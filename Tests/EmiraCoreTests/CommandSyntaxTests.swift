import Foundation
import Testing
@testable import EmiraCore

/// The surface syntax of the vocabulary (`CommandSyntax.swift`) — the spelling shared by the CLI and
/// (at M5) the config file's keybindings. Two properties carry the file: every command **round-trips**
/// through its canonical words, and the verb table **covers** every case (the one thing the compiler
/// can't check here). The rest is diagnostics: each way of getting it wrong is a distinct, printable
/// error rather than a shrug.
@Suite struct CommandSyntaxTests {

    /// One of every case, including each supporting-enum shape. Kept in the same spirit as
    /// `CommandTests.everyCommandRoundTrips` — a new `Command` case is meant to be added here too,
    /// and `verbTableCoversEveryCommand` fails if the table and this list disagree.
    static let all: [Command] = [
        .focus(.left), .focus(.right), .focus(.up), .focus(.down),
        .moveWindow(.left), .moveWindow(.down),
        .moveToWorkspace(.index(3)), .moveToWorkspace(.next), .moveToWorkspace(.previous),
        .moveToMonitor(.direction(.right)), .moveToMonitor(.index(2)),
        .moveToMonitor(.next), .moveToMonitor(.previous),
        .cycleWidth, .cycleHeight,
        .consumeOrExpel(.left), .consumeOrExpel(.right),
        .fullscreen(.on), .fullscreen(.off), .fullscreen(.toggle),
        .float(.on), .float(.off), .float(.toggle),
        .focusWorkspace(.index(1)), .focusWorkspace(.next), .focusWorkspace(.previous),
        .closeWindow, .centerColumn, .reloadConfig, .dumpState,
    ]

    // MARK: - The two load-bearing properties

