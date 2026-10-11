# emira — assessment

> 2026-10-11, against `b273167`. Read `PRINCIPLES.md`, `IMPLEMENTATION.md`, the core and the shell, then
> ran the release daemon on the real desktop and measured it.

## 1. Scope and method

**Desktop.** Studio Display XDR (main, 2560×1440 @2×) with the built-in display to its left. The user's
own `config.toml`: `cover = immediate`, `window = crop`, `unfocused-opacity = 0.5`, `unfocused-blur = 8`,
`mouse.hide = true`, `trackpad-scroll = magnet`, 20 pt gaps, 31 `fn` bindings. A `watch` client was
connected the whole time (a bar, pid 5004).

**Instruments.** `EMIRA_TRACE=1` (every reduce with a wall clock), `EMIRA_STALL_PROBE=16`, `sample` at
1 ms over two transitions and over 4 s idle, `vmmap --summary`, `emira debug`. Subjects: the Ghostty
window this ran from, TextEdit ×3, Chrome ×2, Finder ×5 — 39 commands, 15 arrivals and 14 departures, 46 covered transitions.

**Not measured.** The trackpad path (gesture events cannot be synthesized), a transition on both displays
at once, hot reload, `snap`/`off`, the settings window.

**Verdict in one line.** The architecture is sound and the idle cost is nil. Every measurable delay is
in the *head* of a transition and in work the daemon does to itself afterwards — none of it is in the
reducer, the springs or the GPU. The wins below are mostly ordering and gating, not new mechanism.

## 2. Where a keystroke's time goes

`focus left` with 3–5 windows in scope, `cover = immediate`, kept stills warm:

| Phase | Measured | Notes |
| --- | --- | --- |
| command → base capture lands (the gate) | 48–81 ms, median ~62 | one 5120×2880 SCK screenshot, plus ~10 ms `SCShareableContent` |
| `beginTransition` → `coverOnScreen` (the fence) | 18–40 ms | two display callbacks + one window-server read; layers are **not** animated meanwhile |
| teleport → every `axLanded` | 1–20 ms AppKit; Chrome once 575 ms | the hold deadline did its job |
| spring (stiffness 800, ζ 1) | ~360 ms, 118–126 fps | occasional 102–113 fps runs — see P6 |
| cross-fade | 220 ms | ends in a 25–50 ms main-thread stall — see P5 |
| **command → first visible motion** | **~90–120 ms** | |
| **command → `crossfadeDone`** | **~700 ms** | |

A window **arriving** is slower than a keystroke: `focusChanged(nil)` → `windowCreated` 162–172 ms (the
join fails under the open animation and the 150 ms rescan binds it), then a 116–269 ms head because the
newcomer has no stand-in and is filmed behind everything else. A new window is placed **~300–440 ms**
after its app made it.

A focus change between two columns already on the glass costs one AX write and one scrim recut: 6 ms to
the echo, 30 ms to the activation. That path is as cheap as it should be.

**Idle:** 0.3–0.4 % CPU, 8 threads, one `CGWindowListCopyWindowInfo` every 3 s (2 samples in 4 s),
no display link. Physical footprint 136 MB, **peak 670 MB** during a transition (IOSurfaces from
ScreenCaptureKit and Core Image; the two 2× desktop photographs alone are ~83 MB).

**Per-capture cost on this display is ~50 ms, not the ~25 ms the documents carry.** Window stills of
2500×2748 px took 47–60 ms each, the 5K base 48–98 ms. With four or more windows in scope the 250 ms
batch deadline fires on nearly every transition (`— DEADLINE` on 25 of the 46 head batches logged).

## 3. Performance — findings, ranked by what they buy

### P1. Film the windows the gate is waiting on first

`SCKCapturer.grab` films `content.windows.filter { windows.contains($0.windowID) }` — ScreenCaptureKit's
order, which is neither scope order (as the comment says) nor priority order. Under `immediate` most
windows are stood in and ready at the base; the one or two with no matching still are what the raise is
waiting for, and they queue behind refreshes of windows that already have pixels.

Measured: `move-window left` raised at **256 ms** because the mover (its size had changed in the
previous `cycle-width`) was filmed last, behind three refreshes. Filming it first would have raised at
~110 ms. The same shape hit every arrival (116–269 ms heads) and the first boot.

