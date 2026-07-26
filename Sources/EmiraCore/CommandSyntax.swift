import Foundation

// The *surface syntax* of the command vocabulary — how a `Command` (IMPLEMENTATION.md §2) is spelled
// as words, and how words are parsed back into one. `Command.swift` owns *what* emira can do; this
// file owns *how a human writes it down*.
//
// **Why this lives in the pure core rather than in the CLI.** Two surfaces need the identical
// string↔`Command` mapping, and they live in different targets:
//
//   · the **CLI** turns `argv` into a `Command` (`emira focus left`);
//   · the **config file** binds keys to the same words (`alt-h = "focus left"`, M5) — and
//     `ConfigLoader` lives in `EmiraShell`, which does not depend on the CLI.
//
// Putting the spelling anywhere else would fork it. Here, §2's promise holds literally: a new verb is
// a case in `Command`, an entry in `verbs`, and a line in `words` — all in this pair of files, and
// every surface picks it up for free.
//
// Two properties are load-bearing and tested:
//
//  · **Round-trip.** `Command.parse(c.words) == c` for every command. `words` is the canonical
//    spelling (an exhaustive `switch`, so the compiler catches a new case), `parse` accepts it plus a
//    couple of aliases people will type anyway (`prev`, `dump-state`).
//  · **Coverage.** The `verbs` table can't be exhaustiveness-checked by the compiler, so a test
//    asserts the table's verb names are exactly the set of first words `words` can produce.
//
// Parsing is strict and case-sensitive, like every other Unix CLI: unknown verb, missing argument,
// bad argument and trailing junk are all distinct, printable errors rather than a shrug.

