import Foundation

// The config file's format — text in, keyed values out, and one value at a time spelled back. TOML
// 1.0.0, read by a scanner over Unicode *scalars*, which is the unit the spec's own ABNF is written
// in. Every value carries both the line it was read on and the stretch of text it was read from —
// which is what lets `ConfigDocument` change one value and disturb no other byte.
//
// **Scalars, not lines, and not `Character`s.** `ws` is space and tab; `newline` is LF or CRLF. Swift's
// `isWhitespace` also admits NBSP and `isNewline` also admits U+0085, U+2028 and U+2029 — scalars
// `basic-unescaped` explicitly permits *inside* a string, so a reader that splits on them reports an
// unterminated string in a file that is correct. And `"\r\n"` is one `Character` but two scalars, so
// only the scalar view can tell a bare CR from a line ending.
//
// **A tree, because a name means one of three things.** A table holds values, subtables and arrays of
// tables, and each table remembers how it came to exist — declared, implied by a deeper header, made by
// a dotted key, or written inline. That is what the redefinition rules are stated in terms of, what
// files `[a.b]` after `[[a]]` against the array's last element, and what keeps an element's index out of
// the same namespace as an all-digit key. The schema still addresses the document by dotted path: that
// is an interface, and this is the storage.
//
// A date-time is kept as the text it was written as, validated to the calendar and no further. Nothing
// emira has is one, so the components are never asked for.
//
// Regexes are written in `'literal strings'`: a `"…"` string has to double every backslash it
// contains — `"^com\\.apple\\."` — and `"\d"` is a reserved escape rather than a character class.

/// Where a value was written. The indices belong to the text that was parsed and mean nothing against
/// any other string; `ConfigDocument` is what holds the two together.
struct TOMLSpan: Equatable {
    /// The value's own text — its trailing comment and the whitespace around it excluded. What an
    /// edit splices over.
    let value: Range<String.Index>
    /// The key's own name as it was written: the **last segment** of the key expression, quoting and
    /// all. What a rename splices over — the segments before it name the table the line sits in, and
    /// changing those would be moving the line rather than renaming it.
    let key: Range<String.Index>
    /// The whole `key = value` carrying it — its trailing comment included, its terminator not. What
    /// an unset takes out. Not a line: a multi-line string or array is one statement over several.
    let statement: Range<String.Index>
}

/// One value read out of the config text — or built to be written into it — plus where it came from.
public struct TOMLValue: Equatable {
    /// TOML's value kinds. Integer and float are two types rather than one `Double`, because the spec
    /// says so and because a `Double` cannot hold every `Int64`.
    enum Payload: Equatable {
        case bool(Bool)
        case integer(Int64)
        case float(Double)
        case string(String)
        /// A date or a time, kept as the text it was written as. Nothing emira has is one, so the
        /// components are never asked for — only that the file said something a date-time may be.
        case dateTime(String)
        case array([TOMLValue])
        /// An inline table `{ … }` standing where a value goes — inside an array, or inside another
        /// inline table. A `TOMLTable` rather than a bare dictionary so that one reading of the
        /// redefinition rules covers both: `{ a = { }, a.b = 1 }` is the same mistake as `[a]` twice.
        indirect case table(TOMLTable)
    }

    /// Which of the two string notations spells this value. Inert on anything that isn't a string.
    enum Quoting: Equatable {
        /// `"…"`, with `\"` `\\` `\n` `\t` `\r` escaped.
        case basic
        /// `'…'`, no escapes at all — how a regex is written, and why (see `ConfigSyntax.swift`).
        case literal
    }

    let payload: Payload
    let quoting: Quoting
    let line: Int
    /// Absent on a value built to be written: it has not been written down anywhere yet.
    let span: TOMLSpan?

    init(payload: Payload, quoting: Quoting = .basic, line: Int, span: TOMLSpan? = nil) {
        self.payload = payload
        self.quoting = quoting
        self.line = line
        self.span = span
    }

    /// How this value's kind is named in a diagnostic ("expected a number, found a string").
    var kindName: String {
        switch payload {
        case .bool:     return "a boolean"
        case .integer:  return "a number"
        case .float:    return "a number"
        case .string:   return "a string"
        case .dateTime: return "a date"
        case .array:    return "an array"
        case .table:    return "a table"
        }
    }

    /// Either numeric kind as the `Double` every setting is read as. `nil` on anything that is not a
    /// number — the one place the schema does not care which of the two the file wrote.
    var asDouble: Double? {
        switch payload {
        case .integer(let value): return Double(value)
        case .float(let value):   return value
        default:                  return nil
        }
    }
}

/// A parsed document: a table of values, subtables and arrays of tables, addressed from outside by the
/// dotted paths the schema is written in.
struct TOMLTable: Equatable {

    /// What brought a table into being. The redefinition rules are written in terms of it: a table the
    /// file *declared* may not be declared twice, while one that only exists because a deeper header
    /// needed it may still be declared later.
    enum Origin: Equatable {
        /// The document, or one `[[array]]` element read as a table of its own.
        case root
        /// `[a]` — written down.
        case header
        /// Brought into being by `[a.b]`, which says nothing about `a` except that it exists.
        case implicit
        /// Brought into being by `a.b = 1`, which closes `a` to any later header.
        case dotted
        /// Written whole as `a = { … }`. Closed to everything: an inline table states its contents in
        /// one breath, and nothing later may add to it.
        case inline
    }

    /// One name in a table.
    enum Entry: Equatable {
        case value(TOMLValue)
        case table(TOMLTable)
        case array([TOMLTable])
    }

    private(set) var origin: Origin = .root
    private(set) var line = 0
    /// The stretch of file this table governs: its header and every key line under it, which is where a
    /// key the file doesn't have yet is inserted. Only a table the file declared has one.
    private(set) var extent: Range<String.Index>?
    /// Whether the schema has said it knows this header. Marked rather than removed, because a table the
    /// schema knows may still hold a key it doesn't.
    private var accepted = false
    private(set) var entries: [String: Entry] = [:]

    init(origin: Origin = .root, line: Int = 0, extent: Range<String.Index>? = nil) {
        self.origin = origin
        self.line = line
        self.extent = extent
    }

