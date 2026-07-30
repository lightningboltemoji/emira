import Foundation
import Testing
import EmiraCore
@testable import EmiraConfig

// `Config` ⇄ text, the direction `ConfigSyntaxTests` doesn't cover. Two properties carry this file and
// everything else is a corollary of them: a document read and written back is the same bytes, and a
// document read twice — once for its values, once for its spans — is the same reading.
//
// The corpus is chosen for the ways a config file can be *shaped* rather than for the settings it sets.
// A writer that reformats is a writer that eats somebody's comments.

@Suite struct ConfigDocumentTests {

    // MARK: - Fixtures

    /// One fixture, named so a failure says which shape broke.
    struct File: Sendable, CustomStringConvertible {
        let name: String
        let text: String
        var description: String { name }
    }

    /// Tanner's own `~/.config/emira/emira.toml`, verbatim: a base gap with one per-side override, a
    /// `[keys]` table with blank lines grouping it, and an `exec` line whose quoting is its own hazard.
    static let real = #"""
    [layout]
    column-gap = 20
    window-gap = 20
    outer-gap = 20
    outer-gap-top = 8

    [focus]
    system-events = "on-screen"

    [animation]
    window = "crop"
    cover = "immediate"

    [keys]
    alt-1 = "focus-workspace 1"
    alt-2 = "focus-workspace 2"
    alt-3 = "focus-workspace 3"
    alt-4 = "focus-workspace 4"
    alt-5 = "focus-workspace 5"
    alt-q = "focus-workspace q"
    alt-w = "focus-workspace w"
    alt-e = "focus-workspace e"
    alt-r = "focus-workspace r"
    alt-t = "focus-workspace t"

    alt-shift-1 = "move-to-workspace-and-focus 1"
    alt-shift-2 = "move-to-workspace-and-focus 2"
    alt-shift-3 = "move-to-workspace-and-focus 3"
    alt-shift-4 = "move-to-workspace-and-focus 4"
    alt-shift-5 = "move-to-workspace-and-focus 5"
    alt-shift-q = "move-to-workspace-and-focus q"
    alt-shift-w = "move-to-workspace-and-focus w"
    alt-shift-e = "move-to-workspace-and-focus e"
    alt-shift-r = "move-to-workspace-and-focus r"
    alt-shift-t = "move-to-workspace-and-focus t"

    alt-h = "focus left"
    alt-j = "focus down"
    alt-k = "focus up"
    alt-l = "focus right"
    alt-f = "fullscreen"
    alt-shift-f = "float toggle"

    alt-shift-h = "move-window left"
    alt-shift-j = "move-window down"
    alt-shift-k = "move-window up"
    alt-shift-l = "move-window right"

    alt-shift-leftbracket = "consume-or-expel left"
    alt-shift-rightbracket = "consume-or-expel right"
    alt-equal = "grow 10%"
    alt-minus = "shrink 10%"

    alt-space = "exec osascript -e 'tell application \"Ghostty\" to new window'"

    """#

    /// CRLF, which Swift reads as one grapheme per break — so a writer spelling `\n` would leave the
    /// file with two kinds of line ending.
    static let crlf = "[layout]\r\ncolumn-gap = 8\r\nwindow-gap = 4\r\n\r\n[focus]\r\n"
                    + "system-events = \"ignore\"\r\n"

    /// No terminator on the last line: its span ends where the text does, with nothing to take out.
    static let noTrailingNewline = "[layout]\ncolumn-gap = 8\nwindow-gap = 4"

    /// Comments after values. Each describes the line it sits on, which decides what `remove` does
    /// with it, and none of them is at a column the writer is allowed to have an opinion about.
    static let trailingComments = """
    # how wide the strip breathes
    [layout]      # points throughout
    column-gap = 8    # between columns
    window-gap = 4    # within one
    center-focused-column = true
    """

    /// `[[window-rules]]` — the repeating table, whose elements flatten under a positional index.
    static let windowRules = #"""
    [[window-rules]]
    app-id = "com.tinyspeck.slackmacgap"
    workspace = "3"

