import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The guide's arithmetic, with no AppKit and no window server — the half of the guide that is worth
// asserting, which is why it is a file of its own (`MenuBar`'s `StatusModel` split, again).

@Suite struct GuideModelTests {

    /// A 1000×800 working area at the origin, which makes every projected number readable by eye.
    static let working = Rect(x: 0, y: 0, width: 1000, height: 800)
    /// The one display every fixture here builds — the guide is per monitor now, so a projection has
    /// to say which one it is of.
    static let display = MonitorId(1)

    static func settings(style: GuideStyle = .placeholder, position: GuidePosition = .topRight,
                         width: Double = 0.3, span: Double = 3, gap: Double = 16,
                         duration: Double = 1) -> GuideSettings {
        GuideSettings(style: style, position: position, width: width, span: span, gap: gap,
                      duration: duration)
    }

    /// A strip `screens` working-areas long, starting flush with the viewport's left edge.
    static func strip(_ screens: Double, from x: Double = 0) -> Rect {
        Rect(x: x, y: 0, width: screens * working.width, height: working.height)
    }

    static func projection(_ s: GuideSettings, strip: Rect = strip(3)) throws -> GuideModel.Projection {
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
        // A nine-screen strip. `naturalFrames` gives screen-space frames, so scrolling to offset `o`
        // puts the strip at `-o`; the viewport is always the working area, [0, 1000].
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

    // Where the strip divides

    /// A column of `windows`, and the frames a strip of such columns would resolve to: `width` wide,
    /// full height, `gap` apart, each column's stack sharing its height equally.
    static func arrangement(_ columns: [[UInt64]], width: Double = 400,
                            gap: Double = 20) -> ([ColumnLayout], [WindowId: Rect]) {
        var frames: [WindowId: Rect] = [:]
        var x = 0.0
        let layouts = columns.enumerated().map { index, windows -> ColumnLayout in
            let share = working.height / Double(windows.count)
            for (row, id) in windows.enumerated() {
                frames[WindowId(id)] = Rect(x: x, y: Double(row) * share, width: width, height: share)
            }
            x += width + gap
            return ColumnLayout(id: ColumnId(UInt64(index + 1)), windowIds: windows.map(WindowId.init))
        }
        return (layouts, frames)
    }

    @Test func onlyOneTileMeansNothingToDivide() {
        let (columns, frames) = Self.arrangement([[1]])
        #expect(GuideModel.boundaries(of: columns, frames: frames).isEmpty)
    }

    @Test func adjacentColumnsAreDividedDownTheMiddleOfTheirGap() {
        let (columns, frames) = Self.arrangement([[1], [2]])
        // 400 wide with a 20 pt gap between them: the boundary is the gap's midpoint, not either edge,
        // so `column-gap = 0` would put it exactly on the shared edge instead.
        #expect(GuideModel.boundaries(of: columns, frames: frames)
                == [Rect(x: 410, y: 0, width: 0, height: 800)])
    }

