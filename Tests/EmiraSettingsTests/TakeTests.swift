import Testing
import EmiraCore
@testable import EmiraSettings

// A take is pure and total in `t`. That is what makes the demonstration testable without a clock and
// without a window: playing to a time gives a set, and the same time always gives the same one.

@Suite struct TakeTests {

    static let scene = Scenes.fourColumns
    static let first = Scenes.fourColumnsFirst

    /// Two steps right by 1.0 s, so at 1.2 s focus has reached the third column.
    static let take = Take(scene: scene,
                           beats: [(0.5, .focusRight), (1.0, .focusRight), (2.0, .focus(first))],
                           period: 3.0)

    // The one the phase is done when it passes.

    @Test func playingToATimeGivesTheArrangementItClaims() throws {
        #expect(Self.take.scene(at: 0).focus == WindowId(11))
        #expect(Self.take.scene(at: 0.7).focus == WindowId(12))

        let third = Self.take.scene(at: 1.2)
        #expect(third.focus == WindowId(13))
        #expect(third.columnIndex(ofWindow: third.focus) == 2)
    }

    @Test func aLoopComesBackToItsOwnStart() {
        let start = Self.take.scene(at: 0)
        #expect(Self.take.scene(at: 3.0) == start)
        #expect(Self.take.scene(at: 6.0) == start)
        // And a take played for an hour is somewhere in its loop, not off the end of it.
        #expect(Self.take.scene(at: 3600 + 1.2) == Self.take.scene(at: 1.2))
    }

    @Test func aStaticTakeIsItsOwnSceneAtEveryTime() {
        let take = Take(scene: Scenes.threeColumns)
        #expect(take.isStatic)
        #expect(take.scene(at: 0) == Scenes.threeColumns)
        #expect(take.scene(at: 99) == Scenes.threeColumns)
    }

    @Test func focusStopsAtTheEndsOfTheStrip() {
        let right = Take(scene: Self.scene,
                         beats: [(1, .focusRight), (2, .focusRight), (3, .focusRight),
                                 (4, .focusRight), (5, .focusRight)],
                         period: 10)
        // Four columns, five steps: the last two ask for something that isn't there.
        #expect(right.scene(at: 6).focus == WindowId(14))

        let left = Take(scene: Self.scene.focusing(WindowId(11)),
                        beats: [(1, .focusLeft), (2, .focusLeft)], period: 10)
        #expect(left.scene(at: 3).focus == WindowId(11))
    }

    @Test func cyclingAWidthStepsTheFocusedColumnOnly() throws {
        let take = Take(scene: Scenes.threeColumns, beats: [(1, .cycleWidth)], period: 10)
        let before = Scenes.threeColumns
        let after = take.scene(at: 2)

        let focusedBefore = try #require(before.focusedColumn)
        let focusedAfter = try #require(after.focusedColumn)
        #expect(focusedAfter.widthPreset == focusedBefore.widthPreset + 1)

        // Its neighbours are where they were.
        #expect(after.columns[0].widthPreset == before.columns[0].widthPreset)
        #expect(after.columns[2].widthPreset == before.columns[2].widthPreset)
    }

    @Test func beatsApplyInOrderAndOnlyOnceEach() {
        let take = Take(scene: Scenes.threeColumns,
                        beats: [(1, .cycleWidth), (2, .cycleWidth)], period: 10)
        #expect(take.scene(at: 0).focusedColumn?.widthPreset == 0)
        #expect(take.scene(at: 1.5).focusedColumn?.widthPreset == 1)
        #expect(take.scene(at: 2.5).focusedColumn?.widthPreset == 2)
        // Still two beats' worth at the end of the loop, not one per frame drawn since.
        #expect(take.scene(at: 9.9).focusedColumn?.widthPreset == 2)
    }
}