    /// This table as an inline one would be written. Sorted by name, because a table carries no order
    /// of its own and the same value has to spell the same way twice.
    var spelled: String {
        let pairs = entries.sorted { $0.key < $1.key }.map { name, entry -> String in
            let value: String
            switch entry {
            case .value(let v):        value = v.spelled
            case .table(let child):    value = child.spelled
            case .array(let elements): value = "[" + elements.map(\.spelled).joined(separator: ", ") + "]"
            }
            return TOMLTable.spell(key: name) + " = " + value
        }
        return pairs.isEmpty ? "{}" : "{ " + pairs.joined(separator: ", ") + " }"
    }

    // Walking
    //
    // Every reader and every writer below goes through one of these two, so there is one answer to what
    // a dotted path means — including that a path through an array of tables means its *last* element,
    // which is the rule `[a.b]` after `[[a]]` turns on.

    /// The table at `path`, or `nil` if the path doesn't lead to one.
    private func table(at path: ArraySlice<String>) -> TOMLTable? {
        guard let name = path.first else { return self }
        switch entries[name] {
        case .table(let child):    return child.table(at: path.dropFirst())
        case .array(let elements): return elements.last?.table(at: path.dropFirst())
        default:                   return nil
        }
    }

    /// Run `body` against the table at `path`, writing back whatever it changed. `nil` when the path
    /// doesn't lead to a table, in which case `body` never runs.
    @discardableResult
    private mutating func withTable<T>(at path: ArraySlice<String>,
                                       _ body: (inout TOMLTable) throws -> T) rethrows -> T? {
        guard let name = path.first else { return try body(&self) }
        switch entries[name] {
        case .table(var child):
            defer { entries[name] = .table(child) }
            return try child.withTable(at: path.dropFirst(), body)
        case .array(var elements):
            guard !elements.isEmpty else { return nil }
            defer { entries[name] = .array(elements) }
            return try elements[elements.count - 1].withTable(at: path.dropFirst(), body)
        default:
            return nil
        }
    }

    private static func segments(_ path: String) -> [String] {
        path.split(separator: ".").map(String.init)
    }

    // Reading
    //
    // Taking the keys it knows and then asking what is left means "unknown key" needs no second list
    // of valid names to drift out of step with the reader.

    /// The value at a dotted path, or `nil` if the file didn't set it. Non-destructive: `ConfigDocument`
    /// reads spans off a table the schema has already eaten.
    func value(at path: String) -> TOMLValue? {
        var names = Self.segments(path)
        guard let last = names.popLast(), let parent = table(at: names[...]),
              case .value(let value)? = parent.entries[last] else { return nil }
        return value
    }

    /// Remove and return the value at a dotted path, or `nil` if the file didn't set it.
    mutating func take(_ path: String) -> TOMLValue? {
        var names = Self.segments(path)
        guard let last = names.popLast() else { return nil }
        return withTable(at: names[...]) { parent -> TOMLValue? in
            guard case .value(let value)? = parent.entries[last] else { return nil }
            parent.entries.removeValue(forKey: last)
            return value
        } ?? nil
    }

    /// Mark a `[table]` header as understood, so it isn't reported as unknown. Taking a key does *not*
    /// imply this: a header may legitimately be declared with nothing under it.
    mutating func acceptTable(_ path: String) {
        withTable(at: Self.segments(path)[...]) { $0.accepted = true }
    }

    /// Remove and return every key under a table, keyed by the part *after* the prefix, earliest line
    /// first. For `[keys]`, the one open table, whose key names the user invents and so cannot be
    /// `take`n one by one.
    ///
    /// A subtable's keys come back dotted, and the subtable itself stays — a `[keys.sub]` header is not
    /// a binding, and it is still a header the schema never asked for.
    mutating func takeAll(under prefix: String) -> [(key: String, value: TOMLValue)] {
        let taken = withTable(at: Self.segments(prefix)[...]) { $0.drainValues(under: "") } ?? []
        return taken.sorted { ($0.value.line, $0.key) < ($1.value.line, $1.key) }
    }

    private mutating func drainValues(under prefix: String) -> [(key: String, value: TOMLValue)] {
        var taken: [(key: String, value: TOMLValue)] = []
        for (name, entry) in entries {
            let path = prefix.isEmpty ? name : prefix + "." + name
            switch entry {
            case .value(let value):
                taken.append((path, value))
                entries.removeValue(forKey: name)
            case .table(var child):
                taken += child.drainValues(under: path)
                entries[name] = .table(child)
            case .array:
                continue
            }
        }
        return taken
    }

    /// Remove and return the elements of an array of tables (`[[window-rules]]`), in file order — each
    /// as a table of its own keys, so the schema reads one element with the very same typed readers it
    /// uses at the top level, and an element's unread keys are that element's leftovers. `nil` when the
    /// document declares none.
    mutating func takeArray(of prefix: String) -> [(line: Int, table: TOMLTable)]? {
        var names = Self.segments(prefix)
        guard let last = names.popLast() else { return nil }
        return withTable(at: names[...]) { parent -> [(line: Int, table: TOMLTable)]? in
            guard case .array(let elements)? = parent.entries[last] else { return nil }
            parent.entries.removeValue(forKey: last)
            return elements.map { (line: $0.line, table: $0) }
        } ?? nil
    }

    /// Everything the schema never took, earliest line first — keys, and headers it never accepted.
    /// Sorted by line so the diagnostic points at the *first* mistake.
    var leftovers: [(key: String, line: Int)] {
        var found: [(key: String, line: Int)] = []
        collectLeftovers(under: "", into: &found)
        return found.sorted { ($0.line, $0.key) < ($1.line, $1.key) }
    }

    private func collectLeftovers(under prefix: String, into found: inout [(key: String, line: Int)]) {
        for (name, entry) in entries {
            let path = prefix.isEmpty ? name : prefix + "." + name
            switch entry {
            case .value(let value):
                found.append((path, value.line))
            case .table(let child):
                // Only a table the file *wrote* is a mistake on its own. One that exists because a
                // deeper header or a dotted key needed it has no line of its own to point at.
                if child.origin == .header, !child.accepted { found.append((path, child.line)) }
                child.collectLeftovers(under: path, into: &found)
            case .array(let elements):
                for element in elements {
                    found.append((path, element.line))
                    element.collectLeftovers(under: path, into: &found)
                }
            }
        }
    }

    // Where things were written
    //
    // What an edit needs and the schema never asks for. Read off the pristine table — `take` is
    // destructive, so a document keeps its own uneaten copy.

