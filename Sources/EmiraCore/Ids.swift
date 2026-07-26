import Foundation

/// A strongly-typed opaque identifier.
///
/// The phantom `Tag` makes the four id kinds mutually non-interchangeable at compile time even
/// though all wrap a `UInt64` — passing a `ColumnId` where a `WindowId` is expected simply won't
/// compile, closing off a whole class of mix-up bugs for free.
///
/// Ids are **core-minted opaque tokens** (a monotonic counter), deliberately *not* system
/// handles: a `WindowId` is bound to its public `CGWindowID` by the shell's `WindowRegistry` and
/// keyed on it forever after, but is never *equal* to it (PRINCIPLES.md §7). Keeping the core's
/// ids independent of the OS's means the pure brain — and its replay logs — carry no framework
/// types.
///
/// `Codable` so ids serialize into the wire protocol and the deterministic replay log;
/// `Comparable` so collections of them iterate deterministically (stable debug dumps, golden
/// replays); `Hashable` so they key the `World`/`Layout` dictionaries.
public struct Id<Tag>: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// The underlying token. Opaque — its only contract is uniqueness within a kind.
    public let raw: UInt64

    public init(_ raw: UInt64) { self.raw = raw }

    public static func < (lhs: Id<Tag>, rhs: Id<Tag>) -> Bool { lhs.raw < rhs.raw }

    public var description: String { "\(Tag.self)#\(raw)" }

    // Encode as the bare number, not `{"raw": n}` — a compact, human-legible wire/replay form.
    public init(from decoder: any Decoder) throws {
        raw = try decoder.singleValueContainer().decode(UInt64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

// Phantom tags — uninhabited enums that exist only to distinguish id kinds at the type level.
// They carry no values and are never instantiated.
//
// There is deliberately no workspace tag. `WorkspaceTag`/`WorkspaceId` lived here for a minted-token
// model we are not building: workspaces are a **fixed named domain** of 36 addresses, not a dynamic
// set handed opaque ids (`WorkspaceName`, 2026-07-26). They were deleted rather than left as a second
// way to name a workspace — the same call the project made when it deleted `FakeWorld` instead of
// keeping it as a fallback.
public enum WindowTag {}
public enum ColumnTag {}
public enum MonitorTag {}
public enum LayerTag {}

/// Identifies a managed window (bound to a `CGWindowID` by the shell's `WindowRegistry`).
public typealias WindowId = Id<WindowTag>
/// Identifies a column on the strip (a vertical stack of windows). Minted by `ColumnAllocator`, one
/// id space across every workspace.
public typealias ColumnId = Id<ColumnTag>
/// Identifies a monitor / display.
public typealias MonitorId = Id<MonitorTag>
/// Identifies a presentation-plane layer in the reconstruction overlay (§4b).
public typealias LayerId = Id<LayerTag>
