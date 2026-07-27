import Foundation

// The reader half of the config file — text in, keyed values out. A hand-rolled, deliberately partial
// TOML: the subset emira's own config is written in, and nothing else. Anything outside the grammar is
// a diagnostic naming the line, and every value carries the line it was read on.
//
// Supported: `#` comments, whole-line or trailing; `[table]`/`[table.sub]` headers and `[[array]]`
// headers, keys before any header sitting at the top level; `key = value` with bare (`column-gap`) or
// quoted (`"cmd-alt-h"`) dot-separated keys; values that are `true`/`false`, a number, a `"string"` or
// a `'literal string'`, or a single-line array of those. Not implemented, each saying so when met:
// multi-line arrays, inline tables, multi-line strings, dates.
//
// The last two additions arrived together with `[[window-rules]]`, and the second is not incidental to
// the first: a rule matches on regular expressions, and a regex written in a `"…"` string has to double
// every backslash it contains — `"^com\\.apple\\."` — while `\d` isn't a legal escape here at all and
// so is a *syntax error* rather than a character class. Literal strings are what that notation is for.

/// One value read out of the config text, plus the line it was written on.
struct TOMLValue: Equatable {
    /// The four value kinds the subset admits. Numbers are `Double` throughout — the schema decides
    /// whether a given key wants an integral one.
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
/// `"layout.column-gap"`. Flat rather than a tree because the schema *takes* the keys it knows.
struct TOMLTable: Equatable {
    /// Every `key = value` in the document, by dotted path.
    private(set) var values: [String: TOMLValue] = [:]
    /// Every `[table]` header *declared*, by dotted path → line. Kept apart from the values because an
    /// empty table is still a typo worth catching: `[layuot]` contributes no key to be left over.
    private(set) var tables: [String: Int] = [:]

    // MARK: - Consumption
    //
    // Taking the keys it knows and then asking what is left means "unknown key" needs no second list
    // of valid names to drift out of step with the reader.

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
    /// first. For `[keys]`, the one open table, whose key names the user invents and so cannot be
    /// `take`n one by one.
    mutating func takeAll(under prefix: String) -> [(key: String, value: TOMLValue)] {
        let dotted = prefix + "."
        let matching = values.filter { $0.key.hasPrefix(dotted) }
        for key in matching.keys { values.removeValue(forKey: key) }
        return matching
            .map { (key: String($0.key.dropFirst(dotted.count)), value: $0.value) }
            .sorted { ($0.value.line, $0.key) < ($1.value.line, $1.key) }
    }

    /// Remove and return the elements of an array of tables (`[[window-rules]]`), in file order — each
    /// as a table of its own keys, so the schema reads one element with the very same typed readers it
    /// uses at the top level, and an element's unread keys are that element's leftovers. `nil` when the
    /// document declares none.
    ///
    /// Elements are addressed by the index `parse` flattened them under, which is an implementation
    /// detail of the flattening and never appears in a diagnostic: the caller re-qualifies what it
    /// reports (`ConfigSyntaxError.qualified(by:)`).
    mutating func takeArray(of prefix: String) -> [(line: Int, table: TOMLTable)]? {
        let dotted = prefix + "."
        var elements: [Int: (line: Int, table: TOMLTable)] = [:]

        for path in tables.keys.filter({ $0.hasPrefix(dotted) }) {
            guard let index = Int(path.dropFirst(dotted.count)) else { continue }
            let line = tables.removeValue(forKey: path) ?? 0
            elements[index] = (line, TOMLTable())
        }
        for path in values.keys.filter({ $0.hasPrefix(dotted) }) {
            let rest = path.dropFirst(dotted.count)
            guard let dot = rest.firstIndex(of: "."), let index = Int(rest[..<dot]),
                  elements[index] != nil, let value = values.removeValue(forKey: path)
            else { continue }
            elements[index]?.table.values[String(rest[rest.index(after: dot)...])] = value
        }

        guard !elements.isEmpty else { return nil }
        return elements.sorted { $0.key < $1.key }.map(\.value)
    }

    /// Everything the schema never took, earliest line first — keys, then declared-but-unaccepted table
    /// headers. Sorted by line so the diagnostic points at the *first* mistake.
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
        // How many elements each `[[array]]` header has been seen with, which is the index the next one
        // flattens under. Local to a parse: the numbering is positional, never written down by anyone.
        var elementCounts: [String: Int] = [:]