    /// Where the value at a dotted path was written, or `nil` if the file doesn't set it.
    func span(of path: String) -> TOMLSpan? {
        value(at: path)?.span
    }

    /// Which line a dotted path was written on — what a diagnostic about it points at.
    func line(of path: String) -> Int? {
        value(at: path)?.line
    }

    /// The keys written directly under `path`, as they were spelled, earliest line first. A deeper key
    /// is not one of them: `keys.alt-h` is a name under `keys`, and `layout.spring.stiffness` is not.
    func names(under path: String) -> [String] {
        guard let table = table(at: Self.segments(path)[...]) else { return [] }
        let found: [(name: String, line: Int)] = table.entries.compactMap { name, entry in
            guard case .value(let value) = entry else { return nil }
            return (name, value.line)
        }
        return found.sorted { ($0.line, $0.name) < ($1.line, $1.name) }.map(\.name)
    }

    /// The stretch of file a new key under `path` goes at the end of, or `nil` when the file declares
    /// no such table and so has no run to join.
    func extent(of path: [String]) -> Range<String.Index>? {
        table(at: path[...])?.extent
    }

    /// Where the first `[table]` header of the file begins — the ceiling a top-level key sits under.
    var firstHeaderStart: String.Index? {
        var earliest: String.Index?
        collectExtents { start in
            if earliest.map({ start < $0 }) ?? true { earliest = start }
        }
        return earliest
    }

    private func collectExtents(_ visit: (String.Index) -> Void) {
        if let extent { visit(extent.lowerBound) }
        for entry in entries.values {
            switch entry {
            case .value:               continue
            case .table(let child):    child.collectExtents(visit)
            case .array(let elements): for element in elements { element.collectExtents(visit) }
            }
        }
    }

    // Building
    //
    // The three ways a document names something, and the rules about naming it twice. TOML's own words:
    // "defining a key multiple times is invalid" — and a table declared, a table implied, and a table a
    // dotted key made are three different things to have already defined.

    /// Open `[path]`, which subsequent keys are written under.
    mutating func openTable(_ path: [String], line: Int, extent: Range<String.Index>) throws {
        var names = path
        let last = names.removeLast()
        let key = path.joined(separator: ".")
        try makePath(names[...], line: line, origin: .implicit, reporting: key)

        let opened: Void? = try withTable(at: names[...]) { parent in
            switch parent.entries[last] {
            case nil:
                parent.entries[last] = .table(TOMLTable(origin: .header, line: line, extent: extent))
            // `[a.b.c]` before `[a]` is the one redefinition TOML allows: the first only said that `a`
            // exists, and the second is where it is written down.
            case .table(var child) where child.origin == .implicit:
                child.origin = .header
                child.line = line
                child.extent = extent
                parent.entries[last] = .table(child)
            default:
                throw ConfigSyntaxError.duplicateKey(line: line, key: key)
            }
        }
        guard opened != nil else { throw ConfigSyntaxError.duplicateKey(line: line, key: key) }
    }

    /// Open one more element of `[[path]]`.
    mutating func openElement(_ path: [String], line: Int, extent: Range<String.Index>) throws {
        var names = path
        let last = names.removeLast()
        let key = path.joined(separator: ".")
        try makePath(names[...], line: line, origin: .implicit, reporting: key)

        let opened: Void? = try withTable(at: names[...]) { parent in
            let element = TOMLTable(origin: .root, line: line, extent: extent)
            switch parent.entries[last] {
            case nil:
                parent.entries[last] = .array([element])
            case .array(var elements):
                elements.append(element)
                parent.entries[last] = .array(elements)
            default:
                throw ConfigSyntaxError.duplicateKey(line: line, key: key)
            }
        }
        guard opened != nil else { throw ConfigSyntaxError.duplicateKey(line: line, key: key) }
    }

    /// Write `names = value` inside the table `current` names. The two halves are separate because only
    /// `names` is a *dotted key*: `current` is the header already open, and walking into it is not the
    /// thing TOML forbids a dotted key from doing. `key` is the whole name a diagnostic should say.
    mutating func set(_ names: [String], under current: [String], to value: TOMLValue,
                      line: Int, reporting key: String) throws {
        var path = names
        let last = path.removeLast()

        // An inline table written as a whole statement is a table, not a value standing in one — so
        // the schema reaches `a.b` whether the file said `a = { b = 1 }` or `[a]` and `b = 1`.
        let entry: Entry
        if case .table(let contents) = value.payload {
            entry = .table(contents)
        } else {
            entry = .value(value)
        }

        let written: Void? = try withTable(at: current[...]) { table in
            try table.makePath(path[...], line: line, origin: .dotted, reporting: key)
            let placed: Void? = try table.withTable(at: path[...]) { parent in
                guard parent.entries[last] == nil else {
                    throw ConfigSyntaxError.duplicateKey(line: line, key: key)
                }
                parent.entries[last] = entry
            }
            guard placed != nil else { throw ConfigSyntaxError.duplicateKey(line: line, key: key) }
        }
        guard written != nil else { throw ConfigSyntaxError.duplicateKey(line: line, key: key) }
    }

    /// Bring every table on `path` into being, refusing one that is already something else. `origin` is
    /// what a table created here is: a header implies its parents, a dotted key defines them.
    private mutating func makePath(_ path: ArraySlice<String>, line: Int, origin: Origin,
                                   reporting key: String) throws {
        guard let name = path.first else { return }
        switch entries[name] {
        case nil:
            entries[name] = .table(TOMLTable(origin: origin, line: line))
        case .table(let child):
            // A dotted key may not reach into a table the file declared, and nothing may reach into an
            // inline one. A header *may* pass through a table a dotted key made — `apple.color = "red"`
            // then `[fruit.apple.texture]` is legal, and only `[fruit.apple]` itself is not, which is
            // the final segment's business rather than this walk's.
            let clash = (origin == .dotted && child.origin == .header) || child.origin == .inline
            guard !clash else { throw ConfigSyntaxError.duplicateKey(line: line, key: key) }
        // A header path may run on through an array of tables, into its last element. A dotted key may
        // not: it would be redefining the array.
        case .array where origin == .implicit:
            break
        default:
            throw ConfigSyntaxError.duplicateKey(line: line, key: key)
        }
        try withTable(at: path.prefix(1)) { child in
            try child.makePath(path.dropFirst(), line: line, origin: origin, reporting: key)
        }
    }

