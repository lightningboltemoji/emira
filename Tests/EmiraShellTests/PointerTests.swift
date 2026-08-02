import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The pointer plane above its one untestable call. `CursorSurface` is the seam: what is asserted here
// is that a hide is re-assertable while every show pays out the whole depth, and that quitting gives
// the cursor back — everything below that is `CGDisplayHideCursor`, which needs a window server and a
// real cursor to say anything about.
//
// The three window-server facts these tests are shaped around were measured, not assumed, and are
// recorded in `.agents/changes/1785627157.md`: absent an activation the hide count is real; an
// activation resets it; the count floors at zero.

@Suite struct PointerTests {

    /// A cursor that records rather than hides, and moves a point rather than the pointer.
    /// `canHideCursor` is a constructor argument because the interesting case is the machine where it
    /// is false.
    @MainActor final class RecordingCursor: CursorSurface {
        let canHideCursor: Bool
        private(set) var calls: [String] = []
        /// Where the pointer is. Settable, because a test about the lazy skip is a test about where the
        /// user left it.
        var location: Point

        init(canHide: Bool = true, at location: Point = Point(x: 0, y: 0)) {
            canHideCursor = canHide
            self.location = location
        }

        func hideCursor() { calls.append("hide") }
        func showCursor() { calls.append("show") }

        func warp(to point: Point) {
            calls.append("warp(\(Int(point.x)),\(Int(point.y)))")
            location = point
        }

        /// How many hides are outstanding — the count `CGDisplayHideCursor` keeps per connection,
        /// reconstructed from what actually reached it.
        var depth: Int { calls.reduce(0) { $0 + ($1 == "hide" ? 1 : $1 == "show" ? -1 : 0) } }
    }

    @MainActor final class EventLog {
        private(set) var events: [Event] = []
        lazy var sink = EventSink { [self] event in events.append(event) }
    }

    @MainActor @Test func aHideAndAShowReachTheCursor() {
        let cursor = RecordingCursor()
        let executor = PointerExecutor(surface: cursor)
        let log = EventLog()

        executor.execute([.setCursorHidden(true)], feedback: log.sink)
        #expect(cursor.calls == ["hide"])
        #expect(executor.isCursorHidden)

        executor.execute([.setCursorHidden(false)], feedback: log.sink)
        #expect(cursor.calls == ["hide", "show"])
        #expect(!executor.isCursorHidden)
        // Unacked by contract: what answers a hide is the user moving the mouse.
        #expect(log.events.isEmpty)
    }

    /// A hide is an *assertion*, so every one of them reaches the cursor: the core re-issues it on
    /// `Event.appActivated`, and the re-issue is the entire point — an activation discards the hide
    /// that came before it.
    @MainActor @Test func everyAssertedHideReachesTheCursor() {
        let cursor = RecordingCursor()
        let executor = PointerExecutor(surface: cursor)
        let log = EventLog()

        for _ in 0..<3 { executor.execute([.setCursorHidden(true)], feedback: log.sink) }
        #expect(cursor.calls == ["hide", "hide", "hide"])
        #expect(executor.isCursorHidden)
    }

    /// The other half, and the one that is unrecoverable if it is wrong: a show pays out the whole
    /// depth. Leaving a hide unpaid is a desktop with no cursor until it is next activated into.
    @MainActor @Test func aShowPaysOutEveryHide() {
        let cursor = RecordingCursor()
        let executor = PointerExecutor(surface: cursor)
        let log = EventLog()

        for _ in 0..<3 { executor.execute([.setCursorHidden(true)], feedback: log.sink) }
        executor.execute([.setCursorHidden(false)], feedback: log.sink)
        #expect(cursor.calls == ["hide", "hide", "hide", "show", "show", "show"])
        #expect(cursor.depth == 0)
        #expect(!executor.isCursorHidden)

        // And a show with nothing outstanding does not reach the cursor at all, so it cannot drive
        // someone else's count anywhere.
        executor.execute([.setCursorHidden(false)], feedback: log.sink)
        #expect(cursor.depth == 0)
        #expect(cursor.calls.filter { $0 == "show" }.count == 3)
    }

