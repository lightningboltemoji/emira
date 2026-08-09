# emira — Implementation

**Companion to `PRINCIPLES.md`.** `PRINCIPLES.md` is the _why_ — the SIP-on charter, the two-plane model, the
graphics thesis. This document is the _how_: the boundaries, the loops, the state, and the rules a change has to
respect. Where the two disagree, `PRINCIPLES.md` wins on principle and this doc gets corrected.

**What is deliberately not here.** Rejected alternatives, the bug that motivated a line, the numbers that proved
it, the investigation — those live in `changes/<id>.md`, which `git blame` reaches (`.agents/README.md`). This
file carries only what someone needs to _contribute_: where a thing goes, what holds the system together, and
which invariants break the product if you break them. When a paragraph here starts explaining, it has drifted.

Guiding bias, restated: **stay small.** emira is not a platform.

---

## 1. The architectural spine

**Functional core, imperative shell — and the core owns the clock.**

```
                    ┌──────────────────────────────────────────────────┐
   Events  ───────► │            EmiraCore  (pure, no AppKit)          │ ──────► Effects
                    │                                                  │
  · CLI command     │   reduce(State, Event) -> (State, [Effect])      │   · setFrame / park       [AX]
  · hotkey command  │                                                  │   · focus / raise         [AX]
  · AX observation  │   State = World (truth) + Workspaces + Monitors  │   · capture               [SCK]
  · display tick dt │           (structure) + Motion + Config          │   · begin/endTransition   [CA]
  · trackpad swipe  │           + Pointer + Drag + TrackpadScroll      │   · setLayerFrame         [CA]
  · config reload   │                                                  │   · setCursorHidden/warp  [CG]
                    └──────────────────────────────────────────────────┘   · exec                  [sh]
                             ▲                              │
                             │ feedback events              │ executed by
                             │ (axLanded, captureReady,     ▼
                             │  coverOnScreen, axFailed)   EmiraShell  (AppKit / AX / SCK / CA / CG)
```

Four invariants hold this together. They are the whole design:

1. **`EmiraCore` imports no framework.** Foundation + `EmiraMotion`, nothing else. If a thing can't be a value
   type or an exhaustive `enum`, it lives in the shell. This is what makes the brain unit-testable in isolation.
2. **The core owns animation time.** No `CAAnimation` tweening. The core holds `{current, velocity, target}` per
   animated quantity and advances them on `Event.tick(dt)`; the shell just blits `layer.frame` each frame.
   Retargeting mid-flight is pure arithmetic (new target, keep velocity), not a `presentationLayer` teardown.
3. **Effects can fail, and failure is just another event.** Every effect may feed a result back — `axLanded`,
   `axFailed`, `captureReady`, `coverOnScreen`, `coverUnavailable`, `crossfadeDone`, `holdTimeout`. The reducer
   is _total_ over `Event`, so a hung app or a vanished window is a normal transition, not a crash.
4. **The pump is never re-entrant.** `dispatch()` during an active pump **appends to a FIFO and returns**;
   `reduce` never runs inside `reduce`, and event A's effects are fully issued before event B reduces. macOS
   makes accidental recursion the default — `orderFront` fires delegate notifications synchronously, an AX call
   can complete on the calling thread — so any handler producing an event must enqueue, never dispatch inline.
   Interruption and retargeting happen _between_ pumps, still inside one run-loop turn.

Everything else in this document is a consequence of these four.

---

## 2. The three vocabularies

`Command`, `Event` and `Effect` are the system's only interfaces. All three are exhaustive `enum`s in
`EmiraCore`, all three are `Codable`, and none of them carries a framework type — no `AXUIElement`, no
`CGImage`, no pid. Ids only.

**`Command` is the one list of "things you can ask emira to do"**, defined once and reused by every surface, so
a new verb is added in exactly one place: the CLI parses `argv` into it, the hotkey manager maps a chord to it,
the config file binds keys to it, the wire protocol carries it, the core consumes it as `Event.command`.

The rule it lives by: **every verb in it does something.** `Command.usage` _is_ `emira --help`, and a listed
verb is a promise. That is not automatic — a verb can parse, ride the socket, be answered `ok`, and be inert in
the reducer with the syntax and wire tests green the whole time, because those check that a verb _parses_.

**Its surface spelling is core-side, in `CommandSyntax.swift`, not in the CLI**, because the config file's
keybindings need the identical `argv ↔ Command` mapping and `EmiraConfig` cannot depend on an executable.
`words` is an exhaustive `switch` the compiler checks; a test pins the verb table against it. This is also why
there is **no `swift-argument-parser`**: the grammar is "verb, then at most one word", and `exec` — the one verb
whose argument is a _shell_ line — declares `takesRawTail` and gets everything after its own word, unsplit.

**`Event` is the replay log.** Every input to the reducer is a case of it, which is what makes
`(State, Event) → (State, [Effect])` replayable in principle. Two consequences bind the shell: nothing may enter
the pump at the refresh rate that isn't a tick, and nothing that displays state may be an `Event`.

The first has two instances, and the stated cost is the same in both — every dispatch drains
`onStateChanged`, where the guide re-derives its whole projection. Raw pointer samples are filtered into one
`pointerEntered` crossing _outside_ the pump. Trackpad travel is **accumulated in the shell and drained on the
frame boundary**, immediately ahead of the tick that will paint it (`DisplayLinkDriver.onFrame`): the pad
samples at ~120 Hz and the screen may paint at 60, so dispatching per sample would write the viewport twice
between paints and throw the first one away. Riding the frame is what earns the exemption — gesture events
then never exceed the tick rate the pump was already running at, over an interval bounded by a hand.

**`Effect` is the output vocabulary**, grouped by the plane that executes it (§4). Adding one means assigning it
a plane in `CompositingExecutor.plane(of:)`, which is exhaustive on purpose.

---

## 3. Module graph & where things go

Six library targets and two executables. Dependencies point strictly upward; nothing below `EmiraSettings`
imports a framework.

```
EmiraMotion     pure math — springs, easing curves, the scalar Animator.  (zero deps)
    ▲
EmiraCore       pure — geometry, ids, Command/Event/Effect, State, layout engine,
    │           rules, Config values, the Engine reducer.        (deps: EmiraMotion)
    ▲
   ├── EmiraProtocol   Codable request/reply envelope, wire framing, one-shot socket client.
   └── EmiraConfig     pure — the TOML grammar and the config schema; text ⇄ `Config`.
    ▲
EmiraSettings   AppKit — the settings window: the scrim, the mock desktop, the controls.
    │           Sees the config and the geometry; may not name the reducer.
    │                        (deps: EmiraCore, EmiraConfig, EmiraMotion; imports AppKit/QuartzCore)
    ▲
EmiraShell      imperative — Runtime, Executor, AX, Capture, Compositor, Guide, Pointer,
    │           Display, Hotkeys, ConfigLoader, IPC, MenuBar, Onboarding, Teardown.
    │  (deps: EmiraCore, EmiraConfig, EmiraProtocol, EmiraSettings; imports AppKit/QuartzCore/SCK/AX/Carbon/CG)
    ▲
   ├── emira-daemon   executable — NSApplication accessory host that wires the Runtime.
   └── emira          executable — CLI; socket client, plus `emira config` over the file.
```

Each boundary buys one enforced property:

- **`EmiraMotion` separate from `EmiraCore`** — a scalar solver that can't reach into reconciler state, and is
  testable by feeding `dt` and asserting convergence. Trivially collapsible into `EmiraCore/Animation/` if the
  seam ever stops paying.
- **`EmiraConfig` separate from `EmiraCore`** — the config _values_ stay in core because the reducer reads them;
  what moved out is the _format_. The target is what makes "the settings GUI sees the config and nothing else"
  enforced rather than intended, and it does the same for `emira config` in the other direction.
- **`EmiraSettings` separate from `EmiraShell`** — a target rather than a folder, for `EmiraConfig`'s reason one
  rung further out: it sees the config and the geometry and nothing else, so a preview cannot reach the reducer.
  The graph does not enforce that on its own — `EmiraConfig` pulls in `EmiraCore` — so `ImportFenceTests` scans
  the sources for `Engine`, `State`, `Event`, `Effect` and `Command` and fails on any of them. The fence reads
  code alone, since the module's own header states the rule by naming all five.
- **`EmiraProtocol` separate from the CLI** — an executable can't be imported, so anything with logic in it is
  untested by construction. Partial writes, a peer hanging up mid-reply, and version-mismatched answers are
  exactly the failures that need tests.
- **The CLI at the bottom** — framework-free and fast to launch. No AX, no CA, no AppKit, no `EmiraShell`.

**Where a new thing goes**, in the order to ask:

| If it…                                                      | it belongs in             |
| ----------------------------------------------------------- | ------------------------- |
| decides _what should happen_ — geometry, policy, sequencing | `EmiraCore`               |
| is scalar motion given `dt`                                 | `EmiraMotion`             |
| is a fact about the config file's _text_                    | `EmiraConfig`             |
| is how a *setting* is shown, previewed or edited            | `EmiraSettings`           |
| needs a framework, a thread, or a system answer             | `EmiraShell`              |
| only wires things together                                  | `emira-daemon/main.swift` |

If a decision needs a system answer _and_ a policy, split it: the shell reports the fact as an `Event`, the core
decides. `Event.pointerEntered` (fact) versus `[focus] follows-mouse` (policy) is the model case.

---

## 4. The event loop

`Runtime` (`EmiraShell/Runtime.swift`, ~170 lines) is the only place `Engine.reduce` is called and the only
writer of core `State` in the application. It is `@MainActor` and framework-free.

```
dispatch(event)
  └─ queue.append                      ← from any source, at any time, including mid-pump
  └─ if already pumping: return        ← invariant 4
  └─ pump():  while head < queue.count
                (state, effects) = Engine.reduce(state, queue[head])
                executor.execute(effects, feedback: sink)     ← empty batches are skipped
  └─ syncTimeSources()                 ← start/stop the frame clock, arm/cancel each cover's deadline
  └─ onStateChanged(state)             ← once per *drain*, for peripherals that display state
```

**Event sources** all hold an `EventSink` — a `Sendable` struct wrapping a `@MainActor` closure with a weak
capture, so nothing in the shell owns or outlives the pump, and the "cross a thread to get here, deliver on the
main actor" AX boundary is expressed once in one type. The sources are:

`WorldWatcher` (AX observers + `NSWorkspace`) · `DisplayLinkDriver` (ticks) · `HotkeyManager` (Carbon, and a tap for fn) ·
`SocketServer` (the CLI) · `ConfigLoader` (hot reload) · `PointerFocus` / `PointerWake` (filtered samples) ·
and the executors themselves, acking their own effects.

**Effect execution splits by plane.** `CompositingExecutor` splits a batch into **maximal contiguous
same-plane runs** — never partitioned, because emission order is the reducer's to decide — and routes each to
its executor. There are five planes:

| Plane        | Executor                              | Machinery                                            |
| ------------ | ------------------------------------- | ---------------------------------------------------- |
| presentation | `Reconstruction` (via `CoverSurface`) | Core Animation, main thread, instant                 |
| capture      | `CaptureService`                      | ScreenCaptureKit, own queue, deadline-bounded        |
| truth        | `AXExecutor`                          | AX Mach IPC, serial per-app queues, slow, may refuse |
| pointer      | `PointerExecutor`                     | CoreGraphics on the cursor itself                    |
| system       | `ShellLauncher`                       | `/bin/sh -c`, fire and forget                        |

What the router cannot supply is "cover before teleport" — that is a fact about the _display_, not about
emission order, so it is a phase in the core fenced by `Event.coverOnScreen`, and the two never share a batch.

**The frame clock is gated on `Motion.needsFrames`**, not on the cover being up: the session opens a few
milliseconds before the cover is raised, so the display link's spin-up overlaps the captures and the pre-cover
ticks are inert in the reducer. An idle emira runs no display link at all. `FrameClock` and `HoldTimer` are
protocols so the pump stays headless-testable.

**`onStateChanged` fires once per drain, not once per event.** A single command cascades through capture →
raise → on-screen → teleport → landings, and an observer seeing each step would see states the user never does.
Peripherals that _display_ state (`MenuBarItem`, `Guide`) hang off it and diff their own projection; they are
deliberately not `Effect`s. `PointerFocus` is the one exception and holds a `() -> State` reader instead,
because it reads on a _sample_, which is not an event and must not become one.

---

## 5. The transition lifecycle

The hardest part of the system, and the part a change is most likely to break.

**Steady state has no overlay.** At rest the real windows sit at their AX positions and the presentation plane
does not exist. A cover is _ephemeral_: up for the duration of a transition, down on cross-fade.

