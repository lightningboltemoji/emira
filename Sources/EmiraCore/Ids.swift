import Foundation

/// A strongly-typed opaque identifier. The phantom `Tag` makes the id kinds mutually
/// non-interchangeable at compile time even though all wrap a `UInt64`. Ids are core-minted from a
/// monotonic counter, never system handles: a `WindowId` is *bound* to a `CGWindowID` by the shell's
/// `WindowRegistry` but is never equal to it, which keeps the core free of framework types.
public struct Id<Tag>: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// The underlying token. Opaque — its only contract is uniqueness within a kind.
    public let raw: UInt64

    public init(_ raw: UInt64) { self.raw = raw }

    public static func < (lhs: Id<Tag>, rhs: Id<Tag>) -> Bool { lhs.raw < rhs.raw }

    public var description: String { "\(Tag.self)#\(raw)" }

    // Encode as the bare number, not `{"raw": n}` — a compact, legible wire/replay form.
    public init(from decoder: any Decoder) throws {
        raw = try decoder.singleValueContainer().decode(UInt64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

// Phantom tags — uninhabited enums that exist only to distinguish id kinds at the type level. No
// workspace tag: workspaces are a fixed named domain (`WorkspaceName`), not a dynamic id space.
public enum WindowTag {}
public enum ColumnTag {}
public enum MonitorTag {}
public enum LayerTag {}

/// Identifies a managed window (bound to a `CGWindowID` by the shell's `WindowRegistry`).
public typealias WindowId = Id<WindowTag>
/// Identifies a column on the strip. Minted by `ColumnAllocator`, one id space across all workspaces.
public typealias ColumnId = Id<ColumnTag>
/// Identifies a monitor / display.
public typealias MonitorId = Id<MonitorTag>
/// Identifies a presentation-plane layer in the reconstruction overlay.
public typealias LayerId = Id<LayerTag>
