import AppKit
import Foundation
import EmiraCore
import EmiraProtocol

// `watch`'s other half: a peripheral on `Runtime.onStateChanged`, beside `Guide` and `MenuBarItem`,
// that diffs the published projection and hands a line to every watcher when it changes. It displays
// state rather than changing it, so it is not an `Effect`, and with nobody watching it builds nothing.

/// Whoever is listening for the desktop: whether anyone is, and a way to reach them all. `SocketServer`
/// is the real one; a test records what it was handed.
public protocol DesktopWatchers: AnyObject, Sendable {
    var isWatched: Bool { get }
    /// Hand every watcher `reply`. Returns at once; the writing is the watchers' own.
    func broadcast(_ reply: Reply)
}

/// Publishes `DesktopStatus` to the watchers whenever it changes.
@MainActor
public final class DesktopPublisher {

    /// Set once the server exists, since the server's handler is what answers a `watch` from here.
    public weak var watchers: (any DesktopWatchers)?

    private let names: GuideNames
    private let displayName: @MainActor (MonitorId) -> String?
    /// Resolved once per display: a screen's name does not change while it is attached.
    private var screens: [MonitorId: String] = [:]
    /// The snapshot every watcher has, or `nil` while there are none — the next one to attach is sent a
    /// fresh one, and the drains between built nothing to compare against.
    private var last: DesktopStatus?

    public init(names: GuideNames, displayName: @escaping @MainActor (MonitorId) -> String?) {
        self.names = names
        self.displayName = displayName
    }

    /// One drain's worth of state.
    public func stateChanged(_ state: State) {
        guard let watchers, watchers.isWatched else {
            last = nil
            return
        }
        let next = status(of: state)
        guard next != last else { return }
        last = next
        if let reply = Self.reply(next) { watchers.broadcast(reply) }
    }

    /// The first line a new watcher is sent: the desktop as it stands, which is also what every other
    /// watcher already has, since the socket's hop to main lands between drains.
    public func snapshot(_ state: State) -> Reply {
        let now = status(of: state)
        last = now
        return Self.reply(now) ?? .failed(.internalError("could not encode the desktop"))
    }

    private func status(of state: State) -> DesktopStatus {
        DesktopStatus(state: state, name: { names.name(for: $0) }, displayName: { screen($0) })
    }

    /// A display's name once something answers, and its number until then.
    private func screen(_ monitor: MonitorId) -> String {
        if let known = screens[monitor] { return known }
        guard let name = displayName(monitor) else { return "Display \(monitor.raw)" }
        screens[monitor] = name
        return name
    }

    private static func reply(_ status: DesktopStatus) -> Reply? {
        (try? status.json()).map(Reply.desktop(json:))
    }

    /// What macOS calls a display, for the daemon's `displayName`. The id the core knows a screen by is
    /// `ScreenGeometry`'s, so the lookup goes through the same reader.
    public static func screenName(of monitor: MonitorId) -> String? {
        NSScreen.screens.enumerated()
            .first { ScreenGeometry.monitorId(of: $1, at: $0) == monitor }?.1.localizedName
    }
}
