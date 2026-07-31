# emira — Implementation Plan

**Companion to `PRINCIPLES.md`.** `PRINCIPLES.md` is the *why* — the SIP-on charter, the two-plane model, and the
graphics thesis. This document is the *how*: the module layout, the shape of the pure core, the shell subsystems a
mature emira contains, and the order we build them in. Where the two disagree, `PRINCIPLES.md` wins on principle and
this doc gets corrected. (`CLAUDE.md` is a thin pointer at both, so agent sessions auto-load the charter.)

Guiding bias, restated: **stay small.** emira should read like AeroSpace-sized software, not a platform. Every
subsystem below earns its place or gets cut. The roadmap (§9) marks the milestone (**M5**) at which emira is a
complete, lightweight product; everything past it is optional polish.

---

## 1. The architectural spine

**Functional core, imperative shell — and the core owns the clock.**

emira is one pure reducer wrapped in a thin macOS shell:

```
                    ┌──────────────────────────────────────────────────┐
   Events  ───────► │            EmiraCore  (pure, no AppKit)           │ ──────► Effects
                    │                                                   │
  · CLI command     │   reduce(State, Event) -> (State, [Effect])       │   · setFrame(win, rect)   [AX]
  · hotkey command  │                                                   │   · park(win)             [AX]
  · AX observation  │   State = World (truth) + Layout + Motion         │   · setLayerFrame(id,rect)[CA]
  · display tick dt │            + Config                               │   · capture(win)          [SCK]
  · IPC / config    │                                                   │   · raiseCover / crossFade
                    └──────────────────────────────────────────────────┘   · focus(win) / raise(win)
                             ▲                              │
                             │ feedback events              │ executed by
                             │ (axLanded, captureReady,     ▼
                             │  crossfadeDone, axFailed)   EmiraShell  (AppKit / AX / SCK / CA)
```

Four invariants hold this together. They are the whole design:

1. **`EmiraCore` imports no framework.** Foundation-only. If a thing can't be a value type or an exhaustive `enum`, it
   lives in the shell. This is what makes the brain unit-testable in isolation.
2. **The core owns animation time.** We do *not* use `CAAnimation` tweening. The core holds `{current, velocity,
   target, curve}` for every animated element and advances them on `Event.tick(dt)`; the shell just blits
   `layer.position` each frame. Retargeting mid-flight is therefore pure arithmetic (new target, keep velocity), not a
   `presentationLayer`/`CAAnimation` teardown. This is the decision from `PRINCIPLES.md` §7.
3. **Effects can fail, and failure is just another event.** Every Effect the shell executes may feed a result back in
   (`axLanded`, `axFailed`, `captureReady`, `crossfadeDone`). The core stays *total* — exhaustive over every event —
   so a hung app or a vanished window is a normal transition, not a crash.
4. **The pump is never re-entrant.** `dispatch()` during an active pump **appends to a FIFO queue and returns**;
   `reduce` never runs inside `reduce`, and event A's effects are fully issued before event B reduces. macOS makes
   accidental recursion easy — `orderFront` fires delegate notifications synchronously, an AX call can complete on the
   calling thread — so any handler that produces an event must enqueue it, never dispatch inline. This costs nothing
   (the queued event still runs in the same run-loop turn, against a consistent state) and does **not** limit
   interruption/retargeting, which happens *between* pumps, never inside one.

Everything else in this document is a consequence of these four.

---

## 2. The command vocabulary (one source of truth)

There is exactly **one** list of "things you can ask emira to do": `Command`. It is defined once in `EmiraCore` and
reused by every surface, so a new verb is added in one place:

- the **CLI** parses `argv` into a `Command` and sends it over the socket;
- the **hotkey manager** maps a key combo to a `Command`;
- the **config file** binds keys and window-rules to `Command`s;
- the **wire protocol** is `Command` (Codable) in an envelope;
- the **core** consumes it as `Event.command(Command)`.

```swift
enum Command {
    case focus(Direction)            // left/right/up/down
    case moveWindow(Direction)
    case moveToWorkspace(WorkspaceRef)
    case moveToWorkspaceAndFocus(WorkspaceRef)   // …and follow it there
    case cycleWidth                  // preset column widths
    case grow(SizeDelta)             // …and the continuous alternative to that ladder
    case shrink(SizeDelta)
    case cycleHeight
    case consumeOrExpel(Direction)   // pull a window into / push out of the column
    case fullscreen(Toggle)
    case float(Toggle)
    case focusWorkspace(WorkspaceRef)
    case closeWindow
    case centerColumn
    case exec(String)                // …and the one verb that is not about the desktop at all
    case dumpState                   // introspection for `emira debug`
    // …grows here, and only here.
}
```

**And shrinks here too, when a verb turns out not to earn its place.** The rule this vocabulary lives by is that
**every verb in it does something**, because `Command.usage` *is* `emira --help` and a listed verb is a promise. That
is not automatic: a verb can parse, ride the socket, be answered `ok`, and be inert in the reducer, with the syntax and
wire tests green the whole time — those check that a verb *parses*, which is not the property anyone cares about.

Keeping this in the pure core (not the protocol layer) means the reducer, the tests, and the CLI all speak the same
type with no translation. `EmiraProtocol` only wraps it for the wire.

**Its surface spelling lives beside it, in `CommandSyntax.swift`, not in the CLI.** The config file's keybindings need
the identical `argv ↔ Command` mapping and `ConfigLoader` cannot depend on an executable, so `parse`, `words` and
`usage` are all core-side; `words` is an exhaustive `switch` the compiler checks, and a test pins the verb table
against it. This is also why there is **no `swift-argument-parser`**: the grammar is "verb, then at most one word", it
is already defined once here, and a subcommand type per verb would be more code in the one target that cannot be
unit-tested at all.

**One verb takes the rest of the line instead of a word, and that is a property of its argument rather than an
exception.** Every other argument is drawn from a fixed vocabulary, so `parse(line:)` splits on whitespace and no
quoting is needed; `exec`'s argument is a *shell* line, whose whitespace and quotes belong to the shell and not to
this grammar. So a verb may declare `takesRawTail`, and `parse(line:)` hands it everything after its own word,
unsplit. From argv the tail is re-joined with single spaces, which is what makes `emira exec …` and
`alt-space = "exec …"` land on the same string: the user's own shell has already done the only splitting that was
theirs to do. This is also why there is no argv-form `exec` beside it — with no quoting in the grammar, an argv form
could not express `osascript -e 'tell application "Ghostty" …'`, which is the entire reason the verb exists.

---

## 3. Data flow & the transition lifecycle

**Steady state has no overlay.** In the resting state the real windows simply sit at their AX positions; the
presentation plane does not exist. A cover/reconstruction is *ephemeral* — it goes up only for the duration of a
transition and comes down on cross-fade. The Runtime therefore has two modes, and the core drives the switch:

