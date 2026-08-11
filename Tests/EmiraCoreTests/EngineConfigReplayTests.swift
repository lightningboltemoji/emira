import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// The config file reaching a running daemon, and the state dump replaying faithfully.

@Suite struct EngineConfigReplayTests {

    /// The observable effect of editing the file: the strip is re-resolved against the new metrics
    /// and every window re-placed, with no window having moved and no command having been given.
    @Test func aConfigReloadRelaysOutInPlace() {
        // Fixed-width columns, so both stay on screen and the gap really is the only thing that moves —
        // a *proportional* width is a share of the gap too, and re-resolves with it (below).
        let narrow = Config(widthPresets: PresetCycle([.fixed(250)]))
        let (s, _) = EngineFix.run(EngineFix.booted(config: narrow), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        var gapped = narrow
        gapped.columnGap = 40
        let (next, fx) = Engine.reduce(s, .configChanged(gapped))
        #expect(next.config.columnGap == 40)
        #expect(EngineFix.approx(EngineFix.placement(of: WindowId(2), in: fx) ?? .zero,
                                 Rect(x: 290, y: 0, width: 250, height: 800)))
        // The first column's target didn't change, so it isn't re-sent: a reload re-places only what
        // the new geometry actually moved, and touching an app over AX is never free.
        #expect(EngineFix.placement(of: WindowId(1), in: fx) == nil)
        #expect(EngineFix.approx(next.world.windows[WindowId(1)]?.frame ?? .zero,
                                 Rect(x: 0, y: 0, width: 250, height: 800)))
    }

    /// `column-gap` is not only spacing: a proportion is a share of the extent *and* the gap, so raising
    /// it narrows every proportional column to keep the ladder's arithmetic exact. Both columns are
    /// therefore re-placed, which is the one way this reload differs from the fixed-width one above.
    @Test func raisingTheColumnGapReResolvesProportionalWidths() {
        let quarters = Config(widthPresets: PresetCycle([.proportion(0.25)]))
        let (s, _) = EngineFix.run(EngineFix.booted(config: quarters), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        #expect(EngineFix.approxScalar(EngineFix.width(s, 0), 250))     // ¼ of 1000, no gap to fold

        var gapped = quarters
        gapped.columnGap = 40
        let (next, fx) = Engine.reduce(s, .configChanged(gapped))
        // ¼ of (1000 + 40) less the gap it carries = 220, so four of them and three gaps still make 1000.
        #expect(EngineFix.approxScalar(EngineFix.width(next, 0), 220))
        #expect(EngineFix.approx(EngineFix.placement(of: WindowId(1), in: fx) ?? .zero,
                                 Rect(x: 0, y: 0, width: 220, height: 800)))
        #expect(EngineFix.approx(EngineFix.placement(of: WindowId(2), in: fx) ?? .zero,
                                 Rect(x: 260, y: 0, width: 220, height: 800)))
    }

    /// The spring is *seeded* into the animator at construction, so storing the new config isn't
    /// enough — a file that only changed the feel would otherwise take effect at the next daemon
    /// start rather than the next scroll.
    @Test func aConfigReloadRetunesTheLiveScrollSpring() {
        let s = EngineFix.booted()
        var slower = Config()
        slower.scrollSpring = SpringParams(stiffness: 100, dampingRatio: 1.0)
        let (next, _) = Engine.reduce(s, .configChanged(slower))
        #expect(next.viewport.offset.params.stiffness == 100)
    }

    /// A reload mid-scroll must not snap the viewport out from under a raised cover — the same rule
    /// `reveal` already keeps for every other snap-path event.
    @Test func aConfigReloadMidTransitionRedirectsRatherThanSnapping() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in s.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen(MonitorId(1)))               // …and the display shows it
        (s, _) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(s.motion.isTransitioning)
        let mid = s.viewport.offset.current

        var gapped = EngineFix.fullWidth
        gapped.columnGap = 12
        let (after, _) = Engine.reduce(s, .configChanged(gapped))
        // Still one session, still travelling from where it was — not teleported to the new target.
        #expect(after.motion.isTransitioning)
        #expect(after.viewport.offset.current == mid)
    }

    /// `cycleWidth` animates the *resize* spring, which exists so it can differ from the scroll's.
    @Test func aResizeUsesTheResizeSpring() {
        var config = Config(widthPresets: PresetCycle([.proportion(0.5), .proportion(1.0)]))
        config.resizeSpring = SpringParams(stiffness: 123, dampingRatio: 1.0)
        var (s, _) = EngineFix.run(EngineFix.booted(config: config), [.windowCreated(EngineFix.snapshot(1))])
        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        let column = s.layout.columns.first!.id
        #expect(s.motion.columnWidth(column)?.params.stiffness == 123)
    }

    @Test func stateRoundTripsThroughCodable() throws {
        let (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(State.self, from: data)
        #expect(back == s)
    }

    @Test func replayingAnEventLogReproducesStateExactly() {
        // The deterministic-replay payoff: the same event log through a fresh Engine → same state.
        let events: [Event] = [
            .screensChanged([MonitorInfo(id: MonitorId(1), frame: EngineFix.displayFrame)]),
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .command(.focus(.left)),
            .windowCreated(EngineFix.snapshot(3)),
            // Structural edits mint `ColumnId`s, so replay only reproduces if the allocator watermark
            // is state rather than a fresh count.
            .command(.consumeOrExpel(.left)),
            .command(.moveWindow(.right)),
            .windowDestroyed(WindowId(2)),
            .command(.centerColumn),
        ]
        let (a, fxA) = EngineFix.run(State(), events)
        let (b, fxB) = EngineFix.run(State(), events)
        #expect(a == b)
        #expect(fxA == fxB)
    }

}
