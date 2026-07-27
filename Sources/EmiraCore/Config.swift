import Foundation
import EmiraMotion

// The configuration values the reducer reads. Pure data: the *parse* is next door
// (`ConfigSyntax.swift`), and finding, reading and watching `~/.config/emira/emira.toml` is the
// shell's, which hands the result back as `Event.configChanged`.
//
// **Lengths are in points; width presets are proportions of the content width.** A zero-config
// `Config()` lays out a sensible strip, which is also what a missing config file produces.

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
    /// How a window's captured still is painted into the rect it occupies during a transition. Read
    /// by the compositor, never the reducer — the core's emitted geometry is identical under both,
    /// and the two differ only when a window's rect stops matching the still captured of it.
    public var windowAnimation: WindowAnimation
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
        windowAnimation: WindowAnimation = .stretch,
        smoothTransitions: Bool = true,
        holdTimeout: Double = 1.0,
        keys: [KeyBinding] = []
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
        self.windowAnimation = windowAnimation
        self.smoothTransitions = smoothTransitions
        self.holdTimeout = holdTimeout
        self.keys = keys
    }
}
