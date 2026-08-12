import AppKit
import EmiraCore

// How a key is drawn, as opposed to how it is spelled.
//
// `KeyChord.description` is the file's spelling and the only one the config reads back; this is the
// keyboard's, which is what a control has to show — nobody hunting for the key labelled ⌫ is looking
// for the word `backspace`. The same job `CueLayer` does for `Cue.keys`, one surface over.
//
// **Grouping is presentation too.** Ninety keys in one popup is a list nobody can find anything in, and
// which six groups they fall into is a fact about keyboards rather than about the vocabulary — so it is
// here and not on `Key`.

@MainActor
enum Keycap {

    /// The six rungs a key popup is divided into.
    enum Group: String, CaseIterable {
        case letters = "Letters"
        case digits = "Digits"
        case function = "Function"
        case arrows = "Arrows"
        case editing = "Editing"
        case punctuation = "Punctuation"
    }

    /// Which group a key belongs in. Exhaustive with no `default`, so a key added to the vocabulary is
    /// a compile error here rather than a name that quietly falls off the end of the list.
    static func group(of key: Key) -> Group {
        switch key {
        case .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
             .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z:
            return .letters
        case .digit0, .digit1, .digit2, .digit3, .digit4,
             .digit5, .digit6, .digit7, .digit8, .digit9:
            return .digits
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
             .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            return .function
        case .left, .right, .up, .down:
            return .arrows
        case .enter, .tab, .space, .escape, .backspace, .delete, .home, .end, .pageup, .pagedown:
            return .editing
        case .minus, .equal, .leftbracket, .rightbracket, .backslash,
             .semicolon, .quote, .comma, .period, .slash, .backtick:
            return .punctuation
        }
    }

    /// Every key, in its group, in the order `Key.allCases` gives them — which is the order they sit on
    /// a keyboard, near enough, and is the vocabulary's own rather than a second one.
    static let groups: [(group: Group, keys: [Key])] = Group.allCases.map { name in
        (name, Key.allCases.filter { Keycap.group(of: $0) == name })
    }

    /// What a key is labelled on the keyboard. The named punctuation keys get their character back —
    /// `period` is how the *file* spells it and `.` is what is on the key — and the ones with a glyph
    /// get the glyph with its name beside it, since ⌦ and ⌫ are told apart by nobody at a glance.
    static func label(for key: Key) -> String {
        switch key {
        case .enter:     return "⏎  Return"
        case .tab:       return "⇥  Tab"
        case .space:     return "␣  Space"
        case .escape:    return "⎋  Escape"
        case .backspace: return "⌫  Delete"
        case .delete:    return "⌦  Forward delete"
        case .home:      return "↖  Home"
        case .end:       return "↘  End"
        case .pageup:    return "⇞  Page up"
        case .pagedown:  return "⇟  Page down"
        case .left:      return "←  Left"
        case .right:     return "→  Right"
        case .up:        return "↑  Up"
        case .down:      return "↓  Down"

        case .minus:        return "-"
        case .equal:        return "="
        case .leftbracket:  return "["
        case .rightbracket: return "]"
        case .backslash:    return "\\"
        case .semicolon:    return ";"
        case .quote:        return "'"
        case .comma:        return ","
        case .period:       return "."
        case .slash:        return "/"
        case .backtick:     return "`"

        default:
            // Letters, digits and the F-keys are labelled what they are spelled, in the case a keycap
            // wears.
            return key.rawValue.uppercased()
        }
    }

    /// The short form, for a chip or a badge — no name beside the glyph.
    static func glyph(for key: Key) -> String {
        String(label(for: key).prefix(while: { !$0.isWhitespace }))
    }

    /// A modifier's own keycap. The order these are laid out in is `KeyModifiers.canonical`'s, which is
    /// macOS's own; this only says what each one looks like.
    ///
    /// **fn is spelled, not drawn.** Every other modifier has a monochrome character that inherits the
    /// colour it is given; the fn key's is 🌐, a colour emoji, which does not — so a row of five would be
    /// four glyphs that answer the theme and one that ignores it. Drawing it as an SF Symbol instead
    /// trades that for two rendering paths whose colours are set two different ways, and the first
    /// version of this proved they drift: `contentTintColor` reaches an image and never a title, so the
    /// globe stayed at full strength while the four beside it went dim. `fn` is one path, it is legible
    /// at chip size, and it is the word the config file itself spells.
    static func glyph(for modifier: KeyModifiers) -> String {
        switch modifier {
        case .function: return "fn"
        case .control:  return "⌃"
        case .option:   return "⌥"
        case .shift:    return "⇧"
        case .command:  return "⌘"
        default:        return "?"
        }
    }
}
