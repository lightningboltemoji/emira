import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// Resizing a window by its own handle. The strip adopts the size the drag left behind rather than
// taking the window back — which is only safe because `Drag` says a hand was on it: AX reports a
// resize identically whoever asked for it, and our own placements provoke one every time.

@Suite struct EngineHandResizeTests {

    /// `halfWidthSnap` throughout, so a placement lands in the command's own batch and the frames read
    /// off it directly. A 1000×800 display, no gaps: columns are 500 wide, a stack of two is 400 each.
    static func columns(_ count: UInt64, config: Config = EngineFix.halfWidthSnap) -> State {
        EngineFix.run(EngineFix.booted(config: config),
                      (1...count).map { .windowCreated(EngineFix.snapshot($0)) }).0
    }

    /// A stacked column: w2 consumed into w1's, both 500×400.
    static func stack() -> State {
        var s = columns(2)
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        return s
    }

    /// One drag, press to release, leaving `id` at `frame`.
    static func drag(_ s: State, _ id: WindowId, to frame: Rect) -> (State, [Effect]) {
        EngineFix.run(s, [.dragBegan, .windowFrameChanged(id, frame), .dragEnded])
    }

    /// Where the truth plane says every window belongs right now.
    static func placed(_ s: State) -> [WindowId: Rect] {
        s.workspaces.targetFrames(s.placements())
    }

    /// The window the layout stacks on top of `column`, and the one under it.
    static func rows(_ s: State) -> (top: WindowId, bottom: WindowId) {
        let stack = s.layout.columns[0].windowIds
        return (stack[0], stack[1])
    }

    // The gate: a frame change is intent only under a hand

    /// The echo guard, and the reason `Drag` exists at all. Our own `setFrame` provokes the identical
    /// `AXWindowResized` an app clamping one does, and both arrive as `windowFrameChanged` — so with no
    /// button down, a frame change teaches the layout nothing and the window is taken back.
    @Test func aFrameChangeWithNoButtonDownIsStillTakenBack() {
        var s = Self.columns(2)
        let before = Self.placed(s)[WindowId(2)]!

        var fx: [Effect] = []
        (s, fx) = EngineFix.run(s, [.windowFrameChanged(WindowId(2), Rect(x: 500, y: 0,
                                                                          width: 620, height: 800)),
                                    .dragEnded])
        #expect(s.layout.columns[1].widthOverride == nil)
        #expect(s.drag == .idle)
        #expect(EngineFix.approx(EngineFix.placement(of: WindowId(2), in: fx)!, before))
    }

    /// The subject latch. A placement pass mid-drag writes the stackmates, and an app clamping one of
    /// those reports a frame change with the button still down — so only the *first* window to move
    /// under one press is read as the thing being dragged.
    @Test func onlyTheFirstWindowToMoveUnderOnePressIsAdopted() {
        var s = Self.columns(2)
        (s, _) = EngineFix.run(s, [
            .dragBegan,
            .windowFrameChanged(WindowId(1), Rect(x: 0, y: 0, width: 620, height: 800)),
            .windowFrameChanged(WindowId(2), Rect(x: 620, y: 0, width: 300, height: 800)),
        ])
        #expect(s.drag == .subject(WindowId(1)))
        (s, _) = Engine.reduce(s, .dragEnded)

        #expect(s.layout.columns[0].widthOverride == .fixed(620))
        #expect(s.layout.columns[1].widthOverride == nil)      // the clamp, not a second drag
    }

