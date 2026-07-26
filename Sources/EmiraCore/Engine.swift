import Foundation
import EmiraMotion

// The reducer — the pure heart the whole architecture exists to make trustworthy (IMPLEMENTATION.md
// §1/§3/§8, PRINCIPLES.md §7). `reduce(State, Event) -> (State, [Effect])` is a **pure function**: it
// composes the three halves of `State` (`World` truth, `Layout` structure, `Motion` animation),
// folds every inbound `Event` into a new `State`, and emits the `Effect`s the shell should run. It
// imports no framework — it never touches AX / Core Animation / ScreenCaptureKit, it only *names*
// them via `Effect`. That is what lets the entire brain be verified with a recording executor and no
// macOS in sight (§8).
//
// **The snap/idle floor (the M3-parity brain).** Everything that needs no cover: fold reality into
// `World`, keep the `Layout` structure reconciled, and place every managed window at its *correct*
// frame *instantly* — new window, close, minimize, drag-end, display change, and **externally-
// initiated** focus resolve to direct `setFrame`/`park` sets with the viewport **snapped**, no
// animation. This is AeroSpace's floor: "placement is immediate and correct" (§4a), and it must be
// rock-solid — the animated path builds on the very same frame-target math (`Layout.targetFrames`,
// `emitPlacements`).
//
// **The transition session (the M4-parity brain, this slice).** A *user-initiated* scroll — `focus`
// across columns, `centerColumn` — no longer snaps; it plays the signature smooth scroll (§4b) under
// a layered cover. `scrollReveal` opens a `TransitionSession`, `capture`s the scoped windows, and on
// the last `captureReady` raises the cover (`beginTransition`) and **teleports the reals to their end
// frames behind it** (zero exposure); each `tick(dt)` advances the viewport spring and emits one
// `setLayerFrame` per layer (natural, un-parked positions — the layers slide, the hidden reals park);
// once the animators settle **and** every scoped `axLanded` is in (or `holdTimeout` bounds the wait),
// it `endTransition`s and drops the cover. The interrupt is pure arithmetic: a second scroll command
// mid-flight `retarget`s the open session (velocity carried) and re-teleports the reals behind the
// still-up cover — one session throughout, never a second (PRINCIPLES.md §7). `Motion` already models
// the session lifecycle; this reducer supplies the *policy* of when to open / raise / close it.
//
// **The animated resize (M4 part 3).** `cycleWidth` is the first command whose motion is not a scroll:
// it changes the strip's *own geometry*, so the offset scalar cannot express it. It gets the second
// animated quantity — the column's resolved width (`Motion.columnWidths`) — and rides the very same
// session machinery, because §4d's "cross-fade a scaled screenshot over the reflow" is what the cover
// already is. The reals are teleported to their final *size* behind it; the layers, holding stills of
// the old content, are scaled to meet them.
//
// **The animated structural edit (this slice).** `moveWindow` and `consumeOrExpel` change the strip's
// *structure* rather than a number the frames derive from: a window leaves one column for another, a
// column is born, a column is merged away. They landed as snaps, deliberately, because before and
// after are two different `Layout`s and there is nothing to interpolate between — and animating them
// looked like per-window rect interpolation across two structures, i.e. the "lockstep as something to
// be maintained rather than something that cannot break" the resize slice rejected.
//
// **What was missing was the observation that the thing to animate is not a position.** It is a
// *displacement*: `Layout` mutates at once and stays the sole authority on where every window belongs,
// and what goes under a spring is how far **behind** that answer each layer currently is, decaying to
// zero (`Motion.windowAnimators`, now `RectAnimator`). Seeded with `before − after` — the same
// `naturalFrames` query either side of the mutation, at one offset and one width map, so the scroll
// and any in-flight resize cancel and only the structural delta survives.
//
// This does **not** reverse M4 part 3, and the distinction is the whole justification. That slice
// rejected choreographing a quantity *everything derives from* — a column's width — because doing so
// per-window makes lockstep a thing to maintain. Here the destination is still derived; only the lag
// is per-window, and lag genuinely is per-window. Everything else falls out: the first frame
// reproduces the old layout exactly (so the raise cannot pop), a settled animator is indistinguishable
// from no animator (so `closeTransition` may drop them), an orphan is harmless, and a second edit
// mid-flight is a `nudge` — position continuous, velocity carried.
//
// One thing genuinely could not be derived. Two columns trading places pass *through* each other on
// the presentation plane, and which one is drawn on top is a fact about the **command**, not the
// strip — so the core names it (`TransitionSession.elevated`) and says so out loud
// (`Effect.elevateLayer`). Every other transition can ignore z-order because strip windows never
// overlap; this is the first one that can't.
//
// **Totality is the contract (§1 invariant 3).** `reduce` is exhaustive over `Event` and every
// handler is total: a command with nothing focused, a destroy racing a prior removal, an event
// before any monitor is known — all produce a well-defined `(State, [])`, never a trap. A hung app
// or a vanished window is a normal transition, not a crash.

/// The complete core state — the three halves plus the config the reducer resolves against. A value
/// type, `Equatable`/`Codable` like its parts, so the whole brain dumps to JSON (`emira debug`) and
/// replays deterministically (§7).
public struct State: Sendable, Equatable, Codable {
    /// Truth: what actually exists on the system (windows, apps, monitors, focus).
    public var world: World
    /// Structure: how the strip's windows are arranged into columns.
    public var layout: Layout
    /// Animation: the viewport-offset scroll, independent per-window motion, the transition session.
    public var motion: Motion
    /// The parsed config values the reducer reads (gaps, presets, struts, scroll feel).
    public var config: Config

    /// A fresh, empty state — the launch state before any window or monitor is enumerated. The
    /// viewport spring is seeded from the config so scroll feel is config-driven from the first frame.
    public init(config: Config = Config()) {
        self.world = World()
        self.layout = Layout()
        self.motion = Motion(viewportOffset: 0, params: config.scrollSpring)
        self.config = config
    }

    /// Full memberwise init — for the reducer building a specific state, for replay, and for tests.
    public init(world: World, layout: Layout, motion: Motion, config: Config) {
        self.world = world
        self.layout = layout
        self.motion = motion
        self.config = config
    }

    /// The layout metrics for the current monitor + config, or `nil` when no display is known yet
    /// (so geometry commands no-op until the first `screensChanged`). Single-monitor for now — a
    /// per-monitor strip container is M6; this resolves against the first display, inset by the
    /// struts to keep tiles clear of the menu bar / Dock.
    public func metrics() -> LayoutMetrics? {
        guard let monitor = world.monitors.first else { return nil }
        return LayoutMetrics(
            workingArea: monitor.frame.inset(by: config.struts),
            widthPresets: config.widthPresets,
            columnGap: config.columnGap,
            windowGap: config.windowGap,
            corrections: world.corrections)
    }
}

