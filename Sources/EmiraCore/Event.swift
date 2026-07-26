import Foundation

// The exhaustive *input* vocabulary — everything that can reach the reducer
// (IMPLEMENTATION.md §1 diagram, §5). `reduce(State, Event) -> (State, [Effect])` is **total** over
// this enum: a command, a display tick, an app-launched notification, a vanished window, a timed-out
// AX set — all are just `Event`s, so a hung app or a disappearing window is a normal state
// transition, not a crash (§1 invariant 3).
//
// The design payoff (§7): because the core is a pure function of `Event`, logging every inbound
// `Event` and replaying the log through a fresh `Engine` reproduces any state exactly — bug repro
// from a user session, golden regression fixtures, offline debugging with zero macOS involved. So
// `Event` is **`Codable`** (it *is* the replay log) and **`Equatable`** (scenario tests assert the
// exact event a surface produced).
//
// `Event` grows as milestones land (trackpad gestures at M7); this is the M1–M5 set — commands, the
// frame clock, truth-plane observations, config reloads, effect feedback, and display hotplug.
// Deferred cases are noted at the bottom so the next session knows they're intentional gaps, not
// omissions.

/// One input to the reducer. Grouped by source: commands & the clock, truth-plane observations,
/// effect feedback, and display hotplug.
public enum Event: Sendable, Equatable, Codable {

    // MARK: Commands & the frame clock

    /// A command from any surface — CLI, hotkey, or config binding — all of which build the same
    /// `Command` (§2) and hand it to the core identically.
    case command(Command)

    /// A display-link frame. The core advances every animator by `dt` seconds and emits
    /// `setLayerFrame` intents (it owns animation time — PRINCIPLES.md §7). Emitted **only while a
    /// transition session is open**; idle steady state produces no ticks.
    case tick(dt: Double)

    // MARK: Truth-plane observations (AX + `NSWorkspace`) — reality folded into `World`

    /// A new manageable window appeared. The shell's `WindowRegistry` has already minted its
    /// `WindowId` and bound it to a `CGWindowID` at first sight (§7); the `WindowSnapshot` carries
    /// the metadata the rules engine and initial placement need.
    case windowCreated(WindowSnapshot)

    /// A window went away (closed, or its app quit). The core removes it from the strip and re-tiles.
    case windowDestroyed(WindowId)

    /// A window's frame changed **externally** — most often the user dragging or resizing it. The
    /// core notes the drift; a tiled window re-asserts its layout on `dragEnded`.
    ///
    /// Also carries a *parked* landing that drifted. A park is a near-off-screen position, and an app's
    /// answer there is not an answer about the window (PRINCIPLES.md §10: a window at its 1 px sliver
    /// refused a resize it accepted the moment it scrolled back into view), so a park records truth and
    /// teaches nothing. A drifted **tiled** landing is `placementCorrected` instead.
    case windowFrameChanged(WindowId, Rect)

    /// Keyboard focus moved to a window, or left every managed window (`nil`). Covers both our own
    /// focus commands *and* externally-initiated focus (Cmd-Tab, a Dock click, an app self-activating
    /// — the shell's observation source collapses `NSWorkspace` activation into this same event). When the
    /// focused window isn't in the viewport the core **snaps** to reveal it (PRINCIPLES.md §4a) — we
    /// made no motion, so we owe no animation.
    case focusChanged(WindowId?)

    /// A window was minimized. Per the 2026-07-23 decision it **leaves the strip** — animated out
    /// like a close, its strip position remembered for re-insertion.
    case windowMinimized(WindowId)

    /// A minimized window was restored — re-inserted at its remembered strip position.
    case windowDeminimized(WindowId)

    /// A global mouse-up fired (observed via the AX grant). Marks the end of a possible drag: a tiled
    /// window that drifted from its target re-tiles on release. Parameterless — the core already
    /// knows which window drifted from prior `windowFrameChanged` events.
    case dragEnded

    // MARK: Configuration

