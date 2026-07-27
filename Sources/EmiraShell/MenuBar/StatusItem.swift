import AppKit
import ServiceManagement
import EmiraCore

// The menu bar item — emira's entire GUI: the focused workspace's address, a quit and an
// open-at-login action, and a failure channel for hot reload, which is otherwise silent (the title
// becomes `!` and the menu says what broke). `StatusModel` holds the policy as pure data so it is
// testable without a status bar; `MenuBarItem` is the AppKit wiring.

/// What the menu bar item displays, as pure data.
public struct StatusModel: Equatable, Sendable {

    /// The workspace the viewport is looking at — `state.workspaces.focused`.
    public var workspace: WorkspaceName

    /// The diagnostic from the last config load, or `nil` when the file is fine.
    public var configError: String?

    public init(workspace: WorkspaceName = .first, configError: String? = nil) {
        self.workspace = workspace
        self.configError = configError
    }

    /// The button's text: the workspace address normally, `!` when the config is broken. The address
    /// is replaced rather than annotated — a menu bar item has room for one character.
    public var title: String { configError == nil ? workspace.description : "!" }

    /// What hovering says — where the address goes when `!` has taken the title.
    public var tooltip: String {
        configError == nil
            ? "emira — workspace \(workspace)"
            : "emira — config error (workspace \(workspace))"
    }

    /// The diagnostic, wrapped so an absolute path can't make the menu wider than the screen.
    public func diagnosticLines(width: Int = 56) -> [String] {
        guard let configError else { return [] }
        return Self.wrap(configError, at: width)
    }

    /// Greedy word wrap. A single word longer than `width` (a long path) is left over-long rather
    /// than broken mid-token, since a truncated path can't be pasted into a terminal.
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

/// Whether emira starts itself at login. `SMAppService.mainApp` registers *the containing app bundle*
/// — no `LaunchAgent` plist, and the toggle appears in System Settings › General › Login Items where
/// the user can override us. This is why the daemon is a bundled app rather than a launchd job.
public enum LoginItem: Sendable {
    /// Not running from an app bundle — a bare `swift build` binary has nothing to register.
    case unavailable
    case enabled
    case disabled
    /// Registered, but switched off by the user. We can't turn it back on from here; only they can.
    case requiresApproval

    /// `Bundle.main.bundleIdentifier` is `nil` for a bare SwiftPM executable and set for anything with
    /// an `Info.plist` — the distinction `SMAppService` cares about.
    public static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// Read when the menu opens, never cached: the user can change it in System Settings while we run.
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

    /// Stop the daemon. Set by the daemon to the same shutdown path `SIGINT` takes.
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
        // Diagnostic lines are disabled items with no action; automatic enabling would fight us.
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        render()
    }

    /// The workspace on display. Assigning the value it already holds does nothing.
    public var workspace: WorkspaceName {
        get { model.workspace }
        set { update { $0.workspace = newValue } }
    }

    /// The config diagnostic, or `nil` when the file loads. Flips the title between address and `!`.
    public var configError: String? {
        get { model.configError }
        set { update { $0.configError = newValue } }
    }

    private func update(_ change: (inout StatusModel) -> Void) {
        var next = model
        change(&next)
        guard next != model else { return }     // the pump reduces at 120 Hz; a scroll changes nothing here
        model = next
        render()
    }

    private func render() {
        guard let button = item.button else { return }
        button.title = model.title
        button.toolTip = model.tooltip
    }

    // MARK: - The menu

    /// Rebuilt every time it opens rather than kept in sync: the login-item registration can be
    /// changed in System Settings, and the diagnostic can change while the menu is closed.
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
            // Registered, and the user turned it off. Mixed, because on or off would both be a lie.
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
