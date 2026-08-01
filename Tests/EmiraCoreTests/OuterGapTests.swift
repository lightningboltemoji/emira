import Foundation
import Testing
@testable import EmiraCore

/// Outer gaps — the margin the strip keeps clear at the edges of the working area, and the split it
/// forces: `LayoutMetrics.contentArea` (the *logical* viewport the strip lives in) versus `workingArea`
/// (the *physical* extent that decides what is on screen). Nearly every test here pins which of the two
/// a given query asks, because they agree exactly when the gaps are zero — so a wrong choice is silent.
@Suite struct OuterGapTests {

    private let w0 = WindowId(1), w1 = WindowId(2), w2 = WindowId(3), w3 = WindowId(4)

    /// A 1000×700 display with a uniform 40 pt margin → a 920×620 content area at (40, 40). Columns are
    /// half the *content* width = 460, so two fill it exactly and the third starts precisely at the
    /// content area's right edge — the alignment that makes the margin the only thing it can bleed into.
    ///
    ///   content viewport [0, 920) in strip space · columns at strip 0 · 460 · 920 · 1380
    private func metrics(columnGap: Double = 0, windowGap: Double = 0,
                         gaps: EdgeInsets = EdgeInsets(uniform: 40)) -> LayoutMetrics {
        LayoutMetrics(
            workingArea: Rect(x: 0, y: 0, width: 1000, height: 700),
            widthPresets: PresetCycle([.proportion(0.5)]),
            columnGap: columnGap, windowGap: windowGap, outerGaps: gaps)
    }

    private func fourColumns() -> Layout {
        Layout(columns: (0..<4).map {
            ColumnLayout(id: ColumnId(UInt64($0 + 1)), windowIds: [WindowId(UInt64($0 + 1))])
        })
    }

    @Test func theContentAreaIsTheWorkingAreaInsetByTheGaps() {
        let m = metrics()
        #expect(m.contentArea == Rect(x: 40, y: 40, width: 920, height: 620))
        #expect(m.workingArea == Rect(x: 0, y: 0, width: 1000, height: 700))
    }

    /// The physical viewport is the logical one *outset* by the horizontal gaps — a wider viewport
    /// parked `outerGaps.left` further left. One shift, no new geometry.
    @Test func thePhysicalViewportIsTheLogicalOneOutsetByTheHorizontalGaps() {
        let m = metrics(gaps: EdgeInsets(top: 5, left: 10, bottom: 15, right: 50))
        #expect(m.contentArea == Rect(x: 10, y: 5, width: 940, height: 680))
        let view = m.physicalViewport(at: 300)
        #expect(view.offset == 290)                 // 300 − left gap
        #expect(view.width == 1000)                 // the whole display, gaps included
        // …and it composes with the sweep's widening rather than each shifting on its own.
        #expect(m.physicalViewport(at: 300, widenedBy: 250).width == 1250)
        #expect(m.physicalViewport(at: 300, widenedBy: 250).offset == 290)
    }

    // What "100%" means

    /// A proportion is a share of the *content* width, so a full-width column fills the strip's area and
    /// leaves the margin showing — which is what a user who asked for a margin means by full.
    @Test func aProportionResolvesAgainstTheContentWidthNotTheDisplay() {
        let m = metrics()
        let full = ColumnLayout(id: ColumnId(1), windowIds: [w0], widthPreset: 0,
                                widthOverride: .proportion(1.0))
        #expect(Layout(columns: [full]).resolvedWidth(of: full, metrics: m) == 920)
        // Half of the content width, not half of the display.
        let half = ColumnLayout(id: ColumnId(1), windowIds: [w0])
        #expect(Layout(columns: [half]).resolvedWidth(of: half, metrics: m) == 460)
    }

    /// `fullscreen` means the same 100% everything else does: the content width, so a fullscreen column
    /// fills the strip's area with the outer margin still showing. A second definition of "full" is how
    /// the two verbs would come to rest one outer gap apart.
    @Test func fullscreenIsTheContentWidthNotTheDisplayWidth() {
        let m = metrics()                            // 1000 wide, 40 pt outer gaps ⇒ 920 of content
        let column = ColumnLayout(id: ColumnId(1), windowIds: [w0], fullscreen: .plain)
        #expect(Layout(columns: [column]).resolvedWidth(of: column, metrics: m) == 920)
    }

