import EmiraConfig
import EmiraCore

// Which take demonstrates which **setting** — the unit is the setting and not the section, because that
// is the difference between a preview and a demonstration: hovering `center-focused-column` should show
// what it does before it has been touched.
//
// Several takes share one scene, and that is what keeps it from being noisy. Every Layout setting plays
// over the same three columns, so moving from `column-gap` to `window-gap` changes nothing at all — same
// set, no beats, no retarget. The mock moves when a value moves, and otherwise holds still.
//
// **Some settings cannot be shown, and this says so rather than faking it.** `notDemonstrable` is the
// list, and `CatalogTests` requires every schema entry to be on it or to have a take, so a new setting
// cannot be added without a demo story.

/// The takes, keyed by setting.
public enum Catalog {

    /// What `key` demonstrates with, or `nil` for a setting on `notDemonstrable`.
    ///
    /// Unknown keys answer `nil` too: the schema is the authority on what settings exist, and a catalog
    /// that had its own opinion would be a second one. **A bespoke surface's key is known** — it is on
    /// `ConfigSchema.bespoke` — and answers its section's set, which is right for the one that has an
    /// editor: outer gaps are geometry, and geometry re-derives with nothing playing.
    public static func take(for key: String) -> Take? {
        guard !notDemonstrable.contains(key) else { return nil }
        let section = ConfigSchema.setting(for: key)?.section
            ?? ConfigSchema.bespoke.first { $0.key == key }?.section
        guard let section else { return nil }
        return byKey[key] ?? self.take(for: section)
    }

    /// What a section shows when nothing in it is hovered — the set at rest.
    public static func take(for section: Setting.Section) -> Take {
        switch section {
        case .layout, .animation:
            return Take(scene: Scenes.threeColumns)
        case .guide:
            return Take(scene: Scenes.guided)
        case .focus:
            return Take(scene: Scenes.fourColumns)
        case .mouse:
            return Take(scene: Scenes.twoColumns)
        case .keys, .windowRules:
            // No entries in the schema, so nothing ever asks — but the switch is total on purpose, so
            // adding a section is a compile error here rather than a blank mock at runtime.
            return Take(scene: Scenes.threeColumns)
        }
    }

    /// The settings with no honest picture, and why. A take that mimed one would teach the user
    /// something false, which is worse than a control with only its sentence under it.
    ///
    /// - `layout.interactive-resize` is a hand on a real window's frame.
    /// - `animation.hold-timeout` is how long emira waits before giving up on a window it cannot see.
    /// - `animation.cover` is a policy about what gets captured, not about what moves.
    public static let notDemonstrable: Set<String> = [
        "layout.interactive-resize",
        "animation.hold-timeout",
        "animation.cover",
    ]

    /// The settings whose demonstration is more than their section's set at rest. Everything absent here
    /// is demonstrated by geometry alone — `PreviewModel` re-derives on every draft change, so a gap
    /// opens under the hand with nothing playing.
    static let byKey: [String: Take] = [
        // Layout — the one setting here that is behaviour rather than geometry: a preset ladder only
        // means something while a column is climbing it.
        "layout.width-presets": Scenes.widthCycle,
        "layout.height-presets": Scenes.widthCycle,

        // Focus. Travelling across the strip is the only way `focus right` means anything, and
        // `system-events` is about a focus change emira did not cause — so the take goes far enough
        // that the strip has to move to keep up.
        "focus.system-events": Scenes.focusTravel,
        "focus.follows-mouse": Scenes.pointerFollows,

        // Mouse. Every one of these plays over the set that carries a pointer; what differs is what the
        // draft does to it, which is `PreviewModel`'s business rather than the script's.
        "mouse.hide": Scenes.pointerFollows,
        "mouse.follows-focus": Scenes.pointerFollows,
        "mouse.trackpad-scroll": Scenes.pointerScroll,
        "mouse.trackpad-scroll-direction": Scenes.pointerScroll,

        // Animation. `transition` and `window` are both about what a move looks like, so both want one
        // happening; the springs each drive the quantity their own help sentence names.
        "animation.transition": Scenes.focusTravel,
        "animation.window": Scenes.widthCycle,

        "animation.scroll.stiffness": Scenes.focusTravel,
        "animation.scroll.damping-ratio": Scenes.focusTravel,
        "animation.glide.stiffness": Scenes.focusTravel,
        "animation.glide.damping-ratio": Scenes.focusTravel,
        "animation.resize.stiffness": Scenes.widthCycle,
        "animation.resize.damping-ratio": Scenes.widthCycle,
        "animation.movement.stiffness": Scenes.widthCycle,
        "animation.movement.damping-ratio": Scenes.widthCycle,
    ]
}

