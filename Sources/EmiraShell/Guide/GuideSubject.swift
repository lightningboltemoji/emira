import Foundation
import EmiraCore

// What one display's guide is drawn from, and what it is *about* — the two reads that turn a `State`
// into the pure `GuideInput` the model runs on, and into the small diffed value that decides when a
// guide goes up.
//
// **Here rather than in `EmiraCore`** because `State` is exactly what a guide must not need: the
// settings window builds its own input from a mock desktop, and `ImportFenceTests` forbids it from
// naming the reducer. The arithmetic is shared; the truth plane is the shell's.
//
// **Everything is asked of `monitor`**: its metrics, the address it is showing, and that strip's
// windows. A display showing an empty workspace has an input with nothing on it, which is the right
// answer and not a special case.

extension GuideInput {

    /// What `monitor`'s guide draws this frame, or `nil` when there is nothing to project onto — no
    /// display known yet (boot, or a reload racing a display change), or this display gone.
    public init?(state: State, monitor: MonitorId) {
        guard let metrics = state.metrics(of: monitor),
              let shown = state.monitors.shown(on: monitor) else { return nil }

        // **This display's workspaces only**: the neighbours that slide through the panel during a
        // switch are the ones *this* monitor holds, and another display's strips have nothing to do
        // with this panel.
        let owned = state.monitors.owned(of: monitor)
        let frames = state.workspaces.naturalFrames(shown: shown, among: owned,
                                                    scrollOffset: state.motion.offset(of: monitor).current,
                                                    metrics: metrics,
                                                    widths: state.motion.currentColumnWidths)
        // The **shown** strip, not every workspace's: a long strip on a workspace you cannot see would
        // otherwise size the guide for one you can. During a switch this is already the strip being
        // switched *to*, which is the one the guide should be sizing itself for.
        let columns = state.workspaces[shown].columns.map { column in
            GuideInput.Column(id: column.id,
                              windows: column.windowIds.compactMap { GuideInput.Window(state, $0) })
        }
        let placed = Set(state.workspaces[shown].allWindowIds)
        let passing = frames.keys.sorted().filter { !placed.contains($0) }
            .compactMap { GuideInput.Window(state, $0) }

        // The ring is single because focus is; only the monitor holding it draws one.
        let mine = Set(owned.flatMap { state.workspaces[$0].allWindowIds })
        let focus = state.world.focusedWindow.flatMap { mine.contains($0) ? $0 : nil }

        self.init(workingArea: metrics.workingArea, columns: columns, passing: passing,
                  frames: frames, focus: focus,
                  focusDisplacement: state.motion.focusRingDisplacement)
    }
}

extension GuideInput.Window {
    /// The window as the guide names it, or `nil` for an id the world no longer knows.
    fileprivate init?(_ state: State, _ id: WindowId) {
        guard let window = state.world.windows[id] else { return nil }
        self.init(id: id, bundleId: window.bundleId)
    }
}

/// What a *change* in the guide's subject looks like — a small diffed projection of `State` rather than
/// the whole of it, so an `axLanded` or a title change cannot summon a HUD. `MenuBarItem`'s rule:
/// report a change in the value, not in the thing carrying it.
public struct GuideTrigger: Equatable, Sendable {
    /// One column's identity and its stack, which together say "the strip was rearranged".
    public struct Column: Equatable, Sendable {
        public let id: ColumnId
        public let windows: [WindowId]
    }

    public let focused: WindowId?
    public let workspace: WorkspaceName
    public let columns: [Column]
    /// Where the scroll is *aimed*, not where it is — a target moves once per command, a current value
    /// moves 120 times a second.
    public let offset: Double

    /// What `monitor`'s guide is about right now, or `nil` when the display has left.
    ///
    /// Every field is this display's, `focused` included: there is one focused window on the desktop,
    /// and a display that does not hold it must not summon a HUD because focus moved on another screen.
    public init?(state: State, monitor: MonitorId) {
        guard let shown = state.monitors.shown(on: monitor) else { return nil }
        let mine = Set(state.monitors.owned(of: monitor).flatMap { state.workspaces[$0].allWindowIds })
        focused = state.world.focusedWindow.flatMap { mine.contains($0) ? $0 : nil }
        workspace = shown
        columns = state.workspaces[shown].columns.map { .init(id: $0.id, windows: $0.windowIds) }
        offset = state.motion.offset(of: monitor).target
    }
}