    /// Quitting with a hidden pointer would leave the desktop without one. Not through `Teardown`:
    /// that takes the truth executor and emits only `setFrame`/`raise`/`focus`.
    @MainActor @Test func shutdownGivesTheCursorBack() {
        let cursor = RecordingCursor()
        let executor = PointerExecutor(surface: cursor)
        executor.execute([.setCursorHidden(true)], feedback: EventLog().sink)

        executor.restoreCursor()
        #expect(cursor.calls == ["hide", "show"])
        #expect(cursor.depth == 0)

        // Latched, so the two paths into a shutdown cannot show it twice.
        executor.restoreCursor()
        #expect(cursor.calls == ["hide", "show"])
    }

    /// The capability is a *config* question, answered once by `applyEnvironment`, and the executor does
    /// not second-guess it per effect. Declining a hide the reducer has already recorded would put the
    /// two permanently out of step — no announcement, so no armed watcher, so no `pointerWoke`, so no
    /// way back for the rest of the session.
    @MainActor @Test func theCapabilityIsAnsweredForTheClampNotPerEffect() {
        let cursor = RecordingCursor(canHide: false)
        let executor = PointerExecutor(surface: cursor)
        let announced = Announcements()
        executor.onCursorHidden = { announced.record($0) }

        // What the daemon clamps `[mouse] hide` against, and the only place the answer is read.
        #expect(!executor.canHideCursor)

        // Asked anyway, it stays in step with the core, so the wake still recovers the setting.
        executor.execute([.setCursorHidden(true)], feedback: EventLog().sink)
        #expect(executor.isCursorHidden)
        #expect(announced.values == [true])
    }

    /// The other plane's effects reach here only through a mis-routing, and doing nothing with them is
    /// what keeps that a routing bug rather than a cursor bug.
    @MainActor @Test func everyOtherPlanesEffectsAreIgnored() {
        let cursor = RecordingCursor()
        let executor = PointerExecutor(surface: cursor)
        let log = EventLog()

        executor.execute([.setFrame(WindowId(1), .zero), .focus(WindowId(1)), .endTransition,
                          .capture(WindowId(1), size: .zero), .exec("true")], feedback: log.sink)
        #expect(cursor.calls.isEmpty)
        #expect(log.events.isEmpty)
    }

    // The warp (the lazy half of `Effect.warpPointer`)

    /// A rect rather than a point is what lets "leave it alone if it is already in there" belong to the
    /// instruction — so focus landing on the window the pointer is over does not yank it.
    @MainActor @Test func aPointerAlreadyInsideTheRectIsLeftWhereItIs() {
        let cursor = RecordingCursor(at: Point(x: 640, y: 400))
        let executor = PointerExecutor(surface: cursor)
        var warped: [Point] = []
        executor.onWarp = { warped.append($0) }

        executor.execute([.warpPointer(into: Rect(x: 600, y: 300, width: 200, height: 200))],
                         feedback: EventLog().sink)
        #expect(cursor.calls.isEmpty)
        #expect(cursor.location == Point(x: 640, y: 400))
        #expect(warped.isEmpty)
    }

    @MainActor @Test func aPointerOutsideTheRectGoesToItsCentre() {
        let cursor = RecordingCursor(at: Point(x: 20, y: 20))
        let executor = PointerExecutor(surface: cursor)
        var warped: [Point] = []
        executor.onWarp = { warped.append($0) }

        executor.execute([.warpPointer(into: Rect(x: 600, y: 300, width: 200, height: 200))],
                         feedback: EventLog().sink)
        #expect(cursor.calls == ["warp(700,400)"])
        // Announced *with* where it was put: both sample readers hold a record of where the cursor was,
        // and a re-anchor that did not say where would only be half the news.
        #expect(warped == [Point(x: 700, y: 400)])
    }

    /// Only a warp that *moved* the pointer is announced. The re-anchor exists because the cursor is
    /// somewhere it was not; a skipped warp left it exactly where the threshold was measuring from.
    @MainActor @Test func onlyAWarpThatMovedIsAnnounced() {
        let cursor = RecordingCursor(at: Point(x: 20, y: 20))
        let executor = PointerExecutor(surface: cursor)
        var warped: [Point] = []
        executor.onWarp = { warped.append($0) }
        let rect = Rect(x: 600, y: 300, width: 200, height: 200)

        executor.execute([.warpPointer(into: rect)], feedback: EventLog().sink)
        #expect(warped == [Point(x: 700, y: 400)])
        // The pointer is now at the centre, so a second identical instruction is the lazy case.
        executor.execute([.warpPointer(into: rect)], feedback: EventLog().sink)
        #expect(warped == [Point(x: 700, y: 400)])
        #expect(cursor.calls == ["warp(700,400)"])
    }