    @Test func everyCommandRoundTripsThroughItsWords() throws {
        for command in Self.all {
            let words = command.words
            #expect(try Command.parse(words) == command,
                    "round-trip changed \(command) (spelled '\(words.joined(separator: " "))')")
        }
    }

    /// The `verbs` table can't be exhaustiveness-checked by the compiler, so check it against the one
    /// thing that *is* exhaustive: the `words` switch. A new case with no table entry (unparseable) or
    /// a table entry no command produces (dead verb) both fail here.
    @Test func verbTableCoversEveryCommand() {
        let spelled = Set(Self.all.compactMap(\.words.first))
        let tabled = Set(Command.verbs.map(\.name))
        #expect(spelled == tabled,
                "unparseable: \(spelled.subtracting(tabled).sorted()); dead: \(tabled.subtracting(spelled).sorted())")
    }

    // MARK: - Canonical spellings (pinned — they're a user-facing contract)

    @Test func canonicalSpellingsAreStable() {
        #expect(Command.focus(.left).words == ["focus", "left"])
        #expect(Command.moveWindow(.down).words == ["move-window", "down"])
        #expect(Command.moveToWorkspace(.index(3)).words == ["move-to-workspace", "3"])
        #expect(Command.moveToWorkspace(.previous).words == ["move-to-workspace", "previous"])
        #expect(Command.moveToMonitor(.direction(.right)).words == ["move-to-monitor", "right"])
        #expect(Command.consumeOrExpel(.left).words == ["consume-or-expel", "left"])
        #expect(Command.fullscreen(.toggle).words == ["fullscreen", "toggle"])
        #expect(Command.cycleWidth.words == ["cycle-width"])
        #expect(Command.closeWindow.words == ["close-window"])
        #expect(Command.reloadConfig.words == ["reload-config"])
        // `emira debug` is the documented user-facing verb for `dumpState` (IMPLEMENTATION.md §6).
        #expect(Command.dumpState.words == ["debug"])
    }

    @Test func aliasesParseToTheSameCommand() throws {
        #expect(try Command.parse(["dump-state"]) == .dumpState)
        #expect(try Command.parse(["focus-workspace", "prev"]) == .focusWorkspace(.previous))
        #expect(try Command.parse(["move-to-workspace", "prev"]) == .moveToWorkspace(.previous))
        #expect(try Command.parse(["move-to-monitor", "prev"]) == .moveToMonitor(.previous))
    }

    /// The spelling a keybind actually wants: bare `fullscreen` means "flip it".
    @Test func togglesDefaultToToggleWhenTheArgumentIsOmitted() throws {
        #expect(try Command.parse(["fullscreen"]) == .fullscreen(.toggle))
        #expect(try Command.parse(["float"]) == .float(.toggle))
        #expect(try Command.parse(["float", "off"]) == .float(.off))
    }

    /// The form a config binding's right-hand side arrives in (`alt-h = "focus left"`, M5).
    @Test func aWholeLineParsesLikeArgv() throws {
        #expect(try Command.parse(line: "focus left") == .focus(.left))
        #expect(try Command.parse(line: "  move-to-workspace   2  ") == .moveToWorkspace(.index(2)))
        #expect(try Command.parse(line: "cycle-width") == .cycleWidth)
    }

    // MARK: - Diagnostics

    @Test func anEmptyInvocationIsNoVerb() {
        #expect(throws: CommandSyntaxError.noVerb) { try Command.parse([]) }
        #expect(throws: CommandSyntaxError.noVerb) { try Command.parse([""]) }
        #expect(throws: CommandSyntaxError.noVerb) { try Command.parse(line: "   ") }
    }

    @Test func anUnknownVerbNamesTheWordTyped() {
        #expect(throws: CommandSyntaxError.unknownVerb("frobnicate")) {
            try Command.parse(["frobnicate", "left"])
        }
        // Near-misses are unknown verbs, not helpful guesses — no fuzzy matching by design.
        #expect(throws: CommandSyntaxError.unknownVerb("move")) { try Command.parse(["move", "left"]) }
    }

    @Test func aMissingArgumentNamesTheGrammar() throws {
        let error = try #require(throws: CommandSyntaxError.self) { try Command.parse(["focus"]) }
        #expect(error == .missingArgument(verb: "focus", expected: "<left|right|up|down>"))
        #expect("\(error)" == "'focus' needs an argument: <left|right|up|down>")
    }

    @Test func aBadArgumentNamesTheValueAndTheGrammar() throws {
        let error = try #require(throws: CommandSyntaxError.self) {
            try Command.parse(["focus", "sideways"])
        }
        #expect(error == .badArgument(verb: "focus", value: "sideways",
                                      expected: "<left|right|up|down>"))
        #expect("\(error)".contains("sideways"))

        #expect(throws: CommandSyntaxError.badArgument(verb: "fullscreen", value: "yes",
                                                       expected: "[on|off|toggle]")) {
            try Command.parse(["fullscreen", "yes"])
        }
    }

    /// Workspaces and monitors are 1-based the way a user counts them, so `0` is a mistake — and a
    /// silently-accepted `0` would index a different workspace than the one typed.
    @Test func referenceIndicesAreOneBasedAndPositive() throws {
        #expect(try Command.parse(["focus-workspace", "1"]) == .focusWorkspace(.index(1)))
        #expect(try Command.parse(["move-to-monitor", "2"]) == .moveToMonitor(.index(2)))
        for bad in ["0", "-1", "two", "1.5", ""] {
            #expect(throws: CommandSyntaxError.self) { try Command.parse(["focus-workspace", bad]) }
            #expect(throws: CommandSyntaxError.self) { try Command.parse(["move-to-monitor", bad]) }
        }
    }

    /// Trailing junk is a typo (`emira focus left right`), and swallowing it would silently do
    /// something the user didn't ask for.
    @Test func trailingWordsAreRefused() throws {
        let error = try #require(throws: CommandSyntaxError.self) {
            try Command.parse(["focus", "left", "right"])
        }
        #expect(error == .tooManyArguments(verb: "focus", extra: ["right"]))

        #expect(throws: CommandSyntaxError.tooManyArguments(verb: "cycle-width", extra: ["2"])) {
            try Command.parse(["cycle-width", "2"])
        }
        #expect(throws: CommandSyntaxError.tooManyArguments(verb: "fullscreen", extra: ["please"])) {
            try Command.parse(["fullscreen", "on", "please"])
        }
    }

    /// An alias in, the canonical name out — so the message reads the same however it was typed.
    @Test func errorsNameTheCanonicalVerbEvenAfterAnAlias() throws {
        let error = try #require(throws: CommandSyntaxError.self) {
            try Command.parse(["dump-state", "now"])
        }
        #expect(error == .tooManyArguments(verb: "debug", extra: ["now"]))
    }

    // MARK: - Help

    @Test func usageListsEveryVerbWithItsGrammarInAlignedColumns() {
        let lines = Command.usage.split(separator: "\n").map(String.init)
        #expect(lines.count == Command.verbs.count)

        var summaryColumns: Set<Int> = []
        for (line, verb) in zip(lines, Command.verbs) {
            #expect(line.hasPrefix("  " + verb.signature), "usage line for '\(verb.name)': \(line)")
            #expect(line.hasSuffix(verb.summary), "usage line for '\(verb.name)': \(line)")
            summaryColumns.insert(line.count - verb.summary.count)
        }
        #expect(summaryColumns.count == 1, "summaries are not aligned: \(summaryColumns.sorted())")
    }
}
