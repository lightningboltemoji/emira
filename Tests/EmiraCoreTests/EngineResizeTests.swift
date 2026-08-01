import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// Resizing a column: the animated preset cycle, the continuous `grow`/`shrink`, and the
// detent that catches a neighbour on the way past.

@Suite struct EngineResizeTests {

    /// Two columns, 500 + 450 in a 1000-wide viewport, the left one focused: 50 pt of slack at the right
    /// edge, so one `grow 10%` is three times what it takes to go flush.
    static func detentPair(detent: Bool = true) -> State {
        let config = Config(widthPresets: PresetCycle([.proportion(0.5)]), resizeDetent: detent,
                            transitionMode: .off)
        var s = EngineFix.world(2, config: config)
        s.layout.setWidthOverride(.proportion(0.45), ofColumn: s.layout.columns[1].id)
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))
        return EngineFix.settle(s)
    }

    /// Whether the strip shows column `i` whole, where the viewport is coming to rest.
    static func showsWhole(_ s: State, _ i: Int) -> Bool {
        s.layout.strip(metrics: s.metrics()!)
            .isFullyVisible(i, viewportWidth: 1000, offset: s.motion.viewportOffset.target)
    }

    /// `cycleWidth`, end to end. The strip's own geometry changes, so the viewport-offset scalar cannot
    /// express it and the column's *resolved width* goes under its own spring — a transition opens even
    /// though the viewport never moves.
    ///
    /// Two ⅓-width columns on a 1000-wide display: 333⅓ each. Cycling col1 to ½ makes it 500 wide.
    @Test func cycleWidthOpensATransitionEvenThoughTheViewportNeverMoves() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),          // focused, column 1
        ])
        let column = s.layout.columns[1].id
        #expect(EngineFix.approxScalar(s.layout.strip(metrics: s.metrics()!).columnWidths[1], 1000.0 / 3.0))

        let (c, cfx) = Engine.reduce(s, .command(.cycleWidth))
        s = c
        #expect(s.motion.isTransitioning)                          // …despite zero viewport motion
        #expect(s.motion.viewportOffset.target == 0)
        #expect(s.motion.viewportOffset.current == 0)
        #expect(s.layout.columns[1].widthPreset == 1)              // ⅓ → ½, stored immediately
        #expect(Set(EngineFix.capturedIds(in: cfx)) == Set([WindowId(1), WindowId(2)]))
        // The width animator starts at the width being left behind, not the one being arrived at.
        #expect(EngineFix.approxScalar(s.motion.columnWidth(column)?.current ?? 0, 1000.0 / 3.0))
        #expect(s.motion.columnWidth(column)?.target == 500)
        #expect(!s.motion.isSettled)                               // …and it holds the cover up

        // Raise, then the cover on screen: the *real* window is resized to its final width at once,
        // behind it — only the owning app can produce resized pixels, so there is nothing to animate on
        // the truth plane.
        var fx: [Effect] = []
        for w in s.motion.transition?.windows ?? [] {
            let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; fx += f
        }
        let teleports: [Effect]
        (s, teleports) = Engine.reduce(s, .coverOnScreen)
        fx += teleports
        #expect(s.motion.isCovered)
        #expect(EngineFix.placement(of: WindowId(2), in: fx)?.width == 500)
        #expect(EngineFix.placement(of: WindowId(1), in: fx) == nil)    // untouched: left of the resize
        #expect(s.motion.transition?.awaitingLanding == Set([WindowId(2)]))

        // …while the *layer* grows across frames — the scaled still cross-fades over the reflow.
        let layer = try! #require(s.motion.transition?.layerId(for: WindowId(2)))
        var mid: [Effect] = []
        for _ in 0..<5 { let (n, f) = Engine.reduce(s, .tick(dt: 1.0 / 120)); s = n; mid += f }
        let growing = try! #require(EngineFix.layerFrame(of: layer, in: mid))
        #expect(growing.width > 1000.0 / 3.0 + 1)
        #expect(growing.width < 500)
        #expect(growing.minX == 1000.0 / 3.0)                      // anchored at the column's left edge

        // Land + settle: the layer converges onto the real window's frame, then the cover comes down.
        let (done, dfx) = EngineFix.drive(s)
        #expect(done.motion.isTransitioning == false)
        #expect(dfx.contains(.endTransition))
        #expect(done.motion.currentColumnWidths.isEmpty)           // the override is dropped, not kept
        #expect(done.layout.strip(metrics: done.metrics()!).columnWidths[1] == 500)
    }

    /// Every column to the right of a resize slides, and nothing choreographs that — it falls out of
    /// the strip accumulating the animated width. Three ⅓ columns; growing the *middle* one pushes the
    /// third along by exactly what the second gained.
    @Test func columnsRightOfAResizeSlideInLockstepWithIt() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(2), origin: .system))      // focus the middle column, no scroll
        #expect(s.motion.isTransitioning == false)

        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and the display shows it
        let l2 = try! #require(s.motion.transition?.layerId(for: WindowId(2)))
        let l3 = try! #require(s.motion.transition?.layerId(for: WindowId(3)))

        var fx: [Effect] = []
        for _ in 0..<5 { let (n, f) = Engine.reduce(s, .tick(dt: 1.0 / 120)); s = n; fx += f }
        let grown = try! #require(EngineFix.layerFrame(of: l2, in: fx))
        let pushed = try! #require(EngineFix.layerFrame(of: l3, in: fx))
        #expect(grown.width > 1000.0 / 3.0 + 1)                    // the middle column is mid-growth…
        #expect(grown.width < 500)
        // …and col2 starts where col1 ends, at every instant of the motion.
        #expect(EngineFix.approxScalar(pushed.minX, grown.maxX))
        #expect(pushed.minX > 1000.0 * 2 / 3 + 1)                  // i.e. strictly past where it was
        #expect(pushed.width == 1000.0 / 3.0)                      // …at its own, unchanged width
    }

    /// Why the scope is a union of two geometries: a column can be on screen *before* the resize and
    /// swept by nothing *after* it, because a growing neighbour pushes it off the right edge. Scoping on
    /// the new geometry alone would leave it sliding out of view with no layer, i.e. a hole.
    ///
    /// ¼/full presets on a 1000-wide display. Four 250-wide columns all on screen at offset 0; cycling
    /// col1 to full evicts cols 2 *and* 3 — two, deliberately, so one lands outside the shoulder the
    /// sweep already carries and only the two-geometry union can account for it.
    @Test func aResizeScopesTheColumnItPushesOffTheScreen() {
        let config = Config(widthPresets: PresetCycle([.proportion(0.25), .proportion(1.0)]))
        var (s, _) = EngineFix.run(EngineFix.booted(config: config), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
            .windowCreated(EngineFix.snapshot(4)),
        ])
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(2), origin: .system))
        #expect(EngineFix.approxScalar(s.motion.viewportOffset.current, 0))
        #expect(s.layout.visibleWindowIds(scrollOffset: 0, metrics: s.metrics()!)
                == [WindowId(1), WindowId(2), WindowId(3), WindowId(4)])

        let (c, cfx) = Engine.reduce(s, .command(.cycleWidth))
        s = c
        // Under the *new* geometry the viewport holds col1 alone; the sweep and its shoulders reach
        // only as far as w3. w4 is scoped and captured purely because it was on screen under the *old*
        // geometry and has to be drawn on its way out.
        #expect(s.layout.sweptWindowIds(from: 0, to: s.motion.viewportOffset.target,
                                        metrics: s.metrics()!)
                == [WindowId(1), WindowId(2), WindowId(3)])
        #expect(s.motion.transition?.windows                                  // layout order = z-order
                == [WindowId(1), WindowId(2), WindowId(3), WindowId(4)])
        #expect(EngineFix.capturedIds(in: cfx)
                == [WindowId(1), WindowId(2), WindowId(3), WindowId(4)])

        let (done, _) = EngineFix.drive(s)
        #expect(done.motion.isTransitioning == false)
        #expect(done.layout.strip(metrics: done.metrics()!).columnWidths == [250, 1000, 250, 250])
    }

    /// A resize arriving mid-scroll joins the open session rather than opening a second one — the same
    /// rule every other interrupt follows, now with two different animated quantities in flight at once.
    @Test func aResizeMidScrollRidesTheOpenSession() {
        // Full-width columns so a focus change genuinely scrolls, and a second preset so there is
        // something to cycle to (`fullWidth` has one preset, i.e. nothing a resize could change).
        let config = Config(widthPresets: PresetCycle([.proportion(1.0), .proportion(0.5)]))
        var (s, _) = EngineFix.run(EngineFix.booted(config: config), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))         // scroll w3 → w2, offset 2000 → 1000
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and the display shows it
        for _ in 0..<6 { (s, _) = Engine.reduce(s, .tick(dt: 1.0 / 120)) }
        let scrolling = s.motion.viewportOffset.velocity
        #expect(scrolling != 0)
        #expect(s.motion.currentColumnWidths.isEmpty)              // a scroll animates no widths

        let (r, _) = Engine.reduce(s, .command(.cycleWidth))
        #expect(r.motion.isTransitioning)                          // still exactly one session…
        #expect(r.motion.isCovered)                                // …under the same raised cover
        #expect(r.motion.viewportOffset.velocity == scrolling)     // the scroll is undisturbed
        #expect(r.motion.currentColumnWidths.count == 1)           // …and now a width travels with it

        let (done, _) = EngineFix.drive(r)
        #expect(done.motion.isTransitioning == false)
        #expect(done.motion.currentColumnWidths.isEmpty)
    }

    /// With no Screen Recording grant the resize still happens, at once: the column ends up exactly the
    /// width the animated path would have converged on.
    @Test func withTransitionOffAResizeHappensAtOnce() {
        var config = Config()
        config.transitionMode = .off
        var (s, _) = EngineFix.run(EngineFix.booted(config: config), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        let (c, cfx) = Engine.reduce(s, .command(.cycleWidth))
        s = c
        #expect(!s.motion.isTransitioning)
        #expect(s.motion.currentColumnWidths.isEmpty)
        #expect(!EngineFix.hasEffect(cfx) { if case .capture = $0 { return true }; return false })
        #expect(EngineFix.placement(of: WindowId(2), in: cfx)?.width == 500)
    }

    /// `grow` is `cycleWidth`'s motion with different arithmetic in front of it: the same width spring,
    /// the same transition over a viewport that never moves.
    @Test func growAnimatesTheColumnWidthExactlyAsACycleDoes() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [.windowCreated(EngineFix.snapshot(1))])
        let column = s.layout.columns[0].id

        let (g, gfx) = Engine.reduce(s, .command(.grow(.points(100))))
        s = g
        #expect(s.motion.isTransitioning)                       // …despite zero viewport motion
        #expect(s.motion.viewportOffset.target == 0)
        #expect(EngineFix.approxScalar(s.motion.columnWidth(column)?.current ?? 0, EngineFix.third))
        #expect(EngineFix.approxScalar(s.motion.columnWidth(column)?.target ?? 0, EngineFix.third + 100))
        #expect(EngineFix.capturedIds(in: gfx) == [WindowId(1)])

        let (done, dfx) = EngineFix.drive(s)
        #expect(dfx.contains(.endTransition))
        #expect(EngineFix.approxScalar(EngineFix.placement(of: WindowId(1), in: dfx)?.width ?? 0,
                                       EngineFix.third + 100))
        #expect(EngineFix.approxScalar(EngineFix.width(done), EngineFix.third + 100))
        #expect(done.motion.currentColumnWidths.isEmpty)        // the override is dropped, not kept
    }

    /// A percentage is of the working area, not of the current width — so steps are uniform however wide
    /// the column already is and the two verbs are exact inverses. Under the compounding reading the
    /// round trip would land 1% short of where it began.
    @Test func aPercentageIsOfTheWorkingAreaSoTheStepsAreUniformAndTheVerbsInvert() {
        var s = EngineFix.oneThirdSnap()                             // 1000-wide working area ⇒ 10% = 100 pt
        let start = EngineFix.width(s)

        for step in 1...3 {
            (s, _) = Engine.reduce(s, .command(.grow(.percent(10))))
            #expect(EngineFix.approxScalar(EngineFix.width(s), start + 100 * Double(step)),
                    "step \(step): \(EngineFix.width(s))")
        }
        for step in stride(from: 2, through: 0, by: -1) {
            (s, _) = Engine.reduce(s, .command(.shrink(.percent(10))))
            #expect(EngineFix.approxScalar(EngineFix.width(s), start + 100 * Double(step)))
        }
        #expect(EngineFix.approxScalar(EngineFix.width(s), start))         // …back exactly, not 1% short
    }

    /// The unit the user typed is the unit that is stored, which is what makes a percentage track the
    /// monitor the way a preset does while points stay points (`ColumnLayout.widthOverride`).
    @Test func theStoredIntentKeepsTheUnitItWasAskedIn() throws {
        var s = EngineFix.oneThirdSnap()
        (s, _) = Engine.reduce(s, .command(.grow(.percent(10))))
        guard case .proportion(let share) = try #require(s.layout.columns[0].widthOverride) else {
            Issue.record("a percentage stored something other than a proportion"); return
        }
        #expect(EngineFix.approxScalar(share, EngineFix.third / 1000 + 0.1, tol: 1e-9))

        (s, _) = Engine.reduce(s, .command(.grow(.points(100))))
        guard case .fixed(let points) = try #require(s.layout.columns[0].widthOverride) else {
            Issue.record("points stored something other than a fixed width"); return
        }
        #expect(EngineFix.approxScalar(points, EngineFix.third + 200))
    }

    /// Bounded above by 100% of the working area, and a `grow` that has nothing left to give is silent —
    /// no transition, no AX set, not even a redundant re-place.
    @Test func growIsBoundedByTheWorkingWidth() {
        var s = EngineFix.oneThirdSnap()
        (s, _) = Engine.reduce(s, .command(.grow(.percent(500))))
        #expect(EngineFix.width(s) == 1000)

        let (again, fx) = Engine.reduce(s, .command(.grow(.points(100))))
        #expect(EngineFix.width(again) == 1000)
        #expect(fx.isEmpty)
        #expect(!again.motion.isTransitioning)
    }

    /// Bounded below by `minimumColumnWidth` — the backstop for apps that accept any size at all, where
    /// there is no `SizeCorrection` to discover a real floor from.
    @Test func shrinkIsBoundedByAMinimumWidth() {
        var s = EngineFix.oneThirdSnap()
        (s, _) = Engine.reduce(s, .command(.shrink(.points(1000))))
        #expect(EngineFix.width(s) == Engine.minimumColumnWidth)

        let (again, fx) = Engine.reduce(s, .command(.shrink(.percent(1))))
        #expect(EngineFix.width(again) == Engine.minimumColumnWidth)
        #expect(fx.isEmpty)
        // …and the way back out is immediate: a clamp that stopped the resize stored nothing to undo.
        let (grown, _) = Engine.reduce(again, .command(.grow(.points(50))))
        #expect(EngineFix.width(grown) == Engine.minimumColumnWidth + 50)
    }

    /// The clamp can stop a resize; it may never reverse one. A config that deliberately asks for
    /// columns wider than the screen (`width-presets = [1.5]`) is honored by `Presets`, so a `grow` that
    /// clamped to the working width would answer "wider, please" with a sudden 500 pt *shrink*.
    @Test func aClampNeverMovesAColumnTheWayItWasNotAsked() {
        let config = Config(widthPresets: PresetCycle([.proportion(1.5)]), transitionMode: .off)
        var s = EngineFix.run(EngineFix.booted(config: config), [.windowCreated(EngineFix.snapshot(1))]).0
        #expect(EngineFix.width(s) == 1500)

        let (grown, fx) = Engine.reduce(s, .command(.grow(.points(100))))
        #expect(EngineFix.width(grown) == 1500)                       // stopped…
        #expect(fx.isEmpty)                                      // …and silent about it
        (s, _) = Engine.reduce(s, .command(.shrink(.points(100))))
        #expect(EngineFix.width(s) == 1400)                           // …while the other way still moves
    }

    /// The press that would evict a neighbour stops where it goes flush; the next one means it, and
    /// spends the whole delta. Nothing is remembered between the two — the first press left the strip
    /// *in* the notch, and that is what the second one reads.
    @Test func growCatchesAtFlushAndTheNextPressPushesPast() {
        var s = Self.detentPair()
        #expect(Self.showsWhole(s, 1))

        (s, _) = Engine.reduce(s, .command(.grow(.percent(10))))
        #expect(EngineFix.approxScalar(EngineFix.width(s, 0), 550))         // 50 of the 100 asked for
        #expect(Self.showsWhole(s, 1))                            // …the neighbour kept, exactly flush

        (s, _) = Engine.reduce(s, .command(.grow(.percent(10))))
        #expect(EngineFix.approxScalar(EngineFix.width(s, 0), 650))         // …and now the whole 100
        #expect(!Self.showsWhole(s, 1))                           // 100 pt of it off screen
    }

    /// The way back in, on the same notch: a shrink stops where the column it cut comes back whole. Without
    /// it the packed strip would be a configuration you can only pass through, never land on.
    @Test func shrinkCatchesWhereTheCutColumnComesBackWhole() {
        var s = Self.detentPair()
        (s, _) = Engine.reduce(s, .command(.grow(.percent(10))))
        (s, _) = Engine.reduce(s, .command(.grow(.percent(10))))
        #expect(EngineFix.approxScalar(EngineFix.width(s, 0), 650))

        (s, _) = Engine.reduce(s, .command(.shrink(.percent(20))))
        #expect(EngineFix.approxScalar(EngineFix.width(s, 0), 550))         // 100 of the 200 asked for
        #expect(Self.showsWhole(s, 1))

        (s, _) = Engine.reduce(s, .command(.shrink(.percent(20))))
        #expect(EngineFix.approxScalar(EngineFix.width(s, 0), 350))         // …and past it, the whole 200
    }

    /// Off — the default — a delta is the delta, and the neighbour goes off screen on the first press.
    @Test func withoutTheDetentAGrowSpendsTheWholeDelta() {
        var s = Self.detentPair(detent: false)
        (s, _) = Engine.reduce(s, .command(.grow(.percent(10))))
        #expect(EngineFix.approxScalar(EngineFix.width(s, 0), 600))
        #expect(!Self.showsWhole(s, 1))
    }

    /// The ladder is exempt. A preset is an exact intent — ½ has to stay ½ — so `cycleWidth` steps past
    /// the notch the continuous knob would have caught on.
    @Test func theWidthLadderIgnoresTheDetent() {
        let config = Config(widthPresets: PresetCycle([.proportion(0.5), .proportion(0.9)]),
                            resizeDetent: true, transitionMode: .off)
        var s = EngineFix.world(2, config: config)
        s.layout.setWidthOverride(.proportion(0.45), ofColumn: s.layout.columns[1].id)
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))

        (s, _) = Engine.reduce(EngineFix.settle(s), .command(.cycleWidth))
        #expect(EngineFix.approxScalar(EngineFix.width(s, 0), 900))          // not 550
    }

    /// Centred, the viewport travels half the width with the column, so both its edges close in at half
    /// speed and the nearer one decides. 320 + 320 + 200 with a 10 pt gap leaves 140 at the right edge but
    /// only 10 at the left once the middle column is centred — a notch the uncentred strip doesn't have.
    @Test func aCentredResizeCatchesOnTheEdgeTheUncentredOneNeverReaches() {
        func trio(centered: Bool) -> State {
            let config = Config(widthPresets: PresetCycle([.proportion(0.32)]), columnGap: 10,
                                centerFocusedColumn: centered, resizeDetent: true,
                                transitionMode: .off)
            var s = EngineFix.world(3, config: config)
            s.layout.setWidthOverride(.proportion(0.20), ofColumn: s.layout.columns[2].id)
            (s, _) = Engine.reduce(s, .focusChanged(WindowId(2), origin: .system))
            return EngineFix.settle(s)
        }

        var (centred, plain) = (trio(centered: true), trio(centered: false))
        (centred, _) = Engine.reduce(centred, .command(.grow(.percent(10))))
        (plain, _) = Engine.reduce(plain, .command(.grow(.percent(10))))

        #expect(EngineFix.approxScalar(EngineFix.width(centred, 1), 340))    // caught by the left edge, at 2 × 10
        #expect(EngineFix.approxScalar(EngineFix.width(plain, 1), 420))      // 140 of room to the right: uncaught
    }

    /// A failed shrink stops at the app's own floor and converges there. There is no public attribute for
    /// a minimum, so all we have is what the app answered to the question we asked; taking each delta
    /// from the *resolved* width rather than the stored intent makes that a fixed point, not a dead zone.
    @Test func aRefusedShrinkSettlesAtTheAppsFloorAndGrowStillMovesAtOnce() {
        var s = EngineFix.oneThirdSnap()                              // 333⅓
        /// The app under test: it will not go below 300 pt wide.
        func refuseBelow300(_ s: inout State, _ fx: [Effect]) {
            guard let asked = EngineFix.placement(of: WindowId(1), in: fx), asked.width < 300 else { return }
            var landed = asked
            landed.size = Size(width: 300, height: asked.height)
            (s, _) = Engine.reduce(s, .placementCorrected(WindowId(1), requested: asked, actual: landed))
        }

        // Every press asks. An app's limits are usually a property of what it is currently showing, so a
        // refusal is a cache of one answer rather than a standing fact: a resize verb retires it and
        // genuinely re-asks, and the column springs out and back each time.
        for press in 1...3 {
            let (next, fx) = Engine.reduce(s, .command(.shrink(.points(100))))
            s = next
            #expect(EngineFix.placement(of: WindowId(1), in: fx) != nil, "press \(press) asked nothing")
            refuseBelow300(&s, fx)
            #expect(EngineFix.width(s) == 300, "press \(press)")      // the column is built around the answer
        }

        // …and growing out of the floor works on the first press — no dead zone to walk back through.
        (s, _) = Engine.reduce(s, .command(.grow(.points(100))))
        #expect(EngineFix.width(s) == 400)
    }

    /// Why it re-asks instead of bouncing: change tabs and the same app will accept a width it just
    /// refused, and nothing reports that. Here the limit lifts between presses and the very next `grow`
    /// succeeds, with nothing having told emira anything changed.
    @Test func aWindowWhoseLimitLiftsGrowsOnTheNextPress() {
        var s = EngineFix.oneThirdSnap()
        var limit = 500.0
        /// The app under test: it accepts any width up to `limit` and answers `limit` above it.
        func answer(_ s: inout State, _ fx: [Effect]) {
            guard let asked = EngineFix.placement(of: WindowId(1), in: fx), asked.width > limit else { return }
            var landed = asked
            landed.size = Size(width: limit, height: asked.height)
            (s, _) = Engine.reduce(s, .placementCorrected(WindowId(1), requested: asked, actual: landed))
        }

        var (next, fx) = Engine.reduce(s, .command(.grow(.points(300))))      // 333⅓ → asks 633⅓
        s = next
        answer(&s, fx)
        #expect(EngineFix.width(s) == 500)                             // built around what it allows

        (next, fx) = Engine.reduce(s, .command(.grow(.points(300))))          // 500 → asks 800
        s = next
        #expect(EngineFix.placement(of: WindowId(1), in: fx)?.width == 800)        // it really asks again…
        answer(&s, fx)
        #expect(EngineFix.width(s) == 500)                             // …and is really refused again

        limit = 5000                                              // the user switches tabs
        (next, fx) = Engine.reduce(s, .command(.grow(.points(300))))
        s = next
        answer(&s, fx)
        #expect(EngineFix.width(s) == 800)                             // no longer refused, so it grows
    }

    /// The ladder and the continuous knob are alternatives, and `cycle-width` is how you get back on the
    /// ladder: it clears the override and takes the next rung after wherever the ladder was left — not a
    /// guess at which rung the grown width was nearest.
    @Test func cycleWidthClearsAGrowAndResumesTheLadder() {
        let config = Config(transitionMode: .off)            // ⅓ / ½ / ⅔
        var s = EngineFix.run(EngineFix.booted(config: config), [.windowCreated(EngineFix.snapshot(1))]).0

        (s, _) = Engine.reduce(s, .command(.grow(.points(200))))
        #expect(s.layout.columns[0].widthOverride != nil)
        #expect(EngineFix.approxScalar(EngineFix.width(s), EngineFix.third + 200))

        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        #expect(s.layout.columns[0].widthOverride == nil)
        #expect(s.layout.columns[0].widthPreset == 1)            // ⅓ → ½, from where the ladder was
        #expect(EngineFix.width(s) == 500)
    }

    /// An expelled window keeps the width it is on screen at, override included — otherwise a grown
    /// column would silently snap back to its ladder rung as a side effect of a structural edit.
    @Test func anExpelledWindowCarriesItsGrownWidthIntoItsNewColumn() {
        let config = Config(transitionMode: .off)
        var s = EngineFix.run(EngineFix.booted(config: config), [.windowCreated(EngineFix.snapshot(1))]).0
        (s, _) = Engine.reduce(s, .command(.grow(.points(200))))
        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(2)))
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // w2 joins w1's column
        #expect(s.layout.columns.count == 1)

        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.right)))  // …and pops back out
        #expect(s.layout.columns.count == 2)
        #expect(s.layout.columns.allSatisfy { $0.widthOverride == .fixed(EngineFix.third + 200) })
    }

    /// Total against a world with nothing to resize, like every other command.
    @Test func growAndShrinkWithNothingFocusedAreSilent() {
        for command in [Command.grow(.points(100)), .shrink(.percent(10))] {
            let (s, fx) = Engine.reduce(EngineFix.booted(), .command(command))
            #expect(fx.isEmpty)
            #expect(s.layout.isEmpty)
        }
    }

    /// After any command settles, the viewport is inside the strip it describes. Every scroll target
    /// derives from the same column widths a correction changes, so a session that keeps the destination
    /// it was given travels to a place computed for a strip that no longer exists — which the user sees
    /// as phantom desktop tacked onto the side after a refused `grow`.
    @Test func aRefusedResizeNeverLeavesTheViewportPastTheStripsEnd() {
        let config = Config(widthPresets: PresetCycle([.proportion(1.0 / 3.0)]), columnGap: 8)
        var (s, _) = EngineFix.run(EngineFix.booted(config: config), [
            .windowCreated(EngineFix.snapshot(1)), .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = EngineFix.drive(s)

        /// The stubborn app: w3 answers ⅓ of the working width to every question, in either direction.
        func refuse(_ fx: [Effect]) {
            guard let asked = EngineFix.placement(of: WindowId(3), in: fx),
                  abs(asked.width - EngineFix.third) > 0.5 else { return }
            var landed = asked
            landed.size = Size(width: EngineFix.third, height: asked.height)
            (s, _) = Engine.reduce(s, .placementCorrected(WindowId(3), requested: asked, actual: landed))
        }

        for command: Command in [.grow(.points(300)), .focus(.left), .focus(.right),
                                 .grow(.points(300)), .shrink(.points(100)),
                                 .grow(.points(300)), .grow(.points(300))] {
            var (next, fx) = Engine.reduce(s, .command(command))
            s = next
            for w in s.motion.transition?.windows ?? [] {
                (next, _) = Engine.reduce(s, .captureReady(w))
                s = next
            }
            (next, fx) = Engine.reduce(s, .coverOnScreen)       // …which is what carries the teleports
            s = next
            refuse(fx)
            (s, _) = EngineFix.drive(s)

            let metrics = s.metrics()!
            let offset = s.motion.viewportOffset.current
            let end = s.layout.clampScrollOffset(offset, metrics: metrics)
            #expect(EngineFix.approxScalar(offset, end),
                    "after \(command): viewport at \(offset), strip ends at \(end)")
            // …and the column is always the width the window will actually be, never the one it refused.
            #expect(EngineFix.approxScalar(EngineFix.width(s, 2), EngineFix.third), "after \(command)")
        }
    }

}
