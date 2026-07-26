import Foundation

// The reader half of the config file — text in, keyed values out. It is a **deliberately partial
// TOML**: the subset emira's own config is written in, and nothing else.
//
// **Why hand-rolled rather than a dependency.** The package has no dependencies and this is not the
// place to acquire the first one. The grammar we actually need is "comments, `[table]` headers, and
// `key = value` over five scalar kinds" — a few hundred lines with error messages we control — while a
// conforming TOML implementation carries dates, times, multi-line and literal strings, arrays of
// tables, dotted-key merging, and integer/float distinctions we have no use for. This is the same
// judgement `CommandSyntax.swift` made about `swift-argument-parser` (IMPLEMENTATION.md §11,
// 2026-07-24): the surface is small, it lives in the core where it can be tested exhaustively, and
// vendoring a parser into `emira.app` for it would be more machinery than the thing it parses.
//
// **We keep TOML's *spelling* on purpose.** Editors highlight it, and AeroSpace users already write
// it — the value of the format is familiarity, which a subset keeps intact. What a subset must never
// do is *silently* accept something it doesn't implement, so anything outside the grammar below is a
// diagnostic naming the line, never a shrug:
//
//   · comments (`# …`), whole-line or trailing
//   · `[table]` and `[table.sub]` headers; keys before any header sit at the top level
//   · `key = value`, with bare (`column-gap`) or quoted (`"cmd-alt-h"`) keys, dot-separated
//   · values: `true`/`false`, a number, a `"string"`, or a single-line array of those
//
// Not implemented, and each says so when met: multi-line arrays, inline tables (`{ … }`), arrays of
// tables (`[[…]]`), literal/multi-line strings, dates.
//
// **Everything carries its line number.** A config file is written by a human in an editor, so a
// diagnostic that can't be jumped to is half a diagnostic. Values remember where they were read, and
// the schema layer (`ConfigSyntax.swift`) quotes that line back when a value is the wrong kind or a
// key isn't one we know.

/// One value read out of the config text, plus the line it was written on.
struct TOMLValue: Equatable {
    /// The four value kinds the subset admits. Numbers are `Double` throughout — the schema decides
    /// whether a given key wants an integral one, because `column-gap = 8` and `column-gap = 8.0`
    /// mean the same thing to a layout engine that works in points.
    enum Payload: Equatable {
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([TOMLValue])
    }

    let payload: Payload
    let line: Int

    /// How this value's kind is named in a diagnostic ("expected a number, found a string").
    var kindName: String {
        switch payload {
        case .bool:   return "a boolean"
        case .number: return "a number"
        case .string: return "a string"
        case .array:  return "an array"
        }
    }
}

/// A parsed document, flattened to dotted paths: `[layout] column-gap = 8` reads back as
/// `"layout.column-gap"`.
///
/// Flat rather than a tree because of what the schema layer does with it: it *takes* the keys it
/// knows, one at a time, and then complains about whatever is left (`ConfigSyntax.swift`). A tree
/// would make both halves of that walk recursive for no gain — there is exactly one schema, and it is
/// two levels deep.
struct TOMLTable: Equatable {
    /// Every `key = value` in the document, by dotted path.
    private(set) var values: [String: TOMLValue] = [:]
    /// Every `[table]` header that was *declared*, by dotted path → line. Kept separately from the
    /// values because an empty table is still a typo worth catching: `[layuot]` with nothing under it
    /// contributes no keys at all, so leftover-key detection alone would let it pass in silence.
    private(set) var tables: [String: Int] = [:]

    // MARK: - Consumption
    //
    // The schema layer reads this table by *taking* the keys it knows and then asking what is left —
    // so "unknown key" needs no second list of valid names to drift out of step with the reader.

    /// Remove and return the value at a dotted path, or `nil` if the file didn't set it.
    mutating func take(_ path: String) -> TOMLValue? {
        values.removeValue(forKey: path)
    }

    /// Mark a `[table]` header as understood, so it isn't reported as unknown. Taking a key does *not*
    /// imply this: a header may legitimately be declared with nothing under it.
    mutating func acceptTable(_ path: String) {
        tables.removeValue(forKey: path)
    }

    /// Remove and return every key under a table, keyed by the part *after* the prefix, earliest line
    /// first.
    ///
    /// **The one open table in the schema**, and it needs its own reader for exactly that reason:
    /// everywhere else the schema knows the key names in advance and `take`s them one by one, but a
    /// `[keys]` binding's name is a key combination the user invented, so it can only be read by
    /// asking for the whole table. Line order is preserved because it is meaningful twice: a
    /// diagnostic should point at the first mistake, and the daemon registers and reports bindings in
    /// the order the file lists them.
    mutating func takeAll(under prefix: String) -> [(key: String, value: TOMLValue)] {
        let dotted = prefix + "."
        let matching = values.filter { $0.key.hasPrefix(dotted) }
        for key in matching.keys { values.removeValue(forKey: key) }
        return matching
            .map { (key: String($0.key.dropFirst(dotted.count)), value: $0.value) }
            .sorted { ($0.value.line, $0.key) < ($1.value.line, $1.key) }
    }