**A cover is one display's, and so is the session that drives it.** `Motion` holds a `Viewport` per
`MonitorId` — that screen's scroll offset, its session, and the redirect count its deadline re-arms on — so a
transition on one screen leaves the other's desktop alone: nothing photographed there, no cover raised, no video
frozen for the length of a scroll. Every gate below is therefore stated per display. Three things stay
whole-desktop, each for its own reason: the frame clock (one `dt`, §7), the `LayerId` watermark (so an id names
one layer on one screen and the per-frame call can stay untagged), and the per-window displacement and
per-column width animators — keyed by ids that outlive a display, so a window changing screens keeps the
animator carrying it. The cost of that last one is that "which of these is this screen's" is a question `Motion`
cannot answer for itself: `State.contents(of:)` supplies it as `MonitorContents`, and `advance` and the settle
gate take it. Scoping `advance` is load-bearing rather than tidy — a structural edit seeds a displacement the
instant its command lands, and advancing it under *another* display's tick would decay that seed away during
this display's capture head.

- **Idle.** Anything that moves no windows on screen — a focus change that doesn't scroll, a display change, a
  config reload — is executed as direct AX sets. Plain `setFrame` / `park` / `focus`, snap, no cover.
- **Transition.** Anything that moves the strip opens a _session_, including motion nobody asked emira for:
  externally-initiated focus (Cmd-Tab, a Dock click, an app activating itself) reveals its window exactly as the
  `focus` command does.

### The phase machine

`TransitionSession.Phase` is `.capturing → .raising → .covered`, and **only the last lets a real window move.**

```
command                                            (m = the display it acts on)
  └─ Effect.capture(m, win, size:) per scoped win     phase(m) = .capturing
       └─ Event.captureReady × n   (all in ⇒)         ← untagged: marked in every session waiting
            └─ Effect.beginTransition(m, bindings)    phase(m) = .raising
               + elevateLayer + setLayerFrame         ← untagged: routed by layer
                 └─ Event.coverOnScreen(m)            phase(m) = .covered
                      └─ teleport the reals behind it  ← the ONLY teleport batch
                           └─ Event.tick(dt) × N  →  Effect.setLayerFrame
                                └─ m's animators settled AND every scoped axLanded
                                     └─ Effect.endTransition(m) → Event.crossfadeDone(m)
```

**Which calls carry a display and which do not is the whole of the vocabulary change.** A cover belongs to one
screen, so `beginTransition` / `extendCover` / `endTransition` name theirs, and so do the four reports that
answer them. `capture` names one too, for the one thing the store cannot otherwise know: which display's desktop
*base* a batch opening a cover owes. Everything else stays untagged, and deliberately: `captureReady` and
`axLanded` are facts about a **window**, marked in every session waiting on them, so one still and one landing
settle both covers that show it; `setLayerFrame`, `elevateLayer` and `refreshLayer` are facts about a **layer**,
which already names one layer on one screen, so the hottest path in the reducer carries nothing extra and the
compositor routes on a dictionary read.

**Why the raise is two steps.** `beginTransition` reaches the window server synchronously, but the display
composes on its own schedule, and an app fast enough to answer an AX set inside that interval would move in the
open. Emission order cannot close that — ordering our own calls says nothing about whose pixels the window
server has ready. So the shell fences the raise against the display itself (`CADisplayLink.targetTimestamp`, two
callbacks) and reports `coverOnScreen`, which is the only thing advancing the phase and the only batch a
teleport rides in. `.raising` answers the truth plane exactly as `.capturing` does — `reassertTruthPlane` writes
nothing **for that display** — so an unrelated event landing inside the window cannot write there either.

**And the gate is quantified over displays:** a real window may move only when the cover is up on every display
it is visible on before *or* after the move. A workspace lives on one display, so that is the display holding
it — one placement pass writes each screen's windows at its own viewport (resting where it rests, at the
scroll's end where a cover is up) and skips a screen mid-capture or mid-raise entirely. On one display that is
the rule above with the quantifier written down; on two it is what stops one screen's capture head from freezing
the other's truth plane. What it does *not* cover is a window whose pixels reach past its own display: it is
covered on the screen its workspace lives on, and its far half stays in the neighbouring desktop.

A held display still contributes its share of `World.placedOnScreen` — what the last completed pass decided —
so the record describes the whole desktop while the writes are only what the gate allows.

### The close gate, and its bound

A session closes when **both** halves are answered: the animators **it** is waiting on have settled, _and_ every
scoped window has reported `axLanded`. Both halves are that display's: a width still growing holds up the cover
over the screen it is growing on and no other, and the deadline that bounds the wait is one per cover, so an app
hanging under one screen's cover costs the other nothing. The landing wait is **scoped and bounded**:

- **Scoped** to every window the viewport _sweeps_ between its start and end offsets — departing windows count,
  because a failed park leaves a window squatting in view. Only park→park motion is invisible and skippable.
- **Bounded** by `[animation] hold-timeout` (1 s), itself just an `Event`: reveal the truth, keep retrying the
  AX set, reconcile when it lands. A frozen cover is worse than a visibly hung app. The one display it is not
  armed for is one a hand is on (`TrackpadScroll`): a leisurely drag outruns a second, and there is no AX set
  outstanding to wait on until the lift — which is the timeout's own definition rather than an exemption from
  it. The lift's aim is the first `retargetGeneration` bump of the gesture, so the deadline arms fresh exactly
  when the placement pass it bounds is issued.

The wait **grows and never shrinks**: only the _initial_ teleport replaces it, since a later re-teleport that
moves nothing would clear the wait for sets still in flight and cross-fade onto reals that have not arrived.

### Scope, sweep and shoulder

- **The sweep is one query of a wider window.** A viewport of width `w` travelling `a → b` covers
  `[min, max + w]`, so `Layout.sweptWindowIds` needs no new geometry.
- **It carries a shoulder** — the column just outside each end — because a retarget's new stills take a capture
  round trip and nothing holds the layers back while they are out. Not free: the window server serializes
  screenshot requests, so every shouldered window adds ~10 ms to the head of every scroll.
- **A scope grows and never shrinks.** A retarget _widens_ the scope, captures what that adds, and grows the
  raised cover (`Effect.extendCover`) when the still lands. Nothing is removed: a window the old destination
  swept is mid-flight on both planes.
- **The extend gate asks per window, not per session.** An all-or-nothing gate starves under a stream of
  extensions. The _raise_ keeps its all-or-nothing gate, because that one is about the base: a cover raised
  without it is not a cover.
- **Sweep is not `visibleWindowIds`.** That query means "what is on screen" and the reducer parks its
  complement; a shouldered answer there would put two parked columns on the strip.
- **A window handed across displays is the one term of the difference no display can compute.** A structural
  edit animates `before − after`, and each display's geometry answers only for the strips it holds — so a
  travelling window is missing from the _after_ side on the screen it left and from the _before_ side on the
  one it reached, and each sees one frame and no travel at all. `Engine.Crossing` reads the pair instead:
  the frame the source snapshot holds, and the frame the display that now owns its workspace lays it out at.
  Natural frames on every display share **one global space**, so this is a single difference, seeded **once**
  — the displacement animators are the desktop's, and a second seed would double the journey — and read by
  both covers, which is what makes it one window crossing rather than two cutting. The arrival is also the
  only thing an otherwise-still destination has to animate, so it is asked separately from `moves` when
  deciding whether that screen covers at all.
- **A cover names what it draws from elsewhere** (`TransitionSession.carried`). Its own strips cannot place a
  window that has left them, so without this the departing layer freezes at the frame it was captured at
  while the strip it left closes behind it. Set by the edit that hands the window over, read per frame by
  `emitLayerFrames`, and answered from the display that holds it now — the same global number that display's
  own cover draws it at.

### Degradation — every exit owes a placement

| Event               | Meaning                                | Response                                                |
| ------------------- | -------------------------------------- | ------------------------------------------------------- |
| `holdTimeout`       | an AX set never landed                 | close, `endTransition`, re-place                        |
| `coverUnavailable`  | the capture plane produced no base     | abandon **before anything moved**, snap                 |
| `axFailed`          | the app refused or timed out the write | mark the window's frame unverified, resolve its landing |
| `abandonTransition` | a switch handed no before-geometry     | close, with `finishStructuralEdit` placing behind it    |
| `screensChanged`    | the ground the strip stands on moved   | close **every** cover, `endTransition` each, re-place   |

The last one is quantified over the desktop rather than over the displays that left, and it is the only
exit that is: nothing on any screen is travelling to where it now belongs, and the shell rebuilds the
overlay of every display a reconfiguration touched, so a cover left open would be drawing on a surface
nobody can see. A report that changes **nothing** is exempt, and has to be — `screensChanged` also
arrives redundantly, and closing a cover mid-raise there would write the truth plane with nothing on
the glass to hide it.

`axFailed` records that _we don't know where the window is_. Placement writes its target into `World`
optimistically, which is what keeps a repeated idle event from re-emitting forever; a timed-out write generally
cannot read the frame back to correct it, so the lie would stand as truth and the placement diff would skip the
window forever. Marking it unverified makes that predicate answer `false`. Deliberately **not** a retry —
nothing is scheduled — so a hung app costs one extra set per real event instead of a busy loop.

A snap-path event arriving mid-transition (a `windowCreated` during a scroll) **redirects** the session rather
than returning nothing. Every such path goes through the same opens-or-redirects call the command paths use.

### The modes

- **`smooth`** — springs; the cover dissolves over 220 ms.
- **`snap`** — the same session with **no animator created at all**. An absent animator resolves to the value
  `Layout` derives, so the settle half of the gate is answered from the session's first instant, the cover's
  first blit is the finished strip, and the close waits on `axLanded` alone. Ticks still arrive and the reducer
  drops them. Exit is 40 ms — a seam rather than a jump.
- **`off`** — no cover raised at all, and the one setting that waives a grant: asking for the cover is what makes
  Screen Recording required, so `off` drops the requirement with it (§9). `snap` is on the _asking_ side of that
  line with `smooth` — it animates nothing, but a cover it cannot make of pixels is not a cover.

Every exit length is safe for one reason: a cover is dismissed only once its animators have settled _and_ its
reals have landed, so it always comes off a desktop that already matches it. What a dissolve hides is content
that went stale under the cover, never geometry. The numbers live in `CompositingExecutor`, above the test seam.

`CoverMode` decides when a window _has_ pixels. Under `immediate` a window whose kept still fits is acked at
once; its real capture returns as `Event.captureRefreshed` → `Effect.refreshLayer`, a cross-fade of one layer's
_contents_ that settles no gate. `SurfaceCache` holds what a cover leaves behind, at quarter scale.

---

## 6. State — what lives where

```swift
State = World         // truth: displays (frame + struts), apps, windows, focus, frames, corrections
      + Workspaces    // structure: 36 strips, the shared ColumnId allocator
      + Monitors      // structure: which display owns which workspaces, shows which, and is focused
      + Motion        // animation: a viewport per display (offset + session), column widths, displacements
      + Config        // the parsed values the reducer reads
      + Pointer       // intent the shell is owed: a pending warp, a wanted hide
      + Drag          // a button is down, and which window has moved under it
      + TrackpadScroll // three fingers are down, and whose viewport they are driving
```

`State.layout` is a **settable computed projection** of `workspaces[monitors.shown]` — single storage, not a
second authority. Only the genuinely cross-strip queries bypass it: reconcile, `targetFrames`, the placement
walks, and the mutators that mint a `ColumnId`.

**Three joins, and each is one method on `State` because the containers must move together.** Where a step
touches two of them, the pair is not something a caller may be trusted to remember:

- **`setMonitors`** folds `Event.screensChanged`. `World` takes the geometry observation reports, `Monitors`
  re-homes the workspaces around whatever arrived or left, and every address a display ends up showing is
  materialized. A `World` that knows about a display `Monitors` does not is a desktop with geometry, no acting
  monitor and therefore no metrics at all.
- **`show`** switches a monitor's address — the acting one unless a verb names another
  (`move-workspace-to-monitor`). Not one strip per call: the claim dispossesses whichever display held that
  address, and _that_ display falls back to one nothing may ever have materialized, so what the switch owes a
  strip to is every address left on a screen. Which addresses are **occupied** rides along, because the
  fallback prefers one holding a window and only `Workspaces` can answer that.
- **`move`** lands a window on another address, which materializes it — and an address with a strip belongs to
  a display (invariant 2). `Workspaces.move` is internal for exactly this reason: a container that cannot know
  about displays must not be the way in.

**Shown ⇒ materialized** is what the first two hold between them, and it is the assumption every cross-strip
query makes — `placementOrder(shown:)` and `targetFrames(shown:)` are handed the on-screen list, and a name in
it with no strip is a hole in the placement walk and a park ordinal handed out against nothing.

