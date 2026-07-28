import Foundation

// The infinite horizontal strip: columns laid out left→right at resolved point widths separated by
// `gap`, with a viewport of `viewportWidth` whose left edge sits at the scroll offset — a column's
// on-screen position is derived from that one scalar, never stored. Pure math, no policy.
//
// Virtual-strip points, top-left origin (Geometry.swift); `x` is unbounded and routinely negative.
public struct Strip: Sendable, Equatable {
    /// Resolved column widths in points, left→right.
    public let columnWidths: [Double]
    /// The gap between adjacent columns, in points. Between columns only — outer margins are applied
    /// upstream of the strip.
    public let gap: Double
    /// The x of the first column's left edge. Usually 0; a nonzero value shifts the entire run.
    public let origin: Double

    public init(columnWidths: [Double], gap: Double, origin: Double = 0) {
        self.columnWidths = columnWidths
        self.gap = gap
        self.origin = origin
    }

    public var count: Int { columnWidths.count }
    public var isEmpty: Bool { columnWidths.isEmpty }

    // MARK: Placement

    /// The x of column `i`'s left edge. Defined for `i` in `0...count` — `leftEdge(of: count)` is where
    /// a newly appended column would go. Outside that range it clamps, so the function is total.
    public func leftEdge(of i: Int) -> Double {
        let clamped = min(max(i, 0), count)
        var x = origin
        for k in 0..<clamped {
            x += columnWidths[k] + gap
        }
        return x
    }

    /// The `[x, width]` span of column `i`. An out-of-range index yields a zero-width span at the
    /// clamped edge.
    public func span(of i: Int) -> (x: Double, width: Double) {
        guard i >= 0, i < count else { return (leftEdge(of: i), 0) }
        return (leftEdge(of: i), columnWidths[i])
    }

    /// Total width of the laid-out run: `Σ widths + (count − 1)·gap`, or `0` when empty. No outer gaps.
    public var contentWidth: Double {
        guard count > 0 else { return 0 }
        return columnWidths.reduce(0, +) + Double(count - 1) * gap
    }

    // MARK: Scroll math — offset that frames a column

    /// The largest offset that still shows content across the whole viewport — the last column's right
    /// edge flush with the viewport's. Degenerates to `origin` when the strip fits entirely on screen.
    public func maxOffset(viewportWidth: Double) -> Double {
        Swift.max(origin, origin + contentWidth - viewportWidth)
    }

    /// `offset` brought inside `[origin, maxOffset]` — not looking past either end of the strip.
    public func clampOffset(_ offset: Double, viewportWidth: Double) -> Double {
        Swift.min(Swift.max(offset, origin), maxOffset(viewportWidth: viewportWidth))
    }

    /// The scroll offset that places column `i`'s left edge flush with the viewport's left edge.
    public func offsetToAlignLeft(_ i: Int) -> Double {
        leftEdge(of: i)
    }

    /// The scroll offset that centers column `i`. A column wider than the viewport still centers, its
    /// overflow spilling equally off both edges.
    public func offsetToCenter(_ i: Int, viewportWidth: Double) -> Double {
        let (x, w) = span(of: i)
        return x + w / 2 - viewportWidth / 2
    }

    /// The minimal scroll change that makes column `i` fully visible from `offset`: unchanged if it
    /// already fits, otherwise scrolled just far enough to bring the hidden edge in. A column wider
    /// than the viewport cannot fit, so its left edge is aligned instead.
    ///
    /// The result is clamped even in the "already visible, don't move" case — otherwise a viewport
    /// left pointing past the end of the strip stays stranded there.
    public func offsetToReveal(_ i: Int, viewportWidth: Double, from offset: Double) -> Double {
        let (left, width) = span(of: i)
        let right = left + width
        let framed: Double
        if width >= viewportWidth { framed = left }            // can't fit: show the left edge
        else if left < offset { framed = left }                // hidden past the left: pull it in
        else if right > offset + viewportWidth { framed = right - viewportWidth }  // past the right
        else { framed = offset }                               // already fully visible: don't move
        return clampOffset(framed, viewportWidth: viewportWidth)
    }

    // MARK: Visibility — which columns the viewport touches

    /// Whether column `i` lies entirely within the viewport. Edge-flush counts as visible.
    public func isFullyVisible(_ i: Int, viewportWidth: Double, offset: Double) -> Bool {
        let (left, width) = span(of: i)
        return left >= offset && left + width <= offset + viewportWidth
    }

    /// How much of a column must be inside the viewport to count as on screen — the sub-pixel
    /// tolerance `Engine` diffs placements at. `leftEdge` and `maxOffset` sum the widths differently,
    /// so a viewport-wide column can leave its neighbour ~1e-13 pt over the edge, and tiling a window
    /// that far off-screen gets it clamped back into view by macOS.
    public static let visibilityTolerance: Double = 0.5

    /// Indices of every column overlapping the viewport by more than `visibilityTolerance`. Flush
    /// against the edge — or within the tolerance of it — is excluded, matching `Rect.intersects`.
    public func visibleColumnIndices(viewportWidth: Double, offset: Double) -> [Int] {
        let tol = Self.visibilityTolerance
        let viewMax = offset + viewportWidth
        var result: [Int] = []
        for i in 0..<count {
            let (left, width) = span(of: i)
            guard width > 0 else { continue }
            if left < viewMax - tol && left + width > offset + tol {
                result.append(i)
            }
        }
        return result
    }

    /// `run` plus the column immediately outside each of its ends — its shoulders — clamped to the strip
    /// and still ascending. A run is contiguous and ascending, so this adds at most two indices.
    public func shoulderedColumnIndices(_ run: [Int]) -> [Int] {
        guard let first = run.first, let last = run.last else { return [] }
        var result = run
        if first > 0 { result.insert(first - 1, at: 0) }
        if last < count - 1 { result.append(last + 1) }
        return result
    }
}
