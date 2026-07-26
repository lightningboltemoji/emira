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
    case moveToMonitor(MonitorRef)
    case cycleWidth                  // preset column widths
    case cycleHeight
    case consumeOrExpel(Direction)   // pull a window into / push out of the column
    case fullscreen(Toggle)
    case float(Toggle)
    case focusWorkspace(WorkspaceRef)
    case closeWindow
    case centerColumn
    case reloadConfig
    case dumpState                   // introspection for `emira debug`
    // …grows here, and only here.
}
```

Keeping this in the pure core (not the protocol layer) means the reducer, the tests, and the CLI all speak the same
type with no translation. `EmiraProtocol` only wraps it for the wire.

**Its surface spelling lives beside it, in `CommandSyntax.swift`, not in the CLI.** The config file's keybindings need
the identical `argv ↔ Command` mapping and `ConfigLoader` cannot depend on an executable, so `parse`, `words` and
`usage` are all core-side; `words` is an exhaustive `switch` the compiler checks, and a test pins the verb table
against it. This is also why there is **no `swift-argument-parser`**: the grammar is "verb, then at most one word", it
is already defined once here, and a subcommand type per verb would be more code in the one target that cannot be
unit-tested at all.

---

## 3. Data flow & the transition lifecycle

**Steady state has no overlay.** In the resting state the real windows simply sit at their AX positions; the
presentation plane does not exist. A cover/reconstruction is *ephemeral* — it goes up only for the duration of a
transition and comes down on cross-fade. The Runtime therefore has two modes, and the core drives the switch:

- **Idle.** Commands that produce no motion (e.g. a focus change that doesn't scroll) are executed as direct AX sets —
  snap, no cover. The core emits plain `setFrame` / `focus` effects. **Externally-initiated focus** (Cmd-Tab, Dock
  click, an app activating itself — observed via `NSWorkspace` + AX) takes this same path: snap the viewport to reveal
  the focused window. We made no motion, so we owe no animation.
- **Transition.** A command (or a gesture) that produces motion opens a *transition session*: the core emits
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

**A scope grows and never shrinks.** A retarget aims the scroll somewhere the session was not scoped for, and a
window sliding in with no layer shows the base — i.e. wallpaper — through the gap. So a redirect **widens** the
scope over the newly-swept interval, captures what that adds, and **grows the raised cover** (`Effect.extendCover`)
when the still lands. Nothing is ever *removed*: a window the old destination swept is mid-flight on the
presentation plane and mid-teleport on the truth plane, and dropping it would abandon both.

**The sweep is one query asked of a wider window.** A viewport of width `w` travelling from `a` to `b` covers
`[min, max + w]` — one viewport of width `w + |b − a|` — so `Layout.sweptWindowIds` needs no new geometry. Today's
one-column commands cannot tell the sweep apart from "visible at the start ∪ visible at the end", which is exactly
why it should be right before one can.

**A deadline that fires must degrade, not black out.** Every `capture` is answered exactly once within a bounded
deadline (250 ms), because the core raises the cover on the *last* `captureReady` and the hold-timeout only starts at
the raise — a dropped ack is a command that silently does nothing, with nothing to rescue it. A head batch that
resolves with **no base** leaves the reconstruction nothing to be opaque with, and an overlay's own fill is black, so
the capture plane answers `Event.coverUnavailable` and the core abandons the session **before any window has moved**
and snaps — the same degradation a machine with no Screen Recording grant gets.

Continuous gestures (§9, M7) are the same session opened by gesture-begin and closed by gesture-end + settle.

---

## 4. Module / target graph

Four library targets and two executables. Dependencies point strictly upward; nothing below imports a framework.

```
EmiraMotion     pure math — springs, easing curves, the scalar Animator.  (zero deps)
    ▲
EmiraCore       pure — geometry, ids, Command/Event/Effect, State, layout engine,
    │           rules, Config values, the Engine reducer.        (deps: EmiraMotion)
    ▲