`Pointer` is separate from `World` because every field of `World` is refreshed by observation and these cannot
be: no public API reports cursor visibility, and the window server discards a background hide on activation
without saying so. A record nothing can refresh is a wish, and holding it as one is what makes a hide an
assertion that is re-made rather than a latch that refuses.

`Drag` is beside it on the same argument rather than inside it: a window's frame is observed, but _who moved it_
is reported by nothing. It is a latch, which is exactly the thing `Pointer`'s own paragraph exists to say a hide
is not, so folding one into the other would blur the distinction both depend on.

`TrackpadScroll` is the third on that argument, and not `Motion`'s either: a viewport offset is refreshed by
the spring that owns it, but "a hand is on the trackpad" is reported by nothing and derivable from nothing. It
is `.idle` or `.dragging(MonitorId)` — **one at a time and one display**, since there is one trackpad and the
hand is in one place, latched from `State.acting()` because the fingers are not on a screen and the focused
monitor is the only thing that can answer. There is deliberately **no `gliding` case**: the lift hands the
offset back to a spring aimed at a target, and from that instant every question about it has the answer it has
for a keyboard scroll, so a case that changed no answer would be a second authority on "is a transition in
flight". The latch buys exactly three things, each a question `Motion` cannot answer for itself: **a cover a
hand is still on never closes** (`isReadyToClose(…, hand:)` — a driven offset is settled by construction, so a
paused finger would otherwise cross-fade), the **hold deadline is not armed** for that display (there is no AX
set outstanding to wait on, which is the timeout's own definition rather than an exemption), and the tick
**blits its frame anyway** despite `isSettled` calling it done. **The latch dies with its session**, stated
once as a join over `State` (`closeTransition` / `abortTransition`) rather than repeated at four teardown
sites — a latch outliving its cover would drive a viewport with nothing to hide it and no clock to paint it.

### The four animated quantities

Never two authorities on one number.

1. **Scroll** — one viewport offset **per display**, with every layer frame on that screen derived from it.
   Lockstep is structural rather than maintained; a retarget is one number. The per-workspace scroll
   `Workspaces` remembers is the other half: the live animator is the display's, the memory a switch writes
   out and reads back in is the strip's.

   **It is the one quantity with a second author.** A trackpad drag writes it outright — `driveViewport` is an
   `Animator.snap` minus the `retargetGeneration` bump, so a dragged offset is one that has _already arrived_
   every frame, `advance` is a no-op for it and nothing needs a special case. The two never overlap: a command
   arriving mid-gesture drops the latch and takes the viewport back. At the lift `glideViewport` hands it to a
   spring seeded with the hand's velocity — the one place `Animator.velocity` is written from outside — and
   **which spring a viewport is under is derived from the last aim rather than stored**, since
   `retargetViewport` and `snapViewport` both put it back on the scroll spring before aiming.
2. **Resize** — a column's resolved width (`Motion.columnWidths`), for the same reason: every frame derives from
   it, so the growing column and everything it pushes move together. Retargeted in flight, never restarted.
3. **Structural edit** — the odd one, because an edit that inserts or removes a column makes before and after
   two different `Layout`s, with no number to interpolate. So what goes under a spring is each window's
   **displacement** from where the layout now says it belongs, decaying to zero (`Motion.windowAnimators`,
   `RectAnimator`). Destination stays derived; only the _lag_ is per-window.
4. **The guide's focus ring** — a displacement from the focused window's own frame. The odd one out because
   **nothing derives from it**, and three consequences are load-bearing: it is **not in `Motion.isSettled`** (a
   decoration must not hold a cover up), it **never bumps `retargetGeneration`** (a focus change must not extend
   a hung transition's hold), and it **survives `closeTransition()`** (the guide outlives the cover by design).
   Hence `needsFrames = isTransitioning || !isFocusRingSettled`, while `syncHold` reads the first term alone.

Every emitted layer frame is one expression: `naturalFrames` resolved at (1) and (2) — the live offset and the
live widths — then `.displaced(by:)` (3). The guide draws the _same_ expression at another scale, which is why
off-screen columns, vertical workspace slides and animated resizes all arrive there at no cost (`emitLayerFrames`,
`GuideModel`).

Departures, arrivals, close, minimize, hide, `move-window`, `consume-or-expel`, `cycle-height` and boot
adoptions all ride the one structural-edit path. A departure simply lacks a _mover_; an arrival is seeded with
**the frame its app opened it at**, which is also the frame the cover captures — that equality is why the raise
does not pop, and it makes a newcomer _travel_ rather than appear.

**An edit carries one before-geometry per display it changes, and each drives its own cover.** A verb that
hands a window or a workspace across the desktop changes what two screens show, and two screens are two
presentation planes: each decides for itself whether it has anything to animate, so one may open a cover
while the other lands its share at once. One display is that with a list of one. Two consequences are worth
recognising: a window that changed displays appears in one side of the difference only, so no displacement is
seeded for it and both covers simply draw it where their own strip says it belongs; and an address changing
displays is read as **each screen's own** in the before-geometry, which is invariant 4's implementation — the
hand-over is two independent workspace switches, and the destination's is a slide *in* from one screen away,
which it can only be if the geometry it is leaving already places it there.

### Layout

`Layout` is ONE strip: columns → windows, and their target geometry. It exposes **four structural editing
primitives** — `moveColumn`, `moveWindowWithinColumn`, `move(window:toColumn:at:)`, `extract(window:toNewColumnAt:)`.
Twelve command cases compose out of them. **Each is atomic over the invariants**, and that is what chose the set:
"non-empty columns" and "no duplicate windows" cannot be maintained by a reducer composing "remove from column"
then "insert column", because the state between the two calls is invalid.

The decision tree lives in the reducer beside `handleFocus`, which already makes the distinction: _alone in its
column ⇒ the column moves or consumes; with stackmates ⇒ it pops out._

**Two viewports, and every geometry query picks a side.** `LayoutMetrics.contentArea` is the **logical**
viewport (the working area inset by the outer gaps); `workingArea` is the **physical** extent.

- **Logical** is where the strip lives: widths resolve against it, column 0 starts at its left edge, and every
  scroll target frames against it.
- **Physical** is what is on screen: `visibleWindowIds` (the reducer's `setFrame`-vs-`park` switch), the capture
  scope, and the edge a park sliver hugs.

Asking `visibleWindowIds` of the _logical_ viewport parks any column whose leading edge sits in the margin —
enforcing the margin by teleporting windows out of it, which is the clipping this design exists to avoid, and it
pops the cross-fade because the presentation plane draws that column from geometry that never parks.

**An outer gap is not a strut**, and the arithmetic being identical is the trap. A strut is **forbidden ground**
— no managed window is ever inside it, tiled or parked, which is what licenses the strut-inset cover. An outer
gap is **empty at rest and crossed in motion**, and the cover clips, so a strut-shaped outer gap would cut every
layer off at the margin and a window would pop into being instead of sliding through.

**Width resolution is a stack**: `fullscreen` shadows an explicit `widthOverride` (from `grow`/`shrink`, or from
a hand resize) shadows a preset index (from `cycle-width`). Because it shadows rather than replaces, the width
underneath needs no memory and no restore policy. Percentages are of the **working area**, not of the column's
own width, so `grow`/`shrink` are exact inverses.

**Height resolves the same way, one container over**: a `heightOverride` (a hand resize) shadows a preset index
(`cycle-height`) shadows **auto**, which shares the column's leftover height with the other autos. Both rungs
are `Workspaces`' rather than the column's, keyed by `WindowId`, so a window carries its height through the four
structural edits and across a workspace. `LayoutMetrics.heightIntent(of:)` is the one place the stack resolves,
for the reason `Layout.resolvedWidth` is on the other axis.

**What an app answered is a fact the geometry consults** — `World.corrections`, one `SizeCorrection
{ wanted, actual }` per window, keyed on the _question_ rather than stored as a `minWidth`, so a refusal at one
preset cannot ratchet every other preset forever. Corrections ride in `LayoutMetrics`, which is the load-bearing
placement: every geometry entry point already takes `metrics`, so a call site cannot forget one — and it must
reach all of them, or `targetFrames` and the visibility/sweep/scroll queries accumulate different left edges.

`World.parkFloors` is the same shape on the park path, and deliberately separate: a park answer says nothing
about _size_ (a window refuses at a sliver what it accepts in view) and one thing about the window's _chrome_.

**A window resized by its own handle keeps that size, and `Drag` is the whole of what makes that safe.** AX
reports a resize identically whoever asked for it and our own placements provoke one every time, so a frame
change is evidence only inside the mouse-down/up bracket — and only for the **first** window to move inside it,
since a placement pass mid-drag writes the stackmates and an app clamping one of those reports a frame change
with the button still down. The observed size is taken as the intent directly rather than as a delta, which is
also what makes it total over a window that was already refusing its target. Three consequences:

- **Adoption is on release, not live.** The truth plane is the app's main thread, so re-tiling under every
  intermediate frame would trade writes with the drag at the rate of the slowest app in the column — and none of
  it is maskable, since a cover over the window being dragged hides the one thing the user is looking at. This is
  the one motion deliberately outside the transition machinery.
- **The release is not the mouse-up**, and cannot be. The app is still draining the resize when the button comes
  up: the window is not yet the size it was dragged to, and neither AX nor the window server can say what that
  size will be, because nothing has decided it. So `Event.dragEnded` arrives once the window stops moving rather
  than when the button does (`WorldWatcher.beginSettle`), and the adoption reads a `World` that has caught up.
  Nothing is written while that wait is open, so the reports it waits on carry no echoes of our own.
- **A drag of the _left_ edge moves the viewport by the width delta.** The strip accumulates left to right, so a
  column grows rightward whichever edge is pulled; letting the offset take the difference is what puts the moving
  edge back under the pointer, and it costs nothing — the offset is already the one authority on where the strip
  is looked at.
- **A height drag sends the neighbour on that edge back to auto**, which is what makes it a divider rather than a
  window growing into its stackmates. Without it a column whose windows are every one of them pinned has nobody
  to hand the difference to, and repeated drags walk the last window off the bottom of the screen.

"They cannot comply" needs almost nothing new: a stackmate that will not be that narrow is `resolvedWidth`'s
`max`, a stackmate that will not be that short is the water-fill's floor, and both learn through the same
`SizeCorrection` round trip an explicit `grow` uses. `Engine.minimumWindowHeight` is the backstop beside
`minimumColumnWidth` — not the real bound, just what keeps a drag from subscribing a column past its own height
before any app has been asked. A drag that only _moved_ the window is still reverted: reading one as _insert
here_ is a different feature, and until it exists taking the window back is the honest answer.

**Ids are never reused.** `WindowId`, `ColumnId`, `LayerId` are minted once and retired; a dead window's cache
entry is unreachable rather than wrong, and a `Fullscreen` record naming a vanished `ColumnId` is simply not
applied. Staleness is unrepresentable rather than detected. New `ColumnId`s are minted **only inside `Layout`**,
from one allocator shared by all 36 strips — a re-issued id is the key `Motion.columnWidths` and the cover's
animation identity hang on.

### Workspaces

36 addresses in **key** order (`1`–`9`, `0`, then `a`–`z`), a fixed named domain rather than minted tokens.
The addresses on screen tile; the rest are parked in full. Nothing persists across restart.

**Which strip is on screen is not a fact this container holds.** A workspace is shown because a _monitor_
shows it, so every query that turns on the difference between the strip in view and the parked remainder
takes the shown address as an argument. That is what keeps `Workspaces` a pure structure joined to the
displays by a name, rather than a second opinion about which display is looking at what.

- **A switch is `Monitors.show` plus `Workspaces.materialize` plus a placement pass.** "Everything not shown
  is parked" was already what `targetFrames` meant, so the verbs needed no new `Effect` and nothing in
  `EmiraShell`. What they needed was _memory_: each strip's scroll offset and last-focused window. Neither
  container can do the other's half of a switch, which is the join working.
- **The supply is per display; the park run is not.** `targetFrames` and `uncorrectedSizes` take a
  `StripPlacement` per materialized address — the metrics it is laid out against, and, for an address on
  screen, the offset its display's viewport is at — so each screen tiles its own strip and every other strip
  parks in the lot of the display that holds it. `State.placements()` is where `Monitors` and `Motion` are
  joined into that list, which is what lets this container lay out a desktop of several displays without
  knowing displays exist. The **ordinals are one run across every lot**, threaded as a cursor: mirrored
  displays report the same frame, so per-lot cursors would give two windows the same nub and break the
  identity join and the no-overlap invariant silently. The run and the placement walk take the same list, so
  there is one answer to what is on screen rather than two that agree by coincidence.
- **The vertical term is a _sign_, not a distance** (`Workspaces.verticalOffset`): every off-screen workspace
  sits exactly one screen away, so `1 → z` animates the same screen as `1 → 2`. Presentation-plane only — on the
  truth plane an off-workspace window is simply parked.
- **The cross-strip move is one call**, because the decomposition passes through a state with a window on _no_
  strip, where a placement pass landing in between leaves a real window wherever it happens to be. Internal,
  so `State.move` is the only way in — see the joins in §6.
- **Membership and stacking are two queries.** `allWindowIds` answers which windows exist, in name order;
  `windowIds(inPlacementOrder:)` answers what stacks over what, the shown addresses first. One order served
  both while there was one screen looking at one strip.
- **`naturalFrames` answers for one display's strips**, since it is what a cover draws: the address that
  screen shows, plus the ones it owns sliding a screen above and below. A strip another display holds is
  drawn by that display's cover, at its metrics and its offset.

### Monitors

Displays as **containers of workspaces**: a workspace lives on exactly one monitor, and a verb naming a
workspace works whichever monitor holds it. Its own container beside `Workspaces`, joined to it by a
`WorkspaceName` exactly as `World` and `Workspaces` are joined by a `WindowId`. Geometry is _not_ here —
`World.monitors` holds each display's frame and struts, because those are what observation refreshes, and
`State.metrics(of:)` is where the two meet.

Four invariants, the first two kept structurally rather than checked:

1. **A monitor always shows exactly one address, and showing it claims it.** `show` is the only way to move
   `shown`, and it moves `owned` with it — including for the _loser_ of a claim, which takes an address it
   can have in the same call. "A monitor with no workspaces" is unrepresentable; the honest state is a
   monitor showing an _empty_ workspace, which every verb already handles.

   What the loser can take is a three-rung ladder, **nearest first**: the occupied addresses it still
   holds, then anything it holds or nobody holds, then one another display holds but is **not showing**.
   Rung 1 is why a display losing its screen lands on windows it already has rather than on an address it
   passed through once. Rung 3 is what makes the invariant hold, because `show` claims and never releases
   — the acting monitor accumulates every address it has ever shown, so two displays and enough switching
   exhaust the unassigned set long before the 36 addresses run out. Taking an address its owner is not
   looking at costs that owner nothing it can see, so no repair cascades from it. Only every address being
   _on a screen_ leaves nothing to take, and that needs 37 displays.

   "Nearest" is `WorkspaceName` distance from the address being left, **forward winning ties** — `next`'s
   own bias, so a display losing `5` lands on `7` rather than on `3`.
2. **Materialized ⇒ assigned**, and kept where it can break rather than repaired later. Two mutators hold
   it: `show` claims what a display shows, `assign` claims what a verb only _materializes_ — `State.move`
   is the join, since `Workspaces.move` gives an address a strip and cannot know about displays. An
   address some display already holds keeps it, which is what lets a window sent to one travel to
   whichever screen that is. `reconcile` still repairs what neither saw: orphans from a departed display
   land on the first survivor, and an address that lost its strip is dropped unless it is being shown.
3. **`focused` is stored, not derived from `World.focusedWindow`.** A monitor showing an empty workspace has
   no AX target, and emira's focus must still be able to sit there — which is what makes the next window
   spawn land on it, for free, through the unchanged newcomer rule.
4. **A display's assignments outlive the display being gone.** Sleep, lock, clamshell and KVM switches produce
   transient zero- and one-display states, and dropping the desktop's arrangement on each would scramble it
   every lid close. Two records carry it, and they answer different questions: `unattached` is what the
   desktop is showing while **nothing** is attached, which has to be total; `detached` is what each departed
   display held, keyed by the id it will come back as, which only has to be right. A survivor owns those
   addresses meanwhile — the memory is never an authority — and **a returning id takes them back**,
   dispossessing whoever adopted them exactly as a `show` would, with the same repair behind it.

   Where the two meet, **the adoption outranks the reclaim**: the first display back from a zero-display
   state shows `unattached.shown` rather than its own memory, because what the user was *looking at*
   outranks what that particular screen happened to be showing, and every display departing into that state
   leaves a memory behind — so a reclaim that always won would mean the address `unattached` exists to
   choose never survives the lid close it exists for. A display whose address it really was takes it back in
   the same pass.

**A viewport does not survive its display; the address it was showing does.** A reconfiguration is a workspace
switch on every screen at once — each may come out showing a different address — so it runs the same two halves
a switch does: every display banks its scroll against the address it is showing before the containers move, and
every display resumes at the memory of whatever it shows afterwards. Banked at the scroll's **target**, since
the same report takes every cover down and `closeTransition` snaps each viewport to exactly that. A display
whose address did not change reads back the number it just wrote, so the ordinary reconfiguration is an
identity, and the whole thing is skipped for a report that changes nothing — re-seating a viewport there would
freeze a spring mid-travel, for the reason closing a cover there would write the truth plane onto bare glass.

`Monitors.shown` is **total**, including with no display attached: every verb reads `State.layout`, so a `nil`
there would be a crash at boot rather than the no-op `metrics()` already gives.

**Resolving a reference is where the two containers decide together**, and both halves live on `State`:

- **`WorkspaceRef` — absolute is global, relative is per-monitor.** A name goes wherever the workspace
  lives, switching displays if that is where it is; `next` and its kin stay inside `Monitors.reachable`,
  which is the acting monitor's addresses plus every address no display holds. The monitor is the container,
  and cycling should not leave it. Strictly a generalization: on one display that set is all 36 addresses.
- **`MonitorRef` — index, direction, or a step along the enumeration**, and **it clamps rather than
  wrapping**, exactly as `WorkspaceRef` does: a ref with nowhere to go answers the acting monitor, which
  every verb reads as the no-op it is. A direction is spatial — the nearest display whose frame centre lies
  in that half-plane, by distance along the direction's own axis, tie-broken on the cross axis and then on
  enumeration order — so `focus-monitor down` finds the display *under* this one even when it sorts after
  the one beside it. The desktop has an edge where the strip does not, which is why nothing that way is
  silence rather than a wrap.

### Focus policy

- `[focus] system-events` — `respect` / `on-screen` / `ignore`: which focus changes emira did not cause it
  honours. A refusal is one `.focus` effect restoring the focus the core already believed in and **no state
  change at all** — no reveal, no switch, no cover. Two things are always admitted: our own echo (marked
  `.ours` by `FocusIntent`), and a `nil` report.
- `[focus] follows-mouse` — the only focus source that can chase itself, because **here focus scrolls**. Two
  rules stop the runaway and neither is an optimisation: it fires on **pointer motion only, never window
  motion** (that is the termination argument), and it is **suspended while a cover is up** while still
  _tracking_, so a cover coming down leaves the baseline under the hand rather than reporting a phantom crossing.
- **Focus off the strip is an entry condition, not a dead end.** A focus command with no column to start from
  re-enters at the near end: `right` at the leftmost column, `left` at the rightmost.
- `Engine.stripAnchor` — "where was the user working", used when focus rests on nothing. It reads
  `World.lastStripFocus` rather than live focus, because an app focuses its brand-new window before emira has
  adopted it, so a `focusChanged(nil)` lands a moment _before_ the creation; anchoring on live focus passes a
  unit test and appends in reality every time.

### Window rules

Pure predicates over a window's metadata at **first sight** (`Rules.swift`): `WindowRule` — four AND'd matchers
(app id and title, each exact or regex) → `RuleOutcome` (workspace / float / width). Matching rules apply top to
bottom, later overriding earlier, field by field.

All three actions are **seeds into somewhere the user can already reach**: `workspace` is the move
`move-to-workspace` performs, `float` writes the tri-state `Command.float` toggles, `width` is the override
`grow`/`shrink` set and `cycle-width` clears. Nothing here is a mode, which is why none of them needed state.
**A rule fires once and is never consulted again** — a window's workspace is _derived_ from the strip holding
it, so a standing rule would be a second authority over it.

Built-in taxonomy underneath: only `AXStandardWindow` tiles; dialogs/sheets/panels/popovers float;
native-fullscreen windows are excluded; app chrome that merely happens to carry an `NSWindow` is declined
outright at the AX boundary and never reaches a rule at all; minimized and Cmd-H-hidden windows leave the strip,
animated out like a close, position remembered.

---

## 7. The shell, subsystem by subsystem

`EmiraShell` is where every framework lives. It stays thin on purpose: policy that can be pure, is.

| Area                      | Owns                                                                                                     | Its seam (what a test substitutes)                  |
| ------------------------- | -------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `Runtime.swift`           | the pump; the only writer of `State`                                                                     | `Executor`, `FrameClock`, `HoldTimer`               |
| `Executor.swift`          | `EventSink` + the `Executor` protocol                                                                    | `MockExecutor` records effects                      |
| `AX/`                     | the truth plane, in three directions: read (`AXEnumerator`), write (`AXExecutor`), watch (`AXObservers`) | `WindowSource`, `WindowWriter`, `ObservationSource` |
| `WindowRegistry.swift`    | window identity: mints `WindowId`, binds AX ↔ `CGWindowID`                                               | — (pure joins live in `WindowIdentity`)             |
| `WorldWatcher.swift`      | the live world's _policy_: boot scan → adopt → watch → reconcile                                         | driven entirely through the three AX seams          |
| `Capture/`                | SCK stills, the batch deadline, the `WindowId`-keyed store, `SurfaceCache`                               | `SurfaceCapturer`, `CaptureStore`                   |
| `Compositor/`             | an overlay + reconstruction per display, the plane over them, the Y-flip, effect routing                 | `CoverSurface` / `CoverPlane`                        |
| `Guide/`                  | one transient minimap per display; `GuideModel` is the arithmetic, `GuidePanel` the AppKit               | `GuideModel` is pure                                |
| `Pointer/`                | hide/show, warp, and the two sample readers                                                              | `CursorSurface`                                     |
| `Display/`                | `CADisplayLink` → `tick(dt)`, a hold deadline per cover, and the display set as a source                 | `FrameClock`, `HoldTimer`                           |
| `Input/`                  | the two intent sources: chords → `Event.command` through Carbon `RegisterEventHotKey`, or a consuming `CGEventTap` for the fn ones; and a gesture `CGEventTap` → the three trackpad events | `HotkeyBinder`, `GestureTapper`   |
| `Config/`                 | the half that needs a disk: read → watch → report                                                        | `FileWatcher`                                       |
| `Ipc/`                    | unix socket, JSON-lines, `Request` → `Reply`                                                             | a real socket, in-test                              |
| `MenuBar/`, `Onboarding/` | the two GUIs; the policy half of each is pure                                                            | `StatusModel`, `OnboardingModel`                    |
| `Teardown.swift`          | the exit path: place the quit cascade, wait, bounded                                                     | `WindowWriter`                                      |

A few facts that a change is likely to trip over:

**AX hygiene is not optional, and most "slow AX" pain is self-inflicted.** Eight rules, each of which a change
can quietly break:

- **Touch as little of the tree as possible.** Chromium/Electron and JVM apps spin up a _heavyweight_
  accessibility engine the moment a client touches their tree, which slows the whole app. Fetch window-level
  elements only, cache `AXUIElementRef`s, never descend below a window, and don't re-query what an observer
  already reports. Naming the *application* element's own children is not a descent — it answers windows and a
  menu bar — and it is the one place the rule bends, for `kAXWindowsAttribute` going empty below.
- **The `kAXEnhancedUserInterface` bug.** With it on (Chromium/Electron enable it), `setFrame` gets animated and
  positions come out offset. Toggle it off immediately before a set and restore after — read before written,
  never introduced to an app that didn't have it, never left off.
- **Never block our own run loop.** AX setters are synchronous Mach IPC. They run off the main thread on serial
  per-app lanes under a short `AXUIElementSetMessagingTimeout`, which protects _us_ and does nothing for the app.
- **Expect clamping.** Apps clamp to their own min/max, so landing exactly can take size → position → size. What
  an app answered is then a fact the geometry consults (`World.corrections`, §6) rather than something re-asked.
- **An empty `AXWindows` is not proof of an app with no windows.** Finder stops answering it — `.success`, empty
  array — while those same window elements are still the application element's children, and an app contributing
  nothing simply leaves `World`. An answer that is *empty* is asked again as `AXChildren`; an answer that
  *failed* is not, since that is usually the messaging timeout and a second one would double what a hung app
  costs its lane.
- **The window classifier is failable, in two directions.** `kAXWindowsAttribute` is not a list of windows —
  Finder answers it with the desktop, and the fallback above adds a menu bar. An unrecognized **role** means
  "not a window", which is what filters both. And a window whose subrole is the literal `AXUnknown` **and**
  whose `AXMain` is not *settable* is app chrome that happens to be an `NSWindow` — Chrome's Cmd-F find bar is
  a full entry in the list, frame and title and all. Both are dropped at the AX boundary. An unrecognized
  subrole that can still be main means "a real window we leave alone".
- **AppKit derives a window's subrole from `canBecomeMain`.** Two windows with identical style masks report
  `AXStandardWindow` or `AXDialog` purely according to whether the app overrode that method, so a decorationless
  terminal — which must override it to be typable at all — is indistinguishable from a decorated one, and the
  stoplight buttons are worthless as a signal. It also means subrole and settable-`AXMain` are one fact read
  twice on the AppKit path; the conjunction earns its keep off that path, where a toolkit growing its own AX
  tree can answer `AXUnknown` for an ordinary window and the settable `AXMain` is the half to believe.
- **Adopting a non-window is not free even though it never tiles.** It mints a `WindowId` per appearance (a find
  bar is opened and closed all day), attaches an observer, and enters `World.window(at:)` — which prefers floats
  over tiled windows, so it wins the `follows-mouse` hit test over the page underneath it and takes focus it
  cannot hold.

**AX identity is the fragile part.** A match must be **unique in both directions** within 2 pt or it is not a
match — a nearest-position match always answers, and a wrong answer is permanent and invisible. Two joins run on
the same scan against the same two lists: `WindowIdentity.bind` (which window-list entry is this AX window) and
`WindowIdentity.succeed` (which arriving window is standing where a departed one stood). Both are pure.

**`WindowRegistry.rebind` is the only thing that re-points a binding**, and it buys native tab groups: keeping
the `WindowId` makes a tab switch _unobservable to the core_, so the column, its width, its workspace and its
float state survive one without a single `Event`. Three maps move together or the seam leaks — number, element,
and the record's element. A destroy notification therefore **waits for one scan** before retiring an id.

**Whether emira may change which app is active is macOS's decision, and `activate()` returning `false` is the
only sign it went the other way.** A background agent is not always eligible, and one launched from a terminal
can find itself able to bring _that terminal_ forward and nothing else — which reads as one app refusing focus
forever rather than as a refusal at all. `AXWindowWriter.focus` answers a refusal by writing `AXFrontmost` on
the application element: the Accessibility API, which emira holds a grant for, rather than AppKit activation,
which is the thing being withheld. It goes out **only** on a refusal, so the common path keeps its latency and
the cross-app ordering `FocusIntent`'s ticket buys. A focus neither route lands reports nothing, so no
`appActivated` is claimed for an activation that never happened.

**A batch is grouped into one lane job per app**, not one per window: the reducer emits placements in layout
order, which interleaves apps, and grouping collapses N lane hops and N enhanced-UI toggles into one. The
enhanced-UI flag is **read before it is written** and restored after — never introduced to an app that didn't
have it, never left off.

**A reconciliation heartbeat is the standing check behind all of it** (`WorldWatcher.reconcile`, every 3 s).
Everything else is edge-triggered, so a missed discovery is a window unmanaged for the life of the daemon,
silently. The list is a window-server query rather than IPC, so being level-triggered costs ~2.5 ms and no AX
until the two disagree. `Heartbeat` is its own seam beside `DelayScheduler`: a retry terminates and a heartbeat
does not, and one drained by a test's "run everything pending" loop never would.

**It holds three invariants, not one, and the division is race versus state.** A race resolves itself, so it is
waited out under a budget in the edge plane; a state stays wrong until something asks again, and only the
heartbeat can ask forever. Every app we know is observed — a registration that failed leaves an app deaf to us,
which no edge can repair because a budget must terminate. Every managed window still exists — the destroy
notification comes from the app, and a wedged app sends nothing. Every on-screen window is managed. The retry
chain is kept in front of the first two as a hurry rather than a repair: it answers a launch race in
milliseconds instead of at the next tick, and running out no longer means giving up.

**The window server is the authority the removal direction rests on**, because it owns the window rather than
the app does — the one witness a beachballed app cannot keep quiet. Absence from `CGWindowListCopyWindowInfo`
is therefore a death certificate, and a stronger one than any evidence the AX paths hold, where silence has a
second reading. Two edges make it safe. It is absence from the list *entirely*, never `isOnScreen`: an ordinary
desktop carries far more off-screen layer-0 entries than on-screen ones — background tabs, other Spaces, the
Dock — and each is a live window, which is exactly why the *discovery* direction filters on the opposite sense.
And an empty list is a failed read rather than an empty desktop, so it is refused before it can retire the
strip. Removal goes through `vanish`, so a window that closed unheard still gets the succession its
notification would have bought it. A window number outlives everything a window does short of closing,
**native full screen included**: the window goes off screen and changes frame across that transition and
keeps its number, while the full-screen-sized and menu-bar-height windows the transition mints and
destroys around it are the ones that come and go. The set is layer-0 only, so a level change would read as a
death as surely as a close does — and nothing a managed window goes through changes its layer, **Mission
Control, App Exposé and a Space switch included**, which matter more than full screen because they last as
long as the user holds them.

**`alreadyOpen` is provenance, and every seam a scan request crosses has to carry it.** A window emira
watched open is snapped onto the first preset and followed to the workspace a rule sends it to; one it met
mid-life keeps the width it already has and moves nobody's desktop. Only a birth notification says the
former, so `appLaunched` and `windowAppeared` are the only two scans that mean it — boot, reconciliation
and the destroy scan all mean the latter, since what provoked each of them names no arrival. It therefore
travels with the scan *request* rather than being decided where the report is absorbed, and that includes
the scan coalescer: several requests for one app merge into one answer whose windows nothing can tell apart,
and they merge toward "met already open", the only one of the two mistakes that leaves a window the user
was already using where they put it. The scan already in flight is one of those requests — what its replay is
left to announce is precisely what that scan missed — so the merge runs over it as well as over the ones
coalesced behind it.

**Observers speak `WorldObservation`, not `Event`.** Three cases decide the type: "a window appeared" is not a
window we can name (the notification carries an element with no window number, so the response is a re-scan),
"a window moved" is not a frame (AX never says where to), and a mouse-up is not the end of a drag — the window
under it goes on being resized by its app for some milliseconds afterwards, so the release is held until the
frames stop arriving. All three responses are policy, and the last two are why the watcher owns a clock: a
`WorldObservation` is a fact about the desktop and an `Event` is one the core can act on, which for anything
the truth plane answers late is a fact that has to wait for its own answer.

**The cover is the working area, not the display.** Our overlay is `.floating` (level 3); the menu bar is
`.mainMenu` (level 24) and always composites on top of it, over the base capture's own copy of it. So the
overlay is **inset by the struts** and the chrome bands show the real, live menu bar and Dock — safe for exactly
the reason the strut exists. The struts reach the core on `Event.screensChanged`, beside the frame they inset,
so a display's overlay and that display's strip are laid out against one number: the invariant holds only
while the two agree, and it is stated per monitor. Which is why the daemon reads the display set **once** and
hands that same array to both — `NSScreen.visibleFrame` is live, so a second read for the core's copy would
let a Dock that moved in between inset the cover by one number and the strip by another, and adoption can be
held back for as long as a broken config file takes to fix. A display's **identity** has one reader for the same
reason (`ScreenGeometry.displayId`): the `MonitorId` the core keys a strip on, the `CGDirectDisplayID`
ScreenCaptureKit films from and the `NSScreen` the overlay covers are one number under three names, and a
second reader with its own fallback is how they quietly stop naming the same display.

**One of every display-shaped thing, per display.** An `Overlay` + `Reconstruction` each (its own struts, its
own backing scale, its own base capture), a `GuidePanel` + `Guide` each, an `SCKCapturer` each. Three seams
carry the plural:

- **`CoverSurface` is one display's layer tree; `CoverPlane` is all of them, plus the frame boundary and the
  route.** The `CATransaction` lives on the plane (`Compositor`), because with N surfaces a transaction
  wrapping one of them is not a frame — two displays blitting inside two transactions are two frames, and the
  strips on them shear apart by exactly one refresh. The route is `[LayerId: MonitorId]`, recorded at every
  raise and extension: the cover calls name their display and the layer calls do not, so the per-frame path
  routes on what it already carries.
- **A raise fences on its own display, and a dismissal takes down its own cover.** `coverOnScreen(m)` entitles
  the reducer to teleport the windows *that* cover shows, so it is owed by that surface alone; a fence that
  never fires leaves the report unmade and that display's hold deadline to rescue it. A fence firing twice is
  dropped, as is one from a superseded raise — the generation idiom `Overlay.fadeOut` already uses, kept per
  display.
- **A batch goes to the capturer whose screen its cover is over.** A base is a photograph of one screen, so a
  head batch owes exactly one — its own — and a second display costs an ordinary transition nothing, neither a
  base nor the `SCShareableContent` fetch that comes with it. The still is not per display
  (`SCContentFilter(desktopIndependentWindow:)` is display-independent), but a window owed by two covers is
  filmed once *per cover*, which is what carries each destination overlay's backing scale — a still filmed at
  2× shown on a 1× overlay pops on the cross-fade. Photographing and cutting out of the base are one list
  again for the same reason: the windows a cover shows and the windows its own base must not contain are the
  same set.
- **The stills are one store with per-cover ownership.** A window two covers show is released by the last of
  them, so one cover coming down cannot blank a layer still on screen on the other display. A head batch that
  ends without its base abandons **its own** cover — `coverUnavailable(m)` — and the other screen's keeps
  running.

A surface builds a layer for every binding it is handed, and every binding it is handed is its own: a cover
belongs to one display, so the session that minted them named its monitor. A guide draws only the strips its
own monitor owns. Both are the same rule: a per-display thing asks a per-display question.

**The menu bar is the exception, because it is one item for a desktop of several.** `StatusModel.title` is a
single character and goes to the address the user is on; the rest go to the tooltip after it
(`StatusModel.elsewhere`, in enumeration order). One display leaves that string exactly what it was, which is
the absence of the others doing the work rather than a branch.

**The set is reconciled, not fixed.** `ScreenWatcher` folds
`NSApplication.didChangeScreenParametersNotification` into one reading of the displays, and the daemon's
`syncDisplays` matches the machinery to it: keep what still describes its display, build what does not,
retire the rest, and hand the result to the two containers that route by display (`Compositor.setSurfaces`,
`CaptureService.setCapturers`). Everything holding *those* — the executor, the runtime — is wired once and
never rebuilt. Four things follow:

- **Kept only on exact geometry.** A window frame, a base placement, a backing scale and a
  `CGDirectDisplayID` are all fixed at construction, so a display that merely changed resolution is as new
  as one just plugged in — and a moved flip line makes every display new, since every overlay frame is
  measured from it. Rebuilding is the cheap, boring option and it removes a whole class of half-updated
  state.
- **A retired surface stops being routable with its layers**, and its raise and dismiss generations move, so
  a fence or a fade still in flight on it reports nothing. A retired capturer's **base** goes with it: a
  photograph of a screen is the one thing in the store that cannot outlive its display.
- **The core takes every cover down first** (`State.setMonitors`), so each dismissal reaches the surface
  that raised it rather than one already replaced.
- **One clock, re-homed.** The fastest display can change or be unplugged, and a `CADisplayLink` for a
  screen that has gone never fires again, so `DisplayLinkDriver.retarget` invalidates and rebuilds — a
  transition in flight loses at most a frame.

**A display that leaves must still cost its own screen and no other**, in the window between macOS reporting
the change and anything acting on it. A departed display's capturer can produce no base at all and its
overlay fences a raise on a display link for a screen that is gone — so a head batch owing it a base would
abandon every cover, and a report gated on its fence would never come. Both consult a live `isAttached` and
leave it out. A dismissal is not gated that way: taking a cover down is always safe.

**One frame clock, on the fastest display attached.** `dt` is real elapsed time and the springs are analytic
in it, so a 60 Hz screen fed at 120 Hz simply drops frames while a 120 Hz screen fed at 60 Hz is visibly
under-driven — picking the fastest means nobody is ever the latter.

**What a second display costs.** An ordinary transition: nothing. It is covered, photographed and animated on
the screen it happens on, and the other display keeps its live pixels, its own scroll and its own cover's
schedule. Two covers at once cost two bases and two `SCShareableContent` fetches, which cannot be shared (the
type is not `Sendable`) — the honest price of two transitions, paid only when there are two.

**A raised cover holds `alpha 0.999`.** A window at full alpha marks everything beneath it _occluded_, and an
occluded app may stop feeding a separately-composited plane — a playing video comes back dark for the first
frame of the dissolve. Any alpha below 1 disqualifies a window from occluding; a thousandth is under one 8-bit
level.

**Hotkeys consume.** An `NSEvent` global monitor is available under the AX grant but cannot swallow the
keystroke, so `alt-h` would scroll the strip _and_ type into the focused app. Hence Carbon, for every chord it
can express — which is every chord without `fn`. **`fn` is not in the Carbon registry's vocabulary at any
width**: `EventModifiers` is a `UInt16` ending at `rightControlKey`, and `RegisterEventHotKey` matches on that
width, so a wider word carrying an invented fn bit registers with `noErr` and then answers to the _unmodified_
key — `fn-h` taking plain `h` from every app on the machine. `carbonFlags` returns `nil` rather than let that
reach the registry, and `SplitHotkeyBinder` routes the chord to `FunctionKeyTap` instead: a consuming
`CGEventTap`, created lazily so a config without `fn-` never makes one, and running **on its own thread**. That
last part is what answers the objection this paragraph would otherwise raise against a tap — matching reads a
locked snapshot and the hop to the main actor is `async` and happens after the decision to consume, so a main
actor blocked on AX cannot stall a keystroke. It needs no grant beyond Accessibility. A swallowed press is
remembered by key so its release is swallowed to match: `fn` is usually let go first, and a release matched on
the chord again would miss and hand the focused app a key-up whose key-down it never saw. The cost is a rule the
grammar has to carry: macOS marks the arrows, the F-keys and the nav cluster with the fn flag whether or not fn
is held, so `fn-left` would match the bare left arrow and `KeyChord.parse` refuses it by name. A hotkey manager is
an event **source**, not an effect — it belongs beside the socket server, and `Config.keys` is a value the
reducer never reads. **There are no default bindings**: a registered chord is taken from every application on
the machine, so a default is emira confiscating a keystroke nobody asked it to. That is also what puts `exec` in
the vocabulary — what emira takes, it must be able to give back.

**IPC is one `Request`, one `Reply`, then close.** Versioning is a **probe, not a decode**: `version` is a flat
top-level `Int` on both messages and `Wire.probeVersion` reads it _before_ decoding, so a peer from another
build gets a sentence instead of an undecodable envelope. `Reply.state` carries **opaque JSON**, so a CLI one
release behind still dumps a newer daemon's state. `dumpState` is a **read**, answered out of band straight off
`Runtime.state` — safe _because of_ invariant 4, since the socket's main-actor hop always lands between pumps.
All socket I/O runs on one private serial queue; the main thread never blocks on a client.

**The socket path is checked, never trusted.** `$TMPDIR/emira.sock` (per-user and `0700` by construction,
reboot-cleaned, short enough for `sun_path`), overridable via `EMIRA_SOCKET`. Bind only if nothing is there, or
if it is a socket we own with nobody answering. A regular file, another user's socket, or a live daemon is
refused **without deleting anything**.

**Teardown's order is the daemon's**, and it needs one thing from `WorldWatcher`: _our own writes are
observations_. A live watcher answers each cascade move by re-placing the window on the strip being dismantled,
and the two fight until the deadline. So every event source is silenced first — a latch on delivery, not an
unregistration of live `AXObserver`s.

**Both grants are required to _start_; only Accessibility is required to keep _running_.** Screen Recording
being non-fatal is the right response to macOS revoking it under a live daemon — killing the window manager
there would strand every parked window at its 1 px nub with nothing to put them back. Two asymmetries drive the
onboarding code and are easy to mistake for bugs: `AXIsProcessTrusted` answers freshly every call, while
`CGPreflightScreenCaptureAccess` is **cached for the life of the process** — which is why onboarding relaunches
the daemon's own executable with `--probe-capture` (same binary, same signature, same bundle identity, which is
what TCC records against) and why `GrantRow.refreshed()` is monotonic. And a grant given to a _running_ emira is
only half a grant, so onboarding ends in a deliberate restart rather than proceeding.

**The settings window is a target of its own, and the shell only raises it.** `EmiraSettings` sees the config
and the geometry; `ImportFenceTests` is what makes that a fact (§3). Four things cross the boundary: the shell
hands over the file's text, it is handed back text to write, it tells the window when the file changed
underneath it, and it is told when the composition has come off the screen. **Text to write and the window
closing are two crossings and not one**, because a caller told the window is gone is entitled to let go of it,
and a save leaves the window up.

- **The composition.** A scrim over **every** display — `NSVisualEffectView` at `.hudWindow` with
  `blendingMode = .behindWindow`, dimmed, at `CGShieldingWindowLevel() − 1` so it covers the menu bar and the
  Dock. `.underPageBackground` and `.windowBackground` are opaque and render as flat black with the blur
  working perfectly behind them, which is a silent failure and therefore a decision rather than a taste. The
  mock monitor and the control slab float on the scrim of the display holding the pointer.
- **It is set down on the desktop and lifted off it, and those are one animation run in either direction.**
  The whole composition dissolves while the stack it carries travels the last 4% of a zoom, from just above
  the glass on the way in and back above it on the way out — an arrival that reads as an object placed on the
  desktop rather than a window that appeared over it. The curve is symmetric, so the exit is the entrance
  backwards and not a second animation that happens to take the same time; a scale *above* one is what makes
  it a placement, since below one the same motion tells the opposite story. **A scrim cannot zoom** — its
  edges are the screen's, so a scaled one would show desktop down one side and crop the other — which is why
  the travel belongs to the stack and the dissolve to everything. `Stage` is that stack as one view: the
  stacking arithmetic, one transform about one centre, and a click in the space between the monitor and the
  slab still reaching the blur it looks like. Reduce Motion keeps the dissolve and drops the travel, which is
  what the preference asks a zoom to become rather than what it asks to be removed.
- **The preview is the reconstruction's projection at a third scale**, after the cover and the guide. One
  scalar, `k`, applied in `Projection.mock(_:)` and nowhere earlier: `LayoutMetrics` is built against the
  display's **true-point** working area and `naturalFrames` answers true-point rects, so an 8 pt gap is 8 pt of
  a real screen rather than 8 pt of a mock. A window's corner, its title bar and its stoplights are real
  dimensions projected the same way, or the chrome drifts from the layout at every other `k`.
- **A `Scene` is the set and a `Take` is the script over it**, keyed per **setting** rather than per section.
  The script is empty for most of them: a setting that *is* geometry re-derives with nothing playing, and a
  script is for behaviour — `focus right` has to happen for `focus.system-events` to mean anything. Several
  takes share one scene, so crossing between two settings in a section costs nothing at all. `Catalog` maps
  setting → take, and every schema entry must have one or be named on `notDemonstrable` with a reason.
  **The draft is an input to the catalog**, because a script's shape can be the value: a ladder take walks
  one beat per rung, so three widths typed is three beats and five is five, and a spring dial's loop is
  paced by the spring being edited (`Take.paced(by:)` over §8's own settle arithmetic). And a take
  answering `nil` means **hold the stage**, never cut to the section — a row with no picture must leave
  the setting above it on screen rather than tearing the mock away from it.
- **A setting that fires on an event is asked on the event, never held as an invariant.**
  `mouse.follows-focus` sends the pointer *when focus moves* — one `CGWarpMouseCursorPosition` — so
  `PreviewModel` asks it where focus has just changed and parks the cursor there. Asked every frame
  instead it stops being that setting and becomes "the cursor is always in the middle of the focused
  window", which pins the hand through every take that carries one: a scripted travel never appears to
  move, and a script walking a cursor to a window's *edge* holds it at that window's centre until
  something else takes the pointer over. The same reading applies to the fold itself — focus answering a
  hover is folded at every beat and not only at the end, because a command back to the window a hover
  already left is a focus change, and one the fold cannot see is a pointer that is never sent after it.
- **A script says what happened; the draft says what it did.** A beat asks for a cursor to be hidden, an
  event to be honoured, a swipe to carry, a tick to be drawn, a column to grow by a third of a screen —
  and `mouse.hide`, `focus.system-events`, `mouse.trackpad-scroll`, `layout.resize-detent` and the geometry
  decide. That split is what makes a rung whose answer is "nothing moves" a *refusal* rather than a preview
  that has stopped working, and it is why `Cue` has two states. It is also why a take may stage its own
  premise where a value the *user* owns would otherwise decide what the demonstration shows: a detent is a
  distance to the screen's edge, so `Scenes.detentPair` spends explicit widths rather than the draft's
  ladder, and the first press completes and the second catches whatever `width-presets` says.
- **The cue names the cause as a command**, spelled the way `[keys]` spells one — `focus right`, not
  `⌥L`. A chord is a fact about one user's keyboard and unreadable to anyone who has not bound it; the
  verb is what the beat is about, and it is text the reader can go and type. The exception is
  `focus.system-events`, whose whole subject is focus emira did *not* cause: there is no command to name,
  so it keeps `⌘⇥`, and the badge reading a foreign chord is itself the distinction. The spelling is held
  as a `String` because the import fence keeps `Command` out of `EmiraSettings` — `CueTests` parses every
  one back and checks it re-emits unchanged, which is where the two vocabularies are pinned together.
- **Three house rules are load-bearing in code**, and the comments that cite them say so by name.
  **Two motion vocabularies, never mixed** is why the camera has its own fixed curve in `CameraTravel`
  and the desktop has the draft's springs in `PreviewMotion`; a sludgy `movement.stiffness` must not be
  able to hide behind an equally sludgy lens. **A hand is not a spring** is `PreviewState.travel`:
  direct manipulation is modelled as a linear tween the view draws exactly, a warp is a jump because
  `CGWarpMouseCursorPosition` is one, and only machine motion springs. The rule is about the hand as an
  *input* — `scrub` and `dragEdge` track it 1:1 with nothing in between, and must. A hand being
  **animated** is the opposite case and takes `PreviewModel.reach`, the minimum-jerk profile a person
  reaching for something actually traces: a scripted cursor at a constant speed sets off and stops dead
  inside one frame, and what that reads as is a cursor that teleported and then slid. **Legibility is bought with
  the camera, never with a lie** is why `Camera.frame(containing:display:)` only ever *grows* a subject to
  the display's aspect, so a shot always contains whole the object the value is measured against — and
  why nothing on the mock is ever drawn larger than it is. What that object is, is the setting's to say:
  for a gap it is the two **edges** the number holds apart and not the two windows they belong to, which
  is what puts both gaps at the same push-in. **Life size is the
  ceiling**, and `Camera.maximumScale` is where the rule stops being a resolution and becomes arithmetic:
  no camera may draw one real point as more than one mock point. A gap is a length judged by eye — that
  *is* the demonstration — so at the cap a 40 pt gap is drawn at 40 points and the number in the field is
  the thing on the screen. The one framing allowed closer is the guide's own panel, and it is allowed
  because nothing read at it is a length: `style` is what a tile draws and `span` is how many there are.
  `guide.gap` is points, and it is framed by `guideCorner`, which keeps the cap.
- **The camera is a `Rect` inside the monitor's clip**, and a property of the *setting* rather than the
  section. `Projection.camera` is what `mock(_:)` maps through, so one number carries a push-in through a
  title bar, a corner radius and a shadow together; the bezel never moves, because a slab that grew would
  fight `Stage`'s own placement zoom. Crossing from `column-gap` to `window-gap` is then a pan, and the pan
  is the difference between the two settings: the same shot at the same distance, a right angle apart —
  the seam *between* two columns, and the seam *inside* one at a window's height centred on it.
- **The window says two things about the desktop, and both are answerable.** The **ring** is a claim that
  focus is part of what a setting is about, so `Take.showsFocus` turns it off for the six on the Layout tab
  that are pure geometry — a gap is the same number whichever window is focused, and a blue border on one
  of them is a subject the setting does not have for the eye to follow. The **mark** is `Mark.Drawn`, and
  there are exactly two: the gutter an outer gap holds open, filled, which at `0` collapses to the hairline
  that makes the row legible before anything is typed; and the flush tick, granted only where a column edge
  really has landed on a viewport edge. A gutter is drawn as a washed region inside an accent outline, and
  the wash is **measured**: it lies on the user's own desktop picture, so `Wallpaper.luminance(of:layer:)`
  samples the strip it covers and it flips black or white — the same question the mock menu bar asks, for
  the same reason. That is not a second accent; an accent stripe on an accent-coloured wallpaper is a
  stripe nobody can see.
- **A pane is one image.** `MockContent` draws a window's whole interior — band, stoplights, the app's icon
  and a suggestion of the app — in Core Graphics at true-point sizes rasterized at mock scale, and the pane
  paints that still into whatever rect it now occupies. The still is taken **on arrival and never in
  flight**, which is what the compositor does with a screenshot and what makes `animation.window` a
  `contentsGravity` rather than a second mechanism; the 80 ms cross-fade when it is taken again is the app
  catching up. The guide borrows the same image for `guide.style = preview`, which is the relationship the
  real guide has with the real cover rather than an imitation of it.
- **The panel is a fold, and the exception is a list rather than an omission.** Rows come off
  `ConfigSchema.settings` filtered by section; a bespoke surface has no `kind` for `ControlFactory` to switch
  on, so each editor it gets is written — `OuterGapsControl` is the one there is, four edges on one row because
  the file spells one value five ways and four rows would say the opposite. `BespokeEditors.notEditable` names
  the two with no editor and why, and `BespokeTests` requires one or the other. Both protocols exist for this:
  a `PanelRow` shows a draft, a `SettingControl` is a `PanelRow` that is exactly one setting.
- **The panel says it has more in it twice, and neither is a scroll bar.** Its scroller is half a row
  short of a whole number of them, so a row is always cut by the bottom edge rather than sitting flush
  with it — content, not chrome, and it survives someone who has turned scroll bars off. Over that, a
  gradient mask on the clip view dissolves the end that has more into the blur behind the slab, and
  **only** that end: both ends of a list that fits fade not at all, which is what makes it an
  affordance rather than a gradient. `ScrollFade` is the arithmetic and is tested; the layer is
  plumbing over it. The half is taken off the panel's height rather than added on — the mock, the gap
  and the slab are one centred stack, already close to a scaled display's height. Two inputs feed it
  and both are observed: the clip view's bounds for how far it is scrolled, the document view's frame
  for how much there is to scroll, which settles a layout pass after the rows go in. The mask is
  rewritten on every pass rather than when a remembered value moves — the layer is the fact, and a
  memory that says "already correct" while nothing is installed is a fade that never appears.
- **A section becomes a tab when it has something to show** — a setting, or a bespoke surface with an editor.
  `keys` and `windowRules` have neither and are not tabs. There is no springs section either: the four spring
  tables are eight advanced dials of `animation`, because a tab whose every row is behind the disclosure opens
  on a triangle and nothing else.
- **The scroll offset is a fold over the beats**, not a function of the final set: `offsetToReveal` is relative
  to where the strip already is, so a take that focuses right twice reveals from the offset the first one left
  — which is what the reducer does, one command at a time.
- **`PreviewMotion` is `Motion` with the sessions removed** — a `RectAnimator` per window and one for the
  guide's panel, and nothing else. Which spring carries a displacement follows the schema's own sentences: a
  coast after a trackpad lift is the glide spring, a size that changed is a resize, a pure translation is the
  viewport's if the viewport moved and the strip's own rearrangement if it did not. **The cursor is not here
  at all** — `PreviewModel` owns the whole of where one is, because a hand traces its own path and a
  warp arrives in a single frame, and neither is a spring. `animation.transition` is the *shape* of every
  arrival rather than its speed, and it governs every take rather than only its own: `snap` changes every
  frame at once, and `off` holds each window at its old frame for a fixed stagger and then jumps it.
- **Save writes the file and hot reload does the rest.** No route pushes a draft to the running daemon, so the
  preview and the desktop cannot hold different opinions. The write is checked against what is on disk first,
  because a comment-only edit changes the file without changing the `Config` the loader reports.
- **Hotkeys are suspended while it is up.** `RegisterEventHotKey` claims a chord at the window server, so a
  binding fires whatever is focused — with every display scrimmed that rearranges a desktop the user cannot
  see. `HotkeyManager` holds what to restore, since the daemon's copy of the config goes stale across a reload.
- **The mock takes no input, and absorbs it.** Nothing inside it is addressable — no hover, no focus, no drag
  — but a click lands on it and stops there rather than falling through to the scrim. Those are two different
  properties and the difference is dismissal: the mock is what the user is looking at, so a click on it must
  not be a click on the blur behind it. Dismissing is Escape, or a **double** click on the blur; a single one
  is too easy to spend by accident on a window covering every display, and what it costs is an edit.
- **The composition owns itself while it is on screen**, from the scrims being ordered in to `close()`. The
  reference the shell keeps is for *talking* to the window — a second `⌘,`, a file that changed — and
  `dismiss()` is what ends one, since a release cannot. What that rules out is not a leak: AppKit owns a
  window that is ordered in, so a dropped last reference leaves every display dim with each callback into a
  `nil weak self` behind it, answering neither Escape nor a click, and the chords resumed because the shell
  was told it had gone. Beneath that, the two ways down answer even when there is nobody to ask:
  `ScrimWindow.tearDownOrphans()` takes the scrims off the screen, and it is every scrim rather than the one
  that was pressed on because they are one thing to whoever is looking at them. `close()` is one-way for the
  same reason the count is two — a quadruple click is three dismissals — and `DismissalTests` holds both the
  threshold and the answer of last resort.

---

## 8. Cross-cutting rules

- **Concurrency.** `@MainActor` pins the Runtime, core state, and all CA/overlay work; Swift 6 strict
  concurrency then _proves_ nothing mutates it off-thread. The only off-thread work is AX (serial per-app GCD
  lanes, marshaled back) and capture (its own queue). Nothing in the effect path is `async`, so nothing can
  suspend the pump.
- **One `AXClient` for the whole daemon.** The per-app lanes are only serial if the enumerator, the writer and
  the observers all queue onto the same ones. A lane is dropped for exactly one reason — the app quit, so its
  application element holds a port to a dead process. Dropping one for any lesser reason is worse than keeping
  it: work already queued runs on, and the next call mints a second queue beside it. So a failed observer
  registration releases the observer alone, which matters because the standing check retries one forever.
- **Platform floor: macOS 26.** Greenfield with no users, so take the newest floor and use the current API
  surface everywhere — `CADisplayLink` via `NSScreen.displayLink` unconditionally, modern ScreenCaptureKit
  throughout, no `@available` checks and no legacy paths. Revisit for a concrete tester need, never
  speculatively.
- **No pixels in the core's vocabulary.** `Effect.capture(win, size:)` is answered by `Event.captureReady(win)`
  — ids, never image payloads. The shell owns the image store, keyed by `WindowId`.
- **Coordinate spaces: the Y-flip happens exactly once**, at the **Cocoa** boundary
  (`Compositor/ScreenGeometry.swift`), whose only customers are the overlay and `NSScreen` enumeration. AX's
  global space **is** the core's space (top-left origin at the primary display's top-left), so `AXAccess` copies
  frames across with no arithmetic at all. The pointer plane is in the same position — `CGEvent.location` and
  `CGWarpMouseCursorPosition` both speak that space — and the comment there says so, because every _other_ seam
  in the shell flips and a boundary that doesn't is worth a line.
- **Settle tolerance is point-valued and lives in `EmiraCore`.** `EmiraMotion`'s `1e-3` is right for a
  unit-agnostic scalar solver and wrong for the strip: a spring's tail decays exponentially, so on a 900-point
  scroll the last thousandth of a point costs about as long as the first 900 and the cover outstays the motion.
  `Motion` supplies a sub-pixel position epsilon plus a velocity bound; position is the criterion, and the
  velocity bound exists only so an underdamped spring can't be called settled while streaking through target.
- **Feel is a calculation, not a taste.** For a critically-damped spring the remaining distance is
  `D(1 + ωt)e^(−ωt)`, so settle time is `u/ω` where `(1 + u)e^(−u) = ε/D`. Pick the duration, solve for
  stiffness.
- **Smoothness needs its own instrument.** `Spring` is analytic, so it lands on the correct position for any
  `dt` — a six-frame lurching scroll and a 76-frame fluid one trace the _same_ offset-vs-wall-clock curve, and
  no amount of `emira debug` polling tells them apart (worse, polling perturbs the subject). So
  **frames-per-transition** is reported permanently on cover dismissal, with the capture head stitched in by the
  daemon: `41 frames in 336 ms (122 fps); 145 ms capture head → 481 ms`.
- **Observability.** `emira debug` dumps the live `State` as JSON over the socket; `os_log` behind a small
  `Logging` wrapper; the daemon logs every command, key press, capture batch and transition to stderr. Note that
  a bundled app's stderr goes nowhere — reading `capture:` / `transition:` lines means running the daemon from a
  terminal.
- **Deterministic replay is a property the architecture has, not a feature that is built.** `reduce` is pure and
  `Event` is `Codable`, so a log of inbound events replays exactly; the reducer suites already exploit this by
  driving scripted event sequences. There is no on-disk event log and no trace flag.

---

## 9. Config

**TOML**, at `~/.config/emira/emira.toml` (override: `EMIRA_CONFIG`).

The split is the one §3 states: the **values** are a pure `Config` struct in `EmiraCore` because the reducer
reads them; the **format** — grammar, schema, path — is `EmiraConfig`, and `String → Config` is pure by
construction. The shell owns only reading and watching.

**`emira.example.toml` is the config surface**, generated from `ConfigSchema.document` and pinned by a golden
test. Read it rather than a list here; `make example` regenerates it, and the diff a human reads is `git diff`.
The variable it uses (`EMIRA_UPDATE_GOLDEN`) is opt-in and CI never sets it — a suite that repaired itself on
the way past would answer differently on a second run.

**The schema is a table, not a procedure.** One `Setting` per key, each carrying its spelling, its sentence, its
legal values, and a codec that moves the value between file and `Config` field. Reading is a loop over it; the
example document is a render of it; `emira config explain` prints it; the settings window **lays it out**. Four
consumers off one list, so nothing describing a setting is written down twice — and `Setting.Kind` carries the
rule that makes the fourth cheap: one case per shape of control, never per setting.

**Setting something to its default unsets it.** An absent key already means the default, and a file that writes
it down pins it against ever changing. The fork lives on `ConfigDocument.set(_ setting:to:)` rather than at a
call site, because a `Setting` is what knows its own default and a bare key does not — and two consumers now
write settings. `setOrUnset(_ key:to:)` is the same rule for a key whose default is **not a constant**: a
per-side outer gap defaults to whatever `outer-gap` says two lines up, so what a line would be redundant with is
found by taking it out and reading again rather than by asking the key.

**Unknown keys are refused, and there is no second list of valid names.** The reader _takes_ each key the schema
knows and reports whatever is left, so "which keys are valid" _is_ the reading code. A declared-but-empty
`[layuot]` is caught too. Silence is the failure mode that matters: a window manager that ignores `colum-gap` is
one the user believes is broken.

**The three the table can't describe are still a list.** `outer-gap` (one logical value with five spellings),
`[keys]` (an open table whose names the user invents) and `[[window-rules]]` (repeating, ordered,
cross-validated) each keep a hand-written reader — but they are on `ConfigSchema.bespoke`, carrying a label, a
sentence, a section, the documentation block, a sample that disagrees with the default, and the reason the table
cannot hold them. Every consumer that walks `settings` has to decide what to do about these three, and before
the list they each decided by hand: the generated document placed three named constants, the coverage test
spelled three fragments into a string, and the settings window did nothing at all — which is how `outer-gap`
came to have no control without anyone choosing that. `after` names the key a surface is written
directly behind, and the document and the panel both read it, so the three gaps are together in both. A test pins that every stored property of `Config` is
covered by an entry, claimed by a surface on that list, or on an explicit not-a-key list, so a new field cannot
be added without a config story; `EmiraSettings` pins the second half, that a surface either builds an editor or
is named with the reason it has none (§7).

**Writing goes back through `ConfigDocument`, not through serializing.** It holds the text beside its parse and
changes one value by splicing over the bytes that value occupies, so a file keeps its comments, ordering and
blank lines. It renders a `String`; the write is the caller's, which keeps the package free of I/O.

**Three rules about a file that isn't what we hoped:**

- **missing** → `Config()`, not an error. emira must run before it is configured.
- **broken on reload** → changes _nothing_, and reports `path:line: message`. Falling back to defaults would
  rearrange a whole desktop as the side effect of a typo, at the moment the user is least able to tell why.
- **broken at boot** → emira manages _nothing_. "Keep what you had" needs something to keep; at boot there is
  none, and adopting the whole desktop under defaults nobody wrote is indistinguishable from emira working. So
  the daemon prompts for both grants, raises the `!` menu-bar item, and leaves the desktop as it found it. The
  first save that parses starts the truth plane, the keyboard and the scan.

**Hot reload watches the file _and_ its directory, and the parsed value is the filter.** An atomic save is a
_directory_ event that kills any file-level watch along with the inode; an in-place rewrite is a _file_ event
the directory never sees. And because a directory watch wakes on any activity, what is reported is a change in
the **parsed `Config`**, not a change to the file.

**Two functions the daemon owns, and both matter for correctness:**

- **`applyEnvironment`** — the values a file may not decide, all four of them capabilities rather than
  preferences. `transitionMode` is a preference answerable to the Screen
  Recording _capability_ (no grant ⇒ `off`; `snap` is out of reach exactly as `smooth` is, both being made of
  captured pixels). `hidesCursor` needs two conjuncts — the private cursor property resolves _and_ the pointer
  motion monitor installed — because the only exit from a hidden pointer is seeing the mouse move, and emira
  will not enter a state it has no exit from. `focusFollowsMouse` shares that second conjunct. `trackpadScroll`
  needs a cover to run under and a tap to listen through, and **its position in the function is load-bearing**:
  it reads the _post-clamp_ `transitionMode`, or a machine with no grant would keep a live gesture with nowhere
  for a 120 Hz scroll to happen. One clamp feeding another is why that line goes last rather than beside the
  grant check it depends on. A setting asked for and clamped away is logged once. **The
  struts are not here**: they are per display and they move under a running daemon (the Dock changes edge),
  so they ride on `Event.screensChanged` beside the frame they inset rather than through `Config`.
- **`applyShellConfig`** — the values that reach the shell rather than the reducer (`windowAnimation`,
  `coverMode`, `transitionMode`, the kept stills, the pointer rung and its monitor, the gesture tap). One
  function, called at launch and again from `ConfigLoader.onLoad`. Two call sites assigning a property each is
  where "the reducer and the shell read the same post-`applyEnvironment` value" goes quietly false. Two
  observations are gated here rather than left standing, and for one reason: each fires at its device's own
  rate for as long as it is installed, so neither the pointer's motion monitor nor the trackpad's tap is
  installed for a setting nobody turned on.

`main.swift` defines `applyShellConfig` _below_ everything it writes to, and that is a language fact rather than
a style: top-level `let`s are initialized in execution order and are **not** lazy, so a function declared above a
global it reaches compiles clean and reads zeroed memory if called early.

---

## 10. Directory map

```
emira/
├── Package.swift · Makefile · emira.example.toml (generated, golden)
├── .github/workflows/{ci,release}.yml   ci: build+test on macos-26 · release: tip + v* + cask bump
├── .github/demo/                        the README's film: demo.sh + caption.swift + screencapture
├── .agents/{README,PRINCIPLES,IMPLEMENTATION}.md + changes/<epoch>.md
├── Resources/Info.plist                 LSUIElement=YES + a stable CFBundleIdentifier (TCC keys on it)
├── Resources/emira.icon/                layered icon; `make icon` compiles it to Assets.car
└── Sources/
    ├── EmiraMotion/     Curve · Spring (analytic, closed-form) · Animator
    ├── EmiraCore/       Geometry · Ids · WorkspaceName · Command · CommandSyntax · KeyChord
    │                    Event · Effect · Config · Rules · Engine · GuideModel (pure)
    │   ├── State/       World · Monitors · Motion · RectAnimator · Pointer · Drag · TrackpadScroll
    │   └── Layout/      Layout · Workspaces · Strip · Column · Presets · Cascade · Park
    ├── EmiraConfig/     TOML · ConfigSchema · ConfigSyntax · ConfigExample · ConfigExplain
    │                    ConfigDocument · ConfigPath
    ├── EmiraProtocol/   Request · Reply · Wire (framing + probe) · SocketClient
    ├── EmiraSettings/   Draft · Scene · Take · Catalog · PreviewModel · PreviewMotion (pure)
    │                    Camera (the lens + the marks) · Cue (the input badge) · GuidePreview
    │                    Projection (the one number) · Wallpaper
    │                    SettingsWindow (the scrim) · Stage · DesktopView · MockContent · CueLayer
    │                    MockMenuBar · MockIcons
    │                    ControlSlab (+ ScrollFade) · Controls · Bespoke · PreviewClock
    │                    SettingsStyle · Environment
    ├── EmiraShell/      Runtime · Executor · WindowRegistry · WorldWatcher · Teardown
    │                    ProcessLauncher · Scheduler · Permissions · Logging
    │   ├── AX/          AXAccess · AXClient · AXEnumerator · AXWriter · AXExecutor
    │   │                Observation · AXObservers · FocusIntent · EnhancedUI
    │   ├── Capture/     CaptureService · SurfaceCache · SCKCapturer
    │   ├── Compositor/  ScreenGeometry (THE Y-flip) · Overlay · Reconstruction (one per display)
    │   │                Compositor (the plane: one frame, and the layer route) · CompositingExecutor
    │   ├── Guide/       GuidePanel · RoundedLayer · GuideIcons · Guide
    │   ├── Pointer/     CursorConnection · PointerExecutor · PointerFocus · PointerWake · PointerSamples
    │   ├── Display/     FrameClock · DisplayLinkDriver · HoldTimer · ScreenWatcher
    │   ├── Input/       Hotkeys (policy) · CarbonHotkeys · FunctionKeyTap · Gestures (policy) · GestureTap
    │   ├── Config/      ConfigLoader · ConfigFile
    │   ├── Ipc/         SocketServer · RequestRouter
    │   ├── MenuBar/     StatusItem — StatusModel (pure) + LoginItem + MenuBarItem
    │   ├── Onboarding/  Onboarding (policy) · OnboardingWindow · Wordmark · PulseButton
    │   └── Resources/   logo.webp — a resource of the target that draws it, so `Bundle.module`
    │                    resolves in a bare `swift build` tree too
    ├── emira-daemon/main.swift   accessory NSApplication; the wiring. Also answers `--probe-capture`
    └── emira/           main.swift (argv → Command → socket) · ConfigCommand.swift (straight to file)
```

Two spellings that recur and are worth recognising: `X` / `XSyntax` separates a value from its surface
spelling (`Command`/`CommandSyntax`, `Config`/`ConfigSyntax`), and every framework-touching subsystem is a pure
_model_ plus an AppKit _panel_ (`GuideModel`/`GuidePanel`, `StatusModel`/`MenuBarItem`,
`OnboardingModel`/`OnboardingWindow`), so the interesting half is testable with no window server.

---

## 11. Testing

`make test` — **not** bare `swift test`. On a CommandLineTools-only machine SwiftPM doesn't wire Swift Testing's
macro plugin into the explicit-module test build; the Makefile detects that and adds the flags (and filters
SwiftPM's own bogus linker search-path warnings). Under a full Xcode the flags stay empty.

The architecture exists to make testing cheap, so the pyramid is weighted at the bottom:

- **`EmiraMotionTests`** — `SpringTests`, `AnimatorTests`, `EasingTests`: feed synthetic `dt`, assert
  convergence, no overshoot past tolerance, and that `retarget()` preserves velocity.
- **`EmiraCoreTests` / layout** — `StripTests` (scroll math, visibility, detents), `PresetTests`, `ColumnTests`
  (height water-fill and its bounds), `ParkTests`, `LayoutTests`, `WorkspaceTests`, `MonitorTests`,
  `OuterGapTests`, `CascadeTests`, `GeometryTests`. One suite per question. Pure, fast, exhaustive.

  `MonitorTests`, `MonitorCommandTests` and the reducer's `MonitorSessionTests` earn their place the way
  `WorkspaceTests` does: everything they assert — an address orphaned by a departure, the assignments a lid
  close and a replug have to survive, a cover that stays on its own screen, a window held back while *its*
  display is mid-capture, a `MonitorRef` with more than one answer, a `next` that steps over another
  screen's addresses — is a **silent** failure while there is one display, so this is the only place any of
  it can be proved at all.
- **`EmiraCoreTests` / the reducer** — `EngineArrivalTests`, `EngineFocusTests`, `EngineWindowOpTests`,
  `EngineTransitionTests`, `EngineResizeTests`, `EngineHandResizeTests`, `EngineFullscreenTests`,
  `EngineRefusalTests`,
  `EngineStructuralEditTests`, `EnginePointerTests`, `EngineWarpTests`, `EngineConfigReplayTests`,
  `MonitorSessionTests`, `GuideRingTests`, `SystemFocusEventTests`, `TransitionModeTests`,
  `WorkspaceCommandTests`, `RulesTests`,
  `GhostWindowTests` — all over the shared scripted world in **`EngineFix`**. A fixture there is just a way of
  saying "a desktop in this shape"; the scenarios that motivated the whole design are written as scripts:

  ```
  moveWindow(A, right); tick×3; focus(right); moveWindow(B, right); tick×N
    → assert: A's animator retargeted from its in-flight position with velocity preserved,
              B animating, exactly one transition session open, correct final targets,
              setFrame effects emitted for both, endTransition only after both axLanded.
  ```

- **`EmiraConfigTests`** — the grammar and schema (every diagnostic, by line number), the document model
  (round-trip identity over a corpus), and the schema as text (every entry reads back whatever it prints, and
  `emira.example.toml` matches its golden).
- **`EmiraProtocolTests`** — envelope round-trips, framing, version mismatch in both directions.
- **`EmiraSettingsTests`** — the draft (an edit as text, unset-on-default, a refusal that does not land), the
  preview's geometry against `Layout`'s own, a take's arrangement at a given `t`, which spring drives which
  quantity, the wallpaper's luminance under the menu bar, the guide preview's panel, and — for each take that
  is a *demonstration* rather than geometry — the assertion the setting turns on: that the focus ring
  transfers on the frame the cursor crosses the seam, that the three `system-events` rungs answer three
  different patterns of taken and declined, that a magnet settles flush and `free` plainly does not, that a
  detent catches on the second growth and lets the third past, that a drag's neighbours do not move and the
  last 500 ms are opposite between the two rungs, that `snap`, `smooth` and `off` are three different
  pictures, and that the guide is raised by motion and lowered by `duration`. Plus the three claims that
  are really about the schema: every setting builds a control, every setting is demonstrated by a take or named
  on `Catalog.notDemonstrable`, and every bespoke surface builds an editor or is named on
  `BespokeEditors.notEditable`. `BespokeTests` also drives the outer-gap editor end to end — a side that
  matches the base key it resolves against is not written down, and one set back to what the file already means
  takes its line out again. `ScrollFadeTests` covers the scroll affordance: which end fades and by how much,
  and — off a laid-out slab — that the scroller is still half a row short of a whole number of them.
  `StageTests` pins the presentation: the zoom holds the composition's centre whatever anchor point the
  backing layer carries, a corner travels its own distance from it, the stack is the stage's own bounds, and
  the gap between the monitor and the slab still answers the scrim. Plus `ImportFenceTests`, which is what makes the target's boundary a fact rather
  than an intention. No window server anywhere — a control is a view tree, and building one is free.
- **`EmiraShellTests`** — the pump (FIFO / non-re-entrancy / clock gating), the IPC seam over a real socket,
  identity (`GhostIdentityTests`, `NativeTabTests`), the write path, the truth plane, capture (including the
  per-display covers in `MultiDisplayCaptureTests`), compositing (including the routing and the per-display
  raise fence in `CompositorTests`), the pointer plane, the guide's tile (`GuideTileTests` drives
  `RoundedLayer` against a detached `CALayer`), hotkeys — including that `suspend`/`resume` hands every chord
  back while the settings window is up — config loading, onboarding, teardown.
  Everything runs against the seams in §7 — the shell's untestable calls are one file deep at every boundary.

The reducer suites run with **`MockExecutor`**, which records effects instead of touching macOS: the entire
interrupt/retarget brain is verified with no AX, CA or SCK in sight.

**What the suite does not cover**, and what therefore needs the daemon actually running: anything about the
window server (whether a cover composed before a teleport, whether a warp posts an event, what an app does with
a size it dislikes), and anything visual. Per `CLAUDE.md`: running the daemon and moving windows is never an
interruption.

---

## 12. Build & release

`make build` · `make test` · `make app` (assembles `dist/emira.app`) · `make dist` · `make install`.

- **The app _is_ the daemon** — one process, one bundle identity, no launchd job. The daemon has been an
  accessory `NSApplication` since the overlay existed (it needs a window server connection and a running app for
  `CADisplayLink`), so anything put under launchd would be this same GUI process. Launch-at-login is
  `SMAppService.mainApp`, and "Quit stops the daemon" comes free. The one thing given up is crash-respawn.
- **TCC records a grant against the code signature of what runs**, so grant stability _is_ product stability.
  Ad-hoc signing identifies the app by cdhash, which changes every build, so macOS re-asks on every rebuild
  until a Developer ID signature replaces it.
- **The git tag is the only version authority.** No file in the tree carries a version number. `make app` asks
  `git describe` and stamps the answer into the bundle's _copy_ of `Info.plist`; the source file keeps `0.0.0`,
  which is what a build from a tarball honestly is. Run out of `.build` there is no bundle and `emira --version`
  says `dev`.
- **Two channels, one of them a release.** A push to `main` force-moves the `tip` tag and updates one long-lived
  **prerelease** with a stable asset name, so its download URL is a permalink. A human pushing a `v*` tag cuts
  the versioned release. Machines never decide a version. A tagged release also bumps the Homebrew cask in the
  tap; `tip` deliberately cannot have one, since its asset is clobbered in place.
- **The CLI ships inside the bundle and nothing symlinks it**, so there is exactly one copy of the wire protocol
  on the machine. Putting it on `$PATH` is the cask's `binary` stanza pointing into the bundle.
- Archives are `ditto -c -k --keepParent`, never `zip` (which mangles symlinks, xattrs and the signature).
  Builds are arm64 only — the platform floor is macOS 26 and `macos-26` runners are Apple Silicon.
