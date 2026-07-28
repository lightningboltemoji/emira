import Foundation
import EmiraMotion

// The reducer: `reduce(State, Event) -> (State, [Effect])`. Pure and framework-free — AX / Core
// Animation / ScreenCaptureKit are only named, through `Effect` — and total over `Event`.
//
// A change we did not initiate (new window, close, display change, external focus) snaps every window to
// its target frame. A change the user asked for (scroll, resize, structural edit, workspace switch) runs
// a covered transition: capture the scoped windows, raise a layered cover, teleport the reals behind it,
// animate the layers, drop the cover when everything settles.

/// The complete core state — a value type throughout, so it dumps to JSON and replays deterministically.
public struct State: Sendable, Equatable, Codable {
    /// Truth: what actually exists on the system (windows, apps, monitors, focus).
    public var world: World
    /// Structure: the 36-address workspace set — one strip per materialized workspace, which one is
    /// focused, and the `ColumnId` allocator they share.
    public var workspaces: Workspaces
    /// Animation: the viewport-offset scroll, independent per-window motion, the transition session.
    public var motion: Motion
    /// The parsed config values the reducer reads (gaps, presets, struts, scroll feel).
    public var config: Config

    /// The focused workspace's strip — a projection of `workspaces`, not a second authority. Only the
    /// cross-workspace queries bypass it: reconcile, `targetFrames`, the placement walks, the mutators
    /// that mint a `ColumnId`.
    public var layout: Layout {
        get { workspaces.focusedStrip }
        set { workspaces.focusedStrip = newValue }
    }

    /// A fresh, empty state. The viewport spring is seeded from the config.
    public init(config: Config = Config()) {
        self.world = World()
        self.workspaces = Workspaces()
        self.motion = Motion(viewportOffset: 0, params: config.scrollSpring)
        self.config = config
    }

    /// Full memberwise init — for the reducer building a specific state, for replay, and for tests.
    public init(world: World, workspaces: Workspaces, motion: Motion, config: Config) {
        self.world = world
        self.workspaces = workspaces
        self.motion = motion
        self.config = config
    }

    /// The single-strip init: `layout` becomes the focused workspace's strip, nothing else materialized.
    public init(world: World, layout: Layout, motion: Motion, config: Config) {
        self.init(world: world,
                  workspaces: Workspaces(focused: .first, strips: [.first: layout]),
                  motion: motion, config: config)
    }

    /// Layout metrics for the current monitor + config, `nil` until the first `screensChanged` (so
    /// geometry commands no-op until then). Single-monitor: the first display, inset by the struts.
    public func metrics() -> LayoutMetrics? {
        guard let monitor = world.monitors.first else { return nil }
        return LayoutMetrics(
            workingArea: monitor.frame.inset(by: config.struts),
            widthPresets: config.widthPresets,
            heightPresets: config.heightPresets,
            heightSelections: workspaces.heightSelections,
            columnGap: config.columnGap,
            windowGap: config.windowGap,
            outerGaps: config.outerGaps,
            corrections: world.corrections)
    }
}

/// The pure reducer. Stateless namespace — all state travels through the `State` value.
public enum Engine {

    /// Fold one `Event` into a new `State`, emitting the `Effect`s the shell should run.
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
        // Ticks fire only while a transition is open, and are inert until the cover is raised.
        case .tick(let dt):
            guard s.motion.isCovered else { return (s, []) }
            s.motion.advance(by: dt)
            var effects = emitLayerFrames(s)
            effects += maybeCloseTransition(&s)
            return (s, effects)

        // MARK: Truth-plane observations — reality folded into `World`, then re-placed

        case .windowCreated(let snapshot):
            let before = strandedGeometry(&s)
            // Read before focus moves: the new column opens beside whatever had focus.
            let beside = insertionAnchor(s)
            s.world.insert(snapshot)
            // Read once, and *before* the guard below: `float` decides that guard's answer in both
            // directions — it can take a standard window off the strip and put a dialog on it.
            let rule = WindowRules.outcome(bundleId: snapshot.bundleId, title: snapshot.title,
                                           in: s.config.windowRules)
            if let float = rule.float { s.world.setFloating(snapshot.id, float) }
            // A non-tiling window (dialog/panel/sheet/float) is the app's to position.
            guard s.world.participatesInStrip(snapshot.id) else { return (s, []) }
            // A rule may send it to another workspace entirely, in which case it never joins the strip
            // in view and this arrival has nothing to animate.
            if let assigned = rule.workspace, assigned != s.workspaces.focused {
                let effects = arriveOnWorkspace(&s, snapshot, at: assigned, width: rule.width)
                return (s, effects)
            }
            s.world.setFocus(snapshot.id)   // a new window takes focus (truth tracked always)
            guard let before else { return (s, []) }   // no display known: nothing to place
            // Bound to a local first — the same tuple-evaluation-order trap as `.command` above.
            let effects = arriveOnStrip(&s, snapshot.id, beside: beside, old: before,
                                        width: rule.width, keepingWidth: snapshot.wasAlreadyOpen)
            return (s, effects)

        case .windowDestroyed(let id):
            // `World.remove` clears focus if it was on the departing window and retires its displacement.
            let effects = departFromStrip(&s, id) { $0.world.remove(id) }
            return (s, effects)

        case .windowFrameChanged(let id, let frame):
            // External drift, usually a live drag. Don't fight it; `dragEnded` re-asserts the layout.
            s.world.updateFrame(id, to: frame)
            return (s, [])

        case .dragEnded:
            let effects = emitPlacements(&s)   // a window dragged off its target snaps back
            return (s, effects)

        case .focusChanged(let id):
            // Externally-initiated focus (Cmd-Tab, Dock click, self-activation) and the echo of our own
            // `focus` effect. Snap to reveal it; we made no motion, so we owe no animation and no `focus`.
            guard let id else {
                s.world.setFocus(nil)              // focus left every managed window
                return (s, [])
            }
            let effects = revealAcrossWorkspaces(&s, id)
            return (s, effects)

        case .windowMinimized(let id):
            let effects = departFromStrip(&s, id) { s in
                let wasFocused = s.world.focusedWindow == id
                s.world.setMinimized(id, true)
                if wasFocused { s.world.setFocus(nil) }
            }
            return (s, effects)

        case .windowDeminimized(let id):
            // An arrival — the reverse of `windowMinimized`'s departure.
            let before = strandedGeometry(&s)
            let beside = insertionAnchor(s)
            s.world.setMinimized(id, false)
            guard s.world.participatesInStrip(id) else {
                let effects = emitPlacements(&s)
                return (s, effects)
            }
            s.world.setFocus(id)            // restoring re-focuses, like a fresh window
            guard let before else { return (s, []) }
            let effects = arriveOnStrip(&s, id, beside: beside, old: before)
            return (s, effects)

        // MARK: Configuration
        //
        // A reload is a `screensChanged` by another route: the geometry changed without a window moving,
        // so both re-resolve the strip and keep the focused column in view.

        case .configChanged(let config):
            s.config = config
            // Into the live animator, not just stored: `Motion` seeds the spring only at construction,
            // so a feel-only change would otherwise wait for the next daemon start.
            s.motion.setScrollSpring(config.scrollSpring)
            if let focused = s.world.focusedWindow {
                let effects = reveal(&s, focused, center: config.centerFocusedColumn)
                return (s, effects)
            }
            let effects = emitPlacements(&s)
            return (s, effects)

        case .screensChanged(let infos):
            s.world.setMonitors(infos)
            if let focused = s.world.focusedWindow {
                let effects = reveal(&s, focused, center: s.config.centerFocusedColumn)
                return (s, effects)
            }
            let effects = emitPlacements(&s)
            return (s, effects)

        // MARK: Effect feedback — every effect's result is just another event

