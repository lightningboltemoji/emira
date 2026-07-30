import Foundation
import EmiraMotion

// The configuration values the reducer reads. Pure data: the *parse* is next door
// (`ConfigSyntax.swift`), and finding, reading and watching `~/.config/emira/emira.toml` is the
// shell's, which hands the result back as `Event.configChanged`.
//
// **Lengths are in points; width presets are proportions of the content width.** A zero-config
// `Config()` lays out a sensible strip, which is also what a missing config file produces.

/// When a cover may go up: once every window in it is exact, or the moment the desktop behind it is.
/// The question `WindowAnimation` answers in space — what to paint where the pixels aren't there yet —
/// asked in time. Neither mode changes a frame of emitted geometry.
public enum CoverMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Raise only once every scoped window's own still has landed: pixel-identical to the desktop it
    /// replaces, at a head latency that grows with the number of columns the motion sweeps.
    case exact
    /// Raise as soon as the desktop base has landed, standing in for each window with whatever still an
    /// earlier cover left behind, and sharpening each layer as its own capture arrives. The head cost is
    /// then one capture whatever the strip looks like — at the price of a window whose content changed
    /// since it was last filmed being briefly wrong.
    case immediate
}

/// Which focus changes emira did not ask for it will honour. Apps move focus to themselves at moments
/// nobody chose — dismissing a floating reminder brings its parked window forward from another
/// workspace — and the strip follows, because a focus emira did not cause is still one it must reveal.
///
/// Three escalating refusals, and the ladder is monotone: `ignore`'s admissions are a subset of
/// `onScreen`'s, which are a subset of `respect`'s. Each buys quiet at the price of a piece of system
/// behaviour, so the choice is how much of macOS's own focus you still need — all of it, clicking what
/// you can see, or none.
///
/// **What none means.** `ignore` still honours focus onto a window emira does not place — a float, a
/// dialog, a sheet. Not an exception grudgingly made: emira already declines an opinion about where a
/// float *sits*, and policing focus onto one is the same opinion. It is also what keeps a modal save
/// sheet usable, since at this layer a sheet taking focus and a Cmd-Tab are the same notification.
public enum SystemFocusEvents: String, Sendable, Equatable, Codable, CaseIterable {
    /// Every focus change is honoured — the strip reveals whatever the system focused.
    case respect
    /// Honoured only if the window is already on the screen. A parked column, another workspace, a
    /// minimized window and a hidden app are all refused, so nothing an app does to itself can move the
    /// viewport or switch workspaces; clicking a window you can see still works, and so does Cmd-Tab
    /// *to* one.
    case onScreen = "on-screen"
    /// Honoured only for windows emira does not place. Focus between tiled windows becomes emira's
    /// alone: Cmd-Tab and a click on a neighbouring window both bounce back.
    case ignore
}

