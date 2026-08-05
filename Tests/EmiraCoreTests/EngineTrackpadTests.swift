import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// The strip under the hand, as scripted event sequences. Everything with arithmetic in it is reachable
// with no window server and no trackpad, which is the design working: the shell decides *that* a swipe
// happened, and every question about what it means is answered here.
//
// The fixture is one full-width preset on a 1000×800 display, so each column *is* the viewport and the
// magnet rests are exactly the column edges: 0, 1000, 2000, 3000 for four windows. `trackpadGain` is 3,
// so one normalized unit of travel is 3000 points.

@Suite struct EngineTrackpadTests {

    static let monitor = MonitorId(1)
    /// One unit of normalized pad travel, in points: `contentArea.width × trackpadGain`.
    static let unit = 3000.0

    static func world(_ count: UInt64 = 4, mode: TrackpadScrollMode = .magnet,
                      transition: TransitionMode = .smooth, centered: Bool = false,
                      direction: TrackpadScrollDirection = .standard) -> State {
        EngineFix.world(count, config: Config(widthPresets: PresetCycle([.proportion(1.0)]),
                                              centerFocusedColumn: centered,
                                              transitionMode: transition,
                                              trackpadScroll: mode,
                                              trackpadScrollDirection: direction))
    }

    /// Begin a gesture and get its cover onto the glass — the state every drag test starts from. The
    /// strip rests at 3000 with the last window focused, which is where building the world leaves it.
    static func gesturing(_ start: State) -> (State, [Effect]) {
        var s = start
        var fx: [Effect] = []
        func feed(_ e: Event) { let (n, f) = Engine.reduce(s, e); s = n; fx += f }
        feed(.trackpadScrollBegan)
        for w in s.motion.transition(of: monitor)?.windows ?? [] { feed(.captureReady(w)) }
        feed(.coverOnScreen(monitor))
        return (s, fx)
    }

    static func offset(_ s: State) -> Animator { s.motion.offset(of: monitor) }

    static func focuses(_ fx: [Effect]) -> [WindowId] {
        fx.compactMap { if case .focus(let w) = $0 { return w }; return nil }
    }

    static func placements(_ fx: [Effect]) -> Int {
        fx.filter { if case .setFrame = $0 { return true }; if case .park = $0 { return true }
                    return false }.count
    }

    // The gesture, end to end

    @Test func aMagnetizedDragSettlesOnAColumnEdge() {
        let (open, _) = Self.gesturing(Self.world())
        #expect(open.trackpadScroll == .dragging(Self.monitor))
        #expect(open.motion.isCovered(on: Self.monitor))
        #expect(Self.offset(open).current == 3000)

        // Two drains carrying 0.1 of the pad each — 600 points back down the strip.
        let (dragged, drag) = EngineFix.run(open, [.trackpadScrolled(by: -0.1),
                                                   .trackpadScrolled(by: -0.1)])
        #expect(Self.offset(dragged).current == 2400)
        // A driven offset is one that has already arrived, every frame — which is what lets the tick
        // stay a no-op for it and `Motion.advance` need no special case.
        #expect(Self.offset(dragged).target == 2400)
        #expect(Self.offset(dragged).velocity == 0)
        // **No teleport per sample.** The reals stay where the opening pass put them; a drained sample
        // emits captures and nothing else.
        #expect(Self.placements(drag) == 0)

        let (lifted, _) = Engine.reduce(dragged, .trackpadScrollEnded(velocity: 0))
        #expect(lifted.trackpadScroll == .idle)
        #expect(Self.offset(lifted).target == 2000)      // the nearer of {2000, 3000} to 2400
        #expect(lifted.motion.isTransitioning(on: Self.monitor))   // still gliding under the cover
    }

    @Test func theLiftIsTheOnlySessionOpened() {
        let (open, _) = Self.gesturing(Self.world())
        let (dragged, _) = EngineFix.run(open, (0..<8).map { _ in .trackpadScrolled(by: -0.05) })
        #expect(dragged.motion.transitioningMonitors == [Self.monitor])
        let (lifted, _) = Engine.reduce(dragged, .trackpadScrollEnded(velocity: 0))
        #expect(lifted.motion.transitioningMonitors == [Self.monitor])
        // …and the AX landings gate the close exactly as they do for a keyboard scroll.
        let (settled, _) = EngineFix.drive(lifted)
        #expect(!settled.motion.isTransitioning)
        #expect(Self.offset(settled).current == 2000)
    }

