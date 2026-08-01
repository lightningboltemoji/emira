import Foundation

// The exhaustive input vocabulary — everything that can reach the reducer, which is total over this
// enum, so a hung app or a vanished window is a normal transition rather than a crash. The log of
// inbound events *is* the replay log, which is why this is `Codable`.

/// One input to the reducer, grouped below by source.
public enum Event: Sendable, Equatable, Codable {

    // MARK: Commands & the frame clock

    /// A command from any surface — CLI, hotkey, or config binding.
    case command(Command)

    /// A display-link frame; every animator advances by `dt` seconds. Only emitted mid-transition.
    case tick(dt: Double)

    // MARK: Truth-plane observations (AX + `NSWorkspace`) — reality folded into `World`

    /// A new manageable window appeared, its `WindowId` already minted and bound to a `CGWindowID`.
    case windowCreated(WindowSnapshot)

    /// A window went away (closed, or its app quit). The core removes it from the strip and re-tiles.
    case windowDestroyed(WindowId)

    /// A window's frame changed externally — most often a user drag or resize; a tiled window re-asserts
    /// its layout on `dragEnded`. A drifted landing of our own is not this: it is `placementCorrected`
    /// when tiled and `parkCorrected` when parked, both of which know what was asked for.
    case windowFrameChanged(WindowId, Rect)

    /// Keyboard focus moved to a window, or left every managed window (`nil`). Covers our own focus
    /// commands *and* external ones — Cmd-Tab, a Dock click. The core reveals it under a cover, exactly as
    /// `focus left` and `focus-workspace` do: a reveal is a move of the strip whoever asked for it.
    /// `origin` is what `[focus] system-events` judges.
    case focusChanged(WindowId?, origin: FocusOrigin)

    /// A window was minimized: it leaves the strip, animated out like a close, its position remembered.
    case windowMinimized(WindowId)

    /// A minimized window was restored — re-inserted at its remembered strip position.
    case windowDeminimized(WindowId)

    /// A global mouse-up: the end of a possible drag, on which a drifted tiled window re-tiles.
    case dragEnded

    // MARK: Configuration

    /// The config file parsed successfully; the core adopts the values and re-lays out in place. Only
    /// successful parses reach the core — a syntax error logs a diagnostic and emits nothing.
    case configChanged(Config)

    // MARK: Display hotplug

    /// The set of displays changed. Carries the full monitor set in system enumeration order, which
    /// decides which display the strip is laid out against (`State.metrics()` takes the first).
    case screensChanged([MonitorInfo])

    // MARK: Effect feedback — every effect's result is just another event

    /// A `setFrame`/`park` landed at its AX target. The bounded wait on these is what closes a transition.
    case axLanded(WindowId)

    /// A *tiled* `setFrame` landed at a size other than the one asked for — the app imposed a minimum
    /// size or a character-cell grid. Unlike `windowFrameChanged`, this one knows the question, so it is
    /// evidence: the core records it in `World.corrections` and widens the column instead of overlapping
    /// its neighbour.
    case placementCorrected(WindowId, requested: Rect, actual: Rect)

    /// A `park` landed showing more of its window than the slot asked for — the app refuses to keep less
    /// than that much of itself on screen. Evidence about the *nub*, and only about the nub: the core
    /// records the chrome in `World.parkFloors` and allocates a taller slot, rather than re-asking for a
    /// slot the app has already declined on every placement pass. A park says nothing about *size*
    /// (`Effect.park`), so this is not a `placementCorrected` and never becomes a `SizeCorrection`.
    case parkCorrected(WindowId, requested: Rect, actual: Rect)

    /// A `setFrame`/`park` was refused or timed out — the write did not happen at all.
    case axFailed(WindowId)

    /// A `capture(win)` produced pixels the cover can be built from — the window's own still, or, under
    /// `CoverMode.immediate`, one kept from an earlier cover standing in for it. Once every window a
    /// transition needs has reported ready, the core raises the cover (`beginTransition`) or grows an
    /// already-raised one (`extendCover`).
    case captureReady(WindowId)

