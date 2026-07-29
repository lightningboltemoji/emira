import Foundation
import EmiraMotion

// The schema of the config file — which keys exist, what they mean, and what a legal value is.
// `TOML.swift` owns the grammar (how a line is written down); this file owns the vocabulary.
//
// **Unknown keys are errors, not shrugs**: a window manager that silently ignores `colum-gap` is one
// the user believes is broken. The reader takes every key the schema knows and reports whatever is
// left, so there is only one list of known keys and it is the reading code itself.
//
// The whole schema, at its `Config()` defaults:
//
// ```toml
// [layout]
// column-gap = 0                        # points; likewise window-gap and outer-gap
// outer-gap-top = 0                     # …and -left/-bottom/-right, overriding outer-gap per side
// width-presets = [0.333, 0.5, 0.667]   # ≤ 1 is a fraction of the *content* width; > 1 is points
// height-presets = [0.333, 0.5, 0.667]  # likewise, against the column height (`cycle-height`)
// center-focused-column = false         # false = scroll the minimum that reveals the column
//
// [animation]
// smooth-transitions = true             # false = always snap
// hold-timeout = 1.0                    # seconds a cover may stay up waiting for AX to land
// window = "stretch"                    # or "crop" — how a still is painted into a changing rect
// cover = "exact"                       # or "immediate" — raise on the desktop alone, sharpen after
//
// [animation.scroll]                    # likewise [animation.resize] and [animation.movement]
// stiffness = 800
// damping-ratio = 1.0
//
// [keys]                                # empty by default
// alt-h = "focus left"
// cmd-alt-period = "center-column"      # punctuation is named — see `KeyChord.swift`
// alt-space = "exec ghostty"            # …or hand the chord back to the system entirely
//
// [[window-rules]]                      # none by default; a list, so it repeats
// app-id = "com.tinyspeck.slackmacgap"  # …or app-id-regex / title / title-regex, all AND'd
// workspace = "3"                       # where a matching window *starts*
// width = 0.5                           # …and how wide, on width-presets' scale
// float = true                          # …or off the strip entirely, overriding the role
// ```
//
// `[keys]` is the one **open** table: its names are chords the user invents (`KeyChord.swift`) and
// its values are commands spelled as `CommandSyntax.swift` spells them, both validated here so a typo
// in either is a diagnostic with a line number rather than a binding that never fires. No bindings
// ship by default — registering a hotkey takes that chord from every other app on the machine, which
// is also why `exec` is in the vocabulary: emira has to be able to give one back. `exec`'s argument
// runs to the end of the line, so a shell line keeps its own spacing and quoting; in a `"…"` string
// the inner double quotes are escaped (`\"`), and the daemon's PATH is launchd's, not the shell's.
//
// `[[window-rules]]` is the one **repeating** table, and the only place order in the file means
// anything: matching rules apply top to bottom, later ones overriding earlier ones field by field
// (`Rules.swift`). Regular expressions are compiled here rather than at match time, so a broken
// pattern is a diagnostic about a line in a file the user is looking at instead of a rule that
// quietly never fires. Write them in `'literal strings'` — a `"…"` string would need every backslash
// doubled, and `"\d"` isn't an escape this grammar admits at all.
//
// `outer-gap` is spelled flat, never dotted: `layout.outer-gap.left` would parse (the grammar
// flattens to dotted paths) but no reader looks at it, and it makes one key both a scalar and a
// table, which real TOML forbids.

/// Why a config file couldn't be read. `CustomStringConvertible` because each is shown to a human
/// looking at that file in an editor — so each names the line.
public enum ConfigSyntaxError: Error, Equatable, CustomStringConvertible {
    /// The text isn't the grammar (`TOML.swift`): a malformed header, an unterminated string, a value
    /// that isn't a value.
    case syntax(line: Int, message: String)
    /// The same key was set twice — refused rather than last-wins.
    case duplicateKey(line: Int, key: String)
    /// A key (or a whole table) the schema doesn't know — almost always a typo.
    case unknownKey(line: Int, key: String)
    /// The key exists but the value is the wrong kind or outside the range it may take.
    case badValue(line: Int, key: String, message: String)

