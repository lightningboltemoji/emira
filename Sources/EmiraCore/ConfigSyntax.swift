import Foundation
import EmiraMotion

// The *schema* of the config file — which keys exist, what they mean, and what a legal value for each
// one is. `TOML.swift` owns the grammar (how a line is written down); this file owns the vocabulary,
// and the pair stand in the same relation as `Command.swift` and `CommandSyntax.swift`.
//
// **Why the parse is in the pure core when IMPLEMENTATION.md §6 assigned it to the shell.** The
// sentence there — "the parsed values are a pure `Config` struct in `EmiraCore` … the
// loading/parsing/watching is in the shell" — bundles three things that don't belong together. Only
// *loading* and *watching* are imperative (a path, a file, an FSEvents stream); **parsing is a pure
// function from a `String` to a value type**, which is the definition of what §1 invariant 1 puts in
// the core. Splitting it here means the half with all the decisions in it — every key name, every
// range check, every diagnostic — is unit-testable against string literals with no filesystem, and
// `EmiraShell/Config/ConfigLoader.swift` is left holding exactly the part that needs a disk.
//
// **Unknown keys are errors, not shrugs.** A window manager that silently ignores `colum-gap` is a
// window manager the user believes is broken. The reader takes every key the schema knows and then
// reports whatever is left, so the "known keys" list can't drift out of step with the code that
// reads them — there is only one list, and it is the reading code itself. Same discipline as the
// CLI's trailing-argument check (`CommandSyntax.swift`): a typo is refused, never discarded.
//
// The file `Config()`'s defaults describe, in full:
//
// ```toml
// [layout]
// column-gap = 0                        # points between columns
// window-gap = 0                        # points between windows stacked in a column
// outer-gap = 0                         # points of margin at every edge of the working area
// outer-gap-top = 0                     # …and the four per-side overrides
// outer-gap-left = 0
// outer-gap-bottom = 0
// outer-gap-right = 0
// width-presets = [0.333, 0.5, 0.667]   # ≤ 1 is a fraction of the *content* width; > 1 is points
// center-focused-column = false         # false = scroll the minimum that reveals the column
//
// [animation]
// smooth-transitions = true             # false = always snap (PRINCIPLES.md §4a)
// hold-timeout = 1.0                    # seconds a cover may stay up waiting for AX to land
// window = "stretch"                    # or "crop" — how a still is painted into a changing rect
//
// [animation.scroll]                    # the viewport scroll
// stiffness = 800
// damping-ratio = 1.0
//
// [animation.resize]                    # a column's resolved width
// stiffness = 800
// damping-ratio = 1.0
//
// [animation.movement]                  # a window's displacement
// stiffness = 800
// damping-ratio = 1.0
//
// [keys]                                # empty by default — see below
// ```
//
// `[keys]` is the one **open** table: its key names are chords the user invents (`KeyChord.swift`),
// its values are commands in the spelling `CommandSyntax.swift` already owns, and both halves are
// validated here so a typo in either is a diagnostic with a line number rather than a binding that
// silently never fires.
//
// ```toml
// [keys]
// alt-h = "focus left"
// alt-shift-h = "move-window left"
// cmd-alt-period = "center-column"      # punctuation is named — see `KeyChord.swift`
// ```
//
// **No chord ever needs quoting, which is a small surprise worth recording.** M5 part 1 taught
// `TOML.swift` quoted keys *for this table*, on the assumption that a chord would need characters the
// bare-key charset (letters, digits, `-`, `_`) refuses. It doesn't: `-` separates a chord's words, so
// every punctuation key had to be given a *name* anyway — and a name is bare-key-legal. Two decisions
// made a milestone apart, each for its own reason, ended up making the other unnecessary. The quoted
// form still parses and is still tested; it is simply never required.
//
// **No default bindings, and that is a decision rather than an omission.** Everywhere else in this
// file silence is the failure mode we refuse — a window manager that ignores `colum-gap` is one the
// user believes is broken. A binding is the opposite case: registering a hotkey takes that chord away
// from *every other application on the machine*, so a default binding is emira confiscating a keystroke
// nobody asked it to. An unbound emira steals nothing. The daemon says how many bindings are live at
// boot, naming the file, so "none" is reported rather than merely being true.
//
// **`outer-gap` is spelled flat, not dotted (2026-07-26).** `outer-gap.left` would in fact parse —
// `TOML.swift` flattens the document to dotted paths in one dictionary, so `layout.outer-gap` and
// `layout.outer-gap.left` are simply two distinct keys and neither reader would notice the other. It is
// still the wrong spelling: it makes one key both a scalar and a table, which real TOML forbids, so the
// day the hand-rolled grammar is replaced by a strict one every config file using it breaks. The flat
// form costs one `take` per side, reads like the `column-gap`/`window-gap` it belongs beside, and is
// legal TOML in any parser.
//
// **What is deliberately *not* a key.** `struts` is a fact about the hardware, read off
// `NSScreen.visibleFrame` by the daemon and handed to both the core and the overlay (M4 part 3 — the
// invariant holds only while the two agree), so a config file cannot contradict the menu bar. A user
// who wants a margin at the screen's edge wants `outer-gap`, which is additive with the struts and
// measured inside them.