/// The pure configuration values the reducer reads.
public struct Config: Sendable, Equatable, Codable {
    /// The column width presets `cycleWidth` steps through. A column stores an *index* into this
    /// cycle, resolved to points against the monitor at layout time, so a "½" column stays ½ on any
    /// display.
    public var widthPresets: PresetCycle
    /// The window height presets `cycleHeight` steps through, resolved against the *column* height the
    /// same way widths resolve against the content width. The ladder has one more rung than it lists:
    /// **auto**, the default, which shares the column's leftover height with the other autos. Cycling
    /// runs auto → first → … → last → auto, so every selection is reachable and reversible without a
    /// second verb.
    public var heightPresets: PresetCycle
    /// Points between adjacent columns on the strip (inter-column only).
    public var columnGap: Double
    /// Points between vertically-adjacent windows within a column (inter-window only).
    public var windowGap: Double
    /// Points of margin held clear at the edges of the working area. Not a strut, though `struts` is
    /// the same arithmetic: a strut is forbidden ground, while an outer gap is empty at rest and
    /// *crossed in motion*, which is why the cover must not shrink with it. Additive with `struts`
    /// and applied after it, so `outer-gap-top` measures down from the menu bar, not the screen.
    public var outerGaps: EdgeInsets
    /// The reserved region around the working area — menu bar/notch, Dock edge. Top-left origin, so
    /// `top` is the menu-bar edge. A fact about the hardware read off `NSScreen.visibleFrame`, and
    /// deliberately not a config key; a user who wants a margin wants `outerGaps`.
    public var struts: EdgeInsets
    /// The spring driving the viewport-offset scroll, seeding `Motion.viewportOffset`.
    public var scrollSpring: SpringParams
    /// The spring driving a resizing column's resolved width (`Motion.columnWidths`).
    public var resizeSpring: SpringParams
    /// The spring driving a window's displacement when a structural edit rearranges the strip. Unlike
    /// `scrollSpring` it is never copied into a live animator, so a reload takes effect on the next
    /// edit rather than reshaping one in flight.
    public var moveSpring: SpringParams
    /// Whether a focus change centers the focused column or does the minimal scroll that reveals it.
    public var centerFocusedColumn: Bool
    /// Which focus changes emira did not cause it honours. `respect` is every one of them, which is
    /// macOS's own behaviour and the only setting under which an app can move the viewport by itself.
    public var systemFocusEvents: SystemFocusEvents
    /// How a window's captured still is painted into the rect it occupies during a transition. Read
    /// by the compositor, never the reducer — the core's emitted geometry is identical under both,
    /// and the two differ only when a window's rect stops matching the still captured of it.
    public var windowAnimation: WindowAnimation
    /// When a cover may be raised. Read by the capture plane, never the reducer: what changes is when a
    /// window is deemed to *have* pixels, not what the core does once every scoped one does.
    public var coverMode: CoverMode
    /// Whether a scroll animates under a layered cover or simply snaps. Also a capability bit: the
    /// cover is made of captured pixels, so the shell clears this when the Screen Recording grant is
    /// missing, which degrades emira to instant, correct placement rather than a blank rectangle.
    public var smoothTransitions: Bool
    /// Seconds a transition may stay under its cover before the truth is revealed regardless. Read by
    /// the shell's hold timer, not the reducer — the core owns no wall clock.
    public var holdTimeout: Double
    /// The key combinations bound to commands (`[keys]` in the file). Read by the shell's hotkey
    /// source, not the reducer; what reaches the core is `Event.command`, identical to the CLI's.
    /// Empty by default: a window manager must not confiscate a keystroke nobody asked it to.
    public var keys: [KeyBinding]
    /// The rules deciding where a window starts (`[[window-rules]]`), in file order — which is
    /// precedence order, since later matches win (`Rules.swift`). Consulted once per window, when emira
    /// first meets it, so editing this rearranges nothing that is already on screen.
    public var windowRules: [WindowRule]

    public init(
        widthPresets: PresetCycle = .defaultWidths,
        heightPresets: PresetCycle = .defaultHeights,
        columnGap: Double = 0,
        windowGap: Double = 0,
        outerGaps: EdgeInsets = .zero,
        struts: EdgeInsets = .zero,
        scrollSpring: SpringParams = .smooth,
        resizeSpring: SpringParams = .smooth,
        moveSpring: SpringParams = .smooth,
        centerFocusedColumn: Bool = false,
        systemFocusEvents: SystemFocusEvents = .respect,
        windowAnimation: WindowAnimation = .stretch,
        coverMode: CoverMode = .exact,
        smoothTransitions: Bool = true,
        holdTimeout: Double = 1.0,
        keys: [KeyBinding] = [],
        windowRules: [WindowRule] = []
    ) {
        self.widthPresets = widthPresets
        self.heightPresets = heightPresets
        self.columnGap = columnGap
        self.windowGap = windowGap
        self.outerGaps = outerGaps
        self.struts = struts
        self.scrollSpring = scrollSpring
        self.resizeSpring = resizeSpring
        self.moveSpring = moveSpring
        self.centerFocusedColumn = centerFocusedColumn
        self.systemFocusEvents = systemFocusEvents
        self.windowAnimation = windowAnimation
        self.coverMode = coverMode
        self.smoothTransitions = smoothTransitions
        self.holdTimeout = holdTimeout
        self.keys = keys
        self.windowRules = windowRules
    }
}
