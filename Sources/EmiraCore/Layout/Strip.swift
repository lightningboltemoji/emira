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

    // Scroll math — offset that frames a column

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

    // Visibility — which columns the viewport touches

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

    // Magnets — the rests a driven scroll settles on

    /// The offsets at which a column edge lies flush with a viewport edge — every rest a magnetized
    /// scroll may stop at. For column `i`: `leftEdge(i)` puts its left edge against the viewport's
    /// left, and `leftEdge(i) + width(i) − viewportWidth` puts its right against the viewport's right.
    /// Clamped into `[origin, maxOffset]`, deduplicated, ascending.
    ///
    /// Both edges, not just left: a column wider than the viewport has two legitimate rest points and a
    /// left-only answer makes its right half unreachable. `origin` and `maxOffset` fall out of the set
    /// for free — they *are* the first column's left flush and the last column's right flush.
    ///
    /// `centered` takes the column **centres** instead, unclamped for the reason `offsetToCenter` is
    /// never clamped: at the strip's ends, honouring a centre means showing space past the last column.
    public func magnetOffsets(viewportWidth: Double, centered: Bool) -> [Double] {
        guard count > 0 else { return [] }
        var candidates: [Double] = []
        for i in 0..<count {
            guard !centered else {
                candidates.append(offsetToCenter(i, viewportWidth: viewportWidth))
                continue
            }
            let (x, width) = span(of: i)
            candidates.append(clampOffset(x, viewportWidth: viewportWidth))
            candidates.append(clampOffset(x + width - viewportWidth, viewportWidth: viewportWidth))
        }
        // Deduplicated at the tolerance a placement is diffed at — a strip shorter than the viewport
        // clamps every candidate onto `origin`, and two rests half a point apart are one rest.
        return candidates.sorted().reduce(into: []) { kept, candidate in
            guard let last = kept.last else { return kept.append(candidate) }
            if candidate - last > Self.visibilityTolerance { kept.append(candidate) }
        }
    }

    /// The nearest of those to `offset`; an exact tie takes the higher one — `Monitors`' forward-wins
    /// rule for a `WorkspaceName` distance, so the two places in emira that break a tie between
    /// neighbours break it the same way. An empty strip has no edge to catch on and nowhere to be but
    /// its origin.
    public func magnetOffset(nearest offset: Double, viewportWidth: Double, centered: Bool) -> Double {
        let candidates = magnetOffsets(viewportWidth: viewportWidth, centered: centered)
        guard var best = candidates.first else {
            return clampOffset(offset, viewportWidth: viewportWidth)
        }
        // Ascending, and `<=` keeps the later one, which is the forward-wins tie-break.
        for candidate in candidates.dropFirst()
        where abs(candidate - offset) <= abs(best - offset) { best = candidate }
        return best
    }

    // Detents — the edge a resize catches on

    /// How far column `i`'s width may travel before a viewport edge crosses a column edge, or `nil` where
    /// neither bound crosses one — a bound already flush with an edge included, the notch a second press
    /// passes through. Only the columns at or after `i` move with its width, and the viewport moves with
    /// them once the reveal has nowhere else to put the focused column.
    public func resizeDetent(ofColumn i: Int, growing: Bool, viewportWidth: Double, offset: Double,
                             centered: Bool) -> Double? {
        guard i >= 0, i < count else { return nil }
        let viewMax = offset + viewportWidth
        // The right viewport edge sweeps the right edges of the columns from `i` on — the ones its width
        // moves — and the left edge the left edges of those up to `i`, which it doesn't. Each bound over
        // one kind of edge only: the far edge landing on a column's near one is that column gone
        // entirely, a legitimate arrangement but not one to stop a press at.
        let rights = (i..<count).map { leftEdge(of: $0) + columnWidths[$0] }
        let lefts = (0...i).map { leftEdge(of: $0) }
        // Growing carries the right edge inward, over the last column shown whole, and the left edge
        // outward, over the first one it evicts; shrinking reverses both.
        let right = Self.crossing(rights, from: viewMax, ascending: !growing)
        let left = Self.crossing(lefts, from: offset, ascending: growing)

        // Centred, the viewport travels half the width with the column, so both edges sweep from the
        // first point of the delta at half speed — the nearer notch, twice as far off.
        guard !centered else { return [right, left].compactMap { $0 }.min().map { 2 * $0 } }

        // Uncentred the two sweep in sequence, not together, because a reveal is the minimal scroll: the
        // viewport is still — only the right edge closing — until the column's own right edge reaches it
        // growing, or the shrinking strip's end is pulled off it, which is `drag` away. Past that the
        // strip travels with the column, freezing every edge from `i` on against the viewport's right,
        // and the left edge is the only one still crossing anything.
        let drag = growing ? viewMax - (leftEdge(of: i) + columnWidths[i])
                           : maxOffset(viewportWidth: viewportWidth) - offset
        return [right, left.map { drag + $0 }]
            .compactMap { $0 }
            .filter { $0 > Self.visibilityTolerance }   // an edge a stale offset is already past
            .min()
    }

    /// How far a bound at `at` travels before it crosses one of `edges` — ascending or descending — and
    /// `nil` where it meets none. `edges` is ascending.
    ///
    /// An edge the bound already sits on, within the tolerance a placement is diffed at, is not one it is
    /// about to cross: a detent is reached by arithmetic that has to land on it exactly to be left again,
    /// and that notch is what a second press passes through. Taken per bound — being flush at one says
    /// nothing about what the other is about to reach.
    private static func crossing(_ edges: [Double], from at: Double, ascending: Bool) -> Double? {
        let edge = ascending ? edges.first(where: { $0 > at + visibilityTolerance })
                             : edges.last(where: { $0 < at - visibilityTolerance })
        return edge.map { abs($0 - at) }
    }
}
