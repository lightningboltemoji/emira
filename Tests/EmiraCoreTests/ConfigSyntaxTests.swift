import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// text → `Config`. Two layers, tested separately because they fail differently: `TOMLTable` (the
// grammar — is this a line?) and `Config.parse` (the schema — is this a setting, and is that a legal
// value for it?).
//
// The property that carries the file is that nothing is ever silently ignored, so every test below
// that ends in a thrown error is testing the product's behaviour rather than an edge case.

@Suite struct ConfigSyntaxTests {

    // MARK: - Fixtures

    /// Parse, failing the test with the diagnostic if it throws (which is what a human would see).
    static func parse(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Config {
        do {
            return try Config.parse(text)
        } catch let error as ConfigSyntaxError {
            Issue.record("unexpected diagnostic: \(error)", sourceLocation: sourceLocation)
            throw error
        }
    }

    /// The error `text` produces, or `nil` if it parsed.
    static func diagnostic(_ text: String) -> ConfigSyntaxError? {
        do {
            _ = try Config.parse(text)
            return nil
        } catch let error as ConfigSyntaxError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - The zero-config file

    @Test func anEmptyFileIsTheDefaultConfig() throws {
        #expect(try Self.parse("") == Config())
    }

    @Test func aFileOfNothingButCommentsAndBlankLinesIsAlsoTheDefault() throws {
        let text = """
        # emira config

           # indented comment

        """
        #expect(try Self.parse(text) == Config())
    }

    /// Absent keys keep their default rather than resetting to zero — the property that lets a user
    /// write down only the one thing they care about.
    @Test func anAbsentKeyKeepsItsDefault() throws {
        let config = try Self.parse("[layout]\ncolumn-gap = 12\n")
        #expect(config.columnGap == 12)
        #expect(config.windowGap == Config().windowGap)
        #expect(config.widthPresets == Config().widthPresets)
        #expect(config.scrollSpring == Config().scrollSpring)
    }

    // MARK: - Every key in the schema

    @Test func theWholeSchemaReadsBack() throws {
        let text = """
        [layout]
        column-gap = 8
        window-gap = 4
        outer-gap = 16
        outer-gap-left = 24
        width-presets = [0.25, 0.5, 900]
        center-focused-column = true

        [animation]
        smooth-transitions = false
        hold-timeout = 2.5

        [animation.scroll]
        stiffness = 400
        damping-ratio = 1.0

        [animation.resize]
        stiffness = 1200
        damping-ratio = 0.8
        """
        let config = try Self.parse(text)
        #expect(config.columnGap == 8)
        #expect(config.windowGap == 4)
        #expect(config.outerGaps == EdgeInsets(top: 16, left: 24, bottom: 16, right: 16))
        #expect(config.centerFocusedColumn)
        #expect(!config.smoothTransitions)
        #expect(config.holdTimeout == 2.5)
        #expect(config.scrollSpring.stiffness == 400)
        #expect(abs(config.scrollSpring.dampingRatio - 1.0) < 1e-9)
        #expect(config.resizeSpring.stiffness == 1200)
        #expect(abs(config.resizeSpring.dampingRatio - 0.8) < 1e-9)
    }

    /// The one piece of cleverness in the schema, pinned: `≤ 1` is a fraction of the working width,
    /// `> 1` is a point count. Both spellings are things a user means, and `PresetSize` already has
    /// the two cases — so the file needs no ceremony to reach either.
    @Test func aWidthOfOneOrLessIsAProportionAndAnythingLargerIsPoints() throws {
        let config = try Self.parse("[layout]\nwidth-presets = [0.25, 1.0, 900]\n")
        #expect(config.widthPresets.presets == [.proportion(0.25), .proportion(1.0), .fixed(900)])
    }

    /// Heights read the same way widths do — the same spelling, resolved against the *column* height
    /// instead of the content width — and the two ladders are independent.
    @Test func heightPresetsParseLikeWidthsAndAreIndependentOfThem() throws {
        let config = try Self.parse("[layout]\nheight-presets = [0.25, 400]\n")
        #expect(config.heightPresets.presets == [.proportion(0.25), .fixed(400)])
        #expect(config.widthPresets == Config().widthPresets)     // untouched
        #expect(Config().heightPresets == .defaultHeights)
    }

    /// Scroll, resize and movement are separately tunable, they default to the *same* spring so nothing
    /// moves until asked, and turning one leaves the other two alone.
    @Test func theThreeSpringsAreIndependentAndDefaultToTheSameOne() throws {
        #expect(Config().scrollSpring == Config().resizeSpring)
        #expect(Config().scrollSpring == Config().moveSpring)

        let resized = try Self.parse("[animation.resize]\nstiffness = 2000\n")
        #expect(resized.resizeSpring.stiffness == 2000)
        #expect(resized.scrollSpring == Config().scrollSpring)
        #expect(resized.moveSpring == Config().moveSpring)

        let moved = try Self.parse("[animation.movement]\nstiffness = 1500\ndamping-ratio = 0.9\n")
        #expect(moved.moveSpring.stiffness == 1500)
        #expect(abs(moved.moveSpring.dampingRatio - 0.9) < 1e-9)
        #expect(moved.scrollSpring == Config().scrollSpring)
        #expect(moved.resizeSpring == Config().resizeSpring)
    }

    /// A misspelled animation table is refused like any other unknown key: a window manager that ignores
    /// `[animation.movemnt]` is one the user believes is broken.
    @Test func aMisspelledAnimationTableIsRefused() {
        #expect(Self.diagnostic("[animation.movemnt]\nstiffness = 1500\n")
                == .unknownKey(line: 1, key: "animation.movemnt"))
    }

    /// A spring table that sets only one of its two keys keeps the other — a file that stiffens the
    /// scroll must not silently fall off to `ζ = 0` (an undamped spring that never settles).
    @Test func aPartialSpringKeepsTheOtherConstant() throws {
        let config = try Self.parse("[animation.scroll]\nstiffness = 200\n")
        #expect(config.scrollSpring.stiffness == 200)
        #expect(abs(config.scrollSpring.dampingRatio - Config().scrollSpring.dampingRatio) < 1e-9)
    }

    /// The reason the file spells a spring as `stiffness` + `damping-ratio` rather than as a response
    /// time: published constants in those terms are copyable verbatim.
    @Test func documentedConstantsProduceTheDefaultSpring() throws {
        let config = try Self.parse("[animation.scroll]\nstiffness = 800\ndamping-ratio = 1.0\n")
        #expect(abs(config.scrollSpring.stiffness - SpringParams.smooth.stiffness) < 1e-9)
        #expect(abs(config.scrollSpring.damping - SpringParams.smooth.damping) < 1e-9)
    }

    // MARK: - Typos are refused, and the diagnostic names the line

    @Test func anUnknownKeyIsRefusedWithItsLine() {
        let text = """
        [layout]
        column-gap = 8
        colum-gap = 4
        """
        #expect(Self.diagnostic(text) == .unknownKey(line: 3, key: "layout.colum-gap"))
    }

    /// The case leftover-key detection alone would miss: a misspelled table with nothing under it
    /// contributes no keys, so the header itself has to be accounted for.
    @Test func anUnknownTableIsRefusedEvenWhenItIsEmpty() {
        #expect(Self.diagnostic("[layuot]\n") == .unknownKey(line: 1, key: "layuot"))
    }

    @Test func aKeyInTheWrongTableIsUnknown() {
        // `column-gap` is real, `[animation]` is real, the combination is not.
        #expect(Self.diagnostic("[animation]\ncolumn-gap = 8\n")
                == .unknownKey(line: 2, key: "animation.column-gap"))
    }

