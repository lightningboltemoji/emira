import Foundation
import EmiraCore
import EmiraProtocol

// The read that turns a `State` into what `watch` publishes. Here rather than beside the type in
// `EmiraProtocol` for `GuideSubject`'s reason: the schema is a contract anyone can decode, and the
// truth plane it is read off is the shell's.
//
// **A column is named by its natural geometry**, the layout's own answer with no animation applied, so
// the name a watcher sees cannot flicker while the column it names is still resizing.

extension DesktopStatus {

    /// The desktop as `watch` publishes it. `name` turns a bundle id into the word a user calls the app
    /// and `displayName` a display into the word macOS calls it — the caller's, since only the shell
    /// can answer either.
    public init(state: State, name: (String) -> String, displayName: (MonitorId) -> String) {
        let focused = state.world.focusedWindow
        func window(_ id: WindowId) -> Window? {
            state.world.windows[id].map {
                Window(id: id, app: name($0.bundleId), bundle: $0.bundleId, focused: id == focused)
            }
        }

        let displays = state.monitors.ids.compactMap { monitor -> Display? in
            guard let shown = state.monitors.shown(on: monitor) else { return nil }
            let layout = state.workspaces[shown]
            let frames = state.metrics(of: monitor).map {
                layout.naturalFrames(scrollOffset: 0, metrics: $0)
            } ?? [:]
            let columns = layout.columns.compactMap { column -> Column? in
                let windows = column.windowIds.compactMap(window)
                guard !windows.isEmpty else { return nil }
                let named = NamesModel.largest(
                    of: GuideInput.Column(id: column.id, windows: windows.map {
                        GuideInput.Window(id: $0.id, bundleId: $0.bundle)
                    }),
                    in: frames)
                return Column(id: column.id, focused: windows.contains(where: \.focused),
                              app: name(named), windows: windows)
            }
            let bands = state.world.pinBands(on: monitor)
            let pins = PinSide.allCases.compactMap { side in
                bands[side].flatMap { window($0.window) }.map { Pin(side: side, window: $0) }
            }
            return Display(id: Self.key(monitor), name: displayName(monitor),
                           main: state.world.monitor(monitor)?.isMain ?? false,
                           focused: state.monitors.focused == monitor,
                           workspace: shown, layout: layout.kind, columns: columns, pins: pins)
        }

        let onScreen = Set(state.monitors.ids.compactMap { state.monitors.shown(on: $0) })
        let named = Set(state.workspaces.occupied).union(onScreen)
        let workspaces = WorkspaceName.all.filter(named.contains).map { address in
            Workspace(name: address, display: state.monitors.monitor(of: address).map(Self.key),
                      shown: onScreen.contains(address),
                      windows: state.workspaces[address].allWindowIds.count)
        }

        self.init(moving: state.motion.needsFrames,
                  focus: state.world.focusedWindowState.map { focus in
                      Self.focus(of: focus, in: state, name: name)
                  },
                  displays: displays, workspaces: workspaces)
    }

    /// Where the focused window is: the workspace holding it and the display holding that, or the
    /// display a pin is held at, or — for a window on neither — the display under its middle.
    private static func focus(of window: WindowState, in state: State,
                              name: (String) -> String) -> Focus {
        let workspace = state.workspaces.workspace(of: window.id)
        let monitor = workspace.flatMap { state.monitors.monitor(of: $0) }
            ?? state.world.pins[window.id]?.monitor
            ?? state.world.monitor(at: window.frame.center)
        return Focus(display: monitor.map(key), workspace: workspace, window: window.id,
                     app: name(window.bundleId), bundle: window.bundleId)
    }

    /// A display as the schema names it: its number, as text, so nobody does arithmetic on it.
    static func key(_ monitor: MonitorId) -> String { String(monitor.raw) }
}
