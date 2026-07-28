import Foundation

// The exhaustive output vocabulary — the only things the pure core can ask the shell to do. The core
// speaks ids, never pixels: nothing here carries a `CGImage`. Every effect may feed its result back
// as an `Event`.

/// A single instruction from the core to the shell, grouped by the subsystem that executes it.
public enum Effect: Sendable, Equatable, Codable {

    // MARK: Truth plane — Accessibility API (`AXUIElementSetAttributeValue`)
    //
    // Each acks with `Event.axLanded(win)`, or `Event.axFailed(win)` when the app refuses or times
    // out. An app that *accepts* the set and then puts the window somewhere else (a minimum size,
    // character-cell quantizing) is not a failure — that is `Event.windowFrameChanged`.

    /// Teleport a real window to `rect` on the virtual strip (the shell Y-flips at its boundary).
    case setFrame(WindowId, Rect)

    /// Park a window off-viewport at a deterministic sliver `slot`. Geometrically a `setFrame`, but
    /// distinct because the shell captures *before* parking and `axLanded` scoping skips park→park.
    case park(WindowId, Rect)

    // MARK: Presentation plane — Core Animation (our own overlay layers)
    //
    // Blitted on the main thread inside a `CATransaction` with actions disabled. No ack: these are
    // per-frame writes driven by `Event.tick(dt)` while a transition session is open.

    /// Place a reconstruction layer this frame. Keyed by `LayerId`, not `WindowId`: a window may back
    /// several layers, and the wallpaper layer backs no window at all.
    case setLayerFrame(LayerId, Rect)

    // MARK: Capture — ScreenCaptureKit

    /// Grab a still of `win`'s surface (SCK captures it even when occluded), acked by
    /// `Event.captureReady`. Gating on that ack is what makes the cover opaque before any real
    /// window teleports behind it.
    case capture(WindowId)

    // MARK: Transition lifecycle — the layered reconstruction (Compositor)

    /// Open a transition session: build the layered reconstruction and raise it. Carries the ordered
    /// `LayerBinding`s that compose the cover, one per scoped window, z-order bottom→top.
    case beginTransition([LayerBinding])

    /// Add layers to an already-raised cover, on top, for windows that entered scope after it opened
    /// — an interrupting command retargets the scroll, and the new destination sweeps windows the
    /// original scope never named. Immediately followed by a `setLayerFrame` for every binding, so a
    /// newcomer is created and placed within one frame.
    case extendCover([LayerBinding])

    /// Move one layer to the top of the cover's z-order for the rest of the transition. Only
    /// structural edits need it: two columns trading places pass through each other, and which is on
    /// top is a fact about the command, not derivable from the layout. Re-emitted after every
    /// `extendCover`, which would otherwise bury the mover.
    case elevateLayer(LayerId)

    /// Close the transition session: cross-fade back to the real desktop and drop the cover. Acks
    /// with `Event.crossfadeDone`.
    case endTransition

    // MARK: Focus & stacking — AX + `NSRunningApplication`

    /// Give a real window keyboard focus (raise + make key via AX / app activation).
    case focus(WindowId)

    /// Raise a real window in the z-order without necessarily focusing it (stacking within a column).
    case raise(WindowId)

    // MARK: Lifetime — AX

    /// Ask a window to close itself, as clicking its close button would. Deliberately unacked: the app
    /// owns its own close path, so it may put up a save sheet, close later, or refuse outright. The only
    /// truth is the destroy observation, which arrives as `Event.windowDestroyed` like any other close —
    /// so the core changes no state here and the strip closes ranks when (and if) the window really goes.
    case closeWindow(WindowId)

    // MARK: System — a child process

    /// Run a command line through `/bin/sh -c`, fire and forget. The one effect that reaches outside
    /// the desktop, and unacked for the reason `closeWindow` is: what a process does belongs to the
    /// process. A window it opens arrives on its own as `Event.windowCreated`, by the ordinary path.
    case exec(String)
}