    /// A warp does not touch the hide, and a hide does not touch the warp: the pointer being invisible
    /// is exactly why a warp under a cover is worth doing.
    @MainActor @Test func aWarpLeavesTheHiddenCursorHidden() {
        let cursor = RecordingCursor(at: Point(x: 20, y: 20))
        let executor = PointerExecutor(surface: cursor)

        executor.execute([.setCursorHidden(true),
                          .warpPointer(into: Rect(x: 600, y: 300, width: 200, height: 200))],
                         feedback: EventLog().sink)
        #expect(executor.isCursorHidden)
        #expect(cursor.calls == ["hide", "warp(700,400)"])
        #expect(cursor.depth == 1)
    }

    /// The hide is re-asserted but the *announcement* is edge-triggered, and the difference is
    /// load-bearing: `onCursorHidden` arms the wake watcher, which re-anchors as it arms. Announcing
    /// every re-assertion would move the anchor to wherever the pointer sat at the last activation, so
    /// a pointer that never moved would be measured from a fresh origin each time and the wake would
    /// need the user to travel four points from *there*.
    @MainActor @Test func onlyTheEdgeIsAnnounced() {
        let announced = Announcements()
        let cursor = RecordingCursor()
        let executor = PointerExecutor(surface: cursor)
        executor.onCursorHidden = { announced.record($0) }

        executor.execute([.setCursorHidden(true), .setCursorHidden(true),
                          .setCursorHidden(false)], feedback: EventLog().sink)
        #expect(announced.values == [true, false])
        // Both hides reached the cursor even so, and both were paid for.
        #expect(cursor.calls == ["hide", "hide", "show", "show"])
        #expect(cursor.depth == 0)
    }

    @MainActor final class Announcements {
        private(set) var values: [Bool] = []
        func record(_ value: Bool) { values.append(value) }
    }
}

//
// The hide's one exit. Hiding the pointer is only safe because emira can see the motion that brings it
// back — refusing a state with no exit beats any timeout, which would also unhide on somebody who is
// merely reading. *Which* motion counts is the threshold, and the threshold is the whole of this type.

@Suite @MainActor struct PointerWakeTests {

    /// Nothing is hidden, so a mouse crossing the whole desktop says nothing to the core. The pointer
    /// moves all day; this is the reason raw samples never reach the pump.
    @Test func samplesSayNothingUntilSomethingIsHidden() {
        let log = PointerTests.EventLog()
        let wake = PointerWake(sink: log.sink)

        for x in stride(from: 0.0, through: 900.0, by: 100) {
            wake.pointerMoved(to: Point(x: x, y: 400))
        }
        #expect(log.events.isEmpty)
    }

    /// The first sample after a hide is the anchor, not a wake: a hide takes the cursor where it
    /// stands, and there is no position to measure against until the pointer reports one.
    @Test func theFirstSampleAfterAHideOnlyAnchors() {
        let log = PointerTests.EventLog()
        let wake = PointerWake(sink: log.sink)
        wake.setArmed(true)

        wake.pointerMoved(to: Point(x: 500, y: 400))
        #expect(log.events.isEmpty)
    }

    @Test func jitterInPlaceNeverWakesThePointer() {
        let log = PointerTests.EventLog()
        let wake = PointerWake(sink: log.sink)
        wake.setArmed(true)
        wake.pointerMoved(to: Point(x: 500, y: 400))

        // A hundred samples inside the threshold, in every direction — a finger resting on a trackpad.
        for step in 0..<100 {
            let wobble = Double(step % 3) - 1
            wake.pointerMoved(to: Point(x: 500 + wobble, y: 400 - wobble))
        }
        #expect(log.events.isEmpty)
    }