    /// A window emira does not place is already the app's to size, so nothing latches onto it and the
    /// press releases having taught the strip nothing.
    @Test func aWindowOffTheStripNeverBecomesTheSubject() {
        var s = Self.columns(1)
        (s, _) = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(9, role: .dialog))])
        (s, _) = EngineFix.run(s, [.dragBegan,
                                   .windowFrameChanged(WindowId(9), Rect(x: 10, y: 10,
                                                                          width: 300, height: 300))])
        #expect(s.drag == .armed)
    }

    /// The setting is one gate at the latch, so nothing downstream needs a second opinion about it.
    @Test func theSettingRefusesTheAdoptionOutright() {
        let config = Config(widthPresets: PresetCycle([.proportion(0.5)]),
                            interactiveResize: false, transitionMode: .off)
        var s = Self.columns(2, config: config)
        (s, _) = Self.drag(s, WindowId(2), to: Rect(x: 500, y: 0, width: 620, height: 800))
        #expect(s.layout.columns[1].widthOverride == nil)
    }

    /// A drag that only *moved* the window is not a resize, and until the strip can read one as an
    /// instruction, taking the window back is the honest answer.
    @Test func aMoveDragIsStillTakenBack() {
        var s = Self.columns(2)
        let before = Self.placed(s)[WindowId(2)]!

        var fx: [Effect] = []
        (s, fx) = Self.drag(s, WindowId(2), to: before.offsetBy(dx: 40, dy: 60))
        #expect(s.layout.columns[1].widthOverride == nil)
        #expect(s.workspaces.heightOverrides.isEmpty)
        #expect(EngineFix.approx(EngineFix.placement(of: WindowId(2), in: fx)!, before))
    }

    // Width

    /// The width lands as a `widthOverride` — the same rung `grow`/`shrink` write, so the first
    /// `cycle-width` afterwards puts the column back on the ladder rather than having to guess which
    /// rung a dragged width was nearest.
    @Test func aWidthDragBecomesTheColumnsOwnWidth() {
        var s = Self.columns(2)
        var fx: [Effect] = []
        (s, fx) = Self.drag(s, WindowId(2), to: Rect(x: 500, y: 0, width: 620, height: 800))

        #expect(s.layout.columns[1].widthOverride == .fixed(620))
        #expect(EngineFix.approxScalar(Self.placed(s)[WindowId(2)]!.width, 620))
        // No `setFrame` for the subject: it is already the size the layout now wants, which is the
        // adoption working rather than a placement missed.
        #expect(EngineFix.placement(of: WindowId(2), in: fx) == nil)

        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        #expect(s.layout.columns[1].widthOverride == nil)
    }

    /// One width for the whole column, since that is what a column is: a drag on the lower window of a
    /// stack widens the column, and its stackmate with it.
    @Test func aWidthDragOnOneOfAStackWidensTheColumn() {
        var s = Self.stack()
        let (top, bottom) = Self.rows(s)
        (s, _) = Self.drag(s, bottom, to: Rect(x: 0, y: 400, width: 700, height: 400))

        #expect(s.layout.columns[0].widthOverride == .fixed(700))
        #expect(EngineFix.approxScalar(Self.placed(s)[top]!.width, 700))
    }

    /// A stackmate that will not be that narrow holds the column open — `Layout.resolvedWidth`'s max
    /// rule, reached through a drag instead of through `shrink`. The drag is honoured as far as the
    /// windows will actually go, which is the whole of "get as close as possible" on this axis.
    @Test func aStackmateThatRefusesTheWidthHoldsTheColumnOpen() {
        var s = Self.stack()
        let (top, bottom) = Self.rows(s)
        (s, _) = Self.drag(s, top, to: Rect(x: 0, y: 0, width: 200, height: 400))
        #expect(s.layout.columns[0].widthOverride == .fixed(200))

        // The stackmate answers the 200 it was asked for with 340 — the question `forgetCorrections`
        // left it free to be asked afresh.
        let asked = Self.placed(s)[bottom]!
        (s, _) = Engine.reduce(s, .placementCorrected(bottom, requested: asked,
                                                      actual: Rect(x: asked.minX, y: asked.minY,
                                                                   width: 340, height: asked.height)))
        #expect(EngineFix.approxScalar(
            s.layout.resolvedWidth(of: s.layout.columns[0], metrics: s.metrics()!), 340))
    }

    /// A drag of the **left** edge nails the column's right edge. The strip accumulates left to right,
    /// so a column grows rightward whichever edge is pulled; the viewport takes the difference, which
    /// is what puts the moving edge back under the pointer.
    @Test func aLeftEdgeDragMovesTheViewportRatherThanTheRightEdge() {
        var s = Self.columns(2)
        #expect(s.viewport.offset.current == 0)

        (s, _) = Self.drag(s, WindowId(2), to: Rect(x: 400, y: 0, width: 600, height: 800))

        #expect(EngineFix.approxScalar(s.viewport.offset.current, 100))   // exactly the width delta
        let placed = Self.placed(s)[WindowId(2)]!
        #expect(EngineFix.approxScalar(placed.minX, 400))                 // the edge the hand moved
        #expect(EngineFix.approxScalar(placed.maxX, 1000))                // the edge it did not
    }

    /// A right-edge drag leaves the viewport where it was — the compensation is the left edge's alone.
    @Test func aRightEdgeDragLeavesTheViewportAlone() {
        var s = Self.columns(2)
        (s, _) = Self.drag(s, WindowId(1), to: Rect(x: 0, y: 0, width: 300, height: 800))
        #expect(s.viewport.offset.current == 0)
    }

    // Height

    /// The height lands on the new middle rung, and the stackmate absorbs it: pinning one window is
    /// already an instruction to the autos beneath it, so a divider drag needs nothing else.
    @Test func aHeightDragPinsTheWindowAndTheStackmateAbsorbsIt() {
        var s = Self.stack()
        let (top, bottom) = Self.rows(s)
        (s, _) = Self.drag(s, top, to: Rect(x: 0, y: 0, width: 500, height: 500))

        #expect(s.workspaces.heightOverrides[top] == .fixed(500))
        #expect(EngineFix.approxScalar(Self.placed(s)[top]!.height, 500))
        let below = Self.placed(s)[bottom]!
        #expect(EngineFix.approxScalar(below.height, 300))               // 800 − 500
        #expect(EngineFix.approxScalar(below.minY, 500))                 // …and it moved up under it
    }

    /// The neighbour on the dragged edge goes back to auto. Without it a column whose windows are every
    /// one of them pinned has nobody to hand the difference to, and repeated drags walk the last window
    /// off the bottom of the screen.
    @Test func theNeighbourOnTheDraggedEdgeGoesBackToAuto() {
        var s = Self.stack()
        let (top, bottom) = Self.rows(s)

        // Pin the lower window first, so both windows in the column hold an intent.
        (s, _) = Engine.reduce(s, .focusChanged(bottom, origin: .system))
        (s, _) = Engine.reduce(s, .command(.cycleHeight))
        #expect(s.workspaces.heightSelections[bottom] != nil)

        (s, _) = Self.drag(s, top, to: Rect(x: 0, y: 0, width: 500, height: 500))

        #expect(s.workspaces.heightSelections[bottom] == nil)            // back to sharing
        #expect(s.workspaces.heightOverrides[bottom] == nil)
        let heights = [top, bottom].map { Self.placed(s)[$0]!.height }
        #expect(EngineFix.approxScalar(heights.reduce(0, +), 800))       // still fills its box exactly
    }

    /// The backstop: every other window in the stack keeps at least `minimumWindowHeight`, so no drag
    /// can subscribe a column past its own height. Their real floors are larger and unknown until
    /// asked — those arrive as corrections and the water-fill honours them.
    @Test func aHeightDragCannotSubscribeTheColumnPastItsOwnHeight() {
        var s = Self.stack()
        let (top, bottom) = Self.rows(s)
        (s, _) = Self.drag(s, top, to: Rect(x: 0, y: 0, width: 500, height: 900))

        #expect(s.workspaces.heightOverrides[top] == .fixed(800 - Engine.minimumWindowHeight))
        #expect(EngineFix.approxScalar(Self.placed(s)[bottom]!.height, Engine.minimumWindowHeight))
    }

    /// A window alone in its column may be made short. The model already permits it — `cycle-height` on
    /// a solo window pins it to a rung and leaves the rest of the column empty — so refusing the drag
    /// would be refusing something a keybinding already does.
    @Test func aWindowAloneInItsColumnMayBeMadeShort() {
        var s = Self.columns(1)
        (s, _) = Self.drag(s, WindowId(1), to: Rect(x: 0, y: 0, width: 500, height: 500))

        #expect(s.workspaces.heightOverrides[WindowId(1)] == .fixed(500))
        #expect(EngineFix.approxScalar(Self.placed(s)[WindowId(1)]!.height, 500))
    }

    /// The height stack shadows rather than replaces, exactly as the width stack does: a cycle clears
    /// the dragged height and resumes the ladder at its first rung.
    @Test func cycleHeightClearsAnAdoptedHeight() {
        var s = Self.stack()
        let (top, _) = Self.rows(s)
        (s, _) = Self.drag(s, top, to: Rect(x: 0, y: 0, width: 500, height: 500))
        #expect(s.workspaces.heightOverrides[top] == .fixed(500))

        (s, _) = Engine.reduce(s, .focusChanged(top, origin: .system))
        (s, _) = Engine.reduce(s, .command(.cycleHeight))
        #expect(s.workspaces.heightOverrides[top] == nil)
        #expect(s.workspaces.heightSelections[top] == 0)
    }

    /// A corner drag is both axes at once, and neither branch knows about the other.
    @Test func aCornerDragIsAdoptedOnBothAxes() {
        var s = Self.stack()
        let (top, _) = Self.rows(s)
        (s, _) = Self.drag(s, top, to: Rect(x: 0, y: 0, width: 640, height: 520))

        #expect(s.layout.columns[0].widthOverride == .fixed(640))
        #expect(s.workspaces.heightOverrides[top] == .fixed(520))
    }

    /// A dragged height goes with its window when the window leaves the strip, on the same reconcile
    /// pass `heightSelections` has always been filtered by.
    @Test func anAdoptedHeightDoesNotOutliveItsWindow() {
        var s = Self.stack()
        let (top, _) = Self.rows(s)
        (s, _) = Self.drag(s, top, to: Rect(x: 0, y: 0, width: 500, height: 500))
        #expect(s.workspaces.heightOverrides[top] == .fixed(500))

        (s, _) = Engine.reduce(s, .windowDestroyed(top))
        #expect(s.workspaces.heightOverrides[top] == nil)
    }
}
