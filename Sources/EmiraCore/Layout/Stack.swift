import Foundation

// The cascade: `n` equal tiles staggered down and right from the top-left of a region, `Strip`'s
// counterpart and the geometry `Layout.Kind.stack` resolves through. Pure math, no policy.
//
// **Every tile is the same size, and that size is a function of `n`** — the region shrunk by the whole
// spread on both axes — so an arrival or a departure resizes every window on the workspace. Nothing
// else resizes one: there is no width stack here, no preset ladder and no detent.
//
// Screen points, top-left origin (Geometry.swift). Nothing here reads a z-order, and nothing here
// asserts one: which band of a buried tile you can actually see is macOS's answer, not this one.
public enum Stack {

    /// How far each tile sits down and right of the one before it, in points — enough of the one behind
    /// it to grab, on both edges.
    public static let stagger: Double = 30

    /// The size below which the stagger compresses instead of the tile shrinking further. The soft
    /// bound: it is what a deep cascade trades away first, exactly as `Cascade.frames` does.
    public static let minimumSize = Size(width: 480, height: 320)

    /// …and the hard one, which compression stops at. `WindowRegistry` binds AX windows to window-list
    /// entries by ±2 pt uniqueness, and every tile here is the same size, so two tiles closer than that
    /// are two windows nothing can tell apart — and a wrong answer there is permanent and invisible.
    /// `ParkingLot.stagger` carries the identical constraint and the identical number.
    public static let minimumStagger: Double = 8

    /// The stagger `count` tiles are actually laid out at: `stagger`, compressed to whatever the region
    /// can give once a tile would go under `minimum`, and never below `minimumStagger`.
    public static func step(count: Int, in region: Rect,
                            stagger: Double = stagger,
                            minimum: Size = minimumSize) -> Double {
        guard count > 1 else { return stagger }
        // The travel available to the last tile on the tighter axis — whichever of width and height
        // runs out first decides the step for both, so the cascade stays square-cornered.
        let room = min(max(0, region.width - minimum.width),
                       max(0, region.height - minimum.height))
        return max(min(stagger, room / Double(count - 1)), minimumStagger)
    }

    /// The size every tile takes at that stagger: the region less the whole spread. Floored at
    /// `minimumStagger`, which is only reachable by a stack deep enough to exhaust the region at the
    /// identity floor — past navigating long before it is past drawing.
    public static func size(count: Int, in region: Rect,
                            stagger: Double = stagger,
                            minimum: Size = minimumSize) -> Size {
        guard count > 1 else { return region.size }
        let spread = Double(count - 1) * step(count: count, in: region, stagger: stagger,
                                              minimum: minimum)
        return Size(width: max(region.width - spread, minimumStagger),
                    height: max(region.height - spread, minimumStagger))
    }

    /// `count` frames, staggered down-right from the region's top-left, all of one size. Slot 0 is
    /// furthest back and up-left. Total for every input: zero tiles is no frames, one tile is the
    /// region itself, and a stack too deep for `stagger` compresses rather than collapsing.
    public static func frames(count: Int, in region: Rect,
                              stagger: Double = stagger,
                              minimum: Size = minimumSize) -> [Rect] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [region] }
        let step = step(count: count, in: region, stagger: stagger, minimum: minimum)
        let size = size(count: count, in: region, stagger: stagger, minimum: minimum)
        return (0..<count).map { index in
            let offset = Double(index) * step
            return Rect(x: region.minX + offset, y: region.minY + offset,
                        width: size.width, height: size.height)
        }
    }
}
