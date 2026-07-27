import Foundation

// The surface syntax of the command vocabulary — how a `Command` is spelled as words and parsed back.
// In the core because two surfaces in different targets need the identical mapping: the CLI
// (`emira focus left`) and the config file (`alt-h = "focus left"`). Parsing is strict and
// case-sensitive; unknown verb, missing/bad argument and trailing junk are distinct printable errors.

/// Why a string couldn't be read as a `Command`. The CLI prints the `description` to stderr; the config
/// loader prefixes it with a file and line.
public enum CommandSyntaxError: Error, Equatable, CustomStringConvertible {
    /// Nothing to parse — an empty argument list.
    case noVerb
    /// The first word isn't a known verb.
    case unknownVerb(String)
    /// The verb needs an argument that wasn't supplied. `expected` is the grammar fragment.
    case missingArgument(verb: String, expected: String)
    /// The argument was supplied but isn't one of the accepted words/numbers.
    case badArgument(verb: String, value: String, expected: String)
    /// Trailing words the verb doesn't take — a typo we refuse to silently discard.
    case tooManyArguments(verb: String, extra: [String])

    public var description: String {
        switch self {
        case .noVerb:
            return "no command given"
        case .unknownVerb(let word):
            return "unknown command '\(word)'"
        case .missingArgument(let verb, let expected):
            return "'\(verb)' needs an argument: \(expected)"
        case .badArgument(let verb, let value, let expected):
            return "'\(verb)': bad argument '\(value)' — expected \(expected)"
        case .tooManyArguments(let verb, let extra):
            let plural = extra.count == 1 ? "" : "s"
            return "'\(verb)': unexpected argument\(plural) '\(extra.joined(separator: " "))'"
        }
    }
}

extension Command {

    // MARK: - Rendering (the canonical spelling)

    /// This command written as argv words — the spelling `parse` accepts back. Exhaustive on purpose:
    /// a new `Command` case fails to compile here until it is given a spelling and a `verbs` entry.
    public var words: [String] {
        switch self {
        case .focus(let direction):           return ["focus", direction.rawValue]
        case .moveWindow(let direction):      return ["move-window", direction.rawValue]
        case .moveToWorkspace(let ref):       return ["move-to-workspace", ref.word]
        case .moveToWorkspaceAndFocus(let r): return ["move-to-workspace-and-focus", r.word]
        case .cycleWidth:                     return ["cycle-width"]
        case .grow(let delta):                return ["grow", delta.word]
        case .shrink(let delta):              return ["shrink", delta.word]
        case .cycleHeight:                    return ["cycle-height"]
        case .consumeOrExpel(let direction):  return ["consume-or-expel", direction.rawValue]
        case .fullscreen(let toggle):         return ["fullscreen", toggle.rawValue]
        case .float(let toggle):              return ["float", toggle.rawValue]
        case .focusWorkspace(let ref):        return ["focus-workspace", ref.word]
        case .closeWindow:                    return ["close-window"]
        case .centerColumn:                   return ["center-column"]
        // `debug` is the user-facing spelling; `dump-state` parses as an alias.
        case .dumpState:                      return ["debug"]
        }
    }

    // MARK: - Parsing

    /// Read a `Command` from argv-style words (verb first, then its arguments).
    /// - Throws: `CommandSyntaxError`, whose `description` is already a printable diagnostic.
    public static func parse(_ words: [String]) throws -> Command {
        guard let word = words.first, !word.isEmpty else { throw CommandSyntaxError.noVerb }
        guard let verb = verbs.first(where: { $0.matches(word) }) else {
            throw CommandSyntaxError.unknownVerb(word)
        }
        // Errors always name the *canonical* verb, even when the user typed an alias.
        return try verb.build(verb.name, Array(words.dropFirst()))
    }

