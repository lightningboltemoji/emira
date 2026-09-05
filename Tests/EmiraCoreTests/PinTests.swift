import Foundation
import Testing
@testable import EmiraCore

// The geometry a pin opens: one area becomes three, and each of the three answers a different
// question. The load-bearing claim is that a proportion keeps its meaning across a pin — pinning moves
// the strip and re-proportions nothing — while `fullscreen` and every ceiling move onto what is left.

@Suite struct PinGeometryTests {

    /// A 1000-wide display, a 200 pt pin on `side`, and whatever gaps the case is about.
    static func metrics(_ side: PinSide? = nil, width: Double = 200, columnGap: Double = 0,
                        outerGaps: EdgeInsets = .zero) -> LayoutMetrics {
        var pins: [PinSide: PinBand] = [:]
        if let side {
            pins[side] = PinBand(window: WindowId(9), widthOverride: .fixed(width))
        }
        return LayoutMetrics(workingArea: EngineFix.displayFrame, columnGap: columnGap,
                             outerGaps: outerGaps, pins: pins)
    }

    // The three areas

    @Test func nothingPinnedLeavesAllThreeAreasWhereTheyWere() {
        let m = Self.metrics(outerGaps: EdgeInsets(uniform: 10))
        #expect(m.nominalArea == Rect(x: 10, y: 10, width: 980, height: 780))
        #expect(m.contentArea == m.nominalArea)          // no band to take off
        #expect(m.screenArea == m.workingArea)           // the strip bleeds to the display
    }

    @Test func aLeftPinMovesTheStripsOriginAndNotItsScale() {
        let m = Self.metrics(.left, columnGap: 12)
        #expect(m.nominalArea == Rect(x: 0, y: 0, width: 1000, height: 800))
        #expect(m.contentArea == Rect(x: 212, y: 0, width: 788, height: 800))
        #expect(m.pinFrame(.left) == Rect(x: 0, y: 0, width: 200, height: 800))
        #expect(m.pinFrame(.right) == nil)
    }

    @Test func aRightPinTakesTheOtherEnd() {
        let m = Self.metrics(.right, columnGap: 12)
        #expect(m.contentArea == Rect(x: 0, y: 0, width: 788, height: 800))
        #expect(m.pinFrame(.right) == Rect(x: 800, y: 0, width: 200, height: 800))
    }

    @Test func aPinIsFullHeightSoNoHeightChanges() {
        let plain = Self.metrics(outerGaps: EdgeInsets(uniform: 20))
        let pinned = Self.metrics(.left, outerGaps: EdgeInsets(uniform: 20))
        #expect(pinned.contentArea.height == plain.contentArea.height)
        #expect(pinned.heightExtent == plain.heightExtent)
        #expect(pinned.pinFrame(.left)?.height == plain.nominalArea.height)
    }

    /// A pin stands where the outermost column would have — inside the margin, not outside it.
    @Test func aPinStandsInsideTheOuterGap() {
        let m = Self.metrics(.left, outerGaps: EdgeInsets(uniform: 30))
        #expect(m.pinFrame(.left)?.minX == 30)
        #expect(m.screenArea.minX == 230)                // the outer gap it stands in, plus itself
        #expect(m.contentArea.minX == 230)               // …plus a column gap, which here is zero
    }

    // The split that makes "50% is 50%"

    @Test func aProportionIsAShareOfTheNominalAreaWhicheverSideIsPinned() {
        let plain = Self.metrics(columnGap: 12)
        let left = Self.metrics(.left, columnGap: 12)
        let right = Self.metrics(.right, columnGap: 12)
        // `(span + gap)·p − gap` over the whole screen, pin or no pin — which is the claim: half is
        // half of the display, not half of what the pin left.
        #expect(plain.widthExtent.resolve(.proportion(0.5)) == 494)
        #expect(left.widthExtent == plain.widthExtent)
        #expect(right.widthExtent == plain.widthExtent)
    }

