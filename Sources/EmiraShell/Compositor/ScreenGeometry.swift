import AppKit
import EmiraCore

// **The single Y-flip.** AX and SCK speak top-left-origin global coordinates; Cocoa speaks
// bottom-left. It happens exactly once, here — core geometry is always top-left virtual-strip space
// and never sees a flipped Y. One number suffices: Cocoa's global origin is the bottom-left of the
// *primary* screen and CG/AX/SCK put theirs at that screen's top-left, so the two differ by a
// reflection about `y = primaryHeight / 2`, which is its own inverse. Secondary displays, including
// ones above the primary where core `y` goes negative, fall out of it with no special case.

/// The conversion between `EmiraCore`'s top-left virtual-strip coordinates and Cocoa's bottom-left
/// global coordinates. Build one per display configuration and re-read it on `Event.screensChanged`:
/// a resolution change or a new primary moves the flip line.
public struct ScreenGeometry: Sendable, Equatable {

    /// The primary screen's height — the reflection line between the two coordinate spaces. Equal to
    /// the Cocoa `maxY` of the screen whose origin is `(0, 0)`.
    public let flipHeight: Double

    public init(flipHeight: Double) {
        self.flipHeight = flipHeight
    }

    /// The geometry of the attached displays right now. The primary screen is the one at the Cocoa
    /// origin, not `screens.first` — AppKit documents that ordering loosely, and the wrong screen
    /// slides every conversion by the difference in heights.
    public static func current() -> ScreenGeometry {
        let screens = NSScreen.screens
        let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
        return ScreenGeometry(flipHeight: Double(primary?.frame.maxY ?? 0))
    }

    /// Core (top-left, `y` down) → Cocoa (bottom-left, `y` up): placing an overlay window or a layer.
    public func cocoa(_ rect: Rect) -> CGRect {
        CGRect(x: rect.minX, y: flipHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Cocoa → core: folding a display's frame into `Event.screensChanged`. Identical arithmetic to
    /// `cocoa(_:)` — the flip is its own inverse — but spelled separately so call sites read as a
    /// direction.
    public func core(_ rect: CGRect) -> Rect {
        Rect(x: Double(rect.minX), y: flipHeight - Double(rect.maxY),
             width: Double(rect.width), height: Double(rect.height))
    }

    /// A core (top-left, global) rect in the local coordinates of a window whose Cocoa frame is
    /// `windowFrame`: flipped, then translated by the window's origin. The cover is inset past the
    /// menu bar and the desktop base sits at a *negative* local origin, so this decides whether the
    /// reconstruction's wallpaper lines up with the real one.
    public func local(_ rect: Rect, in windowFrame: CGRect) -> CGRect {
        let global = cocoa(rect)
        return CGRect(x: global.minX - windowFrame.minX,
                      y: global.minY - windowFrame.minY,
                      width: global.width,
                      height: global.height)
    }

    /// A core (top-left) rect in the local coordinates of a layer whose own frame is the core rect
    /// `parent` — one level below `local(_:in:)`. No `flipHeight` appears, and that is not an
    /// oversight: the reflection cancels between two rects measured from the same origin, leaving a
    /// local reflection about the parent's mid-line.
    public func local(_ rect: Rect, within parent: Rect) -> CGRect {
        CGRect(x: rect.minX - parent.minX,
               y: parent.maxY - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// The region a display reserves for system chrome, as the core's `EdgeInsets` — menu bar and
    /// notch at the top, Dock wherever it lives. A zero here would put title bars out of reach.
    public static func struts(of screen: NSScreen) -> EdgeInsets {
        struts(frame: screen.frame, visible: screen.visibleFrame)
    }

    /// The strut arithmetic over two rectangles, so it is testable with no display attached.
    ///
    /// Both rects are Cocoa's (bottom-left, `y` up), so the vertical edges **swap**: Cocoa's `maxY` is
    /// the top of the screen, where the menu bar is, and becomes the core's `top`. Backwards, this
    /// puts the menu bar's height at the bottom of the strip and hides the Dock instead. Clamped at
    /// zero, since a negative strut would *grow* the working area past the display.
    static func struts(frame: CGRect, visible: CGRect) -> EdgeInsets {
        EdgeInsets(top: max(Double(frame.maxY - visible.maxY), 0),
                   left: max(Double(visible.minX - frame.minX), 0),
                   bottom: max(Double(visible.minY - frame.minY), 0),
                   right: max(Double(frame.maxX - visible.maxX), 0))
    }

    /// A screen's display id, and the `MonitorId` the core knows it by — **one reader, because they
    /// have to be the same number.** ScreenCaptureKit films from the `CGDirectDisplayID`, the overlay
    /// covers that screen and the core lays a strip out on that `MonitorId`; a second reader with its
    /// own fallback is how the three quietly stop being the same display.
    ///
    /// `index` is the enumeration position, standing in for a screen AppKit gives no number — which is
    /// not a display SCK can film either, so the core still gets a distinct id and the capture fails
    /// honestly rather than landing on somebody else's screen.
    public static func displayId(of screen: NSScreen, at index: Int = 0) -> CGDirectDisplayID {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return number ?? CGDirectDisplayID(index)
    }

    public static func monitorId(of screen: NSScreen, at index: Int = 0) -> MonitorId {
        MonitorId(UInt64(displayId(of: screen, at: index)))
    }

    /// The displays currently attached, by the id every display-shaped subsystem keys on. Read live:
    /// the shell builds its overlays and capturers once, and this is how one of them finds out that
    /// the screen it was built for has gone.
    public static func attached(_ screens: [NSScreen] = NSScreen.screens) -> Set<MonitorId> {
        Set(screens.enumerated().map { monitorId(of: $1, at: $0) })
    }

    /// The attached displays as the core's `MonitorInfo`, in AppKit enumeration order — which is the
    /// order `Monitors` keeps its records in. The id is the `CGDirectDisplayID`.
    ///
    /// Each display carries its own struts, so the core and that display's overlay lay out against the
    /// same working area — the invariant that licenses an unpainted chrome band, stated per monitor.
    ///
    /// `isMain` is `CGMainDisplayID()` rather than `screens.first`, for the reason `current()` picks
    /// the primary by its origin. Read here so it rides the one observation: the window server flips
    /// main a beat *before* `NSScreen.screens` catches up, and a later read can name a display this
    /// list does not hold.
    public func monitors(_ screens: [NSScreen]) -> [MonitorInfo] {
        let main = CGMainDisplayID()
        return screens.enumerated().map { index, screen in
            MonitorInfo(id: Self.monitorId(of: screen, at: index),
                        frame: core(screen.frame),
                        struts: Self.struts(of: screen),
                        isMain: Self.displayId(of: screen, at: index) == main)
        }
    }
}
