import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// `layout.interactive-resize` — the flagship take, and the one that came off `notDemonstrable`.
//
// Two claims, and both are true of the real thing: **nothing but the dragged window moves during the
// drag**, and the last 500 ms are opposite between the two rungs. A third is about the hand rather than
// the setting: it moves only where the script moves it, and a released one stays where it was let go.

@Suite struct DragTests {

    static let area = PreviewModelTests.workingArea

    static func config(_ adopts: Bool) -> Config {
        var config = Config()
        config.interactiveResize = adopts
        return config
    }

    static func state(_ adopts: Bool, at t: Double) throws -> PreviewState {
        let config = Self.config(adopts)
        let take = try #require(Catalog.take(for: "layout.interactive-resize", config: config))
        return PreviewModel.state(of: take, at: t, config: config, workingArea: area)
    }

    static let dragged = WindowId(71)
    static let neighbour = WindowId(72)

    /// What the hand carries, in true points on the test display — 30% of the working width.
    static var carried: Double {
        PreviewModel.metrics(for: Config(), workingArea: area).contentArea.width * 0.30
    }

    @Test func itIsDemonstrableNow() {
        #expect(!Catalog.notDemonstrable.contains("layout.interactive-resize"))
        #expect(Catalog.take(for: "layout.interactive-resize", config: Config()) != nil)
    }

    @Test func theEdgeTracksTheHandOneToOne() throws {
        // Direct manipulation, so equal steps of time are equal steps of width — no easing anywhere.
        let widths = try [0.6, 0.75, 0.9, 1.05].map { t in
            try #require(Self.state(true, at: t).frames[Self.dragged]).width
        }
        let steps = zip(widths.dropFirst(), widths).map(-)
        for step in steps { #expect(abs(step - steps[0]) < 0.001) }
        #expect(steps[0] > 0)
    }

    @Test func theNeighbourDoesNotMoveDuringTheDrag() throws {
        // Adoption is on release, because a strip re-tiling under every intermediate frame would trade
        // writes with the hand. Not a simplification.
        let before = try #require(Self.state(true, at: 0.55).frames[Self.neighbour])
        for t in [0.7, 0.9, 1.1] {
            #expect(try #require(Self.state(true, at: t).frames[Self.neighbour]) == before)
        }
    }

    @Test func theNeighbourIsStillVisibleWhileItIsGrownOver() throws {
        // Which is the whole point of it not moving: a neighbour entirely covered cannot be seen
        // holding still, and the dragged column is the narrow one so that it never is.
        let neighbour = try #require(Self.state(true, at: 1.1).frames[Self.neighbour])
        let dragged = try #require(Self.state(true, at: 1.1).frames[Self.dragged])
        #expect(dragged.maxX > neighbour.minX, "the drag has to reach over the neighbour at all")
        #expect(neighbour.maxX - dragged.maxX > Self.area.width * 0.1,
                "a tenth of the screen of neighbour has to survive the drag")
    }

    @Test func theCursorIsOnTheEdgeItIsCarrying() throws {
        for t in [0.6, 0.85, 1.1] {
            let state = try Self.state(true, at: t)
            let edge = try #require(state.frames[Self.dragged]).maxX
            let cursor = try #require(state.pointer)
            #expect(abs(cursor.x - edge) < 0.001)
        }
    }

    @Test func theHandIsAlreadyOnTheEdgeWhenTheDragTakesItOver() throws {
        // The script's own travel and the drag's grip have to land on the same point, or the cursor
        // jumps sideways at the instant the button goes down — which reads as a dropped frame. Sampled
        // either side of the beat, where the drag has carried the edge nowhere yet.
        let before = try #require(Self.state(true, at: 0.499).pointer)
        let after = try #require(Self.state(true, at: 0.5).pointer)
        #expect(abs(before.x - after.x) < 0.001)
        #expect(abs(before.y - after.y) < 0.001)
    }

