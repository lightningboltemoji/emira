import AppKit
import ServiceManagement
import EmiraConfig
import EmiraCore

// The menu bar item — emira's entire GUI: the focused workspace's address, a way into the config
// file, a quit and an open-at-login action, and a failure channel for the config file, which is
// otherwise silent (the title becomes `!` and the menu says what broke). `StatusModel` holds the
// policy as pure data so it is testable without a status bar; `MenuBarItem` is the AppKit wiring.

/// What the config file is doing to emira — the whole of what the menu bar has to say about it.
///
/// The two failures are not the same failure. A file that *stops* parsing leaves the settings that
/// were already running in place, so emira carries on and the diagnostic is advice. A file that has
/// *never* parsed leaves nothing behind it, so emira manages no windows at all and the diagnostic is
/// the reason why.
public enum ConfigStatus: Equatable, Sendable {

    /// The file loads — or isn't there, which means the same thing.
    case loaded

    /// A reload failed, and the settings from before it broke are still running.
    case broken(String)

    /// The file was already broken when emira started, so there are no settings to fall back to and
    /// the desktop is left alone until it parses.
    case neverLoaded(String)

    /// The diagnostic, when there is one.
    public var error: String? {
        switch self {
        case .loaded:                                       return nil
        case .broken(let error), .neverLoaded(let error):   return error
        }
    }
}

/// What the menu bar item displays, as pure data.
public struct StatusModel: Equatable, Sendable {

    /// The address the **acting** display is showing — `state.monitors.shown`. The title's one
    /// character, so of the several addresses a multi-display desktop is showing this is the one that
    /// gets it: the others are somewhere the user is not.
    public var workspace: WorkspaceName

    /// What the **other** displays are showing, in enumeration order — empty on one display, which is
    /// what keeps every string below unchanged there.
    public var elsewhere: [WorkspaceName] = []

    /// What the last config load left behind.
    public var configStatus: ConfigStatus

    public init(workspace: WorkspaceName = .first, elsewhere: [WorkspaceName] = [],
                configStatus: ConfigStatus = .loaded) {
        self.workspace = workspace
        self.elsewhere = elsewhere
        self.configStatus = configStatus
    }

    /// The button's text: the workspace address normally, `!` when the config is broken. The address
    /// is replaced rather than annotated — a menu bar item has room for one character.
    public var title: String { configStatus.error == nil ? workspace.description : "!" }

    /// What hovering says — where the address goes when `!` has taken the title, and the only place a
    /// desktop of several displays can say what the *other* screens are showing. An emira that never
    /// loaded a config says that instead: the address of a workspace holding no windows is not the
    /// fact the user is missing.
    public var tooltip: String {
        switch configStatus {
        case .loaded:       return "emira — workspace \(addresses)"
        case .broken:       return "emira — config error (workspace \(addresses))"
        case .neverLoaded:  return "emira — config error (not managing windows)"
        }
    }

    /// The acting display's address, and the others after it. One display reads as it always did.
    private var addresses: String {
        guard !elsewhere.isEmpty else { return workspace.description }
        return "\(workspace) (also \(elsewhere.map(\.description).joined(separator: ", ")))"
    }

    /// What the failure means for the emira that is running, and `nil` when nothing is wrong — so
    /// this is also the bit that decides whether the menu carries a diagnostic at all.
    public var consequence: String? {
        switch configStatus {
        case .loaded:       return nil
        case .broken:       return "emira is running with the last settings that loaded."
        case .neverLoaded:  return "emira starts managing windows when it parses."
        }
    }

    /// The diagnostic, wrapped so an absolute path can't make the menu wider than the screen.
    public func diagnosticLines(width: Int = 56) -> [String] {
        guard let error = configStatus.error else { return [] }
        return Self.wrap(error, at: width)
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
    /// The file the daemon actually loaded, which `$EMIRA_CONFIG` may have moved.
    private let configPath: String

    public init(model: StatusModel = StatusModel(), configPath: String = Config.defaultPath()) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.model = model
        self.configPath = configPath
        super.init()
        let menu = NSMenu()
        // Diagnostic lines are disabled items with no action; automatic enabling would fight us.
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        render()
    }

    /// What each display is showing: the acting one's address, then the rest. One assignment rather
    /// than two, so a desktop where both changed at once renders once. Assigning what it already holds
    /// does nothing.
    public func setWorkspaces(_ workspace: WorkspaceName, elsewhere: [WorkspaceName] = []) {
        update {
            $0.workspace = workspace
            $0.elsewhere = elsewhere
        }
    }

    /// The acting display's workspace, for a caller with only one to give.
    public var workspace: WorkspaceName {
        get { model.workspace }
        set { update { $0.workspace = newValue } }
    }

    /// What the config file is doing to emira. Flips the title between the address and `!`.
    public var configStatus: ConfigStatus {
        get { model.configStatus }
        set { update { $0.configStatus = newValue } }
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

    /// Rebuilt every time it opens rather than kept in sync: the login-item registration can be
    /// changed in System Settings, and the diagnostic can change while the menu is closed.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let consequence = model.consequence {
            menu.addItem(disabled("config failed to parse"))
            let small = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                    weight: .regular)
            for line in model.diagnosticLines() {
                menu.addItem(disabled(line, font: small))
            }
            menu.addItem(disabled(consequence))
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

        let config = NSMenuItem(title: "open config file",
                                action: #selector(openConfigFile), keyEquivalent: ",")
        config.target = self
        config.toolTip = configPath
        menu.addItem(config)

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

    @objc private func openConfigFile() {
        do {
            try ConfigFile.open(at: configPath)
        } catch {
            onError?("config file: \(error.localizedDescription)")
        }
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
