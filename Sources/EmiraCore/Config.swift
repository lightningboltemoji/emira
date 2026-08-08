import Foundation
import EmiraMotion

// The configuration values the reducer reads. Pure data: the *parse* is next door
// (`ConfigSyntax.swift`), and finding, reading and watching `~/.config/emira/emira.toml` is the
// shell's, which hands the result back as `Event.configChanged`.
//
// **Lengths are in points; width presets are proportions of the content width.** A zero-config
// `Config()` lays out a sensible strip, which is also what a missing config file produces.

/// Whether a transition is covered, and whether it animates under the cover — two independent questions
/// on one ladder, `off` ⊂ `snap` ⊂ `smooth` in what each asks of the machine. Both upper rungs ask for the
/// same thing, captured pixels, which is why a missing grant collapses the whole ladder rather than a rung.
public enum TransitionMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// No cover. Windows are placed by AX and arrive when they arrive, which is emira's motion with the
    /// graphics thesis removed — and the honest behaviour with no Screen Recording grant to make it from.
    case off
    /// Cover, with no motion under it: one capture round-trip at the head buys atomicity, the strip being
    /// seen in its two resting states and never in the half-arranged interval between them.
    case snap
    /// Cover, with the springs running under it: the transition emira is for.
    case smooth

    /// Whether a cover is raised at all — the gate on opening a session.
    public var covers: Bool { self != .off }
    /// Whether the quantities a transition moves are put in motion rather than snapped to their targets.
    /// The reducer's question alone — the compositor reads the mode itself, for the exit's length.
    public var animates: Bool { self == .smooth }
}

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

/// Whether focus moving takes the pointer with it, and how insistently.
///
/// **The two middle rungs both refuse, and they refuse on different questions.** `lazy` asks where the
/// pointer *is*; `exceptHover` asks whether the pointer is what *moved focus*. Elsewhere `lazy` is the
/// obvious default: with many small windows, the pointer already being inside the window focus landed on
/// is the *rare* case, so skipping it only avoids the occasional pointless yank. **Here a column is most
/// of the screen**, so "already inside" is the common case and `lazy` is nearly inert — the pointer
/// stays put through almost every focus change.
///
/// Which is why the source question is worth asking separately. `force` is what most people mean by the
/// feature, and it also fires when the *pointer* moved focus: a hover under `[focus] follows-mouse`
/// centres the cursor the user has their hand on, and the only thing that recentring can add is a jump
/// away from the spot they aimed at — the window under it is already the right one. `exceptHover` is
/// `force` with that one source removed, which leaves every focus the *hand was not already on* —
/// Cmd-Tab, a Dock click, an app raising itself, a window arriving — still taking the pointer along.
public enum MouseFollowsFocus: String, Sendable, Equatable, Codable, CaseIterable {
    /// The pointer stays where the user left it.
    case off
    /// Move it only when it is not already inside the window focus landed on.
    case lazy
    /// Centre it in the focused window on every focus change except one the pointer itself caused.
    case exceptHover = "except-hover"
    /// Centre it in the focused window on every focus change.
    case force

    /// Whether a focus change owes the pointer a visit, given whether the *pointer* is what moved it.
    ///
    /// The source is read off the event rather than off `FocusOrigin`, which cannot answer this: a
    /// hovered focus reduces into the same tail `focus(Direction)` does, so its echo comes home marked
    /// `.ours` exactly as a commanded one's does.
    public func warps(pointerCaused: Bool) -> Bool {
        switch self {
        case .off:          return false
        case .exceptHover:  return !pointerCaused
        case .lazy, .force: return true
        }
    }

    /// Whether a pointer already inside the window is moved anyway. Read by the *shell*, off the
    /// config and never off the effect: the position it decides against is only knowable there, and a
    /// rung that changes no emitted geometry belongs beside `[animation] window` rather than in the
    /// effect vocabulary. `exceptHover` centres like `force`: it has already refused on the source, and
    /// refusing a second time on the position would leave the rung doing nothing a plain `lazy` doesn't.
    public var recentres: Bool { self == .force || self == .exceptHover }
}