    /// Grow the run of key lines a new key would be appended to. A key written before the first header
    /// belongs to no header and extends nothing.
    mutating func extend(_ path: [String], over statement: Range<String.Index>) {
        withTable(at: path[...]) { table in
            guard let extent = table.extent else { return }
            table.extent = extent.lowerBound..<statement.upperBound
        }
    }
}
extension TOMLTable {

    /// Read a whole config file. Throws on the first thing it cannot read, naming the line.
    static func parse(_ text: String) throws -> TOMLTable {
        var table = TOMLTable()
        var scanner = TOMLScanner(text)
        // The path keys are written under. A header sets it; through an array of tables it names the
        // last element, which is what the walk resolves rather than anything counted here.
        var current: [String] = []

        while true {
            try scanner.skipBlanks()
            guard !scanner.isAtEnd else { break }
            let line = scanner.line
            let start = scanner.index

            if scanner.peek == "[" {
                let (path, isElement) = try scanner.header()
                let extent = try scanner.endOfStatement(from: start, line: line, after: "a table header")
                if isElement {
                    try table.openElement(path, line: line, extent: extent)
                } else {
                    try table.openTable(path, line: line, extent: extent)
                }
                current = path
                continue
            }

            let (names, keySpan) = try scanner.keyPath()
            scanner.skipSpaces()
            guard scanner.take("=") else {
                throw ConfigSyntaxError.syntax(line: line, message: "expected 'key = value'")
            }
            scanner.skipSpaces()
            guard !scanner.isAtEnd, !scanner.atNewline else {
                throw ConfigSyntaxError.syntax(line: line, message: "missing value after '='")
            }
            let valueStart = scanner.index
            let (payload, quoting) = try scanner.value()
            let valueSpan = valueStart..<scanner.index
            let statement = try scanner.endOfStatement(from: start, line: line, after: "a value")

            let value = TOMLValue(payload: payload, quoting: quoting, line: line,
                                  span: TOMLSpan(value: valueSpan, key: keySpan, statement: statement))
            try table.set(names, under: current, to: value, line: line,
                          reporting: (current + names).joined(separator: "."))
            table.extend(current, over: statement)
        }
        return table
    }
}

//
// The inverse of `value(_:)`, and all of the grammar the writer needs: `ConfigDocument` decides *where*
// a line goes, this decides how it reads. Only the value being written is ever spelled — a line the
// edit doesn't touch keeps whatever the author typed, down to the spaces around its `=`.

extension TOMLTable {
    /// A key segment as the file carries it: bare where the charset allows, quoted where it doesn't.
    /// A quoted key is spelled exactly like a basic string, which is the grammar's own rule. The same
    /// predicate the reader uses, so emira cannot write a key it would refuse to read back.
    static func spell(key segment: String) -> String {
        segment.isEmpty || !segment.unicodeScalars.allSatisfy(TOMLScanner.isBareKey)
            ? TOMLValue.spell(segment, quoting: .basic)
            : segment
    }
}

extension TOMLValue {
    /// This value as a line would carry it — also how it is shown outside the file, since the file's
    /// spelling is the one a user can type back.
    public var spelled: String {
        switch payload {
        case .bool(let flag):      return flag ? "true" : "false"
        case .integer(let value):  return String(value)
        // `String(Double)` always writes a `.` or an `e`, which is what keeps a float a float: `1.0`
        // read back as `1` would be an integer, a different type for the same line.
        case .float(let value):    return String(value)
        case .string(let text):    return Self.spell(text, quoting: quoting)
        case .dateTime(let text):  return text
        case .array(let elements): return "[" + elements.map(\.spelled).joined(separator: ", ") + "]"
        // By name, so the same table spells the same way twice — a table has no order to keep.
        case .table(let contents): return contents.spelled
        }
    }

    /// `8` rather than `8.0` — also how a diagnostic spells an integral bound. Beyond the range where
    /// a `Double` still counts by ones there is no integral spelling to reach for.
    static func spell(_ number: Double) -> String {
        guard number == number.rounded(), abs(number) < 1e15 else { return String(number) }
        return String(Int64(number))
    }

    /// A string in the notation it asked for, falling back to `"…"` where a literal cannot carry the
    /// text: `'…'` has no escape for its own quote, nor for a newline.
    static func spell(_ text: String, quoting: Quoting) -> String {
        // A literal string has no escape for any of these, so text carrying one is spelled `"…"`
        // whatever it asked for.
        let unspellable = text.unicodeScalars.contains { $0 == "'" || isControl($0) }
        if quoting == .literal, !unspellable { return "'" + text + "'" }

        // Per scalar rather than per character: Swift reads `"\r\n"` as one grapheme, and a raw one
        // left in the middle of a line would split the line in two the next time the file is read.
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":     escaped += #"\""#
            case "\\":     escaped += #"\\"#
            case "\u{08}": escaped += #"\b"#
            case "\t":     escaped += #"\t"#
            case "\n":     escaped += #"\n"#
            case "\u{0C}": escaped += #"\f"#
            case "\r":     escaped += #"\r"#
            // Everything else the grammar refuses raw has no shorthand, and `\u` is what it has
            // instead — without this the writer emits a file the reader is right to reject.
            case _ where isControl(scalar):
                escaped += String(format: #"\u%04X"#, scalar.value)
            default:       escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"" + escaped + "\""
    }

    /// What a string may not carry raw. The reader's rule, restated on the writing side because the two
    /// halves have to agree about it: tab is content, every other C0 control and delete is not.
    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        s != "\t" && (s.value <= 0x1F || s.value == 0x7F)
    }
}

// Values to be written
//
// A value handed to `ConfigDocument.set` has no line and no span: it hasn't been written down yet.
// These are the only way to make one from outside the package, which keeps `Payload` — the grammar's
// own value model, and no business of a settings window — out of the API.

extension TOMLValue {
    /// Line 0 is the nowhere a value that has never been written comes from. Nothing reads it: a
    /// diagnostic can only ever name a value that was parsed.
    private init(writing payload: Payload, quoting: Quoting = .basic) {
        self.init(payload: payload, quoting: quoting, line: 0)
    }

    /// `true` or `false`.
    public static func bool(_ flag: Bool) -> TOMLValue { TOMLValue(writing: .bool(flag)) }

