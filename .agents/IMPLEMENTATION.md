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
  · AX observation  │   State = World (truth) + Workspaces (structure) │   · capture               [SCK]
  · display tick dt │           + Motion + Config + Pointer            │   · begin/endTransition   [CA]
  · config reload   │                                                  │   · setLayerFrame         [CA]
                    └──────────────────────────────────────────────────┘   · setCursorHidden/warp  [CG]
                             ▲                              │              · exec                  [sh]
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
the pump at the refresh rate that isn't a tick (raw pointer samples are filtered into one `pointerEntered`
crossing _outside_ the pump), and nothing that displays state may be an `Event`.

**`Effect` is the output vocabulary**, grouped by the plane that executes it (§4). Adding one means assigning it
a plane in `CompositingExecutor.plane(of:)`, which is exhaustive on purpose.

---

## 3. Module graph & where things go

Five library targets and two executables. Dependencies point strictly upward; nothing below imports a framework.

```
EmiraMotion     pure math — springs, easing curves, the scalar Animator.  (zero deps)
    ▲
EmiraCore       pure — geometry, ids, Command/Event/Effect, State, layout engine,
    │           rules, Config values, the Engine reducer.        (deps: EmiraMotion)
    ▲
   ├── EmiraProtocol   Codable request/reply envelope, wire framing, one-shot socket client.
   └── EmiraConfig     pure — the TOML grammar and the config schema; text ⇄ `Config`.
    ▲
EmiraShell      imperative — Runtime, Executor, AX, Capture, Compositor, Guide, Pointer,
    │           Display, Hotkeys, ConfigLoader, IPC, MenuBar, Onboarding, Teardown.
    │  (deps: EmiraCore, EmiraConfig, EmiraProtocol; imports AppKit/QuartzCore/SCK/AX/Carbon/CG)
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
  └─ syncTimeSources()                 ← start/stop the frame clock, arm/cancel the hold deadline
  └─ onStateChanged(state)             ← once per *drain*, for peripherals that display state
```

**Event sources** all hold an `EventSink` — a `Sendable` struct wrapping a `@MainActor` closure with a weak
capture, so nothing in the shell owns or outlives the pump, and the "cross a thread to get here, deliver on the
main actor" AX boundary is expressed once in one type. The sources are:

`WorldWatcher` (AX observers + `NSWorkspace`) · `DisplayLinkDriver` (ticks) · `HotkeyManager` (Carbon) ·
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

- **Idle.** Anything that moves no windows on screen — a focus change that doesn't scroll, a display change, a
  config reload — is executed as direct AX sets. Plain `setFrame` / `park` / `focus`, snap, no cover.
- **Transition.** Anything that moves the strip opens a _session_, including motion nobody asked emira for:
  externally-initiated focus (Cmd-Tab, a Dock click, an app activating itself) reveals its window exactly as the
  `focus` command does.

### The phase machine

`TransitionSession.Phase` is `.capturing → .raising → .covered`, and **only the last lets a real window move.**

```
command
  └─ Effect.capture(win, size:) per scoped window     phase = .capturing
       └─ Event.captureReady × n   (all in ⇒)
            └─ Effect.beginTransition(bindings)       phase = .raising
               + elevateLayer + setLayerFrame
                 └─ Event.coverOnScreen               phase = .covered
                      └─ teleport the reals behind the cover  ← the ONLY teleport batch
                           └─ Event.tick(dt) × N  →  Effect.setLayerFrame
                                └─ animators settled AND every scoped axLanded
                                     └─ Effect.endTransition → Event.crossfadeDone
```

**Why the raise is two steps.** `beginTransition` reaches the window server synchronously, but the display
composes on its own schedule, and an app fast enough to answer an AX set inside that interval would move in the
open. Emission order cannot close that — ordering our own calls says nothing about whose pixels the window
server has ready. So the shell fences the raise against the display itself (`CADisplayLink.targetTimestamp`, two
callbacks) and reports `coverOnScreen`, which is the only thing advancing the phase and the only batch a
teleport rides in. `.raising` answers the truth plane exactly as `.capturing` does — `reassertTruthPlane` writes
nothing — so an unrelated event landing inside the window cannot write there either.