    @Test func freeRestsWhereTheMomentumRunsOut() {
        let (open, _) = Self.gesturing(Self.world(mode: .free))
        let (dragged, _) = Engine.reduce(open, .trackpadScrolled(by: -0.2))
        #expect(Self.offset(dragged).current == 2400)

        // ω = 10 on the default glide spring, so the throw is `v/ω` — half a pad per second is
        // −1500 pt/s, and 150 points of coast.
        let (lifted, _) = Engine.reduce(dragged, .trackpadScrollEnded(velocity: -0.5))
        #expect(Self.offset(lifted).target == 2250)
        #expect(Self.offset(lifted).velocity == -0.5 * Self.unit)   // seeded with the hand's own speed
    }

    @Test func aFlickOffTheEndOfTheStripIsClamped() {
        let (open, _) = Self.gesturing(Self.world(mode: .free))
        let (dragged, _) = Engine.reduce(open, .trackpadScrolled(by: -0.2))
        // Ten pads a second would throw 3000 points past the origin. The strip's end is hard.
        let (lifted, _) = Engine.reduce(dragged, .trackpadScrollEnded(velocity: -10))
        #expect(Self.offset(lifted).target == 0)

        let (settled, _) = EngineFix.drive(lifted)
        #expect(!settled.motion.isTransitioning)          // no cover left open
        #expect(settled.trackpadScroll == .idle)
        #expect(Self.offset(settled).current == 0)
    }

    @Test func theDragItselfCannotLookPastEitherEnd() {
        let (open, _) = Self.gesturing(Self.world(mode: .free))
        let (dragged, _) = EngineFix.run(open, [.trackpadScrolled(by: -2),      // 6000 pt of travel
                                                .trackpadScrolled(by: +5)])
        #expect(Self.offset(dragged).current == 3000)      // maxOffset, not 9000
    }

    // What holds the cover up

    @Test func aCoverAHandIsStillOnNeverCloses() {
        let (open, _) = Self.gesturing(Self.world())
        var (s, _) = Engine.reduce(open, .trackpadScrolled(by: -0.2))
        // Every real the opening pass moved has landed, and a driven viewport is settled by
        // construction — so without the latch this cover would cross-fade the instant the finger paused.
        for w in s.motion.transition(of: Self.monitor)?.awaitingLanding ?? [] {
            s = Engine.reduce(s, .axLanded(w)).0
        }
        for _ in 0..<200 { s = Engine.reduce(s, .tick(dt: 1.0 / 120)).0 }
        #expect(s.motion.isCovered(on: Self.monitor))
        #expect(s.trackpadScroll == .dragging(Self.monitor))

        // …and the lift is what lets it go.
        let (settled, _) = EngineFix.drive(Engine.reduce(s, .trackpadScrollEnded(velocity: 0)).0)
        #expect(!settled.motion.isTransitioning)
    }

    @Test func aPausedFingerStillGetsItsFrameBlitted() {
        let (open, _) = Self.gesturing(Self.world())
        let (dragged, _) = Engine.reduce(open, .trackpadScrolled(by: -0.2))
        let (_, fx) = Engine.reduce(dragged, .tick(dt: 1.0 / 120))
        // `isSettled` calls a driven viewport done, which is the one reading of it that would leave the
        // frame the drain just wrote unpainted.
        #expect(fx.contains { if case .setLayerFrame = $0 { return true }; return false })
    }

    // Every other way a session can end

    @Test func aCommandMidGestureTakesTheViewportAndDropsTheLatch() {
        let (open, _) = Self.gesturing(Self.world())
        let (dragged, _) = Engine.reduce(open, .trackpadScrolled(by: -0.2))
        #expect(Self.offset(dragged).current == 2400)

        let (commanded, _) = Engine.reduce(dragged, .command(.focus(.left)))
        #expect(commanded.trackpadScroll == .idle)
        #expect(Self.offset(commanded).target != 2400)          // the hotkey aimed it somewhere

        // Everything behind the command is inert, in either order.
        let aimed = Self.offset(commanded).target
        let (after, fx) = EngineFix.run(commanded, [.trackpadScrolled(by: -0.5),
                                                    .trackpadScrollEnded(velocity: -2)])
        #expect(Self.offset(after).target == aimed)
        #expect(fx.isEmpty)
    }

    @Test func aReconfigurationDropsTheLatchWithTheSession() {
        let (open, _) = Self.gesturing(Self.world())
        let (dragged, _) = Engine.reduce(open, .trackpadScrolled(by: -0.2))

        let moved = MonitorInfo(id: Self.monitor, frame: Rect(x: 0, y: 0, width: 1200, height: 800))
        let (after, fx) = Engine.reduce(dragged, .screensChanged([moved]))
        #expect(after.trackpadScroll == .idle)
        #expect(!after.motion.isTransitioning)
        #expect(Self.placements(fx) > 0)                        // the ground moved; everything re-places

        // A sample arriving behind it moves nothing.
        let (later, tail) = Engine.reduce(after, .trackpadScrolled(by: -0.5))
        #expect(Self.offset(later).current == Self.offset(after).current)
        #expect(tail.isEmpty)
    }

