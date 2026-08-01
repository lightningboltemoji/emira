import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// The fourth animated quantity — `Motion.focusRing`, the guide's ring as a displacement from the
// focused window's own frame. Everything here is about what it must *not* touch: the ring is the only
// animated quantity nothing else derives from, so it is outside `isSettled` (the transition's close
// gate) and outside `retargetGeneration` (the shell's hold deadline), and it survives the close.

@Suite struct GuideRingTests {

    static let display = Rect(x: 0, y: 0, width: 1000, height: 800)

    /// One full-width column per window, so a focus change genuinely scrolls and the two frames a ring
    /// is measured between are a screen apart.
    static func config(_ style: GuideStyle) -> Config {
        Config(widthPresets: PresetCycle([.proportion(1.0)]),
               guide: GuideSettings(style: style))
    }

    static func world(_ count: UInt64, style: GuideStyle = .placeholder) -> State {
        EngineTests.world(count, config: config(style))
    }

    static func focus(_ s: State, _ direction: Direction) -> (State, [Effect]) {
        Engine.reduce(s, .command(.focus(direction)))
    }

    /// Tick until the ring has arrived — `EngineTests.settle` stops at the transition, which the ring
    /// deliberately outlives.
    static func settleRing(_ start: State) -> State {
        var s = start
        for _ in 0..<2000 where s.motion.needsFrames {
            s = Engine.reduce(s, .tick(dt: 1.0 / 120)).0
        }
        return s
    }

    // MARK: - The ring travels, and arrives

    @Test func aFocusChangeSeedsTheRingWithTheTravelBetweenTwoWindows() {
        let s = Self.settleRing(Self.world(2))
        #expect(s.motion.isFocusRingSettled)                // arrived, from the second window's arrival
        let (moved, _) = Self.focus(s, .left)
        // Two full-width columns on a 1000 pt display: the ring starts a whole screen away from the
        // window it now belongs to, and decays to zero from there.
        #expect(moved.motion.focusRing != nil)
        #expect(abs(moved.motion.focusRingDisplacement.minX - 1000) < Motion.settleEpsilon)
        #expect(moved.motion.focusRingDisplacement.width == 0)   // same-size columns: no size travel
    }

    @Test func anArrivalMovesTheRingToo() {
        // A newcomer takes focus, so the ring travels to it — the arrival is a focus change like any
        // other, which is the whole reason `trackFocusRing` sits at the tail of `reduce`.
        let s = Self.settleRing(Self.world(1))
        let (arrived, fx) = Engine.reduce(s, .windowCreated(EngineTests.snapshot(2)))
        _ = fx
        #expect(arrived.motion.focusRing != nil)
        #expect(!arrived.motion.isFocusRingSettled)
    }

    @Test func theRingSettlesAndTheClockGateFollowsItDown() {
        let (moved, fx) = Self.focus(Self.world(2), .left)
        #expect(moved.motion.needsFrames)
        var s = EngineTests.settle(moved, fx)
        // `settle` stops as soon as the transition closes; the ring outlives it, so tick on.
        for _ in 0..<600 where s.motion.needsFrames {
            s = Engine.reduce(s, .tick(dt: 1.0 / 120)).0
        }
        #expect(!s.motion.needsFrames)
        #expect(abs(s.motion.focusRingDisplacement.minX) < Motion.settleEpsilon)
    }

    @Test func aRefocusMidFlightCarriesTheRingsVelocityThrough() {
        let (first, _) = Self.focus(Self.world(3), .left)
        var s = first
        for _ in 0..<10 { s = Engine.reduce(s, .tick(dt: 1.0 / 120)).0 }
        let inFlight = try? #require(s.motion.focusRing)
        #expect(inFlight != nil)
        let speed = s.motion.focusRing.map { abs($0.x.velocity) } ?? 0
        #expect(speed > 0)                                  // genuinely moving before the interrupt

        let (again, _) = Self.focus(s, .left)
        // `nudge`, not a rebuild: the second travel is *added* to the ground still uncovered, and the
        // velocity already carried survives. A rebuilt animator would start from rest.
        #expect((again.motion.focusRing.map { abs($0.x.velocity) } ?? 0) >= speed)
        #expect(again.motion.focusRingDisplacement.minX > s.motion.focusRingDisplacement.minX)
    }

    // MARK: - The three traps

