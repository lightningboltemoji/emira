import Foundation

// emira's own geometry primitives, defined on the infinite virtual strip. Not CoreGraphics types —
// `EmiraCore` is Foundation-only.
//
// Top-left origin, always: `y` grows downward, `minY` is the top edge. Cocoa speaks bottom-left, and
// the single Y-flip happens once at the `AXClient`/`CaptureService` boundary. `x` is unbounded.

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

    /// Straight-line distance to another point.
    public func distance(to other: Point) -> Double {
        let dx = x - other.x, dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
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

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Within `tolerance` of `other` on both axes.
    public func isClose(to other: Size, within tolerance: Double) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    public var description: String { "\(width)×\(height)" }
}

/// An axis-aligned rectangle on the virtual strip. Top-left origin: `minY` is the top edge, `maxY` the
/// bottom. Window frames, columns, the viewport, park slots and struts are all `Rect`s in this space.
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

    /// Half-open containment `[minX, maxX) × [minY, maxY)`, matching `CGRectContainsPoint` — two
    /// edge-sharing rects (adjacent columns) never both claim the boundary.
    public func contains(_ p: Point) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    /// Strict positive-area overlap (matching `CGRectIntersectsRect`): rects that merely share an edge
    /// do *not* intersect.
    public func intersects(_ other: Rect) -> Bool {
        minX < other.maxX && maxX > other.minX &&
        minY < other.maxY && maxY > other.minY
    }

    /// The overlapping region, or `nil` when it has no positive area — consistent with `intersects`.
    public func intersection(_ other: Rect) -> Rect? {
        let x1 = max(minX, other.minX)
        let y1 = max(minY, other.minY)
        let x2 = min(maxX, other.maxX)
        let y2 = min(maxY, other.maxY)
        guard x2 > x1, y2 > y1 else { return nil }
        return Rect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    /// How much of this rect lies inside `other`, in square points — zero where they do not overlap.
    public func overlapArea(with other: Rect) -> Double {
        intersection(other)?.area ?? 0
    }

    /// The index of the rect in `frames` holding the largest share of this one — the display the window
    /// server draws a window on (`Neighbourhood`). The first wins a tie; `nil` where none overlaps it.
    public func largestShare(among frames: [Rect]) -> Int? {
        var best: (index: Int, area: Double)?
        for (index, frame) in frames.enumerated() {
            let area = overlapArea(with: frame)
            guard area > 0, area > best?.area ?? 0 else { continue }
            best = (index, area)
        }
        return best?.index
    }

    /// The smallest rect enclosing both. An empty operand is ignored rather than dragging the union to
    /// the origin, so this accumulates a bounding box cleanly.
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

    /// Translate *and* resize by a component-wise delta — the presentation plane adding a window's
    /// in-flight displacement to its layout frame. Unlike `offsetBy`, this carries a size change.
    public func displaced(by delta: Rect) -> Rect {
        Rect(x: minX + delta.minX, y: minY + delta.minY,
             width: width + delta.width, height: height + delta.height)
    }

    /// The component-wise difference `self − other`: the displacement that carries `other` to `self`.
    public func delta(from other: Rect) -> Rect {
        Rect(x: minX - other.minX, y: minY - other.minY,
             width: width - other.width, height: height - other.height)
    }

    /// Symmetric inset; negative values grow the rect. The caller owns avoiding a collapse past zero.
    public func insetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: minX + dx, y: minY + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    /// Asymmetric inset by per-edge amounts — the primitive for struts and outer gaps. Top-left origin,
    /// so a positive `top` pushes the origin down and trims height.
    public func inset(by insets: EdgeInsets) -> Rect {
        Rect(x: minX + insets.left,
             y: minY + insets.top,
             width: width - insets.left - insets.right,
             height: height - insets.top - insets.bottom)
    }

    /// Origin and size each rounded to whole points — what AX stores, so the only frame a write can land
    /// on exactly. Rounded separately rather than by edge, so no size moves more than half a point.
    public func rounded() -> Rect {
        Rect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }

    /// Within `tolerance` of `other` on every edge.
    public func isClose(to other: Rect, within tolerance: Double) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    public var description: String { "Rect(\(origin.x), \(origin.y), \(size.width)×\(size.height))" }
}

/// How far apart two geometries may be and still be one, by what is being compared. Kept together so the
/// relations between them are stated rather than latent: a check that must agree with another reads the
/// same constant, and one that must clear another says so beside it.
public enum Tolerance {
    /// A placement and its landing. Frames are written whole (`Rect.rounded()`), so a window a whole point
    /// off is its app's answer and anything less is arithmetic. The reducer's diff and the executor's
    /// landing report both read this: two thresholds would re-write a window landing between them.
    public static let placement = 0.5

    /// How far a landing may sit from its request before the writer re-sets it once (`AXWindow.place`).
    /// A clamp worth a second size → position pass is more than a point; within one is an app's own
    /// rounding, which a second pass would only repeat.
    public static let landing = 1.0

    /// Two subsystems describing one window's frame — an AX read against the window list, or a departing
    /// tab against its successor (`WindowIdentity`). Their rounding and nothing wider: a parked nub's
    /// stagger has to clear it (`ParkingLot`), or two parked windows of one app bind ambiguously.
    public static let identity = 2.0

    /// A kept still's size against the window it would stand in for (`SurfaceCache`): the same rounding
    /// as `identity`, between what AX answered and what ScreenCaptureKit filmed.
    public static let still = identity
}

/// Per-edge insets: struts (asymmetric, e.g. the menu bar) and gaps (uniform). `top` is the menu edge.
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

/// Some of an inset's edges: what a file says about one when it need not say all four. A `nil` edge
/// is one it leaves as it was.
public struct EdgeInsetsPatch: Sendable, Equatable, Codable {
    public var top: Double?
    public var left: Double?
    public var bottom: Double?
    public var right: Double?

    public init(top: Double? = nil, left: Double? = nil, bottom: Double? = nil, right: Double? = nil) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    /// Whether this sets no edge at all.
    public var isEmpty: Bool { top == nil && left == nil && bottom == nil && right == nil }

    /// `insets`, with every edge this sets replaced.
    public func applied(to insets: EdgeInsets) -> EdgeInsets {
        EdgeInsets(top: top ?? insets.top, left: left ?? insets.left,
                   bottom: bottom ?? insets.bottom, right: right ?? insets.right)
    }
}

//
// Read only by the compositor; the arithmetic lives here because it is pure and testable headlessly.

/// How a window's captured still is mapped into the rect it occupies this frame. The two modes trade
/// against the same fact: during a resize we hold pixels of the *old* size and only the app makes new
/// ones.
public enum WindowAnimation: String, Sendable, Equatable, Codable, CaseIterable {
    /// Scale the still to fill the rect: geometry exact, content distorted. The default.
    case stretch
    /// Hold the still at its captured scale, anchored top-left: content exact, geometry incomplete. A
    /// grown window shows desktop through the space it hasn't filled; a shrunk one is cut off.
    case crop
}

extension Rect {

    /// Where a still of size `natural` sits inside this rect at its captured scale
    /// (`WindowAnimation.crop`) — pinned to the top-left, at its own size, larger or smaller. A rule
    /// about the anchor, not about fitting: a larger still deliberately overflows and the compositor's
    /// rounded clip is what cuts it off, so the cut follows the window's own corner.
    public func anchoring(_ natural: Size) -> Rect {
        Rect(origin: origin, size: natural)
    }
}