    @Test func fullscreenAndTheCeilingsReadWhatIsLeft() {
        let m = Self.metrics(.left, columnGap: 12)
        #expect(m.contentExtent.span == 788)
        #expect(m.widthExtent.span == 1000)
        #expect(m.contentExtent.resolve(.proportion(1.0)) == 788)
    }

    /// The column a pin narrows is the *viewport*, so a preset wider than what is left is honoured and
    /// simply cannot be framed — exactly as `width-presets = [1.5]` already is on an unpinned screen.
    @Test func aPresetWiderThanTheClearAreaIsStillTheWidthItAsksFor() {
        let m = Self.metrics(.left, width: 700)
        let layout = Layout(columns: [ColumnLayout(id: ColumnId(1), windowIds: [WindowId(1)],
                                                   widthOverride: .proportion(0.5))])
        #expect(layout.resolvedWidth(of: layout.columns[0], metrics: m) == 500)
        #expect(m.contentArea.width == 300)
    }

    @Test func aFullscreenColumnFillsWhatIsLeftAndNoMore() {
        let m = Self.metrics(.left, columnGap: 12)
        let layout = Layout(columns: [ColumnLayout(id: ColumnId(1), windowIds: [WindowId(1)],
                                                   fullscreen: .plain)])
        #expect(layout.resolvedWidth(of: layout.columns[0], metrics: m) == 788)
    }

    // The physical viewport

    /// The shift is the distance between the two left edges, which is the outer gap with nothing
    /// pinned and the column gap beside a pin — or the tile-vs-park switch and the sweep disagree.
    @Test func thePhysicalViewportShiftsByWhateverTheStripMayBleedInto() {
        let plain = Self.metrics(outerGaps: EdgeInsets(uniform: 10))
        #expect(plain.physicalViewport(at: 100).width == 1000)
        #expect(plain.physicalViewport(at: 100).offset == 90)

        let pinned = Self.metrics(.left, columnGap: 12, outerGaps: EdgeInsets(uniform: 10))
        #expect(pinned.physicalViewport(at: 100).width == 790)   // 1000 − (10 outer + 200 pin)
        #expect(pinned.physicalViewport(at: 100).offset == 88)    // …bleeding one column gap
    }

    // The clamp

    @Test func aPinMayNotSwallowTheStrip() {
        let m = Self.metrics(.left, width: 5000)
        #expect(m.pinWidth(.left) == 1000 - LayoutMetrics.minimumColumnWidth)
        #expect(m.contentArea.width == LayoutMetrics.minimumColumnWidth)
    }

    /// Two pins divide what is left evenly rather than each taking a share of the other's remainder,
    /// which is what keeps the pair from being a fixed point.
    @Test func twoPinsClampAgainstTheStripAndNotAgainstEachOther() {
        var pins: [PinSide: PinBand] = [:]
        for side in PinSide.allCases {
            pins[side] = PinBand(window: WindowId(side == .left ? 8 : 9), widthOverride: .fixed(5000))
        }
        let m = LayoutMetrics(workingArea: EngineFix.displayFrame, pins: pins)
        #expect(m.pinWidth(.left) == (1000 - LayoutMetrics.minimumColumnWidth) / 2)
        #expect(m.pinWidth(.right) == m.pinWidth(.left))
        #expect(m.contentArea.width == LayoutMetrics.minimumColumnWidth)
    }

    @Test func aPinWalksTheSameTwoWidthRungsAColumnDoes() {
        let cycle = PresetCycle([.proportion(0.25), .proportion(0.5)])
        func metrics(_ band: PinBand) -> LayoutMetrics {
            LayoutMetrics(workingArea: EngineFix.displayFrame, widthPresets: cycle,
                          pins: [.left: band])
        }
        #expect(metrics(PinBand(window: WindowId(9), widthPreset: 0)).pinWidth(.left) == 250)
        #expect(metrics(PinBand(window: WindowId(9), widthPreset: 1)).pinWidth(.left) == 500)
        // The override shadows the rung, exactly as `ColumnLayout.widthOverride` does.
        #expect(metrics(PinBand(window: WindowId(9), widthPreset: 1,
                                widthOverride: .fixed(120))).pinWidth(.left) == 120)
    }
}
