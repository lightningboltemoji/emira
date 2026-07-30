// The example config file, generated from the schema rather than restated beside it.
//
// It used to be a comment block at the top of `ConfigSyntax.swift`, and that comment is the proof this
// is worth doing: a hand-written restatement of the reader, kept true by nothing but a careful eye. Now
// the settings, their sentences and their defaults all come off the one table the reader runs, so the
// document cannot describe a schema emira doesn't have.
//
// The bespoke blocks below are the three sections the table deliberately doesn't describe. Their prose
// is hand-written for the same reason their readers are — but the whole document is *parsed* by the
// test that pins it, so a spelling that stopped being legal fails the suite instead of misleading a
// reader.

extension ConfigSchema {

    /// Every setting emira has, written out as the config file that would set each to its default.
    ///
    /// Pinned by a golden file (`emira.example.toml`), which is what the docs quote: generated means it
    /// cannot drift from the reader, and golden means it cannot change without someone reading the diff.
    public static var document: String {
        var tables: [(header: String, entries: [String])] = []
        for setting in settings {
            let header = "[\(setting.table)]"
            if tables.last?.header != header { tables.append((header, [])) }
            tables[tables.endIndex - 1].entries.append(entry(setting))
        }
        // `outer-gap` is documented where it is written — inside `[layout]`, which the loop above has
        // already opened. It is one value with five spellings, so no single entry can carry it.
        if let layout = tables.firstIndex(where: { $0.header == "[layout]" }) {
            tables[layout].entries.append(outerGapBlock)
        }
        let generated = tables.map { ([$0.header] + $0.entries).joined(separator: "\n\n") }
        return ([preamble] + generated + [keysBlock, windowRulesBlock])
            .joined(separator: "\n\n") + "\n"
    }

    /// One setting: its sentence, what it may be, and the line that sets it to its default.
    private static func entry(_ setting: Setting) -> String {
        let notes = [setting.help] + [setting.kind.legend].compactMap { $0 }
        return (notes.flatMap(comment) + ["\(TOMLTable.spell(key: setting.name)) = "
                                       + "\(setting.defaultValue.spelled)"]).joined(separator: "\n")
    }

    /// `text` as `#` comment lines, wrapped to the width the rest of the tree is written at.
    private static func comment(_ text: String) -> [String] {
        var lines: [String] = []
        var line = "#"
        for word in text.split(separator: " ") {
            if line.count + word.count + 1 > 96 {
                lines.append(line)
                line = "#"
            }
            line += " " + word
        }
        return lines + [line]
    }

    private static let preamble = """
    # Every setting emira has, at its default — so a file that says none of this says exactly this.
    # Write down only what you disagree with: an absent key keeps its default, and a key emira does not
    # know is an error naming its line rather than a setting that quietly does nothing.
    #
    # Generated from the schema (`ConfigSchema.document`), and pinned by a test. Don't edit it by hand.
    """

    /// One logical value with five spellings, so no single entry can carry it.
    private static let outerGapBlock = """
    # Points of margin held clear at the edges of the working area. Not a strut: a strut is forbidden
    # ground, an outer gap is empty at rest and crossed in motion.
    # In points, must be at least 0.
    outer-gap = 0

    # …and outer-gap-left, outer-gap-bottom, outer-gap-right — each replacing one side of it. A side on
    # its own means that side, so outer-gap-left alone leaves the other three where they were.
    # In points, must be at least 0.
    outer-gap-top = 0
    """

    /// The one open table: its key names are invented by whoever writes the file.
    private static let keysBlock = """
    # The one open table: its names are chords you invent, and its values are commands spelled exactly
    # as the CLI spells them. Nothing is bound by default — registering a hotkey takes that chord from
    # every other app on the machine, which is also why `exec` is in the vocabulary: emira has to be
    # able to give one back. Punctuation in a chord is named rather than typed.
    [keys]

    alt-h = "focus left"
    alt-shift-h = "move-window left"
    cmd-alt-period = "center-column"
    alt-space = "exec ghostty"
    """

    /// The one repeating table — written out twice, because repeating is the thing to show.
    private static let windowRulesBlock = """
    # A list, so the header repeats, and the only place order in the file means anything: every matching
    # rule applies, top to bottom, later ones overriding earlier ones field by field. A rule has to both
    # match something and do something. Regular expressions are compiled when the file is read, so a
    # broken one is a line number rather than a rule that quietly never fires.
    [[window-rules]]

    # …or app-id-regex / title / title-regex, all of which must match.
    app-id = "com.tinyspeck.slackmacgap"
    # Where a matching window starts…
    workspace = "3"
    # …and how wide it starts, on width-presets' scale.
    width = 0.5

    # Write a regex in a 'literal string': a "…" string would need every backslash doubled, and \\d is
    # not an escape this grammar admits at all.
    [[window-rules]]

    title-regex = 'Inspector'
    # Off the strip entirely, overriding whatever emira made of the window's role.
    float = true
    """
}