/// Why a config file couldn't be read. `CustomStringConvertible` because every one of these is shown
/// to a human who is looking at that file in an editor — so each names the line.
public enum ConfigSyntaxError: Error, Equatable, CustomStringConvertible {
    /// The text isn't the grammar (`TOML.swift`): a malformed header, an unterminated string, a value
    /// that isn't a value.
    case syntax(line: Int, message: String)
    /// The same key was set twice. Refused rather than last-wins, because which one the user meant is
    /// not knowable and one of the two is dead text they will keep editing.
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

    /// The line the diagnostic points at — the daemon logs it, and a future `emira check-config`
    /// would underline it.
    public var line: Int {
        switch self {
        case .syntax(let line, _), .duplicateKey(let line, _),
             .unknownKey(let line, _), .badValue(let line, _, _):
            return line
        }
    }
}

extension Config {

    /// Read a config file's text into the values the reducer runs on.
    ///
    /// Absent keys keep their `Config()` default, so an empty file and a missing file mean the same
    /// thing — the zero-config strip. Present keys are validated: a gap can't be negative, a spring
    /// can't have zero stiffness, the preset cycle can't be empty. Anything the schema doesn't
    /// recognize is refused with its line number rather than ignored.
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

        table.acceptTable("animation")
        if let flag = try table.bool("animation.smooth-transitions") { config.smoothTransitions = flag }
        if let seconds = try table.number("animation.hold-timeout", greaterThan: 0) {
            config.holdTimeout = seconds
        }
        if let animation: WindowAnimation = try table.word("animation.window") {
            config.windowAnimation = animation
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

        if let leftover = table.leftovers.first {
            throw ConfigSyntaxError.unknownKey(line: leftover.line, key: leftover.key)
        }
        return config
    }
}

// MARK: - Typed reads
//
// One reader per value kind, each producing the same shape of complaint: what was expected, on which
// line, for which key. They are `private` to this file because they are the *schema's* readers — the
// ranges and the wording are decisions about emira's config, not about TOML.

extension TOMLTable {

    fileprivate mutating func bool(_ key: String) throws -> Bool? {
        guard let value = take(key) else { return nil }
        guard case .bool(let flag) = value.payload else {
            throw ConfigSyntaxError.badValue(line: value.line, key: key,
                                             message: "must be true or false, not \(value.kindName)")
        }
        return flag
    }

    /// A quoted word drawn from a fixed vocabulary — an enumeration the user spells out rather than a
    /// number or a flag.
    ///
    /// Generic over the enum so the *list of legal words is the type itself*: a case added to
    /// `WindowAnimation` is accepted by the file and named in the diagnostic with nothing here to
    /// update. Same discipline as the unknown-key check at the top of this file — one list, and it is
    /// the code that reads it.
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