/// Whether a three-finger trackpad swipe scrolls the strip, and where it comes to rest.
///
/// **Both live modes track the fingers continuously; they differ in one line — where the lift's
/// projection lands.** A scroll that rests anywhere is only meaningful if the fingers were driving
/// position, which is what makes this direct manipulation rather than a recognized swipe firing a
/// `focus right`.
///
/// **`off` is the default, for the reason there are no default keybindings**: a three-finger swipe is a
/// gesture macOS already owns, and turning this on means the user handing it over in System Settings →
/// Trackpad. Taking it uninvited would break the system's own desktop switching on first launch.
///
/// Also a capability bit, the shape `transitionMode` has: the strip follows the hand under a cover made
/// of captured pixels, so the shell clamps this to `off` when there is no cover to run it under.
public enum TrackpadScrollMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// The tap is never installed and emira observes nothing.
    case off
    /// The strip follows the fingers, and on lift settles so that a column edge lies flush with a
    /// viewport edge — the nearest such rest to where the momentum was going.
    case magnet
    /// The strip follows the fingers, and on lift coasts to a stop wherever the momentum runs out.
    case free

    /// Whether the gesture is listened for at all — the shell's install gate, and the reducer's.
    public var isLive: Bool { self != .off }
}

/// Which way a three-finger swipe carries the strip.
///
/// The two conventions macOS itself offers under *Natural scrolling*, on the axis emira keeps. Neither
/// is obviously right and the machine cannot answer it: emira reads raw contacts rather than scroll
/// events, so the system's own inversion is never applied on the way in — which is exactly why this is
/// a setting rather than something derived.
///
/// `standard` is the default because it is what a scrollbar does, and because a user who has not
/// thought about it has not asked emira to invert anything. Anyone whose macOS scrolling is natural —
/// which is macOS's own default, and what its three-finger Space swipe follows — wants the other one.
public enum TrackpadScrollDirection: String, Sendable, Equatable, Codable, CaseIterable {
    /// The viewport follows your fingers: swipe right and the strip travels right, so its content
    /// slides left. What dragging a scrollbar does.
    case standard
    /// The *content* follows your fingers: swipe right and the columns come with you.
    case natural

    /// The sign a swipe's travel takes on its way to points of strip. The whole of the setting —
    /// applied inside the one conversion, so the lift's velocity and its projection flip with it.
    public var sign: Double { self == .natural ? -1 : 1 }
}

/// What the guide draws for each window on the strip, or nothing at all. A ladder like
/// `TransitionMode`'s: each rung asks the machine for strictly more, and the top one asks for the same
/// thing a cover does — captured pixels — at a cost of zero extra captures, since it only keeps what a
/// cover was going to discard.
public enum GuideStyle: String, Sendable, Equatable, Codable, CaseIterable {
    /// No guide. Nothing is drawn, no panel is shown, and no focus ring is ever created.
    case off
    /// A rectangle per window carrying its app's icon — the arrangement, with no window content.
    case placeholder
    /// The window's own last still where there is one, the icon placeholder where there isn't.
    case preview
}

/// Which corner or edge of the working area the guide sits at. Nine anchors rather than four corners:
/// the guide is a wide, short ribbon, so the edge midpoints are as natural a resting place as a corner.
public enum GuidePosition: String, Sendable, Equatable, Codable, CaseIterable {
    case topLeft = "top-left", topCenter = "top-center", topRight = "top-right"
    case centerLeft = "center-left", center, centerRight = "center-right"
    case bottomLeft = "bottom-left", bottomCenter = "bottom-center", bottomRight = "bottom-right"

    /// Where along each axis, as a fraction of the free space: 0 is the leading edge, 1 the trailing.
    public var fractions: (x: Double, y: Double) {
        switch self {
        case .topLeft:      return (0, 0)
        case .topCenter:    return (0.5, 0)
        case .topRight:     return (1, 0)
        case .centerLeft:   return (0, 0.5)
        case .center:       return (0.5, 0.5)
        case .centerRight:  return (1, 0.5)
        case .bottomLeft:   return (0, 1)
        case .bottomCenter: return (0.5, 1)
        case .bottomRight:  return (1, 1)
        }
    }
}

/// The guide's settings. Pure data, read by the shell — the reducer reads exactly one field of it,
/// `style != .off`, which decides whether a focus ring is created at all; the other five never enter
/// `reduce`, so no setting here can change a frame of emitted geometry.
public struct GuideSettings: Sendable, Equatable, Codable {
    /// What the guide draws for each window, or off.
    public var style: GuideStyle
    /// Which corner or edge of the working area it sits at.
    public var position: GuidePosition
    /// How wide the guide is when it is showing its full `span`, as a fraction of the working width. A
    /// shorter strip draws a proportionally narrower ribbon. Its *height* is derived, never configured
    /// — the ribbon is exactly as tall as one desktop at the scale `width`/`span` implies.
    public var width: Double
    /// The most screens of strip the guide shows at once — a ceiling, not a frame. A strip shorter than
    /// this is drawn whole and the guide shrinks to it; a longer one is followed, the viewport
    /// indicator travelling to either end rather than the guide's middle standing in for the screen.
    public var span: Double
    /// Points held clear between the guide and the working area's edge.
    public var gap: Double
    /// Seconds the guide stays up after the last thing that moved.
    public var duration: Double