    @Test func aTravellingRingDoesNotHoldTheCoverUp() {
        // The ring is a guide decoration; `isReadyToClose` is the cross-fade. A session with every
        // animator arrived and every set landed is ready to close *however far the ring still has to go*.
        var motion = Motion()
        motion.openTransition(scope: [WindowId(1)])
        motion.markCaptured(WindowId(1))
        motion.raiseCover()
        motion.confirmCover()
        motion.markLanded(WindowId(1))
        motion.nudgeFocusRing(by: Rect(x: 900, y: 0, width: 0, height: 0), params: .smooth)

        #expect(!motion.isFocusRingSettled)                 // a long way from home…
        #expect(motion.isSettled)                           // …and `isSettled` never saw it
        #expect(motion.isReadyToClose)                      // …so the cross-fade is not blocked
    }

    @Test func aRingNudgeDoesNotRearmTheHoldDeadline() {
        // `retargetGeneration` drives `Runtime.syncHold`. A focus change that only moves the ring must
        // not be able to extend a hung transition's deadline.
        var motion = Motion()
        let before = motion.retargetGeneration
        motion.nudgeFocusRing(by: Rect(x: 400, y: 0, width: 0, height: 0), params: .smooth)
        motion.advanceFocusRing(by: 1.0 / 120)
        motion.clearFocusRing()
        #expect(motion.retargetGeneration == before)
    }

    @Test func theRingSurvivesClosingTheTransition() {
        var motion = Motion()
        motion.openTransition(scope: [WindowId(1)])
        motion.nudgeFocusRing(by: Rect(x: 400, y: 0, width: 0, height: 0), params: .smooth)
        motion.displaceWindow(WindowId(1), by: Rect(x: 400, y: 0, width: 0, height: 0))
        motion.closeTransition()
        // Widths and displacements are dropped with the session; the ring belongs to the guide.
        #expect(motion.windowAnimators.isEmpty)
        #expect(motion.focusRing != nil)
        #expect(motion.needsFrames)                         // …and still asks for frames with no session
    }

    // MARK: - The clock gate

    @Test func aFocusChangeThatScrollsNothingStillAsksForFrames() {
        // Two half-width columns share one screen, so focusing across them scrolls nothing and opens no
        // transition — the case the ring needs `needsFrames` for.
        let config = Config(widthPresets: PresetCycle([.proportion(0.5)]),
                            guide: GuideSettings(style: .placeholder))
        let s = EngineTests.world(2, config: config)
        let (moved, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(!moved.motion.isTransitioning)              // nothing scrolled
        #expect(moved.motion.needsFrames)                   // and the clock runs anyway
    }

    @Test func aTickAdvancesTheRingWithNoCoverInSight() {
        // Half-width columns share one screen, so this focus change opens no session at all — the tick
        // has nothing but the ring to move, and moves it.
        let config = Config(widthPresets: PresetCycle([.proportion(0.5)]),
                            guide: GuideSettings(style: .placeholder))
        let s = Self.settleRing(EngineTests.world(2, config: config))
        let (moved, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(!moved.motion.isCovered)
        let started = moved.motion.focusRingDisplacement.minX
        let (ticked, effects) = Engine.reduce(moved, .tick(dt: 1.0 / 60))
        #expect(effects.isEmpty)                            // no cover ⇒ no layer frames
        #expect(ticked.motion.focusRingDisplacement.minX < started)
    }

    // MARK: - Off

    @Test func theGuideOffCreatesNoRingAtAll() {
        let (moved, _) = Self.focus(Self.world(2, style: .off), .left)
        #expect(moved.motion.focusRing == nil)
        #expect(moved.motion.needsFrames == moved.motion.isTransitioning)
    }

    @Test func turningTheGuideOffClearsARingAlreadyInFlight() {
        let (moved, _) = Self.focus(Self.world(2), .left)
        #expect(moved.motion.focusRing != nil)
        var off = moved.config
        off.guide.style = .off
        let (reloaded, _) = Engine.reduce(moved, .configChanged(off))
        #expect(reloaded.motion.focusRing == nil)
    }

    @Test func focusLeavingEveryManagedWindowDropsTheRing() {
        let (moved, _) = Self.focus(Self.world(2), .left)
        #expect(moved.motion.focusRing != nil)
        let (blurred, _) = Engine.reduce(moved, .focusChanged(nil, origin: .system))
        #expect(blurred.motion.focusRing == nil)
    }
}
