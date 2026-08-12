import Foundation

// The surface syntax of a key combination — how `cmd-alt-h` is written down, read back, and spelled
// again. `Key` is exhaustive here so `cmd-alt-zz` is refused by `Config.parse` with a line number,
// rather than failing later at hotkey-registration time. A chord names a physical key *position*, not
// a character: on a non-QWERTY layout `alt-h` is the key where H sits on ANSI. Spelling is words
// separated by `-`, modifiers first in any order, re-emitted in 🌐⌃⌥⇧⌘ order, lower-case and strict.

/// The five modifier keys a binding may carry. An `OptionSet` because the empty set is meaningful
/// (`f13` alone is a legitimate binding). No left/right distinction — the hotkey registry makes none.
public struct KeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option  = KeyModifiers(rawValue: 1 << 1)
    public static let shift   = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// The fn (🌐) key. The Carbon registry has no bit for it and silently matches the *bare* key if
    /// handed one, so a chord carrying `.function` is bound through an event tap instead. The two
    /// registries divide on exactly this flag; `SplitHotkeyBinder` is where that happens.
    public static let function = KeyModifiers(rawValue: 1 << 4)

    /// Canonical spelling order, macOS's own 🌐⌃⌥⇧⌘ — what re-emits `cmd-alt-h` and `alt-cmd-h` alike.
    ///
    /// Public because it is also the order a *control* has to lay its modifiers out in, and the order
    /// is not the settings window's to pick: four chips in a second order would be a second opinion
    /// about a spelling this type already fixes.
    public static let canonical: [(modifier: KeyModifiers, word: String)] = [
        (.function, "fn"),
        (.control, "ctrl"), (.option, "alt"), (.shift, "shift"), (.command, "cmd"),
    ]

    /// Every accepted spelling. Aliases live here and nowhere else — key *names* have one spelling each.
    private static let words: [(word: String, modifier: KeyModifiers)] = [
        ("ctrl", .control), ("control", .control),
        ("alt", .option), ("opt", .option), ("option", .option),
        ("shift", .shift),
        ("cmd", .command), ("command", .command),
        ("fn", .function), ("globe", .function),
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

    /// Keys macOS reports the fn flag on when they are pressed *alone* — AppKit's "function key"
    /// class, which the window server marks whether or not fn is held. `fn` cannot qualify one: the
    /// flag carries no information, so the binding would take the bare key. `parse` refuses it.
    public var isFunctionClass: Bool {
        switch self {
        case .left, .right, .up, .down,
             .home, .end, .pageup, .pagedown, .delete,
             .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
             .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            return true
        default:
            return false
        }
    }

    /// This key's virtual key code — its *physical position*, which is what both the hotkey registry
    /// and a recorded press speak in. `0x04` is the key where H sits on US layout, whatever it types
    /// elsewhere.
    ///
    /// **Hex rather than `kVK_*`, and here rather than beside the registry that spends it.** The
    /// package's hard rule is that nothing below imports a framework and `EmiraCore` is Foundation-only,
    /// so a table spelled in Carbon's constants cannot live where both consumers can reach it — and the
    /// alternative, a second table in the module that records keystrokes, is exactly the silent
    /// transposition this is arranged to prevent. What the spelling bought was checkability against
    /// Apple's header; `HotkeyTests` now checks it, entry by entry, against those same constants, plus
    /// the injectivity the spelling never gave us. Checked beats checkable.
    ///
    /// A `switch` rather than a table literal, so a `Key` added without a code is a compile error here
    /// rather than a trap the first time somebody binds it.
    public var virtualKeyCode: UInt16 {
        switch self {
        case .a: return 0x00
        case .b: return 0x0B
        case .c: return 0x08
        case .d: return 0x02
        case .e: return 0x0E
        case .f: return 0x03
        case .g: return 0x05
        case .h: return 0x04
        case .i: return 0x22
        case .j: return 0x26
        case .k: return 0x28
        case .l: return 0x25
        case .m: return 0x2E
        case .n: return 0x2D
        case .o: return 0x1F
        case .p: return 0x23
        case .q: return 0x0C
        case .r: return 0x0F
        case .s: return 0x01
        case .t: return 0x11
        case .u: return 0x20
        case .v: return 0x09
        case .w: return 0x0D
        case .x: return 0x07
        case .y: return 0x10
        case .z: return 0x06

        case .digit0: return 0x1D
        case .digit1: return 0x12
        case .digit2: return 0x13
        case .digit3: return 0x14
        case .digit4: return 0x15
        case .digit5: return 0x17
        case .digit6: return 0x16
        case .digit7: return 0x1A
        case .digit8: return 0x1C
        case .digit9: return 0x19

        case .f1:  return 0x7A
        case .f2:  return 0x78
        case .f3:  return 0x63
        case .f4:  return 0x76
        case .f5:  return 0x60
        case .f6:  return 0x61
        case .f7:  return 0x62
        case .f8:  return 0x64
        case .f9:  return 0x65
        case .f10: return 0x6D
        case .f11: return 0x67
        case .f12: return 0x6F
        case .f13: return 0x69
        case .f14: return 0x6B
        case .f15: return 0x71
        case .f16: return 0x6A
        case .f17: return 0x40
        case .f18: return 0x4F
        case .f19: return 0x50
        case .f20: return 0x5A

        case .left:  return 0x7B
        case .right: return 0x7C
        case .up:    return 0x7E
        case .down:  return 0x7D

        case .enter:  return 0x24
        case .tab:    return 0x30
        case .space:  return 0x31
        case .escape: return 0x35
        // The key a Mac keyboard *labels* "delete" is `kVK_Delete`, and ⌦ is `kVK_ForwardDelete`; this
        // type names them `backspace` and `delete`. The two conventions meet here.
        case .backspace: return 0x33
        case .delete:    return 0x75

        case .home:     return 0x73
        case .end:      return 0x77
        case .pageup:   return 0x74
        case .pagedown: return 0x79

        case .minus:        return 0x1B
        case .equal:        return 0x18
        case .leftbracket:  return 0x21
        case .rightbracket: return 0x1E
        case .backslash:    return 0x2A
        case .semicolon:    return 0x29
        case .quote:        return 0x27
        case .comma:        return 0x2B
        case .period:       return 0x2F
        case .slash:        return 0x2C
        case .backtick:     return 0x32
        }
    }

    /// The key at a virtual key code, or `nil` for a position this vocabulary has no name for — which is
    /// what a recorder answers a press with, and what makes an unnameable key a refusal by name rather
    /// than a binding that silently never fires.
    ///
    /// **Derived from `virtualKeyCode`, never written twice.** A second table would be free to disagree
    /// with the first, and the disagreement is invisible: the chord would register against one physical
    /// key and be displayed as another.
    public init?(virtualKeyCode code: UInt16) {
        guard let key = Self.named[code] else { return nil }
        self = key
    }

    /// The forward table read backwards. A transposition collapses two entries into one, so this is
    /// shorter than `allCases` exactly when the map is not injective — which is what `HotkeyTests`
    /// checks, rather than trapping here at first use.
    private static let named: [UInt16: Key] = Dictionary(
        allCases.map { ($0.virtualKeyCode, $0) }, uniquingKeysWith: { first, _ in first })

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
    /// `fn` on a key that already reports the fn flag by itself — `fn-left` would take the left arrow.
    case functionCannotQualify(String)

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
        case .functionCannotQualify(let key):
            return "'fn' cannot qualify '\(key)': macOS reports the fn flag on that key whether or "
                + "not fn is held, so the binding would take the bare key"
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
        guard !(modifiers.contains(.function) && key.isFunctionClass) else {
            throw KeyChordSyntaxError.functionCannotQualify(key.rawValue)
        }
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

    /// The command as the file spells it — `"focus left"`, the binding's own right-hand side.
    ///
    /// A *spelled* view of the binding, so a surface that may read the vocabulary but not the reducer's
    /// input can show what a chord does. `Cue` established the pattern; `Command.parse(line:)` takes it
    /// back.
    public var spelling: String { command.words.joined(separator: " ") }
}
