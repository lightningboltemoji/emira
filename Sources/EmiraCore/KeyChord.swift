import Foundation

// The *surface syntax* of a key combination — how `cmd-alt-h` is written down, read back, and spelled
// again. It stands to the shell's hotkey machinery exactly as `CommandSyntax.swift` stands to the CLI:
// the decisions are here, in the pure core, and the framework-bound half (`EmiraShell/Input/`) holds
// only the calls.
//
// **Why the key vocabulary is a core enum and not a string the shell resolves.** The alternative —
// `Config` carrying `"cmd-alt-zz"` as text and `CarbonHotkeyBinder` failing to find a keycode for it —
// moves the only interesting failure (a typo) out of the config diagnostic and into a log line at
// registration time, on a machine where nobody is looking. With `Key` exhaustive here, `cmd-alt-zz` is
// refused by `Config.parse` with the line number it was written on, like every other typo in the file
// (`ConfigSyntax.swift`), and the shell's keycode table is a `switch` the compiler checks: adding a key
// name without giving it a keycode does not build.
//
// **Physical keys, not characters.** A chord names a *position* on the keyboard, because that is what
// the OS's hotkey registry takes. On a non-QWERTY layout `alt-h` is the key where H sits on ANSI, which
// is what AeroSpace does and what makes a config portable between machines. The consequence worth
// stating: a chord is not "the key that types 'h'".
//
// **Spelling rules, all three of them.** Words are separated by `-`; modifiers come first in any order
// and are re-emitted in macOS's own ⌃⌥⇧⌘ order; everything is lower-case and strict, like the CLI
// (`CommandSyntax.swift`). A literal minus key is `minus`, which is *why* the punctuation keys are
// named rather than typed — `alt--` would otherwise be a chord with a hole in it.

/// The four modifier keys a binding may carry. An `OptionSet` because a chord holds a *set* of them
/// and the empty set is meaningful (`f13` alone is a legitimate binding).
///
/// Deliberately no distinction between left and right modifiers: the system hotkey registry doesn't
/// make one, so neither can we.
public struct KeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option  = KeyModifiers(rawValue: 1 << 1)
    public static let shift   = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// Canonical spelling order — macOS's own ⌃⌥⇧⌘, the order the menu bar draws them in. Used to
    /// re-emit a chord, which is what makes `cmd-alt-h` and `alt-cmd-h` visibly the same binding in a
    /// diagnostic (`ConfigSyntax.swift` refuses the pair as a duplicate, naming this spelling).
    static let canonical: [(modifier: KeyModifiers, word: String)] = [
        (.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "cmd"),
    ]

    /// Every accepted spelling. Aliases exist here and nowhere else in the chord grammar: people
    /// genuinely write both `cmd` and `command`, and both `alt` and `option`, and refusing either
    /// would be pedantry. Key *names* have exactly one spelling apiece, because there the alternative
    /// is a table of synonyms nobody can remember the extent of.
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

/// The keys a binding can name — a *closed* vocabulary, so an unknown one is a config diagnostic.
///
/// The raw value is the spelling a user writes. Two naming choices are worth stating because they
/// surprise people in opposite directions:
///
///  · **`backspace` is the key labelled "delete" on a Mac keyboard**, and `delete` is the one labelled
///    "forward delete" (⌦) on a full-size one. This is AeroSpace's naming, and our users come from
///    there; the alternative made `delete` mean different physical keys on different keyboards.
///  · **Punctuation is named, never typed** (`minus`, `period`, `slash`). `-` is the chord separator,
///    so `alt--` cannot mean what it looks like; naming all of them keeps one rule instead of an
///    exception.
public enum Key: String, Sendable, Hashable, Codable, CaseIterable {
    // Letters. The physical ANSI positions, not the characters the layout produces.
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z

    // Digits. A Swift case name can't start with a digit, so the *spelling* is the raw value.
    case digit0 = "0", digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4"
    case digit5 = "5", digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9"

    // Function keys. F13–F20 exist because they are the classic "bind something unmodified" keys —
    // a programmable keyboard sends them and nothing else claims them.
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

