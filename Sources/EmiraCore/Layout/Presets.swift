import Foundation

// Cyclable size presets: the widths a column cycles through and the heights a window cycles through
// inside it. A preset is a proportion or a fixed point count, resolved against an `Extent` only at
// layout time, so "½" tracks whichever monitor the column lands on. The selection is an index the
// caller stores, so cycling is `+1 mod count`. Every accessor is total against a drifted index.

/// The space a run of tiles fills and the gap between two adjacent ones — what a `PresetSize` resolves
/// against. **`n` tiles have `n − 1` gaps between them, so a tile is a share of the span widened by one
/// gap and pays one gap back**, which is what makes proportions summing to 1 fill `span` exactly.
public struct Extent: Sendable, Equatable {
    /// The extent a proportion is a share of: the content area's width, or the column box's height.
    public let span: Double
    /// The gap between two adjacent tiles laid out in it — inter-tile only, as `Strip` and `Column` mean it.
    public let gap: Double

    public init(span: Double, gap: Double) {
        self.span = span
        self.gap = gap
    }

    /// `size` in points. A `.fixed` is taken verbatim; a `.proportion` gets the share above.
    public func resolve(_ size: PresetSize) -> Double {
        switch size {
        case .proportion(let fraction): return (span + gap) * fraction - gap
        case .fixed(let points): return points
        }
    }

    /// The proportion `resolve` would turn back into `points` — the inverse, for the callers that record
    /// a resolved size as an intent. Stated beside the formula it inverts so the two cannot drift.
    public func proportion(of points: Double) -> PresetSize {
        .proportion((points + gap) / (span + gap))
    }
}

/// One preset entry: a fraction of the available working extent, or an absolute point count.
public enum PresetSize: Sendable, Equatable, Codable {
    /// A fraction of the available working extent. Not clamped here — the caller owns any clamping.
    case proportion(Double)
    /// An absolute size in points, independent of the working extent.
    case fixed(Double)
}

/// An ordered, wrap-around list of `PresetSize`s that a cycle command steps through.
public struct PresetCycle: Sendable, Equatable, Codable {
    /// The presets in cycle order, small→large by convention (not enforced).
    public let presets: [PresetSize]

    public init(_ presets: [PresetSize]) {
        self.presets = presets
    }

    public var count: Int { presets.count }
    public var isEmpty: Bool { presets.isEmpty }

    /// Default column-width cycle: ⅓ → ½ → ⅔ of the working width.
    public static let defaultWidths = PresetCycle([
        .proportion(1.0 / 3.0), .proportion(1.0 / 2.0), .proportion(2.0 / 3.0),
    ])

    /// Default window-height cycle inside a column — the same ⅓ / ½ / ⅔ ladder.
    public static let defaultHeights = PresetCycle([
        .proportion(1.0 / 3.0), .proportion(1.0 / 2.0), .proportion(2.0 / 3.0),
    ])

    /// The preset at `index`, normalized into range by wrapping. An empty cycle falls back to the full
    /// extent, so callers never need a nil branch.
    public func size(at index: Int) -> PresetSize {
        guard let i = normalized(index) else { return .proportion(1.0) }
        return presets[i]
    }

    /// Convenience: resolve the preset at `index` straight to points.
    public func resolved(at index: Int, in extent: Extent) -> Double {
        extent.resolve(size(at: index))
    }

    /// The next selection when cycling forward, wrapping past the end back to the start.
    public func nextIndex(after index: Int) -> Int {
        guard let i = normalized(index) else { return 0 }
        return (i + 1) % count
    }

    /// The previous selection, wrapping past the start back to the end.
    public func previousIndex(before index: Int) -> Int {
        guard let i = normalized(index) else { return 0 }
        return (i - 1 + count) % count
    }

    /// Map an arbitrary integer into `0..<count` (wrapping), or `nil` for an empty cycle.
    private func normalized(_ index: Int) -> Int? {
        guard count > 0 else { return nil }
        return ((index % count) + count) % count
    }
}