- **Idle.** Commands that produce no motion (e.g. a focus change that doesn't scroll) are executed as direct AX sets —
  snap, no cover. The core emits plain `setFrame` / `focus` effects. So does a change to the ground the strip stands
  on — a display change, a config reload — where the geometry moved and nothing travelled.
- **Transition.** Anything that moves the strip opens a *transition session* — including a move nobody asked emira
  for, since **externally-initiated focus** (Cmd-Tab, Dock click, an app activating itself — observed via
  `NSWorkspace` + AX) reveals its window exactly as the `focus` and `focus-workspace` commands do, scrolling to it
  on the strip in view and switching to it across two. The core emits
  `beginTransition`, the shell captures + raises the reconstruction, real windows teleport behind it, and from then on
  every `tick(dt)` advances the core's animators and emits `setLayerFrame`. When all animators settle **and** the AX
  targets have landed (`axLanded`), the core emits `endTransition` → the shell cross-fades to the real desktop and
  drops the cover. The `axLanded` wait is **scoped and bounded**: scoped — wait on every window the viewport **sweeps**
  between its start and end offsets (a failed park leaves a window squatting in view, so departing windows count; only
  park→park motion is invisible and skippable) — and bounded — a hold-timeout (~1 s, itself just an Event) closes the
  transition regardless: reveal the truth, keep retrying the AX set, reconcile when it lands. A frozen cover is worse
  than a visibly hung app.

The core decides *whether a command warrants a transition* (motion vs snap) and *when the transition is done*; the
shell owns the mechanics of cover/capture/cross-fade. This is the clean seam between "policy" (pure) and "mechanism"
(native).

**`snap` is the cover without the clock.** Under `transition = "snap"` the same session runs with **no animator created
at all**: an absent animator already resolves to the value `Layout` derives, so the settle half of the close gate is
answered from the session's first instant, the cover's first blit is the finished strip, and the close waits on
`axLanded` alone. Ticks still arrive — the session is open, so the shell runs the frame clock — and the reducer drops
them, having no new frame to emit.

**A cover's exit is a length, not a yes-or-no**, and each mode has its own: `smooth` dissolves over 220 ms, the tail of
its own motion; `snap` over 40 ms, roughly two frames, enough to be a seam rather than a jump and not enough to be the
most conspicuous motion in a transition whose claim is that it has none; `off` takes `snap`'s length, raising no
cover of its own and so only ever pricing one whose transition outlived a reload. Every length is safe, and this is
why: a cover is dismissed only once its animators have settled *and* its
reals have landed, so it always comes off a desktop that already matches it — what a dissolve hides is a window whose
*content* went stale under the cover, never its geometry. The numbers therefore live in `CompositingExecutor`, above
the test seam, rather than in `Overlay` or `Reconstruction` below it.

**A scope grows and never shrinks.** A retarget aims the scroll somewhere the session was not scoped for, and a
window sliding in with no layer shows the base — i.e. wallpaper — through the gap. So a redirect **widens** the
scope over the newly-swept interval, captures what that adds, and **grows the raised cover** (`Effect.extendCover`)
when the still lands. Nothing is ever *removed*: a window the old destination swept is mid-flight on the
presentation plane and mid-teleport on the truth plane, and dropping it would abandon both.

**The sweep is one query asked of a wider window.** A viewport of width `w` travelling from `a` to `b` covers
`[min, max + w]` — one viewport of width `w + |b − a|` — so `Layout.sweptWindowIds` needs no new geometry. Today's
one-column commands cannot tell the sweep apart from "visible at the start ∪ visible at the end", which is exactly
why it should be right before one can.

**And it carries a shoulder, because growing on a retarget still grows too late.** The stills a widened scope asks
for take a capture round trip and *nothing holds the layers back while they are out*; with minimal-reveal scrolling
the newcomer's leading edge sits exactly one `column-gap` past the destination the session was already aiming at, so
the layers cross into it within a few frames of the press. So `sweptWindowIds` returns the swept run **flanked by the
column just outside each end** — the ones a further command can reach. It is **not** free where it is paid: the
window server serializes screenshot requests, so every shouldered window adds ~10 ms to the head of every scroll
whether or not a further command comes. It is paid there because the alternative does not work — deferred to a batch
issued once the cover is up, the stills land after the layers have already crossed into the newcomer, and a spammed
`focus` reopens a 126 pt band of wallpaper, exactly the hole the shoulder exists to close. Deliberately not
`visibleWindowIds`' business: that query means "what is on
screen" and the reducer parks its complement, so a shouldered answer there would place two parked columns on the
strip.

**The extend gate asks per window, not per session.** Demanding that *every* outstanding capture be in is correct for
one extension and starves under a stream of them — each command adds a capture before the previous lands, the gate
never opens again, and the cover stops growing for the rest of the transition. The gate exists for a real reason
(`extendCover` mints a layer id for every unbound window and the shell binds it *once*, so naming a window whose
still is in flight spends its only chance at a layer), and asking it per window makes it incapable of starving. The
**raise** keeps its all-or-nothing gate, because that one is about the base: a cover raised without it is not a cover.

**A snap-path event arriving mid-transition *redirects* the session rather than returning nothing.** A
`windowCreated` during a scroll reconciles the newcomer onto the strip; a branch that then retargets the viewport and
emits no effects leaves it never placed, never captured, and never re-asserted, because nothing emits placements when
a transition closes. Every such path goes through the same opens-or-redirects call the command paths use, which widens
the scope, captures the newcomer and re-teleports the reals behind a raised cover. The consequence is that the
landing wait **grows and never shrinks**: only the *initial* teleport replaces it, since a later re-teleport that
moves nothing would otherwise clear the wait for sets still in flight and let the cover cross-fade onto reals that
have not arrived.

**`axFailed` records that we don't know where the window is.** Placement writes its target into `World`
optimistically, which is what keeps a repeated idle event from re-emitting forever; the executor corrects that only
when it could still read the frame back, which a timed-out write generally cannot. The lie then stands as truth and
the placement diff skips the window forever. Marking it unverified makes that predicate answer `false`, and issuing
the set clears it. Deliberately **not** a retry — nothing is scheduled — so a genuinely hung app costs one extra set
per real event instead of a busy loop.

**A batch streams its pieces, and what the atomic batch was protecting is now said outright.** Stills used to be
answered all at once, on the reasoning that per-window acks would let the core count down to a raise the base was not
ready for. That reasoning is about the *base*, not about batching, and answering as a unit charges every cover the
full serialized cost of its scope (§6). So a batch hands each piece over as it lands, and the capture plane holds
every ack until the base is in — the same guarantee, stated as the rule it always was. The core's gate is untouched:
it still raises on the last `captureReady` and knows nothing about a base.

**`CoverMode` decides when a window *has* pixels, and that is the whole of it.** Under `immediate` a window whose
kept still fits is acked at once, and its own capture — still taken, because the stand-in buys the raise and not the
transition — comes back as `Event.captureRefreshed`, which the reducer turns into `Effect.refreshLayer`: a cross-fade
of one layer's *contents*, at whatever rect the last tick left it. It settles no gate, so it cannot raise, extend or
close anything; a refresh naming a window with no layer yet is silently nothing, because the raise reads the store and
finds those pixels already there. `Effect.capture` carries the window's current **size** for this, since only the core
can say whether a window moved (its pixels are still good) or was re-laid-out (they are not), and `SurfaceCache` holds
what a cover leaves behind at quarter scale — the memory budget and the "this is not live" tell, bought once. Nothing
invalidates on a window's death: `WindowId`s are never reused, so a dead window's entry is unreachable rather than
wrong, and the byte budget collects it.

**A deadline that fires must degrade, not black out.** Every `capture` is answered exactly once within a bounded
deadline (250 ms), because the core raises the cover on the *last* `captureReady` and the hold-timeout only starts at
the raise — a dropped ack is a command that silently does nothing, with nothing to rescue it. A head batch that
resolves with **no base** leaves the reconstruction nothing to be opaque with, and an overlay's own fill is black, so
the capture plane answers `Event.coverUnavailable` and the core abandons the session **before any window has moved**
and snaps — the same degradation a machine with no Screen Recording grant gets.

Continuous gestures (§9, M7) are the same session opened by gesture-begin and closed by gesture-end + settle.

---

## 4. Module / target graph

Five library targets and two executables. Dependencies point strictly upward; nothing below imports a framework.

```
EmiraMotion     pure math — springs, easing curves, the scalar Animator.  (zero deps)
    ▲
EmiraCore       pure — geometry, ids, Command/Event/Effect, State, layout engine,
    │           rules, Config values, the Engine reducer.        (deps: EmiraMotion)
    ▲
   ├── EmiraProtocol   Codable request/reply envelope, wire framing, one-shot socket client.  (deps: EmiraCore)
   └── EmiraConfig     pure — the TOML grammar and the config schema; text ⇄ `Config`.        (deps: EmiraCore)
    ▲
EmiraShell      imperative — Runtime, Executor, AX, Capture, Compositor, DisplayLink,
    │           Hotkeys, ConfigLoader, IPC server, MenuBar, Permissions.
    │  (deps: EmiraCore, EmiraConfig, EmiraProtocol; imports AppKit/QuartzCore/SCK/AX/Carbon)
    ▲
   ├── emira-daemon   executable — NSApplication accessory host that runs the Runtime.
   └── emira          executable — CLI; socket client, plus `emira config` over the file.
                      (deps: EmiraProtocol + EmiraCore + EmiraConfig)
```

**Why `EmiraMotion` is its own target and not a folder.** A spring/easing solver is genuinely generic — scalar in,
scalar out, given `dt` — and has nothing to do with columns or AX. Splitting it out keeps the physics honest (it can't
reach into reconciler state) and independently testable (feed ticks, assert convergence and velocity carryover). It's
tiny; if two targets ever feels like one too many we collapse it into `EmiraCore/Animation/`, but the seam is worth
starting with.

**Why `EmiraConfig` is its own target and not a folder.** The config *values* stay in `EmiraCore`, because the reducer
reads them; what moved out is the file format — the grammar and the schema, `String ⇄ Config`. A folder would have
been the same code in the same places, and it would not have stopped a settings window from importing the `Engine`.
The target is the thing that makes "the GUI sees the config and nothing else" enforced rather than intended, and it
does the same for the CLI in the other direction: `emira config` reaches the file format without reaching the shell.
The naming precedent was already in the tree — `Command`/`CommandSyntax`, `Config`/`ConfigSyntax`; the package
boundary is what makes that separation load-bearing.

**Why the CLI stays at the bottom of the graph.** The CLI must be framework-free and trivially fast to launch. It
parses `argv` into a `Command`, hands it to `SocketClient`, prints the reply. No AX, no CA, no AppKit — and no
`EmiraShell`. Note that the *transport* lives in `EmiraProtocol`, not in the executable: an executable can't be
imported, so anything with logic in it is untested by construction, and partial writes, a peer hanging up mid-reply
and version-mismatched answers are exactly the failures that need tests. It names `EmiraCore` as well as
`EmiraProtocol` because it builds the *one* vocabulary directly (§2, `Command.parse`); `EmiraProtocol` already pulls
`EmiraCore` in, so this adds nothing to launch cost, and the alternative — wrapping `Command` behind the envelope —
would be the translation layer §2 exists to avoid. It names `EmiraConfig` for `emira config`, which is **local**: it
reads and writes the file and dials no socket, so it branches before `Command.parse` and is not a verb — the config
file is not a thing you ask the daemon to do. The same rule about logic applies, so the schema knowledge (what a
setting is, what a word from the command line means) is `EmiraConfig`'s and what is left in the executable is argv,
exit codes and the disk.

---

## 5. Directory layout

```
emira/
├── Package.swift
├── Makefile                         # build + test; `app` assembles dist/emira.app — the two
│                                    # executables, the nested CLI signed before the outer seal, plus
│                                    # EmiraShell's resource bundle, which is *not* signed: it holds no
│                                    # code, the outer seal covers its files, and whether SwiftPM gives
│                                    # it a Contents/Info.plist is toolchain-dependent — codesign
│                                    # rejects the flat form. Also compiles the icon (§5 Resources) and
│                                    # stamps its
│                                    # version from the git tag, `zip` archives it, `install` copies
│                                    # it to /Applications. No CLI symlink — a Homebrew cask's
│                                    # `binary` stanza points at the copy inside the bundle
├── .github/
│   ├── workflows/
│   │   ├── ci.yml                   # pull requests: build + test on macos-26
│   │   └── release.yml              # main → the `tip` prerelease; a `v*` tag → that version, and
│   │                                # the cask bump pushed to the tap (§7)
│   └── demo/                        # the README's film, written down. `demo.sh` choreographs shell
│                                    # + `emira` calls with fixed pauses, captions each step through
│                                    # `caption.swift` (an AppKit panel over a fifo) and records the
│                                    # lot with `screencapture`, stopped by SIGINT so the film is
│                                    # exactly as long as the choreography
├── CLAUDE.md                        # thin agent pointer at the docs below
├── .knowledge/
│   ├── README.md                    # how this project remembers things
│   ├── PRINCIPLES.md                # charter / why
│   ├── IMPLEMENTATION.md            # this file / how
│   └── changes/                     # one file per change, named by epoch second
├── Resources/
│   ├── Info.plist                   # LSUIElement=YES (menu-bar accessory) + a stable
│   │                                # CFBundleIdentifier, which is what TCC records a grant
│   │                                # against. No TCC usage strings: neither Accessibility nor
│   │                                # Screen Recording takes one
│   ├── emira.icon/                  # the app icon, layered: three offset panes the system relights
│   │                                # per layer. `icon.json` composes `Assets/{back,middle,front}.svg`,
│   │                                # one group each so every pane casts its own shadow. `make icon`
│   │                                # compiles it to Assets.car, named by CFBundleIconName; no legacy
│   │                                # .icns, since macOS 26 is the floor
│   └── default-config.toml
├── Sources/
│   ├── EmiraMotion/
│   │   ├── Curve.swift              # easing functions + spring params
│   │   ├── Spring.swift             # critically-damped spring integrator (analytic, closed-form)
│   │   └── Animator.swift           # {current, velocity, target}; advance(dt); retarget(); nudge()
│   ├── EmiraCore/
│   │   ├── Geometry.swift           # own Rect/Point/Size on the virtual strip (not CG*)
│   │   ├── Ids.swift                # WindowId, ColumnId, MonitorId, LayerId — no WorkspaceId:
│   │   │                            # workspaces are a fixed *named* domain, not minted tokens
│   │   ├── WorkspaceName.swift      # the 36 workspace addresses in **key** order — `1`–`9`, `0`, then
│   │   │                            # `a`–`z`. A rank plus its character; `1` is the launch address and
│   │   │                            # `0` is the tenth, so rank order is *not* alphabetical
│   │   ├── Command.swift            # §2 — the one vocabulary
│   │   ├── CommandSyntax.swift      # its surface spelling: parse(argv)/words/usage (CLI + keybinds)
│   │   ├── KeyChord.swift           # the *other* surface spelling: `cmd-alt-h` ⇄ modifiers + a named
│   │   │                            # `Key`. Exhaustive in the core so a bad chord is a config
│   │   │                            # diagnostic with a line number, not a log line at bind time
│   │   ├── Event.swift              # exhaustive input enum (commands + observations + tick)
│   │   ├── Effect.swift             # exhaustive output enum (AX / CA / SCK / cover intents)
│   │   ├── State/
│   │   │   ├── World.swift          # truth: monitors, apps, windows, focus, managed/floating
│   │   │   ├── Motion.swift         # viewport-offset + per-column width + per-window Animators;
│   │   │   │                        # the transition session
│   │   │   └── RectAnimator.swift   # four scalar animators in a trenchcoat, for displacements
│   │   ├── Layout/
│   │   │   ├── Layout.swift         # ONE strip → columns → windows; its target geometry. Also
│   │   │   │                        # the four structural editing primitives — reorder a column,
│   │   │   │                        # reorder within a stack, merge into a column, extract into a
│   │   │   │                        # new one — that `move-window`/`consume-or-expel` compose from
│   │   │   ├── Workspaces.swift     # the 36 strips, which one is focused, and the *one* ColumnId
│   │   │   │                        # allocator they share. Owns the queries that span strips:
│   │   │   │                        # membership reconciliation, the park-ordinal run, `targetFrames`
│   │   │   │                        # over the whole set, each strip's scroll/focus **memory**,
│   │   │   │                        # `WorkspaceRef` resolution, and the atomic cross-strip `move`
│   │   │   ├── Strip.swift          # infinite-axis math, viewport scroll, centering
│   │   │   ├── Column.swift         # vertical stack, heights; the height **water-fill** — an auto
│   │   │   │                        # window whose `HeightBound` rules its share out takes the bound
│   │   │   │                        # and the others re-divide, to a fixpoint. Both directions: a
│   │   │   │                        # floor shrinks what the rest divide, a ceiling (an app that will
│   │   │   │                        # not *grow*) hands the surplus back rather than leaving a hole
│   │   │   ├── Presets.swift        # cyclable width/height presets, inner + outer gaps, struts
│   │   │   ├── Cascade.swift        # the one layout that isn't the strip: the **quit cascade**.
│   │   │   │                        # Centre ¾ of the working area, 30 pt stagger, bottom-rights
│   │   │   │                        # aligned, step compressed rather than collapsed on a deep
│   │   │   │                        # stack. Pure `Rect` arithmetic; the ordering policy (focused
│   │   │   │                        # window last = frontmost) is beside it on `State`
│   │   │   └── Park.swift           # deterministic unique corner nubs (park = target geometry)
│   │   ├── Config.swift             # parsed config *values* (pure data; loading is in Shell)
│   │   └── Engine.swift             # reduce(State, Event) -> (State, [Effect])
│   ├── EmiraConfig/                 # the config file's *format*, and nothing that touches a disk
│   │   ├── TOML.swift               # the minimal TOML *grammar* the config file is written in —
│   │   │                            # text → dotted keys + line numbers + source spans, and one
│   │   │                            # value spelled back. Hand-rolled, no dependency
│   │   ├── ConfigSchema.swift       # the config *schema* as a table you can enumerate: one `Setting`
│   │   │                            # per key — spelling, prose, legal values, presentation — and the
│   │   │                            # codec that moves it between file and `Config`
│   │   ├── ConfigSyntax.swift       # the *reading*: runs the table, then the three sections it
│   │   │                            # doesn't describe, then "what was left". Stands to `Config.swift`
│   │   │                            # as `CommandSyntax` stands to `Command`
│   │   ├── ConfigExample.swift      # the schema rendered as a config file — `emira.example.toml`,
│   │   │                            # generated and pinned by a golden test
│   │   ├── ConfigExplain.swift      # the schema rendered as prose — one setting in full, or every
│   │   │                            # setting beside what the file says now. `emira config explain`
│   │   ├── ConfigDocument.swift     # text + parse held together: set/remove one value, splicing over
│   │   │                            # the bytes it occupies and reformatting nothing. Renders a
│   │   │                            # `String`; the caller writes it
│   │   └── ConfigPath.swift         # `Config.defaultPath()` — `$EMIRA_CONFIG` or the XDG-style
│   │                                # path. Where the file lives is a fact about the config, so
│   │                                # both the daemon and the CLI read it from here
│   ├── EmiraProtocol/
│   │   ├── Request.swift            # Command + client metadata (pid) + version
│   │   ├── Reply.swift              # ok / error / state dump (opaque JSON), + version
│   │   ├── Wire.swift               # socket path + sockaddr, JSON-lines framing (LineBuffer), probe
│   │   └── SocketClient.swift       # blocking one-shot dial: send(Request) -> Reply
│   ├── EmiraShell/
│   │   ├── Runtime.swift            # @MainActor pump: Event -> Engine.reduce -> Executor
│   │   ├── Executor.swift           # protocol interpreting Effects (Live + Mock impls)
│   │   ├── WindowRegistry.swift     # mints WindowIds; binds AX ↔ CGWindowID at first sight
│   │   ├── AX/
│   │   │   ├── AXAccess.swift       # the AX vocabulary: AXApplication/AXWindow value wrappers,
│   │   │   │                        # typed attribute reads, subrole -> WindowRole. One of the two
│   │   │   │                        # files that import ApplicationServices
│   │   │   ├── AXClient.swift       # serial per-app queues, messaging timeout, set/get
│   │   │   ├── AXEnumerator.swift   # window-level enumeration only (no child walk).
│   │   │   │                        # `WindowSource` protocol + AXWindowSource (the untestable half)
│   │   │   ├── AXWriter.swift       # the write half's boundary: `WindowWriter` protocol (place a
│   │   │   │                        # *group* of one app's windows / focus / raise) + AXWindowWriter
│   │   │   ├── AXExecutor.swift     # the truth plane's Executor: groups a batch into one lane job
│   │   │   │                        # per app, acks axLanded/axFailed, reports clamp drift
│   │   │   ├── Observation.swift    # WorldObservation vocabulary + the `ObservationSource` seam.
│   │   │   │                        # Not `Event`: "a window appeared" needs a re-scan to be named,
│   │   │   │                        # and "a window moved" carries no frame — both are policy
│   │   │   ├── AXObservers.swift    # AXObservationSource: per-app AXObserver (registered against
│   │   │   │                        # *two* element scopes), NSWorkspace launch/quit/activate, and
│   │   │   │                        # the global mouse-up monitor
│   │   │   ├── FocusIntent.swift    # the focus emira asked for, so it can tell its own echo from the
│   │   │   │                        # user's Cmd-Tab. Written by the writer, read by the writer (which
│   │   │   │                        # activation is still wanted) and by WorldWatcher (which report is
│   │   │   │                        # news). Shared per daemon, like WindowRegistry
│   │   │   └── EnhancedUI.swift     # suspend kAXEnhancedUserInterface around a group of sets —
│   │   │                            # read first, restore after, once per app per batch
│   │   ├── Capture/
│   │   │   ├── CaptureService.swift # the capture *plane*: batch, deadline, ack-exactly-once, hold
│   │   │   │                        # every ack for the base, and the WindowId-keyed store the
│   │   │   │                        # cover reads
│   │   │   ├── SurfaceCache.swift   # stills that outlive their cover, at quarter scale — what
│   │   │   │                        # CoverMode.immediate raises over, matched on size alone
│   │   │   ├── SCKCapturer.swift    # the ScreenCaptureKit half: one still per window
│   │   │   │                        # (desktopIndependentWindow) + the display excluding them as
│   │   │   │                        # the base, streamed back a piece at a time, base first
│   │   │   └── LiveStream.swift     # SCK live layers (deluxe; M7)
│   │   ├── Compositor/
│   │   │   ├── ScreenGeometry.swift # THE Y-flip: core top-left ↔ Cocoa bottom-left (one number)
│   │   │   ├── Overlay.swift        # borderless click-through NSWindow per display; raise/cross-fade
│   │   │   ├── Reconstruction.swift # captured desktop base + one CALayer per window carrying that
│   │   │   │                        # window's still, placed at its *capture-time* frame, with a
│   │   │   │                        # synthesized shadow (CoverSurface)
│   │   │   └── CompositingExecutor.swift # CoverSurface protocol + Executor routing by plane —
│   │   │                            # three of them (presentation / capture / truth)
│   │   ├── Display/
│   │   │   ├── FrameClock.swift     # tick-source protocol the Runtime gates (the testable seam)
│   │   │   ├── DisplayLinkDriver.swift  # CADisplayLink (NSScreen.displayLink) -> Event.tick(dt)
│   │   │   └── HoldTimer.swift      # the transition deadline -> Event.holdTimeout
│   │   ├── Input/
│   │   │   ├── Hotkeys.swift        # the policy: `HotkeyBinder` seam + `HotkeyManager`. An event
│   │   │   │                        # *source* like the socket server, not an Effect
│   │   │   └── CarbonHotkeys.swift  # RegisterEventHotKey + the Key -> kVK_* table
│   │   ├── Config/
│   │   │   ├── ConfigLoader.swift   # the half that needs a disk: read → watch → report.
│   │   │   │                        # The `FileWatcher` seam and `ConfigWatcher` — vnode sources on
│   │   │   │                        # the file *and* its directory
│   │   │   └── ConfigFile.swift     # the third thing done with it: hand it to the user's editor,
│   │   │                            # creating it first — a file that isn't there has no handler
│   │   ├── Ipc/
│   │   │   ├── SocketServer.swift   # unix-domain socket, JSON-lines, dispatch to Runtime
│   │   │   └── RequestRouter.swift  # Request -> Reply: commands are writes, dumpState is a read
│   │   ├── MenuBar/
│   │   │   └── StatusItem.swift     # the running GUI: an NSStatusItem showing the focused
│   │   │                            # workspace's address, `!` when the config won't parse.
│   │   │                            # `StatusModel` is the pure title/diagnostic policy;
│   │   │                            # `LoginItem` wraps SMAppService; `MenuBarItem` is the
│   │   │                            # AppKit wiring. Open-at-login, open-config-file and quit
│   │   │                            # are the menu
│   │   ├── Onboarding/              # the *other* GUI, and it only ever runs once: the first
│   │   │   ├── Onboarding.swift     # launch. `OnboardingModel` is the policy — which grants
│   │   │   │                        # are asked for, the copy, when boot may proceed — and
│   │   │   │                        # `OnboardingPlacement` the geometry that keeps the
│   │   │   │                        # window clear of macOS's own prompt
│   │   │   ├── OnboardingWindow.swift  # the AppKit wiring: wordmark, blurb, a row per grant,
│   │   │   │                        # and a modal session that *holds boot* while a 300 ms
│   │   │   │                        # heartbeat waits for the switch to be flipped
│   │   │   ├── Wordmark.swift       # the heading: the README's animated WebP, one frame decoded
│   │   │   │                        # at a time on the delays the asset itself declares
│   │   │   └── PulseButton.swift    # `quit emira` — the only control emira asks anyone to press,
│   │   │                            # so it glows and shimmers. The cell draws nothing; the
│   │   │                            # gradient, the sheen and the label are all ours
│   │   ├── Resources/logo.webp      # that asset — the README's wordmark, animation and alpha
│   │   │                            # included. A resource of the target that draws it, so
│   │   │                            # `Bundle.module` resolves in a bare `swift build` tree too
│   │   ├── WorldWatcher.swift       # the live world's *policy*: boot scan -> adopt -> watch;
│   │   │                            # re-scan an app when it makes a window; one bounded retry for
│   │   │                            # the two "asked too early" races; coalesced frame reads
│   │   ├── Teardown.swift           # the last thing that runs: place every managed window into the
│   │   │                            # quit cascade and hold the exit until the AX sets land, bounded.
│   │   │                            # What it owns is the *waiting*; the daemon owns the order —
│   │   │                            # silence the event sources first, since our own writes are
│   │   │                            # observations (`WorldWatcher.stop()`)
│   │   ├── ProcessLauncher.swift    # the system plane, whole: `Effect.exec` → `/bin/sh -c`, fire
│   │   │                            # and forget. `ShellLauncher` reports only what a command
│   │   │                            # surface cannot already log — a failed spawn, a bad exit
│   │   ├── Scheduler.swift          # DelayScheduler — "try that again in a moment"; Heartbeat — "and keep asking"
│   │   ├── Permissions.swift        # AX + Screen Recording TCC checks (asked for in Onboarding/)
│   │   └── Logging.swift            # os_log wrapper
│   ├── emira-daemon/main.swift      # accessory NSApplication; wire up Runtime + subsystems. Also
│   │                                # answers `--probe-capture` before any of that exists — one
│   │                                # TCC read, one exit code, for onboarding's subprocess probe
│   └── emira/
│       ├── main.swift               # argv -> Command -> Request -> socket; --dry-run, --help
│       └── ConfigCommand.swift      # `emira config` — check/explain/get/set, straight to the file.
│                                    # No socket, no verb, and no sentence about a setting: argv,
│                                    # exit codes and the atomic save, over `EmiraConfig`
└── Tests/
    ├── EmiraMotionTests/            # spring convergence, retarget velocity carryover
    ├── EmiraCoreTests/              # layout math, engine scenarios, golden replays
    ├── EmiraConfigTests/            # the grammar and the schema — every diagnostic, by line number;
                                     # the document model — round-trip identity over a corpus; and the
                                     # schema as text — every entry reads back whatever it prints
    ├── EmiraProtocolTests/          # envelope round-trips, framing, version-mismatch (both ways)
    └── EmiraShellTests/             # the pump: FIFO/non-re-entrancy, lifecycle, clock gating;
                                     # the IPC seam over a real socket + socket-path safety
```

---

## 6. What a mature emira contains

Grouped by plane. Items marked *(later)* are post-M5 polish, not part of the lightweight core.

### Pure core (`EmiraMotion` + `EmiraCore`)
- **Motion: three animated quantities, and never three authorities on one number.** A critically-damped spring plus
  easing curves, and a scalar `Animator` whose `retarget()` preserves velocity and whose `nudge()` says "the thing
  this is measured against jumped".
  - A **scroll** animates the viewport offset — one scalar, with every layer frame derived from it, so lockstep is
    structural rather than maintained, settle-detection is trivial and a retarget is one number. It is also the natural
    handle for continuous trackpad gestures (M7): the finger drives it directly.
  - A **resize** animates the *second* such scalar, a column's resolved width (`Motion.columnWidths`), for exactly
    the same reason: every frame on the strip derives from it, so the growing column and every column it pushes
    along move in lockstep from geometry that already existed. `animateColumnWidth` **retargets** an in-flight width
    rather than restarting it, because cycling is a keybind and the second press lands mid-flight.
  - A **structural edit** animates the *third* quantity, and it is the one that is not like the other two: there is
    no number the new frames derive from, because an edit that inserts or removes a column makes before and after two
    different `Layout`s. So what goes under a spring is each window's **displacement** from where the layout now says
    it belongs, decaying to zero (`Motion.windowAnimators`, `RectAnimator`) — the destination stays derived, and only
    the *lag* is per-window. Every emitted layer frame is one derived rect plus these three, summed.
    - **A departure and an arrival are structural edits too**, and saying so is the whole of their animation.
      `move-window`, `consume-or-expel`, close, minimize, hide and adoption all ride one shared path. The only thing a
      departure lacks is a **mover** — the window that would ride on top has left, and the survivors merely close
      ranks — so that parameter is optional and nothing else changes. An *arrival* has the opposite asymmetry: a
      newcomer has no frame in the old geometry, so it is seeded with **the frame its app opened it at**, which is
      also the frame the cover captures. That equality is why the raise does not pop, and it makes the newcomer
      *travel* rather than appear, with every column it displaces handled by the ordinary loop.
    - **Boot animates too, deliberately**: the launch scan's adoptions coalesce into one session, and carving out an
      exception would mean a second vocabulary for "a window we found" versus "a window you made".
    - **Whether an edit is worth a cover asks about *both* animated quantities.** Counting displacements alone is not
      the same claim as "nothing moves": the displacements are deliberately measured at a *fixed* offset on both sides
      of the edit so the scroll cancels out of them, which means a scroll can never show up as one. A departure at the
      far end of the strip displaces nobody — every survivor keeps its strip position, and the only thing that changed
      is that the strip is now a column shorter than the offset the viewport rests at.
- **Geometry & the strip:** infinite-axis coordinates, column widths/heights, inner gaps (`column-gap`,
  `window-gap`), **outer gaps** at the edges of the working area, and **struts** (reserve the menu-bar/notch region so
  tiled windows never sit under it).
  - **An outer gap is not a strut, and that is the whole design.** The arithmetic is identical — both are
    `Rect.inset(by:)` — so the tempting implementation folds the gaps into the struts in one line. It is wrong,
    because the two insets mean opposite things about *motion*. A strut is **forbidden ground**: no managed window is
    ever inside it, tiled or parked, which is precisely what licensed the strut-inset cover. An outer gap is **empty
    at rest and crossed in motion** — a column scrolling in slides through it — and the cover clips, so a
    strut-shaped outer gap would cut every layer off at the margin's inner edge and a window would pop into being
    there instead of sliding through. Two insets that compute the same thing and disagree about what may cross them
    are two quantities.
  - **So there are two viewports, and every geometry query picks a side.** `LayoutMetrics.contentArea` is the
    *logical* viewport (the working area inset by the outer gaps) and `workingArea` keeps meaning the *physical*
    extent. **Logical** is where the strip lives: a width proportion resolves against it (so 100% leaves the margin
    showing, and `grow`'s ceiling moves with it), column 0 starts at its left edge, columns are as tall as it, and
    every scroll target frames against it — *"reveal this column" means put it where it can comfortably be seen,
    inside the margin, not flush with the screen edge.* **Physical** is what is on screen: tile-vs-park, the capture
    scope, and the edge a sliver hugs.
  - **The physical half is load-bearing and it looks harmless.** `Layout.visibleWindowIds` *is* the reducer's
    setFrame-vs-park switch. Ask it of the logical viewport and a column whose leading edge sits in the margin gets
    parked to its 1 px sliver — the margin enforced by teleporting windows out of it, which is the clipping this
    design exists to avoid, reintroduced through the back door. Worse, it pops the cross-fade, because the
    presentation plane draws that column from geometry that never parks. The conversion costs no new geometry: the
    physical viewport in strip space is the logical one *outset* by the horizontal gaps.
    - **And sub-point overlap is not visibility**, because the two sides of that comparison are computed
      differently. A column's left edge is a running *prefix* of the widths while the offset that frames a
      viewport-wide column comes from their *sum*, so at the one arrangement where those are equal in exact
      arithmetic — a `fullscreen` or grown-to-ceiling column revealed against a neighbour no binary fraction holds,
      like ⅓ — they differ by ~1e-13 and the neighbour strictly overlaps. Tiled on that, a full-height window is
      asked to sit entirely off the left edge, which macOS will not do; it clamps the window back to a ~40 pt sliver
      in plain view. The presentation plane derives from the same numbers and correctly draws nothing, so the strand
      is invisible during the motion and arrives out of the cross-fade. `Strip.visibilityTolerance` is half a point,
      the sub-pixel tolerance the placement diff already runs at.
  - **A neighbour bleeds into the margin at rest iff `outer-gap > column-gap`.** After a reveal leaves a column flush
    with the content's right edge, its neighbour starts one `column-gap` further on while the display ends one
    `outer-gap-right` further on. Bleed is a supported state, not a defect — windows may overflow the viewport, that
    is the premise — but a user who wants a clean margin now knows the inequality that gives them one.
- **Width resolution is a stack, and a column steps *off* the preset ladder rather than rewriting it.** `cycle-width`
  advances a preset index; `grow`/`shrink` write an explicit `widthOverride` that shadows it, and `cycle-width` clears
  the override and resumes from the rung the ladder was last left on. That is why the override is a second field
  beside the preset index rather than a third case unioned into it: nothing has to guess which preset a grown column
  is "nearest", and the nearest-match rule has no right answer.
  - **A percentage is of the working area, not of the column's own width.** The compounding reading loses on its
    consequences: the step size drifts with every press, and `grow 10%` followed by `shrink 10%` lands 1% short of
    where it began (0.9 × 1.1 = 0.99) — an instrument whose two directions do not cancel. Against the working width
    the steps are uniform, the verbs are exact inverses, and the unit is the one the ⅓/½/⅔ presets already speak.
  - **The intent is stored in the unit it was asked in.** `grow 10%` leaves a proportion that tracks the monitor
    exactly as a preset does; `grow 100px` leaves a fixed count that means those points on any display. Someone who
    names points meant points.
  - **The clamp can stop a resize; it may never reverse one.** The ceiling is the working width and the floor is a
    bare minimum, but each is widened to the current width when the column is already outside it — so a `grow` on a
    column a config deliberately made wider than the screen is a no-op rather than a sudden shrink to fit.
  - **`resize-detent` catches the knob where the strip goes flush, and a second press pushes past.** A delta that
    would carry a viewport edge across a column edge is cut short at that edge (`Strip.resizeDetent`); a delta
    starting *from* one spends in full, because a sweep beginning on an edge crosses none. **The geometry is the
    memory** — nothing records that the last press was clamped, so nothing has to invalidate it when a focus change,
    a new window or an app's `SizeCorrection` moves the strip underneath. Only the continuous verbs catch: a preset
    is an exact intent and ½ has to stay ½, so the ladder and `fullscreen` step past the notch.
  - **`fullscreen` is a third layer *shadowing* both, not a fourth way of writing a width.** It takes the focused
    window to 100% of the content area — the strip's fullscreen, not the system's: no Space, nothing hidden, the
    neighbours simply park and scroll back. Because the flag shadows the override, which shadows the preset, **the
    width underneath needs no memory and no restore policy**: a column grown to 40% is 40% again exactly, and one on
    a ladder rung is that rung, re-resolved against whatever the presets say *now*. The alternative (save the old
    intent, put it back) has to decide what a saved 500 pt means after the ladder was rewritten, and there is no good
    answer.
  - **An explicit width verb clears the flag**, which is a decision rather than hygiene: a width the user asked for
    out loud must be a width they can see. Left shadowed it is an invisible number, and the next `shrink` on a column
    already at 100% would move nothing at all — a dead knob. Cleared, the same press is *continuous* for free, since
    the delta is taken from the resolved width. It clears the undo record with it, for the same reason: what the user
    just asked for is where things now are.
  - **A window, not a column — so it *expels*, and therefore has to undo.** One with stackmates pops out into a
    column of its own first, which is how it becomes full height as well as full width with no per-window height
    intent to invent. That branch is the one `move-window` and `consume-or-expel` already make: alone in its column ⇒
    the column resizes; with stackmates ⇒ it pops out. An expel is only tolerable because the second press puts it
    back, so the column carries a `Fullscreen` record — the stack it left (column id + row) and the viewport it was
    looking at. **Two things shadowing cannot carry, and nothing else**: the width still comes back by being
    un-shadowed.
    - **The viewport is stored as an anchor, not an offset** — a column, and its distance from the content area's
      left edge. A scroll offset is a number in strip space that a column opening, closing or resizing to its *left*
      silently re-points; re-reading the anchor's left edge at restore time absorbs all three, so rearranging the
      part of the strip you were not looking at leaves the restore exact.
    - **Staleness is not detected, it is unrepresentable.** Each half of the record names a `ColumnId`, ids are never
      re-issued, and each half is simply not applied if its column has gone — the window keeps the column it is in,
      or the strip reveals it the ordinary way. So "somebody rearranged things" needs no predicate and no expiry, and
      every degradation lands on exactly what `fullscreen` did before it remembered anything.
    - **The growth rides the structural edit, not the width spring.** The popped-out column is *born* at 100% and
      never resizes, so its width is the expelled window's displacement from the slot it left — one animator with an
      opinion about that number, the same division of labour `springHeightChange` keeps on the other axis. The
      solo-window branch stays a pure resize and keeps the width spring, which is what a `SizeCorrection` springs back
      through.
  - **Still not exclusive.** Two fullscreen windows is two full-width columns, an arrangement `grow` already reaches,
    and each carries its own record, so each undoes on its own and in either order. A window carried to another
    workspace, or expelled out of a fullscreen column, takes the **width** and not the record: the arrangement it
    would restore into is not the one it is going to.
- **What an app answered is a fact the geometry consults, in both directions** (`World.corrections`, one
  `SizeCorrection { wanted, actual }` per window, `PRINCIPLES.md` §5). `wanted` is the **uncorrected** layout size —
  computed by running the ordinary geometry against metrics with the corrections emptied — so the question cannot
  drift from the answer. A preset cycle, a gap or strut edit, a display change or a change in column membership all
  change the question, which retires the record with no expiry to maintain.
  - **Keying on the question is what stops a ratchet, and the alternative genuinely fails.** A stored `minWidth` is
    raised by any refusal-to-shrink — but the first refusal observed might be character-cell quantization at a *large*
    preset (ask 900, get 904), and 904 then floors the ⅓ preset forever, so the column can never be 600 again and
    nothing will ever ask it to. There is no threshold separating "a minimum" from "a grid" without guessing a number.
    Against its question, 904 is simply not consulted when the question is 600.
  - **`Layout.resolvedWidth` says what a column is for: a column is as wide as the widest width its windows can
    actually achieve for the width it was asked.** A window that has answered contributes its answer, one that has not
    contributes the intent, and `max` is what makes a single expression cover both directions. The invariant chooses
    it: a window refusing to *shrink* needs the room, since less would overlap its neighbour — the one thing the strip
    promises — while a column *none* of whose windows can grow is holding room nobody can use. A mixed stack keeps the
    intent, because one window that can fill it is reason enough.
  - **Corrections ride in `LayoutMetrics`, and that placement is the load-bearing one.** Every geometry entry point
    already takes `metrics`, so a correction cannot be forgotten at a call site — and it *must* reach all of them,
    because a `targetFrames` that widened a column while the visibility, sweep and scroll queries kept the preset
    would accumulate different left edges and place windows at the wrong x. The same argument the Y-flip makes:
    something that cannot break beats something that must be maintained.
  - **A park teaches nothing.** A park slot is a 1 px sliver at the working area's edge, and a window will refuse a
    resize there that it accepts the moment it scrolls back into view — so an answer given at a park describes
    off-viewport geometry, not the window, and recording it would freeze the column at whatever width it was parked
    at. Hence a drifted **tile** is a placement correction that carries its request along (an answer is only evidence
    in relation to its question), while a drifted **park** is ordinary external drift.
  - **The downward direction can recurse, and is bounded where the evidence is.** Narrowing means the column follows
    the answer down, so the *next* request is the answer rather than the question — and an app that always returns
    slightly less than asked would walk the column toward nothing. So a **narrower** answer is learned only when the
    request that produced it *was* the question: at most one narrowing per question. The widening direction keeps
    learning unconditionally, and the asymmetry is the invariant rather than taste — too wide overlaps a neighbour and
    must be absorbed however late it arrives; too narrow only leaves space.
  - **A refusal is a cache of one answer, not a fact about the window — so a resize verb re-asks.** The record's own
    rule ("ask once, then use the answer") assumed a window's limits are a property of the *window*. They are usually
    a property of what it is currently *showing*: an app that will not be 900 pt wide with one tab open may be
    perfectly willing with another, and nothing observes that or can. So the explicit resize verbs retire the record
    for their column and genuinely re-ask, because the moment the user asks for a size again is exactly the moment to
    find out rather than to consult a memory. **That also answers "how do we give feedback for a refusal" without a
    mechanism for it**: there is no bounce to stage. There is an attempt, and the spring home *is* what a failed
    attempt looks like. Called only from the verbs, never from a placement — a scroll must stay quiet, and quiescence
    between commands is what the record is for.
  - **The viewport is derived from the widths too, so a correction re-aims it.** Every scroll target is computed from
    the same column widths a correction changes, so a session that keeps the destination it was given is travelling
    somewhere computed for a strip that no longer exists — leaving phantom desktop tacked onto the side of the strip,
    exactly the width the app refused. Correcting one animated quantity and not the other over one geometry is the
    whole defect; a correction re-aims the scroll through the same call a resize makes when it *starts*.
  - **A correction under a raised cover springs rather than jumps.** Every layer frame is re-derived from the strip's
    geometry each tick, so a column that changes width between two frames pops. The change goes under the same width
    animator `cycle-width` uses, retargeted in place — which is also *required* during a resize, since the layers must
    converge on the width the reals were teleported to. Mid-*capture*, the correction is recorded and nothing is
    placed: the raise's own teleport is moments away and reads it.
  - **Heights are the same fact on the other axis, and the bound is *signed*.** `Column` runs a **water-fill**: an
    auto window whose bound rules its share out takes the bound and the others re-divide, to a fixpoint (≤ n passes,
    since the bounded set only grows). It pins in **both** directions — a floor above its share takes the floor and
    *shrinks* what the rest divide; a ceiling below its share takes the ceiling and *grows* it. Direction is the one
    thing a bare number loses: offered 400, a window that answered 200 must be held at 200 while one that answered 500
    must be given 500. A bound never overrides a pinned preset: a pin is the user's instruction, a bound is the app's
    constraint. Two residues, both deliberate — a column whose every window has a ceiling **under**-fills its box,
    since there is nowhere to give the height back (unlike the strip, which just packs the next column against a
    narrow one), and a height learned mid-transition rides the **third** animated quantity rather than the second,
    since re-running the water-fill produces two different divisions of one box with no number to interpolate.
- **Layout engine:** columns ↔ windows, preset cycling, scroll/center, per-monitor strips, dynamic workspaces, and
  **park-slot assignment** — deterministic, unique, staggered ~1 × 40 pt nubs in the working area's **bottom-right**
  corner, the window's own title bar left on screen as a grab handle and the nub's *height* carrying the stagger
  (`PRINCIPLES.md` §4a). A park slot is just target geometry, so placement is core-owned: one geometry authority,
  replay-testable, and unique frames keep identity rebinding unambiguous (`PRINCIPLES.md` §7).
  - **`Layout` gained four editing primitives, not four verbs** — `moveColumn`, `moveWindowWithinColumn`,
    `move(window:toColumn:at:)`, `extract(window:toNewColumnAt:)`. Twelve command cases compose out of them, and the
    decision tree — *alone in its column ⇒ the column moves or it consumes; with stackmates ⇒ it pops out* — stays in
    the reducer beside `handleFocus`, which already makes exactly that distinction. **Each primitive is atomic over
    the invariants**, and that is what chose the set rather than a smaller one: "non-empty columns" and "no duplicate
    windows" cannot be maintained by a reducer composing "remove from column" then "insert column", because the state
    between the two calls is invalid.
  - **New column ids are minted only inside `Layout`.** A re-issued `ColumnId` is not a cosmetic collision: it is the
    key `Motion.columnWidths` and the cover's animation identity hang on.
  - **The viewport clamps to the strip's extent, in two places because there are two ways in.**
    `Strip.offsetToReveal` clamps its *answer* rather than trusting its input — the stranding rides specifically the
    "already fully visible, don't move" branch, which hands the offset straight back, so a range check on the result
    is what makes the bound an invariant of the answer instead of a property of the caller. And `placeAtRest`
    re-clamps the resting offset, which is the half a reveal cannot reach: a strip can shrink with nothing asking to
    reveal anything (close a column left of the viewport, minimize one, narrow the presets). It deliberately stops at
    the **centering** path: `center-focused-column` is an instruction to put a column in the middle, and at the
    strip's ends honouring it *means* showing space past the last column, so clamping there would silently convert an
    explicit request into flush-left.
  - **A re-place asks where the truth plane's authority is, not where the viewport looks.** `MotionPhase` is that
    question made into a value — `TransitionSession.Phase` extended with the case a session cannot represent, its
    own absence — and `reassertTruthPlane` switches over it exhaustively. **Idle** it is `placeAtRest` at
    `viewportOffset.current`; **covered** it is `teleportBehindCover`, because the reals went to the scroll's *end*
    when the cover went up and `.current` has stopped describing them — it is the number feeding the layers, so
    placing at it drags the desktop to a position the animation invented, which the cross-fade then reveals as a
    jump backwards; **capturing** it is nothing at all, no real window having moved yet, and the raise's own
    teleport reads whatever this would have written. The routing is in the function rather than at its call sites
    because the events that ask for a re-place arrive on their own schedule, and **the mouse-up is the proof**:
    every click on a window is one, landing tens of milliseconds inside the reveal that same click started.
    - **The phase is one value and not two booleans** because the three answers are otherwise an ordered guard
      chain whose order is load-bearing and unwritten — ask `isTransitioning` before `isCovered` and every covered
      re-place silently does nothing. `isTransitioning` and `isCovered` remain as its projections, for the gates
      that genuinely ask one yes/no question.
    - **The capturing answer is a deferral, so every way out of that phase owes a place**, and there are four:
      the raise teleports; `coverUnavailable` aborts and re-places; `holdTimeout` closes and re-places; and
      `abandonTransition` — a switch handed no before-geometry — closes, with `finishStructuralEdit` placing
      behind it. Only the last belongs to somebody else, which is why it is written down: a head that exits
      without placing is *silent*, leaving the strip claiming a scroll no window performed and nothing scheduled
      to correct it.
    - **`World.placedOnScreen` is the same fact for readers rather than writers**: which windows the last
      placement put on the glass. `isOnScreen` reads it, so `[focus] system-events` judges a report against where
      the windows *are* rather than where the viewport is headed — the two differ for the whole capture head of
      every reveal, and a refusal is an AX write that would yank focus back off a click that landed on a window
      still plainly on the glass. It is **recorded by the two writers, not derived**, because every way of aiming
      runs ahead of the windows it aims: `.current` is the spring's under a raised cover, and `snap` aims by
      writing *both* ends at the open, leaving a snapped capture head with no animator that still holds where the
      windows are.
      - **The record is the `setFrame`-vs-`park` decision, not the offset behind it**, because an offset means
        nothing without the layout it was measured against, and a capture head is precisely where those two come
        apart: it is the one phase that restructures the strip without re-placing anything. Close a column left
        of the viewport mid-head and the last-written offset, read against the strip as it now is, points past
        the end of it and reports an empty desktop — so the click on the window physically filling the display
        is refused. Keeping the decision keeps both inputs frozen together, and it costs the predicate its
        `metrics` read, its workspace test and its layout query: a pass parks everything off the focused strip,
        so membership already says all three.
      - What entitles anything to name it is being the reducer's only `setFrame`/`park`, so the two arms share
        the one that is: **`writeTruthPlane(at:)`** emits the diffed sets, takes the optimistic `World` write,
        and records the on-screen set, while `placeAtRest` and `teleportBehindCover` keep only what actually
        distinguishes them — the resting clamp and which offset is the truth on the one side, arming the landing
        wait on the other. Two copies of that loop is how the record starts drifting from the writes it claims
        to describe. The record covers *every* managed window, including those already standing correctly, where
        the effect stream is a diff and names only what moved.
  - **A new column opens immediately right of the focused one**, not at the far end of the strip. Appending made "the
    strip opens for a new window" untrue — an appended column displaces nothing, so the only motion was the viewport
    chasing the strip's new end. The anchor must be the window focused *before* the newcomer arrives, and it is
    `World.lastStripFocus` ("where was the user working") rather than live focus: an app focuses its brand-new window
    before emira has adopted it, so the observer resolves that element to no id and a `focusChanged(nil)` lands a
    moment *before* the creation. Anchoring on live focus passes a unit test and appends in reality every time.
    - **`stripAnchor` is that fallback as a shared concept**, because an arrival is not the only decision needing a
      *place on the strip* when focus rests on nothing: a refused system focus report needs somewhere to put focus
      back, and meets the identical race. It is gated to the **focused** strip in both directions, since
      `lastStripFocus` outlives its window being moved to another workspace and an anchor over there is not a place
      this workspace can act — restoring focus to one would switch the desktop, which is the thing the refusal
      exists to prevent, arriving through the guard meant to prevent it.
  - **Focus after a departure takes the neighbour** — a surviving stackmate in the same column, else whichever column
    slid into the departed one's place, right-then-left. "First window in layout order" silently re-framed the strip
    on column 1 on every close; under a snap that re-frame *was* the whole observable event, and animated it is a
    full-strip scroll home. **A snap is not a cheaper animation, it is a shorter one, and it hides precisely what the
    motion would draw the eye to.**
  - **Focus off the strip is an entry condition, not a dead end.** `World` deliberately records whatever the system
    says is focused — a dialog, furniture, a window an app raised itself — and activating an app surfaces whichever
    window is `AXMain` at that moment, which need not be the one we asked for. So a focus command with no column to
    start from re-enters the strip at the near end: `right` at the leftmost column, `left` at the rightmost. The
    strip's own edges still no-op; no-wrap is a different fact.
  - **`[focus] system-events` decides which focus changes emira did not cause it honours** — `respect` (all of them,
    macOS's own behaviour), `on-screen` (only onto a window already in view), `ignore` (only onto a window emira does
    not place). The key is named for what it gates rather than for the setting it is: a *system focus event* is a
    click on a window, a Dock click, a Cmd-Tab, an app raising itself — which is exactly `FocusOrigin.system`, so the
    file's vocabulary and the event's are one word.
    Apps move focus to themselves at moments nobody chose, and under `respect` the strip faithfully follows
    them across the desktop. The refusal is one `.focus` effect restoring the focus the core already believed in and
    **no state change at all**: no reveal, no workspace switch, no cover — the transition is precisely what the user
    is trying to stop seeing. Two things are admitted whatever the mode: our own echo (the reducer wrote that focus
    optimistically when it emitted the effect, so refusing it would make every focus command fight itself), and a
    `nil` report (it names no window, and refusing it breaks ⌘N — see the strip anchor above). **The predicate is
    "on screen", which is not "on the strip"**: a float is off the strip and plainly visible while a minimized window
    is off the strip and in the Dock, so `isOnScreen` tests minimized and `Cmd-H` first, then treats anything emira
    does not place as visible, then asks `World.placedOnScreen` of the rest.
    - **Having nothing to restore focus to is not consent.** With no anchor the refusal is *silent* rather than
      absent — a refusal is at most one `.focus`, and nothing in the reducer can *un*focus a window, so declining to
      act leaves macOS's own focus exactly where it was and cannot produce a keyless desktop. Reading the absent
      anchor as "no grounds to refuse" instead is reachable two ordinary ways, both ending with the desktop switching
      to a workspace nobody asked for: a `nil` report is handled *above* this guard, so it clears focus without the
      policy ever seeing it and the next report finds the anchor gone; and an **empty workspace** has no anchor by
      construction. Which is why the anchor is `stripAnchor`'s rather than `World.focusedWindow`'s — the question is
      where the user *would be*, and focus is only a proxy for it.
  - **Provenance is a field of `focusChanged`, not a second event.** The shell is the only place that can tell a
    Cmd-Tab from the echo of our own `Effect.focus` (`FocusIntent`), and it already computes exactly that verdict; the
    origin carries it the rest of the way. Re-deriving it in the core would duplicate a ticket ordinal and a grace
    timer the core has no clock for, and splitting the case in two would let a third focus source be added without
    anyone being made to think about the policy.
- **Workspaces: 36 strips, one focused, the rest parked in full** (`PRINCIPLES.md` §1). Nothing is persisted across
  restart, so a daemon restart adopts every window onto the focused workspace — accepted deliberately, and the most
  annoying consequence of the charter.
  - **One `ColumnId` space, not one per strip.** A per-strip watermark would make column #1 on workspace `1` and
    column #1 on workspace `3` the *same* id — and `Motion.columnWidths` is keyed by a bare one, so an in-flight
    resize on one workspace would re-aim a column on another. The allocator lives on `Workspaces` and is passed
    `inout` to the two mutators that mint, so the compiler asks for it at every call site.
  - **One park-ordinal run across the whole set.** With every window on every unfocused workspace parked, per-strip
    ordinals would give two windows the same nub — breaking both the ±2 pt first-sight identity join and the
    no-overlap invariant, silently, one of them permanently.
  - **`State.layout` is a settable computed projection** of the focused strip — single storage, not a second
    authority. Nearly every question the reducer asks *is* about one strip; only the handful that genuinely span
    workspaces (reconcile, `targetFrames`, placement emission, the teleport behind a cover, and a placement
    correction, which asks whichever strip holds the window) stop using it. `visibleWindowIds` still asks the
    **focused** strip alone, which is the whole model in one line: everything else parks by construction.
  - **A switch is `focused` moving plus a placement pass, and on the presentation plane it is a structural edit.**
    "Everything that is not the focused strip is parked" was already what `targetFrames` meant, and a park is a frame
    like any other — so the verbs needed no new `Effect` and nothing in `EmiraShell`. What they genuinely needed was
    *memory*: each strip's scroll offset and last-focused window, written on the way out and read on the way in.
    - **Arriving somewhere empty focuses nothing, and the switch writes that** rather than skipping the write.
      Leaving `World.focusedWindow` on the strip being *left* reads as the more truthful answer — emira asked AX for
      nothing, so macOS really does still have that window focused — but the field is not a mirror of the system,
      it is what every verb takes as its **subject**. Stranded, `close-window` asks an app to close a window on
      another workspace that the user cannot see, and a refused system focus report restores focus over there,
      switching the desktop back through the guard meant to hold it still. `nil` is a state the reducer already
      supports everywhere — the verbs decline to act and `handleFocus` treats it as an entry condition — which is
      what makes it safe to say.
  - **The vertical term is a *sign*, not a distance** (`Workspaces.verticalOffset`). Every unfocused workspace sits
    exactly one screen away, so `1 → z` animates the same one screen as `1 → 2`. Taken as a distance the address space
    would be a 36-screen ribbon, a jump across it would sweep thirty-four workspaces nobody asked to see, and the
    capture scope would be the whole desktop set. It also leaves a *third* workspace's offset unchanged by a switch
    that does not involve it, which is what keeps a spammed switch a two-strip motion rather than an accelerating
    ribbon. `H` is the **physical** working height: measured against the content area a neighbour would come to rest
    inside the outer-gap margin, which the cover paints.
  - **It lives in `Workspaces`, not `Layout`, and is presentation-plane only.** A single strip has no opinion about
    workspaces and gains nothing from acquiring one, so the container that already owns the address ordering offsets
    the strip's answer. `targetFrames` has no counterpart, because on the truth plane an off-workspace window is
    simply parked.
  - **The arithmetic is a two-row table and everything else falls out of it.** With the new address sorting after the
    old, a window on the outgoing strip goes `y → y − H` and one on the incoming strip `y + H → y`, so **both seed
    `(0, +H)`** and the two strips travel rigidly one screen apart, from a loop with nothing about workspaces written
    into it. `move-to-workspace` needed nothing added: the moved window's "after" is a screen away, so it flies toward
    its new workspace while the columns it left close ranks behind it. The **follow** verb reads differently for a
    reason that is geometry rather than choreography — the moved window is on the focused workspace both before *and*
    after, so its seed is purely horizontal: it glides into its new column while everything else travels a screen.
  - **Each unfocused strip resolves at its own stored scroll offset.** Applied the live animator, an outgoing strip
    would slide *sideways* as it left, in step with a scroll happening on the workspace arriving. Frozen at its own
    remembered offset it travels straight up or down, which is what reads as one desktop replacing another.
  - **`WorkspaceRef` has five cases** — a name, plus `next`/`previous` (one address, occupied or not) and
    `nextOccupied`/`previousOccupied` (the next address *holding* a window). Both pairs clamp at the ends rather than
    wrapping, and resolving to the workspace you are on is how "nowhere to go" is spelled, so the edge rule exists
    once. **Materialized-but-empty is not occupied** — a workspace you passed through once should not keep answering
    `next-non-empty` forever.
  - **The cross-strip move is one call**, because the decomposition (take it off there, put it on here) passes through
    a state with a window on *no* strip, where a placement pass landing in between leaves a real window wherever it
    happens to be. That is `Layout`'s four-primitives argument one level up, over the container's invariant instead of
    the strip's. The window's width intent travels with it — the size is one the user asked for out loud.
  - **A remembered focus is an invariant of the container, not a check at the switch.** `reconcile` clears one that is
    no longer on its own strip (the window closed, minimized, floated, or was moved elsewhere), because membership is
    the fact that function is already about. A switch focuses the remembered window, else the strip's first, else
    nothing.
  - **Cross-workspace `focusChanged` is the path only the product produces.** Cmd-Tab, a Dock click or an app raising
    its own window can name a window on a workspace nobody is looking at, and the reveal promise is about the
    *window*. It is the **same switch `focus-workspace` performs**, handed the same before-geometry — one call, not
    a second code path, and therefore the same vertical transition. Who initiated the motion is not the axis: emira
    animates that span on demand, so cutting across it for arriving by Cmd-Tab is the two-window-managers complaint
    that retired the rule on the horizontal axis, one axis over. Two orderings are
    load-bearing: focus is recorded **inside** the switch (setting it first would make the outgoing record read `nil`
    and wipe the memory of the workspace being left), and **no focus effect is emitted**, which makes the echo loop
    unrepresentable rather than merely unlikely.
  - **A switch mid-transition rides the open cover** rather than abandoning it, because the layers have somewhere to
    go — one screen up or down. And the outgoing workspace remembers where its strip **was**, not where an abandoned
    scroll was heading: remembering the target would jump it the remaining distance sideways on its way out. Nothing
    is lost, since coming back re-reveals the remembered focus, which finishes the interrupted scroll.
  - **The two `naturalFrames` reads are no longer taken at the same offset**, and that is the one structural change
    the shared edit path needed. For every edit on one strip they are the same number; for a switch they *must*
    differ, because the offset is a per-workspace quantity and switching restores the incoming strip's remembered
    scroll in between. That store-then-restore sitting **between the two reads** is exactly what makes the horizontal
    axis cancel and the seed purely vertical.
  - **The scope ordering had to span workspaces.** Ordered by the focused strip's window ids, the whole departing half
    would have been silently dropped after a switch. Ordered by the workspace set's it is identical whenever the scope
    is confined to one strip, which is every command but these. Across two strips z-order is arbitrary anyway — they
    are one screen apart and never overlap — which is also why a plain `focus-workspace` elevates nothing while the
    two move verbs elevate the window that moved.
- **Three verbs that own no geometry of their own.**
  - **`close-window` is an `Effect`, and deliberately unacked.** It presses the window's own `AXCloseButton`, which is
    the public equivalent of the user clicking the red dot and — the point — *not* the same as destroying the window
    behind the app's back: the app runs its own close path, so an unsaved document still gets its sheet. The reducer
    therefore changes **no state**. Removing the window optimistically, the way placement writes frames
    optimistically, would be asserting a fact only the app owns, and would be wrong every time an app declines. The
    strip closes ranks on the destroy notification, which is the path a user-clicked close already takes, so the
    animation came for free. Reading `AXCloseButton` is a window-level *attribute*, not the child walk
    `PRINCIPLES.md` §5 forbids.
  - **`float` is a tri-state override, stored explicitly.** Tri-state (absent = follow the role) rather than a flag,
    because `float off` has to *tile* a window macOS classed as a dialog — with a mere flag half the verb is
    unreachable and a mis-classified window is stuck floating forever. And stored **even when it agrees with the
    role**, because an AX subrole describes presentation rather than identity and changes under us (`PRINCIPLES.md`
    §6), so a user's answer must outrank a role that moves. The verb owns no geometry: floating is the departure path
    minus the refocus (the window is still there to look at), and tiling is the arrival path minus the focus effect
    (it already has focus).
  - **`cycle-height` needed no fourth animated quantity.** The budgeted cost was a new animator, since heights had
    never moved. There isn't one: a height change moves and resizes the windows of *one column* and nothing else,
    which is exactly the per-window **displacement** structural edits already animate — `Rect` deltas carry size as
    well as origin, so a window that only got shorter is a displacement whose origin term is zero.
    - **The selection is keyed by window and lives on `Workspaces`, not on a column.** A parallel array beside the
      column's window ids would have to survive four structural primitives plus reconcile, and desyncs silently.
      Keyed, it survives all of them for free, and holding it for the whole set rather than per strip means a
      workspace move carries it without `move` remembering to. It rides into geometry through `LayoutMetrics` for
      exactly the reason corrections do: it must reach *every* query or they disagree about how tall a window is.
    - **Auto is a rung of the ladder, not a state you can only leave.** The cycle runs auto → ⅓ → ½ → ⅔ → auto, so one
      verb reaches every selection *and* gets home; the alternative is a second verb whose only job is "un-pin".
- **`exec` is the one verb that is not about the desktop**, and it earns its place by what owning the keyboard
  costs. A bound chord is taken from *every* application on the machine, so a user who binds `alt-h` to emira can no
  longer bind `alt-space` to anything else — running a second hotkey daemon beside emira means two registries racing
  for the same modifier space and whichever started first wins, silently. A window manager that takes the keyboard has
  to be able to hand a chord back.
  - **It goes through the pump like every other verb, and that is the whole of its integration.** The reducer returns
    `(state, [.exec(line)])` — no state, no session, no ack — which is `close-window`'s shape exactly: a verb whose
    consequence belongs to someone else. Routing it around the pump instead was the tempting shape and it costs the
    property §6 states about hotkeys: *a press produces `Event.command`, full stop*. Intercepting one verb in
    `HotkeyManager` would make the keyboard a second code path rather than a second surface, and would put a
    verb-identity branch in front of a pump whose value is being total. Through the pump it is also in the event log,
    so a session that ends "and then I pressed alt-space" replays — and replays **safely**, because `MockExecutor`
    records effects rather than running them.
  - **A spawn opens no transition, because a process is not a window.** Whatever the child opens announces itself as
    an ordinary `AXWindowCreated` whenever it is ready — milliseconds or seconds later — and takes the arrival path,
    with window rules, the seeded frame and the follow-the-newcomer focus it already has. Coupling the two would mean
    holding a cover open for a process that may never make a window at all.
  - **The CLI spelling looks redundant and is the diagnostic.** `emira exec …` from a shell is a slower way to run
    something you could just run — except that it runs in the *daemon's* environment, which is the one thing a user
    debugging a dead keybind cannot otherwise see. A bundled daemon is launched by `SMAppService` and inherits
    launchd's `PATH`, not the login shell's, so `exec ghostty` fails for a Homebrew binary and `exec
    /opt/homebrew/bin/ghostty` does not. Running the same line through the CLI, in a terminal, puts the child's own
    stderr in front of the person who needs it.
  - **`/bin/sh`, never the login shell.** `$SHELL -lc` would source the user's profile and make the PATH problem
    disappear, at the price of a shell startup on every keypress and of emira's behaviour depending on a file it does
    not own — a second authority over what a binding means. The escape hatch needs no mechanism, because the config
    line is already a shell line: `exec /bin/zsh -lc 'ghostty'`.
- **Rules engine:** pure predicates over a window's metadata at **first sight** — `WindowRule` (four AND'd matchers:
  app id and title, each exact or regex) → `RuleOutcome` (workspace / float / width). Definitions come from config;
  evaluation is pure.
  - **All three actions are seeds into somewhere the user can already reach**, which is what keeps the
    "starting position" promise honest rather than merely stated. `workspace` is the move `move-to-workspace`
    performs; `float` writes the same tri-state `Command.float` toggles, so the verb still works on a window a rule
    floated; `width` is the override `grow`/`shrink` set and `cycle-width` clears, so the first press puts the column
    back on the ladder. Nothing here is a mode — each action is the first value of something ordinary, which is why
    none of them needed state of its own.
    - **`float` is read *before* the tiling guard, because it decides that guard's answer** — in both directions. It
      has to be tri-state for the same reason the verb is, and it already was, so the rule sets the stored answer and
      the existing predicate does the rest.
    - **A rule's `width` outranks the width a boot-adopted window arrived with.** They meet on exactly one window —
      one emira met already open, that a rule also names — and the explicit answer wins, because `wasAlreadyOpen`
      infers a width from whatever happened to be on screen while a rule is what the user asked for. One helper holds
      that precedence, so both arrival paths get it from the same place.
    - **One rule may not both float a window and place it on the strip**, since a floating window has no column and
      the second clause provably does nothing — refused at parse time, for the reason an unknown key is. The check is
      per rule and not on the merge: two rules that each make sense and combine into this are answered by the same
      silence a dialog with a `workspace` already gets.
  - **A rule fires once, at first sight, and is never consulted again** (`PRINCIPLES.md` §4a). That is what makes an
    assignment a *starting position* rather than a leash, and it is the only reading that doesn't create a second
    authority: a window's workspace is **derived** from the strip holding it, so a standing rule would be a fact
    competing with the container that already owns it. A window restored from the Dock is an arrival on the strip too
    and deliberately does *not* ask — restoring is a deliberate act on a window that already exists, and it lands
    where the user is.
  - **Boot is quiet; a live arrival takes you with it**, and `wasAlreadyOpen` already told the two apart. The launch
    scan is emira sorting a desktop nobody just asked it to sort, so it places and says nothing; a window opened *now*
    is one the user opened, and following it is what a Dock click on an app living elsewhere already does.
  - **Matching rules apply top to bottom, later overriding earlier, field by field.** Precedence is positional and not
    clever about it, so a broad rule can set a default that a narrower one below it refines, and the two never have to
    agree about anything else to coexist. Written as a merge from the start, which is what lets a new action be one
    field and two lines rather than a second pass at precedence.
  - **An assigned arrival is not an arrival on the visible strip at all** — the window never joins the strip in view,
    so there is no gap for columns to open around and nothing on screen that moves. It is the move
    `move-to-workspace` already performs, from a column the window holds for one statement. Focus is set *inside* the
    switch, never before it, for the reason the cross-workspace reveal already documents.
  - **The grammar grew two things, and the second is not incidental.** `[[window-rules]]` needs **arrays of tables**,
    which the subset had refused by name — fine, since the subset was always "what the config is written in, each
    omission saying so when met", and the config now needs a list. **Literal strings** came with it because a rule
    matches on *regular expressions*: in a `"…"` string every backslash doubles, and `"\d"` isn't an escape this
    grammar admits at all, so it is a syntax error rather than a character class. Patterns compile at parse time (a
    broken one is a line number, not a rule that quietly never fires) and are stored as their source text, since
    `Config` is an `Equatable`, `Codable` value and a compiled `Regex` is neither.
  - Built-in taxonomy defaults sit underneath all of this: only `AXStandardWindow` tiles;
    dialogs/sheets/panels/popovers float; native-fullscreen windows are excluded (they live on their own Space);
    **minimized and Cmd-H-hidden windows leave the strip** — animated out like a close, strip position remembered,
    re-inserted on return.
- **The `Engine` reducer:** the reconciliation state machine — absorbs external reality (user clicks, app-launched,
  display hotplug) into the World model, decides snap-vs-transition, drives the motion session.

### Imperative shell (`EmiraShell`)
- **Runtime** — the `@MainActor` pump: turn Events into `reduce`, hand Effects to the Executor. The one place the two
  planes meet.
  - **Effects arrive at the executor batched per reduced event**, because the batch boundary *is* the frame boundary —
    a tick's `setLayerFrame` blits must land in one `CATransaction`. Empty batches are never delivered.
  - **Feedback flows back through an `EventSink` value**, not a reference to the `Runtime`: a `Sendable` struct
    wrapping a `@MainActor` closure with a weak capture. Every event source — executor ack, AX observer, display link,
    socket — holds a sink, so nothing in the shell owns or outlives the pump, and the "cross a thread to get here,
    deliver on the main actor" AX boundary is expressed once, in one type.
  - **The frame clock is gated on `motion.isTransitioning`, not on the cover being up** — start it when the session
    opens, a few ms before the cover is raised, so the display link's spin-up overlaps the captures; the pre-cover
    ticks are inert in the reducer. `FrameClock` is a protocol so the pump stays framework-free and headless-testable.
  - **The executor splits by plane, joined by a router.** `CompositingExecutor` sends the cover lifecycle to a
    `CoverSurface` and everything else onward, because the planes share no machinery — Core Animation on our own
    layers, main-thread and instant, versus AX Mach IPC into other processes, off-thread and slow. A batch is split
    into **maximal contiguous same-plane runs**, never partitioned: "cover before teleport" is the reducer's policy to
    emit, and the executor's job is only to be faithful to the order.
    - **There are four planes, and `exec`'s is its own rather than a corner of the truth plane.** A spawn has no
      window, no per-app lane, no enhanced-UI toggle and no ack, so the only thing it would share with AX is the file
      it was routed in. `plane(of:)` is exhaustive on purpose — a new `Effect` must be *assigned* a home rather than
      falling into one — and the run-splitting means the system plane keeps its place in emission order for free.
- **AXClient / enumerator / writer / observers / watcher** — the truth plane, in its three directions: read
  (`AXEnumerator`), write (`AXExecutor`), watch (`AXObservationSource` + `WorldWatcher`). Per-app serial queues,
  messaging timeout, enhanced-UI toggle, the clamping dance, window-level-only enumeration (AX hygiene,
  `PRINCIPLES.md` §5). The same source watches `NSWorkspace` activation so externally-initiated focus becomes an Event
  (which reveals by scrolling), and holds a global mouse-up monitor (allowed under the AX grant) marking drag-end so a
  user-dragged tiled window re-tiles on release.
  - **A match must be unique or it is not a match.** Exactly one candidate within a 2 pt tolerance, checked in *both*
    directions (no window may see two entries; no entry may be claimed by two windows), and everything else is
    rejected *with a reason* the daemon logs. A nearest-position match is right for a prototype and wrong here,
    because nearest always answers and a wrong answer is forever.
  - **`axFailed` means the app said no, not "the window ended up somewhere else."** An AX set has two independent
    outcomes — whether the writes were accepted, and where the window actually is afterwards — and collapsing them
    loses the one that matters. A window that lands off-target reports `windowFrameChanged` *and* `axLanded`; only a
    refused or timed-out write is `axFailed`. The alternative would call a terminal quantizing to character cells a
    failure on every placement.
  - **A batch is grouped into one lane job per app**, not one per window: the reducer emits placements in layout
    order, which interleaves apps, and per-app grouping collapses N lane hops and N enhanced-UI toggles into one (each
    toggle makes Chromium/JVM apps rebuild their accessibility tree). **The enhanced-UI flag is read before it is
    written** and restored after — never *introduced* to an app that didn't have it, and never left off, which would
    strip VoiceOver of the mode it asked for.
  - **The observers' vocabulary is `WorldObservation`, not `Event`.** Two of its cases decide the type: *"a window
    appeared" is not a window we can name* (the notification carries an `AXUIElement` with no window number, so the
    response is re-scan that app), and *"a window moved" is not a frame* (AX never says where to). Both responses are
    policy, so `ObservationSource` stays a handful of framework calls and `WorldWatcher` holds the decisions.
  - **`AXObserver` registration is split across two element scopes** — window-created and focused-window-changed on
    the **application** element, destroyed/moved/resized/miniaturized on each **window** element — because that is how
    the API delivers them; the wrong scope is silent, not an error. **Registration is IPC and runs on the app's lane**,
    since a busy or still-starting app answers with `.cannotComplete` and on the main actor that costs up to one
    messaging timeout per notification. Delivery stays on the main run loop in `.commonModes`, so a tracking menu
    can't make the window manager go deaf.
  - **Two macOS races share one bounded retry** (three attempts, ~150 ms apart): a window the window list hasn't
    caught up with, and an app not yet ready to be observed — the same "asked too early" bug, where the alternative
    reading of either is "not ours" and must not become a busy loop. It revisits `Report.incompleteApps`, not every
    app the scan covered: at boot that is the whole desktop, seven round trips per window, re-confirming what already
    bound — and each attempt slower than the last on exactly the machines needing them.
  - **A reconciliation heartbeat is the standing check behind all of it** (`WorldWatcher.reconcile`, every 3 s).
    Everything else is edge-triggered — one notification, at one moment — so a discovery missed is a window unmanaged
    for the life of the daemon, silently: an app that wasn't `.regular` when `applications()` was asked is one
    `appLaunched` never fires for and `windowAppeared` is gated against, and an off-screen window AX failed to
    describe sets neither `unbound` nor `unclaimed`. The list is a window-server query rather than IPC into anyone's
    app, so being level-triggered costs ~2.5 ms and no AX until the two disagree. `maxReconcileRounds` caps attempts
    per window number, because an on-screen layer-0 entry AX will never describe is a real thing; the budget is
    dropped when a number stops being listed, because the window server reuses them. What it finds is announced
    `alreadyOpen` — emira did not watch it open. `Heartbeat` is its own seam beside `DelayScheduler`: a retry
    terminates and a heartbeat does not, and one drained by a test's "run everything pending" loop never would.
  - **Move notifications are coalesced to at most one read in flight per window**, because AX emits them at the
    refresh rate during a drag and each answer queues on the *same serial lane* our placement writes use.
  - **A focus report is not self-describing, so the watcher asks before passing it on.** `Event.focusChanged` has
    exactly one meaning in the reducer — focus moved and we did not move it, so scroll to reveal it — and macOS produces
    the identical notification for something that is not intent at all: an app whose key window closes picks a
    replacement and announces it. A report means "the user moved focus" if the window it **displaced** is still alive,
    and "macOS filled a hole" if it is not. That cannot come from the notification stream, because the difficulty is
    precisely that the notification saying so has not arrived yet: AppKit chooses a new key window *synchronously*
    while the closing one is ordered out and destroys its element later, so the focus change normally arrives
    **before** the destroy. So `ObservationSource` gained an `isAlive` probe — one attribute read (`role`, the
    cheapest with an answer) on that app's own serial lane. The other notification order costs nothing at all: once
    the departure has been handled the registry has already forgotten the window, which answers the question for free.
    A probe is a majority and not a proof — it can be answered before the element is invalidated — so what makes the
    filter's misses tolerable is that the reveal is a *transition*: the destroy a beat behind it retargets the session
    it finds open rather than arriving at a viewport already standing where it wanted to travel.
    - **Both failure directions were chosen.** A busy app can time out and answer "dead" for a live window, and the
      cost is one dropped reveal. Reading that same timeout as "the window is gone" would drop a real window off the
      strip, which is why this asks about *focus* and never synthesises a departure from what it learns — the destroy
      notification stays the sole authority on a window's death, exactly as a frame read already refuses to invent a
      frame for one.
    - **The loss is bounded at one report**, because a dropped report still updates what the next one is read against.
      A watcher that went deaf to focus after every close would be a worse bug than the one this fixes.
  - **A scan reports what *changed*, not what it saw.** A re-scan that announced an app's other four windows would
    steal the user's focus every time a fifth opened, since the reducer gives a new window focus.
  - **The enumerator runs a *second* join, on the same scan and against the same two lists.** `WindowIdentity.bind`
    asks which window-list entry an AX window is; `WindowIdentity.succeed` asks which arriving window is standing
    where a departed one stood. Both are pure, both take value types and return indices, and both refuse a match that
    is not unique in **both** directions — a mis-pair is permanent and invisible, which is the property that governs
    every identity decision here. This is what makes a native tab group one window on the strip
    (`PRINCIPLES.md` §7).
  - **`WindowRegistry.rebind` is the only thing in emira that re-points a binding**, and a record's window number is
    no longer "for life" because of it. That is a real amendment and it buys the whole feature: keeping the `WindowId`
    is what makes a tab switch *unobservable to the core*, so the column, its width override, its workspace and its
    float state survive one without a single `Event`. Three things move together or the seam leaks — the number map
    (the capture plane films by `CGWindowID`), the element map (a notification arrives carrying an element and nothing
    else), and the record's element (the write path sets frames through it, and a *background* tab accepts geometry
    writes and applies them to itself alone, so a stale element is placement landing on an invisible window).
  - **`AXMainWindowChanged`, registered on the app element.** `AXWindowCreated` fires once per tab and never again,
    and `AXFocusedWindowChanged` does not fire for a tab switch at all — measured, not assumed. This is the sole
    notice that the window standing for a group has changed, and it costs one dictionary lookup to dismiss when it
    names a window already managed.
  - **A record keeps the window's frame, refreshed on every scan and every frame read.** The succession needs a
    rectangle for a window AX has stopped describing, and the closed-tab case has nothing else left — no element, no
    window-list entry. A drag is the one thing that moves a window between scans. Corroboration for one join, never a
    second copy of `World`.
  - **Absence is only read from a complete answer.** An app that described *nothing* is the shape of a timeout, a
    missing grant and a process exiting alike; an app whose two lists disagree is the same race `unclaimed` already
    reports, and is exactly what a successor looks like a moment before it can be seen. Both skip the app entirely and
    let the retry ask again. Believing either costs a live column.
  - **A departure with no successor is corroborated against the window list.** The succession refuses to guess, but
    its *orphans* used to go straight to `windowDestroyed` on the strength of an app's silence — and a window snapshot
    is seven round trips under the messaging timeout, so one failed read drops a live window out of its app's answer
    and looks exactly like a backgrounded tab. The corroboration costs nothing: the window-list entries are already
    read for the first join, and a window still listed **on screen** is alive whatever AX says, since a background tab
    is ordered out and a closed window is not listed at all. Such a window is kept on the strip and marks the scan
    incomplete, so the existing retry asks again. Three properties: **only orphans are corroborated** (a succession
    has stronger evidence than a flag the window server may not have flipped yet, and second-guessing it would put the
    tab fix back at the mercy of the race it was written to survive); **the guard is one-directional by construction**,
    so the worst it can do is hold a column one retry interval too long; and it cannot separate a backgrounded tab from
    a **minimized** window, which it never has to, because AX keeps listing minimized windows so they are rebound and
    never reach this point.
  - **A destroy notification waits for one scan.** `AXUIElementDestroyed` proves an *element* died; ⌘W on a tab group
    destroys the selected tab while the group carries on under the next one, so the `WindowId` may still have
    somewhere to go. Retiring it synchronously is a race the succession loses: the scan that would rebind it is
    asynchronous and the registry has already let go by the time it answers. So the id enters a vanishing set and is
    retired by whichever comes first — the scan **rebinds** it onto a successor (the column survives and the core
    hears nothing), the scan **rules a successor out** (retired at once, including the app that answers with no
    windows at all, which is what closing an app's *last* window looks like), or a short grace deadline fires as the
    backstop for a scan that settles nothing. Two answers deliberately settle nothing: a scan that still **lists** the
    window read AX before the element died, and one that may have missed an arrival has not ruled a successor out — it
    has failed to look. Both wait for the next scan, which the existing retry chain delivers ahead of the deadline.
    **Only the id waits**: the window is not live from the notification onward, so no frame read, focus report,
    minimize or move about it reaches the core in the interval.
  - **Departures are announced before arrivals**, so the reducer never holds both a window leaving the strip and the
    one taking its place; and a succeeded id is re-watched *after* being un-watched, since watching is idempotent by
    `WindowId` and without the un-watch the new element would never be observed at all.
  - **Three rules keep the join from running twice** (`PRINCIPLES.md` §7): a known element goes straight to a rebind;
    an entry already bound to a live window is not a candidate for anything; and `WindowRegistry.adopt` returns `nil`
    rather than binding an element that already carries a different number.
  - **`Report.unclaimed` is the join's other direction, and it must be on-screen-only.** `unbound` names a window AX
    described that the list didn't; nothing named the reverse, so "the notification arrived before the window server
    would list it" and "this window's AX attributes were unreadable" both left no trace and triggered no retry. Both
    now feed the same bounded chain. The on-screen restriction is not a tweak: ordinary apps carry several off-screen
    layer-0 entries that are not windows and never will be — four `1800×39` strips at the origin for Ghostty, Safari
    *and* Finder — and counting them would mark every scan of those apps incomplete forever. The cost of that
    restriction is an off-screen window AX also failed to describe, which lands in no report at all; the heartbeat is
    what covers it.
  - **The two sides of the join are read together, per app** (`ScanAnswer`). The list read belongs on the app's lane,
    immediately after its AX reads — a window-server query, so it is safe off the main actor and safe concurrently
    across lanes. Read once for a whole fan-out instead, it is stale by the *slowest* app's latency for every app
    that answered early, and the join matches within ±2 pt: a window that moved is a window unmanaged, and the gap
    widens with the number of windows on the desktop rather than with anything about the window that goes missing.
    Decomposing this way costs no outcome: `bind` narrows by owner before comparing frames and a `CGWindowID` belongs
    to one process, so no window of one app can match, contest or displace a window of another.
  - **Scans coalesce per app, exactly as frame reads already do.** Four ⌘N presses otherwise produce four concurrent
    full re-scans of one app, each seven AX round trips per window, on the one serial lane placement writes share. It
    is the same argument coalescing makes for drags — a notification storm is a poll unless you coalesce it — and it
    is *upstream* of the identity join: less lane pressure is a scan that answers sooner.
  - **A failed window-level observer registration rolls back.** Discarding the result while marking the window watched
    optimistically makes a registration a busy app refused permanent *and* silent: no destroy notification, so `World`
    keeps the window and the strip carries an empty column for the session. Registration is idempotent, so re-offering
    an app's known windows on every scan costs nothing when the first attempt worked and is the only second chance
    when it didn't.
- **Capture** — ScreenCaptureKit stills; live streams *(later)*. Identity comes from `WindowRegistry`: bound once at
  first sight, keyed on the stable public `CGWindowID` thereafter.
  - **A capture batch is atomic** (stills + base together, acked together): per-window acks would let the core count
    down to a raise the base isn't ready for, and the base is what makes the cover opaque. The store is written
    *before* the acks go out, because the last ack re-enters the pump synchronously and returns as `raiseCover`.
  - **The capture plane holds a cover *session*, because "one base per cover" is not "one base per batch".** The base
    is the display captured excluding the batch's windows, so a growing batch must not take a second one — by then the
    first batch's windows have teleported to their end frames and would be baked into the desktop behind their own
    sliding layers. The first batch after a close clears the store and takes the base; the rest merge into it, keyed by
    generation so a retarget arriving before the raise doesn't ack the original windows with no pixels.
  - **Each layer starts at its capture's frame, not the core's idea of the window's frame.** They differ only when it
    matters, and that difference is fidelity.
  - **Stills are released on cross-fade completion, not at `endTransition`** — `CALayer.contents` holds them for the
    whole fade, and a command arriving inside the fade opens a new cover whose stills the old fade must not free.
- **Compositor** — the layered reconstruction overlays, synthesized shadows, raise/cross-fade.
  - **The cover is the working area, not the display.** Being *below* the menu bar is not the same as not colliding
    with it: our overlay is `.floating` (level 3) and the menu bar is `.mainMenu` (level 24), so the **real** menu bar
    always composites on top of the cover — over the base capture's own copy of it. The two coincide invisibly until
    they disagree, which any transition changing the frontmost app guarantees, and then the shot shows two app names
    superimposed. So the overlay window is **inset by the struts** and the chrome bands show the real, live menu bar
    and Dock. This is safe for the same reason the strut exists — no managed window is ever in that band, tiled or
    parked — and it is why the daemon reads the struts *once* and hands the same value to both the core and the
    overlay: the invariant holds only while the two agree. The desktop base is still the whole display, placed at the
    display's rect in local coordinates and clipped by the host layer, so the wallpaper stays where it was captured.
  - **`Reconstruction` is the only place `Config.windowAnimation` means anything, and it is one animation with two
    renderers.** The obvious shape — a window-animation protocol with two conformers — is wrong, because the two modes
    emit a **byte-identical `Effect` stream**: `setLayerFrame` says *where a window is*, never how to paint one, so
    the core's geometry does not depend on the setting and cannot. Everything that differs is downstream of a fact
    only the shell holds — how big the still it is holding actually is — so the whole feature is two frame assignments
    plus one pure function, and `Engine`, `Motion`, `Effect` and `CoverSurface` are untouched. `stretch` is one layer
    scaled to the core's rect; `crop` is three.
  - **One rule covers both directions of a crop, and it is a rule about the *anchor* alone**: the still goes at its
    own size, pinned to the rect's top-left, overflowing when the window has shrunk past it. Centering the grow would
    have needed `max(0, (rect − still)/2)` and two cases; top-left is where a window's own content is anchored, so the
    title bar and traffic lights stay where the real ones are about to be. The cases meet continuously at equality, so
    an overshooting spring or a mid-flight reversal crosses between them without the content jumping — and the axes
    need no cases at all, which is why this isn't a `contentsGravity` constant: a `consume` grows a window's width
    while halving its height, and a gravity is one value for both axes.
  - **Three layers, because a shadow and a clip cannot share one.** A `CALayer` with `masksToBounds` on cannot draw
    its own shadow, and a crop must clip or a shrinking window ends in a square edge where the cut still covers the
    rounded extent it sits in. So `root` casts the shadow, `clip` rounds and masks, and `still` draws at capture scale
    and overflows — the ordinary AppKit idiom, which removes every per-corner special case in exchange for two layers
    nobody sees.
  - **The corner radius is measured off the capture, not chosen.** `crop` paints a window's *silhouette* at a size no
    capture of it exists at, so it has to reproduce a shape the pixels would otherwise have carried for free. There is
    no public API for another window's corner radius and a constant goes stale with the next macOS — but the shape is
    already in the alpha, the same property the synthesized shadow has always rested on. **Measure the corner's
    *area*, not its edge:** scanning the leftmost column for the first opaque pixel looks exact and is not, because
    the arc is *tangent* to the edge there and leaves it quadratically, so a threshold answers about `r − √r` — 28%
    short at a radius of 12, and visibly tight. A quarter-disc leaves `r²(1 − π/4)` of its square uncovered and
    antialiasing *conserves* coverage, so summing the alpha deficit over a corner-sized block inverts to `r` within a
    quarter-pixel regardless of what the rasterizer did to the edges, and degrades honestly on a continuous (squircle)
    corner by yielding the circular radius enclosing the same area.
- **DisplayLinkDriver** — the frame clock; emits `tick(dt)` only while a transition is active (idle = no ticks).
- **Hotkeys** — global binds via Carbon `RegisterEventHotKey`. The deciding property is not latency, it is
  **consumption**: an `NSEvent` global monitor is already available to us under the AX grant, but it cannot swallow
  the keystroke, so `alt-h` would scroll the strip *and* type into the focused app — disqualifying rather than merely
  imperfect. Escalate to a `CGEventTap` only if we need combos the registry can't express. A press produces
  `Event.command` — the same value the CLI sends, so the keyboard adds a *surface*, never a code path.
  - **A hotkey manager is an event *source*, not an effect.** It belongs beside the socket server and the AX
    observers, so it is wired in the daemon and `Config.keys` is a value the reducer never reads. An
    `Effect.rebindKeys` would route the bindings through the reducer only to hand them straight back out, and would
    make the keyboard depend on a pump that isn't running yet at boot.
  - **There are no default bindings**, inverting this milestone's usual rule on purpose: a registered chord is taken
    from *every* application on the machine, so a default is emira confiscating a keystroke nobody asked it to. An
    unbound emira steals nothing, and the daemon reports "none bound" naming the file. The same fact is what puts
    `exec` in the vocabulary: what emira takes, it must be able to give back.
  - **Punctuation is named (`period`, `minus`), never typed**, forced by `-` being the chord separator; one rule beats
    an exception, and it has the consequence that no chord ever needs TOML quoting, because a name is bare-key-legal.
    Duplicates are detected on the `KeyChord`, not the key text (`cmd-alt-h` and `alt-cmd-h` are two TOML keys and one
    hotkey, and the grammar cannot see it).
  - **`bind` returning `true` is not a promise the chord will fire.** macOS handles its own reserved chords *ahead of*
    application hotkeys — `ctrl-up` is accepted by the registry and delivered to Mission Control anyway. Nothing in the
    charter can change that; the honest response is a detection (`CopySymbolicHotKeys()` is public) that warns, rather
    than a workaround that fights the OS.
  - **A press is logged**, because the keyboard is the only command surface with no other trace of itself: a socket
    command leaves a client, a shell history and an exit code, and an in-view `focus` correctly produces no motion, so
    a chord that worked and one that never registered are otherwise indistinguishable.
- **ConfigLoader** — TOML parse + watch + hot reload.
- **IPC SocketServer** — the CLI/daemon seam and the introspection endpoint (`dumpState`).
  - **One `Request`, one `Reply`, then close.** `emira` is a one-shot process, so there are no request ids and no
    session (a future event-stream subscriber adds an id field; the probe below is what makes that non-breaking).
  - **Versioning is a probe, not a decode.** `version` is a flat top-level `Int` on *both* messages and
    `Wire.probeVersion` reads it out of a line *before* decoding, so a peer from another build gets "the daemon speaks
    v1, this client speaks v2" instead of an undecodable envelope. **`Reply.state` carries an opaque JSON string**,
    not a decoded `State`: `emira debug` only prints it, so a CLI one release behind still dumps a newer daemon's
    state.
  - **Framing is JSON-lines**, safe because a non-pretty `JSONEncoder` never emits a raw newline; the reader half is a
    pure, byte-at-a-time-safe, length-bounded `LineBuffer` so `SocketServer` can be a thin loop.
  - **`dumpState` is a read, answered out of band** straight off `Runtime.state` — not a new `Effect`/`Event` pair.
    Routing it through the reducer would need an `Effect` carrying a live reply channel, and `Effect` is a `Codable`
    value by contract, so that one rule would bend for the one command that gains nothing from it. It is safe
    **because of** §1 invariant 4: the pump is never re-entrant, so the socket's main-actor hop always lands between
    pumps and can only observe a fully-reduced state.
  - **All socket I/O runs on one private serial queue**, hopping to the main actor only to compute a `Reply` — a window
    manager's main thread must never block on a client, and this way the worst a wedged peer can occupy is the IPC
    queue.
  - **The socket path is checked, never trusted.** It lives at `$TMPDIR/emira.sock` (per-user and `0700` by
    construction on macOS, reboot-cleaned, short enough for `sun_path`), overridable via `EMIRA_SOCKET`. Bind only if
    nothing is there, or if it is *a socket we own with nobody answering* (a crash leftover → unlink); a regular file,
    another user's socket, or a live daemon is refused **without deleting anything** — a second daemon must exit
    rather than steal the path.
- **MenuBar StatusItem** — an accessory (`LSUIElement`, no Dock icon) menu-bar item showing the focused workspace's
  address plus three menu items, **open at login**, **open config file** and **quit**. This is the whole of the running
  GUI, and it carries no `reload-config` item, because reload is automatic and a button would advertise a step nobody
  has to take. **Settings…** joins it when the window does (§9's M6.5) — a menu item, not a second chrome.
  - **Opening the file needs no editor setting, and there is no `$EDITOR` to read** — a daemon launched by launchd
    doesn't have one. macOS types `.toml` as `public.toml`, which conforms to plain text, so LaunchServices always
    answers: whatever the user opens TOML with, and TextEdit when they have never said. A `false` from
    `NSWorkspace.open` means nothing claimed it, and Finder is the fallback — the file gets selected, `Open With` is a
    right-click away. **The file is created first if it isn't there**, because emira runs perfectly well without one:
    the absent file is every setting at its default, and it is exactly the machine where someone wants to start
    editing. What is written into it is a comment pointing at `emira config explain`, never `ConfigSchema.document` —
    a file that writes a default down pins it — and it parses to the `Config()` the missing file already meant, so the
    watcher sees the new file and reloads nothing.
  - **`!` exists because a hot reload's failure mode is silence.** A broken file changes nothing, deliberately — the
    desktop stays exactly as it was — which means a typo and a correct edit that happens to be a no-op are
    indistinguishable from the outside. In a terminal the diagnostic was on stderr; a bundled app has no stderr anyone
    reads, so the indicator takes the title and the menu carries the text. The same argument produces the **one
    alert** on the two remaining fatal paths — no displays, a control socket that won't bind: an `.app` that exits
    silently is indistinguishable from a broken download. A missing grant *was* a third such path, and is now a window
    that waits instead of a message that gives up.
  - **A file broken *at launch* is a different failure, and emira manages nothing until it parses.** "Change nothing"
    works as a reload rule because there is something to change nothing *from* — the settings that were running before
    the file broke. At boot there are none, and "keep what you had" degrades into adopting the whole desktop under
    defaults nobody wrote: every window snapped onto a gapless full-width strip, none of the user's own keys bound to
    undo it, and no way to tell that apart from emira working as intended. So the daemon goes as far as it can and
    stops: it prompts for **both** grants — a file it cannot read is a file whose intent it does not have, and a grant
    is the one thing a later reload cannot go back and collect — raises the `!` item, and leaves the truth plane
    unstarted, the keyboard unbound and the desktop exactly as it found it. The first save that parses starts all
    three, which is the ordinary boot arriving late; a save that is still broken keeps it waiting and says so. **A
    missing file is not this case**: it parses to `Config()`, which is a config, and emira manages under it. The menu
    says which of the two the user is in, since the sentence that follows the diagnostic is the whole difference —
    running on the last settings that loaded, or waiting to start.
  - **On the launch that goes through the grant flow the item does not appear, and it is routed around rather than
    fixed.** Everything the item can be asked says it is fine — `isVisible` true, a button, a title, and even a child
    under `AXExtrasMenuBar` — while nothing is on screen; it is there on every launch afterwards, which is what
    onboarding's closing restart guarantees. Ruled out by measurement, so that nobody re-runs the search: a modal
    session before `NSApplication.run()`, an `execv`, a spawned successor, an item created before the run loop starts, a
    bare binary versus a bundled `LSUIElement` app, and a LaunchServices launch versus a shell one. The lesson worth
    keeping is about the instrument: `AXExtrasMenuBar` answers "this app has an extras menu bar with something in it",
    which is not "the user can see it", and two probes were built on that misreading before a real launch disproved it.
  - **It is a *display* seam, so `Runtime` grew an `onStateChanged` observer rather than an `Effect`.** Nothing about
    the status item changes state, so it must not be in the effect vocabulary — the same judgement `dumpState` got. It
    fires **once per drain**, not once per event: a single command cascades through capture → raise → teleport →
    landings, and an observer that saw each step would see states the user never does. Firing after the drain means an
    observer only ever sees a settled state, which is invariant 4 paying out a second time. It fires unconditionally
    rather than on a change, because `State` is large and comparing all of it at 120 Hz to save the observer a
    comparison is the wrong trade; **the observer diffs its own projection**, which is the file watcher's rule again —
    report a change in the *value*, not in the thing carrying it.
- **Teardown** — the exit path. Silence every event source, place the whole desktop into the **quit cascade**
  (`PRINCIPLES.md` §4a), wait for the AX sets to land under a 1.5 s bound, then exit. One path, reached three ways
  (Ctrl-C, `kill`, the menu item), and one-shot — a second Ctrl-C must not cascade a cascade.
  - **It is a layout, so it is in the core**, and that decided most of the rest: a park slot is target geometry, and
    the same applies to a pile. `State.cascadeEffects()` emits nothing but `setFrame`/`raise`/`focus`, which is to say
    it is an *ordinary placement* the existing executor runs and the existing acks answer. **No new `Effect`, no new
    `Event`, no `Command`** — a quit is not a verb the user types, and adding one would put a second door on a
    lifecycle that already has three, all reaching one function.
  - **No cover**, and that is instant-and-correct rather than a shortcut: the cascade is the last thing that happens,
    there is nothing left running to animate it, and a capture round trip before an exit would only delay the exit.
  - **The stagger cannot be honoured unconditionally** — a deep enough stack drives the last windows through zero size
    — so the step **compresses** uniformly to keep a floor, rather than clipping the list, wrapping it, or letting a
    window collapse. Every input is total, including a screen with no room for a cascade at all.
  - **The order is the daemon's, and it needed one thing from `WorldWatcher`: our own writes are observations.** A
    live watcher answers each move notification by re-placing the window on the strip being dismantled, and the
    cascade and the layout fight until the deadline. So every event source is silenced first — a latch on delivery,
    not an unregistration of live `AXObserver`s, because tearing those down at exit buys nothing the process exiting
    doesn't and its failure mode is a crash on the way out.
- **Permissions** — Accessibility + Screen Recording TCC checks and the window that asks for them. **Both grants are
  required to *start*; only Accessibility is required to keep *running*.** Screen Recording being non-fatal is correct
  as a response to macOS revoking the grant under a live daemon, and it must survive — killing the window manager
  there would strand every parked window at its 1 px nub with nothing to put them back. As a *first launch* it is a
  quiet failure: the user installed a scrollable-tiling window manager, received a permanently snappier AeroSpace, and
  the explanation went to a stderr a bundled app has nowhere to print. **Asking for the cover is what makes the grant
  required** (`transition = "off"` waives it — demanding a screen-recording permission to power a feature the
  user disabled is both obnoxious and a privacy smell), so the waived grant is not a row in the window rather than a
  row marked optional, and "satisfied" stays "all of them". `snap` is on the asking side of that line with `smooth`:
  it animates nothing, but a cover it cannot make of pixels is not a cover.
  - **One window, and every grant in it, because the alternative is a queue of prompts.** A grant apiece meant an alert
    apiece, each naming one pane and each ending in "then launch emira again" — and the count is the tell: two grants
    that must both be in place before anything works is *one* piece of setup, so it gets one surface. The rows carry
    the state (✅/❌ per grant, live), the blurb carries the reason, and each row carries the button that opens its own
    pane, so nothing has to be read in order.
  - **It opens in the top-right corner, inset 80 pt, and that is a *structural* answer to a placement problem.** macOS
    puts its own grant prompt in the middle of the screen, and that prompt must stay clickable — it deep-links to the
    pane with emira already listed, and it is the only dialog here that never dismisses itself. Clearing a centred
    prompt on the y axis means knowing its height, which nothing tells us; a corner is *beside* it instead, and no
    prompt height can reach the right-hand column. It is also where emira lives, a few points under the menu bar item
    the window hands the user over to — so it opens on `NSScreen.screens.first`, the display the strip is laid out on,
    for the same reason the compositor does and not `NSScreen.main`. `.floating` completes it: watching the row turn ✅
    from the pane you are standing in is the whole point of a live table.
  - **A grant is polled, not waited on, because macOS offers no notification for one.** The window re-reads every
    300 ms — fast enough that flipping the switch and glancing back reads as instant, which is the whole of what the
    live table buys: the user learns their click landed without leaving the pane, and finds out immediately rather than
    by relaunching emira to see whether it worked.
  - **The two grants are not equally *readable*, and that asymmetry costs a subprocess.** `AXIsProcessTrusted` answers
    freshly every call, so Accessibility lands in a running process. `CGPreflightScreenCaptureAccess` does not: the
    answer is cached for the life of the process, which is why macOS offers "Quit & Reopen" instead of picking the grant
    up — and a relaunch working *at all* is the evidence that a new process reads the truth. So onboarding relaunches
    something small: the daemon's own executable with `--probe-capture`, which preflights, exits with the answer and
    touches nothing else. Same binary, same signature, same bundle identity — which is what TCC records a grant
    against. One probe in flight at a time, ~200 ms each, so the row lands within about half a second of the switch.
    Two consequences fall out: `GrantRow.refreshed()` is **monotonic**, since an in-process read would revert the
    probe's answer on the very next tick; and an unexpected argument to `emira-daemon` now *fails*, because the
    fall-through is a window manager that adopts the whole desktop, which is a lot to get from a typo.
  - **Onboarding ends in a restart, and that is the design rather than a shortfall.** A grant given to a *running*
    emira is only half a grant: this process cannot read the Screen Recording answer it was just handed (above), its
    capture client is stale in the same way, and — separately and still unexplained — its menu bar item never appears.
    Each was worked around in turn and every workaround was then removed, an in-place `execv` included: it fixed the
    two capture problems and did nothing for the indicator, which reports itself present while being nowhere on screen.
    So the window ends with the one thing that fixes all three and needs no mechanism at all — **quit emira, open it
    again** — carried by a centred `quit emira` button with the reason directly beneath it, at the size of the
    paragraphs above because it is the same kind of sentence. `Outcome.restart` covers both ways out, the button and
    the close box, because the daemon's move is the same: exit, and let the next launch have the grants from the start.
    - **That button is the only control emira ever asks anyone to press, and it is drawn to say so** — the wordmark's
      greens, a glow that breathes, a highlight that crosses its face and then rests (`PulseButton`). Instruction, not
      decoration: a window that says "quit, then open it again" over a plain grey button reads as an error. `NSButton`
      keeps the click, the target/action and the key equivalent; the drawing is entirely ours, because a layer-backed
      button draws its cell into the layer's contents where any sublayer of ours would cover it — hence a subview
      label for the title. Core Animation is driven by the render server, so both animations run inside the modal
      session (measured off the presentation layer), and `accessibilityDisplayShouldReduceMotion` turns them off.
  - **The wait is a modal session**, which is what keeps the daemon's boot straight-line. Everything below the
    permissions check assumes the grants are in, and a modal loop is the only way to wait *before*
    `NSApplication.run()` has started; a main-queue timer still fires inside one, which is what the poll needs. Two
    consequences to remember. The loop has exactly one exit — a `stopModal` delivered after the session ends is
    remembered and closes the *next* one. And **`runModal(for:)` centres a window it has to show itself**, discarding
    any frame set beforehand, so the window is ordered front *first*; unfixed, that is not a small misplacement but
    precisely the collision the placement exists to avoid, since `NSWindow.center()` is 75% of the free space and the
    system prompt is centred by the same rule.
  - **The heading is the README's animation, not a still of it**, which costs a decision: 101 frames held at
    the size it draws is ~35 MB for a decoration, and that is precisely what a `CAKeyframeAnimation` over
    `contents` would have needed. So `Wordmark` decodes **one frame at a time** (~1 ms each) and chains the
    next on the delay the asset declares — which it has to do anyway, the delays being 40 ms per stroke and
    2.5 s for the rest at the end. ImageIO composites animated WebP frames whole, so nothing has to
    interpret WebP's blend and dispose rules, and the alpha survives, so one asset carries both
    appearances (its green was chosen for 4.35:1 either way).
  - **The prompts are asked for one at a time, because two at once is one.** Firing the Accessibility and Screen
    Recording requests together put up the Accessibility sheet and dropped the other on the floor, so the second grant
    had no prompt behind it at all. The window asks for the first outstanding row only, and the next prompt goes up when
    the previous grant lands — which is also when the user is already standing in System Settings. It follows that the
    subprocess probe waits its turn too: a spawn every 300 ms for the whole of an Accessibility wait is a process per
    tick for a grant nobody has been asked for yet.
  - **Both grants are billed as required, and the waiver is deliberately unadvertised.** `transition = "off"`
    still removes the row and the requirement with it, but the window doesn't mention it: wanting the animations is the
    overwhelming case, and a paragraph about the setting spends the reader's attention arguing against the thing they
    installed. Anyone who does want it will find it in the config. Closing the window quits, because there is nothing
    to run — and deliberately not a "start anyway" button, since a waiver granted to one session leaves no trace while
    the config file is a record.

### Executables
- **`emira-daemon`** — the long-running accessory app that hosts the Runtime and all subsystems; bundled as
  `emira.app` (`make app`), launch-at-login via `SMAppService.mainApp`. **The app *is* the daemon** — one process,
  one bundle identity, no launchd job. Three reasons, and the middle one is load-bearing:
  - **There is no headless emira to separate out.** The daemon has been an accessory `NSApplication` since the overlay
    existed — it needs a window server connection and a running app for `CADisplayLink` — so whatever went under
    launchd would be this same GUI process, and splitting would buy two identities for one program.
  - **TCC records a grant against the code signature of what runs.** Accessibility is fatal-if-missing and Screen
    Recording gates the whole cover, so grant stability *is* product stability, and a stable `CFBundleIdentifier`
    inside a bundle is what makes "grant once" possible. Corollary already visible in the build: ad-hoc signing
    identifies the app by **cdhash**, which changes every build, so macOS re-asks on every rebuild until a Developer ID
    signature replaces it. That is a bigger reason to sign properly than distribution is.
  - **"Quit stops the daemon" is then free**, which is what was actually asked for. Under a `KeepAlive` agent it is the
    opposite of free: quitting means `launchctl bootout` or the job comes straight back.
  - The one thing given up is crash-respawn, and it is a real loss *here* specifically, since a respawn would rescue a
    desktop full of parked windows via the boot scan. It can be added later as a bundled `SMAppService.agent(…)`
    without changing any of the above.
- **`emira`** — the CLI; `emira focus left`, `emira move-window right`, `emira debug` (pretty-prints the state dump),
  and `emira config check | explain | get | set`, which is the one branch that talks to the *file* instead of the
  daemon — `set` writes through `ConfigDocument` and hot reload does the rest, so there is no command afterwards.
  **It ships inside the bundle and nothing symlinks it**, so there is exactly one copy of the wire protocol on the
  machine — the version probe exists because skew is possible, and this makes it not happen. Putting it on `$PATH` is a
  packaging concern, answered by a Homebrew cask's `binary` stanza pointing into the bundle.

### Config (**TOML**, matching AeroSpace)
`~/.config/emira/emira.toml` (override: `EMIRA_CONFIG`). The **parsed values** are a pure `Config` struct in
`EmiraCore`, because the reducer reads them; the **format** is `EmiraConfig` — the grammar, the schema and the path
(§4) — and a `String → Config` function is pure by construction. The shell owns only **reading and watching**.
It goes the other way too, and **not by serializing**: `ConfigDocument` holds the text beside its parse and changes
one value by splicing over the bytes that value occupies, so a file keeps its comments, its ordering and its blank
lines through an edit. Rendering back is a `String`; the write is still the caller's, which is what keeps the package
free of I/O and leaves the atomic save with the code that owns the path. §10's window is an editor of the file, so
this is the seam it edits through — and it refuses to write a file it could not read. `emira config` is the same
seam from a terminal, and the schema is what both of them read: the label, the sentence, the legal values and the
default are printed by `explain` and laid out by the window off the one table, so nothing describing a setting is
written down twice. A value typed as a *word* — `8`, `true`, `adopt`, `0.5 1` — goes through the same codec a line of
the file does, so a bound is checked in one place and refused in one sentence.
Covers: keybindings (`[keys]`, key → `Command`, including the
`exec` that hands a chord back to the system), gaps
(`column-gap`, `window-gap`, `outer-gap` + its four per-side overrides), `width-presets` and `height-presets`,
`center-focused-column` (the height ladder has an implicit extra rung, **auto**, which the cycle wraps through),
`focus.system-events` (`"respect"` / `"on-screen"` / `"ignore"` — which focus changes emira did not cause it honours),
`animation.transition` (`"off"` / `"snap"` / `"smooth"` — the one key **both** planes read: the reducer for whether
to cover and whether to animate, the shell for how long the finished cover takes to leave), and animation params (spring stiffness/damping,
durations, and the two word-valued keys that reach the *shell* alone rather than the reducer — `animation.window`,
`"stretch"` or `"crop"`, and `animation.cover`, `"exact"` or `"immediate"`; one says what to paint where a still no
longer fits the rect, the other what to paint before it has arrived, and the core's emitted geometry is identical
under both settings of both). Struts are
deliberately *not* a
key — they are read off `NSScreen.visibleFrame`; a user who wants a margin wants `outer-gap`, which is additive with
them and measured inside them. Hot-reload emits `Event.configChanged(Config)` — the reducer re-lays-out in place.

**Per-side overrides are spelled flat (`outer-gap-left`), not dotted.** `outer-gap.left` would in fact parse — the
grammar flattens a document to dotted paths in one dictionary, so the two are simply distinct keys — and it is still
the wrong spelling, because it makes one key both a scalar and a table, which real TOML forbids. Every config file
using it would break the day the hand-rolled grammar is replaced, so the dotted form is *refused* as an unknown key
rather than silently ignored.

**The format is TOML's spelling over a hand-rolled subset.** The value of TOML is familiarity (editors highlight it,
AeroSpace users write it) and a subset keeps all of that; what a conforming implementation would add is dates,
multi-line strings, inline tables and dotted-key merging, none of which this config says. So `TOML.swift` reads
comments, `[table]` headers, `key = value` over four scalar kinds and single-line arrays, and **names everything it
doesn't implement** rather than misreading it — the same judgement as declining `swift-argument-parser`, for the same
reason: the surface is small, it lives where it can be tested exhaustively, and the package still has no dependencies
to vendor into a bundle.

**Unknown keys are refused, and the schema keeps no second list of valid names.** The reader *takes* each key the
schema knows and then reports whatever is left, so "which keys are valid" is the reading code itself and cannot drift.
A declared-but-empty `[layuot]` is caught too — leftover *keys* alone would miss it. Silence is the failure mode that
matters here: a window manager that ignores `colum-gap` is one the user believes is broken.

**The schema is a table, not a procedure.** `ConfigSchema.settings` is one `Setting` per key, each carrying its
spelling, its sentence, what a legal value is, and a codec that moves the value between the file and a `Config` field.
Reading is a loop over it; the example document is a render of it; `emira config` and the settings window are the two
consumers still to come. Presentation metadata — section, order, advanced-or-not — sits on the entry because it
describes the *setting*, and the alternative is a second list that drifts; nothing in the package imports a framework.

Three sections stay hand-written and are named as such in the reader: **`outer-gap`** (one logical value with five
spellings), **`[keys]`** (an open table whose names the user invents) and **`[[window-rules]]`** (repeating, ordered,
cross-validated). They are exactly the three that get bespoke editors in the settings window, so forcing them into the
table would buy a tidier list and a worse GUI. `struts` is not a key at all, and a test says so by name.

Two properties are pinned rather than hoped for: the generated `emira.example.toml` matches a golden file (so the
document cannot drift from the reader, and cannot change without someone reading the diff), and every stored property
of `Config` is either covered by an entry, claimed by one of the three named sections, or on an explicit not-a-key
list — so a new field cannot be added without a config story.

**Three rules about a file that isn't what we hoped, and each is a decision:** a **missing** file is `Config()`, not an
error (emira must run before it is configured); a **broken** file changes *nothing* and reports `path:line: message`
(falling back to defaults would rearrange a whole desktop as the side effect of a typo, at the moment the user is
least able to tell why); and a **saved** file reloads *once*, however many filesystem events the editor produced.

**Hot reload watches the file *and* its directory, and the parsed value is the filter.** An atomic save (temp file +
`rename(2)`) is a *directory* event that kills any file-level watch along with the inode it held; an in-place rewrite
(a shell redirect, `vim` with `backupcopy=yes`) is a *file* event the directory never sees — watch one and not the
other and hot reload works for some ways of editing a file and silently not for others. And because a directory watch
wakes on *any* activity in that directory, what is reported is a change in the **parsed `Config`**, not a change to
the file: the file changing is a guess, the config changing is the fact.

**The daemon owns the two values a file may not decide.** `struts` come from `NSScreen.visibleFrame` and the same
number must reach the core and the overlay; `transitionMode` is a *preference* answerable to the Screen Recording
*capability* — no grant sends it to `off` outright, both covered rungs being made of the same pixels, so `snap` is out
of reach exactly as `smooth` is. Both are re-applied on every reload (`applyEnvironment`), which also makes a reload
the first thing that notices macOS revoking the grant mid-session.

**Boot and reload apply the same config the same way.** The three values that reach the shell rather than the reducer
(`windowAnimation`, `coverMode`, `transitionMode`) are pushed onto their subsystems by one `applyShellConfig`, called
at launch and again from `ConfigLoader.onLoad`. Two call sites assigning three properties each is where "the reducer
and the shell read the same post-`applyEnvironment` value" goes quietly false.

---

## 7. Cross-cutting concerns

- **Concurrency.** `@MainActor` pins the Runtime, the Engine state, and all CA/overlay work — Swift 6 strict
  concurrency then *proves* nothing mutates it off-thread. The only off-thread work is AX (serial per-app GCD queues,
  results marshaled back to the main actor) and capture (its own queue). This is exactly `PRINCIPLES.md` §7.
- **No pixels in the core's vocabulary.** `Effect.capture(win)` is answered by `Event.captureReady(win)` — ids, never
  image payloads. The shell owns the image cache keyed by `WindowId`. This keeps `EmiraCore` Foundation-only and keeps
  replay logs small and serializable.
- **Coordinate spaces.** AX and SCK speak top-left-origin global coordinates; Cocoa speaks bottom-left. The Y-flip
  happens exactly once, and the one place is the **Cocoa** boundary — `Compositor/ScreenGeometry.swift`, whose only
  customers are the overlay and `NSScreen` enumeration. It is a `Double` plus an involution: the two spaces differ by
  a reflection about the primary screen's half-height. AX's global space **is** the core's space (top-left origin at
  the primary display's top-left), so `AXAccess` copies frames straight across with no arithmetic at all. There is
  nothing to get wrong there, which is the strongest form of "exactly once".
- **Smoothness needs its own instrument, and there is only one.** `Spring` is an analytic integrator, so it lands on
  the physically correct position for any `dt`: a six-frame lurching scroll and a 76-frame fluid one trace the *same*
  offset-vs-wall-clock curve, and no amount of `emira debug` polling tells them apart — worse, polling perturbs the
  subject, since `dumpState` is answered on the main actor and an observer competes with the compositor for the
  display link's thread. So **frames-per-transition** is reported permanently, on cover dismissal. It needs a second
  instrument beside it, because it starts at the *raise* and is structurally blind to the capture batch in front of
  it: every capture batch reports its own window count, misses and elapsed time, and the daemon stitches the head into
  the transition line (`41 frames in 336 ms (122 fps); 145 ms capture head → 481 ms`).
- **Settle tolerance is point-valued, and it lives in `EmiraCore`.** `EmiraMotion`'s `1e-3` default is right for a
  unit-agnostic scalar solver and wrong for the strip: a spring's tail decays exponentially, so on a 900-point scroll
  the last thousandth of a point costs about as long as the first 900 and the cover stays up long after the motion is
  visually over. `Motion` knows its animators carry points, so it supplies a sub-pixel position epsilon and a velocity
  bound — position is the criterion, and the velocity bound exists only so an underdamped spring can't be called
  settled while streaking through its target.
- **The spring's settle time is a calculation, not a taste.** For a critically-damped spring the remaining distance is
  `D(1 + ωt)e^(−ωt)`, so settle time is `u/ω` where `(1 + u)e^(−u) = ε/D`. Model and measurement agree to a few
  milliseconds in the product, which means the feel knob turns by arithmetic: pick the duration, solve for stiffness.
- **Error & timeout handling.** AX sets have a short messaging timeout; a failure surfaces as `Event.axFailed(win)`
  and the reducer reconciles (retry, or drop the window from layout). A window that vanishes mid-transition is a normal
  event, not an exception. The cover masking slow AX is a *feature*: the user sees smooth layers while a busy app
  teleports on its own schedule.
- **Deterministic replay (a first-class payoff, nearly free).** Because the core is a pure `(State, Event) → (State,
  [Effect])`, we can log every inbound Event and replay the log through a fresh Engine to reproduce any state exactly.
  This gives us: bug repro from a user's session log, regression fixtures (golden Effect streams), and offline
  debugging with zero macOS involved. Build the event log early — it costs almost nothing and pays forever. (At
  120 Hz, `tick` events dominate the log — record them run-length-compressed, or synthesize them on replay.)
- **Observability.** `emira debug` dumps the live `State` as JSON over the socket; structured logging via `os_log`
  behind a small `Logging` wrapper; an optional `EMIRA_TRACE` that appends the event log to disk.
- **Release: the git tag is the only version authority.** No file in the tree carries a version number, so there is
  nothing to bump out of step with a tag and no reading of "what version is this" that can disagree with another.
  `make app` asks `git describe --tags --match 'v[0-9]*'` and stamps the answer into the bundle's *copy* of
  `Info.plist`; the source file keeps `0.0.0`, which is what a build from a tarball honestly is. `CFBundleVersion` is
  the commit count — monotonic along main, which is the one property that key must have. The stamp is observable at
  the far end, because `Bundle.main` for an executable inside `Contents/MacOS` resolves to the bundle around it, so
  `emira --version` reads the daemon's own string with no codegen and no second source; run straight out of `.build`
  there is no bundle and it says `dev`.
  - **Two channels, and only one of them is a release.** A push to `main` force-moves the `tip` tag and updates one
    long-lived **prerelease**, whose asset name is stable (`emira-tip.zip`) so its download URL is a permalink. A
    human pushing a `v*` tag cuts the versioned release. Machines never decide a version; that is the whole point of
    the split, and it is what makes "the same semver published twice" unreachable rather than merely discouraged —
    `gh release create` refuses an existing release, and a guard refuses it earlier, before the build, with a better
    message. The same guard requires the tag's commit to be an ancestor of `main`.
  - **`tip` is updated in place rather than deleted and recreated.** Both reach the same end state, and creating a
    release notifies everyone watching releases — on a rolling channel that lands on every push to main, which turns
    a convenience into a reason to unwatch the repository. So the tag is force-moved, the release is edited, and the
    asset is clobbered.
  - **Prerelease, so `tip` is invisible to everything that asks for a version.** `/releases/latest` and a Homebrew
    cask both read the newest non-prerelease, so the rolling channel cannot become someone's install by accident. A
    semver prerelease tag (`v0.2.0-rc1`) is marked the same way, by the same rule.
  - **A tagged release publishes the cask, and `tip` deliberately cannot have one.** The tap holds two casks and
    only `emira` is ever bumped: `emira@tip` is `version :latest` with `sha256 :no_check` against the permalink, so
    no build changes a field in it. Giving it a real version and checksum is the tempting repair and it is wrong —
    tip's asset is *clobbered in place*, so a pinned checksum is correct only until the next push to main, and
    anyone installing in the window between that upload and the tap commit gets a mismatch. `:no_check` makes the
    race unrepresentable rather than unlikely; the price is that `version :latest` upgrades only under `brew
    upgrade --greedy`, which is a caveat rather than a defect on a channel whose whole promise is "whatever just
    landed".
  - **`brew` does the edit and the verification; git does everything else.** `brew bump-cask-pr --write-only
    --commit` rewrites `version` and `sha256` and touches nothing else, and then `brew style` and `brew audit
    --online` gate the push — the audit fetches the published URL and checks the checksum against it, so a release
    whose asset upload silently failed is caught before the cask points at it. Both run because they catch
    **disjoint** things: audit, even `--strict`, passes a cask whose `desc` style fails. The wrapper actions
    (`Homebrew/actions/bump-packages` and the third-party ones) were rejected for solving a different problem —
    they use `livecheck` to *discover* a version and fork the tap to open a pull request, which is what
    contributing to a tap you do not own requires. Here the checksum is already in hand from the archive just
    built, and the tap is ours, so discovery, a fork and a pull request are all dead weight in the release path.
    `brew style --fix` is deliberately not what runs: a fix landing inside the commit is a tap edited without
    anyone reading it, so a style regression fails the step instead.
  - **The cask is downstream of the release, and the ordering says so.** The bump runs after `gh release create`,
    in the same job because that is where the archive's checksum is free — a separate job would re-download the
    asset to hash what it had just built. The consequence is accepted rather than worked around: a failed bump
    leaves a published release with a stale cask, which is repaired by re-running the job, never by re-tagging. A
    version is published once (§7), and the cask is not what makes that true.
  - **The tap is pushed to by a GitHub App, and the token is minted per run.** `github.token` is scoped to this
    repository and cannot reach the tap, so the push needs a second credential — and an app installed on the tap
    alone, holding `contents: write` and nothing else, is the tightest one on offer. What it hands the job is an
    *installation* token: an hour's life, revoked when the job ends, belonging to no person, so there is nothing
    to renew and nobody whose departure takes the release path with them. A fine-grained token grants the same
    access with none of that and expires on a date no one is watching. The minted token is also the whole gate on
    the bump — a skipped mint has no outputs — so a missing app skips the cask exactly as a missing certificate
    skips signing. The commit is authored as the app, which needs the app's bot account and its numeric id for
    the noreply address to resolve to that identity rather than to nobody.
  - **One environment holds every credential, and it gates on the ref rather than on a person.** `production`
    carries the six signing secrets and the app's client id and private key, and admits `main` and `v*` — the two
    channels restated where the secrets are, so a run from any other ref cannot read them. Deliberately no
    required reviewer: the same job builds `tip` on every push to main, so an approval rule would tax every merge
    in order to guard the one ref a human already had to tag on purpose.
  - **The archive is `ditto -c -k --keepParent`, not `zip`.** A bundle carries symlinks, extended attributes and a
    code signature, and plain `zip` mangles all three — a mangled signature is a bundle Gatekeeper rejects for a
    reason that looks nothing like the cause. It is also the format `notarytool` accepts.
  - **`make zip` deliberately does not depend on `make app`.** Notarization runs *between* them: build and sign,
    archive, submit, staple the ticket into the bundle, archive again. A prerequisite would re-sign the bundle on that
    second archive and discard the ticket. `make dist` is the ordinary path for anyone not notarizing.
  - **Signing is a `CODESIGN_IDENTITY` the workflow supplies when it has one**, defaulting to ad-hoc (`-`). A real
    identity brings `--options runtime` and `--timestamp` with it, because notarization requires both and ad-hoc can
    have neither. Until the secrets exist the published bundle is ad-hoc: it runs locally, and on a machine that
    *downloaded* it Gatekeeper refuses and every update re-asks for Accessibility and Screen Recording, since an
    ad-hoc signature is identified by a cdhash that changes with every build. That is a worse failure on the rolling
    channel than on a tagged one — tip updates on every push — and it is the concrete cost of open item 3.
  - **Builds are arm64, not universal.** The toolchain warns that x86_64 is deprecated at this deployment target, and
    the platform floor is a macOS that is the last to run on Intel at all. `macos-26` is Apple Silicon, so the native
    build is the shipped build and there is no second slice to keep honest.

---

## 8. Testing strategy

The architecture exists to make testing cheap. Weight the pyramid accordingly:

- **`EmiraMotionTests`** — feed synthetic `dt` sequences; assert springs converge, don't overshoot past tolerance, and
  that `retarget()` preserves velocity (no visual discontinuity on interrupt).
- **`EmiraCoreTests / LayoutTests`** — strip math, width/height cycling, viewport scroll & centering, gaps/struts,
  multi-monitor placement, park-slot assignment (uniqueness, reuse on unpark), rule evaluation. Pure, fast,
  exhaustive.
- **`EmiraCoreTests / EngineScenarioTests`** — the scenarios that motivated this whole design, written as scripts:

  ```
  moveWindow(A, right); tick×3; focus(right); moveWindow(B, right); tick×N
    → assert: A's animator retargeted from its in-flight position with velocity preserved,
              B animating, exactly one transition session open, correct final targets,
              AX setFrame effects emitted for both, endTransition only after both axLanded.
  ```

  These run with a **`MockExecutor`** that records Effects instead of touching macOS — the entire interrupt/retarget
  brain is verified with no AX, CA, or SCK in sight.
- **`ReplayTests`** — golden event logs → asserted final state / Effect stream; regression guard.
- **Shell** stays deliberately thin so it needs little unit testing; it's exercised by the milestone smoke tests (M2
  visual smoke, then real windows at M3+).

