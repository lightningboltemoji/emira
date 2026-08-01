import Foundation

// Park slots — where an off-viewport column's windows, and every window on an unfocused workspace, go
// to wait. macOS won't let a window leave the screen: it honors a requested position only while a
// sliver stays on-screen, so a parked window is shoved almost entirely off the bottom-right corner
// with its top-left corner — the title bar — poking back in, grabbable by hand and, since occlusion is
// binary, still rendering. Slots are pure geometry, top-left points (Geometry.swift).
public struct ParkingLot: Sendable, Equatable {
    /// The monitor working area nubs live against — already Dock/menu-bar inset by the shell.
    public let frame: Rect
    /// Points of a parked window's left edge that stay on-screen. ~1 pt is enough for macOS to honor
    /// the position and to keep the window warm.
    public let visibleSliver: Double
    /// Points of a parked window's top edge that stay on-screen — its title bar. The rest hangs off
    /// the bottom.
    public let visibleChrome: Double
    /// How much taller the nub grows per ordinal. Must clear `WindowRegistry`'s ±2 pt binding tolerance,
    /// or two parked windows of one app are ambiguous at rebind and neither is managed — a right-edge
    /// park gives them all the same `minX`, so height is the only thing telling them apart.
    public let stagger: Double
    /// How much further on-screen each new lane pokes — the horizontal counterpart of `stagger`, and
    /// there for the same ±2 pt tolerance: at one sliver, lane 1 row 0 sat 1 pt from lane 0 row 0 in
    /// `x` and identical otherwise. Kept as small as clears the tolerance, since `x` is the axis the
    /// user sees.
    public let laneStep: Double

    public init(frame: Rect, visibleSliver: Double = 1, visibleChrome: Double = 40,
                stagger: Double = 8, laneStep: Double = 4) {
        self.frame = frame
        self.visibleSliver = visibleSliver
        self.visibleChrome = visibleChrome
        self.stagger = stagger
        self.laneStep = laneStep
    }

    /// How many staggered rows a lane holds: as many as fit before the nub would outgrow the working
    /// area. At least one. Deliberately long, since wrapping trades height for user-visible width.
    private var rowsPerLane: Int {
        max(Int(((frame.height - visibleChrome) / stagger).rounded(.down)) + 1, 1)
    }

    /// The ordinal to hand out at `ordinal` for a window that will not keep less than `chrome` points of
    /// itself on screen — its own row if that already shows enough, else the first row of the same lane
    /// that does. Ordinals only ever move *forward*, so a run stays unique however many windows push.
    ///
    /// The floor is rounded **up onto the stagger lattice** rather than honoured exactly: every slot
    /// staying one of the staggered ones is what keeps distinctness a property of the lattice instead of
    /// something each window's answer has to re-argue. A floor past the last row is not reachable — that
    /// window is asking for more of itself than a nub can show — so it takes the tallest row there is.
    public func ordinal(atLeast ordinal: Int, clearing chrome: Double) -> Int {
        let n = max(ordinal, 0)
        let rows = rowsPerLane
        let needed = min(max(Int(((chrome - visibleChrome) / stagger).rounded(.up)), 0), rows - 1)
        let (lane, row) = (n / rows, n % rows)
        return needed <= row ? n : lane * rows + needed
    }

    /// The park frame for the `ordinal`-th parked window of size `size`: shoved off the bottom-right so
    /// `visibleSliver` of its left edge and `visibleChrome` (+ `stagger` per ordinal) of its top edge
    /// poke back in. Unique per ordinal, total for any `ordinal`. `size` is kept verbatim — parking
    /// repositions, never resizes.
    public func slot(ordinal: Int, size: Size) -> Rect {
        let n = max(ordinal, 0)
        let rows = rowsPerLane
        let lane = n / rows
        let row = n % rows
        // Poke in from the right; the body sits off-screen right of `frame.maxX`.
        let pokeX = visibleSliver + Double(lane) * laneStep
        let x = frame.maxX - pokeX
        // …and the top edge up from the bottom, one stagger taller per row; the rest hangs off-screen.
        let pokeY = visibleChrome + Double(row) * stagger
        let y = frame.maxY - pokeY
        return Rect(x: x, y: y, width: size.width, height: size.height)
    }
}