    @Test func aCoverThatCouldNotBeMadeDropsTheLatchWithTheSession() {
        // Still `.capturing`, so the abort path rather than the close path — and the offset accumulates
        // through the capture head regardless, which is what leaves something to re-place here.
        let (began, _) = Engine.reduce(Self.world(), .trackpadScrollBegan)
        #expect(began.trackpadScroll == .dragging(Self.monitor))
        let (dragged, _) = Engine.reduce(began, .trackpadScrolled(by: -0.2))
        #expect(Self.offset(dragged).current == 2400)

        let (after, fx) = Engine.reduce(dragged, .coverUnavailable(Self.monitor))
        #expect(after.trackpadScroll == .idle)
        #expect(!after.motion.isTransitioning)
        // No pixels to hide a write, so the desktop is put where the fingers left it, in the open.
        #expect(Self.placements(fx) > 0)

        let (later, tail) = Engine.reduce(after, .trackpadScrolled(by: -0.5))
        #expect(Self.offset(later).current == Self.offset(after).current)
        #expect(tail.isEmpty)
    }

    @Test func aHoldTimeoutDropsTheLatchToo() {
        let (open, _) = Self.gesturing(Self.world())
        let (dragged, _) = Engine.reduce(open, .trackpadScrolled(by: -0.2))
        let (after, _) = Engine.reduce(dragged, .holdTimeout(Self.monitor))
        #expect(after.trackpadScroll == .idle)
        #expect(!after.motion.isTransitioning)
    }

    // Focus follows on settle, and only when it has to

    @Test func focusStaysPutWhenItsColumnIsStillOnScreen() {
        let (open, _) = Self.gesturing(Self.world())
        let focused = open.world.focusedWindow
        // A nudge the magnet takes straight back to the edge it came from.
        let (dragged, _) = Engine.reduce(open, .trackpadScrolled(by: -0.05))
        let (lifted, fx) = Engine.reduce(dragged, .trackpadScrollEnded(velocity: 0))
        #expect(Self.offset(lifted).target == 3000)
        #expect(Self.focuses(fx).isEmpty)
        #expect(lifted.world.focusedWindow == focused)
    }

    @Test func scrollingAwayTakesFocusToTheMostCentralColumn() {
        let (open, _) = Self.gesturing(Self.world())
        // Down to 900, which the magnet takes to 1000 — the second column's own edge.
        let (dragged, _) = Engine.reduce(open, .trackpadScrolled(by: -0.7))
        #expect(Self.offset(dragged).current == 900)

        let (lifted, fx) = Engine.reduce(dragged, .trackpadScrollEnded(velocity: 0))
        #expect(Self.offset(lifted).target == 1000)
        #expect(Self.focuses(fx) == [WindowId(2)])
        #expect(lifted.world.focusedWindow == WindowId(2))
    }

    /// The regression that would otherwise be found by hand: a magnetized rest is the first aim in
    /// emira that is not itself a minimal reveal, so the echo of its own `.focus` must not re-derive one.
    @Test func theSettlesOwnFocusEchoDoesNotUndoTheMagnet() {
        let (open, _) = Self.gesturing(Self.world())
        let (dragged, _) = Engine.reduce(open, .trackpadScrolled(by: -0.7))
        let (lifted, _) = Engine.reduce(dragged, .trackpadScrollEnded(velocity: 0))
        #expect(Self.offset(lifted).target == 1000)

        let (echoed, fx) = Engine.reduce(lifted, .focusChanged(WindowId(2), origin: .ours))
        #expect(Self.offset(echoed).target == 1000)
        #expect(!fx.contains { if case .capture = $0 { return true }; return false })
        // …and the same offset survives the glide it was aimed with.
        let (settled, _) = EngineFix.drive(echoed)
        #expect(Self.offset(settled).current == 1000)
    }

    // Modes and refusals

    @Test func snapTakesTheLiftWhereTheFingersLeftItWithNoProjection() {
        let (open, _) = Self.gesturing(Self.world(mode: .free, transition: .snap))
        let (dragged, _) = Engine.reduce(open, .trackpadScrolled(by: -0.2))
        #expect(Self.offset(dragged).current == 2400)
        // A throw is motion inherited from the hand, and `snap` is the mode that refuses motion.
        let (lifted, _) = Engine.reduce(dragged, .trackpadScrollEnded(velocity: -2))
        #expect(Self.offset(lifted).target == 2400)
        #expect(Self.offset(lifted).velocity == 0)
    }

