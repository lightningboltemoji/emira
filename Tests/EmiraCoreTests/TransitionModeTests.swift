import Foundation
import Testing
@testable import EmiraCore

// `[animation] transition`: whether a transition is covered, and whether it animates under the cover.
//
// `off` and `smooth` are the two ends the rest of the suite already drives — every fixture spelled
// `transitionMode: .off` is the first, and the animated-scroll section of `EngineTests` is the second.
// What is asserted here is the middle one, and the claim it rests on: **`snap` is the cover without the
// clock.** The reducer opens a session and creates no animator, so the cover is raised painting the
// finished strip, and it comes down on the AX sets alone — no tick has to happen for a snap transition
// to complete, and none of them does anything if it does.
//
// The pairs against `smooth` carry the file: the two modes must agree about *where* every window ends
// up and disagree only about what is on screen in between.

@Suite struct TransitionModeTests {

    // MARK: - Fixtures

    /// One full-width column *is* the viewport, so every focus change across columns genuinely scrolls —
    /// `EngineTests.fullWidth`'s reason, which is what makes a transition open at all.
    static func fullWidth(_ mode: TransitionMode) -> Config {
        Config(widthPresets: PresetCycle([.proportion(1.0)]), transitionMode: mode)
    }

    /// Three full-width columns at rest, focused on w3.
    static func world(_ mode: TransitionMode) -> State {
        let (s, _) = EngineTests.run(EngineTests.booted(config: fullWidth(mode)), [
            .windowCreated(EngineTests.snapshot(1)),
            .windowCreated(EngineTests.snapshot(2)),
            .windowCreated(EngineTests.snapshot(3)),
        ])
        return s
    }

    /// Answer every capture the session is waiting on — the step that raises the cover.
    static func completeCaptures(_ s: State) -> (State, [Effect]) {
        var s = s
        var fx: [Effect] = []
        for w in s.motion.transition?.windows ?? [] {
            let (next, out) = Engine.reduce(s, .captureReady(w))
            s = next
            fx += out
        }
        return (s, fx)
    }

    // MARK: - The cover goes up

    /// The distinction from `off`, which is the whole point of having three modes rather than two: a
    /// snapped scroll is still covered, so the AX latency happens behind pixels instead of on screen.
    @Test func snapCapturesAndRaisesACover() {
        var s = Self.world(.snap)
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .command(.focus(.left)))

        #expect(s.motion.isTransitioning, "snap opens a session; only off declines one")
        #expect(!EngineTests.capturedIds(in: fx).isEmpty)

