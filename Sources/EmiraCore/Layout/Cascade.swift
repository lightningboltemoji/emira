import Foundation

// The **quit cascade** (2026-07-26) — the one layout in emira that is not the strip.
//
// Stopping the daemon used to leave the desktop exactly as the strip had arranged it, which means
// every off-viewport column and every window on the other 35 workspaces sitting at its 1 pt corner
// nub (`PRINCIPLES.md` §4a). That is a coherent state and an awful one to be handed: emira's whole
// off-screen model is only survivable *while emira is running*, and the moment it isn't, a user is
// looking at a desktop with most of their windows hidden a pixel off the edge and no way to get them
// back but dragging each nub in by hand. `emira-daemon`'s teardown said so in a comment for a
// milestone; this is the geometry that answers it.
//
// **The shape: a solitaire cascade.** Every managed window is stacked in the middle three-quarters
// of the screen, each one staggered 30 pt down and 30 pt right of the one before, and **resized so
// that every window's bottom-right corner lands on the same point**. So the stack reads as a fan of
// title bars marching down-right, exactly the Windows-3.1/Solitaire cascade — every window has a
// grabbable corner, nothing is off-screen, and the desktop is legible again with no window manager
// running.
//
// Three properties, and each is a decision rather than an accident:
//
//  · **Aligned bottom-rights, so window *i+1* is strictly inside window *i*.** That is what makes the
//    stagger legible — every earlier window shows an even 30 pt band along its top and left edge,
//    and no window is half-covered at an arbitrary offset. It also means **z-order matters**: an
//    earlier (larger) window drawn above a later one hides it completely, which is why
//    `State.cascadeEffects()` raises in cascade order and puts the focused window last.
//  · **The centre three-quarters, not the whole working area.** A cascade that filled the screen
//    would put the first window's edges exactly where the strip's already are, so quitting would look
//    like nothing happened until you noticed the stagger. Insetting says *this is a pile, not a
//    layout*, and it leaves a margin of desktop that reads as "these windows are parked".
//  · **No min/max negotiation.** Apps clamp — a terminal to character cells, an app with a minimum
//    size to that minimum — and the answer here is to not care. `AXWindow.place(at:)` writes the
//    size and then the **position**, so a window that refuses to shrink keeps the top-left corner
//    this file gave it and overhangs the bottom-right. That is the right way to be wrong: the
//    corner is the thing the cascade is made of, and an overhang costs one window's tidy edge
//    rather than the whole stack's rhythm.

/// The quit cascade's geometry: a staggered, bottom-right-aligned stack in the centre of an area.
///
/// Pure arithmetic over `Rect` and nothing else — no windows, no ids, no state — so it is exhaustively
/// testable and reads as what it is. `State.cascadeEffects()` is the half that knows about windows.
public enum Cascade {

    /// How much of the working area the stack occupies, on both axes. Three-quarters, centred.
    public static let fraction: Double = 0.75

    /// How far each window is offset down and right of the one before it, in points.
    ///
    /// 30 pt is a title bar's worth: enough that the exposed band of every buried window is
    /// unmistakably grabbable, small enough that a dozen windows still fit inside the region without
    /// the compression below ever engaging.
    public static let stagger: Double = 30

    /// The floor the *smallest* (last, innermost) window is kept at.
    ///
    /// The stagger cannot be honoured unconditionally: with the bottom-right corners pinned, window
    /// *i* is `i × stagger` smaller than the first on both axes, so a long enough stack would drive
    /// the last windows to zero and then negative. Rather than clip the list, wrap it, or let a
    /// window collapse, the **step shrinks** so the whole stack still fits with this much left over
    /// (`frames(count:in:)`). Compression is uniform, so the cascade stays even; it simply gets
    /// tighter as the pile gets deeper, which is what a pile does.
    ///
    /// Sized so the last window is still a window you can read and aim at, not a sliver — and loose
    /// enough that an ordinary desktop never reaches it (on an 1800×1130 working area the 30 pt step
    /// survives 18 windows).
    public static let minimumSize = Size(width: 480, height: 320)

