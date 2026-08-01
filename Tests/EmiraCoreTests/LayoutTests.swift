import Foundation
import Testing
@testable import EmiraCore

/// The layout assembler: structure (`reconcile`, columns, width presets) and `targetFrames` turning
/// columns + scroll offset into concrete tiled / parked frames.
@Suite struct LayoutTests {

    // Window ids used across the assembly fixtures.
    private let w10 = WindowId(10), w20 = WindowId(20), w21 = WindowId(21)
    private let w30 = WindowId(30), w40 = WindowId(40)

    // The minting mutators take a `ColumnAllocator` (one id space across every workspace, so it lives in
    // `Workspaces` in the product). Each test that mints declares its own `ColumnAllocator(next: 5)` —
    // seeded past `fourColumns`' explicit ids 1–4, as `Workspaces.init(focused:strips:)` would.

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

    // reconcile — the World→Layout membership bridge

    @Test func reconcileAppendsNewcomersAsSingleWindowColumns() {
        var ids = ColumnAllocator(next: 5)
        var layout = Layout()
        layout.reconcile(stripWindowIds: [w10, w20, w30], columnIds: &ids)
        #expect(layout.columns.count == 3)
        #expect(layout.columns.map(\.windowIds) == [[w10], [w20], [w30]])  // one each, input order
        #expect(layout.allWindowIds == [w10, w20, w30])
    }

    @Test func reconcileDropsDepartedWindowsAndEmptyColumns() {
        var ids = ColumnAllocator(next: 5)
        var layout = Layout()
        layout.reconcile(stripWindowIds: [w10, w20, w30], columnIds: &ids)
        let idOfW20Column = layout.columns[1].id
        layout.reconcile(stripWindowIds: [w10, w30], columnIds: &ids)       // w20 gone → its column emptied → dropped
        #expect(layout.columns.map(\.windowIds) == [[w10], [w30]])
        #expect(layout.columnIndex(withId: idOfW20Column) == nil)
    }

    @Test func reconcilePreservesExistingColumnIdentityAndArrangement() {
        var ids = ColumnAllocator(next: 5)
        // A two-window column survives a churn that only adds a newcomer: same column id, same stack.
        var layout = Layout(columns: [ColumnLayout(id: ColumnId(7), windowIds: [w20, w21])])
        layout.reconcile(stripWindowIds: [w20, w21, w40], columnIds: &ids)
        #expect(layout.columns[0].id == ColumnId(7))       // identity preserved
        #expect(layout.columns[0].windowIds == [w20, w21]) // arrangement preserved
        #expect(layout.columns[1].windowIds == [w40])      // newcomer appended as its own column
        // The freshly-minted id doesn't collide with the supplied one.
        #expect(layout.columns[1].id != ColumnId(7))
    }

    @Test func reconcileIsIdempotentForAnUnchangedSet() {
        var ids = ColumnAllocator(next: 5)
        var layout = Layout()
        layout.reconcile(stripWindowIds: [w10, w20], columnIds: &ids)
        let before = layout.columns
        layout.reconcile(stripWindowIds: [w10, w20], columnIds: &ids)
        #expect(layout.columns == before)                  // no churn, no new columns minted
    }

