import Foundation
import Testing
@testable import EmiraCore

/// Deterministic, unique, staggered park slots for off-viewport windows.
@Suite struct ParkTests {

    // Reused fixture: a 1440×900 working area at the origin; 1 pt sliver of width, 40 pt of chrome,
    // 8 pt stagger. rows-per-lane = floor((900 − 40) / 8) + 1 = 108.
    private let lot = ParkingLot(frame: Rect(x: 0, y: 0, width: 1440, height: 900))
    private let size = Size(width: 400, height: 300)

    @Test func slotPokesACornerNubInFromTheBottomRight() {
        // window shoved right so only 1 pt of its left edge shows (x = 1440 − 1) and down so only
        // 40 pt of its top edge does (y = 900 − 40) — the title bar, the grabbable part.
        let s = lot.slot(ordinal: 0, size: size)
        #expect(s == Rect(x: 1439, y: 860, width: 400, height: 300))
        #expect(s.minX == lot.frame.maxX - lot.visibleSliver)   // exactly `visibleSliver` on-screen
        #expect(s.minY == lot.frame.maxY - lot.visibleChrome)   // exactly `visibleChrome` of it
    }

    @Test func onlyTheNubIsOnScreenNotTheWholeHeight() {
        // The point of a corner park: what the user sees is 1 × 40, not a full-height line down the
        // edge. The rest of the window hangs off the display's right and bottom.
        #expect(lot.slot(ordinal: 0, size: size).intersection(lot.frame)
                == Rect(x: 1439, y: 860, width: 1, height: 40))
    }

    @Test func successiveSlotsGrowTheNubByStagger() {
        #expect(lot.slot(ordinal: 0, size: size).minY == 860)   // 40 pt of chrome showing
        #expect(lot.slot(ordinal: 1, size: size).minY == 852)   // 48
        #expect(lot.slot(ordinal: 2, size: size).minY == 844)   // 56
        // same lane → same x, only y moves
        #expect(lot.slot(ordinal: 1, size: size).minX == lot.slot(ordinal: 0, size: size).minX)
    }

    @Test func slotFramesAreUniqueAcrossManyOrdinals() {
        // The load-bearing property: no two parked windows share a frame. (`Rect` isn't Hashable —
        // width/height are constant here, so a distinct origin means a distinct frame.)
        let frames = (0..<300).map { lot.slot(ordinal: $0, size: size) }
        let origins = Set(frames.map { "\($0.minX),\($0.minY)" })
        #expect(origins.count == frames.count)
    }

    @Test func slotsDifferByMoreThanTheIdentityBindingTolerance() {
        // "Unique" is not enough on its own: `WindowRegistry.bind` matches frames within ±2 pt per
        // edge and refuses a window with two candidates, so slots a point apart would make two parked
        // windows of one app ambiguous at rebind and neither would be managed. Every consecutive pair
        // in a lane must clear that tolerance — which is why the stagger is 8 and not 1.
        for n in 0..<20 {
            let gap = abs(lot.slot(ordinal: n, size: size).minY - lot.slot(ordinal: n + 1, size: size).minY)
            #expect(gap > 2)
        }
    }

    @Test func lanesWrapALaneStepFurtherInWhenRowsAreExhausted() {
        // ordinal 108 == lane 1, row 0: the nub resets to 40 pt tall, x pokes one lane step further.
        let first = lot.slot(ordinal: 0, size: size)
        let wrapped = lot.slot(ordinal: 108, size: size)
        #expect(wrapped.minY == first.minY)                  // back to a bare-chrome nub
        #expect(wrapped.minX == first.minX - lot.laneStep)   // one lane step further on-screen
        #expect(wrapped != first)
    }

    /// The wrap has to clear the identity tolerance too. Lane 1 row 0 shares its `y`, `width` and
    /// `height` with lane 0 row 0, so `x` is the *only* edge telling them apart, and it must differ by
    /// more than `WindowRegistry.bind`'s ±2 pt per-edge match or both windows are refused at rebind.
    /// Hence every pair, not just consecutive ones — only a workspace set parks enough windows
    /// (~107 rows to a lane) to reach a second lane at all.
    @Test func everyPairOfSlotsClearsTheIdentityBindingToleranceAcrossLanes() {
        let slots = (0..<250).map { lot.slot(ordinal: $0, size: size) }   // three lanes' worth
        func ambiguous(_ a: Rect, _ b: Rect) -> Bool {
            abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
                && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
        }
        for i in slots.indices {
            for j in (i + 1)..<slots.count where ambiguous(slots[i], slots[j]) {
                Issue.record("ordinals \(i) and \(j) are indistinguishable at rebind")
            }
        }
    }

    @Test func aLaneNeverGrowsTheNubPastTheWorkingArea() {
        // The wrap point is chosen so the tallest nub in a lane still fits the working area — past
        // that, growing it further is just the full-height sliver this design replaced.
        for n in 0..<108 {
            #expect(lot.slot(ordinal: n, size: size).minY >= lot.frame.minY)
        }
    }

    @Test func negativeOrdinalsSnapToTheFirstSlot() {
        #expect(lot.slot(ordinal: -5, size: size) == lot.slot(ordinal: 0, size: size))
    }

    @Test func slotKeepsTheWindowSizeAndStaysWarm() {
        let s = lot.slot(ordinal: 3, size: size)
        #expect(s.width == 400 && s.height == 300)              // reposition, never resize
        #expect(s.intersects(lot.frame))                        // a nub is genuinely on-screen
    }

    // Windows that refuse a short nub

    @Test func aFloorTakesTheFirstSlotOnTheLatticeThatClearsIt() {
        // 52 pt of chrome sits between rows 1 (48) and 2 (56), and the answer is row 2: rounding *up*
        // onto the lattice is what keeps distinctness a property of the lattice rather than something
        // each app's answer has to re-argue.
        #expect(lot.ordinal(atLeast: 0, clearing: 52) == 2)
        #expect(lot.slot(ordinal: 2, size: size).minY == 844)   // 56 pt showing, not 52
        // Exactly on a row is that row, not the next one.
        #expect(lot.ordinal(atLeast: 0, clearing: 56) == 2)
    }

    @Test func aFloorTheBareNubAlreadyClearsChangesNothing() {
        #expect(lot.ordinal(atLeast: 0, clearing: 40) == 0)
        #expect(lot.ordinal(atLeast: 0, clearing: 0) == 0)
        #expect(lot.ordinal(atLeast: 7, clearing: 40) == 7)     // row 7 already shows 96
    }

    @Test func aRunOnlyEverMovesForward() {
        // The cursor is what makes a run unique, so a floor may push it on and may never pull it back —
        // a slot behind the cursor has already been handed to another window.
        for cursor in 0..<12 {
            #expect(lot.ordinal(atLeast: cursor, clearing: 52) >= cursor)
        }
        #expect(lot.ordinal(atLeast: 9, clearing: 52) == 9)     // past the floor already: unchanged
    }

    @Test func aFloorPastTheLastRowTakesTheTallestNubThereIs() {
        // A window asking for more of itself than a nub can show — an app that refuses to park at all,
        // rather than one stating a chrome. It gets the tallest slot in the lane and no more, so one
        // window's refusal cannot walk the whole run off the working area.
        let last = lot.ordinal(atLeast: 0, clearing: 100_000)
        #expect(lot.slot(ordinal: last, size: size).minY >= lot.frame.minY)
        #expect(lot.ordinal(atLeast: 0, clearing: 100_000) == lot.ordinal(atLeast: 0, clearing: 99_000))
    }

    @Test func twoWindowsWithTheSameFloorStillGetDistinctNubs() {
        // The identity consequence, and the reason the floor moves a *cursor* instead of just clamping
        // each window on its own: two windows that refuse the same short nub would otherwise land on
        // byte-identical frames, which `WindowRegistry.bind` calls ambiguous and refuses both of.
        var cursor = 0
        let first = lot.ordinal(atLeast: cursor, clearing: 52)
        cursor = first + 1
        let second = lot.ordinal(atLeast: cursor, clearing: 52)
        #expect(first != second)
        #expect(abs(lot.slot(ordinal: first, size: size).minY
                    - lot.slot(ordinal: second, size: size).minY) > 2)
    }
}
