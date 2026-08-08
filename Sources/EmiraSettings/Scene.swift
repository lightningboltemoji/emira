import EmiraCore

// The set: which mock windows exist, what they are, and how they are arranged into columns. No time in
// it — a scene is what the mock desktop *is*, and `Take` is what happens on it.
//
// A scene names **roles** rather than applications. The catalog resolves a role to an app actually
// installed on the machine, so a scene stays a scripted fact rather than a snapshot of whatever happens
// to be open, while still looking like the user's own desktop.

/// What a mock window is meant to be. Resolved to a real installed app — and its real icon — by the
/// AppKit half; a role with nothing installed for it falls back to a generic glyph.
public enum MockRole: String, Sendable, Equatable, CaseIterable {
    case editor, browser, terminal, chat, notes, music
}

/// One window on the mock desktop.
public struct MockWindow: Sendable, Equatable {
    public let id: WindowId
    public let role: MockRole

    public init(id: WindowId, role: MockRole) {
        self.id = id
        self.role = role
    }
}

/// One column of the mock desktop: its windows top to bottom, and which width preset it sits at.
public struct MockColumn: Sendable, Equatable {
    public let id: ColumnId
    public let windows: [MockWindow]
    /// An index into `Config.widthPresets` — the rung `cycleWidth` would leave the column on.
    public let widthPreset: Int

    public init(id: ColumnId, windows: [MockWindow], widthPreset: Int = 0) {
        self.id = id
        self.windows = windows
        self.widthPreset = widthPreset
    }
}

/// A mock desktop's arrangement, and which of its windows has focus.
public struct Scene: Sendable, Equatable {
    public let columns: [MockColumn]
    /// The focused window. The strip frames its column, so this is what the scroll offset derives from.
    public let focus: WindowId
    /// Whether the real guide is drawn on this set, small. Only the Guide section wants one.
    public let hasGuide: Bool
    /// Whether a mock pointer is drawn on this set. Only the Mouse section wants one — elsewhere it is
    /// a second thing moving that no setting on screen explains.
    public let hasPointer: Bool

    public init(columns: [MockColumn], focus: WindowId,
                hasPointer: Bool = false, hasGuide: Bool = false) {
        self.columns = columns
        self.focus = focus
        self.hasPointer = hasPointer
        self.hasGuide = hasGuide
    }

    public var windows: [MockWindow] { columns.flatMap(\.windows) }

    public func role(of id: WindowId) -> MockRole? {
        windows.first { $0.id == id }?.role
    }

    /// The index of the column holding `id`, or `nil` for a window not on this set.
    public func columnIndex(ofWindow id: WindowId) -> Int? {
        columns.firstIndex { $0.windows.contains { $0.id == id } }
    }

    /// This scene as the layout the real strip would be. The one translation between a scripted desktop
    /// and the code that lays out the real one — everything downstream works on `Layout`, so a mock
    /// window's frame is arrived at by the same arithmetic a real window's is.
    public var layout: Layout {
        Layout(columns: columns.map {
            ColumnLayout(id: $0.id, windowIds: $0.windows.map(\.id), widthPreset: $0.widthPreset)
        })
    }

    /// The same set with `focus` moved. What a take's `focusLeft`/`focusRight` beat produces.
    public func focusing(_ id: WindowId) -> Scene {
        Scene(columns: columns, focus: id, hasPointer: hasPointer, hasGuide: hasGuide)
    }

    /// The same set with one column's width preset changed — `cycleWidth` on the mock.
    public func setting(widthPreset preset: Int, ofColumn id: ColumnId) -> Scene {
        Scene(columns: columns.map {
            $0.id == id ? MockColumn(id: $0.id, windows: $0.windows, widthPreset: preset) : $0
        }, focus: focus, hasPointer: hasPointer, hasGuide: hasGuide)
    }

    /// The focused window's column, which is the one a width beat acts on.
    public var focusedColumn: MockColumn? {
        columns.first { $0.windows.contains { $0.id == focus } }
    }
}
