import Foundation

// The surface syntax of a key combination — how `cmd-alt-h` is written down, read back, and spelled
// again. `Key` is exhaustive here so `cmd-alt-zz` is refused by `Config.parse` with a line number,
// rather than failing later at hotkey-registration time. A chord names a physical key *position*, not
// a character: on a non-QWERTY layout `alt-h` is the key where H sits on ANSI. Spelling is words
// separated by `-`, modifiers first in any order, re-emitted in ⌃⌥⇧⌘ order, lower-case and strict.

/// The four modifier keys a binding may carry. An `OptionSet` because the empty set is meaningful
/// (`f13` alone is a legitimate binding). No left/right distinction — the hotkey registry makes none.
public struct KeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option  = KeyModifiers(rawValue: 1 << 1)
    public static let shift   = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// Canonical spelling order, macOS's own ⌃⌥⇧⌘ — what re-emits `cmd-alt-h` and `alt-cmd-h` alike.
    static let canonical: [(modifier: KeyModifiers, word: String)] = [
        (.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "cmd"),
    ]

    /// Every accepted spelling. Aliases live here and nowhere else — key *names* have one spelling each.
    private static let words: [(word: String, modifier: KeyModifiers)] = [
        ("ctrl", .control), ("control", .control),
        ("alt", .option), ("opt", .option), ("option", .option),
        ("shift", .shift),
        ("cmd", .command), ("command", .command),
    ]

    /// The modifier a word names, or `nil` if it doesn't name one (in which case it must be the key).
    static func named(_ word: String) -> KeyModifiers? {
        words.first { $0.word == word }?.modifier
    }
}

/// The keys a binding can name — a *closed* vocabulary, so an unknown one is a config diagnostic; the
/// raw value is the spelling a user writes. Two surprises: `backspace` is the key labelled "delete" on
/// a Mac keyboard and `delete` is forward-delete (⌦); and punctuation is named, never typed (`minus`,
/// `period`, `slash`), because `-` is the chord separator and `alt--` cannot mean what it looks like.
public enum Key: String, Sendable, Hashable, Codable, CaseIterable {
    // Letters. The physical ANSI positions, not the characters the layout produces.
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z

    // Digits. A Swift case name can't start with a digit, so the *spelling* is the raw value.
    case digit0 = "0", digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4"
    case digit5 = "5", digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9"

    // Function keys. F13–F20 are the classic "bind something unmodified" keys: nothing else claims them.
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10
    case f11, f12, f13, f14, f15, f16, f17, f18, f19, f20

    // Arrows.
    case left, right, up, down

    // Whitespace, editing and navigation.
    case enter, tab, space, escape, backspace, delete
    case home, end, pageup, pagedown

    // Punctuation, by name (see the type's note).
    case minus, equal, leftbracket, rightbracket, backslash
    case semicolon, quote, comma, period, slash, backtick

    /// The name of the key a punctuation character sits on. Not a second spelling — `parse` never
    /// accepts these; it exists so the diagnostic for `cmd-alt-.` can name `period`.
    static func name(forCharacter character: String) -> String? {
        switch character {
        case "=":  return Key.equal.rawValue
        case "[":  return Key.leftbracket.rawValue
        case "]":  return Key.rightbracket.rawValue
        case "\\": return Key.backslash.rawValue
        case ";":  return Key.semicolon.rawValue
        case "'":  return Key.quote.rawValue
        case ",":  return Key.comma.rawValue
        case ".":  return Key.period.rawValue
        case "/":  return Key.slash.rawValue
        case "`":  return Key.backtick.rawValue
        default:   return nil
        }
    }
}

