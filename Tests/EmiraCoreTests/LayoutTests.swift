import Foundation
import Testing
@testable import EmiraCore

/// The layout engine's first cut: the infinite-strip placement/scroll/viewport math (`Strip`) and
/// the cyclable size presets (`PresetSize` / `PresetCycle`). Pure, fast, exhaustive — the
/// `LayoutTests` bucket IMPLEMENTATION.md §8 calls for.
@Suite struct StripTests {

    // Reused fixture: three columns of 100 / 200 / 300 pt with a 10 pt gap at the strip origin.
    //   col0 [  0, 100)   col1 [110, 310)   col2 [320, 620)
    private let strip = Strip(columnWidths: [100, 200, 300], gap: 10)

    // MARK: Placement

    @Test func leftEdgeAccumulatesWidthsAndGaps() {
        #expect(strip.leftEdge(of: 0) == 0)
        #expect(strip.leftEdge(of: 1) == 110)   // 100 + gap
        #expect(strip.leftEdge(of: 2) == 320)   // 100 + gap + 200 + gap
    }

    @Test func leftEdgePastTheEndIsTheAppendPosition() {
        // leftEdge(count) is where a newly appended column's left edge would land — one gap past
        // the last column's right edge. Indices beyond that clamp to it.
        #expect(strip.leftEdge(of: 3) == 630)   // 620 (content) + gap
        #expect(strip.leftEdge(of: 99) == strip.leftEdge(of: 3))
        #expect(strip.leftEdge(of: -5) == 0)    // clamped low
    }

    @Test func originShiftsTheWholeRun() {
        let shifted = Strip(columnWidths: [100, 200, 300], gap: 10, origin: 50)
        #expect(shifted.leftEdge(of: 0) == 50)
        #expect(shifted.leftEdge(of: 1) == 160)
        #expect(shifted.leftEdge(of: 2) == 370)
    }

    @Test func spanReturnsOriginAndWidth() {
        let (x, w) = strip.span(of: 1)
        #expect(x == 110)
        #expect(w == 200)
    }

    @Test func contentWidthSumsWidthsPlusInnerGaps() {
        #expect(strip.contentWidth == 620)                       // 600 + 2·10
        #expect(Strip(columnWidths: [100], gap: 10).contentWidth == 100)  // single: no gap
        #expect(Strip(columnWidths: [], gap: 10).contentWidth == 0)       // empty
        #expect(Strip(columnWidths: [], gap: 10).isEmpty)
    }

    // MARK: Scroll math

    @Test func offsetToAlignLeftIsJustTheLeftEdge() {
        #expect(strip.offsetToAlignLeft(2) == 320)
    }

    @Test func offsetToCenterCentersTheColumn() {
        // col1 spans [110, 310), mid 210. In a 500-wide viewport, centering puts the offset at
        // 210 − 250 = −40 (negative offset is normal on the infinite strip).
        let offset = strip.offsetToCenter(1, viewportWidth: 500)
        #expect(offset == -40)
        // Sanity: the viewport center now equals the column center.
        #expect(offset + 500 / 2 == 210)
    }

    @Test func offsetToRevealLeavesAlreadyVisibleColumnPut() {
        // col1 [110,310) fits entirely inside a wide viewport at offset 0 → no scroll.
        #expect(strip.offsetToReveal(1, viewportWidth: 800, from: 0) == 0)
    }

    @Test func offsetToRevealPullsInAColumnHiddenPastTheLeft() {
        // col2 left edge 320; viewport at 400 has scrolled past it → align its left edge.
        #expect(strip.offsetToReveal(2, viewportWidth: 200, from: 400) == 320)
    }

    @Test func offsetToRevealPullsInAColumnHiddenPastTheRight() {
        // col2 [320,620); viewport [0,500) hides its right edge → scroll so right edge is flush:
        // 620 − 500 = 120.
        #expect(strip.offsetToReveal(2, viewportWidth: 500, from: 0) == 120)
    }

    @Test func offsetToRevealAlignsLeftWhenColumnWiderThanViewport() {
        // col2 is 300 wide; a 200-wide viewport can't contain it → show its left edge.
        #expect(strip.offsetToReveal(2, viewportWidth: 200, from: 0) == 320)
    }

    // MARK: Visibility

    @Test func isFullyVisibleIsInclusiveAtTheEdges() {
        // col1 [110,310) exactly fills a 200-wide viewport at offset 110 → visible (edge-flush ok).
        #expect(strip.isFullyVisible(1, viewportWidth: 200, offset: 110))
        // Nudge the viewport one point right and the left edge falls outside → not fully visible.
        #expect(!strip.isFullyVisible(1, viewportWidth: 200, offset: 111))
    }

    @Test func visibleColumnIndicesCollectsOverlappingColumns() {
        // viewport [0,250): col0 [0,100) and col1 [110,310) overlap; col2 [320,…) doesn't.
        #expect(strip.visibleColumnIndices(viewportWidth: 250, offset: 0) == [0, 1])
    }

    @Test func visibleColumnIndicesExcludesEdgeFlushColumns() {
        // viewport [100,200): col0's right edge is exactly 100 (flush, no pixels) → excluded;
        // col1 [110,310) overlaps → included; col2 starts at 320 → excluded.
        #expect(strip.visibleColumnIndices(viewportWidth: 100, offset: 100) == [1])
    }

    @Test func visibleColumnIndicesEmptyOnEmptyStrip() {
        #expect(Strip(columnWidths: [], gap: 10).visibleColumnIndices(viewportWidth: 500, offset: 0) == [])
    }
}

/// Cyclable width/height presets — resolution against a working extent and wrap-around cycling.
@Suite struct PresetTests {

    @Test func presetSizeResolvesProportionAndFixed() {
        #expect(PresetSize.proportion(0.5).resolved(available: 1000) == 500)
        #expect(PresetSize.proportion(1.0 / 3.0).resolved(available: 900) == 300)
        #expect(PresetSize.fixed(800).resolved(available: 1000) == 800)   // ignores available
    }

    @Test func defaultWidthsAreTheThirdHalfTwoThirdsLadder() {
        let w = PresetCycle.defaultWidths
        #expect(w.count == 3)
        #expect(w.size(at: 0) == .proportion(1.0 / 3.0))
        #expect(w.size(at: 1) == .proportion(1.0 / 2.0))
        #expect(w.size(at: 2) == .proportion(2.0 / 3.0))
        #expect(w.resolved(at: 1, available: 1000) == 500)
    }

    @Test func cyclingWrapsForwardAndBackward() {
        let c = PresetCycle.defaultWidths        // count 3
        #expect(c.nextIndex(after: 0) == 1)
        #expect(c.nextIndex(after: 1) == 2)
        #expect(c.nextIndex(after: 2) == 0)      // wrap to start
        #expect(c.previousIndex(before: 0) == 2) // wrap to end
        #expect(c.previousIndex(before: 1) == 0)
    }

    @Test func accessorsAreTotalForDriftedIndices() {
        let c = PresetCycle.defaultWidths        // count 3
        #expect(c.size(at: 5) == c.size(at: 2))  // 5 mod 3 == 2
        #expect(c.size(at: -1) == c.size(at: 2)) // negative normalizes into range
        #expect(c.nextIndex(after: 5) == 0)      // normalize (→2) then step (→0)
    }

