import Foundation
import EmiraConfig
import EmiraCore
import EmiraMotion

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

    /// What `key` demonstrates with under `config`, or `nil` for a setting on `notDemonstrable`.
    ///
    /// **`nil` means hold the stage, not cut to the section.** A row with nothing to show must leave
    /// whatever was playing exactly where it is — crossing `hold-timeout` on the way down the panel
    /// tearing the mock away from the setting above it is the worst thing a preview can do, because the
    /// user reads it as the setting they just left having no picture either.
    ///
    /// **The draft is an input, because a script's shape can be the value.** A ladder take walks one
    /// beat per rung, so three widths typed is three beats and five is five; nothing else here reads it,
    /// and a take that hard-coded a beat count would be lying about the number in the field beside it.
    ///
    /// Unknown keys answer `nil`: the schema is the authority on what settings exist, and a catalog
    /// that had its own opinion would be a second one. `scripted` is consulted first, because the four
    /// edges of `outer-gap` are keys the *file* spells and the schema does not.
    public static func take(for key: String, config: Config) -> Take? {
        if let take = binding(key, config) { return take }
        if let take = scripted(key, config) { return take }
        guard !notDemonstrable.contains(key) else { return nil }
        let section = ConfigSchema.setting(for: key)?.section
            ?? ConfigSchema.bespoke.first { $0.key == key }?.section
        guard let section else { return nil }
        return self.take(for: section)
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
        case .keys:
            // The Keys tab holds a *list*, so its set at rest is what the strip looks like before any
            // of the bindings on it has fired. The long one, because most of the verbs that have a
            // picture play over it.
            return Take(scene: Scenes.longStrip)
        case .windowRules:
            // No entries in the schema and no editor, so nothing ever asks — but the switch is total on
            // purpose, so adding a section is a compile error here rather than a blank mock at runtime.
            return Take(scene: Scenes.threeColumns)
        }
    }

    // The bindings
    //
    // **The unit here is the verb, not the binding.** A chord is one user's; what a row demonstrates is
    // what the command it runs does, badged with `Cue.command` — the spelling the file itself carries,
    // and the same badge every other take on the panel uses for a cause that happens off screen.
    //
    // The rule `notDemonstrable` keeps for settings, one rung out: **every verb has a take or a written
    // reason**, and `CatalogTests` will not let a verb be added without one. The list starts longer than
    // the settings one, because the mock is a single display showing a single workspace and a third of
    // the vocabulary is about the other displays and the other workspaces.

    /// What a `[keys]` row demonstrates — the command bound to that chord, over the set that shows it.
    ///
    /// The chord is *parsed* out of the key rather than compared as text, because the key a row is
    /// looked up by is the one the **file** spells and `cmd-alt-h` and `alt-cmd-h` are one hotkey
    /// written two ways. What it resolves to is read from the draft's own bindings, so a row shows what
    /// it currently runs and follows the command popup as that changes.
    private static func binding(_ key: String, _ config: Config) -> Take? {
        let prefix = "keys."
        guard key.hasPrefix(prefix), let chord = try? KeyChord.parse(String(key.dropFirst(prefix.count)))
        else { return nil }
        guard let binding = config.keys.first(where: { $0.chord == chord }) else { return nil }

        let spelling = binding.spelling
        let verb = String(spelling.prefix { !$0.isWhitespace })
        guard let take = demonstration(of: verb, config) else { return nil }
        return take.badged(spelling)
    }

    /// The verbs with a picture, and what plays it. Everything else is on `notDemonstrableVerbs`.
    ///
    /// **A beat per verb, or nothing.** Every take here is the mock doing the thing the verb names —
    /// not a rearrangement that happens to look like it. That is what keeps the list short and what
    /// makes the ones that are here worth watching.
    private static func demonstration(of verb: String, _ config: Config) -> Take? {
        switch verb {

        // Focus walking the strip, far enough that the viewport has to move to keep up — which is the
        // whole of what `focus` does that a two-column set cannot show.
        case "focus":
            return Take(scene: Scenes.longStrip,
                        beats: [(0.8, .focusRight), (1.8, .focusRight),
                                (3.0, .focus(Scenes.longStripFirst))],
                        period: 4.2)

        // Pure translation across a full screen, so what moves is one column and nothing else.
        case "move-window":
            return Take(scene: Scenes.threeAcross,
                        beats: [(0.9, .moveColumn(ColumnId(91), to: 2)),
                                (2.4, .moveColumn(ColumnId(91), to: 0))],
                        period: 3.9)

        // The two ladders, walked by the very commands they are ladders for — and paced by the draft's
        // own list, so a five-rung cycle is five beats.
        case "cycle-width":
            return Scenes.widthLadder(config)
        case "cycle-height":
            return Scenes.heightLadder(config)

        // A continuous width change, on the set that leaves room for one. `grow` has a beat of its own;
        // `shrink` is scripted as the width it arrives at, which is the same picture read backwards.
        case "grow":
            return Take(scene: Scenes.detentPair,
                        beats: [(0.9, .grow(.percent(Scenes.growStep))),
                                (2.6, .widthOverride(.proportion(0.35), column: ColumnId(71)))],
                        period: 4.0)
        case "shrink":
            return Take(scene: Scenes.detentPair,
                        beats: [(0.9, .widthOverride(.proportion(0.20), column: ColumnId(71))),
                                (2.6, .widthOverride(.proportion(0.35), column: ColumnId(71)))],
                        period: 4.0)

        // The strip's full width, and back — **not macOS's full screen**, which is the confusion the
        // picture is there to settle: the neighbours scroll out of view rather than a new Space opening.
        case "fullscreen":
            return Take(scene: Scenes.threeColumns,
                        beats: [(0.9, .widthOverride(.proportion(1), column: ColumnId(2))),
                                (2.6, .widthOverride(nil, column: ColumnId(2)))],
                        period: 4.0)

        default:
            return nil
        }
    }

    /// The verbs with no honest picture, and what a take would have had to invent to give them one.
    ///
    /// Three groups, and none of them is a gap in the catalogue. **The mock is one display showing one
    /// workspace**, so every verb whose subject is another display or another workspace is genuinely
    /// undemonstrable on it. **Three verbs need a mechanism the mock has no beat for** — membership,
    /// floating, closing — and a take that mimed one would be teaching a picture the desktop cannot
    /// actually make. **Two have no picture at all**: a shell line and a JSON dump both happen off
    /// screen, which is the point of `exec` and the whole of `debug`.
    public static let notDemonstrableVerbs: [String: String] = [
        "consume-or-expel": """
        Changes which column a window belongs to, and no beat moves a window between a column and its \
        neighbour — the mock scripts focus, widths and whole-column moves. A take would have to invent \
        the mechanism rather than show it.
        """,

        "center-column": """
        Scrolls the viewport on its own, and the mock only ever moves the strip as a consequence of \
        focusing something. A take would be playing `focus` and calling it by another name.
        """,

        "close-window": """
        Takes a window off the desktop, and no beat removes one — every set is fixed for the life of \
        its take, which is what lets the view pool a layer per mock window.
        """,

        "float": """
        Takes a window off the strip, and a `MockFloat` is part of a *set* rather than something a beat \
        can produce. A take would have to cut between two sets, which reads as the preview restarting.
        """,

        "focus-workspace": Self.oneWorkspace,
        "move-to-workspace": Self.oneWorkspace,
        "move-to-workspace-and-focus": Self.oneWorkspace,

        "focus-monitor": Self.oneDisplay,
        "move-to-monitor": Self.oneDisplay,
        "move-to-monitor-and-focus": Self.oneDisplay,
        "move-workspace-to-monitor": Self.oneDisplay,
        "move-workspace-to-monitor-and-focus": Self.oneDisplay,

        "exec": """
        Launches something, and says nothing about the desktop — a window the process opens arrives \
        later as an ordinary creation. The mock has no apps to launch and no dock to launch them from.
        """,

        "debug": """
        A read, answered out of band over the socket. Nothing happens on the desktop at all, which is \
        the one case where a still picture is the honest one.
        """,
    ]

    /// The mock shows one workspace, and the whole content of a workspace verb is the other one.
    private static let oneWorkspace = """
    The mock is a single workspace, so there is nowhere for a window to go and nothing to switch to. \
    A take would have to cut to a second desktop, which is the preview restarting rather than a command \
    running.
    """

    /// …and one display.
    private static let oneDisplay = """
    The mock is a single display. Every monitor verb's whole content is the *other* screen, and a set \
    with one screen in it cannot show a window arriving on another.
    """

    /// The settings with no honest picture, and why. A take that mimed one would teach the user
    /// something false, which is worse than a control with only its sentence under it.
    ///
    /// - `animation.hold-timeout` bounds **the cover**, and a preview has no cover: no truth plane,
    ///   nothing to place, nothing that can refuse. A take miming one would have to invent both a hung
    ///   app and a cover to drop, and would be teaching a mechanism the mock does not have.
    public static let notDemonstrable: Set<String> = [
        "animation.hold-timeout",
    ]

    /// The settings whose demonstration is more than their section's set at rest. Everything answering
    /// `nil` here is demonstrated by geometry alone — `PreviewModel` re-derives on every draft change,
    /// so a gap opens under the hand with nothing playing.
    private static func scripted(_ key: String, _ config: Config) -> Take? {
        switch key {

        // The two gaps are the same set seen from two places, and **the pan is the setting**: one frames
        // the seam *between* two columns, the other the seam *inside* one, both at the same push-in and
        // a right angle apart. Neither plays a beat — geometry re-derives under the hand.
        //
        // **No ring on either**, and that is the second half of the same thought: a gap is the same
        // number whichever window is focused, so a blue border on one of them is a subject the setting
        // does not have.
        case "layout.column-gap":
            return Take(scene: Scenes.threeColumns, camera: .seams(slack: 0.25), showsFocus: false)
        case "layout.window-gap":
            return Take(scene: Scenes.threeColumns, camera: .stackSeam, showsFocus: false)

        // **Outer gaps are wide and stay wide**: the value is measured from the screen's own edges, and
        // a frame that lost them would lose the setting. The band is the value — at `0` it is a hairline
        // because the gutter is — and only the edge under the hand is marked, because the row is four
        // controls and the mock has to say which one. Geometry again, so again no ring.
        case "layout.outer-gap-top":
            return Take(scene: Scenes.threeColumns, mark: .outerGap(.top), showsFocus: false)
        case "layout.outer-gap-left":
            return Take(scene: Scenes.threeColumns, mark: .outerGap(.left), showsFocus: false)
        case "layout.outer-gap-bottom":
            return Take(scene: Scenes.threeColumns, mark: .outerGap(.bottom), showsFocus: false)
        case "layout.outer-gap-right":
            return Take(scene: Scenes.threeColumns, mark: .outerGap(.right), showsFocus: false)

        // Where a reveal comes to rest. Three screens of strip, so the column being revealed starts
        // partly off the right edge: under `off` it slides in and stops flush against that edge, and
        // under `on` it carries on to the middle. Toggling mid-take retargets the viewport live, which
        // is the clearest statement the setting can get.
        case "layout.center-focused-column":
            return Scenes.strideRight

        // Where a grow comes to rest. Two presses of the same size: the first takes its whole delta, the
        // second arrives at a quarter of it and stops with the strip flush against the screen's edge —
        // or, unchecked, carries the neighbour a fifth of a screen off it.
        case "layout.resize-detent":
            return Scenes.growDetent

        // A hand on a window's own edge. Off is identical up to the release and opposite for the last
        // 500 ms, which is precisely the setting.
        case "layout.interactive-resize":
            return Scenes.handResize

        // The ladders. A preset list only means something while something is climbing it, and what
        // climbs is the axis the setting names — a width for `width-presets`, and a **height**, in the
        // stacked column, for the one that has been showing a width.
        case "layout.width-presets":
            return Scenes.widthLadder(config)
        case "layout.height-presets":
            return Scenes.heightLadder(config)

        // Focus. Travelling across the strip is the only way `focus right` means anything, and
        // `system-events` is about a focus change emira did not cause — so the take goes far enough
        // that the strip has to move to keep up.
        case "focus.system-events":
            return Scenes.systemEvents
        case "focus.follows-mouse":
            return Scenes.pointerCrosses

        // Mouse. Every one of these plays over a set that carries a pointer; what differs is what the
        // draft does to it, which is `PreviewModel`'s business rather than the script's.
        case "mouse.hide":
            return Scenes.pointerHides
        case "mouse.follows-focus":
            return Scenes.pointerRungs
        case "mouse.trackpad-scroll", "mouse.trackpad-scroll-direction":
            return Scenes.trackpadSwipe

        // Animation. `transition` and `window` are both about what a move looks like, so both want one
        // happening; the springs each drive the quantity their own help sentence names.
        case "animation.transition":
            return Scenes.rearrange
        case "animation.cover":
            return Scenes.coverTrade

        // The camera frames the growing column **whole**, which on a tiled desktop is very nearly the
        // display: a column is full height, and a shot contains the object the value is measured
        // against. The artifact is big enough at that framing to be the subject.
        case "animation.window":
            return Scenes.widthLadder(config).looking(.stack)

        // Each dial gets the motion its own help sentence names, and each is **paced by the spring being
        // edited** — one complete motion, then a beat of rest, whatever the slider says. A `k = 20`
        // scroll interrupted by the next beat and a `k = 400` one leaving the desktop still for most of
        // the loop are the same bug seen from two ends.
        case "animation.scroll.stiffness", "animation.scroll.damping-ratio":
            return Scenes.strideRight.paced(by: Scenes.beat(config.scrollSpring, over: 900))
        case "animation.glide.stiffness", "animation.glide.damping-ratio":
            return Scenes.trackpadSwipe.paced(by: Scenes.beat(config.glideSpring, over: 400))
        case "animation.resize.stiffness", "animation.resize.damping-ratio":
            return Scenes.widthLadder(config).paced(by: Scenes.beat(config.resizeSpring, over: 300))
        case "animation.movement.stiffness", "animation.movement.damping-ratio":
            return Scenes.translate.paced(by: Scenes.beat(config.moveSpring, over: 1200))

        // The guides. Fifteen settings over one long set, separated by **where the camera stands** —
        // the whole argument for a framing per setting, and now for one per *guide*: two can be up at
        // once, and a lens framing "the guide" would push in on the minimap while the user was editing
        // the row of names.
        //
        // **A close framing and a life cycle are exclusive.** A lens pushed in on a guide that is not
        // up frames the wallpaper where one would be, so only the two settings whose subject *is* the
        // life cycle play it, and they play it wide. Every other guide setting is geometry, and
        // geometry re-derives under the hand with nothing playing.
        case "guide.preview.enabled", "guide.preview.duration":
            return Scenes.guideLife(config, .preview)
        case "guide.preview.position", "guide.preview.width":
            // Wide. A corner is only a corner against the whole screen, and the width is a fraction
            // *of the working width* — the screen's own edges are the ruler.
            return Take(scene: Scenes.guided)
        case "guide.preview.content", "guide.preview.span":
            // Close: `content` is a choice about what a tile draws, and `span` about how many of them
            // there are. Both are unreadable at a couple of points across.
            return Take(scene: Scenes.guided, camera: .guidePanel(.preview))
        case "guide.preview.gap":
            return Take(scene: Scenes.guided, camera: .guideCorner(.preview))

        // The names guide, on the same set and the same rules. Everything but where it *sits* is read
        // by the word, so everything but position is framed close — and close on the names guide is
        // **life size**, because everything read on it is type.
        case "guide.names.enabled", "guide.names.duration":
            return Scenes.guideLife(config, .names)
        case "guide.names.position", "guide.names.width":
            // Wide, for the minimap's reason: a corner is only a corner against the whole screen, and
            // the width is a fraction *of the working width* — the screen's own edges are the ruler.
            return Take(scene: Scenes.guided)
        case "guide.names.gap":
            return Take(scene: Scenes.guided, camera: .guideCorner(.names))
        case "guide.names.font-size", "guide.names.lowercase", "guide.names.max-columns":
            return Take(scene: Scenes.guided, camera: .guidePanel(.names))

        default:
            return nil
        }
    }
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

    /// **Eight columns, three screens** — the Guide set, and the only one that carries a guide.
    ///
    /// It has to be long. `scale = min(width, 1) / span` shrinks the panel to a short strip, so on a
    /// set that fits on one screen both `width` and `span` read as broken rather than as settings.
    ///
    /// **One column is stacked**, which the minimap shows as a rule across it and the names guide as a
    /// superscript — `terminal²` is that column's terminal and one other. A set of eight singletons
    /// would leave the count with nothing to count.
    public static let guided = Scene(
        columns: zip(101..., [[MockRole.editor], [.browser], [.terminal, .editor], [.chat],
                              [.notes], [.music], [.editor], [.browser]]).map { id, stack in
            MockColumn(id: ColumnId(UInt64(id)),
                       windows: stack.enumerated().map {
                           window(UInt64(id) + UInt64($0.offset) * 100, $0.element)
                       },
                       widthPreset: 1)
        },
        focus: WindowId(101),
        hasGuide: true)

    public static let guidedFirst = WindowId(101)

    /// **A guide's whole life cycle, every few seconds.** A column moves, the guide arrives, it holds
    /// for `duration`, it goes, and there is a beat of nothing before it happens again — which is what
    /// the daemon does, and what makes enabling one a cause with an effect.
    ///
    /// The period is derived from **the value being edited**, so at `duration = 4` the loop is six
    /// seconds rather than restarting before that guide has ever gone away. Wide, and only wide: for
    /// most of it there is no guide on the desktop for a lens to be pushed in on.
    static func guideLife(_ config: Config, _ style: GuideStyle) -> Take {
        // A beat of nothing before the first motion, so a loop opens on a desktop with no guide on it
        // and the arrival is something you watch happen rather than something already there.
        let raise = 0.6
        let cycle = max(config.guide.table(of: style).duration, 0.3) + 1.1
        return Take(scene: guided,
                    beats: [(raise, .focusRight), (raise + cycle, .focus(guidedFirst))],
                    period: raise + cycle * 2)
    }

    /// Where the four-column take returns to at the end of its loop.
    public static let fourColumnsFirst = WindowId(11)

    /// **Six columns at a half — three screens of content.** The set every take about *where the strip
    /// comes to rest* plays over, because a reveal is only a reveal when there is something off the
    /// edge to reveal, and a viewport that already holds everything cannot demonstrate a viewport.
    ///
    /// The rung is the user's own second width preset rather than a number written here: the mock
    /// spends the draft's own ladder, as everything else on it does.
    public static let longStrip = Scene(
        columns: zip(31..., [MockRole.editor, .browser, .terminal, .chat, .notes, .music]).map {
            MockColumn(id: ColumnId(UInt64($0.0)), windows: [window(UInt64($0.0), $0.1)],
                       widthPreset: 1)
        },
        focus: WindowId(31))

    /// Where the long strip's take returns to at the end of its loop.
    public static let longStripFirst = WindowId(31)

    /// Focus walking three columns up the long strip and travelling home, with a beat of rest on each
    /// arrival — **the hold is the content**, since what the setting decides is where each reveal
    /// *lands* and there is nothing to read while the strip is still moving.
    static let strideRight = Take(
        scene: longStrip,
        beats: [(1.0, .focusRight), (2.0, .focusRight), (3.0, .focusRight),
                (4.2, .focus(longStripFirst))],
        period: 5.4)

    /// Two columns and room for a pointer to travel between them. The Mouse set.
    ///
    /// `pointerFocus` is `.always` here, and that is a **premise the take stages**: `mouse.follows-focus`
    /// has a rung whose whole content is what a *hovered* focus change does to the cursor, and there is
    /// no honest way to show it without a hover that moves focus. Staged rather than claimed — the
    /// pointer visibly causes the change on screen.
    public static let twoColumns = Scene(
        columns: [
            MockColumn(id: ColumnId(21), windows: [window(21, .notes)], widthPreset: 1),
            MockColumn(id: ColumnId(22), windows: [window(22, .browser)], widthPreset: 1),
        ],
        focus: WindowId(21),
        pointer: MockPointer(at: .window(WindowId(21))),
        pointerFocus: .always)

    /// How long a scripted travel takes. A hand crossing half a screen, near enough — long enough that
    /// the crossing is a moment you can see happen rather than a jump.
    static let handTravel: Double = 0.5

    /// Two columns and a third **partly off the right edge**, with focus answering the pointer exactly
    /// when the setting says so. The Focus-follows-mouse set.
    public static let hoverStrip = Scene(
        columns: [
            MockColumn(id: ColumnId(41), windows: [window(41, .editor)], widthPreset: 0),
            MockColumn(id: ColumnId(42), windows: [window(42, .browser)], widthPreset: 0),
            MockColumn(id: ColumnId(43), windows: [window(43, .terminal)], widthPreset: 1),
        ],
        focus: WindowId(41),
        pointer: MockPointer(at: .window(WindowId(41))),
        pointerFocus: .whenConfigured)

    /// **The pointer is the actor and focus is what answers it**, which is the direction that separates
    /// this setting from `mouse.follows-focus`.
    ///
    /// The last crossing is the clause that makes emira's version of the setting unlike every other
    /// window manager's: the third column starts off the right edge, and crossing into it focuses it
    /// *and scrolls the strip to reveal it*.
    static let pointerCrosses = Take(
        scene: hoverStrip,
        beats: [(1.0, .hover(.window(WindowId(42)), over: handTravel)),
                (2.4, .hover(.window(WindowId(43)), over: handTravel)),
                (4.0, .hover(.window(WindowId(41)), over: handTravel))],
        period: 5.6)

    /// Four rungs, and every one of them gets a picture. **A** — focus moves to a window the pointer is
    /// not in, which separates `off`. **C** — the pointer crosses a seam and moves focus itself, which
    /// separates `force`, since only that rung yanks the cursor away from the spot the hand aimed at.
    /// **B** — focus lands on the window the pointer is already inside, which separates `lazy`.
    ///
    /// The order is A, C, B because each needs focus somewhere particular first, and a transit beat is
    /// another A rather than a wasted one.
    ///
    /// **The transit is a warp under three of the four rungs, so the hand walks back before B**, whose
    /// whole content is focus landing on the window the pointer is *already inside* — a premise the
    /// take has to establish rather than assume.
    static let pointerRungs = Take(
        scene: twoColumns,
        beats: [(1.1, .focus(WindowId(22))),                                      // A
                (2.5, .hover(.inside(WindowId(21), x: 0.3, y: 0.72),
                             over: handTravel)),                                  // C
                (3.9, .focus(WindowId(22))),                                      // transit — an A
                (4.7, .pointer(.inside(WindowId(21), x: 0.3, y: 0.72),
                               over: handTravel)),                                // the hand walks back
                (5.9, .focus(WindowId(21))),                                      // B
                (7.2, .pointer(.window(WindowId(21)), over: handTravel))],        // home
        period: 8.4)

    /// How long one rung of a ladder is held. Long enough to read the new width against the neighbours
    /// that reflowed under it, short enough that a five-rung ladder is still a loop and not a slideshow.
    static let rung: Double = 0.9

    /// How long one beat of a spring dial's take should be: the spring's own settle over `distance`,
    /// plus a beat of rest. **Feel is a calculation, not a taste** — remaining distance under a
    /// critically damped spring is `D(1 + ωt)e^(−ωt)`, so settle time is `u/ω` where
    /// `(1 + u)e^(−u) = ε/D`. This is that equation read the other way, and the underdamped case is
    /// approximated by the same envelope, which is what the tail actually decays under.
    static func beat(_ spring: SpringParams, over distance: Double) -> Double {
        let omega = max(spring.naturalFrequency, 1e-6)
        let epsilon = 0.5
        let ratio = max(min(epsilon / max(distance, epsilon), 0.9), 1e-9)
        // `(1 + u)e^(−u) = ratio`, monotone decreasing in `u`, so bisection is exact enough and cannot
        // wander off the way a Newton step can near the flat end.
        var low = 0.0, high = 40.0
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if (1 + mid) * exp(-mid) > ratio { low = mid } else { high = mid }
        }
        let settle = (low + high) / 2 / (omega * max(spring.dampingRatio, 0.2))
        // Floored and capped so a dial dragged to an extreme leaves a loop someone can still watch.
        return min(max(settle + 0.35, 0.5), 2.6)
    }

    /// The focused column walking **the whole width ladder**, one beat per rung, in the order the field
    /// spells them and wrapping to the first.
    ///
    /// `cycleWidth` rather than a spelled rung, because that is the command the setting is about:
    /// `PresetCycle` normalizes an unbounded index, so `n` steps land back where they started and the
    /// return to rung zero is played rather than rewound. The extra rung at the end is the rest beat, so
    /// the loop shows the first width twice as long as any other.
    static func widthLadder(_ config: Config) -> Take {
        let rungs = max(config.widthPresets.count, 1)
        return Take(scene: threeColumns,
                    beats: (1...rungs).map { (Double($0) * rung, Beat.cycleWidth) },
                    period: Double(rungs + 1) * rung)
    }

    /// The **stacked** column walking the height ladder: the focused window takes each rung in turn
    /// while its stackmate takes the leftover, so the pair visibly trade the column rather than one of
    /// them changing in isolation.
    ///
    /// The ladder includes the rung the field cannot spell — **auto**, where the two are equal — so the
    /// loop is `auto → first → … → last → auto`, which is what cycling actually does.
    static func heightLadder(_ config: Config) -> Take {
        let rungs = config.heightPresets.count
        let focus = threeColumns.focus
        let ladder: [Int?] = (0..<rungs).map { $0 } + [nil]
        return Take(scene: threeColumns, camera: .stack,
                    beats: ladder.enumerated().map {
                        (Double($0.offset + 1) * rung, Beat.heightPreset($0.element, window: focus))
                    },
                    period: Double(rungs + 2) * rung)
    }

    /// Three kinds of target on one set, because the setting is a ladder over exactly three of them:
    /// a tiled window **on screen**, one parked **off the right edge**, and a **float** over the strip
    /// that emira does not place. A set without a float cannot say what `ignore` still honours.
    public static let systemTargets = Scene(
        columns: [
            MockColumn(id: ColumnId(61), windows: [window(61, .editor)], widthPreset: 1),
            MockColumn(id: ColumnId(62), windows: [window(62, .browser)], widthPreset: 1),
            MockColumn(id: ColumnId(63), windows: [window(63, .terminal)], widthPreset: 1),
        ],
        focus: WindowId(61),
        floats: [MockFloat(window: window(64, .chat),
                           at: Rect(x: 0.30, y: 0.22, width: 0.30, height: 0.44))])

    /// `⌘⇥` three times, at the three kinds of target — and **each rung answers a different pattern of
    /// taken and declined across them**, which is the whole of a three-word setting whose desktop looks
    /// identical in two of them.
    ///
    /// **The one cue that stays a chord**, because the setting is about focus emira did *not* cause:
    /// there is no command to name, and a badge that invented one would claim the opposite of the point.
    static let systemEvents = Take(
        scene: systemTargets,
        beats: [(0.8, .cue(.keys("⌘⇥"))), (0.8, .systemFocus(WindowId(63))),
                (1.9, .cue(nil)),
                (2.3, .focus(WindowId(61))),
                (3.0, .cue(.keys("⌘⇥"))), (3.0, .systemFocus(WindowId(62))),
                (4.1, .cue(nil)),
                (4.5, .focus(WindowId(61))),
                (5.2, .cue(.keys("⌘⇥"))), (5.2, .systemFocus(WindowId(64))),
                (6.3, .cue(nil)),
                (6.7, .focus(WindowId(61)))],
        period: 7.8)

    /// Three columns filling the screen exactly. What a rearrangement needs: every window that moves
    /// stays on screen, so a strip caught half-arranged is *visibly* half-arranged.
    public static let threeAcross = Scene(
        columns: [
            MockColumn(id: ColumnId(91), windows: [window(91, .editor)]),
            MockColumn(id: ColumnId(92), windows: [window(92, .browser)]),
            MockColumn(id: ColumnId(93), windows: [window(93, .terminal)]),
        ],
        focus: WindowId(91))

    /// **One motion, big enough that half-arranged is visibly wrong**, with a held frame either side so
    /// that the *shape* of the change is what differs between the three rungs.
    ///
    /// `smooth` glides, `snap` changes in one frame — the held frames are what make an instant cut read
    /// as atomicity rather than as a dropped animation — and `off` staggers, which is the honest
    /// picture of what the cover is for.
    static let rearrange = Take(
        scene: threeAcross,
        beats: [(1.2, .cue(.command("move-window right"))), (1.2, .moveColumn(ColumnId(91), to: 2)),
                (2.1, .cue(nil)),
                (3.0, .cue(.command("move-window left"))), (3.0, .moveColumn(ColumnId(91), to: 0)),
                (3.9, .cue(nil))],
        period: 5.0)

    /// A `move-window` that is **pure translation** — nothing on screen changes size, so the movement
    /// spring is the only spring in the shot and its dials have nowhere to hide.
    static let translate = Take(
        scene: threeAcross,
        beats: [(1.0, .moveColumn(ColumnId(91), to: 2)),
                (2.6, .moveColumn(ColumnId(91), to: 0))],
        period: 4.2)

    /// **The trade `animation.cover` is**: a head latency against a briefly wrong window. The take shows
    /// the two shapes rather than claiming a duration — `exact` pauses and then moves sharply from the
    /// first frame; `immediate` moves on the cue and sharpens when the app catches up.
    ///
    /// The rearrangement carries a **width change** with it, and it has to: a stale still can only be
    /// seen to be stale where the rect it is painted into has changed shape, and a pure translation
    /// paints the same picture into the same size either way.
    static let coverTrade = Take(
        scene: threeAcross,
        beats: [(1.0, .cue(.command("move-window right"))), (1.0, .coverHead),
                (1.0, .moveColumn(ColumnId(91), to: 2)),
                (1.0, .widthPreset(2, column: ColumnId(91))),
                (2.2, .cue(nil)),
                (3.2, .moveColumn(ColumnId(91), to: 0)),
                (3.2, .widthPreset(0, column: ColumnId(91)))],
        period: 5.2)

    /// Focus travelling far enough that the strip scrolls under it, for the springs that drive the
    /// viewport.
    static let focusTravel = Take(scene: fourColumns,
                                  beats: [(0.8, .focusRight), (1.6, .focusRight),
                                          (2.4, .focusRight), (3.4, .focus(fourColumnsFirst))],
                                  period: 4.4)

    /// Two narrow columns with the right third of the screen left bare, and the pointer parked out on
    /// it. `mouse.hide`'s set: a cursor disappearing against a plain field is a disappearance, and one
    /// disappearing over a window is a cursor that might just be somewhere in the furniture.
    public static let barePointer = Scene(
        columns: [
            MockColumn(id: ColumnId(51), windows: [window(51, .notes)], widthPreset: 0),
            MockColumn(id: ColumnId(52), windows: [window(52, .browser)], widthPreset: 0),
        ],
        focus: WindowId(51),
        pointer: MockPointer(at: .spot(x: 0.86, y: 0.56)))

    /// A focus change takes the cursor away, and **the cursor's own movement brings it back** — which is
    /// the whole of "until the mouse next moves". The motion is the cause and the fade follows it.
    static let pointerHides = Take(
        scene: barePointer,
        beats: [(1.0, .cue(.command("focus right"))), (1.0, .focusRight), (1.0, .hidePointer(true)),
                (2.1, .cue(nil)),
                (2.8, .pointer(.spot(x: 0.79, y: 0.51), over: handTravel)),
                (2.8, .hidePointer(false)),
                (4.2, .focus(WindowId(51))),
                (4.2, .pointer(.spot(x: 0.86, y: 0.56), over: handTravel))],
        period: 5.6)

    /// The long strip with a pointer parked on it that **never moves**: a trackpad scroll moves the
    /// strip, not the cursor, and a cursor drifting along with it would be the wrong picture entirely.
    public static let scrolled = Scene(
        columns: longStrip.columns, focus: longStripFirst,
        pointer: MockPointer(at: .spot(x: 0.5, y: 0.62)))

    /// The swipe, the lift, and where it comes to rest.
    ///
    /// The cue is load-bearing twice over: without a finger direction on screen you can see the strip
    /// move and not tell which way the hand went, which is the *whole* of `-direction`; and under `off`
    /// the cue arriving and dimming is the only thing that distinguishes a refusal from a broken loop.
    ///
    /// **The resting frame is held a full second**, because the difference between the two live rungs
    /// is *where it stopped* and there is nothing to read while it is still moving.
    static let trackpadSwipe = Take(
        scene: scrolled,
        beats: [(0.6, .cue(.swipe(.right))),
                (0.9, .scrub(screens: 1.25, over: 0.8)),
                (1.7, .lift), (1.7, .cue(nil)),
                (2.3, .flushMark(.left)),
                (2.7, .flushMark(nil)),
                (3.9, .scrub(screens: -1.25, over: 0.7)),
                (4.6, .lift)],
        period: 6.0)

    /// Two columns at widths **the take chose rather than the draft's ladder**, leaving a boundary
    /// exactly one step and a little further off.
    ///
    /// The one set on the panel that spends explicit widths, and it has to: a detent is a *distance* to
    /// the screen's edge, and off a user ladder that distance is anything at all — already zero where
    /// two presets fill the screen, so the first press is the catch and there is nothing to compare it
    /// against. An override is also what a `grow` leaves behind, so a take about continuous widths
    /// starting from one is the same object it is about to produce.
    public static let detentPair = Scene(
        columns: [
            MockColumn(id: ColumnId(71), windows: [window(71, .editor)],
                       widthOverride: .proportion(0.35)),
            MockColumn(id: ColumnId(72), windows: [window(72, .browser)],
                       widthOverride: .proportion(0.27)),
        ],
        focus: WindowId(71))

    /// What one press of the detent take asks for, as a percentage of the working width — big enough
    /// that a press arriving at a quarter of it is a difference nobody has to be told about.
    ///
    /// The badge is spelled from the same number, so the words on screen and the width on screen cannot
    /// drift apart. `Int` because a percentage is written `30%` and not `30.0%`, which is the spelling
    /// `Command.parse` takes back — `CueTests` checks every cue re-emits unchanged.
    static let growStep: Double = 30
    static var growCue: Cue { .command("grow \(Int(growStep))%") }

    /// The grow set with a hand on it — and the narrow column is the one dragged, so the neighbour it
    /// grows over is still visible standing still. Its own scene rather than the detent's, because a
    /// cursor on that take would be a second thing moving that no setting on screen explains.
    ///
    /// **The hand starts on the handle**, in the shape a handle puts it in. Everything this take is
    /// about happens along one horizontal line, and the cursor never leaves it.
    public static let dragPair = Scene(
        columns: [
            MockColumn(id: ColumnId(71), windows: [window(71, .editor)], widthPreset: 0),
            MockColumn(id: ColumnId(72), windows: [window(72, .browser)], widthPreset: 1),
        ],
        focus: WindowId(71),
        pointer: MockPointer(at: .inside(WindowId(71), x: 1, y: PreviewModel.dragGrip),
                             shape: .resizeEW))

    /// **The right edge is dragged**, and nothing but the dragged window moves until the release — both
    /// true of the real thing, and the pull-out and the reflow are one motion because they are one
    /// event: the layout taking the size as its own intent.
    ///
    /// **Wide from first frame to last.** The subject is a window growing by a third of a screen and
    /// then keeping or losing it, which is a shape read against the display's own edges; a lens pushed in
    /// on the handle would be moving while the very thing it was framing changed size, and two motions
    /// at once is one motion nobody can read. The handle announces itself with the cursor instead, which
    /// is what a handle does.
    ///
    /// The hand is aimed at **exactly** the point the drag will carry — `x: 1` is the trailing edge and
    /// `dragGrip` is where the reducer takes hold — because a cursor that lands a fraction short pops
    /// sideways the instant the button goes down.
    /// **A shuttle along one line**: pull the edge out, let go, read what happened to it, walk back to
    /// where the edge now is, pull again. A third of a screen in two thirds of a second is somebody
    /// pulling an edge rather than easing one across, and the walk back is quicker because nothing is
    /// being aimed at along the way.
    ///
    /// The rewind rides that walk. Under `on` the width is adopted, so the rung has to be restored for
    /// the loop to start over, and doing it while the hand travels left makes it one motion rather than
    /// a window shrinking on its own.
    static let handResize = Take(
        scene: dragPair,
        beats: [(0.4, .press(true)),
                (0.5, .dragEdge(by: .percent(30), over: 0.65)),
                (1.15, .release), (1.15, .press(false)),
                (2.7, .widthPreset(0, column: ColumnId(71))),
                (2.7, .cursor(.arrow)),
                (2.7, .pointer(.inside(WindowId(71), x: 1, y: PreviewModel.dragGrip), over: 0.45)),
                // Back on the handle, so the shape says so again — and the loop wraps on the cursor it
                // started with.
                (3.15, .cursor(.resizeEW))],
        period: 3.7)

    /// Two presses of the same size, and **the catch is the content** — so the caught arrangement is
    /// held for two seconds and the loop is mostly that.
    ///
    /// The set leaves the screen's edge one step *and a quarter* away, so the first press takes its whole
    /// delta and the second arrives at a quarter of it. The badge says the same words both times: what
    /// differs is what the desktop does with them.
    ///
    /// `grow` is continuous, a `SizeDelta` rather than a rung, which is exactly why the setting exists:
    /// the ladder is deliberately exempt from the detent because a preset is an exact intent.
    static let growDetent = Take(
        scene: detentPair,
        beats: [(0.8, .cue(growCue)), (0.8, .grow(.percent(growStep))),
                (1.9, .cue(nil)),
                (2.4, .cue(growCue)), (2.4, .grow(.percent(growStep))),
                (2.4, .flushMark(.right)),
                (3.5, .cue(nil)),
                (4.2, .flushMark(nil)),
                (4.6, .widthOverride(.proportion(0.35), column: ColumnId(71)))],
        period: 5.8)
}
