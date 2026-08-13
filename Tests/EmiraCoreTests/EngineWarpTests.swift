import Foundation
import Testing
@testable import EmiraCore

// The pointer following focus: which focus changes owe the pointer a visit, and *when* the visit is
// paid. The timing is the whole of it — under a cover the reals have already teleported, so the right
// target exists immediately while the user is still watching layers travel toward it.
//
// So the suite needs a clock: `trace` drives one transition frame by frame and reports the tick each
// landmark fell on, which is the only way to state a rule whose whole content is "before the end".
//
// The platform facts stay recorded in the change file rather than asserted here: that a warp posts no
// event, and that `CGWarpMouseCursorPosition` takes top-left global coordinates and works from a
// background process, are facts about the window server no unit test can witness.

@Suite struct EngineWarpTests {

    /// Full-width columns, so every focus across columns genuinely scrolls and opens a session.
    static let following = Config(widthPresets: PresetCycle([.proportion(1.0)]),
                                  mouseFollowsFocus: .lazy)

    /// The same, snapping — for the "no session open" half of the one rule.
    static let followingSnapped = Config(widthPresets: PresetCycle([.proportion(1.0)]),
                                         transitionMode: .off, mouseFollowsFocus: .lazy)

    static func warps(_ effects: [Effect]) -> [Rect] {
        effects.compactMap { if case .warpPointer(let rect) = $0 { rect } else { nil } }
    }

    /// What one transition did, in ticks. `nil` for a landmark that never came.
    struct Trace {
        var warps: [Rect] = []
        /// The tick the visit was paid on, counted from the command.
        var warpTick: Int?
        /// The tick the session closed on — the instant the old rule paid at.
        var closeTick: Int?
        /// Every `setLayerFrame` emitted in the same batch as the warp: where the user could see each
        /// stand-in at the moment the cursor moved.
        var standIns: [LayerId: Rect] = [:]
        /// The state the visit was paid into — the session is still open in it, so it is the only one
        /// that can say which layer was standing in for which window.
        var atWarp = State()
        /// The state once everything has come to rest.
        var settled = State()
    }

    /// Drive one transition to its close, frame by frame, recording when things happened. Answers every
    /// capture, reports the cover on screen, lands every real, then ticks — `EngineFix.drive` with a
    /// clock in it, and bounded so a non-converging spring fails rather than hangs.
    static func trace(_ start: State, _ opening: [Effect]) -> Trace {
        var t = Trace()
        var s = start
        var queue = opening
        var ticks = 0

        func feed(_ event: Event) {
            let wasOpen = s.motion.isTransitioning
            let (next, fx) = Engine.reduce(s, event)
            s = next
            for case .warpPointer(let rect) in fx {
                t.warps.append(rect)
                guard t.warpTick == nil else { continue }
                t.warpTick = ticks
                t.atWarp = s
                for case .setLayerFrame(let layer, let rect) in fx { t.standIns[layer] = rect }
            }
            if wasOpen, !s.motion.isTransitioning, t.closeTick == nil { t.closeTick = ticks }
            queue += fx
        }

        for _ in 0..<4000 {
            var feedback: [Event] = []
            for effect in queue {
                switch effect {
                case .capture(_, let w, _): feedback.append(.captureReady(w))
                case .beginTransition(let m, _): feedback.append(.coverOnScreen(m))
                case .setFrame(let w, _), .park(let w, _): feedback.append(.axLanded(w))
                default: continue
                }
            }
            queue = []
            if feedback.isEmpty {
                guard s.motion.isTransitioning else { break }
                feedback = [.tick(dt: 1.0 / 120)]
                ticks += 1
            }
            for event in feedback { feed(event) }
        }
        t.settled = s
        return t
    }

    // With no session open the visit is paid at once