    public var description: String {
        switch self {
        case .syntax(let line, let message):
            return "line \(line): \(message)"
        case .duplicateKey(let line, let key):
            return "line \(line): '\(key)' is set twice"
        case .unknownKey(let line, let key):
            return "line \(line): unknown setting '\(key)'"
        case .badValue(let line, let key, let message):
            return "line \(line): '\(key)' \(message)"
        }
    }

    /// The line the diagnostic points at.
    public var line: Int {
        switch self {
        case .syntax(let line, _), .duplicateKey(let line, _),
             .unknownKey(let line, _), .badValue(let line, _, _):
            return line
        }
    }

    /// The same complaint with its key qualified by `prefix`. One caller: an element of an array of
    /// tables is read as a table of its own, so its keys arrive bare (`app-id`) and a diagnostic about
    /// one has to name the table it was written under (`window-rules.app-id`).
    func qualified(by prefix: String) -> ConfigSyntaxError {
        switch self {
        case .syntax:
            return self
        case .duplicateKey(let line, let key):
            return .duplicateKey(line: line, key: "\(prefix).\(key)")
        case .unknownKey(let line, let key):
            return .unknownKey(line: line, key: "\(prefix).\(key)")
        case .badValue(let line, let key, let message):
            return .badValue(line: line, key: "\(prefix).\(key)", message: message)
        }
    }
}

extension Config {

    /// Read a config file's text into the values the reducer runs on. Absent keys keep their
    /// `Config()` default, so an empty file and a missing file mean the same thing; present keys are
    /// range-checked, and an unrecognized one is refused with its line number rather than ignored.
    ///
    /// - Throws: `ConfigSyntaxError`, whose `description` is already a printable diagnostic.
    public static func parse(_ text: String) throws -> Config {
        var table = try TOMLTable.parse(text)
        var config = Config()

        table.acceptTable("layout")
        if let gap = try table.number("layout.column-gap", atLeast: 0) { config.columnGap = gap }
        if let gap = try table.number("layout.window-gap", atLeast: 0) { config.windowGap = gap }
        if let gaps = try table.edgeInsets("layout.outer-gap", default: config.outerGaps) {
            config.outerGaps = gaps
        }
        if let flag = try table.bool("layout.center-focused-column") { config.centerFocusedColumn = flag }
        if let presets = try table.presetCycle("layout.width-presets") { config.widthPresets = presets }
        if let presets = try table.presetCycle("layout.height-presets") { config.heightPresets = presets }

        table.acceptTable("animation")
        if let flag = try table.bool("animation.smooth-transitions") { config.smoothTransitions = flag }
        if let seconds = try table.number("animation.hold-timeout", greaterThan: 0) {
            config.holdTimeout = seconds
        }
        if let animation: WindowAnimation = try table.word("animation.window") {
            config.windowAnimation = animation
        }
        if let cover: CoverMode = try table.word("animation.cover") {
            config.coverMode = cover
        }
        if let spring = try table.spring("animation.scroll", default: config.scrollSpring) {
            config.scrollSpring = spring
        }
        if let spring = try table.spring("animation.resize", default: config.resizeSpring) {
            config.resizeSpring = spring
        }
        if let spring = try table.spring("animation.movement", default: config.moveSpring) {
            config.moveSpring = spring
        }

        table.acceptTable("keys")
        if let bindings = try table.keyBindings("keys") { config.keys = bindings }

        if let rules = try table.windowRules("window-rules") { config.windowRules = rules }

        if let leftover = table.leftovers.first {
            throw ConfigSyntaxError.unknownKey(line: leftover.line, key: leftover.key)
        }
        return config
    }
}

// MARK: - Typed reads
//
// One reader per value kind, each producing the same shape of complaint: what was expected, on which
// line, for which key.