EmiraProtocol   Codable request/reply envelope, wire framing, one-shot socket client.
    │                                                            (deps: EmiraCore)
    ▲
EmiraShell      imperative — Runtime, Executor, AX, Capture, Compositor, DisplayLink,
    │           Hotkeys, ConfigLoader, IPC server, MenuBar, Permissions.
    │           (deps: EmiraCore, EmiraProtocol; imports AppKit/QuartzCore/SCK/AX/Carbon)
    ▲
   ├── emira-daemon   executable — NSApplication accessory host that runs the Runtime.
   └── emira          executable — CLI; thin socket client.  (deps: EmiraProtocol + EmiraCore)
```

**Why `EmiraMotion` is its own target and not a folder.** A spring/easing solver is genuinely generic — scalar in,
scalar out, given `dt` — and has nothing to do with columns or AX. Splitting it out keeps the physics honest (it can't
reach into reconciler state) and independently testable (feed ticks, assert convergence and velocity carryover). It's
tiny; if two targets ever feels like one too many we collapse it into `EmiraCore/Animation/`, but the seam is worth
starting with.

**Why the CLI stays at the bottom of the graph.** The CLI must be framework-free and trivially fast to launch. It
parses `argv` into a `Command`, hands it to `SocketClient`, prints the reply. No AX, no CA, no AppKit — and no
`EmiraShell`. Note that the *transport* lives in `EmiraProtocol`, not in the executable: an executable can't be
imported, so anything with logic in it is untested by construction, and partial writes, a peer hanging up mid-reply
and version-mismatched answers are exactly the failures that need tests. It names `EmiraCore` as well as
`EmiraProtocol` because it builds the *one* vocabulary directly (§2, `Command.parse`); `EmiraProtocol` already pulls
`EmiraCore` in, so this adds nothing to launch cost, and the alternative — wrapping `Command` behind the envelope —
would be the translation layer §2 exists to avoid.

---

## 5. Directory layout

```
emira/
├── Package.swift
├── Makefile                         # build + test
├── CLAUDE.md                        # thin agent pointer at the docs below
├── .knowledge/
│   ├── README.md                    # how this project remembers things
│   ├── PRINCIPLES.md                # charter / why
│   ├── IMPLEMENTATION.md            # this file / how
│   └── changes/                     # one file per change, named by epoch second
├── Resources/
│   └── default-config.toml
├── Sources/
│   ├── EmiraMotion/
│   │   ├── Curve.swift              # easing functions + spring params
│   │   ├── Spring.swift             # critically-damped spring integrator (analytic, closed-form)
│   │   └── Animator.swift           # {current, velocity, target}; advance(dt); retarget(); nudge()
│   ├── EmiraCore/
│   │   ├── Geometry.swift           # own Rect/Point/Size on the virtual strip (not CG*)
│   │   ├── Ids.swift                # WindowId, ColumnId, MonitorId, LayerId
│   │   ├── Command.swift            # §2 — the one vocabulary
│   │   ├── CommandSyntax.swift      # its surface spelling: parse(argv)/words/usage (CLI + keybinds)
│   │   ├── KeyChord.swift           # the *other* surface spelling: `cmd-alt-h` ⇄ modifiers + a named
│   │   │                            # `Key`. Exhaustive in the core so a bad chord is a config
│   │   │                            # diagnostic with a line number, not a log line at bind time
│   │   ├── TOML.swift               # the minimal TOML *grammar* the config file is written in —
│   │   │                            # text → dotted keys + line numbers. Hand-rolled, no dependency
│   │   ├── ConfigSyntax.swift       # the config *schema*: which keys exist, what they mean, what a
│   │   │                            # legal value is. Stands to `Config.swift` as `CommandSyntax`
│   │   │                            # stands to `Command`
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
│   │   │   ├── Strip.swift          # infinite-axis math, viewport scroll, centering
│   │   │   ├── Column.swift         # vertical stack, heights
│   │   │   ├── Presets.swift        # cyclable width/height presets, inner gaps, struts
│   │   │   └── Park.swift           # deterministic unique corner nubs (park = target geometry)
│   │   ├── Config.swift             # parsed config *values* (pure data; loading is in Shell)
│   │   └── Engine.swift             # reduce(State, Event) -> (State, [Effect])
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
│   │   │   └── EnhancedUI.swift     # suspend kAXEnhancedUserInterface around a group of sets —
│   │   │                            # read first, restore after, once per app per batch
│   │   ├── Capture/
│   │   │   ├── CaptureService.swift # the capture *plane*: batch, deadline, ack-exactly-once, and
│   │   │   │                        # the WindowId-keyed store the cover reads
│   │   │   ├── SCKCapturer.swift    # the ScreenCaptureKit half: one still per window
│   │   │   │                        # (desktopIndependentWindow) + the display excluding them as
│   │   │   │                        # the base, fanned out concurrently
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
│   │   ├── Config/ConfigLoader.swift# the half that needs a disk: locate → read → watch → report.
│   │   │                            # The `FileWatcher` seam and `ConfigWatcher` — vnode sources on
│   │   │                            # the file *and* its directory
│   │   ├── Ipc/
│   │   │   ├── SocketServer.swift   # unix-domain socket, JSON-lines, dispatch to Runtime
│   │   │   └── RequestRouter.swift  # Request -> Reply: commands are writes, dumpState is a read
│   │   ├── WorldWatcher.swift       # the live world's *policy*: boot scan -> adopt -> watch;
│   │   │                            # re-scan an app when it makes a window; one bounded retry for
│   │   │                            # the two "asked too early" races; coalesced frame reads
│   │   ├── Scheduler.swift          # DelayScheduler — "try that again in a moment"
│   │   ├── Permissions.swift        # AX + Screen Recording TCC checks + onboarding
│   │   └── Logging.swift            # os_log wrapper
│   ├── emira-daemon/main.swift      # accessory NSApplication; wire up Runtime + subsystems
│   └── emira/main.swift             # argv -> Command -> Request -> socket; --dry-run, --help
└── Tests/
    ├── EmiraMotionTests/            # spring convergence, retarget velocity carryover
    ├── EmiraCoreTests/              # layout math, engine scenarios, golden replays, the grammar
    │                                # and the schema (every diagnostic, by line number)
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
  - A **structural edit** (`move-window`, `consume-or-expel`) animates the *third* quantity, and it is the one that
    is not like the other two: there is no number the new frames derive from, because an edit that inserts or removes
    a column makes before and after two different `Layout`s. So what goes under a spring is each window's
    **displacement** from where the layout now says it belongs, decaying to zero (`Motion.windowAnimators`,
    `RectAnimator`) — the destination stays derived, and only the *lag* is per-window. Every emitted layer frame is
    one derived rect plus these three, summed.