    [[window-rules]]
    app-id-regex = '^com\.apple\.'
    float = true
    """#

    /// `'literal strings'`, the notation a regex is written in.
    static let literalStrings = #"""
    [[window-rules]]
    title-regex = 'Huddle \d+'
    workspace = "z"
    """#

    static let corpus: [File] = [
        File(name: "Tanner's own file", text: real),
        File(name: "CRLF", text: crlf),
        File(name: "no trailing newline", text: noTrailingNewline),
        File(name: "trailing comments", text: trailingComments),
        File(name: "window rules", text: windowRules),
        File(name: "literal strings", text: literalStrings),
        File(name: "empty", text: ""),
        File(name: "nothing but a comment", text: "# not a setting in sight\n"),
    ]

    /// The lines that differ, by position — the shape of a diff, which is what "disturbs nothing else"
    /// has to be measured against.
    static func changedLines(_ before: String, _ after: String) -> [String] {
        let old = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let new = after.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard old.count == new.count else {
            return ["\(old.count) lines became \(new.count)"]
        }
        return zip(old, new).filter { $0 != $1 }.map { String($1) }
    }

    // MARK: - Round-trip identity

    @Test(arguments: corpus)
    func aDocumentRendersBackByteForByte(_ file: File) throws {
        #expect(try ConfigDocument(file.text).rendered == file.text)
    }

    /// The two readings can never diverge, because they are the same code over the same table.
    @Test(arguments: corpus)
    func aDocumentReadsWhatConfigParseReads(_ file: File) throws {
        #expect(try ConfigDocument(file.text).config == Config.parse(file.text))
    }

    @Test(arguments: corpus)
    func aDocumentThrowsWhatConfigParseThrows(_ file: File) throws {
        let broken = file.text + "\n[layuot]\ncolumn-gap = 8\n"
        let fromParse = #expect(throws: ConfigSyntaxError.self) { _ = try Config.parse(broken) }
        let fromDocument = #expect(throws: ConfigSyntaxError.self) { _ = try ConfigDocument(broken) }
        #expect(fromDocument?.description == fromParse?.description)
    }

    // MARK: - set

    @Test func settingAValueTheFileAlreadyHasMovesExactlyOneLine() throws {
        var document = try ConfigDocument(Self.real)
        try document.set("layout.column-gap", to: .number(12))
        #expect(Self.changedLines(Self.real, document.rendered) == ["column-gap = 12"])
        #expect(document.config.columnGap == 12)
    }

    /// A base gap and a per-side override are two real keys that both mean something, so an edit to one
    /// is not allowed to be clever about the other.
    @Test func aBaseGapAndItsPerSideOverrideAreEditedIndependently() throws {
        var document = try ConfigDocument(Self.real)
        try document.set("layout.outer-gap", to: .number(30))
        #expect(Self.changedLines(Self.real, document.rendered) == ["outer-gap = 30"])
        #expect(document.config.outerGaps == EdgeInsets(top: 8, left: 30, bottom: 30, right: 30))

        try document.set("layout.outer-gap-top", to: .number(4))
        #expect(document.config.outerGaps == EdgeInsets(top: 4, left: 30, bottom: 30, right: 30))
    }

    @Test func aNewKeyJoinsTheEndOfItsTablesRunOfKeys() throws {
        var document = try ConfigDocument(Self.real)
        try document.set("layout.center-focused-column", to: .bool(true))
        #expect(document.rendered.contains("outer-gap-top = 8\ncenter-focused-column = true\n\n[focus]"))
        #expect(document.config.centerFocusedColumn)
    }

    /// The run ends at the last *key*, not at the blank line or the comment after it, so a new key
    /// joins its table instead of the gap between two.
    @Test func aNewKeyGoesBeforeTheCommentThatIntroducesTheNextTable() throws {
        var document = try ConfigDocument("""
        [layout]
        column-gap = 8

        # what the strip does when focus moves
        [focus]
        system-events = "ignore"
        """)
        try document.set("layout.window-gap", to: .number(4))
        #expect(document.rendered == """
        [layout]
        column-gap = 8
        window-gap = 4