    /// The name of the key a punctuation character sits on.
    ///
    /// **This is not a second spelling — `parse` never accepts these.** It exists only so the
    /// diagnostic can teach: somebody writing `cmd-alt-.` has made a reasonable guess, and
    /// "unknown key or modifier '.'" leaves them to discover the naming rule by reading source. The
    /// same courtesy `emptyWord` extends to `alt--`, which is the same mistake one character earlier.
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

/// Why a string couldn't be read as a key combination. `CustomStringConvertible` because the message
/// is user-facing: `ConfigSyntax` folds it into a `path:line:` diagnostic about the file it was
/// written in.
public enum KeyChordSyntaxError: Error, Equatable, CustomStringConvertible {
    /// Nothing at all — an empty key in the `[keys]` table.
    case empty
    /// A `-` with nothing on one side of it. Almost always someone spelling the minus key literally.
    case emptyWord
    /// A word that names neither a modifier nor a key — the ordinary typo.
    case unknownWord(String)
    /// A punctuation key typed as itself (`cmd-alt-.`). A reasonable guess, and wrong for a reason
    /// worth stating rather than making the user infer: `-` separates words, so *all* punctuation is
    /// named to keep one rule instead of an exception.
    case punctuationNeedsItsName(character: String, name: String)
    /// Modifiers only: `cmd-alt` is a chord with no key in it.
    case noKey(String)
    /// Two key names in one chord. A binding fires on one key; `cmd-h-j` is two ideas.
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

/// One key combination: a set of modifiers plus the key they qualify.
///
/// `Hashable` because the schema detects two spellings of the same chord by putting them in a set —
/// which is the whole reason the type exists rather than the string it was written as.
///
/// Its `Codable` form is that string. `State` dumps to JSON for `emira debug` (§7), and a binding that
/// reads back `"chord": "ctrl-alt-h"` is one a human can check against their own config file, where
/// `{"modifiers":11,"key":"h"}` is a bitfield they'd have to decode. It also means the round-trip runs
/// through the same `parse`/`description` pair the config file uses, so there is one spelling, tested
/// once.
public struct KeyChord: Sendable, Hashable, Equatable, Codable, CustomStringConvertible {
    public let modifiers: KeyModifiers
    public let key: Key

    public init(_ modifiers: KeyModifiers, _ key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// The canonical spelling: modifiers in ⌃⌥⇧⌘ order, then the key. `parse` accepts this back
    /// unchanged, which a test pins for every `Key` there is.
    public var description: String {
        let words = KeyModifiers.canonical.filter { modifiers.contains($0.modifier) }.map(\.word)
        return (words + [key.rawValue]).joined(separator: "-")
    }

    /// Read a chord from its written form (`"cmd-alt-h"`, `"f13"`, `"shift-comma"`).
    ///
    /// Strict and lower-case, like `Command.parse` — a config file is read by a machine and written in
    /// an editor, and both do better with one spelling than with a lenient one.
    ///
    /// - Throws: `KeyChordSyntaxError`, whose `description` is already a printable diagnostic.
    public static func parse(_ text: String) throws -> KeyChord {
        guard !text.isEmpty else { throw KeyChordSyntaxError.empty }

        var modifiers: KeyModifiers = []
        var key: Key?
        var keyWord = ""

        for word in text.split(separator: "-", omittingEmptySubsequences: false).map(String.init) {
            guard !word.isEmpty else { throw KeyChordSyntaxError.emptyWord }
            if let modifier = KeyModifiers.named(word) {
                // A modifier *after* the key is accepted (`h-cmd` is odd but unambiguous); a repeat
                // is not, because it is a typo that would otherwise work silently.
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

    // MARK: - Codable (as the spelling)

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

/// A chord bound to a command — one line of the config file's `[keys]` table.
///
/// An **array** of these rather than a `[KeyChord: Command]` dictionary, for three reasons that all
/// point the same way: the file's order is the order the daemon reports and registers them in; the
/// duplicate-chord check belongs in the parse (where it can name a line) rather than being silently
/// performed by a dictionary literal; and nothing ever looks a binding up *by chord* — the shell
/// registers each one and is handed back an id, so the only lookup that exists is id → command.
public struct KeyBinding: Sendable, Equatable, Codable {
    public let chord: KeyChord
    public let command: Command

    public init(_ chord: KeyChord, _ command: Command) {
        self.chord = chord
        self.command = command
    }
}