    @Test func theFirstMistakeIsTheOneReported() {
        let text = """
        [layout]
        wrong-one = 1
        wrong-two = 2
        """
        #expect(Self.diagnostic(text)?.line == 2)
    }

    @Test func aDuplicateKeyIsRefusedRatherThanLastWins() {
        let text = """
        [layout]
        column-gap = 8
        column-gap = 12
        """
        #expect(Self.diagnostic(text) == .duplicateKey(line: 3, key: "layout.column-gap"))
    }

    // MARK: - Values are validated, not merely read

    @Test func aValueOfTheWrongKindIsRefused() {
        #expect(Self.diagnostic("[layout]\ncolumn-gap = \"8\"\n")
                == .badValue(line: 2, key: "layout.column-gap",
                             message: "must be a number, not a string"))
        #expect(Self.diagnostic("[layout]\ncenter-focused-column = 1\n")
                == .badValue(line: 2, key: "layout.center-focused-column",
                             message: "must be true or false, not a number"))
    }

    @Test func aNegativeGapIsRefused() {
        #expect(Self.diagnostic("[layout]\ncolumn-gap = -4\n")
                == .badValue(line: 2, key: "layout.column-gap", message: "must be at least 0"))
    }

    @Test func aZeroStiffnessSpringIsRefused() {
        // ζ = 0 is legal (an undamped spring is a choice); k = 0 is not a spring at all.
        #expect(Self.diagnostic("[animation.scroll]\nstiffness = 0\n")
                == .badValue(line: 2, key: "animation.scroll.stiffness",
                             message: "must be greater than 0"))
        #expect(Self.diagnostic("[animation.scroll]\ndamping-ratio = 0\n") == nil)
    }

    @Test func aZeroHoldTimeoutIsRefused() {
        #expect(Self.diagnostic("[animation]\nhold-timeout = 0\n")
                == .badValue(line: 2, key: "animation.hold-timeout",
                             message: "must be greater than 0"))
    }

    @Test func anEmptyWidthCycleIsRefused() {
        // `PresetCycle` is *total* against an empty cycle (it answers full-width), but a file that
        // says "cycle through nothing" is a mistake, and totality is a safety net, not a spec.
        #expect(Self.diagnostic("[layout]\nwidth-presets = []\n")
                == .badValue(line: 2, key: "layout.width-presets",
                             message: "must list at least one width"))
    }

    @Test func aNonPositiveWidthIsRefused() {
        #expect(Self.diagnostic("[layout]\nwidth-presets = [0.5, 0]\n")
                == .badValue(line: 2, key: "layout.width-presets",
                             message: "must be greater than 0"))
    }

    @Test func aWidthCycleOfTheWrongKindIsRefused() {
        #expect(Self.diagnostic("[layout]\nwidth-presets = 0.5\n")
                == .badValue(line: 2, key: "layout.width-presets",
                             message: "must be an array, not a number"))
    }

    // MARK: - The grammar (TOMLTable)

    @Test func commentsAndBlanksAndTrailingCommentsAreIgnored() throws {
        let config = try Self.parse("""
        # heading comment
        [layout]   # after a header

        column-gap = 8   # points

        """)
        #expect(config.columnGap == 8)
    }

    /// A `#` inside a string is not a comment — e.g. a keybinding spelled `"#" = "focus left"`, and the
    /// reason every scan in the reader is quote-aware.
    @Test func aHashInsideAStringIsNotAComment() throws {
        let table = try TOMLTable.parse("key = \"a # b\"\n")
        #expect(table.values["key"]?.payload == .string("a # b"))
    }

    /// Quoted keys parse: the `[keys]` table needs `"cmd-alt-h"` to be a key, and the grammar is where
    /// that belongs.
    @Test func quotedAndDottedKeysAreRead() throws {
        let table = try TOMLTable.parse("""
        [keys]
        "cmd-alt-h" = "focus left"
        bare.dotted = 1
        """)
        #expect(table.values["keys.cmd-alt-h"]?.payload == .string("focus left"))
        #expect(table.values["keys.bare.dotted"]?.payload == .number(1))
    }

    @Test func windowsLineEndingsAreNotASyntaxError() throws {
        let config = try Self.parse("[layout]\r\ncolumn-gap = 8\r\n")
        #expect(config.columnGap == 8)
    }

    @Test func escapesInStringsAreRead() throws {
        let table = try TOMLTable.parse(#"key = "a\"b\\c\td""#)
        #expect(table.values["key"]?.payload == .string("a\"b\\c\td"))
    }

    @Test func aTrailingCommaInAnArrayIsTolerated() throws {
        let config = try Self.parse("[layout]\nwidth-presets = [0.5, 0.75,]\n")
        #expect(config.widthPresets.presets == [.proportion(0.5), .proportion(0.75)])
    }

    /// Everything the subset deliberately does not implement says so, on its line, instead of being
    /// read as something else. A partial parser that quietly accepts what it can't represent is worse
    /// than one that refuses.
    @Test func unsupportedTOMLIsRefusedByName() {
        #expect(Self.diagnostic("[layout]\nx = { a = 1 }\n")?.description
                == "line 2: inline tables are not supported")
        #expect(Self.diagnostic("[layout]\nx = [[1]]\n")?.description
                == "line 2: nested arrays are not supported")
        #expect(Self.diagnostic("[layout]\nwidth-presets = [0.5,\n0.75]\n")?.description
                == "line 2: unterminated array — it must open and close on one line")
    }

    /// The two the grammar *did* refuse until `[[window-rules]]` needed them, and they arrived
    /// together for one reason: a rule matches on regular expressions, and a regex in a `"…"` string
    /// has to double its backslashes. An unknown table is still an unknown table.
    @Test func arraysOfTablesAndLiteralStringsAreRead() throws {
        let table = try TOMLTable.parse("[[workspace]]\nx = 1\n[[workspace]]\nx = 2\n")
        #expect(table.values["workspace.0.x"]?.payload == .number(1))
        #expect(table.values["workspace.1.x"]?.payload == .number(2))
        #expect(Self.diagnostic("[[workspace]]\n")?.description
                == "line 1: unknown setting 'workspace.0'")

        let literal = try TOMLTable.parse(#"key = 'a\d"b'"#)
        #expect(literal.values["key"]?.payload == .string(#"a\d"b"#))
    }

    /// A `'…'` opens a string too, so the comment stripper and the `=` scanner have to see it — and a
    /// `'` inside a `"…"` is just an apostrophe, not the start of one.
    @Test func literalStringsAreQuotesForEveryScannerThatCares() throws {
        let commented = try TOMLTable.parse("key = 'a # b'   # the real comment\n")
        #expect(commented.values["key"]?.payload == .string("a # b"))

        let apostrophe = try TOMLTable.parse(#"key = "it's fine""#)
        #expect(apostrophe.values["key"]?.payload == .string("it's fine"))

        #expect(Self.diagnostic("[layout]\nx = 'unterminated\n")?.description
                == "line 2: unterminated string")
    }

    // MARK: - [[window-rules]]

    @Test func rulesAreReadInFileOrderWithEveryMatcher() throws {
        let config = try Self.parse("""
        [[window-rules]]
        app-id = "com.tinyspeck.slackmacgap"
        workspace = "3"

        [[window-rules]]
        app-id-regex = '^com\\.apple\\.'
        title-regex  = 'Huddle'
        workspace    = "z"
        """)

        #expect(config.windowRules.count == 2)
        #expect(config.windowRules[0]
                == WindowRule(appId: "com.tinyspeck.slackmacgap", workspace: WorkspaceName("3")!))
        #expect(config.windowRules[1]
                == WindowRule(appIdRegex: #"^com\.apple\."#, titleRegex: "Huddle",
                              workspace: WorkspaceName("z")!))
    }

    @Test func aFileWithNoRulesLeavesTheListEmpty() throws {
        #expect(try Self.parse("[layout]\ncolumn-gap = 4\n").windowRules.isEmpty)
    }

    /// A rule matching nothing would apply to every window on the desktop and a rule doing nothing
    /// would apply to none — neither is ever what someone meant, so neither parses.
    @Test func aRuleMustBothMatchSomethingAndDoSomething() {
        #expect(Self.diagnostic("[[window-rules]]\nworkspace = \"3\"\n")?.description
                == "line 1: 'window-rules' must match something — "
                 + "set app-id, app-id-regex, title or title-regex")
        #expect(Self.diagnostic("[[window-rules]]\napp-id = \"com.apple.Safari\"\n")?.description
                == "line 1: 'window-rules' must do something — set workspace, float or width")
    }

    @Test func theOtherTwoActionsParse() throws {
        let config = try Self.parse("""
        [[window-rules]]
        title-regex = 'Inspector'
        float = true

        [[window-rules]]
        app-id = "com.apple.Safari"
        width = 0.5

        [[window-rules]]
        app-id = "com.apple.Terminal"
        float = false
        width = 700
        """)
        #expect(config.windowRules[0] == WindowRule(titleRegex: "Inspector", float: true))
        #expect(config.windowRules[1] == WindowRule(appId: "com.apple.Safari",
                                                    width: .proportion(0.5)))
        // Over 1 is points, on `width-presets`' scale — the same reader, so they cannot disagree.
        #expect(config.windowRules[2] == WindowRule(appId: "com.apple.Terminal", float: false,
                                                    width: .fixed(700)))
    }

    /// A floating window has no column, so a rule doing both contains a clause that provably does
    /// nothing — the same reason an unknown key is refused rather than shrugged at. Checked per rule:
    /// two rules that each make sense and merge into this are not a typo anyone made.
    @Test func oneRuleCannotBothFloatAWindowAndPlaceItOnTheStrip() {
        let both = "[[window-rules]]\napp-id = \"x\"\nfloat = true\nworkspace = \"3\"\n"
        #expect(Self.diagnostic(both)?.description
                == "line 1: 'window-rules' floats a window and then places it on the strip — a "
                 + "floating window has no column, so drop 'float = true' or drop the workspace "
                 + "and width")
        // …but `float = false` alongside a placement is the ordinary combination.
        #expect(Self.diagnostic("[[window-rules]]\napp-id = \"x\"\nfloat = false\nwidth = 0.5\n")
                == nil)
    }

    @Test func aRuleWidthIsBoundedLikeAPreset() {
        #expect(Self.diagnostic("[[window-rules]]\napp-id = \"x\"\nwidth = 0\n")?.description
                == "line 3: 'window-rules.width' must be greater than 0")
        #expect(Self.diagnostic("[[window-rules]]\napp-id = \"x\"\nwidth = \"half\"\n")?.description
                == "line 3: 'window-rules.width' must be a number, not a string")
    }

    /// The diagnostic names the key as it is written in the file, not as the flattening keys it.
    @Test func aBadKeyInsideARuleIsReportedUnderTheTableItIsWrittenIn() {
        #expect(Self.diagnostic("[[window-rules]]\napp-di = \"x\"\nworkspace = \"3\"\n")?.description
                == "line 2: unknown setting 'window-rules.app-di'")
        #expect(Self.diagnostic("[[window-rules]]\napp-id = 3\nworkspace = \"3\"\n")?.description
                == "line 2: 'window-rules.app-id' must be text in quotes, not a number")
    }

    /// Compiled here so a broken pattern is a line in a file rather than a rule that never fires.
    @Test func anUnreadableRegexIsRefusedWithItsLine() throws {
        let error = try #require(Self.diagnostic("[[window-rules]]\napp-id-regex = 'com.(apple'\n"))
        #expect(error.line == 2)
        #expect(error.description.hasPrefix("line 2: 'window-rules.app-id-regex' "
                                          + "is not a regular expression — "))
    }

    /// Addresses are quoted characters, never bare numbers: half the domain isn't numeric and the
    /// tenth address is spelled `"0"`, neither of which a TOML integer could carry.
    @Test func aWorkspaceIsNamedByItsCharacterInQuotes() throws {
        let expected = "must be a workspace name in quotes — \"1\"-\"9\", \"0\", then \"a\"-\"z\""
        #expect(Self.diagnostic("[[window-rules]]\napp-id = \"x\"\nworkspace = 3\n")?.description
                == "line 3: 'window-rules.workspace' \(expected)")
        #expect(Self.diagnostic("[[window-rules]]\napp-id = \"x\"\nworkspace = \"33\"\n")?.description
                == "line 3: 'window-rules.workspace' \(expected)")
        // …and every address the domain has does parse, including the tenth.
        for character in "1234567890az" {
            let text = "[[window-rules]]\napp-id = \"x\"\nworkspace = \"\(character)\"\n"
            #expect(try Self.parse(text).windowRules.first?.workspace == WorkspaceName(character))
        }
    }

    /// Written with single brackets it parses as a table and then goes nowhere, so the diagnostic says
    /// which mistake it is instead of leaving "unknown setting" to imply a misspelling.
    @Test func aSinglyBracketedRulesTableSaysItIsAList() {
        #expect(Self.diagnostic("[window-rules]\napp-id = \"x\"\nworkspace = \"3\"\n")?.description
                == "line 1: 'window-rules' is a list of rules — "
                 + "write each one under its own '[[window-rules]]'")
    }

    @Test func malformedLinesAreSyntaxErrors() {
        #expect(Self.diagnostic("[layout\n")?.line == 1)
        #expect(Self.diagnostic("column-gap\n")?.description == "line 1: expected 'key = value'")
        #expect(Self.diagnostic("[layout]\ncolumn-gap =\n")?.description
                == "line 2: missing value after '='")
        #expect(Self.diagnostic("[layout]\nx = \"unterminated\n")?.description
                == "line 2: unterminated string")
        #expect(Self.diagnostic("[layout]\nx = \"bad\\qescape\"\n")?.description
                == "line 2: unknown escape '\\q'")
        #expect(Self.diagnostic("[]\n")?.line == 1)
    }

    /// `Double("inf")`, `Double("nan")` and `Double("0x1p3")` all succeed, and none of them is
    /// something a config file should be able to say — so the charset is checked before the parse.
    @Test func numbersThatOnlySwiftWouldAcceptAreRefused() {
        #expect(Self.diagnostic("[layout]\ncolumn-gap = inf\n")?.line == 2)
        #expect(Self.diagnostic("[layout]\ncolumn-gap = nan\n")?.line == 2)
        #expect(Self.diagnostic("[layout]\ncolumn-gap = 0x10\n")?.line == 2)
    }

    // MARK: - The diagnostic is the product

    @Test func diagnosticsReadAsSentences() {
        #expect(ConfigSyntaxError.unknownKey(line: 4, key: "layout.colum-gap").description
                == "line 4: unknown setting 'layout.colum-gap'")
        #expect(ConfigSyntaxError.duplicateKey(line: 9, key: "layout.column-gap").description
                == "line 9: 'layout.column-gap' is set twice")
        #expect(ConfigSyntaxError.badValue(line: 2, key: "layout.column-gap",
                                           message: "must be at least 0").description
                == "line 2: 'layout.column-gap' must be at least 0")
        #expect(ConfigSyntaxError.syntax(line: 1, message: "unterminated string").description
                == "line 1: unterminated string")
    }

    /// The documented example in `ConfigSyntax.swift`'s header is the defaults written out — if it
    /// ever stops parsing to `Config()`, the documentation has drifted from the code.
    @Test func theDocumentedExampleIsExactlyTheDefaults() throws {
        let text = """
        [layout]
        column-gap = 0
        window-gap = 0
        width-presets = [0.333, 0.5, 0.667]
        center-focused-column = false

        [animation]
        smooth-transitions = true
        hold-timeout = 1.0

        [animation.scroll]
        stiffness = 800
        damping-ratio = 1.0

        [animation.resize]
        stiffness = 800
        damping-ratio = 1.0
        """
        let config = try Self.parse(text)
        let defaults = Config()
        #expect(config.columnGap == defaults.columnGap)
        #expect(config.windowGap == defaults.windowGap)
        #expect(config.centerFocusedColumn == defaults.centerFocusedColumn)
        #expect(config.smoothTransitions == defaults.smoothTransitions)
        #expect(config.holdTimeout == defaults.holdTimeout)
        #expect(abs(config.scrollSpring.stiffness - defaults.scrollSpring.stiffness) < 1e-9)
        #expect(abs(config.scrollSpring.damping - defaults.scrollSpring.damping) < 1e-9)
        // The presets are the ⅓/½/⅔ ladder to three decimal places, which is as close as a file gets.
        #expect(config.widthPresets.presets.count == 3)
        #expect(config.widthPresets.resolved(at: 1, available: 1000) == 500)
        // No default bindings: an unbound emira confiscates no keystroke from any other app.
        #expect(config.keys.isEmpty)
    }

    // MARK: - The `[keys]` table (the one open table in the schema)

    @Test func bindingsAreReadInFileOrder() throws {
        let config = try Self.parse("""
        [keys]
        alt-h = "focus left"
        alt-l = "focus right"
        alt-shift-h = "move-window left"
        cmd-alt-f = "fullscreen"
        """)
        #expect(config.keys == [
            KeyBinding(KeyChord([.option], .h), .focus(.left)),
            KeyBinding(KeyChord([.option], .l), .focus(.right)),
            KeyBinding(KeyChord([.option, .shift], .h), .moveWindow(.left)),
            KeyBinding(KeyChord([.option, .command], .f), .fullscreen(.toggle)),
        ])
    }

    /// A bare TOML key is enough for almost every chord (the bare charset already admits `-`); quoting is
    /// there for the ones it isn't.
    @Test func aChordMayBeWrittenBareOrQuoted() throws {
        let config = try Self.parse("""
        [keys]
        "cmd-alt-h" = "focus left"
        cmd-alt-l = "focus right"
        """)
        #expect(config.keys.map(\.chord) == [KeyChord([.command, .option], .h),
                                             KeyChord([.command, .option], .l)])
    }

    /// The right-hand side goes through `Command.parse` — the *same* function the CLI uses, so
    /// `emira focus left` and `alt-h = "focus left"` cannot diverge.
    @Test func aBindingSpellsACommandExactlyAsTheCLIDoes() throws {
        let config = try Self.parse("""
        [keys]
        cmd-1 = "focus-workspace 1"
        alt-c = "close-window"
        alt-r = "center-column"
        """)
        #expect(config.keys.map(\.command)
                == [.focusWorkspace(.name(WorkspaceName("1")!)), .closeWindow, .centerColumn])
    }

    /// The binding this feature exists for, written the way a user writes it: a TOML basic string
    /// whose `\"` escapes leave the shell's own quoting intact. `exec`'s tail is never split, so the
    /// AppleScript arrives at the daemon as one argument — which is the whole point of the raw tail.
    @Test func aBindingMayLaunchSomethingThroughTheShell() throws {
        let config = try Self.parse("""
        [keys]
        alt-space = "exec osascript -e 'tell application \\"Ghostty\\" to new window'"
        alt-shift-space = "exec /opt/homebrew/bin/ghostty"
        """)
        #expect(config.keys.map(\.command) == [
            .exec("osascript -e 'tell application \"Ghostty\" to new window'"),
            .exec("/opt/homebrew/bin/ghostty"),
        ])
        #expect(config.keys.map(\.chord) == [KeyChord([.option], .space),
                                             KeyChord([.option, .shift], .space)])
    }

    @Test func anUnreadableChordIsRefusedWithItsLine() {
        let error = Self.diagnostic("""
        [keys]
        alt-h = "focus left"
        cmd-zz = "focus right"
        """)
        #expect(error?.line == 3)
        #expect(error?.description
                == "line 3: 'keys.cmd-zz' is not a key combination — unknown key or modifier 'zz'")
    }

    @Test func anUnreadableCommandIsRefusedWithItsLine() {
        let error = Self.diagnostic("""
        [keys]
        alt-h = "focus lefft"
        """)
        #expect(error?.line == 2)
        #expect(error?.description
                == "line 2: 'keys.alt-h' must be a command — "
                + "'focus': bad argument 'lefft' — expected <left|right|up|down>")
    }

    @Test func aBindingsValueMustBeAString() {
        let error = Self.diagnostic("""
        [keys]
        alt-h = 3
        """)
        #expect(error?.description == "line 2: 'keys.alt-h' must be a command in quotes, not a number")
    }

    /// The check the grammar can't make: `cmd-alt-h` and `alt-cmd-h` are two TOML keys and one hotkey,
    /// so without this the second registers over the first and silently never fires.
    @Test func twoSpellingsOfOneChordAreADuplicate() {
        let error = Self.diagnostic("""
        [keys]
        cmd-alt-h = "focus left"
        alt-cmd-h = "focus right"
        """)
        #expect(error?.line == 3)
        // Named in the canonical spelling, which is what connects it to the line above.
        #expect(error?.description == "line 3: 'keys.alt-cmd-h' is set twice")
    }

    /// The grammar's own duplicate check still applies to the identical spelling, one layer earlier.
    @Test func theSameSpellingTwiceIsStillADuplicate() {
        #expect(Self.diagnostic("""
        [keys]
        alt-h = "focus left"
        alt-h = "focus right"
        """)?.line == 3)
    }

    /// `[keys]` is open, but only `[keys]` is: the schema still refuses a table it doesn't know, and a
    /// chord written outside the table is not a binding.
    @Test func opennessDoesNotLeakToTheRestOfTheSchema() {
        #expect(Self.diagnostic("""
        [kesy]
        alt-h = "focus left"
        """)?.line == 1)
        #expect(Self.diagnostic("""
        [layout]
        alt-h = "focus left"
        """)?.line == 2)
    }

    @Test func anEmptyKeysTableIsLegalAndBindsNothing() throws {
        #expect(try Self.parse("[keys]\n").keys.isEmpty)
    }

    /// Bindings coexist with the rest of the file — worth pinning because `[keys]` is read by a
    /// different mechanism (`takeAll`) than every other setting.
    @Test func bindingsCoexistWithTheOtherSettings() throws {
        let config = try Self.parse("""
        [layout]
        column-gap = 8

        [keys]
        alt-h = "focus left"

        [animation]
        hold-timeout = 2.0
        """)
        #expect(config.columnGap == 8)
        #expect(config.holdTimeout == 2.0)
        #expect(config.keys.count == 1)
    }
}

/// `outer-gap` and its four per-side overrides — the one setting written as a *family* of keys, so
/// precedence and partial specification both need pinning.
@Suite struct OuterGapConfigTests {

    @Test func theBareKeySetsAllFourEdges() throws {
        let config = try ConfigSyntaxTests.parse("[layout]\nouter-gap = 12\n")
        #expect(config.outerGaps == EdgeInsets(uniform: 12))
    }

    /// A side on its own means *that side*, not "that side and zero elsewhere" — which is why the
    /// reader refines the running default rather than starting from scratch.
    @Test func oneSideAloneLeavesTheOthersAtTheirDefault() throws {
        let config = try ConfigSyntaxTests.parse("[layout]\nouter-gap-left = 20\n")
        #expect(config.outerGaps == EdgeInsets(top: 0, left: 20, bottom: 0, right: 0))
    }

    /// Precedence is read order and nothing else: the bare key seeds all four, each side overwrites.
    /// File order is irrelevant — a user who writes the override first still gets the override.
    @Test func aSideOverridesTheBareKeyWhicheverOrderTheyAreWritten() throws {
        let after = try ConfigSyntaxTests.parse("[layout]\nouter-gap = 8\nouter-gap-right = 40\n")
        let before = try ConfigSyntaxTests.parse("[layout]\nouter-gap-right = 40\nouter-gap = 8\n")
        #expect(after.outerGaps == EdgeInsets(top: 8, left: 8, bottom: 8, right: 40))
        #expect(before.outerGaps == after.outerGaps)
    }

    @Test func allFourSidesCanBeNamedIndividually() throws {
        let text = """
        [layout]
        outer-gap-top = 1
        outer-gap-left = 2
        outer-gap-bottom = 3
        outer-gap-right = 4
        """
        #expect(try ConfigSyntaxTests.parse(text).outerGaps
                == EdgeInsets(top: 1, left: 2, bottom: 3, right: 4))
    }

    @Test func absentKeysLeaveTheGapsAtZero() throws {
        #expect(try ConfigSyntaxTests.parse("[layout]\ncolumn-gap = 8\n").outerGaps == .zero)
    }

    /// Refused like the other gaps: a negative margin would push the strip back under the menu bar the
    /// struts exist to keep it out of.
    @Test func aNegativeGapIsRefused() {
        #expect(ConfigSyntaxTests.diagnostic("[layout]\nouter-gap = -1\n")
                == .badValue(line: 2, key: "layout.outer-gap", message: "must be at least 0"))
        #expect(ConfigSyntaxTests.diagnostic("[layout]\nouter-gap-top = -1\n")
                == .badValue(line: 2, key: "layout.outer-gap-top", message: "must be at least 0"))
    }

    @Test func aNonNumberIsRefused() {
        #expect(ConfigSyntaxTests.diagnostic("[layout]\nouter-gap = true\n")
                == .badValue(line: 2, key: "layout.outer-gap",
                             message: "must be a number, not a boolean"))
    }

    /// The family's names are exact: a plausible-looking sibling is a typo, and a typo is a diagnostic.
    @Test func aPlausibleNearMissIsStillAnUnknownKey() {
        #expect(ConfigSyntaxTests.diagnostic("[layout]\nouter-gaps = 8\n")
                == .unknownKey(line: 2, key: "layout.outer-gaps"))
        #expect(ConfigSyntaxTests.diagnostic("[layout]\nouter-gap-horizontal = 8\n")
                == .unknownKey(line: 2, key: "layout.outer-gap-horizontal"))
    }

    /// `outer-gap.left` is the spelling this schema deliberately *doesn't* use. The flat grammar would
    /// happily store it, so nothing but this test says so.
    @Test func theDottedSpellingIsRefusedRatherThanSilentlyIgnored() {
        #expect(ConfigSyntaxTests.diagnostic("[layout]\nouter-gap.left = 20\n")
                == .unknownKey(line: 2, key: "layout.outer-gap.left"))
    }

    /// `struts` remain the daemon's to set. A user reaching for a margin is reaching for `outer-gap`.
    @Test func strutsAreStillNotAKey() {
        #expect(ConfigSyntaxTests.diagnostic("[layout]\nstruts = 8\n")
                == .unknownKey(line: 2, key: "layout.struts"))
    }

    // MARK: `animation.cover` — the same question `animation.window` asks, in time

    @Test func theCoverModeIsExactUntilAskedOtherwise() throws {
        #expect(try ConfigSyntaxTests.parse("").coverMode == .exact)
        #expect(try ConfigSyntaxTests.parse("[animation]\nhold-timeout = 2\n").coverMode == .exact)
    }

    @Test func bothCoverModesParse() throws {
        #expect(try ConfigSyntaxTests.parse("[animation]\ncover = \"immediate\"\n").coverMode
                    == .immediate)
        #expect(try ConfigSyntaxTests.parse("[animation]\ncover = \"exact\"\n").coverMode == .exact)
    }

    /// The two word-valued keys of `[animation]` are independent: neither implies anything about the
    /// other, because one is about a rect the still no longer fits and the other about a still that has
    /// not arrived.
    @Test func theCoverModeAndTheWindowAnimationDoNotImplyEachOther() throws {
        let config = try ConfigSyntaxTests.parse(
            "[animation]\nwindow = \"crop\"\ncover = \"immediate\"\n")
        #expect(config.windowAnimation == .crop)
        #expect(config.coverMode == .immediate)
    }

    @Test func anUnknownCoverModeIsRefusedAndTheLegalOnesNamed() {
        #expect(ConfigSyntaxTests.diagnostic("[animation]\ncover = \"fast\"\n")
                == .badValue(line: 2, key: "animation.cover",
                             message: "must be \"exact\" or \"immediate\", not \"fast\""))
    }

    // MARK: `animation.window` — the schema's one word-valued key

    @Test func theWindowAnimationIsStretchUntilAskedOtherwise() throws {
        #expect(try ConfigSyntaxTests.parse("").windowAnimation == .stretch)
        #expect(try ConfigSyntaxTests.parse("[animation]\nhold-timeout = 2\n").windowAnimation == .stretch)
    }

    @Test func bothWindowAnimationsParse() throws {
        #expect(try ConfigSyntaxTests.parse("[animation]\nwindow = \"crop\"\n").windowAnimation == .crop)
        #expect(try ConfigSyntaxTests.parse("[animation]\nwindow = \"stretch\"\n").windowAnimation == .stretch)
    }

    /// The diagnostic lists the legal words *off the type*, so a third `WindowAnimation` case would be
    /// named here with nothing in the schema to update.
    @Test func anUnknownWordIsRefusedAndTheLegalOnesNamed() {
        #expect(ConfigSyntaxTests.diagnostic("[animation]\nwindow = \"fill\"\n")
                == .badValue(line: 2, key: "animation.window",
                             message: "must be \"stretch\" or \"crop\", not \"fill\""))
    }

    @Test func anUnquotedWindowAnimationIsRefused() {
        #expect(ConfigSyntaxTests.diagnostic("[animation]\nwindow = true\n")
                == .badValue(line: 2, key: "animation.window",
                             message: "must be a word in quotes, not a boolean"))
    }

    /// It is a key of `[animation]`, not a table of its own — `[animation.window]` is the spelling of a
    /// spring. Refused at the header, on the line the user wrote it, not at the key underneath.
    @Test func theWindowAnimationIsNotATable() {
        #expect(ConfigSyntaxTests.diagnostic("[animation.window]\nstiffness = 800\n")
                == .unknownKey(line: 1, key: "animation.window"))
    }

}

/// `[focus]` — one word-valued key today, named for what it gates rather than for the setting it is.
/// The behaviour behind it is `SystemFocusEventTests`; this is only the reading of the file.
@Suite struct FocusConfigTests {

    private static func parse(_ text: String,
                              sourceLocation: SourceLocation = #_sourceLocation) throws -> Config {
        try ConfigSyntaxTests.parse(text, sourceLocation: sourceLocation)
    }

    private static func diagnostic(_ text: String) -> ConfigSyntaxError? {
        ConfigSyntaxTests.diagnostic(text)
    }

    /// macOS's own behaviour until asked otherwise: a window manager must not confiscate focus nobody
    /// asked it to, the same rule that ships no key bindings.
    @Test func systemFocusEventsAreRespectedUntilAskedOtherwise() throws {
        #expect(try Self.parse("").systemFocusEvents == .respect)
        #expect(try Self.parse("[focus]\n").systemFocusEvents == .respect)
    }

    @Test func allThreeSystemFocusEventModesParse() throws {
        let read = { (word: String) in try Self.parse("[focus]\nsystem-events = \"\(word)\"\n") }
        #expect(try read("respect").systemFocusEvents == .respect)
        #expect(try read("on-screen").systemFocusEvents == .onScreen)
        #expect(try read("ignore").systemFocusEvents == .ignore)
    }

    /// Hyphenated in the file, camel-cased in Swift — so the diagnostic must quote the *file's* spelling,
    /// which it does because it reads the raw values off the type.
    @Test func anUnknownSystemFocusEventModeIsRefusedAndTheLegalOnesNamed() {
        #expect(Self.diagnostic("[focus]\nsystem-events = \"onscreen\"\n")
                == .badValue(line: 2, key: "focus.system-events",
                             message: "must be \"respect\" or \"on-screen\" or \"ignore\", "
                                    + "not \"onscreen\""))
    }

    @Test func anUnquotedSystemFocusEventModeIsRefused() {
        #expect(Self.diagnostic("[focus]\nsystem-events = false\n")
                == .badValue(line: 2, key: "focus.system-events",
                             message: "must be a word in quotes, not a boolean"))
    }

    /// The bare `system` is not quietly accepted as a synonym. Nothing shipped under that spelling, but
    /// the schema's whole promise is that a key it does not know is a diagnostic rather than a shrug.
    @Test func theBareSystemSpellingIsNotAKey() {
        #expect(Self.diagnostic("[focus]\nsystem = \"ignore\"\n")
                == .unknownKey(line: 2, key: "focus.system"))
    }

    /// `[focus]` is emira's own table, not a place to spell a `focus` *command* — an unknown key under it
    /// is refused like any other.
    @Test func anUnknownKeyUnderFocusIsRefused() {
        #expect(Self.diagnostic("[focus]\nfollow-mouse = true\n")
                == .unknownKey(line: 2, key: "focus.follow-mouse"))
    }
}
