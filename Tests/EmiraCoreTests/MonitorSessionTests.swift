import Foundation
import Testing
@testable import EmiraCore

// A cover is one screen's. Everything here is silent with one display attached — a session that covers
// every screen and a session per screen are indistinguishable while there is one — which is why this
// suite exists at all, the same argument `MonitorTests` makes about assignments.
//
// The desktop these are written against: two displays side by side, the second showing the address the
// first does not. A window reaches the second by being *sent* to that address — `Monitors.assign`
// leaves an address on whichever display holds it, so `move-to-workspace` crosses displays already,
// without any of phase 4's verbs.

@Suite struct MonitorSessionTests {

    static let left = MonitorId(1), right = MonitorId(2)
    static let leftFrame = Rect(x: 0, y: 0, width: 1000, height: 800)
    static let rightFrame = Rect(x: 1000, y: 0, width: 1200, height: 900)

    /// One column fills a viewport exactly, so every focus change across columns genuinely scrolls —
    /// which is what opens a session rather than snapping.
    static let fullWidth = Config(widthPresets: PresetCycle([.proportion(1.0)]))

    /// Two displays, `count` windows on the first one's strip, at rest.
    static func desktop(_ count: UInt64, config: Config = fullWidth) -> State {
        var s = State(config: config)
        (s, _) = Engine.reduce(s, .screensChanged([MonitorInfo(id: left, frame: leftFrame),
                                                   MonitorInfo(id: right, frame: rightFrame)]))
        for raw in 1...max(count, 1) where count > 0 {
            let (next, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(raw)))
            s = EngineFix.settle(next, fx)
        }
        return s
    }

    /// The address the second display is showing — the one `Monitors` handed it, which is whatever the
    /// acting monitor does not hold.
    static func shownOnRight(_ s: State) -> WorkspaceName {
        s.monitors.shown(on: right) ?? .first
    }

    /// Send the focused window to the address `right` is showing, and drive everything to rest.
    static func sendToRight(_ s: State) -> State {
        let (next, fx) = Engine.reduce(s, .command(.moveToWorkspace(.name(shownOnRight(s)))))
        return EngineFix.settle(next, fx)
    }

    // What a second display's strip is laid out against

    /// **Each display tiles its own shown address, against its own working area.** One supply per
    /// display is what `State.placements()` is for; laid out against the acting monitor's metrics
    /// instead, a window on the second screen would be placed inside the first one's bounds.
    @Test func aWindowOnTheSecondDisplaysAddressTilesOnThatDisplay() {
        let s = Self.sendToRight(Self.desktop(2))
        let moved = try! #require(s.workspaces[Self.shownOnRight(s)].allWindowIds.first)

        let frame = try! #require(s.world.windows[moved]?.frame)
        #expect(Self.rightFrame.contains(Point(x: frame.midX, y: frame.midY)),
                "the window is laid out on the display that holds its workspace")
        #expect(s.world.isOnScreen(moved), "…and it tiles there rather than parking")
    }

    /// The two viewports are independent numbers. A scroll on one screen must not move the other's
    /// strip by a point — with one offset for the desktop, it moved both.
    @Test func eachDisplayScrollsItsOwnViewport() {
        // Two windows on each strip, so either display's `focus left` genuinely scrolls.
        var s = Self.sendToRight(Self.desktop(4))
        s = Self.sendToRight(s)
        let before = s.motion.offset(of: Self.right).current

        let (after, fx) = Engine.reduce(s, .command(.focus(.left)))
        let settled = EngineFix.settle(after, fx)
        #expect(settled.motion.offset(of: Self.left).current != s.motion.offset(of: Self.left).current)
        #expect(settled.motion.offset(of: Self.right).current == before)
    }

    // One session per display (D7)

    /// A transition on one screen opens a session there and **nowhere else** — the other display's
    /// cover is not raised, its desktop is not photographed, and the video playing on it keeps playing.
    @Test func aScrollOpensASessionOnItsOwnDisplayAlone() {
        let s = Self.sendToRight(Self.desktop(3))
        let (after, fx) = Engine.reduce(s, .command(.focus(.left)))

        #expect(after.motion.isTransitioning(on: Self.left))
        #expect(!after.motion.isTransitioning(on: Self.right))
        #expect(after.motion.transitioningMonitors == [Self.left])
        // Every capture this asked for is for the left display's cover: the right one owes no base,
        // which is the `SCShareableContent` fetch a second screen used to cost every transition.
        let covers = fx.compactMap { if case .capture(let m, _, _) = $0 { return m }; return nil }
        #expect(!covers.isEmpty)
        #expect(Set(covers) == [Self.left])
    }

    /// Two sessions live at once, each with its own cover, and **each closes on its own schedule**. One
    /// session spanning both screens is what this replaces: there, a hung app under one cover held the
    /// other screen's cover up for the whole hold timeout.
    @Test func oneDisplaysCoverComesDownWhileTheOthersIsStillUp() {
        var s = Self.sendToRight(Self.desktop(4))
        s = Self.sendToRight(s)

        // A scroll on the left…
        var (state, fx) = Engine.reduce(s, .command(.focus(.left)))
        // …and one on the right, by focusing the monitor the reducer acts on. (Phase 4 spells this as a
        // verb; here the acting monitor is moved directly, which is all `focus-monitor` will do.)
        state.monitors.focus(Self.right)
        let (both, rightFx) = Engine.reduce(state, .command(.focus(.left)))
        state = both
        #expect(state.motion.transitioningMonitors == [Self.left, Self.right])

        // Drive the right display's cover all the way down, and nothing else.
        var effects = fx + rightFx
        func feed(_ event: Event) {
            let (next, out) = Engine.reduce(state, event)
            state = next
            effects += out
        }
        for w in state.motion.transition(of: Self.right)?.windows ?? [] { feed(.captureReady(w)) }
        feed(.coverOnScreen(Self.right))
        for w in state.motion.transition(of: Self.right)?.awaitingLanding ?? [] { feed(.axLanded(w)) }
        for _ in 0..<2000 where state.motion.isTransitioning(on: Self.right) { feed(.tick(dt: 1.0 / 120)) }

        #expect(!state.motion.isTransitioning(on: Self.right), "its own gates closed it")
        #expect(state.motion.isTransitioning(on: Self.left), "and the other cover is still up")
        #expect(effects.contains(.endTransition(Self.right)))
        #expect(!effects.contains(.endTransition(Self.left)))
    }

    /// A hold timeout is one display's. The other screen's cover keeps running, which is the whole
    /// point of a deadline per cover.
    @Test func aHoldTimeoutClosesOneCoverAndLeavesTheOther() {
        var s = Self.sendToRight(Self.desktop(4))
        s = Self.sendToRight(s)
        var (state, _) = Engine.reduce(s, .command(.focus(.left)))
        state.monitors.focus(Self.right)
        (state, _) = Engine.reduce(state, .command(.focus(.left)))

        let (after, fx) = Engine.reduce(state, .holdTimeout(Self.left))
        #expect(fx.contains(.endTransition(Self.left)))
        #expect(!after.motion.isTransitioning(on: Self.left))
        #expect(after.motion.isTransitioning(on: Self.right))
    }

    // The quantified gate (D8)

    /// **A real window may move only when the cover is up on every display it is visible on.** With the
    /// left display mid-capture, a window on it stays where it is however far out of place it has
    /// drifted: there is nothing on that glass to hide the write.
    @Test func aWindowOnACapturingDisplayIsNotWritten() {
        let s = Self.sendToRight(Self.desktop(3))
        let onLeft = try! #require(s.layout.allWindowIds.first)

        // Open a session on the left and leave it capturing — no `captureReady` answered.
        var (state, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(state.motion.phase(of: Self.left) == .capturing)

        // Drift a left-display window well off its target, then ask for a re-place.
        (state, _) = Engine.reduce(state, .windowFrameChanged(onLeft, Rect(x: 77, y: 77,
                                                                           width: 200, height: 200)))
        let (_, fx) = Engine.reduce(state, .dragEnded)
        #expect(EngineFix.placement(of: onLeft, in: fx) == nil)
    }

    /// …and the same pass writes a window on the **other** display, which has no cover pending and
    /// nothing to hide. Held everywhere, this is the regression a session per display exists to remove:
    /// one screen's capture head froze the whole desktop's truth plane.
    @Test func aWindowOnAnIdleDisplayIsWrittenWhileAnotherIsCapturing() {
        let s = Self.sendToRight(Self.desktop(3))
        let onRight = try! #require(s.workspaces[Self.shownOnRight(s)].allWindowIds.first)

        var (state, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(state.motion.phase(of: Self.left) == .capturing)

        (state, _) = Engine.reduce(state, .windowFrameChanged(onRight, Rect(x: 1077, y: 77,
                                                                            width: 200, height: 200)))
        let (_, fx) = Engine.reduce(state, .dragEnded)
        #expect(EngineFix.placement(of: onRight, in: fx) != nil)
    }

    /// The gate lifts per display too: once *its* cover is on the glass, that display's windows are
    /// written — at the scroll's end, which is where its layers are travelling to.
    @Test func aCoveredDisplayWritesItsWindowsAtTheScrollsEnd() {
        let s = Self.sendToRight(Self.desktop(3))
        var (state, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in state.motion.transition(of: Self.left)?.windows ?? [] {
            (state, _) = Engine.reduce(state, .captureReady(w))
        }
        let (covered, fx) = Engine.reduce(state, .coverOnScreen(Self.left))

        #expect(covered.motion.isCovered(on: Self.left))
        #expect(fx.contains { if case .setFrame = $0 { return true }; return false },
                "the teleport behind the cover is the batch this report entitles")
        let focused = try! #require(covered.world.focusedWindow)
        let atEnd = covered.layout.naturalFrames(scrollOffset: covered.motion.offset(of: Self.left).target,
                                                 metrics: covered.metrics()!)[focused]
        #expect(EngineFix.approx(try! #require(covered.world.windows[focused]?.frame),
                                 try! #require(atEnd)))
    }

    // The two untagged reports (D10)

    /// `captureReady` names a window, not a screen, because a still is display-independent: one is
    /// filmed once and marked in **every** session waiting on it. Two covers showing one window is
    /// what phase 4's cross-display move is made of, and the gate has to close for both.
    @Test func oneStillSettlesEverySessionWaitingOnIt() {
        var m = Motion()
        m.openTransition(scope: [WindowId(1)], on: Self.left)
        m.openTransition(scope: [WindowId(1), WindowId(2)], on: Self.right)

        m.markCaptured(WindowId(1))
        #expect(m.isReadyToRaise(on: Self.left))          // the left cover's whole scope is in
        #expect(!m.isReadyToRaise(on: Self.right))        // …and w2 is still owed on the right
        m.markCaptured(WindowId(2))
        #expect(m.isReadyToRaise(on: Self.right))
    }

    /// The same for `axLanded`: the window landed, which is true wherever it is being waited on.
    @Test func oneLandingSettlesEverySessionWaitingOnIt() {
        var m = Motion()
        let contents = MonitorContents(windows: [WindowId(1)])
        for monitor in [Self.left, Self.right] {
            m.openTransition(scope: [WindowId(1)], on: monitor)
            m.markCaptured(WindowId(1))
            m.raiseCover(on: monitor)
            m.confirmCover(on: monitor)
        }
        #expect(!m.isReadyToClose(on: Self.left, holding: contents))
        #expect(!m.isReadyToClose(on: Self.right, holding: contents))

        m.markLanded(WindowId(1))
        #expect(m.isReadyToClose(on: Self.left, holding: contents))
        #expect(m.isReadyToClose(on: Self.right, holding: contents))
    }

    // A window handed across the desktop
    //
    // The one term of a structural difference no single display can compute. A travelling window is
    // missing from the *after* side on the display it left and from the *before* side on the one it
    // reached, so each screen's own geometry sees one frame and no travel at all — which came out as a
    // hard cut on the arrival and a layer frozen at its capture frame on the departure.

    /// **Both screens cover it.** The destination has nothing of its own to animate — its strip was
    /// still, its viewport did not move — so the arriving window is the whole of what it has to show,
    /// and without counting the crossing it judged the edit invisible and snapped.
    @Test func aWindowSentToAnotherDisplayCoversBothScreens() {
        let s = Self.desktop(3)
        let (after, _) = Engine.reduce(s, .command(.moveToWorkspace(.name(Self.shownOnRight(s)))))

        #expect(after.motion.transitioningMonitors == [Self.left, Self.right])
    }

    /// **One journey, read twice.** Natural frames on every display share one global space and the
    /// displacement animators are the desktop's, so the two covers draw the travelling window at the
    /// *same* rect on every frame — it reads as one window crossing rather than two cutting.
    ///
    /// That rect starting at the window's pre-move frame is also the guard against seeding the
    /// crossing on both displays: a second seed accumulates, and the layer would open one whole
    /// journey past where the window actually was.
    @Test func bothCoversDrawTheTravellingWindowOnOneJourney() {
        let s = Self.desktop(3)
        let moved = try! #require(s.world.focusedWindow)
        let before = try! #require(s.world.windows[moved]?.frame)

        var (state, _) = Engine.reduce(s, .command(.moveToWorkspace(.name(Self.shownOnRight(s)))))
        for monitor in state.motion.transitioningMonitors {
            for w in state.motion.transition(of: monitor)?.windows ?? [] {
                (state, _) = Engine.reduce(state, .captureReady(w))
            }
        }
        for monitor in state.motion.transitioningMonitors {
            (state, _) = Engine.reduce(state, .coverOnScreen(monitor))
        }

        // A short step, so the spring has barely left the start it was seeded at.
        let (_, fx) = Engine.reduce(state, .tick(dt: 1.0 / 1000))
        var drawn: [MonitorId: Rect] = [:]
        for monitor in state.motion.transitioningMonitors {
            let layer = try! #require(state.motion.transition(of: monitor)?.layerId(for: moved),
                                      "every cover that scopes it owes it a layer")
            for effect in fx {
                if case .setLayerFrame(let id, let rect) = effect, id == layer { drawn[monitor] = rect }
            }
        }

        let onLeft = try! #require(drawn[Self.left], "the display it left still draws it travelling off")
        let onRight = try! #require(drawn[Self.right], "and the one it reached draws it arriving")
        #expect(EngineFix.approx(onLeft, onRight), "one journey, not two")
        #expect(EngineFix.approx(onLeft, before, tol: 2),
                "…starting where the window actually was, so the crossing was seeded once")
    }

    /// The arrival lands where the *destination* lays it out, which is the other end of the same
    /// journey — proof the travel is between two displays' geometries rather than within one.
    @Test func theTravellingWindowComesToRestOnTheDisplayItReached() {
        let s = Self.desktop(3)
        let moved = try! #require(s.world.focusedWindow)
        let (after, fx) = Engine.reduce(s, .command(.moveToWorkspace(.name(Self.shownOnRight(s)))))
        let settled = EngineFix.settle(after, fx)

        let frame = try! #require(settled.world.windows[moved]?.frame)
        #expect(Self.rightFrame.contains(Point(x: frame.midX, y: frame.midY)))
        #expect(settled.motion.windowAnimator(moved) == nil, "and the displacement is retired with it")
    }

    // What a display leaving takes with it

    /// A session on a display that has gone has no overlay to drive and no glass to reach, so it is
    /// dropped — and the overlay is told, because a dismissal is the one call that is safe for a screen
    /// that is no longer there.
    @Test func aDepartingDisplayTakesItsSessionAndIsToldToDropItsCover() {
        let s = Self.sendToRight(Self.desktop(3))
        var (state, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(state.motion.isTransitioning(on: Self.left))

        let (after, fx) = Engine.reduce(state, .screensChanged([MonitorInfo(id: Self.right,
                                                                            frame: Self.rightFrame)]))
        state = after
        #expect(fx.contains(.endTransition(Self.left)))
        #expect(!state.motion.isTransitioning(on: Self.left))
        #expect(state.monitors.focused == Self.right, "the acting monitor is always one that exists")
    }

    /// A reconfiguration takes down **every** cover, not only the ones whose display left: the ground
    /// the strip stands on moved, so nothing on any screen is travelling to where it now belongs — and
    /// the shell rebuilds the overlay of every display a change touched, which would otherwise strand a
    /// cover nobody dismissed.
    @Test func aReconfigurationTakesDownTheSurvivingDisplaysCoverToo() {
        let s = Self.sendToRight(Self.desktop(3))
        var (state, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(state.motion.isTransitioning(on: Self.left))

        // The same two displays, one of them resized — nobody left, and the cover still comes down.
        let (after, fx) = Engine.reduce(state, .screensChanged([
            MonitorInfo(id: Self.left, frame: Self.leftFrame),
            MonitorInfo(id: Self.right, frame: Rect(x: 1000, y: 0, width: 1600, height: 1000)),
        ]))
        state = after
        #expect(fx.contains(.endTransition(Self.left)))
        #expect(!state.motion.isTransitioning)
    }

    /// …and a report that changes *nothing* changes nothing. `screensChanged` also arrives
    /// redundantly, and closing a cover mid-raise there would write the truth plane with nothing on
    /// the glass to hide it — the one thing the phase machine exists to prevent.
    @Test func aRedundantReportLeavesALiveCoverAlone() {
        let s = Self.sendToRight(Self.desktop(3))
        var (state, _) = Engine.reduce(s, .command(.focus(.left)))
        let same: [MonitorInfo] = [MonitorInfo(id: Self.left, frame: Self.leftFrame),
                                   MonitorInfo(id: Self.right, frame: Self.rightFrame)]

        let (after, fx) = Engine.reduce(state, .screensChanged(same))
        state = after
        #expect(!fx.contains(.endTransition(Self.left)))
        #expect(state.motion.isTransitioning(on: Self.left))
    }

    /// The far end of `right`'s strip — a scroll offset that display can legally come to rest at, so a
    /// reconfiguration's own clamp cannot be what a scroll-memory test is measuring.
    static func scrolledToTheEnd(_ s: inout State) -> Double {
        let metrics = s.metrics(of: right)!
        let offset = s.workspaces[shownOnRight(s)].clampScrollOffset(.greatestFiniteMagnitude,
                                                                     metrics: metrics)
        s.motion.snapViewport(to: offset, on: right)
        return offset
    }

    /// **A workspace keeps its scroll across an unplug.** A `Viewport` is where one screen's scroll
    /// happens to be and does not survive its display, so the number has to be banked against the
    /// *address* — which is what makes a display that comes back resume where it left off rather than
    /// at the strip's origin.
    @Test func aWorkspaceKeepsItsScrollAcrossAnUnplug() {
        var s = Self.sendToRight(Self.desktop(4))
        s = Self.sendToRight(s)
        let address = Self.shownOnRight(s)
        let offset = Self.scrolledToTheEnd(&s)
        #expect(offset > 0, "the fixture has to have something to scroll to")

        (s, _) = Engine.reduce(s, .screensChanged([MonitorInfo(id: Self.left, frame: Self.leftFrame)]))
        (s, _) = Engine.reduce(s, .screensChanged([MonitorInfo(id: Self.left, frame: Self.leftFrame),
                                                   MonitorInfo(id: Self.right, frame: Self.rightFrame)]))

        #expect(s.monitors.shown(on: Self.right) == address, "D12 gives it its workspaces back…")
        #expect(EngineFix.approxScalar(s.motion.offset(of: Self.right).current, offset),
                "…and the address it shows remembers where it was scrolled to")
    }

    /// A lid close takes every display, and what comes back has to be the **focused** display's
    /// workspace at the **focused** display's scroll. The two are separate records — one names the
    /// address, one names the number — so a survivor's viewport standing in for the focused one's is a
    /// desktop that returns showing the right strip in the wrong place.
    @Test func aLidCloseReturnsTheFocusedDisplaysScrollAndNotAnothers() {
        var s = Self.sendToRight(Self.desktop(4))
        s = Self.sendToRight(s)
        let address = Self.shownOnRight(s)
        let offset = Self.scrolledToTheEnd(&s)
        s.motion.snapViewport(to: 0, on: Self.left)      // the other display, deliberately elsewhere
        s.monitors.focus(Self.right)
        #expect(offset > 0)

        (s, _) = Engine.reduce(s, .screensChanged([]))   // everything goes
        #expect(s.monitors.shown == address, "the desktop keeps what the user was looking at")

        (s, _) = Engine.reduce(s, .screensChanged([MonitorInfo(id: Self.right,
                                                               frame: Self.rightFrame)]))
        #expect(s.monitors.shown(on: Self.right) == address)
        #expect(EngineFix.approxScalar(s.motion.offset(of: Self.right).current, offset))
    }

    /// …and a report that changes nothing must not disturb a scroll in flight, for the reason it must
    /// not take a cover down: `screensChanged` also arrives redundantly, and re-seating every viewport
    /// there would freeze a spring mid-travel.
    @Test func aRedundantReportLeavesAScrollInFlightAlone() {
        let s = Self.sendToRight(Self.desktop(3))
        var (state, _) = Engine.reduce(s, .command(.focus(.left)))
        let mid = state.motion.offset(of: Self.left)
        let same = [MonitorInfo(id: Self.left, frame: Self.leftFrame),
                    MonitorInfo(id: Self.right, frame: Self.rightFrame)]

        (state, _) = Engine.reduce(state, .screensChanged(same))
        #expect(state.motion.offset(of: Self.left).current == mid.current)
        #expect(state.motion.offset(of: Self.left).target == mid.target)
    }

    /// A viewport is where one screen's scroll happens to be, so it goes with the display — but the
    /// **last** display leaving hands its scroll to the detached slot, and the display that returns
    /// takes it back. That is what makes a lid close and its reopening one continuous scroll.
    @Test func theLastDisplayLeavingHandsItsScrollToTheOneThatComesBack() {
        var m = Motion()
        m.reconcile([Self.left])
        m.snapViewport(to: 420, on: Self.left)

        m.reconcile([])                                   // the lid closes
        #expect(m.offset(of: nil).current == 420)
        m.reconcile([Self.left])                          // …and opens again
        #expect(m.offset(of: Self.left).current == 420)
    }
}