    @Test func emptyCycleStaysTotal() {
        let empty = PresetCycle([])
        #expect(empty.isEmpty)
        #expect(empty.count == 0)
        #expect(empty.size(at: 0) == .proportion(1.0))   // full-extent fallback, no trap
        #expect(empty.nextIndex(after: 0) == 0)
        #expect(empty.previousIndex(before: 0) == 0)
    }

    @Test func presetsRoundTripThroughCodable() throws {
        let cycle = PresetCycle([.proportion(0.25), .fixed(640), .proportion(1.0)])
        let data = try JSONEncoder().encode(cycle)
        let back = try JSONDecoder().decode(PresetCycle.self, from: data)
        #expect(back == cycle)
    }
}

/// The vertical stack inside one column: height distribution (the auto/pinned model) and the
/// stacked window frames. Pure, total, top-left origin — same bucket as `StripTests`.
@Suite struct ColumnTests {

    // Reused fixture: a column box at x=100, top y=50, 400 wide, 900 tall, with a 10 pt inter-window
    // gap. Windows fill the 400 width and stack down from y=50.
    private let box = Rect(x: 100, y: 50, width: 400, height: 900)

    // MARK: Height distribution

    @Test func singleAutoWindowFillsTheColumn() {
        let c = Column(frame: box, windowHeights: [.auto], gap: 10)
        #expect(c.resolvedHeights() == [900])           // no gaps, no pins → full box height
        #expect(c.frame(of: 0) == Rect(x: 100, y: 50, width: 400, height: 900))
        #expect(c.contentHeight == 900)
    }

    @Test func twoAutoWindowsSplitEquallyMinusTheGap() {
        // leftover = 900 − 1·10 = 890; each auto gets 445.
        let c = Column(frame: box, windowHeights: [.auto, .auto], gap: 10)
        #expect(c.resolvedHeights() == [445, 445])
        #expect(c.windowFrames() == [
            Rect(x: 100, y: 50, width: 400, height: 445),
            Rect(x: 100, y: 505, width: 400, height: 445),   // 50 + 445 + 10
        ])
        #expect(c.contentHeight == 900)                 // autos absorb the slack exactly
    }

    @Test func pinnedHeightIsHonoredAndAutoTakesTheRemainder() {
        // fixed 300 pinned; leftover = 900 − 10 − 300 = 590 for the lone auto.
        let c = Column(frame: box, windowHeights: [.preset(.fixed(300)), .auto], gap: 10)
        #expect(c.resolvedHeights() == [300, 590])
        #expect(c.windowFrames() == [
            Rect(x: 100, y: 50, width: 400, height: 300),
            Rect(x: 100, y: 360, width: 400, height: 590),   // 50 + 300 + 10
        ])
        #expect(c.contentHeight == 900)
    }

    @Test func proportionPinsResolveAgainstTheColumnHeight() {
        // ½ of 900 = 450; no auto to absorb the rest, so content is short of the box (honest).
        let c = Column(frame: box, windowHeights: [.preset(.proportion(0.5))], gap: 10)
        #expect(c.resolvedHeights() == [450])
        #expect(c.contentHeight == 450)
    }

    @Test func overPinnedColumnClampsAutoToZeroAndOverflows() {
        // two fixed 700s + an auto: leftover = 900 − 20 − 1400 < 0 → auto clamps to 0; the fixed
        // heights overflow the box (contentHeight > frame.height). Total, never negative.
        let c = Column(
            frame: box,
            windowHeights: [.preset(.fixed(700)), .preset(.fixed(700)), .auto],
            gap: 10)
        #expect(c.resolvedHeights() == [700, 700, 0])
        #expect(c.contentHeight == 1420)                // 700 + 700 + 0 + 2·10, exceeds 900
    }

    // MARK: Height floors — the water-fill (a window that refuses to be as short as its share)

    @Test func aHeightFloorBelowTheShareChangesNothing() {
        // Three autos in 900 with two 10 pt gaps → 293.33 each. A window that accepts 200 has no
        // opinion worth acting on, and an inert floor must stay inert.
        let c = Column(frame: box, windowHeights: [.auto, .auto, .auto], gap: 10,
                       minHeights: [200, nil, nil])
        let h = c.resolvedHeights()
        #expect(h.allSatisfy { abs($0 - 880.0 / 3) < 0.001 })
    }

    @Test func aHeightFloorAboveTheShareTakesItAndTheRestRedivide() {
        // leftover = 900 − 2·10 = 880; equal shares would be 293.33 each. The first window insists on
        // 500, so it takes 500 and the other two split the remaining 380 → 190 apiece.
        let c = Column(frame: box, windowHeights: [.auto, .auto, .auto], gap: 10,
                       minHeights: [500, nil, nil])
        #expect(c.resolvedHeights() == [500, 190, 190])
        #expect(c.contentHeight == 900)          // still fills the box exactly
    }

    @Test func redividingCanPushAnotherWindowUnderItsFloorAndTheFillRepeats() {
        // The reason this is a loop and not one pass. Shares start at 293.33; w0's 500 floor drops the
        // others to 190, which is now under w1's 250 floor — so w1 is floored on the *second* pass and
        // w2 takes what is left: 880 − 500 − 250 = 130.
        let c = Column(frame: box, windowHeights: [.auto, .auto, .auto], gap: 10,
                       minHeights: [500, 250, nil])
        #expect(c.resolvedHeights() == [500, 250, 130])
        #expect(c.contentHeight == 900)
    }

    @Test func floorsThatCannotFitOverflowTheBoxRatherThanGoingNegative() {
        // Two windows that each insist on 700 in a 900 box: both get their floor, the last auto
        // clamps to zero, and the column overflows — exactly what over-pinned presets already do.
        let c = Column(frame: box, windowHeights: [.auto, .auto, .auto], gap: 10,
                       minHeights: [700, 700, nil])
        #expect(c.resolvedHeights() == [700, 700, 0])
        #expect(c.contentHeight == 1420)
    }

    @Test func aHeightFloorNeverOverridesAPinnedPreset() {
        // A pin is the user's explicit instruction; a floor is an app's constraint. Only autos honor
        // floors, so the pinned 300 stays 300 and the auto absorbs the rest.
        let c = Column(frame: box, windowHeights: [.preset(.fixed(300)), .auto], gap: 10,
                       minHeights: [800, nil])
        #expect(c.resolvedHeights() == [300, 590])
    }

    @Test func aShortOrAbsentFloorArrayIsTotal() {
        let c = Column(frame: box, windowHeights: [.auto, .auto], gap: 10, minHeights: [600])
        #expect(c.resolvedHeights() == [600, 290])       // 890 − 600
        #expect(Column(frame: box, windowHeights: [.auto, .auto], gap: 10, minHeights: [])
            .resolvedHeights() == [445, 445])
    }

    // MARK: Totality / edges

    @Test func emptyColumnHasNoFramesAndZeroContent() {
        let c = Column(frame: box, windowHeights: [], gap: 10)
        #expect(c.isEmpty)
        #expect(c.resolvedHeights() == [])
        #expect(c.windowFrames() == [])
        #expect(c.frame(of: 0) == nil)
        #expect(c.contentHeight == 0)
    }

    @Test func frameOfIsTotalForOutOfRangeIndices() {
        let c = Column(frame: box, windowHeights: [.auto, .auto], gap: 10)
        #expect(c.frame(of: -1) == nil)
        #expect(c.frame(of: 2) == nil)                  // count is 2 → indices 0,1 only
        #expect(c.frame(of: 1) == Rect(x: 100, y: 505, width: 400, height: 445))
    }

    @Test func everyWindowSharesTheColumnXAndWidth() {
        let c = Column(frame: box, windowHeights: [.auto, .auto, .auto], gap: 10)
        for f in c.windowFrames() {
            #expect(f.minX == 100)
            #expect(f.width == 400)
        }
    }
}

