import Foundation

// The command vocabulary — the *one* list of "things you can ask emira to do" (IMPLEMENTATION.md §2).
//
// This type is defined once, here in the pure core, and reused by every surface so a new verb is
// added in exactly one place:
//
//   · the CLI parses `argv` into a `Command` and sends it over the socket;
//   · the hotkey manager maps a key combo to a `Command`;
//   · the config file binds keys and window-rules to `Command`s;
//   · the wire protocol is `Command` (Codable) inside `EmiraProtocol`'s envelope;
//   · the core consumes it as `Event.command(Command)`.
//
// Keeping it in `EmiraCore` (not the protocol layer) means the reducer, the tests, and the CLI all
// speak the same type with no translation — `EmiraProtocol` only *wraps* it for the wire.
//
// Everything here is a pure `Codable` value type: no framework, no ids the user can't name. The
// small supporting enums (`Direction`, `Axis`, `Toggle`, `WorkspaceRef`, `MonitorRef`) live
// alongside `Command` because they exist to spell it.

/// The four cardinal directions on the strip. Left/right run **along the ribbon** (between
/// columns); up/down run **within a column** (between the windows stacked in it). Used by
/// `focus`, `moveWindow`, and `consumeOrExpel`, whose meaning turns on the axis.
public enum Direction: String, Sendable, Codable, CaseIterable, Equatable {
    case left, right, up, down

    /// The reversed direction — `left↔right`, `up↔down`. Handy for symmetric reducer logic
    /// (expel is consume in the opposite sense, an undo retraces the move, …).
    public var opposite: Direction {
        switch self {
        case .left: return .right
        case .right: return .left
        case .up: return .down
        case .down: return .up
        }
    }

    /// Which axis this direction travels. Left/right are horizontal (across columns); up/down are
    /// vertical (within a column). The strip scroll only ever responds to the horizontal axis.
    public var axis: Axis {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }
}

/// The two axes of the layout: horizontal is the infinite ribbon of columns; vertical is the stack
/// of windows inside one column.
public enum Axis: String, Sendable, Codable, CaseIterable, Equatable {
    case horizontal, vertical
}

/// A boolean command that can be forced on/off or flipped — for `fullscreen` and `float`, which
/// are stateful toggles. `.toggle` is the usual keybind; `.on`/`.off` let a script or rule assert
/// an absolute state without knowing the current one.
public enum Toggle: String, Sendable, Codable, CaseIterable, Equatable {
    case on, off, toggle

    /// Resolve against the present state: `on`→true, `off`→false, `toggle`→the negation. Pure, so
    /// the reducer applies a `Toggle` with no branching of its own.
    public func resolved(current: Bool) -> Bool {
        switch self {
        case .on: return true
        case .off: return false
        case .toggle: return !current
        }
    }
}

/// How much to change a size by — the argument to `grow` / `shrink`. Always a *magnitude*: the verb
/// carries the sign, so there is no such thing as a negative delta and `grow -10%` is a syntax error
/// rather than a second spelling of `shrink 10%`.
///
/// **A percentage is of the monitor's working extent, not of the current size** (settled 2026-07-26).
/// The alternative — a factor on the column's own width — compounds, so its step size drifts with
/// every press and `grow 10%` followed by `shrink 10%` loses 1% instead of landing back where it
/// started. Against the working width the steps are uniform and the two verbs are exact inverses,
/// which is also the only reading that composes with the ⅓/½/⅔ presets (`PresetSize.proportion`),
/// since those are proportions of the same extent.
///
/// Distinct from `PresetSize` despite the identical arithmetic: that type is an absolute size *intent*
/// ("be half the screen"), this one is a *change* ("be 10 points of screen wider"). A `grow` resolves
/// one into the other, which is precisely why they are not the same type.
public enum SizeDelta: Sendable, Codable, Equatable {
    /// An absolute number of points (`grow 100px`). Points, not device pixels — the unit everything in
    /// the core speaks; `px` is accepted as its spelling because it is what people type.
    case points(Double)
    /// A percentage of the working extent (`grow 10%` on an 1800 pt-wide working area is 180 pt),
    /// spelled as a percentage rather than a fraction because that is how the user writes it.
    case percent(Double)

