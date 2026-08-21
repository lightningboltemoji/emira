import Foundation

// Park slots — where an off-viewport column's windows, and every window on an unfocused workspace, go
// to wait. macOS won't let a window leave the screen: it honors a requested position only while a
// sliver stays on-screen, so a parked window is shoved almost entirely off the bottom-right corner
// with its top-left corner — the title bar — poking back in, grabbable by hand and, since occlusion is
// binary, still rendering. Slots are pure geometry, top-left points (Geometry.swift).
//
// **The corner is the desktop's, not a display's.** A body hangs off the bottom right of the lot it
// is parked in, so a display sitting beyond that corner catches it: the window is not parked but
// sitting in view on another screen. There is one lot for the whole desktop, and the arrangement
// picks it — `init(among:)`.
public struct ParkingLot: Sendable, Equatable {
    /// The working area nubs live against — already Dock/menu-bar inset by the shell, and the
    /// *working* area rather than the content one: a slot inset by the outer gap would poke a window
    /// a margin's width in.
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

    /// The lot the whole desktop parks in: the working area of the display no other display lies
    /// beyond, so a body hangs off the *arrangement* rather than onto a neighbour's screen. Ranked, not
    /// filtered: it `clears` every display, then main, then furthest bottom-right. `nil` with none.
    public init?(among monitors: [MonitorState]) {
        // A display this one *covers* is this one — mirrored displays report the same frame — so its
        // pixels are nowhere a body can land. Which disposes of `monitor` itself, too.
        func isClear(_ monitor: MonitorState) -> Bool {
            let lot = ParkingLot(frame: monitor.workingArea)
            return monitors.allSatisfy { monitor.frame.covers($0.frame) || lot.clears($0.frame) }
        }
        func rank(_ monitor: MonitorState) -> (Int, Int, Double, Double) {
            (isClear(monitor) ? 1 : 0, monitor.isMain ? 1 : 0,
             monitor.workingArea.maxX, monitor.workingArea.maxY)
        }
        // First of equal ranks wins (`max(by:)` replaces only on a strict increase), so enumeration
        // order breaks the last tie and the answer is stable across a re-report.
        guard let best = monitors.max(by: { rank($0) < rank($1) }) else { return nil }
        self.init(frame: best.workingArea)
    }

    /// Whether a nub in this lot keeps its body off `display`. A body hangs off the bottom right, and
    /// the tallest row starts at the lot's own top edge, so it can reach anything right of the nub's
    /// left edge that is not entirely above the lot.
    public func clears(_ display: Rect) -> Bool {
        display.maxX <= frame.maxX - visibleSliver || display.maxY <= frame.minY
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

private extension Rect {
    /// Whether `other` lies entirely within this rect, edges included — two displays are disjoint
    /// unless they are mirrors of each other, which report the same frame.
    func covers(_ other: Rect) -> Bool {
        other.minX >= minX && other.minY >= minY && other.maxX <= maxX && other.maxY <= maxY
    }
}
