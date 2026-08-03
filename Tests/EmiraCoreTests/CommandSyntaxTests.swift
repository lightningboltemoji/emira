import Foundation
import Testing
@testable import EmiraCore

/// The surface syntax of the vocabulary — the spelling shared by the CLI and the config file's
/// keybindings. Two properties carry the file: every command round-trips through its canonical words,
/// and the verb table covers every case (the one thing the compiler can't check here). The rest is
/// diagnostics: each way of getting it wrong is a distinct, printable error rather than a shrug.
@Suite struct CommandSyntaxTests {

    /// One of every case, including each supporting-enum shape. Kept in the same spirit as
    /// `CommandTests.everyCommandRoundTrips` — a new `Command` case is meant to be added here too,
    /// and `verbTableCoversEveryCommand` fails if the table and this list disagree.
    static let all: [Command] = [
        .focus(.left), .focus(.right), .focus(.up), .focus(.down),
        .moveWindow(.left), .moveWindow(.down),
        .moveToWorkspace(.name(WorkspaceName("3")!)), .moveToWorkspace(.next),
        .moveToWorkspace(.previous), .moveToWorkspace(.nextOccupied),
        .moveToWorkspace(.previousOccupied),
        .moveToWorkspaceAndFocus(.name(WorkspaceName("a")!)), .moveToWorkspaceAndFocus(.next),
        .cycleWidth, .cycleHeight,
        .grow(.points(100)), .grow(.percent(10)),
        .shrink(.points(12.5)), .shrink(.percent(5)),
        .consumeOrExpel(.left), .consumeOrExpel(.right),
        .fullscreen(.on), .fullscreen(.off), .fullscreen(.toggle),
        .float(.on), .float(.off), .float(.toggle),
        .focusWorkspace(.name(.first)), .focusWorkspace(.name(.last)),
        .focusWorkspace(.next), .focusWorkspace(.previous),
        .focusWorkspace(.nextOccupied), .focusWorkspace(.previousOccupied),
        .focusMonitor(.index(1)), .focusMonitor(.index(12)), .focusMonitor(.direction(.left)),
        .focusMonitor(.direction(.down)), .focusMonitor(.next), .focusMonitor(.previous),
        .moveToMonitor(.index(2)), .moveToMonitor(.direction(.right)),
        .moveToMonitorAndFocus(.next), .moveToMonitorAndFocus(.direction(.up)),
        .moveWorkspaceToMonitor(.previous), .moveWorkspaceToMonitor(.index(3)),
        .moveWorkspaceToMonitorAndFocus(.next), .moveWorkspaceToMonitorAndFocus(.direction(.left)),
        .closeWindow, .centerColumn, .dumpState,
        .exec("ghostty"), .exec("osascript -e 'tell application \"Ghostty\" to new window'"),
    ]

    // The two load-bearing properties

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

    /// **`config` is not a verb.** The CLI branches on that word before `Command.parse` ever sees it —
    /// the config file is a file it reads, not a thing the daemon is asked to do — so a verb spelled
    /// that way would be unreachable, and unreachable *silently*.
    @Test func noVerbIsSpelledConfig() {
        #expect(!Command.verbs.contains { $0.matches("config") })
    }

    // Canonical spellings (pinned — they're a user-facing contract)