- **Geometry & the strip:** infinite-axis coordinates, column widths/heights, gaps, and **struts** (reserve the
  menu-bar/notch region so tiled windows never sit under it).
- **Layout engine:** columns ↔ windows, preset cycling, scroll/center, per-monitor strips, dynamic workspaces, and
  **park-slot assignment** — deterministic, unique, staggered ~1 × 40 pt nubs in the working area's corner
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
- **Rules engine:** pure predicates over window metadata → assign-to-workspace / float / initial-width. Definitions
  come from config; evaluation is pure. Built-in taxonomy defaults: only `AXStandardWindow` tiles;
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
- **AXClient / enumerator / writer / observers / watcher** — the truth plane, in its three directions: read
  (`AXEnumerator`), write (`AXExecutor`), watch (`AXObservationSource` + `WorldWatcher`). Per-app serial queues,
  messaging timeout, enhanced-UI toggle, the clamping dance, window-level-only enumeration (AX hygiene,
  `PRINCIPLES.md` §5). The same source watches `NSWorkspace` activation so externally-initiated focus becomes an Event
  (snap-reveal), and holds a global mouse-up monitor (allowed under the AX grant) marking drag-end so a user-dragged
  tiled window re-tiles on release.
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
    reading of either is "not ours" and must not become a busy loop.
  - **Move notifications are coalesced to at most one read in flight per window**, because AX emits them at the
    refresh rate during a drag and each answer queues on the *same serial lane* our placement writes use.
  - **A scan reports what *changed*, not what it saw.** A re-scan that announced an app's other four windows would
    steal the user's focus every time a fifth opened, since the reducer gives a new window focus.
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
    unbound emira steals nothing, and the daemon reports "none bound" naming the file.
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
- **MenuBar StatusItem** — an accessory (`LSUIElement`, no Dock icon) menu-bar item. This *is* the GUI — no
  preferences window.
