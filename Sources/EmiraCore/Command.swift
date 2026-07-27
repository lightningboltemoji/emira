import Foundation

// The command vocabulary — the one list of "things you can ask emira to do", reused by every surface
// (CLI, hotkeys, config bindings, the wire protocol) so a new verb is added in exactly one place.

/// The four cardinal directions on the strip. Left/right run along the ribbon (between columns);
/// up/down run within a column (between the windows stacked in it).
public enum Direction: String, Sendable, Codable, CaseIterable, Equatable {
    case left, right, up, down

    /// The reversed direction.
    public var opposite: Direction {
        switch self {
        case .left: return .right
        case .right: return .left
        case .up: return .down
        case .down: return .up
        }
    }

    /// Which axis this direction travels.
    public var axis: Axis {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }
}

/// The two axes: horizontal is the infinite ribbon of columns, vertical the stack inside one column.
public enum Axis: String, Sendable, Codable, CaseIterable, Equatable {
    case horizontal, vertical
}

/// A boolean command: forced on/off, or flipped. `.on`/`.off` let a script assert an absolute state
/// without knowing the current one.
public enum Toggle: String, Sendable, Codable, CaseIterable, Equatable {
    case on, off, toggle

    /// Resolve against the present state.
    public func resolved(current: Bool) -> Bool {
        switch self {
        case .on: return true
        case .off: return false
        case .toggle: return !current
        }
    }
}

/// How much to change a size by — the argument to `grow` / `shrink`. Always a magnitude: the verb
/// carries the sign, so `grow -10%` is a syntax error rather than a second spelling of `shrink 10%`.
/// A percentage is of the monitor's working extent, not of the current size, so the steps are uniform,
/// the two verbs are exact inverses, and it composes with the presets.
public enum SizeDelta: Sendable, Codable, Equatable {
    /// Points, not device pixels. `px` is accepted as a spelling because it is what people type.
    case points(Double)
    /// A percentage of the working extent (`grow 10%` of an 1800 pt-wide area is 180 pt).
    case percent(Double)

    /// This delta in points, against the working extent a percentage measures.
    public func resolved(available: Double) -> Double {
        switch self {
        case .points(let points): return points
        case .percent(let percent): return available * percent / 100
        }
    }
}

/// A user-facing way to name one of the 36 workspace addresses — by the character that spells it, or
/// relative to the focused one. A *reference*, not a `WorkspaceName`: a relative ref has no name until
/// `Workspaces.resolve(_:)` resolves it against focus and occupancy. Relative refs clamp, never wrap.
public enum WorkspaceRef: Sendable, Codable, Equatable {
    /// The address spelled by its character — `1`…`9`, `0`, then `a`…`z`.
    case name(WorkspaceName)
    /// The next address along, occupied or not.
    case next
    /// The previous address, occupied or not.
    case previous
    /// The next address holding a window.
    case nextOccupied
    /// The previous address holding a window.
    case previousOccupied
}

/// The complete set of operations emira can perform. The `Codable` shape is Swift's synthesized enum
/// form (`{"focus":{"_0":"left"}}`); `EmiraProtocol` owns the outer envelope.
public enum Command: Sendable, Codable, Equatable {
    /// Move keyboard focus to the neighbouring column (left/right) or window-in-column (up/down).
    case focus(Direction)
    /// Move the focused window one slot in the given direction.
    case moveWindow(Direction)
    /// Move the focused window to another workspace, leaving focus behind on this one.
    case moveToWorkspace(WorkspaceRef)
    /// Move the focused window to another workspace and follow it there.
    case moveToWorkspaceAndFocus(WorkspaceRef)
    /// Cycle the focused column through the preset widths.
    case cycleWidth
    /// Widen the focused column by a delta — the continuous alternative to `cycleWidth`'s ladder,
    /// bounded above by the working width.
    case grow(SizeDelta)
    /// Narrow the focused column by a delta, bounded below by a floor and by what the app accepts.
    case shrink(SizeDelta)
    /// Cycle the focused window through the preset heights (within its column).
    case cycleHeight
    /// Pull the adjacent window *into* this column, or push the focused one *out* — direction selects.
    case consumeOrExpel(Direction)
    /// Toggle (or force) the focused *column* to the strip's full width. Not macOS's native full screen
    /// (no new Space) — neighbours just scroll out of view, and toggling off restores the exact width.
    case fullscreen(Toggle)
    /// Toggle (or force) floating (untiled) for the focused window.
    case float(Toggle)
    /// Switch the focused workspace.
    case focusWorkspace(WorkspaceRef)
    /// Close the focused window.
    case closeWindow
    /// Scroll the strip so the focused column is centred in the viewport.
    case centerColumn
    /// Dump the live `State` as JSON over the socket — introspection for `emira debug`.
    case dumpState
}
