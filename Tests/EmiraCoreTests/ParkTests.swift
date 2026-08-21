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

/// Which corner of the display arrangement the desktop parks in. Provably inert with one display
/// attached — there is one corner and it is that display's — and a wrong answer is silent in the
/// worst way available: a window that is meant to be parked, sitting in view on another screen.
@Suite struct DesktopParkingTests {

    private func display(_ raw: UInt64, _ frame: Rect, struts: EdgeInsets = .zero,
                         main: Bool = false) -> MonitorState {
        MonitorState(id: MonitorId(raw), frame: frame, struts: struts, isMain: main)
    }

    @Test func oneDisplayParksInItsOwnWorkingArea() {
        let laptop = display(1, Rect(x: 0, y: 0, width: 1440, height: 900),
                             struts: EdgeInsets(top: 25, bottom: 70), main: true)
        let lot = try! #require(ParkingLot(among: [laptop]))
        #expect(lot.frame == laptop.workingArea)
        // The working area, so the nub stays above the Dock where a hand can reach it.
        #expect(lot.slot(ordinal: 0, size: Size(width: 400, height: 300)).minY == 790)
    }

    @Test func noDisplayIsNoLot() {
        #expect(ParkingLot(among: []) == nil)
    }

    @Test func aDisplayBesideOneTakesTheLotOffIt() {
        // At the laptop's own corner a parked body lands in the middle of the screen next to it, so
        // the lot is the monitor's — clearance outranks main, and the laptop is main here.
        let laptop = display(1, Rect(x: 0, y: 0, width: 1440, height: 900), main: true)
        let monitor = display(2, Rect(x: 1440, y: 0, width: 2560, height: 1440))
        #expect(ParkingLot(among: [laptop, monitor])?.frame == monitor.workingArea)
    }

    @Test func aParkedBodyReachesNoOtherScreen() {
        // The property the corner is chosen for, at the size a window actually is: on the display
        // that holds the lot, the nub; on every other display, nothing.
        let laptop = display(1, Rect(x: 0, y: 0, width: 1440, height: 900), main: true)
        let monitor = display(2, Rect(x: 1440, y: 0, width: 2560, height: 1440))
        let lot = try! #require(ParkingLot(among: [laptop, monitor]))
        let slot = lot.slot(ordinal: 0, size: Size(width: 1200, height: 800))
        #expect(slot.intersection(laptop.frame) == nil)
        #expect(slot.intersection(monitor.frame) == Rect(x: 3999, y: 1400, width: 1, height: 40))
    }

    @Test func aDisplayBelowDisqualifiesTheOneAboveEvenSharingARightEdge() {
        // Nothing is to the *right* of the upper display, and its bodies still run down the shared
        // edge onto the lower one — a sliver-wide line of window, the full height of a screen.
        let upper = display(1, Rect(x: 0, y: 0, width: 1000, height: 800), main: true)
        let lower = display(2, Rect(x: 0, y: 800, width: 1000, height: 800))
        #expect(ParkingLot(among: [upper, lower])?.frame == lower.workingArea)
    }

    @Test func aDisplayAboveAndToTheRightIsNoObstacle() {
        // A body only ever hangs *down*, so a screen whose bottom edge is above the lot's top edge
        // cannot catch one, however far right it sits.
        let desk = display(1, Rect(x: 0, y: 0, width: 1000, height: 800), main: true)
        let shelf = display(2, Rect(x: 1000, y: -1000, width: 1000, height: 900))
        #expect(ParkingLot(among: [desk, shelf])?.frame == desk.workingArea)
    }

    @Test func theMainDisplayKeepsTheNubsWhenBothCornersAreClear() {
        // A monitor with the laptop centred below it: neither corner has anything beyond it, and
        // macOS's own answer to which screen is the user's breaks the tie.
        let monitor = display(1, Rect(x: 0, y: 0, width: 2560, height: 1440), main: true)
        let laptop = display(2, Rect(x: 524, y: 1440, width: 1512, height: 982))
        #expect(ParkingLot(among: [monitor, laptop])?.frame == monitor.workingArea)
        // …and with the role on the laptop, the nubs go with it.
        let docked = display(2, laptop.frame, main: true)
        #expect(ParkingLot(among: [display(1, monitor.frame), docked])?.frame == docked.workingArea)
    }

    @Test func mirroredDisplaysDoNotDisqualifyEachOther() {
        // Two displays reporting one frame is what mirroring looks like from here: the second one's
        // pixels *are* the first one's, so there is nothing beyond the corner for a body to land on.
        let frame = Rect(x: 0, y: 0, width: 1440, height: 900)
        #expect(ParkingLot(among: [display(1, frame, main: true), display(2, frame)])?.frame == frame)
    }

    // The join: every display's metrics carry the one lot

    private static let left = MonitorInfo(id: MonitorId(1), frame: Rect(x: 0, y: 0, width: 1000, height: 800),
                                          isMain: true)
    private static let right = MonitorInfo(id: MonitorId(2),
                                           frame: Rect(x: 1000, y: 0, width: 1200, height: 900))

    /// Two displays side by side and three ½-width windows on the left one's strip: two columns fill
    /// its viewport and the third is scrolled off, which is a window parked.
    private static func desktop() -> (State, WindowId) {
        var s = State(config: EngineFix.halfWidthSnap)
        (s, _) = Engine.reduce(s, .screensChanged([left, right]))
        for raw in UInt64(1)...3 {
            let (next, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(raw)))
            s = EngineFix.settle(next, fx)
        }
        let parked = s.workspaces.allWindowIds.first { !s.world.isOnScreen($0) }
        return (s, try! #require(parked, "the fixture is meant to leave a window parked"))
    }

    @Test func aStripParksInTheDesktopsLotAndNotItsOwnDisplays() {
        let (s, parked) = Self.desktop()
        let frame = try! #require(s.world.windows[parked]?.frame)
        #expect(frame.minX == 2199 && frame.minY == 860)      // the right display's corner
        #expect(frame.intersection(Self.left.frame) == nil,   // …and nothing of it on the left one
                "a nub at the left display's corner would hang its body across the right one")
    }

    @Test func aParkFloorIsMeasuredFromTheLotTheWindowIsParkedIn() {
        // The window is on the left display's strip and parked at the right one's corner, so the
        // chrome it keeps is a distance from *that* bottom edge. Measured from its own display's, a
        // 56 pt answer reads as −44 and the slot the app refused is asked for again.
        let (s, parked) = Self.desktop()
        let slot = try! #require(s.world.windows[parked]?.frame)
        let kept = Rect(x: slot.minX, y: 900 - 56, width: slot.width, height: slot.height)
        let (after, _) = Engine.reduce(s, .parkCorrected(parked, requested: slot, actual: kept))
        #expect(after.world.parkFloors[parked] == 56)
    }
}