    /// Reported once and then disarmed: `pointerWoke` is an edge. A stream of them would put a mouse
    /// drag through the pump at the refresh rate, into the inbound log — which *is* the replay log.
    @Test func realMotionWakesExactlyOnce() {
        let log = PointerTests.EventLog()
        let wake = PointerWake(sink: log.sink)
        wake.setArmed(true)
        wake.pointerMoved(to: Point(x: 500, y: 400))

        for x in stride(from: 500.0, through: 600.0, by: 5) {
            wake.pointerMoved(to: Point(x: x, y: 400))
        }
        #expect(log.events == [.pointerWoke])
    }

    /// A slow, deliberate drag crosses the threshold as surely as a fast one — the anchor does not
    /// move, so distance accumulates however few points each sample adds.
    @Test func aSlowDragStillWakes() {
        let log = PointerTests.EventLog()
        let wake = PointerWake(sink: log.sink)
        wake.setArmed(true)
        wake.pointerMoved(to: Point(x: 500, y: 400))

        for step in 1...Int(PointerWake.distance * 2) {
            wake.pointerMoved(to: Point(x: 500 + Double(step), y: 400))
        }
        #expect(log.events == [.pointerWoke])
    }

    /// Disarming stops the watching outright, which is what keeps an unhidden pointer from putting an
    /// event through the pump on every twitch for the rest of the session.
    @Test func disarmingStopsTheWatching() {
        let log = PointerTests.EventLog()
        let wake = PointerWake(sink: log.sink)
        wake.setArmed(true)
        wake.pointerMoved(to: Point(x: 500, y: 400))
        wake.setArmed(false)

        for x in stride(from: 500.0, through: 900.0, by: 20) {
            wake.pointerMoved(to: Point(x: x, y: 400))
        }
        #expect(log.events.isEmpty)
    }

    /// Arming again re-anchors: the arming *is* the anchor, so a hide that has been re-taken starts
    /// measuring afresh from wherever the cursor is now.
    @Test func armingAgainReAnchors() {
        let log = PointerTests.EventLog()
        let wake = PointerWake(sink: log.sink)
        wake.setArmed(true)
        wake.pointerMoved(to: Point(x: 500, y: 400))
        wake.pointerMoved(to: Point(x: 502, y: 400))     // inside the threshold

        wake.setArmed(true)
        wake.pointerMoved(to: Point(x: 900, y: 400))     // the new anchor, however far
        #expect(log.events.isEmpty)

        wake.pointerMoved(to: Point(x: 940, y: 400))
        #expect(log.events == [.pointerWoke])
    }

    /// A warp forgets the anchor without stopping the watching. Without it the next jitter would
    /// measure hundreds of points against a place the cursor has left and unhide instantly.
    @Test func aReanchorForgetsTheAnchorAndKeepsWatching() {
        let log = PointerTests.EventLog()
        let wake = PointerWake(sink: log.sink)
        wake.setArmed(true)
        wake.pointerMoved(to: Point(x: 500, y: 400))

        wake.reanchor()
        wake.pointerMoved(to: Point(x: 900, y: 400))     // the warp's destination, not a wake
        #expect(log.events.isEmpty)

        wake.pointerMoved(to: Point(x: 940, y: 400))     // …and the user's own motion still is one
        #expect(log.events == [.pointerWoke])
    }

    /// …and a re-anchor with nothing hidden must not *start* the watching, or an unhidden pointer would
    /// put an event through the pump on every twitch thereafter.
    @Test func aReanchorWithNothingHiddenStartsNothing() {
        let log = PointerTests.EventLog()
        let wake = PointerWake(sink: log.sink)

        wake.reanchor()
        for x in stride(from: 0.0, through: 900.0, by: 100) {
            wake.pointerMoved(to: Point(x: x, y: 400))
        }
        #expect(log.events.isEmpty)
    }
}

//
// The one thing about the two readers that is not either reader's: which runs first.

@Suite @MainActor struct PointerSamplesTests {