/// Why a string couldn't be read as a `Command`. `CustomStringConvertible` because the message is
/// user-facing: the CLI prints it to stderr, and the config loader will prefix it with a file/line.
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

    /// This command written as argv words — the spelling `parse` accepts back unchanged.
    ///
    /// An exhaustive `switch` on purpose: adding a case to `Command` fails to compile here, which is
    /// the reminder to give the new verb a spelling and a `verbs` entry.
    public var words: [String] {
        switch self {
        case .focus(let direction):           return ["focus", direction.rawValue]
        case .moveWindow(let direction):      return ["move-window", direction.rawValue]
        case .moveToWorkspace(let ref):       return ["move-to-workspace", ref.word]
        case .moveToWorkspaceAndFocus(let r): return ["move-to-workspace-and-focus", r.word]
        case .moveToMonitor(let ref):         return ["move-to-monitor", ref.word]
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
        case .reloadConfig:                   return ["reload-config"]
        // Spelled `debug` because that's the promised user-facing verb (IMPLEMENTATION.md §6,
        // "`emira debug` (pretty-prints the state dump)"); `dump-state` parses as an alias.
        case .dumpState:                      return ["debug"]
        }
    }

    // MARK: - Parsing

    /// Read a `Command` from argv-style words (verb first, then its arguments).
    ///
    /// ```swift
    /// try Command.parse(["focus", "left"])            // .focus(.left)
    /// try Command.parse(["fullscreen"])               // .fullscreen(.toggle) — the useful default
    /// try Command.parse(["move-to-workspace", "3"])   // .moveToWorkspace(.name("3"))
    /// ```
    ///
    /// - Throws: `CommandSyntaxError`, whose `description` is already a printable diagnostic.
    public static func parse(_ words: [String]) throws -> Command {
        guard let word = words.first, !word.isEmpty else { throw CommandSyntaxError.noVerb }
        guard let verb = verbs.first(where: { $0.matches(word) }) else {
            throw CommandSyntaxError.unknownVerb(word)
        }
        // Errors always name the *canonical* verb, even when the user typed an alias.
        return try verb.build(verb.name, Array(words.dropFirst()))
    }

    /// Convenience for a whole command line as one string (a config binding's right-hand side,
    /// `"focus left"`). Splits on runs of whitespace; quoting is deliberately not a thing, because no
    /// argument in the vocabulary can contain a space.
    public static func parse(line: String) throws -> Command {
        try parse(line.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    // MARK: - Help

    /// One indented line per verb — `signature` then `summary`, columns aligned. The CLI wraps this
    /// with its own header, so the core stays free of any particular binary's name.
    public static var usage: String {
        let width = verbs.map(\.signature.count).max() ?? 0
        return verbs.map { verb in
            let padding = String(repeating: " ", count: width - verb.signature.count + 2)
            return "  \(verb.signature)\(padding)\(verb.summary)"
        }.joined(separator: "\n")
    }

    // MARK: - The verb table

    /// One spelling of one command: its canonical name, the aliases we also accept, the grammar of
    /// its arguments (for `usage`), a one-line summary, and how to build the `Command`.
    ///
    /// `build` receives the canonical verb name so its errors read the same whichever alias was typed.
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

    /// Every verb, in the order `usage` prints them (roughly: focus, move, size, state, meta).
    ///
    /// Not `private`, because the compiler can't check this table against `Command`'s cases — a test
    /// does, by comparing these names to the first word of every command's `words`.
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

        Verb("move-to-monitor", arguments: Grammar.monitor,
             summary: "Move the focused window to a monitor.",
             build: { verb, args in .moveToMonitor(try monitorRef(args, verb: verb)) }),

        Verb("reload-config", summary: "Re-read the config and re-lay-out in place.",
             build: bare(.reloadConfig)),

        Verb("debug", aliases: ["dump-state"], summary: "Print the daemon's live state as JSON.",
             build: bare(.dumpState)),
    ]

    // MARK: - Grammar fragments (one spelling, used by both `usage` and the error messages)

    private enum Grammar {
        static let direction = "<left|right|up|down>"
        static let toggle = "[on|off|toggle]"
        // The four relative motions are folded into one bracket rather than listed flat
        // (`next|prev|next-non-empty|prev-non-empty`, 15 characters longer). `usage` pads every
        // summary to the widest signature, and this fragment appears on the longest verb in the
        // table — spelled flat it pushed *every* other verb's summary out past column 90.
        static let workspace = "<0-9|a-z|(next|prev)[-non-empty]>"
        static let monitor = "<left|right|up|down|next|prev|N>"
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

    /// `on|off|toggle`, defaulting to `.toggle` when omitted — the spelling a keybind actually wants
    /// (`fullscreen` alone is the common case; `fullscreen off` is for scripts and rules).
    private static func toggle(_ args: [String], verb: String) throws -> Toggle {
        guard let word = args.first else { return .toggle }
        try noMore(args.dropFirst(), verb: verb)
        guard let toggle = Toggle(rawValue: word) else {
            throw CommandSyntaxError.badArgument(verb: verb, value: word, expected: Grammar.toggle)
        }
        return toggle
    }

    /// `100px` / `100pt` / `100` / `10%` — the argument to `grow` and `shrink`.
    ///
    /// **A magnitude, strictly.** The verb carries the sign, so `grow -10%` is refused rather than
    /// quietly becoming a second spelling of `shrink 10%` — one operation, one spelling. The guard also
    /// catches everything else `Double` is happy to read: `nan`, `inf`, `1e400`, and `0` (a resize by
    /// nothing is a typo, the same judgement `monitorRef` makes about index `0`).
    ///
    /// `px` and `pt` are the same suffix, and a bare number means points too. The core's unit is
    /// **points** everywhere — CoreGraphics' unit, not device pixels — but `px` is what people reach
    /// for, so it is accepted rather than corrected.
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

    /// A workspace address (`1`…`9`, `0`, `a`…`z`) or one of the four relative motions.
    ///
    /// **`0` names the first workspace; it used to be a syntax error** (reversed 2026-07-26). This
    /// reader parsed a 1-based `Int` and refused `0` with the comment *"`0` is a mistake, not workspace
    /// zero"* — which was right while workspaces were a dynamic list the user counted from one. They
    /// are a fixed named domain now (`WorkspaceName`), `0` is its first address, and it is where focus
    /// rests at launch. The guard is deleted knowingly rather than adapted: there is no index left to
    /// be off by one.
    ///
    /// Two of the four motions take a short spelling as well (`prev`, `prev-non-empty`) because they
    /// are what people type; the canonical spellings are the long ones, and `Command.words` emits those.
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

    private static func monitorRef(_ args: [String], verb: String) throws -> MonitorRef {
        let word = try only(args, verb: verb, expected: Grammar.monitor)
        if let direction = Direction(rawValue: word) { return .direction(direction) }
        switch word {
        case "next": return .next
        case "previous", "prev": return .previous
        default:
            guard let index = Int(word), index >= 1 else {
                throw CommandSyntaxError.badArgument(verb: verb, value: word, expected: Grammar.monitor)
            }
            return .index(index)
        }
    }
}

// MARK: - Reference spellings
//
// The inverse halves of `parse`'s argument readers. Internal, not public: they exist to spell
// `Command.words`, which is the public surface.

extension SizeDelta {
    /// How this delta is written as a single word (`"100px"`, `"10%"`). Canonical: a bare `100` and
    /// `100pt` both parse, and both come back out as `100px`.
    var word: String {
        switch self {
        case .points(let points): return Self.number(points) + "px"
        case .percent(let percent): return Self.number(percent) + "%"
        }
    }

    /// A number spelled the way it was typed — `100`, not `100.0`. Only whole values take the integer
    /// path (and only in a range `Int64` can hold); everything else keeps its decimal form, which
    /// `Double.init` reads back exactly.
    private static func number(_ value: Double) -> String {
        guard value == value.rounded(), abs(value) < 1e15 else { return String(value) }
        return String(Int64(value))
    }
}

extension WorkspaceRef {
    /// How this reference is written as a single word (`"3"`, `"a"`, `"next"`, `"prev-non-empty"`'s
    /// canonical `"previous-non-empty"`).
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

extension MonitorRef {
    /// How this reference is written as a single word (`"left"`, `"next"`, `"2"`).
    var word: String {
        switch self {
        case .direction(let direction): return direction.rawValue
        case .index(let index): return String(index)
        case .next: return "next"
        case .previous: return "previous"
        }
    }
}
