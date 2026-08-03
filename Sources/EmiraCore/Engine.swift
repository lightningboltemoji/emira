import Foundation
import EmiraMotion

// The reducer: `reduce(State, Event) -> (State, [Effect])`. Pure and framework-free — AX / Core
// Animation / ScreenCaptureKit are only named, through `Effect` — and total over `Event`.
//
// A change to the ground the strip stands on (a display change, a config reload) snaps every window to its
// target frame: nothing travelled, so there is nothing to animate. Anything that moves the strip — scroll,
// resize, structural edit, workspace switch, a window arriving or leaving, a focus we did not cause — runs
// a covered transition: capture the scoped windows, raise a layered cover, teleport the reals behind it,
// animate the layers, drop the cover when everything settles.

/// The complete core state — a value type throughout, so it dumps to JSON and replays deterministically.
public struct State: Sendable, Equatable, Codable {
    /// Truth: what actually exists on the system (windows, apps, monitors, focus).
    public var world: World
    /// Structure: the 36-address workspace set — one strip per materialized workspace, plus the
    /// `ColumnId` allocator they share.
    public var workspaces: Workspaces
    /// Structure, the other axis: which display holds which workspaces, which one each is showing, and
    /// which display the user is on. Beside `workspaces` rather than inside it — the two are orthogonal
    /// facts joined by a `WorkspaceName`.
    public var monitors: Monitors
    /// Animation: the viewport-offset scroll, independent per-window motion, the transition session.
    public var motion: Motion
    /// The parsed config values the reducer reads (gaps, presets, scroll feel).
    public var config: Config
    /// What the pointer plane is owed. Two intents, neither a fact about the desktop — see `Pointer`.
    public var pointer: Pointer

    /// The strip the acting monitor is showing — a projection of `workspaces` at `monitors.shown`, not
    /// a second authority. Only the cross-workspace queries bypass it: reconcile, `targetFrames`, the
    /// placement walks, the mutators that mint a `ColumnId`.
    public var layout: Layout {
        get { workspaces[monitors.shown] }
        set { workspaces[monitors.shown] = newValue }
    }

    /// A fresh, empty state. The viewport spring is seeded from the config.
    public init(config: Config = Config()) {
        self.world = World()
        self.workspaces = Workspaces()
        self.monitors = Monitors()
        self.motion = Motion(viewportOffset: 0, params: config.scrollSpring)
        self.config = config
        self.pointer = Pointer()
    }

    /// Full memberwise init — for the reducer building a specific state, for replay, and for tests.
    /// `monitors` and `pointer` default to the launch state, which is what every caller but a replay
    /// wants; they are parameters rather than hard-coded so that "full" stays true.
    public init(world: World, workspaces: Workspaces, motion: Motion, config: Config,
                monitors: Monitors = Monitors(), pointer: Pointer = Pointer()) {
        self.world = world
        self.workspaces = workspaces
        self.monitors = monitors
        self.motion = motion
        self.config = config
        self.pointer = pointer
    }

    /// The single-strip init: `layout` becomes the launch address's strip, nothing else materialized.
    public init(world: World, layout: Layout, motion: Motion, config: Config,
                pointer: Pointer = Pointer()) {
        self.init(world: world,
                  workspaces: Workspaces(showing: .first, strips: [.first: layout]),
                  motion: motion, config: config, pointer: pointer)
    }

    /// Layout metrics for one display — its working area (bounds minus its own struts) under the current
    /// config. `nil` for a display that is not attached, which is what makes every geometry query a
    /// no-op before the first `screensChanged`.
    ///
    /// The corrections and park floors are the *whole* desktop's, not the display's: they are keyed by
    /// `WindowId` and a window carries what it answered across a monitor exactly as it carries it
    /// across a workspace.
    public func metrics(of id: MonitorId) -> LayoutMetrics? {
        guard let monitor = world.monitor(id) else { return nil }
        return LayoutMetrics(
            workingArea: monitor.workingArea,
            widthPresets: config.widthPresets,
            heightPresets: config.heightPresets,
            heightSelections: workspaces.heightSelections,
            columnGap: config.columnGap,
            windowGap: config.windowGap,
            outerGaps: config.outerGaps,
            corrections: world.corrections,
            parkFloors: world.parkFloors)
    }

    /// The **acting** monitor's metrics — the display the user is on, which is what a verb naming no
    /// monitor lays out against. `nil` until the first `screensChanged`, so geometry commands no-op
    /// until then.
    public func metrics() -> LayoutMetrics? {
        monitors.focused.flatMap(metrics(of:))
    }

    /// The acting monitor and its metrics together — what a verb naming no monitor works against, and
    /// the one guard it needs: `nil` is a desktop with no display, where there is no correct frame to
    /// land on and nothing to open a cover over.
    public func acting() -> (monitor: MonitorId, metrics: LayoutMetrics)? {
        guard let monitor = monitors.focused, let metrics = metrics(of: monitor) else { return nil }
        return (monitor, metrics)
    }

    /// The acting monitor's viewport — the scroll every verb naming no monitor moves. Total, including
    /// with no display attached, for the reason `Monitors.shown` is.
    public var viewport: Viewport { motion.viewport(of: monitors.focused) }

    // Resolving a reference (where the two containers decide together what a verb's argument names)

    /// The address a `WorkspaceRef` names. **Absolute refs are global, relative ones are not** (D1): a
    /// name goes wherever it lives, switching displays if that is where it is — the "just work"
    /// requirement — while `next` and its kin stay inside the acting monitor's own set, because the
    /// monitor is the container and cycling should not leave it. Strictly a generalization: on one
    /// display "held here or held by nobody" is all 36 addresses.
    public func resolve(_ ref: WorkspaceRef) -> WorkspaceName {
        workspaces.resolve(ref, from: monitors.shown, within: monitors.reachable)
    }

    /// The display a `MonitorRef` names — `nil` only with none attached. Total otherwise, and
    /// **clamping rather than wrapping**, exactly as `WorkspaceRef` does: a ref with nowhere to go
    /// answers the acting monitor, which every verb reads as the no-op it is.
    public func resolve(_ ref: MonitorRef) -> MonitorId? {
        let ids = monitors.ids
        guard let acting = monitors.focused, let here = ids.firstIndex(of: acting) else { return nil }
        switch ref {
        case .index(let n):     return ids[min(max(n - 1, 0), ids.count - 1)]
        case .next:             return ids[min(here + 1, ids.count - 1)]
        case .previous:         return ids[max(here - 1, 0)]
        case .direction(let d): return nearestMonitor(from: acting, towards: d) ?? acting
        }
    }

    /// The display spatially nearest the acting one in `d`: among those whose frame centre lies
    /// strictly in `d`'s half-plane, the smallest distance along `d`'s own axis, tie-broken on the
    /// cross axis and then on enumeration order. `nil` when there is nothing that way — the desktop
    /// has an edge, where the strip does not (D2).
    private func nearestMonitor(from origin: MonitorId, towards d: Direction) -> MonitorId? {
        guard let from = world.monitor(origin)?.frame.center else { return nil }
        var best: (id: MonitorId, primary: Double, cross: Double)?
        // Enumeration order, with a strict comparison, so the earliest display wins every tie.
        for id in monitors.ids where id != origin {
            guard let centre = world.monitor(id)?.frame.center else { continue }
            // Core `y` grows *downward*, so `up` is the negative side of it.
            let along = d == .left || d == .up ? -1.0 : 1.0
            let primary = along * (d.axis == .horizontal ? centre.x - from.x : centre.y - from.y)
            let cross = abs(d.axis == .horizontal ? centre.y - from.y : centre.x - from.x)
            guard primary > 0 else { continue }
            guard let current = best else { best = (id, primary, cross); continue }
            if (primary, cross) < (current.primary, current.cross) { best = (id, primary, cross) }
        }
        return best?.id
    }

    /// The acting monitor's transition, or `nil`. The projection `layout` is, one container over.
    public var transition: TransitionSession? { motion.transition(of: monitors.focused) }

    /// The placement plan for this instant: every materialized address, in placement order, carrying
    /// the geometry it is laid out against and — for an address on screen — the offset its display's
    /// viewport is at. **Where `Monitors`, `Motion` and `Workspaces` meet**, so that the layout
    /// container can lay out a desktop of several displays without knowing that displays exist.
    ///
    /// A covered display supplies the scroll's **end** and every other display where its viewport
    /// **rests**, which is the one rule behind both placement passes: behind a raised cover the reals
    /// belong where the motion is going, everywhere else they belong where the strip is.
    ///
    /// Empty with no display attached — the placement no-op `metrics()` already gives.
    public func placements() -> [StripPlacement] {
        let shown = Set(monitors.shownWorkspaces)
        return workspaces.placementOrder(shown: monitors.shownWorkspaces).compactMap { name in
            // The fallback is unreachable while invariant 2 holds (materialized ⇒ assigned) and is an
            // answer rather than a trap: an orphan is laid out by the display the user is on.
            guard let owner = monitors.monitor(of: name) ?? monitors.focused,
                  let metrics = metrics(of: owner) else { return nil }
            let live = motion.offset(of: owner)
            return StripPlacement(name: name, metrics: metrics,
                                  scrollOffset: shown.contains(name)
                                      ? (motion.isCovered(on: owner) ? live.target : live.current)
                                      : nil)
        }
    }

    /// The animated things one display is responsible for — every window on a strip it holds, plus the
    /// columns they sit in, plus whatever its own cover still has in scope. The membership `Motion`
    /// cannot answer for itself, since its displacements and widths are keyed by ids that outlive both
    /// a workspace and a display.
    ///
    /// The scope is unioned in because a cover is answerable for everything it *draws*: a window that
    /// left this display's strips mid-transition is still sliding on its layers.
    public func contents(of id: MonitorId) -> MonitorContents {
        var windows: Set<WindowId> = []
        var columns: Set<ColumnId> = []
        for name in monitors.owned(of: id) {
            for column in workspaces[name].columns {
                columns.insert(column.id)
                windows.formUnion(column.windowIds)
            }
        }
        windows.formUnion(motion.transition(of: id)?.windows ?? [])
        return MonitorContents(windows: windows, columns: columns)
    }

    /// Fold `Event.screensChanged` into all four containers. **One method, because they must move
    /// together:** `World` takes the geometry observation just reported, `Monitors` re-homes the
    /// workspaces around whatever arrived or left, every address a display ends up showing is
    /// materialized, and `Motion` drops the viewports of displays that have gone. A `World` that knows
    /// about a display `Monitors` does not is a desktop with no metrics and no route to any, so the
    /// ordering is structural rather than remembered.
    ///
    /// **A report that moves the ground takes every cover down with it**, not only the covers of the
    /// displays that left. Nothing on any screen is travelling to where it now belongs, which is the
    /// same reason a display change snaps rather than animates — and the shell rebuilds the overlay of
    /// every display a reconfiguration touched, which would otherwise strand covers nobody took down.
    ///
    /// A report that changes *nothing* changes nothing: `screensChanged` also arrives redundantly, and
    /// tearing a cover down mid-raise there would write the truth plane with nothing on the glass to
    /// hide it — the one thing the phase machine exists to prevent.
    ///
    /// - Returns: the displays owed an `endTransition` — the sessions are gone from the core, and the
    ///   overlays they were drawing on have to be told.
    @discardableResult
    public mutating func setMonitors(_ infos: [MonitorInfo]) -> [MonitorId] {
        let moved = !describesSameDisplays(as: infos)
        if moved { bankViewports() }
        world.setMonitors(infos)
        monitors.reconcile(materialized: workspaces.materialized, occupied: workspaces.occupied,
                           infos: infos)
        materializeShown()
        let departed = motion.reconcile(infos.map(\.id))
        guard moved else { return departed }
        let surviving = motion.transitioningMonitors
        for monitor in surviving { motion.closeTransition(on: monitor) }
        resumeViewports()
        return departed + surviving
    }

    /// Store every display's live scroll against the address it is showing — the write half of a
    /// workspace switch (`Engine.switchWorkspace`), applied to every screen at once.
    ///
    /// **A reconfiguration is a switch on every display**, because each may come out showing a different
    /// address: one that left hands its workspaces to a survivor, one that returns takes them back. So
    /// the same two halves apply, and this is the one that has to run *before* the containers move,
    /// while each display can still say what it was looking at. Without it a `Viewport` is the only
    /// record of where a display was scrolled to, and a viewport does not survive its display — so a lid
    /// close would return every workspace it took with it to the strip's origin.
    /// Banked at the scroll's **target**, not where it happens to be: a reconfiguration takes every
    /// cover down with it, and `closeTransition` snaps each viewport to exactly that. For a display at
    /// rest the two are the same number, so this is the resting read everywhere else.
    private mutating func bankViewports() {
        for id in monitors.ids {
            guard let shown = monitors.shown(on: id) else { continue }
            workspaces[scrollOffsetOf: shown] = motion.offset(of: id).target
        }
    }