    /// The width floor a correction imposes is capped at the content width too — one definition of
    /// "as wide as it can be", shared by the preset, the override and the correction.
    @Test func aCorrectionCannotWidenAColumnPastTheContentWidth() {
        var m = metrics()
        m.corrections = [w0: SizeCorrection(wanted: Size(width: 460, height: 620),
                                            actual: Size(width: 5000, height: 620))]
        let column = ColumnLayout(id: ColumnId(1), windowIds: [w0])
        #expect(Layout(columns: [column]).resolvedWidth(of: column, metrics: m) == 920)
    }

    // The load-bearing split — tile vs park

    /// At rest the third column's left edge sits exactly on the content area's right edge, so it is
    /// invisible to the *logical* viewport and visible to the *physical* one. It must be tiled, bleeding
    /// 40 pt into the margin: parking it would teleport the window out of the margin, and would pop the
    /// cross-fade since `naturalFrames` never parks and would draw it there anyway.
    @Test func aColumnBleedingIntoTheMarginIsTiledNotParked() {
        let layout = fourColumns()
        let m = metrics()
        let frames = layout.targetFrames(scrollOffset: 0, metrics: m)

        #expect(frames[w0] == Rect(x: 40, y: 40, width: 460, height: 620))    // flush with content left
        #expect(frames[w1] == Rect(x: 500, y: 40, width: 460, height: 620))   // flush with content right
        #expect(frames[w2] == Rect(x: 960, y: 40, width: 460, height: 620))   // 40 pt into the margin
        #expect(layout.visibleWindowIds(scrollOffset: 0, metrics: m) == [w0, w1, w2])

        // And the counterfactual, so the assertion above isn't vacuous: asked of the *logical*
        // viewport, the same strip answers without col2.
        let strip = layout.strip(metrics: m)
        #expect(strip.visibleColumnIndices(viewportWidth: m.contentArea.width, offset: 0) == [0, 1])
        #expect(strip.visibleColumnIndices(viewportWidth: 1000, offset: -40) == [0, 1, 2])
    }

    /// A column genuinely past the display edge still parks — the bleed rule widens the visible set, it
    /// doesn't abolish it.
    @Test func aColumnPastTheDisplayEdgeStillParks() {
        let m = metrics()
        let frames = fourColumns().targetFrames(scrollOffset: 0, metrics: m)
        // col3 sits at strip 1380 — its natural frame would be x = 1420; it is at its nub instead.
        #expect(frames[w3] == Rect(x: 999, y: 660, width: 460, height: 620))
        #expect(!fourColumns().visibleWindowIds(scrollOffset: 0, metrics: m).contains(w3))
    }

    /// A park nub hugs the *physical* corner: inset by the margin it would poke a window 40 pt into the
    /// screen on purpose, which is the opposite of what parking is for.
    @Test func parkNubsHugThePhysicalCornerNotTheContentEdge() {
        let m = metrics()
        // Scroll far right so col0 parks at ordinal 0.
        let frames = fourColumns().targetFrames(scrollOffset: 1380, metrics: m)
        #expect(frames[w0] == Rect(x: 999, y: 660, width: 460, height: 620))   // 1000 − 1, 700 − 40
    }

    // The other side of the split — scroll math frames against the logical viewport

    /// "Reveal this column" means put it where it can comfortably be seen — inside the margin, flush
    /// with the *content* edge. Revealing into the physical extent would scroll a column to sit half in
    /// the gap and call it shown.
    @Test func revealFramesAColumnAgainstTheContentEdge() {
        let layout = fourColumns()
        let m = metrics()
        let offset = layout.scrollOffsetToReveal(window: w2, from: 0, metrics: m)
        #expect(offset == 460)

        // One offset, both halves of the design at once: col2 revealed flush with the content's right
        // edge, and col3 bleeding into the margin behind it.
        let frames = layout.targetFrames(scrollOffset: offset ?? 0, metrics: m)
        #expect(frames[w1] == Rect(x: 40, y: 40, width: 460, height: 620))    // flush, content left
        #expect(frames[w2] == Rect(x: 500, y: 40, width: 460, height: 620))   // flush, content right
        #expect(frames[w3] == Rect(x: 960, y: 40, width: 460, height: 620))   // into the margin
        // …and col0 is the same rule on the other side: scrolled off the *content* area but still
        // bleeding 40 pt into the left margin, so it is tiled there rather than parked.
        #expect(frames[w0] == Rect(x: -420, y: 40, width: 460, height: 620))
    }

    /// Centering and the end-of-strip clamp frame against the content width for the same reason.
    @Test func centerAndClampFrameAgainstTheContentWidth() {
        let layout = fourColumns()
        let m = metrics()
        // col2 spans strip [920, 1380); centered in a 920-wide viewport → 920 + 230 − 460.
        #expect(layout.scrollOffsetToCenter(window: w2, metrics: m) == 690)
        // Content run is 4 × 460 = 1840 wide; the last offset showing strip everywhere is 1840 − 920.
        #expect(layout.clampScrollOffset(99_999, metrics: m) == 920)
    }

