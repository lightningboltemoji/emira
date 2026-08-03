import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// Windows that do not land where they are put: the app that refuses our width, and the
// one that refuses to be parked behind a nub.

@Suite struct EngineRefusalTests {

    /// A state with two tiled windows, both already placed at their targets.
    static func twoColumns() -> State {
        EngineFix.run(EngineFix.booted(), [.windowCreated(EngineFix.snapshot(1)),
                                           .windowCreated(EngineFix.snapshot(2))]).0
    }

    /// A world with one window parked at a nub, plus that window and the slot it was sent to. Four
    /// ⅓-width columns on a 1000 pt viewport: three fit, the fourth is scrolled off and parks.
    static func parkedWorld() -> (State, WindowId, Rect) {
        let s = EngineFix.world(4)
        let frames = s.workspaces.targetFrames(shown: s.monitors.shownWorkspaces,
                                               scrollOffset: s.motion.viewportOffset.current,
                                               metrics: s.metrics()!)
        let parked = s.workspaces.allWindowIds.first { !s.world.placedOnScreen.contains($0) }
        let id = try! #require(parked, "the fixture is meant to leave a window parked")
        return (s, id, try! #require(frames[id]))
    }

    /// A window that keeps `chrome` points of itself on screen, whatever the slot asked for.
    static func clamped(_ slot: Rect, keeping chrome: Double, in s: State) -> Rect {
        Rect(x: slot.minX, y: s.metrics()!.workingArea.maxY - chrome,
             width: slot.width, height: slot.height)
    }

    @Test func aClampedTiledLandingWidensItsColumnAndPushesTheNeighbourAlong() {
        // w1's app refuses 333⅓ and takes 500; without a record of that, `Layout` keeps col1 at 333⅓ and
        // the two real windows *overlap* by 167 pt — the one thing the strip promises never happens.
        var s = Self.twoColumns()
        let asked = Rect(x: 0, y: 0, width: EngineFix.third, height: 800)
        let got = Rect(x: 0, y: 0, width: 500, height: 800)

        let (next, fx) = Engine.reduce(s, .placementCorrected(WindowId(1), requested: asked, actual: got))
        s = next

        // The answer is recorded against the question it answers.
        let correction = try! #require(s.world.corrections[WindowId(1)])
        #expect(correction.actual == Size(width: 500, height: 800))
        #expect(EngineFix.approxScalar(correction.wanted.width, EngineFix.third))
        // …and the column is now built around it.
        #expect(s.layout.resolvedWidth(ofColumn: s.layout.columns[0].id, metrics: s.metrics()!) == 500)
        // w1 is already at the answer, so nothing is asked of it again; w2 slides right by the 167 pt
        // w1 took, which is derived — the strip accumulates from the same widths.
        #expect(EngineFix.placement(of: WindowId(1), in: fx) == nil)
        let moved = try! #require(EngineFix.placement(of: WindowId(2), in: fx))
        #expect(EngineFix.approx(moved, Rect(x: 500, y: 0, width: EngineFix.third, height: 800)))
    }

    @Test func aCorrectedWindowIsNeverAskedTheSameQuestionAgain() {
        // The convergence claim: one round of writes, then silence. Without the record the diff never
        // matches and every subsequent placement re-issues the same doomed set, forever.
        var s = Self.twoColumns()
        (s, _) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: EngineFix.third, height: 800),
            actual: Rect(x: 0, y: 0, width: 500, height: 800)))

        let (_, again) = Engine.reduce(s, .dragEnded)      // any re-place trigger
        #expect(again.isEmpty)
    }

    @Test func aNarrowerAnswerNarrowsTheColumnToWhatTheWindowCanBe() {
        // An under-filled column is not merely cosmetic: a column's width is strip extent, so the
        // shortfall is desktop that scroll targets, tile-vs-park and the sweep all treat as content.
        // The column follows the answer down, and quiescence comes free — the target *is* the window.
        var s = Self.twoColumns()
        let narrow = Rect(x: 0, y: 0, width: EngineFix.third - 8, height: 800)
        let (next, _) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: EngineFix.third, height: 800), actual: narrow))
        s = next

        let width = try! #require(s.layout.resolvedWidth(ofColumn: s.layout.columns[0].id,
                                                         metrics: s.metrics()!))
        #expect(EngineFix.approxScalar(width, EngineFix.third - 8))              // …to what it can be
        let (_, again) = Engine.reduce(s, .dragEnded)
        #expect(EngineFix.placement(of: WindowId(1), in: again) == nil)     // and goes quiet
    }

    /// The recursion guard: a narrower answer teaches only when it answered the *question*. Otherwise an
    /// app that always returns a little less would walk the column toward nothing, one placement at a
    /// time. At most one narrowing per question.
    @Test func anAppThatAlwaysReturnsLessCannotWalkTheColumnDown() {
        var s = Self.twoColumns()
        let question = EngineFix.third

        // First refusal, given to the question itself: learned, and the column follows.
        (s, _) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: question, height: 800),
            actual: Rect(x: 0, y: 0, width: question - 8, height: 800)))
        #expect(EngineFix.approxScalar(EngineFix.width(s), question - 8))

        // Every later refusal answers a request we made *because* of the first one, so it teaches
        // nothing — the column holds, rather than stepping down 8 pt per event forever.
        for step in 1...5 {
            (s, _) = Engine.reduce(s, .placementCorrected(
                WindowId(1), requested: Rect(x: 0, y: 0, width: question - 8, height: 800),
                actual: Rect(x: 0, y: 0, width: question - 8 - Double(step) * 8, height: 800)))
            #expect(EngineFix.approxScalar(EngineFix.width(s), question - 8), "step \(step)")
        }

        // …while the *widening* direction keeps learning unconditionally, because too wide overlaps a
        // neighbour and that is the invariant the strip promises.
        (s, _) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: question - 8, height: 800),
            actual: Rect(x: 0, y: 0, width: 500, height: 800)))
        #expect(EngineFix.approxScalar(EngineFix.width(s), 500))
    }

    @Test func aReportThatAnswersAQuestionNobodyIsAskingRecordsTruthAndTeachesNothing() {
        // The write went out and the layout moved on before the ack came back. Recording this would
        // key an answer to a question that was never asked, which is exactly how a learned minimum
        // ratchets. Truth is still recorded — it is where the window is.
        var s = Self.twoColumns()
        let stale = Rect(x: 0, y: 0, width: 220, height: 800)      // nothing on this strip wants 200
        let (next, fx) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: 200, height: 800), actual: stale))
        s = next

        #expect(fx.isEmpty)
        #expect(s.world.corrections.isEmpty)
        #expect(s.world.windows[WindowId(1)]?.frame == stale)      // …but reality is reality
    }

    @Test func positionOnlyDriftIsNotAFactAboutSize() {
        // A window that went somewhere else at the size we asked is telling us about *position*.
        // That is a real and separate problem (the 1 px park sliver is one) and it never overlaps a
        // neighbour, so nothing about the column's geometry follows from it.
        var s = Self.twoColumns()
        let asked = Rect(x: 0, y: 0, width: EngineFix.third, height: 800)
        let elsewhere = Rect(x: 0, y: 40, width: EngineFix.third, height: 800)
        let (next, _) = Engine.reduce(s, .placementCorrected(WindowId(1), requested: asked, actual: elsewhere))
        s = next

        #expect(s.world.corrections.isEmpty)
        #expect(s.world.windows[WindowId(1)]?.frame == elsewhere)
    }

    @Test func externalDriftNeverBecomesAConstraint() {
        // `windowFrameChanged` is the user dragging, and a *parked* landing (`AXExecutor` splits them
        // deliberately). Neither knows what question it answers, so neither may teach.
        var s = Self.twoColumns()
        (s, _) = Engine.reduce(s, .windowFrameChanged(WindowId(1), Rect(x: 700, y: 500, width: 60, height: 60)))
        #expect(s.world.corrections.isEmpty)
    }

    @Test func aCorrectionIsForgottenWithItsWindow() {
        var s = Self.twoColumns()
        (s, _) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: EngineFix.third, height: 800),
            actual: Rect(x: 0, y: 0, width: 500, height: 800)))
        #expect(s.world.corrections.count == 1)

        (s, _) = Engine.reduce(s, .windowDestroyed(WindowId(1)))
        #expect(s.world.corrections.isEmpty)   // a stale answer must not greet the next window to reuse
    }

    @Test func aClampedParkTeachesTheChromeTheWindowKept() {
        // Safari will not keep less than its toolbar on screen: sent to a 40 pt nub it lands showing 52,
        // and the slot it refused is the one every later placement would ask for again.
        var (s, id, slot) = Self.parkedWorld()
        let refused = Self.clamped(slot, keeping: 52, in: s)

        let (next, fx) = Engine.reduce(s, .parkCorrected(id, requested: slot, actual: refused))
        s = next

        #expect(s.world.parkFloors[id] == 52)
        // Re-parked at once, at a slot that clears the floor — rounded up onto the stagger lattice, so
        // 56 rather than the 52 it asked for.
        let reparked = try! #require(EngineFix.placement(of: id, in: fx))
        #expect(reparked.minY == s.metrics()!.workingArea.maxY - 56)
        #expect(reparked.size == slot.size)                 // a park still never resizes
    }

    @Test func aSlotThatClearsTheFloorIsNeverAskedForTwice() {
        // The defect, stated as the property that kills it: a park the app clamps used to be re-issued
        // on *every* placement pass — a `dragEnded`, a focus change, an arrival — because the window was
        // never where the layout said and nothing recorded why. One session logged 27 identical parks
        // of one Safari window.
        var (s, id, slot) = Self.parkedWorld()
        var fx: [Effect] = []
        (s, fx) = Engine.reduce(s, .parkCorrected(id, requested: slot, actual: Self.clamped(slot, keeping: 52, in: s)))

        // The app accepts the taller nub, and the world holds it.
        let reparked = try! #require(EngineFix.placement(of: id, in: fx))
        (s, _) = Engine.reduce(s, .axLanded(id))
        #expect(s.world.windows[id]?.frame == reparked)

        // Every later pass is silent about it.
        for _ in 0..<3 {
            let (next, quiet) = Engine.reduce(s, .dragEnded)
            s = next
            #expect(EngineFix.placement(of: id, in: quiet) == nil)
        }
    }

    @Test func theSameRefusalTwiceDoesNotTradeWritesWithTheApp() {
        // An app that lands where it likes however tall a nub we offer would otherwise have us re-place
        // on every report of the same news. The floor is already recorded; asking again asks the
        // identical question.
        var (s, id, slot) = Self.parkedWorld()
        let refused = Self.clamped(slot, keeping: 52, in: s)
        (s, _) = Engine.reduce(s, .parkCorrected(id, requested: slot, actual: refused))

        let (next, fx) = Engine.reduce(s, .parkCorrected(id, requested: slot, actual: refused))
        #expect(fx.isEmpty)
        #expect(next.world.windows[id]?.frame == refused)   // truth is still recorded
    }

    @Test func aParkAnswerIsNeverAFactAboutSize() {
        // The other half of "a park teaches nothing": a window can refuse a resize at its sliver that it
        // accepts once scrolled back into view, so recording the size would freeze the column at
        // whatever width it happened to be parked at.
        var (s, id, slot) = Self.parkedWorld()
        let refused = Rect(x: slot.minX, y: slot.minY - 12, width: slot.width - 90, height: slot.height)

        (s, _) = Engine.reduce(s, .parkCorrected(id, requested: slot, actual: refused))

        #expect(s.world.corrections.isEmpty)
        #expect(s.world.parkFloors[id] == 52)               // the chrome half is still evidence
    }

    @Test func aWindowThatMovedSidewaysIsNotStatingAFloor() {
        // An app that put itself somewhere else entirely is refusing to park rather than answering how
        // much of itself it keeps on screen, and a lot that only allocates chrome has nothing to learn
        // from it.
        var (s, id, slot) = Self.parkedWorld()
        let elsewhere = Rect(x: 200, y: 300, width: slot.width, height: slot.height)

        (s, _) = Engine.reduce(s, .parkCorrected(id, requested: slot, actual: elsewhere))

        #expect(s.world.parkFloors.isEmpty)
        #expect(s.world.windows[id]?.frame == elsewhere)    // truth first, as ever
    }

    @Test func aParkFloorIsForgottenWithItsWindow() {
        var (s, id, slot) = Self.parkedWorld()
        (s, _) = Engine.reduce(s, .parkCorrected(id, requested: slot, actual: Self.clamped(slot, keeping: 52, in: s)))
        #expect(s.world.parkFloors.count == 1)

        (s, _) = Engine.reduce(s, .windowDestroyed(id))
        #expect(s.world.parkFloors.isEmpty)   // a stale answer must not greet the next window to reuse
    }

    @Test func aCorrectionUnderARaisedCoverSpringsTheColumnRatherThanJumpingIt() {
        // Every layer frame is re-derived from the strip's geometry each tick, so a column that
        // changes width between two frames *jumps*. Under a cover the change goes under the resize
        // spring — the same quantity `cycleWidth` animates, retargeted in place.
        var s = Self.twoColumns()
        var fx: [Effect] = []
        (s, _) = Engine.reduce(s, .command(.cycleWidth))          // col1 (focused, w2): ⅓ → ½ = 500
        let column = s.layout.columns[1].id
        #expect(s.motion.columnWidth(column)?.target == 500)

        for w in s.motion.transition?.windows ?? [] {
            let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; fx += f
        }
        (s, _) = Engine.reduce(s, .coverOnScreen)
        #expect(s.motion.isCovered)

        // The app takes 600 instead of the 500 it was just teleported to.
        let (next, _) = Engine.reduce(s, .placementCorrected(
            WindowId(2), requested: Rect(x: EngineFix.third, y: 0, width: 500, height: 800),
            actual: Rect(x: EngineFix.third, y: 0, width: 600, height: 800)))
        s = next

        // Retargeted, not restarted: the layer keeps travelling from wherever it had got to.
        #expect(s.motion.columnWidth(column)?.target == 600)
        #expect(!s.motion.isSettled)

        // …and it converges on the width the real window actually took, so the cross-fade has nothing
        // to pop against.
        let (done, _) = EngineFix.drive(s)
        #expect(!done.motion.isTransitioning)
        #expect(done.layout.strip(metrics: done.metrics()!).columnWidths[1] == 600)
    }

    @Test func cycleWidthAnimatesFromTheCorrectedWidthNotThePreset() {
        // A column an app has already widened *is* at the corrected width, so starting the spring at
        // the raw preset would begin the motion somewhere the layers are not — a visible jump on the
        // first frame of every resize of a stubborn window.
        var s = Self.twoColumns()
        (s, _) = Engine.reduce(s, .placementCorrected(
            WindowId(2), requested: Rect(x: EngineFix.third, y: 0, width: EngineFix.third, height: 800),
            actual: Rect(x: EngineFix.third, y: 0, width: 400, height: 800)))
        let column = s.layout.columns[1].id
        #expect(s.layout.resolvedWidth(ofColumn: column, metrics: s.metrics()!) == 400)

        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        #expect(s.motion.columnWidth(column)?.current == 400)    // where it actually is…
        #expect(s.motion.columnWidth(column)?.target == 500)     // …to the ½ preset, a fresh question
    }

    @Test func aTallerAnswerFloorsTheWindowInItsColumnAndTheStackmateRedivides() {
        // The vertical axis, reachable through `consume-or-expel`: two windows in one column are each
        // asked for half its height, and an app that refuses gets its floor while its stackmate takes
        // what is left.
        var s = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidthSnap),
                              [.windowCreated(EngineFix.snapshot(1)), .windowCreated(EngineFix.snapshot(2))]).0
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // w2 joins w1's column
        #expect(s.layout.columns.count == 1)

        let asked = try! #require(s.layout.targetFrames(scrollOffset: 0, metrics: s.metrics()!)[WindowId(2)])
        #expect(asked.height == 400)                                  // 800 split two ways, no gaps
        var taller = asked
        taller.size.height = 500
        (s, _) = Engine.reduce(s, .placementCorrected(WindowId(2), requested: asked, actual: taller))

        let frames = s.layout.targetFrames(scrollOffset: 0, metrics: s.metrics()!)
        #expect(frames[WindowId(1)]?.height == 300)                   // the stackmate re-divides…
        #expect(frames[WindowId(2)]?.height == 500)                   // …around the floor
        #expect(s.layout.resolvedWidth(ofColumn: s.layout.columns[0].id, metrics: s.metrics()!) == 500)
    }

    @Test func aShorterAnswerCapsTheWindowAndTheLayoutStopsAskingItToGrow() {
        // The other direction, which used to be recorded and then never consulted: a window that will
        // not *grow* (Digital Color Meter is fixed in both axes) answered 200 to a full-height slot,
        // and the layout went on handing it 800 forever. Every placement was a resize the app refused
        // again, and — the visible half — every scroll back into view animated a layer from the 200 pt
        // still it was captured at to an 800 pt slot, which is the stretch that reads as "expanding".
        var s = Self.twoColumns()
        let asked = Rect(x: 0, y: 0, width: EngineFix.third, height: 800)
        let short = Rect(x: 0, y: 0, width: EngineFix.third, height: 200)

        let (next, fx) = Engine.reduce(s, .placementCorrected(WindowId(1), requested: asked, actual: short))
        s = next

        // The answer is now a *ceiling*, keyed to the question like the width answer beside it.
        let correction = try! #require(s.world.corrections[WindowId(1)])
        #expect(correction.heightBound(forQuestion: 800) == .atMost(200))
        // The column is built around it: the slot is the height the window actually is…
        let frames = s.layout.targetFrames(scrollOffset: 0, metrics: s.metrics()!)
        #expect(frames[WindowId(1)]?.height == 200)
        // …on the presentation plane too, so the layer holding its still has nothing left to stretch.
        #expect(s.layout.naturalFrames(scrollOffset: 0, metrics: s.metrics()!)[WindowId(1)]?.height == 200)
        // …and it is already there, so it is not asked again — now, or on any later re-place.
        #expect(fx.isEmpty)
        #expect(EngineFix.placement(of: WindowId(1), in: Engine.reduce(s, .dragEnded).1) == nil)
    }

    @Test func aCappedWindowKeepsItsHeightWhenParkedAndComingBackIsAMove() {
        // The scroll-in symptom, stated as the property that kills it: parking repositions and never
        // resizes, so a capped window's parked frame and its tiled frame differ in *position only*.
        // While the layout held a height the app refused, the two differed in size as well and every
        // return from the strip's edge re-asked for it.
        var s = Self.twoColumns()
        (s, _) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: EngineFix.third, height: 800),
            actual: Rect(x: 0, y: 0, width: EngineFix.third, height: 200)))
        let metrics = s.metrics()!

        var cursor = 0
        let tiled = try! #require(s.layout.targetFrames(scrollOffset: 0, metrics: metrics)[WindowId(1)])
        let parked = try! #require(s.layout.parkedFrames(metrics: metrics,
                                                         parkingFrom: &cursor)[WindowId(1)])
        #expect(tiled.size == parked.size)
        #expect(parked.size == Size(width: EngineFix.third, height: 200))
    }

    @Test func aShorterAnswerCapsTheWindowInItsColumnAndTheStackmateTakesTheRest() {
        // The consume symptom. Sharing a column with an elastic window, the fixed-height one was given
        // half the column and used 200 of it, leaving the rest as a hole underneath — the placeholder
        // that has no counterpart on the width axis, where a column simply narrows to what it can be.
        // The surplus now goes back to the stack, so the column still fills its box exactly.
        var s = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidthSnap),
                              [.windowCreated(EngineFix.snapshot(1)), .windowCreated(EngineFix.snapshot(2))]).0
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // w2 joins w1's column
        #expect(s.layout.columns.count == 1)

        let asked = try! #require(s.layout.targetFrames(scrollOffset: 0, metrics: s.metrics()!)[WindowId(2)])
        #expect(asked.height == 400)                                  // 800 split two ways, no gaps
        var short = asked
        short.size.height = 200
        (s, _) = Engine.reduce(s, .placementCorrected(WindowId(2), requested: asked, actual: short))

        let frames = s.layout.targetFrames(scrollOffset: 0, metrics: s.metrics()!)
        let w1 = try! #require(frames[WindowId(1)])
        let w2 = try! #require(frames[WindowId(2)])
        #expect(w2.height == 200)                                     // …the cap
        #expect(w1.height == 600)                                     // …and the stackmate absorbs it
        #expect(w1.height + w2.height == 800)                         // no hole anywhere in the column
        let (upper, lower) = w1.minY <= w2.minY ? (w1, w2) : (w2, w1)
        #expect(lower.minY == upper.minY + upper.height)              // …and none between them either
    }

    @Test func aHeightCorrectionUnderARaisedCoverSpringsTheStackRatherThanJumpingIt() {
        // The width branch's hazard, on the vertical axis: layers re-derive their frames from the
        // layout every tick, so a column that re-divides between two frames pops. A re-division has no
        // single number to interpolate — it is two different splits of one box — so it rides the
        // *displacement* animator structural edits use, seeded so the first frame reproduces the old
        // division exactly and decaying to the new one.
        var s = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth),
                              [.windowCreated(EngineFix.snapshot(1)), .windowCreated(EngineFix.snapshot(2))]).0
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))    // one column, two windows
        s = EngineFix.settle(s)

        (s, _) = Engine.reduce(s, .command(.cycleWidth))               // open a session
        for w in s.motion.transition?.windows ?? [] {
            (s, _) = Engine.reduce(s, .captureReady(w))
        }
        (s, _) = Engine.reduce(s, .coverOnScreen)
        #expect(s.motion.isCovered)

        let asked = try! #require(s.layout.targetFrames(scrollOffset: s.motion.viewportOffset.target,
                                                        metrics: s.metrics()!)[WindowId(2)])
        var short = asked
        short.size.height = 200
        let (corrected, fx) = Engine.reduce(s, .placementCorrected(WindowId(2), requested: asked,
                                                                   actual: short))
        s = corrected

        // Both windows of the column carry lag — the one that shrank and the stackmate that grew —
        // and neither of them is a width, which the column-width animator still owns alone.
        let capped = try! #require(s.motion.windowAnimator(WindowId(2)))
        #expect(capped.current.height != 0)
        #expect(capped.current.width == 0)
        #expect(s.motion.windowAnimator(WindowId(1))?.current.height != 0)

        // …and it decays: at rest the layers sit exactly on the layout's new division.
        let done = EngineFix.settle(s, fx)
        #expect(done.motion.displacement(of: WindowId(2)) == .zero)
        #expect(done.layout.targetFrames(scrollOffset: 0, metrics: done.metrics()!)[WindowId(2)]?.height
                == 200)
    }

    /// The recursion guard, on the axis it was missing from. Symmetric with the width case above: at
    /// most one shrink per question, or an app that always returns a little less walks its own slot to
    /// nothing while its stackmates swell to fill the space.
    @Test func anAppThatAlwaysReturnsShorterCannotWalkItsSlotDown() {
        var s = Self.twoColumns()
        func height(_ s: State) -> Double? {
            s.layout.targetFrames(scrollOffset: 0, metrics: s.metrics()!)[WindowId(1)]?.height
        }

        // First refusal, given to the question itself: learned, and the slot follows.
        (s, _) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: EngineFix.third, height: 800),
            actual: Rect(x: 0, y: 0, width: EngineFix.third, height: 200)))
        #expect(height(s) == 200)

        // Every later refusal answers a request we made *because* of the first one, so it teaches
        // nothing — the slot holds rather than stepping down 8 pt per event forever.
        for step in 1...5 {
            (s, _) = Engine.reduce(s, .placementCorrected(
                WindowId(1), requested: Rect(x: 0, y: 0, width: EngineFix.third, height: 200),
                actual: Rect(x: 0, y: 0, width: EngineFix.third, height: 200 - Double(step) * 8)))
            #expect(height(s) == 200, "step \(step)")
        }

        // …while the growing direction keeps learning unconditionally, as it does for width.
        (s, _) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: EngineFix.third, height: 200),
            actual: Rect(x: 0, y: 0, width: EngineFix.third, height: 500)))
        #expect(height(s) == 500)
    }

}
