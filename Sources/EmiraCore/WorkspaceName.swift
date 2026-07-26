import Foundation

// The workspace address space (IMPLEMENTATION.md §5, `WorkspaceName.swift`) — the names the 36
// virtual workspaces have, and the only names they can have.
//
// **Fixed, not dynamic (decided 2026-07-26).** emira's workspaces are a *fixed named domain*, not a
// GNOME-style list that grows and collapses as it is used. That reverses what `Command.swift`'s
// `WorkspaceRef` and IMPLEMENTATION.md §9's M6 row originally assumed, and it is strictly simpler:
// there is no creation policy, no deletion policy, no renumbering when a workspace empties, and
// nothing anywhere has to answer "what is workspace 4 now that 3 was collapsed?". Every address
// exists from launch; most of them are simply empty.
//
// **The domain is `1`…`9`, then `0`, then `a`…`z` — the order the keys sit in** (settled
// 2026-07-26). 36 addresses, spelled exactly as a keyboard's number row followed by its letters, which
// is what a keybinding table wants to write down: `cmd-1` through `cmd-0`, then `cmd-a` onward. The
// first address is therefore `"1"`, and that is where focus rests at launch.
//
// `0` sitting tenth rather than first is the whole of the ordering, and it is a deliberate reversal of
// this file's first draft, which ran `0`…`9` and started there. Nobody counts workspaces from zero on
// a keyboard-driven window manager; they press the key at the left end of the row, and that key is
// `1`. Under the old order `prev` at launch stepped to an address the user had no reason to think
// about; under this one it clamps, exactly as `focus left` does at the strip's start.
//
// **Rank order is therefore *not* lexicographic order**, and `0` is the single place the two disagree.
// This is stated once, here, and it costs nothing: `WorkspaceName` is `Comparable` **by rank**, and
// every ordered view in `Workspaces` sorts by `WorkspaceName` rather than by the character, so all of
// them get the key order without re-deriving anything. The one place the string order still shows
// through is a `.sortedKeys` JSON dump, where `"0"` prints first — cosmetic, and the dump is keyed by
// name rather than ordered by it.

/// One of the 36 workspace addresses — `1`…`9`, `0`, then `a`…`z`, the order the keys sit in. A value
/// type over a rank in `0..<36`, spelled as its character.
///
/// `Comparable` **by rank**, which is the key order and *not* the character's alphabetical order (see
/// the file header — `0` is the one address where they disagree). So `next`/`previous` are `rank ± 1`
/// and clamp at the ends rather than wrapping, matching `focus left|right`, which already no-ops at the
/// strip's edges.
///
/// The initializers are **failable and total**: a character outside the domain answers `nil`, so a
/// bad name in a config file or on the CLI is a diagnostic with a line number rather than a trap.
/// Deliberately strict about case — `A` is *not* accepted as a spelling of `a`, because this type is
/// also a dictionary key (`CodingKeyRepresentable`, below) and two spellings of one address would let
/// a decoded document silently lose an entry.
///
/// `Codable` as the one-character string rather than as the rank, the same judgement `Id` makes about
/// encoding as the bare number: `emira debug` dumps and replay logs stay human-legible, and a
/// workspace reads as `"3"` in both places a user ever sees it.
public struct WorkspaceName: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// How many addresses there are. Fixed — see the file header.
    public static let count = 36

    /// The address's position in the domain, `0..<36`. Rank `0` is `"1"`; rank `9` is `"0"`; rank `35`
    /// is `"z"`.
    public let rank: Int

    /// Unchecked construction for the paths that have already proved the range (the static members
    /// and `next`/`previous`). Private so the public surface stays total.
    private init(unchecked rank: Int) {
        self.rank = rank
    }

    /// The address at `rank`, or `nil` if it is outside `0..<36`.
    public init?(rank: Int) {
        guard (0..<Self.count).contains(rank) else { return nil }
        self.rank = rank
    }

    /// The address spelled `character`, or `nil` if that character names none. `1`–`9` map to ranks
    /// 0–8, `0` to rank 9 — the key order, see the file header — and lowercase `a`–`z` to ranks 10–35.
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

    /// The address spelled by a one-character string, or `nil` — anything longer or shorter names no
    /// address at all. The form a config value, a CLI argument and a decoded dictionary key arrive in.
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

    /// The first address, `"1"` — where focus rests at launch, and the key at the left end of the
    /// number row.
    public static let first = WorkspaceName(unchecked: 0)
    /// The last address, `"z"`.
    public static let last = WorkspaceName(unchecked: count - 1)
    /// Every address, in order. The whole domain, because the whole domain is fixed.
    public static let all: [WorkspaceName] = (0..<count).map(WorkspaceName.init(unchecked:))

    /// The next address along, or `nil` at the end — the clamp that makes `focus-workspace next` a
    /// no-op at `"z"` rather than a wrap back to the start. Follows the *key* order, so `"9"`'s next is
    /// `"0"` and `"0"`'s is `"a"`.
    public var next: WorkspaceName? { WorkspaceName(rank: rank + 1) }
    /// The previous address, or `nil` at `"1"`. The mirror of `next`, and clamping for the same reason.
    public var previous: WorkspaceName? { WorkspaceName(rank: rank - 1) }

    // MARK: - Codable (the one-character string, not the rank)

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

// MARK: - CodingKeyRepresentable

/// Makes `[WorkspaceName: T]` encode as a **JSON object keyed by the character** (`{"0": …, "3": …}`)
/// instead of the flat alternating key/value array Swift falls back to for non-string keys.
///
/// This is not cosmetic. `Workspaces` is a dictionary keyed by this type and it is the thing
/// `emira debug` prints; an alternating array is unreadable at a glance and unstable to diff, which
/// defeats the reason the state dump exists (IMPLEMENTATION.md §7, "observability"). It is the same
/// argument the single-value `Codable` above makes, one container out.
extension WorkspaceName: CodingKeyRepresentable {
    /// A minimal string-only `CodingKey`. Private: it exists to spell one character as a key and has
    /// no business anywhere else.
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