extension TOMLTable {

    fileprivate mutating func bool(_ key: String) throws -> Bool? {
        guard let value = take(key) else { return nil }
        guard case .bool(let flag) = value.payload else {
            throw ConfigSyntaxError.badValue(line: value.line, key: key,
                                             message: "must be true or false, not \(value.kindName)")
        }
        return flag
    }

    /// A quoted word drawn from a fixed vocabulary. Generic over the enum so the list of legal words
    /// *is* the type — a new case is accepted and named in the diagnostic with nothing here to update.
    fileprivate mutating func word<T: RawRepresentable & CaseIterable>(
        _ key: String
    ) throws -> T? where T.RawValue == String {
        guard let value = take(key) else { return nil }
        guard case .string(let text) = value.payload else {
            throw ConfigSyntaxError.badValue(line: value.line, key: key,
                                             message: "must be a word in quotes, not \(value.kindName)")
        }
        guard let word = T(rawValue: text) else {
            let legal = T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")
            throw ConfigSyntaxError.badValue(line: value.line, key: key,
                                             message: "must be \(legal), not \"\(text)\"")
        }
        return word
    }

    /// A number, optionally bounded. Two separate bound parameters rather than a range, because the
    /// two failures read differently ("must be at least 0" vs "must be greater than 0").
    fileprivate mutating func number(
        _ key: String, atLeast minimum: Double? = nil, greaterThan exclusive: Double? = nil
    ) throws -> Double? {
        guard let value = take(key) else { return nil }
        return try Self.number(value, key: key, atLeast: minimum, greaterThan: exclusive)
    }

    private static func number(
        _ value: TOMLValue, key: String, atLeast minimum: Double? = nil,
        greaterThan exclusive: Double? = nil
    ) throws -> Double {
        guard case .number(let number) = value.payload else {
            throw ConfigSyntaxError.badValue(line: value.line, key: key,
                                             message: "must be a number, not \(value.kindName)")
        }
        if let minimum, number < minimum {
            throw ConfigSyntaxError.badValue(line: value.line, key: key,
                                             message: "must be at least \(Self.spell(minimum))")
        }
        if let exclusive, number <= exclusive {
            throw ConfigSyntaxError.badValue(line: value.line, key: key,
                                             message: "must be greater than \(Self.spell(exclusive))")
        }
        return number
    }

    /// A four-edge inset written as a base key plus per-side overrides: `outer-gap` sets all four,
    /// `outer-gap-left` and its siblings replace one. `default` is what the per-side keys refine when
    /// the base key is absent, which makes `outer-gap-left` alone mean "just the left edge" rather
    /// than "left edge, zero elsewhere". `nil` when the file sets none of the five.
    fileprivate mutating func edgeInsets(_ key: String, default fallback: EdgeInsets) throws -> EdgeInsets? {
        let uniform = try number(key, atLeast: 0)
        var insets = uniform.map(EdgeInsets.init(uniform:)) ?? fallback
        var set = uniform != nil
        // Read order, not file order, decides which of two bad sides is reported.
        let sides: [(String, WritableKeyPath<EdgeInsets, Double>)] = [
            ("top", \.top), ("left", \.left), ("bottom", \.bottom), ("right", \.right),
        ]
        for (name, edge) in sides {
            guard let value = try number("\(key)-\(name)", atLeast: 0) else { continue }
            insets[keyPath: edge] = value
            set = true
        }
        return set ? insets : nil
    }

    /// One size on the same scale the cycles are written in (`presetCycle`) — a rule's `width`. The
    /// conversion is shared rather than restated so the two spellings of a width cannot drift apart.
    fileprivate mutating func presetSize(_ key: String) throws -> PresetSize? {
        guard let value = take(key) else { return nil }
        return Self.presetSize(try Self.number(value, key: key, greaterThan: 0))
    }