    /// A number. An integral one is written as a TOML *integer* — `column-gap = 8`, not `8.0` — which
    /// is both the shorter spelling and the truer type for a count. The schema reads either.
    public static func number(_ number: Double) -> TOMLValue {
        guard number == number.rounded(), let integer = Int64(exactly: number) else {
            return TOMLValue(writing: .float(number))
        }
        return TOMLValue(writing: .integer(integer))
    }

    /// A `"…"` string.
    public static func string(_ text: String) -> TOMLValue { TOMLValue(writing: .string(text)) }

    /// A `'…'` string — no escapes, which is how a regex is written and read. Text carrying a `'` is
    /// written as a `"…"` string instead, since a literal string cannot hold one at all.
    public static func literalString(_ text: String) -> TOMLValue {
        TOMLValue(writing: .string(text), quoting: .literal)
    }

    /// A single-line array.
    public static func array(_ elements: [TOMLValue]) -> TOMLValue {
        TOMLValue(writing: .array(elements))
    }
}


//
// The grammar itself: a cursor over the text's Unicode scalars, and one method per production. It
// counts its own lines, because nothing else can — a `"""` string and a multi-line array both carry
// line breaks that belong to the value rather than ending the statement.

/// A cursor over the config text. Its `index` is a `String.Index`, so every range it hands back is one
/// `ConfigDocument` can splice against the original string.
private struct TOMLScanner {
    private let scalars: String.UnicodeScalarView
    private(set) var index: String.Index
    private(set) var line = 1

    init(_ text: String) {
        scalars = text.unicodeScalars
        index = scalars.startIndex
        // A byte-order mark is not in any production. Editors write one; the spec has no opinion, and
        // refusing the first key of an otherwise valid file is the one reading nobody wants.
        if scalars.first == "\u{FEFF}" { index = scalars.index(after: index) }
    }

    var isAtEnd: Bool { index >= scalars.endIndex }
    var peek: Unicode.Scalar? { isAtEnd ? nil : scalars[index] }

    /// The scalar `offset` positions ahead, for the two-scalar lookaheads (`[[`, `"""`, `\` + newline).
    func peek(_ offset: Int) -> Unicode.Scalar? {
        guard let ahead = scalars.index(index, offsetBy: offset, limitedBy: scalars.endIndex),
              ahead < scalars.endIndex else { return nil }
        return scalars[ahead]
    }

    mutating func advance() {
        guard !isAtEnd else { return }
        index = scalars.index(after: index)
    }

    /// Consume `scalar` if it is next.
    @discardableResult
    mutating func take(_ scalar: Unicode.Scalar) -> Bool {
        guard peek == scalar else { return false }
        advance()
        return true
    }

    /// Consume a run of the same scalar — `"""`, `'''`, `[[`, `]]`. All or nothing.
    @discardableResult
    mutating func take(_ scalar: Unicode.Scalar, count: Int) -> Bool {
        for offset in 0..<count where peek(offset) != scalar { return false }
        for _ in 0..<count { advance() }
        return true
    }

    // Whitespace, newlines, comments
    //
    // `ws = %x20 / %x09` and `newline = %x0A / %x0D.0A`, to the letter. Everything else the standard
    // library would call whitespace is ordinary content.

    /// Space and tab only.
    mutating func skipSpaces() {
        while peek == " " || peek == "\t" { advance() }
    }

    var atNewline: Bool { peek == "\n" || (peek == "\r" && peek(1) == "\n") }

    /// Consume one LF or CRLF, counting the line. A bare CR is not a line ending and is left alone —
    /// it is a control character, and whatever it sits in will refuse it by name.
    mutating func takeNewline() -> Bool {
        guard atNewline else { return false }
        if peek == "\r" { advance() }
        advance()
        line += 1
        return true
    }

    /// Consume a `#` comment up to (not including) the line ending.
    mutating func skipComment() throws {
        guard take("#") else { return }
        while let scalar = peek, !atNewline {
            guard !TOMLScanner.isControl(scalar) else {
                throw ConfigSyntaxError.syntax(
                    line: line, message: "a comment cannot contain \(TOMLScanner.name(of: scalar))")
            }
            advance()
        }
    }

    /// Everything between one statement and the next: spaces, comments and line endings.
    mutating func skipBlanks() throws {
        while true {
            skipSpaces()
            if peek == "#" { try skipComment() }
            if !takeNewline() { return }
        }
    }

    /// The tail of a statement — trailing spaces, an optional comment, then a line ending or the end of
    /// the file. Returns the statement's extent, which stops at the comment and never at the newline.
    mutating func endOfStatement(from start: String.Index, line: Int,
                                 after what: String) throws -> Range<String.Index> {
        skipSpaces()
        var stop = index
        if peek == "#" {
            try skipComment()
            stop = index
        }
        guard isAtEnd || atNewline else {
            throw ConfigSyntaxError.syntax(line: line, message: "unexpected text after \(what)")
        }
        _ = takeNewline()
        return start..<stop
    }

    // Keys

    /// `[layout]` / `[animation.scroll]` / `[[window-rules]]` → the path it sets subsequent keys under,
    /// and whether it opens one *element* of an array of tables rather than the table itself.
    mutating func header() throws -> (path: [String], isElement: Bool) {
        let line = self.line
        advance()                                   // the opening '['
        let isElement = take("[")
        let closer = isElement ? "]]" : "]"
        let (path, _) = try keyPath()
        skipSpaces()
        guard take("]"), !isElement || take("]") else {
            throw ConfigSyntaxError.syntax(
                line: line, message: "unterminated table header — expected '\(closer)'")
        }
        return (path, isElement)
    }

    /// A dot-separated key expression — headers and key names are spelled the same way. Each segment is
    /// bare (`column-gap`), `"quoted"`, or `'literal'`. `last` is where the final segment was written,
    /// quoting included: the one part of the expression a rename replaces.
    mutating func keyPath() throws -> (segments: [String], last: Range<String.Index>) {
        var segments: [String] = []
        var last = index..<index
        while true {
            skipSpaces()
            let start = index
            switch peek {
            case "\"":
                segments.append(try basicString())
            case "'":
                segments.append(try literalString())
            default:
                var bare = ""
                while let scalar = peek, TOMLScanner.isBareKey(scalar) {
                    bare.unicodeScalars.append(scalar)
                    advance()
                }
                // A scalar that is neither part of a key nor anything that may follow one names the
                // mistake — `café`, or a hyphen pasted from a web page — far better than the `=` that
                // will be missing further along the line.
                if let scalar = peek, !atNewline, !TOMLScanner.followsKey(scalar) {
                    while let scalar = peek, !atNewline, !TOMLScanner.followsKey(scalar) {
                        bare.unicodeScalars.append(scalar)
                        advance()
                    }
                    throw ConfigSyntaxError.syntax(line: line, message: "invalid key '\(bare)'")
                }
                guard !bare.isEmpty else {
                    throw ConfigSyntaxError.syntax(line: line, message: "empty key")
                }
                segments.append(bare)
            }
            last = start..<index
            skipSpaces()
            guard take(".") else { return (segments, last) }
        }
    }