    /// …and the read half: every display resumes at the memory of whatever it now shows. A display whose
    /// address did not change reads back the number `bankViewports` just wrote, so the common
    /// reconfiguration is an identity — and one that did, including a returning display reclaiming its
    /// workspaces, arrives where it left off.
    ///
    /// Snapping is right for the same reason a display change snaps everything else: the ground the
    /// strip stands on moved, so nothing is travelling to where it now belongs.
    private mutating func resumeViewports() {
        for id in monitors.ids {
            guard let shown = monitors.shown(on: id) else { continue }
            motion.snapViewport(to: workspaces[scrollOffsetOf: shown], on: id)
        }
    }

    /// Whether `infos` reports the geometry `World` already holds, display for display and in order —
    /// the difference between a reconfiguration and a repeat of one.
    private func describesSameDisplays(as infos: [MonitorInfo]) -> Bool {
        world.monitors.count == infos.count
            && zip(world.monitors, infos).allSatisfy {
                $0.id == $1.id && $0.frame == $1.frame && $0.struts == $1.struts
            }
    }

    /// Show `name` on `id`, defaulting to the acting monitor. **One method, for the same reason
    /// `setMonitors` is one:** a display claiming an address dispossesses whichever display held it,
    /// and that display then takes one it can have — which may be an address nothing has ever
    /// materialized. So the strip the switch asked for is not the only one it owes; every address left
    /// on a screen needs one. Which of them is occupied is `Workspaces`' answer and decides the
    /// fallback, so it is supplied here rather than remembered by the caller.
    public mutating func show(_ name: WorkspaceName, on id: MonitorId? = nil) {
        monitors.show(name, on: id ?? monitors.focused, occupied: workspaces.occupied)
        materializeShown()
    }

    /// **Shown ⇒ materialized**, the invariant every cross-strip query assumes: `placementOrder(shown:)`
    /// and `targetFrames(shown:)` are handed the on-screen list, and an address in it with no strip is a
    /// name in the placement walk that answers for nothing.
    private mutating func materializeShown() {
        for name in monitors.shownWorkspaces { workspaces.materialize(name) }
    }

    /// Move a window to another address. **One method, for the same reason `setMonitors` is one:**
    /// `Workspaces.move` materializes the destination strip, and an address with a strip belongs to a
    /// display (invariant 2). A destination some display already holds keeps it, so this is also where
    /// a window sent across the desktop learns which screen it is going to.
    @discardableResult
    public mutating func move(window: WindowId, to destination: WorkspaceName,
                              insertingAfter anchor: WindowId?) -> LayoutEdit {
        let edit = workspaces.move(window: window, to: destination, insertingAfter: anchor)
        guard edit.moved else { return edit }
        monitors.assign(destination)
        return edit
    }
}

/// The pure reducer. Stateless namespace — all state travels through the `State` value.
public enum Engine {

    /// Fold one `Event` into a new `State`, emitting the `Effect`s the shell should run.
    ///
    /// The fold itself is `fold(_:_:)`; this wraps it with the one thing focus cannot report for
    /// itself. Focus reaches `World.setFocus` from a dozen paths — a command, a system event, a
    /// workspace switch, a departure's refocus, an arrival, boot — and the ring's travel is a
    /// *difference between two states*, which no single one of those paths can see.
    /// **The hide runs before the warp**, and not because of where each writes — the hide prepends and
    /// the warp appends, so the emitted order comes out the same either way. It is because the hide
    /// asks whether the command *did something*, and reads that off `effects.isEmpty`: that question is
    /// about the fold's own output, and a warp appended first would answer it `true` for a command that
    /// moved nothing. A visit the pointer was already owed is a consequence of an earlier hide, never a
    /// reason for a new one.
    public static func reduce(_ state: State, _ event: Event) -> (State, [Effect]) {
        var (next, effects) = fold(state, event)
        trackFocusRing(from: state, into: &next)
        hidePointer(on: event, into: &next, effects: &effects)
        warpPointer(on: event, from: state, into: &next, effects: &effects)
        return (next, effects)
    }

    /// Hide the pointer while the user is working from the keyboard. A post-pass over the whole batch
    /// rather than a call in each verb, so a verb added later is covered without being told.
    ///
    /// Both gates ask *who asked*, never what moved: a **command** that **emitted something** — which
    /// also excludes a read like `dumpState` and a `focus left` into the wall. Drawn around window
    /// movement instead it would miss focus crossing two columns already on screen, which emits `.focus`
    /// alone and is the commonest thing a keyboard user does. Prepending buys the capture head and is
    /// *not* sufficient: the same batch usually ends in `.focus`, whose activation discards the hide, and
    /// `Event.appActivated` is what puts it back.
    ///
    /// **The setting going off pays the hide back here**, because it is the one exit the mouse cannot
    /// supply — a shell that has stopped watching for motion leaves a desktop with no way to get its
    /// cursor back. Stated as the invariant rather than as a list of events.
    private static func hidePointer(on event: Event, into s: inout State, effects: inout [Effect]) {
        guard s.config.hidesCursor else {
            guard s.pointer.isCursorHidden else { return }
            s.pointer.isCursorHidden = false
            effects.append(.setCursorHidden(false))
            return
        }
        guard case .command = event, !s.pointer.isCursorHidden, !effects.isEmpty else { return }
        s.pointer.isCursorHidden = true
        effects.insert(.setCursorHidden(true), at: 0)
    }

    /// Send the pointer after focus — but not until the user can see where it went. A post-pass beside
    /// `trackFocusRing`, and for its reason: "focus moved" is a difference between two states that none
    /// of the dozen paths into `World.setFocus` can see.
    ///
    /// **The visit is owed while a session is open and paid the moment none is** — one rule for both the
    /// covered case and the uncovered one. Warping on the focus change itself would put the cursor on
    /// its target 250 ms before the window gets there, which is the flash the cover exists to prevent.
    ///
    /// **The source gates the owing, never the paying**: by payment time the event that booked the visit
    /// is several events ago, and `FocusOrigin` could not answer anyway, a hovered focus reducing into
    /// the same tail a commanded one does. Every focus change re-decides the debt, including one the rung
    /// declines — an older visit left standing aims the pointer at a window focus has left.
    private static func warpPointer(on event: Event, from before: State, into s: inout State,
                                    effects: inout [Effect]) {
        // A debt outlives the event that booked it, so the setting going off has to cancel one already
        // standing rather than only stopping the next — the same shape the hide's payout above has,
        // and the same reason: a reload is the one way a rung can change under an owed visit.
        guard s.config.mouseFollowsFocus != .off else { return s.pointer.pendingWarp = nil }
        var pointerCaused = false
        if case .pointerEntered = event { pointerCaused = true }
        if before.world.focusedWindow != s.world.focusedWindow {
            s.pointer.pendingWarp = s.config.mouseFollowsFocus.warps(pointerCaused: pointerCaused)
                ? s.world.focusedWindow : nil
        }
        // Across every display, not the acting one: a cover anywhere is a desktop the user is not
        // being shown, and the visit is owed until every one of them is down.
        guard let owed = s.pointer.pendingWarp, !s.motion.isTransitioning else { return }
        // Dropped whether or not it produces an effect: a window that closed, parked or went off-screen
        // while the cover was up is not one to send the pointer to, and nothing here retries.
        s.pointer.pendingWarp = nil
        guard s.world.isOnScreen(owed), let metrics = s.metrics(),
              let frame = s.world.windows[owed]?.frame,
              // Clamped into the working area, so a column only half revealed at the viewport's edge
              // takes the pointer to the part of itself the user can actually see.
              let target = frame.intersection(metrics.workingArea) else { return }
        effects.append(.warpPointer(into: target))
    }

    /// Seed the guide's focus ring when focus moved between two windows on the strip.
    ///
    /// Both frames are read at `scrollOffset: 0`, so the scroll cancels out of the delta — the same
    /// two-reads-one-offset rule `finishStructuralEdit` runs on. The `!=` comparison comes first, so the
    /// two `naturalFrames` calls happen only when focus actually moved, never per tick.
    private static func trackFocusRing(from before: State, into after: inout State) {
        guard after.config.guide.style != .off else { return after.motion.clearFocusRing() }
        guard before.world.focusedWindow != after.world.focusedWindow else { return }
        guard after.world.focusedWindow != nil else { return after.motion.clearFocusRing() }
        // Each read is the acting monitor's own — its metrics, its address, its strips. When focus
        // crossed displays those are two different screens, and the delta between them is the
        // inter-display vector: the ring flies in from the direction focus left, for free.
        guard let metrics = after.metrics(), let old = before.metrics() else { return }
        let now = after.workspaces.naturalFrames(shown: after.monitors.shown,
                                                 among: after.monitors.owned, scrollOffset: 0,
                                                 metrics: metrics)
        // A float, or a window off the strip entirely, has no frame to ring and nothing to travel to.
        guard let arriving = after.world.focusedWindow.flatMap({ now[$0] }) else { return }
        let was = before.workspaces.naturalFrames(shown: before.monitors.shown,
                                                  among: before.monitors.owned, scrollOffset: 0,
                                                  metrics: old)
        guard let leaving = before.world.focusedWindow.flatMap({ was[$0] }) else { return }
        after.motion.nudgeFocusRing(by: leaving.delta(from: arriving), params: after.config.moveSpring)
    }