    /// **The waking sample must not also report a crossing**, and only the order makes that true. A
    /// hidden pointer may be sitting over a window nobody chose — the strip can have scrolled under it
    /// — so the motion that ends a hide must only wake. `PointerFocus` tells this is that sample from
    /// `State.pointer.isCursorHidden`, which the `pointerWoke` is about to clear, so a wake that ran
    /// first would hand focus to whatever the cursor had drifted over.
    ///
    /// The move is from over *nothing* into a window, which is what makes this a test of the order
    /// rather than of the baseline: the two run orders disagree about this sample and no other.
    @Test func theWakingSampleReportsNoCrossing() throws {
        var state = PointerFocusTests.world()
        state.pointer.isCursorHidden = true
        let target = try #require(state.world.placedOnScreen.sorted().first)
        let inside = PointerFocusTests.point(in: state, of: target)

        // The core's own answer to `pointerWoke`, spelled by hand: reducing it clears the flag, which
        // is exactly what must not have happened yet when focus reads.
        let log = PointerTests.EventLog()
        let sink = EventSink { event in
            if event == .pointerWoke { state.pointer.isCursorHidden = false }
            log.sink(event)
        }
        let wake = PointerWake(sink: sink)
        let samples = PointerSamples(focus: PointerFocusTests.reader({ state }, sink), wake: wake)
        wake.setArmed(true)

        samples.pointerMoved(to: Point(x: -5000, y: -5000))   // the anchor, over nothing
        samples.pointerMoved(to: inside)                      // past the threshold, into a window

        #expect(log.events == [.pointerWoke])
        #expect(!state.pointer.isCursorHidden)
    }

    /// …and once it is awake the very next sample behaves normally, so the suppression is one sample
    /// wide rather than a mode the feature can be left stuck in.
    @Test func theSampleAfterTheWakeCrossesNormally() throws {
        var state = PointerFocusTests.world()
        state.pointer.isCursorHidden = true
        let target = try #require(state.world.placedOnScreen.sorted().first)
        let inside = PointerFocusTests.point(in: state, of: target)

        let log = PointerTests.EventLog()
        let sink = EventSink { event in
            if event == .pointerWoke { state.pointer.isCursorHidden = false }
            log.sink(event)
        }
        let wake = PointerWake(sink: sink)
        let samples = PointerSamples(focus: PointerFocusTests.reader({ state }, sink), wake: wake)
        wake.setArmed(true)

        samples.pointerMoved(to: inside)                      // anchor, inside the window
        samples.pointerMoved(to: Point(x: -5000, y: -5000))   // wakes; leaves every window
        samples.pointerMoved(to: inside)                      // a crossing the user really made

        #expect(log.events == [.pointerWoke, .pointerEntered(target)])
    }

    // The other direction: a move the user did not make

    /// A warp posts no event, so nothing else can tell the readers the cursor is somewhere new. Left
    /// untold, focus measures the next real sample against the window the pointer *left* and calls it a
    /// crossing — into a window that already has focus, and so usually harmless, but the reducer would
    /// be answering a report of something nobody did.
    @Test func aWarpRebasesTheCrossingBaseline() throws {
        let state = PointerFocusTests.world()
        let target = try #require(state.world.placedOnScreen.sorted().first)
        let inside = PointerFocusTests.point(in: state, of: target)
        let nowhere = Point(x: -5000, y: -5000)

        let log = PointerTests.EventLog()
        let samples = PointerSamples(focus: PointerFocusTests.reader({ state }, log.sink),
                                     wake: PointerWake(sink: log.sink))

        samples.pointerMoved(to: nowhere)      // the user's pointer, over no window
        #expect(log.events.isEmpty)

        // Focus went to `target` and the pointer was sent after it.
        samples.pointerWarped(to: inside)
        // The first twitch afterwards is not a crossing: the pointer travelled nowhere the user took
        // it, and the window under it is the one the warp aimed at. Untold, the baseline would still
        // be "over nothing" and this sample would report a crossing nobody made.
        samples.pointerMoved(to: inside.offsetBy(dx: 1, dy: 1))
        #expect(log.events.isEmpty)
    }

    /// …and the rebase is not a mute: leaving the warped-to window and coming back still reports.
    @Test func aCrossingAfterAWarpIsStillReported() throws {
        let state = PointerFocusTests.world()
        let target = try #require(state.world.placedOnScreen.sorted().first)
        let inside = PointerFocusTests.point(in: state, of: target)

        let log = PointerTests.EventLog()
        let samples = PointerSamples(focus: PointerFocusTests.reader({ state }, log.sink),
                                     wake: PointerWake(sink: log.sink))

        samples.pointerWarped(to: inside)
        samples.pointerMoved(to: Point(x: -5000, y: -5000))   // out of every window
        samples.pointerMoved(to: inside)                      // and back in, which the user did

        #expect(log.events == [.pointerEntered(target)])
    }

