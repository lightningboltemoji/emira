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
// So the effect belongs to the strip, and this is where it says so: **`strip` promises that windows
// never overlap** (`PRINCIPLES` §1), and that promise is what makes the desktop the true backdrop for
// every window on it. A cascade overlaps by definition and its tiles are backed by each other, so a
// `stack` workspace's windows are not named at all — one photograph cannot stand in for five windows,
// the alternative is a capture per window refilmed whenever anything behind anything redraws, and what
// a veil buys on a cascade is small beside that: the tiles are the same size, so the overlaps are the
// whole of what says which is on top.
//
// **Which layout a window is on is the core's fact; how the desktop stacks is the shell's.** So the
// layout's decline is made here and the physical one there, on the split `capture` already sits on —
// the core asks for a still and the shell reports it could not take one. The windows emira never
// placed, and the order the window server holds them all in, are knowable only where that fact lives.

/// One window drawn as though you could see through it, and how much of the desktop shows. No frame and no
/// display: where it stands is the window server's to say, and `Effect.setScrims` names the screen.
/// Array order is z-order, bottom→top — the convention `LayerBinding` and `HoistBinding` carry.
public struct ScrimBinding: Sendable, Equatable, Codable {
    public let window: WindowId
    /// The share of the backdrop that shows — `1 − [focus] unfocused-opacity`. Carried per binding
    /// rather than read from the config by the shell, so the one place that decides how transparent a
    /// window looks is the reducer, as it is for every other number the shell draws with.
    public let veil: Double

    public init(window: WindowId, veil: Double) {
        self.window = window
        self.veil = veil
    }
}

/// How a scrim's mask gets from what it is drawing to what a set asks for. **The core says which**, since
/// it is what knows why the set changed; the plane keeps no memory of its own to guess from.
public enum ScrimChange: String, Sendable, Equatable, Codable {
    /// A veil moved: focus crossed, a window reached the glass or left it, the setting itself changed.
    /// The mask dissolves over `ScrimWindow.fadeDuration`.
    case dissolve
    /// The mask moves with no veil behind it — the desktop settled under a set that did not move, or a
    /// hand lifted one — so it changes at once. A correction that faded would read as the window
    /// deciding to become transparent by itself.
    case cut
}

extension State {

    /// Every on-screen window that is not the focused one, bottom→top, at the veil the config asks for.
    /// The guard is the first line because the post-pass that calls it runs on every event, including a
    /// display-link tick, and `unfocusedOpacity` is 1 unless somebody turned this on.
    ///
    /// `placedOnScreen` and not "every window", for `hoistBindings`' reason: it is the placement pass's
    /// own record of what it put on the glass, so a parked column at its sliver is out without anybody
    /// deriving a viewport.
    ///
    /// **Empty while a window is in the user's hand**: a mask is cut once per set, so a moving window's
    /// hole would stay where it was picked up. By display, because a scrim is one display's, and each
    /// screen's own run of the z-order is the only order there is.
    public func scrimBindings() -> [MonitorId: [ScrimBinding]] {
        let veil = min(max(1 - config.unfocusedOpacity, 0), 1)
        guard veil > 0, drag.subject == nil else { return [:] }

        // **Focus resting on nothing keeps the veil where it was**: `World.lastFocus` is the shelter the
        // arrival path already takes from the same routine `nil`, which read literally draws the whole
        // strip see-through for as long as no managed window holds the keyboard.
        let focused = world.focusedWindow ?? world.lastFocus
        let candidates = world.placedOnScreen.filter { $0 != focused }.sorted()
        guard !candidates.isEmpty else { return [:] }

        let showing = stackingOrder(of: candidates)
            .compactMap { id -> (MonitorId, ScrimBinding)? in
                guard let frame = world.windows[id]?.frame,
                      let monitor = veiling(id, at: frame) else { return nil }
                return (monitor, ScrimBinding(window: id, veil: veil))
            }
        return Dictionary(grouping: showing, by: \.0).mapValues { $0.map(\.1) }
    }

    /// Which display draws `id` see-through, or `nil` where none does: a pin names its own, a window on
    /// a layout takes the display showing that layout's workspace — and declines there if the layout is
    /// a cascade — and only what is on neither is asked where it happens to be.
    ///
    /// **Not the window's centre**, which is what a hoist's display is asked of. A float sits inside
    /// the screen it is on; a column need not — the strip is infinite and the viewport is a slice of
    /// it, so a column at the edge hangs half off with its centre in the parked region beyond.
    private func veiling(_ id: WindowId, at frame: Rect) -> MonitorId? {
        if let pin = world.pins[id] { return pin.monitor }
        if let name = workspaces.workspace(of: id) {
            guard workspaces[name].kind == .strip else { return nil }
            return monitors.monitor(of: name)
        }
        return world.monitor(at: frame.center)
    }
}
