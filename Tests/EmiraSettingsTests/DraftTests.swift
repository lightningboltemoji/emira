import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// The edit session. What only a draft can be asked: that an edit lands as text, that setting something
// to its default takes the key out rather than writing it down, and that a refused value leaves the file
// exactly as it was.

@Suite struct DraftTests {

    static func setting(_ key: String) throws -> Setting {
        try #require(ConfigSchema.setting(for: key))
    }

    static let file = """
        # a comment the author wrote
        [layout]
        column-gap = 8
        window-gap = 4
        """

    @Test func aDocumentNobodyTouchedRendersItsOwnText() throws {
        let draft = try Draft(Self.file)
        #expect(draft.rendered == Self.file)
        #expect(!draft.isDirty)
        #expect(draft.refusal == nil)
    }

    @Test func anEditLandsAsTextAndMakesTheDraftDirty() throws {
        var draft = try Draft(Self.file)
        draft.set(try Self.setting("layout.column-gap"), to: .number(20))

        #expect(draft.isDirty)
        #expect(draft.config.columnGap == 20)
        #expect(draft.rendered.contains("column-gap = 20"))
        // Every other byte where the author left it, the comment included.
        #expect(draft.rendered.contains("# a comment the author wrote"))
        #expect(draft.rendered.contains("window-gap = 4"))
    }

    @Test func settingSomethingToItsDefaultUnsetsIt() throws {
        var draft = try Draft(Self.file)
        let gap = try Self.setting("layout.column-gap")
        #expect(gap.defaultValue.spelled == "0")

        draft.set(gap, to: .number(0))

        // An absent key already means the default; writing it down would pin it against ever changing.
        #expect(!draft.rendered.contains("column-gap"))
        #expect(draft.config.columnGap == 0)
        #expect(draft.isDirty)
    }

    @Test func aRefusedEditDoesNotLandAndCarriesTheFilesOwnSentence() throws {
        var draft = try Draft(Self.file)
        let before = draft.rendered

        draft.set(try Self.setting("layout.column-gap"), to: .number(-5))

        #expect(draft.rendered == before)
        #expect(draft.config.columnGap == 8)
        #expect(!draft.isDirty)
        let refusal = try #require(draft.refusal)
        #expect(refusal.contains("column-gap"))
    }

    @Test func alandingEditClearsAnEarlierRefusal() throws {
        var draft = try Draft(Self.file)
        draft.set(try Self.setting("layout.column-gap"), to: .number(-5))
        #expect(draft.refusal != nil)

        draft.set(try Self.setting("layout.column-gap"), to: .number(12))
        #expect(draft.refusal == nil)
    }

    @Test func discardGoesBackToTheFileAsItWasOpened() throws {
        var draft = try Draft(Self.file)
        draft.set(try Self.setting("layout.column-gap"), to: .number(20))
        draft.set(try Self.setting("layout.window-gap"), to: .number(30))
        #expect(draft.isDirty)

        draft.discard()

        #expect(draft.rendered == Self.file)
        #expect(!draft.isDirty)
        #expect(draft.config.columnGap == 8)
    }

    @Test func anEditSetBackByHandIsNotDirty() throws {
        var draft = try Draft(Self.file)
        draft.set(try Self.setting("layout.column-gap"), to: .number(20))
        draft.set(try Self.setting("layout.column-gap"), to: .number(8))

        // Dirty is a comparison and not a flag, so putting a value back really is putting it back.
        #expect(!draft.isDirty)
    }

    @Test func savingMakesTheDraftItsOwnBaseline() throws {
        var draft = try Draft(Self.file)
        draft.set(try Self.setting("layout.column-gap"), to: .number(20))
        let saved = draft.rendered

        draft.saved()

        #expect(!draft.isDirty)
        draft.discard()
        #expect(draft.rendered == saved)
    }

    @Test func reloadTakesANewFileWholesale() throws {
        var draft = try Draft(Self.file)
        draft.set(try Self.setting("layout.column-gap"), to: .number(20))

        try draft.reload("[layout]\ncolumn-gap = 3")

        #expect(!draft.isDirty)
        #expect(draft.config.columnGap == 3)
    }

    @Test func aFileThatDoesNotParseIsRefusedAtTheDoor() {
        // The window opens read-only on this: splicing text whose meaning is unknown is the one thing a
        // GUI must not do.
        #expect(throws: ConfigSyntaxError.self) {
            _ = try Draft("[layout]\ncolumn-gap = ")
        }
    }

    @Test func anEmptyFileIsEveryDefault() throws {
        let draft = try Draft("")
        #expect(draft.config == Config())
        #expect(!draft.isDirty)
    }

    // The two edits an open table needs
    //
    // A `Setting` is never absent and never renamed. A `[keys]` entry is both, constantly — which is
    // why neither of these is expressible as a value written to a key.

    @Test func anUnsetTakesTheWholeLine() throws {
        var draft = try Draft("""
        [keys]
        alt-h = "focus left"   # the one I actually use
        alt-l = "focus right"
        """)
        draft.apply(.unset("keys.alt-h"))

        #expect(draft.refusal == nil)
        #expect(draft.config.keys.count == 1)
        // The trailing comment described that binding, so it goes with it.
        #expect(!draft.rendered.contains("actually use"))
        #expect(draft.rendered == "[keys]\nalt-l = \"focus right\"")
    }

    @Test func aRenameRetypesTheChordAndKeepsTheCommand() throws {
        var draft = try Draft("[keys]\nalt-h = \"focus left\"\nalt-l = \"focus right\"\n")
        draft.apply(.rename("keys.alt-h", to: "keys.ctrl-alt-h"))

        #expect(draft.refusal == nil)
        #expect(draft.config.keys.map(\.chord.description) == ["ctrl-alt-h", "alt-l"])
        #expect(draft.config.keys.first?.spelling == "focus left")
    }

    /// **A refused rename leaves the binding where it was, not deleted.** The whole reason this is one
    /// edit rather than a `remove` and a `set`: two edits have a state between them in which the user's
    /// binding does not exist.
    @Test func aRefusedRenameLeavesTheBindingAlone() throws {
        var draft = try Draft("[keys]\nalt-h = \"focus left\"\nalt-l = \"focus right\"\n")
        let before = draft.rendered
        draft.apply(.rename("keys.alt-h", to: "keys.alt-l"))

        #expect(draft.refusal != nil)
        #expect(draft.rendered == before, "a refused rename landed")
        #expect(draft.config.keys.count == 2)
        #expect(!draft.isDirty)
    }

    /// An edit names the key a take is looked up by — and after a rename that is the *new* name, since
    /// the row under the pointer is the renamed one.
    @Test func anEditNamesTheKeyItLeavesBehind() {
        #expect(Draft.Edit.unset("keys.alt-h").key == "keys.alt-h")
        #expect(Draft.Edit.rename("keys.alt-h", to: "keys.cmd-j").key == "keys.cmd-j")
    }
}
