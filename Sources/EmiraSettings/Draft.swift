import EmiraConfig
import EmiraCore

// The edit session: the file as it stands, and the file as it started. Every control reads and writes
// through this, and Save is `rendered`.
//
// **No I/O**, the same rule `ConfigDocument` keeps and for the same reason: the window owns the path,
// the atomic write and the watcher, and a draft that read the disk could disagree with the one on
// screen. What is here is text ⇄ values, and the two documents that make "dirty" a fact rather than a
// flag someone has to remember to set.

/// One editing session over a config file.
public struct Draft {

    /// The document as the file was when it was opened — Discard's destination, and the other half of
    /// every dirty comparison.
    public private(set) var baseline: ConfigDocument
    /// The document as it now stands. What the preview reads and what Save writes.
    public private(set) var document: ConfigDocument

    /// Why the last edit did not land, or `nil` if it did. One sentence, the file's own — the schema
    /// refusing a value produces the same complaint here that `emira config set` prints.
    public private(set) var refusal: String?

    /// Open a draft over `text`. An absent file is read as the starter document, which is what the
    /// daemon makes of one.
    ///
    /// - Throws: `ConfigSyntaxError` for a file that does not parse, which is what keeps the window
    ///   shut: splicing text whose meaning is unknown is the one thing a GUI must not do, and the
    ///   caller says so and sends the user to the file.
    public init(_ text: String) throws {
        let document = try ConfigDocument(text)
        self.baseline = document
        self.document = document
    }

    /// The config the preview draws — a reading of the file that would be saved. `ConfigDocument`
    /// re-reads its own text on every edit, so this cannot fall out of step with `rendered`.
    public var config: Config { document.config }

    /// The text Save writes.
    public var rendered: String { document.rendered }

    /// Whether anything would be written. Compares the text rather than the values: a draft that set a
    /// key and then set it back has changed nothing, and one that only reordered bytes is not something
    /// this can produce.
    public var isDirty: Bool { document.rendered != baseline.rendered }

    /// The value `setting` currently holds, spelled as the file would spell it.
    public func value(of setting: Setting) -> TOMLValue {
        setting.value(in: config)
    }

    /// One thing a control asks the draft to do.
    ///
    /// **Two cases, because the two surfaces disagree about what a file should contain.** A `Setting`
    /// knows its own default and is unset when it reaches it; a bespoke key's default is whatever the
    /// file says elsewhere — an `outer-gap-top` is redundant when it matches the `outer-gap` two lines
    /// up — so it is asked rather than known. Both rules live on `ConfigDocument`, and this is which of
    /// them a row is entitled to.
    public enum Edit {
        /// A key the table describes, at the value a control produced.
        case setting(Setting, TOMLValue)
        /// One key of a surface the table cannot describe, spelled the way the file spells it.
        case key(String, TOMLValue)

        /// The dotted key this touches — what a take is looked up by.
        public var key: String {
            switch self {
            case .setting(let setting, _): return setting.key
            case .key(let key, _):         return key
            }
        }
    }

    /// Take an edit.
    ///
    /// A refused edit leaves the document exactly as it was and records the complaint — so a slider that
    /// ran past a bound and a number typed below its floor both leave something true on screen rather
    /// than a value the file would not accept.
    public mutating func apply(_ edit: Edit) {
        do {
            switch edit {
            case .setting(let setting, let value): try document.set(setting, to: value)
            case .key(let key, let value):         try document.setOrUnset(key, to: value)
            }
            refusal = nil
        } catch let error as ConfigSyntaxError {
            refusal = error.message
        } catch {
            refusal = "\(error)"
        }
    }

    /// Take a new value for `setting` — `apply(.setting(…))`, kept because a caller that has a `Setting`
    /// in hand should not have to spell the case.
    public mutating func set(_ setting: Setting, to value: TOMLValue) {
        apply(.setting(setting, value))
    }

    /// Back to the file as it was opened. The preview re-derives from `config`, so nothing else has to
    /// be told.
    public mutating func discard() {
        document = baseline
        refusal = nil
    }

    /// Take `text` as the new baseline *and* the new document — the file changed underneath a draft with
    /// nothing unsaved in it, which is a silent re-read.
    ///
    /// - Throws: as `init` does, and the draft is untouched when it throws.
    public mutating func reload(_ text: String) throws {
        let document = try ConfigDocument(text)
        self.baseline = document
        self.document = document
        self.refusal = nil
    }

    /// Take the draft's own text as the baseline — what a successful Save leaves behind, and the one
    /// thing that makes a saved draft clean without re-reading the file it just wrote.
    public mutating func saved() {
        baseline = document
    }
}