        case .captureReady(let id):
            // A scoped still completes one of two waits: the *last* raises the cover and teleports the
            // reals behind it; one a retarget pulled into scope grows a raised cover. Neither ⇒ no-op.
            s.motion.markCaptured(id)
            if s.motion.isReadyToRaise {
                s.motion.raiseCover()
                guard let session = s.motion.transition else { return (s, []) }
                var effects: [Effect] = [.beginTransition(session.bindings)]
                effects += elevationEffects(s)      // z-order the bindings alone can't express
                // Blit before teleporting (one `CATransaction`): a layer starts at its capture-time
                // frame, which is wrong for a column captured at its park sliver.
                effects += emitLayerFrames(s)
                effects += teleportBehindCover(&s, initial: true)
                return (s, effects)
            }
            if s.motion.isReadyToExtend {
                let added = s.motion.extendCover()
                guard !added.isEmpty else { return (s, []) }
                // The `setLayerFrame`s ride along so a newcomer's layer is created *and* positioned in
                // one `CATransaction`; the re-elevation does because `extendCover` appends on top.
                return (s, [.extendCover(added)] + elevationEffects(s) + emitLayerFrames(s))
            }
            return (s, [])

        case .coverUnavailable:
            // No pixels from the capture plane; raising anyway would black out the display. Nothing has
            // moved yet, so abandon and snap.
            guard s.motion.isTransitioning, !s.motion.isCovered else { return (s, []) }
            s.motion.abortTransition()          // snaps the viewport to its target
            let effects = emitPlacements(&s)
            return (s, effects)

        case .axLanded(let id):
            // A real window arrived at its AX target. No session ⇒ no-op (an idle set's ack).
            s.motion.markLanded(id)
            let effects = maybeCloseTransition(&s)
            return (s, effects)

        case .placementCorrected(let id, let requested, let actual):
            let effects = handlePlacementCorrected(&s, id, requested: requested, actual: actual)
            return (s, effects)

        case .axFailed(let id):
            // A set timed out or was refused. Resolve its landing so one stuck window can't wedge the
            // cover open, and mark its recorded frame a guess so the next placement re-issues the set.
            s.world.markUnverified(id)
            s.motion.markLanded(id)
            let effects = maybeCloseTransition(&s)
            return (s, effects)

        case .holdTimeout:
            // Bound the wait: close regardless, letting unlanded AX sets finish in the open.
            guard s.motion.isTransitioning else { return (s, []) }
            s.motion.closeTransition()
            return (s, [.endTransition])

