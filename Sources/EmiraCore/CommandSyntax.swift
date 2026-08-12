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

// The vocabulary as a table
//
// **The grammar is data, not prose.** A surface that has to *offer* the vocabulary — a keybinding editor
// picking a verb and then whatever that verb takes — cannot read `usage` and cannot call `parse`, because
// both answer only after the user has already typed something. So the table carries each verb's argument
// as a shape, and the printed grammar falls out of it: `Grammar.direction = "<left|right|up|down>"` and
// `Direction(rawValue:)` were two statements of one fact, and now there is one.
//
// The shape is `Argument`, and the rule is `Setting.Kind`'s one vocabulary over: **one case per shape of
// control, never per verb.** Five cases carry twenty-one verbs.

/// The command vocabulary: every verb emira answers to, and the grammar of what each one takes.
///
/// Top-level rather than nested in `Command` because a consumer of the *spellings* is not a consumer of
/// the reducer's input — the settings window offers `focus left` as four words and never names the type
/// that parses back to.
public enum Vocabulary {

    /// The verb `word` names, by its canonical spelling or any of its aliases.
    public static func verb(named word: String) -> Verb? {
        verbs.first { $0.matches(word) }
    }

    /// One indented line per verb, columns aligned. The CLI adds its own header.
    public static var usage: String {
        let width = verbs.map(\.signature.count).max() ?? 0
        return verbs.map { verb in
            let padding = String(repeating: " ", count: width - verb.signature.count + 2)
            return "  \(verb.signature)\(padding)\(verb.summary)"
        }.joined(separator: "\n")
    }
}

/// One spelling of one command: canonical name, aliases, what it takes, and a summary.
///
/// `build` is deliberately **not public**. The vocabulary is offerable outside this module; turning
/// words into the reducer's input is not.
public struct Verb: Sendable {
    public let name: String
    public let aliases: [String]
    public let summary: String
    /// The grammar of this verb's argument — what a control has to ask for, and what `signature` prints.
    public let argument: Argument

    /// How this verb builds its command. Gets the whole verb, so a diagnostic can name the canonical
    /// spelling and the grammar without either being restated at the call site.
    let build: @Sendable (Verb, [String]) throws -> Command

    init(_ name: String, aliases: [String] = [], argument: Argument = .none, summary: String,
         build: @escaping @Sendable (Verb, [String]) throws -> Command) {
        self.name = name
        self.aliases = aliases
        self.argument = argument
        self.summary = summary
        self.build = build
    }

    /// `"focus <left|right|up|down>"` — the left column of `usage`, derived from the argument.
    public var signature: String {
        let grammar = argument.signature
        return grammar.isEmpty ? name : "\(name) \(grammar)"
    }

    /// This verb's argument is the rest of the line, verbatim — `parse(line:)` hands it over unsplit.
    /// Only a `.line` takes one, and only because a shell line owns its own whitespace.
    var takesRawTail: Bool {
        if case .line = argument { return true }
        return false
    }

    public func matches(_ word: String) -> Bool { word == name || aliases.contains(word) }

    /// What a verb takes after its name — **one case per shape of control**, which is why five of them
    /// cover twenty-one verbs. A case serving a single verb is the sign the table has stopped paying for
    /// itself; `.line` sits at that edge and earns it by being the only genuinely open argument here.
    public enum Argument: Sendable, Equatable {
        /// Nothing. The verb is the whole command, and a word after it is a typo.
        case none

        /// One of a fixed set of words. `fallback` is what an omitted argument means — which is what
        /// makes a bare `fullscreen` flip it — and `nil` is an argument the verb requires.
        case words([String], default: String?)

        /// A relative motion, or a specific address. Two halves because that is what the control is: a
        /// popup of the motions plus one rung that reveals a field for `name`.
        ///
        /// `grammar` is spelled rather than derived, and it is the one place in this type that is.
        /// `words` is what may be *offered* — the canonical relative spellings — while the printed
        /// grammar compresses an accepted set that also holds aliases and a 36-address alphabet:
        /// `(next|prev)[-non-empty]` is editorial, and listing the set flat widens every usage line by
        /// sixteen columns to say the same thing.
        case address(words: [String], name: Name, grammar: String)

        /// A positive magnitude carrying one of `units`. Nothing to hint: a number field and a unit
        /// toggle cannot be spelled wrong.
        case magnitude(units: [String])

        /// The rest of the line, verbatim.
        case line(placeholder: String)

        /// What the field beside an address popup takes.
        public enum Name: Sendable, Equatable {
            /// One of a fixed alphabet of one-character addresses — the 36 workspaces.
            case alphabet([String])
            /// A whole number at or above a floor — a display's place in the enumeration.
            case number(atLeast: Int)
        }

