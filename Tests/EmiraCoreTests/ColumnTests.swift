import Foundation
import Testing
@testable import EmiraCore

/// The vertical stack inside one column: the auto/pinned height distribution and the stacked window
/// frames. Top-left origin.
@Suite struct ColumnTests {

    // Reused fixture: a column box at x=100, top y=50, 400 wide, 900 tall, with a 10 pt inter-window
    // gap. Windows fill the 400 width and stack down from y=50.
    private let box = Rect(x: 100, y: 50, width: 400, height: 900)

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
        // ½ of the box *and the gap it stacks with*: (900 + 10)/2 − 10 = 445, so two of them and the
        // gap between fill the box exactly. No auto to absorb the rest, so one alone leaves it short
        // (honest), by the half-gap its absent twin would have paid.
        let c = Column(frame: box, windowHeights: [.preset(.proportion(0.5))], gap: 10)
        #expect(c.resolvedHeights() == [445])
        #expect(c.contentHeight == 445)
    }

    /// The point of folding the gap in: a stack of pinned proportions summing to 1 fills the box to the
    /// pixel rather than overflowing its bottom by one `window-gap` per boundary.
    @Test func pinnedProportionsSummingToOneFillTheBoxExactly() {
        let halves = Column(frame: box, windowHeights: [.preset(.proportion(0.5)),
                                                        .preset(.proportion(0.5))], gap: 10)
        #expect(halves.resolvedHeights() == [445, 445])
        #expect(halves.contentHeight == 900)
        #expect(halves.windowFrames().last?.maxY == box.maxY)

        // …and it holds for an uneven partition, and for more of them.
        let mixed = Column(frame: box, windowHeights: [.preset(.proportion(0.5)),
                                                       .preset(.proportion(0.25)),
                                                       .preset(.proportion(0.25))], gap: 10)
        #expect(mixed.contentHeight == 900)
        #expect(mixed.windowFrames().last?.maxY == box.maxY)
    }

    /// The inconsistency that named the bug: `auto` shares what is left *after* the gaps, so a window
    /// pinned to the proportion it would have got must come out the same height, not one gap taller.
    @Test func aPinnedProportionMatchesTheAutoShareItStandsInFor() {
        let autos = Column(frame: box, windowHeights: [.auto, .auto], gap: 10)
        let pinned = Column(frame: box, windowHeights: [.preset(.proportion(0.5)), .auto], gap: 10)
        #expect(autos.resolvedHeights() == [445, 445])
        #expect(pinned.resolvedHeights() == autos.resolvedHeights())
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

    // Height bounds — the water-fill, in both directions (a window that refuses its share)

    @Test func aHeightFloorBelowTheShareChangesNothing() {
        // Three autos in 900 with two 10 pt gaps → 293.33 each. A window that accepts 200 has no
        // opinion worth acting on, and an inert floor must stay inert.
        let c = Column(frame: box, windowHeights: [.auto, .auto, .auto], gap: 10,
                       heightBounds: [.atLeast(200), nil, nil])
        let h = c.resolvedHeights()
        #expect(h.allSatisfy { abs($0 - 880.0 / 3) < 0.001 })
    }

    @Test func aHeightFloorAboveTheShareTakesItAndTheRestRedivide() {
        // leftover = 900 − 2·10 = 880; equal shares would be 293.33 each. The first window insists on
        // 500, so it takes 500 and the other two split the remaining 380 → 190 apiece.
        let c = Column(frame: box, windowHeights: [.auto, .auto, .auto], gap: 10,
                       heightBounds: [.atLeast(500), nil, nil])
        #expect(c.resolvedHeights() == [500, 190, 190])
        #expect(c.contentHeight == 900)          // still fills the box exactly
    }

    @Test func redividingCanPushAnotherWindowUnderItsFloorAndTheFillRepeats() {
        // The reason this is a loop and not one pass. Shares start at 293.33; w0's 500 floor drops the
        // others to 190, which is now under w1's 250 floor — so w1 is floored on the *second* pass and
        // w2 takes what is left: 880 − 500 − 250 = 130.
        let c = Column(frame: box, windowHeights: [.auto, .auto, .auto], gap: 10,
                       heightBounds: [.atLeast(500), .atLeast(250), nil])
        #expect(c.resolvedHeights() == [500, 250, 130])
        #expect(c.contentHeight == 900)
    }

    @Test func floorsThatCannotFitOverflowTheBoxRatherThanGoingNegative() {
        // Two windows that each insist on 700 in a 900 box: both get their floor, the last auto
        // clamps to zero, and the column overflows — exactly what over-pinned presets already do.
        let c = Column(frame: box, windowHeights: [.auto, .auto, .auto], gap: 10,
                       heightBounds: [.atLeast(700), .atLeast(700), nil])
        #expect(c.resolvedHeights() == [700, 700, 0])
        #expect(c.contentHeight == 1420)
    }

    @Test func aHeightFloorNeverOverridesAPinnedPreset() {
        // A pin is the user's explicit instruction; a floor is an app's constraint. Only autos honor
        // floors, so the pinned 300 stays 300 and the auto absorbs the rest.
        let c = Column(frame: box, windowHeights: [.preset(.fixed(300)), .auto], gap: 10,
                       heightBounds: [.atLeast(800), nil])
        #expect(c.resolvedHeights() == [300, 590])
    }

    @Test func aShortOrAbsentFloorArrayIsTotal() {
        let c = Column(frame: box, windowHeights: [.auto, .auto], gap: 10, heightBounds: [.atLeast(600)])
        #expect(c.resolvedHeights() == [600, 290])       // 890 − 600
        #expect(Column(frame: box, windowHeights: [.auto, .auto], gap: 10, heightBounds: [])
            .resolvedHeights() == [445, 445])
    }

    @Test func aHeightCeilingAboveTheShareChangesNothing() {
        // The mirror of the inert floor: a window that will go to 600 has no opinion about the 293.33
        // it is being offered, and an inert ceiling must stay inert.
        let c = Column(frame: box, windowHeights: [.auto, .auto, .auto], gap: 10,
                       heightBounds: [.atMost(600), nil, nil])
        #expect(c.resolvedHeights().allSatisfy { abs($0 - 880.0 / 3) < 0.001 })
    }

    @Test func aHeightCeilingBelowTheShareHandsTheSurplusBackToTheStack() {
        // The bug this exists for: a fixed-height window (Digital Color Meter) offered 293.33 takes
        // 150 whatever we say, and the 143 it cannot use is a hole *under* it unless the others get
        // it. 880 − 150 = 730, split two ways.
        let c = Column(frame: box, windowHeights: [.auto, .auto, .auto], gap: 10,
                       heightBounds: [.atMost(150), nil, nil])
        #expect(c.resolvedHeights() == [150, 365, 365])
        #expect(c.contentHeight == 900)          // …so the column still fills the box exactly
    }

    @Test func aCeilingCanFreeEnoughRoomToSatisfyAFloorAndTheFillRepeats() {
        // The loop, run in the other direction. Shares start at 293.33, under w1's 400 floor; capping
        // w0 at 150 raises the rest to 365 — still short — so w1 floors on a later pass and w2 takes
        // 880 − 150 − 400 = 330. Two bounds pulling opposite ways, one fixpoint.
        let c = Column(frame: box, windowHeights: [.auto, .auto, .auto], gap: 10,
                       heightBounds: [.atMost(150), .atLeast(400), nil])
        #expect(c.resolvedHeights() == [150, 400, 330])
        #expect(c.contentHeight == 900)
    }

    @Test func aColumnOfNothingButCeilingsUnderfillsItsBox() {
        // The one case with no width analogue — the strip absorbs a narrow column by packing the next
        // one against it, and a column has nowhere to put the height back. Two windows that top out
        // leave real desktop below, which is honest: that is how tall they are.
        let c = Column(frame: box, windowHeights: [.auto, .auto], gap: 10,
                       heightBounds: [.atMost(150), .atMost(200)])
        #expect(c.resolvedHeights() == [150, 200])
        #expect(c.contentHeight == 360)          // 150 + 10 + 200, in a 900 box
        #expect(c.windowFrames().map(\.minY) == [box.minY, box.minY + 160])   // stacked from the top
    }

    @Test func aHeightCeilingNeverOverridesAPinnedPreset() {
        // The mirror of the floor's rule, and the same reason: a pin is the user's instruction, a
        // bound is the app's constraint, and only autos honor bounds.
        let c = Column(frame: box, windowHeights: [.preset(.fixed(300)), .auto], gap: 10,
                       heightBounds: [.atMost(100), nil])
        #expect(c.resolvedHeights() == [300, 590])
    }

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
