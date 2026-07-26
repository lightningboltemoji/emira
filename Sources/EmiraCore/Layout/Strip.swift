import Foundation

// The infinite horizontal strip — the geometric heart of the layout model (PRINCIPLES.md §1, §3).
//
// Columns are laid out left→right on an unbounded x-axis, each at a resolved point width, separated
// by a fixed inter-column `gap`. A *viewport* — a window of width `viewportWidth`, the working area
// of the monitor — slides along that axis; its left edge is the `scrollOffset`. "Scrolling the
// strip" is moving that one scalar (PRINCIPLES.md §7: "a strip scroll animates one scalar — the
// viewport offset"); a column's on-screen position is derived from it, never stored.
//
// This type is a **pure toolbox over one run of column widths**: it answers *where* each column
// sits, *how wide* the whole run is, and *what scroll offset* reveals or centers a given column. It
// holds no state beyond its inputs and encodes **no policy** — whether a focus change should center
// or minimally reveal a column is the reducer's call (driven by config, `centerFocusedColumn`), so
// both primitives (`offsetToReveal`, `offsetToCenter`) are offered and neither is privileged.
//
// Coordinates are virtual-strip points, top-left origin (Geometry.swift). `x` is unbounded and
// routinely negative once the viewport scrolls right of the origin; nothing here assumes a finite
// axis. Widths are assumed positive (a real column always has width); zero/negative widths degrade
// gracefully but aren't a supported input.
public struct Strip: Sendable, Equatable {
    /// Resolved column widths in points, left→right. Index `i` is the i-th column on the strip.
    public let columnWidths: [Double]
    /// The gap between adjacent columns, in points. Applied *between* columns only — there is no
    /// gap before the first or after the last (outer margins are the monitor's working-area inset,
    /// handled upstream of the strip).
    public let gap: Double
    /// The x of the first column's left edge. Usually 0 (the strip has its own origin); a nonzero
    /// value shifts the entire run, e.g. to align the strip's start with a working-area inset.
    public let origin: Double

    public init(columnWidths: [Double], gap: Double, origin: Double = 0) {
        self.columnWidths = columnWidths
        self.gap = gap
        self.origin = origin
    }

    public var count: Int { columnWidths.count }
    public var isEmpty: Bool { columnWidths.isEmpty }

    // MARK: Placement

    /// The x of column `i`'s left edge: `origin + Σ widths[0..<i] + i·gap`.
    ///
    /// Defined for `i` in `0...count` — `leftEdge(of: count)` is the position a newly appended
    /// column would take (its left edge, one gap past the last column's right edge), which the
    /// insert path wants. Indices outside `0...count` are clamped into that range so the function
    /// is total.
    public func leftEdge(of i: Int) -> Double {
        let clamped = min(max(i, 0), count)
        var x = origin
        for k in 0..<clamped {
            x += columnWidths[k] + gap
        }
        return x
    }

    /// The `[x, width]` span of column `i` on the strip. Precondition-free for valid indices; an
    /// out-of-range index yields a zero-width span at the clamped edge.
    public func span(of i: Int) -> (x: Double, width: Double) {
        guard i >= 0, i < count else { return (leftEdge(of: i), 0) }
        return (leftEdge(of: i), columnWidths[i])
    }

    /// Total width of the laid-out run: `Σ widths + (count − 1)·gap`, or `0` when empty. This is the
    /// span from the first column's left edge to the last column's right edge (no outer gaps).
    public var contentWidth: Double {
        guard count > 0 else { return 0 }
        return columnWidths.reduce(0, +) + Double(count - 1) * gap
    }

    // MARK: Scroll math — offset that frames a column

    /// The largest scroll offset that still shows strip content across the whole viewport: the last
    /// column's right edge flush with the viewport's right edge. Zero when the strip fits entirely
    /// on screen, so `[origin, maxOffset]` is a valid — possibly degenerate — range either way.
    public func maxOffset(viewportWidth: Double) -> Double {
        Swift.max(origin, origin + contentWidth - viewportWidth)
    }

    /// `offset` brought inside `[origin, maxOffset]` — the offsets from which the viewport is not
    /// looking past either end of the strip.
    public func clampOffset(_ offset: Double, viewportWidth: Double) -> Double {
        Swift.min(Swift.max(offset, origin), maxOffset(viewportWidth: viewportWidth))
    }

    /// The scroll offset that places column `i`'s left edge flush with the viewport's left edge.
    public func offsetToAlignLeft(_ i: Int) -> Double {
        leftEdge(of: i)
    }

    /// The scroll offset that centers column `i` within a viewport of `viewportWidth`. A column
    /// wider than the viewport still centers (its overflow spills equally off both edges).
    public func offsetToCenter(_ i: Int, viewportWidth: Double) -> Double {
        let (x, w) = span(of: i)
        return x + w / 2 - viewportWidth / 2
    }

    /// The **minimal** scroll change that makes column `i` fully visible in a viewport of
    /// `viewportWidth` currently at `offset`: unchanged if the column already fits inside the
    /// viewport; otherwise scrolled just far enough to bring the hidden edge in — keep the focused
    /// column on screen with as little motion as possible.
    ///
    /// If the column is *wider* than the viewport it cannot fit; we then align its left edge, so the
    /// user sees the start of the column.
    /// **The answer is clamped to the strip's extent** (2026-07-26), including in the "already fully
    /// visible, don't move" case — because *that* case is the one that strands. `offset` is an input
    /// this function is otherwise happy to hand straight back, so a viewport left pointing past the
    /// end of the strip (columns closed out from under it) stays there for as long as the focused
    /// column happens to remain visible, showing a lone window beside empty desktop. Clamping the
    /// result rather than trusting the input makes the range an invariant of the answer.
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

    /// Whether column `i` lies entirely within the viewport `[offset, offset + viewportWidth]`.
    /// Edge-flush counts as visible (inclusive), the complement of `offsetToReveal` returning
    /// `offset` unchanged.
    public func isFullyVisible(_ i: Int, viewportWidth: Double, offset: Double) -> Bool {
        let (left, width) = span(of: i)
        return left >= offset && left + width <= offset + viewportWidth
    }

    /// The indices of every column whose span overlaps the viewport `[offset, offset + viewportWidth)`
    /// with positive width — the set the shell must capture and wait on during a transition
    /// (IMPLEMENTATION.md §3, the scoped `axLanded` / capture set). Overlap is strict (a column
    /// merely flush against the viewport edge contributes no visible pixels and is excluded),
    /// matching `Rect.intersects`.
    public func visibleColumnIndices(viewportWidth: Double, offset: Double) -> [Int] {
        let viewMax = offset + viewportWidth
        var result: [Int] = []
        for i in 0..<count {
            let (left, width) = span(of: i)
            guard width > 0 else { continue }
            if left < viewMax && left + width > offset {
                result.append(i)
            }
        }
        return result
    }

    /// `run` plus the column immediately outside each of its ends — its **shoulders** — clamped to the
    /// strip and still ascending. Empty in, empty out.
    ///
    /// A run of columns overlapping an interval is contiguous (columns are ordered, non-overlapping and
    /// positively wide), and `visibleColumnIndices` emits it ascending, so the ends are `first` and
    /// `last` and this adds at most two indices.
    public func shoulderedColumnIndices(_ run: [Int]) -> [Int] {
        guard let first = run.first, let last = run.last else { return [] }
        var result = run
        if first > 0 { result.insert(first - 1, at: 0) }
        if last < count - 1 { result.append(last + 1) }
        return result
    }
}
