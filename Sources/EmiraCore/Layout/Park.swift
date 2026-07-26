import Foundation

// Park slots — where an off-viewport column's windows go to wait (PRINCIPLES.md §4a, §7;
// IMPLEMENTATION.md §5, `Layout/Park.swift`).
//
// emira emulates workspaces and off-screen stashing by parking the windows the viewport isn't
// showing, rather than touching native Spaces (PRINCIPLES.md §3). But macOS **won't let a window
// leave the screen** — it honors a requested position only while a sliver stays on-screen (validated
// in `spike/strip-scroll.swift`'s `cornerPark`; PRINCIPLES.md §10). So a parked window is shoved
// almost entirely off an edge, leaving a thin sliver poking back in. Two properties make that sliver
// load-bearing rather than incidental:
//
//  · **Warm.** Occlusion is binary — any visible pixel keeps the app rendering (PRINCIPLES.md §10),
//    so a parked column doesn't freeze and scrolls back in without a flash. The sliver is what keeps
//    it warm.
//  · **Unique.** Every parked window gets a *distinct* frame, so first-sight identity rebinding
//    after a daemon restart (pid+frame+title → `CGWindowID`, PRINCIPLES.md §7) is never ambiguous —
//    parked frames would otherwise all collapse onto the same edge and collide.
//
// A park slot is **just target geometry** (§4a: "computed by the layout engine like any other target
// geometry"), so it lives in the pure core: `slot(ordinal:size:)` is a deterministic, replay-testable
// function of a window's size and its ordinal among the parked set. Slots hug the **left** edge —
// each window pushed off so only `visibleSliver` px poke back in — and stagger **downward** by
// `stagger` per ordinal to keep frames distinct; past one column's worth of rows they wrap into a new
// lane a sliver further on-screen, staying unique and total for any ordinal.
//
// Dock/menu-bar avoidance (§4a) is handled upstream: `frame` is the monitor **working area** (already
// inset past the Dock and menu bar by the shell), so slots never land under the Dock by construction.
// Coordinates are top-left virtual-strip points (Geometry.swift).
public struct ParkingLot: Sendable, Equatable {
    /// The monitor working area parked slivers live against — already Dock/menu-bar inset by the
    /// shell, so hugging its edges is safe.
    public let frame: Rect
    /// How many points of a parked window stay on-screen (the poking sliver's width). ~1 pt is
    /// enough for macOS to honor the position (PRINCIPLES.md §10) and to keep the window warm; the
    /// default keeps intrusion minimal.
    public let visibleSliver: Double
    /// The vertical step between successive slots — what makes each parked frame distinct and
    /// spreads the slivers down the edge so they don't stack into one blob.
    public let stagger: Double

    public init(frame: Rect, visibleSliver: Double = 1, stagger: Double = 8) {
        self.frame = frame
        self.visibleSliver = visibleSliver
        self.stagger = stagger
    }

    /// How many staggered rows fit down the left edge before a new lane starts. At least one, always.
    private var rowsPerLane: Int {
        max(Int((frame.height / stagger).rounded(.down)), 1)
    }

    /// The park frame for the `ordinal`-th parked window of size `size`: the window shoved off the
    /// left edge so exactly `visibleSliver` px poke back in, its top staggered `stagger` px down per
    /// ordinal. Deterministic and **unique** per ordinal (distinct frames for identity rebind, §7),
    /// and total for any `ordinal` (negatives snap to 0; past one lane it wraps a sliver further in,
    /// never colliding). The returned rect keeps `size` verbatim — parking repositions, never resizes.
    public func slot(ordinal: Int, size: Size) -> Rect {
        let n = max(ordinal, 0)
        let rows = rowsPerLane
        let lane = n / rows
        let row = n % rows
        // Poke `visibleSliver` px in from the left; each new lane pokes one sliver further, so lanes
        // never share an x (still tiny, still warm). x itself is off-screen-left (mostly negative).
        let pokeX = visibleSliver * Double(lane + 1)
        let x = frame.minX - size.width + pokeX
        let y = frame.minY + Double(row) * stagger
        return Rect(x: x, y: y, width: size.width, height: size.height)
    }
}