    public init(style: GuideStyle = .off, position: GuidePosition = .topRight, width: Double = 0.2,
                span: Double = 3, gap: Double = 24, duration: Double = 0.7) {
        self.style = style
        self.position = position
        self.width = width
        self.span = span
        self.gap = gap
        self.duration = duration
    }

    /// The projection's whole scale factor: guide points per strip point, and the only number the
    /// geometry needs. Clamped so the ribbon is never wider or taller than one working area — the
    /// schema's bounds are floors only, so an over-wide `width` or an under-one `span` is stopped here
    /// by the geometry rather than refused by the parser. A stop, not a reversal.
    public var scale: Double {
        guard span > 0 else { return 0 }
        return min(min(width, 1) / span, 1)
    }
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
    /// Points of margin held clear at the edges of the working area. Not a strut, though
    /// `MonitorState.struts` is the same arithmetic: a strut is forbidden ground, while an outer gap is
    /// empty at rest and *crossed in motion*, which is why the cover must not shrink with it. Additive
    /// with the struts and applied after them, so `outer-gap-top` measures down from the menu bar,
    /// not the screen.
    public var outerGaps: EdgeInsets
    /// The spring driving the viewport-offset scroll, seeding `Motion.viewportOffset`.
    public var scrollSpring: SpringParams
    /// The spring driving a resizing column's resolved width (`Motion.columnWidths`).
    public var resizeSpring: SpringParams
    /// The spring driving a window's displacement when a structural edit rearranges the strip. Unlike
    /// `scrollSpring` it is never copied into a live animator, so a reload takes effect on the next
    /// edit rather than reshaping one in flight.
    public var moveSpring: SpringParams
    /// The spring a trackpad scroll coasts under after the fingers lift. Its `1/ω` **is** the throw
    /// horizon, since a lift aims at `current + v/ω`. It shapes `free` alone: `magnet` uses the
    /// projection only to choose a column edge, and travels under `scrollSpring`.
    public var glideSpring: SpringParams
    /// Whether a focus change centers the focused column or does the minimal scroll that reveals it.
    public var centerFocusedColumn: Bool
    /// Whether `grow` and `shrink` catch where the columns on screen sit flush with the viewport, a
    /// second press pushing past. Nothing is remembered between presses: being *in* the notch is what
    /// the second press reads, so the geometry carries the intent the way a stored flag would.
    public var resizeDetent: Bool
    /// Whether a window resized by its own handle keeps the size it was left at. Off, the layout is
    /// inviolable and the window is taken back on release — which is also what a *move* drag gets
    /// either way, since the strip has no way to read one as an instruction yet.
    public var interactiveResize: Bool
    /// Which focus changes emira did not cause it honours. `respect` is every one of them, which is
    /// macOS's own behaviour and the only setting under which an app can move the viewport by itself.
    public var systemFocusEvents: SystemFocusEvents
    /// Whether the pointer crossing into a window focuses it. Beside `systemFocusEvents` because it is
    /// another source of focus changes — and unlike every other window manager's version of this, here
    /// focus *scrolls*, so the shell fires it on pointer motion alone and never on window motion.
    public var focusFollowsMouse: Bool
    /// How a window's captured still is painted into the rect it occupies during a transition. Read
    /// by the compositor, never the reducer — the core's emitted geometry is identical under both,
    /// and the two differ only when a window's rect stops matching the still captured of it.
    public var windowAnimation: WindowAnimation
    /// When a cover may be raised. Read by the capture plane, never the reducer: what changes is when a
    /// window is deemed to *have* pixels, not what the core does once every scoped one does.
    public var coverMode: CoverMode
    /// Whether a transition covers, and whether it animates under the cover. Also a capability bit: the
    /// cover is made of captured pixels, so the shell clamps this to `off` when the Screen Recording
    /// grant is missing, which degrades emira to instant, correct placement rather than a blank rectangle.
    public var transitionMode: TransitionMode
    /// Seconds a transition may stay under its cover before the truth is revealed regardless. Read by
    /// the shell's hold timer, not the reducer — the core owns no wall clock.
    public var holdTimeout: Double
    /// Whether a command that *did something* hides the pointer until the mouse next moves — any
    /// command that emitted an effect, deliberately including `exec`, which moves no window: the rule
    /// is about the hand being on the keyboard rather than about the desktop being rearranged, and a
    /// keybind that opens a terminal is as much the one as the other. What it excludes is a command
    /// that changed nothing, which would cost a mouse jiggle for a keystroke that did nothing at all.
    ///
    /// Also a capability bit, the shape `transitionMode` has: hiding the cursor from a background
    /// process is reachable only by private property and only while the motion that ends it can be
    /// seen, so the shell clamps this to `false` when either is missing.
    public var hidesCursor: Bool
    /// Whether focus moving takes the pointer with it, and how insistently. Not a capability — warping
    /// is public API and works from a background process — so nothing clamps this.
    public var mouseFollowsFocus: MouseFollowsFocus
    /// Whether a three-finger swipe scrolls the strip, and where it comes to rest. A capability bit
    /// like `transitionMode`: the strip follows the hand under a cover, so the shell clamps this to
    /// `off` with no cover to make and with no tap to listen through.
    public var trackpadScroll: TrackpadScrollMode
    /// Which way that swipe carries the strip. Not a capability — nothing can clamp a sign — and read
    /// only where normalized travel becomes points, which is the one conversion the gesture has.
    public var trackpadScrollDirection: TrackpadScrollDirection
    /// The transient minimap of the strip. The reducer reads `style != .off` and nothing else: that one
    /// bit decides whether a focus change seeds `Motion.focusRing`, and the rest is the shell's.
    public var guide: GuideSettings
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
        scrollSpring: SpringParams = .smooth,
        resizeSpring: SpringParams = .smooth,
        moveSpring: SpringParams = .smooth,
        // ω = 10, a 100 ms throw horizon: solved so that a glide settles inside `holdTimeout` at any
        // flick speed, since a deadline firing under one still travelling reveals a truth plane the
        // layers have not reached. Spelled as stiffness for `.smooth`'s reason.
        glideSpring: SpringParams = SpringParams(stiffness: 100, dampingRatio: 1),
        centerFocusedColumn: Bool = false,
        resizeDetent: Bool = false,
        interactiveResize: Bool = true,
        systemFocusEvents: SystemFocusEvents = .respect,
        focusFollowsMouse: Bool = false,
        windowAnimation: WindowAnimation = .stretch,
        coverMode: CoverMode = .exact,
        transitionMode: TransitionMode = .smooth,
        holdTimeout: Double = 1.0,
        hidesCursor: Bool = false,
        mouseFollowsFocus: MouseFollowsFocus = .off,
        trackpadScroll: TrackpadScrollMode = .off,
        trackpadScrollDirection: TrackpadScrollDirection = .standard,
        guide: GuideSettings = GuideSettings(),
        keys: [KeyBinding] = [],
        windowRules: [WindowRule] = []
    ) {
        self.widthPresets = widthPresets
        self.heightPresets = heightPresets
        self.columnGap = columnGap
        self.windowGap = windowGap
        self.outerGaps = outerGaps
        self.scrollSpring = scrollSpring
        self.resizeSpring = resizeSpring
        self.moveSpring = moveSpring
        self.glideSpring = glideSpring
        self.centerFocusedColumn = centerFocusedColumn
        self.resizeDetent = resizeDetent
        self.interactiveResize = interactiveResize
        self.systemFocusEvents = systemFocusEvents
        self.focusFollowsMouse = focusFollowsMouse
        self.windowAnimation = windowAnimation
        self.coverMode = coverMode
        self.transitionMode = transitionMode
        self.holdTimeout = holdTimeout
        self.hidesCursor = hidesCursor
        self.mouseFollowsFocus = mouseFollowsFocus
        self.trackpadScroll = trackpadScroll
        self.trackpadScrollDirection = trackpadScrollDirection
        self.guide = guide
        self.keys = keys
        self.windowRules = windowRules
    }
}

