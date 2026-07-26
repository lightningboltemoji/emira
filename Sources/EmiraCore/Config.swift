import Foundation
import EmiraMotion

// The configuration **values** the reducer reads. Pure data — no file I/O, no `FSEvents`. Since M5
// part 1 it has a file behind it, in two halves that sit on either side of §1 invariant 1: the
// *parse* is pure and lives next door (`ConfigSyntax.swift`, `Config.parse(_:)`), while *finding,
// reading and watching* `~/.config/emira/emira.toml` is the shell's (`Config/ConfigLoader.swift`),
// which hands the result back as `Event.configChanged`.
//
// **Scope.** The knobs the `Engine` reducer needs to lay out and scroll a single strip: the layout
// metrics (width presets, gaps, struts) and the feel (two springs, centering policy) — plus, since M5
// part 2, the one thing here that the reducer does *not* read: the keybindings, which configure a
// shell event source rather than the layout (see `keys`). The things `Config` still grows to hold —
// window/workspace rules, per-monitor overrides — land with their subsystems. Defaults are chosen so a
// zero-config `Config()`
// lays out a sensible strip, which is also what a *missing* config file produces.
//
// It is `Codable`/`Equatable`/`Sendable` like the rest of `State`, so the whole of `State` dumps to
// JSON (`emira debug`) and round-trips for replay (§7).

/// The pure configuration values the reducer reads. Defaults give a working strip with no
/// gaps, no struts, ⅓/½/⅔ column widths, and a calm scroll — override via the (later) config file.
public struct Config: Sendable, Equatable, Codable {
    /// The column width presets `cycleWidth` steps through.
    /// A column stores an *index* into this cycle; it's resolved to points against the monitor at
    /// layout time (`Presets.swift`), so a "½" column stays ½ on any display.
    public var widthPresets: PresetCycle
    /// Gap between adjacent columns on the strip (inter-column only).
    public var columnGap: Double
    /// Gap between vertically-adjacent windows within a column (inter-window only).
    public var windowGap: Double
    /// The reserved region around the working area — the menu-bar/notch at the top, the Dock edge,
    /// outer margins. The monitor frame is inset by this to get the layout's working area, so tiled
    /// windows never sit under the menu bar or Dock (PRINCIPLES.md §4a). Top-left origin: `top` is
    /// the menu-bar edge.
    public var struts: EdgeInsets
    /// The spring that drives the viewport-offset scroll (the one scalar a strip scroll animates,
    /// PRINCIPLES.md §7). Used to seed `Motion.viewportOffset`.
    public var scrollSpring: SpringParams
    /// The spring that drives a resizing column's *resolved width* — the strip's second animated
    /// quantity (`Motion.columnWidths`, M4 part 3).
    ///
    /// A separate knob from `scrollSpring` because the two motions are not the same experience: a
    /// scroll travels a column's width or more, while a resize covers the *difference* between two
    /// presets and reads slower at identical constants. The default is deliberately the same spring,
    /// so this changes nothing until someone writes it down — it exists to be turned, not to have
    /// been guessed.
    public var resizeSpring: SpringParams
    /// The spring that drives a window's **displacement** when a structural edit rearranges the strip
    /// — `move-window` and `consume-or-expel` (`Motion.windowAnimators`).
    ///
    /// A third knob for the reason there is a second: the motion is a different experience again —
    /// a scroll travels the strip, a resize travels the gap between two presets, and this travels
    /// the gap between two *arrangements*. The default is stiffness 800 / ζ 1.0, the same spring
    /// the other two already carry: copied, not guessed.
    ///
    /// Unlike `scrollSpring` it is never copied into a live animator — it is passed at install time,
    /// exactly as `resizeSpring` is, so a reload takes effect on the next edit rather than reshaping
    /// one already in flight.
    public var moveSpring: SpringParams
    /// Whether a focus change centers the focused column or does the minimal scroll that reveals
    /// it. `false` — minimal reveal — is the default.
    public var centerFocusedColumn: Bool
    /// Whether a scroll animates under a layered cover (PRINCIPLES.md §4b) or simply snaps (§4a).
    ///
    /// **Not a taste knob — a capability bit.** The cover is made of captured pixels, and capture needs
    /// the Screen Recording grant. Without it every still comes back empty and the "smooth" path would
    /// animate an *empty* cover — strictly worse than not covering at all, because the user would watch
    /// a blank rectangle where their desktop was. So the shell reads the grant at boot and sets this,
    /// and a denied grant degrades emira to exactly what §4a calls the thing to ship first: instant,
    /// correct placement. Every window still lands where it should; it just gets there at once.
    ///
    /// It is a `Config` value rather than shell state because *whether a command warrants a transition*
    /// is the core's decision (§3), and the core cannot see a TCC grant. M5's config file gets it too:
    /// "I have the grant and still want snaps" is a legitimate preference.
    public var smoothTransitions: Bool
    /// How long a transition may stay under its cover before the truth is revealed regardless —
    /// IMPLEMENTATION.md §3's "~1 s hold-timeout". A frozen cover is worse than a visibly hung app.
    ///
    /// **The one value here the reducer does not read.** Every other field feeds `Engine.reduce`
    /// directly; this one is a *duration*, and the core owns no wall clock (PRINCIPLES.md §7 — the
    /// shell drives time, the core only ever sees the events time produces). So the shell's hold timer
    /// reads it off `state.config` and arms itself, and the reducer meets the result as
    /// `Event.holdTimeout` like any other input. It lives here anyway because it is unambiguously a
    /// *config* value — a knob a user will want in the TOML at M5 — and splitting config across two
    /// homes by which side of the seam consumes it would be the worse arrangement.
    public var holdTimeout: Double
    /// The key combinations bound to commands (`[keys]` in the file, M5 part 2).
    ///
    /// **The second value the reducer never reads** — `holdTimeout` was the first, and the two are the
    /// same kind of thing for the same reason. A binding is not a fact about the layout; it is the
    /// configuration of an *event source*, and the source lives in the shell (`Input/Hotkeys.swift`)
    /// alongside the socket server and the AX observers. It rides in `Config` anyway because it is
    /// unambiguously a config value — the user writes it in the TOML next to `column-gap` — and
    /// splitting config across two homes by which side of the seam consumes it would be the worse
    /// arrangement. What reaches the core is what a keypress *produces*: `Event.command`, identical to
    /// the one the CLI sends, which is §2's whole point.
    ///
    /// Empty by default: see `ConfigSyntax.swift`'s header for why a window manager must not confiscate
    /// a keystroke nobody asked it to.
    public var keys: [KeyBinding]

    public init(
        widthPresets: PresetCycle = .defaultWidths,
        columnGap: Double = 0,
        windowGap: Double = 0,
        struts: EdgeInsets = .zero,
        scrollSpring: SpringParams = .smooth,
        resizeSpring: SpringParams = .smooth,
        moveSpring: SpringParams = .smooth,
        centerFocusedColumn: Bool = false,
        smoothTransitions: Bool = true,
        holdTimeout: Double = 1.0,
        keys: [KeyBinding] = []
    ) {
        self.widthPresets = widthPresets
        self.columnGap = columnGap
        self.windowGap = windowGap
        self.struts = struts
        self.scrollSpring = scrollSpring
        self.resizeSpring = resizeSpring
        self.moveSpring = moveSpring
        self.centerFocusedColumn = centerFocusedColumn
        self.smoothTransitions = smoothTransitions
        self.holdTimeout = holdTimeout
        self.keys = keys
    }
}
