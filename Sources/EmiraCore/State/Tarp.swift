import Foundation

// The tarp: the parking lot, drawn over.
//
// **A parked window cannot leave the screen** (`PRINCIPLES` §5), so it waits as a nub in the lot's corner
// and casts its shadow on whatever is there. We cannot hide it, so the presentation plane draws over it:
// a patch of the desktop as it would look with nothing parked in it — the photograph, with the shadows of
// every window that is *not* parked drawn back in, and those windows cut out so they stay live.
//
// **Which windows are parked, and where, is the core's; where each stands now is the window server's.**
// The placement pass records every slot it parks a window in (`World.parkedSlots`), and the shell draws
// over a window only while the server shows it standing in that slot — so a park still on its way, or
// one an app refused, is left in plain view rather than painted over wherever it happens to be.

/// The parked windows one display's tarp draws over, and what it needs to draw the corner without them.
public struct Tarp: Sendable, Equatable, Codable {
    /// The desktop's parking lot (`ParkingLot.frame`) — carried so the shell forms no second opinion
    /// about which corner the nubs are in.
    public let lot: Rect
    /// Every parked window, at the slot the placement pass parked it in.
    public let slots: [WindowId: Rect]
    /// The window macOS draws the key window's shadow around, where emira manages it.
    public let focused: WindowId?

    public init(lot: Rect, slots: [WindowId: Rect], focused: WindowId?) {
        self.lot = lot
        self.slots = slots
        self.focused = focused
    }
}

extension State {

    /// The tarp over the desktop's parking lot, keyed by the display the lot is on. Empty with nothing
    /// parked, and **while a window is in the hand**, for `scrimBindings`' reason: a tarp is cut once
    /// per set, and a window dragged across the corner would pass under the patch cut around where it was.
    public func tarp() -> [MonitorId: Tarp] {
        guard drag.subject == nil, !world.parkedSlots.isEmpty,
              let lot = ParkingLot(among: world.monitors)?.frame,
              let monitor = world.monitors.first(where: { $0.workingArea == lot })?.id
                  ?? world.monitor(at: lot.center)
        else { return [:] }
        return [monitor: Tarp(lot: lot, slots: world.parkedSlots, focused: world.focusedWindow)]
    }
}