// The `Config → LayoutMetrics` mapping, here rather than beside `LayoutMetrics`: layout is geometry and
// takes numbers, so `Layout.swift` naming `Config` would point the dependency the wrong way.
//
// Five of the nine inputs are the file's; the other four are the running desktop's, and default to
// empty. That is not a stub — a caller with no world has no correction to apply and nothing parked, so
// the empty is the honest answer rather than a placeholder for one.

extension LayoutMetrics {
    /// The metrics `config` asks for on a display whose working area is `workingArea`.
    ///
    /// The one place the file's geometry becomes the layout's, so a second caller cannot form a second
    /// opinion of what `column-gap` means.
    public init(config: Config,
                workingArea: Rect,
                heightSelections: [WindowId: Int] = [:],
                heightOverrides: [WindowId: PresetSize] = [:],
                corrections: [WindowId: SizeCorrection] = [:],
                parkFloors: [WindowId: Double] = [:]) {
        self.init(workingArea: workingArea,
                  widthPresets: config.widthPresets,
                  heightPresets: config.heightPresets,
                  heightSelections: heightSelections,
                  heightOverrides: heightOverrides,
                  columnGap: config.columnGap,
                  windowGap: config.windowGap,
                  outerGaps: config.outerGaps,
                  corrections: corrections,
                  parkFloors: parkFloors)
    }
}
