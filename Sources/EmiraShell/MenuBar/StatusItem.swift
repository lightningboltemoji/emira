import AppKit
import ServiceManagement
import EmiraCore

// The menu bar item — emira's entire GUI (IMPLEMENTATION.md §6, "*This* is the GUI — no preferences
// window"). It shows the focused workspace's address and nothing else, and its menu holds the two
// actions that only a GUI can offer: stop the daemon, and start it at login.
//
// **What it deliberately doesn't do.**
//
//  · **No reload-config item.** Reload is automatic (`ConfigWatcher`), so a button for it would
//    advertise a step the user doesn't have to take. What a hot reload *can't* do is tell you it
//    failed — the diagnostic goes to stderr, and a bundled app has no stderr anyone is reading. That
//    is the one thing this item adds: the title becomes `!` and the menu says what broke.
//  · **No per-window state.** The strip already draws itself, on the screen, out of real windows.
//
// **Why the title rule is a value type.** `StatusModel` is the whole policy — what the button says,
// what the menu says about it — as pure data, so it is tested without a status bar. What is left in
// `MenuBarItem` is AppKit wiring: an `NSStatusItem`, a menu rebuilt when it opens, two actions. Same
// split as `FrameClock`/`DisplayLinkDriver` and `CoverSurface`/`Reconstruction`, at a much smaller
// scale — the untestable surface is the part with no decisions in it.
//
// **Rendering is diffed, and that is not a micro-optimization.** The pump reduces at 120 Hz for the
// length of every transition, and this observes it (`Runtime.onStateChanged`). A scroll changes no
// workspace address, so a 400 ms transition costs **zero** redraws. The rule is the one
// `ConfigLoader` already settled for the file watch: report a change in the *value*, not a change in
// the thing that carries it.

/// What the menu bar item displays, as pure data.
public struct StatusModel: Equatable, Sendable {

    /// The workspace the viewport is looking at — `state.workspaces.focused`.
    public var workspace: WorkspaceName

    /// The diagnostic from the last config load, or `nil` when the file is fine. A `String` rather
    /// than a `ConfigLoadError` because this only ever displays it, and the daemon has already
    /// rendered the error once for the log.
    public var configError: String?

    public init(workspace: WorkspaceName = .first, configError: String? = nil) {
        self.workspace = workspace
        self.configError = configError
    }

    /// The button's text: the workspace address normally, `!` when the config is broken.
    ///
    /// The address is *replaced* rather than annotated. A broken config means the strip you are
    /// looking at is not the one the file describes, so which workspace you are on is the less
    /// urgent of the two facts — and a menu bar item has room for exactly one character.
    public var title: String { configError == nil ? workspace.description : "!" }

    /// What hovering says. The tooltip is where the address goes when `!` has taken the title.
    public var tooltip: String {
        configError == nil
            ? "emira — workspace \(workspace)"
            : "emira — config error (workspace \(workspace))"
    }

    /// The diagnostic, wrapped for a menu. Empty when there is nothing wrong.
    ///
    /// Wrapping here rather than letting the menu grow: a diagnostic carries an absolute path plus a
    /// message (`/Users/…/emira.toml:3: unknown setting 'layout.colum-gap'`) and an unwrapped menu
    /// item makes the menu wider than the screen is interesting.
    public func diagnosticLines(width: Int = 56) -> [String] {
        guard let configError else { return [] }
        return Self.wrap(configError, at: width)
    }