    /// The window's *own* still has landed for a window the cover is standing in for. Only
    /// `CoverMode.immediate` produces one, and it settles nothing: the transition's gates were paid at
    /// `captureReady`, so this asks for a content swap and changes no geometry.
    case captureRefreshed(WindowId)

    /// The capture plane could not produce a cover at all. Arrives *instead of* that batch's
    /// `captureReady` acks, so the core never counts down to a raise it has no pixels for.
    case coverUnavailable

    /// The `endTransition` cross-fade finished; the cover is down and steady state resumes.
    case crossfadeDone

    /// The transition hold-timeout fired: close the session regardless, and keep reconciling.
    case holdTimeout
}

/// Who moved focus — the one thing a focus report does not say about itself, and the only fact
/// `[focus] system-events` needs to judge one. The shell already separates the two to recognise its own
/// echo (`FocusIntent`); this carries that answer the rest of the way.
public enum FocusOrigin: String, Sendable, Equatable, Codable, CaseIterable {
    /// The echo of an `Effect.focus` the core asked for. Never refused, whatever the policy: the
    /// reducer wrote that focus optimistically when it emitted the effect, so refusing it would make
    /// every command that moves focus fight itself.
    case ours
    /// Nobody here asked for this — Cmd-Tab, a Dock click, a click on a window, an app raising itself.
    case system
}

/// The first-sight observation of a window — the boundary payload the shell hands the core, not the
/// core's internal window model (that's `World`). Carries no `AXUIElement`, no `CGImage`, no pid.
public struct WindowSnapshot: Sendable, Equatable, Codable {
    /// The core-minted id, already bound to a `CGWindowID` by the shell's `WindowRegistry`.
    public let id: WindowId
    /// The owning app's bundle identifier — the stable key window rules match on, unlike a pid.
    public let bundleId: String
    /// The title at first sight. Rules may match it, but it is unstable and never used for identity.
    public let title: String
    /// The window's role in the tiling taxonomy. Only `.standard` tiles.
    public let role: WindowRole
    /// The frame at first sight, in top-left virtual-strip coordinates (Y already flipped by the
    /// shell). Used for identity binding at a moment of uniqueness and for initial placement.
    public let frame: Rect
    /// Whether the window was *already* minimized when first seen — only possible for the launch scan.
    public let isMinimized: Bool

    /// Whether emira met this window already open rather than watching it appear — true for exactly the
    /// launch scan's adoptions. No layout survives a restart, so an adopted window's column is seeded
    /// with the width it already has.
    public let wasAlreadyOpen: Bool

    public init(
        id: WindowId, bundleId: String, title: String, role: WindowRole,
        frame: Rect, isMinimized: Bool = false, wasAlreadyOpen: Bool = false
    ) {
        self.id = id
        self.bundleId = bundleId
        self.title = title
        self.role = role
        self.frame = frame
        self.isMinimized = isMinimized
        self.wasAlreadyOpen = wasAlreadyOpen
    }

    /// This observation, marked as a window emira met already open.
    public func metAlreadyOpen() -> WindowSnapshot {
        WindowSnapshot(id: id, bundleId: bundleId, title: title, role: role,
                       frame: frame, isMinimized: isMinimized, wasAlreadyOpen: true)
    }
}

/// A window's role in the tiling taxonomy — the shell maps the AX subrole into one of these at its
/// boundary. Only `.standard` tiles; everything else floats, subject to per-app/title config rules.
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

    /// Whether a window of this role joins the tiled strip.
    public var tiles: Bool { self == .standard }
}

/// A display in the current hardware set — the core keys a strip per `MonitorId` and lays it out
/// inside `frame`. Backing scale and colour space stay shell-side.
public struct MonitorInfo: Sendable, Equatable, Codable {
    /// The shell-minted display id (from display enumeration).
    public let id: MonitorId
    /// The display's full bounds in top-left coordinates. Struts are applied by the layout engine.
    public let frame: Rect

    public init(id: MonitorId, frame: Rect) {
        self.id = id
        self.frame = frame
    }
}