    /// The config file was (re-)read and parsed successfully — the shell's `ConfigLoader` answering
    /// either the user saving the file or an `Effect.reloadConfig`. The core adopts the values and
    /// **re-lays-out in place**: new gaps, presets and struts resolve to new frames, and the scroll
    /// spring is re-seeded so the next transition uses the new feel.
    ///
    /// Only *successful* parses reach the core. A file with a syntax error produces a diagnostic in
    /// the daemon's log and no event at all, because the alternative — half a config, or a silent
    /// fall back to defaults — would rearrange the user's desktop as a side effect of a typo.
    case configChanged(Config)

    // MARK: Display hotplug

    /// The set of displays changed (connect, disconnect, resolution/arrangement change). Carries the
    /// full current monitor set in enumeration order (so `MonitorRef.index`/`.next` resolve
    /// consistently); the core reconciles per-monitor strips against it.
    case screensChanged([MonitorInfo])

    // MARK: Effect feedback — every effect's result is just another event (§1 invariant 3)

    /// A `setFrame`/`park` completed: the real window has arrived at its AX target. The scoped,
    /// bounded wait on these is what closes a transition (§3).
    case axLanded(WindowId)

    /// A **tiled** `setFrame` landed at a size other than the one it asked for — the app had an
    /// opinion (a minimum size, a character-cell grid) and imposed it. Distinct from
    /// `windowFrameChanged` because the two are different facts: that one means "reality drifted,
    /// cause unknown", and only *this* one is evidence about what the window will accept, because only
    /// this one knows the question. `requested` is what we set; `actual` is where it ended up.
    ///
    /// The core records the truth either way and, when the request is still the one the layout would
    /// send, remembers the answer (`World.corrections`) so the column can be made the width the app
    /// insists on instead of overlapping its neighbour — and so we stop asking a question we have the
    /// answer to. A *refused* write is `axFailed`, not this: here the write happened.
    case placementCorrected(WindowId, requested: Rect, actual: Rect)

    /// A `setFrame`/`park` was refused or timed out — the *app* said no. The core reconciles (retry,
    /// or drop the window from layout) — a normal transition, not an exception. A window that accepted
    /// the set and landed elsewhere is `windowFrameChanged` + `axLanded` instead, not this (see
    /// `Effect.setFrame`); this case is reserved for the write not happening at all.
    case axFailed(WindowId)

    /// A `capture(win)` produced a still (now in the shell's image cache). When every window a
    /// transition needs has reported ready, the core opens the cover (`beginTransition`) — or, if the
    /// cover is already up and these stills are an extension's, grows it (`extendCover`).
    case captureReady(WindowId)

    /// The capture plane could not produce a cover at all — the batch that owed the *desktop base*
    /// came back without one (the grant lapsed mid-session, ScreenCaptureKit failed, or the deadline
    /// fired). Arrives **instead of** that batch's `captureReady` acks, so the core never counts down
    /// to a raise it has no pixels for.
    ///
    /// This case exists because the alternative is not a degraded cover, it is a **black screen**: the
    /// base is what makes the reconstruction opaque, and an overlay raised without one shows its own
    /// backing fill over the whole display for the length of the transition. The honest response is no
    /// cover — abandon the session before a single real window has moved and snap (§4a), which is
    /// exactly the degradation a machine with no Screen Recording grant already gets.
    case coverUnavailable

    /// The `endTransition` cross-fade finished; the cover is down and steady state resumes.
    case crossfadeDone

    /// The transition hold-timeout (~1 s, §3) fired: close the session regardless — reveal the truth
    /// and keep reconciling any AX set that hasn't landed. A frozen cover is worse than a visibly
    /// hung app. Itself just an event, scheduled by the shell when the transition opened.
    case holdTimeout
}