        // Split on `isNewline`, not on `"\n"`: Swift reads `"\r\n"` as one grapheme cluster, so a
        // CRLF file would split into a single line with every key on it.
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = index + 1
            let trimmed = rawLine.trimmed

            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("[") {
                let (path, isElement) = try header(trimmed, line: line)
                if isElement {
                    let dotted = path.joined(separator: ".")
                    let ordinal = elementCounts[dotted, default: 0]
                    elementCounts[dotted] = ordinal + 1
                    current = path + [String(ordinal)]
                } else {
                    current = path
                }
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

    /// `[layout]` / `[animation.scroll]` / `[[window-rules]]` → the path it sets subsequent keys under,
    /// and whether it opens one *element* of an array of tables rather than the table itself.
    private static func header(_ text: Substring, line: Int) throws -> (path: [String], isElement: Bool) {
        let isElement = text.hasPrefix("[[")
        let closer = isElement ? "]]" : "]"
        let opened = text.dropFirst(isElement ? 2 : 1)
        guard let close = indexOfUnquoted("]", in: opened) else {
            throw ConfigSyntaxError.syntax(line: line,
                                           message: "unterminated table header — expected '\(closer)'")
        }
        var after = opened[opened.index(after: close)...]
        if isElement {
            guard after.hasPrefix("]") else {
                throw ConfigSyntaxError.syntax(line: line,
                                               message: "unterminated table header — expected ']]'")
            }
            after = after.dropFirst()
        }
        let rest = after.trimmed
        guard rest.isEmpty || rest.hasPrefix("#") else {
            throw ConfigSyntaxError.syntax(line: line, message: "unexpected text after '\(closer)'")
        }
        let path = try keyPath(opened[..<close], line: line)
        guard !path.isEmpty else {
            throw ConfigSyntaxError.syntax(line: line, message: "empty table header")
        }
        return (path, isElement)
    }

    /// A dot-separated key expression — headers and key names are spelled the same way. Each segment is
    /// bare (`column-gap`) or quoted (`"cmd-alt-h"`); quoting admits characters the bare charset
    /// (letters, digits, `-`, `_`) refuses.
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
        if text.hasPrefix("'") {
            let (string, remainder) = try literalString(text, line: line)
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
        // `Double(_:)` happily reads "inf", "nan" and hex floats ("0x1p3"), none of which a config file
        // should be able to say — so check the charset first and parse second.
        let numeric = text.allSatisfy { $0.isNumber || "+-.eE".contains($0) }
        guard numeric, let number = Double(text), number.isFinite else {
            throw ConfigSyntaxError.syntax(line: line, message: "cannot read '\(text)' as a value")
        }
        return TOMLValue(payload: .number(number), line: line)
    }

    /// Read a `"…"` string starting at `text`'s first character; returns it and whatever follows.
    /// Escapes: `\"`, `\\`, `\n`, `\t`, `\r`. Anything else escaped is an error.
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

    /// Read a `'…'` literal string starting at `text`'s first character; returns it and whatever
    /// follows. **No escapes at all** — that is the entire point of the notation, and what lets a regex
    /// be written the way it is written everywhere else. It therefore cannot contain a `'`.
    private static func literalString(_ text: Substring, line: Int) throws -> (String, Substring) {
        let body = text.dropFirst()             // past the opening quote
        guard let close = body.firstIndex(of: "'") else {
            throw ConfigSyntaxError.syntax(line: line, message: "unterminated string")
        }
        return (String(body[..<close]), body[body.index(after: close)...])
    }

    // MARK: - Quote-aware scanning
    //
    // A quoted string may contain the character being looked for: `"#" = "focus left"` is a legal
    // binding line, and a quote-blind comment-stripper would mangle it.

    /// Remove a trailing `# comment`, if the `#` is outside a string.
    private static func stripComment(_ text: Substring) -> Substring {
        guard let hash = indexOfUnquoted("#", in: text) else { return text }
        return text[..<hash]
    }

    /// The first `target` outside a string of *either* kind. The open quote is remembered rather than
    /// counted, so `"it's"` and `'say "hi"'` are each one string, and `\` escapes only inside a `"…"`.
    private static func indexOfUnquoted(_ target: Character, in text: Substring) -> Substring.Index? {
        var quote: Character?
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && quote == "\"" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == target {
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
    /// Leading/trailing whitespace removed.
    var trimmed: Substring {
        var slice = self
        while let first = slice.first, first.isWhitespace { slice = slice.dropFirst() }
        while let last = slice.last, last.isWhitespace { slice = slice.dropLast() }
        return slice
    }
}
