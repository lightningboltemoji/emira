import Foundation

// The quit cascade — the one layout that is not the strip, used at teardown to rescue every parked
// window before the daemon exits (parking is only survivable while emira is running). Windows stack in
// the middle three-quarters of the screen, staggered down and right, resized so every bottom-right
// corner lands on the same point. Window *i+1* is therefore strictly inside window *i*, which makes
// z-order load-bearing: an earlier, larger window drawn above a later one hides it completely.

/// The quit cascade's geometry: a staggered, bottom-right-aligned stack in the centre of an area.
/// Pure arithmetic over `Rect`; `State.cascadeEffects()` is the half that knows about windows.
public enum Cascade {

    /// How much of the working area the stack occupies, on both axes, centred.
    public static let fraction: Double = 0.75

    /// How far each window is offset down and right of the one before it, in points — a title bar's
    /// worth, so the exposed band of every buried window is grabbable.
    public static let stagger: Double = 30

    /// The floor the smallest (last, innermost) window is kept at. With bottom-right corners pinned,
    /// window *i* is `i × stagger` smaller than the first on both axes, so rather than let a deep stack
    /// go negative the step shrinks uniformly until the whole stack fits with this much left over.
    public static let minimumSize = Size(width: 480, height: 320)

    /// The centred sub-rect the stack lives in — `area` scaled by `fraction` about its own centre.
    public static func region(in area: Rect, fraction: Double = fraction) -> Rect {
        area.insetBy(dx: area.width * (1 - fraction) / 2,
                     dy: area.height * (1 - fraction) / 2)
    }

    /// `count` frames, staggered down-right from the region's top-left, every one of them ending at the
    /// region's bottom-right corner. Total for every input: zero windows is no frames, one window is
    /// the region itself, and a stack too deep for `stagger` compresses rather than collapsing.
    public static func frames(count: Int, in area: Rect,
                              stagger: Double = stagger,
                              fraction: Double = fraction,
                              minimum: Size = minimumSize) -> [Rect] {
        guard count > 0 else { return [] }
        let region = Cascade.region(in: area, fraction: fraction)
        guard count > 1 else { return [region] }

        // The travel available to the last window on the tighter axis — whichever of width and height
        // runs out first decides the step for both.
        let room = min(max(0, region.width - minimum.width),
                       max(0, region.height - minimum.height))
        let step = min(stagger, room / Double(count - 1))

        return (0..<count).map { index in
            let offset = Double(index) * step
            return Rect(x: region.minX + offset, y: region.minY + offset,
                        width: region.width - offset, height: region.height - offset)
        }
    }
}

extension State {

    /// The effects that pile every managed window into the quit cascade — ordinary truth-plane effects
    /// only, no cover: a quit is not a transition and nothing is left running to animate it. Covers
    /// every window on every workspace's strip including the parked ones (rescuing those is the point),
    /// but never floats, dialogs, panels or sheets — emira never placed them. The focused window goes
    /// last, since later means smaller means on top. Cross-app z-order is best-effort: `raise` is
    /// `AXRaise`, which only orders a window within its own app.
    public func cascadeEffects() -> [Effect] {
        guard let metrics = metrics() else { return [] }
        let ordered = cascadeOrder()
        guard let top = ordered.last else { return [] }

        let frames = Cascade.frames(count: ordered.count, in: metrics.workingArea)
        var effects: [Effect] = zip(ordered, frames).map { .setFrame($0, $1) }
        // Raises after the placements: they commute, and grouping them keeps the build order legible.
        effects += ordered.map { Effect.raise($0) }
        effects.append(.focus(top))
        return effects
    }

    /// Every strip window, back-to-front: placement order with the focused window moved to the end.
    private func cascadeOrder() -> [WindowId] {
        let ids = workspaces.windowIds(inPlacementOrder: monitors.shownWorkspaces)
        guard let focused = world.focusedWindow, ids.contains(focused) else { return ids }
        return ids.filter { $0 != focused } + [focused]
    }
}
