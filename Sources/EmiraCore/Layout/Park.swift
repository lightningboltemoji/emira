import Foundation

// Park slots — where an off-viewport column's windows go to wait (PRINCIPLES.md §4a, §7;
// IMPLEMENTATION.md §5, `Layout/Park.swift`).
//
// emira emulates workspaces and off-screen stashing by parking the windows the viewport isn't
// showing, rather than touching native Spaces (PRINCIPLES.md §3). But macOS **won't let a window
// leave the screen** — it honors a requested position only while a sliver stays on-screen (validated
// in `spike/strip-scroll.swift`'s `cornerPark`; PRINCIPLES.md §10). So a parked window is shoved
// almost entirely off a *corner*, leaving a thin nub poking back in. Three properties make that nub
// load-bearing rather than incidental:
//
//  · **Warm.** Occlusion is binary — any visible pixel keeps the app rendering (PRINCIPLES.md §10),
//    so a parked column doesn't freeze and scrolls back in without a flash. The nub is what keeps
//    it warm.
//  · **Unique.** Every parked window gets a *distinct* frame, so first-sight identity rebinding
//    after a daemon restart (pid+frame+title → `CGWindowID`, PRINCIPLES.md §7) is never ambiguous —
//    parked frames would otherwise all collapse onto the same corner and collide. "Distinct" has a
//    number attached: `WindowRegistry.bind` matches frames within ±2 pt per edge and refuses a
//    window that has two candidates, so successive slots must differ by *more* than that tolerance.
//    That is what `stagger` is for, and why it is 8 pt rather than 1 — the nub's height is the only
//    thing telling two same-size parked windows of one app apart, since a right-edge park gives them
//    all the same `minX` whatever their widths.
//  · **Grabbable.** The nub is the window's own **top-left corner** — the title bar, the one place a
//    window can always be dragged from — held against the working area's *right* edge. A user
//    rescuing a parked window by hand throws the pointer at the screen's right edge (where it stops)
//    and lands on chrome, instead of on whatever toolbar control the window's far edge happens to
//    carry, which is what a left-edge park leaves on screen (decided 2026-07-26).
//
// A park slot is **just target geometry** (§4a: "computed by the layout engine like any other target
// geometry"), so it lives in the pure core: `slot(ordinal:size:)` is a deterministic, replay-testable
// function of a window's size and its ordinal among the parked set. Slots hug the working area's
// **bottom-right corner**: each window is pushed off to the right so only `visibleSliver` px of its
// left edge poke back in, and off the bottom so only `visibleChrome` px of its top do. The nub grows
// `stagger` px taller per ordinal to keep frames distinct; past one lane's worth of rows they wrap
// into a new lane a sliver further on-screen, staying unique and total for any ordinal.
//
// Dock/menu-bar avoidance (§4a) is handled upstream: `frame` is the monitor **working area** (already
// inset past the Dock and menu bar by the shell), so the nub rests just above the Dock rather than
// under it. The window's *body* does hang past that bottom edge — a `visibleSliver`-wide tail of it
// crosses the Dock band on its way off the display, which is the one place a parked window is not
// under the compositor's cover (`Compositor/Overlay.swift`). One point wide beside the Dock is the
// price of parking a corner instead of a full-height edge.
// Coordinates are top-left virtual-strip points (Geometry.swift).
public struct ParkingLot: Sendable, Equatable {
    /// The monitor working area parked nubs live against — already Dock/menu-bar inset by the
    /// shell, so hugging its edges is safe.
    public let frame: Rect
    /// How many points of a parked window's **left edge** stay on-screen (the nub's width). ~1 pt is
    /// enough for macOS to honor the position (PRINCIPLES.md §10) and to keep the window warm; the
    /// default keeps intrusion minimal.
    public let visibleSliver: Double
    /// How many points of a parked window's **top edge** stay on-screen (the nub's height) — the
    /// window's title bar, so the nub is something a hand can grab. ~40 pt is a standard title bar;
    /// the rest of the window hangs off the bottom of the display.
    public let visibleChrome: Double
    /// The step by which the nub grows taller per ordinal — what makes each parked frame distinct.
    /// Must clear `WindowRegistry`'s ±2 pt binding tolerance, or two parked windows of one app become
    /// ambiguous at rebind and neither is managed.
    public let stagger: Double

    public init(frame: Rect, visibleSliver: Double = 1, visibleChrome: Double = 40,
                stagger: Double = 8) {
        self.frame = frame
        self.visibleSliver = visibleSliver
        self.visibleChrome = visibleChrome
        self.stagger = stagger
    }

    /// How many staggered rows a lane holds before a new one starts: as many as fit before the nub
    /// would be taller than the working area itself, at which point growing it further would defeat
    /// the point of a nub. At least one, always. Wrapping trades height for width — a second lane
    /// pokes one more point in — and height is the cheaper of the two at 1 pt wide, so a lane is
    /// deliberately long (~107 rows on a 900 pt-tall area): real parked sets never reach it.
    private var rowsPerLane: Int {
        max(Int(((frame.height - visibleChrome) / stagger).rounded(.down)) + 1, 1)
    }

    /// The park frame for the `ordinal`-th parked window of size `size`: the window shoved off the
    /// bottom-right corner so exactly `visibleSliver` px of its left edge and `visibleChrome` px of
    /// its top edge (+ `stagger` px per ordinal) poke back in. Deterministic and **unique** per
    /// ordinal (distinct frames for identity rebind, §7), and total for any `ordinal` (negatives snap
    /// to 0; past one lane it wraps a sliver further in, never colliding). The returned rect keeps
    /// `size` verbatim — parking repositions, never resizes.
    public func slot(ordinal: Int, size: Size) -> Rect {
        let n = max(ordinal, 0)
        let rows = rowsPerLane
        let lane = n / rows
        let row = n % rows
        // Poke `visibleSliver` px in from the right; each new lane pokes one sliver further, so lanes
        // never share an x (still tiny, still warm). The body sits off-screen right of `frame.maxX`.
        let pokeX = visibleSliver * Double(lane + 1)
        let x = frame.maxX - pokeX
        // …and the top edge `visibleChrome` px up from the bottom, one stagger taller per row. The
        // rest of the window hangs below the working area, off the bottom of the display.
        let pokeY = visibleChrome + Double(row) * stagger
        let y = frame.maxY - pokeY
        return Rect(x: x, y: y, width: size.width, height: size.height)
    }
}
