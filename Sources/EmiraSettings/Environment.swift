import AppKit

// The three things that can change under an open settings window: the system appearance, the displays
// attached, and whether the user wants motion at all. All three are live values rather than ones read
// once at open — the same discipline `PRINCIPLES.md` §5 states for the two system grants, which macOS
// can also change under a running daemon.

/// Watches what the settings window has to react to, and says so once per change.
@MainActor
final class SettingsEnvironment {

    /// The system appearance changed. Every `CGColor` in the layer tree was resolved when its layer was
    /// built, so a live switch means restyling rather than waiting for the next launch.
    var onAppearance: (@MainActor () -> Void)?
    /// A display was attached, detached, or resized. The scrim covers *every* display, so this is not a
    /// cosmetic event: a new screen with no scrim on it is a hole in the composition.
    var onScreens: (@MainActor () -> Void)?
    /// Reduce Motion was turned on or off.
    var onMotionPreference: (@MainActor () -> Void)?

    /// Whether the user has asked for less movement. Read live, never cached: it is a switch in System
    /// Settings that can be flipped while this window is up.
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var appearanceObserver: NSKeyValueObservation?
    /// The block form of `addObserver` registers a **token**, not `self`, so `removeObserver(self)` would
    /// take nothing away and every block would go on firing for the life of the process.
    private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []

    func start() {
        // KVO rather than a notification: `effectiveAppearance` is the value that actually decides how
        // a `CGColor` resolves, and it changes for a per-app override as well as a system one.
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onAppearance?() }
        }
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onScreens?() }
            }
        tokens.append((NotificationCenter.default, screens))

        let motion = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onMotionPreference?() }
            }
        tokens.append((NSWorkspace.shared.notificationCenter, motion))
    }

    func stop() {
        appearanceObserver?.invalidate()
        appearanceObserver = nil
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
    }

    // No `deinit` cleanup: the tokens are main-actor state and a `deinit` is not. `stop()` is called
    // from the one place this is owned — the window coming down — and an observer outliving that would
    // hold only a `weak self` anyway.
    deinit { appearanceObserver?.invalidate() }
}