        /// The grammar fragment `usage` prints and a diagnostic names. **Angle brackets for an argument
        /// the verb needs, square for one it can do without** — the distinction `[on|off|toggle]` has
        /// always carried, now falling out of the default rather than being spelled beside it.
        public var signature: String {
            switch self {
            case .none:
                return ""
            case .words(let words, let fallback):
                let listed = words.joined(separator: "|")
                return fallback == nil ? "<\(listed)>" : "[\(listed)]"
            case .address(_, _, let grammar):
                return "<\(grammar)>"
            case .magnitude(let units):
                return "<" + units.map { "N\($0)" }.joined(separator: "|") + ">"
            case .line(let placeholder):
                return "<\(placeholder)>"
            }
        }
    }
}

extension Command {

    // Rendering (the canonical spelling)

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
        case .focusMonitor(let ref):          return ["focus-monitor", ref.word]
        case .moveToMonitor(let ref):         return ["move-to-monitor", ref.word]
        case .moveToMonitorAndFocus(let r):   return ["move-to-monitor-and-focus", r.word]
        case .moveWorkspaceToMonitor(let r):  return ["move-workspace-to-monitor", r.word]
        case .moveWorkspaceToMonitorAndFocus(let r):
            return ["move-workspace-to-monitor-and-focus", r.word]
        case .closeWindow:                    return ["close-window"]
        case .centerColumn:                   return ["center-column"]
        case .exec(let line):                 return ["exec", line]
        // `debug` is the user-facing spelling; `dump-state` parses as an alias.
        case .dumpState:                      return ["debug"]
        }
    }

    /// Read a `Command` from argv-style words (verb first, then its arguments).
    /// - Throws: `CommandSyntaxError`, whose `description` is already a printable diagnostic.
    public static func parse(_ words: [String]) throws -> Command {
        guard let word = words.first, !word.isEmpty else { throw CommandSyntaxError.noVerb }
        guard let verb = Vocabulary.verb(named: word) else {
            throw CommandSyntaxError.unknownVerb(word)
        }
        // Errors always name the *canonical* verb, even when the user typed an alias.
        return try verb.build(verb, Array(words.dropFirst()))
    }

    /// Convenience for a whole command line as one string (a config binding's right-hand side). Splits
    /// on whitespace runs; there is no quoting, because no argument in the vocabulary contains a space
    /// — except a raw-tail verb's, which is why the split is skipped entirely for those.
    public static func parse(line: String) throws -> Command {
        let text = line.drop(while: \.isWhitespace)
        let head = text.prefix(while: { !$0.isWhitespace })
        // `exec`'s argument is a shell line, so the whitespace in it is the user's, not a separator.
        if let verb = Vocabulary.verb(named: String(head)), verb.takesRawTail {
            let tail = text.dropFirst(head.count).trimmed
            return try verb.build(verb, tail.isEmpty ? [] : [String(tail)])
        }
        return try parse(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }
}

extension Vocabulary {

