import AppKit
import EmiraCore

// **The one number.** The whole mock desktop is a single scalar applied to the real display, exactly as
// the guide's projection is.
//
//     k        = mockWidth / display.width
//     mock     = display.frame       · k     the slab drawn
//     working  = display.visibleFrame · k    the menu-bar band is the difference
//
// **The layout runs at real scale and only the result is projected.** `LayoutMetrics` is built against
// the display's true-point working area and `naturalFrames` returns true-point rects; `mock(_:)` is the
// only place `k` is ever applied. Run the layout against the small rect instead and an 8 pt gap becomes
// 8 pt of a 900-point screen — four times too wide, and every preview a lie about the number beside it.
//
// Everything here is **display-local**: the mock is a little world of its own, so the display's origin
// is `(0, 0)` and the global arrangement of monitors never enters. That is also why no `flipHeight`
// appears — `ScreenGeometry`'s reflection cancels between two rects measured from the same origin.

/// The real display's shape, and the scale the mock draws it at.
public struct Projection: Sendable, Equatable {

    /// The display, top-left origin, its own origin at zero. True points.
    public let displayFrame: Rect
    /// The display's working area — what the strip is laid out against. True points, and the same rect
    /// the daemon would use, because it is `visibleFrame` expressed inside `frame`.
    public let workingArea: Rect
    /// `mockWidth / displayFrame.width`.
    public let k: Double

    public init(displayFrame: Rect, workingArea: Rect, k: Double) {
        self.displayFrame = displayFrame
        self.workingArea = workingArea
        self.k = k
    }

    /// The projection for `screen` at a mock `mockWidth` points wide.
    ///
    /// `visibleFrame` inside `frame` *is* the working area: the display's struts are defined as the
    /// difference between the two, so insetting by them lands exactly back on `visibleFrame`.
    public init(screen: NSScreen, mockWidth: Double) {
        let frame = screen.frame
        let visible = screen.visibleFrame
        self.init(displayFrame: Rect(x: 0, y: 0,
                                     width: Double(frame.width), height: Double(frame.height)),
                  workingArea: Rect(x: Double(visible.minX - frame.minX),
                                    y: Double(frame.maxY - visible.maxY),
                                    width: Double(visible.width), height: Double(visible.height)),
                  k: mockWidth / Double(frame.width))
    }

    /// The mock slab's size in points — what the monitor layer's bounds are.
    public var mockSize: CGSize {
        CGSize(width: displayFrame.width * k, height: displayFrame.height * k)
    }

    /// The menu-bar band's height on the mock: the real difference between the display's frame and its
    /// working area, scaled. What lets the outer-gap preview be truthful about what it insets from.
    public var menuBandHeight: Double {
        (workingArea.minY - displayFrame.minY) * k
    }

    /// A true-point rect on the display, as a layer frame inside the mock slab — scaled by `k` and
    /// reflected into Core Animation's bottom-left space.
    ///
    /// The reflection is about the slab's own mid-line: both rects are measured from the display's
    /// origin, so the flip is local and no screen height appears.
    public func mock(_ rect: Rect) -> CGRect {
        CGRect(x: (rect.minX - displayFrame.minX) * k,
               y: (displayFrame.maxY - rect.maxY) * k,
               width: rect.width * k,
               height: rect.height * k)
    }

    /// A length in true points, at mock scale — a gap, a corner radius, a shadow offset.
    public func mock(_ length: Double) -> CGFloat { length * k }
}
