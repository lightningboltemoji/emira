import AppKit
import EmiraCore

// The display set as an event source. macOS reports every reconfiguration — a monitor plugged in or
// out, a resolution or arrangement change, the Dock moving to another screen, a lid closing — as one
// notification with no payload, so the answer is always a fresh read of `NSScreen.screens`.
//
// **One read, several consumers**, which is the same rule the daemon's boot read follows and for the
// same reason: `NSScreen.visibleFrame` is live, so a second read for the core's copy would let a Dock
// that moved in between inset a cover by one number and its strip by another. Everything a
// reconfiguration produces is therefore bundled into one value.

/// One reading of the attached displays: the screens themselves, the flip line they were measured
/// against, and the core's view of them.
///
/// `screens` and `monitors` are index-aligned, and both carry the `MonitorId` that
/// `ScreenGeometry.monitorId(of:at:)` mints — the one number the overlay, the capturer and the core's
/// strip are all keyed on.
///
/// `@MainActor` rather than `Sendable`: `NSScreen` is neither, and every reader of this is the main
/// actor anyway — the overlays, the guides and the pump all live there.
@MainActor
public struct AttachedDisplays {
    public let screens: [NSScreen]
    public let geometry: ScreenGeometry
    public let monitors: [MonitorInfo]

    /// The displays attached right now.
    public static func current(_ screens: [NSScreen] = NSScreen.screens) -> AttachedDisplays {
        let geometry = ScreenGeometry.current()
        return AttachedDisplays(screens: screens, geometry: geometry,
                                monitors: geometry.monitors(screens))
    }

    /// The screen the frame clock should run on: the fastest attached. `dt` is real elapsed time and
    /// the springs are analytic in it, so a 60 Hz screen fed at 120 Hz drops frames while a 120 Hz one
    /// fed at 60 Hz is visibly under-driven — picking the fastest means nobody is ever the latter.
    public var fastest: NSScreen? {
        screens.max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }
    }

    /// Each display paired with the id it is known by, in enumeration order.
    public var byId: [(monitor: MonitorId, screen: NSScreen, info: MonitorInfo)] {
        zip(monitors, screens).map { ($0.id, $1, $0) }
    }
}

/// Watches for display reconfigurations and reports the new set. An event **source**, so it belongs
/// beside the socket server and the hotkey manager: it reports a fact, and what the daemon does about
/// it — rebuild the per-display machinery, dispatch `Event.screensChanged` — is policy.
@MainActor
public final class ScreenWatcher {

    /// Called on every reconfiguration, with the displays already read.
    public var onChange: (@MainActor (AttachedDisplays) -> Void)?

    private var observer: (any NSObjectProtocol)?

    public init() {}

    /// Begin watching. Idempotent — a second call keeps the first observer rather than adding another,
    /// which would double every rebuild.
    public func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?(AttachedDisplays.current()) }
        }
    }

    /// Stop watching — teardown, where our own writes must stop producing events (`Teardown`'s rule).
    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