    // Values

    /// The right-hand side of a `key = value`, or one element of an array.
    mutating func value() throws -> (TOMLValue.Payload, TOMLValue.Quoting) {
        switch peek {
        case "\"":
            if peek(1) == "\"" && peek(2) == "\"" { return (.string(try multilineBasicString()), .basic) }
            return (.string(try basicString()), .basic)
        case "'":
            if peek(1) == "'" && peek(2) == "'" {
                return (.string(try multilineLiteralString()), .literal)
            }
            return (.string(try literalString()), .literal)
        case "[":
            return (try array(), .basic)
        case "{":
            return (try inlineTable(), .basic)
        default:
            return (try bareValue(), .basic)
        }
    }

    /// `true`, `false`, or a number — everything with no punctuation to recognise it by, read as the run
    /// of scalars up to whatever ends a value and judged afterwards.
    private mutating func bareValue() throws -> TOMLValue.Payload {
        let line = self.line
        var word = ""
        while let scalar = peek, !TOMLScanner.endsValue(scalar), !atNewline {
            word.unicodeScalars.append(scalar)
            advance()
        }
        // A local date-time may be spelled with a space where the `T` goes, and a space is otherwise
        // the end of a value — so a date takes the rest with it, and only a date may.
        if peek == " ", TOMLScanner.isDate(word), let next = peek(1), ("0"..."9").contains(next) {
            advance()
            word += " "
            while let scalar = peek, !TOMLScanner.endsValue(scalar), !atNewline {
                word.unicodeScalars.append(scalar)
                advance()
            }
        }
        if word == "true" { return .bool(true) }
        if word == "false" { return .bool(false) }
        if let dateTime = try TOMLScanner.dateTime(word, line: line) { return dateTime }
        return try TOMLScanner.number(word, line: line)
    }

    /// `{ a = 1, b = 2 }`. The mirror image of an array: an inline table must open and close on one
    /// line, and a trailing comma is a mistake rather than a tolerated habit.
    private mutating func inlineTable() throws -> TOMLValue.Payload {
        let opened = line
        advance()                                   // the opening '{'
        // Built as a table, so `{ a = { }, a.b = 1 }` is refused by the same rule that refuses `[a]`
        // twice, rather than by a second reading of it written for this production.
        var contents = TOMLTable(origin: .inline, line: opened)
        skipSpaces()
        if take("}") { return .table(contents) }

        while true {
            skipSpaces()
            guard !isAtEnd, !atNewline else {
                throw ConfigSyntaxError.syntax(
                    line: opened, message: "unterminated inline table — it must open and close on one line")
            }
            let line = self.line
            let start = index
            let (names, keySpan) = try keyPath()
            skipSpaces()
            guard take("=") else {
                throw ConfigSyntaxError.syntax(line: line, message: "expected 'key = value'")
            }
            skipSpaces()
            let valueStart = index
            let (payload, quoting) = try value()
            let span = TOMLSpan(value: valueStart..<index, key: keySpan, statement: start..<index)
            let value = TOMLValue(payload: payload, quoting: quoting, line: line, span: span)
            try contents.set(names, under: [], to: value, line: line,
                             reporting: names.joined(separator: "."))
            skipSpaces()
            if take(",") { continue }
            guard take("}") else {
                throw ConfigSyntaxError.syntax(
                    line: line, message: "expected ',' or '}' in an inline table")
            }
            return .table(contents)
        }
    }

    /// An array. Line endings and comments are legal anywhere inside one, so this is the production
    /// that a line-at-a-time reader cannot express at all.
    private mutating func array() throws -> TOMLValue.Payload {
        let opened = line
        advance()                                   // the opening '['
        var elements: [TOMLValue] = []
        while true {
            try skipBlanks()
            guard !isAtEnd else {
                throw ConfigSyntaxError.syntax(line: opened, message: "unterminated array")
            }
            if take("]") { return .array(elements) }

            let line = self.line
            let start = index
            let (payload, quoting) = try value()
            let span = TOMLSpan(value: start..<index, key: start..<start, statement: start..<index)
            elements.append(TOMLValue(payload: payload, quoting: quoting, line: line, span: span))

            try skipBlanks()
            if take(",") { continue }
            guard peek == "]" else {
                throw ConfigSyntaxError.syntax(line: line, message: "expected ',' or ']' in array")
            }
        }
    }

    // Strings

    /// `"…"`. Escapes are TOML's eight plus the two Unicode forms; everything else is reserved, and a
    /// reserved escape is a syntax error rather than the character it precedes.
    private mutating func basicString() throws -> String {
        let opened = line
        advance()                                   // the opening quote
        var result = ""
        while let scalar = peek {
            if atNewline { break }
            if scalar == "\"" { advance(); return result }
            if scalar == "\\" {
                advance()
                result.unicodeScalars.append(contentsOf: try escape())
                continue
            }
            guard !TOMLScanner.isControl(scalar) else {
                throw ConfigSyntaxError.syntax(
                    line: line, message: "a string cannot contain \(TOMLScanner.name(of: scalar))")
            }
            result.unicodeScalars.append(scalar)
            advance()
        }
        throw ConfigSyntaxError.syntax(line: opened, message: "unterminated string")
    }

    /// `'…'` — **no escapes at all**, which is the entire point of the notation and what lets a regex be
    /// written the way it is written everywhere else. It therefore cannot contain a `'`.
    private mutating func literalString() throws -> String {
        let opened = line
        advance()                                   // the opening quote
        var result = ""
        while let scalar = peek {
            if atNewline { break }
            if scalar == "'" { advance(); return result }
            guard !TOMLScanner.isControl(scalar) else {
                throw ConfigSyntaxError.syntax(
                    line: line, message: "a string cannot contain \(TOMLScanner.name(of: scalar))")
            }
            result.unicodeScalars.append(scalar)
            advance()
        }
        throw ConfigSyntaxError.syntax(line: opened, message: "unterminated string")
    }