/// The pure reducer. Stateless namespace — all state travels through the `State` value.
public enum Engine {

    /// Fold one `Event` into a new `State`, emitting the `Effect`s the shell should run. Pure and
    /// total: same input always yields the same `(State, [Effect])`, and every `Event` is handled.
    public static func reduce(_ state: State, _ event: Event) -> (State, [Effect]) {
        var s = state
        switch event {

        // MARK: Commands

        case .command(let command):
            // NB: bind effects to a local before returning. `(s, reduceCommand(&s, …))` would read
            // `s` (tuple element 0) *before* the `&s` call mutates it, returning stale state.
            let effects = reduceCommand(&s, command)
            return (s, effects)

        // MARK: The frame clock
        //
        // Ticks fire only while a transition session is open (the shell drives the display link only
        // then). We animate only once the cover is *raised* (`.covered`) — during the brief pre-cover
        // `.capturing` there are no layers to move and no real window has teleported, so a tick is
        // inert. On a covered tick: advance the viewport spring, blit one `setLayerFrame` per layer at
        // its natural position, and close the transition if the animators have settled and every scoped
        // AX set has landed.
        case .tick(let dt):
            guard s.motion.isCovered else { return (s, []) }
            s.motion.advance(by: dt)
            var effects = emitLayerFrames(s)
            effects += maybeCloseTransition(&s)
            return (s, effects)

        // MARK: Truth-plane observations — reality folded into `World`, then re-placed

        case .windowCreated(let snapshot):
            s.world.insert(snapshot)
            // A non-tiling window (dialog/panel/sheet/float) is the app's to position — we record it
            // but never place or force-focus it.
            guard s.world.participatesInStrip(snapshot.id) else { return (s, []) }
            s.world.setFocus(snapshot.id)   // a new window takes focus (truth tracked always)
            // Nothing to place until a display is known; focus stays recorded, no effect emitted.
            guard s.metrics() != nil else { return (s, []) }
            var effects = reveal(&s, snapshot.id, center: s.config.centerFocusedColumn)
            effects.append(.focus(snapshot.id))
            return (s, effects)

        case .windowDestroyed(let id):
            s.world.remove(id)              // clears focus if it was on the departing window
            // Retire any in-flight displacement: the window has left the strip, so `Layout` has no
            // opinion about where it belongs and the animator is measuring a lag against nothing.
            // Harmless if left (it settles on its own), except that `isSettled` is the transition's
            // close gate — the same argument `removeColumnWidthAnimator` makes.
            s.motion.removeWindowAnimator(id)
            let effects = refocusAndPlace(&s)
            return (s, effects)

        case .windowFrameChanged(let id, let frame):
            // External drift (usually a live drag/resize). Record it; don't fight the user mid-drag —
            // a tiled window re-asserts its layout on `dragEnded`.
            s.world.updateFrame(id, to: frame)
            return (s, [])

        case .dragEnded:
            // Re-assert layout: a tiled window the user dragged off its target snaps back (§11).
            let effects = emitPlacements(&s)
            return (s, effects)

        case .focusChanged(let id):
            // Externally-initiated focus (Cmd-Tab, Dock click, self-activation) *and* the echo of our
            // own `focus` effect. Record it and **snap** the viewport to reveal it — we made no
            // motion, so we owe no animation (§4a). No `focus` effect: the shell already moved focus.
            s.world.setFocus(id)
            guard let id else { return (s, []) }   // focus left every managed window
            let effects = reveal(&s, id, center: s.config.centerFocusedColumn)
            return (s, effects)

        case .windowMinimized(let id):
            // Minimize leaves the strip like a close (2026-07-23 decision): drop it from layout,
            // re-place the rest, and move focus off it if it was focused.
            let wasFocused = s.world.focusedWindow == id
            s.world.setMinimized(id, true)
            s.motion.removeWindowAnimator(id)       // off the strip: same as a close, see above
            if wasFocused { s.world.setFocus(nil) }
            let effects = refocusAndPlace(&s)
            return (s, effects)

        case .windowDeminimized(let id):
            s.world.setMinimized(id, false)
            guard s.world.participatesInStrip(id) else {
                let effects = emitPlacements(&s)
                return (s, effects)
            }
            s.world.setFocus(id)            // restoring re-focuses, like a fresh window
            var effects = reveal(&s, id, center: s.config.centerFocusedColumn)
            effects.append(.focus(id))
            return (s, effects)

        // MARK: Configuration
        //
        // A reload is a `screensChanged` by another route: both change the geometry every frame is
        // derived from without any window having moved, so both re-resolve the whole strip and keep
        // the focused column in view. Adopting the values first means `reveal` computes against the
        // *new* gaps and presets, which is the entire observable effect of editing the file.

        case .configChanged(let config):
            s.config = config
            // The spring is copied into the live animator, not just stored: `Motion` seeds it once at
            // construction (`State.init`), so a config that only changed the feel would otherwise
            // take effect at the next daemon start rather than the next scroll.
            s.motion.setScrollSpring(config.scrollSpring)
            if let focused = s.world.focusedWindow {
                let effects = reveal(&s, focused, center: config.centerFocusedColumn)
                return (s, effects)
            }
            let effects = emitPlacements(&s)
            return (s, effects)

        case .screensChanged(let infos):
            s.world.setMonitors(infos)
            // The working area may have changed — re-resolve every frame, keeping focus on-screen.
            if let focused = s.world.focusedWindow {
                let effects = reveal(&s, focused, center: s.config.centerFocusedColumn)
                return (s, effects)
            }
            let effects = emitPlacements(&s)
            return (s, effects)

        // MARK: Effect feedback — every effect's result is just another event (§1 invariant 3)

        case .captureReady(let id):
            // A scoped window's still is in, and it completes one of two waits.
            //
            //  · The cover is not up yet ⇒ when the *last* still arrives, raise it
            //    (`beginTransition`) and teleport the reals to their end frames behind it. From now
            //    on real windows may move with zero exposure.
            //  · The cover *is* up and this still belongs to a window a retarget pulled into scope ⇒
            //    grow the cover (`extendCover`) and place the new layers in the same frame.
            //
            // Total: a stray `captureReady` with no session, or one that completes neither wait,
            // no-ops.
            s.motion.markCaptured(id)
            if s.motion.isReadyToRaise {
                s.motion.raiseCover()
                guard let session = s.motion.transition else { return (s, []) }
                var effects: [Effect] = [.beginTransition(session.bindings)]
                effects += elevationEffects(s)      // z-order the bindings alone can't express
                effects += teleportBehindCover(&s)
                return (s, effects)
            }
            if s.motion.isReadyToExtend {
                let added = s.motion.extendCover()
                guard !added.isEmpty else { return (s, []) }
                // The `setLayerFrame`s ride along deliberately: `extendCover` and the blits are one
                // contiguous presentation run, so the shell wraps them in a single `CATransaction`
                // and a newcomer's layer is created *and* positioned in the same frame. Without them
                // it would show for one refresh at its capture-time frame — off-viewport, i.e. at the
                // 1 px park sliver — which is a flash exactly where the hole used to be.
                // …and the re-elevation rides along for a related reason: `extendCover` appends its
                // layers on *top*, which would bury a structural edit's mover under a window that
                // merely scrolled into scope.
                return (s, [.extendCover(added)] + elevationEffects(s) + emitLayerFrames(s))
            }
            return (s, [])

        case .coverUnavailable:
            // The capture plane has no pixels for us (see `Event.coverUnavailable`). Raising anyway
            // would black out the display, so abandon the session — nothing has moved yet, the phase
            // is still `.capturing` — and take §4a's path instead: snap the viewport to the
            // destination the spring was aiming at and place every window there at once.
            guard s.motion.isTransitioning, !s.motion.isCovered else { return (s, []) }
            s.motion.abortTransition()          // snaps the viewport to its target
            let effects = emitPlacements(&s)
            return (s, effects)

        case .axLanded(let id):
            // A real window arrived at its AX target. If that was the last scoped landing and the
            // animators have settled, cross-fade out. Total: no session ⇒ no-op (an idle set's ack).
            s.motion.markLanded(id)
            let effects = maybeCloseTransition(&s)
            return (s, effects)

        case .placementCorrected(let id, let requested, let actual):
            let effects = handlePlacementCorrected(&s, id, requested: requested, actual: actual)
            return (s, effects)

        case .axFailed(let id):
            // A set timed out or was clamped away. During a transition, resolve its landing so a single
            // stuck window can't wedge the cover open (the ~1 s `holdTimeout` is the ultimate backstop);
            // true retry/drop reconciliation of the truth is a later refinement. Idle ⇒ no-op for now.
            s.motion.markLanded(id)
            let effects = maybeCloseTransition(&s)
            return (s, effects)

        case .holdTimeout:
            // Bound the wait (§3): close the transition regardless of landing/settle — reveal the truth
            // and let any unlanded AX set finish in the open (a visibly hung app beats a frozen cover).
            // `closeTransition` snaps the viewport to its target so resting state matches the reveal.
            guard s.motion.isTransitioning else { return (s, []) }
            s.motion.closeTransition()
            return (s, [.endTransition])

        case .crossfadeDone:
            // The cover is fully down; steady state has already resumed (`closeTransition` ran when we
            // emitted `endTransition`). Nothing left to do — the ack just confirms the hand-off.
            return (s, [])
        }
    }