---

## 9. Roadmap — how it evolves from the early days

Each milestone is independently demonstrable. Everything through **M2** is pure Swift with no macOS surface; the brain
is fully trustworthy before a single real window moves.

| # | Milestone | What lands | State |
|---|-----------|-----------|-------|
| **M0** | Skeleton | `Package.swift`, five targets + two executables compiling; one green test | **done** |
| **M1** | The brain | `EmiraMotion`, geometry, layout engine, `Command`/`Event`/`Effect`, `Engine`; scenario + replay tests | **done** |
| **M2** | End-to-end pipe | daemon loop + IPC + CLI + DisplayLink + Overlay driving layers from the core | **done** |
| **M3** | Truth plane | AXClient/enumerator/writer/observers + WindowRegistry + WorldWatcher; instant, correct tiling of **real** windows; reveal on external focus; taxonomy defaults; drag-end re-tile | **done** — AeroSpace parity |
| **M4** | The signature scroll | Capture + Reconstruction + Transition; motion under cover; the cover that grows on a retarget; the animated resize | **done** |
| **M5** | Ergonomics → **lightweight-complete** | ConfigLoader + Hotkeys + Permissions onboarding + the structural commands (`move-window`, `consume-or-expel`), animated + the menu bar and the `.app` | **done — shippable here** |
| **M6** | Full layout model | Virtual workspaces, per-monitor strips, window rules, monitor hotplug | the workspace model and its verbs are in, snapped; per-monitor strips and rules are not |
| **M6.5** | Configuration surface | `EmiraConfig` as a target; a TOML document model that edits a file without reformatting it; the schema as data; `emira config`; the settings window (§10) | the target boundary, the document model, the schema table and `emira config` are in; the window is not |
| **M7** | Deluxe *(optional)* | Continuous trackpad gestures, live-stream layers, focus-ring overlay, overview/zoom-out | later |