- **Permissions** — Accessibility + Screen Recording TCC checks and a first-run onboarding flow.

### Executables
- **`emira-daemon`** — the long-running accessory app that hosts the Runtime and all subsystems.
- **`emira`** — the CLI; `emira focus left`, `emira move-window right`, `emira debug` (pretty-prints the state dump).

### Config (**TOML**, matching AeroSpace)
`~/.config/emira/emira.toml` (override: `EMIRA_CONFIG`). The **parsed values** are a pure `Config` struct in
`EmiraCore`, and so is the **parse** (`ConfigSyntax.swift` — a `String → Config` function is pure by construction);
the shell owns **locating, reading and watching**. Covers: keybindings (`[keys]`, key → `Command`), gaps
(`column-gap`, `window-gap`), `width-presets` and `height-presets`, `center-focused-column`, and animation params
(spring stiffness/damping, durations). Struts are deliberately *not* a key — they are read off `NSScreen.visibleFrame`.
Hot-reload emits `Event.configChanged(Config)` — the reducer re-lays-out in place.

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
number must reach the core and the overlay; `smooth-transitions` is a *preference* ANDed with the Screen Recording
*capability*. Both are re-applied on every reload, which also makes a reload the first thing that notices macOS
revoking the grant mid-session.

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
| **M3** | Truth plane | AXClient/enumerator/writer/observers + WindowRegistry + WorldWatcher; instant, correct tiling of **real** windows; snap-reveal on external focus; taxonomy defaults; drag-end re-tile | **done** — AeroSpace parity |
| **M4** | The signature scroll | Capture + Reconstruction + Transition; motion under cover; the cover that grows on a retarget; the animated resize | **done** |
| **M5** | Ergonomics → **lightweight-complete** | ConfigLoader + Hotkeys + Permissions onboarding + the structural commands (`move-window`, `consume-or-expel`), animated | MenuBar + bundle outstanding |
| **M6** | Full layout model | Virtual workspaces, per-monitor strips, window/workspace rules, monitor hotplug | next |
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
- **No preferences GUI.** The config file is the UI; the menu bar is the only chrome.
- **No layout persistence across restart.** Re-tile from live window enumeration on launch. (Loose workspace-rule
  reassignment via config is enough.)
- **No foreign-window resize smoothness beyond the app's own speed** — a hard floor (`PRINCIPLES.md` §6); we only cross-fade
  a scaled screenshot over a janky reflow.

---

## 11. Open items

Settle these as we build, not now.

1. **`EmiraMotion` as a separate target vs a folder** — started separate for the clean seam; still separate, still
   trivial to collapse.
2. **The viewport does not clamp to the strip's extent.** Closing columns can leave the scroll offset past the end of
   a strip that now fits entirely on screen, parking a window at its 1 px sliver beside bare desktop.
3. **Real signing** — Developer ID + hardened runtime + notarization, and with them a TCC grant that survives a
   rebuild. Ad-hoc is enough to run locally.
4. **Nothing puts the desktop back on quit.** Parking is only survivable while emira is running; a user who quits is
   left dragging windows back one at a time.
