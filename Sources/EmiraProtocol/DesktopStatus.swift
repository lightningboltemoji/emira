import Foundation
import EmiraCore

// What `emira watch` streams: the desktop as something outside emira reads it — what each display
// shows, the columns on it and what they are called, and where focus is. A bar, a script and a status
// widget all want this and none of them wants `State`, which `debug` dumps and which is nobody's
// contract. So this one is versioned on its own, apart from the wire's envelope around it.
//
// **Discrete facts only.** Nothing here moves while a transition runs — no frame, no scroll offset, no
// title — so a command costs a watcher about two lines, the change and then `moving` settling, and
// never one per tick. `GuideTrigger`'s rule, one consumer further out.
//
// **Every key is always present.** An absent fact is `null`, never a missing key: a consumer that
// merges each line into what it had would otherwise keep the focus that went away.

/// One snapshot of the desktop, as `watch` publishes it. Every line is a whole one, never a delta, so
/// a consumer that falls behind can drop every line but the newest.
public struct DesktopStatus: Sendable, Equatable, Codable {

    /// The schema's version. Bumped when a field changes meaning or goes away; a field added is not a
    /// bump, since a reader that ignores keys it does not know reads the new shape unchanged.
    public static let currentVersion = 1

    /// One window: its id, and the app it belongs to — as the user calls it and as macOS does.
    public struct Window: Sendable, Equatable, Codable {
        public var id: WindowId
        /// The app's own name, localized: "Safari", not the bundle id.
        public var app: String
        public var bundle: String
        public var focused: Bool

        public init(id: WindowId, app: String, bundle: String, focused: Bool) {
            self.id = id
            self.app = app
            self.bundle = bundle
            self.focused = focused
        }
    }

    /// One column of a shown workspace, and its stack top to bottom.
    public struct Column: Sendable, Equatable, Codable {
        public var id: ColumnId
        public var focused: Bool
        /// What the names guide calls the column: the app of its largest window.
        public var app: String
        public var windows: [Window]

        public init(id: ColumnId, focused: Bool, app: String, windows: [Window]) {
            self.id = id
            self.focused = focused
            self.app = app
            self.windows = windows
        }
    }

    /// A window held at an edge of a display, on no workspace at all.
    public struct Pin: Sendable, Equatable, Codable {
        public var side: PinSide
        public var window: Window

        public init(side: PinSide, window: Window) {
            self.side = side
            self.window = window
        }
    }

    /// One attached display, and the workspace on it.
    public struct Display: Sendable, Equatable, Codable {
        /// Opaque and stable while the display stays attached; a workspace's `display` names it.
        public var id: String
        /// What macOS calls the screen — "Built-in Retina Display".
        public var name: String
        /// Whether it holds the menu bar.
        public var main: Bool
        /// Whether it is the display verbs act on. Exactly one is, whenever any display is attached.
        public var focused: Bool
        public var workspace: WorkspaceName
        public var layout: Layout.Kind
        /// The shown workspace's columns, in strip order — a cascade's in slot order.
        public var columns: [Column]
        /// Left before right.
        public var pins: [Pin]

        public init(id: String, name: String, main: Bool, focused: Bool, workspace: WorkspaceName,
                    layout: Layout.Kind, columns: [Column], pins: [Pin]) {
            self.id = id
            self.name = name
            self.main = main
            self.focused = focused
            self.workspace = workspace
            self.layout = layout
            self.columns = columns
            self.pins = pins
        }
    }

    /// One address with something on it, or on a screen.
    public struct Workspace: Sendable, Equatable, Codable {
        public var name: WorkspaceName
        /// The display holding it, or `nil` while no display is attached.
        public var display: String?
        /// Whether some display is showing it right now.
        public var shown: Bool
        public var windows: Int

        public init(name: WorkspaceName, display: String?, shown: Bool, windows: Int) {
            self.name = name
            self.display = display
            self.shown = shown
            self.windows = windows
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(display, forKey: .display)
            try container.encode(shown, forKey: .shown)
            try container.encode(windows, forKey: .windows)
        }
    }

    /// The focused window, wherever it is — a column, a pin, or floating.
    public struct Focus: Sendable, Equatable, Codable {
        /// The display it is on, or `nil` when none can be named.
        public var display: String?
        /// The workspace holding it, or `nil` for a pinned window, which is on none.
        public var workspace: WorkspaceName?
        public var window: WindowId
        public var app: String
        public var bundle: String

        public init(display: String?, workspace: WorkspaceName?, window: WindowId, app: String,
                    bundle: String) {
            self.display = display
            self.workspace = workspace
            self.window = window
            self.app = app
            self.bundle = bundle
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(display, forKey: .display)
            try container.encode(workspace, forKey: .workspace)
            try container.encode(window, forKey: .window)
            try container.encode(app, forKey: .app)
            try container.encode(bundle, forKey: .bundle)
        }
    }

    public var version: Int
    /// Whether anything is still in flight — a transition, the focus ring, a hand on the trackpad. A
    /// consumer that shows the desktop for a while after it changes counts from this going false.
    public var moving: Bool
    public var focus: Focus?
    /// In the order macOS enumerates them.
    public var displays: [Display]
    /// Occupied or shown, in address order: `1`–`9`, `0`, then `a`–`z`.
    public var workspaces: [Workspace]

    public init(moving: Bool, focus: Focus?, displays: [Display], workspaces: [Workspace],
                version: Int = DesktopStatus.currentVersion) {
        self.version = version
        self.moving = moving
        self.focus = focus
        self.displays = displays
        self.workspaces = workspaces
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(moving, forKey: .moving)
        try container.encode(focus, forKey: .focus)
        try container.encode(displays, forKey: .displays)
        try container.encode(workspaces, forKey: .workspaces)
    }

    /// The snapshot as one compact line of JSON, keys sorted — what `watch` prints, and what
    /// `Reply.desktop` carries.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
