import Foundation
import Testing
@testable import EmiraCore

// The cascade's arithmetic (`Stack`) — `StripTests`' counterpart. Every tile is the same size, that
// size is a function of `n`, and the two floors that bound the compression are both live at once.

@Suite struct StackTests {

    /// An 1800×1130 content area — a ProMotion display minus its menu bar.
    static let region = Rect(x: 0, y: 39, width: 1800, height: 1130)

    @Test func noTilesIsNoFrames() {
        #expect(Stack.frames(count: 0, in: Self.region).isEmpty)
        #expect(Stack.frames(count: -3, in: Self.region).isEmpty)
    }

    @Test func oneTileIsTheRegion() {
        #expect(Stack.frames(count: 1, in: Self.region) == [Self.region])
    }

    @Test func everyTileIsThirtyPointsDownAndRightOfTheLast() {
        let frames = Stack.frames(count: 4, in: Self.region)
        #expect(frames.count == 4)
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            #expect(later.minX - earlier.minX == 30)
            #expect(later.minY - earlier.minY == 30)
        }
    }

    /// The diagonal runs top-left → bottom-right, and slot 0 is furthest back and up-left.
    @Test func slotZeroSitsAtTheRegionsTopLeft() {
        let frames = Stack.frames(count: 4, in: Self.region)
        #expect(frames[0].minX == Self.region.minX)
        #expect(frames[0].minY == Self.region.minY)
    }

    /// One size for the whole cascade — no window is bigger for being deeper or shallower, which is
    /// the whole of "nothing resizes a tile".
    @Test func everyTileIsTheSameSize() {
        let frames = Stack.frames(count: 5, in: Self.region)
        #expect(frames.allSatisfy { $0.size == frames[0].size })
    }

    /// …and that size is a function of `n`: the region less the whole spread, so an arrival shrinks
    /// every tile on the workspace by exactly one stagger on both axes.
    @Test func theTileSizeShrinksByOneStaggerPerArrival() {
        let three = Stack.frames(count: 3, in: Self.region)[0].size
        let four = Stack.frames(count: 4, in: Self.region)[0].size
        #expect(three.width - four.width == 30)
        #expect(three.height - four.height == 30)
        #expect(four.width == Self.region.width - 3 * 30)
        #expect(four.height == Self.region.height - 3 * 30)
    }

    /// The last tile's bottom-right corner lands exactly on the region's, so the cascade fills the
    /// content area rather than sitting inside it.
    @Test func theDeepestTileEndsAtTheRegionsBottomRight() {
        let frames = Stack.frames(count: 6, in: Self.region)
        let last = try! #require(frames.last)
        #expect(abs(last.maxX - Self.region.maxX) < 1e-9)
        #expect(abs(last.maxY - Self.region.maxY) < 1e-9)
    }

    // The two floors

    /// The soft one: below `minimumSize` the stagger compresses instead of the tile shrinking on.
    @Test func theStaggerCompressesRatherThanLettingATileGoUnderTheFloor() {
        // Height is the tighter axis: 1130 − 320 = 810 of travel, against 1800 − 480 = 1320.
        let room = Self.region.height - Stack.minimumSize.height
        let count = Int((room / Stack.stagger).rounded(.down)) + 1

        #expect(Stack.step(count: count, in: Self.region) == Stack.stagger)
        // One deeper and there is no longer room for the full stagger, so it gives way first.
        let tighter = Stack.step(count: count + 1, in: Self.region)
        #expect(tighter < Stack.stagger)
        #expect(abs(tighter - room / Double(count)) < 1e-9)
        // …and the tile stops at the floor rather than carrying on down.
        let size = Stack.size(count: count + 1, in: Self.region)
        #expect(abs(size.height - Stack.minimumSize.height) < 1e-9)
    }

    /// The hard one, and it is an identity floor: two same-size tiles closer than `WindowRegistry`'s
    /// ±2 pt binding tolerance are two windows nothing can tell apart.
    @Test func compressionStopsAtTheIdentityFloor() {
        for count in [80, 200, 5_000] {
            #expect(Stack.step(count: count, in: Self.region) >= Stack.minimumStagger)
        }
        #expect(Stack.minimumStagger >= 4, "must clear WindowRegistry's ±2 pt tolerance both ways")
    }

    /// Total past the point where both floors have been spent: a stack deep enough to exhaust the
    /// region still hands back rectangles, rather than negative or zero ones.
    @Test func anAbsurdlyDeepStackStillAnswersWithRectangles() {
        let frames = Stack.frames(count: 400, in: Self.region)
        #expect(frames.count == 400)
        #expect(frames.allSatisfy { $0.width > 0 && $0.height > 0 })
        // Still distinguishable, which is the property the identity floor is protecting.
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            #expect(later.minX - earlier.minX >= Stack.minimumStagger)
        }
    }

    /// A region too small for a tile at all is answered with the region rather than with nothing:
    /// the arithmetic is total, and macOS clamps whatever it cannot honour.
    @Test func aTinyRegionStillAnswers() {
        let cramped = Rect(x: 0, y: 0, width: 200, height: 120)
        let frames = Stack.frames(count: 3, in: cramped)
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.width > 0 && $0.height > 0 })
        #expect(frames[0].origin == cramped.origin)
    }
}