    /// Everything the schema never took, earliest line first — keys, then any table header that was
    /// declared and never accepted. Sorted by line so the diagnostic points at the *first* mistake,
    /// which is the one a human wants to fix.
    var leftovers: [(key: String, line: Int)] {
        let keys = values.map { (key: $0.key, line: $0.value.line) }
        let headers = tables.map { (key: $0.key, line: $0.value) }
        return (keys + headers).sorted { ($0.line, $0.key) < ($1.line, $1.key) }
    }

    // MARK: - Parsing

    /// Read a whole config file. Throws on the first thing it cannot read, naming the line.
    static func parse(_ text: String) throws -> TOMLTable {
        var table = TOMLTable()
        var current: [String] = []

        // Split on *newlines*, not on `"\n"`. Swift reads `"\r\n"` as a single grapheme cluster, so a
        // file written on Windows (or pasted through it) splits on `"\n"` into **one** line — every
        // key on it, and a diagnostic pointing at line 1 forever. `isNewline` covers CRLF, LF, CR and
        // the Unicode separators alike.
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = index + 1
            let trimmed = rawLine.trimmed

            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("[") {
                current = try header(trimmed, line: line)
                table.tables[current.joined(separator: ".")] = line
                continue
            }

            guard let equals = indexOfUnquoted("=", in: trimmed) else {
                throw ConfigSyntaxError.syntax(line: line, message: "expected 'key = value'")
            }
            let path = current + (try keyPath(trimmed[..<equals], line: line))
            let dotted = path.joined(separator: ".")
            guard table.values[dotted] == nil else {
                throw ConfigSyntaxError.duplicateKey(line: line, key: dotted)
            }
            table.values[dotted] = try value(trimmed[trimmed.index(after: equals)...], line: line)
        }
        return table
    }

    /// `[layout]` / `[animation.scroll]` → the path it sets subsequent keys under.
    private static func header(_ text: Substring, line: Int) throws -> [String] {
        if text.hasPrefix("[[") {
            throw ConfigSyntaxError.syntax(line: line, message: "arrays of tables are not supported")
        }
        guard let close = indexOfUnquoted("]", in: text) else {
            throw ConfigSyntaxError.syntax(line: line, message: "unterminated table header — expected ']'")
        }
        let after = text[text.index(after: close)...].trimmed
        guard after.isEmpty || after.hasPrefix("#") else {
            throw ConfigSyntaxError.syntax(line: line, message: "unexpected text after ']'")
        }
        let inner = text[text.index(after: text.startIndex)..<close]
        let path = try keyPath(inner, line: line)
        guard !path.isEmpty else {
            throw ConfigSyntaxError.syntax(line: line, message: "empty table header")
        }
        return path
    }

    /// A dot-separated key expression — used for both headers and key names, since TOML spells them
    /// the same way. Each segment is bare (`column-gap`) or quoted (`"cmd-alt-h"`); quoting exists so
    /// a key can contain characters the bare charset refuses, which is what M5's keybinding table
    /// (`"cmd-alt-h" = "focus left"`) is going to need.
    private static func keyPath(_ text: Substring, line: Int) throws -> [String] {
        var segments: [String] = []
        var rest = text.trimmed
        while true {
            guard let first = rest.first else {
                throw ConfigSyntaxError.syntax(line: line, message: "empty key")
            }
            if first == "\"" {
                let (string, remainder) = try quotedString(rest, line: line)
                segments.append(string)
                rest = remainder.trimmed
            } else {
                let end = rest.firstIndex(of: ".") ?? rest.endIndex
                let bare = rest[..<end].trimmed
                guard !bare.isEmpty, bare.allSatisfy(isBareKeyCharacter) else {
                    throw ConfigSyntaxError.syntax(line: line, message: "invalid key '\(bare)'")
                }
                segments.append(String(bare))
                rest = rest[end...]
            }
            guard let next = rest.first else { return segments }
            guard next == "." else {
                throw ConfigSyntaxError.syntax(line: line, message: "unexpected text after key")
            }
            rest = rest.dropFirst().trimmed
        }
    }

    private static func isBareKeyCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-" || c == "_"
    }

    // MARK: - Values

    /// The right-hand side of a `key = value`, with any trailing comment removed.
    private static func value(_ text: Substring, line: Int) throws -> TOMLValue {
        let body = stripComment(text).trimmed
        guard !body.isEmpty else {
            throw ConfigSyntaxError.syntax(line: line, message: "missing value after '='")
        }
        if body.hasPrefix("[") { return try array(body, line: line) }
        return try scalar(body, line: line)
    }

    private static func array(_ text: Substring, line: Int) throws -> TOMLValue {
        guard text.hasSuffix("]") else {
            throw ConfigSyntaxError.syntax(
                line: line, message: "unterminated array — it must open and close on one line")
        }
        let inner = text.dropFirst().dropLast().trimmed
        guard !inner.isEmpty else { return TOMLValue(payload: .array([]), line: line) }
        var elements: [TOMLValue] = []
        for piece in splitUnquoted(inner, on: ",") {
            let element = piece.trimmed
            if element.isEmpty { continue }         // tolerate a trailing comma, as TOML does
            if element.hasPrefix("[") {
                throw ConfigSyntaxError.syntax(line: line, message: "nested arrays are not supported")
            }
            elements.append(try scalar(element, line: line))
        }
        return TOMLValue(payload: .array(elements), line: line)
    }

    private static func scalar(_ text: Substring, line: Int) throws -> TOMLValue {
        if text.hasPrefix("\"") {
            let (string, remainder) = try quotedString(text, line: line)
            guard remainder.trimmed.isEmpty else {
                throw ConfigSyntaxError.syntax(line: line, message: "unexpected text after value")
            }
            return TOMLValue(payload: .string(string), line: line)
        }
        if text == "true"  { return TOMLValue(payload: .bool(true), line: line) }
        if text == "false" { return TOMLValue(payload: .bool(false), line: line) }
        if text.hasPrefix("{") {
            throw ConfigSyntaxError.syntax(line: line, message: "inline tables are not supported")
        }
        if text.hasPrefix("'") {
            throw ConfigSyntaxError.syntax(line: line,
                                           message: "literal strings are not supported — use \"quotes\"")
        }
        // Number. `Double(_:)` is happy to read "inf", "nan" and hex floats ("0x1p3"), none of which a
        // config file should be able to say — so the charset is checked first and the parse second.
        let numeric = text.allSatisfy { $0.isNumber || "+-.eE".contains($0) }
        guard numeric, let number = Double(text), number.isFinite else {
            throw ConfigSyntaxError.syntax(line: line, message: "cannot read '\(text)' as a value")
        }
        return TOMLValue(payload: .number(number), line: line)
    }

    /// Read a `"…"` string starting at `text`'s first character; returns it and whatever follows.
    /// Escapes: `\"`, `\\`, `\n`, `\t`, `\r`. Anything else escaped is an error rather than a
    /// silently-swallowed backslash.
    private static func quotedString(_ text: Substring, line: Int) throws -> (String, Substring) {
        var result = ""
        var index = text.index(after: text.startIndex)      // past the opening quote
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { break }
                switch text[next] {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n":  result.append("\n")
                case "t":  result.append("\t")
                case "r":  result.append("\r")
                default:
                    throw ConfigSyntaxError.syntax(line: line,
                                                   message: "unknown escape '\\\(text[next])'")
                }
                index = text.index(after: next)
                continue
            }
            if character == "\"" {
                return (result, text[text.index(after: index)...])
            }
            result.append(character)
            index = text.index(after: index)
        }
        throw ConfigSyntaxError.syntax(line: line, message: "unterminated string")
    }

    // MARK: - Quote-aware scanning
    //
    // Every one of these exists because a quoted string may contain the character we're looking for.
    // `"#" = "focus left"` is a legal binding line, and a comment-stripper that didn't know about
    // quotes would turn it into nonsense at some later, much more confusing point.

    /// Remove a trailing `# comment`, if the `#` is outside a string.
    private static func stripComment(_ text: Substring) -> Substring {
        guard let hash = indexOfUnquoted("#", in: text) else { return text }
        return text[..<hash]
    }

    private static func indexOfUnquoted(_ target: Character, in text: Substring) -> Substring.Index? {
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if character == target && !inString {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func splitUnquoted(_ text: Substring, on separator: Character) -> [Substring] {
        var pieces: [Substring] = []
        var start = text.startIndex
        var rest = text
        while let index = indexOfUnquoted(separator, in: rest) {
            pieces.append(text[start..<index])
            start = text.index(after: index)
            rest = text[start...]
        }
        pieces.append(text[start...])
        return pieces
    }
}

extension Substring {
    /// Leading/trailing whitespace removed — spelled once because the reader does it on every line,
    /// every key and every value.
    var trimmed: Substring {
        var slice = self
        while let first = slice.first, first.isWhitespace { slice = slice.dropFirst() }
        while let last = slice.last, last.isWhitespace { slice = slice.dropLast() }
        return slice
    }
}
