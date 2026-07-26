import AppKit
import EmiraCore

// **The single Y-flip.** (IMPLEMENTATION.md §7, "Coordinate spaces": *"AX and SCK speak
// top-left-origin global coordinates; Cocoa speaks bottom-left. The Y-flip happens exactly once, at
// the `AXClient`/`CaptureService` boundary — core geometry is always top-left virtual-strip space and
// never sees a flipped Y. Every spike hand-rolled this flip; the real codebase does it in one
// place."*)
//
// This is that one place. Every spike carried its own `localRect`/`primaryH` arithmetic
// (`spike/strip-scroll.swift:259`) and each one was an opportunity to get a sign wrong in a way that
// only shows up as a window landing on the wrong monitor. Here it is a value type over **one number**
// — the flip height — with an inverse, so the conversion is testable in both directions with no
// display attached.
//
// **Why one number is enough.** Cocoa's global coordinate space has its origin at the bottom-left of
// the *primary* screen (the one whose Cocoa frame origin is `(0, 0)`), with `y` growing up; CG/AX/SCK
// put their origin at that same screen's *top*-left with `y` growing down. So the two spaces differ
// by a reflection about `y = primaryHeight / 2`, and `flip(flip(r)) == r`: the transform is its own
// inverse, which is exactly the property the round-trip test pins. Secondary displays — including
// ones sitting *above* the primary, where core `y` goes negative — need no special case; they fall
// out of the same reflection.

/// The conversion between `EmiraCore`'s top-left virtual-strip coordinates and Cocoa's bottom-left
/// global coordinates, parameterized by the primary display's height.
///
/// Construct it once per display configuration (`current()`) and hand it to every overlay; re-read it
/// on `Event.screensChanged`, since a resolution change or a new primary moves the flip line.
public struct ScreenGeometry: Sendable, Equatable {

    /// The primary screen's height — the reflection line between the two coordinate spaces. Equal to
    /// the Cocoa `maxY` of the screen whose origin is `(0, 0)`.
    public let flipHeight: Double

    /// Build a geometry for a known flip height. Tests use this directly; production goes through
    /// `current()`.
    public init(flipHeight: Double) {
        self.flipHeight = flipHeight
    }

    /// The geometry of the attached displays right now.
    ///
    /// The primary screen is the one at the Cocoa origin, not simply `screens.first` — AppKit
    /// documents the ordering loosely, and picking the wrong screen would slide every conversion by
    /// the difference in heights. Falls back to the first screen, then to a zero flip (a headless
    /// process has nothing to convert *for*, and a zero height is a self-evidently wrong number rather
    /// than a plausible one).
    public static func current() -> ScreenGeometry {
        let screens = NSScreen.screens
        let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
        return ScreenGeometry(flipHeight: Double(primary?.frame.maxY ?? 0))
    }

    /// Core (top-left, `y` down) → Cocoa (bottom-left, `y` up). The direction used to place an overlay
    /// window and its layers.
    public func cocoa(_ rect: Rect) -> CGRect {
        CGRect(x: rect.minX, y: flipHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Cocoa (bottom-left, `y` up) → core (top-left, `y` down). The direction used to fold a display's
    /// frame into `Event.screensChanged`. Identical arithmetic to `cocoa(_:)` — the flip is an
    /// involution — but spelled as its own method so call sites read as a direction, not a coin flip.
    public func core(_ rect: CGRect) -> Rect {
        Rect(x: Double(rect.minX), y: flipHeight - Double(rect.maxY),
             width: Double(rect.width), height: Double(rect.height))
    }

    /// A core (top-left, global) rect in the **local** coordinates of a window whose Cocoa frame is
    /// `windowFrame`: flipped to Cocoa, then translated by the window's origin. The conversion the
    /// compositor performs for every layer, every frame.
    ///
    /// Split out of `Overlay` (M4 part 3) because the overlay stopped being the whole screen. While the
    /// two coincided, a sign error here was invisible — every offset was zero. Now the cover is inset
    /// past the menu bar and the desktop base sits at a *negative* local origin, so this arithmetic
    /// decides whether the reconstruction's wallpaper is aligned with the real one or shifted by the
    /// height of the menu bar. That is worth a test with no display attached.
    public func local(_ rect: Rect, in windowFrame: CGRect) -> CGRect {
        let global = cocoa(rect)
        return CGRect(x: global.minX - windowFrame.minX,
                      y: global.minY - windowFrame.minY,
                      width: global.width,
                      height: global.height)
    }

    /// The region a display reserves for system chrome, as the core's `EdgeInsets` — the menu bar and
    /// notch at the top, the Dock on whichever edge it lives (IMPLEMENTATION.md §4a: tiled windows
    /// never sit under either).
    ///
    /// **Why this is here now.** Enumeration alone (M3 part 1) could leave `Config.struts` at zero
    /// because nothing acted on it — the strip ran under the menu bar in a state dump and nowhere else.
    /// The moment AX writes land, the same zero *moves the user's windows* under the menu bar, where
    /// their title bars are unreachable. So the number stops being a config nicety and becomes part of
    /// the write path being correct.
    ///
    /// Still a *decision* rather than a law, and one the config file overrides at M5: "the working area
    /// is `visibleFrame`" is exactly what a user who has hidden their Dock, or who wants an outer
    /// margin, will want to change.
    public static func struts(of screen: NSScreen) -> EdgeInsets {
        struts(frame: screen.frame, visible: screen.visibleFrame)
    }

    /// The strut arithmetic, over two rectangles — so the decision above is testable with no display
    /// attached and the framework call above it holds none.
    ///
    /// Both rects are Cocoa's (bottom-left, `y` up), so the vertical edges **swap**: Cocoa's `maxY` is
    /// the top of the screen, where the menu bar is, and becomes the core's `top`. Getting this
    /// backwards puts the menu bar's height at the bottom of the strip and hides the Dock instead —
    /// which looks almost right, and is the reason it is spelled out rather than inlined.
    ///
    /// Clamped at zero: `visibleFrame` is documented as a subset of `frame`, and a negative strut would
    /// *grow* the working area past the display (`Rect.inset(by:)` takes negatives happily).
    static func struts(frame: CGRect, visible: CGRect) -> EdgeInsets {
        EdgeInsets(top: max(Double(frame.maxY - visible.maxY), 0),
                   left: max(Double(visible.minX - frame.minX), 0),
                   bottom: max(Double(visible.minY - frame.minY), 0),
                   right: max(Double(frame.maxX - visible.maxX), 0))
    }

    /// The attached displays as the core's `MonitorInfo`, in AppKit enumeration order (which is what
    /// `MonitorRef.index`/`.next` resolve against, per `Event.screensChanged`'s contract).
    ///
    /// The id is the `CGDirectDisplayID`, so it is stable across a re-enumeration for as long as the
    /// display stays attached — what per-monitor strips need at M6 to survive a hotplug of a *different*
    /// display. Falls back to the enumeration index for the (theoretical) screen with no display number.
    public func monitors(_ screens: [NSScreen]) -> [MonitorInfo] {
        screens.enumerated().map { index, screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return MonitorInfo(id: MonitorId(UInt64(number ?? CGDirectDisplayID(index))),
                               frame: core(screen.frame))
        }
    }
}