    // structural mutation — the strip's editing primitives

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
        var ids = ColumnAllocator(next: 5)
        var layout = fourColumns()
        let edit = layout.extract(window: w21, toNewColumnAt: 2, columnIds: &ids)
        #expect(edit.moved)
        #expect(edit.destroyedColumn == nil)                  // the source keeps w20, so it survives
        #expect(layout.columns.count == 5)
        #expect(layout.columns[1].windowIds == [w20])
        #expect(layout.columns[2].windowIds == [w21])
        #expect(layout.columns[2].id == ColumnId(5))          // watermark resumed past the supplied 4
    }

    @Test func extractingLeftAndExtractingRightDifferByOneIndex() {
        var ids = ColumnAllocator(next: 5)
        var left = fourColumns(), right = fourColumns()
        left.extract(window: w21, toNewColumnAt: 1, columnIds: &ids)           // source sits at index 1 → land before it
        right.extract(window: w21, toNewColumnAt: 2, columnIds: &ids)          // → land after it
        #expect(left.columns.map(\.windowIds) == [[w10], [w21], [w20], [w30], [w40]])
        #expect(right.columns.map(\.windowIds) == [[w10], [w20], [w21], [w30], [w40]])
    }

    /// The bug shape this prevents: destroying the column and minting an identical replacement compares
    /// equal by arrangement while the `ColumnId` — the handle `Motion.columnWidths` and the cover's
    /// animation identity key on — silently changed. Comparing the whole value also catches the stray
    /// mint, since `Layout`'s `Equatable` covers the allocator watermark.
    @Test func extractingAWindowAlreadyAloneInItsColumnIsANoOp() {
        var ids = ColumnAllocator(next: 5)
        var layout = fourColumns()
        let before = layout
        #expect(layout.extract(window: w10, toNewColumnAt: 3, columnIds: &ids) == .none)
        #expect(layout == before)
    }

    @Test func anExtractedColumnInheritsTheWidthPresetItLeft() {
        var ids = ColumnAllocator(next: 5)
        var layout = fourColumns()
        layout.setWidthPreset(1, ofColumn: ColumnId(2))       // the stacked column, now preset 1
        layout.extract(window: w21, toNewColumnAt: 2, columnIds: &ids)
        #expect(layout.columns[2].widthPreset == 1)
        // Two presets in the cycle would resolve differently; with one, both are still 300.
        let m = LayoutMetrics(workingArea: Rect(x: 0, y: 0, width: 900, height: 600),
                              widthPresets: PresetCycle([.proportion(1.0 / 3.0), .proportion(2.0 / 3.0)]),
                              columnGap: 0, windowGap: 0)
        #expect(layout.strip(metrics: m).columnWidths[1] == 600)   // source: ⅔ of 900
        #expect(layout.strip(metrics: m).columnWidths[2] == 600)   // and the extracted one matches
    }

    /// An override is part of the width *intent*, so it travels with the window the same way the preset
    /// does — otherwise an expel would silently snap a grown column back onto the ladder.
    @Test func anExtractedColumnInheritsTheWidthOverrideItLeft() {
        var ids = ColumnAllocator(next: 5)
        var layout = fourColumns()
        layout.setWidthOverride(.fixed(420), ofColumn: ColumnId(2))
        layout.extract(window: w21, toNewColumnAt: 2, columnIds: &ids)
        #expect(layout.columns[1].widthOverride == .fixed(420))
        #expect(layout.columns[2].widthOverride == .fixed(420))
        #expect(layout.strip(metrics: metrics).columnWidths[1] == 420)
        #expect(layout.strip(metrics: metrics).columnWidths[2] == 420)
    }

    /// The override supersedes the preset, and `cycleWidth` (via `setWidthPreset`) is what puts the
    /// column back on the ladder — one rung past where the ladder was left, not a nearest-rung guess.
    @Test func aWidthOverrideSupersedesThePresetUntilTheLadderIsResumed() {
        var layout = fourColumns()
        let m = LayoutMetrics(workingArea: Rect(x: 0, y: 0, width: 900, height: 600),
                              widthPresets: PresetCycle([.proportion(1.0 / 3.0), .proportion(2.0 / 3.0)]),
                              columnGap: 0, windowGap: 0)
        #expect(layout.strip(metrics: m).columnWidths[0] == 300)

        layout.setWidthOverride(.proportion(0.5), ofColumn: ColumnId(1))
        #expect(layout.strip(metrics: m).columnWidths[0] == 450)
        layout.setWidthOverride(.fixed(250), ofColumn: ColumnId(1))
        #expect(layout.strip(metrics: m).columnWidths[0] == 250)

        layout.setWidthPreset(1, ofColumn: ColumnId(1))
        #expect(layout.columns[0].widthOverride == nil)
        #expect(layout.strip(metrics: m).columnWidths[0] == 600)
    }

    /// The three width intents are a stack, not three ways of writing one number: fullscreen shadows an
    /// override, which shadows the ladder. Because it shadows rather than replaces, coming back off is
    /// exact — which is why `fullscreen` stores no "what it was" and needs no restore policy.
    @Test func fullscreenShadowsTheWidthUnderneathAndUncoversItExactly() {
        var layout = fourColumns()
        let m = LayoutMetrics(workingArea: Rect(x: 0, y: 0, width: 900, height: 600),
                              widthPresets: PresetCycle([.proportion(1.0 / 3.0), .proportion(2.0 / 3.0)]),
                              columnGap: 0, windowGap: 0)

        // …over a ladder rung.
        layout.setWidthPreset(1, ofColumn: ColumnId(1))
        #expect(layout.strip(metrics: m).columnWidths[0] == 600)
        layout.setFullscreen(.plain, ofColumn: ColumnId(1))
        #expect(layout.strip(metrics: m).columnWidths[0] == 900)
        layout.setFullscreen(nil, ofColumn: ColumnId(1))
        #expect(layout.strip(metrics: m).columnWidths[0] == 600)   // the rung, untouched
        #expect(layout.columns[0].widthPreset == 1)

        // …and over a `grow`n override, which is the case a saved point count would have to get right.
        layout.setWidthOverride(.fixed(250), ofColumn: ColumnId(1))
        layout.setFullscreen(.plain, ofColumn: ColumnId(1))
        #expect(layout.strip(metrics: m).columnWidths[0] == 900)
        #expect(layout.columns[0].widthOverride == .fixed(250))    // still there, merely shadowed
        layout.setFullscreen(nil, ofColumn: ColumnId(1))
        #expect(layout.strip(metrics: m).columnWidths[0] == 250)
    }

    /// An explicit width verb clears fullscreen: a width the user asked for out loud must be one they
    /// can see, and left shadowed it would be an invisible number.
    @Test func anExplicitWidthIntentClearsFullscreen() {
        for setIntent in [{ (l: inout Layout) in l.setWidthPreset(1, ofColumn: ColumnId(1)) },
                          { (l: inout Layout) in l.setWidthOverride(.fixed(250), ofColumn: ColumnId(1)) }] {
            var layout = fourColumns()
            layout.setFullscreen(.plain, ofColumn: ColumnId(1))
            setIntent(&layout)
            #expect(!layout.columns[0].isFullscreen)
        }
    }

    /// Fullscreen travels with an expelled window like the preset and the override do: an intent that
    /// failed to follow would snap the window back as a side effect of a structural edit.
    @Test func anExtractedColumnInheritsFullscreen() {
        var ids = ColumnAllocator(next: 5)
        var layout = fourColumns()
        layout.setFullscreen(.plain, ofColumn: ColumnId(2))
        layout.extract(window: w21, toNewColumnAt: 2, columnIds: &ids)
        #expect(layout.columns[1].isFullscreen)
        #expect(layout.columns[2].isFullscreen)
    }

    /// Total, like its two siblings: an id no longer on the strip is a silent no-op, never a trap.
    @Test func settingFullscreenOnAnUnknownColumnIsANoOp() {
        var layout = fourColumns()
        let before = layout
        layout.setFullscreen(.plain, ofColumn: ColumnId(99))
        #expect(layout == before)
    }

    @Test func extractingClampsAnOutOfRangeIndexToTheEndsOfTheStrip() {
        var ids = ColumnAllocator(next: 5)
        var low = fourColumns(), high = fourColumns()
        low.extract(window: w21, toNewColumnAt: -5, columnIds: &ids)
        high.extract(window: w21, toNewColumnAt: 99, columnIds: &ids)
        #expect(low.columns.first?.windowIds == [w21])
        #expect(high.columns.last?.windowIds == [w21])
    }

    /// The strip has an origin, not an edge — index 0 is an ordinary place on an unbounded axis, so an
    /// expel there creates its column rather than refusing like a consume with no neighbour would.
    @Test func extractingAtTheStripOriginStillCreatesTheColumn() {
        var ids = ColumnAllocator(next: 5)
        var layout = fourColumns()
        #expect(layout.extract(window: w21, toNewColumnAt: 0, columnIds: &ids).moved)
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

    // structural invariants — tests whose subject is an absence

    /// The two rules `Layout.columns` is `private(set)` to protect. Run a mixed script and re-check
    /// after every step, because a mutator that breaks either one does it transiently.
    @Test func noStructuralMutationEverBreaksTheStripsInvariants() {
        var ids = ColumnAllocator(next: 5)
        var layout = fourColumns()
        let all = Set(layout.allWindowIds)
        func check(_ step: String) {
            #expect(layout.columns.allSatisfy { !$0.windowIds.isEmpty }, "empty column after \(step)")
            #expect(Set(layout.allWindowIds) == all, "window lost after \(step)")
            #expect(layout.allWindowIds.count == all.count, "window duplicated after \(step)")
        }
        layout.moveColumn(ColumnId(2), to: 0);                          check("moveColumn")
        layout.extract(window: w21, toNewColumnAt: 0, columnIds: &ids);                  check("extract left")
        layout.move(window: w21, toColumn: ColumnId(1), at: 0);         check("merge")
        layout.moveWindowWithinColumn(w21, to: 1);                      check("reorder")
        layout.move(window: w30, toColumn: ColumnId(4), at: 0);         check("merge onto w40")
        layout.extract(window: w30, toNewColumnAt: 99, columnIds: &ids);                 check("extract right")
        layout.moveColumn(ColumnId(4), to: 0);                          check("moveColumn again")
        layout.move(window: w10, toColumn: ColumnId(2), at: 0);         check("merge alone")
    }

    /// The load-bearing one: every `Engine` handler reconciles at its top, so an arrangement `reconcile`
    /// undoes is a command that does nothing at all — and it would look correct in isolation.
    /// `World.stripWindowIds` is id-sorted, deliberately unrelated to layout order, so that is the input.
    @Test func aStructuralMutationSurvivesTheNextReconcile() {
        var ids = ColumnAllocator(next: 5)
        var layout = fourColumns()
        layout.extract(window: w21, toNewColumnAt: 0, columnIds: &ids)
        layout.moveColumn(ColumnId(1), to: 3)
        let arranged = layout
        layout.reconcile(stripWindowIds: [w10, w20, w21, w30, w40], columnIds: &ids)   // id order, as World supplies
        #expect(layout == arranged)
    }

    /// Guards the `init(columns:)` watermark-rewind hazard: a mutator that rebuilt the layout through
    /// that initializer would resume the allocator below a destroyed column's id and re-issue it.
    @Test func columnIdsAreNeverReusedAfterAColumnIsDestroyed() {
        var ids = ColumnAllocator(next: 5)
        var layout = fourColumns()
        var seen = Set(layout.columns.map(\.id))
        layout.extract(window: w21, toNewColumnAt: 4, columnIds: &ids)                 // mints 5
        seen.formUnion(layout.columns.map(\.id))
        let born = try! #require(layout.columnIndex(ofWindow: w21))
        let dead = layout.columns[born].id
        #expect(layout.move(window: w21, toColumn: ColumnId(3), at: 0).destroyedColumn == dead)
        layout.extract(window: w21, toNewColumnAt: 0, columnIds: &ids)                 // mints again, must not reuse
        let reborn = try! #require(layout.columns.first?.id)
        #expect(reborn == ColumnId(6))
        #expect(!seen.contains(reborn))
    }

    // targetFrames — tiled placement + off-viewport parking

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
        // col3 parked: ordinal 0, size 300×600 → a nub in the bottom-right corner, x = 900 − 1 and
        // y = 600 − 40, the rest of it off the display's right and bottom.
        #expect(frames[w40] == Rect(x: 899, y: 560, width: 300, height: 600))
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
        // col0 now off the left → parked at ordinal 0 (the corner nub, wherever it scrolled off).
        #expect(frames[w10] == Rect(x: 899, y: 560, width: 300, height: 600))
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
        // Scroll far right so several columns park; assert the parked frames are all distinct.
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

    // naturalFrames — the un-parked, presentation-plane positions

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
        // corner nub; `naturalFrames` keeps it at its natural strip position, sliding off the *right*
        // edge — full size, x = 900. The two disagree by design (layer slides, real parks).
        let layout = fourColumns()
        let natural = layout.naturalFrames(scrollOffset: 0, metrics: metrics)
        let tiled = layout.targetFrames(scrollOffset: 0, metrics: metrics)
        #expect(natural[w40] == Rect(x: 900, y: 0, width: 300, height: 600))   // slid off the right edge
        #expect(tiled[w40] == Rect(x: 899, y: 560, width: 300, height: 600))   // parked at its nub
        #expect(natural[w40] != tiled[w40])
    }

    // size corrections — a column built around what the window actually is

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

    @Test func aNarrowerAnswerNarrowsTheColumnAndTheStripClosesUp() {
        // A column's width *is* strip extent, so an under-filled column is not merely a cosmetic gap:
        // the shortfall is phantom desktop that scroll targets, the tile-vs-park split and the sweep all
        // treat as content. The column follows the answer down and every column right of it closes up.
        let narrow = corrected(w10, actual: Size(width: 292, height: 600))
        let frames = fourColumns().targetFrames(scrollOffset: 0, metrics: narrow)
        #expect(frames[w10] == Rect(x: 0, y: 0, width: 292, height: 600))
        #expect(frames[w20] == Rect(x: 292, y: 0, width: 300, height: 300))
        #expect(frames[w30] == Rect(x: 592, y: 0, width: 300, height: 600))
    }

    /// Keyed to its question in both directions: an answer given to a width nobody is asking for any
    /// more is not consulted, so a preset cycle retires it with no expiry to maintain.
    @Test func aNarrowerAnswerToADifferentQuestionIsIgnored() {
        let stale = corrected(w10, wanted: Size(width: 450, height: 600),
                              actual: Size(width: 292, height: 600))
        #expect(fourColumns().targetFrames(scrollOffset: 0, metrics: stale)[w10]
                == Rect(x: 0, y: 0, width: 300, height: 600))
    }

    /// A mixed stack keeps the intent, which is what makes `max` the right operator rather than `min`:
    /// w20 refuses to be 300 wide, but its stackmate w21 has never been asked and may well fill it, so
    /// only a column *nobody* in it can fill gives ground.
    @Test func aColumnWhoseOtherWindowMayStillFillItKeepsItsWidth() {
        let narrow = corrected(w20, actual: Size(width: 240, height: 300))
        #expect(fourColumns().strip(metrics: narrow).columnWidths[1] == 300)
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

    // visibility + scroll targets

    @Test func visibleWindowIdsAreTheOnScreenColumnsInLayoutOrder() {
        // scrollOffset 0: col0/1/2 visible → w10, w20, w21, w30; col3 (w40) parked.
        #expect(fourColumns().visibleWindowIds(scrollOffset: 0, metrics: metrics) == [w10, w20, w21, w30])
    }

    /// Why the transition scope is a *sweep* rather than "visible at the start ∪ visible at the end": a
    /// viewport travelling further than its own width crosses columns on screen at neither endpoint, and
    /// those would slide across the cover with no captured layer, as holes.
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

    /// A column exactly as wide as the viewport puts the strip's end flush with it, so the neighbour is
    /// off screen by construction — and it is the one arrangement where the float residue between
    /// `maxOffset` and the neighbour's right edge decides tile-vs-park. Reachable two ways, `fullscreen`
    /// and `grow` to the ceiling, which resolve to the same width.
    ///
    /// Real geometry, since the residue depends on the exact bits: 1800 pt and 20 pt gaps ⇒ 1760 of
    /// content, whose ⅓ no binary fraction holds.
    @Test(arguments: [true, false])
    func aFullWidthColumnLeavesNoSliverOfItsNeighbourOnScreen(viaFullscreenFlag: Bool) {
        let m = LayoutMetrics(workingArea: Rect(x: 0, y: 39, width: 1800, height: 1130),
                              columnGap: 20, windowGap: 20,
                              outerGaps: EdgeInsets(top: 8, left: 20, bottom: 20, right: 20))
        let layout = Layout(columns: [
            ColumnLayout(id: ColumnId(1), windowIds: [w10], widthPreset: 0),          // ⅓ of 1760
            ColumnLayout(id: ColumnId(2), windowIds: [w20],
                         widthOverride: viaFullscreenFlag ? nil : .proportion(1.0),
                         fullscreen: viaFullscreenFlag ? .plain : nil),
        ])

        let offset = layout.scrollOffsetToReveal(window: w20, from: 0, metrics: m) ?? 0
        #expect(layout.visibleWindowIds(scrollOffset: offset, metrics: m) == [w20])
        // …and the truth plane parks the neighbour rather than asking AX for an unplaceable frame.
        let frames = layout.targetFrames(scrollOffset: offset, metrics: m)
        #expect(frames[w10]?.minX ?? 0 > m.workingArea.maxX - 2)
    }

    @Test func sweptWindowIdsAreDirectionAgnostic() {
        let layout = fourColumns()
        #expect(layout.sweptWindowIds(from: 300, to: 0, metrics: metrics)
                == layout.sweptWindowIds(from: 0, to: 300, metrics: metrics))
    }

    /// The scope is the sweep plus a shoulder on each end — the column a further command can pull into
    /// view before a capture requested at that moment could arrive. So a zero-length sweep is the
    /// visible set widened by one column on either side, not the visible set itself.
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

    // width presets + membership

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

    // in-flight widths — the presentation plane mid-resize

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

    /// The resize animation in one assertion: growing col1 by 150 widens *its* windows and slides every
    /// column to its right by the same 150 — not choreographed, just `Strip.leftEdge` accumulating.
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

    /// `Layout`'s serialized state is purely structural — the allocator watermark lives in `Workspaces`,
    /// and `WorkspaceTests.aRoundTrippedSetMintsTheSameNextColumnId` pins it.
    @Test func layoutRoundTripsThroughCodable() throws {
        let layout = fourColumns()
        let data = try JSONEncoder().encode(layout)
        let back = try JSONDecoder().decode(Layout.self, from: data)
        #expect(back == layout)
    }
}
