import Foundation

// Scrims: transparency for the windows you are not working in.
//
// **We cannot set a foreign window's alpha** (`PRINCIPLES` §2), so this is the presentation plane's
// answer to the same class of problem hoisting answers: draw the thing we are not allowed to change.
// The arithmetic is the whole trick, and it is exact rather than approximate — compositing what is
// *behind* a window over the top of it, at `veil`, is the same blend as the window being transparent:
//
//     drawn = veil · backdrop + (1 − veil) · window
//     true  = (1 − veil) · window + veil · backdrop
//
// Nothing is faked; the two sides are the same number. What the effect can get wrong is only ever the
// *backdrop* — which is why the one rule below is about what is behind a window, not about the blend.
//
// **The backdrop is the desktop, and that is only the truth where the desktop is what is behind.** The
// shell holds one photograph per display: the wallpaper, the icons, the widgets — every window taken
// out of it. Where a window sits directly on that, the photograph is exactly what a transparent window
// would show. Where another *window* is behind it, the photograph is a lie of the worst kind available
// here: it replaces a real window with wallpaper, and the depth of the desktop reads inside out.
//
// So the effect belongs to the strip, and says so: **`strip` promises that windows never overlap**
// (`PRINCIPLES` §1), and that promise is what makes the desktop the true backdrop for every window on
// it. A cascade overlaps by definition, and its tiles are backed by each other rather than by the
// desktop, so they decline — one photograph cannot stand in for five windows, and the alternative is a
// capture per window, refilmed whenever anything behind anything redraws.
//
// **The core names windows; the shell decides which of them the photograph is true for.** That split is
// the one `capture` already sits on — the core asks for a still and the shell reports it could not take
// one. The physical stacking of the desktop, including the windows emira never placed, is the window
// server's fact and not the layout's, so the decline is made where that fact lives.

/// One window drawn as though you could see through it: which window, which display's photograph backs
/// it, the rect it occupies in core (top-left, global) coordinates, and how much of the desktop shows.
///
/// Array order is z-order, bottom→top — the convention `LayerBinding` and `HoistBinding` carry.
public struct ScrimBinding: Sendable, Equatable, Codable {
    public let window: WindowId
    /// Whose desktop photograph backs it. A scrim is one display's, because the photograph is.
    public let monitor: MonitorId
    /// Where the real window is. A scrim stands exactly on it, or it tints somebody else's pixels.
    public let frame: Rect
    /// The share of the backdrop that shows — `1 − [focus] unfocused-opacity`. Carried per binding
    /// rather than read from the config by the shell, so the one place that decides how transparent a
    /// window looks is the reducer, as it is for every other number the shell draws with.
    public let veil: Double

    public init(window: WindowId, monitor: MonitorId, frame: Rect, veil: Double) {
        self.window = window
        self.monitor = monitor
        self.frame = frame
        self.veil = veil
    }
}

extension State {

    /// Every on-screen window that is not the focused one, bottom→top, at the veil the config asks for.
    /// The guard is the first line because the post-pass that calls it runs on every event, including a
    /// display-link tick, and `unfocusedOpacity` is 1 unless somebody turned this on.
    ///
    /// `placedOnScreen` and not "every window", for `hoistBindings`' reason: it is the placement pass's
    /// own record of what it put on the glass, so a parked column at its sliver is out without anybody
    /// deriving a viewport.
    public func scrimBindings() -> [ScrimBinding] {
        let veil = min(max(1 - config.unfocusedOpacity, 0), 1)
        guard veil > 0 else { return [] }

        let focused = world.focusedWindow
        let candidates = world.placedOnScreen.filter { $0 != focused }.sorted()
        guard !candidates.isEmpty else { return [] }

        return stackingOrder(of: candidates)
            .compactMap { id -> ScrimBinding? in
                guard let frame = world.windows[id]?.frame,
                      let monitor = showing(id, at: frame) else { return nil }
                return ScrimBinding(window: id, monitor: monitor, frame: frame, veil: veil)
            }
    }

    /// Which display is showing `id`: a pin names its own, a window on a layout takes the display
    /// showing that layout's workspace, and only what is on neither is asked where it happens to be.
    ///
    /// **Not the window's centre**, which is what a hoist's display is asked of. A float sits inside
    /// the screen it is on; a column need not — the strip is infinite and the viewport is a slice of
    /// it, so a column at the edge hangs half off with its centre in the parked region beyond.
    private func showing(_ id: WindowId, at frame: Rect) -> MonitorId? {
        if let pin = world.pins[id] { return pin.monitor }
        if let name = workspaces.workspace(of: id), let monitor = monitors.monitor(of: name) {
            return monitor
        }
        return world.monitor(at: frame.center)
    }
}
