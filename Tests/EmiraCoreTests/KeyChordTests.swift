import Foundation
import Testing
@testable import EmiraCore

// The chord grammar — `"cmd-alt-h"` ⇄ `KeyChord`. Two properties, as in `CommandSyntaxTests`: every
// key round-trips through its spelling, so what the daemon reports back is what the config file
// accepts; and nothing is silently ignored, because a binding that quietly never fires is the failure
// this vocabulary exists to prevent.

@Suite struct KeyChordTests {

    /// The one test that can't rot: `Key` is `CaseIterable`, so a key added without a spelling that
    /// survives the round-trip fails here rather than at somebody's keyboard.
    @Test func everyKeyRoundTripsThroughItsSpelling() throws {
        for key in Key.allCases {
            let chord = KeyChord([], key)
            #expect(chord.description == key.rawValue)
            #expect(try KeyChord.parse(chord.description) == chord)
        }
    }

    @Test func everyModifierCombinationRoundTrips() throws {
        let all: [KeyModifiers] = [.control, .option, .shift, .command, .function]
        for bits in 0..<32 {
            var modifiers: KeyModifiers = []
            for (index, modifier) in all.enumerated() where bits & (1 << index) != 0 {
                modifiers.insert(modifier)
            }
            let chord = KeyChord(modifiers, .h)
            #expect(try KeyChord.parse(chord.description) == chord)
        }
    }

    /// Modifiers are re-emitted in macOS's own ⌃⌥⇧⌘ order whatever order they were written in — which
    /// is what lets a duplicate-chord diagnostic name one spelling and have it mean both lines.
    @Test func modifiersAreSpelledInTheMenuBarsOrder() throws {
        let chord = KeyChord([.command, .shift, .option, .control], .h)
        #expect(chord.description == "ctrl-alt-shift-cmd-h")
        #expect(try KeyChord.parse("cmd-shift-alt-ctrl-h") == chord)
        #expect(try KeyChord.parse("alt-cmd-h") == KeyChord.parse("cmd-alt-h"))
        // fn leads, as ⌘-menus print 🌐 first.
        #expect(KeyChord([.function, .command, .control], .h).description == "fn-ctrl-cmd-h")
        #expect(try KeyChord.parse("cmd-fn-h") == KeyChord([.function, .command], .h))
    }

    @Test func modifierAliasesAreAccepted() throws {
        #expect(try KeyChord.parse("command-h") == KeyChord([.command], .h))
        #expect(try KeyChord.parse("option-h") == KeyChord([.option], .h))
        #expect(try KeyChord.parse("opt-h") == KeyChord([.option], .h))
        #expect(try KeyChord.parse("control-h") == KeyChord([.control], .h))
        #expect(try KeyChord.parse("globe-h") == KeyChord([.function], .h))
    }