        case .crossfadeDone:
            // The cover is fully down; steady state resumed at `endTransition`.
            return (s, [])
        }
    }

    // MARK: - Command handling

    /// Reduce a `Command`. Total over the vocabulary: the verbs not yet built no-op cleanly.
    private static func reduceCommand(_ s: inout State, _ command: Command) -> [Effect] {
        switch command {
        case .focus(let direction):
            return handleFocus(&s, direction)

        case .centerColumn:
            // A user-initiated scroll → animate it (no focus change; just re-frame the strip).
            guard let focused = s.world.focusedWindow else { return [] }
            return scrollReveal(&s, to: focused, center: true)

        case .closeWindow:
            // Ask, and change nothing. The window is still there until its app says otherwise, and when
            // it does that arrives as `windowDestroyed` — the same path a user-clicked close takes, with
            // the same animated closing of ranks. Removing it here would fight the app over a window it
            // may well keep (an unsaved document puts up a sheet).
            guard let focused = s.world.focusedWindow else { return [] }
            return [.closeWindow(focused)]

        case .cycleWidth:
            return handleCycleWidth(&s)

        case .cycleHeight:
            return handleCycleHeight(&s)

        case .grow(let delta):
            return handleResizeColumn(&s, by: delta, sign: +1)

        case .shrink(let delta):
            return handleResizeColumn(&s, by: delta, sign: -1)

        case .fullscreen(let toggle):
            return handleFullscreen(&s, toggle)

        case .float(let toggle):
            return handleFloat(&s, toggle)

        case .moveWindow(let direction):
            return handleMoveWindow(&s, direction)

        case .consumeOrExpel(let direction):
            return handleConsumeOrExpel(&s, direction)

        case .focusWorkspace(let ref):
            return handleFocusWorkspace(&s, ref)

        case .moveToWorkspace(let ref):
            return handleMoveToWorkspace(&s, ref, follow: false)

        case .moveToWorkspaceAndFocus(let ref):
            return handleMoveToWorkspace(&s, ref, follow: true)

        case .exec(let line):
            // Changes nothing, because a spawn is not a fact about the desktop — and opens no
            // transition for the same reason. Whatever window the process opens announces itself as
            // `windowCreated` whenever it is ready, and *that* is what animates.
            return [.exec(line)]

        // The only verb that is permanently a no-op here: `dumpState` is a *read*, answered out of band
        // by the shell off `Runtime.state` (§11, 2026-07-24). Everything else in the vocabulary does
        // something — a listed verb is a promise, since `Command.usage` is `emira --help`.
        case .dumpState:
            return []
        }
    }

    /// Move keyboard focus. Horizontal crosses to the neighbouring column and reveals it; vertical moves
    /// within the focused column's stack (no scroll). No-op at an edge (no wrap) or on an empty strip.
    /// Focus off the strip is an entry condition, not a dead end: either direction re-enters at the near
    /// end, since `World` records whatever the system says is focused, column or not.
    private static func handleFocus(_ s: inout State, _ direction: Direction) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)

        // Off the strip: re-enter at the end the direction came from, so `right` lands leftmost.
        let column = s.world.focusedWindow.flatMap { s.layout.columnIndex(ofWindow: $0) }
        guard let column else {
            let entry = direction == .left
                ? s.layout.columns.last?.windowIds.first
                : s.layout.columns.first?.windowIds.first
            guard let entry else { return [] }
            s.world.setFocus(entry)
            return scrollReveal(&s, to: entry, center: s.config.centerFocusedColumn) + [.focus(entry)]
        }

        switch direction.axis {
        case .horizontal:
            let targetColumn = direction == .right ? column + 1 : column - 1
            guard s.layout.columns.indices.contains(targetColumn),
                  let target = s.layout.columns[targetColumn].windowIds.first else { return [] }
            s.world.setFocus(target)
            // Crossing columns scrolls the strip → animate under a cover (a snap when already in view).
            return scrollReveal(&s, to: target, center: s.config.centerFocusedColumn) + [.focus(target)]

        case .vertical:
            guard let current = s.world.focusedWindow else { return [] }
            let stack = s.layout.columns[column].windowIds
            guard let row = stack.firstIndex(of: current) else { return [] }
            let targetRow = direction == .down ? row + 1 : row - 1
            guard stack.indices.contains(targetRow) else { return [] }
            let target = stack[targetRow]
            s.world.setFocus(target)
            return [.focus(target), .raise(target)]   // within a column: no scroll, so no cover
        }
    }

    // MARK: - Structural edits (the strip rearranged, under the cover)

    /// Everything a structural command must read off the old geometry before it destroys it. `widths` is
    /// captured once and used for *both* `naturalFrames` calls, so the scroll and any in-flight resize
    /// cancel in the difference and what survives is purely structural.
    private struct StructuralSnapshot {
        /// The in-flight column widths both calls resolve against.
        let widths: [ColumnId: Double]
        /// Where every window on every workspace sat under the geometry we are leaving. The offset it was
        /// read at is deliberately not kept — see `finishStructuralEdit`.
        let frames: [WindowId: Rect]
        /// What was on screen under that geometry — half of the two-geometry scope.
        let departing: [WindowId]

        /// The same snapshot plus an arriving window at the frame its app just opened it at — also the
        /// frame the cover captured, so the raise does not pop.
        func including(_ id: WindowId, at frame: Rect) -> StructuralSnapshot {
            var frames = self.frames
            frames[id] = frame
            return StructuralSnapshot(widths: widths, frames: frames, departing: departing)
        }
    }

    /// Read the old geometry, after `reconcile` and the handler's guards — taken before it, the membership
    /// bridge's own churn would show up as a bogus displacement. Frames span every workspace; `departing`
    /// is the focused strip's alone.
    private static func structuralSnapshot(_ s: State, _ metrics: LayoutMetrics) -> StructuralSnapshot {
        let start = s.motion.viewportOffset.current
        let widths = s.motion.currentColumnWidths
        return StructuralSnapshot(
            widths: widths,
            frames: s.workspaces.naturalFrames(scrollOffset: start, metrics: metrics, widths: widths),
            departing: s.layout.visibleWindowIds(scrollOffset: start, metrics: metrics))
    }

    /// Move the focused window one slot. Horizontal branches on whether it has company: a window alone in
    /// its column moves the whole column one place along the strip; one with stackmates pops out into a
    /// new single-window column on that side. Vertical swaps it with a stack neighbour. No wrap, and no
    /// `.focus` effect — focus already sits on the mover, and a redundant AX set can make an app raise.
    private static func handleMoveWindow(_ s: inout State, _ direction: Direction) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        // Metrics guard before the mutation: with no display known there is no correct frame to land on.
        guard let metrics = s.metrics(),
              let focused = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: focused) else { return [] }

        let old = structuralSnapshot(s, metrics)

        // A copy (`ColumnLayout` is a value type) — never re-read it after the mutation. Passing
        // `s.layout.columns[…]` into a `mutating` call on `s.layout` would overlap access besides.
        let column = s.layout.columns[index]
        let edit: LayoutEdit
        switch direction.axis {
        case .horizontal:
            edit = column.windowIds.count == 1
                ? s.layout.moveColumn(column.id, to: direction == .right ? index + 1 : index - 1)
                : s.workspaces.extract(window: focused,
                                       toNewColumnAt: direction == .right ? index + 1 : index)
        case .vertical:
            guard let row = column.windowIds.firstIndex(of: focused) else { return [] }
            edit = s.layout.moveWindowWithinColumn(focused, to: direction == .down ? row + 1 : row - 1)
        }
        return finishStructuralEdit(&s, edit, focused: focused, mover: focused, animatingFrom: old)
    }

    /// Consume/expel, exact inverses. Horizontal branches on company, the opposite way `moveWindow` does:
    /// a window alone in its column is consumed into the neighbouring column's stack; one with stackmates
    /// is expelled into a new single-window column there. Vertical is a different idea — hence the switch
    /// over `direction`, not `direction.axis`: `down` pulls the next column's top window into the bottom
    /// of this one, `up` pushes the focused window out right. At the strip's end a consume no-ops but an
    /// expel still creates its column: the strip has an origin rather than an edge.
    private static func handleConsumeOrExpel(_ s: inout State, _ direction: Direction) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        guard let metrics = s.metrics(),
              let focused = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: focused) else { return [] }

        let old = structuralSnapshot(s, metrics)

        let column = s.layout.columns[index]      // a copy; never re-read after the mutation
        let edit: LayoutEdit
        // The window that travels — `focused` everywhere except `down`. The cover draws it on top.
        var mover = focused
        switch direction {
        case .left, .right:
            if column.windowIds.count > 1 {
                edit = s.workspaces.extract(window: focused,
                                            toNewColumnAt: direction == .right ? index + 1 : index)
            } else {
                let side = direction == .right ? index + 1 : index - 1
                guard s.layout.columns.indices.contains(side) else { return [] }
                let neighbour = s.layout.columns[side]
                let row = direction == .right ? 0 : neighbour.windowIds.count
                edit = s.layout.move(window: focused, toColumn: neighbour.id, at: row)
            }

        case .down:
            // The pulled window moves, not the focused one; `count` is the pre-merge stack height.
            guard s.layout.columns.indices.contains(index + 1),
                  let pulled = s.layout.columns[index + 1].windowIds.first else { return [] }
            mover = pulled
            edit = s.layout.move(window: pulled, toColumn: column.id, at: column.windowIds.count)

        case .up:
            edit = s.workspaces.extract(window: focused, toNewColumnAt: index + 1)
        }
        return finishStructuralEdit(&s, edit, focused: focused, mover: mover, animatingFrom: old)
    }

    /// Finish a structural command: retire a destroyed column's width animator, seed the per-window
    /// displacements the edit created, name the window that rides on top, and open (or ride) a transition
    /// so the strip rearranges in motion rather than in a jump.
    ///
    /// What animates is a displacement, not a position: `Layout` stays the sole authority on where each
    /// window belongs, and what goes under a spring is how far behind that answer each layer is, decaying
    /// to zero. The scope spans two geometries (visible-before ∪ swept-after), so a column the edit evicts
    /// does not slide out as a hole showing wallpaper.
    ///
    /// - Parameter mover: the window drawn on top, `nil` for a departure — the thing that moved has left.
    /// - Parameter focused: the window the viewport frames on afterwards, `nil` to keep the offset.
    /// - Parameter old: the geometry being left, `nil` to snap (no display known, or a deliberate cut).
    private static func finishStructuralEdit(_ s: inout State, _ edit: LayoutEdit,
                                             focused: WindowId?, mover: WindowId?,
                                             animatingFrom old: StructuralSnapshot?) -> [Effect] {
        guard edit.moved else { return [] }
        if let dead = edit.destroyedColumn { s.motion.removeColumnWidthAnimator(dead) }
        guard let metrics = s.metrics() else { return emitPlacements(&s) }

        // Re-read, not carried in the snapshot: for a workspace switch it must *not* be the number the
        // snapshot was taken at, since switching snaps the offset to the incoming strip's remembered
        // scroll in between — which is what makes the horizontal axis cancel out of the seed.
        let start = s.motion.viewportOffset.current

        // No `end == start ⇒ snap` guard: a swap in full view moves the viewport not at all.
        let end = focused.flatMap {
            s.config.centerFocusedColumn
                ? s.layout.scrollOffsetToCenter(window: $0, metrics: metrics)
                : s.layout.scrollOffsetToReveal(window: $0, from: start, metrics: metrics)
        } ?? start

        guard let old else {                    // not animating this one — land it at once
            s.motion.snapViewport(to: end)
            return emitPlacements(&s)
        }

        let scope = scopeUnion(s.workspaces, old.departing,
                               s.layout.sweptWindowIds(from: start, to: end, metrics: metrics))

        guard s.motion.isTransitioning || (s.config.smoothTransitions && !scope.isEmpty) else {
            s.motion.snapViewport(to: end)
            return emitPlacements(&s)
        }

        // The second half of the difference: the new geometry, at the live offset and the *same* widths.
        let new = s.workspaces.naturalFrames(scrollOffset: start, metrics: metrics, widths: old.widths)
        var displaced = 0
        for id in scope {           // scoped only: a window with no layer has nothing to lag behind
            guard let was = old.frames[id], let now = new[id],
                  !approximatelyEqual(was, now) else { continue }
            s.motion.displaceWindow(id, by: was.delta(from: now), params: s.config.moveSpring)
            displaced += 1
        }

        // An edit nothing on screen can see needs no cover. The viewport is asked separately because
        // closing the strip's *last* column displaces nobody.
        let scrolls = !approximatelyEqualScalar(end, start)
        guard displaced > 0 || scrolls || s.motion.isTransitioning else {
            s.motion.snapViewport(to: end)
            return emitPlacements(&s)
        }

        var effects = driveTransition(&s, to: end, scope: scope)
        // After `driveTransition`: `elevate` no-ops without a session, and that is where one is born.
        if let mover { s.motion.elevate(mover) }
        // Emits nothing for a session still capturing, nor for a mover just pulled into scope.
        effects += elevationEffects(s)
        return effects
    }

    /// `Effect.elevateLayer` for the window this transition draws on top, or nothing — no session,
    /// nothing elevated, or no cover up. Total, so call sites append it unconditionally.
    private static func elevationEffects(_ s: State) -> [Effect] {
        guard let layer = s.motion.elevatedLayer else { return [] }
        return [.elevateLayer(layer)]
    }

    // MARK: - Workspaces (the second axis)
    //
    // A workspace switch is a structural edit in `finishStructuralEdit`'s sense: one geometric term
    // (`Workspaces.verticalOffset`) plus the call `move-window` makes.

    /// Switch the focused workspace. Resolving to the one we are already on is a silent no-op, which is
    /// also how `next` at the last address comes out — `Workspaces.resolve` clamps rather than wrapping.
    private static func handleFocusWorkspace(_ s: inout State, _ ref: WorkspaceRef) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        let destination = s.workspaces.resolve(ref)
        guard destination != s.workspaces.focused else { return [] }
        // Read before `focused` moves: the geometry the switch is about to stop being true.
        let old = s.metrics().map { structuralSnapshot(s, $0) }
        return switchWorkspace(&s, to: destination, animatingFrom: old)
    }

    /// Move the focused window to another workspace, optionally following it there. A window, not its
    /// column: one with stackmates leaves them behind. It opens beside whatever the destination was last
    /// focused on and becomes its remembered focus, so a run of moves builds a group.
    private static func handleMoveToWorkspace(_ s: inout State, _ ref: WorkspaceRef,
                                              follow: Bool) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        let destination = s.workspaces.resolve(ref)
        guard destination != s.workspaces.focused,
              let moved = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: moved) else { return [] }

        // Read before the edit: the geometry it invalidates, the column's id (to tell afterwards whether
        // the departure emptied it), and its index, where focus falls back to if so.
        let old = s.metrics().map { structuralSnapshot(s, $0) }
        let column = s.layout.columns[index].id
        let edit = s.workspaces.move(window: moved, to: destination,
                                     insertingAfter: s.workspaces[lastFocusOf: destination])
        guard edit.moved else { return [] }
        if let dead = edit.destroyedColumn { s.motion.removeColumnWidthAnimator(dead) }
        s.workspaces[lastFocusOf: destination] = moved

        if follow {
            return switchWorkspace(&s, to: destination, focusing: moved, mover: moved,
                                   animatingFrom: old)
        }

        // Staying: focus left with the window, so it lands on the neighbour — or, on an emptied strip, off
        // the strip entirely, which `handleFocus`'s entry condition recovers from.
        let heir = successor(s.layout, column: column, at: index)
        s.world.setFocus(heir)
        let effects = finishStructuralEdit(&s, edit, focused: heir, mover: moved, animatingFrom: old)
        return heir.map { effects + [.focus($0)] } ?? effects
    }

    /// The body of a workspace switch — shared by `focus-workspace`, `move-to-workspace-and-focus`, and
    /// the cross-workspace `focusChanged`. Store the live offset and strip focus into the outgoing record,
    /// move `focused`, snap the viewport to the incoming record, pick the window to focus, then place
    /// through `finishStructuralEdit` — between whose two `naturalFrames` reads those steps sit, making
    /// the seed purely vertical.
    ///
    /// - Parameter mover: the window drawn on top; `nil` for a plain `focus-workspace`, whose strips never
    ///   overlap.
    /// - Parameter old: the geometry being left, or `nil` to snap (see `finishStructuralEdit`).
    /// - Parameter announcingFocus: whether to emit `.focus`. `false` on the `focusChanged` path, where
    ///   the shell already moved focus — asking again is a redundant AX set and an echo to absorb.
    private static func switchWorkspace(_ s: inout State, to destination: WorkspaceName,
                                        focusing wanted: WindowId? = nil,
                                        mover: WindowId? = nil,
                                        animatingFrom old: StructuralSnapshot?,
                                        announcingFocus: Bool = true) -> [Effect] {
        // An unanimated switch must not leave a cover over a desktop it no longer pictures.
        var effects = old == nil ? abandonTransition(&s) : []

        let outgoing = s.workspaces.focused
        s.workspaces[scrollOffsetOf: outgoing] = s.motion.viewportOffset.current
        // Only a window on the outgoing *strip* is worth remembering: a float has no column to return to.
        s.workspaces[lastFocusOf: outgoing] =
            s.world.focusedWindow.flatMap { s.layout.columnIndex(ofWindow: $0) == nil ? nil : $0 }

        s.workspaces.focus(destination)
        s.motion.snapViewport(to: s.workspaces[scrollOffsetOf: destination])

        // An empty workspace focuses nothing; focus rests off the strip, which `handleFocus` recovers from.
        let target = wanted ?? s.workspaces[lastFocusOf: destination] ?? s.layout.allWindowIds.first
        if let target {
            s.world.setFocus(target)
            s.workspaces[lastFocusOf: destination] = target
        }

        effects += finishStructuralEdit(&s, LayoutEdit(moved: true, destroyedColumn: nil),
                                        focused: target, mover: mover, animatingFrom: old)
        if let target, announcingFocus { effects.append(.focus(target)) }
        return effects
    }

    /// Reveal an externally-focused window (Cmd-Tab, a Dock click, an app raising itself), switching
    /// workspaces first if it lives on another one; that switch snaps. Focus must be recorded *inside*
    /// the switch, which stores the outgoing workspace's remembered focus — setting `World.focusedWindow`
    /// to a window on another strip first would make that read `nil` and wipe it. No `.focus` effect is
    /// emitted, which makes a feedback loop unrepresentable.
    private static func revealAcrossWorkspaces(_ s: inout State, _ id: WindowId) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        if let home = s.workspaces.workspace(of: id), home != s.workspaces.focused {
            return switchWorkspace(&s, to: home, focusing: id, animatingFrom: nil,
                                   announcingFocus: false)
        }
        s.world.setFocus(id)
        return reveal(&s, id, center: s.config.centerFocusedColumn)
    }

    /// Drop an in-flight transition before something rearranges the world it pictures — one caller, the
    /// snapped cross-workspace switch. `closeTransition` snaps the viewport to where the abandoned scroll
    /// would have come to rest, which is what the outgoing workspace then remembers.
    private static func abandonTransition(_ s: inout State) -> [Effect] {
        guard s.motion.isTransitioning else { return [] }
        s.motion.closeTransition()
        return [.endTransition]
    }

    // MARK: - Floating (leaving the strip on purpose)

    /// Float or tile the focused window. It is the *same* pair of paths a minimize and a restore take —
    /// a departure and an arrival — so the strip closes and opens ranks in motion, and this handler owns
    /// no geometry of its own.
    ///
    /// Two things are decided here. **The override is tri-state**, so `float off` on a dialog *tiles* it
    /// rather than merely clearing a flag back to a role that says float; without that, half the verb
    /// does nothing and there is no way to tile a window macOS classed as a panel. And **it is stored
    /// even when it agrees with the role**, because an AX subrole describes presentation rather than
    /// identity and does change under us (§10's full-screen Safari window reporting `AXDialog`) — the
    /// user's answer has to outrank a role that moves.
    ///
    /// A floated window keeps the frame it had. We stop placing it; we don't get an opinion about where
    /// it should sit instead.
    private static func handleFloat(_ s: inout State, _ toggle: Toggle) -> [Effect] {
        guard let focused = s.world.focusedWindow, s.world.windows[focused] != nil else { return [] }
        let current = s.world.isFloating(focused)
        guard toggle.resolved(current: current) != current else { return [] }

        guard !current else {                       // floating → tiled: an arrival, like a de-minimize
            let before = strandedGeometry(&s)
            let beside = insertionAnchor(s)
            s.world.setFloating(focused, false)
            // Still off the strip (its app is hidden, or it is minimized): nothing to animate into.
            guard s.world.participatesInStrip(focused), let before else { return emitPlacements(&s) }
            // No `.focus`: it already holds focus, and re-asserting it is an AX set that can make an
            // app raise a *different* window forward.
            return arriveOnStrip(&s, focused, beside: beside, old: before, announcingFocus: false)
        }

        // Tiled → floating: a departure, like a minimize — except focus stays put, because the window is
        // still there. `departFromStrip` only picks a successor when focus was actually lost, and the
        // viewport holds, since a window with no column reveals to nowhere.
        return departFromStrip(&s, focused) { $0.world.setFloating(focused, true) }
    }

    // MARK: - Placement (the instant-correct core)

    /// Snap the viewport to reveal `id`'s column (centered, or minimally revealed per config) and re-place
    /// every window — the no-animation reveal: new window, close/retile, display change, external focus.
    /// Reconciles first, so a just-inserted window is on the strip before its offset is computed. A
    /// snap-path event arriving mid-scroll is redirected through `driveTransition` instead, so it cannot
    /// snap the viewport out from under a raised cover.
    private static func reveal(_ s: inout State, _ id: WindowId, center: Bool) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        guard let metrics = s.metrics() else { return [] }
        let start = s.motion.viewportOffset.current
        let offset = center
            ? s.layout.scrollOffsetToCenter(window: id, metrics: metrics)
            : s.layout.scrollOffsetToReveal(window: id, from: start, metrics: metrics)
        if s.motion.isTransitioning {
            // A window with no column (a float taking focus) reveals to nowhere: keep the destination.
            let end = offset ?? s.motion.viewportOffset.target
            return driveTransition(&s, to: end,
                                   scope: s.layout.sweptWindowIds(from: start, to: end, metrics: metrics))
        }
        if let offset { s.motion.snapViewport(to: offset) }
        return emitPlacements(&s)
    }

    // MARK: - The animated scroll (the transition session)

    /// Reveal `id`'s column with an animated transition under a layered cover — the counterpart to
    /// `reveal`'s snap, driven by the user-initiated scroll commands. An open transition is retargeted; no
    /// motion, or no Screen Recording grant, degrades to a snap-place; otherwise a fresh session is scoped
    /// to every window the viewport sweeps between start and end.
    private static func scrollReveal(_ s: inout State, to id: WindowId, center: Bool) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
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

        // No capture capability ⇒ no cover worth raising. Checked *before* the scope is computed.
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

    /// Open a transition aimed at `end` over `scope`, or redirect a running one there. The single place a
    /// session is opened or re-aimed; the caller owns the snap decisions. On a redirect the scope is
    /// widened, never replaced — a window the old destination swept is already mid-flight on the
    /// presentation plane and mid-teleport on the truth plane — and each newcomer owes a `capture`.
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

    // MARK: - The animated resize (the strip's own geometry in motion)

    /// Cycle the focused column to its next preset width — the ladder, as against `grow`/`shrink`'s
    /// continuous knob.
    private static func handleCycleWidth(_ s: inout State) -> [Effect] {
        resizeFocusedColumn(&s) { layout, column, metrics, _ in
            // Also clears any `grow`/`shrink` override, putting the column back on the ladder.
            layout.setWidthPreset(metrics.widthPresets.nextIndex(after: column.widthPreset),
                                  ofColumn: column.id)
        }
    }

    /// Step the focused window to the next height preset inside its column.
    ///
    /// Unlike `cycleWidth` this animates **no new quantity**. A height change moves and resizes the
    /// windows of one column and touches nothing else on the strip — which is exactly the per-window
    /// *displacement* a structural edit already animates, because `Rect.delta` carries size as well as
    /// origin. So a window that only got shorter is a displacement whose origin term happens to be zero,
    /// and the third animated quantity absorbs a fourth for free.
    ///
    /// The whole column re-divides — the water-fill hands back what a pinned window gives up — so every
    /// window in it forgets what it last answered about its size. The user asked again; a bound learned
    /// against the old share would hold the column at the shape it is trying to leave.
    private static func handleCycleHeight(_ s: inout State) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        guard let metrics = s.metrics(),
              let focused = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: focused) else { return [] }

        let windowIds = s.layout.columns[index].windowIds     // a copy; read before the mutation
        let old = structuralSnapshot(s, metrics)

        s.workspaces.cycleHeight(of: focused, through: s.config.heightPresets)
        s.world.forgetCorrections(of: windowIds)

        // A cycle that resolves to the height it was already at displaces nobody, and
        // `finishStructuralEdit` is silent in exactly that case — the stored selection still moved, so
        // the next press acts at once. Same contract `resizeFocusedColumn` keeps for widths.
        return finishStructuralEdit(&s, LayoutEdit(moved: true, destroyedColumn: nil),
                                    focused: focused, mover: focused, animatingFrom: old)
    }

    /// The narrowest an explicit `shrink` may leave a column — a backstop for apps that accept any size,
    /// not the real bound, which is whatever the app answers as a `SizeCorrection`.
    public static let minimumColumnWidth: Double = 100

    /// Widen or narrow the focused column by an explicit delta — `grow`/`shrink`, the continuous
    /// alternative to `cycleWidth`'s ladder. The delta comes off the column's *resolved* width, not its
    /// stored intent: measuring from the intent opens a dead zone wherever an app refused to be as narrow
    /// as we asked. The clamp (content width, `minimumColumnWidth`) can stop a resize but never reverses
    /// one — each bound widens to the current width when the column is already outside it.
    private static func handleResizeColumn(_ s: inout State, by delta: SizeDelta,
                                           sign: Double) -> [Effect] {
        resizeFocusedColumn(&s) { layout, column, metrics, from in
            let available = metrics.contentArea.width
            let ceiling = Swift.max(available, from)
            let floor = Swift.min(minimumColumnWidth, from)
            let width = Swift.min(Swift.max(from + sign * delta.resolved(available: available), floor),
                                  ceiling)
            // Stored in the unit the user typed: a percentage leaves a proportion, points leave points.
            let intent: PresetSize
            switch delta {
            case .percent where available > 0: intent = .proportion(width / available)
            case .percent, .points:            intent = .fixed(width)
            }
            layout.setWidthOverride(intent, ofColumn: column.id)
        }
    }

    /// Take the focused column to the strip's full width, or hand back the width it already had. The
    /// strip's fullscreen, not macOS's: no native Space, just a column resolving to 100% of the content
    /// area with its neighbours parked at slivers. `isFullscreen` shadows the width intent rather than
    /// replacing it, so coming back off survives a config reload or a display change.
    private static func handleFullscreen(_ s: inout State, _ toggle: Toggle) -> [Effect] {
        resizeFocusedColumn(&s) { layout, column, _, _ in
            layout.setFullscreen(toggle.resolved(current: column.isFullscreen), ofColumn: column.id)
        }
    }

    /// The shared body of every column resize: read the width being left, let `retarget` write the new
    /// width intent, then animate from one to the other. This animates a second quantity — the column's
    /// resolved width goes under a spring, and the presentation plane re-resolves the strip against it —
    /// and warrants a transition even when the viewport does not move, so the `end == start` guard is
    /// deliberately absent. The reals teleport to their final size behind the cover.
    ///
    /// - Parameter retarget: given the layout, the focused column as it was, the metrics, and its current
    ///   resolved width, records the new intent. Called once, between the two reads.
    private static func resizeFocusedColumn(
        _ s: inout State,
        _ retarget: (inout Layout, ColumnLayout, LayoutMetrics, Double) -> Void
    ) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        guard let metrics = s.metrics(),
              let focused = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: focused) else { return [] }

        let column = s.layout.columns[index]
        // Resolved, not raw preset: for a column an app has already widened, the preset is not where
        // the layers are.
        let fromWidth = s.layout.resolvedWidth(of: column, metrics: metrics)

        // Asked *before* the width changes: what is on screen under the geometry we are leaving.
        let start = s.motion.viewportOffset.current
        let departing = s.layout.visibleWindowIds(scrollOffset: start, metrics: metrics)

        retarget(&s.layout, column, metrics, fromWidth)
        // The question, not the answer: `metrics.uncorrected` is what a `SizeCorrection` is keyed on.
        let toWidth = s.layout.resolvedWidth(ofColumn: column.id, metrics: metrics.uncorrected) ?? fromWidth

        // Nothing to look at: a single-preset cycle, two presets resolving alike, or a clamp that left the
        // intent where it was. The stored intent still moved, so a later press acts at once.
        guard !approximatelyEqualScalar(fromWidth, toWidth) else { return emitPlacements(&s) }

        // The user asked again, so ask the app again: limits track what a window is currently showing.
        s.world.forgetCorrections(of: column.windowIds)
        guard let asked = s.metrics() else { return emitPlacements(&s) }

        // A resize scrolls too: a column that just grew may no longer fit where it was.
        let end = (s.config.centerFocusedColumn
            ? s.layout.scrollOffsetToCenter(window: focused, metrics: asked)
            : s.layout.scrollOffsetToReveal(window: focused, from: start, metrics: asked)) ?? start

        let scope = scopeUnion(s.workspaces, departing,
                               s.layout.sweptWindowIds(from: start, to: end, metrics: asked))

        // No Screen Recording grant or an empty scope: resize at once, on the same final width.
        guard s.motion.isTransitioning || (s.config.smoothTransitions && !scope.isEmpty) else {
            s.motion.snapViewport(to: end)
            return emitPlacements(&s)
        }

        s.motion.animateColumnWidth(column.id, from: fromWidth, to: toWidth, params: s.config.resizeSpring)
        return driveTransition(&s, to: end, scope: scope)
    }

    /// Two scoped window sets merged and re-sorted into layout order, which is the cover's z-order. Sorted
    /// by `Workspaces.allWindowIds`, not one strip's, so a scope spanning two workspaces keeps every
    /// member — a switch's outgoing set is on a strip `layout` no longer projects.
    private static func scopeUnion(_ workspaces: Workspaces, _ a: [WindowId], _ b: [WindowId]) -> [WindowId] {
        let wanted = Set(a).union(b)
        return workspaces.allWindowIds.filter { wanted.contains($0) }
    }

    /// Teleport the real windows to their frames at the scroll's end (`viewportOffset.target`) behind the
    /// raised cover, and re-arm the landing wait to the scoped windows that moved. All strip windows are
    /// repositioned but only scoped moves are waited on, park→park motion being invisible.
    ///
    /// - Parameter initial: the teleport at the cover's raise, which *replaces* the scope-wide landing
    ///   wait the session was born with. Later re-teleports only add to it — earlier sets may be in flight.
    private static func teleportBehindCover(_ s: inout State, initial: Bool = false) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        guard let metrics = s.metrics(), let scope = s.motion.transition?.windows else { return [] }
        let offset = s.motion.viewportOffset.target
        let frames = s.workspaces.targetFrames(scrollOffset: offset, metrics: metrics)
        let visible = Set(s.layout.visibleWindowIds(scrollOffset: offset, metrics: metrics))
        let questions = s.workspaces.uncorrectedSizes(metrics: metrics)
        let scopeSet = Set(scope)

        var effects: [Effect] = []
        var moved: [WindowId] = []
        for id in s.workspaces.allWindowIds {
            guard let target = frames[id] else { continue }
            if isAlreadyPlaced(s.world, id, at: target, question: questions[id]) { continue }
            effects.append(visible.contains(id) ? .setFrame(id, target) : .park(id, target))
            s.world.updateFrame(id, to: target)     // optimistic: AX will land here (or axFailed)
            if scopeSet.contains(id) { moved.append(id) }
        }
        s.motion.armLandings(moved, replacing: initial)   // wait on the scoped windows that moved
        return effects
    }

    /// Blit one `setLayerFrame` per reconstruction layer this frame — the cover's stand-ins sliding to
    /// their *natural* (un-parked) positions at the current scroll offset, so a window scrolling off-view
    /// glides off the screen edge here while its real counterpart sits at a corner sliver. A pure read, in
    /// z-order, over the whole workspace set. Each frame is one derived rect plus three independent
    /// animated quantities: scroll offset, column widths (resize only), displacement (structural edit).
    private static func emitLayerFrames(_ s: State) -> [Effect] {
        guard let metrics = s.metrics(), let session = s.motion.transition else { return [] }
        let frames = s.workspaces.naturalFrames(scrollOffset: s.motion.viewportOffset.current,
                                                metrics: metrics,
                                                widths: s.motion.currentColumnWidths)
        return session.bindings.compactMap { binding in
            frames[binding.window].map {
                .setLayerFrame(binding.layer, $0.displaced(by: s.motion.displacement(of: binding.window)))
            }
        }
    }

    /// Cross-fade out iff the transition is fully done — cover raised, every scoped AX set landed, every
    /// animator settled. Snaps the viewport to its target so resting state matches the reveal.
    private static func maybeCloseTransition(_ s: inout State) -> [Effect] {
        guard s.motion.isReadyToClose else { return [] }
        s.motion.closeTransition()
        return [.endTransition]
    }

    /// The column a newly arriving window opens beside: whatever holds focus if it has a column, else the
    /// last strip window that did. The fallback is load-bearing — an app focuses a new window before emira
    /// adopts it, so `focusChanged(nil)` clears focus just *before* `windowCreated` arrives and every ⌘N
    /// would otherwise append at the far end of the strip.
    private static func insertionAnchor(_ s: State) -> WindowId? {
        for candidate in [s.world.focusedWindow, s.world.lastStripFocus] {
            if let candidate, s.layout.columnIndex(ofWindow: candidate) != nil { return candidate }
        }
        return nil
    }

    /// The strip's geometry as it stands right now, reconciled first — what an arrival is about to
    /// change. `nil` with no display known, which is also the caller's signal that nothing can be placed.
    private static func strandedGeometry(_ s: inout State) -> StructuralSnapshot? {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        guard let metrics = s.metrics() else { return nil }
        return structuralSnapshot(s, metrics)
    }

    /// A window joining the strip — opened, restored, or unhidden — with the strip opening for it in
    /// motion and the newcomer as `mover`. The mirror of `departFromStrip`, plus one thing a departure
    /// does not need: an arriving window has no place in the old geometry, so
    /// `StructuralSnapshot.including` gives it the frame its app opened it at.
    ///
    /// - Parameter width: a config rule's `width` for the column this window opens.
    /// - Parameter keepingWidth: the launch scan's arrival — the column takes the width the window
    ///   already has rather than the ladder's first rung.
    /// - Parameter announcingFocus: whether to emit `.focus`. `false` when the window already holds it
    ///   (`float off`), where asking again is a redundant AX set that can make an app raise.
    private static func arriveOnStrip(_ s: inout State, _ id: WindowId, beside anchor: WindowId?,
                                      old: StructuralSnapshot, width: PresetSize? = nil,
                                      keepingWidth: Bool = false,
                                      announcingFocus: Bool = true) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, insertingAfter: anchor)
        let announce: [Effect] = announcingFocus ? [.focus(id)] : []
        // A window that didn't join a column has nothing to animate; ordinary placement still runs.
        guard s.layout.columnIndex(ofWindow: id) != nil else { return emitPlacements(&s) + announce }
        // Before the geometry below is read, so an adopted window travels to its place on the strip
        // rather than also resizing on the way.
        seedWidth(&s, id, to: width, keepingExisting: keepingWidth)

        let opened = s.world.windows[id]?.frame
        let seeded = opened.map { old.including(id, at: $0) } ?? old
        let edit = LayoutEdit(moved: true, destroyedColumn: nil)
        return finishStructuralEdit(&s, edit, focused: id, mover: id,
                                    animatingFrom: seeded) + announce
    }

    /// Give a just-adopted column the width it should start at. Two sources, and the explicit one
    /// wins: a config rule is what the user asked for, while `keepingExisting` infers a width from
    /// whatever happened to be on screen when emira launched.
    ///
    /// Both are `widthOverride`s, so the first `cycle-width` clears either and the column rejoins the
    /// ladder — a rule decides where a window *starts*, the same promise it makes about workspaces.
    private static func seedWidth(_ s: inout State, _ id: WindowId, to width: PresetSize?,
                                  keepingExisting: Bool) {
        if let width {
            guard let index = s.layout.columnIndex(ofWindow: id) else { return }
            s.layout.setWidthOverride(width, ofColumn: s.layout.columns[index].id)
        } else if keepingExisting {
            keepExistingWidth(&s, id)
        }
    }

    /// A window whose arrival a rule sends to another workspace. Deliberately *not* `arriveOnStrip`'s
    /// path: the window never joins the strip the viewport is looking at, so there is no gap for the
    /// columns to open around and nothing on screen that moves. It goes straight to its place on a
    /// parked strip, which is a placement like any other.
    ///
    /// **Focus is the one thing the two arrivals disagree about, and `wasAlreadyOpen` is the whole
    /// rule.** The launch scan is emira sorting a desktop nobody just asked it to sort, so a boot
    /// adoption is silent — the alternative walks the user through six workspaces on the way to their
    /// first keystroke. A window opened *now* is one the user opened, and following it there is the
    /// same thing `focusChanged` already does for a Dock click on an app living elsewhere.
    private static func arriveOnWorkspace(_ s: inout State, _ snapshot: WindowSnapshot,
                                          at destination: WorkspaceName,
                                          width: PresetSize? = nil) -> [Effect] {
        // `Workspaces.reconcile` admits every newcomer to the *focused* strip, so an assignment is the
        // move `move-to-workspace` performs, from a column this window has held for one statement. It
        // is long enough to be given a width, which `move` then carries across.
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        seedWidth(&s, snapshot.id, to: width, keepingExisting: snapshot.wasAlreadyOpen)
        s.workspaces.move(window: snapshot.id, to: destination,
                          insertingAfter: s.workspaces[lastFocusOf: destination])

        guard !snapshot.wasAlreadyOpen else { return emitPlacements(&s) }
        // Focus is set *inside* the switch, never before it: `switchWorkspace` reads the current focus
        // to record what the outgoing workspace should return to, and a window on another strip reads
        // as nothing and wipes it.
        return switchWorkspace(&s, to: destination, focusing: snapshot.id, animatingFrom: nil)
    }

    /// Seed a just-adopted column with the width its window already has, instead of the ladder's first
    /// rung — the launch scan's case only, since emira keeps no layout across restarts. A `widthOverride`,
    /// so `cycle-width` clears it; clamped to the working width and stored as a proportion so the clamp
    /// survives a display change. No readable width falls back to the preset.
    private static func keepExistingWidth(_ s: inout State, _ id: WindowId) {
        guard let metrics = s.metrics(), metrics.contentArea.width > 0,
              let index = s.layout.columnIndex(ofWindow: id),
              let width = s.world.windows[id]?.frame.width, width > 0 else { return }
        let fraction = Swift.min(width / metrics.contentArea.width, 1.0)
        s.layout.setWidthOverride(.proportion(fraction), ofColumn: s.layout.columns[index].id)
    }

    /// Where focus lands when the window holding it leaves the strip: a surviving stackmate in the same
    /// column, else whichever column now occupies the departed one's place, else anything at all. `nil`
    /// only for an empty strip.
    private static func successor(_ layout: Layout, column: ColumnId?, at index: Int?) -> WindowId? {
        if let column, let i = layout.columnIndex(withId: column) {
            return layout.columns[i].windowIds.first   // the column outlived the window: stay in it
        }
        guard let index, !layout.columns.isEmpty else { return layout.allWindowIds.first }
        return layout.columns[Swift.min(index, layout.columns.count - 1)].windowIds.first
    }

    /// A window leaving the strip — closed, minimized, or hidden — with the survivors closing ranks in
    /// motion. A structural edit with `move-window`'s shape, minus a `mover`: the window that would ride
    /// on top has left. Snaps where `finishStructuralEdit` snaps, plus for a window never on the strip and
    /// for a strip left empty.
    ///
    /// - Parameter leave: performs the removal. A closure so the before/after pair cannot come apart — the
    ///   snapshot must be taken while the window is still on the strip, and the reconcile afterwards is
    ///   what turns "gone from `World`" into "gone from `Layout`".
    private static func departFromStrip(_ s: inout State, _ id: WindowId,
                                        _ leave: (inout State) -> Void) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        // All three read *before* the removal: the column's id, to tell afterwards whether it died; its
        // index, so focus can land where the window was; and the geometry we are leaving.
        let index = s.layout.columnIndex(ofWindow: id)
        let column = index.map { s.layout.columns[$0].id }
        let old = s.metrics().map { structuralSnapshot(s, $0) }

        leave(&s)
        // The departed window's own lag is measured against a layout that no longer places it.
        s.motion.removeWindowAnimator(id)
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)

        // Focus may have gone with it. Choose the successor *before* framing the strip, since that is
        // what the viewport aims at, and take the neighbour — the front of the strip would scroll home.
        var refocus: [Effect] = []
        if s.world.focusedWindow == nil, let next = successor(s.layout, column: column, at: index) {
            s.world.setFocus(next)
            refocus = [.focus(next)]
        }

        guard let old, let column, let focused = s.world.focusedWindow else {
            return emitPlacements(&s) + refocus
        }
        let destroyed = s.layout.columnIndex(withId: column) == nil ? column : nil
        let edit = LayoutEdit(moved: true, destroyedColumn: destroyed)
        return finishStructuralEdit(&s, edit, focused: focused, mover: nil,
                                    animatingFrom: old) + refocus
    }

    // MARK: - Windows that refuse the size we ask for

    /// Fold a tiled landing that came back a different size than we asked for: record the truth, remember
    /// the answer, re-place. The guards below decline to learn from a stale report and from position-only
    /// drift; staleness is compared on *size* alone, since `emitPlacements` writes at
    /// `viewportOffset.current` and `teleportBehindCover` at `.target`. Keying the record on the question
    /// makes it self-invalidating.
    private static func handlePlacementCorrected(_ s: inout State, _ id: WindowId,
                                                 requested: Rect, actual: Rect) -> [Effect] {
        s.world.updateFrame(id, to: actual)          // truth first, exactly as `windowFrameChanged` does

        // Whichever workspace holds the window, not the focused one: a parked window elsewhere is still
        // placed by us, and ignoring its refusal would re-set it on every event, forever.
        guard let metrics = s.metrics(),
              let (name, column) = s.workspaces.column(containing: id),
              let live = s.workspaces.targetFrames(scrollOffset: s.motion.viewportOffset.target,
                                                   metrics: metrics)[id],
              approximatelyEqualSize(requested.size, live.size),      // not stale
              !approximatelyEqualSize(actual.size, requested.size),   // actually about size
              let question = s.workspaces[name].uncorrectedSize(of: id, metrics: metrics)
        else { return [] }

        // A smaller answer teaches only when it answered the question — one shrink per question **on
        // either axis**, or an app always returning slightly less than asked walks its column toward
        // nothing, one placement at a time. Growing keeps learning unconditionally: too wide overlaps a
        // neighbour, too tall overlaps a stackmate, and those are the invariants the strip promises.
        if shrankOffQuestion(actual.width, requested: requested.width, question: question.width)
            || shrankOffQuestion(actual.height, requested: requested.height, question: question.height) {
            return []
        }

        let before = s.workspaces[name].resolvedWidth(of: column, metrics: metrics)
        let stackedBefore = s.workspaces[name].naturalFrames(scrollOffset: 0, metrics: metrics)
        s.world.noteCorrection(id, wanted: question, actual: actual.size)
        guard let corrected = s.metrics() else { return [] }
        let after = s.workspaces[name].resolvedWidth(of: column, metrics: corrected)
        springHeightChange(&s, on: name, column, from: stackedBefore, to: corrected)

        // Under a cover every layer frame is re-derived from the strip's geometry each tick, so a column
        // that changes width between two frames jumps. Put the change under the resize spring instead.
        if s.motion.isTransitioning, !approximatelyEqualScalar(before, after) {
            s.motion.animateColumnWidth(column.id, from: before, to: after, params: s.config.resizeSpring)
            // Re-aim too: scroll targets derive from the column widths this just changed, so a session
            // keeping its old destination comes to rest past the strip's end, showing phantom desktop.
            return reaimViewport(&s, corrected)
        }

        // Mid-capture nothing has moved yet; the raise's own teleport will read the correction.
        if s.motion.isCovered { return teleportBehindCover(&s) }
        return s.motion.isTransitioning ? [] : emitPlacements(&s)
    }

    /// Carry a learned *height* across a raised cover, for the reason the width branch below it exists:
    /// the layers re-derive their frames from the layout every tick, so a column that re-divides between
    /// two frames jumps. This is the third animated quantity rather than the second, and correctly so —
    /// a height answer re-runs the water-fill, and before and after are two different divisions of the
    /// column with no single number to interpolate, exactly like a structural edit. So what springs is
    /// each window's *displacement* from where the column now says it belongs, decaying to zero.
    ///
    /// Vertical components only: `x`/`width` belong to the column-width animator, and the two must not
    /// both have an opinion about one number. Idle (no session open) there is nothing to smooth — the
    /// placement snaps, as every uncovered placement does.
    private static func springHeightChange(_ s: inout State, on name: WorkspaceName,
                                           _ column: ColumnLayout,
                                           from stackedBefore: [WindowId: Rect],
                                           to corrected: LayoutMetrics) {
        guard s.motion.isTransitioning else { return }
        let stackedAfter = s.workspaces[name].naturalFrames(scrollOffset: 0, metrics: corrected)
        for window in column.windowIds {
            guard let was = stackedBefore[window], let now = stackedAfter[window] else { continue }
            let delta = Rect(x: 0, y: was.minY - now.minY, width: 0, height: was.height - now.height)
            guard delta != .zero else { continue }
            s.motion.displaceWindow(window, by: delta, params: s.config.resizeSpring)
        }
    }

    /// Re-derive where an open transition is travelling to, after something changed the geometry its
    /// destination came from — `resizeFocusedColumn`'s opening arithmetic, applied again when the answer
    /// changes what the resize meant. With nothing focused there is no column to frame on, so it falls
    /// back to a plain re-teleport.
    private static func reaimViewport(_ s: inout State, _ metrics: LayoutMetrics) -> [Effect] {
        guard let focused = s.world.focusedWindow else {
            return s.motion.isCovered ? teleportBehindCover(&s) : []
        }
        let start = s.motion.viewportOffset.current
        let end = (s.config.centerFocusedColumn
            ? s.layout.scrollOffsetToCenter(window: focused, metrics: metrics)
            : s.layout.scrollOffsetToReveal(window: focused, from: start, metrics: metrics))
            ?? s.motion.viewportOffset.target
        return driveTransition(&s, to: end,
                               scope: s.layout.sweptWindowIds(from: start, to: end, metrics: metrics))
    }

    /// Whether a window needs no set: it is already at its target, or it is at the answer we know it gives
    /// to the question the layout is asking, and in the right place. The second clause covers the
    /// direction geometry ignores — a terminal quantizing its width 8 pt *down* leaves a gap, not an
    /// overlap, so the column never widens for it and every placement would re-issue a known-answer set.
    private static func isAlreadyPlaced(_ world: World, _ id: WindowId,
                                        at target: Rect, question: Size?) -> Bool {
        // A frame we have been told is a guess is not evidence of anything (`World.unverified`).
        guard !world.unverified.contains(id) else { return false }
        guard let known = world.windows[id]?.frame else { return false }
        if approximatelyEqual(known, target) { return true }
        guard let correction = world.corrections[id], let question,
              approximatelyEqualSize(correction.wanted, question),
              approximatelyEqualSize(known.size, correction.actual)
        else { return false }
        return approximatelyEqualScalar(known.minX, target.minX)
            && approximatelyEqualScalar(known.minY, target.minY)
    }

    /// Emit the `setFrame`/`park` sets that bring every managed window to its target frame at the current
    /// scroll offset. A window whose column overlaps the viewport is `setFrame`d to its tiled frame; one
    /// scrolled off-view is `park`ed at its sliver slot. Only windows that need to move are emitted,
    /// diffed within a sub-pixel tolerance; reconciles first. `World` frames are updated optimistically —
    /// a failure comes back as `axFailed` — which keeps a repeated idle event from re-emitting forever.
    private static func emitPlacements(_ s: inout State) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        guard let metrics = s.metrics() else { return [] }

        // Bring the resting viewport back inside the strip, which can shrink with nothing asking to reveal
        // anything. Not mid-transition (snapping would tear the animation), not when centering (a column
        // in the middle at the strip's end *means* showing space past it).
        if !s.motion.isTransitioning, !s.config.centerFocusedColumn {
            let clamped = s.layout.clampScrollOffset(s.motion.viewportOffset.current, metrics: metrics)
            if !approximatelyEqualScalar(clamped, s.motion.viewportOffset.current) {
                s.motion.snapViewport(to: clamped)
            }
        }

        let offset = s.motion.viewportOffset.current
        let frames = s.workspaces.targetFrames(scrollOffset: offset, metrics: metrics)
        let visible = Set(s.layout.visibleWindowIds(scrollOffset: offset, metrics: metrics))
        let questions = s.workspaces.uncorrectedSizes(metrics: metrics)

        var effects: [Effect] = []
        // `visible` is the focused strip's on-screen set and nothing else's: the rest are parked.
        for id in s.workspaces.allWindowIds {
            guard let target = frames[id] else { continue }
            if isAlreadyPlaced(s.world, id, at: target, question: questions[id]) { continue }
            effects.append(visible.contains(id) ? .setFrame(id, target) : .park(id, target))
            s.world.updateFrame(id, to: target)    // optimistic: AX will land here (or axFailed)
        }
        return effects
    }

    /// Frames within half a point on every edge are "already there" — a placement no-op, so sub-pixel
    /// rounding drift between the layout math and observed truth does not re-emit sets.
    private static func approximatelyEqual(_ a: Rect, _ b: Rect, tolerance: Double = 0.5) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Whether one axis of an answer came back smaller than a request that was **not** the question —
    /// the recursion guard, per axis. The request being the question is what makes an answer a fact
    /// about the app rather than a fact about our own last concession to it.
    private static func shrankOffQuestion(_ actual: Double, requested: Double, question: Double) -> Bool {
        actual < requested - 0.5 && !approximatelyEqualScalar(requested, question)
    }

    /// Two sizes within half a point on both axes — the comparison a `SizeCorrection` is matched with.
    private static func approximatelyEqualSize(_ a: Size, _ b: Size, tolerance: Double = 0.5) -> Bool {
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Two scroll offsets within half a point are "the same" — the guard that keeps a reveal of an
    /// already-in-view column a snap-place rather than a zero-distance transition.
    private static func approximatelyEqualScalar(_ a: Double, _ b: Double, tolerance: Double = 0.5) -> Bool {
        abs(a - b) <= tolerance
    }
}
