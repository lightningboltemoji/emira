import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// The config file, in the half that has all the decisions in it: text → `Config`. Two layers get
// tested separately because they fail differently — `TOMLTable` (the grammar: is this a line?) and
// `Config.parse` (the schema: is this a setting, and is that a legal value for it?).
//
// The property that matters most here is the one that isn't about success: **nothing is ever
// silently ignored**. A window manager that shrugs at `colum-gap` is a window manager the user
// believes is broken, so every test below that ends in a thrown error is testing the product's
// actual behaviour, not its edge cases.

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

    /// The reason `Config` grew a second spring at all (iteration 21's named gap), and then a third
    /// (the structural-edit slice): the three motions are separately tunable, they default to the
    /// *same* spring so nothing moves until asked, and turning one leaves the other two alone. All
    /// three default to stiffness 800 / ζ 1.0, so the defaults here are copied rather than chosen.
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

    /// A misspelled animation table is refused like any other unknown key — the silence rule
    /// (M5 part 1): a window manager that ignores `[animation.movemnt]` is one the user believes is
    /// broken.
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

    /// Published spring constants are copyable verbatim — the whole reason the file spells a spring
    /// as `stiffness` + `damping-ratio` rather than as a response time.
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

    /// A `#` inside a string is not a comment — the case that will matter the day a keybinding is
    /// spelled `"#" = "focus left"`, and the reason every scan in the reader is quote-aware.
    @Test func aHashInsideAStringIsNotAComment() throws {
        let table = try TOMLTable.parse("key = \"a # b\"\n")
        #expect(table.values["key"]?.payload == .string("a # b"))
    }

    /// Quoted keys parse today even though nothing in the schema uses one yet — M5 part 2's
    /// `[keys]` table needs `"cmd-alt-h"` to be a key, and the grammar is where that belongs.
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
        #expect(Self.diagnostic("[[workspace]]\n")?.description
                == "line 1: arrays of tables are not supported")
        #expect(Self.diagnostic("[layout]\nx = { a = 1 }\n")?.description
                == "line 2: inline tables are not supported")
        #expect(Self.diagnostic("[layout]\nx = 'single'\n")?.description
                == "line 2: literal strings are not supported — use \"quotes\"")
        #expect(Self.diagnostic("[layout]\nx = [[1]]\n")?.description
                == "line 2: nested arrays are not supported")
        #expect(Self.diagnostic("[layout]\nwidth-presets = [0.5,\n0.75]\n")?.description
                == "line 2: unterminated array — it must open and close on one line")
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

    /// A bare TOML key is enough for almost every chord (the bare charset already admits `-`), and
    /// quoting is there for the ones it isn't — which is why `TOML.swift` learned quoted keys before
    /// there was anything to use them for.
    @Test func aChordMayBeWrittenBareOrQuoted() throws {
        let config = try Self.parse("""
        [keys]
        "cmd-alt-h" = "focus left"
        cmd-alt-l = "focus right"
        """)
        #expect(config.keys.map(\.chord) == [KeyChord([.command, .option], .h),
                                             KeyChord([.command, .option], .l)])
    }

    /// The right-hand side goes through `Command.parse` — the *same* function the CLI uses, which is
    /// §2's claim made literal: `emira focus left` and `alt-h = "focus left"` cannot diverge.
    @Test func aBindingSpellsACommandExactlyAsTheCLIDoes() throws {
        let config = try Self.parse("""
        [keys]
        cmd-1 = "focus-workspace 1"
        alt-c = "close-window"
        alt-r = "reload-config"
        """)
        #expect(config.keys.map(\.command)
                == [.focusWorkspace(.index(1)), .closeWindow, .reloadConfig])
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

    /// **The check the grammar can't make.** `cmd-alt-h` and `alt-cmd-h` are two different TOML keys
    /// and one hotkey; without this, the second would be registered over the first and silently never
    /// fire, while the user looked at two lines that both say what they mean.
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
