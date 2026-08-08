// The example config file, generated from the schema rather than restated beside it.
//
// It used to be a comment block at the top of `ConfigSyntax.swift`, and that comment is the proof this
// is worth doing: a hand-written restatement of the reader, kept true by nothing but a careful eye. Now
// the settings, their sentences and their defaults all come off the one table the reader runs, so the
// document cannot describe a schema emira doesn't have.
//
// The three surfaces the table deliberately doesn't describe come off `ConfigSchema.bespoke`, which
// carries the prose each of them writes. Where one goes falls out of how the file spells it — a dotted
// key joins the table it names, a bare one opens a header of its own — so this places nothing by hand
// and cannot leave a surface out by saying nothing about it. Their prose is hand-written for the same
// reason their readers are, and the whole document is *parsed* by the test that pins it, so a spelling
// that stopped being legal fails the suite instead of misleading a reader.

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
            // A surface written directly after this key — `outer-gap` follows `window-gap`, so the
            // three gaps are documented together.
            for surface in bespoke where surface.after == setting.key {
                tables[tables.endIndex - 1].entries.append(surface.documentation)
            }
        }
        // One written inside a table but after everything in it; one that opens a header of its own
        // falls through to `blocks` below.
        for surface in bespoke where surface.after == nil {
            guard let table = surface.table,
                  let i = tables.firstIndex(where: { $0.header == "[\(table)]" })
            else { continue }
            tables[i].entries.append(surface.documentation)
        }
        let generated = tables.map { ([$0.header] + $0.entries).joined(separator: "\n\n") }
        let blocks = bespoke.filter { $0.table == nil }.map(\.documentation)
        return ([preamble] + generated + blocks).joined(separator: "\n\n") + "\n"
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
}
