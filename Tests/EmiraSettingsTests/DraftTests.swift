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
}