        # what the strip does when focus moves
        [focus]
        system-events = "ignore"
        """)
    }

    @Test func aKeyWhoseTableHasNoHeaderGetsOne() throws {
        var document = try ConfigDocument("[layout]\ncolumn-gap = 8\n")
        try document.set("animation.scroll.stiffness", to: .number(400))
        #expect(document.rendered == "[layout]\ncolumn-gap = 8\n\n[animation.scroll]\nstiffness = 400\n")
        #expect(document.config.scrollSpring.stiffness == 400)
    }

    @Test func aKeyInAnEmptyTableGoesRightUnderItsHeader() throws {
        var document = try ConfigDocument("[animation]\n\n[layout]\ncolumn-gap = 8\n")
        try document.set("animation.cover", to: .string("immediate"))
        #expect(document.rendered == "[animation]\ncover = \"immediate\"\n\n[layout]\ncolumn-gap = 8\n")
        #expect(document.config.coverMode == .immediate)
    }

    @Test func aFileWithNoTableAtAllGetsOneAppended() throws {
        var document = try ConfigDocument("# my window manager\n")
        try document.set("layout.column-gap", to: .number(8))
        #expect(document.rendered == "# my window manager\n\n[layout]\ncolumn-gap = 8\n")
    }

    @Test func anEmptyFileBecomesJustTheTableAndTheKey() throws {
        var document = try ConfigDocument("")
        try document.set("layout.column-gap", to: .number(8))
        #expect(document.rendered == "[layout]\ncolumn-gap = 8\n")
    }

    /// Per file, not per line: the terminator an inserted line ends with is the one the file uses.
    @Test func aCRLFFileKeepsItsLineEndingsThroughAnEdit() throws {
        var document = try ConfigDocument(Self.crlf)
        try document.set("layout.column-gap", to: .number(12))
        try document.set("layout.center-focused-column", to: .bool(true))
        #expect(document.rendered == "[layout]\r\ncolumn-gap = 12\r\nwindow-gap = 4\r\n"
                                   + "center-focused-column = true\r\n\r\n[focus]\r\n"
                                   + "system-events = \"ignore\"\r\n")
        #expect(!document.rendered.contains("\n\n"))
    }

    /// Deterministic, so a GUI that writes the same change twice writes the same file — and a change
    /// re-applied to its own output is a no-op rather than a second line.
    @Test func theSameChangeWrittenTwiceWritesTheSameFile() throws {
        var once = try ConfigDocument(Self.real)
        try once.set("layout.center-focused-column", to: .bool(true))

        var twice = try ConfigDocument(Self.real)
        try twice.set("layout.center-focused-column", to: .bool(true))
        #expect(once.rendered == twice.rendered)

        var again = try ConfigDocument(once.rendered)
        try again.set("layout.center-focused-column", to: .bool(true))
        #expect(again.rendered == once.rendered)
    }

    @Test func aFileOfRulesIsUntouchedByAnEditElsewhereInIt() throws {
        var document = try ConfigDocument(Self.windowRules)
        try document.set("layout.column-gap", to: .number(6))
        #expect(document.rendered == Self.windowRules + "\n\n[layout]\ncolumn-gap = 6\n")
        #expect(document.config.windowRules.count == 2)
    }

    /// A GUI gets the file's own diagnostic instead of a second validator to keep in step with the
    /// first — and gets its document back untouched, so a refused edit costs nothing.
    @Test func anEditTheSchemaRefusesDoesNotLand() throws {
        var document = try ConfigDocument(Self.real)

        let outOfRange = #expect(throws: ConfigSyntaxError.self) {
            try document.set("layout.column-gap", to: .number(-1))
        }
        #expect(outOfRange?.description == "line 2: 'layout.column-gap' must be at least 0")

        let misspelled = #expect(throws: ConfigSyntaxError.self) {
            try document.set("layout.colum-gap", to: .number(8))
        }
        #expect(misspelled?.description == "line 6: unknown setting 'layout.colum-gap'")

        #expect(document.rendered == Self.real)
        #expect(document.config.columnGap == 20)
    }

    // MARK: - remove

    @Test func removingAKeyTheFileDoesNotSetIsANoOp() throws {
        var document = try ConfigDocument(Self.real)
        try document.remove("layout.center-focused-column")
        #expect(document.rendered == Self.real)
    }

    @Test func removingAKeyLeavesNoBlankLineWhereItWas() throws {
        var document = try ConfigDocument(Self.real)
        try document.remove("layout.window-gap")
        #expect(document.rendered.contains("column-gap = 20\nouter-gap = 20\n"))
        #expect(!document.rendered.contains("\n\n\n"))
        #expect(document.config.windowGap == Config().windowGap)
    }

    /// A comment on a value line describes that value, so it goes when the value goes — the
    /// alternative is a sentence left explaining a setting the file no longer has.
    @Test func removingAKeyTakesItsTrailingCommentWithIt() throws {
        var document = try ConfigDocument(Self.trailingComments)
        try document.remove("layout.window-gap")
        #expect(document.rendered == """
        # how wide the strip breathes
        [layout]      # points throughout
        column-gap = 8    # between columns
        center-focused-column = true
        """)
    }

    /// The last line of a file that doesn't end in a terminator has none of its own to take, so it
    /// takes the one in front of it instead.
    @Test func removingTheLastLineOfAFileThatDoesNotEndInATerminator() throws {
        var document = try ConfigDocument(Self.noTrailingNewline)
        try document.remove("layout.window-gap")
        #expect(document.rendered == "[layout]\ncolumn-gap = 8")
    }

    // MARK: - Spelling

    /// The writer's half of the grammar, pinned exactly: these are the bytes that land in a file.
    @Test func valuesAreSpelledTheWayTheFileWritesThem() {
        #expect(TOMLValue.bool(false).spelled == "false")
        #expect(TOMLValue.number(8).spelled == "8")            // never `8.0`
        #expect(TOMLValue.number(-3).spelled == "-3")
        #expect(TOMLValue.number(0.5).spelled == "0.5")
        #expect(TOMLValue.string("focus left").spelled == #""focus left""#)
        #expect(TOMLValue.string("a\"b\\c\td").spelled == #""a\"b\\c\td""#)
        #expect(TOMLValue.literalString(#"^com\.apple\."#).spelled == #"'^com\.apple\.'"#)
        #expect(TOMLValue.array([.number(1), .number(0.5)]).spelled == "[1, 0.5]")
        #expect(TOMLValue.array([]).spelled == "[]")
    }

    /// A literal string has no escape for its own quote, so text carrying one is written the other way
    /// rather than written unreadably.
    @Test func aLiteralStringThatCannotHoldItsTextIsWrittenAsABasicOne() {
        #expect(TOMLValue.literalString("it's").spelled == #""it's""#)
        #expect(TOMLValue.literalString("two\nlines").spelled == #""two\nlines""#)
    }

    /// Spelling and reading are inverses: whatever the writer writes, the reader reads back as the
    /// value that was written — which is the property that lets a GUI's edit survive its own save.
    @Test func everySpellingReadsBackAsTheValueItSpelled() throws {
        let values: [TOMLValue] = [
            .bool(true), .bool(false),
            .number(8), .number(-3), .number(0.5), .number(1e9),
            .string("focus left"), .string("a\"b\\c\td"), .string("a\r\nb"), .string(""),
            .string("exec osascript -e 'tell application \"Ghostty\" to new window'"),
            .literalString(#"^com\.apple\."#), .literalString("it's"),
            .array([.number(1), .string("x")]), .array([]),
        ]
        for value in values {
            let table = try TOMLTable.parse("key = " + value.spelled + "\n")
            let read = table.values["key"]
            #expect(read?.spelled == value.spelled, "\(value.spelled)")
        }
    }

    /// A key is spelled bare where the charset allows and quoted where it doesn't — the same rule the
    /// reader applies. Every chord `KeyChord` accepts is bare, so this is the grammar covering itself
    /// rather than a case `[keys]` can reach.
    @Test func aKeyIsSpelledBareOrQuotedAsTheCharsetDemands() {
        #expect(TOMLTable.spell(key: "column-gap") == "column-gap")
        #expect(TOMLTable.spell(key: "alt_1") == "alt_1")
        #expect(TOMLTable.spell(key: "#") == "\"#\"")
        #expect(TOMLTable.spell(key: "a b") == "\"a b\"")
        #expect(TOMLTable.spell(key: "") == "\"\"")
    }

    /// `[keys]` is the open table — its names are the user's own, and a new one joins the run like any
    /// other key, with the command it names read by the same parser a hand-written line gets.
    @Test func aNewBindingJoinsTheKeysTable() throws {
        var document = try ConfigDocument(Self.real)
        let bound = try Config.parse(Self.real).keys.count
        try document.set("keys.alt-p", to: .string("exec osascript -e 'say \"hi\"'"))
        #expect(document.rendered == Self.real + #"alt-p = "exec osascript -e 'say \"hi\"'""# + "\n")
        #expect(document.config.keys.count == bound + 1)
    }
}