    /// `"""…"""`. A line ending straight after the opening delimiter is dropped; a `\` that ends a line
    /// eats that line ending and the indentation after it.
    private mutating func multilineBasicString() throws -> String {
        let opened = line
        take("\"", count: 3)
        _ = takeNewline()
        var result = ""
        while peek != nil {
            if peek == "\"" {
                let run = quoteRun("\"")
                result += run.text
                if run.closed { return result }
                continue
            }
            if takeNewline() { result += "\n"; continue }
            let scalar = scalars[index]
            if scalar == "\\" {
                if try skipLineEndingBackslash() { continue }
                advance()
                result.unicodeScalars.append(contentsOf: try escape())
                continue
            }
            guard !TOMLScanner.isControl(scalar) else {
                throw ConfigSyntaxError.syntax(
                    line: line, message: "a string cannot contain \(TOMLScanner.name(of: scalar))")
            }
            result.unicodeScalars.append(scalar)
            advance()
        }
        throw ConfigSyntaxError.syntax(line: opened, message: "unterminated string")
    }

    /// `'''…'''`, with the same leading-newline rule and no escapes.
    private mutating func multilineLiteralString() throws -> String {
        let opened = line
        take("'", count: 3)
        _ = takeNewline()
        var result = ""
        while peek != nil {
            if peek == "'" {
                let run = quoteRun("'")
                result += run.text
                if run.closed { return result }
                continue
            }
            if takeNewline() { result += "\n"; continue }
            let scalar = scalars[index]
            guard !TOMLScanner.isControl(scalar) else {
                throw ConfigSyntaxError.syntax(
                    line: line, message: "a string cannot contain \(TOMLScanner.name(of: scalar))")
            }
            result.unicodeScalars.append(scalar)
            advance()
        }
        throw ConfigSyntaxError.syntax(line: opened, message: "unterminated string")
    }

    /// A run of the delimiter's own quote inside a multi-line string. Fewer than three is content;
    /// three closes, and the up-to-two before those belong to the body — `""""` is one quote and a
    /// delimiter, which is why the run is measured rather than matched.
    private mutating func quoteRun(_ quote: Unicode.Scalar) -> (closed: Bool, text: String) {
        var run = 0
        while peek(run) == quote { run += 1 }
        let body = run < 3 ? run : min(run - 3, 2)
        for _ in 0..<(run < 3 ? run : body + 3) { advance() }
        return (run >= 3, String(repeating: String(quote), count: body))
    }

    /// A `\` that ends a line: it and every space, tab and line ending after it are dropped. `false`
    /// when the backslash begins an ordinary escape instead.
    private mutating func skipLineEndingBackslash() throws -> Bool {
        var lookahead = 1
        while peek(lookahead) == " " || peek(lookahead) == "\t" { lookahead += 1 }
        guard peek(lookahead) == "\n" || (peek(lookahead) == "\r" && peek(lookahead + 1) == "\n")
        else { return false }
        advance()
        while true {
            skipSpaces()
            if takeNewline() { continue }
            return true
        }
    }

    /// What follows a `\` in a basic string. The cursor is past the backslash.
    private mutating func escape() throws -> [Unicode.Scalar] {
        guard let scalar = peek else {
            throw ConfigSyntaxError.syntax(line: line, message: "unterminated string")
        }
        advance()
        switch scalar {
        case "\"": return ["\""]
        case "\\": return ["\\"]
        case "b":  return ["\u{08}"]
        case "t":  return ["\t"]
        case "n":  return ["\n"]
        case "f":  return ["\u{0C}"]
        case "r":  return ["\r"]
        case "u":  return [try unicodeEscape(digits: 4)]
        case "U":  return [try unicodeEscape(digits: 8)]
        default:
            throw ConfigSyntaxError.syntax(line: line, message: "unknown escape '\\\(scalar)'")
        }
    }