    @Test func snapStillTracksTheFingersUnderTheCover() {
        let (open, _) = Self.gesturing(Self.world(mode: .magnet, transition: .snap))
        let (dragged, fx) = Engine.reduce(open, .trackpadScrolled(by: -0.1))
        #expect(Self.offset(dragged).current == 2700)
        #expect(Self.placements(fx) == 0)
    }

    /// The clamp lives in `applyEnvironment`, so this is the reducer declining to be a second opinion
    /// about it rather than the setting's own story.
    @Test func withNoCoverToRunUnderTheGestureIsRefused() {
        let (s, fx) = Engine.reduce(Self.world(transition: .off), .trackpadScrollBegan)
        #expect(s.trackpadScroll == .idle)
        #expect(fx.isEmpty)
    }

    @Test func withTheSettingOffNothingLatches() {
        let (s, fx) = Engine.reduce(Self.world(mode: .off), .trackpadScrollBegan)
        #expect(s.trackpadScroll == .idle)
        #expect(fx.isEmpty)
    }

    @Test func aSecondBeginWhileAHandIsDownChangesNothing() {
        let (open, _) = Self.gesturing(Self.world())
        let (again, fx) = Engine.reduce(open, .trackpadScrollBegan)
        #expect(again.trackpadScroll == .dragging(Self.monitor))
        #expect(fx.isEmpty)
    }

    @Test func aLiftWithNoHandOnItIsInert() {
        let s = Self.world()
        let (after, fx) = Engine.reduce(s, .trackpadScrollEnded(velocity: -3))
        #expect(Self.offset(after).target == Self.offset(s).target)
        #expect(fx.isEmpty)
    }

    // Which way a swipe carries the strip

    /// `standard` is a scrollbar: the viewport follows your fingers, so the columns slide the other way.
    /// `natural` is macOS's own convention on this axis — the content comes with you.
    @Test func naturalReversesTheDrag() {
        let (standard, _) = Self.gesturing(Self.world(mode: .free))
        let (draggedRight, _) = Engine.reduce(standard, .trackpadScrolled(by: +0.1))
        #expect(Self.offset(draggedRight).current == 3000)      // already at maxOffset; it tried to go up

        let (natural, _) = Self.gesturing(Self.world(mode: .free, direction: .natural))
        let (draggedLeft, _) = Engine.reduce(natural, .trackpadScrolled(by: +0.1))
        #expect(Self.offset(draggedLeft).current == 2700)       // the same swipe, the other way
    }

    /// The lift's velocity converts through the **same** expression as its travel, which is the whole
    /// reason there is one conversion: a distance and a velocity that disagreed about which way is
    /// forward would throw the projection off the wrong end of the strip.
    @Test func naturalReversesTheProjectionWithIt() {
        let (open, _) = Self.gesturing(Self.world(mode: .free, direction: .natural))
        let (dragged, _) = Engine.reduce(open, .trackpadScrolled(by: +0.2))
        #expect(Self.offset(dragged).current == 2400)

        // ω = 10, so +0.5 of a pad per second throws 150 points — *backwards* down the strip.
        let (lifted, _) = Engine.reduce(dragged, .trackpadScrollEnded(velocity: +0.5))
        #expect(Self.offset(lifted).target == 2250)
        #expect(Self.offset(lifted).velocity == -0.5 * Self.unit)
    }

    /// …and the magnet chooses off that same projection, so the edge it picks flips too.
    @Test func naturalPicksTheMagnetEdgeOnTheOtherSide() {
        let (open, _) = Self.gesturing(Self.world(direction: .natural))
        let (dragged, _) = Engine.reduce(open, .trackpadScrolled(by: +0.7))
        #expect(Self.offset(dragged).current == 900)

        let (lifted, fx) = Engine.reduce(dragged, .trackpadScrollEnded(velocity: 0))
        #expect(Self.offset(lifted).target == 1000)
        #expect(Self.focuses(fx) == [WindowId(2)])
    }

    @Test func standardIsTheDefaultAndTheSignIsTheWholeSetting() {
        #expect(Config().trackpadScrollDirection == .standard)
        #expect(TrackpadScrollDirection.standard.sign == 1)
        #expect(TrackpadScrollDirection.natural.sign == -1)
    }

    @Test func centeringMagnetizesOntoColumnCentresInstead() {
        let (open, _) = Self.gesturing(Self.world(centered: true))
        let (dragged, _) = Engine.reduce(open, .trackpadScrolled(by: -0.2))
        let (lifted, _) = Engine.reduce(dragged, .trackpadScrollEnded(velocity: 0))
        // A full-width column centres at its own left edge, so the candidates are still 0…3000 — but
        // unclamped, which is what centering at the strip's ends means.
        #expect(Self.offset(lifted).target == 2000)
    }
}
