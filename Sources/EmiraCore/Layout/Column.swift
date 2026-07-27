import Foundation

// A single column of the strip: the vertical stack of windows inside one bounded box. Unlike `Strip`,
// a column *distributes* height — each window is either auto, sharing the leftover height equally with
// the other autos, or pinned to a preset (a proportion of the column height, or a fixed point count).
// Pinned heights are honored first; those that exceed the box overflow its bottom. Coordinates are
// top-left points (Geometry.swift): `frame.minY` is the top edge and windows stack downward.

/// One window's height intent within its column — resolved to points at layout time.
public enum WindowHeight: Sendable, Equatable, Codable {
    /// Share the column's leftover height equally with the other auto windows. The default.
    case auto
    /// A pinned height, resolved against the column height (`.proportion`) or taken verbatim (`.fixed`).
    case preset(PresetSize)
}

/// The vertical layout of one column: its box on the strip plus per-window height intents, turned into
/// stacked window frames. No policy — which window is pinned to what is decided upstream.
public struct Column: Sendable, Equatable {
    /// The column's box on the strip: x/width from `Strip`, y/height the monitor working area.
    public let frame: Rect
    /// Per-window height intents, top→bottom. Array order *is* the vertical stacking order.
    public let windowHeights: [WindowHeight]
    /// The gap between vertically-adjacent windows. Inter-window only, matching `Strip`'s convention.
    public let gap: Double
    /// Per-window height floors, top→bottom, 1:1 with `windowHeights` — a window's own answer to the
    /// height the column last offered it (`SizeCorrection`). `nil` or a short array means no floor.
    ///
    /// A separate array rather than a `WindowHeight` case because a floor is a constraint, not an
    /// intent: autos honor it, but a pinned preset is the user's instruction and is left alone.
    public let minHeights: [Double?]

    public init(frame: Rect, windowHeights: [WindowHeight], gap: Double, minHeights: [Double?] = []) {
        self.frame = frame
        self.windowHeights = windowHeights
        self.gap = gap
        self.minHeights = minHeights
    }

    public var count: Int { windowHeights.count }
    public var isEmpty: Bool { windowHeights.isEmpty }

    // MARK: Height distribution

    /// Each window's resolved point height, top→bottom, 1:1 with `windowHeights`. Presets resolve
    /// against the column height; what remains after them and the gaps splits equally among the autos,
    /// clamped at zero. Floors are water-filled: an auto whose floor exceeds its share takes the floor
    /// and stops sharing, re-dividing the rest — a fixpoint reached in at most `count` passes, since
    /// the floored set only grows.
    public func resolvedHeights() -> [Double] {
        guard count > 0 else { return [] }
        let totalGap = Double(count - 1) * gap
        var heights = [Double](repeating: 0, count: count)
        var isAuto = [Bool](repeating: false, count: count)
        var fixedSum = 0.0

        for (i, h) in windowHeights.enumerated() {
            switch h {
            case .auto:
                isAuto[i] = true
            case .preset(let size):
                heights[i] = size.resolved(available: frame.height)
                fixedSum += heights[i]
            }
        }

        // Share what's left equally, promote anyone under their floor to it, repeat.
        while true {
            let autoCount = isAuto.filter { $0 }.count
            let share = autoCount > 0 ? max((frame.height - totalGap - fixedSum) / Double(autoCount), 0) : 0
            guard let floored = isAuto.indices.first(where: { i in
                isAuto[i] && (heightFloor(at: i).map { $0 > share } ?? false)
            }) else {
                for i in isAuto.indices where isAuto[i] { heights[i] = share }
                return heights
            }
            heights[floored] = heightFloor(at: floored) ?? share
            fixedSum += heights[floored]
            isAuto[floored] = false
        }
    }

    /// Window `i`'s height floor, if it has one. Total against a short or absent `minHeights`.
    private func heightFloor(at i: Int) -> Double? {
        minHeights.indices.contains(i) ? minHeights[i] : nil
    }

    // MARK: Placement

    /// Every window's frame, top→bottom: full column width, resolved height, stacked down from
    /// `frame.minY`. 1:1 with `windowHeights`.
    public func windowFrames() -> [Rect] {
        let heights = resolvedHeights()
        var result: [Rect] = []
        result.reserveCapacity(heights.count)
        var y = frame.minY
        for h in heights {
            result.append(Rect(x: frame.minX, y: y, width: frame.width, height: h))
            y += h + gap
        }
        return result
    }

    /// Window `i`'s frame, or `nil` if `i` is out of range — a stale index is a normal `nil`, not a trap.
    public func frame(of i: Int) -> Rect? {
        let frames = windowFrames()
        return frames.indices.contains(i) ? frames[i] : nil
    }

    /// The total stacked height. Equals `frame.height` when at least one window is auto and unfloored;
    /// may exceed it when pinned heights or floors overflow the box.
    public var contentHeight: Double {
        guard count > 0 else { return 0 }
        return resolvedHeights().reduce(0, +) + Double(count - 1) * gap
    }
}