Fix: `CaptureService.capture` already knows `stoodIn`; pass an order to the capturer and film the
un-stood-in windows (and the base) first. One line of policy, no new mechanism.

### P2. Warm the still cache after a transition, for windows whose size changed

A still is matched on size alone, and the head batch films a window at its *pre-transition* size. So
after any resize — `cycle-width`, `grow`, `fullscreen`, a column widening on a departure, every arrival —
the resized window has no stand-in for the *next* transition and that head waits on a fresh capture
(P1's 256 ms case is exactly this).

Fix: at `crossfadeDone`, film each window whose current size differs from the size its kept still was
taken at. The capture plane is idle then, it is one one-shot screenshot per resized window off the main
thread, and it makes the next head base-only. (The hoist objection to timer captures does not apply:
this is bounded per transition, not standing.)

### P3. Late stills are recorded but never painted

`CaptureService.receive` stores a piece that lands after the deadline (`cache.record` runs first) and
then `guard let batch else { return }` — so no `captureRefreshed` goes out. On this display the deadline
cut every 4–5 window batch, leaving the last one or two layers at **quarter-resolution stand-ins for the
rest of the transition and the cross-fade** ("5/5 standing", three refreshes, two layers never
sharpened). The cover is up for another 300–500 ms after the deadline, so the pixels would still land.

Fix: keep emitting `captureRefreshed` while `isCurrent` holds, deadline or not — the batch's *acks* are
settled by `finish`, its *refreshes* need not be. Separately, re-measure the 25 ms figure the deadline was
sized against; at 50 ms it bounds a four-window batch, which is an ordinary strip on a 5K display.

### P4. The fence is dead time the layers could use

Ticks only drive layers for `coveredMonitors` (`Engine.swift:739`), so between `beginTransition` and
`coverOnScreen` — 18–40 ms, two to five frames at 120 Hz — the cover is up and static. The fence
exists to hold the *reals*; nothing about the stand-ins depends on it, and they are under an opaque cover
either way.

Option: let `.raising` displays advance and blit (the teleport stays gated on the phase). Cost: when the
cover is first shown it is a frame or two into the spring rather than pixel-identical, which at
stiffness 800 is a few points. If pixel-identity at the raise is the thing you most want to keep, leave
this — it is the one item here with a real trade.

### P5. `SurfaceCache.unpin` downscales every still synchronously on the main thread

`CaptureService.discard` → `SurfaceCache.unpin` (`SurfaceCache.swift:158`) → `reduced` (`:276`) runs
`CGContextDrawImage` over every full-size still at the end of every cross-fade: 48 of the ~150 busy
main-thread samples across two transitions, and 25–77 ms stalls in the probe. It lands exactly when the
next keypress's head batch wants the main thread, and it stutters any guide or scrim fade in flight.

The change file's argument for synchrony is about *which* photograph is current, not about when the
reduction completes. `reduced` is already `nonisolated`; run it on the capture queue and swap the small
pixels in when done (a read in between gets the full-resolution image, which is better, not worse). Or
use `vImage`/`CGImageSourceCreateThumbnailAtIndex`, which are several times faster than a Core Graphics
draw for a 4× downscale.

### P6. Window-list reads on the main thread while frames are being committed

`Scrims.watch` (`Scrims.swift:444`) re-reads the window list every 16 ms after each set until four quiet
readings or 400 ms, and a transition sends 2–3 sets. `paint` → `StackedWindow.current` (`:94`) was 34
samples in the transition sample and the probe caught it at 24–37 ms several times — the read waits on
our own pending Core Animation commit, exactly as `IMPLEMENTATION.md` says it does for reconciliation.
Those are the 102–113 fps transitions. Only `expectArrival` and `reconcile` yield to `isPainting`; the
settle watch does not.

Fix: while a cover is up on that display, apply the set once and defer the settle watch to
`crossfadeDone` — the cover hides the scrim, so nothing the watch would correct is visible. And share one
reading per run-loop turn: `reconcile` already reads the list and then `recut` reads it again
(`onStackChanged` could carry the reading, as `paint(against:)` already can).

### P7. Our own placements provoke AX reads we already have the answer to

Each `setFrame` lands, the executor reads the frame back, and then the app posts `AXWindowMoved` *and*
`AXWindowResized`, which `WorldWatcher.readFrame` turns into one or two more reads (position + size,
2–4 IPC per window — visible in every trace as paired `windowFrameChanged` lines 0.2 ms apart). Each read
then arms a 120 ms `stillness` timer whose `windowSelfPlaced` runs a full placement pass that emits
nothing. Per four-window scroll: ~40 AX round trips, of which ~16 are these echoes.

Fix: a record of in-flight writes shared between `AXExecutor` and `WorldWatcher` — `FocusIntent`'s shape
for frames — so a move report for a window we are writing is dropped and the executor's own read-back
stands. Reports arriving after the landing are still read (an app that moves itself afterwards, see P8).
A cheaper half-step: coalesce `windowMoved`+`windowResized` into one read with a 1–2 ms debounce.

### P8. Two tolerances disagree, so some windows are written twice per move

`AXExecutor.landingTolerance` is 1 pt (`AXExecutor.swift:21`); `Engine.approximatelyEqual` is 0.5 pt
(`Engine.swift:3635`). A window landing 0.5–1 pt off its target is reported `axLanded` with no
`placementCorrected`, so nothing records a refusal, `isAlreadyPlaced` says no, and the next
`windowSelfPlaced` re-emits the identical `setFrame`. Ghostty does this on every move (asked
`x = -40.476`, lands at `-41`): three writes of the same rect 120 ms apart in the first trace.

Two causes, both small:

- **Targets are fractional.** `(span + gap)·p − gap` with the user's 20 pt gap yields `.476` offsets, and
  AX stores integers. Rounding target frames to the backing-pixel grid before they are written would make
  "landed where asked" true for every well-behaved app.
- **`keepExistingWidth` (`Engine.swift:3104`) stores `width / nominalArea.width`** rather than
  `Extent.proportion(of:)` (`Presets.swift:33`), so a 1320 pt window adopted at boot resolves to
  1310.476 and is asked to shrink by ten points on every placement.

Align the two tolerances (one constant, read by both) and the redundant write disappears regardless.

### P9. Arrival: the 150 ms rescan is most of the latency

Every arrival here was `focusChanged(nil)` → 162–172 ms → `windowCreated`: the first scan's join fails
because the open animation grows the window past the 2 pt tolerance, and the second scan is scheduled
150 ms later. The change file measured the animation overshoot holding for ~115 ms.

Cheap: `rescanDelay` 150 → ~60 ms with the same three attempts (a rescan is one app's windows, not the
desktop). Riskier but worth a test: when a scan leaves exactly one unbound AX window and exactly one
unclaimed on-screen entry *of the same pid*, that pairing is unique in both directions by count rather than
by frame — the charter's rule, satisfied differently.

### P10. The `watch` publisher rebuilds the whole status on every drain

`DesktopPublisher.stateChanged` builds a full `DesktopStatus` — `naturalFrames` per display and
`NamesModel.largest` per column — and then compares it, on every drain while anyone is watching. With
a bar connected that is 120×/s for the length of every transition, to find that nothing changed. The
guide solved the same problem with `GuideTrigger`, a small diffed projection; `DesktopStatus` needs the
same cheap trigger in front of it.

### P11. Smaller things seen in the traces

- **Parked Chrome windows cost a correction round trip per park.** Chrome answers 1394, then 1392, then
  1384 for the same slot; `parkCorrected` re-parks both windows every time one is parked. The learned
  floor (46) does not stop the first write landing off, so each such transition carries two extra sets.
  Worth a look at whether the floor should be applied to the *requested* slot before the first write.
- **`CADisplayLink` creation is ~34 ms on the main thread** (`SLSGetDisplayLink`). Paid once per driver
  and once per overlay's fence link (lazily, at the first raise on that display), and again on every
  `retarget` — a reconfiguration pays it for every display.
- **A 174 ms stall at boot in `CGSDisplayInitialize`** — the first window-server touch. Unavoidable, but
  it is inside the onboarding gate's window, so it does not delay the first scan.
- **The shoulder.** Every scroll filmed 4–5 windows for 2–3 visible. Under `immediate` that is not on the
  head, but it is 50–100 ms of serialized capture queue per scroll and it is what pushes batches past the
  deadline (P3). The shoulder was priced at 25 ms a window.
- **The hold deadline is shared with the pin fence's share and the publish grace**: `0.75 s publishGrace`
  < `1 s hold-timeout` is a relation nothing checks. See A9.
- **One anomaly, not reproduced.** Closing a TextEdit window that was parked left of the viewport (three
  windows closing at once, two of them hoisted floats) landed as a *snap* — `windowDestroyed` → three
  placements, no capture, no cover — where the same close reproduced on its own animated correctly. The
  trace is in the session log; the snapped path emitted exactly `reassertTruthPlane`'s output at
  `restingOffset`'s target, which points at `actingSnapshot` answering empty.

### What is fine

The reducer and the springs cost nothing measurable: at 120 Hz with four layers, `Runtime.dispatch` was
4 of ~150 busy samples. `CATransaction` commits are 5. The pump is not re-entrant in practice as well as
by design (no stall in the probe ever had `Engine` on its stack). The AX lanes keep the main thread clean:
not one AX call appears in the main-thread samples. The fn-key tap, the socket and the hotkey path are all
under 3 ms to the reducer. The frame clock is off at idle, and the motion monitor's samples cost nothing
with `follows-mouse` off (the guard is the first line).

## 4. Architecture — findings

The design holds. The four invariants in `IMPLEMENTATION.md` §1 are visible in the code, the vocabularies
are exhaustive, the seams make the suite cheap (2,389 tests, `make test` in 18 s wall including the
build). What follows is about weight and repetition, not shape.

### A1. `Engine.swift` is 3,657 lines and 65 commits

It is the file most changes touch and the hardest to navigate: ~120 static functions under one `enum`.
The outline already has its seams — transition lifecycle (`scrollReveal`/`driveTransition`/
`teleportBehindCover`/`emitLayerFrames`/`closeSettledTransitions`), structural edits
(`finishStructuralEdit`, the snapshots, `Crossing`), workspaces and monitors, focus policy, the trackpad,
resize and the hand, pins, arrivals and departures, the placement pass. Each is an `extension Engine` in
its own file at no cost but changing `private` to `fileprivate`-equivalent `internal`. The post-pass chain
in `reduce` and `fold`'s event switch stay in `Engine.swift`.

### A2. `main.swift` is a composition root written as 829 lines of order-dependent globals

Second most-churned file. The "a function declared above a global it reaches reads zeroed memory" rule
exists because top-level code is the composition root. Two concrete duplications fall out of it:

- `applyShellConfig` (`main.swift:535`) and `syncDisplays` (`:621`) both assign the same four
  `Reconstruction` properties (`animation`, `motionBlur`, `veil`, `backdrop`) — two sites that must agree.
- `syncDisplays` updates seven per-display containers by hand (`compositor.setSurfaces`,
  `capture.setCapturers`, `hoistPanels.setDisplays`, `desktopCapturer.setScales`, `scrims.setDisplays`,
  `clock.retarget`, the reconstruction properties).

A `Daemon` type whose stored properties are the subsystems removes the ordering trap outright; a
`DisplayBound` protocol (`setDisplays(_ displays: AttachedDisplays)`) over a list collapses the seven
calls to one loop.

### A3. `reconcile(tiledWindowIds:onto:)` is called from 27 sites in the reducer

Every path that might touch membership re-runs it defensively; it is idempotent, so this is safe, and it
is O(windows × workspaces) each time. It is the clearest case of the same call in many places. Two ways
to make it one: run it once at the top of `fold` for the events that can change `World`'s tiled set, or
make the four `World` mutators that change membership (`insert`, `remove`, `setMinimized`,
`setFloating`/`setPin`, `setAppHidden`) the only callers through `State`.

### A4. Geometry is rebuilt several times per event

`State.metrics(of:)` (`Engine.swift:111`) is called from 30 sites and each call copies five dictionaries
and re-ranks the parking lot. `naturalFrames` has 8 callers, `targetFrames` 6; `writeTruthPlane` lays out
the whole desktop on every reassert, and `alreadyRefused` does it again per `windowSelfPlaced`. At ten
windows none of this is measurable (see "what is fine"), so this is a shape note rather than a
performance one: a per-reduce `Geometry` scratch (metrics per display, computed once at the top of
`fold`) would make most of those 44 calls a field read and would make the cost visible if it ever grows.

### A5. Fifteen generation counters and six hand-rolled poll loops

Because `DelayScheduler` cannot cancel, every subsystem keeps a counter to disown stale closures:
`Overlay.generation`, `Compositor.raise/dismissGeneration`, `HoistPanel.generation`,
`HoistPanels.fence/filmGeneration`, `Scrims.film/settle/arrivalGeneration`, `CaptureService.generation`
and `coverGeneration`, `PinFence.generation`, `Guide.dwells`, `GuidePanel.generation`,
`WorldWatcher.settleId/quietId/shownCheck/stillness`. Each is correct; together they are ~80 lines of the
same idiom. A `DelayScheduler.schedule` that returns a cancellable token deletes most of them.

The same files hold six "ask again until quiet or deadline" loops (`WorldWatcher.waitForQuiet`,
`waitForStillness`, `Scrims.watch`, `Scrims.expectArrival`, `HoistPanels.ask`, `PinFence.ask`), each with
its own interval, quiet count and limit. One `Settle` helper (`interval`, `quiet`, `limit`, a read, a
changed-test) would carry all six and make their constants comparable.

### A6. Seven near-equal comparisons with five different tolerances

`Engine.approximatelyEqual` 0.5, `AXExecutor.approximatelyEqual` 1, `AXWindow.sameFrame` 1,
`WindowIdentity.sameFrame` 2, `SurfaceCache.sameSize` 2, plus `approximatelyEqualSize` and `…Scalar`.
P8 is the bug the spread hides. One `Geometry.Tolerance` namespace with named constants (`placement`,
`landing`, `identity`, `still`) and one `Rect.isClose(to:within:)` would make the relations explicit.

### A7. Five readers of the window server, three decoders

`WindowListEntry.current` (`optionAll`), `StackedWindow.current` (`onScreenOnly`), `CGStackProbe`,
`Overlay.confirmPublished` and `AXWindowWriter.canHoldFocus` each call `CGWindowListCopyWindowInfo` and
decode the dictionaries their own way. A `WindowServer` type with one decoder and a per-turn cache would
let `reconcile`, `recut` and `noteShown` share a reading (P6), and would be the one place the "waits on
our own commit" rule is stated.

### A8. Four copies of the passive-window idiom

`Overlay`, `ScrimWindow`, `HoistPanel` and `GuidePanel` (and `SettingsWindow`) each build a borderless
`NSWindow` with `animationBehavior = .none`, ordered in at alpha 0, `isReleasedWhenClosed = false`,
`ignoresMouseEvents`, a level and a collection behaviour. The docs say the copying is deliberate because
the idiom is proven; a `PassiveWindow.make(level:behavior:frame:)` factory keeps it proven in one place.

### A9. ~55 timing constants in 25 files, with unstated relations

`hold-timeout` (config) is the base for `PinFence.share` (0.5) and must exceed `Overlay.publishGrace`
(0.75 s); `Scrims.settleLimit` (0.4 s) and `arrivalLimit` (~1 s) bound watches that run inside transitions
the deadline also bounds; `CaptureService.defaultDeadline` (0.25 s) is sized to a per-capture cost that
has doubled. None of these relations is written where the numbers are. A `Timing` table per subsystem —
or one for the shell — with the relations as comments (or as `precondition`s at boot) would make P3 and
P11's relation visible instead of latent.

### A10. The prose has outgrown its own rule

`DOCS.md` sets a three-line ceiling on declaration comments and sends the rest to `changes/`. Measured:
604 of 3,222 doc-comment blocks exceed it; the longest run 18–30 lines (`WorldWatcher.swift:832`,
`Engine.swift:1613`, `AXWriter.swift:127`); ten file headers run 30–50 lines. Comment lines are 38 % of
`EmiraCore` and 34 % of `EmiraShell`. `IMPLEMENTATION.md` is 2,650 lines, of which §6 is 1,029 — the
scrims subsection alone argues its design over ~250 lines, which is the "when a paragraph here starts
explaining, it has drifted" the file warns about. The content is good; its placement costs reading time at
the moment someone is chasing a bug. A pass that moves derivations into the change files and leaves
constraints in place would halve both without losing anything that is recorded.

### A11. Post-passes run on ticks

`reduce` runs seven post-passes on every event, including the 120 Hz tick. `scrimBindings` sorts and
groups the on-screen set per tick whenever `unfocused-opacity < 1` (this config), `hoistBindings` early-outs
only when nothing is floated by choice. Both are microseconds at this size; both could `guard` on the event
kind (`.tick` changes nothing they read) and stay that way at any size.

### A12. Size, for the record

`EmiraSettings` is 16,782 lines — the largest module, 40 % of the sources — for a window the README calls
partially implemented, and it carries a second motion system (`PreviewMotion`, `CameraTravel`, the takes).
The documents defend each piece and nothing here depends on it; it is only worth saying that it is where
the weight is, if weight ever matters.

### What is fine

The `Command`/`Event`/`Effect` vocabularies, the `Executor` and plane split, the `WindowRegistry` identity
join, the per-app AX lanes, the capture store's entitlement model, the `Motion` ownership of time, the
per-display containers, and the test seams are all clean and all doing what the documents say. The
suite is the project's real asset: 1,165 core tests over scripted worlds, and every shell subsystem one
seam deep from its framework.

## 5. Suggested order

1. **P1 + P3** — two small edits in `CaptureService`/`SCKCapturer`; the largest latency win per line.
2. **P8** — align the tolerances, round targets; removes a redundant AX write per move for any
   cell-quantizing app (terminals).
3. **P5** — move the downscale off the main thread; removes the stall at the end of every transition.
4. **P6** — gate the scrim settle watch while covered; recovers the dropped frames.
5. **P2** — warm the cache after resizes; makes `immediate` immediate after a resize too.
6. **P7** — echo filtering for frame reads; the "fewer AX interactions" item proper.
7. **A3, A6, A5** — the three duplication items, in that order; each is mechanical and the suite prices it.
8. **A1, A2** — the two big files; purely for reading, do them when the above has settled.

## 6. Appendix — raw numbers

Transitions (display 2, `immediate`, this desktop):

```
command            scope  base   raise  onScreen  land   frames  fps  head→done
focus left         4      64     164    203       209    44      122  526
focus left         4      67     67     91        113    37      102  432
focus right        3      56     56     89        92     31      126  303
focus right        4      56     56     81        88     44      122  418
cycle-width        4      62     62     92        118    36      113  381
cycle-width        4      65     117    158       183    39      122  436
move-window left   4      70     256    297       308    45      124  618
move-window right  4      53     53     92        126    44      123  412
fullscreen         4      58     122    153       189    43      120  482
float toggle       3      66     66     97        110    44      122  427
pin toggle-left    3      62     62     87        94     43      120  421
close-window       3      74     97     124       137    43      120  434
arrival (TextEdit) 3      62     149    178       207    44      121  512
arrival (Finder)   4      73     233    269       —      45      125  594
```

Main-thread busy samples over two transitions (1 ms sampling, ~150 of 1,613 busy): `SurfaceCache.reduced`
48, `Scrims.paint → CGWindowListCopyWindowInfo` 34, display-link tick (reduce + blit) 17, `NSRunningApplication.activate`
8, `WindowListEntry.current` 8, `CATransaction` 5.

Stalls caught at the 16 ms threshold over ~12 minutes: boot `CGSDisplayInitialize` 174 ms; `SLSGetDisplayLink`
34 ms; `Scrims.watch` window-list reads 24, 33, 33, 37 ms; `SurfaceCache.reduced` 37, 52, 65 ms.

Memory: 596 MB RSS, 136 MB physical footprint, 670 MB peak; `IOSurface` 465 MB virtual, `Accelerate`
56 MB dirty (the `vImage` shade buffers).

Tests: `make test` 18.2 s wall (8.8 s build), 71 s CPU, all passing.