    // MARK: - Command handling

    /// Reduce a `Command`. Total over the vocabulary: the motion/focus verbs this slice owns produce
    /// effects; the rest are **deferred** (documented below) and no-op cleanly so the reducer stays
    /// total while their behavior lands with the subsystem each needs.
    private static func reduceCommand(_ s: inout State, _ command: Command) -> [Effect] {
        switch command {
        case .focus(let direction):
            return handleFocus(&s, direction)

        case .centerColumn:
            // A user-initiated scroll → animate it (no focus change; just re-frame the strip).
            guard let focused = s.world.focusedWindow else { return [] }
            return scrollReveal(&s, to: focused, center: true)

        case .cycleWidth:
            return handleCycleWidth(&s)

        case .moveWindow(let direction):
            return handleMoveWindow(&s, direction)

        case .consumeOrExpel(let direction):
            return handleConsumeOrExpel(&s, direction)

        case .reloadConfig:
            // Pure pass-through: the core has no idea where the file is or what it says. The shell
            // reads it and answers with `configChanged` — or with nothing at all, if it doesn't parse.
            return [.reloadConfig]

        // Deferred — each waits on a capability not built yet, so it no-ops rather than misbehave:
        //  · cycleHeight                  — unlike `cycleWidth` (landed M4 part 3) this is blocked on
        //    *state*, not on the resize path: `Layout` deliberately holds no per-window height
        //    selection ("heights are all-auto", `Layout.swift`), so there is nothing to cycle yet. It
        //    also can't ride the strip's own geometry the way a width can — a height is independent
        //    motion *within* one column, i.e. the `windowAnimators` channel.
        //  · fullscreen / float           — need float/fullscreen state modeling on the window.
        //  · moveToWorkspace / focusWorkspace / moveToMonitor — workspaces + multi-monitor are M6.
        //  · closeWindow                  — needs a new `Effect` (an AX close) not in the vocabulary yet.
        //
        // `dumpState` is different: it is **permanently** a no-op here, not a deferral. It's a *read*,
        // answered out of band by the shell straight off `Runtime.state` (`Ipc/RequestRouter.swift`,
        // decided 2026-07-24) — routing it through the reducer would mean an `Effect` carrying a live
        // reply channel, which `Effect`'s `Codable`-value contract forbids for zero gain.
        case .moveToWorkspace, .moveToMonitor, .cycleHeight, .fullscreen, .float,
             .focusWorkspace, .closeWindow, .dumpState:
            return []
        }
    }

    /// Move keyboard focus. Horizontal (left/right) crosses to the neighbouring column and reveals
    /// it; vertical (up/down) moves within the focused column's stack (no scroll). With nothing
    /// focused, either direction focuses the first window on the strip. No-op at an edge (no wrap) or
    /// on an empty strip.
    private static func handleFocus(_ s: inout State, _ direction: Direction) -> [Effect] {
        s.layout.reconcile(stripWindowIds: s.world.stripWindowIds)

        // Nothing focused yet: focus the first window on the strip, wherever the direction pointed.
        guard let current = s.world.focusedWindow else {
            guard let first = s.layout.allWindowIds.first else { return [] }
            s.world.setFocus(first)
            return scrollReveal(&s, to: first, center: s.config.centerFocusedColumn) + [.focus(first)]
        }

        switch direction.axis {
        case .horizontal:
            guard let column = s.layout.columnIndex(ofWindow: current) else { return [] }
            let targetColumn = direction == .right ? column + 1 : column - 1
            guard s.layout.columns.indices.contains(targetColumn),
                  let target = s.layout.columns[targetColumn].windowIds.first else { return [] }
            s.world.setFocus(target)
            // Crossing columns scrolls the strip → animate under a cover (a snap when already in view).
            return scrollReveal(&s, to: target, center: s.config.centerFocusedColumn) + [.focus(target)]

        case .vertical:
            guard let column = s.layout.columnIndex(ofWindow: current) else { return [] }
            let stack = s.layout.columns[column].windowIds
            guard let row = stack.firstIndex(of: current) else { return [] }
            let targetRow = direction == .down ? row + 1 : row - 1
            guard stack.indices.contains(targetRow) else { return [] }
            let target = stack[targetRow]
            s.world.setFocus(target)
            // Within-column focus doesn't scroll the strip; just focus + raise the window.
            return [.focus(target), .raise(target)]
        }
    }

