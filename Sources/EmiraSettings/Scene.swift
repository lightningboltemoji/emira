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
    /// An index into `Config.heightPresets` — the rung `cycleHeight` would leave this window on. `nil`
    /// is **auto**, the rung the field cannot spell: share the column's leftover height with the other
    /// autos, which is where every window starts.
    public let heightPreset: Int?

    public init(id: WindowId, role: MockRole, heightPreset: Int? = nil) {
        self.id = id
        self.role = role
        self.heightPreset = heightPreset
    }
}

/// One column of the mock desktop: its windows top to bottom, and which width preset it sits at.
public struct MockColumn: Sendable, Equatable {
    public let id: ColumnId
    public let windows: [MockWindow]
    /// An index into `Config.widthPresets` — the rung `cycleWidth` would leave the column on.
    public let widthPreset: Int
    /// An explicit width off the ladder, as `grow` and a hand resize leave one. Shadows the preset,
    /// exactly as `ColumnLayout.widthOverride` does — `grow` is continuous and a rung is not.
    public let widthOverride: PresetSize?

    public init(id: ColumnId, windows: [MockWindow], widthPreset: Int = 0,
                widthOverride: PresetSize? = nil) {
        self.id = id
        self.windows = windows
        self.widthPreset = widthPreset
        self.widthOverride = widthOverride
    }
}

/// Where the mock pointer is, said in terms of the **set** rather than in points.
///
/// A scripted path has to survive a display it does not know, a gap the user is dragging and a preset
/// ladder that has three rungs today and five tomorrow — so it names a window and a place inside it, and
/// the geometry answers where that is this frame.
public enum PointerAt: Sendable, Equatable {
    /// The middle of a window.
    case window(WindowId)
    /// A fraction of the way across a window and down it. `(1, 0.5)` is the middle of its right edge,
    /// which is where a resize handle lives.
    case inside(WindowId, x: Double, y: Double)
    /// A fraction of the way across the working area — open desktop, where nothing is.
    case spot(x: Double, y: Double)
}

/// The mock pointer: where it is, what shape it is, and whether it is being held down.
public struct MockPointer: Sendable, Equatable {
    /// A cursor's shape is an announcement — `resizeEW` on a window's edge is the handle saying it is
    /// one, and it is half of what makes a drag read as a drag rather than as a window resizing itself.
    public enum Shape: Sendable, Equatable { case arrow, resizeEW }

    public var at: PointerAt
    public var shape: Shape
    public var isPressed: Bool
    /// Whether the script has *hidden* it — which is not the same as a set that never draws one, and
    /// the difference is the whole of `mouse.hide`. Whether the hiding actually happens is the draft's.
    public var isHidden: Bool

    public init(at: PointerAt, shape: Shape = .arrow, isPressed: Bool = false,
                isHidden: Bool = false) {
        self.at = at
        self.shape = shape
        self.isPressed = isPressed
        self.isHidden = isHidden
    }
}

/// What the pointer crossing into another window does to focus **on this set**.
public enum PointerFocus: Sendable, Equatable {
    /// Nothing. Focus is the script's, and the pointer is a passenger.
    case none
    /// Focus follows it exactly when `focus.follows-mouse` says so — which makes the crossing itself the
    /// demonstration, and the ring conspicuously staying put the other half of it.
    case whenConfigured
    /// Focus follows it, full stop. A **premise the take stages**, so `mouse.follows-focus` can show
    /// what a hovered focus change does to the cursor — honest, because the pointer visibly causes the
    /// change on screen rather than a caption claiming it.
    case always

    /// Whether a hover moves focus under `config`.
    func answers(_ config: Config) -> Bool {
        switch self {
        case .none:           return false
        case .whenConfigured: return config.focusFollowsMouse
        case .always:         return true
        }
    }
}

/// A mock desktop's arrangement, and which of its windows has focus.
public struct Scene: Sendable, Equatable {
    public let columns: [MockColumn]
    /// The focused window. The strip frames its column, so this is what the scroll offset derives from.
    public let focus: WindowId
    /// Whether the real guide is drawn on this set, small. Only the Guide section wants one.
    public let hasGuide: Bool
    /// The mock pointer, or `nil` for a set that carries none — which is most of them, because
    /// elsewhere it is a second thing moving that no setting on screen explains.
    public let pointer: MockPointer?
    /// Whether focus answers the pointer here.
    public let pointerFocus: PointerFocus
    /// Windows emira does not place — over the strip, off the ladder. One set has them.
    public let floats: [MockFloat]
    /// The input badge, or `nil` while nothing is being said. Only for a beat whose cause is off-screen.
    public let cue: Cue?
    /// Whether the script has asked for the flush tick. Whether it is *drawn* is a fact about the
    /// geometry — a mark claiming an alignment that is not there would be the one lie in the window.
    public let asksFlush: Mark.Edge?

    public init(columns: [MockColumn], focus: WindowId,
                pointer: MockPointer? = nil, pointerFocus: PointerFocus = .none,
                floats: [MockFloat] = [], cue: Cue? = nil, asksFlush: Mark.Edge? = nil,
                hasGuide: Bool = false) {
        self.columns = columns
        self.focus = focus
        self.pointer = pointer
        self.pointerFocus = pointerFocus
        self.floats = floats
        self.cue = cue
        self.asksFlush = asksFlush
        self.hasGuide = hasGuide
    }