    /// Greedy word wrap. A single word longer than `width` (a long path) is left over-long rather
    /// than broken mid-token — a truncated path is worse than a wide menu, because it can't be
    /// pasted into a terminal.
    static func wrap(_ text: String, at width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if line.isEmpty {
                line = String(word)
            } else if line.count + 1 + word.count <= width {
                line += " " + word
            } else {
                lines.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}

/// Whether emira starts itself at login, and whether that question can be asked at all.
///
/// `SMAppService.mainApp` registers *the containing app bundle* — no `LaunchAgent` plist to write,
/// nothing under `~/Library/LaunchAgents` to maintain, and the toggle shows up in System Settings ›
/// General › Login Items under emira's own name where the user can override us. This is the whole
/// reason the daemon is a bundled app rather than a launchd job (see the menu bar discussion,
/// 2026-07-26): one process, one identity, one place the grant and the login item both hang off.
public enum LoginItem: Sendable {
    /// Not running from an app bundle — a bare `swift build` binary has nothing to register.
    case unavailable
    /// Registered and will launch at login.
    case enabled
    /// Not registered.
    case disabled
    /// Registered, but switched off by the user in System Settings. We can't turn it back on from
    /// here; only they can.
    case requiresApproval

    /// Whether this process is inside an app bundle. `Bundle.main.bundleIdentifier` is `nil` for a
    /// bare SwiftPM executable and set for anything with an `Info.plist`, which is exactly the
    /// distinction `SMAppService` cares about.
    public static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// The live state. Read when the menu opens, never cached — the user can change it in System
    /// Settings while we run, the same reason `Permissions.screenRecording` is computed.
    public static var current: LoginItem {
        guard isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered:    return .disabled
        case .notFound:         return .disabled
        @unknown default:       return .disabled
        }
    }

    /// Register or unregister. Throws what `SMAppService` throws; the caller logs it.
    public static func set(_ wanted: Bool) throws {
        if wanted {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// The `NSStatusItem` itself: a title, a menu, and two actions.
@MainActor
public final class MenuBarItem: NSObject, NSMenuDelegate {

    /// Stop the daemon. Set by the daemon to the same shutdown path `SIGINT` takes, so quitting from
    /// the menu and Ctrl-C in a terminal do exactly the same thing.
    public var onQuit: (@MainActor () -> Void)?

    /// Somewhere to report a failed login-item toggle. The daemon points this at its log.
    public var onError: (@MainActor (String) -> Void)?

    private let item: NSStatusItem
    private var model: StatusModel

    public init(model: StatusModel = StatusModel()) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.model = model
        super.init()
        let menu = NSMenu()
        // We decide what is enabled — a diagnostic line is a disabled item with no action, and
        // AppKit's automatic enabling would fight us for every one of them.
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        render()
    }

    /// The workspace on display. Assigning the value it already holds does nothing at all.
    public var workspace: WorkspaceName {
        get { model.workspace }
        set { update { $0.workspace = newValue } }
    }

    /// The config diagnostic, or `nil` when the file loads. Assigning flips the title between the
    /// address and `!`.
    public var configError: String? {
        get { model.configError }
        set { update { $0.configError = newValue } }
    }

    private func update(_ change: (inout StatusModel) -> Void) {
        var next = model
        change(&next)
        guard next != model else { return }     // the 120 Hz guard — see the file header
        model = next
        render()
    }

    private func render() {
        guard let button = item.button else { return }
        button.title = model.title
        button.toolTip = model.tooltip
    }

    // MARK: - The menu

    /// Rebuilt every time it opens rather than kept in sync, because two of the three things on it
    /// are facts about the system rather than about us: the login-item registration can be changed
    /// in System Settings, and the diagnostic can change while the menu is closed.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if model.configError != nil {
            menu.addItem(disabled("config failed to parse"))
            let small = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                    weight: .regular)
            for line in model.diagnosticLines() {
                menu.addItem(disabled(line, font: small))
            }
            menu.addItem(disabled("emira is running with the last settings that loaded."))
            menu.addItem(.separator())
        }

        let login = NSMenuItem(title: "open at login",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        switch LoginItem.current {
        case .unavailable:
            login.isEnabled = false
            login.toolTip = "Available when emira runs from its app bundle."
        case .enabled:
            login.state = .on
        case .disabled:
            login.state = .off
        case .requiresApproval:
            // Registered, and the user turned it off. Shown as mixed rather than on or off because
            // both of those would be a lie about who is in control of it.
            login.state = .mixed
            login.toolTip = "Turned off in System Settings › General › Login Items."
        }
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "quit emira", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func disabled(_ title: String, font: NSFont? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let font {
            item.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        }
        return item
    }

    @objc private func toggleLoginItem() {
        let wanted = LoginItem.current != .enabled
        do {
            try LoginItem.set(wanted)
        } catch {
            onError?("login item: \(error.localizedDescription)")
        }
    }

    @objc private func quit() {
        onQuit?()
    }
}