    /// A number, optionally bounded. Both bounds are spelled as separate parameters rather than a
    /// range because the two failures read differently to a human ("must not be negative" vs "must be
    /// greater than zero") and that difference is the whole value of the message.
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

    /// A four-edge inset written as a base key plus per-side overrides: `outer-gap` sets all four and
    /// `outer-gap-left` (and its three siblings) replaces one of them. Reading the base first and
    /// letting each side overwrite it *is* the precedence rule, so there is nothing to enforce.
    ///
    /// `default` is the value the per-side keys refine when the base key is absent, which is what makes
    /// `outer-gap-left` alone mean "just the left edge" rather than "the left edge, and zero elsewhere".
    ///
    /// Returns `nil` when the file sets none of the five, so an absent setting keeps the `Config()`
    /// default rather than asserting zero over it — the same shape as `spring` and every other reader
    /// here. Negative is refused like the other gaps: a negative margin would push the strip back under
    /// the menu bar the struts exist to keep it out of.
    fileprivate mutating func edgeInsets(_ key: String, default fallback: EdgeInsets) throws -> EdgeInsets? {
        let uniform = try number(key, atLeast: 0)
        var insets = uniform.map(EdgeInsets.init(uniform:)) ?? fallback
        var set = uniform != nil
        // Read order, not file order, decides which of two bad sides is reported — the same property
        // `spring` has for `stiffness` before `damping-ratio`.
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

    /// The width cycle. **A value ≤ 1 is a fraction of the content width; a value > 1 is a point
    /// count** — the one piece of cleverness in the schema, and it earns its place: `[0.333, 0.5]`
    /// and `[600, 900]` are both what a user means by them, and `PresetSize` already models the two
    /// as distinct cases (`Presets.swift`), so nothing is lost in translation. The alternative
    /// spelling — TOML inline tables, `{ proportion = 0.5 }` — would have cost the reader a whole
    /// value kind to express something no one is ambiguous about. A 1.0 preset is a full-width
    /// column, not a one-point one.
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
            let size = try Self.number(element, key: key, greaterThan: 0)
            return size <= 1 ? .proportion(size) : .fixed(size)
        }
        return PresetCycle(sizes)
    }

    /// A `[table]` of spring constants, spelled physically (`stiffness`, `damping-ratio`) so
    /// published values can be copied across unchanged — which is how `.smooth` got its numbers in
    /// the first place (`Curve.swift`, M4 part 2).
    ///
    /// Returns `nil` only when the table sets neither key, so a file that overrides just the
    /// stiffness keeps the default damping ratio rather than falling off a cliff to zero.
    fileprivate mutating func spring(_ table: String, default fallback: SpringParams) throws -> SpringParams? {
        acceptTable(table)
        let stiffness = try number("\(table).stiffness", greaterThan: 0)
        let ratio = try number("\(table).damping-ratio", atLeast: 0)
        guard stiffness != nil || ratio != nil else { return nil }
        return SpringParams(stiffness: stiffness ?? fallback.stiffness,
                            dampingRatio: ratio ?? fallback.dampingRatio)
    }

    /// The `[keys]` table: chord → command, both parsed by the vocabularies that already own them
    /// (`KeyChord.parse`, `Command.parse(line:)`), so this reader is only the *joining* of the two and
    /// the wrapping of their complaints in a line number.
    ///
    /// Returns `nil` when the table sets nothing, so an absent `[keys]` keeps whatever default
    /// `Config()` has rather than asserting emptiness over it — the same shape as every other reader
    /// here.
    ///
    /// **Duplicates are caught on the chord, not on the key text.** `cmd-alt-h` and `alt-cmd-h` are
    /// two different TOML keys and the same hotkey, so the grammar's own duplicate check (which
    /// compares dotted paths) cannot see it: whichever came second would silently never fire, and the
    /// user would be looking at two lines that both plainly say what they mean. The diagnostic names
    /// the **canonical** spelling of the chord, which is what makes the connection between the two
    /// lines visible.
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

    /// `8` rather than `8.0` in a diagnostic about an integral bound.
    private static func spell(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }
}