    /// This delta in points, against the working extent a percentage is measured on.
    public func resolved(available: Double) -> Double {
        switch self {
        case .points(let points): return points
        case .percent(let percent): return available * percent / 100
        }
    }
}

/// A user-facing way to name a workspace. Workspaces are **dynamic and per-monitor**, stacked
/// vertically, so the user names one either absolutely by position or relative to the
/// focused one. Deliberately *not* a `WorkspaceId` — the internal id is minted by the core and
/// isn't something a keybind or CLI arg can spell; the shell resolves a `WorkspaceRef` to an id.
public enum WorkspaceRef: Sendable, Codable, Equatable {
    /// 1-based position among the focused monitor's workspaces.
    case index(Int)
    /// The next workspace down (dynamic: creates a fresh empty one past the end).
    case next
    /// The previous workspace up.
    case previous
}

/// A user-facing way to name a monitor — by spatial direction from the focused one, by absolute
/// position, or relatively. Mirrors AeroSpace's `--focus-monitor (left|right|…|next|prev|N)`. Like
/// `WorkspaceRef`, it carries no `MonitorId`; the shell resolves it against the live display set.
public enum MonitorRef: Sendable, Codable, Equatable {
    /// The monitor physically to the given side of the focused one.
    case direction(Direction)
    /// 1-based position in system enumeration order.
    case index(Int)
    /// The next / previous monitor in enumeration order (wraps).
    case next
    case previous
}

/// The complete set of operations emira can perform. **This is the single source of truth** — the
/// list "…grows here, and only here" (IMPLEMENTATION.md §2). Adding a verb is one case here plus
/// its handling in the reducer; every surface picks it up for free.
///
/// `Codable` so it rides the wire and the deterministic replay log; `Equatable` so scenario tests
/// can assert the exact command a keybind or CLI arg produced. The `Codable` shape is Swift's
/// synthesized enum form (`{"focus":{"_0":"left"}}`, `{"cycleWidth":{}}`); `EmiraProtocol` (M2)
/// owns the outer envelope and may refine presentation there — the core just needs a faithful
/// round-trip, which this has.
public enum Command: Sendable, Codable, Equatable {
    /// Move keyboard focus to the neighbouring column (left/right) or window-in-column (up/down).
    case focus(Direction)
    /// Move the focused window one slot in the given direction (reorder within/between columns,
    /// or push it to the next column along the ribbon).
    case moveWindow(Direction)
    /// Move the focused window to another workspace.
    case moveToWorkspace(WorkspaceRef)
    /// Move the focused window (and follow it) to another monitor.
    case moveToMonitor(MonitorRef)
    /// Cycle the focused column through the preset widths.
    case cycleWidth
    /// Widen the focused column by a delta — the continuous alternative to `cycleWidth`'s ladder.
    /// Bounded above by the working width; a column already there is a silent no-op.
    case grow(SizeDelta)
    /// Narrow the focused column by a delta. Bounded below by a floor, and in practice by whatever
    /// the app inside answers when asked to be that narrow (`SizeCorrection`).
    case shrink(SizeDelta)
    /// Cycle the focused window through the preset heights (within its column).
    case cycleHeight
    /// Consume or expel: pull the adjacent window *into* this column, or push the focused
    /// window *out* of it — direction selects which.
    case consumeOrExpel(Direction)
    /// Toggle (or force) fullscreen for the focused window.
    case fullscreen(Toggle)
    /// Toggle (or force) floating (untiled) for the focused window.
    case float(Toggle)
    /// Switch the focused workspace.
    case focusWorkspace(WorkspaceRef)
    /// Close the focused window.
    case closeWindow
    /// Scroll the strip so the focused column is centred in the viewport.
    case centerColumn
    /// Re-read the config file and re-lay-out in place.
    case reloadConfig
    /// Dump the live `State` as JSON over the socket — introspection for `emira debug`.
    case dumpState
}