    // MARK: - Structural edits (the strip rearranged, under the cover)

    /// Everything a structural command must read off the *old* geometry before it destroys it — the
    /// arguments `finishStructuralEdit` needs and cannot re-derive once `Layout` has mutated.
    ///
    /// `widths` is captured once and used for **both** `naturalFrames` calls: with the same offset and
    /// the same width overrides on either side of the edit, the scroll and any in-flight resize cancel
    /// in the difference, and what survives is purely structural. (`Layout.strip(metrics:widths:)`
    /// already ignores an override for a column it no longer has, so a stale entry for a column the
    /// edit destroyed is not just safe but identical to a pruned map.)
    private struct StructuralSnapshot {
        /// The scroll offset both `naturalFrames` calls are asked at.
        let start: Double
        /// The in-flight column widths both calls resolve against.
        let widths: [ColumnId: Double]
        /// Where every window sat under the geometry we are leaving.
        let frames: [WindowId: Rect]
        /// What was on screen under that geometry — half of the two-geometry scope.
        let departing: [WindowId]
    }

    /// Read the old geometry, after `reconcile` and after the handler's guards. **Ordering matters:**
    /// taken before `reconcile` it would attribute the membership bridge's own churn (a window the
    /// scan just added or dropped) to the edit, which for an appended column is a large bogus
    /// displacement on windows that never moved.
    private static func structuralSnapshot(_ s: State, _ metrics: LayoutMetrics) -> StructuralSnapshot {
        let start = s.motion.viewportOffset.current
        let widths = s.motion.currentColumnWidths
        return StructuralSnapshot(
            start: start,
            widths: widths,
            frames: s.layout.naturalFrames(scrollOffset: start, metrics: metrics, widths: widths),
            departing: s.layout.visibleWindowIds(scrollOffset: start, metrics: metrics))
    }

    /// Move the focused window one slot. **Horizontal** branches on whether it has company: a window
    /// *alone* in its column moves the whole column one place along the strip; a window with
    /// *stackmates* pops out into a new single-window column on that side. **Vertical** swaps it
    /// with the window above or below it in its column's stack.
    ///
    /// Focus never moves — it is already on the window that moved — so no `.focus` effect is owed, and
    /// emitting one anyway would be a redundant AX set that can make an app raise itself. No wrap at
    /// either edge, matching `handleFocus`; the clamping in `Layout`'s mutators is what produces it.
    private static func handleMoveWindow(_ s: inout State, _ direction: Direction) -> [Effect] {
        s.layout.reconcile(stripWindowIds: s.world.stripWindowIds)
        // Metrics guard before the mutation, as `handleCycleWidth` does: with no display known there
        // is no correct frame to place the result at, so the strip stays exactly as it was.
        guard let metrics = s.metrics(),
              let focused = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: focused) else { return [] }

        let old = structuralSnapshot(s, metrics)