    @Test func aFocusWithNoTransitionWarpsImmediately() {
        let s = EngineFix.world(3, config: Self.followingSnapped)
        let (next, effects) = Engine.reduce(s, .command(.focus(.left)))

        let rects = Self.warps(effects)
        #expect(rects.count == 1)
        #expect(next.pointer.pendingWarp == nil)
        // Into the window that now has focus, and inside the working area.
        let focused = try? #require(next.world.focusedWindow)
        #expect(rects.first == next.world.windows[focused ?? WindowId(0)]?.frame
            .intersection(next.metrics()!.workingArea))
    }

    /// Last, not first: the pointer arrives once the batch that moves the desktop has been issued.
    @Test func theWarpComesAfterTheRestOfTheBatch() {
        let s = EngineFix.world(3, config: Self.followingSnapped)
        let (_, effects) = Engine.reduce(s, .command(.focus(.left)))
        #expect(effects.count > 1)
        if case .warpPointer = effects.last {} else {
            Issue.record("the warp should be the last effect, not \(String(describing: effects.last))")
        }
    }

    // With a session open the visit is owed until the reveal reaches it

    /// The whole rule, end to end: one visit, booked by the command, paid **while the window is still
    /// travelling**, to the frame that window is going to come to rest at.
    @Test func aFocusMidTransitionIsPaidBeforeTheSessionCloses() throws {
        let s = EngineFix.world(3, config: Self.following)
        let (next, effects) = Engine.reduce(s, .command(.focus(.left)))

        #expect(Self.warps(effects).isEmpty, "a cursor arriving before its window is the flash a cover prevents")
        let owed = try #require(next.pointer.pendingWarp)
        #expect(next.motion.isTransitioning)

        let t = Self.trace(next, effects)
        #expect(t.warps.count == 1, "exactly one visit")
        #expect(t.settled.pointer.pendingWarp == nil)
        #expect(!t.settled.motion.isTransitioning)

        let warpTick = try #require(t.warpTick, "the visit was never paid")
        let closeTick = try #require(t.closeTick)
        #expect(warpTick < closeTick, "the pointer arrives before the transition ends, not with it")
        // Not a hair before it: the point is a lead the eye can use. The spring's tail is most of the
        // session, so half a window of travel left over lands the visit inside the first third of it.
        #expect(warpTick * 3 < closeTick,
                "paid on tick \(warpTick) of \(closeTick) — too late to read as anticipation")

        // Where it was sent is where the window ends up: a prediction, not a snapshot of a window
        // mid-flight. This is the half the lead could quietly break.
        let resting = try #require(t.settled.world.windows[owed]?.frame)
        let metrics = try #require(t.settled.metrics())
        #expect(t.warps.first == resting.intersection(metrics.workingArea))
    }

    /// **The gate itself**: at the instant the cursor moves, the pixels under it belong to the window it
    /// was sent to. Asked of the stand-in the same batch blits — the arriving window's own layer — which
    /// is what the user is looking at while the cover is up, and the reason the lead is safe at all.
    @Test func theCursorLandsOnTheArrivingWindowsStandIn() throws {
        let s = EngineFix.world(3, config: Self.following)
        let (next, effects) = Engine.reduce(s, .command(.focus(.left)))
        let owed = try #require(next.pointer.pendingWarp)

        let t = Self.trace(next, effects)
        let landing = try #require(t.warps.first).center
        let layer = try #require(t.atWarp.motion.layerIds(for: owed).first)
        let standIn = try #require(t.standIns[layer], "the arriving window blitted no frame that tick")

        #expect(standIn.contains(landing),
                "the cursor landed at \(landing) with the window's stand-in at \(standIn)")
        // …and it is genuinely still travelling: a stand-in already at rest would make the test above
        // true for the old close-gated timing too.
        #expect(!EngineFix.approx(standIn, try #require(t.warps.first), tol: 1),
                "the window should still have ground to cover when the cursor arrives")
    }

    /// Nothing is paid before the cover is up. The reals have not teleported yet, so the truth plane
    /// still describes where the window *was* — there is no destination to have arrived at.
    @Test func theVisitIsNotPaidBeforeTheCoverIsUp() throws {
        let s = EngineFix.world(3, config: Self.following)
        var (next, effects) = Engine.reduce(s, .command(.focus(.left)))
        let owed = try #require(next.pointer.pendingWarp)

        // Every capture in — the session is `.raising`, one event short of a cover on the glass.
        for case .capture(_, let w, _) in effects {
            let (n, fx) = Engine.reduce(next, .captureReady(w))
            next = n
            effects = fx
        }
        #expect(next.motion.phase(of: MonitorId(1)) == .raising)
        #expect(Self.warps(effects).isEmpty)

        let (ticked, out) = Engine.reduce(next, .tick(dt: 1.0 / 120))
        #expect(Self.warps(out).isEmpty, "a cursor on a photograph of the old desktop")
        #expect(ticked.pointer.pendingWarp == owed, "and the visit is still owed")
    }

    /// **The cover that holds a visit is the one over the window the pointer is going to.** A cover on
    /// the other screen answers about neither the destination nor what is drawn under it, and holding
    /// the visit for it would leave the cursor behind for a reveal it is not part of.
    @Test func aCoverOnAnotherDisplayDoesNotHoldTheVisit() throws {
        var s = MonitorSessionTests.desktop(2, config: Self.following)
        let left = try #require(s.monitors.shown(on: MonitorId(1)))
        // On screen there, since a visit to a parked window is dropped for its own reason.
        let owed = try #require(s.workspaces[left].allWindowIds.first(where: s.world.placedOnScreen.contains))
        #expect(s.motion.phase(of: MonitorId(1)) == .idle)

        // A session on the second display only, opened where a cross-display edit would leave one.
        s.motion.openTransition(scope: [owed], on: MonitorId(2))
        #expect(s.motion.isTransitioning)

        s.pointer.pendingWarp = owed
        let (next, effects) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(Self.warps(effects).count == 1, "the window it is going to is not under a cover")
        #expect(next.pointer.pendingWarp == nil)
    }

    /// Newest wins — the resolution `FocusIntent` and every retargeted animator already use. A second
    /// focus mid-scroll means the pointer was always going to the second window.
    @Test func aSecondFocusMidTransitionRetargetsTheVisit() {
        let s = EngineFix.world(3, config: Self.following)
        let (first, _) = Engine.reduce(s, .command(.focus(.left)))
        let owed = first.pointer.pendingWarp

        let (second, effects) = Engine.reduce(first, .command(.focus(.left)))
        #expect(Self.warps(effects).isEmpty)
        #expect(second.pointer.pendingWarp != nil)
        #expect(second.pointer.pendingWarp != owed, "the visit should follow the newest focus")
    }

    /// The hold timeout closes the session regardless, which is exactly the case the single rule —
    /// "owed, and no session open" — has to cover without naming it.
    @Test func aTimedOutTransitionStillPaysTheVisit() {
        let s = EngineFix.world(3, config: Self.following)
        let (next, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(next.pointer.pendingWarp != nil)

        let (closed, effects) = Engine.reduce(next, .holdTimeout(MonitorId(1)))
        #expect(Self.warps(effects).count == 1)
        #expect(closed.pointer.pendingWarp == nil)
    }

    // What is never visited

    /// A window that has left the strip while the cover was up is not one to send the pointer to, and
    /// nothing retries: the visit is dropped whether or not it produced an effect.
    @Test func aWindowThatWentAwayIsNotVisited() {
        let s = EngineFix.world(3, config: Self.following)
        let (next, _) = Engine.reduce(s, .command(.focus(.left)))
        let owed = next.pointer.pendingWarp

        let (gone, effects) = Engine.reduce(next, .windowDestroyed(owed ?? WindowId(0)))
        #expect(Self.warps(effects).isEmpty)
        #expect(gone.pointer.pendingWarp == nil || gone.pointer.pendingWarp != owed)
    }

    /// Minimized is off the screen for a reason that has nothing to do with the strip — the same
    /// `isOnScreen` predicate `[focus] system-events = on-screen` judges a report against. A visit owed
    /// to a window that has since gone to the Dock is dropped rather than paid or retried.
    @Test func aWindowThatWentToTheDockIsNotVisited() throws {
        var s = EngineFix.world(2, config: Self.followingSnapped)
        s = EngineFix.settle(Engine.reduce(s, .windowMinimized(WindowId(1))).0)
        #expect(s.world.windows[WindowId(1)]?.isMinimized == true)

        s.pointer.pendingWarp = WindowId(1)
        let (next, effects) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(Self.warps(effects).isEmpty)
        #expect(next.pointer.pendingWarp == nil)
    }

    /// A parked column is somewhere else on the strip and the pointer has no business out there. The
    /// answer is `World.placedOnScreen` — what the last placement pass decided — rather than a frame
    /// re-derived against a viewport that describes a destination rather than a position.
    @Test func aParkedWindowIsNotVisited() throws {
        var s = EngineFix.world(3, config: Self.followingSnapped)
        let parked = try #require(s.world.stripWindowIds.first { !s.world.placedOnScreen.contains($0) })

        s.pointer.pendingWarp = parked
        let (next, effects) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(Self.warps(effects).isEmpty)
        #expect(next.pointer.pendingWarp == nil)
    }

    /// …and a window the same pass *did* put on the glass is visited, which is what makes the test
    /// above about the predicate rather than about the tick.
    @Test func anOnScreenWindowIsVisited() throws {
        var s = EngineFix.world(3, config: Self.followingSnapped)
        let onScreen = try #require(s.world.placedOnScreen.sorted().first)

        s.pointer.pendingWarp = onScreen
        let (next, effects) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(Self.warps(effects).count == 1)
        #expect(next.pointer.pendingWarp == nil)
    }

    /// A column only half revealed at the viewport's edge takes the pointer to the part of itself the
    /// user can actually see — otherwise the centre of a straddling window is off the screen, and
    /// macOS would land the cursor at the edge with no relation to the window that asked for it.
    @Test func aStraddlingWindowIsVisitedWhereItCanBeSeen() throws {
        // Three ½-width columns in a 1000-wide viewport, centred on the *middle* one: the outer two
        // hang over the edges by 250 points each.
        var s = EngineFix.world(3, config: Config(widthPresets: PresetCycle([.proportion(0.5)]),
                                                  transitionMode: .off, mouseFollowsFocus: .lazy))
        s = EngineFix.settle(Engine.reduce(s, .command(.focus(.left))).0)
        s = EngineFix.settle(Engine.reduce(s, .command(.centerColumn)).0)
        let metrics = try #require(s.metrics())
        let straddler = try #require(s.world.placedOnScreen.sorted().first {
            let frame = s.world.windows[$0]?.frame
            return frame.map { $0.minX < metrics.workingArea.minX } ?? false
        })

        s.pointer.pendingWarp = straddler
        let (_, effects) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        let rect = try #require(Self.warps(effects).first)
        #expect(rect.minX == metrics.workingArea.minX)
        #expect(metrics.workingArea.contains(rect.center))
    }

    // The ladder

    /// **The rung is not on the effect.** Every one of them emits the identical warp — the difference
    /// is whether a pointer already inside the rect is centred anyway, and that is a question only the
    /// shell can ask, so it reads `recentres` off the config the way the compositor reads
    /// `[animation] window`. Both halves are pinned here: the mapping, and that the stream doesn't move.
    @Test func everyRungEmitsTheSameWarpAndDiffersOnlyInRecentres() {
        #expect(MouseFollowsFocus.off.recentres == false)
        #expect(MouseFollowsFocus.lazy.recentres == false)
        #expect(MouseFollowsFocus.exceptHover.recentres == true)
        #expect(MouseFollowsFocus.force.recentres == true)

        var emitted: [[Effect]] = []
        for rung in [MouseFollowsFocus.lazy, .exceptHover, .force] {
            var config = Self.followingSnapped
            config.mouseFollowsFocus = rung
            let s = EngineFix.world(3, config: config)
            emitted.append(Engine.reduce(s, .command(.focus(.left))).1)
        }
        #expect(Self.warps(emitted[0]).count == 1)
        #expect(emitted.dropFirst().allSatisfy { $0 == emitted[0] })
    }

    /// **The one source it removes.** Under `force` a hover yanks the cursor the user has their hand on
    /// toward a centre they did not aim at — and the window under it is already the right one, so the
    /// recentring is all the warp can add.
    @Test func exceptHoverLeavesAHoveredFocusAlone() throws {
        var config = Self.followingSnapped
        config.mouseFollowsFocus = .exceptHover
        config.focusFollowsMouse = true
        var s = EngineFix.world(3, config: config)
        let target = try #require(s.world.stripWindowIds.first)
        s = EngineFix.settle(Engine.reduce(s, .command(.focus(.right))).0)

        let (next, effects) = Engine.reduce(s, .pointerEntered(target))
        #expect(next.world.focusedWindow == target, "the hover still moves focus")
        #expect(Self.warps(effects).isEmpty)
        #expect(next.pointer.pendingWarp == nil)
    }

    /// …and `force` does take the pointer along, which is what makes the test above about the rung
    /// rather than about hover being a special case in the post-pass.
    @Test func forceFollowsAHoveredFocusToo() throws {
        var config = Self.followingSnapped
        config.mouseFollowsFocus = .force
        config.focusFollowsMouse = true
        var s = EngineFix.world(3, config: config)
        let target = try #require(s.world.stripWindowIds.first)
        s = EngineFix.settle(Engine.reduce(s, .command(.focus(.right))).0)

        let (_, effects) = Engine.reduce(s, .pointerEntered(target))
        #expect(Self.warps(effects).count == 1)
    }

    /// **Only the pointer's own focus is removed, not every focus emira did not command.** A Cmd-Tab
    /// or a Dock click is a focus the hand was not already on, so the pointer follows it.
    @Test func exceptHoverStillFollowsASystemFocus() {
        var config = Self.followingSnapped
        config.mouseFollowsFocus = .exceptHover
        let s = EngineFix.world(3, config: config)
        let target = s.world.stripWindowIds.first { $0 != s.world.focusedWindow }

        let (next, effects) = Engine.reduce(s, .focusChanged(target, origin: .system))
        #expect(next.world.focusedWindow == target)
        #expect(Self.warps(effects).count == 1)
    }

    /// A window opening takes focus, so it takes the pointer — the same rule, and one the hand is not
    /// already on either.
    @Test func exceptHoverStillFollowsAnArrivingWindow() {
        var config = Self.followingSnapped
        config.mouseFollowsFocus = .exceptHover
        let s = EngineFix.world(3, config: config)

        let (next, effects) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(9)))
        #expect(next.world.focusedWindow == WindowId(9))
        #expect(Self.warps(effects).count == 1)
    }

    /// A declined focus **cancels** the visit an earlier one booked rather than leaving it standing:
    /// paying it would send the pointer to a window that no longer has focus. Reachable in the few ms
    /// between a session opening and its cover going up — the one interval in which the shell still
    /// dispatches a crossing into an open transition.
    @Test func aHoveredFocusCancelsAVisitAlreadyOwed() throws {
        var config = Self.following
        config.mouseFollowsFocus = .exceptHover
        config.focusFollowsMouse = true
        let s = EngineFix.world(3, config: config)

        let (commanded, _) = Engine.reduce(s, .command(.focus(.left)))
        let owed = try #require(commanded.pointer.pendingWarp)
        #expect(commanded.motion.isTransitioning)

        let hovered = try #require(s.world.stripWindowIds.first { $0 != owed })
        let (next, effects) = Engine.reduce(commanded, .pointerEntered(hovered))
        #expect(next.world.focusedWindow == hovered)
        #expect(Self.warps(effects).isEmpty)
        #expect(next.pointer.pendingWarp == nil,
                "the visit to the window focus has left is not still owed")
    }

    /// `off` owes nothing at all — the gate is on the rung, not on the effect.
    @Test func offOwesNoVisit() {
        var config = Self.followingSnapped
        config.mouseFollowsFocus = .off
        let s = EngineFix.world(3, config: config)
        let (next, effects) = Engine.reduce(s, .command(.focus(.left)))
        #expect(Self.warps(effects).isEmpty)
        #expect(next.pointer.pendingWarp == nil)
    }

    /// …and it cancels a visit already standing, rather than only declining the next one. A debt
    /// outlives the event that booked it, so a reload mid-transition is the one way a rung can change
    /// under one — and paying it afterwards would move a pointer for a setting nobody has on.
    @Test func turningTheSettingOffCancelsAVisitAlreadyOwed() throws {
        let s = EngineFix.world(3, config: Self.following)
        let (owing, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(owing.pointer.pendingWarp != nil)
        #expect(owing.motion.isTransitioning)

        var off = owing.config
        off.mouseFollowsFocus = .off
        let (next, effects) = Engine.reduce(owing, .configChanged(off))
        #expect(next.pointer.pendingWarp == nil)
        #expect(Self.warps(effects).isEmpty)

        // And the session closing afterwards pays nothing, which is the half that would have leaked.
        let (closed, out) = Engine.reduce(next, .holdTimeout(MonitorId(1)))
        #expect(Self.warps(out).isEmpty)
        #expect(closed.pointer.pendingWarp == nil)
    }

    // The setting

    @Test func withTheSettingOffNothingIsEmitted() {
        let s = EngineFix.world(3, config: Config(widthPresets: PresetCycle([.proportion(1.0)]),
                                                  transitionMode: .off))
        let (next, effects) = Engine.reduce(s, .command(.focus(.left)))
        #expect(Self.warps(effects).isEmpty)
        #expect(next.pointer.pendingWarp == nil)
    }

    /// A command that moves the strip without moving focus owes nothing: this follows *focus*, and
    /// centring a column the user is already in is not a focus change.
    @Test func aScrollThatDoesNotMoveFocusOwesNothing() {
        var s = EngineFix.world(3, config: Self.followingSnapped)
        s = EngineFix.settle(Engine.reduce(s, .command(.centerColumn)).0)

        let (next, effects) = Engine.reduce(s, .command(.centerColumn))
        #expect(Self.warps(effects).isEmpty)
        #expect(next.pointer.pendingWarp == nil)
    }

    /// Focus leaving every managed window has nowhere to send a pointer.
    @Test func focusLeavingEverythingOwesNothing() {
        let s = EngineFix.world(3, config: Self.followingSnapped)
        let (next, effects) = Engine.reduce(s, .focusChanged(nil, origin: .system))
        #expect(Self.warps(effects).isEmpty)
        #expect(next.pointer.pendingWarp == nil)
    }
}