/// The sets, written once and shared by every take that plays over them. Ids are minted here and are
/// stable for the life of the process, which is what lets the view pool a layer per mock window.
public enum Scenes {

    static func window(_ n: UInt64, _ role: MockRole) -> MockWindow {
        MockWindow(id: WindowId(n), role: role)
    }

    /// Three columns, the middle one focused and stacked two deep. The Layout set.
    public static let threeColumns = Scene(
        columns: [
            MockColumn(id: ColumnId(1), windows: [window(1, .browser)]),
            MockColumn(id: ColumnId(2), windows: [window(2, .terminal), window(3, .editor)]),
            MockColumn(id: ColumnId(3), windows: [window(4, .music)]),
        ],
        focus: WindowId(2))

    /// Four columns, wide enough that the last one is off the right edge. The Focus set.
    public static let fourColumns = Scene(
        columns: [
            MockColumn(id: ColumnId(11), windows: [window(11, .editor)], widthPreset: 1),
            MockColumn(id: ColumnId(12), windows: [window(12, .browser)], widthPreset: 1),
            MockColumn(id: ColumnId(13), windows: [window(13, .terminal)], widthPreset: 1),
            MockColumn(id: ColumnId(14), windows: [window(14, .chat)], widthPreset: 1),
        ],
        focus: WindowId(11))

    /// The Layout set with the real guide drawn on it. The Guide section's, and the only set that
    /// carries one: elsewhere it would be a second thing moving that no setting on screen explains.
    public static let guided = Scene(
        columns: threeColumns.columns, focus: threeColumns.focus, hasGuide: true)

    /// Where the four-column take returns to at the end of its loop.
    public static let fourColumnsFirst = WindowId(11)

    /// Two columns and room for a pointer to travel between them. The Mouse set.
    public static let twoColumns = Scene(
        columns: [
            MockColumn(id: ColumnId(21), windows: [window(21, .notes)]),
            MockColumn(id: ColumnId(22), windows: [window(22, .browser)]),
        ],
        focus: WindowId(21),
        hasPointer: true)

    /// A column cycling its width, for the springs that drive a size.
    static let widthCycle = Take(scene: threeColumns,
                                 beats: [(0.8, .cycleWidth),
                                         (1.9, .widthPreset(0, column: ColumnId(2)))],
                                 period: 3.0)

    /// Focus travelling far enough that the strip scrolls under it, for the springs that drive the
    /// viewport.
    static let focusTravel = Take(scene: fourColumns,
                                  beats: [(0.8, .focusRight), (1.6, .focusRight),
                                          (2.4, .focusRight), (3.4, .focus(fourColumnsFirst))],
                                  period: 4.4)

    /// Focus crossing between two windows with a pointer on the set — what `mouse.follows-focus` sends
    /// the pointer after, and what `mouse.hide` takes away.
    static let pointerFollows = Take(scene: twoColumns,
                                     beats: [(1.0, .focusRight), (2.4, .focus(WindowId(21)))],
                                     period: 3.6)

    /// The strip travelling under a resting pointer — a trackpad scroll is the strip moving, not the
    /// pointer, and the two settings here decide whether and which way.
    static let pointerScroll = Take(scene: twoColumns,
                                    beats: [(1.0, .cycleWidth), (2.2, .widthPreset(0, column: ColumnId(21)))],
                                    period: 3.4)
}
