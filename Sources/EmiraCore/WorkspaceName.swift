import Foundation

// The workspace address space — a *fixed* named domain of 36 addresses, not a list that grows and
// collapses: every address exists from launch, most of them empty, so there is no creation, deletion
// or renumbering policy anywhere. The domain is `1`…`9`, `0`, then `a`…`z` — the order the keys sit
// in, so the first address is `"1"`, and that is where focus rests at launch.

/// One of the 36 workspace addresses, spelled as its character — a value type over a rank in `0..<36`.
/// `Comparable` by rank, which is key order and *not* the character's alphabetical order; `0` is the
/// one address where the two disagree. The initializers are failable and total, so a bad name in a
/// config file or on the CLI is a diagnostic rather than a trap, and case-strict — `A` is not a
/// spelling of `a`, since this is a dictionary key and two spellings would silently lose an entry.
public struct WorkspaceName: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// How many addresses there are.
    public static let count = 36

    /// The address's position in the domain, `0..<36`. Rank `0` is `"1"`, rank `9` is `"0"`.
    public let rank: Int

    /// Unchecked construction for the paths that have already proved the range.
    private init(unchecked rank: Int) {
        self.rank = rank
    }

    /// The address at `rank`, or `nil` if it is outside `0..<36`.
    public init?(rank: Int) {
        guard (0..<Self.count).contains(rank) else { return nil }
        self.rank = rank
    }

    /// The address spelled `character`, or `nil`. `1`–`9` map to ranks 0–8, `0` to 9, `a`–`z` to 10–35.
    public init?(_ character: Character) {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "1")...UInt8(ascii: "9"):
            self.rank = Int(ascii - UInt8(ascii: "1"))
        case UInt8(ascii: "0"):
            self.rank = 9
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            self.rank = 10 + Int(ascii - UInt8(ascii: "a"))
        default:
            return nil
        }
    }

    /// The address spelled by a one-character string, or `nil` — the form config values, CLI arguments
    /// and decoded dictionary keys arrive in.
    public init?(_ text: String) {
        guard text.count == 1, let character = text.first else { return nil }
        self.init(character)
    }

    /// How this address is spelled — the exact inverse of `init?(_:)`, including rank 9's `"0"`.
    public var character: Character {
        switch rank {
        case ..<9:  return Character(UnicodeScalar(UInt8(ascii: "1") + UInt8(rank)))
        case 9:     return "0"
        default:    return Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(rank - 10)))
        }
    }

    public var description: String { String(character) }

    public static func < (lhs: WorkspaceName, rhs: WorkspaceName) -> Bool { lhs.rank < rhs.rank }

    /// The first address, `"1"` — where focus rests at launch.
    public static let first = WorkspaceName(unchecked: 0)
    /// The last address, `"z"`.
    public static let last = WorkspaceName(unchecked: count - 1)
    /// Every address, in order.
    public static let all: [WorkspaceName] = (0..<count).map(WorkspaceName.init(unchecked:))

    /// The next address along, or `nil` at the end — the clamp that makes `focus-workspace next` a
    /// no-op at `"z"` rather than a wrap. Follows *key* order, so `"9"`'s next is `"0"`.
    public var next: WorkspaceName? { WorkspaceName(rank: rank + 1) }
    /// The previous address, or `nil` at `"1"`. The mirror of `next`.
    public var previous: WorkspaceName? { WorkspaceName(rank: rank - 1) }

    // Codable (the one-character string, not the rank)

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let name = WorkspaceName(text) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "'\(text)' is not a workspace name (1-9, 0, then a-z)"))
        }
        self = name
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Makes `[WorkspaceName: T]` encode as a JSON object keyed by the character (`{"0": …, "3": …}`)
/// instead of the flat alternating key/value array Swift falls back to for non-string keys.
extension WorkspaceName: CodingKeyRepresentable {
    /// A minimal string-only `CodingKey` — it exists only to spell one character as a key.
    private struct NameKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { self.stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public var codingKey: any CodingKey { NameKey(description) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(codingKey.stringValue)
    }
}