    /// The wake is re-anchored by the same call — a hidden pointer carried hundreds of points by a warp
    /// would otherwise clear its own threshold on the next jitter and unhide on nobody.
    @Test func aWarpAlsoReanchorsTheWake() throws {
        let state = PointerFocusTests.world()
        let target = try #require(state.world.placedOnScreen.sorted().first)
        let inside = PointerFocusTests.point(in: state, of: target)

        let log = PointerTests.EventLog()
        let wake = PointerWake(sink: log.sink)
        let samples = PointerSamples(focus: PointerFocusTests.reader({ state }, log.sink), wake: wake)
        wake.setArmed(true)
        samples.pointerMoved(to: Point(x: -5000, y: -5000))   // the anchor a hide left
        #expect(log.events.isEmpty)

        samples.pointerWarped(to: inside)
        // Without the re-anchor this jitter is thousands of points from the old anchor and wakes at once.
        samples.pointerMoved(to: inside.offsetBy(dx: 1, dy: 1))
        #expect(log.events.isEmpty)
    }
}

//
// Focus following the pointer, above the hit test. `World.window(at:)` is pure and tested in the
// core; what is here is the part that cannot be pure — *when to ask*, and the two rules that keep a
// feature whose focus scrolls from chasing itself across the desktop.

@Suite struct PointerFocusTests {

    /// A booted world of three full-width columns at rest, with hover on. Full width so a crossing
    /// genuinely scrolls, and `off` so it does so without a cover in the way.
    @MainActor static func world() -> State {
        var s = State(config: Config(widthPresets: PresetCycle([.proportion(1.0)]),
                                     focusFollowsMouse: true, transitionMode: .off))
        s = Engine.reduce(s, .screensChanged([
            MonitorInfo(id: MonitorId(1), frame: Rect(x: 0, y: 0, width: 1000, height: 800))])).0
        for raw in UInt64(1)...3 {
            let snapshot = WindowSnapshot(id: WindowId(raw), bundleId: "com.test.app", title: "w",
                                          role: .standard,
                                          frame: Rect(x: 0, y: 0, width: 400, height: 300))
            var (next, effects) = Engine.reduce(s, .windowCreated(snapshot))
            // Settle: answer every capture and land every set, then tick out the springs.
            for _ in 0..<2000 {
                var feedback: [Event] = []
                for effect in effects {
                    switch effect {
                    case .capture(let w, _):  feedback.append(.captureReady(w))
                    case .beginTransition:    feedback.append(.coverOnScreen)
                    case .setFrame(let w, _), .park(let w, _): feedback.append(.axLanded(w))
                    default: continue
                    }
                }
                effects = []
                if feedback.isEmpty {
                    guard next.motion.isTransitioning else { break }
                    feedback = [.tick(dt: 1.0 / 120)]
                }
                for event in feedback {
                    let (n, out) = Engine.reduce(next, event)
                    next = n
                    effects += out
                }
            }
            s = next
        }
        return s
    }

    /// A point inside a window that is on the glass, and one over nothing.
    @MainActor static func point(in state: State, of id: WindowId) -> Point {
        state.world.windows[id]?.frame.center ?? .zero
    }

    /// A reader with the setting on. `isEnabled` is `applyShellConfig`'s and defaults **off**, so a
    /// test about a crossing turns it on the way the daemon does — which is also why the "off" test
    /// below is about this flag rather than about the config the reducer reads.
    @MainActor static func reader(_ state: @escaping @MainActor () -> State,
                                  _ sink: EventSink) -> PointerFocus {
        let focus = PointerFocus(state: state, sink: sink)
        focus.isEnabled = true
        return focus
    }

    @MainActor @Test func aCrossingIsReportedOnce() throws {
        let state = Self.world()
        let log = PointerTests.EventLog()
        let focus = Self.reader({ state }, log.sink)
        let target = try #require(state.world.placedOnScreen.sorted().first)
        let inside = Self.point(in: state, of: target)

        // Several samples inside one window: a crossing, then nothing.
        focus.pointerMoved(to: inside)
        focus.pointerMoved(to: inside.offsetBy(dx: 3, dy: 3))
        focus.pointerMoved(to: inside.offsetBy(dx: -4, dy: 1))

        #expect(log.events == [.pointerEntered(target)])
    }