        // Read the column out *before* mutating. `ColumnLayout` is a value type, so this is a copy —
        // which is what we want (it must not be re-read afterwards), and passing `s.layout.columns[…]`
        // straight into a `mutating` call on `s.layout` would be an overlapping access besides.
        let column = s.layout.columns[index]
        let edit: LayoutEdit
        switch direction.axis {
        case .horizontal:
            edit = column.windowIds.count == 1
                ? s.layout.moveColumn(column.id, to: direction == .right ? index + 1 : index - 1)
                : s.layout.extract(window: focused,
                                   toNewColumnAt: direction == .right ? index + 1 : index)
        case .vertical:
            guard let row = column.windowIds.firstIndex(of: focused) else { return [] }
            edit = s.layout.moveWindowWithinColumn(focused, to: direction == .down ? row + 1 : row - 1)
        }
        // Every branch here moves the focused window — the whole column when it is alone in one, and
        // the whole column is one window in that case. So the mover is always `focused`, which is
        // exactly what `consumeOrExpel` cannot say.
        return finishStructuralEdit(&s, edit, focused: focused, mover: focused, old: old)
    }

    /// Consume or expel. **Horizontal** branches on company, the opposite way `moveWindow` does: a
    /// window *alone* in its column is CONSUMED into the neighbouring column's stack on that side; one
    /// with *stackmates* is EXPELLED into a new single-window column there. **Vertical is not the same
    /// idea twice** — hence the switch over `direction` rather than `direction.axis`, which is the one
    /// thing here that copying `handleFocus`'s shape would get wrong while still compiling: `down`
    /// pulls the top window of the *next* column into the bottom of this one, `up` pushes the focused
    /// window out into its own new column to the right.
    ///
    /// A consumed window lands **adjacent to where it was in layout order** — left ⇒ the bottom of the
    /// left neighbour, right ⇒ the top of the right one. `Layout.allWindowIds` is the strip's reading
    /// order, so "the smallest move in that order" is one rule instead of two conventions, and it makes
    /// consume and expel exact inverses.
    ///
    /// The two directions disagree about the strip's end, on purpose. A *consume* with no neighbour is
    /// a no-op — there is nothing to merge into. An *expel* at the same place still creates its column,
    /// because the strip has an origin, not an edge: index 0 and `columns.count` are ordinary places on
    /// an unbounded axis.
    private static func handleConsumeOrExpel(_ s: inout State, _ direction: Direction) -> [Effect] {
        s.layout.reconcile(stripWindowIds: s.world.stripWindowIds)
        guard let metrics = s.metrics(),
              let focused = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: focused) else { return [] }

        let old = structuralSnapshot(s, metrics)

        let column = s.layout.columns[index]      // a copy; never re-read after the mutation
        let edit: LayoutEdit
        // The window that travels, which is `focused` everywhere except `down`. It is what the cover
        // draws on top, so getting it wrong is visible rather than merely wrong.
        var mover = focused
        switch direction {
        case .left, .right:
            if column.windowIds.count > 1 {
                edit = s.layout.extract(window: focused,
                                        toNewColumnAt: direction == .right ? index + 1 : index)
            } else {
                let side = direction == .right ? index + 1 : index - 1
                guard s.layout.columns.indices.contains(side) else { return [] }
                let neighbour = s.layout.columns[side]
                let row = direction == .right ? 0 : neighbour.windowIds.count
                edit = s.layout.move(window: focused, toColumn: neighbour.id, at: row)
            }

        case .down:
            // The *pulled* window moves, not the focused one — which is why focus is untouched here
            // too. `column.windowIds.count` is the pre-merge stack height, i.e. the bottom row.
            guard s.layout.columns.indices.contains(index + 1),
                  let pulled = s.layout.columns[index + 1].windowIds.first else { return [] }
            mover = pulled
            edit = s.layout.move(window: pulled, toColumn: column.id, at: column.windowIds.count)

        case .up:
            edit = s.layout.extract(window: focused, toNewColumnAt: index + 1)
        }
        return finishStructuralEdit(&s, edit, focused: focused, mover: mover, old: old)
    }

    /// Finish a structural command: retire a destroyed column's width animator, seed the per-window
    /// **displacements** the edit created, name the window that rides on top, and open (or ride) a
    /// transition so the strip rearranges in motion rather than in a jump.
    ///
    /// **What animates is a displacement, not a position, and that is what makes this derived rather
    /// than choreographed.** `Layout` has already mutated and remains the sole authority on where each
    /// window belongs; what goes under a spring is the *difference* between where a window was and
    /// where it now belongs, decaying to zero (`Motion.windowAnimators`, `RectAnimator`). Three things
    /// fall out and none of them had to be arranged: the first frame reproduces the old layout exactly
    /// (so the raise cannot pop — the shell gave each layer its capture-time frame, which *is* that
    /// frame), a settled animator contributes nothing (so `closeTransition` may drop them, as it
    /// already drops the widths), and a second edit mid-flight is a `nudge` — position continuous to
    /// the point, velocity carried through. It also composes with the two existing quantities for
    /// free: a scroll and an in-flight resize both change the frame this is *added to*.
    ///
    /// **The scope spans two geometries**, exactly as `handleCycleWidth`'s does and for the identical
    /// reason: a column the edit evicts from the viewport is on screen *before* and not swept *after*,
    /// and scoping on the new geometry alone would slide it out as a hole showing wallpaper.
    ///
    /// **`driveTransition` needs no argument for any of this.** It already opens-or-redirects, widens
    /// the scope over what the new destination sweeps, captures the newcomers, and re-teleports the
    /// reals behind a raised cover — which is also the whole of what the old snap path hand-rolled
    /// here, plus the scope widening it was missing.
    ///
    /// Three snaps remain, in the order they are cheapest to decide: an edit that changed nothing (an
    /// edge press stays silent), no capture capability or an empty scope (§4a — the strip still lands
    /// exactly where the animated path would have converged), and an edit that displaced nothing the
    /// cover could show.
    private static func finishStructuralEdit(_ s: inout State, _ edit: LayoutEdit,
                                             focused: WindowId, mover: WindowId,
                                             old: StructuralSnapshot) -> [Effect] {
        guard edit.moved else { return [] }
        if let dead = edit.destroyedColumn { s.motion.removeColumnWidthAnimator(dead) }
        guard let metrics = s.metrics() else { return emitPlacements(&s) }

        // Where the focused column sits under the *new* structure. There is deliberately no
        // `end == start ⇒ snap` guard, for `handleCycleWidth`'s reason: a swap in full view moves the
        // viewport not at all and is still the thing we are here to animate.
        let end = (s.config.centerFocusedColumn
            ? s.layout.scrollOffsetToCenter(window: focused, metrics: metrics)
            : s.layout.scrollOffsetToReveal(window: focused, from: old.start, metrics: metrics))
            ?? old.start

        let scope = scopeUnion(s.layout, old.departing,
                               s.layout.sweptWindowIds(from: old.start, to: end, metrics: metrics))

        guard s.motion.isTransitioning || (s.config.smoothTransitions && !scope.isEmpty) else {
            s.motion.snapViewport(to: end)
            return emitPlacements(&s)
        }

        // The second half of the difference, asked of the new layout at the *same* offset and the
        // *same* widths — see `StructuralSnapshot`.
        let new = s.layout.naturalFrames(scrollOffset: old.start, metrics: metrics, widths: old.widths)
        var displaced = 0
        for id in scope {           // scoped only: a window with no layer has nothing to lag behind
            guard let was = old.frames[id], let now = new[id],
                  !approximatelyEqual(was, now) else { continue }
            s.motion.displaceWindow(id, by: was.delta(from: now), params: s.config.moveSpring)
            displaced += 1
        }

        // An edit no window on screen can see — e.g. reordering two columns that are both parked.
        // Nothing to cover, so don't stand one up.
        guard displaced > 0 || s.motion.isTransitioning else {
            s.motion.snapViewport(to: end)
            return emitPlacements(&s)
        }

        var effects = driveTransition(&s, to: end, scope: scope)
        // *After* `driveTransition`, which is where a fresh session comes into existence — `elevate`
        // is a mutator on the session and no-ops without one.
        s.motion.elevate(mover)
        // Emits nothing for a session still capturing (no layers yet — the raise will emit it), and
        // nothing for a mover this edit only just pulled into scope (`extendCover` will). So this is
        // reached with something to say only when a cover was already up over a window we can name.
        effects += elevationEffects(s)
        return effects
    }

    /// `Effect.elevateLayer` for the window this transition draws on top, or nothing — no session,
    /// nothing elevated (a scroll or a resize), or a cover that isn't up yet. Emitted at the raise,
    /// after every `extendCover`, and on a structural edit under a raised cover; total everywhere, so
    /// all three call sites can append it unconditionally.
    private static func elevationEffects(_ s: State) -> [Effect] {
        guard let layer = s.motion.elevatedLayer else { return [] }
        return [.elevateLayer(layer)]
    }

    // MARK: - Placement (the instant-correct core, §4a)

    /// Snap the viewport to reveal `id`'s column (centered, or minimally revealed per config) and
    /// re-place every window — the **no-animation** reveal (§4a): new window, close/retile, display
    /// change, and *externally-initiated* focus, none of which we owe a smoothness promise. Reconciles
    /// first so a just-inserted window is on the strip before its offset is computed.
    ///
    /// Transition-safe by construction: in the (rare) case a snap-path event lands while an animated
    /// scroll is still in flight, we must not `snap` the viewport out from under a raised cover — that
    /// would tear the animation. We instead *redirect* the running scroll (retarget, velocity carried)
    /// and leave the session's teleport/landing bookkeeping to the command path (`scrollReveal`). In
    /// steady state — the overwhelmingly common case — this is a plain snap + place.
    private static func reveal(_ s: inout State, _ id: WindowId, center: Bool) -> [Effect] {
        s.layout.reconcile(stripWindowIds: s.world.stripWindowIds)
        guard let metrics = s.metrics() else { return [] }
        let offset = center
            ? s.layout.scrollOffsetToCenter(window: id, metrics: metrics)
            : s.layout.scrollOffsetToReveal(window: id, from: s.motion.viewportOffset.current, metrics: metrics)
        if s.motion.isTransitioning {
            if let offset { s.motion.retargetViewport(to: offset) }
            return []
        }
        if let offset { s.motion.snapViewport(to: offset) }
        return emitPlacements(&s)
    }

    // MARK: - The animated scroll (the transition session, §4b)

    /// Reveal `id`'s column with an **animated** transition under a layered cover — the animated
    /// counterpart to `reveal`'s snap, driven by the user-initiated scroll commands (`focus` across
    /// columns, `centerColumn`). Three paths:
    ///
    ///  · **Interrupt** (a transition already open): retarget the running scroll to the new end
    ///    (velocity preserved — the whole point of core-owned motion, §7), widen the scope over the
    ///    newly-swept interval and capture whatever it added, and — if the cover is up — re-teleport
    ///    the reals to the new end behind it. One session throughout; never a second.
    ///  · **No motion** (the target column is already in view): degrade to a plain snap-place — there is
    ///    nothing to animate, so we don't stand up a cover.
    ///  · **No cover available** (`Config.smoothTransitions == false`, i.e. no Screen Recording grant):
    ///    the same snap-place. The window still lands correctly; it just gets there at once (§4a).
    ///  · **Fresh scroll**: scope the transition to every window the viewport *sweeps* between the
    ///    start and end offsets (§3, `Layout.sweptWindowIds`), open the session, `capture` each, and
    ///    aim the viewport spring at the end. The cover is raised — and the reals teleported — later,
    ///    once every capture is in (`captureReady`).
    private static func scrollReveal(_ s: inout State, to id: WindowId, center: Bool) -> [Effect] {
        s.layout.reconcile(stripWindowIds: s.world.stripWindowIds)
        guard let metrics = s.metrics() else { return [] }
        let start = s.motion.viewportOffset.current
        let end = center
            ? s.layout.scrollOffsetToCenter(window: id, metrics: metrics)
            : s.layout.scrollOffsetToReveal(window: id, from: start, metrics: metrics)
        guard let end else { return [] }

        if s.motion.isTransitioning {
            return driveTransition(&s, to: end,
                                   scope: s.layout.sweptWindowIds(from: start, to: end, metrics: metrics))
        }

        if approximatelyEqualScalar(end, start) {
            return emitPlacements(&s)               // already in view → snap, no cover
        }

        // No capture capability ⇒ no cover worth raising (`Config.smoothTransitions`). Degrade to §4a:
        // snap the viewport and place. Checked *before* the scope is computed, because a cover we
        // cannot fill with pixels shouldn't cost us the walk that decides what would have been in it.
        guard s.config.smoothTransitions else {
            s.motion.snapViewport(to: end)
            return emitPlacements(&s)
        }

        let scope = s.layout.sweptWindowIds(from: start, to: end, metrics: metrics)
        guard !scope.isEmpty else {                 // defensive: nothing to cover → snap
            s.motion.snapViewport(to: end)
            return emitPlacements(&s)
        }
        return driveTransition(&s, to: end, scope: scope)
    }

    /// Open a transition aimed at `end` over `scope`, or — if one is already running — **redirect** it
    /// there. The single place a session is opened or re-aimed, shared by every command that produces
    /// motion (`scrollReveal`'s scroll, `handleCycleWidth`'s resize), so the interrupt story is written
    /// once instead of per-verb.
    ///
    /// The redirect path is the subtle one, and it is M4 part 2's rule: the scope a session was opened
    /// with was computed for a destination it is no longer travelling to, so it is **widened** — never
    /// replaced — and each newcomer owes a `capture` (it joins the batch the raise is waiting on if the
    /// cover is not up yet, and grows the cover through `Effect.extendCover` if it is). Growth is the
    /// only safe direction: a window the *old* destination swept is already mid-flight on the
    /// presentation plane and mid-teleport on the truth plane. The reals are re-teleported to the new
    /// end behind the still-raised cover, which also re-arms the landing wait.
    ///
    /// The caller owns the snap decisions (nothing to animate, no capture capability, empty scope);
    /// by the time we are here the answer is "a transition", and the only question is whether it is a
    /// new one.
    private static func driveTransition(_ s: inout State, to end: Double, scope: [WindowId]) -> [Effect] {
        guard s.motion.isTransitioning else {
            s.motion.openTransition(scope: scope)
            s.motion.retargetViewport(to: end)
            return scope.map { .capture($0) }
        }
        s.motion.retargetViewport(to: end)
        let newcomers = s.motion.extendTransition(scope: scope)
        var effects: [Effect] = newcomers.map { .capture($0) }
        if s.motion.isCovered { effects += teleportBehindCover(&s) }
        return effects
    }

    // MARK: - The animated resize (§4d, and the strip's own geometry in motion)

    /// Cycle the focused column to its next preset width — the first command whose motion is **not** a
    /// scroll. Three things make it different from `scrollReveal`, and they are the whole of this slice:
    ///
    ///  · **It animates a second quantity.** The column's *resolved width* goes under a spring
    ///    (`Motion.animateColumnWidth`), and the presentation plane resolves the strip against it
    ///    (`Layout.naturalFrames(…, widths:)`). Every consequence — this column's windows growing, every
    ///    column to its right sliding — is then derived rather than choreographed, in lockstep, exactly
    ///    as a scroll's is derived from the offset.
    ///  · **It warrants a transition even when the viewport does not move.** `scrollReveal` snaps when
    ///    start and end agree, because then there is nothing to animate; here there always is, because
    ///    the geometry changed underneath a stationary viewport. The `end == start` guard is deliberately
    ///    absent, not forgotten.
    ///  · **The scope spans two geometries.** The windows on screen *before* the resize and the windows
    ///    the viewport sweeps *after* it are answers to the same question asked of different strips —
    ///    a column pushed off the right edge by a growing neighbour is in the first and not the second.
    ///    The scope is their union (M4 part 2's rule again: a scope only ever grows), re-sorted into
    ///    layout order because that order is the cover's z-order.
    ///
    /// The truth plane is unchanged: the real windows teleport to their *final* size behind the cover,
    /// because only the owning app can produce resized pixels (`PRINCIPLES.md` §6). What the user watches
    /// is a scaled still — §4d's "cross-fade a scaled screenshot over it until the app redraws", except
    /// the cross-fade is the one the cover already performs, so §4d needs no mechanism of its own.
    private static func handleCycleWidth(_ s: inout State) -> [Effect] {
        s.layout.reconcile(stripWindowIds: s.world.stripWindowIds)
        guard let metrics = s.metrics(),
              let focused = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: focused) else { return [] }

        let column = s.layout.columns[index]
        let nextPreset = metrics.widthPresets.nextIndex(after: column.widthPreset)
        // Resolved, not raw preset: a column an app has already widened is *at* the corrected width,
        // and animating from the preset would start the spring somewhere the layers are not. The new
        // preset is a question nobody has answered yet, so `toWidth` is ordinarily the preset itself —
        // and if the app refuses it, `placementCorrected` retargets this same animator mid-flight.
        let fromWidth = s.layout.resolvedWidth(of: column, metrics: metrics)

        // Asked *before* the preset changes: what is on screen under the geometry we are leaving.
        let start = s.motion.viewportOffset.current
        let departing = s.layout.visibleWindowIds(scrollOffset: start, metrics: metrics)

        s.layout.setWidthPreset(nextPreset, ofColumn: column.id)
        let toWidth = s.layout.resolvedWidth(ofColumn: column.id, metrics: metrics) ?? fromWidth

        // A single-preset cycle (or two presets that resolve to the same points) changes nothing to
        // look at. The index still advanced, so a later press moves on; `emitPlacements` diffs to
        // nothing and the command is silent.
        guard !approximatelyEqualScalar(fromWidth, toWidth) else { return emitPlacements(&s) }

        // Where the focused column sits under the *new* widths — a resize scrolls too, because a column
        // that just grew may no longer fit where it was.
        let end = (s.config.centerFocusedColumn
            ? s.layout.scrollOffsetToCenter(window: focused, metrics: metrics)
            : s.layout.scrollOffsetToReveal(window: focused, from: start, metrics: metrics)) ?? start

        let scope = scopeUnion(s.layout, departing,
                               s.layout.sweptWindowIds(from: start, to: end, metrics: metrics))

        // §4a, for a machine with no Screen Recording grant or an empty scope: resize at once. The
        // column still ends up exactly the width the animated path would have converged on.
        guard s.motion.isTransitioning || (s.config.smoothTransitions && !scope.isEmpty) else {
            s.motion.snapViewport(to: end)
            return emitPlacements(&s)
        }

        s.motion.animateColumnWidth(column.id, from: fromWidth, to: toWidth, params: s.config.resizeSpring)
        return driveTransition(&s, to: end, scope: scope)
    }

    /// Two scoped window sets merged and re-sorted into **layout order** — which is the cover's z-order,
    /// bottom→top. Used where a scope is assembled from more than one query (`handleCycleWidth`), so the
    /// result reads left→right across the strip rather than in the order the queries happened to run.
    private static func scopeUnion(_ layout: Layout, _ a: [WindowId], _ b: [WindowId]) -> [WindowId] {
        let wanted = Set(a).union(b)
        return layout.allWindowIds.filter { wanted.contains($0) }
    }

    /// Teleport the *real* windows to their frames at the scroll's **end** (`viewportOffset.target`)
    /// behind the raised cover, and re-arm the transition's landing wait to exactly the scoped windows
    /// that actually moved. Called at cover-raise and on an interrupt re-teleport. All strip windows
    /// are repositioned (a park→park window's sliver ordinal can shift too), but only *scoped* moves are
    /// waited on — park→park motion is invisible and doesn't gate the close (§3). Reuses the
    /// `emitPlacements` diff+optimistic-update discipline, just at the target offset rather than current.
    private static func teleportBehindCover(_ s: inout State) -> [Effect] {
        s.layout.reconcile(stripWindowIds: s.world.stripWindowIds)
        guard let metrics = s.metrics(), let scope = s.motion.transition?.windows else { return [] }
        let offset = s.motion.viewportOffset.target
        let frames = s.layout.targetFrames(scrollOffset: offset, metrics: metrics)
        let visible = Set(s.layout.visibleWindowIds(scrollOffset: offset, metrics: metrics))
        let questions = s.layout.naturalFrames(scrollOffset: 0, metrics: metrics.uncorrected)
        let scopeSet = Set(scope)

        var effects: [Effect] = []
        var moved: [WindowId] = []
        for id in s.layout.allWindowIds {
            guard let target = frames[id] else { continue }
            if isAlreadyPlaced(s.world, id, at: target, question: questions[id]?.size) { continue }
            effects.append(visible.contains(id) ? .setFrame(id, target) : .park(id, target))
            s.world.updateFrame(id, to: target)     // optimistic: AX will land here (or axFailed)
            if scopeSet.contains(id) { moved.append(id) }
        }
        s.motion.armLandings(moved)                 // wait only on the scoped windows that moved
        return effects
    }

    /// Blit one `setLayerFrame` per reconstruction layer this frame — the cover's per-window stand-ins
    /// sliding to their **natural** (un-parked) positions at the current scroll offset (§4b). A window
    /// scrolling off-view glides smoothly off the screen edge here, while its hidden real counterpart
    /// sits parked at a corner sliver (`teleportBehindCover`). In z-order (bottom→top) via the session's
    /// bindings. Pure read of `State`; the tick already advanced the animators.
    ///
    /// **Every frame is one derived rect plus three animated quantities, and none of them knows about
    /// the others.** The offset positions the strip; `Motion.currentColumnWidths` re-resolves its
    /// geometry (empty except during a `cycleWidth`, which is the entire resize animation on this
    /// side — the growing column's layers grow and every column right of it slides, without this
    /// function knowing a resize is happening); and `Motion.displacement(of:)` adds each window's
    /// in-flight lag behind the layout (`.zero` except during a structural edit, which is that whole
    /// animation on this side, for the same reason). Summing into a derived frame is what keeps them
    /// orthogonal: three quantities, not three authorities on one number.
    private static func emitLayerFrames(_ s: State) -> [Effect] {
        guard let metrics = s.metrics(), let session = s.motion.transition else { return [] }
        let frames = s.layout.naturalFrames(scrollOffset: s.motion.viewportOffset.current,
                                            metrics: metrics,
                                            widths: s.motion.currentColumnWidths)
        return session.bindings.compactMap { binding in
            frames[binding.window].map {
                .setLayerFrame(binding.layer, $0.displaced(by: s.motion.displacement(of: binding.window)))
            }
        }
    }

    /// Cross-fade out iff the transition is fully done — cover raised, every scoped AX set landed, and
    /// all animators settled (`Motion.isReadyToClose`). Tears the session down (snapping the viewport to
    /// its target so resting state matches the reveal) and emits `endTransition`. Checked after both a
    /// settling `tick` and a final `axLanded`, whichever completes the gate last.
    private static func maybeCloseTransition(_ s: inout State) -> [Effect] {
        guard s.motion.isReadyToClose else { return [] }
        s.motion.closeTransition()
        return [.endTransition]
    }

    /// After focus may have been cleared (destroy/minimize), pick a new focus if the strip still has
    /// windows and none is focused, then place. Keeps the strip usable without a manual focus command.
    /// The neighbour policy is intentionally simple for now (the first window in layout order); a
    /// spatially-nearest choice can refine it later without changing the shape here.
    private static func refocusAndPlace(_ s: inout State) -> [Effect] {
        s.layout.reconcile(stripWindowIds: s.world.stripWindowIds)
        if s.world.focusedWindow == nil, let next = s.layout.allWindowIds.first {
            s.world.setFocus(next)
            return reveal(&s, next, center: s.config.centerFocusedColumn) + [.focus(next)]
        }
        return emitPlacements(&s)
    }

    // MARK: - Windows that refuse the size we ask for

    /// Fold a **tiled** landing that came back a different size than we asked for: record the truth,
    /// remember the answer, and re-place so the strip is built around what the window actually is.
    ///
    /// This is the whole of "ask the question once, then use the answer" on the reducer's side.
    /// Everything interesting is in what it *declines* to learn from:
    ///
    ///  · **A stale report.** The write went out, and the layout changed before the ack came back. What
    ///    the app answered is no longer an answer to any question we are asking, so the frame is
    ///    recorded and nothing is learned. Compared on **size** alone, deliberately: `emitPlacements`
    ///    writes at `viewportOffset.current` and `teleportBehindCover` at `.target`, so a legitimate
    ///    position difference is normal, and position is not what a column's geometry is built from.
    ///  · **Position-only drift.** A window that went where we asked but at the size we asked is not
    ///    telling us anything about size. (A window that refuses a *position* is a real and separate
    ///    problem — the 1 px park sliver is one — but it never overlaps a neighbour.)
    ///
    /// The question itself (`Layout.uncorrectedSize`) is what makes the record self-invalidating, so
    /// there is no expiry to maintain and nothing that can ratchet: see `SizeCorrection`.
    private static func handlePlacementCorrected(_ s: inout State, _ id: WindowId,
                                                 requested: Rect, actual: Rect) -> [Effect] {
        s.world.updateFrame(id, to: actual)          // truth first, exactly as `windowFrameChanged` does

        guard let metrics = s.metrics(),
              let index = s.layout.columnIndex(ofWindow: id),
              let live = s.layout.targetFrames(scrollOffset: s.motion.viewportOffset.target,
                                               metrics: metrics)[id],
              approximatelyEqualSize(requested.size, live.size),      // not stale
              !approximatelyEqualSize(actual.size, requested.size),   // actually about size
              let question = s.layout.uncorrectedSize(of: id, metrics: metrics)
        else { return [] }

        let column = s.layout.columns[index]
        let before = s.layout.resolvedWidth(of: column, metrics: metrics)
        s.world.noteCorrection(id, wanted: question, actual: actual.size)
        guard let corrected = s.metrics() else { return [] }
        let after = s.layout.resolvedWidth(of: column, metrics: corrected)

        // Under a cover every layer frame is re-derived from the strip's geometry each tick, so a
        // column that changes width between two frames *jumps*. Put the change under the resize spring
        // instead — the same quantity `cycleWidth` animates, retargeted in place when one is already in
        // flight — and the column springs to the width the app insisted on. During a resize this is
        // also required for correctness: the layers must converge on the width the reals were
        // teleported to, or the cross-fade has something to pop against.
        if s.motion.isTransitioning, !approximatelyEqualScalar(before, after) {
            s.motion.animateColumnWidth(column.id, from: before, to: after, params: s.config.resizeSpring)
        }

        // Mid-capture there is no cover yet and no real window has moved for this session; the raise's
        // own teleport is moments away and will read the correction we just recorded. Placing here
        // would move real windows out from under a transition that hasn't started hiding them.
        if s.motion.isCovered { return teleportBehindCover(&s) }
        return s.motion.isTransitioning ? [] : emitPlacements(&s)
    }

    /// Whether a window needs no set: it is already at its target, **or** it is at the answer we know
    /// it gives to the question the layout is currently asking, and in the right place.
    ///
    /// The second clause is the other half of `SizeCorrection`, and it is what makes the loop quiet in
    /// the direction geometry deliberately ignores. A terminal that quantizes its width 8 pt *down*
    /// leaves a gap rather than an overlap, so `Layout.resolvedWidth` does not widen the column for it —
    /// but without this the diff would never match and every placement, forever, would re-issue a set
    /// we already know the answer to. Position is still compared exactly: the strip scrolls, and a
    /// window at the right size in the wrong place must still move.
    private static func isAlreadyPlaced(_ world: World, _ id: WindowId,
                                        at target: Rect, question: Size?) -> Bool {
        guard let known = world.windows[id]?.frame else { return false }
        if approximatelyEqual(known, target) { return true }
        guard let correction = world.corrections[id], let question,
              approximatelyEqualSize(correction.wanted, question),
              approximatelyEqualSize(known.size, correction.actual)
        else { return false }
        return approximatelyEqualScalar(known.minX, target.minX)
            && approximatelyEqualScalar(known.minY, target.minY)
    }

    /// Emit the `setFrame`/`park` sets that bring every managed window to its target frame at the
    /// current scroll offset — the instant, correct placement the product floors on. A window whose
    /// column overlaps the viewport is `setFrame`d to its tiled frame; a window scrolled off-view is
    /// `park`ed at its sliver slot (§4a). Only windows that actually need to move are emitted (diffed
    /// against last-known truth within a sub-pixel tolerance), so a redundant re-place is silent.
    ///
    /// The moved windows' `World` frames are updated **optimistically** to their targets: we set it,
    /// it will land, and a failure comes back as `axFailed` for the transition slice to reconcile —
    /// this is what keeps a repeated idle event from re-emitting the same set forever. Reconciles
    /// first so structural churn (a new/departed window) is reflected before frames are computed.
    private static func emitPlacements(_ s: inout State) -> [Effect] {
        s.layout.reconcile(stripWindowIds: s.world.stripWindowIds)
        guard let metrics = s.metrics() else { return [] }
        let offset = s.motion.viewportOffset.current
        let frames = s.layout.targetFrames(scrollOffset: offset, metrics: metrics)
        let visible = Set(s.layout.visibleWindowIds(scrollOffset: offset, metrics: metrics))
        let questions = s.layout.naturalFrames(scrollOffset: 0, metrics: metrics.uncorrected)

        var effects: [Effect] = []
        for id in s.layout.allWindowIds {          // deterministic column-then-stack order
            guard let target = frames[id] else { continue }
            if isAlreadyPlaced(s.world, id, at: target, question: questions[id]?.size) { continue }
            effects.append(visible.contains(id) ? .setFrame(id, target) : .park(id, target))
            s.world.updateFrame(id, to: target)    // optimistic: AX will land here (or axFailed)
        }
        return effects
    }

    /// Frames within half a point on every edge are "already there" — a placement no-op. Avoids
    /// re-emitting sets for sub-pixel rounding drift between the layout math and observed truth.
    private static func approximatelyEqual(_ a: Rect, _ b: Rect, tolerance: Double = 0.5) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Two sizes within half a point on both axes. The comparison a `SizeCorrection` is matched with,
    /// on both sides: a question against the layout's, and an answer against observed truth.
    private static func approximatelyEqualSize(_ a: Size, _ b: Size, tolerance: Double = 0.5) -> Bool {
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Two scroll offsets within half a point are "the same" — the guard that keeps a reveal of an
    /// already-in-view column a snap-place rather than a zero-distance transition (nothing to animate).
    private static func approximatelyEqualScalar(_ a: Double, _ b: Double, tolerance: Double = 0.5) -> Bool {
        abs(a - b) <= tolerance
    }
}
