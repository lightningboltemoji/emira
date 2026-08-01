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

/// What one window answered about its height, in the direction it refused (`SizeCorrection.heightBound`).
/// The two cases are mutually exclusive by construction — an answer is either taller or shorter than the
/// question, never both — and the direction is exactly what a bare number would lose: offered 400, a
/// window that answered 200 must be held at 200 while one that answered 500 must be given 500.
public enum HeightBound: Sendable, Equatable, Codable {
    /// The window would not shrink to the height it was offered; it needs at least this much. Honoring
    /// it is what stops a stack overlapping — the refused surplus has to come off someone else.
    case atLeast(Double)
    /// The window would not grow to the height it was offered; it will not use more than this. Honoring
    /// it is what hands the surplus *back*, instead of leaving a hole under a window in its own slot.
    case atMost(Double)

    /// The height to pin this window at instead of `share`, or `nil` if `share` is one it might accept —
    /// a floor below the share (it takes more happily) or a ceiling above it (it takes less).
    func ruling(outOf share: Double) -> Double? {
        switch self {
        case .atLeast(let floor):  return floor > share ? floor : nil
        case .atMost(let ceiling): return ceiling < share ? ceiling : nil
        }
    }
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
    /// Per-window height bounds, top→bottom, 1:1 with `windowHeights` — a window's own answer to the
    /// height the column last offered it (`SizeCorrection`). `nil` or a short array means unbounded.
    ///
    /// A separate array rather than a `WindowHeight` case because a bound is a constraint, not an
    /// intent: autos honor it, but a pinned preset is the user's instruction and is left alone.
    public let heightBounds: [HeightBound?]

    public init(frame: Rect, windowHeights: [WindowHeight], gap: Double,
                heightBounds: [HeightBound?] = []) {
        self.frame = frame
        self.windowHeights = windowHeights
        self.gap = gap
        self.heightBounds = heightBounds
    }

    public var count: Int { windowHeights.count }
    public var isEmpty: Bool { windowHeights.isEmpty }

    /// Each window's resolved point height, top→bottom, 1:1 with `windowHeights`. Presets resolve
    /// against the column height; what remains after them and the gaps splits equally among the autos,
    /// clamped at zero. Bounds are water-filled **in both directions**: an auto whose bound rules its
    /// share out takes the bound and stops sharing, and the rest re-divide what is left — which a
    /// ceiling *grows* and a floor shrinks. A fixpoint in at most `count` passes either way, since the
    /// bounded set only ever grows and a window is pinned at the value it answered, not at a share.
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

        // Share what's left equally, pin anyone whose answer rules that share out, repeat.
        while true {
            let autoCount = isAuto.filter { $0 }.count
            let share = autoCount > 0 ? max((frame.height - totalGap - fixedSum) / Double(autoCount), 0) : 0
            guard let (index, bound) = isAuto.indices.lazy.compactMap({ i -> (Int, Double)? in
                guard isAuto[i], let pinned = self.heightBound(at: i)?.ruling(outOf: share)
                else { return nil }
                return (i, pinned)
            }).first else {
                for i in isAuto.indices where isAuto[i] { heights[i] = share }
                return heights
            }
            heights[index] = bound
            fixedSum += bound
            isAuto[index] = false
        }
    }

    /// Window `i`'s height bound, if it has one. Total against a short or absent `heightBounds`.
    private func heightBound(at i: Int) -> HeightBound? {
        heightBounds.indices.contains(i) ? heightBounds[i] : nil
    }

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

    /// The total stacked height. Equals `frame.height` when at least one window is auto and unbounded;
    /// may exceed it when pinned heights or floors overflow the box, and falls short of it when every
    /// auto has a ceiling — the column's windows are as tall as they will go and the rest is desktop.
    public var contentHeight: Double {
        guard count > 0 else { return 0 }
        return resolvedHeights().reduce(0, +) + Double(count - 1) * gap
    }
}