    /// **Rule 2.** Mid-transition the reals have teleported and the eye is on a photograph, so hover —
    /// an act of the eye — must not read a screen the eye is not seeing.
    @MainActor @Test func nothingIsReportedWhileACoverIsUp() throws {
        var state = Self.world()
        let target = try #require(state.world.placedOnScreen.sorted().first)
        let inside = Self.point(in: state, of: target)
        // Force the covered phase the way a real transition reaches it.
        state.motion.openTransition(scope: state.world.stripWindowIds)
        for id in state.world.stripWindowIds { state.motion.markCaptured(id) }
        state.motion.raiseCover()
        state.motion.confirmCover()
        #expect(state.motion.isCovered)

        let log = PointerTests.EventLog()
        let focus = Self.reader({ state }, log.sink)
        focus.pointerMoved(to: inside)
        #expect(log.events.isEmpty)
    }

    /// …and the suspension still *tracks*. When the cover comes down the baseline is already whatever
    /// is now under the hand, so the first twitch reports a crossing the pointer never made only if the
    /// window really did change — which is rule 1 holding through a transition.
    @MainActor @Test func aSuspendedIntervalStillUpdatesTheBaseline() throws {
        var covered = Self.world()
        let target = try #require(covered.world.placedOnScreen.sorted().first)
        let inside = Self.point(in: covered, of: target)
        let uncovered = covered
        covered.motion.openTransition(scope: covered.world.stripWindowIds)
        for id in covered.world.stripWindowIds { covered.motion.markCaptured(id) }
        covered.motion.raiseCover()
        covered.motion.confirmCover()

        var current = covered
        let log = PointerTests.EventLog()
        let focus = Self.reader({ current }, log.sink)

        focus.pointerMoved(to: inside)          // suspended: tracked, not reported
        #expect(log.events.isEmpty)

        current = uncovered                     // the cover comes down
        focus.pointerMoved(to: inside.offsetBy(dx: 2, dy: 2))
        #expect(log.events.isEmpty, "the pointer never left the window it was already over")
    }

    /// The strip may have scrolled under a hidden pointer, so it can be sitting over a window nobody
    /// chose. The first twitch only wakes.
    @MainActor @Test func aHiddenPointerReportsNoCrossing() throws {
        var state = Self.world()
        let target = try #require(state.world.placedOnScreen.sorted().first)
        state.pointer.isCursorHidden = true

        let log = PointerTests.EventLog()
        let focus = Self.reader({ state }, log.sink)
        focus.pointerMoved(to: Self.point(in: state, of: target))
        #expect(log.events.isEmpty)
    }

    /// …and the sample after the wake reports nothing either, because the hidden interval tracked the
    /// baseline. Only a crossing the user actually made is news.
    @MainActor @Test func theSampleAfterAWakeIsMeasuredAgainstWhereTheHideLeftIt() throws {
        var state = Self.world()
        let target = try #require(state.world.placedOnScreen.sorted().first)
        let inside = Self.point(in: state, of: target)
        state.pointer.isCursorHidden = true

        var current = state
        let log = PointerTests.EventLog()
        let focus = Self.reader({ current }, log.sink)
        focus.pointerMoved(to: inside)

        current.pointer.isCursorHidden = false
        focus.pointerMoved(to: inside.offsetBy(dx: 5, dy: 5))
        #expect(log.events.isEmpty)
    }

    /// **With the setting off this type does not read `State` at all**, which is the whole reason the
    /// bit is kept here rather than asked of the config per sample: `[mouse] hide` can keep the samples
    /// arriving on its own, and a copy of the world to find out nobody wants them is exactly the idle
    /// price a window manager must not charge for a feature that is switched off.
    @MainActor @Test func withTheSettingOffTheStateIsNotEvenRead() throws {
        let state = Self.world()
        let target = try #require(state.world.placedOnScreen.sorted().first)

        var reads = 0
        let log = PointerTests.EventLog()
        let focus = PointerFocus(state: { reads += 1; return state }, sink: log.sink)
        #expect(!focus.isEnabled, "off is the default, so a daemon that never applied a config is quiet")

        for _ in 0..<10 { focus.pointerMoved(to: Self.point(in: state, of: target)) }
        #expect(log.events.isEmpty)
        #expect(reads == 0)
    }