### The close gate, and its bound

A session closes when **both** halves are answered: the animators have settled, _and_ every scoped window has
reported `axLanded`. The landing wait is **scoped and bounded**:

- **Scoped** to every window the viewport _sweeps_ between its start and end offsets — departing windows count,
  because a failed park leaves a window squatting in view. Only park→park motion is invisible and skippable.
- **Bounded** by `[animation] hold-timeout` (1 s), itself just an `Event`: reveal the truth, keep retrying the
  AX set, reconcile when it lands. A frozen cover is worse than a visibly hung app.

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

### Degradation — every exit owes a placement

| Event               | Meaning                                | Response                                                |
| ------------------- | -------------------------------------- | ------------------------------------------------------- |
| `holdTimeout`       | an AX set never landed                 | close, `endTransition`, re-place                        |
| `coverUnavailable`  | the capture plane produced no base     | abandon **before anything moved**, snap                 |
| `axFailed`          | the app refused or timed out the write | mark the window's frame unverified, resolve its landing |
| `abandonTransition` | a switch handed no before-geometry     | close, with `finishStructuralEdit` placing behind it    |

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
State = World         // truth: monitors, apps, windows, focus, frames, corrections, placedOnScreen
      + Workspaces    // structure: 36 strips, which is focused, the shared ColumnId allocator
      + Motion        // animation: viewport offset, column widths, per-window displacement, the session
      + Config        // the parsed values the reducer reads
      + Pointer       // intent the shell is owed: a pending warp, a wanted hide