/// Deterministic, unique, staggered park slots for off-viewport windows (PRINCIPLES.md §4a, §7).
@Suite struct ParkTests {

    // Reused fixture: a 1440×900 working area at the origin; 1 pt slivers, 8 pt vertical stagger.
    // rows-per-lane = floor(900 / 8) = 112.
    private let lot = ParkingLot(frame: Rect(x: 0, y: 0, width: 1440, height: 900))
    private let size = Size(width: 400, height: 300)

    @Test func slotPokesVisibleSliverInFromTheLeft() {
        // window shoved left so only 1 pt shows: x = 0 − 400 + 1 = −399, right edge at 1.
        let s = lot.slot(ordinal: 0, size: size)
        #expect(s == Rect(x: -399, y: 0, width: 400, height: 300))
        #expect(s.maxX == lot.frame.minX + lot.visibleSliver)   // exactly `visibleSliver` on-screen
    }

    @Test func successiveSlotsStaggerDownByStagger() {
        #expect(lot.slot(ordinal: 0, size: size).minY == 0)
        #expect(lot.slot(ordinal: 1, size: size).minY == 8)
        #expect(lot.slot(ordinal: 2, size: size).minY == 16)
        // same lane → same x, only y moves
        #expect(lot.slot(ordinal: 1, size: size).minX == lot.slot(ordinal: 0, size: size).minX)
    }

    @Test func slotFramesAreUniqueAcrossManyOrdinals() {
        // The load-bearing property (§7): no two parked windows share a frame. (`Rect` isn't
        // Hashable — width/height are constant here, so a distinct origin means a distinct frame.)
        let frames = (0..<300).map { lot.slot(ordinal: $0, size: size) }
        let origins = Set(frames.map { "\($0.minX),\($0.minY)" })
        #expect(origins.count == frames.count)
    }

    @Test func lanesWrapASliverFurtherInWhenRowsAreExhausted() {
        // ordinal 112 == lane 1, row 0: y resets to the top, x pokes one more sliver in.
        let first = lot.slot(ordinal: 0, size: size)
        let wrapped = lot.slot(ordinal: 112, size: size)
        #expect(wrapped.minY == lot.frame.minY)                 // back to the top of the next lane
        #expect(wrapped.minX == first.minX + lot.visibleSliver) // one sliver further on-screen
        #expect(wrapped != first)
    }

    @Test func negativeOrdinalsSnapToTheFirstSlot() {
        #expect(lot.slot(ordinal: -5, size: size) == lot.slot(ordinal: 0, size: size))
    }

    @Test func slotKeepsTheWindowSizeAndStaysWarm() {
        let s = lot.slot(ordinal: 3, size: size)
        #expect(s.width == 400 && s.height == 300)              // reposition, never resize
        #expect(s.intersects(lot.frame))                        // a sliver is genuinely on-screen
    }
}

/// The layout assembler: structure (`reconcile`, columns, width presets) and the payoff —
/// `targetFrames` turning columns + scroll offset into concrete tiled / parked frames. Pure, total.
@Suite struct LayoutTests {

    // Window ids used across the assembly fixtures.
    private let w10 = WindowId(10), w20 = WindowId(20), w21 = WindowId(21)
    private let w30 = WindowId(30), w40 = WindowId(40)

    // Reused metrics: a 900×600 working area at the origin; each column ⅓ of the width = 300 pt;
    // no gaps (clean arithmetic). Strip of four 300-wide columns → content 1200, viewport 900.
    private let metrics = LayoutMetrics(
        workingArea: Rect(x: 0, y: 0, width: 900, height: 600),
        widthPresets: PresetCycle([.proportion(1.0 / 3.0)]),
        columnGap: 0, windowGap: 0)

    // Reused arrangement: col0 [w10] · col1 [w20, w20's stackmate w21] · col2 [w30] · col3 [w40].
    //   col0 [0,300)  col1 [300,600)  col2 [600,900)  col3 [900,1200)
    private func fourColumns() -> Layout {
        Layout(columns: [
            ColumnLayout(id: ColumnId(1), windowIds: [w10]),
            ColumnLayout(id: ColumnId(2), windowIds: [w20, w21]),
            ColumnLayout(id: ColumnId(3), windowIds: [w30]),
            ColumnLayout(id: ColumnId(4), windowIds: [w40]),
        ])
    }

    // MARK: reconcile — the World→Layout membership bridge

    @Test func reconcileAppendsNewcomersAsSingleWindowColumns() {
        var layout = Layout()
        layout.reconcile(stripWindowIds: [w10, w20, w30])
        #expect(layout.columns.count == 3)
        #expect(layout.columns.map(\.windowIds) == [[w10], [w20], [w30]])  // one each, input order
        #expect(layout.allWindowIds == [w10, w20, w30])
    }

    @Test func reconcileDropsDepartedWindowsAndEmptyColumns() {
        var layout = Layout()
        layout.reconcile(stripWindowIds: [w10, w20, w30])
        let idOfW20Column = layout.columns[1].id
        layout.reconcile(stripWindowIds: [w10, w30])       // w20 gone → its column emptied → dropped
        #expect(layout.columns.map(\.windowIds) == [[w10], [w30]])
        #expect(layout.columnIndex(withId: idOfW20Column) == nil)
    }

    @Test func reconcilePreservesExistingColumnIdentityAndArrangement() {
        // A two-window column survives a churn that only adds a newcomer: same column id, same stack.
        var layout = Layout(columns: [ColumnLayout(id: ColumnId(7), windowIds: [w20, w21])])
        layout.reconcile(stripWindowIds: [w20, w21, w40])
        #expect(layout.columns[0].id == ColumnId(7))       // identity preserved
        #expect(layout.columns[0].windowIds == [w20, w21]) // arrangement preserved
        #expect(layout.columns[1].windowIds == [w40])      // newcomer appended as its own column
        // The freshly-minted id doesn't collide with the supplied one.
        #expect(layout.columns[1].id != ColumnId(7))
    }

    @Test func reconcileIsIdempotentForAnUnchangedSet() {
        var layout = Layout()
        layout.reconcile(stripWindowIds: [w10, w20])
        let before = layout.columns
        layout.reconcile(stripWindowIds: [w10, w20])
        #expect(layout.columns == before)                  // no churn, no new columns minted
    }

    // MARK: structural mutation — the strip's editing primitives