    /// **A value ≤ 1 is a fraction of the content width; a value > 1 is a point count** — so `1.0` is a
    /// full-width column, not a one-point one. `PresetSize` models the two as distinct cases, so
    /// nothing is lost in translation.
    private static func presetSize(_ number: Double) -> PresetSize {
        number <= 1 ? .proportion(number) : .fixed(number)
    }

    /// The width cycle, each entry read on `presetSize`'s scale.
    fileprivate mutating func presetCycle(_ key: String) throws -> PresetCycle? {
        guard let value = take(key) else { return nil }
        guard case .array(let elements) = value.payload else {
            throw ConfigSyntaxError.badValue(line: value.line, key: key,
                                             message: "must be an array, not \(value.kindName)")
        }
        guard !elements.isEmpty else {
            throw ConfigSyntaxError.badValue(line: value.line, key: key,
                                             message: "must list at least one width")
        }
        let sizes = try elements.map { element -> PresetSize in
            Self.presetSize(try Self.number(element, key: key, greaterThan: 0))
        }
        return PresetCycle(sizes)
    }

    /// A `[table]` of spring constants (`stiffness`, `damping-ratio`). Returns `nil` only when the
    /// table sets neither key, so a file overriding just the stiffness keeps the default damping ratio
    /// rather than falling off a cliff to zero.
    fileprivate mutating func spring(_ table: String, default fallback: SpringParams) throws -> SpringParams? {
        acceptTable(table)
        let stiffness = try number("\(table).stiffness", greaterThan: 0)
        let ratio = try number("\(table).damping-ratio", atLeast: 0)
        guard stiffness != nil || ratio != nil else { return nil }
        return SpringParams(stiffness: stiffness ?? fallback.stiffness,
                            dampingRatio: ratio ?? fallback.dampingRatio)
    }

    /// The `[keys]` table: chord → command, parsed by `KeyChord.parse` and `Command.parse(line:)`,
    /// with their complaints wrapped in a line number. `nil` when the table sets nothing.
    ///
    /// **Duplicates are caught on the chord, not on the key text**: `cmd-alt-h` and `alt-cmd-h` are
    /// two TOML keys and one hotkey, which the grammar's dotted-path check cannot see.
    fileprivate mutating func keyBindings(_ prefix: String) throws -> [KeyBinding]? {
        let entries = takeAll(under: prefix)
        guard !entries.isEmpty else { return nil }

        var bindings: [KeyBinding] = []
        var seen: Set<KeyChord> = []
        for entry in entries {
            let line = entry.value.line
            let chord: KeyChord
            do {
                chord = try KeyChord.parse(entry.key)
            } catch let error as KeyChordSyntaxError {
                throw ConfigSyntaxError.badValue(
                    line: line, key: "\(prefix).\(entry.key)",
                    message: "is not a key combination — \(error)")
            }
            guard case .string(let text) = entry.value.payload else {
                throw ConfigSyntaxError.badValue(
                    line: line, key: "\(prefix).\(chord)",
                    message: "must be a command in quotes, not \(entry.value.kindName)")
            }
            let command: Command
            do {
                command = try Command.parse(line: text)
            } catch let error as CommandSyntaxError {
                throw ConfigSyntaxError.badValue(
                    line: line, key: "\(prefix).\(chord)", message: "must be a command — \(error)")
            }
            guard seen.insert(chord).inserted else {
                throw ConfigSyntaxError.duplicateKey(line: line, key: "\(prefix).\(chord)")
            }
            bindings.append(KeyBinding(chord, command))
        }
        return bindings
    }