        let raised: [Effect]
        (s, raised) = Self.completeCaptures(s)
        #expect(s.motion.isCovered)
        #expect(EngineTests.hasEffect(raised) { if case .beginTransition = $0 { return true }; return false })
    }

    // MARK: - …with no clock under it

    /// The mechanism, asserted directly: no animator is ever created, which is what makes every gate that
    /// reads `isSettled` answer yes from the session's first instant.
    @Test func snapPutsNothingInMotion() {
        var s = Self.world(.snap)
        (s, _) = Engine.reduce(s, .command(.focus(.left)))

        #expect(s.motion.windowAnimators.isEmpty)
        #expect(s.motion.columnWidths.isEmpty)
        #expect(s.motion.isSettled, "the scroll is already at its target, so nothing is in flight")
        #expect(EngineTests.approxScalar(s.motion.viewportOffset.current,
                                         s.motion.viewportOffset.target))
    }

    /// The visible claim. The cover's first blit is the *finished* strip — `emitLayerFrames` reads the
    /// viewport's `.current`, which a snapped aim has already put at the destination. Under `smooth` the
    /// same blit is the strip as it stands, and the springs carry it the rest of the way.
    @Test func aSnappedCoverIsBlittedAtTheFinishedGeometry() {
        var snap = Self.world(.snap)
        (snap, _) = Engine.reduce(snap, .command(.focus(.left)))       // w3 → w2, target offset 1000
        let snapRaise: [Effect]
        (snap, snapRaise) = Self.completeCaptures(snap)

        let layer = try! #require(snap.motion.layerId(for: WindowId(2)))
        let framed = try! #require(EngineTests.layerFrame(of: layer, in: snapRaise))
        // w2 is the column being revealed: at rest it fills the viewport from the working-area origin.
        #expect(EngineTests.approx(framed, Rect(x: 0, y: 0, width: 1000, height: 800)))

        // The same instant under `smooth`: the cover goes up on the strip as it *was* — the viewport is
        // still on w3, so w2 is a full screen off to the left — and only then starts moving.
        var smooth = Self.world(.smooth)
        (smooth, _) = Engine.reduce(smooth, .command(.focus(.left)))
        let smoothRaise: [Effect]
        (smooth, smoothRaise) = Self.completeCaptures(smooth)

        let smoothLayer = try! #require(smooth.motion.layerId(for: WindowId(2)))
        let smoothFramed = try! #require(EngineTests.layerFrame(of: smoothLayer, in: smoothRaise))
        #expect(EngineTests.approx(smoothFramed, Rect(x: -1000, y: 0, width: 1000, height: 800)))
    }

    /// A tick is not part of a snapped transition's story: the cover closes on the AX sets alone, so the
    /// frame clock can spin or not without changing the outcome. (`Runtime` still runs it — the session
    /// is open — which is why the reducer has to be inert rather than merely unused.)
    @Test func aSnappedTransitionClosesWithoutATick() {
        var s = Self.world(.snap)
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        (s, _) = Self.completeCaptures(s)
        #expect(s.motion.isCovered)

        var fx: [Effect] = []
        for w in s.motion.transition?.awaitingLanding ?? [] {
            let (next, out) = Engine.reduce(s, .axLanded(w))
            s = next
            fx += out
        }

        #expect(!s.motion.isTransitioning, "landings alone close it — no tick was fed")
        #expect(fx.contains(.endTransition))
        #expect(EngineTests.approxScalar(s.motion.viewportOffset.current, 1000))
    }

    /// The tick guard, from the other side: a covered-but-settled tick repeats no frame and emits
    /// nothing. Every tick of a snapped transition is this one.
    @Test func aTickUnderASnappedCoverEmitsNothing() {
        var s = Self.world(.snap)
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        (s, _) = Self.completeCaptures(s)

        let (ticked, tfx) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(tfx.isEmpty, "nothing is in motion, so there is no new frame to blit")
        #expect(ticked.motion.isCovered, "and it does not close either — the reals have not landed")
    }

    // MARK: - The placement invariant

    /// What all three modes owe: the same resting world. A mode decides what is on screen during the
    /// transition and nothing else — if snap and smooth disagreed here, one of them would be laying out
    /// a different strip rather than animating the same one differently.
    @Test func everyModeComesToRestInTheSamePlace() {
        var resting: [TransitionMode: Double] = [:]
        var frames: [TransitionMode: Rect] = [:]
        for mode in TransitionMode.allCases {
            var s = Self.world(mode)
            let fx: [Effect]
            (s, fx) = Engine.reduce(s, .command(.focus(.left)))
            s = EngineTests.settle(s, fx)
            resting[mode] = s.motion.viewportOffset.current
            frames[mode] = s.world.windows[WindowId(2)]?.frame
        }
        #expect(EngineTests.approxScalar(resting[.snap] ?? -1, resting[.smooth] ?? -2))
        #expect(EngineTests.approxScalar(resting[.off] ?? -1, resting[.smooth] ?? -2))
        #expect(EngineTests.approx(frames[.snap] ?? .zero, frames[.smooth] ?? .zero))
        #expect(EngineTests.approx(frames[.off] ?? .zero, frames[.smooth] ?? .zero))
    }

    // MARK: - The other two things a transition covers

    /// A resize under `snap` leaves the width out of `Motion` entirely, and an absent width animator
    /// resolves to the preset the layout now holds — so the cover paints the finished width rather than
    /// travelling to it. The still inside that rect was filmed at the old width, which is the one place
    /// snap is visibly a compromise: `animation.window` decides how it is painted, and it is held rather
    /// than passed through.
    @Test func aSnappedResizeIsCoveredAtTheFinalWidth() {
        let ladder = Config(widthPresets: PresetCycle([.proportion(0.5), .proportion(1.0)]),
                            transitionMode: .snap)
        var s = EngineTests.world(2, config: ladder)
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .command(.cycleWidth))

        #expect(s.motion.isTransitioning, "a resize is covered under snap")
        #expect(s.motion.columnWidths.isEmpty, "…but the width itself is never animated")
        #expect(!EngineTests.capturedIds(in: fx).isEmpty)
    }

    /// A structural edit under `snap` must still raise a cover, which is the branch that has to count the
    /// windows it would have displaced without displacing them: an edit that moves nobody on screen needs
    /// no cover under any mode, and reading that count off an empty animator set would make *every*
    /// snapped edit look invisible.
    @Test func aSnappedStructuralEditIsStillCovered() {
        var s = EngineTests.world(3, config: Config(widthPresets: PresetCycle([.proportion(0.5)]),
                                                    transitionMode: .snap))
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .command(.moveWindow(.left)))

        #expect(s.motion.isTransitioning, "the strip rearranged where someone can see it")
        #expect(s.motion.windowAnimators.isEmpty, "…and nothing was put in motion to show it")
        #expect(!EngineTests.capturedIds(in: fx).isEmpty)
    }
}
