import EmiraCore

// The config file as something you can edit — the writer half of `EmiraConfig`, and the reason
// `TOML.swift` carries spans at all.
//
// A settings window reads a `Config` out of a file and writes single values back into it. What it must
// not do is *rewrite* the file: emira is configured by hand today, and the comments, the ordering and
// the blank lines that group one table from the next are the author's work. A `Config → TOML`
// serializer would be a tenth of this code and would eat all three. So nothing here formats. An edit
// splices over the stretch of text one value occupies, or adds one line, and every other byte stays
// exactly where the author left it — including the spaces around a `=` and whether a number two lines
// up was typed `8` or `8.0`.
//
// **No I/O.** `rendered` is a `String`; the caller writes it. The atomic temp-file + `rename(2)` dance
// belongs with the code that owns the path, and `ConfigWatcher` (`ConfigLoader.swift`) is already built
// to survive exactly that kind of save.

/// A config file, its text and its parse held together, so a value can be changed in place. Every
/// field is a `let`: an edit replaces the whole document rather than patching one, which is what makes
/// the text, the spans and the `Config` unable to disagree.
public struct ConfigDocument {

    /// The file's text. `rendered` is this and nothing else, which makes round-trip identity a property
    /// of the design rather than one the tests have to keep true.
    private let text: String
    /// The same text parsed, kept whole: the schema consumes a *copy*, so the spans survive the read.
    private let table: TOMLTable
    /// The terminator this file's lines end with. Per file, not per line — Swift reads `"\r\n"` as one
    /// grapheme, so a CRLF file arrives as CRLF lines, and any line this adds has to match.
    private let terminator: String

    /// The document read as a `Config`. In step with every edit: one the schema refuses throws rather
    /// than landing, so this is always the reading of `rendered`.
    public let config: Config

    /// Read a config file, remembering where every value in it was written.
    ///
    /// - Throws: `ConfigSyntaxError` — exactly what `Config.parse` throws of the same text, from the
    ///   same code. A document that cannot be read is one a GUI must not offer to write.
    public init(_ text: String) throws {
        let table = try TOMLTable.parse(text)
        var consumable = table
        self.config = try Config(reading: &consumable)
        self.table = table
        self.text = text
        self.terminator = text.first(where: \.isNewline).map(String.init) ?? "\n"
    }

    /// The file as it now stands, for the caller to write.
    public var rendered: String { text }

    /// Set `key` to `value` — splicing over the value already on its line, or inserting a line for a
    /// key the file doesn't set.
    ///
    /// `key` is a dotted path spelled the way the parse flattens one: `"layout.column-gap"`,
    /// `"keys.alt-h"`. Overlapping spellings are nobody's business but the schema's — setting
    /// `layout.outer-gap` in a file that also sets `layout.outer-gap-top` touches the first line and
    /// leaves the second alone, because both keys are real and both mean something.
    ///
    /// **Not an element of a `[[window-rules]]`.** Those flatten under a positional index that
    /// `TOMLTable.takeArray` calls an implementation detail, and `"window-rules.2.app-id"` would make
    /// it public by accident. Editing rules needs to move whole blocks to reorder them, so it gets an
    /// API of its own; this one is for named settings.
    ///
    /// - Throws: `ConfigSyntaxError` when the result is not a config the schema accepts — a number
    ///   outside its range, a key it doesn't know. The document is untouched, so a refused edit costs
    ///   nothing, and the complaint is the same sentence the file itself would have produced.
    public mutating func set(_ key: String, to value: TOMLValue) throws {
        var edited = text
        if let span = table.span(of: key) {
            edited.replaceSubrange(span.value, with: value.spelled)
        } else {
            insert(key, value, into: &edited)
        }
        try commit(edited)
    }

    /// Unset `key`, taking its whole line with it — **its trailing comment included**, since a comment
    /// on a value line describes that value and would be left describing nothing. A key the file
    /// doesn't set is left alone.
    ///
    /// - Throws: as `set` does. Dropping a key restores its default, which the schema accepts on its
    ///   own; a rule that loses its last matcher is the case that doesn't.
    public mutating func remove(_ key: String) throws {
        guard let span = table.span(of: key) else { return }
        var edited = text
        edited.removeSubrange(withTerminator(span.line))
        try commit(edited)
    }

    /// Take the edit, by reading the edited text from scratch. Spans move when text is spliced, so the
    /// alternative is bookkeeping to keep the parse in step with the file, and there is no version of
    /// that which cannot fall out of step. Reading again cannot: it is where `config` comes from and
    /// where the next edit's spans come from, both at once, and a config file is a page long.
    ///
    /// An assignment, so a document whose edit the schema refuses is left exactly as it was.
    private mutating func commit(_ edited: String) throws {
        self = try ConfigDocument(edited)
    }

    //
    // Deterministic, so writing the same change twice writes the same file. Where a *new header* goes
    // is the part with a real choice in it, and appending is the placeholder: once a schema can be
    // enumerated, the file's tables can be ordered the way the schema is.

    /// A key the file doesn't set yet: at the end of its `[table]`'s run of keys, or under a header
    /// appended for it.
    private func insert(_ key: String, _ value: TOMLValue, into edited: inout String) {
        var path = key.split(separator: ".").map(String.init)
        let name = path.popLast() ?? key
        let statement = TOMLTable.spell(key: name) + " = " + value.spelled

        if let extent = table.extent(of: path) {
            // The run ends at the last key line, not at the blank line or comment that may follow it,
            // so the new key joins the table rather than the gap after it.
            edited.insert(contentsOf: terminator + statement, at: extent.upperBound)
        } else if path.isEmpty {
            // A top-level key has to precede every header — TOML's rule, not a preference. No setting
            // is spelled that way, so this is here to put an unknown one somewhere the schema can name
            // it, rather than somewhere the *grammar* complains about first.
            if let first = table.firstHeaderStart {
                edited.insert(contentsOf: statement + terminator + terminator, at: first)
            } else {
                append(statement, to: &edited)
            }
        } else {
            let header = "[" + path.map(TOMLTable.spell(key:)).joined(separator: ".") + "]"
            append(header + terminator + statement, to: &edited)
        }
    }

    /// At the end of the file, a blank line clear of whatever was there. A file that didn't end in a
    /// terminator gains one, which is the one byte an append moves that it wasn't asked to.
    private func append(_ block: String, to edited: inout String) {
        if let last = edited.last, !last.isNewline { edited += terminator }
        if !edited.isEmpty { edited += terminator }
        edited += block + terminator
    }

    /// A line's range grown to swallow the terminator that ends it — or, on a last line that has none,
    /// the terminator before it, so removing the line doesn't leave a blank one in its place.
    private func withTerminator(_ line: Range<String.Index>) -> Range<String.Index> {
        if line.upperBound < text.endIndex, text[line.upperBound].isNewline {
            return line.lowerBound..<text.index(after: line.upperBound)
        }
        if line.lowerBound > text.startIndex {
            return text.index(before: line.lowerBound)..<line.upperBound
        }
        return line
    }
}