    /// The centred sub-rect the stack lives in — `area` scaled by `fraction` about its own centre.
    public static func region(in area: Rect, fraction: Double = fraction) -> Rect {
        area.insetBy(dx: area.width * (1 - fraction) / 2,
                     dy: area.height * (1 - fraction) / 2)
    }

    /// `count` frames, staggered down-right from the region's top-left, every one of them ending at
    /// the region's bottom-right corner.
    ///
    /// Total for every input: zero windows is no frames, one window is the region itself (a lone
    /// window has nothing to be staggered against, and shrinking it for a stack of one would be
    /// arithmetic showing through), and a stack too deep for `stagger` compresses rather than
    /// collapsing. A region smaller than `minimumSize` degenerates to a step of zero — every window
    /// exactly on top of every other — which is the honest answer on a screen with no room for a
    /// cascade, and still leaves every window on screen and the same size.
    public static func frames(count: Int, in area: Rect,
                              stagger: Double = stagger,
                              fraction: Double = fraction,
                              minimum: Size = minimumSize) -> [Rect] {
        guard count > 0 else { return [] }
        let region = Cascade.region(in: area, fraction: fraction)
        guard count > 1 else { return [region] }

        // The travel available to the *last* window on the tighter of the two axes: whichever of
        // width and height runs out first is the one that decides the step, or the stack would keep
        // its rhythm horizontally while collapsing vertically.
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

    /// The effects that pile every managed window into the quit cascade — the teardown placement, and
    /// the only thing in the core that deliberately abandons the strip.
    ///
    /// Ordinary truth-plane effects and nothing else (`setFrame` / `raise` / `focus`), so the shell
    /// runs them through the same `AXExecutor` every other placement goes through and answers with
    /// the same `axLanded` / `axFailed`. There is no cover: a quit is not a transition, nothing is
    /// left running to animate it, and §4a's "instant and correct" is exactly what is wanted.
    ///
    /// **What is in the pile.** Every window on every workspace's strip (`Workspaces.allWindowIds`),
    /// including the 35 that are parked at their nubs — rescuing those is the entire point.
    /// Deliberately *not* floating windows, dialogs, panels or sheets: emira never placed them, so
    /// moving them on the way out would be the one and only time it did.
    ///
    /// **Why the focused window goes last.** Later means smaller means *on top*, and with the
    /// bottom-rights aligned a window drawn above its predecessors hides them outright — so the order
    /// is a z-order decision, not just a reading order. Putting the window that had focus at the end
    /// makes it the frontmost, fully-visible one, which is both the window most likely to be wanted
    /// first and the one already frontmost — so the final `focus` moves keyboard focus nowhere and
    /// exists only to guarantee its app is the one in front. Everything else keeps placement order
    /// (focused workspace first, then by address; left→right, top→bottom within a strip), so the
    /// stack is read back in the order the strip had it.
    ///
    /// **The residual, stated plainly: cross-app z-order is not ours.** `raise` is `AXRaise`, which
    /// orders a window within *its own app*; re-levelling a foreign window against another app's needs
    /// SkyLight and we don't do that (`PRINCIPLES.md` §6). So a stack spanning several apps is
    /// correct app-by-app and best-effort between them. The alternative — activating every app in
    /// turn on the way out — is a burst of focus changes at the exact moment the user is quitting, and
    /// is not worth it for a stacking nicety.
    public func cascadeEffects() -> [Effect] {
        guard let metrics = metrics() else { return [] }
        let ordered = cascadeOrder()
        guard let top = ordered.last else { return [] }

        let frames = Cascade.frames(count: ordered.count, in: metrics.workingArea)
        var effects: [Effect] = zip(ordered, frames).map { .setFrame($0, $1) }
        // Raises after the placements: they commute (one is geometry, the other z-order) and the
        // executor issues them the moment it meets them, so keeping them together keeps the order the
        // stack is built in legible in the effect stream.
        effects += ordered.map { Effect.raise($0) }
        effects.append(.focus(top))
        return effects
    }

    /// Every strip window, back-to-front: placement order with the focused window moved to the end.
    private func cascadeOrder() -> [WindowId] {
        let ids = workspaces.allWindowIds
        guard let focused = world.focusedWindow, ids.contains(focused) else { return ids }
        return ids.filter { $0 != focused } + [focused]
    }
}