**M5 is the line.** A complete emira is M0–M5: it tiles, scrolls smoothly, is keyboard-driven, configurable, and
installs cleanly. M6 makes it a daily driver; M7 is where we chase the last 10% of the feel. If we stop at M5 we still
have shipped the thing.

---

## 10. Non-goals & explicit scope cuts

- **No SIP-off anything, ever.** No SkyLight, no code injection, no scripting additions, no private AX SPI (window identity via
  first-sight binding → public `CGWindowID`, not `_AXUIElementGetWindow`). This is the charter, not a phase.
- **No native Spaces / Mission Control integration.** Workspaces are emulated by off-screen parking (`PRINCIPLES.md` §3).
  We recommend users disable "Displays have separate Spaces," as AeroSpace does.
- **No setting the file cannot express, and no state the settings window owns.** A preferences window is *in* scope
  (§4's `EmiraConfig`, §9's M6.5) — a window manager only a developer can configure is one most people never get to
  try, and "the config file is the UI" cut off that audience on a premise about who the user is rather than about the
  architecture. What does not change is which artifact is authoritative: the window is an **editor of the file**. It
  writes `~/.config/emira/emira.toml` in place, preserving comments, ordering and grouping, and every control it
  offers corresponds to a key someone can also type. So: no preferences database, no key reachable only through a
  GUI, no settings that live in `UserDefaults`, and no import/export — the file *is* the export.
