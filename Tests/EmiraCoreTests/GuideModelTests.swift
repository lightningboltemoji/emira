import Foundation
import Testing
@testable import EmiraCore

// The guide's arithmetic, with no AppKit, no window server and no `State` — the half of the guide that
// is worth asserting, which is why it is a file of its own (`MenuBar`'s `StatusModel` split, again).
//
// Everything here runs on a `GuideInput`, which is the point: the settings window builds one from a
// mock desktop and the shell builds one from the truth plane, so what is asserted here is what both
// hosts draw.

@Suite struct GuideModelTests {

    /// A 1000×800 working area at the origin, which makes every projected number readable by eye.
    static let working = Rect(x: 0, y: 0, width: 1000, height: 800)

    static func settings(position: GuidePosition = .topRight, width: Double = 0.3,
                         span: Double = 3, gap: Double = 16) -> PreviewGuideSettings {
        PreviewGuideSettings(enabled: true, position: position, width: width, span: span, gap: gap)
    }

    /// A strip `screens` working-areas long, starting flush with the viewport's left edge.
    static func strip(_ screens: Double, from x: Double = 0) -> Rect {
        Rect(x: x, y: 0, width: screens * working.width, height: working.height)
    }

    static func projection(_ s: PreviewGuideSettings,
                           strip: Rect = strip(3)) throws -> GuideModel.Projection {
        try #require(GuideModel.projection(settings: s, working: working, strip: strip))
    }

    static func approx(_ a: Rect, _ b: Rect, tol: Double = 0.001) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
            && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    // k is the whole projection

    @Test func theScaleIsWidthOverSpan() {
        #expect(abs(Self.settings(width: 0.3, span: 3).scale - 0.1) < 1e-12)
        #expect(Self.settings(width: 0.5, span: 2).scale == 0.25)
        #expect(Self.settings(width: 1, span: 20).scale == 0.05)
    }

    @Test func aSillyWidthOrSpanIsStoppedByTheGeometryRatherThanReversed() {
        // The schema's bounds are floors only, so both of these parse. Neither may produce a ribbon
        // bigger than the working area it is anchored inside.
        #expect(Self.settings(width: 4, span: 2).scale == 0.5)      // width clamped at 1
        #expect(Self.settings(width: 0.5, span: 0.25).scale == 1)   // span under 1 clamped at 1
        #expect(Self.settings(span: 0).scale == 0)                  // and a degenerate span draws nothing
        #expect(GuideModel.projection(settings: Self.settings(span: 0), working: Self.working) == nil)
    }

    @Test func aFullSpanStripIsWidthOfTheWorkingWidthAndItsHeightIsDerived() throws {
        let panel = try Self.projection(Self.settings(width: 0.3, span: 3), strip: Self.strip(3)).panel
        #expect(abs(panel.width - 300) < 0.001)         // width × working.width, span cancelling out
        #expect(abs(panel.height - 80) < 0.001)         // k × working.height — never configured
    }

    // `span` is a ceiling, not a frame

    @Test func aStripShorterThanTheSpanShrinksTheGuideToFitIt() throws {
        let settings = Self.settings(width: 0.3, span: 3)
        // Three screens of strip is the full 30%; two is 20%, one is 10% — the ribbon is as long as
        // there is something to show, and never a fixed frame with the ends left empty.
        #expect(abs(try Self.projection(settings, strip: Self.strip(3)).panel.width - 300) < 0.001)
        #expect(abs(try Self.projection(settings, strip: Self.strip(2)).panel.width - 200) < 0.001)
        #expect(abs(try Self.projection(settings, strip: Self.strip(1)).panel.width - 100) < 0.001)
        // The height is one desktop at scale `k` whatever the strip does.
        #expect(abs(try Self.projection(settings, strip: Self.strip(1)).panel.height - 80) < 0.001)
    }

