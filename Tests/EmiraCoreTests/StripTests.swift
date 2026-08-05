import Foundation
import Testing
@testable import EmiraCore

/// The infinite-strip placement/scroll/viewport math (`Strip`) and the cyclable size presets
/// (`PresetSize` / `PresetCycle`).
@Suite struct StripTests {

    // Reused fixture: three columns of 100 / 200 / 300 pt with a 10 pt gap at the strip origin.
    //   col0 [  0, 100)   col1 [110, 310)   col2 [320, 620)
    private let strip = Strip(columnWidths: [100, 200, 300], gap: 10)

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

    // Magnets — the rests a driven scroll settles on

    @Test func magnetOffsetsAreBothEdgesOfEveryColumn() {
        // Viewport 400 over col0 [0,100) col1 [110,310) col2 [320,620). Left flushes are 0/110/320;
        // right flushes are 100−400, 310−400, 620−400 → clamped to 0, 0, 220. maxOffset = 620−400.
        #expect(strip.magnetOffsets(viewportWidth: 400, centered: false) == [0, 110, 220])
    }

    @Test func aColumnWiderThanTheViewportKeepsBothOfItsRests() {
        // One 900-wide column against a 400 viewport: left-flush at 0 and right-flush at 500, and the
        // right half is unreachable without the second one.
        let wide = Strip(columnWidths: [900], gap: 10)
        #expect(wide.magnetOffsets(viewportWidth: 400, centered: false) == [0, 500])
    }

    @Test func aStripShorterThanTheViewportHasOneRest() {
        // Every candidate clamps onto `origin`, and the dedupe collapses them to the one rest there is.
        let short = Strip(columnWidths: [100, 100], gap: 10)
        #expect(short.magnetOffsets(viewportWidth: 400, centered: false) == [0])
    }

    @Test func anEmptyStripHasNoMagnetsAndClampsInstead() {
        let empty = Strip(columnWidths: [], gap: 10)
        #expect(empty.magnetOffsets(viewportWidth: 400, centered: false).isEmpty)
        #expect(empty.magnetOffset(nearest: 900, viewportWidth: 400, centered: false) == 0)
    }

    @Test func centeringTakesTheColumnCentresUnclamped() {
        // Centering means putting a column in the middle, which at the strip's ends *means* showing
        // space past it — so these are deliberately outside [origin, maxOffset].
        let centres = strip.magnetOffsets(viewportWidth: 400, centered: true)
        #expect(centres == [-150, 10, 270])         // 50−200, 210−200, 470−200
    }

    @Test func nearestMagnetTakesTheHigherOfATie() {
        let rests = strip.magnetOffsets(viewportWidth: 400, centered: false)   // [0, 110, 220]
        #expect(rests.contains(110))
        #expect(strip.magnetOffset(nearest: 104, viewportWidth: 400, centered: false) == 110)
        #expect(strip.magnetOffset(nearest: 40, viewportWidth: 400, centered: false) == 0)
        // Exactly between 0 and 110: forward wins, the rule `Monitors` breaks a name-distance tie with.
        #expect(strip.magnetOffset(nearest: 55, viewportWidth: 400, centered: false) == 110)
    }