    private static func fold(_ state: State, _ event: Event) -> (State, [Effect]) {
        var s = state
        switch event {

        case .command(let command):
            // NB: bind effects to a local before returning. `(s, reduceCommand(&s, …))` would read
            // `s` (tuple element 0) *before* the `&s` call mutates it, returning stale state.
            let effects = reduceCommand(&s, command)
            return (s, effects)

        //
        // Ticks fire while a transition is open *or* the guide's focus ring is travelling, and are
        // inert for the strip until the cover is raised.
        case .tick(let dt):
            // The ring runs outside a cover, so it advances ahead of the gate that makes a pre-cover
            // tick inert — and never inside `advance`, which must not move the strip during a capture
            // head.
            s.motion.advanceFocusRing(by: dt)
            // One clock for every display (D9), so one tick drives every cover that is up. A display
            // still capturing is not among them: its seeds must not decay before its cover raises onto
            // them, which is what makes `advance` scoped rather than global.
            let covered = s.motion.coveredMonitors.map { (monitor: $0, contents: s.contents(of: $0)) }
            guard !covered.isEmpty else { return (s, []) }
            // Settled already ⇒ advancing moves nothing and the frame would repeat the last one. That is
            // every tick of a `snap` transition, which has no animator to advance, and the tail of a
            // `smooth` one still waiting on an AX set after its motion is over. Asked per display, so a
            // scroll on one screen does not re-blit a finished cover on the other.
            let moving = covered.filter { !s.motion.isSettled(on: $0.monitor, holding: $0.contents) }
            var effects: [Effect] = []
            if !moving.isEmpty {
                s.motion.advance(by: dt, on: moving.map(\.monitor),
                                 holding: moving.map(\.contents).reduce(MonitorContents()) { $0.union($1) })
                for entry in moving { effects += emitLayerFrames(s, on: entry.monitor) }
            }
            for entry in covered { effects += maybeCloseTransition(&s, on: entry.monitor,
                                                                   holding: entry.contents) }
            return (s, effects)

        // Truth-plane observations — reality folded into `World`, then re-placed

        case .windowCreated(let snapshot):
            let before = strandedGeometry(&s)
            // Read before focus moves: the new column opens beside whatever had focus.
            let beside = stripAnchor(s)
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
            if let assigned = rule.workspace, assigned != s.monitors.shown {
                let effects = arriveOnWorkspace(&s, snapshot, at: assigned, width: rule.width)
                return (s, effects)
            }
            s.world.setFocus(snapshot.id)   // a new window takes focus (truth tracked always)
            guard !before.isEmpty else { return (s, []) }   // no display known: nothing to place
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
            let effects = reassertTruthPlane(&s)   // a window dragged off its target snaps back
            return (s, effects)

        case .pointerEntered(let id):
            let effects = handlePointerEntered(&s, id)   // local first — the `.command` trap above
            return (s, effects)

        case .pointerWoke:
            // The mouse moved, so the user is looking at the desktop again. Edge-triggered and
            // idempotent: the shell's anchor and the core's flag are two records of one fact, and a
            // wake that arrives with nothing hidden is the ordinary way they resynchronize.
            guard s.pointer.isCursorHidden else { return (s, []) }
            s.pointer.isCursorHidden = false
            return (s, [.setCursorHidden(false)])

        case .appActivated:
            // An app coming to the front discards a hide issued from the background, so it is
            // re-asserted for as long as one is wanted. The state does not move: nothing is decided
            // here, something has been undone. The common case is emira's own `focus` landing, which is
            // why a command that hides sees one of these a few milliseconds later.
            guard s.pointer.isCursorHidden else { return (s, []) }
            return (s, [.setCursorHidden(true)])

        case .focusChanged(let id, let origin):
            // Externally-initiated focus (Cmd-Tab, Dock click, self-activation) and the echo of our own
            // `focus` effect. Reveal it under a cover, and emit no `focus`: we did not move it.
            guard let id else {
                s.world.setFocus(nil)              // focus left every managed window
                return (s, [])
            }
            if let refusal = refuseSystemFocusEvent(s, id, origin) { return (s, refusal) }
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
            let beside = stripAnchor(s)
            s.world.setMinimized(id, false)
            guard s.world.participatesInStrip(id) else {
                let effects = reassertTruthPlane(&s)
                return (s, effects)
            }
            s.world.setFocus(id)            // restoring re-focuses, like a fresh window
            guard !before.isEmpty else { return (s, []) }
            let effects = arriveOnStrip(&s, id, beside: beside, old: before)
            return (s, effects)

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
            let effects = reassertTruthPlane(&s)
            return (s, effects)

        case .screensChanged(let infos):
            // A display that left took its session with it, and the overlay it was drawing on still
            // has to be told — a dismissal is the one call that is safe for a screen that is gone.
            let abandoned = s.setMonitors(infos).map { Effect.endTransition($0) }
            if let focused = s.world.focusedWindow {
                let effects = reveal(&s, focused, center: s.config.centerFocusedColumn)
                return (s, abandoned + effects)
            }
            let effects = reassertTruthPlane(&s)
            return (s, abandoned + effects)

        // Effect feedback — every effect's result is just another event

        case .captureReady(let id):
            // A scoped still completes one of two waits: the *last* raises that display's cover and
            // teleports the reals behind it; one a retarget pulled into scope grows a raised cover.
            // **Untagged, so it is marked in every session waiting on it** (D10) — one still serves
            // however many covers show that window, and either of them may be the one it completes.
            s.motion.markCaptured(id)
            var effects: [Effect] = []
            for monitor in s.motion.transitioningMonitors {
                if s.motion.isReadyToRaise(on: monitor) {
                    s.motion.raiseCover(on: monitor)
                    guard let session = s.motion.transition(of: monitor) else { continue }
                    effects.append(.beginTransition(monitor, session.bindings))
                    effects += elevationEffects(s, on: monitor)   // z-order the bindings can't express
                    // A layer starts at its capture-time frame, which is wrong for a column captured at
                    // its park sliver. Presentation only: the reals move at `coverOnScreen`.
                    effects += emitLayerFrames(s, on: monitor)
                } else if s.motion.isReadyToExtend(on: monitor) {
                    let added = s.motion.extendCover(on: monitor)
                    guard !added.isEmpty else { continue }
                    // The `setLayerFrame`s ride along so a newcomer's layer is created *and* positioned
                    // in one `CATransaction`; the re-elevation does because `extendCover` appends on top.
                    effects += [.extendCover(monitor, added)] + elevationEffects(s, on: monitor)
                        + emitLayerFrames(s, on: monitor)
                }
            }
            return (s, effects)

        case .captureRefreshed(let id):
            // The window's own pixels, for a layer already standing in with older ones. No gate reads
            // this and no geometry follows from it — a window with no layer yet (its still beat the
            // raise) needs nothing either, because the raise reads the store and will find the fresh
            // one waiting there. Every layer showing it repaints: a window in two covers has one in each.
            return (s, s.motion.layerIds(for: id).map { .refreshLayer($0) })

        case .coverOnScreen(let monitor):
            // This display's cover is where the eye can see it, so the windows it shows may move. Gated
            // on the phase advancing rather than on `isCovered`: this teleport *replaces* that session's
            // landing wait, so a repeated report would free sets still in flight.
            guard s.motion.phase(of: monitor) == .raising else { return (s, []) }
            s.motion.confirmCover(on: monitor)
            let effects = teleportBehindCover(&s, on: monitor)
            return (s, effects)

        case .coverUnavailable(let monitor):
            // No pixels from the capture plane; raising anyway would black out that display. Nothing has
            // moved there yet, so abandon and snap — on that screen alone.
            guard s.motion.phase(of: monitor) == .capturing else { return (s, []) }
            s.motion.abortTransition(on: monitor)   // snaps its viewport to its target
            let effects = reassertTruthPlane(&s)
            return (s, effects)

        case .axLanded(let id):
            // A real window arrived at its AX target — marked in every session waiting on it, for the
            // reason `captureReady` is untagged. No session ⇒ no-op (an idle set's ack).
            s.motion.markLanded(id)
            let effects = closeSettledTransitions(&s)
            return (s, effects)

        case .placementCorrected(let id, let requested, let actual):
            let effects = handlePlacementCorrected(&s, id, requested: requested, actual: actual)
            return (s, effects)

        case .parkCorrected(let id, let requested, let actual):
            let effects = handleParkCorrected(&s, id, requested: requested, actual: actual)
            return (s, effects)

        case .axFailed(let id):
            // A set timed out or was refused. Resolve its landing so one stuck window can't wedge the
            // cover open, and mark its recorded frame a guess so the next placement re-issues the set.
            s.world.markUnverified(id)
            s.motion.markLanded(id)
            let effects = closeSettledTransitions(&s)
            return (s, effects)

        case .holdTimeout(let monitor):
            // Bound the wait: close that cover regardless, letting unlanded AX sets finish in the open.
            // One deadline per display, so a hung app under one cover costs the other screen nothing.
            guard s.motion.isTransitioning(on: monitor) else { return (s, []) }
            s.motion.closeTransition(on: monitor)
            // A session that timed out *before* its cover reached the glass never moved a window, and
            // closing it snapped the viewport to a destination nothing has travelled to. Free for a
            // covered session, which teleported at `coverOnScreen` and is already there.
            let effects = reassertTruthPlane(&s)
            return (s, [.endTransition(monitor)] + effects)

        case .crossfadeDone:
            // The cover is fully down; steady state resumed at `endTransition`.
            return (s, [])
        }
    }

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

        case .focusMonitor(let ref):
            return handleFocusMonitor(&s, ref)

        case .moveToMonitor(let ref):
            return handleMoveToMonitor(&s, ref, follow: false)

        case .moveToMonitorAndFocus(let ref):
            return handleMoveToMonitor(&s, ref, follow: true)

        case .moveWorkspaceToMonitor(let ref):
            return handleMoveWorkspaceToMonitor(&s, ref, follow: false)

        case .moveWorkspaceToMonitorAndFocus(let ref):
            return handleMoveWorkspaceToMonitor(&s, ref, follow: true)

        case .exec(let line):
            // Changes nothing, because a spawn is not a fact about the desktop — and opens no
            // transition for the same reason. Whatever window the process opens announces itself as
            // `windowCreated` whenever it is ready, and *that* is what animates.
            return [.exec(line)]