    /// …and switching it on mid-session takes effect on the next sample, because a reload is how it
    /// arrives (`applyShellConfig`) and nothing re-creates this type.
    @MainActor @Test func turningItOnMidSessionStartsReporting() throws {
        let state = Self.world()
        let target = try #require(state.world.placedOnScreen.sorted().first)
        let inside = Self.point(in: state, of: target)

        let log = PointerTests.EventLog()
        let focus = PointerFocus(state: { state }, sink: log.sink)
        focus.pointerMoved(to: inside)
        #expect(log.events.isEmpty)

        focus.isEnabled = true
        focus.pointerMoved(to: inside)
        #expect(log.events == [.pointerEntered(target)])
    }

    /// Leaving every window and coming back is a crossing again — the baseline is "what the pointer is
    /// over", including nothing.
    @MainActor @Test func leavingAndReturningIsANewCrossing() throws {
        let state = Self.world()
        let target = try #require(state.world.placedOnScreen.sorted().first)
        let inside = Self.point(in: state, of: target)

        let log = PointerTests.EventLog()
        let focus = Self.reader({ state }, log.sink)
        focus.pointerMoved(to: inside)
        focus.pointerMoved(to: Point(x: -5000, y: -5000))
        focus.pointerMoved(to: inside)

        #expect(log.events == [.pointerEntered(target), .pointerEntered(target)])
    }
}

//
// The ladder's upper rungs, at the seam they are actually decided at. `lazy` — leave a pointer that is
// already inside where it is — is the rule everywhere else and it is a good one, but an emira column is
// most of the screen, so "already inside" is the *common* case and lazy leaves the pointer still
// through almost every focus change. `force` is the
// answer, and it is a shell-side setting rather than a bit on the effect: the core emits the identical
// warp under every rung, exactly as it emits identical geometry under every `[animation] window`.

@Suite struct PointerRecentresTests {

    /// The same instruction, the same executor, one setting apart — which is the whole claim.
    static let rect = Rect(x: 600, y: 300, width: 200, height: 200)

    @MainActor @Test func recentringCentresAPointerThatIsAlreadyInside() {
        let cursor = PointerTests.RecordingCursor(at: Point(x: 640, y: 400))   // inside
        let executor = PointerExecutor(surface: cursor)
        executor.recentres = true
        var warped: [Point] = []
        executor.onWarp = { warped.append($0) }

        executor.execute([.warpPointer(into: Self.rect)], feedback: PointerTests.EventLog().sink)
        #expect(cursor.calls == ["warp(700,400)"])
        #expect(warped == [Point(x: 700, y: 400)])
    }

    /// …and the identical effect without it leaves the pointer exactly where the user put it, which is
    /// the whole difference between the two rungs.
    @MainActor @Test func withoutItTheSamePointerIsLeftAlone() {
        let cursor = PointerTests.RecordingCursor(at: Point(x: 640, y: 400))
        let executor = PointerExecutor(surface: cursor)

        executor.execute([.warpPointer(into: Self.rect)], feedback: PointerTests.EventLog().sink)
        #expect(cursor.calls.isEmpty)
    }

    /// The default is the lazy one, so a daemon that never reached `applyShellConfig` cannot centre a
    /// pointer nobody asked it to.
    @MainActor @Test func theDefaultIsLazy() {
        #expect(!PointerExecutor(surface: PointerTests.RecordingCursor()).recentres)
    }

    /// Recentring never consults the position, so a cursor that cannot answer where it is does not
    /// silently disable the feature.
    @MainActor @Test func recentringDoesNotDependOnReadingThePosition() {
        let cursor = PointerTests.RecordingCursor(at: .zero)
        let executor = PointerExecutor(surface: cursor)
        executor.recentres = true
        executor.execute([.warpPointer(into: Rect(x: 0, y: 0, width: 100, height: 100))],
                         feedback: PointerTests.EventLog().sink)
        #expect(cursor.calls == ["warp(50,50)"])
    }
}