```

`State.layout` is a **settable computed projection** of the focused strip — single storage, not a second
authority. Only the genuinely cross-strip queries bypass it: reconcile, `targetFrames`, the placement walks, and
the mutators that mint a `ColumnId`.

`Pointer` is separate from `World` because every field of `World` is refreshed by observation and these cannot
be: no public API reports cursor visibility, and the window server discards a background hide on activation
without saying so. A record nothing can refresh is a wish, and holding it as one is what makes a hide an
assertion that is re-made rather than a latch that refuses.

### The four animated quantities

Never two authorities on one number.

1. **Scroll** — the viewport offset, one scalar, with every layer frame derived from it. Lockstep is structural
   rather than maintained; a retarget is one number. Also the natural handle for trackpad gestures.
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

**Width resolution is a stack**: `fullscreen` shadows an explicit `widthOverride` (from `grow`/`shrink`) shadows
a preset index (from `cycle-width`). Because it shadows rather than replaces, the width underneath needs no
memory and no restore policy. Percentages are of the **working area**, not of the column's own width, so
`grow`/`shrink` are exact inverses.

**What an app answered is a fact the geometry consults** — `World.corrections`, one `SizeCorrection
{ wanted, actual }` per window, keyed on the _question_ rather than stored as a `minWidth`, so a refusal at one
preset cannot ratchet every other preset forever. Corrections ride in `LayoutMetrics`, which is the load-bearing
placement: every geometry entry point already takes `metrics`, so a call site cannot forget one — and it must
reach all of them, or `targetFrames` and the visibility/sweep/scroll queries accumulate different left edges.

`World.parkFloors` is the same shape on the park path, and deliberately separate: a park answer says nothing
about _size_ (a window refuses at a sliver what it accepts in view) and one thing about the window's _chrome_.

**Ids are never reused.** `WindowId`, `ColumnId`, `LayerId` are minted once and retired; a dead window's cache
entry is unreachable rather than wrong, and a `Fullscreen` record naming a vanished `ColumnId` is simply not
applied. Staleness is unrepresentable rather than detected. New `ColumnId`s are minted **only inside `Layout`**,
from one allocator shared by all 36 strips — a re-issued id is the key `Motion.columnWidths` and the cover's
animation identity hang on.

### Workspaces

36 addresses in **key** order (`1`–`9`, `0`, then `a`–`z`), a fixed named domain rather than minted tokens.
One focused, the rest parked in full. Nothing persists across restart.

- **A switch is `focused` moving plus a placement pass.** "Everything not focused is parked" was already what
  `targetFrames` meant, so the verbs needed no new `Effect` and nothing in `EmiraShell`. What they needed was
  _memory_: each strip's scroll offset and last-focused window.
- **One park-ordinal run across the whole set**, threaded as a cursor — per-strip ordinals would give two
  windows the same nub, breaking the identity join and the no-overlap invariant silently.
- **The vertical term is a _sign_, not a distance** (`Workspaces.verticalOffset`): every unfocused workspace
  sits exactly one screen away, so `1 → z` animates the same screen as `1 → 2`. Presentation-plane only — on the
  truth plane an off-workspace window is simply parked.
- **The cross-strip move is one call**, because the decomposition passes through a state with a window on _no_
  strip, where a placement pass landing in between leaves a real window wherever it happens to be.

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
native-fullscreen windows are excluded; minimized and Cmd-H-hidden windows leave the strip, animated out like a
close, position remembered.

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
| `Compositor/`             | the overlay window, the layered reconstruction, the Y-flip, plane routing                                | `CoverSurface`                                      |
| `Guide/`                  | the transient minimap; `GuideModel` is the arithmetic, `GuidePanel` the AppKit                           | `GuideModel` is pure                                |
| `Pointer/`                | hide/show, warp, and the two sample readers                                                              | `CursorSurface`                                     |
| `Display/`                | `CADisplayLink` → `tick(dt)`, and the hold deadline                                                      | `FrameClock`, `HoldTimer`                           |
| `Input/`                  | Carbon `RegisterEventHotKey`; a press produces `Event.command`                                           | `HotkeyBinder`                                      |
| `Config/`                 | the half that needs a disk: read → watch → report                                                        | `FileWatcher`                                       |
| `Ipc/`                    | unix socket, JSON-lines, `Request` → `Reply`                                                             | a real socket, in-test                              |
| `MenuBar/`, `Onboarding/` | the two GUIs; the policy half of each is pure                                                            | `StatusModel`, `OnboardingModel`                    |
| `Teardown.swift`          | the exit path: place the quit cascade, wait, bounded                                                     | `WindowWriter`                                      |

A few facts that a change is likely to trip over:

**AX hygiene is not optional, and most "slow AX" pain is self-inflicted.** Five rules, each of which a change
can quietly break:

- **Touch as little of the tree as possible.** Chromium/Electron and JVM apps spin up a _heavyweight_
  accessibility engine the moment a client touches their tree, which slows the whole app. Fetch window-level
  elements only, cache `AXUIElementRef`s, never walk children, and don't re-query what an observer already
  reports.
- **The `kAXEnhancedUserInterface` bug.** With it on (Chromium/Electron enable it), `setFrame` gets animated and
  positions come out offset. Toggle it off immediately before a set and restore after — read before written,
  never introduced to an app that didn't have it, never left off.
- **Never block our own run loop.** AX setters are synchronous Mach IPC. They run off the main thread on serial
  per-app lanes under a short `AXUIElementSetMessagingTimeout`, which protects _us_ and does nothing for the app.
- **Expect clamping.** Apps clamp to their own min/max, so landing exactly can take size → position → size. What
  an app answered is then a fact the geometry consults (`World.corrections`, §6) rather than something re-asked.
- **The window classifier is failable.** `kAXWindowsAttribute` is not a list of windows — Finder answers it with
  the desktop. An unrecognized **role** means "not a window" and is dropped at the AX boundary; an unrecognized
  **subrole** means "a real window we leave alone".

**AX identity is the fragile part.** A match must be **unique in both directions** within 2 pt or it is not a
match — a nearest-position match always answers, and a wrong answer is permanent and invisible. Two joins run on
the same scan against the same two lists: `WindowIdentity.bind` (which window-list entry is this AX window) and
`WindowIdentity.succeed` (which arriving window is standing where a departed one stood). Both are pure.

**`WindowRegistry.rebind` is the only thing that re-points a binding**, and it buys native tab groups: keeping
the `WindowId` makes a tab switch _unobservable to the core_, so the column, its width, its workspace and its
float state survive one without a single `Event`. Three maps move together or the seam leaks — number, element,
and the record's element. A destroy notification therefore **waits for one scan** before retiring an id.

**A batch is grouped into one lane job per app**, not one per window: the reducer emits placements in layout
order, which interleaves apps, and grouping collapses N lane hops and N enhanced-UI toggles into one. The
enhanced-UI flag is **read before it is written** and restored after — never introduced to an app that didn't
have it, never left off.

**A reconciliation heartbeat is the standing check behind all of it** (`WorldWatcher.reconcile`, every 3 s).
Everything else is edge-triggered, so a missed discovery is a window unmanaged for the life of the daemon,
silently. The list is a window-server query rather than IPC, so being level-triggered costs ~2.5 ms and no AX
until the two disagree. `Heartbeat` is its own seam beside `DelayScheduler`: a retry terminates and a heartbeat
does not, and one drained by a test's "run everything pending" loop never would.

**Observers speak `WorldObservation`, not `Event`.** Two cases decide the type: "a window appeared" is not a
window we can name (the notification carries an element with no window number, so the response is a re-scan),
and "a window moved" is not a frame (AX never says where to). Both responses are policy.

**The cover is the working area, not the display.** Our overlay is `.floating` (level 3); the menu bar is
`.mainMenu` (level 24) and always composites on top of it, over the base capture's own copy of it. So the
overlay is **inset by the struts** and the chrome bands show the real, live menu bar and Dock — safe for exactly
the reason the strut exists. This is why the daemon reads the struts _once_ and hands the same value to both the
core and the overlay: the invariant holds only while the two agree.

**A raised cover holds `alpha 0.999`.** A window at full alpha marks everything beneath it _occluded_, and an
occluded app may stop feeding a separately-composited plane — a playing video comes back dark for the first
frame of the dissolve. Any alpha below 1 disqualifies a window from occluding; a thousandth is under one 8-bit
level.

**Hotkeys consume.** An `NSEvent` global monitor is available under the AX grant but cannot swallow the
keystroke, so `alt-h` would scroll the strip _and_ type into the focused app. Hence Carbon. A hotkey manager is
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

---

## 8. Cross-cutting rules

- **Concurrency.** `@MainActor` pins the Runtime, core state, and all CA/overlay work; Swift 6 strict
  concurrency then _proves_ nothing mutates it off-thread. The only off-thread work is AX (serial per-app GCD
  lanes, marshaled back) and capture (its own queue). Nothing in the effect path is `async`, so nothing can
  suspend the pump.
- **One `AXClient` for the whole daemon.** The per-app lanes are only serial if the enumerator, the writer and
  the observers all queue onto the same ones.
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
example document is a render of it; `emira config explain` and (later) the settings window are its consumers, so
nothing describing a setting is written down twice.

**Unknown keys are refused, and there is no second list of valid names.** The reader _takes_ each key the schema
knows and reports whatever is left, so "which keys are valid" _is_ the reading code. A declared-but-empty
`[layuot]` is caught too. Silence is the failure mode that matters: a window manager that ignores `colum-gap` is
one the user believes is broken.

Three sections stay hand-written and are named as such in the reader — **`outer-gap`** (one logical value with
five spellings), **`[keys]`** (an open table whose names the user invents) and **`[[window-rules]]`**
(repeating, ordered, cross-validated). They are exactly the three that would get bespoke editors in a settings
window. A test pins that every stored property of `Config` is either covered by an entry, claimed by one of
those three, or on an explicit not-a-key list — so a new field cannot be added without a config story.

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

- **`applyEnvironment`** — the values a file may not decide. `struts` come from `NSScreen.visibleFrame` and the
  same number must reach the core _and_ the overlay. `transitionMode` is a preference answerable to the Screen
  Recording _capability_ (no grant ⇒ `off`; `snap` is out of reach exactly as `smooth` is, both being made of
  captured pixels). `hidesCursor` needs two conjuncts — the private cursor property resolves _and_ the pointer
  motion monitor installed — because the only exit from a hidden pointer is seeing the mouse move, and emira
  will not enter a state it has no exit from. A setting asked for and clamped away is logged once.
- **`applyShellConfig`** — the values that reach the shell rather than the reducer (`windowAnimation`,
  `coverMode`, `transitionMode`, the kept stills, the pointer rung and its monitor). One function, called at
  launch and again from `ConfigLoader.onLoad`. Two call sites assigning a property each is where "the reducer
  and the shell read the same post-`applyEnvironment` value" goes quietly false.

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
    │                    Event · Effect · Config · Rules · Engine
    │   ├── State/       World · Motion · RectAnimator · Pointer
    │   └── Layout/      Layout · Workspaces · Strip · Column · Presets · Cascade · Park
    ├── EmiraConfig/     TOML · ConfigSchema · ConfigSyntax · ConfigExample · ConfigExplain
    │                    ConfigDocument · ConfigPath
    ├── EmiraProtocol/   Request · Reply · Wire (framing + probe) · SocketClient
    ├── EmiraShell/      Runtime · Executor · WindowRegistry · WorldWatcher · Teardown
    │                    ProcessLauncher · Scheduler · Permissions · Logging
    │   ├── AX/          AXAccess · AXClient · AXEnumerator · AXWriter · AXExecutor
    │   │                Observation · AXObservers · FocusIntent · EnhancedUI
    │   ├── Capture/     CaptureService · SurfaceCache · SCKCapturer
    │   ├── Compositor/  ScreenGeometry (THE Y-flip) · Overlay · Reconstruction · CompositingExecutor
    │   ├── Guide/       GuideModel (pure) · GuidePanel · RoundedLayer · GuideIcons · Guide
    │   ├── Pointer/     CursorConnection · PointerExecutor · PointerFocus · PointerWake · PointerSamples
    │   ├── Display/     FrameClock · DisplayLinkDriver · HoldTimer
    │   ├── Input/       Hotkeys (policy) · CarbonHotkeys
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
  (height water-fill and its bounds), `ParkTests`, `LayoutTests`, `WorkspaceTests`, `OuterGapTests`,
  `CascadeTests`, `GeometryTests`. One suite per question. Pure, fast, exhaustive.
- **`EmiraCoreTests` / the reducer** — `EngineArrivalTests`, `EngineFocusTests`, `EngineWindowOpTests`,
  `EngineTransitionTests`, `EngineResizeTests`, `EngineFullscreenTests`, `EngineRefusalTests`,
  `EngineStructuralEditTests`, `EnginePointerTests`, `EngineWarpTests`, `EngineConfigReplayTests`,
  `GuideRingTests`, `SystemFocusEventTests`, `TransitionModeTests`, `WorkspaceCommandTests`, `RulesTests`,
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
- **`EmiraShellTests`** — the pump (FIFO / non-re-entrancy / clock gating), the IPC seam over a real socket,
  identity (`GhostIdentityTests`, `NativeTabTests`), the write path, the truth plane, capture, compositing, the
  pointer plane, `GuideModel`, hotkeys, config loading, onboarding, teardown. Everything runs against the seams
  in §7 — the shell's untestable calls are one file deep at every boundary.

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