    @Test func windowsStackedInAColumnAreDividedAcrossIt() {
        let (columns, frames) = Self.arrangement([[1, 2, 3]])
        // Two boundaries for three windows, each spanning the column and nothing beyond it.
        #expect(GuideModel.boundaries(of: columns, frames: frames)
                == [Rect(x: 0, y: 800.0 / 3, width: 400, height: 0),
                    Rect(x: 0, y: 1600.0 / 3, width: 400, height: 0)])
    }

    @Test func aBoundaryRunsTheWholeLengthOfWhatItDivides() {
        // A stacked column beside a single window: the column rule is full height whichever side is
        // stacked, and the stack rule stops at its own column's edge rather than crossing the strip.
        let (columns, frames) = Self.arrangement([[1, 2], [3]])
        let lines = GuideModel.boundaries(of: columns, frames: frames)
        #expect(lines.count == 2)
        #expect(lines[0] == Rect(x: 0, y: 400, width: 400, height: 0))
        #expect(lines[1] == Rect(x: 410, y: 0, width: 0, height: 800))
    }

    @Test func aRealStripCarriesItsBoundariesProjectedWithEverythingElse() throws {
        // Two full-width columns, so the one boundary sits on the seam between them — at `k = 0.1`,
        // 100 pt along a 200 pt ribbon, running its full height.
        let layout = try #require(GuideModel.layout(for: Self.world(), on: Self.display))
        #expect(layout.separators.count == 1)
        #expect(Self.approx(layout.separators[0], Rect(x: 100, y: 0, width: 0, height: 80)))
    }

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

    @Test func theGuideOffHasNoLayoutAndNoTrigger() {
        var state = State(config: Config(guide: Self.settings(style: .off)))
        state.setMonitors([MonitorInfo(id: MonitorId(1), frame: Self.working)])
        #expect(GuideModel.layout(for: state, on: Self.display) == nil)
        #expect(GuideModel.trigger(for: state, on: Self.display) == nil)
    }

    @Test func noDisplayYetMeansNothingToProjectOnto() {
        let state = State(config: Config(guide: Self.settings()))
        // No metrics *and* nothing to be about: a guide belongs to a display, and before the first
        // `screensChanged` there is no display for it to belong to.
        #expect(GuideModel.layout(for: state, on: Self.display) == nil)
        #expect(GuideModel.trigger(for: state, on: Self.display) == nil)
    }

    // A layout over a real strip

    /// Two windows on a strip, at rest, with the guide on.
    static func world(_ style: GuideStyle = .placeholder) -> State {
        var state = State(config: Config(widthPresets: PresetCycle([.proportion(1.0)]),
                                         transitionMode: .off,
                                         guide: settings(style: style)))
        state.setMonitors([MonitorInfo(id: MonitorId(1), frame: working)])
        for raw in UInt64(1)...2 {
            let (next, _) = Engine.reduce(state, .windowCreated(
                WindowSnapshot(id: WindowId(raw), bundleId: "com.test.app", title: "w",
                               role: .standard, frame: Rect(x: 0, y: 0, width: 10, height: 10))))
            state = next
        }
        return state
    }

    // One guide per display

    /// `Self.world()`, plus a second display. Everything the core manages is still on the first, which
    /// is what "N in the shell, one managed" means.
    static func twoDisplays() -> State {
        var state = world()
        state.setMonitors([
            MonitorInfo(id: display, frame: working),
            MonitorInfo(id: MonitorId(2), frame: Rect(x: 1000, y: 0, width: 800, height: 600)),
        ])
        return state
    }

    /// A guide draws the strips **its own display holds** and no others. On a second screen showing an
    /// empty address that is nothing at all — the panel is the bare viewport indicator, with none of
    /// the managed display's windows leaking into a panel they have nothing to do with.
    @Test func aSecondDisplayDrawsNoneOfTheFirstsWindows() throws {
        let state = Self.twoDisplays()
        let second = MonitorId(2)
        #expect(state.monitors.shown(on: second) != state.monitors.shown(on: Self.display))
        #expect(state.workspaces[state.monitors.shown(on: second)!].isEmpty)

        #expect(try #require(GuideModel.layout(for: state, on: Self.display)).tiles.count == 2)
        let empty = try #require(GuideModel.layout(for: state, on: second))
        #expect(empty.tiles.isEmpty)
        #expect(empty.separators.isEmpty)
    }

    /// …and each display's guide is *about* its own address, so two guides on one desktop diff
    /// independently. `focused` is per display for the same reason: there is one focused window, and a
    /// screen that does not hold it must not summon a HUD because focus moved on the other one.
    @Test func eachDisplaysTriggerNamesItsOwnWorkspaceAndItsOwnFocus() throws {
        let state = Self.twoDisplays()
        let first = try #require(GuideModel.trigger(for: state, on: Self.display))
        let second = try #require(GuideModel.trigger(for: state, on: MonitorId(2)))
        #expect(first.workspace == state.monitors.shown(on: Self.display))
        #expect(second.workspace == state.monitors.shown(on: MonitorId(2)))
        #expect(first.focused == state.world.focusedWindow)
        #expect(second.focused == nil)
        #expect(first != second)
        #expect(second.columns.isEmpty)
    }

    /// The ring follows focus, not the panel: only the display holding the focused window draws one.
    @Test func onlyTheDisplayHoldingFocusDrawsARing() throws {
        let state = Self.settled(Self.twoDisplays())
        #expect(try #require(GuideModel.layout(for: state, on: Self.display)).ring != nil)
        #expect(try #require(GuideModel.layout(for: state, on: MonitorId(2))).ring == nil)
    }

    /// A display that has left answers nothing at all, rather than projecting onto stale geometry.
    @Test func aDetachedDisplayHasNeitherALayoutNorATrigger() {
        var state = Self.twoDisplays()
        state.setMonitors([MonitorInfo(id: Self.display, frame: Self.working)])
        #expect(GuideModel.layout(for: state, on: MonitorId(2)) == nil)
        #expect(GuideModel.trigger(for: state, on: MonitorId(2)) == nil)
    }

    /// …with the focus ring arrived, which the arrivals themselves set travelling.
    static func settled(_ start: State) -> State {
        var s = start
        for _ in 0..<2000 where s.motion.needsFrames { s = Engine.reduce(s, .tick(dt: 1.0 / 120)).0 }
        return s
    }

    @Test func aTilePerWindowCarriesItsAppAndItsRectangle() throws {
        let layout = try #require(GuideModel.layout(for: Self.world(), on: Self.display))
        #expect(layout.tiles.count == 2)
        #expect(layout.tiles.allSatisfy { $0.bundleId == "com.test.app" })
        #expect(layout.tiles.map(\.window) == [WindowId(1), WindowId(2)])   // sorted, so the pool is stable
    }

    @Test func theViewportIndicatorIsTheWorkingAreaProjected() throws {
        let layout = try #require(GuideModel.layout(for: Self.world(), on: Self.display))
        #expect(Self.approx(layout.viewport, Rect(x: 100, y: 0, width: 100, height: 80)))
    }

    @Test func theRingLeavesTheOldTileAndTravelsToTheNewOne() throws {
        // Settled first: the second window's *arrival* is itself a focus change, so a freshly built
        // world already has a ring in flight.
        let state = Self.settled(Self.world())
        let atRest = try #require(GuideModel.layout(for: state, on: Self.display))
        // At rest the ring sits exactly on the focused window's tile.
        #expect(Self.approx(try #require(atRest.ring),
                            try #require(atRest.tiles.first { $0.window == WindowId(2) }?.rect),
                            tol: GuideModel.separation * 2 + 0.001))

        let (moved, _) = Engine.reduce(state, .command(.focus(.left)))
        let seeded = try #require(GuideModel.layout(for: moved, on: Self.display))
        // The instant focus moves, the ring is still drawn over the window it is *leaving* — that
        // equality is what makes the travel read as travel rather than as a jump-then-slide.
        let departed = try #require(seeded.tiles.first { $0.window == WindowId(2) }?.rect)
        #expect(abs(try #require(seeded.ring).minX - departed.minX) < GuideModel.separation * 2 + 0.001)

        // …and it arrives on the newly focused one.
        let arrived = try #require(GuideModel.layout(for: Self.settled(moved), on: Self.display))
        let target = try #require(arrived.tiles.first { $0.window == WindowId(1) }?.rect)
        #expect(abs(try #require(arrived.ring).minX - target.minX) < GuideModel.separation * 2 + 0.5)
    }

    @Test func theGuideShrinksToWhatIsActuallyOnTheStrip() throws {
        // Two full-width columns is two screens of strip, so at the default `span = 3` the ribbon is
        // two thirds of `width` rather than `width` with a third of it empty.
        let two = try #require(GuideModel.layout(for: Self.world(), on: Self.display))
        #expect(abs(two.panel.width - 200) < 0.001)

        // Close one, and it shrinks again.
        let (one, _) = Engine.reduce(Self.world(), .windowDestroyed(WindowId(2)))
        #expect(abs(try #require(GuideModel.layout(for: one, on: Self.display)).panel.width - 100) < 0.001)
    }

    @Test func focusOnNothingLeavesNoRingToDraw() throws {
        let (blurred, _) = Engine.reduce(Self.world(), .focusChanged(nil, origin: .system))
        let layout = try #require(GuideModel.layout(for: blurred, on: Self.display))
        #expect(layout.ring == nil)
        #expect(layout.tiles.count == 2)                // the strip is still there
    }

    @Test func theTriggerReportsAChangeInTheValueNotInTheThingCarryingIt() {
        let state = Self.world()
        // A title change, and an AX landing: neither is a reason to summon a HUD.
        let (retitled, _) = Engine.reduce(state, .axLanded(WindowId(1)))
        #expect(GuideModel.trigger(for: retitled, on: Self.display) == GuideModel.trigger(for: state, on: Self.display))

        let (refocused, _) = Engine.reduce(state, .command(.focus(.left)))
        #expect(GuideModel.trigger(for: refocused, on: Self.display) != GuideModel.trigger(for: state, on: Self.display))
    }

    @Test func theTriggerDoesNotMoveWithTheScrollsCurrentValue() {
        // It carries the scroll's *target*: a target moves once per command, a current value 120 times
        // a second — and a trigger that moved per frame would re-arm the dwell forever.
        var state = Self.world()
        let before = GuideModel.trigger(for: state, on: Self.display)
        state.motion.advance(by: 1.0 / 120)
        #expect(GuideModel.trigger(for: state, on: Self.display) == before)
    }
}