    /// The keys macOS already marks with the fn flag when they are pressed alone. Binding `fn` to one
    /// would match the bare key — the failure that motivated the whole refusal, and the one that has
    /// to stay caught at the config file rather than at somebody's keyboard.
    @Test func functionCannotQualifyAKeyThatCarriesItsFlagAlready() throws {
        for spelling in ["fn-left", "fn-right", "fn-up", "fn-down",
                         "fn-home", "fn-end", "fn-pageup", "fn-pagedown",
                         "fn-delete", "fn-f1", "fn-f12", "fn-f20"] {
            #expect(throws: KeyChordSyntaxError.self) { try KeyChord.parse(spelling) }
        }
        // The diagnostic names the key, because the fix is to drop the `fn-`, not to respell it.
        #expect(throws: KeyChordSyntaxError.functionCannotQualify("left")) {
            try KeyChord.parse("fn-left")
        }
        // Those keys are perfectly bindable without fn, and stay so.
        #expect(try KeyChord.parse("left") == KeyChord([], .left))
        #expect(try KeyChord.parse("alt-f1") == KeyChord([.option], .f1))
    }

    /// Letters, digits and punctuation are the fn layer that is actually free — nothing else claims
    /// the flag on them, so the tap can tell `fn-h` from `h`.
    @Test func functionQualifiesAnOrdinaryKey() throws {
        #expect(try KeyChord.parse("fn-h") == KeyChord([.function], .h))
        #expect(KeyChord([.function], .h).description == "fn-h")
        #expect(try KeyChord.parse("fn-1") == KeyChord([.function], .digit1))
        #expect(try KeyChord.parse("fn-space") == KeyChord([.function], .space))
        #expect(try KeyChord.parse("fn-period") == KeyChord([.function], .period))
        #expect(try KeyChord.parse("fn-shift-h") == KeyChord([.function, .shift], .h))
    }

    /// An unmodified chord is legal. `f13`–`f20` exist precisely to be bound bare, and refusing them
    /// would be the vocabulary having an opinion the system doesn't.
    @Test func aChordNeedsNoModifiers() throws {
        #expect(try KeyChord.parse("f13") == KeyChord([], .f13))
    }

    /// Punctuation is named rather than typed, which is what keeps `-` unambiguous as the separator.
    @Test func punctuationIsNamed() throws {
        #expect(try KeyChord.parse("alt-minus") == KeyChord([.option], .minus))
        #expect(try KeyChord.parse("cmd-period") == KeyChord([.command], .period))
        #expect(try KeyChord.parse("ctrl-backtick") == KeyChord([.control], .backtick))
    }

    /// Digits are keys, not numbers — `cmd-1` is the chord a workspace switch is bound to.
    @Test func digitsAreKeys() throws {
        #expect(try KeyChord.parse("cmd-1") == KeyChord([.command], .digit1))
        #expect(KeyChord([.command], .digit0).description == "cmd-0")
    }

    // Every way of writing it wrong

    /// The error `text` produces, or `nil` if it parsed.
    static func diagnostic(_ text: String) -> KeyChordSyntaxError? {
        do {
            _ = try KeyChord.parse(text)
            return nil
        } catch let error as KeyChordSyntaxError {
            return error
        } catch {
            return nil
        }
    }

    @Test func anEmptyChordIsRefused() {
        #expect(Self.diagnostic("") == .empty)
    }

    @Test func anUnknownWordIsRefusedAndNamed() {
        #expect(Self.diagnostic("cmd-alt-zz") == .unknownWord("zz"))
        #expect(Self.diagnostic("meta-h") == .unknownWord("meta"))
        // Case-sensitive, like the CLI: one spelling, not a lenient one.
        #expect(Self.diagnostic("Cmd-H") == .unknownWord("Cmd"))
    }

    /// `cmd-alt-.` is the guess a user makes, and "unknown key or modifier '.'" leaves them to infer the
    /// naming rule from source. The hint turns a dead end into an instruction.
    @Test func punctuationTypedAsItselfSaysHowToSpellIt() {
        #expect(Self.diagnostic("cmd-alt-.") == .punctuationNeedsItsName(character: ".", name: "period"))
        #expect(Self.diagnostic("alt-/") == .punctuationNeedsItsName(character: "/", name: "slash"))
        #expect(KeyChordSyntaxError.punctuationNeedsItsName(character: ".", name: "period").description
                == "the '.' key is spelled 'period'")
    }

    /// The hint is a *diagnostic*, not a second spelling — every punctuation key still has exactly one
    /// way to be written, which is the rule that keeps `-` unambiguous.
    @Test func theHintIsNotAnAlternativeSpelling() {
        for key in Key.allCases {
            guard let character = Self.character(of: key) else { continue }
            #expect(Self.diagnostic(character) != nil, "'\(character)' must not parse as \(key.rawValue)")
            #expect(Key.name(forCharacter: character) == key.rawValue)
        }
    }

    /// The inverse of `Key.name(forCharacter:)`, spelled out here so the test can't be written by
    /// asking the code under test what it thinks.
    static func character(of key: Key) -> String? {
        switch key {
        case .equal: return "="
        case .leftbracket: return "["
        case .rightbracket: return "]"
        case .backslash: return "\\"
        case .semicolon: return ";"
        case .quote: return "'"
        case .comma: return ","
        case .period: return "."
        case .slash: return "/"
        case .backtick: return "`"
        default: return nil
        }
    }

    @Test func modifiersAloneAreNotAChord() {
        #expect(Self.diagnostic("cmd-alt") == .noKey("cmd-alt"))
        #expect(Self.diagnostic("shift") == .noKey("shift"))
    }

    @Test func twoKeysInOneChordAreRefused() {
        #expect(Self.diagnostic("cmd-h-j") == .multipleKeys("h", "j"))
    }

    @Test func aRepeatedModifierIsATypo() {
        #expect(Self.diagnostic("cmd-cmd-h") == .repeatedModifier("cmd"))
        // The aliases are the same modifier, so this is the same typo wearing a hat.
        #expect(Self.diagnostic("cmd-command-h") == .repeatedModifier("command"))
    }

    /// Somebody spelling the minus key literally. The message says what to write instead, because
    /// "unknown key ''" would leave them staring at a line that looks fine.
    @Test func aLiteralMinusSaysHowToSpellIt() {
        #expect(Self.diagnostic("alt--") == .emptyWord)
        #expect(Self.diagnostic("-h") == .emptyWord)
        #expect(KeyChordSyntaxError.emptyWord.description
                == "a '-' with nothing beside it — the minus key is spelled 'minus'")
    }

    /// The diagnostics are the product here as much as anywhere else in the config file.
    @Test func theDiagnosticsReadAsSentences() {
        #expect(KeyChordSyntaxError.unknownWord("zz").description == "unknown key or modifier 'zz'")
        #expect(KeyChordSyntaxError.noKey("cmd-alt").description
                == "'cmd-alt' names only modifiers — it needs a key too")
        #expect(KeyChordSyntaxError.multipleKeys("h", "j").description
                == "two keys, 'h' and 'j' — a binding takes one")
    }

    /// A chord encodes as the string it was written as, so `emira debug` prints bindings a human can
    /// check against their own config file — and so there is one spelling, not two.
    @Test func aChordEncodesAsItsSpelling() throws {
        let chord = KeyChord([.command, .option], .h)
        let json = String(decoding: try JSONEncoder().encode(chord), as: UTF8.self)
        #expect(json == "\"alt-cmd-h\"")
        #expect(try JSONDecoder().decode(KeyChord.self, from: Data(json.utf8)) == chord)
    }

    @Test func aBindingRoundTripsThroughJSON() throws {
        let binding = KeyBinding(KeyChord([.option], .h), .focus(.left))
        let data = try JSONEncoder().encode(binding)
        #expect(try JSONDecoder().decode(KeyBinding.self, from: data) == binding)
    }

    /// A chord that isn't a chord is a decode failure, not a silently empty one — the same rule the
    /// parse follows, reached through the other door.
    @Test func decodingRefusesAnUnreadableSpelling() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KeyChord.self, from: Data("\"cmd-zz\"".utf8))
        }
    }

    /// A chord is the key's *set* of modifiers plus its key, so two spellings of one binding hash the
    /// same — which is what makes the schema's duplicate check possible at all.
    @Test func chordsAreHashedByWhatTheyAreNotHowTheyAreWritten() throws {
        var seen: Set<KeyChord> = []
        #expect(seen.insert(try KeyChord.parse("cmd-alt-h")).inserted)
        #expect(!seen.insert(try KeyChord.parse("alt-cmd-h")).inserted)
    }
}
