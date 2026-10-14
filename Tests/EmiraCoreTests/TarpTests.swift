import Foundation
import Testing
@testable import EmiraCore

// The tarp derivation (`State.tarp`): which parked windows the shell draws the desktop back over, the
// slots they were parked in, and on which display — plus the post-pass that sends it on `setScrims`'
// terms: when it changes, held while the writes that change it are in flight, and lifted for a hand.

@Suite struct TarpTests {

    /// Three ½-width columns on the 1000-wide display: two on the glass, one parked.
    static func world(_ config: Config = EngineFix.halfWidth) -> State {
        EngineFix.world(3, config: config)
    }

    static let monitor = MonitorId(1)

    /// Every tarp a batch sent, in order — `nil` being one taken down.
    static func sent(_ effects: [Effect]) -> [Tarp?] {
        effects.compactMap { effect -> Tarp?? in
            if case .setTarp(_, let tarp) = effect { tarp } else { nil }
        }
    }

    static func parked(_ s: State) throws -> WindowId {
        try #require(s.world.tiledWindowIds.first { !s.world.placedOnScreen.contains($0) })
    }

    // The record.

    @Test func thePlacementPassRecordsWhereItParkedEachWindow() throws {
        let s = Self.world()
        let parked = try Self.parked(s)
        #expect(Set(s.world.parkedSlots.keys) == [parked])
        let slot = try #require(s.world.parkedSlots[parked])
        #expect(slot.minX == EngineFix.displayFrame.maxX - 1, "a nub one point wide")
        #expect(slot == s.world.windows[parked]?.frame, "and the window was parked there")
    }

    @Test func aWindowOnTheGlassHasNoSlot() {
        let s = Self.world()
        #expect(s.world.placedOnScreen.allSatisfy { s.world.parkedSlots[$0] == nil })
    }

    @Test func aClosedWindowLeavesTheRecord() throws {
        let s = Self.world(EngineFix.halfWidthSnap)
        let parked = try Self.parked(s)
        let (next, _) = Engine.reduce(s, .windowDestroyed(parked))
        #expect(next.world.parkedSlots[parked] == nil)
    }

    // What the tarp holds.

    @Test func theTarpNamesTheLotsDisplayEveryParkedSlotAndTheKeyWindow() throws {
        let s = Self.world()
        let tarp = try #require(s.tarps[Self.monitor])
        #expect(tarp.lot == EngineFix.displayFrame)
        #expect(tarp.slots == s.world.parkedSlots)
        #expect(tarp.focused == s.world.focusedWindow)
        #expect(s.tarp() == s.tarps)
    }

    @Test func nothingParkedIsNoTarp() {
        let s = EngineFix.world(2, config: EngineFix.halfWidth)
        #expect(s.world.parkedSlots.isEmpty)
        #expect(s.tarps.isEmpty)
    }

    /// The lot is the desktop's, so the tarp is on the display the lot is on — not the one a window was
    /// parked from.
    @Test func theTarpIsOnTheDisplayTheLotIsOn() throws {
        // Four ½-width columns, one sent right: the left display shows two and parks the third.
        var s = MonitorSessionTests.desktop(4, config: EngineFix.halfWidth)
        s = MonitorSessionTests.sendToRight(s)
        let parked = try Self.parked(s)
        #expect(s.workspaces.workspace(of: parked).flatMap { s.monitors.monitor(of: $0) }
                == MonitorSessionTests.left)
        // The left display's corner has the right one beyond it, so the lot is the right display's.
        let lot = try #require(ParkingLot(among: s.world.monitors))
        #expect(lot.frame == MonitorSessionTests.rightFrame)
        #expect(Array(s.tarps.keys) == [MonitorSessionTests.right])
    }

    // When it is sent.

    /// The key window's shadow is the one the tarp draws differently, so focus moving re-sends it —
    /// at once, since a focus change between two columns on the glass writes nothing.
    @Test func aFocusChangeSendsTheTarpWithTheNewKeyWindow() throws {
        let s = Self.world()
        let other = try #require(s.world.placedOnScreen.first { $0 != s.world.focusedWindow })
        let (next, effects) = Engine.reduce(s, .focusChanged(other, origin: .system))
        #expect(Self.sent(effects).map { $0?.focused } == [other])
        #expect(next.tarps[Self.monitor]?.focused == other)
    }

    @Test func anUnchangedTarpIsNotSentAgain() {
        let s = Self.world()
        let (_, effects) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(Self.sent(effects).isEmpty)
    }

    /// **A park with no cover over it holds the tarp until it lands**, for `setScrims`' reason: the batch
    /// that writes the frames reaches the plane before the window server has moved them.
    @Test func anUncoveredParkHoldsTheTarpUntilItLands() throws {
        var s = Self.world(EngineFix.halfWidthSnap)
        // Focus the leftmost column on the glass, so the next `focus left` scrolls the parked one in.
        s = EngineFix.settle(s, Engine.reduce(s, .command(.focus(.left))).1)
        let before = try #require(s.tarps[Self.monitor])

        let (placing, effects) = Engine.reduce(s, .command(.focus(.left)))
        s = placing
        let written = ScrimTests.written(effects)
        #expect(!written.isEmpty)
        #expect(Self.sent(effects).isEmpty, "the tarp waits for the parks")
        #expect(s.tarps[Self.monitor] == before)

        var landing: [Effect] = []
        for id in written.dropLast() {
            (s, landing) = Engine.reduce(s, .axLanded(id))
            #expect(Self.sent(landing).isEmpty, "not while one is still in flight")
        }
        (s, landing) = Engine.reduce(s, .axLanded(try #require(written.last)))
        let landed = try #require(Self.sent(landing).last ?? nil, "the last landing pays it")
        #expect(landed.slots != before.slots)
        #expect(landed.slots == s.world.parkedSlots)
    }

    /// A tarp is cut once per set, so a window carried across the corner would pass under a patch cut
    /// around where it was picked up. A float, so the stop re-tiles nothing and the tarp comes back as it was.
    @Test func aWindowInTheHandLiftsTheTarpAndItsStopSetsItBack() throws {
        let float = WindowId(9)
        let s = EngineFix.run(Self.world(), [.windowCreated(EngineFix.snapshot(9, role: .dialog))]).0
        let before = try #require(s.tarps[Self.monitor])
        let moved = Rect(x: 340, y: 320, width: 200, height: 200)
        var (held, effects) = EngineFix.run(s, [.dragBegan, .windowFrameChanged(float, moved)])
        #expect(held.tarps.isEmpty)
        #expect(Self.sent(effects).contains { $0 == nil })

        (held, effects) = EngineFix.run(held, [.dragReleased, .dragEnded])
        #expect(Self.sent(effects).last == before)
        #expect(held.tarps[Self.monitor] == before)
    }
}