    /// `\uXXXX` / `\UXXXXXXXX`. The value must be a Unicode scalar — a surrogate half is a number in
    /// range that no character corresponds to, and `Unicode.Scalar(_:)` is what knows the difference.
    private mutating func unicodeEscape(digits: Int) throws -> Unicode.Scalar {
        var hex = ""
        for _ in 0..<digits {
            guard let scalar = peek, TOMLScanner.isHexDigit(scalar) else {
                throw ConfigSyntaxError.syntax(
                    line: line, message: "an escape needs \(digits) hexadecimal digits")
            }
            hex.unicodeScalars.append(scalar)
            advance()
        }
        guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw ConfigSyntaxError.syntax(
                line: line, message: "'\\u\(hex)' is not a Unicode character")
        }
        return scalar
    }

    // Character classes
    //
    // Spelled as scalar ranges because that is how the ABNF spells them, and because every Swift
    // property that looks like the right question — `isLetter`, `isNumber`, `isWhitespace` — answers a
    // Unicode-wide one instead.

    static func isBareKey(_ s: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(s) || ("a"..."z").contains(s) || ("0"..."9").contains(s)
            || s == "-" || s == "_"
    }

    private static func isHexDigit(_ s: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(s) || ("a"..."f").contains(s) || ("A"..."F").contains(s)
    }

    /// What a string or a comment refuses raw: the C0 controls other than tab, and delete. A line ending
    /// is among them — a multi-line string admits one as a line break, never as content.
    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        s.value <= 0x08 || (0x0A...0x1F).contains(s.value) || s.value == 0x7F
    }

    /// What ends a bare value: array and inline-table punctuation, a comment, or whitespace.
    private static func endsValue(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\t" || s == "," || s == "]" || s == "}" || s == "#" || s == "\r"
    }

    /// What may stand where a key has just ended: the rest of a dotted path, the `=` or `]` it leads to,
    /// or the whitespace and comment before either.
    private static func followsKey(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\t" || s == "." || s == "=" || s == "]" || s == "#"
    }

    private static func name(of s: Unicode.Scalar) -> String {
        String(format: "the control character U+%04X", s.value)
    }

    // Numbers
    //
    // Validated before `Double(_:)` sees the text: the standard library reads `0x1p3`, `007`, `.5` and
    // `5.`, and TOML admits none of them.

    /// A decimal integer or float. Hexadecimal, octal and binary are refused by name rather than read
    /// into a `Double` that cannot hold every one of them.
    static func number(_ text: String, line: Int) throws -> TOMLValue.Payload {
        func refuse() -> ConfigSyntaxError {
            .syntax(line: line, message: "cannot read '\(text)' as a value")
        }
        var rest = Substring(text)
        var negative = false
        var signed = false
        if rest.first == "+" || rest.first == "-" {
            negative = rest.first == "-"
            signed = true
            rest = rest.dropFirst()
        }
        if rest == "inf" { return .float(negative ? -.infinity : .infinity) }
        if rest == "nan" { return .float(.nan) }

        // A radix integer takes no sign at all — not even a `+` — and no fraction, so it is the whole
        // value or a mistake.
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where rest.hasPrefix(prefix) {
            var body = rest.dropFirst(2)
            guard !signed, let digits = TOMLScanner.digits(&body, radix: radix), body.isEmpty,
                  let value = Int64(digits, radix: radix)
            else { throw refuse() }
            return .integer(value)
        }

        guard let whole = TOMLScanner.digits(&rest) else { throw refuse() }
        // `0` alone is the only integer part that may begin with one.
        guard whole == "0" || !whole.hasPrefix("0") else { throw refuse() }
        var literal = (negative ? "-" : "") + whole
        var isFloat = false

        if rest.first == "." {
            rest = rest.dropFirst()
            guard let fraction = TOMLScanner.digits(&rest) else { throw refuse() }
            literal += "." + fraction
            isFloat = true
        }
        if rest.first == "e" || rest.first == "E" {
            rest = rest.dropFirst()
            var exponent = ""
            if rest.first == "+" || rest.first == "-" {
                exponent = rest.first == "-" ? "-" : ""
                rest = rest.dropFirst()
            }
            // The exponent is the one integer TOML lets begin with a zero.
            guard let value = TOMLScanner.digits(&rest) else { throw refuse() }
            literal += "e" + exponent + value
            isFloat = true
        }
        guard rest.isEmpty else { throw refuse() }

        if isFloat {
            guard let value = Double(literal), value.isFinite else { throw refuse() }
            return .float(value)
        }
        // An integer outside `Int64` is a number TOML defines and no type here holds. Saying so beats
        // rounding it into a `Double` and reading it back as something the file does not say.
        guard let value = Int64(literal) else {
            throw ConfigSyntaxError.syntax(
                line: line, message: "'\(text)' is too large for a 64-bit integer")
        }
        return .integer(value)
    }

    // Dates and times
    //
    // Validated to the shape and the calendar, then kept as the text they were written as. Nothing emira
    // has is a date, so no reader ever asks for the components — only that a file saying one is a file
    // emira opens, and that a file saying `1979-02-30` is not.

    /// Whether `text` opens with the *shape* `YYYY-MM-DD` — digits and hyphens in the right places, the
    /// calendar not yet consulted. Shape is what decides that a value is a date at all, and so what
    /// makes `1979-02-30` a bad date rather than an unreadable number.
    static func isDate(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars.prefix(10))
        guard scalars.count == 10 else { return false }
        return scalars.enumerated().allSatisfy { index, scalar in
            index == 4 || index == 7 ? scalar == "-" : ("0"..."9").contains(scalar)
        }
    }

    /// One of TOML's four date-time types, or `nil` when the text is not shaped like any of them and so
    /// belongs to the number reader instead.
    static func dateTime(_ text: String, line: Int) throws -> TOMLValue.Payload? {
        func refuse() -> ConfigSyntaxError {
            .syntax(line: line, message: "'\(text)' is not a valid date or time")
        }
        // A local time is the one form with no date in front of it.
        if text.count >= 8, Array(text)[2] == ":" {
            guard time(text) else { throw refuse() }
            return .dateTime(text)
        }
        guard isDate(text) else { return nil }
        guard date(String(text.prefix(10))) else { throw refuse() }
        var rest = Substring(text.dropFirst(10))
        if rest.isEmpty { return .dateTime(text) }               // local date

        guard rest.first == "T" || rest.first == "t" || rest.first == " " else { throw refuse() }
        rest = rest.dropFirst()
        // An offset closes the value: `Z`, or `±HH:MM` after the seconds.
        var offset = Substring()
        if let last = rest.last, last == "Z" || last == "z" {
            rest = rest.dropLast()
        } else if let sign = rest.dropFirst(8).firstIndex(where: { $0 == "+" || $0 == "-" }) {
            offset = rest[sign...]
            rest = rest[..<sign]
        }
        guard time(String(rest)), offset.isEmpty || zone(String(offset)) else { throw refuse() }
        return .dateTime(text)
    }

    /// A `YYYY-MM-DD` of the right shape, checked against the calendar — February has 28 days, or 29 in
    /// a leap year.
    private static func date(_ text: String) -> Bool {
        let parts = text.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
              let day = Int(parts[2]), (1...12).contains(month)
        else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...lengths[month - 1]).contains(day)
    }

    /// `HH:MM:SS` with an optional fractional second. Leap seconds are why 60 is a legal value.
    private static func time(_ text: String) -> Bool {
        let body = text.split(separator: ".", omittingEmptySubsequences: false)
        guard body.count <= 2 else { return false }
        if body.count == 2, body[1].isEmpty || !body[1].allSatisfy({ $0.isASCII && $0.isNumber }) {
            return false
        }
        let parts = body[0].split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ $0.count == 2 }),
              body[0].allSatisfy({ $0 == ":" || $0.isASCII && $0.isNumber }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), let second = Int(parts[2])
        else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute) && (0...60).contains(second)
    }

    /// `±HH:MM`.
    private static func zone(_ text: String) -> Bool {
        guard text.count == 6, text.first == "+" || text.first == "-" else { return false }
        let parts = text.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }),
              let hour = Int(parts[0]), let minute = Int(parts[1])
        else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute)
    }

    /// A run of digits with `_` allowed between them — never leading, never trailing, never doubled.
    /// Returns them with the underscores taken out, which is what `Int64` and `Double` can read.
    private static func digits(_ rest: inout Substring, radix: Int = 10) -> String? {
        var out = ""
        var afterDigit = false
        while let character = rest.first {
            if let value = character.hexDigitValue, value < radix {
                out.append(character)
                afterDigit = true
            } else if character == "_", afterDigit {
                afterDigit = false
            } else {
                break
            }
            rest = rest.dropFirst()
        }
        return afterDigit ? out : nil
    }
}
