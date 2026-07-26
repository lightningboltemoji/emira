import Foundation

// emira's own geometry primitives, defined on the infinite virtual strip.
//
// These are deliberately **not** CoreGraphics types, for two reasons the charter insists on
// (PRINCIPLES.md §3, IMPLEMENTATION.md §7):
//
//  1. `EmiraCore` is Foundation-only — it may not import CoreGraphics/AppKit. Owning
//     `Point`/`Size`/`Rect` keeps the brain framework-free and unit-testable in isolation.
//  2. **Top-left origin, always.** AX and ScreenCaptureKit speak top-left-origin global
//     coordinates; Cocoa speaks bottom-left. The single Y-flip happens exactly once, at the
//     `AXClient`/`CaptureService` boundary — core geometry never sees a flipped Y. So here `y`
//     grows **downward**: `minY` is the *top* edge, `maxY` is the *bottom* edge. Stated once,
//     relied on everywhere.
//
// The x-axis is the infinite scrollable ribbon — columns arranged left→right, a viewport-worth
// on-screen and the rest parked off-screen — so `x` is unbounded and routinely negative. Nothing
// here assumes a finite screen.

/// A point on the virtual strip. Top-left origin (`y` grows downward).
public struct Point: Sendable, Equatable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)

    /// Translate by a delta. `+dy` moves *down* (top-left origin).
    public func offsetBy(dx: Double, dy: Double) -> Point {
        Point(x: x + dx, y: y + dy)
    }

    public var description: String { "(\(x), \(y))" }
}

/// A width × height extent. Negative or zero dimensions are considered empty.
public struct Size: Sendable, Equatable, Codable, CustomStringConvertible {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)

    public var area: Double { width * height }

    /// A non-positive dimension means the size encloses nothing.
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public var description: String { "\(width)×\(height)" }
}

/// An axis-aligned rectangle on the virtual strip. Top-left origin: `minY` is the top edge,
/// `maxY` the bottom. This is the workhorse type — a window frame, a column, the viewport, a
/// park slot, and a strut region are all `Rect`s in the same coordinate space.
public struct Rect: Sendable, Equatable, Codable, CustomStringConvertible {
    public var origin: Point
    public var size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var width: Double { size.width }
    public var height: Double { size.height }

    // Edges. Top-left origin, so `minY`/`maxY` are top/bottom respectively.
    public var minX: Double { origin.x }
    public var minY: Double { origin.y }          // top
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height } // bottom

    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }
    public var center: Point { Point(x: midX, y: midY) }

    public var area: Double { size.area }
    public var isEmpty: Bool { size.isEmpty }

    /// Half-open containment `[minX, maxX) × [minY, maxY)` — matching `CGRectContainsPoint`, so
    /// two edge-sharing rects (adjacent columns) never both claim the boundary. An empty rect
    /// contains nothing.
    public func contains(_ p: Point) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    /// Strict positive-area overlap (matching `CGRectIntersectsRect`): rects that merely share
    /// an edge do **not** intersect. This is the predicate that scopes the `axLanded` wait —
    /// "every window whose start *or* end frame intersects the viewport" (IMPLEMENTATION.md §3).
    public func intersects(_ other: Rect) -> Bool {
        minX < other.maxX && maxX > other.minX &&
        minY < other.maxY && maxY > other.minY
    }

    /// The overlapping region, or `nil` when the overlap has no positive area (disjoint or
    /// edge-touching) — consistent with `intersects`.
    public func intersection(_ other: Rect) -> Rect? {
        let x1 = max(minX, other.minX)
        let y1 = max(minY, other.minY)
        let x2 = min(maxX, other.maxX)
        let y2 = min(maxY, other.maxY)
        guard x2 > x1, y2 > y1 else { return nil }
        return Rect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    /// The smallest rect enclosing both. An empty operand is ignored (so this accumulates a
    /// bounding box cleanly), rather than dragging the union to the origin.
    public func union(_ other: Rect) -> Rect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let x1 = min(minX, other.minX)
        let y1 = min(minY, other.minY)
        let x2 = max(maxX, other.maxX)
        let y2 = max(maxY, other.maxY)
        return Rect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    /// Translate without resizing — the strip scroll is exactly this on every column's frame.
    public func offsetBy(dx: Double, dy: Double) -> Rect {
        Rect(origin: origin.offsetBy(dx: dx, dy: dy), size: size)
    }

    /// Translate **and** resize by a component-wise delta — the presentation plane adding a
    /// window's in-flight *displacement* to its layout-derived frame (`Motion.windowAnimators`).
    /// Distinct from `offsetBy(dx:dy:)`, which cannot carry a size: a consumed window changes
    /// height as well as position, and both halves have to travel together.
    public func displaced(by delta: Rect) -> Rect {
        Rect(x: minX + delta.minX, y: minY + delta.minY,
             width: width + delta.width, height: height + delta.height)
    }

    /// The component-wise difference `self − other`, as the displacement that carries `other` to
    /// `self`. The seed of a structural edit's animation: *where a window was*, expressed relative
    /// to where the new layout says it now belongs.
    public func delta(from other: Rect) -> Rect {
        Rect(x: minX - other.minX, y: minY - other.minY,
             width: width - other.width, height: height - other.height)
    }

    /// Symmetric inset: shrink by `dx` on each vertical edge and `dy` on each horizontal edge.
    /// Negative values grow the rect. The caller owns avoiding a collapse past zero size.
    public func insetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: minX + dx, y: minY + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    /// Asymmetric inset by per-edge amounts — the primitive for **struts** (reserve the
    /// menu-bar/notch region at the top) and **gaps** (a uniform inset). Top-left origin, so a
    /// positive `top` pushes the origin down and trims height.
    public func inset(by insets: EdgeInsets) -> Rect {
        Rect(x: minX + insets.left,
             y: minY + insets.top,
             width: width - insets.left - insets.right,
             height: height - insets.top - insets.bottom)
    }

    public var description: String { "Rect(\(origin.x), \(origin.y), \(size.width)×\(size.height))" }
}

/// Per-edge insets — used to model struts (asymmetric, e.g. menu bar at the top) and gaps
/// (uniform). Top-left origin, so `top` is the menu-bar edge.
public struct EdgeInsets: Sendable, Equatable, Codable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = EdgeInsets()

    /// The same inset on all four edges — the shape of a gap.
    public init(uniform value: Double) {
        self.init(top: value, left: value, bottom: value, right: value)
    }
}
