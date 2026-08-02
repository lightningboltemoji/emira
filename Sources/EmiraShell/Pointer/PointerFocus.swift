import EmiraCore
import Foundation

// Focus following the pointer — the half of it that cannot be pure, which is *when to ask*.
//
// **Here a focus scrolls**, so hover can chase itself: the reveal carries the next column under a
// stationary pointer. Two rules stop it, and neither is an optimisation:
//
// 1. **It fires on pointer motion only, never on window motion** — the termination argument, and why
//    this type is driven by the mouse monitor rather than by `onStateChanged`.
// 2. **It is suspended while a cover is up.** Hover is an act of the eye, and mid-transition the eye is
//    on a photograph of where the real windows were.
//
// Suspension keeps *tracking* while it declines to *dispatch*, so a cover coming down leaves the
// baseline as whatever is under the hand rather than reporting a crossing the pointer never made.

/// Turns pointer samples into `Event.pointerEntered`, one per crossing.
///
/// Holds a `() -> State` reader rather than living in `WorldWatcher`, which holds no core state by
/// design. The hit test itself is the core's (`World.window(at:)`); what is here is the hysteresis.
@MainActor
public final class PointerFocus {

    private let state: @MainActor () -> State
    private let sink: EventSink

    /// Whether `[focus] follows-mouse` is on. Kept here rather than read out of `State` per sample,
    /// because copying a `State` to find out it is off *is* the cost being avoided — and `[mouse] hide`
    /// keeps the samples coming either way. Set by `applyShellConfig`; the reducer holds the real policy.
    public var isEnabled = false

    /// The window the pointer was last seen over — the baseline a crossing is measured against.
    private var current: WindowId?

    public init(state: @escaping @MainActor () -> State, sink: EventSink) {
        self.state = state
        self.sink = sink
    }

    /// Fold one pointer sample.
    public func pointerMoved(to point: Point) {
        // Asked before anything is read, let alone the hit test: a query over every window at the
        // refresh rate is exactly the kind of idle price a window manager must not pay for a setting
        // nobody turned on, and neither is a copy of the whole `State` to find out it is off.
        guard isEnabled else { return }
        let state = state()
        let hit = state.world.window(at: point)
        // Tracked before either refusal below, so a suspended interval leaves the baseline current.
        defer { current = hit }
        // Rule 2. The reals have teleported and the eye is on a photograph of where they were.
        guard !state.motion.isCovered else { return }
        // A hidden pointer may be sitting over a window nobody chose — the strip can have scrolled under
        // it — so the motion that ends a hide only *wakes*. The wake comes off this same sample, a step
        // later (`PointerSamples`), which is why this reads the flag rather than counting samples.
        guard !state.pointer.isCursorHidden else { return }
        guard let hit, hit != current else { return }
        sink(.pointerEntered(hit))
    }

    /// The pointer was put somewhere by us rather than moved there by the user — `Effect.warpPointer`,
    /// which posts no event. Rebase the baseline on what is under it now, or the next real sample
    /// reports a crossing against the window the cursor *left*: usually harmless, but `World.window(at:)`
    /// prefers a float to the tiled window beneath it, and a float over the target's centre would take
    /// the focus the warp was sent to deliver. The sibling of `PointerWake.reanchor()`.
    public func pointerWarped(to point: Point) {
        // The same refusal `pointerMoved` opens with: with the setting off nothing reads `current`, so
        // nothing is owed an update, and a `State` copy to find that out is the cost being avoided.
        guard isEnabled else { return }
        current = state().world.window(at: point)
    }
}