    @Test func nearestMagnetIsTotalPastEitherEnd() {
        #expect(strip.magnetOffset(nearest: -9000, viewportWidth: 400, centered: false) == 0)
        #expect(strip.magnetOffset(nearest: 9000, viewportWidth: 400, centered: false) == 220)
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

    /// Sub-point overlap is flush. Both ends, since the arithmetic that ties is symmetric.
    @Test func visibleColumnIndicesTreatsSubPointOverlapAsFlush() {
        // col0 [0,100): a viewport starting 0.1 pt inside it sees a tenth of a point — not on screen.
        #expect(strip.visibleColumnIndices(viewportWidth: 100, offset: 99.9) == [1])
        // …and the same at the far edge: col1 starts 0.1 pt before the viewport's right edge.
        #expect(strip.visibleColumnIndices(viewportWidth: 110.1, offset: 0) == [0])
        // A whole point either side still counts, so the tolerance stays under anything a user sees.
        #expect(strip.visibleColumnIndices(viewportWidth: 100, offset: 99) == [0, 1])
        #expect(strip.visibleColumnIndices(viewportWidth: 111, offset: 0) == [0, 1])
    }

    // 500 + 450 in a 1000-wide viewport: 50 pt of slack at the right edge.
    private let pair = Strip(columnWidths: [500, 450], gap: 0)

    @Test func growCatchesWhereTheLastWholeColumnGoesFlush() {
        #expect(pair.resizeDetent(ofColumn: 0, growing: true, viewportWidth: 1000, offset: 0,
                                  centered: false) == 50)
    }

    /// The notch is left by being *in* it: flush, that bound starts on an edge and crosses none, which is
    /// what lets a second press push a column off screen without anything being remembered. What it
    /// reaches instead is the edge beyond — col0's own right edge, 450 out, where col1 has gone entirely
    /// and col0 fills the viewport. Nothing is out there going the other way.
    @Test func aFlushStripCatchesOnlyOnTheEdgeBeyond() {
        let flush = Strip(columnWidths: [550, 450], gap: 0)
        #expect(flush.resizeDetent(ofColumn: 0, growing: true, viewportWidth: 1000, offset: 0,
                                   centered: false) == 450)
        #expect(flush.resizeDetent(ofColumn: 0, growing: false, viewportWidth: 1000, offset: 0,
                                   centered: false) == nil)
    }

    /// Grow and shrink catch on different columns: one protects what is whole, the other collects what
    /// is cut. col1 [500,950) is whole with 50 to spare, col2 [950,1250) hangs 250 over the edge.
    @Test func theTwoDirectionsCatchOnOppositeSidesOfTheViewportEdge() {
        let three = Strip(columnWidths: [500, 450, 300], gap: 0)
        #expect(three.resizeDetent(ofColumn: 0, growing: true, viewportWidth: 1000, offset: 0,
                                   centered: false) == 50)
        #expect(three.resizeDetent(ofColumn: 0, growing: false, viewportWidth: 1000, offset: 0,
                                   centered: false) == 250)
    }

    /// A column with nothing but slack ahead of it catches going up and never going down — there is no
    /// edge out there to collect.
    @Test func shrinkingWithNothingCutCrossesNoEdge() {
        #expect(pair.resizeDetent(ofColumn: 1, growing: false, viewportWidth: 1000, offset: 0,
                                  centered: false) == nil)
        #expect(pair.resizeDetent(ofColumn: 1, growing: true, viewportWidth: 1000, offset: 0,
                                  centered: false) == 50)
    }

    /// A focused column already cut has no edge below the viewport's right one to protect — but the
    /// reveal holds it against that edge as it grows, so the strip travels left under a viewport whose
    /// left edge crosses the fixed edges behind: col1's own, 50 out, where it exactly fills the viewport.
    @Test func growingAnAlreadyCutColumnCatchesWhereItFillsTheViewport() {
        // col1 [500,1450) runs 450 past a 1000-wide viewport.
        let cut = Strip(columnWidths: [500, 950], gap: 0)
        #expect(cut.resizeDetent(ofColumn: 1, growing: true, viewportWidth: 1000, offset: 0,
                                 centered: false) == 50)
        #expect(cut.resizeDetent(ofColumn: 1, growing: false, viewportWidth: 1000, offset: 0,
                                 centered: false) == 450)   // …back to whole
    }

    /// The right edge is not always the first crossed. A column resting flush against it — every focused
    /// column at the strip's end, and any the reveal has just pulled in — scrolls the viewport from the
    /// first point of the delta, freezing the edges from it on against the viewport's right and leaving
    /// the left edge the only one still sweeping. [300, 300, 600] rests at offset 200 with col0 cut;
    /// growing col2 catches 100 out, where col1 goes flush left and the pair exactly fill the viewport.
    @Test func growingAgainstTheRightEdgeCatchesOnTheLeftOne() {
        let trailing = Strip(columnWidths: [300, 300, 600], gap: 0)
        #expect(trailing.offsetToReveal(2, viewportWidth: 1000, from: 0) == 200)
        #expect(trailing.resizeDetent(ofColumn: 2, growing: true, viewportWidth: 1000, offset: 200,
                                      centered: false) == 100)
        // Past the notch, the next one is col2's own left edge: col1 gone, col2 filling the viewport.
        let packed = Strip(columnWidths: [300, 300, 700], gap: 0)
        #expect(packed.resizeDetent(ofColumn: 2, growing: true, viewportWidth: 1000, offset: 300,
                                    centered: false) == 300)
    }

    /// The mirror, on the same strip: shrinking at the far end pulls the viewport off `maxOffset` rather
    /// than uncovering anything to the right, and the notch is where the column it had cut comes back
    /// whole — 200 out, the whole strip flush inside the viewport.
    @Test func shrinkingAtTheFarEndCatchesWhereTheCutColumnComesBackWhole() {
        let trailing = Strip(columnWidths: [300, 300, 600], gap: 0)
        #expect(trailing.resizeDetent(ofColumn: 2, growing: false, viewportWidth: 1000, offset: 200,
                                      centered: false) == 200)
        // Flush, there is nothing cut left or right, and the strip no longer fills the viewport.
        let short = Strip(columnWidths: [300, 300, 400], gap: 0)
        #expect(short.resizeDetent(ofColumn: 2, growing: false, viewportWidth: 1000, offset: 0,
                                   centered: false) == nil)
    }

    /// Centred, both viewport edges sweep at half the width's speed, so the notch is the nearer of the
    /// two, doubled. col1 [200,600) centred in 1000 looks from −100: col0's left edge is 100 away, col2's
    /// right edge 40 past the far side and so already cut — col0 is what the press protects.
    @Test func centredResizeCatchesOnTheNearerEdgeAtHalfSpeed() {
        let centred = Strip(columnWidths: [200, 400, 340], gap: 0)
        #expect(centred.resizeDetent(ofColumn: 1, growing: true, viewportWidth: 1000, offset: -100,
                                     centered: true) == 200)
        // Uncentred, the same strip only ever asks about its right edge, where col1's own is 300 short.
        #expect(centred.resizeDetent(ofColumn: 1, growing: true, viewportWidth: 1000, offset: -100,
                                     centered: false) == 300)
    }

    @Test func detentIsNilOffTheEndsOfTheStrip() {
        #expect(pair.resizeDetent(ofColumn: 2, growing: true, viewportWidth: 1000, offset: 0,
                                  centered: false) == nil)
        #expect(Strip(columnWidths: [], gap: 0).resizeDetent(ofColumn: 0, growing: true,
                                                             viewportWidth: 1000, offset: 0,
                                                             centered: false) == nil)
    }
}