    /// Every verb, in the order `usage` prints them. Not `private`: the compiler can't check this table
    /// against `Command`'s cases, so a test does.
    ///
    /// **Every choice is read off the type that parses it back.** `Direction.allCases` is what `.words`
    /// carries and what `Direction(rawValue:)` accepts, so the grammar in `usage` and the set the parser
    /// admits cannot drift; the addresses are the one pair that also needs an editorial spelling, and
    /// `Argument.address` says why.
    public static let verbs: [Verb] = [
        Verb("focus", argument: .direction,
             summary: "Focus the neighbouring column or window.",
             build: { verb, args in .focus(try direction(args, verb: verb)) }),

        Verb("move-window", argument: .direction,
             summary: "Move the focused window one slot.",
             build: { verb, args in .moveWindow(try direction(args, verb: verb)) }),

        Verb("consume-or-expel", argument: .direction,
             summary: "Pull a window into or out of the column.",
             build: { verb, args in .consumeOrExpel(try direction(args, verb: verb)) }),

        Verb("center-column", summary: "Centre the focused column in the viewport.",
             build: bare(.centerColumn)),

        Verb("cycle-width", summary: "Cycle the column through the width presets.",
             build: bare(.cycleWidth)),

        Verb("grow", argument: .delta,
             summary: "Widen the focused column.",
             build: { verb, args in .grow(try sizeDelta(args, verb: verb)) }),

        Verb("shrink", argument: .delta,
             summary: "Narrow the focused column.",
             build: { verb, args in .shrink(try sizeDelta(args, verb: verb)) }),

        Verb("cycle-height", summary: "Cycle the window through the height presets.",
             build: bare(.cycleHeight)),

        Verb("fullscreen", argument: .toggle,
             summary: "Toggle the focused window to the strip's full width, and back.",
             build: { verb, args in .fullscreen(try toggle(args, verb: verb)) }),

        Verb("float", argument: .toggle,
             summary: "Toggle floating for the focused window.",
             build: { verb, args in .float(try toggle(args, verb: verb)) }),

        Verb("close-window", summary: "Close the focused window.", build: bare(.closeWindow)),

        Verb("focus-workspace", argument: .workspace,
             summary: "Switch to a workspace, wherever it lives.",
             build: { verb, args in .focusWorkspace(try workspaceRef(args, verb: verb)) }),

        Verb("move-to-workspace", argument: .workspace,
             summary: "Move the focused window to a workspace.",
             build: { verb, args in .moveToWorkspace(try workspaceRef(args, verb: verb)) }),

        Verb("move-to-workspace-and-focus", argument: .workspace,
             summary: "Move the focused window to a workspace and follow it.",
             build: { verb, args in .moveToWorkspaceAndFocus(try workspaceRef(args, verb: verb)) }),

        Verb("focus-monitor", argument: .monitor,
             summary: "Move to another display, whatever it is showing.",
             build: { verb, args in .focusMonitor(try monitorRef(args, verb: verb)) }),

        Verb("move-to-monitor", argument: .monitor,
             summary: "Move the focused window to what another display is showing.",
             build: { verb, args in .moveToMonitor(try monitorRef(args, verb: verb)) }),

        Verb("move-to-monitor-and-focus", argument: .monitor,
             summary: "Move the focused window to another display and follow it.",
             build: { verb, args in .moveToMonitorAndFocus(try monitorRef(args, verb: verb)) }),

        Verb("move-workspace-to-monitor", argument: .monitor,
             summary: "Hand this workspace to another display.",
             build: { verb, args in .moveWorkspaceToMonitor(try monitorRef(args, verb: verb)) }),

        Verb("move-workspace-to-monitor-and-focus", argument: .monitor,
             summary: "Hand this workspace to another display and follow it.",
             build: { verb, args in .moveWorkspaceToMonitorAndFocus(try monitorRef(args, verb: verb)) }),

        Verb("exec", argument: .line(placeholder: "shell command"),
             summary: "Run a shell command line, without waiting for it.",
             build: { verb, args in .exec(try commandLine(args, verb: verb)) }),

        Verb("debug", aliases: ["dump-state"], summary: "Print the daemon's live state as JSON.",
             build: bare(.dumpState)),
    ]

    /// A verb that takes no arguments: any word after it is a typo, not something to ignore.
    private static func bare(_ command: Command) -> @Sendable (Verb, [String]) throws -> Command {
        { verb, args in
            try noMore(args[...], verb: verb.name)
            return command
        }
    }

    /// Exactly one argument, or a precise complaint about which way it was wrong. The grammar named in
    /// either complaint is the verb's own, so the sentence and the usage line cannot disagree.
    private static func only(_ args: [String], verb: Verb) throws -> String {
        guard let first = args.first else {
            throw CommandSyntaxError.missingArgument(verb: verb.name,
                                                     expected: verb.argument.signature)
        }
        try noMore(args.dropFirst(), verb: verb.name)
        return first
    }

    private static func noMore(_ extra: ArraySlice<String>, verb: String) throws {
        guard extra.isEmpty else {
            throw CommandSyntaxError.tooManyArguments(verb: verb, extra: Array(extra))
        }
    }

    private static func badArgument(_ word: String, verb: Verb) -> CommandSyntaxError {
        .badArgument(verb: verb.name, value: word, expected: verb.argument.signature)
    }

    private static func direction(_ args: [String], verb: Verb) throws -> Direction {
        let word = try only(args, verb: verb)
        guard let direction = Direction(rawValue: word) else { throw badArgument(word, verb: verb) }
        return direction
    }

    /// `on|off|toggle`, defaulting to `.toggle` when omitted — what a keybind wants; the explicit forms
    /// are for scripts and rules.
    private static func toggle(_ args: [String], verb: Verb) throws -> Toggle {
        guard let word = args.first else { return .toggle }
        try noMore(args.dropFirst(), verb: verb.name)
        guard let toggle = Toggle(rawValue: word) else { throw badArgument(word, verb: verb) }
        return toggle
    }