    @Test func canonicalSpellingsAreStable() {
        #expect(Command.focus(.left).words == ["focus", "left"])
        #expect(Command.moveWindow(.down).words == ["move-window", "down"])
        #expect(Command.moveToWorkspace(.name(WorkspaceName("3")!)).words == ["move-to-workspace", "3"])
        #expect(Command.moveToWorkspace(.previous).words == ["move-to-workspace", "previous"])
        #expect(Command.moveToWorkspaceAndFocus(.name(WorkspaceName("a")!)).words
                == ["move-to-workspace-and-focus", "a"])
        #expect(Command.focusWorkspace(.nextOccupied).words == ["focus-workspace", "next-non-empty"])
        #expect(Command.focusWorkspace(.previousOccupied).words
                == ["focus-workspace", "previous-non-empty"])
        #expect(Command.consumeOrExpel(.left).words == ["consume-or-expel", "left"])
        #expect(Command.fullscreen(.toggle).words == ["fullscreen", "toggle"])
        #expect(Command.cycleWidth.words == ["cycle-width"])
        #expect(Command.closeWindow.words == ["close-window"])
        // `emira debug` is the documented user-facing verb for `dumpState`.
        #expect(Command.dumpState.words == ["debug"])
    }

    @Test func aliasesParseToTheSameCommand() throws {
        #expect(try Command.parse(["dump-state"]) == .dumpState)
        #expect(try Command.parse(["focus-workspace", "prev"]) == .focusWorkspace(.previous))
        #expect(try Command.parse(["move-to-workspace", "prev"]) == .moveToWorkspace(.previous))
        // `prev-non-empty` is the short spelling; `previous-non-empty` is what `words` emits.
        #expect(try Command.parse(["focus-workspace", "prev-non-empty"])
                == .focusWorkspace(.previousOccupied))
        #expect(try Command.parse(["focus-workspace", "previous-non-empty"])
                == .focusWorkspace(.previousOccupied))
    }

    /// The spelling a keybind actually wants: bare `fullscreen` means "flip it".
    @Test func togglesDefaultToToggleWhenTheArgumentIsOmitted() throws {
        #expect(try Command.parse(["fullscreen"]) == .fullscreen(.toggle))
        #expect(try Command.parse(["float"]) == .float(.toggle))
        #expect(try Command.parse(["float", "off"]) == .float(.off))
    }

    /// The form a config binding's right-hand side arrives in (`alt-h = "focus left"`).
    @Test func aWholeLineParsesLikeArgv() throws {
        #expect(try Command.parse(line: "focus left") == .focus(.left))
        #expect(try Command.parse(line: "  move-to-workspace   2  ")
                == .moveToWorkspace(.name(WorkspaceName("2")!)))
        #expect(try Command.parse(line: "cycle-width") == .cycleWidth)
    }

    // `exec`, the one verb whose argument owns its own whitespace

    /// The motivating binding: a shell line whose interior quoting and spacing must survive intact.
    /// Every other verb's argument is a word, so `parse(line:)` splits — for this one it must not.
    @Test func execTakesTheRestOfTheLineVerbatim() throws {
        let script = "osascript -e 'tell application \"Ghostty\" to new window'"
        #expect(try Command.parse(line: "exec \(script)") == .exec(script))
        // Interior runs of whitespace are the user's, not separators.
        #expect(try Command.parse(line: "exec echo  a   b") == .exec("echo  a   b"))
        // Words that would otherwise be verbs or arguments are just text here.
        #expect(try Command.parse(line: "exec focus left") == .exec("focus left"))
    }

    /// From argv the user's own shell has already done the splitting, so the tail is rejoined — which
    /// is what makes `emira exec …` and the config's `exec …` land on the same string.
    @Test func execFromArgvRejoinsWhatTheShellSplit() throws {
        #expect(try Command.parse(["exec", "open", "-a", "Ghostty"]) == .exec("open -a Ghostty"))
        // The single-argument spelling (the user quoted it) is the one `words` round-trips through.
        #expect(try Command.parse(["exec", "echo hi"]) == .exec("echo hi"))
    }

    /// Only the raw tail is trimmed at its ends; nothing inside it is touched.
    @Test func execTrimsItsEndsAndRefusesAnEmptyLine() throws {
        #expect(try Command.parse(line: "exec   ghostty  ") == .exec("ghostty"))
        for empty in ["exec", "exec   "] {
            let error = try #require(throws: CommandSyntaxError.self) { try Command.parse(line: empty) }
            #expect(error == .missingArgument(verb: "exec", expected: "<shell command>"))
        }
        #expect(throws: CommandSyntaxError.missingArgument(verb: "exec", expected: "<shell command>")) {
            try Command.parse(["exec"])
        }
    }

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

    // `grow` / `shrink` arguments

    /// The unit is points throughout the core, but `px` is what people type — so `100px`, `100pt` and a
    /// bare `100` are one value, and `100px` is the spelling it comes back out as.
    @Test func aSizeDeltaAcceptsPointsSpelledThreeWaysAndPercent() throws {
        for spelling in ["100", "100px", "100pt"] {
            #expect(try Command.parse(["grow", spelling]) == .grow(.points(100)))
        }
        #expect(try Command.parse(["shrink", "10%"]) == .shrink(.percent(10)))
        #expect(try Command.parse(["grow", "12.5%"]) == .grow(.percent(12.5)))
        #expect(Command.grow(.points(100)).words == ["grow", "100px"])
        #expect(Command.shrink(.percent(10)).words == ["shrink", "10%"])
        #expect(Command.grow(.points(12.5)).words == ["grow", "12.5px"])
    }

    /// The verb carries the sign, so a delta is a magnitude: `grow -10%` is refused rather than being a
    /// second spelling of `shrink 10%`, and `0` is a typo. The same guard catches everything else
    /// `Double.init` is happy to read.
    @Test func aSizeDeltaMustBeAPositiveFiniteMagnitude() throws {
        for bad in ["-10%", "-100px", "0", "0%", "nan", "inf", "1e400", "px", "%", "", "10 %", "wide"] {
            #expect(throws: CommandSyntaxError.self, "accepted '\(bad)'") {
                try Command.parse(["grow", bad])
            }
            #expect(throws: CommandSyntaxError.self, "accepted '\(bad)'") {
                try Command.parse(["shrink", bad])
            }
        }
        let error = try #require(throws: CommandSyntaxError.self) { try Command.parse(["grow"]) }
        #expect(error == .missingArgument(verb: "grow", expected: "<Npx|N%>"))
    }

    /// Workspaces are a fixed 36-address domain in *key* order — `1` first, `0` tenth — and every address
    /// is one character. There is no index to be off by one, so a two-character or out-of-domain word is
    /// the only way to get it wrong.
    @Test func aWorkspaceIsNamedByItsCharacterAndOneIsTheFirstOne() throws {
        #expect(try Command.parse(["focus-workspace", "1"]) == .focusWorkspace(.name(.first)))
        #expect(try Command.parse(["focus-workspace", "0"])
                == .focusWorkspace(.name(WorkspaceName("0")!)))          // accepted, and it is the tenth
        #expect(try Command.parse(["focus-workspace", "9"]) == .focusWorkspace(.name(WorkspaceName("9")!)))
        #expect(try Command.parse(["focus-workspace", "a"]) == .focusWorkspace(.name(WorkspaceName("a")!)))
        #expect(try Command.parse(["focus-workspace", "z"]) == .focusWorkspace(.name(.last)))
        // Every one of the 36 round-trips through the CLI spelling.
        for name in WorkspaceName.all {
            #expect(try Command.parse(["move-to-workspace", name.description])
                    == .moveToWorkspace(.name(name)))
        }
        // Case-sensitive like the type it parses into, and nothing outside the domain.
        for bad in ["A", "10", "-1", "1.5", "", "next-workspace", "aa", "!"] {
            #expect(throws: CommandSyntaxError.self, "accepted '\(bad)'") {
                try Command.parse(["focus-workspace", bad])
            }
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