    @Test func movingAColumnOneSlotRightSwapsItWithItsNeighbour() {
        var layout = fourColumns()
        let edit = layout.moveColumn(ColumnId(2), to: 2)
        #expect(edit.moved)
        #expect(edit.destroyedColumn == nil)                  // a reorder empties nothing
        #expect(layout.columns.map(\.id) == [ColumnId(1), ColumnId(3), ColumnId(2), ColumnId(4)])
        #expect(layout.allWindowIds == [w10, w30, w20, w21, w40])
        // col1 is now w30's, so the [300,600) slot holds w30 rather than the w20/w21 stack.
        #expect(layout.targetFrames(scrollOffset: 0, metrics: metrics)[w30]
                == Rect(x: 300, y: 0, width: 300, height: 600))
    }

    @Test func movingAColumnOneSlotLeftSwapsItWithItsNeighbour() {
        var layout = fourColumns()
        #expect(layout.moveColumn(ColumnId(3), to: 1).moved)
        #expect(layout.columns.map(\.id) == [ColumnId(1), ColumnId(3), ColumnId(2), ColumnId(4)])
    }

    /// The clamp has to land on `count - 1` and then be compared against the source index — clamping
    /// to `count` instead turns an edge press into a silent identity move that still reports `moved`.
    @Test func movingAColumnPastEitherEndOfTheStripIsANoOp() {
        var layout = fourColumns()
        let before = layout
        #expect(layout.moveColumn(ColumnId(1), to: -1) == .none)   // already leftmost
        #expect(layout.moveColumn(ColumnId(4), to: 4) == .none)    // already rightmost
        #expect(layout == before)
    }

    @Test func movingAnUnknownColumnIsANoOp() {
        var layout = fourColumns()
        let before = layout
        #expect(layout.moveColumn(ColumnId(99), to: 0) == .none)
        #expect(layout == before)
    }

    @Test func aReorderedColumnKeepsItsIdItsStackAndItsWidthPreset() {
        var layout = fourColumns()
        layout.setWidthPreset(3, ofColumn: ColumnId(2))
        layout.moveColumn(ColumnId(2), to: 0)
        let moved = layout.columns[0]
        #expect(moved.id == ColumnId(2))                      // identity animation keys on this
        #expect(moved.windowIds == [w20, w21])
        #expect(moved.widthPreset == 3)
    }

    @Test func movingAWindowDownItsColumnSwapsItWithTheWindowBelow() {
        var layout = fourColumns()
        #expect(layout.moveWindowWithinColumn(w20, to: 1).moved)
        #expect(layout.columns[1].windowIds == [w21, w20])
        // Two auto windows split the 600-tall area: rows at y 0 and y 300, now swapped.
        let frames = layout.targetFrames(scrollOffset: 0, metrics: metrics)
        #expect(frames[w21] == Rect(x: 300, y: 0, width: 300, height: 300))
        #expect(frames[w20] == Rect(x: 300, y: 300, width: 300, height: 300))
    }

    @Test func movingAWindowPastTheTopOrBottomOfItsStackIsANoOp() {
        var layout = fourColumns()
        let before = layout
        #expect(layout.moveWindowWithinColumn(w20, to: -1) == .none)   // already the top
        #expect(layout.moveWindowWithinColumn(w21, to: 2) == .none)    // already the bottom
        #expect(layout == before)
    }

    @Test func movingAWindowWithinItsColumnNeverChangesColumnMembership() {
        var layout = fourColumns()
        layout.moveWindowWithinColumn(w20, to: 1)
        #expect(layout.columns.count == 4)
        #expect(layout.columnIndex(ofWindow: w20) == 1)
        #expect(layout.columnIndex(ofWindow: w21) == 1)
    }

    @Test func movingAnUnknownWindowWithinAColumnIsANoOp() {
        var layout = fourColumns()
        let before = layout
        #expect(layout.moveWindowWithinColumn(WindowId(999), to: 0) == .none)
        #expect(layout == before)
    }

    @Test func extractingAStackedWindowMintsANewSingleWindowColumnAtTheGivenIndex() {
        var layout = fourColumns()
        let edit = layout.extract(window: w21, toNewColumnAt: 2)
        #expect(edit.moved)
        #expect(edit.destroyedColumn == nil)                  // the source keeps w20, so it survives
        #expect(layout.columns.count == 5)
        #expect(layout.columns[1].windowIds == [w20])
        #expect(layout.columns[2].windowIds == [w21])
        #expect(layout.columns[2].id == ColumnId(5))          // watermark resumed past the supplied 4
    }

    @Test func extractingLeftAndExtractingRightDifferByOneIndex() {
        var left = fourColumns(), right = fourColumns()
        left.extract(window: w21, toNewColumnAt: 1)           // source sits at index 1 → land before it
        right.extract(window: w21, toNewColumnAt: 2)          // → land after it
        #expect(left.columns.map(\.windowIds) == [[w10], [w21], [w20], [w30], [w40]])
        #expect(right.columns.map(\.windowIds) == [[w10], [w20], [w21], [w30], [w40]])
    }

    /// The bug shape this prevents: the literal implementation destroys the column and mints an
    /// identical replacement, so the layout *compares equal by arrangement* while the `ColumnId` — the
    /// handle `Motion.columnWidths` and the cover's animation identity key on — silently changed
    /// underneath every animator. `Layout`'s synthesized `Equatable` covers the private allocator
    /// watermark, so comparing the whole value catches the stray mint too.
    @Test func extractingAWindowAlreadyAloneInItsColumnIsANoOp() {
        var layout = fourColumns()
        let before = layout
        #expect(layout.extract(window: w10, toNewColumnAt: 3) == .none)
        #expect(layout == before)
    }

    @Test func anExtractedColumnInheritsTheWidthPresetItLeft() {
        var layout = fourColumns()
        layout.setWidthPreset(1, ofColumn: ColumnId(2))       // the stacked column, now preset 1
        layout.extract(window: w21, toNewColumnAt: 2)
        #expect(layout.columns[2].widthPreset == 1)
        // Two presets in the cycle would resolve differently; with one, both are still 300.
        let m = LayoutMetrics(workingArea: Rect(x: 0, y: 0, width: 900, height: 600),
                              widthPresets: PresetCycle([.proportion(1.0 / 3.0), .proportion(2.0 / 3.0)]),
                              columnGap: 0, windowGap: 0)
        #expect(layout.strip(metrics: m).columnWidths[1] == 600)   // source: ⅔ of 900
        #expect(layout.strip(metrics: m).columnWidths[2] == 600)   // and the extracted one matches
    }

    @Test func extractingClampsAnOutOfRangeIndexToTheEndsOfTheStrip() {
        var low = fourColumns(), high = fourColumns()
        low.extract(window: w21, toNewColumnAt: -5)
        high.extract(window: w21, toNewColumnAt: 99)
        #expect(low.columns.first?.windowIds == [w21])
        #expect(high.columns.last?.windowIds == [w21])
    }

    /// The strip has an origin, not an edge — index 0 is an ordinary place on an unbounded axis, so an
    /// expel there creates its column rather than refusing like a consume with no neighbour would.
    @Test func extractingAtTheStripOriginStillCreatesTheColumn() {
        var layout = fourColumns()
        #expect(layout.extract(window: w21, toNewColumnAt: 0).moved)
        #expect(layout.columns[0].windowIds == [w21])
        #expect(layout.columns.count == 5)
    }

    @Test func mergingAWindowIntoAnotherColumnInsertsItAtTheGivenRow() {
        var top = fourColumns(), bottom = fourColumns()
        top.move(window: w10, toColumn: ColumnId(2), at: 0)
        bottom.move(window: w10, toColumn: ColumnId(2), at: 2)
        #expect(top.columns[0].windowIds == [w10, w20, w21])      // col1 became index 0 on the drop
        #expect(bottom.columns[0].windowIds == [w20, w21, w10])
    }

    @Test func mergingTheLastWindowOutOfAColumnDestroysItAndReportsTheId() {
        var layout = fourColumns()
        let edit = layout.move(window: w10, toColumn: ColumnId(2), at: 0)
        #expect(edit.moved)
        #expect(edit.destroyedColumn == ColumnId(1))
        #expect(layout.columnIndex(withId: ColumnId(1)) == nil)
        #expect(layout.columns.count == 3)
    }

    @Test func mergingAWindowOutOfAStackLeavesItsColumnAliveAndDestroysNothing() {
        var layout = fourColumns()
        let edit = layout.move(window: w21, toColumn: ColumnId(3), at: 0)
        #expect(edit.destroyedColumn == nil)
        #expect(layout.columns[1].windowIds == [w20])              // col1 survives with one window
        #expect(layout.columns[2].windowIds == [w21, w30])
    }

    /// A same-column reposition is `moveWindowWithinColumn`'s job. Handling it here would have to
    /// special-case a removal that empties the very column it is inserting into.
    @Test func mergingIntoTheWindowsOwnColumnIsANoOp() {
        var layout = fourColumns()
        let before = layout
        #expect(layout.move(window: w20, toColumn: ColumnId(2), at: 1) == .none)
        #expect(layout == before)
    }

    @Test func mergingAnUnknownWindowOrAnUnknownTargetIsANoOp() {
        var layout = fourColumns()
        let before = layout
        #expect(layout.move(window: WindowId(999), toColumn: ColumnId(2), at: 0) == .none)
        #expect(layout.move(window: w10, toColumn: ColumnId(99), at: 0) == .none)
        #expect(layout == before)
    }

    @Test func aRowPastTheEndOfTheTargetStackAppendsAtTheBottom() {
        var layout = fourColumns()
        layout.move(window: w10, toColumn: ColumnId(2), at: 99)
        #expect(layout.columns[0].windowIds == [w20, w21, w10])
    }

    /// The index-shift check. Merging the *alone* w10 out of index 0 destroys its column, which shifts
    /// every column to its right one place left. An implementation that resolved the destination index
    /// before the removal would land w10 in `ColumnId(3)` — the column that inherited index 3.
    @Test func aMergeThatDestroysAColumnDoesNotShiftTheTargetOutFromUnderIt() {
        var layout = fourColumns()
        layout.move(window: w10, toColumn: ColumnId(4), at: 1)
        let target = try! #require(layout.columnIndex(withId: ColumnId(4)))
        #expect(layout.columns[target].windowIds == [w40, w10])
        #expect(layout.columnIndex(ofWindow: w10) == target)
    }

    // MARK: structural invariants — tests whose subject is an absence

    /// The two rules `Layout.columns` is `private(set)` to protect. Run a mixed script and re-check
    /// after every step, because a mutator that breaks either one does it transiently.
    @Test func noStructuralMutationEverBreaksTheStripsInvariants() {
        var layout = fourColumns()
        let all = Set(layout.allWindowIds)
        func check(_ step: String) {
            #expect(layout.columns.allSatisfy { !$0.windowIds.isEmpty }, "empty column after \(step)")
            #expect(Set(layout.allWindowIds) == all, "window lost after \(step)")
            #expect(layout.allWindowIds.count == all.count, "window duplicated after \(step)")
        }
        layout.moveColumn(ColumnId(2), to: 0);                          check("moveColumn")
        layout.extract(window: w21, toNewColumnAt: 0);                  check("extract left")
        layout.move(window: w21, toColumn: ColumnId(1), at: 0);         check("merge")
        layout.moveWindowWithinColumn(w21, to: 1);                      check("reorder")
        layout.move(window: w30, toColumn: ColumnId(4), at: 0);         check("merge onto w40")
        layout.extract(window: w30, toNewColumnAt: 99);                 check("extract right")
        layout.moveColumn(ColumnId(4), to: 0);                          check("moveColumn again")
        layout.move(window: w10, toColumn: ColumnId(2), at: 0);         check("merge alone")
    }

    /// **The load-bearing one.** Every `Engine` handler reconciles at its top, so an arrangement that
    /// `reconcile` undoes is a command that does nothing at all — and it would look perfectly correct
    /// in isolation. `World.stripWindowIds` is id-sorted, deliberately unrelated to layout order, so
    /// that is what we hand back.
    @Test func aStructuralMutationSurvivesTheNextReconcile() {
        var layout = fourColumns()
        layout.extract(window: w21, toNewColumnAt: 0)
        layout.moveColumn(ColumnId(1), to: 3)
        let arranged = layout
        layout.reconcile(stripWindowIds: [w10, w20, w21, w30, w40])   // id order, as World supplies
        #expect(layout == arranged)
    }

    /// Guards the `init(columns:)` watermark-rewind hazard: a mutator that rebuilt the layout through
    /// that initializer would resume the allocator below a destroyed column's id and re-issue it.
    @Test func columnIdsAreNeverReusedAfterAColumnIsDestroyed() {
        var layout = fourColumns()
        var seen = Set(layout.columns.map(\.id))
        layout.extract(window: w21, toNewColumnAt: 4)                 // mints 5
        seen.formUnion(layout.columns.map(\.id))
        let born = try! #require(layout.columnIndex(ofWindow: w21))
        let dead = layout.columns[born].id
        #expect(layout.move(window: w21, toColumn: ColumnId(3), at: 0).destroyedColumn == dead)
        layout.extract(window: w21, toNewColumnAt: 0)                 // mints again, must not reuse
        let reborn = try! #require(layout.columns.first?.id)
        #expect(reborn == ColumnId(6))
        #expect(!seen.contains(reborn))
    }

    // MARK: targetFrames — tiled placement + off-viewport parking

    @Test func targetFramesTilesVisibleColumnsAndParksTheRest() {
        // scrollOffset 0, viewport [0,900): col0/1/2 visible, col3 [900,1200) parked.
        let frames = fourColumns().targetFrames(scrollOffset: 0, metrics: metrics)
        // col0: one window fills the column full height.
        #expect(frames[w10] == Rect(x: 0, y: 0, width: 300, height: 600))
        // col1: two auto windows split 600 → 300 each, stacked.
        #expect(frames[w20] == Rect(x: 300, y: 0, width: 300, height: 300))
        #expect(frames[w21] == Rect(x: 300, y: 300, width: 300, height: 300))
        // col2: fills its column.
        #expect(frames[w30] == Rect(x: 600, y: 0, width: 300, height: 600))
        // col3 parked: ordinal 0, size 300×600 → x = 0 − 300 + 1 = −299, hugging the left edge.
        #expect(frames[w40] == Rect(x: -299, y: 0, width: 300, height: 600))
        #expect(frames.count == 5)                         // exhaustive over the strip's windows
    }

    @Test func targetFramesPullTheStripIntoViewOnScroll() {
        // scrollOffset 300 (scrolled one column right), viewport [300,1200): col0 parks, col1/2/3
        // slide left by 300 into view (dx = 0 − 300 = −300).
        let frames = fourColumns().targetFrames(scrollOffset: 300, metrics: metrics)
        #expect(frames[w20] == Rect(x: 0, y: 0, width: 300, height: 300))     // strip 300 → screen 0
        #expect(frames[w21] == Rect(x: 0, y: 300, width: 300, height: 300))
        #expect(frames[w30] == Rect(x: 300, y: 0, width: 300, height: 600))   // strip 600 → screen 300
        #expect(frames[w40] == Rect(x: 600, y: 0, width: 300, height: 600))   // strip 900 → screen 600
        // col0 now off the left → parked at ordinal 0.
        #expect(frames[w10] == Rect(x: -299, y: 0, width: 300, height: 600))
    }

    @Test func targetFramesHonorTheWorkingAreaOriginAndGaps() {
        // Non-zero working-area origin (a menu-bar strut) + gaps: everything shifts by the origin and
        // the gaps open up between columns/windows.
        let m = LayoutMetrics(
            workingArea: Rect(x: 100, y: 25, width: 900, height: 620),
            widthPresets: PresetCycle([.proportion(1.0 / 3.0)]),   // 300 wide
            columnGap: 10, windowGap: 20)
        let layout = Layout(columns: [
            ColumnLayout(id: ColumnId(1), windowIds: [w10]),
            ColumnLayout(id: ColumnId(2), windowIds: [w20, w21]),
        ])
        let frames = layout.targetFrames(scrollOffset: 0, metrics: m)
        // col0 at strip x 0 → screen x = 100 (origin) − 0 (scroll); y = 25; fills 620 tall.
        #expect(frames[w10] == Rect(x: 100, y: 25, width: 300, height: 620))
        // col1 at strip x 310 (300 + 10 gap) → screen x = 410; two windows split (620 − 20)/2 = 300.
        #expect(frames[w20] == Rect(x: 410, y: 25, width: 300, height: 300))
        #expect(frames[w21] == Rect(x: 410, y: 345, width: 300, height: 300))  // 25 + 300 + 20 gap
    }

    @Test func targetFramesParkOrdinalsAreUniqueSoParkedFramesDontCollide() {
        // Scroll far right so several columns park; assert the parked frames are all distinct (§7).
        let frames = fourColumns().targetFrames(scrollOffset: 900, metrics: metrics)  // viewport [900,1200)
        // Only col3 [900,1200) is visible; col0/1/2 (four windows) park.
        let parked = [frames[w10], frames[w20], frames[w21], frames[w30]].compactMap { $0 }
        let origins = Set(parked.map { "\($0.minX),\($0.minY)" })
        #expect(origins.count == parked.count)             // no two parked windows share a frame
        #expect(frames[w40] == Rect(x: 0, y: 0, width: 300, height: 600))  // the lone visible column
    }

    @Test func emptyLayoutProducesNoFrames() {
        #expect(Layout().targetFrames(scrollOffset: 0, metrics: metrics).isEmpty)
    }

    // MARK: naturalFrames — the un-parked, presentation-plane positions (§4b)

    @Test func naturalFramesAgreeWithTiledPlacementForOnViewColumns() {
        // On-viewport columns get the identical frame from both methods (natural == tiled), so the
        // cross-fade at settle lands pixel-on-pixel for everything still on screen.
        let layout = fourColumns()
        let natural = layout.naturalFrames(scrollOffset: 0, metrics: metrics)
        let tiled = layout.targetFrames(scrollOffset: 0, metrics: metrics)
        for id in [w10, w20, w21, w30] { #expect(natural[id] == tiled[id]) }
        #expect(natural.count == 5)                        // exhaustive over the strip's windows
    }

    @Test func naturalFramesSlideOffViewColumnsOffScreenInsteadOfParking() {
        // col3 [900,1200) is off the right of the [0,900) viewport. `targetFrames` parks it to a
        // left-edge sliver; `naturalFrames` keeps it at its natural strip position, sliding off the
        // *right* edge — full size, x = 900. The two disagree by design (layer slides, real parks).
        let layout = fourColumns()
        let natural = layout.naturalFrames(scrollOffset: 0, metrics: metrics)
        let tiled = layout.targetFrames(scrollOffset: 0, metrics: metrics)
        #expect(natural[w40] == Rect(x: 900, y: 0, width: 300, height: 600))   // slid off the right edge
        #expect(tiled[w40] == Rect(x: -299, y: 0, width: 300, height: 600))    // parked off the left edge
        #expect(natural[w40] != tiled[w40])
    }

    // MARK: size corrections — a column built around what the window actually is

    /// `metrics` with one window's answer recorded. `wanted` defaults to the ⅓ preset width (300) and
    /// the full column height (600) — i.e. the question the fixture strip actually asks a lone window.
    private func corrected(_ id: WindowId, wanted: Size = Size(width: 300, height: 600),
                           actual: Size) -> LayoutMetrics {
        var m = metrics
        m.corrections = [id: SizeCorrection(wanted: wanted, actual: actual)]
        return m
    }

    @Test func aColumnWidensToTheAnswerItsWindowGave() {
        // w10's app refused 300 and took 400. col0 becomes 400 wide, and every column right of it
        // starts 100 further along — derived, because they accumulate from the same widths.
        let frames = fourColumns().targetFrames(
            scrollOffset: 0, metrics: corrected(w10, actual: Size(width: 400, height: 600)))
        #expect(frames[w10] == Rect(x: 0, y: 0, width: 400, height: 600))
        #expect(frames[w20] == Rect(x: 400, y: 0, width: 300, height: 300))
        #expect(frames[w30] == Rect(x: 700, y: 0, width: 300, height: 600))
    }

    @Test func anAnswerToADifferentQuestionIsIgnored() {
        // The ratchet guard, and the whole reason a correction stores its question. This answer was
        // given when the layout wanted 450 (a ½ preset, say); the strip now wants 300, so the app has
        // never been asked *this* and the preset stands untouched.
        let stale = corrected(w10, wanted: Size(width: 450, height: 600),
                              actual: Size(width: 500, height: 600))
        #expect(fourColumns().targetFrames(scrollOffset: 0, metrics: stale)[w10]
                == Rect(x: 0, y: 0, width: 300, height: 600))
    }

    @Test func aNarrowerAnswerDoesNotShrinkTheColumn() {
        // A terminal quantizing 8 pt *down* leaves a gap inside its column, which is cosmetic; only
        // the other direction overlaps a neighbour, which is the invariant the strip promises. So
        // geometry widens and never narrows — quiescence for this case is the reducer's job
        // (`Engine.isAlreadyPlaced`), not the layout's.
        let narrow = corrected(w10, actual: Size(width: 292, height: 600))
        #expect(fourColumns().targetFrames(scrollOffset: 0, metrics: narrow)[w10]
                == Rect(x: 0, y: 0, width: 300, height: 600))
    }

    @Test func aColumnIsNeverWidenedPastTheViewport() {
        // The runaway guard: two stacked windows on different quantization grids can chase each other
        // a few points at a time. The cap costs nothing real — a column this wide already fills the
        // viewport, and `Strip.offsetToReveal` shows an over-wide column's left edge.
        let huge = corrected(w10, actual: Size(width: 5000, height: 600))
        #expect(fourColumns().targetFrames(scrollOffset: 0, metrics: huge)[w10]
                == Rect(x: 0, y: 0, width: 900, height: 600))   // the whole 900 working width
    }

    @Test func aTallerAnswerFloorsTheWindowAndItsStackmateRedivides() {
        // col1 stacks w20 and w21, so each is asked for 300 of the 600. w20 refuses and takes 400;
        // w21 gets what is left. The column's *width* is untouched — the axes are independent facts.
        var m = metrics
        m.corrections = [w20: SizeCorrection(wanted: Size(width: 300, height: 300),
                                             actual: Size(width: 300, height: 400))]
        let frames = fourColumns().targetFrames(scrollOffset: 0, metrics: m)
        #expect(frames[w20] == Rect(x: 300, y: 0, width: 300, height: 400))
        #expect(frames[w21] == Rect(x: 300, y: 400, width: 300, height: 200))
    }

    @Test func correctionsReachTheSweepAndTheScrollTargetsToo() {
        // The reason corrections ride in `metrics`: if `targetFrames` widened a column while the
        // visibility and scroll queries kept the preset, the two would accumulate different left edges
        // and place windows at the wrong x. Widening col0 by 400 pushes col3 to [1300,1600), so the
        // reveal offset moves by the same 400 and col2 is evicted from the viewport.
        let layout = fourColumns()
        let wide = corrected(w10, actual: Size(width: 700, height: 600))
        #expect(layout.scrollOffsetToReveal(window: w40, from: 0, metrics: metrics) == 300)
        #expect(layout.scrollOffsetToReveal(window: w40, from: 0, metrics: wide) == 700)
        #expect(layout.visibleWindowIds(scrollOffset: 0, metrics: wide) == [w10, w20, w21])
    }

    @Test func naturalFramesAndTargetFramesAgreeUnderACorrection() {
        // The cross-fade lands pixel-on-pixel only while the two planes resolve the same geometry.
        let wide = corrected(w10, actual: Size(width: 400, height: 600))
        let layout = fourColumns()
        let natural = layout.naturalFrames(scrollOffset: 0, metrics: wide)
        let tiled = layout.targetFrames(scrollOffset: 0, metrics: wide)
        for id in [w10, w20, w21, w30] { #expect(natural[id] == tiled[id]) }
    }

    @Test func theUncorrectedSizeIsTheQuestionACorrectionAnswers() {
        // Round trip: the question `uncorrectedSize` reports is exactly the one a stored answer must
        // match to be consulted, *including* while a correction is already in force — otherwise the
        // record would re-derive itself against its own effect and ratchet.
        let layout = fourColumns()
        #expect(layout.uncorrectedSize(of: w10, metrics: metrics) == Size(width: 300, height: 600))
        #expect(layout.uncorrectedSize(of: w20, metrics: metrics) == Size(width: 300, height: 300))
        let wide = corrected(w10, actual: Size(width: 400, height: 600))
        #expect(layout.uncorrectedSize(of: w10, metrics: wide) == Size(width: 300, height: 600))
        #expect(layout.uncorrectedSize(of: WindowId(999), metrics: metrics) == nil)
    }

    @Test func resolvedWidthByIdIsTheNumberACycleAnimatesTo() {
        let layout = fourColumns()
        let wide = corrected(w10, actual: Size(width: 400, height: 600))
        #expect(layout.resolvedWidth(ofColumn: ColumnId(1), metrics: metrics) == 300)
        #expect(layout.resolvedWidth(ofColumn: ColumnId(1), metrics: wide) == 400)
        #expect(layout.resolvedWidth(ofColumn: ColumnId(99), metrics: metrics) == nil)
    }

    // MARK: visibility + scroll targets

    @Test func visibleWindowIdsAreTheOnScreenColumnsInLayoutOrder() {
        // scrollOffset 0: col0/1/2 visible → w10, w20, w21, w30; col3 (w40) parked.
        #expect(fourColumns().visibleWindowIds(scrollOffset: 0, metrics: metrics) == [w10, w20, w21, w30])
    }

    /// The transition scope, and the reason it is a *sweep* rather than "visible at the start ∪ visible
    /// at the end". A viewport travelling further than its own width crosses columns that are on screen
    /// at neither endpoint — and a scoped-by-endpoints transition gives those columns no captured layer,
    /// so they slide across the cover as holes showing the wallpaper.
    ///
    /// Narrow metrics on purpose: a 300-wide viewport over four 300-wide columns, so a 0 → 900 scroll is
    /// three screens and cols 1–2 are strictly interior to it.
    @Test func sweptWindowIdsIncludeColumnsCrossedInTheMiddleOfTheScroll() {
        let narrow = LayoutMetrics(workingArea: Rect(x: 0, y: 0, width: 300, height: 600),
                                   widthPresets: PresetCycle([.proportion(1.0)]),
                                   columnGap: 0, windowGap: 0)
        let layout = fourColumns()

        // What the endpoints alone can see: the first column and the last.
        #expect(layout.visibleWindowIds(scrollOffset: 0, metrics: narrow) == [w10])
        #expect(layout.visibleWindowIds(scrollOffset: 900, metrics: narrow) == [w40])
        // What the motion actually crosses: everything, in layout (z-)order.
        #expect(layout.sweptWindowIds(from: 0, to: 900, metrics: narrow) == [w10, w20, w21, w30, w40])
    }

    @Test func sweptWindowIdsAreDirectionAgnostic() {
        let layout = fourColumns()
        #expect(layout.sweptWindowIds(from: 300, to: 0, metrics: metrics)
                == layout.sweptWindowIds(from: 0, to: 300, metrics: metrics))
    }

    /// The scope is the sweep **plus a shoulder on each end** — the column a further command can pull
    /// into view before a capture requested at that moment could possibly arrive (2026-07-26). A
    /// zero-length sweep is therefore *not* the still-frame question; it is that question widened by
    /// one column on either side.
    @Test func sweptWindowIdsCarryAShoulderPastEachEndOfTheSweep() {
        let layout = fourColumns()
        // Viewport 900 at offset 0 shows col0–col2; col3 is the shoulder past the right end.
        #expect(layout.visibleWindowIds(scrollOffset: 0, metrics: metrics) == [w10, w20, w21, w30])
        #expect(layout.sweptWindowIds(from: 0, to: 0, metrics: metrics) == [w10, w20, w21, w30, w40])
        // Off the origin, a shoulder appears on the left too: at 300 the viewport shows col1–col3,
        // and col0 is one `focus left` away.
        #expect(layout.visibleWindowIds(scrollOffset: 300, metrics: metrics) == [w20, w21, w30, w40])
        #expect(layout.sweptWindowIds(from: 300, to: 300, metrics: metrics) == [w10, w20, w21, w30, w40])
    }

    /// The shoulder is clamped to the strip, never invented: a sweep that already reaches both ends
    /// has nothing to flank it with, and the answer is the whole strip rather than out-of-range indices.
    @Test func aShoulderStopsAtTheEndsOfTheStrip() {
        let layout = fourColumns()
        #expect(layout.sweptWindowIds(from: 0, to: 1200, metrics: metrics)
                == [w10, w20, w21, w30, w40])
        #expect(Layout().sweptWindowIds(from: 0, to: 300, metrics: metrics).isEmpty)
    }

    @Test func scrollOffsetToRevealPullsAnOffViewColumnIntoView() {
        // w40 is in col3 [900,1200); from offset 0 in a 900 viewport, reveal scrolls to 1200−900=300.
        #expect(fourColumns().scrollOffsetToReveal(window: w40, from: 0, metrics: metrics) == 300)
        // An already-visible window needs no scroll.
        #expect(fourColumns().scrollOffsetToReveal(window: w10, from: 0, metrics: metrics) == 0)
    }

    @Test func scrollOffsetToCenterCentersTheWindowsColumn() {
        // col3 spans [900,1200), mid 1050; a 900 viewport centers at 1050 − 450 = 600.
        #expect(fourColumns().scrollOffsetToCenter(window: w40, metrics: metrics) == 600)
    }

    @Test func scrollTargetsAreNilForAWindowNotOnTheStrip() {
        let unknown = WindowId(999)
        #expect(fourColumns().scrollOffsetToReveal(window: unknown, from: 0, metrics: metrics) == nil)
        #expect(fourColumns().scrollOffsetToCenter(window: unknown, metrics: metrics) == nil)
    }

    // MARK: width presets + membership

    @Test func setWidthPresetChangesResolvedColumnWidth() {
        var layout = Layout(columns: [ColumnLayout(id: ColumnId(1), windowIds: [w10])])
        let m = LayoutMetrics(
            workingArea: Rect(x: 0, y: 0, width: 900, height: 600),
            widthPresets: .defaultWidths)             // ⅓, ½, ⅔ → 300, 450, 600
        #expect(layout.strip(metrics: m).columnWidths == [300])  // preset 0 = ⅓
        layout.setWidthPreset(2, ofColumn: ColumnId(1))          // ⅔
        #expect(layout.strip(metrics: m).columnWidths == [600])
        layout.setWidthPreset(0, ofColumn: ColumnId(99))         // unknown column → no-op, total
        #expect(layout.strip(metrics: m).columnWidths == [600])
    }

    // MARK: in-flight widths — the presentation plane mid-resize (M4 part 3)

    /// The override exists so a `cycleWidth` can be *animated*: the strip is resolved against a width
    /// part-way between two presets. A partial map is meaningful — the columns it doesn't name keep
    /// their presets — because only the resizing column is ever in flight.
    @Test func inFlightWidthsOverrideOnlyTheColumnsTheyName() {
        let layout = fourColumns()                        // four ⅓ columns = 300 each
        let widths = layout.strip(metrics: metrics, widths: [ColumnId(2): 450]).columnWidths
        #expect(widths == [300, 450, 300, 300])
        // An override for a column that isn't there (it left the layout mid-resize) is ignored.
        #expect(layout.strip(metrics: metrics, widths: [ColumnId(99): 1]).columnWidths == [300, 300, 300, 300])
        // No overrides ⇒ exactly the presets, i.e. every other caller is unaffected.
        #expect(layout.strip(metrics: metrics).columnWidths == [300, 300, 300, 300])
    }

    /// **The resize animation, in one assertion.** Growing col1 by 150 must widen *its* windows and
    /// slide every column to its right by the same 150 — and that is not choreographed anywhere, it
    /// falls out of `Strip.leftEdge` accumulating the same widths it always did.
    @Test func anInFlightWidthGrowsItsColumnAndSlidesEveryColumnToItsRight() {
        let layout = fourColumns()
        let before = layout.naturalFrames(scrollOffset: 0, metrics: metrics)
        let during = layout.naturalFrames(scrollOffset: 0, metrics: metrics, widths: [ColumnId(2): 450])

        #expect(during[w10] == before[w10])                          // left of the resize: untouched
        #expect(during[w20]?.width == 450)                           // the resizing column's stack…
        #expect(during[w21]?.width == 450)                           // …both windows of it
        #expect(during[w20]?.minX == 300)                            // …anchored at its left edge
        #expect(during[w30]?.minX == (before[w30]?.minX ?? 0) + 150)  // right of it: pushed along
        #expect(during[w40]?.minX == (before[w40]?.minX ?? 0) + 150)
        #expect(during[w30]?.width == 300)                           // …at their own unchanged widths
    }

    /// The convergence property the cross-fade depends on: when the animator arrives, the override
    /// equals the preset, so the layers are exactly where `targetFrames` put the real windows.
    @Test func aSettledWidthOverrideIsIndistinguishableFromThePreset() {
        var layout = Layout(columns: [
            ColumnLayout(id: ColumnId(1), windowIds: [w10]),
            ColumnLayout(id: ColumnId(2), windowIds: [w20]),
        ])
        let m = LayoutMetrics(workingArea: Rect(x: 0, y: 0, width: 900, height: 600),
                              widthPresets: .defaultWidths)          // ⅓, ½, ⅔ → 300, 450, 600
        layout.setWidthPreset(1, ofColumn: ColumnId(1))              // ½ = 450, the animator's target
        let arrived = layout.naturalFrames(scrollOffset: 0, metrics: m, widths: [ColumnId(1): 450])
        #expect(arrived == layout.naturalFrames(scrollOffset: 0, metrics: m))
        #expect(arrived[w10] == layout.targetFrames(scrollOffset: 0, metrics: m)[w10])
    }

    @Test func columnIndexOfWindowFindsTheStack() {
        let layout = fourColumns()
        #expect(layout.columnIndex(ofWindow: w21) == 1)   // w21 is the 2nd window of col1
        #expect(layout.columnIndex(ofWindow: w40) == 3)
        #expect(layout.columnIndex(ofWindow: WindowId(999)) == nil)
    }

    @Test func layoutRoundTripsThroughCodable() throws {
        let layout = fourColumns()
        let data = try JSONEncoder().encode(layout)
        let back = try JSONDecoder().decode(Layout.self, from: data)
        #expect(back == layout)                            // columns + allocator watermark preserved
    }

    /// The watermark is serialized state (§7 replay), and the only way to observe it is to mint. Mutate
    /// first so it has advanced past `max(id)`, then check that the original and the decoded copy hand
    /// out the *same* next id — a round-trip that dropped it would silently re-issue ColumnId(5).
    @Test func aRoundTrippedLayoutMintsTheSameNextColumnId() throws {
        var layout = fourColumns()
        layout.extract(window: w21, toNewColumnAt: 0)      // mints 5; watermark now 6
        var back = try JSONDecoder().decode(Layout.self, from: try JSONEncoder().encode(layout))
        #expect(back == layout)
        let churn = [w10, w20, w21, w30, w40, WindowId(50)]   // a newcomer, so both must mint
        layout.reconcile(stripWindowIds: churn)
        back.reconcile(stripWindowIds: churn)
        #expect(back.columns.last?.id == layout.columns.last?.id)
        #expect(back.columns.last?.id == ColumnId(6))
    }
}