- **No layout persistence across restart.** Re-tile from live window enumeration on launch. (Loose workspace-rule
  reassignment via config is enough.)
- **No foreign-window resize smoothness beyond the app's own speed** — a hard floor (`PRINCIPLES.md` §6); we only cross-fade
  a scaled screenshot over a janky reflow.

---

## 11. Open items

Settle these as we build, not now.

1. **`EmiraMotion` as a separate target vs a folder** — started separate for the clean seam; still separate, still
   trivial to collapse.
2. **Rubber-banding.** The resting clamp is built; springing back past the strip's end during a gesture is not, and
   is an M7 question.
3. **Real signing** — Developer ID + hardened runtime + notarization, and with them a TCC grant that survives a
   rebuild. Ad-hoc is enough to run locally. The plumbing is in place and unexercised: `release.yml` imports a
   certificate, signs and notarizes when the six `MACOS_*`/`APPLE_*` secrets exist, and falls back to ad-hoc when they
   do not. Until they exist, a downloaded build is one Gatekeeper refuses — which makes this the item standing between
   emira and a release anyone else can install.
4. **Per-monitor strips.** The layout still resolves against the first monitor; `move-to-monitor` has no second strip
   to target, and monitor hotplug is untested.
5. **Both repositories are private, so no cask can install.** A cask's `url` is fetched by plain `curl` with no
   GitHub credentials, so a release asset in a private repository is a 404 to Homebrew and to everyone — `brew audit
   --online` reports exactly that today. The tap being private compounds it: `brew tap` cannot reach it either. The
   bump step and the app it authenticates as are both in place, so visibility is the whole of what stands between the
   cask and a green run — though, like signing, its first real run is still its first test. This is the other half of item 3 — signing decides whether a downloaded build *runs*, visibility decides
   whether it can be downloaded at all.
