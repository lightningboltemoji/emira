import Foundation

// Cyclable size presets — the width a column cycles through (`cycleWidth`) and the height a window
// cycles through inside its column (`cycleHeight`).
//
// Two orthogonal pieces live here, both pure and both resolved against the *available* extent only
// at layout time (never stored as points):
//
//  · `PresetSize` — one entry: a *proportion* of the working area, or a *fixed* point count. A
//    column width of "½" must track the monitor it lands on, so the core stores the proportion and
//    resolves it against that monitor's working width when it computes frames. Fixed sizes are for
//    the "exactly 800 pt" case.
//  · `PresetCycle` — the ordered list a `cycleWidth`/`cycleHeight` command steps through. The
//    *selection* is an index the column stores (see the `Column` state, a later slice), not a
//    resolved value — so cycling is pure index arithmetic and stays stable regardless of which
//    monitor's pixels the proportion currently resolves to. It's what keeps "cycle width" a single
//    `+1 mod count` rather than a fuzzy nearest-pixel match.
//
// Everything here is **total**: a stored index that has drifted out of range (e.g. config was
// reloaded with fewer presets) is normalized modulo the count rather than trapping, and a
// degenerate empty cycle answers with a full-extent fallback instead of crashing. Totality is the
// same discipline the reducer relies on (IMPLEMENTATION.md §1, invariant 3).

/// One preset entry: a fraction of the available working extent, or an absolute point count.
/// Resolved to points only at layout time, against the monitor the column currently occupies.
public enum PresetSize: Sendable, Equatable, Codable {
    /// A fraction of the available working extent. `0.5` is half the working width (or height).
    /// Not clamped here — a config that wants `1.0` (full) or an intentional overshoot is honored;
    /// the caller owns clamping to a sane range if it wants one.
    case proportion(Double)
    /// An absolute size in points, independent of the working extent.
    case fixed(Double)

    /// Resolve to points against the working extent (a width for a column, a height for a window).
    public func resolved(available: Double) -> Double {
        switch self {
        case .proportion(let fraction): return available * fraction
        case .fixed(let points): return points
        }
    }
}

/// An ordered, wrap-around list of `PresetSize`s that a cycle command steps through. The current
/// selection is an *index* the caller stores; this type only owns the list and the arithmetic of
/// moving through it.
public struct PresetCycle: Sendable, Equatable, Codable {
    /// The presets in cycle order, left→right / small→large by convention (not enforced).
    public let presets: [PresetSize]

    public init(_ presets: [PresetSize]) {
        self.presets = presets
    }

    public var count: Int { presets.count }
    public var isEmpty: Bool { presets.isEmpty }

    /// Defaults: a column cycles ⅓ → ½ → ⅔ of the working width.
    public static let defaultWidths = PresetCycle([
        .proportion(1.0 / 3.0), .proportion(1.0 / 2.0), .proportion(2.0 / 3.0),
    ])

    /// Default window-height cycle inside a column — the same ⅓ / ½ / ⅔ ladder.
    public static let defaultHeights = PresetCycle([
        .proportion(1.0 / 3.0), .proportion(1.0 / 2.0), .proportion(2.0 / 3.0),
    ])

    /// The preset at `index`, with the index normalized into range (wrapping, so a drifted or
    /// negative index is still valid). An empty cycle falls back to the full extent so callers
    /// never need a nil branch.
    public func size(at index: Int) -> PresetSize {
        guard let i = normalized(index) else { return .proportion(1.0) }
        return presets[i]
    }

    /// Convenience: resolve the preset at `index` straight to points.
    public func resolved(at index: Int, available: Double) -> Double {
        size(at: index).resolved(available: available)
    }

    /// The next selection when the user cycles *forward*, wrapping past the end back to the start.
    /// Total for any input index (out-of-range or negative is normalized first).
    public func nextIndex(after index: Int) -> Int {
        guard let i = normalized(index) else { return 0 }
        return (i + 1) % count
    }

    /// The previous selection (cycling *backward*), wrapping past the start to the end.
    public func previousIndex(before index: Int) -> Int {
        guard let i = normalized(index) else { return 0 }
        return (i - 1 + count) % count
    }

    /// Map an arbitrary integer into `0..<count` (wrapping), or `nil` for an empty cycle. This is
    /// what makes every accessor total against a drifted stored index.
    private func normalized(_ index: Int) -> Int? {
        guard count > 0 else { return nil }
        return ((index % count) + count) % count
    }
}