    @Test func anEmptyOrTinyStripStillShowsTheScreenYouAreOn() throws {
        let settings = Self.settings(width: 0.3, span: 3)
        // An indicator wider than the panel containing it is not an indicator, so the shown window is
        // never narrower than the viewport.
        for strip in [Rect.zero, Rect(x: 100, y: 0, width: 200, height: 800)] {
            let p = try Self.projection(settings, strip: strip)
            #expect(abs(p.panel.width - 100) < 0.001)                // exactly one screen
            #expect(Self.approx(p.project(Self.working),
                                Rect(x: 0, y: 0, width: 100, height: 80)))
        }
    }

    @Test func aStripLongerThanTheSpanIsCappedAtIt() throws {
        let panel = try Self.projection(Self.settings(width: 0.3, span: 3), strip: Self.strip(9)).panel
        #expect(abs(panel.width - 300) < 0.001)         // nine screens shown three at a time
    }

    // The viewport indicator travels; the guide does not

    @Test func theIndicatorPinsToEitherEndOfALongStripAndCentresBetweenThem() throws {
        let settings = Self.settings(width: 0.3, span: 3)
        // A nine-screen strip. The frames are screen-space, so scrolling to offset `o` puts the strip
        // at `-o`; the viewport is always the working area, [0, 1000].
        func indicator(scrolledTo offset: Double) throws -> Rect {
            let p = try Self.projection(settings, strip: Self.strip(9, from: -offset))
            return p.project(Self.working)
        }
        // At the left end the shown window pins to the strip's start, so the indicator is at the left.
        #expect(Self.approx(try indicator(scrolledTo: 0), Rect(x: 0, y: 0, width: 100, height: 80)))
        // In the middle it centres, and the tiles slide past it instead.
        #expect(Self.approx(try indicator(scrolledTo: 4000), Rect(x: 100, y: 0, width: 100, height: 80)))
        // At the right end it pins to the right — the whole point: no huge gap on one side.
        #expect(Self.approx(try indicator(scrolledTo: 8000), Rect(x: 200, y: 0, width: 100, height: 80)))
    }

    @Test func theIndicatorTravelsTheWholeGuideWhenTheStripFitsInIt() throws {
        let settings = Self.settings(width: 0.3, span: 3)
        // Two screens of strip, drawn whole in a 200 pt ribbon: the tiles never move and the indicator
        // walks from one end to the other.
        func indicator(scrolledTo offset: Double) throws -> Rect {
            try Self.projection(settings, strip: Self.strip(2, from: -offset)).project(Self.working)
        }
        #expect(Self.approx(try indicator(scrolledTo: 0), Rect(x: 0, y: 0, width: 100, height: 80)))
        #expect(Self.approx(try indicator(scrolledTo: 1000),
                            Rect(x: 100, y: 0, width: 100, height: 80)))
    }

    @Test func theShownWindowIsContinuousAcrossTheCap() {
        // The two regimes meet by a `min`/`max`, not a branch, so nothing jumps as a strip grows past
        // `span` screens. Sampled either side of the boundary at a fixed scroll.
        let settings = Self.settings(span: 3)
        let under = GuideModel.shownWindow(settings: settings, working: Self.working,
                                           strip: Self.strip(2.999))
        let over = GuideModel.shownWindow(settings: settings, working: Self.working,
                                          strip: Self.strip(3.001))
        #expect(abs(under.minX - over.minX) < 1)
        #expect(abs(under.width - over.width) < 2)
    }

    // Where a panel goes, which every guide asks the same way

    @Test func everyAnchorPlacesThePanelInsideTheWorkingAreaWithItsGap() throws {
        // A 300×80 panel in a 1000×800 area with a 16 pt gap: the free travel is 1000−32−300 = 668
        // horizontally and 800−32−80 = 688 vertically.
        let expected: [GuidePosition: Point] = [
            .topLeft:      Point(x: 16, y: 16),
            .topCenter:    Point(x: 350, y: 16),
            .topRight:     Point(x: 684, y: 16),
            .centerLeft:   Point(x: 16, y: 360),
            .center:       Point(x: 350, y: 360),
            .centerRight:  Point(x: 684, y: 360),
            .bottomLeft:   Point(x: 16, y: 704),
            .bottomCenter: Point(x: 350, y: 704),
            .bottomRight:  Point(x: 684, y: 704),
        ]
        for position in GuidePosition.allCases {
            let panel = try Self.projection(Self.settings(position: position)).panel
            #expect(Self.approx(panel, Rect(origin: try #require(expected[position]),
                                            size: Size(width: 300, height: 80))),
                    "\(position.rawValue) landed at \(panel)")
        }
    }

    /// The anchor arithmetic is shared, so a panel whose size came from somewhere else entirely — text,
    /// in the names guide's case — lands where the projected one would.
    @Test func placeIsTheProjectionsOwnAnchoring() throws {
        for position in GuidePosition.allCases {
            let placed = GuideModel.place(size: Size(width: 300, height: 80), within: Self.working,
                                          position: position, gap: 16)
            #expect(Self.approx(placed, try Self.projection(Self.settings(position: position)).panel))
        }
    }

    @Test func aPanelWithNoRoomForItsGapLosesTheGapRatherThanTheDisplay() throws {
        // Full width and a gap that cannot fit beside it: the gap is what gives, and the panel stays
        // inside the working area rather than hanging off its edge.
        let panel = try Self.projection(Self.settings(position: .topRight, width: 1, span: 1,
                                                      gap: 40)).panel
        #expect(panel.width == 1000)
        #expect(panel.minX == 0)
        #expect(panel.maxX == 1000)
    }

    // What the panel shows

    @Test func thePanelShowsTheStripItself() throws {
        let p = try Self.projection(Self.settings(width: 0.3, span: 3), strip: Self.strip(3))
        // Three screens of strip fill the ribbon exactly — the guide *is* the strip, not a frame the
        // strip passes through.
        #expect(Self.approx(p.project(Self.strip(3)), Rect(x: 0, y: 0, width: 300, height: 80)))
        // …and the viewport is where you are inside it, at the ribbon's full height.
        #expect(Self.approx(p.project(Self.working), Rect(x: 0, y: 0, width: 100, height: 80)))
    }

    @Test func aStripLongerThanTheSpanRunsOffBothEdges() throws {
        // A nine-screen strip scrolled to its middle: the shown window is the three screens around the
        // viewport, so there is strip off both ends.
        let p = try Self.projection(Self.settings(width: 0.3, span: 3),
                                    strip: Self.strip(9, from: -4000))
        #expect(p.project(Rect(x: -3000, y: 0, width: 1000, height: 800)).maxX < 0)
        #expect(p.project(Rect(x: 4000, y: 0, width: 1000, height: 800)).minX > 300)
    }

    @Test func aWorkspaceOneScreenUpProjectsExactlyOnePanelHeightUp() throws {
        let p = try Self.projection(Self.settings(width: 0.3, span: 3))
        let up = p.project(Self.working.offsetBy(dx: 0, dy: -800))
        #expect(abs(up.maxY - 0) < 0.001)               // flush with the panel's top edge, and above it
        #expect(abs(up.height - 80) < 0.001)
    }

    @Test func separationIsTakenOutInGuidePointsWhateverTheScale() {
        let wide = GuideModel.separated(Rect(x: 0, y: 0, width: 100, height: 80))
        #expect(Self.approx(wide, Rect(x: 1.5, y: 1.5, width: 97, height: 77)))
        // The same absolute inset at a different scale — it is applied *after* projection, so it never
        // depends on `k` and never on the user's `column-gap`.
        let narrow = GuideModel.separated(Rect(x: 0, y: 0, width: 30, height: 80))
        #expect(abs(narrow.width - 27) < 0.001)
    }

    @Test func aTileTooThinToSeparateThinsRatherThanInverting() {
        let sliver = GuideModel.separated(Rect(x: 0, y: 0, width: 2, height: 4))
        #expect(sliver.width > 0)
        #expect(sliver.height > 0)
        #expect(sliver.width == 1)                      // a quarter off each side, never more
    }

    // A layout over a strip
    //
    // At `width = 1, span = 1` the projection is the identity on a strip that fits one working area, so
    // every number below is the arrangement's own and readable by eye.

    /// Settings whose projection is the identity: the panel is the working area, and nothing is scaled.
    static func lifeSize(position: GuidePosition = .topLeft) -> PreviewGuideSettings {
        settings(position: position, width: 1, span: 1, gap: 0)
    }

    /// A strip of `columns`, each a stack of window ids: `width` wide, full height, `gap` apart, each
    /// column's stack sharing its height equally.
    static func input(_ columns: [[UInt64]], width: Double = 400, gap: Double = 20,
                      focus: UInt64? = nil, displacement: Rect = .zero) -> GuideInput {
        var frames: [WindowId: Rect] = [:]
        var x = 0.0
        let strip = columns.enumerated().map { index, windows -> GuideInput.Column in
            let share = working.height / Double(windows.count)
            for (row, id) in windows.enumerated() {
                frames[WindowId(id)] = Rect(x: x, y: Double(row) * share, width: width, height: share)
            }
            x += width + gap
            return GuideInput.Column(id: ColumnId(UInt64(index + 1)),
                                     windows: windows.map {
                                         GuideInput.Window(id: WindowId($0), bundleId: "com.test.app")
                                     })
        }
        return GuideInput(workingArea: working, columns: strip, frames: frames,
                          focus: focus.map(WindowId.init), focusDisplacement: displacement)
    }

    static func layout(_ columns: [[UInt64]], width: Double = 400, gap: Double = 20,
                       focus: UInt64? = nil, displacement: Rect = .zero,
                       settings: PreviewGuideSettings = lifeSize()) throws -> GuideLayout {
        try #require(GuideModel.layout(input(columns, width: width, gap: gap, focus: focus,
                                             displacement: displacement),
                                       settings: settings))
    }

    @Test func onlyOneTileMeansNothingToDivide() throws {
        #expect(try Self.layout([[1]]).separators.isEmpty)
    }

    @Test func adjacentColumnsAreDividedDownTheMiddleOfTheirGap() throws {
        // 400 wide with a 20 pt gap between them: the boundary is the gap's midpoint, not either edge,
        // so `column-gap = 0` would put it exactly on the shared edge instead.
        #expect(try Self.layout([[1], [2]]).separators
                == [Rect(x: 410, y: 0, width: 0, height: 800)])
    }

    @Test func windowsStackedInAColumnAreDividedAcrossIt() throws {
        // Two boundaries for three windows, each spanning the column and nothing beyond it.
        #expect(try Self.layout([[1, 2, 3]]).separators
                == [Rect(x: 0, y: 800.0 / 3, width: 400, height: 0),
                    Rect(x: 0, y: 1600.0 / 3, width: 400, height: 0)])
    }

    @Test func aBoundaryRunsTheWholeLengthOfWhatItDivides() throws {
        // A stacked column beside a single window: the column rule is full height whichever side is
        // stacked, and the stack rule stops at its own column's edge rather than crossing the strip.
        let lines = try Self.layout([[1, 2], [3]]).separators
        #expect(lines.count == 2)
        #expect(lines[0] == Rect(x: 0, y: 400, width: 400, height: 0))
        #expect(lines[1] == Rect(x: 410, y: 0, width: 0, height: 800))
    }

    @Test func aColumnIsTheUnionOfItsStackAndTheTilesAreSeparatedInsideIt() throws {
        let column = try #require(Self.layout([[1, 2]]).columns.first)
        // The column itself is unseparated — it is what the rules are measured between.
        #expect(Self.approx(column.rect, Rect(x: 0, y: 0, width: 400, height: 800)))
        #expect(column.tiles.count == 2)
        #expect(Self.approx(column.tiles[0].rect, Rect(x: 1.5, y: 1.5, width: 397, height: 397)))
    }

    @Test func aTilePerWindowCarriesItsAppAndItsRectangle() throws {
        let layout = try Self.layout([[1], [2]])
        #expect(layout.tiles.count == 2)
        #expect(layout.tiles.allSatisfy { $0.bundleId == "com.test.app" })
        #expect(layout.tiles.map(\.window) == [WindowId(1), WindowId(2)])   // sorted, so the pool is stable
    }

    @Test func aWorkspaceSlidingThroughDrawsTilesAndDividesNothing() throws {
        // A window on a neighbouring workspace: it is a tile like any other, and no rule is drawn for
        // it, because the shown strip is what the guide is about.
        var frames = Self.input([[1], [2]]).frames
        frames[WindowId(9)] = Rect(x: 0, y: -800, width: 400, height: 800)
        let base = Self.input([[1], [2]])
        let input = GuideInput(workingArea: Self.working, columns: base.columns,
                               passing: [GuideInput.Window(id: WindowId(9), bundleId: "com.other.app")],
                               frames: frames)
        let layout = try #require(GuideModel.layout(input, settings: Self.lifeSize()))
        #expect(layout.tiles.count == 3)
        #expect(layout.passing.map(\.window) == [WindowId(9)])
        #expect(layout.separators.count == 1)
        // …and it projects clear above the panel, which is what makes a switch slide through it.
        #expect(try #require(layout.tiles.first { $0.window == WindowId(9) }).rect.maxY <= 0.001)
    }

    @Test func theViewportIndicatorIsTheWorkingAreaProjected() throws {
        // Two full-width columns is two screens of strip at `span = 3`, so `k = 0.1` and the indicator
        // is a third of the ribbon.
        let layout = try Self.layout([[1], [2]], width: 1000, gap: 0,
                                     settings: Self.settings(width: 0.3, span: 3))
        #expect(Self.approx(layout.viewport, Rect(x: 0, y: 0, width: 100, height: 80)))
        #expect(abs(layout.panel.width - 200) < 0.001)
    }

    @Test func theRingIsTheFocusedWindowPlusWhateverTravelIsLeft() throws {
        let atRest = try Self.layout([[1], [2]], focus: 2)
        #expect(Self.approx(try #require(atRest.ring), Rect(x: 420, y: 0, width: 400, height: 800)))

        // Mid-flight the ring is still drawn over the window it is *leaving*, which is what makes the
        // travel read as travel rather than as a jump-then-slide.
        let travelling = try Self.layout([[1], [2]], focus: 1,
                                         displacement: Rect(x: 420, y: 0, width: 0, height: 0))
        #expect(Self.approx(try #require(travelling.ring),
                            Rect(x: 420, y: 0, width: 400, height: 800)))
    }

    @Test func focusOnNothingLeavesNoRingToDraw() throws {
        let layout = try Self.layout([[1], [2]])
        #expect(layout.ring == nil)
        #expect(layout.tiles.count == 2)                // the strip is still there
    }

    @Test func anEmptyStripDrawsAnEmptyRibbon() throws {
        let input = GuideInput(workingArea: Self.working, columns: [], frames: [:])
        let layout = try #require(GuideModel.layout(input, settings: Self.settings()))
        #expect(layout.tiles.isEmpty)
        #expect(layout.separators.isEmpty)
        #expect(layout.ring == nil)
        // One screen wide: there is nothing on the strip, and the screen you are on still fits in it.
        #expect(abs(layout.panel.width - 100) < 0.001)
    }

    @Test func theGuideShrinksToWhatIsActuallyOnTheStrip() throws {
        // Two full-width columns is two screens of strip, so at `span = 3` the ribbon is two thirds of
        // `width` rather than `width` with a third of it empty.
        let two = try Self.layout([[1], [2]], width: 1000, gap: 0,
                                  settings: Self.settings(width: 0.3, span: 3))
        #expect(abs(two.panel.width - 200) < 0.001)
        let one = try Self.layout([[1]], width: 1000, gap: 0,
                                  settings: Self.settings(width: 0.3, span: 3))
        #expect(abs(one.panel.width - 100) < 0.001)
    }

    // The corner rule

    /// A ribbon-sized container with room for the rule to run in: a 4 pt tile inside a 19 pt curve, so
    /// the conformance is alive over the first 15 pt of approach.
    static let inner = Rect(x: 0, y: 0, width: 300, height: 100)
    static func corners(_ rect: Rect, radius: Double = 4, outer: Double = 19) -> Corners {
        GuideModel.corners(of: rect, in: inner, radius: radius, outer: outer)
    }

    @Test func aTileAwayFromEveryCornerIsAllItsOwnRadius() {
        #expect(Self.corners(Rect(x: 100, y: 30, width: 50, height: 40)) == .uniform(4))
    }

    @Test func aTileInACornerRoundsConcentricWithTheRibbonsAndOnlyThere() {
        // Half a point inside the ribbon's inner edge, so the gap the curve keeps from it is half a
        // point the whole way round the corner.
        let c = Self.corners(Rect(x: 0.5, y: 0.5, width: 100, height: 50))
        #expect(c.topLeft == 18.5)
        // The other three are nowhere near a corner of the ribbon, and none of them hears about it.
        #expect(c.topRight == 4)
        #expect(c.bottomLeft == 4)
        #expect(c.bottomRight == 4)
    }

    @Test func theConformanceDecaysWithTheApproachAndThenExpires() {
        // One point of retreat is one point of curve, until the rule reaches the tile's own radius at
        // `outer − radius` and stops. Continuous at both ends: nothing jumps as a tile scrolls off the
        // end of the ribbon.
        #expect(Self.corners(Rect(x: 0, y: 0, width: 50, height: 50)).topLeft == 19)
        #expect(Self.corners(Rect(x: 10, y: 0, width: 50, height: 50)).topLeft == 9)
        #expect(Self.corners(Rect(x: 15, y: 0, width: 50, height: 50)).topLeft == 4)
        #expect(Self.corners(Rect(x: 40, y: 0, width: 50, height: 50)).topLeft == 4)
    }

    @Test func beingFlushWithAnEdgeIsNotBeingInACorner() {
        // The offset that counts is the *larger* of the two: a tile in the middle of the ribbon's top
        // edge is against the edge, not in the corner, and a curve there would read as a mistake.
        let c = Self.corners(Rect(x: 100, y: 0, width: 50, height: 50))
        #expect(c.topLeft == 4)
        #expect(c.topRight == 4)
    }

    @Test func aRadiusIsNeverMoreThanHalfTheShortSide() {
        // A sliver in the corner: the rule wants 19 and the tile has 3 to give, so it gives 3 rather
        // than folding the path back through itself.
        #expect(Self.corners(Rect(x: 0, y: 0, width: 50, height: 6)) == .uniform(3))
    }

    @Test func aTileHangingOffTheRibbonTakesTheRibbonsOwnCurveAndNoMore() {
        // Its corner is outside the clip, where the ribbon's curve is already what the eye sees — so
        // the offset floors at zero rather than going negative and over-rounding.
        let c = Self.corners(Rect(x: -50, y: -50, width: 100, height: 100))
        #expect(c.topLeft == 19)
        #expect(c.bottomRight == 4)
    }

    @Test func insettingCornersTightensEveryRadiusByTheInsetAndNoneBelowZero() {
        let c = Corners(topLeft: 18, topRight: 4, bottomRight: 0.25, bottomLeft: 4).inset(by: 0.5)
        #expect(c == Corners(topLeft: 17.5, topRight: 3.5, bottomRight: 0, bottomLeft: 3.5))
    }

    /// What fraction of its tile's short side the icon takes.
    static func iconFraction(_ size: Size) -> Double {
        GuideModel.placeholder(in: size).width / min(size.width, size.height)
    }

    @Test func aTileWithRoomForTheIconPadsItToThreeFifths() {
        // Square: the case where fitting by aspect alone would draw the icon at the tile's full height.
        #expect(Self.approx(GuideModel.placeholder(in: Size(width: 100, height: 100)),
                            Rect(x: 20, y: 20, width: 60, height: 60)))
    }

    @Test func aCrunchedTileGivesItsPaddingUp() {
        // At 2:1 the padding has fully given way, and the axis it was crunched along does not matter —
        // a window stacked in a column and a narrow column are the same tile turned sideways.
        #expect(Self.approx(GuideModel.placeholder(in: Size(width: 200, height: 100)),
                            Rect(x: 57.5, y: 7.5, width: 85, height: 85)))
        #expect(Self.approx(GuideModel.placeholder(in: Size(width: 100, height: 200)),
                            Rect(x: 7.5, y: 57.5, width: 85, height: 85)))
        // And past it the icon is not asked to grow further: 85% is the floor on the padding, not a
        // point on a line that keeps going.
        #expect(abs(Self.iconFraction(Size(width: 800, height: 100)) - 0.85) < 1e-12)
    }

    @Test func thePaddingOnlyEverGrowsWithTheRoomForIt() {
        var last = 0.85
        for width in stride(from: 200.0, through: 100.0, by: -5) {
            let fraction = Self.iconFraction(Size(width: width, height: 100))
            #expect(fraction <= last + 1e-12)           // monotonic, and no step in it
            #expect(fraction >= 0.6 - 1e-12 && fraction <= 0.85 + 1e-12)
            last = fraction
        }
        #expect(abs(last - 0.6) < 1e-12)                // arriving exactly at square
    }

    @Test func aTileWithNoAreaHasNoIcon() {
        #expect(GuideModel.placeholder(in: .zero) == .zero)
        #expect(GuideModel.placeholder(in: Size(width: 40, height: 0)) == .zero)
    }
}