    /// The `[[window-rules]]` list, in file order — which is the order they apply in. Each element is
    /// read as a little table of its own, with the same readers everything else uses, and anything it
    /// leaves behind is an unknown key inside *that* rule.
    ///
    /// Two shapes are refused that the type system would happily hold: a rule matching nothing (it
    /// would apply to every window on the desktop, which nobody means) and a rule doing nothing.
    fileprivate mutating func windowRules(_ prefix: String) throws -> [WindowRule]? {
        guard let elements = takeArray(of: prefix) else {
            // `[window-rules]` written singly parses fine and then goes nowhere, so say which it is
            // rather than leaving the generic unknown-key complaint to imply the key is misspelled.
            if let stray = leftovers.first(where: { $0.key == prefix || $0.key.hasPrefix(prefix + ".") }) {
                throw ConfigSyntaxError.badValue(
                    line: stray.line, key: prefix,
                    message: "is a list of rules — write each one under its own '[[\(prefix)]]'")
            }
            return nil
        }

        return try elements.map { element in
            var body = element.table
            var rule = WindowRule()
            do {
                rule.appId = try body.string("app-id")
                rule.appIdRegex = try body.pattern("app-id-regex")
                rule.title = try body.string("title")
                rule.titleRegex = try body.pattern("title-regex")
                rule.workspace = try body.workspaceName("workspace")
                rule.float = try body.bool("float")
                rule.width = try body.presetSize("width")
                if let leftover = body.leftovers.first {
                    throw ConfigSyntaxError.unknownKey(line: leftover.line, key: leftover.key)
                }
            } catch let error as ConfigSyntaxError {
                throw error.qualified(by: prefix)
            }
            guard rule.hasMatcher else {
                throw ConfigSyntaxError.badValue(
                    line: element.line, key: prefix,
                    message: "must match something — set app-id, app-id-regex, title or title-regex")
            }
            guard rule.hasAction else {
                throw ConfigSyntaxError.badValue(
                    line: element.line, key: prefix,
                    message: "must do something — set workspace, float or width")
            }
            guard !rule.contradictsItself else {
                throw ConfigSyntaxError.badValue(
                    line: element.line, key: prefix,
                    message: "floats a window and then places it on the strip — a floating window has "
                           + "no column, so drop 'float = true' or drop the workspace and width")
            }
            return rule
        }
    }

    /// A plain string value.
    fileprivate mutating func string(_ key: String) throws -> String? {
        guard let value = take(key) else { return nil }
        guard case .string(let text) = value.payload else {
            throw ConfigSyntaxError.badValue(line: value.line, key: key,
                                             message: "must be text in quotes, not \(value.kindName)")
        }
        return text
    }

    /// A regular expression, **compiled here to prove it is one** and then kept as its source text —
    /// `Config` is an `Equatable`, `Codable` value and a compiled `Regex` is neither. Matching pays the
    /// compile again, which costs nothing at the rate windows appear.
    fileprivate mutating func pattern(_ key: String) throws -> String? {
        guard let value = take(key) else { return nil }
        guard case .string(let text) = value.payload else {
            throw ConfigSyntaxError.badValue(
                line: value.line, key: key,
                message: "must be a regular expression in quotes, not \(value.kindName)")
        }
        do {
            _ = try Regex(text)
        } catch {
            // First line only: a regex parse error carries a multi-line caret diagram, and a config
            // diagnostic is one line naming one line.
            let complaint = String(describing: error)
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? "unreadable"
            throw ConfigSyntaxError.badValue(line: value.line, key: key,
                                             message: "is not a regular expression — \(complaint)")
        }
        return text
    }

    /// A workspace address, spelled as the single character that names it. Always quoted, never a bare
    /// number: the domain runs `1`–`9`, `0`, `a`–`z`, so half of it isn't numeric and the tenth address
    /// is spelled `0` — a TOML integer could carry neither fact.
    fileprivate mutating func workspaceName(_ key: String) throws -> WorkspaceName? {
        guard let value = take(key) else { return nil }
        guard case .string(let text) = value.payload, let name = WorkspaceName(text) else {
            throw ConfigSyntaxError.badValue(
                line: value.line, key: key,
                message: "must be a workspace name in quotes — \"1\"-\"9\", \"0\", then \"a\"-\"z\"")
        }
        return name
    }

    /// `8` rather than `8.0` in a diagnostic about an integral bound.
    private static func spell(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }
}
