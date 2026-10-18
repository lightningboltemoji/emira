import Foundation

// Where one display sits among the others, as far as the window server's drawing goes.
//
// **A window is drawn on one display only: the one holding the largest share of it.** Whatever of it lies
// on any other display is not drawn there at all. So a column hanging off a screen's edge is drawn on that
// screen, cut at the edge, for as long as more of it is on that screen than beyond — and past that point it
// is drawn whole on whatever display the rest of it is over, on top of that screen's own windows, while
// the screen whose strip it is on shows nothing where it should be.
//
// So the placement pass asks this before putting a window on the glass, and a column the neighbour would
// take is parked instead and drawn on its own screen by a peek (`PeekBinding`).

/// One display's frame and every other attached display's — the whole of what decides which screen a
/// window standing somewhere is drawn on. Rides in `LayoutMetrics` for `ParkingLot`'s reason: a query that
/// built its own would be a second opinion about where a window shows.
public struct Neighbourhood: Sendable, Equatable {
    /// This display's full bounds, menu bar and Dock included — they are glass the window is drawn on.
    public let frame: Rect
    /// Every other attached display's full bounds. A mirror reports this display's own frame, so it is
    /// left out: its pixels are these ones.
    public let others: [Rect]

    public init(frame: Rect, others: [Rect] = []) {
        self.frame = frame
        self.others = others.filter { $0 != frame }
    }

    /// Whether the window server draws a window standing at `window` on this display. Strictly more of it
    /// here than on any other display, because a tie is macOS's to break and losing it puts the window
    /// whole on the neighbour.
    public func draws(_ window: Rect) -> Bool {
        let here = window.overlapArea(with: frame)
        return here > 0 && others.allSatisfy { window.overlapArea(with: $0) < here }
    }
}