    /// Convenience for a whole command line as one string (a config binding's right-hand side). Splits
    /// on whitespace runs; there is no quoting, because no argument in the vocabulary contains a space.
    public static func parse(line: String) throws -> Command {
        try parse(line.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    // MARK: - Help

    /// One indented line per verb, columns aligned. The CLI adds its own header.
    public static var usage: String {
        let width = verbs.map(\.signature.count).max() ?? 0
        return verbs.map { verb in
            let padding = String(repeating: " ", count: width - verb.signature.count + 2)
            return "  \(verb.signature)\(padding)\(verb.summary)"
        }.joined(separator: "\n")
    }

    // MARK: - The verb table

    /// One spelling of one command: canonical name, aliases, argument grammar (for `usage`), a summary,
    /// and how to build it. `build` gets the canonical name, so errors read the same via any alias.
    struct Verb: Sendable {
        let name: String
        let aliases: [String]
        let arguments: String
        let summary: String
        let build: @Sendable (String, [String]) throws -> Command

        init(_ name: String, aliases: [String] = [], arguments: String = "", summary: String,
             build: @escaping @Sendable (String, [String]) throws -> Command) {
            self.name = name
            self.aliases = aliases
            self.arguments = arguments
            self.summary = summary
            self.build = build
        }

        /// `"focus <left|right|up|down>"` — the left column of `usage`.
        var signature: String { arguments.isEmpty ? name : "\(name) \(arguments)" }

        func matches(_ word: String) -> Bool { word == name || aliases.contains(word) }
    }

    /// Every verb, in the order `usage` prints them. Not `private`: the compiler can't check this table
    /// against `Command`'s cases, so a test does.
    static let verbs: [Verb] = [
        Verb("focus", arguments: Grammar.direction,
             summary: "Focus the neighbouring column or window.",
             build: { verb, args in .focus(try direction(args, verb: verb)) }),

        Verb("move-window", arguments: Grammar.direction,
             summary: "Move the focused window one slot.",
             build: { verb, args in .moveWindow(try direction(args, verb: verb)) }),

        Verb("consume-or-expel", arguments: Grammar.direction,
             summary: "Pull a window into or out of the column.",
             build: { verb, args in .consumeOrExpel(try direction(args, verb: verb)) }),

        Verb("center-column", summary: "Centre the focused column in the viewport.",
             build: bare(.centerColumn)),

        Verb("cycle-width", summary: "Cycle the column through the width presets.",
             build: bare(.cycleWidth)),

        Verb("grow", arguments: Grammar.delta,
             summary: "Widen the focused column.",
             build: { verb, args in .grow(try sizeDelta(args, verb: verb)) }),

        Verb("shrink", arguments: Grammar.delta,
             summary: "Narrow the focused column.",
             build: { verb, args in .shrink(try sizeDelta(args, verb: verb)) }),

        Verb("cycle-height", summary: "Cycle the window through the height presets.",
             build: bare(.cycleHeight)),

        Verb("fullscreen", arguments: Grammar.toggle,
             summary: "Toggle the focused column to the strip's full width.",
             build: { verb, args in .fullscreen(try toggle(args, verb: verb)) }),

        Verb("float", arguments: Grammar.toggle,
             summary: "Toggle floating for the focused window.",
             build: { verb, args in .float(try toggle(args, verb: verb)) }),

        Verb("close-window", summary: "Close the focused window.", build: bare(.closeWindow)),

        Verb("focus-workspace", arguments: Grammar.workspace,
             summary: "Switch the focused workspace.",
             build: { verb, args in .focusWorkspace(try workspaceRef(args, verb: verb)) }),

        Verb("move-to-workspace", arguments: Grammar.workspace,
             summary: "Move the focused window to a workspace.",
             build: { verb, args in .moveToWorkspace(try workspaceRef(args, verb: verb)) }),

        Verb("move-to-workspace-and-focus", arguments: Grammar.workspace,
             summary: "Move the focused window to a workspace and follow it.",
             build: { verb, args in .moveToWorkspaceAndFocus(try workspaceRef(args, verb: verb)) }),

        Verb("debug", aliases: ["dump-state"], summary: "Print the daemon's live state as JSON.",
             build: bare(.dumpState)),
    ]

    // MARK: - Grammar fragments (one spelling, used by both `usage` and the error messages)

    private enum Grammar {
        static let direction = "<left|right|up|down>"
        static let toggle = "[on|off|toggle]"
        // One bracket rather than listed flat: `usage` pads to the widest signature, and this fragment
        // sits on the longest verb in the table.
        static let workspace = "<0-9|a-z|(next|prev)[-non-empty]>"
        static let delta = "<Npx|N%>"
    }

    // MARK: - Argument readers

    /// A verb that takes no arguments: any word after it is a typo, not something to ignore.
    private static func bare(_ command: Command) -> @Sendable (String, [String]) throws -> Command {
        { verb, args in
            try Command.noMore(args[...], verb: verb)
            return command
        }
    }

    /// Exactly one argument, or a precise complaint about which way it was wrong.
    private static func only(_ args: [String], verb: String, expected: String) throws -> String {
        guard let first = args.first else {
            throw CommandSyntaxError.missingArgument(verb: verb, expected: expected)
        }
        try noMore(args.dropFirst(), verb: verb)
        return first
    }

    private static func noMore(_ extra: ArraySlice<String>, verb: String) throws {
        guard extra.isEmpty else {
            throw CommandSyntaxError.tooManyArguments(verb: verb, extra: Array(extra))
        }
    }

    private static func direction(_ args: [String], verb: String) throws -> Direction {
        let word = try only(args, verb: verb, expected: Grammar.direction)
        guard let direction = Direction(rawValue: word) else {
            throw CommandSyntaxError.badArgument(verb: verb, value: word, expected: Grammar.direction)
        }
        return direction
    }

    /// `on|off|toggle`, defaulting to `.toggle` when omitted — what a keybind wants; the explicit forms
    /// are for scripts and rules.
    private static func toggle(_ args: [String], verb: String) throws -> Toggle {
        guard let word = args.first else { return .toggle }
        try noMore(args.dropFirst(), verb: verb)
        guard let toggle = Toggle(rawValue: word) else {
            throw CommandSyntaxError.badArgument(verb: verb, value: word, expected: Grammar.toggle)
        }
        return toggle
    }

    /// `100px` / `100pt` / `100` / `10%` — the argument to `grow` and `shrink`; the non-percent spellings
    /// all mean *points*. Strictly a magnitude, which also rejects `nan`, `inf` and `0`.
    private static func sizeDelta(_ args: [String], verb: String) throws -> SizeDelta {
        let word = try only(args, verb: verb, expected: Grammar.delta)
        var digits = Substring(word)
        var isPercent = false
        if digits.hasSuffix("%") {
            digits = digits.dropLast()
            isPercent = true
        } else if digits.hasSuffix("px") || digits.hasSuffix("pt") {
            digits = digits.dropLast(2)
        }
        guard let value = Double(digits), value.isFinite, value > 0 else {
            throw CommandSyntaxError.badArgument(verb: verb, value: word, expected: Grammar.delta)
        }
        return isPercent ? .percent(value) : .points(value)
    }

    /// A workspace address (`1`…`9`, `0`, `a`…`z`) or one of the four relative motions. `0` is a legal
    /// address, not an off-by-one. `prev`/`prev-non-empty` parse; the long forms are what `words` emits.
    private static func workspaceRef(_ args: [String], verb: String) throws -> WorkspaceRef {
        let word = try only(args, verb: verb, expected: Grammar.workspace)
        switch word {
        case "next": return .next
        case "previous", "prev": return .previous
        case "next-non-empty": return .nextOccupied
        case "previous-non-empty", "prev-non-empty": return .previousOccupied
        default:
            guard let name = WorkspaceName(word) else {
                throw CommandSyntaxError.badArgument(verb: verb, value: word,
                                                     expected: Grammar.workspace)
            }
            return .name(name)
        }
    }

}

// MARK: - Reference spellings
//
// The inverse halves of `parse`'s argument readers; they exist to spell `Command.words`.

extension SizeDelta {
    /// How this delta is written as a single word. Canonical: `100` and `100pt` both re-emit as `100px`.
    var word: String {
        switch self {
        case .points(let points): return Self.number(points) + "px"
        case .percent(let percent): return Self.number(percent) + "%"
        }
    }

    /// A number spelled the way it was typed — `100`, not `100.0`.
    private static func number(_ value: Double) -> String {
        guard value == value.rounded(), abs(value) < 1e15 else { return String(value) }
        return String(Int64(value))
    }
}

extension WorkspaceRef {
    /// How this reference is written as a single word (`"3"`, `"a"`, `"next"`, `"previous-non-empty"`).
    var word: String {
        switch self {
        case .name(let name): return name.description
        case .next: return "next"
        case .previous: return "previous"
        case .nextOccupied: return "next-non-empty"
        case .previousOccupied: return "previous-non-empty"
        }
    }
}
