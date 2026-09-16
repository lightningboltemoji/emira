import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// A window that places itself — leaving fullscreen, restoring a remembered size, sliding a sidebar out.
// Nobody drew that rectangle, so unlike a hand resize (`EngineHandResizeTests`) there is nothing in it
// to adopt: the strip says where a tiled window goes, and the answer is a re-place once it stops.
//
// The two live either side of one gate, which is why the second suite here is about the gate itself:
// the reports are identical, and a press that a window resized itself just after must not be read as
// the hand that drew it.

@Suite struct EngineSelfPlacementTests {

    static func columns(_ count: UInt64) -> State {
        EngineFix.run(EngineFix.booted(config: EngineFix.halfWidthSnap),
                      (1...count).map { .windowCreated(EngineFix.snapshot($0)) }).0
    }

    static func placed(_ s: State) -> [WindowId: Rect] { s.workspaces.targetFrames(s.placements()) }

    /// The Infuse shape: the app restores its own size and the strip puts it back.
    @Test func aWindowThatResizedItselfIsPutBack() throws {
        var s = Self.columns(2)
        let belongs = Self.placed(s)[WindowId(2)]!
        let own = Rect(x: belongs.minX, y: belongs.minY, width: 300, height: 250)

        var fx: [Effect] = []
        (s, fx) = Engine.reduce(s, .windowFrameChanged(WindowId(2), own))
        #expect(fx.isEmpty)                                   // nothing is fought mid-move
        (s, fx) = Engine.reduce(s, .windowSelfPlaced(WindowId(2)))

        #expect(EngineFix.approx(try #require(EngineFix.placement(of: WindowId(2), in: fx)), belongs))
        #expect(s.layout.columns[1].widthOverride == nil)     // and taught the layout nothing
    }

    /// A window that moved itself without resizing is put back too. The strip's promise is that windows
    /// do not overlap, and a window that walked onto its neighbour has broken it.
    @Test func aWindowThatMovedItselfIsPutBack() throws {
        var s = Self.columns(2)
        let belongs = Self.placed(s)[WindowId(2)]!
        let own = Rect(x: belongs.minX - 300, y: belongs.minY, width: belongs.width,
                       height: belongs.height)

        var fx: [Effect] = []
        (s, _) = Engine.reduce(s, .windowFrameChanged(WindowId(2), own))
        (s, fx) = Engine.reduce(s, .windowSelfPlaced(WindowId(2)))

        #expect(EngineFix.approx(try #require(EngineFix.placement(of: WindowId(2), in: fx)), belongs))
    }

    /// The pass is the comparison. A window that stopped where it already belonged — our own placement
    /// echoing back, which is most of what this event ever reports — writes nothing at all.
    @Test func aWindowThatIsWhereItBelongsCostsNoWrite() {
        var s = Self.columns(2)

        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowSelfPlaced(WindowId(2)))

        #expect(fx.isEmpty)
    }

    /// An app that takes the size and not the place has answered, and re-placing asks it again. The
    /// reports it sends back on refusing are what would otherwise make that a standing exchange, since a
    /// position teaches the geometry nothing and the layout goes on wanting the same frame.
    @Test func aPlaceAnAppAlreadyRefusedIsNotAskedForAgain() throws {
        var s = Self.columns(2)
        let belongs = Self.placed(s)[WindowId(2)]!
        let elsewhere = Rect(x: belongs.minX + 200, y: belongs.minY,
                             width: belongs.width, height: belongs.height)

        // The refusal, as the executor reports it: our frame, the app's place.
        (s, _) = Engine.reduce(s, .placementCorrected(WindowId(2), requested: belongs,
                                                      actual: elsewhere))
        #expect(s.world.refusedFrames[WindowId(2)] == belongs)

        var fx: [Effect] = []
        (s, fx) = Engine.reduce(s, .windowSelfPlaced(WindowId(2)))
        #expect(fx.isEmpty, "the same question is not asked twice")
    }

    /// And the record is the question, so it expires on its own. A refusal of some other frame says
    /// nothing about the one the layout is asking for now, and that one gets asked.
    @Test func aRefusalSaysNothingAboutADifferentFrame() throws {
        var s = Self.columns(2)
        let belongs = Self.placed(s)[WindowId(2)]!
        let stale = Rect(x: belongs.minX - 400, y: belongs.minY,
                         width: belongs.width, height: belongs.height)

        (s, _) = Engine.reduce(s, .placementCorrected(WindowId(2), requested: stale, actual: belongs))
        #expect(s.world.refusedFrames[WindowId(2)] == stale)

        var fx: [Effect] = []
        (s, _) = Engine.reduce(s, .windowFrameChanged(WindowId(2), Rect(
            x: belongs.minX, y: belongs.minY, width: 300, height: 250)))
        (s, fx) = Engine.reduce(s, .windowSelfPlaced(WindowId(2)))

        #expect(EngineFix.approx(try #require(EngineFix.placement(of: WindowId(2), in: fx)), belongs))
    }

    /// A window off the strip draws its own rectangle by definition, so there is nothing here to answer.
    @Test func aFloatIsTheAppsToPlace() {
        var s = Self.columns(1)
        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(9, role: .dialog)))
        let own = Rect(x: 10, y: 10, width: 300, height: 300)

        var fx: [Effect] = []
        (s, _) = Engine.reduce(s, .windowFrameChanged(WindowId(9), own))
        (s, fx) = Engine.reduce(s, .windowSelfPlaced(WindowId(9)))

        #expect(fx.isEmpty)
        #expect(s.world.windows[WindowId(9)]?.frame == own)
    }
}