    /// This set with one thing about it changed. Every mutator below goes through it, so a field added
    /// to `Scene` cannot be silently dropped by the one copy that forgot to carry it.
    private func with(columns: [MockColumn]? = nil, focus: WindowId? = nil,
                      pointer: MockPointer? = nil, cue: Cue?? = nil,
                      asksFlush: Mark.Edge?? = nil) -> Scene {
        Scene(columns: columns ?? self.columns, focus: focus ?? self.focus,
              pointer: pointer ?? self.pointer, pointerFocus: pointerFocus,
              floats: floats, cue: cue ?? self.cue, asksFlush: asksFlush ?? self.asksFlush,
              hasGuide: hasGuide)
    }

    /// The same set with the badge showing something else, or nothing.
    public func showing(cue: Cue?) -> Scene { with(cue: .some(cue)) }

    /// The same set asking for the flush tick, or no longer asking.
    public func showing(flush: Mark.Edge?) -> Scene { with(asksFlush: .some(flush)) }

    /// The same set with the badge answering — how a refusal reads as a refusal.
    public func answering(_ answer: Cue.Answer) -> Scene {
        guard var cue else { return self }
        cue.answer = answer
        return with(cue: .some(cue))
    }

    /// Whether `id` is a window emira does not place. The `ignore` rung of `focus.system-events` is
    /// exactly this question.
    public func isFloat(_ id: WindowId) -> Bool { floats.contains { $0.window.id == id } }

    /// Every float's frame, in true points.
    public func floatFrames(workingArea: Rect) -> [WindowId: Rect] {
        floats.reduce(into: [:]) { frames, float in
            frames[float.window.id] = float.frame(in: workingArea)
        }
    }

    /// Every window on the set, tiled ones first and then the floats over them — which is also the
    /// order they are drawn and the order a hit test reads them in reverse.
    public var windows: [MockWindow] { columns.flatMap(\.windows) + floats.map(\.window) }

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
            ColumnLayout(id: $0.id, windowIds: $0.windows.map(\.id), widthPreset: $0.widthPreset,
                         widthOverride: $0.widthOverride)
        })
    }

    /// The same set with `focus` moved. What a take's `focusLeft`/`focusRight` beat produces.
    public func focusing(_ id: WindowId) -> Scene {
        with(focus: id)
    }

    /// The same set with one column's width preset changed — `cycleWidth` on the mock.
    public func setting(widthPreset preset: Int, ofColumn id: ColumnId) -> Scene {
        // Clears the override, exactly as `Layout.setWidthPreset` does: a cycle resumes the ladder
        // rather than guessing which rung a grown width was nearest.
        with(columns: columns.map {
            $0.id == id ? MockColumn(id: $0.id, windows: $0.windows, widthPreset: preset) : $0
        })
    }

    /// The same set with one column moved along the strip — `move-window`, which is the only motion on
    /// the desktop that is **pure translation**: nothing resizes, so the movement spring is the only
    /// spring in the shot.
    public func moving(column id: ColumnId, to index: Int) -> Scene {
        guard let from = columns.firstIndex(where: { $0.id == id }) else { return self }
        let to = min(max(index, 0), columns.count - 1)
        guard to != from else { return self }
        var moved = columns
        moved.insert(moved.remove(at: from), at: to)
        return with(columns: moved)
    }

    /// The same set with one column at an explicit width — where `grow` and a hand resize leave one.
    public func setting(widthOverride width: PresetSize?, ofColumn id: ColumnId) -> Scene {
        with(columns: columns.map {
            $0.id == id ? MockColumn(id: $0.id, windows: $0.windows, widthPreset: $0.widthPreset,
                                     widthOverride: width) : $0
        })
    }

    /// The same set with one window pinned to a height rung, or back to auto — `cycleHeight` on the
    /// mock. Its stackmates are untouched, so what the pair visibly do is trade the column's height.
    public func setting(heightPreset preset: Int?, ofWindow id: WindowId) -> Scene {
        with(columns: columns.map { column in
            MockColumn(id: column.id,
                       windows: column.windows.map {
                           $0.id == id ? MockWindow(id: $0.id, role: $0.role, heightPreset: preset) : $0
                       },
                       widthPreset: column.widthPreset, widthOverride: column.widthOverride)
        })
    }

    /// The same set with the pointer somewhere else, or in another shape, or held down. A set with no
    /// pointer is left alone — a beat cannot conjure one, because whether a set carries a cursor is a
    /// property of what the take is about.
    public func moving(pointer change: (inout MockPointer) -> Void) -> Scene {
        guard var moved = pointer else { return self }
        change(&moved)
        return with(pointer: moved)
    }

    /// Which height rung each window is pinned to, in the shape `LayoutMetrics` wants. A window on
    /// auto contributes nothing, which is exactly how the real one is spelled.
    public var heightSelections: [WindowId: Int] {
        windows.reduce(into: [:]) { selections, window in
            selections[window.id] = window.heightPreset
        }
    }

    /// The focused window's column, which is the one a width beat acts on.
    public var focusedColumn: MockColumn? {
        columns.first { $0.windows.contains { $0.id == focus } }
    }
}

extension PointerAt {
    /// Where this is, in true points, against the set as it currently stands. `nil` for a window that
    /// has left — a pointer aimed at nothing stays where it was rather than jumping to the origin.
    func point(frames: [WindowId: Rect], workingArea: Rect) -> Point? {
        switch self {
        case .window(let id):
            return frames[id]?.center
        case .inside(let id, let x, let y):
            guard let frame = frames[id] else { return nil }
            return Point(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y)
        case .spot(let x, let y):
            return Point(x: workingArea.minX + workingArea.width * x,
                         y: workingArea.minY + workingArea.height * y)
        }
    }
}