/// Why a string couldn't be read as a key combination. `ConfigSyntax` folds the `description` into a
/// `path:line:` diagnostic.
public enum KeyChordSyntaxError: Error, Equatable, CustomStringConvertible {
    /// Nothing at all — an empty key in the `[keys]` table.
    case empty
    /// A `-` with nothing on one side of it. Almost always someone spelling the minus key literally.
    case emptyWord
    /// A word that names neither a modifier nor a key — the ordinary typo.
    case unknownWord(String)
    /// A punctuation key typed as itself (`cmd-alt-.`) rather than by name.
    case punctuationNeedsItsName(character: String, name: String)
    /// Modifiers only: `cmd-alt` is a chord with no key in it.
    case noKey(String)
    /// Two key names in one chord — a binding fires on one key.
    case multipleKeys(String, String)
    /// The same modifier twice.
    case repeatedModifier(String)

    public var description: String {
        switch self {
        case .empty:
            return "no key combination"
        case .emptyWord:
            return "a '-' with nothing beside it — the minus key is spelled 'minus'"
        case .unknownWord(let word):
            return "unknown key or modifier '\(word)'"
        case .punctuationNeedsItsName(let character, let name):
            return "the '\(character)' key is spelled '\(name)'"
        case .noKey(let text):
            return "'\(text)' names only modifiers — it needs a key too"
        case .multipleKeys(let first, let second):
            return "two keys, '\(first)' and '\(second)' — a binding takes one"
        case .repeatedModifier(let word):
            return "'\(word)' twice"
        }
    }
}

/// One key combination: a set of modifiers plus the key they qualify. `Hashable` because the schema
/// detects two spellings of one chord by putting them in a set. Its `Codable` form is the spelling,
/// not the bitfield, so an `emira debug` dump reads back as `"chord": "ctrl-alt-h"`.
public struct KeyChord: Sendable, Hashable, Equatable, Codable, CustomStringConvertible {
    public let modifiers: KeyModifiers
    public let key: Key

    public init(_ modifiers: KeyModifiers, _ key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// The canonical spelling: modifiers in ⌃⌥⇧⌘ order, then the key. `parse` accepts this back.
    public var description: String {
        let words = KeyModifiers.canonical.filter { modifiers.contains($0.modifier) }.map(\.word)
        return (words + [key.rawValue]).joined(separator: "-")
    }

    /// Read a chord from its written form (`"cmd-alt-h"`, `"f13"`, `"shift-comma"`). Strict, lower-case.
    /// - Throws: `KeyChordSyntaxError`, whose `description` is already a printable diagnostic.
    public static func parse(_ text: String) throws -> KeyChord {
        guard !text.isEmpty else { throw KeyChordSyntaxError.empty }

        var modifiers: KeyModifiers = []
        var key: Key?
        var keyWord = ""

        for word in text.split(separator: "-", omittingEmptySubsequences: false).map(String.init) {
            guard !word.isEmpty else { throw KeyChordSyntaxError.emptyWord }
            if let modifier = KeyModifiers.named(word) {
                // A modifier after the key is accepted (`h-cmd` is odd but unambiguous); a repeat is a
                // typo that would otherwise work silently.
                guard !modifiers.contains(modifier) else {
                    throw KeyChordSyntaxError.repeatedModifier(word)
                }
                modifiers.insert(modifier)
                continue
            }
            guard let named = Key(rawValue: word) else {
                if let name = Key.name(forCharacter: word) {
                    throw KeyChordSyntaxError.punctuationNeedsItsName(character: word, name: name)
                }
                throw KeyChordSyntaxError.unknownWord(word)
            }
            guard key == nil else { throw KeyChordSyntaxError.multipleKeys(keyWord, word) }
            key = named
            keyWord = word
        }

        guard let key else { throw KeyChordSyntaxError.noKey(text) }
        return KeyChord(modifiers, key)
    }

    // Codable (as the spelling)

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do {
            self = try KeyChord.parse(text)
        } catch let error as KeyChordSyntaxError {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: error.description))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A chord bound to a command — one line of the config file's `[keys]` table. Held in an array, not a
/// `[KeyChord: Command]` dictionary: file order is registration order, and nothing looks one up.
public struct KeyBinding: Sendable, Equatable, Codable {
    public let chord: KeyChord
    public let command: Command

    public init(_ chord: KeyChord, _ command: Command) {
        self.chord = chord
        self.command = command
    }
}