/// The first-sight observation of a window — the metadata the shell hands the core when a window
/// appears (`Event.windowCreated`). Deliberately **not** the core's internal window model (that's
/// `World`, next iteration): it's the boundary payload the rules engine (§6) evaluates and initial
/// placement reads.
///
/// Note what it *doesn't* carry: no `AXUIElement`, no `CGImage`, no pid. Identity is the core-minted
/// `WindowId` (the shell keeps the private pid/`AXUIElement`/`CGWindowID` binding to itself, §7);
/// app identity for rules is the stable `bundleId`, not the ephemeral pid.
public struct WindowSnapshot: Sendable, Equatable, Codable {
    /// The core-minted id, already bound to a `CGWindowID` by the shell's `WindowRegistry`.
    public let id: WindowId
    /// The owning app's bundle identifier (e.g. `"com.google.Chrome"`) — the stable key window rules
    /// match on. Stable across launches, unlike a pid.
    public let bundleId: String
    /// The window title at first sight. Rules may match it, but it's **unstable** (apps rewrite it),
    /// so it is never used for identity after binding (§7).
    public let title: String
    /// The window's role in the tiling taxonomy (§6). Only `.standard` tiles.
    public let role: WindowRole
    /// The window's frame at first sight, in top-left virtual-strip coordinates (Y already flipped by
    /// the shell). Used for identity binding at a moment of uniqueness and for initial placement.
    public let frame: Rect
    /// Whether the window is *already* minimized when we first see it.
    ///
    /// Almost always `false` — a window we watch appear is on screen. It matters for the one case
    /// that isn't a birth: **launch enumeration** (`AXEnumerator`, M3), which meets every window
    /// mid-life, some of them in the Dock. Recording that faithfully is the difference between the
    /// core knowing a window exists but is off the strip (2026-07-23: minimize *leaves* the strip) and
    /// the core trying to tile something the user can't see. Defaulted, so every "a window was born"
    /// call site stays a four-argument one.
    public let isMinimized: Bool

    public init(
        id: WindowId, bundleId: String, title: String, role: WindowRole,
        frame: Rect, isMinimized: Bool = false
    ) {
        self.id = id
        self.bundleId = bundleId
        self.title = title
        self.role = role
        self.frame = frame
        self.isMinimized = isMinimized
    }
}

/// A window's role in the tiling taxonomy (IMPLEMENTATION.md §6, built-in defaults). The shell maps
/// the AX subrole (`kAXSubroleAttribute`) into one of these at its boundary, so the pure rules engine
/// classifies against a clean enum rather than stringly-typed AX constants.
///
/// The taxonomy is simple by charter: **only `.standard` tiles**; everything else floats. A window
/// rule in config can still override this per app/title.
public enum WindowRole: String, Sendable, Codable, CaseIterable, Equatable {
    /// `AXStandardWindow` — an ordinary document/app window. The only role that joins the strip.
    case standard
    /// A modal or modeless dialog.
    case dialog
    /// A document-attached sheet.
    case sheet
    /// A utility/inspector panel.
    case panel
    /// A transient popover.
    case popover
    /// Anything else — floats by default.
    case other

    /// Whether a window of this role joins the tiled strip. Pure predicate the rules engine reads;
    /// `true` for `.standard` only, per the §6 defaults.
    public var tiles: Bool { self == .standard }
}

/// A display in the current hardware set (`Event.screensChanged`). The boundary payload for
/// per-monitor strips (§6, M6): the core keys a strip per `MonitorId` and lays it out inside `frame`.
/// Backing scale, color space, and other fidelity concerns stay shell-side (the reconstruction, §6) —
/// core geometry is scale-independent points.
public struct MonitorInfo: Sendable, Equatable, Codable {
    /// The shell-minted display id (from display enumeration).
    public let id: MonitorId
    /// The display's full bounds in top-left virtual-strip coordinates. Struts (menu bar/notch) are
    /// applied by the layout engine, not baked in here.
    public let frame: Rect

    public init(id: MonitorId, frame: Rect) {
        self.id = id
        self.frame = frame
    }
}

// MARK: - Deferred cases (intentional gaps, land with their milestone)
//
//  · trackpad gesture events   — continuous scroll opens the same transition session driven by the
//                                finger instead of a spring (§4c, M7).
//  · app-level hide/unhide     — Cmd-H hides *all* of an app's windows at once; modeling it cleanly
//                                needs `World`'s app grouping (next iteration). Window-level
//                                `windowMinimized`/`Deminimized` are here; app hide follows.