    // The rule that tells a user how to pick the numbers

    /// After a reveal leaves a column flush with the content's right edge, its neighbour starts one
    /// `column-gap` further on while the display edge is one `outer-gap-right` further on — so a
    /// neighbour bleeds into the margin at rest iff `outer-gap` > `column-gap`. A config with the
    /// inter-column gap twice the outer one therefore never bleeds except in motion.
    @Test(arguments: [0.0, 20.0, 40.0, 60.0])
    func aNeighbourBleedsAtRestExactlyWhenTheOuterGapExceedsTheColumnGap(columnGap: Double) {
        let layout = fourColumns()
        let m = metrics(columnGap: columnGap)
        let offset = layout.scrollOffsetToReveal(window: w2, from: 0, metrics: m) ?? 0
        let visible = layout.visibleWindowIds(scrollOffset: offset, metrics: m)

        // col2 lands flush with the content's right edge whatever the gap is.
        let frames = layout.targetFrames(scrollOffset: offset, metrics: m)
        #expect(frames[w2]?.maxX == 960)
        // col3's left edge is one column-gap past it; the display ends 40 pt (the outer gap) past that.
        #expect(visible.contains(w3) == (columnGap < 40))
        if columnGap < 40 { #expect(frames[w3]?.minX == 960 + columnGap) }
    }

    /// Top and bottom gaps enter through the column's box, so they cost no arithmetic of their own —
    /// a column is as tall as the logical viewport and the margin above and below falls out.
    @Test func verticalGapsShortenTheColumnAndPushItDown() {
        let m = metrics(windowGap: 20, gaps: EdgeInsets(top: 10, left: 0, bottom: 30, right: 0))
        let layout = Layout(columns: [ColumnLayout(id: ColumnId(1), windowIds: [w0, w1])])
        let frames = layout.targetFrames(scrollOffset: 0, metrics: m)
        // Content height = 700 − 10 − 30 = 660; two windows split (660 − 20) / 2 = 320.
        #expect(frames[w0] == Rect(x: 0, y: 10, width: 500, height: 320))
        #expect(frames[w1] == Rect(x: 0, y: 350, width: 500, height: 320))    // 10 + 320 + 20
    }

    @Test func horizontalGapsCanBeAsymmetric() {
        let m = metrics(gaps: EdgeInsets(top: 0, left: 10, bottom: 0, right: 50))
        // Content is 1000 − 60 = 940 wide at x = 10; a half-width column is 470.
        #expect(m.contentArea == Rect(x: 10, y: 0, width: 940, height: 700))
        let layout = Layout(columns: [ColumnLayout(id: ColumnId(1), windowIds: [w0])])
        #expect(layout.targetFrames(scrollOffset: 0, metrics: m)[w0]
                == Rect(x: 10, y: 0, width: 470, height: 700))
    }

    // Nothing changes at zero

    /// The gaps are additive with the struts and default to nothing, so a zero-gap `LayoutMetrics` is
    /// byte-identical to one without them — which lets the rest of the suite stand as the guard.
    @Test func zeroGapsLeaveEveryQueryUnchanged() {
        let layout = fourColumns()
        let plain = LayoutMetrics(workingArea: Rect(x: 0, y: 0, width: 1000, height: 700),
                                  widthPresets: PresetCycle([.proportion(0.5)]))
        var zeroed = plain
        zeroed.outerGaps = .zero
        #expect(zeroed.contentArea == plain.workingArea)
        #expect(layout.targetFrames(scrollOffset: 300, metrics: zeroed)
                == layout.targetFrames(scrollOffset: 300, metrics: plain))
        #expect(layout.sweptWindowIds(from: 0, to: 900, metrics: zeroed)
                == layout.sweptWindowIds(from: 0, to: 900, metrics: plain))
    }

    /// The capture scope has to be at least the park set, or a window is on screen with no layer to
    /// draw it — so the sweep asks the same physical question `visibleWindowIds` does.
    @Test func theSweptScopeCoversEveryWindowTheMarginMakesVisible() {
        let layout = fourColumns()
        let m = metrics()
        let swept = Set(layout.sweptWindowIds(from: 0, to: 460, metrics: m))
        for offset in stride(from: 0.0, through: 460.0, by: 20.0) {
            for id in layout.visibleWindowIds(scrollOffset: offset, metrics: m) {
                #expect(swept.contains(id), "\(id) is on screen at offset \(offset) with no layer")
            }
        }
    }
}