        // The only verb that is permanently a no-op here: `dumpState` is a *read*, answered out of band
        // by the shell off `Runtime.state`. Everything else in the vocabulary does
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
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)

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

    // Structural edits (the strip rearranged, under the cover)

    /// Everything a structural command must read off the old geometry before it destroys it. `widths` is
    /// captured once and used for *both* `naturalFrames` calls, so the scroll and any in-flight resize
    /// cancel in the difference and what survives is purely structural.
    private struct StructuralSnapshot {
        /// The display this is the geometry of. An edit that changes what two screens show carries one
        /// snapshot each, and each drives its own display's cover.
        let monitor: MonitorId
        /// The in-flight column widths both calls resolve against.
        let widths: [ColumnId: Double]
        /// Where every window on every workspace **this display holds** sat under the geometry we are
        /// leaving. The offset it was read at is deliberately not kept — see `finishStructuralEdit`.
        let frames: [WindowId: Rect]
        /// What was on this display's screen under that geometry — half of the two-geometry scope.
        let departing: [WindowId]

        /// The same snapshot plus an arriving window at the frame its app just opened it at — also the
        /// frame the cover captured, so the raise does not pop.
        func including(_ id: WindowId, at frame: Rect) -> StructuralSnapshot {
            var frames = self.frames
            frames[id] = frame
            return StructuralSnapshot(monitor: monitor, widths: widths, frames: frames,
                                      departing: departing)
        }
    }

    /// Read one display's old geometry, after `reconcile` and the handler's guards — taken before it,
    /// the membership bridge's own churn would show up as a bogus displacement. Frames span every
    /// workspace that display holds; `departing` is the strip it is showing.
    ///
    /// `nil` for a display that is not attached, which is what makes a snapshot list empty rather than
    /// wrong when there is no geometry to leave.
    ///
    /// - Parameter travelling: an address about to change displays. **Both screens read it as their
    ///   own here**, which is invariant 4's implementation: the hand-over is two independent workspace
    ///   switches, and the destination's is a slide *in* from one screen away — which it can only be if
    ///   the geometry it is leaving already places the workspace there.
    private static func structuralSnapshot(_ s: State, on monitor: MonitorId,
                                           travelling: WorkspaceName? = nil) -> StructuralSnapshot? {
        guard let metrics = s.metrics(of: monitor),
              let shown = s.monitors.shown(on: monitor) else { return nil }
        let start = s.motion.offset(of: monitor).current
        let widths = s.motion.currentColumnWidths
        var drawn = s.monitors.owned(of: monitor)
        if let travelling, !drawn.contains(travelling) { drawn.append(travelling) }
        return StructuralSnapshot(
            monitor: monitor,
            widths: widths,
            frames: s.workspaces.naturalFrames(shown: shown, among: drawn,
                                               scrollOffset: start, metrics: metrics, widths: widths),
            departing: s.workspaces[shown].visibleWindowIds(scrollOffset: start, metrics: metrics))
    }

    /// One snapshot per display an edit is about to change, deduplicated and in the order given. A
    /// cross-display verb names two and an ordinary one names the acting monitor twice over, so the
    /// dedupe is the thing that keeps "one display" the special case of "several" rather than a branch.
    ///
    /// **Empty is the snap signal**: no display attached, and every caller reads it as "land this at
    /// once" (`finishStructuralEdit`).
    private static func snapshots(_ s: State, of monitors: [MonitorId?],
                                  travelling: WorkspaceName? = nil) -> [StructuralSnapshot] {
        var seen: Set<MonitorId> = []
        return monitors.compactMap { $0 }.filter { seen.insert($0).inserted }
            .compactMap { structuralSnapshot(s, on: $0, travelling: travelling) }
    }

    /// The acting monitor's snapshot alone — what every edit that changes one screen passes.
    private static func actingSnapshot(_ s: State) -> [StructuralSnapshot] {
        snapshots(s, of: [s.monitors.focused])
    }

    /// One window's journey **between displays**, or `nil` for one that stayed.
    ///
    /// The case each display's own difference cannot see: a window handed across the desktop is missing
    /// from the *after* side on the display it left (whose strips no longer hold it) and from the
    /// *before* side on the one it reached (whose strips did not hold it yet), so each screen sees one
    /// frame and no travel — a hard cut on the arrival, a frozen layer on the departure.
    ///
    /// Both sides are natural frames, and natural frames on every display share **one global space**, so
    /// this is a single difference that both covers read. That is also why `finishStructuralEdit` seeds
    /// it once: the displacement animators are the desktop's, not a display's, and a second seed would
    /// double the travel.
    private struct Crossing {
        let window: WindowId
        /// The display now holding the window — whose viewport the arrival is aimed at.
        let to: MonitorId
        let was: Rect
        let now: Rect
    }

    /// Where `id` was in the geometry being left, and where it belongs now — `nil` unless it genuinely
    /// changed displays, which is a snapshot holding its old frame plus a *different* display holding
    /// its workspace afterwards. A window that stayed is left to the ordinary per-display difference,
    /// which already answers for it.
    private static func crossing(_ s: State, _ id: WindowId, leaving snapshots: [StructuralSnapshot],
                                 widths: [ColumnId: Double]) -> Crossing? {
        guard let source = snapshots.first(where: { $0.frames[id] != nil }), let was = source.frames[id],
              let home = s.workspaces.workspace(of: id),
              let owner = s.monitors.monitor(of: home), owner != source.monitor,
              let now = naturalFrame(s, of: id, on: owner, widths: widths) else { return nil }
        return Crossing(window: id, to: owner, was: was, now: now)
    }

    /// `id`'s presentation-plane frame on the display that holds its workspace — the same global number
    /// that display's own cover draws it at, which is what lets two covers agree about a window in
    /// flight between them. `nil` for a window on no strip, or a display with no metrics.
    private static func naturalFrame(_ s: State, of id: WindowId, on monitor: MonitorId,
                                     widths: [ColumnId: Double]) -> Rect? {
        guard let home = s.workspaces.workspace(of: id), let metrics = s.metrics(of: monitor),
              let shown = s.monitors.shown(on: monitor) else { return nil }
        return s.workspaces.naturalFrames(shown: shown, among: [home],
                                          scrollOffset: s.motion.offset(of: monitor).current,
                                          metrics: metrics, widths: widths)[id]
    }

    /// Move the focused window one slot. Horizontal branches on whether it has company: a window alone in
    /// its column moves the whole column one place along the strip; one with stackmates pops out into a
    /// new single-window column on that side. Vertical swaps it with a stack neighbour. No wrap, and no
    /// `.focus` effect — focus already sits on the mover, and a redundant AX set can make an app raise.
    private static func handleMoveWindow(_ s: inout State, _ direction: Direction) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        // Metrics guard before the mutation: with no display known there is no correct frame to land on.
        guard s.metrics() != nil,
              let focused = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: focused) else { return [] }

        let old = actingSnapshot(s)

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
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        guard s.metrics() != nil,
              let focused = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: focused) else { return [] }

        let old = actingSnapshot(s)

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
    /// **One snapshot per display the edit changes, and each drives its own cover** (D7). A verb that
    /// hands a window or a workspace across the desktop changes what two screens show, and the two are
    /// two presentation planes: each decides for itself whether it has anything to animate, so one may
    /// open a cover while the other lands its share at once. On one display that is the single-cover
    /// path it always was.
    ///
    /// - Parameter mover: the window drawn on top, `nil` for a departure — the thing that moved has left.
    /// - Parameter focused: the window the viewport frames on afterwards, `nil` to keep the offset. Only
    ///   the display whose strip actually holds it frames on it; the others keep the offset they have.
    /// - Parameter snapshots: the geometry each display is leaving. Empty to snap (no display known, or
    ///   a deliberate cut).
    /// - Parameter travelling: a window this edit hands **across displays**. Named because it is the one
    ///   term of the difference no single display can compute — see `Crossing`.
    /// - Parameter framedAt: an offset to come to rest at instead of the reveal `focused` would compute —
    ///   an un-fullscreen restoring a remembered viewport rather than framing on anything. Still subject
    ///   to the no-motion snap below, so a restore to where we already are is free.
    private static func finishStructuralEdit(_ s: inout State, _ edit: LayoutEdit,
                                             focused: WindowId?, mover: WindowId?,
                                             animatingFrom snapshots: [StructuralSnapshot],
                                             travelling: WindowId? = nil,
                                             framedAt: Double? = nil) -> [Effect] {
        guard edit.moved else { return [] }
        if let dead = edit.destroyedColumn { s.motion.removeColumnWidthAnimator(dead) }

        guard !snapshots.isEmpty else {          // not animating this one — land it at once
            if let monitor = s.monitors.focused,
               let end = restingOffset(s, on: monitor, focused: focused, framedAt: framedAt) {
                s.motion.snapViewport(to: end, on: monitor)
            }
            return reassertTruthPlane(&s)
        }

        // Read against the widths the *first* snapshot captured, for the reason both `naturalFrames`
        // calls below share one set: the scroll and any in-flight resize then cancel in the difference
        // and what survives is purely the hand-over. Seeded once, before any display's own pass —
        // both covers read this one displacement (see `Crossing`).
        let crossed = travelling.flatMap {
            crossing(s, $0, leaving: snapshots, widths: snapshots[0].widths)
        }
        if let crossed, s.config.transitionMode.animates {
            s.motion.displaceWindow(crossed.window, by: crossed.was.delta(from: crossed.now),
                                    params: s.config.moveSpring, on: crossed.to)
        }

        var effects: [Effect] = []
        var snapped = false
        for old in snapshots {
            let monitor = old.monitor
            // Metrics are re-read rather than carried in the snapshot: `cycle-height` forgets a
            // column's corrections between the two, and the new geometry is the corrected one.
            guard let metrics = s.metrics(of: monitor), let shown = s.monitors.shown(on: monitor),
                  let end = restingOffset(s, on: monitor, focused: focused, framedAt: framedAt)
            else { continue }
            let strip = s.workspaces[shown]
            // Re-read, not carried in the snapshot: for a workspace switch it must *not* be the number
            // the snapshot was taken at, since switching snaps the offset to the incoming strip's
            // remembered scroll in between — which makes the horizontal axis cancel out of the seed.
            let start = s.motion.offset(of: monitor).current

            let scope = scopeUnion(s, old.departing,
                                   strip.sweptWindowIds(from: start, to: end, metrics: metrics))

            guard s.motion.isTransitioning(on: monitor)
                    || (s.config.transitionMode.covers && !scope.isEmpty) else {
                s.motion.snapViewport(to: end, on: monitor)
                snapped = true
                continue
            }

            // The second half of the difference: the new geometry, at the live offset and the *same*
            // widths. A window that changed displays appears in one side only and is skipped below —
            // correctly, since there is no single travel for it and both covers already draw it.
            let new = s.workspaces.naturalFrames(shown: shown, among: s.monitors.owned(of: monitor),
                                                 scrollOffset: start, metrics: metrics,
                                                 widths: old.widths)
            // What the edit moves where someone could see it — scoped only, since a window with no
            // layer has nothing to lag behind. A fact about the layout, so no mode changes it; only
            // whether it is put in motion below. The travelling window is excluded because its own
            // difference spans two displays and is already seeded above, once for both.
            let moves: [(id: WindowId, delta: Rect)] = scope.compactMap { id in
                guard id != crossed?.window, let was = old.frames[id], let now = new[id],
                      !approximatelyEqual(was, now) else { return nil }
                return (id, was.delta(from: now))
            }
            if s.config.transitionMode.animates {
                for move in moves {
                    s.motion.displaceWindow(move.id, by: move.delta, params: s.config.moveSpring,
                                            on: monitor)
                }
            }

            // An edit nothing on this screen can see needs no cover on it. The viewport is asked
            // separately because closing the strip's *last* column displaces nobody, and the crossing
            // separately again because it is the one travel not in `moves` — a window arriving on an
            // otherwise-still screen is the whole of what that display has to animate.
            let carries = crossed.map { scope.contains($0.window) } ?? false
            let scrolls = !approximatelyEqualScalar(end, start)
            guard !moves.isEmpty || carries || scrolls || s.motion.isTransitioning(on: monitor) else {
                s.motion.snapViewport(to: end, on: monitor)
                snapped = true
                continue
            }

            effects += driveTransition(&s, on: monitor, to: end, scope: scope)
            // After `driveTransition`: `elevate` no-ops without a session, and that is where one is
            // born. Named on every cover that draws it — a window crossing displays is on two.
            if let mover { s.motion.elevate(mover, on: monitor) }
            // The display it *left* cannot place it from its own strips; the one it reached can, and
            // marking both costs nothing (`emitLayerFrames` prefers its own geometry).
            if carries, let crossed { s.motion.carry(crossed.window, on: monitor) }
            // Emits nothing for a session still capturing, nor for a mover just pulled into scope.
            effects += elevationEffects(s, on: monitor)
        }
        // One pass for however many displays landed their share at once; a display that opened a cover
        // is held back by the gate inside it and teleports at `coverOnScreen` instead.
        return snapped ? effects + reassertTruthPlane(&s) : effects
    }

    /// Where one display's viewport comes to rest after an edit: the offset revealing `focused` on the
    /// strip that display is showing, or — for a display whose strip does not hold it — where it
    /// already is. No `end == start ⇒ snap` guard: a swap in full view moves the viewport not at all.
    ///
    /// `framedAt` is the acting monitor's alone: it restores a viewport this verb remembered, and only
    /// one display can be the subject of that.
    private static func restingOffset(_ s: State, on monitor: MonitorId, focused: WindowId?,
                                      framedAt: Double?) -> Double? {
        guard let metrics = s.metrics(of: monitor),
              let shown = s.monitors.shown(on: monitor) else { return nil }
        let strip = s.workspaces[shown]
        let start = s.motion.offset(of: monitor).current
        let revealed = focused.flatMap {
            s.config.centerFocusedColumn
                ? strip.scrollOffsetToCenter(window: $0, metrics: metrics)
                : strip.scrollOffsetToReveal(window: $0, from: start, metrics: metrics)
        }
        return (monitor == s.monitors.focused ? framedAt : nil) ?? revealed ?? start
    }

    /// `Effect.elevateLayer` for the window `monitor`'s transition draws on top, or nothing — no
    /// session, nothing elevated, or no cover up. Total, so call sites append it unconditionally.
    private static func elevationEffects(_ s: State, on monitor: MonitorId) -> [Effect] {
        guard let layer = s.motion.elevatedLayer(on: monitor) else { return [] }
        return [.elevateLayer(layer)]
    }

    // Workspaces (the second axis)
    //
    // A workspace switch is a structural edit in `finishStructuralEdit`'s sense: one geometric term
    // (`Workspaces.verticalOffset`) plus the call `move-window` makes.

    /// Switch to a workspace, **wherever it lives** (D1). Resolving to the one the acting monitor is
    /// already showing is a silent no-op, which is also how `next` at the top of the monitor's own set
    /// comes out — `State.resolve` clamps rather than wrapping.
    private static func handleFocusWorkspace(_ s: inout State, _ ref: WorkspaceRef) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        let destination = s.resolve(ref)
        guard destination != s.monitors.shown else { return [] }
        // Read before anything moves: the geometry the switch is about to stop being true, on the
        // display that is going to do the switching.
        return switchWorkspace(&s, to: destination, animatingFrom: snapshots(s, of: [host(s, destination)]))
    }

    /// Move the user to another display, whatever it is showing — the one verb that rearranges no
    /// strip at all. Focus lands on that address's remembered window, or on nothing, which is exactly
    /// what invariant 3 buys: an empty display can hold emira's focus, and the next window opens there.
    private static func handleFocusMonitor(_ s: inout State, _ ref: MonitorRef) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        guard let target = s.resolve(ref), target != s.monitors.focused,
              let destination = s.monitors.shown(on: target) else { return [] }
        return switchWorkspace(&s, to: destination, animatingFrom: snapshots(s, of: [target]))
    }

    /// Move the focused window to another workspace, optionally following it there. A window, not its
    /// column: one with stackmates leaves them behind. It opens beside whatever the destination was last
    /// focused on and becomes its remembered focus, so a run of moves builds a group.
    private static func handleMoveToWorkspace(_ s: inout State, _ ref: WorkspaceRef,
                                              follow: Bool) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        return moveToWorkspace(&s, s.resolve(ref), follow: follow)
    }

    /// Move the focused window to whatever `<mon>` is showing — `move-to-workspace` with the address
    /// named by the display holding it rather than by its own letter.
    private static func handleMoveToMonitor(_ s: inout State, _ ref: MonitorRef,
                                            follow: Bool) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        guard let target = s.resolve(ref), target != s.monitors.focused,
              let destination = s.monitors.shown(on: target) else { return [] }
        return moveToWorkspace(&s, destination, follow: follow)
    }

    /// The body both move-a-window verbs share.
    ///
    /// **The destination decides how many screens change**, and nothing here has to branch on it: an
    /// address another display holds carries the window there, so both that display's geometry and this
    /// one's are snapshotted and `finishStructuralEdit` gives each the cover it turns out to need. An
    /// address nobody is showing takes the window straight to a parking lot, where there is nothing to
    /// animate and that display lands its share at once.
    private static func moveToWorkspace(_ s: inout State, _ destination: WorkspaceName,
                                        follow: Bool) -> [Effect] {
        guard destination != s.monitors.shown,
              let moved = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: moved) else { return [] }

        // Read before the edit: the geometry it invalidates on both displays, the column's id (to tell
        // afterwards whether the departure emptied it), and its index, where focus falls back to if so.
        // The destination's owner is read before `State.move`, which is what *gives* an unassigned
        // address an owner — after it, every move would look like a same-display one.
        let old = snapshots(s, of: [s.monitors.focused, s.monitors.monitor(of: destination)])
        let column = s.layout.columns[index].id
        let edit = s.move(window: moved, to: destination,
                          insertingAfter: s.workspaces[lastFocusOf: destination])
        guard edit.moved else { return [] }
        if let dead = edit.destroyedColumn { s.motion.removeColumnWidthAnimator(dead) }
        s.workspaces[lastFocusOf: destination] = moved

        if follow {
            return switchWorkspace(&s, to: destination, focusing: moved, mover: moved,
                                   animatingFrom: old, travelling: moved)
        }

        // Staying: focus left with the window, so it lands on the neighbour — or, on an emptied strip, off
        // the strip entirely, which `handleFocus`'s entry condition recovers from.
        let heir = successor(s.layout, column: column, at: index)
        s.world.setFocus(heir)
        let effects = finishStructuralEdit(&s, edit, focused: heir, mover: moved, animatingFrom: old,
                                           travelling: moved)
        return heir.map { effects + [.focus($0)] } ?? effects
    }

    /// Hand the acting monitor's workspace to another display, which shows it (D3). No window changes
    /// strips: what travels is the **address**, so both screens switch — the destination to the
    /// arriving workspace, the source to whatever `Monitors` falls it back to.
    ///
    /// Invariant 4 is why this is two independent switches rather than one animation: no workspace ever
    /// travels *between* displays, so each screen runs the vertical slide it already has.
    private static func handleMoveWorkspaceToMonitor(_ s: inout State, _ ref: MonitorRef,
                                                     follow: Bool) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        guard let source = s.monitors.focused, let target = s.resolve(ref),
              target != source else { return [] }
        let travelling = s.monitors.shown
        let old = snapshots(s, of: [source, target], travelling: travelling)

        // The live authority for the travelling address is the source's viewport, and the destination
        // reads it back out of the strip's own memory — which is how a workspace keeps its scroll and
        // its focus across the desktop (§8).
        s.workspaces[scrollOffsetOf: travelling] = s.motion.offset(of: source).current
        s.workspaces[lastFocusOf: travelling] = s.world.focusedWindow.flatMap {
            s.workspaces[travelling].columnIndex(ofWindow: $0) == nil ? nil : $0
        }
        // One call for both halves: the claim moves `owned` with `shown`, and the source falls back to
        // an address it can have — which may be one nothing has ever materialized, hence `State.show`.
        s.show(travelling, on: target)

        // Each display now shows its own address and needs its viewport at that address's memory.
        if let landed = s.monitors.shown(on: source) {
            s.motion.snapViewport(to: s.workspaces[scrollOffsetOf: landed], on: source)
        }
        s.motion.snapViewport(to: s.workspaces[scrollOffsetOf: travelling], on: target)

        if follow { s.monitors.focus(target) }
        // Focus follows the screen the user is on, not the workspace: staying means picking up whatever
        // the source's fallback address remembers, which is the same rule `focus-monitor` runs on.
        let landing = s.monitors.shown
        let wanted = s.workspaces[lastFocusOf: landing] ?? s.workspaces[landing].allWindowIds.first
        s.world.setFocus(wanted)
        if let wanted { s.workspaces[lastFocusOf: landing] = wanted }

        var effects = finishStructuralEdit(&s, LayoutEdit(moved: true, destroyedColumn: nil),
                                           focused: wanted, mover: nil, animatingFrom: old)
        if let wanted { effects.append(.focus(wanted)) }
        return effects
    }

    /// The display a destination address switches on: the one holding it, or the acting monitor for an
    /// address nobody holds yet. The whole of D1 in one line — an absolute reference goes wherever the
    /// workspace lives, and the user goes with it.
    private static func host(_ s: State, _ destination: WorkspaceName) -> MonitorId? {
        s.monitors.monitor(of: destination) ?? s.monitors.focused
    }

    /// The body of a workspace switch — shared by `focus-workspace`, `focus-monitor`,
    /// `move-to-workspace-and-focus`, and the cross-workspace `focusChanged`. Store the live offset and
    /// strip focus into the outgoing record, move `focused`, snap the viewport to the incoming record,
    /// pick the window to focus, then place through `finishStructuralEdit` — between whose two
    /// `naturalFrames` reads those steps sit, making the seed purely vertical.
    ///
    /// **Which display switches is the address's to decide (D1).** An address another display holds is
    /// reached by going *there*: the user moves first, that display switches, and the display being left
    /// keeps showing what it was showing. An address the acting monitor holds — or one nobody holds —
    /// switches here, which is single-display behaviour to the letter.
    ///
    /// - Parameter mover: the window drawn on top; `nil` for a plain `focus-workspace`, whose strips never
    ///   overlap.
    /// - Parameter old: the geometry being left, or empty to snap (see `finishStructuralEdit`).
    /// - Parameter travelling: a window this switch carries **across displays** — `move-to-workspace-and-focus`
    ///   onto an address another screen holds, and nothing else.
    /// - Parameter announcingFocus: whether to emit `.focus`. `false` on the `focusChanged` path, where
    ///   the shell already moved focus — asking again is a redundant AX set and an echo to absorb.
    private static func switchWorkspace(_ s: inout State, to destination: WorkspaceName,
                                        focusing wanted: WindowId? = nil,
                                        mover: WindowId? = nil,
                                        animatingFrom old: [StructuralSnapshot],
                                        travelling: WindowId? = nil,
                                        announcingFocus: Bool = true) -> [Effect] {
        // Focus is leaving the address the user is on, whichever display ends up switching — and on a
        // cross-display switch that is *not* the address going off screen, so it is remembered here
        // rather than beside the outgoing strip's scroll below. Only a window on that strip is worth
        // remembering: a float has no column to return to.
        let here = s.monitors.shown
        s.workspaces[lastFocusOf: here] = s.world.focusedWindow.flatMap {
            s.workspaces[here].columnIndex(ofWindow: $0) == nil ? nil : $0
        }
        // The user moves first, so every read below is the switching display's own.
        if let owner = s.monitors.monitor(of: destination) { s.monitors.focus(owner) }

        // An unanimated switch must not leave a cover over a desktop it no longer pictures — asked of
        // the display that is about to change, which is why it follows the move.
        var effects = old.isEmpty ? abandonTransition(&s) : []

        let outgoing = s.monitors.shown
        s.workspaces[scrollOffsetOf: outgoing] = s.viewport.offset.current

        // The two halves of a switch: the monitor shows the new address (which claims it), and every
        // address left on a screen gets a strip. Neither container can do the other's half, which is
        // the join working — and the claim can re-home another display, so the halves are not 1:1.
        s.show(destination)
        s.motion.snapViewport(to: s.workspaces[scrollOffsetOf: destination], on: s.monitors.focused)

        // An empty workspace focuses nothing, written rather than skipped: focus is every verb's subject,
        // so leaving it on the strip being left aims them at a window the user cannot see. `handleFocus`
        // treats the `nil` as an entry condition.
        let target = wanted ?? s.workspaces[lastFocusOf: destination] ?? s.layout.allWindowIds.first
        s.world.setFocus(target)
        if let target { s.workspaces[lastFocusOf: destination] = target }

        effects += finishStructuralEdit(&s, LayoutEdit(moved: true, destroyedColumn: nil),
                                        focused: target, mover: mover, animatingFrom: old,
                                        travelling: travelling)
        if let target, announcingFocus { effects.append(.focus(target)) }
        return effects
    }

    // The focus we did not ask for (`[focus] system-events`)

    /// Whether `[focus] system-events` refuses this focus report — and if so, the whole of the response.
    ///
    /// `nil` admits, and the caller carries on as if the policy did not exist. A refusal is one `.focus`
    /// effect and **no state change at all** — which the signature says, taking `State` by value: the
    /// core's belief about focus never moved, so re-asserting it is the entire undo. Nothing reveals, no
    /// workspace switches, no cover goes up — which is the point, since the transition is exactly what
    /// the user did not want to watch.
    ///
    /// **Our own echo** is always admitted, in every mode, because the reducer wrote that focus
    /// optimistically when it emitted the effect, so refusing it would leave the core arguing with itself.
    /// Before the first `screensChanged` there is no geometry to judge against either, and no grounds to
    /// refuse is not a refusal.
    ///
    /// **Having nothing to restore to is not consent.** A refusal is at most one `.focus`, so with no
    /// anchor it is simply silent — emira declines to move and macOS's own focus stands, which cannot
    /// leave the desktop keyless because nothing here can unfocus a window. Admitting instead was the
    /// rule this replaces, and it is reachable in two ordinary ways that both end with the desktop
    /// switching to a workspace nobody asked for: a `focusChanged` naming no window (routine, legitimate,
    /// and handled above this guard, so it clears focus without ever consulting the policy), and sitting
    /// on an **empty** workspace, where there is no anchor to be had.
    ///
    /// The anchor is `stripAnchor`'s and not `World.focusedWindow` alone, because this asks *where the
    /// user would be if this report had not arrived* and focus is only a proxy for that.
    private static func refuseSystemFocusEvent(_ s: State, _ id: WindowId,
                                               _ origin: FocusOrigin) -> [Effect]? {
        // `.respect` is redundant with `admitsSystemFocusEvent` and tested here anyway, so the default
        // policy pays nothing below. `metrics` is the witness that a placement has ever run — nothing can
        // be placed without it, and the first `screensChanged` places — so there is no record to judge a
        // boot-time report against, and no grounds to refuse is not a refusal.
        guard origin == .system, s.config.systemFocusEvents != .respect,
              s.metrics() != nil else { return nil }
        guard !admitsSystemFocusEvent(s, id) else { return nil }
        // Focus first when there is one — a float holds focus and has no column, so `stripAnchor`
        // declines it, and it is still plainly what the user was looking at.
        guard let restore = s.world.focusedWindow ?? stripAnchor(s) else { return [] }
        // Already ours: nothing to undo, and the reveal is the promise that a focused window is one the
        // user can see. Never reached from another workspace, where focus is `nil` rather than stale.
        guard restore != id else { return nil }
        return [.focus(restore)]
    }

    /// Whether the policy lets a focus emira did not cause land on `id`.
    ///
    /// The ladder is monotone by construction rather than by three separate tests: `ignore` is
    /// `onScreen` minus the windows emira places, and `respect` admits without asking.
    private static func admitsSystemFocusEvent(_ s: State, _ id: WindowId) -> Bool {
        switch s.config.systemFocusEvents {
        case .respect:
            return true
        case .onScreen:
            return s.world.isOnScreen(id)
        case .ignore:
            return s.world.isOnScreen(id) && !s.world.participatesInStrip(id)
        }
    }

    /// Move focus because the pointer crossed into a window.
    ///
    /// Reduces into the same tail as `focus(Direction)` — reveal plus `.focus` — so the echo comes back
    /// marked `.ours` through `FocusIntent` and nothing new is needed on the way home. The termination
    /// argument is not here but in the shell: this fires on **pointer** motion only, so a window sliding
    /// under a stationary pointer changes nothing and a reveal cannot chase itself across the desktop.
    private static func handlePointerEntered(_ s: inout State, _ id: WindowId) -> [Effect] {
        guard s.config.focusFollowsMouse, s.world.focusedWindow != id,
              s.world.windows[id] != nil else { return [] }
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        s.world.setFocus(id)
        // Off the strip — a float, a dialog, a sheet — there is no column to frame on and nothing to
        // scroll: the window is already exactly where its app put it.
        guard s.layout.columnIndex(ofWindow: id) != nil else { return [.focus(id)] }
        return scrollReveal(&s, to: id, center: s.config.centerFocusedColumn) + [.focus(id)]
    }

    /// Reveal an externally-focused window (Cmd-Tab, a Dock click, an app raising itself), switching
    /// workspaces first if it lives on another one. Focus must be recorded *inside* the switch, which
    /// stores the outgoing workspace's remembered focus — setting `World.focusedWindow` to a window on
    /// another strip first would make that read `nil` and wipe it. No `.focus` effect is emitted, which
    /// makes a feedback loop unrepresentable.
    ///
    /// Both axes animate, and for one reason: a reveal is a move of the strip whoever asked for it. On one
    /// strip that is `scrollReveal`'s cover, and across two it is the *same* switch `focus-workspace`
    /// performs — handed the same before-geometry, since a span emira animates on demand cannot become a
    /// cut for arriving at it by Cmd-Tab. An app also hands key status to a survivor *before* it destroys
    /// the window it is closing, so a focus report is routinely the first half of a structural edit — and
    /// a transition is what the second half can ride.
    private static func revealAcrossWorkspaces(_ s: inout State, _ id: WindowId) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        if let home = s.workspaces.workspace(of: id), home != s.monitors.shown {
            // Read before `focused` moves, exactly as `handleFocusWorkspace` does: the geometry the
            // switch is about to stop being true, on the display that is going to do the switching.
            return switchWorkspace(&s, to: home, focusing: id,
                                   animatingFrom: snapshots(s, of: [host(s, home)]),
                                   announcingFocus: false)
        }
        s.world.setFocus(id)
        // Off the strip — a float, a dialog, a sheet — there is no column to frame on and nowhere to
        // scroll, so the placement pass is the whole answer.
        guard s.layout.columnIndex(ofWindow: id) != nil else {
            return reveal(&s, id, center: s.config.centerFocusedColumn)
        }
        return scrollReveal(&s, to: id, center: s.config.centerFocusedColumn)
    }

    /// Drop an in-flight transition before something rearranges the world it pictures — one caller, the
    /// snapped cross-workspace switch. `closeTransition` snaps the viewport to where the abandoned scroll
    /// would have come to rest, which is what the outgoing workspace then remembers.
    private static func abandonTransition(_ s: inout State) -> [Effect] {
        guard let monitor = s.monitors.focused, s.motion.isTransitioning(on: monitor) else { return [] }
        s.motion.closeTransition(on: monitor)
        return [.endTransition(monitor)]
    }

    // Floating (leaving the strip on purpose)

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
            let beside = stripAnchor(s)
            s.world.setFloating(focused, false)
            // Still off the strip (its app is hidden, or it is minimized): nothing to animate into.
            guard s.world.participatesInStrip(focused), !before.isEmpty else { return reassertTruthPlane(&s) }
            // No `.focus`: it already holds focus, and re-asserting it is an AX set that can make an
            // app raise a *different* window forward.
            return arriveOnStrip(&s, focused, beside: beside, old: before, announcingFocus: false)
        }

        // Tiled → floating: a departure, like a minimize — except focus stays put, because the window is
        // still there. `departFromStrip` only picks a successor when focus was actually lost, and the
        // viewport holds, since a window with no column reveals to nowhere.
        return departFromStrip(&s, focused) { $0.world.setFloating(focused, true) }
    }

    // Placement (the instant-correct core)

    /// Snap the viewport to reveal `id`'s column (centered, or minimally revealed per config) and re-place
    /// every window — the no-animation reveal: a display change, a config reload, a focus landing off the
    /// strip. The geometry changed under the strip with nothing travelling anywhere, so there is no motion
    /// to make. Reconciles first, so the strip accounts for every window before an offset is computed
    /// against it. A snap-path event arriving mid-scroll is redirected through `driveTransition`, so it
    /// cannot snap the viewport out from under a raised cover.
    private static func reveal(_ s: inout State, _ id: WindowId, center: Bool) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        guard let (monitor, metrics) = s.acting() else { return [] }
        let start = s.viewport.offset.current
        let offset = center
            ? s.layout.scrollOffsetToCenter(window: id, metrics: metrics)
            : s.layout.scrollOffsetToReveal(window: id, from: start, metrics: metrics)
        if s.motion.isTransitioning(on: monitor) {
            // A window with no column (a float taking focus) reveals to nowhere: keep the destination.
            let end = offset ?? s.viewport.offset.target
            return driveTransition(&s, on: monitor, to: end,
                                   scope: s.layout.sweptWindowIds(from: start, to: end, metrics: metrics))
        }
        if let offset { s.motion.snapViewport(to: offset, on: monitor) }
        return reassertTruthPlane(&s)
    }

    // The animated scroll (the transition session)

    /// Reveal `id`'s column with a transition under a layered cover — the counterpart to `reveal`'s bare
    /// snap, and where every scroll of the strip goes: the focus commands, and the focus reports emira did
    /// not cause. An open transition is retargeted; no motion, or no cover to make (`transition = off`,
    /// which a missing Screen Recording grant forces), degrades to a snap-place; otherwise a fresh session
    /// is scoped to every window the viewport sweeps between start and end.
    private static func scrollReveal(_ s: inout State, to id: WindowId, center: Bool) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        guard let (monitor, metrics) = s.acting() else { return [] }
        let start = s.viewport.offset.current
        let end = center
            ? s.layout.scrollOffsetToCenter(window: id, metrics: metrics)
            : s.layout.scrollOffsetToReveal(window: id, from: start, metrics: metrics)
        guard let end else { return [] }

        if s.motion.isTransitioning(on: monitor) {
            return driveTransition(&s, on: monitor, to: end,
                                   scope: s.layout.sweptWindowIds(from: start, to: end, metrics: metrics))
        }

        if approximatelyEqualScalar(end, start) {
            return reassertTruthPlane(&s)               // already in view → snap, no cover
        }

        // No capture capability ⇒ no cover worth raising. Checked *before* the scope is computed.
        guard s.config.transitionMode.covers else {
            s.motion.snapViewport(to: end, on: monitor)
            return reassertTruthPlane(&s)
        }

        let scope = s.layout.sweptWindowIds(from: start, to: end, metrics: metrics)
        guard !scope.isEmpty else {                 // defensive: nothing to cover → snap
            s.motion.snapViewport(to: end, on: monitor)
            return reassertTruthPlane(&s)
        }
        return driveTransition(&s, on: monitor, to: end, scope: scope)
    }

    /// Open a transition on `monitor` aimed at `end` over `scope`, or redirect a running one there. The
    /// single place a session is opened or re-aimed; the caller owns the snap decisions. On a redirect
    /// the scope is widened, never replaced — a window the old destination swept is already mid-flight on
    /// the presentation plane and mid-teleport on the truth plane — and each newcomer owes a `capture`.
    private static func driveTransition(_ s: inout State, on monitor: MonitorId, to end: Double,
                                        scope: [WindowId]) -> [Effect] {
        guard s.motion.isTransitioning(on: monitor) else {
            s.motion.openTransition(scope: scope, on: monitor)
            aimViewport(&s, at: end, on: monitor)
            return captures(s, scope, on: monitor)
        }
        aimViewport(&s, at: end, on: monitor)
        let newcomers = s.motion.extendTransition(scope: scope, on: monitor)
        var effects: [Effect] = captures(s, newcomers, on: monitor)
        if s.motion.isCovered(on: monitor) { effects += teleportBehindCover(&s, on: monitor) }
        return effects
    }

    /// Aim `monitor`'s scroll at `end` — in motion under `smooth`, already arrived under `snap`, which is
    /// what puts a snapped cover's first blit at the finished geometry (`emitLayerFrames` reads
    /// `.current`). Both paths bump that display's `retargetGeneration`, so a redirect re-arms its hold
    /// timer under either.
    private static func aimViewport(_ s: inout State, at end: Double, on monitor: MonitorId) {
        if s.config.transitionMode.animates {
            s.motion.retargetViewport(to: end, on: monitor)
        } else {
            s.motion.snapViewport(to: end, on: monitor)
        }
    }

    /// Ask the capture plane for each of `ids`, naming the cover the pixels are for and carrying the size
    /// the world currently records — the one fact that decides whether a kept still may stand in for a
    /// fresh capture (`Effect.capture`).
    private static func captures(_ s: State, _ ids: [WindowId], on monitor: MonitorId) -> [Effect] {
        ids.map { .capture(monitor, $0, size: s.world.windows[$0]?.frame.size ?? .zero) }
    }

    // The animated resize (the strip's own geometry in motion)

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
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        guard s.metrics() != nil,
              let focused = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: focused) else { return [] }

        let windowIds = s.layout.columns[index].windowIds     // a copy; read before the mutation
        let old = actingSnapshot(s)

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
    ///
    /// Under `resizeDetent` the delta is cut short where the strip goes flush with a viewport edge
    /// (`Strip.resizeDetent`), and a press made *from* that notch takes the delta it asked for. The
    /// ladder is deliberately exempt: a preset is an exact intent, and ½ has to stay ½.
    private static func handleResizeColumn(_ s: inout State, by delta: SizeDelta,
                                           sign: Double) -> [Effect] {
        // The resting offset, to pair with the resting widths `layout` still holds: mid-flight the two
        // describe different strips, and the notch is a fact about the one being left.
        let offset = s.viewport.offset.target
        let detent = s.config.resizeDetent
        let centered = s.config.centerFocusedColumn
        return resizeFocusedColumn(&s) { layout, column, metrics, from in
            let available = metrics.contentArea.width
            let ceiling = Swift.max(available, from)
            let floor = Swift.min(minimumColumnWidth, from)
            var travel = delta.resolved(available: available)
            if detent, let index = layout.columnIndex(withId: column.id),
               let notch = layout.strip(metrics: metrics)
                   .resizeDetent(ofColumn: index, growing: sign > 0, viewportWidth: available,
                                 offset: offset, centered: centered) {
                travel = Swift.min(travel, notch)     // only ever shorter: a detent catches, it never pulls
            }
            let width = Swift.min(Swift.max(from + sign * travel, floor), ceiling)
            // Stored in the unit the user typed: a percentage leaves a proportion, points leave points.
            let intent: PresetSize
            switch delta {
            case .percent where available > 0: intent = .proportion(width / available)
            case .percent, .points:            intent = .fixed(width)
            }
            layout.setWidthOverride(intent, ofColumn: column.id)
        }
    }

    /// Take the focused **window** to the strip's full width, and put it back. The strip's fullscreen,
    /// not macOS's: no native Space, just a column at 100% of the content area with its neighbours
    /// parked at slivers. A window rather than a column, so one with stackmates is expelled into a
    /// column of its own — the branch `move-window` and `consume-or-expel` make — and the `Fullscreen`
    /// record it carries is what puts it back.
    private static func handleFullscreen(_ s: inout State, _ toggle: Toggle) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        guard let metrics = s.metrics(),
              let focused = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: focused) else { return [] }

        let column = s.layout.columns[index]      // a copy; never re-read after a mutation
        // Before anything is written: `fullscreen on` twice must not overwrite the record with the
        // arrangement fullscreen itself created.
        guard toggle.resolved(current: column.isFullscreen) != column.isFullscreen else { return [] }

        return column.isFullscreen
            ? leaveFullscreen(&s, focused, column, metrics)
            : enterFullscreen(&s, focused, column, at: index, metrics)
    }

    /// Fullscreen on. The anchor names the window's *current* column, the one certain to survive an
    /// expel, and is read at `viewportOffset.target` — a press landing mid-scroll remembers where that
    /// scroll is coming to rest.
    private static func enterFullscreen(_ s: inout State, _ focused: WindowId, _ column: ColumnLayout,
                                        at index: Int, _ metrics: LayoutMetrics) -> [Effect] {
        let anchor = Fullscreen.Anchor(
            column: column.id,
            dx: s.layout.strip(metrics: metrics).leftEdge(of: index) - s.viewport.offset.target)

        guard column.windowIds.count > 1,
              let row = column.windowIds.firstIndex(of: focused) else {
            // Alone in its column: nothing to expel, so a pure resize.
            return resizeFocusedColumn(&s) { layout, column, _, _ in
                layout.setFullscreen(Fullscreen(anchor: anchor), ofColumn: column.id)
            }
        }

        // With stackmates, a structural edit — and the growth rides it rather than the width spring,
        // since the popped-out column is born at 100% and never resizes.
        let old = actingSnapshot(s)
        // In place, the column it leaves sliding right, so the anchor does not move under it.
        let edit = s.workspaces.extract(window: focused, toNewColumnAt: index)
        guard edit.moved, let popped = s.layout.columnIndex(ofWindow: focused) else { return [] }
        s.layout.setFullscreen(Fullscreen(stack: .init(column: column.id, row: row), anchor: anchor),
                               ofColumn: s.layout.columns[popped].id)
        return finishStructuralEdit(&s, edit, focused: focused, mover: focused, animatingFrom: old)
    }

    /// Fullscreen off. Each half of the record is applied only if its column is still on the strip;
    /// a half whose column has gone leaves the window where it is, or the strip revealing it the
    /// ordinary way. `ColumnId`s are never re-issued, so a surviving match is that column.
    private static func leaveFullscreen(_ s: inout State, _ focused: WindowId, _ column: ColumnLayout,
                                        _ metrics: LayoutMetrics) -> [Effect] {
        let record = column.fullscreen ?? .plain

        guard let stack = record.stack, s.layout.columnIndex(withId: stack.column) != nil else {
            // Nothing to merge back into: a pure resize down the width stack. The anchor still applies —
            // only this column's width changed, not the strip's shape.
            return resizeFocusedColumn(&s, framedAt: restoredOffset(s, record.anchor, metrics)) {
                layout, column, _, _ in layout.setFullscreen(nil, ofColumn: column.id)
            }
        }

        let old = actingSnapshot(s)
        // Cleared before the merge, so a merge that no-ops still leaves a width the user can act on.
        s.layout.setFullscreen(nil, ofColumn: column.id)
        let edit = s.layout.move(window: focused, toColumn: stack.column, at: stack.row)
        // Read *after* the merge: the strip is a column shorter, so the anchor's left edge has moved.
        return finishStructuralEdit(&s, edit, focused: focused, mover: focused, animatingFrom: old,
                                    framedAt: restoredOffset(s, record.anchor, metrics))
    }

    /// The offset that puts `anchor`'s column back the same distance from the content area's left edge —
    /// or `nil` if that column has gone, which leaves the caller's ordinary reveal in charge. Clamped
    /// here and not by `reassertTruthPlane`, which the animated path never reaches: with what the distance
    /// was measured across now gone it asks to look past the strip's origin, and a scroll aimed there
    /// travels there.
    private static func restoredOffset(_ s: State, _ anchor: Fullscreen.Anchor?,
                                       _ metrics: LayoutMetrics) -> Double? {
        guard let anchor, let i = s.layout.columnIndex(withId: anchor.column) else { return nil }
        return s.layout.clampScrollOffset(s.layout.strip(metrics: metrics).leftEdge(of: i) - anchor.dx,
                                          metrics: metrics)
    }

    /// The shared body of every column resize: read the width being left, let `retarget` write the new
    /// width intent, then animate from one to the other. This animates a second quantity — the column's
    /// resolved width goes under a spring, and the presentation plane re-resolves the strip against it —
    /// and warrants a transition even when the viewport does not move, so the `end == start` guard is
    /// deliberately absent. The reals teleport to their final size behind the cover.
    ///
    /// - Parameter framedAt: an offset to come to rest at instead of the reveal the resize would compute —
    ///   an un-fullscreen whose window never left its column, restoring a remembered viewport.
    /// - Parameter retarget: given the layout, the focused column as it was, the metrics, and its current
    ///   resolved width, records the new intent. Called once, between the two reads.
    private static func resizeFocusedColumn(
        _ s: inout State,
        framedAt: Double? = nil,
        _ retarget: (inout Layout, ColumnLayout, LayoutMetrics, Double) -> Void
    ) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        guard let (monitor, metrics) = s.acting(),
              let focused = s.world.focusedWindow,
              let index = s.layout.columnIndex(ofWindow: focused) else { return [] }

        let column = s.layout.columns[index]
        // Resolved, not raw preset: for a column an app has already widened, the preset is not where
        // the layers are.
        let fromWidth = s.layout.resolvedWidth(of: column, metrics: metrics)

        // Asked *before* the width changes: what is on screen under the geometry we are leaving.
        let start = s.viewport.offset.current
        let departing = s.layout.visibleWindowIds(scrollOffset: start, metrics: metrics)

        retarget(&s.layout, column, metrics, fromWidth)
        // The question, not the answer: `metrics.uncorrected` is what a `SizeCorrection` is keyed on.
        let toWidth = s.layout.resolvedWidth(ofColumn: column.id, metrics: metrics.uncorrected) ?? fromWidth

        // Nothing to look at: a single-preset cycle, two presets resolving alike, or a clamp that left the
        // intent where it was. The stored intent still moved, so a later press acts at once. `framedAt`
        // is skipped with it: a column reaching here at one width is already at 100%, and a content-width
        // column rests flush under both reveal and center, so its anchor is the offset it already has.
        guard !approximatelyEqualScalar(fromWidth, toWidth) else { return reassertTruthPlane(&s) }

        // The user asked again, so ask the app again: limits track what a window is currently showing.
        s.world.forgetCorrections(of: column.windowIds)
        guard let asked = s.metrics() else { return reassertTruthPlane(&s) }

        // A resize scrolls too: a column that just grew may no longer fit where it was.
        let revealed = s.config.centerFocusedColumn
            ? s.layout.scrollOffsetToCenter(window: focused, metrics: asked)
            : s.layout.scrollOffsetToReveal(window: focused, from: start, metrics: asked)
        let end = framedAt ?? revealed ?? start

        let scope = scopeUnion(s, departing,
                               s.layout.sweptWindowIds(from: start, to: end, metrics: asked))

        // No cover to make, or an empty scope: resize at once, on the same final width.
        guard s.motion.isTransitioning(on: monitor)
                || (s.config.transitionMode.covers && !scope.isEmpty) else {
            s.motion.snapViewport(to: end, on: monitor)
            return reassertTruthPlane(&s)
        }

        // Under `snap` the width is left out of `Motion` entirely, and an absent animator resolves to the
        // preset the layout now holds — the finished width, from the cover's first frame.
        if s.config.transitionMode.animates {
            s.motion.animateColumnWidth(column.id, from: fromWidth, to: toWidth,
                                        params: s.config.resizeSpring, on: monitor)
        }
        return driveTransition(&s, on: monitor, to: end, scope: scope)
    }

    /// Two scoped window sets merged and re-sorted into layout order, which is the cover's z-order.
    /// Sorted across the whole set rather than by one strip, so a scope spanning two workspaces keeps
    /// every member — a switch's outgoing set is on a strip `layout` no longer projects — and in
    /// *placement* order, so the strips on screen sit under the parked ones sliding away.
    private static func scopeUnion(_ s: State, _ a: [WindowId], _ b: [WindowId]) -> [WindowId] {
        let wanted = Set(a).union(b)
        return s.workspaces.windowIds(inPlacementOrder: s.monitors.shownWorkspaces)
            .filter { wanted.contains($0) }
    }

    /// Teleport the real windows behind `monitor`'s newly-raised cover, *replacing* that session's
    /// scope-wide landing wait with the windows the pass actually moved. The pass itself is the whole
    /// desktop's — every display writes what its own phase entitles it to — but the wait it replaces is
    /// this one session's, and only scoped moves are waited on, park→park motion being invisible.
    private static func teleportBehindCover(_ s: inout State, on monitor: MonitorId) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        return placeTruthPlane(&s, replacingFor: monitor)
    }

    /// Blit one `setLayerFrame` per reconstruction layer on `monitor` this frame — that cover's stand-ins
    /// sliding to their *natural* (un-parked) positions at its current scroll offset, so a window
    /// scrolling off-view glides off the screen edge here while its real counterpart sits at a corner
    /// sliver. A pure read, in z-order, over the strips this display holds. Each frame is one derived
    /// rect plus three independent animated quantities: scroll offset, column widths (resize only),
    /// displacement (structural edit).
    private static func emitLayerFrames(_ s: State, on monitor: MonitorId) -> [Effect] {
        guard let metrics = s.metrics(of: monitor), let shown = s.monitors.shown(on: monitor),
              let session = s.motion.transition(of: monitor) else { return [] }
        var frames = s.workspaces.naturalFrames(shown: shown, among: s.monitors.owned(of: monitor),
                                                scrollOffset: s.motion.offset(of: monitor).current,
                                                metrics: metrics,
                                                widths: s.motion.currentColumnWidths)
        // A window handed to another display is still this cover's to draw: it is travelling *off* this
        // screen, and nothing here can say where to. Asked of the display that holds it now, in the same
        // global space and against the same shared displacement, so both covers draw the identical
        // journey and it reads as one window crossing rather than two cutting.
        for id in session.carried where frames[id] == nil {
            guard let home = s.monitors.monitor(of: s.workspaces.workspace(of: id) ?? shown),
                  let frame = naturalFrame(s, of: id, on: home,
                                           widths: s.motion.currentColumnWidths) else { continue }
            frames[id] = frame
        }
        return session.bindings.compactMap { binding in
            frames[binding.window].map {
                .setLayerFrame(binding.layer, $0.displaced(by: s.motion.displacement(of: binding.window)))
            }
        }
    }

    /// Cross-fade `monitor`'s cover out iff its transition is fully done — cover raised, every scoped AX
    /// set landed, every animator *it* is waiting on settled. Snaps that viewport to its target so
    /// resting state matches the reveal.
    private static func maybeCloseTransition(_ s: inout State, on monitor: MonitorId,
                                             holding contents: MonitorContents) -> [Effect] {
        guard s.motion.isReadyToClose(on: monitor, holding: contents) else { return [] }
        s.motion.closeTransition(on: monitor)
        return [.endTransition(monitor)]
    }

    /// Try to close every open cover — what an untagged `axLanded` owes, since the window it names may
    /// have been the last one any number of sessions were waiting on.
    private static func closeSettledTransitions(_ s: inout State) -> [Effect] {
        var effects: [Effect] = []
        for monitor in s.motion.transitioningMonitors {
            effects += maybeCloseTransition(&s, on: monitor, holding: s.contents(of: monitor))
        }
        return effects
    }

    /// The window on the focused strip a decision falls back to when focus is on nothing that has a
    /// column: whatever holds focus if it has one, else the last strip window that did.
    ///
    /// **Focus on nothing is a legitimate resting state, not a gap** — an empty strip focuses nothing,
    /// an unmanaged panel taking a keystroke focuses nothing, and every verb in the reducer reads that
    /// `nil` correctly and declines to act. What is *not* legitimate is a decision that needs a **place
    /// on the strip** being defeated by it, and two of them are: an arrival needs a column to open beside,
    /// and a refused focus report needs somewhere to put focus back. Both meet the same race — an app
    /// focuses a window before emira adopts it, so `focusChanged(nil)` lands just ahead of the event that
    /// wanted the answer. Without the fallback every ⌘N appends at the far end of the strip, and every
    /// report arriving behind a clear is admitted whatever `[focus] system-events` says.
    ///
    /// Constrained to the focused strip in both directions, because `lastStripFocus` outlives its window
    /// being moved to another workspace: an anchor over there is not a place this workspace can act, and
    /// restoring focus to it would switch the desktop — the very thing the refusal exists to prevent.
    private static func stripAnchor(_ s: State) -> WindowId? {
        for candidate in [s.world.focusedWindow, s.world.lastStripFocus] {
            if let candidate, s.layout.columnIndex(ofWindow: candidate) != nil { return candidate }
        }
        return nil
    }

    /// The strip's geometry as it stands right now, reconciled first — what an arrival is about to
    /// change. Empty with no display known, which is also the caller's signal that nothing can be placed.
    private static func strandedGeometry(_ s: inout State) -> [StructuralSnapshot] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        return actingSnapshot(s)
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
                                      old: [StructuralSnapshot], width: PresetSize? = nil,
                                      keepingWidth: Bool = false,
                                      announcingFocus: Bool = true) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown, insertingAfter: anchor)
        let announce: [Effect] = announcingFocus ? [.focus(id)] : []
        // A window that didn't join a column has nothing to animate; ordinary placement still runs.
        guard s.layout.columnIndex(ofWindow: id) != nil else { return reassertTruthPlane(&s) + announce }
        // Before the geometry below is read, so an adopted window travels to its place on the strip
        // rather than also resizing on the way.
        seedWidth(&s, id, to: width, keepingExisting: keepingWidth)

        let opened = s.world.windows[id]?.frame
        let seeded = opened.map { frame in old.map { $0.including(id, at: frame) } } ?? old
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
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        seedWidth(&s, snapshot.id, to: width, keepingExisting: snapshot.wasAlreadyOpen)
        s.move(window: snapshot.id, to: destination,
               insertingAfter: s.workspaces[lastFocusOf: destination])

        guard !snapshot.wasAlreadyOpen else { return reassertTruthPlane(&s) }
        // Focus is set *inside* the switch, never before it: `switchWorkspace` reads the current focus
        // to record what the outgoing workspace should return to, and a window on another strip reads
        // as nothing and wipes it.
        return switchWorkspace(&s, to: destination, focusing: snapshot.id, animatingFrom: [])
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
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        // All three read *before* the removal: the column's id, to tell afterwards whether it died; its
        // index, so focus can land where the window was; and the geometry we are leaving.
        let index = s.layout.columnIndex(ofWindow: id)
        let column = index.map { s.layout.columns[$0].id }
        let old = actingSnapshot(s)

        leave(&s)
        // The departed window's own lag is measured against a layout that no longer places it.
        s.motion.removeWindowAnimator(id)
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)

        // Focus may have gone with it. Choose the successor *before* framing the strip, since that is
        // what the viewport aims at, and take the neighbour — the front of the strip would scroll home.
        var refocus: [Effect] = []
        if s.world.focusedWindow == nil, let next = successor(s.layout, column: column, at: index) {
            s.world.setFocus(next)
            refocus = [.focus(next)]
        }

        guard !old.isEmpty, let column, let focused = s.world.focusedWindow else {
            return reassertTruthPlane(&s) + refocus
        }
        let destroyed = s.layout.columnIndex(withId: column) == nil ? column : nil
        let edit = LayoutEdit(moved: true, destroyedColumn: destroyed)
        return finishStructuralEdit(&s, edit, focused: focused, mover: nil,
                                    animatingFrom: old) + refocus
    }

    // Windows that refuse the size we ask for

    /// Fold a tiled landing that came back a different size than we asked for: record the truth, remember
    /// the answer, re-place. The guards below decline to learn from a stale report and from position-only
    /// drift; staleness is compared on *size* alone, since a resting display writes at its viewport's
    /// `current` and a covered one at its `target`. Keying the record on the question makes it
    /// self-invalidating.
    ///
    /// **Everything here is asked of the display holding the window, not the acting one**: a window that
    /// answered back is placed by the screen it is on, whichever screen the user is working from.
    private static func handlePlacementCorrected(_ s: inout State, _ id: WindowId,
                                                 requested: Rect, actual: Rect) -> [Effect] {
        s.world.updateFrame(id, to: actual)          // truth first, exactly as `windowFrameChanged` does

        // Whichever workspace holds the window, not the focused one: a parked window elsewhere is still
        // placed by us, and ignoring its refusal would re-set it on every event, forever.
        guard let (name, column) = s.workspaces.column(containing: id),
              let monitor = s.monitors.monitor(of: name), let metrics = s.metrics(of: monitor),
              let live = s.workspaces.targetFrames(s.placements())[id],
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
        guard let corrected = s.metrics(of: monitor) else { return [] }
        let after = s.workspaces[name].resolvedWidth(of: column, metrics: corrected)
        springHeightChange(&s, on: name, column, from: stackedBefore, to: corrected, monitor: monitor)

        // Under a cover every layer frame is re-derived from the strip's geometry each tick, so a column
        // that changes width between two frames jumps. Put the change under the resize spring instead.
        if s.motion.isTransitioning(on: monitor), !approximatelyEqualScalar(before, after) {
            s.motion.animateColumnWidth(column.id, from: before, to: after,
                                        params: s.config.resizeSpring, on: monitor)
            // Re-aim too: scroll targets derive from the column widths this just changed, so a session
            // keeping its old destination comes to rest past the strip's end, showing phantom desktop.
            return reaimViewport(&s, on: monitor, corrected)
        }

        return reassertTruthPlane(&s)
    }

    // Windows that refuse the nub we park them behind

    /// Fold a park that landed showing more of its window than the slot asked for: record the truth,
    /// remember the chrome, re-place. macOS honours a park slot only as far as the app will go, and a
    /// window whose title bar carries a toolbar keeps more of itself on screen than a bare 40 pt nub —
    /// so without this the same slot is re-asked on every placement pass for the life of the window.
    ///
    /// What is learned is the **chrome**, not the frame: a floor is a fact about the window, so it
    /// survives the ordinal run renumbering, which happens whenever a column opens or closes. The size
    /// half of the answer is still discarded (`Effect.park`) — an app refuses a resize at a sliver that
    /// it accepts back in view, and recording that would freeze the column at its parked width.
    private static func handleParkCorrected(_ s: inout State, _ id: WindowId,
                                            requested: Rect, actual: Rect) -> [Effect] {
        s.world.updateFrame(id, to: actual)          // truth first, exactly as `windowFrameChanged` does

        // An answer about the nub, or a window that isn't at our corner at all? A park writes the slot's
        // left edge as well, so an app that also moved itself horizontally is refusing to park rather
        // than stating a floor, and has nothing to teach a lot that only allocates chrome.
        guard let name = s.workspaces.workspace(of: id),
              let monitor = s.monitors.monitor(of: name), let metrics = s.metrics(of: monitor),
              approximatelyEqualScalar(actual.minX, requested.minX),
              actual.minY < requested.minY - 0.5
        else { return [] }

        let chrome = metrics.workingArea.maxY - actual.minY
        // Nothing new: the floor is already recorded and the slot it produced was refused anyway. Placing
        // again would ask the identical question, so stop here rather than trade writes with the app.
        if let known = s.world.parkFloors[id], approximatelyEqualScalar(known, chrome) { return [] }
        s.world.noteParkFloor(id, chrome: chrome)
        return reassertTruthPlane(&s)
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
                                           to corrected: LayoutMetrics, monitor: MonitorId) {
        guard s.motion.isTransitioning(on: monitor) else { return }
        let stackedAfter = s.workspaces[name].naturalFrames(scrollOffset: 0, metrics: corrected)
        for window in column.windowIds {
            guard let was = stackedBefore[window], let now = stackedAfter[window] else { continue }
            let delta = Rect(x: 0, y: was.minY - now.minY, width: 0, height: was.height - now.height)
            guard delta != .zero else { continue }
            s.motion.displaceWindow(window, by: delta, params: s.config.resizeSpring, on: monitor)
        }
    }

    /// Re-derive where `monitor`'s open transition is travelling to, after something changed the geometry
    /// its destination came from — `resizeFocusedColumn`'s opening arithmetic, applied again when the
    /// answer changes what the resize meant.
    ///
    /// The strip is that display's own, and framing on the focused window is only meaningful while focus
    /// is on it — a correction arriving for a window on another screen has no column here to frame on,
    /// so the destination stands and only the truth plane is re-asserted against it.
    private static func reaimViewport(_ s: inout State, on monitor: MonitorId,
                                      _ metrics: LayoutMetrics) -> [Effect] {
        guard let shown = s.monitors.shown(on: monitor) else { return reassertTruthPlane(&s) }
        let strip = s.workspaces[shown]
        guard let focused = s.world.focusedWindow,
              strip.columnIndex(ofWindow: focused) != nil else { return reassertTruthPlane(&s) }
        let start = s.motion.offset(of: monitor).current
        let end = (s.config.centerFocusedColumn
            ? strip.scrollOffsetToCenter(window: focused, metrics: metrics)
            : strip.scrollOffsetToReveal(window: focused, from: start, metrics: metrics))
            ?? s.motion.offset(of: monitor).target
        return driveTransition(&s, on: monitor, to: end,
                               scope: strip.sweptWindowIds(from: start, to: end, metrics: metrics))
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

    /// Re-place every managed window the truth plane currently answers for — the one entry point, since
    /// a re-place is asked for by events that arrive on their own schedule.
    ///
    /// The four phases still decide everything, but **per display** rather than for the desktop: an idle
    /// screen's windows are written where its viewport rests, a covered one's at the scroll's end its
    /// cover is travelling to, and a screen mid-capture or mid-raise writes nothing at all, because
    /// there is nothing on its glass to hide a write and its own teleport will read whatever this would
    /// have written. `placements()` carries the first two; `writeTruthPlane` holds back the third.
    private static func reassertTruthPlane(_ s: inout State) -> [Effect] {
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds, onto: s.monitors.shown)
        clampRestingViewports(&s)
        return placeTruthPlane(&s)
    }

    /// Bring every **resting** viewport back inside a strip that may have shrunk — closing a column left
    /// of the viewport, minimizing one, narrowing the presets. A display mid-transition is left alone:
    /// its offset belongs to the spring, and `reassertTruthPlane` is not what tears a session down.
    ///
    /// Not when centering: a column in the middle at the strip's end *means* showing space past it.
    private static func clampRestingViewports(_ s: inout State) {
        guard !s.config.centerFocusedColumn else { return }
        for id in s.monitors.ids where !s.motion.isTransitioning(on: id) {
            guard let metrics = s.metrics(of: id), let shown = s.monitors.shown(on: id) else { continue }
            let live = s.motion.offset(of: id).current
            let clamped = s.workspaces[shown].clampScrollOffset(live, metrics: metrics)
            if !approximatelyEqualScalar(clamped, live) { s.motion.snapViewport(to: clamped, on: id) }
        }
    }

    /// One placement pass over the whole desktop, and every open landing wait re-armed from what it
    /// moved. A window a covered session scoped is waited on wherever the pass moved it, which is what
    /// keeps the close gate honest when two covers are up over one window.
    ///
    /// - Parameter replacingFor: the display whose cover has just reached the glass, whose scope-wide
    ///   wait this pass *replaces*. Every other wait only grows — earlier sets may be in flight, and a
    ///   re-teleport that moves nothing must not free them.
    private static func placeTruthPlane(_ s: inout State, replacingFor: MonitorId? = nil) -> [Effect] {
        let write = writeTruthPlane(&s)
        for monitor in s.motion.coveredMonitors {
            guard let scope = s.motion.transition(of: monitor)?.windows else { continue }
            let scoped = Set(scope)
            s.motion.armLandings(write.moved.filter(scoped.contains),
                                 replacing: monitor == replacingFor, on: monitor)
        }
        return write.effects
    }

    /// Write the truth plane: the `setFrame`/`park` sets that bring every managed window to the frame it
    /// has under `State.placements()`, and the record of which of them that put on the glass. A window
    /// whose column overlaps its display's viewport is `setFrame`d to its tiled frame; one scrolled
    /// off-view is `park`ed at its sliver slot in its own display's lot. Only windows that need to move
    /// are emitted, diffed within a sub-pixel tolerance, and they are what `moved` returns. `World`
    /// frames are updated optimistically — a failure comes back as `axFailed` — which keeps a repeated
    /// idle event from re-emitting forever.
    ///
    /// **D8's gate lives here**: a real window may move only when the cover is up on every display it is
    /// visible on before *or* after the move. A workspace lives on one display, so that is the display
    /// holding it — and a display still capturing or raising is *held*, its windows skipped entirely,
    /// exactly as the whole desktop used to be.
    ///
    /// The reducer's **only** `setFrame`/`park`, which is what entitles it to call `notePlaced` — a second
    /// place that moved a real window would make `World.placedOnScreen` a lie by omission. The record is
    /// the `setFrame`-vs-`park` switch itself rather than the offset behind it, because a reader asking
    /// "can the user see this window" would otherwise have to re-derive that switch against a *live*
    /// layout, and the two inputs come apart: a structural edit in a capture head restructures the strip
    /// with no real window moving. A held display contributes what it was already showing, so the record
    /// stays the whole desktop's while the writes are only what the gate allows.
    private static func writeTruthPlane(_ s: inout State) -> (effects: [Effect], moved: [WindowId]) {
        let placements = s.placements()
        let frames = s.workspaces.targetFrames(placements)
        let questions = s.workspaces.uncorrectedSizes(placements)

        var effects: [Effect] = []
        var moved: [WindowId] = []
        var visible: Set<WindowId> = []
        for placement in placements {
            let strip = s.workspaces[placement.name]
            let owner = s.monitors.monitor(of: placement.name)
            switch s.motion.phase(of: owner) {
            case .capturing, .raising:
                // Nothing has moved on this display and nothing may, so its share of the on-screen
                // record is the one the last completed pass made.
                visible.formUnion(strip.allWindowIds.filter(s.world.isOnScreen))
                continue
            case .idle, .covered:
                break
            }
            if let offset = placement.scrollOffset {
                visible.formUnion(strip.visibleWindowIds(scrollOffset: offset,
                                                         metrics: placement.metrics))
            }
            for id in strip.allWindowIds {
                guard let target = frames[id] else { continue }
                if isAlreadyPlaced(s.world, id, at: target, question: questions[id]) { continue }
                effects.append(visible.contains(id) ? .setFrame(id, target) : .park(id, target))
                s.world.updateFrame(id, to: target)    // optimistic: AX will land here (or axFailed)
                moved.append(id)
            }
        }
        // Every managed window was just answered for, including the ones already standing correctly, so
        // this describes the whole desktop rather than the subset that needed a set.
        s.world.notePlaced(onScreen: visible)
        return (effects, moved)
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