    @Test func theHandleAnnouncesItselfWhileTheHandIsOnIt() throws {
        // The hand rests on the edge, so the shape is the handle's from the first frame — and it is
        // dropped for the walk back, where the cursor is over a neighbour rather than over a handle.
        #expect(try Self.state(true, at: 0.2).scene.pointer?.shape == .resizeEW)
        #expect(try Self.state(true, at: 0.2).scene.pointer?.isPressed == false)
        #expect(try Self.state(true, at: 0.8).scene.pointer?.isPressed == true)
        #expect(try Self.state(true, at: 2.9).scene.pointer?.shape == .arrow)
        #expect(try Self.state(true, at: 3.4).scene.pointer?.shape == .resizeEW)
    }

    @Test func theHandOnlyEverMovesAlongTheEdgeItPulls() throws {
        // The circuit is a line, not a triangle: out with the edge and back to it, at one height. A
        // rest position off the line sends the eye down and back up between every pull.
        let heights = try stride(from: 0.0, to: 3.7, by: 0.05).map { t in
            try #require(Self.state(true, at: t).pointer).y
        }
        let span = (heights.max() ?? 0) - (heights.min() ?? 0)
        #expect(span < 40, "the cursor wandered \(span) pt off its line")
    }

    @Test func theLastFiveHundredMillisecondsAreOpposite() throws {
        // The drag is identical; what differs is whether the layout takes the size as its own intent.
        let resting = try #require(Self.state(true, at: 0.2).frames[Self.dragged]).width
        let adopted = try #require(Self.state(true, at: 2.0).frames[Self.dragged]).width
        let refused = try #require(Self.state(false, at: 2.0).frames[Self.dragged]).width

        #expect(abs(adopted - (resting + Self.carried)) < 0.001,
                "on: the whole third of a screen the hand carried is the layout's width now")
        #expect(abs(refused - resting) < 0.001, "off: emira takes the width back")
    }

    @Test func theHandStaysWhereItWasLetGo() throws {
        // Under `off` the window springs back to the width the ladder says. A cursor still pinned to
        // its edge would be dragged home with it — a hand teleporting rather than a layout changing
        // its mind, and the most conspicuous thing in the take.
        let held = try #require(Self.state(false, at: 1.149).pointer)
        for t in [1.15, 1.4, 2.0, 2.6] {
            let released = try #require(Self.state(false, at: t).pointer)
            #expect(abs(released.x - held.x) < 1, "the hand moved at \(t)s without being sent")
            #expect(abs(released.y - held.y) < 1)
        }
        // And both rungs leave it in the same place, because where the hand got to is not the
        // layout's to answer.
        let adopted = try #require(Self.state(true, at: 2.0).pointer)
        #expect(abs(adopted.x - held.x) < 1)
    }

    @Test func adoptingReflowsTheStripAndRefusingDoesNot() throws {
        let restingNeighbour = try #require(Self.state(true, at: 0.2).frames[Self.neighbour]).minX
        let adopted = try #require(Self.state(true, at: 2.0).frames[Self.neighbour]).minX
        let refused = try #require(Self.state(false, at: 2.0).frames[Self.neighbour]).minX

        #expect(adopted > restingNeighbour, "the strip reflows under the adopted width")
        #expect(abs(refused - restingNeighbour) < 0.001, "an unchanged strip is an unchanged strip")
    }

    @Test func theLensNeverMoves() throws {
        // The subject is a window growing by a third of a screen and then keeping or losing it, which
        // is a shape read against the display's own edges. A lens travelling while the thing it frames
        // changes size is two motions at once, and two motions at once is one nobody can read.
        let take = try #require(Catalog.take(for: "layout.interactive-resize", config: Config()))
        for t in [0.2, 1.0, 2.0, 3.4] { #expect(take.camera(at: t) == .wide) }
    }

    @Test func theTakeReturnsToItsOwnStart() throws {
        for adopts in [true, false] {
            let take = try #require(Catalog.take(for: "layout.interactive-resize",
                                                 config: Self.config(adopts)))
            let start = try Self.state(adopts, at: 0)
            let end = try Self.state(adopts, at: take.period - 1e-6)
            #expect(end.frames == start.frames)
        }
    }
}