    /// `100px` / `100pt` / `100` / `10%` — the argument to `grow` and `shrink`; the non-percent spellings
    /// all mean *points*. Strictly a magnitude, which also rejects `nan`, `inf` and `0`.
    ///
    /// `pt` and a bare number are accepted spellings of `px` rather than units in their own right —
    /// aliases, exactly as a verb has them, so `.magnitude` lists what may be *offered*.
    private static func sizeDelta(_ args: [String], verb: Verb) throws -> SizeDelta {
        let word = try only(args, verb: verb)
        var digits = Substring(word)
        var isPercent = false
        if digits.hasSuffix("%") {
            digits = digits.dropLast()
            isPercent = true
        } else if digits.hasSuffix("px") || digits.hasSuffix("pt") {
            digits = digits.dropLast(2)
        }
        guard let value = Double(digits), value.isFinite, value > 0 else {
            throw badArgument(word, verb: verb)
        }
        return isPercent ? .percent(value) : .points(value)
    }

    /// The rest of the line as one string — `exec`'s shell command. From `parse(line:)` that already
    /// *is* one element (the tail was never split); from argv it is what the user's own shell left
    /// after quoting, rejoined, so both spellings of the same press agree.
    private static func commandLine(_ args: [String], verb: Verb) throws -> String {
        let line = args.joined(separator: " ").trimmed
        guard !line.isEmpty else {
            throw CommandSyntaxError.missingArgument(verb: verb.name,
                                                     expected: verb.argument.signature)
        }
        return String(line)
    }

    /// A workspace address (`1`…`9`, `0`, `a`…`z`) or one of the four relative motions. `0` is a legal
    /// address, not an off-by-one. `prev`/`prev-non-empty` parse; the long forms are what `words` emits.
    private static func workspaceRef(_ args: [String], verb: Verb) throws -> WorkspaceRef {
        let word = try only(args, verb: verb)
        switch word {
        case "next": return .next
        case "previous", "prev": return .previous
        case "next-non-empty": return .nextOccupied
        case "previous-non-empty", "prev-non-empty": return .previousOccupied
        default:
            guard let name = WorkspaceName(word) else { throw badArgument(word, verb: verb) }
            return .name(name)
        }
    }

    /// A display index (1-based), a direction, or one of the two enumeration steps. Numbers below 1
    /// are refused rather than clamped: `focus-monitor 0` is a typo for `1`, and reading it as one
    /// would make the off-by-one silent — the resolution, which clamps, is a different question from
    /// the spelling.
    private static func monitorRef(_ args: [String], verb: Verb) throws -> MonitorRef {
        let word = try only(args, verb: verb)
        switch word {
        case "next": return .next
        case "previous", "prev": return .previous
        default:
            if let direction = Direction(rawValue: word) { return .direction(direction) }
            guard let index = Int(word), index >= 1 else { throw badArgument(word, verb: verb) }
            return .index(index)
        }
    }

}

// The five grammars the table spends, each read off the type that parses it back.

extension Verb.Argument {

    /// `<left|right|up|down>` — the strip's two axes.
    static let direction = Verb.Argument.words(Direction.allCases.map(\.rawValue), default: nil)

    /// `[on|off|toggle]`, and the default is what makes a bare `fullscreen` flip it.
    static let toggle = Verb.Argument.words(Toggle.allCases.map(\.rawValue),
                                            default: Toggle.toggle.rawValue)

    /// `<Npx|N%>`. Points and a percentage of the working extent.
    static let delta = Verb.Argument.magnitude(units: ["px", "%"])

    /// One of the 36 addresses, or a relative motion. The relatives are spelled the way `words` emits
    /// them; `usage` compresses the accepted set, aliases and all.
    static let workspace = Verb.Argument.address(
        words: [WorkspaceRef.next, .previous, .nextOccupied, .previousOccupied].map(\.word),
        name: .alphabet(WorkspaceName.all.map(\.description)),
        grammar: "0-9|a-z|(next|prev)[-non-empty]")

    /// A display's place in the enumeration, a direction, or a step along it.
    static let monitor = Verb.Argument.address(
        words: Direction.allCases.map { MonitorRef.direction($0).word }
            + [MonitorRef.next, .previous].map(\.word),
        name: .number(atLeast: 1),
        grammar: "N|left|right|up|down|next|prev")
}

extension StringProtocol {
    /// Both ends stripped of whitespace. Only a raw tail needs it — every other argument is a word
    /// the split had already delimited.
    var trimmed: SubSequence {
        guard let first = firstIndex(where: { !$0.isWhitespace }),
              let last = lastIndex(where: { !$0.isWhitespace }) else { return self[endIndex...] }
        return self[first...last]
    }
}

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

extension MonitorRef {
    /// How this reference is written as a single word (`"2"`, `"left"`, `"next"`, `"previous"`).
    var word: String {
        switch self {
        case .index(let n): return String(n)
        case .direction(let direction): return direction.rawValue
        case .next: return "next"
        case .previous: return "previous"
        }
    }
}
