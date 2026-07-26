import Foundation

// A single column of the strip: the vertical stack of windows inside one column's box
// (PRINCIPLES.md §1 — "columns hold one or more windows stacked vertically"; IMPLEMENTATION.md §5,
// `Layout/Column.swift`).
//
// Where `Strip` places columns left→right on an *infinite* x-axis, a `Column` stacks its windows
// top→bottom inside a *bounded* box — the column's on-strip frame, whose x/width come from `Strip`
// and whose y/height are the monitor working area. The bounded axis is the essential difference, and
// it's why a column **distributes** height where the strip never does: two windows sharing a column
// split its height, so the interesting job here is turning per-window height
// *intents* into concrete point heights, then stacking them.
//
// Height model: every window in a column is either **auto** — it shares the leftover height
// equally with the other auto windows — or pinned to a **preset** (a `cycleHeight` selection: a
// proportion of the column height, or a fixed point count). Pinned heights are honored first; the
// autos divide whatever remains. The common cases fall straight out: one auto window fills
// the column; N auto windows split it into equal Nths; pinning one to ½ leaves the rest to share the
// other half.
//
// Pure and total, the same discipline as `Strip`/`Presets` (IMPLEMENTATION.md §1, invariant 3): an
// empty column yields no frames, and an auto share that would go negative (pinned heights overflow
// the box) clamps to zero rather than trapping. Vertical scroll *within* an over-tall column (the
// rarer case, when pinned heights exceed the box) is a later slice — for now such heights simply
// overflow the box's bottom, which is honest and fully determined. Coordinates are top-left
// virtual-strip points (Geometry.swift); `frame.minY` is the column's top edge and windows stack
// downward.

/// One window's height intent within its column — resolved to points at layout time.
public enum WindowHeight: Sendable, Equatable, Codable {
    /// Share the column's leftover height equally with the other auto windows — the only mode a
    /// freshly-opened window uses until the user cycles its height.
    case auto
    /// A pinned height — a `cycleHeight` selection. Resolved against the column height at layout
    /// time (a `.proportion`) or taken verbatim (a `.fixed` point count).
    case preset(PresetSize)
}

/// The vertical layout of one column: its box on the strip plus the per-window height intents,
/// turned into concrete stacked window frames. A pure toolbox over `Geometry`/`Presets` — it holds
/// no state beyond its inputs and encodes no policy (which window is pinned to what is decided
/// upstream, in the reducer/config).
public struct Column: Sendable, Equatable {
    /// The column's box on the strip: x/width from `Strip` (the column's left edge + its resolved
    /// preset width), y/height the monitor working area (already strut-inset). Every window fills
    /// the box's width and the stack runs down its height from `frame.minY`.
    public let frame: Rect
    /// Per-window height intents, top→bottom. Array order *is* the vertical stacking order; index
    /// `i` is the i-th window from the top.
    public let windowHeights: [WindowHeight]
    /// The gap between vertically-adjacent windows. Inter-window only — no gap above the first or
    /// below the last (outer margins are the working-area inset), matching `Strip`'s gap convention.
    public let gap: Double
    /// Per-window height **floors**, top→bottom, 1:1 with `windowHeights` — a window's own answer to
    /// the height the column last offered it (`SizeCorrection`). `nil` (or a short/empty array) means
    /// no floor, which is the ordinary case.
    ///
    /// A floor is a *constraint*, not an intent, which is why it is a parallel array rather than a
    /// third `WindowHeight` case: it says nothing about how the user wants the column divided, only
    /// about what the app will actually accept. Auto windows honor it; a pinned preset is the user's
    /// explicit instruction and is left alone.
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

    /// Each window's resolved point height, top→bottom, 1:1 with `windowHeights`. Pinned presets
    /// resolve against the column height; the space left after all pinned heights and the
    /// inter-window gaps is split equally among the auto windows, **clamped at zero** so an
    /// over-pinned column never yields a negative height. `[]` for an empty column.
    ///
    /// **Floors are water-filled.** An auto window whose `minHeights` floor exceeds its equal share
    /// takes the floor instead and stops sharing; the space it did *not* leave behind is re-divided
    /// among the windows still auto, which can push another one below *its* floor — so the pass
    /// repeats to a fixpoint. It terminates in at most `count` passes because the floored set only
    /// ever grows. Floors that cannot all fit simply overflow the box's bottom, exactly as pinned
    /// presets already do: honest and fully determined, and the vertical scroll-within-column that
    /// would answer it properly is the same later slice.
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

        // Water-fill: share what's left equally, promote anyone under their floor to it, repeat.
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
    /// Deliberately not named `floor` — that shadows Foundation's, inside a file full of arithmetic.
    private func heightFloor(at i: Int) -> Double? {
        minHeights.indices.contains(i) ? minHeights[i] : nil
    }

    // MARK: Placement

    /// Every window's frame, top→bottom: each spans the column's full width at the column's x, with
    /// its resolved height, stacked from `frame.minY` down with `gap` between them. Lines up 1:1
    /// with `windowHeights`; `[]` for an empty column.
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

    /// Window `i`'s frame, or `nil` if `i` is out of range — total, so a stale index (a window
    /// removed mid-reconcile) is a normal `nil`, not a trap.
    public func frame(of i: Int) -> Rect? {
        let frames = windowFrames()
        return frames.indices.contains(i) ? frames[i] : nil
    }

    /// The total stacked height: `Σ resolved heights + (count − 1)·gap`. Equals `frame.height` when
    /// at least one window is auto and unfloored (the autos absorb the slack exactly); may *exceed* it
    /// when pinned heights or height floors overflow the box — the over-tall case whose vertical
    /// scroll-within-column is a later slice. `0` for an empty column.
    public var contentHeight: Double {
        guard count > 0 else { return 0 }
        return resolvedHeights().reduce(0, +) + Double(count - 1) * gap
    }
}