//
// The gate. A hand draws a size while the button is **down**; the wait that follows the release is for
// the subject's frames to finish draining, and a window that starts moving inside it is the app.

@Suite struct EngineDragBracketTests {

    /// A press, a release, and then the app resizing itself while the release is still being waited out
    /// — a click on a button that makes a window change shape. The size is the app's and is taken back.
    @Test func aWindowThatResizesItselfAfterTheReleaseIsNotAdopted() throws {
        var s = EngineSelfPlacementTests.columns(2)
        let belongs = EngineSelfPlacementTests.placed(s)[WindowId(2)]!
        let own = Rect(x: belongs.minX, y: belongs.minY, width: 300, height: 250)

        var fx: [Effect] = []
        (s, fx) = EngineFix.run(s, [.dragBegan, .dragReleased,
                                    .windowFrameChanged(WindowId(2), own), .dragEnded])

        #expect(s.drag == .idle)
        #expect(s.layout.columns[1].widthOverride == nil)
        #expect(EngineFix.approx(try #require(EngineFix.placement(of: WindowId(2), in: fx)), belongs))
    }

    /// The same press with the frames arriving where a hand puts them — before the button comes up.
    /// The release still waits, and what it waits for is the rest of this window's frames.
    @Test func aWindowThatMovesUnderThePressIsStillAdopted() {
        var s = EngineSelfPlacementTests.columns(2)
        let belongs = EngineSelfPlacementTests.placed(s)[WindowId(2)]!
        let drawn = Rect(x: belongs.minX, y: belongs.minY, width: 620, height: belongs.height)

        (s, _) = EngineFix.run(s, [.dragBegan, .windowFrameChanged(WindowId(2), drawn)])
        #expect(s.drag == .subject(WindowId(2)))

        // The release does not disturb the latch, and the frames still draining reach `World` first.
        (s, _) = EngineFix.run(s, [.dragReleased,
                                   .windowFrameChanged(WindowId(2), drawn), .dragEnded])

        #expect(s.layout.columns[1].widthOverride == .proportion(0.62))
    }

    /// Every frame of a self-animated resize lands inside the wait, and each one restarts it — so what
    /// a column without this gate takes is a width the window is only passing through.
    @Test func noFrameOfASelfAnimatedResizeIsAdopted() {
        var s = EngineSelfPlacementTests.columns(2)
        let belongs = EngineSelfPlacementTests.placed(s)[WindowId(2)]!
        func frame(_ width: Double) -> Rect {
            Rect(x: belongs.minX, y: belongs.minY, width: width, height: belongs.height)
        }

        (s, _) = EngineFix.run(s, [.dragBegan, .dragReleased] +
                               [440.0, 380, 320, 300].map { .windowFrameChanged(WindowId(2), frame($0)) } +
                               [.dragEnded])

        #expect(s.layout.columns[1].widthOverride == nil)
    }

    /// A press that latched nothing is over at the release, so the wait after it cannot arm the latch
    /// for a window the user never touched.
    @Test func theReleaseDisarmsAPressThatMovedNothing() {
        var s = EngineSelfPlacementTests.columns(1)
        (s, _) = Engine.reduce(s, .dragBegan)
        #expect(s.drag == .armed)

        (s, _) = Engine.reduce(s, .dragReleased)
        #expect(s.drag == .idle)
    }
}
