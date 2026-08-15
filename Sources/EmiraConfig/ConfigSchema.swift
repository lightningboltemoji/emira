import EmiraCore
import EmiraMotion

// The schema as a table you can enumerate, rather than one that exists only by being run.
//
// One entry per setting, and four consumers off the one list: the reader runs it
// (`ConfigSyntax.swift`), the writer renders from it, `emira config explain` prints it, the settings
// window lays it out. What it replaced was a reader of straight-line statements with a hand-maintained
// example document beside it — the same facts written down twice, one of which could silently drift.
//
// **Presentation metadata belongs on the entry.** A section, an order, an advanced-or-not are facts
// about the setting rather than about AppKit, and the alternative is a second list drifting from this
// one exactly the way the example did. What stays out is anything a *frame* needs: no colours, no
// widths, no view types, and nothing here imports a framework.
//
// **What the table deliberately does not describe**: `outer-gap` (one value with five spellings),
// `[keys]` (an open table whose names the user invents) and `[[window-rules]]` (repeating, ordered,
// cross-validated). Each is read by a function named for it in `ConfigSyntax.swift` — forcing them in
// here would produce a worse GUI, not a better schema.
//
// **They are still a list.** `bespoke` is the three of them, carrying what a consumer needs to place
// one: a label, a sentence, the section it belongs to, the block the generated document writes, and a
// fragment that sets it to something its default is not. A surface the table cannot describe is a
// surface every consumer would otherwise name by hand — and one that no consumer names by hand is
// invisible rather than deliberate, which is what `outer-gap` was.

/// One setting the config file may carry: how it is spelled, what it means, what a legal value is, and
/// how that value crosses between the file and a `Config` field.
public struct Setting: Sendable {

    /// The dotted key, spelled the way the file spells it: `"layout.column-gap"`.
    public let key: String
    /// The setting's name in prose, or on a control's label.
    public let label: String
    /// One sentence: what it does. Printed by `explain`, shown under the control, and written into the
    /// generated document as the key's comment — three readers, so it stays a sentence.
    public let help: String
    /// What a legal value is, in the terms a diagnostic and a control both need.
    public let kind: Kind
    /// Which group it belongs to — the order a window shows them in, and the order the document runs.
    public let section: Section
    /// A dial rather than a preference: behind a disclosure, not on the main surface.
    public let isAdvanced: Bool

    /// Validate a value the file carried and write it into `config`. The two halves of `access`, kept
    /// as closures because the table is one array and the values it moves are of different types.
    let apply: @Sendable (TOMLValue, inout Config) throws -> Void
    private let render: @Sendable (Config) -> TOMLValue

    /// This setting's value in `config`, spelled as the file spells it — what `ConfigDocument.set`
    /// takes, and what the generated document shows.
    public func value(in config: Config) -> TOMLValue { render(config) }

    /// What this setting is when the file says nothing about it.
    public var defaultValue: TOMLValue { render(Config()) }

    /// Whether `config` leaves this setting alone. A writer unsets a key rather than writing this back:
    /// a file saying what the default already says is a file that pins it against ever changing.
    public func isDefault(in config: Config) -> Bool { isDefault(render(config)) }

    /// Whether writing `value` down would only repeat what emira already does.
    public func isDefault(_ value: TOMLValue) -> Bool {
        value.spelled == defaultValue.spelled
    }

    /// The common case: a key that is one `Config` field, moved by a codec.
    init<Value>(_ key: String, _ field: WritableKeyPath<Config, Value> & Sendable, _ codec: Codec<Value>,
                label: String, help: String, section: Section, advanced: Bool = false) {
        self.init(key, codec, label: label, help: help, section: section, advanced: advanced,
                  get: { $0[keyPath: field] },
                  set: { $0[keyPath: field] = $1 })
    }

    /// The general case: a key that is one *coordinate* of a field. Only the springs need it — a
    /// stiffness is not a `SpringParams`, and writing one has to say what happens to the other half.
    init<Value>(_ key: String, _ codec: Codec<Value>, label: String, help: String, section: Section,
                advanced: Bool = false,
                get: @escaping @Sendable (Config) -> Value,
                set: @escaping @Sendable (inout Config, Value) -> Void) {
        self.key = key
        self.label = label
        self.help = help
        self.kind = codec.kind
        self.section = section
        self.isAdvanced = advanced
        self.apply = { value, config in set(&config, try codec.read(value, key)) }
        self.render = { codec.write(get($0)) }
    }
}

extension Setting {

    /// What a legal value is. **One case per shape of control, never per setting** — a case serving a
    /// single key is the sign the table has stopped paying for itself.
    public enum Kind: Equatable, Sendable {
        /// `true` or `false`.
        case toggle
        /// A number, with the floor it may not go under and the unit it is counted in.
        case number(Bound, unit: Unit)
        /// One word from a fixed vocabulary, listed as the file spells them.
        case choice([String])
        /// A list of sizes on `width-presets`' scale.
        case sizeList

        /// What a legal value is, in one line: the sentence `explain` prints and the note the generated
        /// document carries. Derived from the case, so a new bound or a new enum case says so for free.
        public var legend: String? {
            switch self {
            case .toggle:
                return nil
            case .number(let bound, let unit):
                return [unit.clause, bound.requirement].compactMap { $0 }
                    .joined(separator: ", ").asSentence
            case .choice(let words):
                return ("one of " + words.map { "\"\($0)\"" }.joined(separator: ", ")).asSentence
            case .sizeList:
                return ("a list of sizes — 1 or less is a fraction of the extent it is resolved "
                      + "against, anything larger is a point count").asSentence
            }
        }
    }

    /// A number's floor. Two spellings rather than one range, because the two refusals read
    /// differently — a gap of zero is a gap, a spring of zero is not a spring — and the sentence the
    /// user reads is the product.
    public enum Bound: Equatable, Sendable {
        case atLeast(Double)
        case greaterThan(Double)

        func admits(_ number: Double) -> Bool {
            switch self {
            case .atLeast(let minimum):     return number >= minimum
            case .greaterThan(let exclusive): return number > exclusive
            }
        }

        /// The complaint a value under the floor produces, and the clause `explain` prints.
        public var requirement: String {
            switch self {
            case .atLeast(let minimum):
                return "must be at least \(TOMLValue.spell(minimum))"
            case .greaterThan(let exclusive):
                return "must be greater than \(TOMLValue.spell(exclusive))"
            }
        }
    }

    /// What a number counts — the suffix beside a field, and a clause of `explain`'s sentence.
    public enum Unit: Equatable, Sendable {
        case points
        case seconds
        /// A ratio or a physical constant: a number that counts nothing.
        case bare

        var clause: String? {
            switch self {
            case .points:  return "in points"
            case .seconds: return "in seconds"
            case .bare:    return nil
            }
        }
    }

    /// The groups a settings window shows, in the order it shows them. `keys` and `windowRules` carry
    /// no *settings* on purpose: they are two of the three surfaces the table cannot describe, and they
    /// are on `bespoke` instead — naming them here is what keeps a window's list of sections one list
    /// rather than "the schema's, plus two".
    ///
    /// **There is no springs section.** The four spring tables are eight advanced dials of `animation`:
    /// a section whose every entry is advanced opens on nothing but a disclosure triangle, which is a
    /// tab that says the settings are elsewhere.
    public enum Section: String, CaseIterable, Sendable {
        case layout, focus, mouse, animation, guide, keys, windowRules

        public var title: String {
            switch self {
            case .layout:      return "Layout"
            case .focus:       return "Focus"
            case .mouse:       return "Mouse"
            case .animation:   return "Animation"
            case .guide:       return "Guide"
            case .keys:        return "Keys"
            case .windowRules: return "Window rules"
            }
        }
    }

    /// The dotted `[table]` the key is written under — everything before its last segment. Public
    /// because it is what groups a settings panel's rows: a section that spans two tables is one the
    /// tab's own title cannot describe.
    public var table: String {
        let segments = key.split(separator: ".")
        return segments.dropLast().joined(separator: ".")
    }

    /// The key as it is written *inside* its table, which is the only part a line carries.
    var name: String { String(key.split(separator: ".").last ?? "") }
}

/// A config surface the table cannot describe: what it is called, where it belongs, why it is here
/// rather than in `settings`, and the block the generated document writes for it.
///
/// **Not a `Setting` with holes in it.** Each of the three fails a different requirement of the table —
/// one value with five spellings, a table of invented names, an ordered repeating block — so none of
/// them has the `(read, write, default)` triple every entry rests on. What they *do* share is being
/// something a consumer has to place: the document has to write it, the coverage test has to name it,
/// and a settings window has to either edit it or say why it doesn't. That much is a list.
public struct Bespoke: Sendable {

    /// The dotted key, or the table's name — spelled the way the file spells it: `"layout.outer-gap"`,
    /// `"keys"`, `"window-rules"`.
    public let key: String
    /// The surface's name in prose, or on a control's label.
    public let label: String
    /// One sentence: what it does. Shown under a control, exactly as a `Setting`'s is.
    public let help: String
    /// Which group it belongs to.
    public let section: Setting.Section
    /// The key this is written directly after, or `nil` to follow every setting in its table.
    ///
    /// **One field, so the document and the panel cannot disagree about where it goes.** Outer gaps
    /// belong beside the two other gaps rather than after the preset lists, and that is a fact about
    /// the setting rather than about either surface — spelling it twice is how the two orders would
    /// come to differ.
    public let after: String?
    /// Why the table cannot carry it. The reason is data rather than a comment because it is the
    /// answer to the only question this list ever provokes.
    public let reason: String

    /// The block the generated document carries — hand-written prose, for the reason its reader is
    /// hand-written. Parsed by the test that pins the document, so a spelling that stopped being legal
    /// fails the suite rather than misleading a reader.
    let documentation: String
    /// A fragment that sets this surface to something its default is not, for the test that proves
    /// every field of `Config` is reachable from the file. Carries its own header where it needs one.
    let sample: String

    /// The `[table]` this is written *inside*, or `nil` when it opens a header of its own. Derived from
    /// the spelling, so where the document puts a surface is not a second decision.
    var table: String? {
        let segments = key.split(separator: ".")
        return segments.count > 1 ? segments.dropLast().joined(separator: ".") : nil
    }
}

//
// What makes one entry serve the reader and the writer both: a codec knows what a legal value is, how
// to take one out of the file, and how to put one back. Every read here goes through
// `ConfigSyntax.swift`'s typed readers rather than restating them, so a table-driven setting and a
// bespoke one refuse the same value with the same sentence.

/// How one kind of value crosses between a line of the file and a field of `Config`.
struct Codec<Value: Sendable>: Sendable {
    /// What a legal value is. Handed to the entry, so the control and the diagnostic are built from
    /// one description rather than from two that agree today.
    let kind: Setting.Kind
    /// Validate a value the file carried. `key` is used only to name it in a complaint.
    let read: @Sendable (TOMLValue, String) throws -> Value
    let write: @Sendable (Value) -> TOMLValue
}

extension Codec where Value == Bool {
    static var toggle: Codec {
        Codec(kind: .toggle, read: { try TOMLTable.bool($0, key: $1) }, write: { .bool($0) })
    }
}

extension Codec where Value == Double {
    /// A number that may sit on its floor.
    static func number(atLeast minimum: Double, unit: Setting.Unit) -> Codec {
        number(.atLeast(minimum), unit)
    }

    /// A number that may not. Spelled separately from `atLeast` rather than as one range, because the
    /// two refusals read differently and the sentence the user gets is the whole point of the split.
    static func number(greaterThan exclusive: Double, unit: Setting.Unit) -> Codec {
        number(.greaterThan(exclusive), unit)
    }

    private static func number(_ bound: Setting.Bound, _ unit: Setting.Unit) -> Codec {
        Codec(kind: .number(bound, unit: unit),
              read: { value, key in
                  let number = try TOMLTable.number(value, key: key)
                  guard bound.admits(number) else {
                      throw ConfigSyntaxError.badValue(line: value.line, key: key,
                                                       message: bound.requirement)
                  }
                  return number
              },
              write: { .number($0) })
    }
}

extension Codec where Value == Int {
    /// A count. Read through the same reader every other number goes through and then rounded, because
    /// the grammar has one numeric type and a count of columns is not a fraction of one.
    static func count(atLeast minimum: Int) -> Codec {
        let bound = Setting.Bound.atLeast(Double(minimum))
        return Codec(kind: .number(bound, unit: .bare),
                     read: { value, key in
                         let number = try TOMLTable.number(value, key: key)
                         guard bound.admits(number) else {
                             throw ConfigSyntaxError.badValue(line: value.line, key: key,
                                                              message: bound.requirement)
                         }
                         return Int(number.rounded())
                     },
                     write: { .number(Double($0)) })
    }
}

extension Codec where Value: RawRepresentable & CaseIterable, Value.RawValue == String {
    /// One word from a fixed vocabulary. **The type is the vocabulary**: the legal words are read off
    /// `allCases`, so a new enum case is accepted, named in the diagnostic and offered by a control
    /// with nothing here to update.
    static var word: Codec {
        Codec(kind: .choice(Value.allCases.map(\.rawValue)),
              read: { try TOMLTable.word($0, key: $1) },
              write: { .string($0.rawValue) })
    }
}

extension Codec where Value == PresetCycle {
    static var sizeList: Codec {
        Codec(kind: .sizeList,
              read: { try TOMLTable.presetCycle($0, key: $1) },
              write: { cycle in .array(cycle.presets.map { .number($0.written) }) })
    }
}

extension PresetSize {
    /// The single number a file spells this size as. The scale carries the case rather than the
    /// notation — anything ≤ 1 reads back as a proportion — so a `.fixed` below one point is the one
    /// value that could not survive the round trip. No cycle holds one: a one-point column is not a
    /// thing anyone writes, and every size that came *from* a file is on the right side of the line.
    fileprivate var written: Double {
        switch self {
        case .proportion(let fraction): return fraction
        case .fixed(let points):        return points
        }
    }
}

// A value from a word
//
// The codec run backwards from *text* rather than from TOML — what a command line hands over, and what
// a text field in a window will. The validation stays the codec's: the word is built into the value the
// kind expects and refused by the same reader, so a bound is checked once and complains once.

extension Setting {

    /// Read a value written the way an argument writes one — `8`, `true`, `adopt`, `0.5, 1` — rather
    /// than the way a line of the file does.
    ///
    /// A word that cannot be read as this setting's kind is built as a string on purpose: "must be a
    /// number, not a string" is already the right complaint, and it is already written down.
    ///
    /// - Throws: `ConfigSyntaxError`, whose `message` is the complaint without a line — this value came
    ///   from an argument, so there is no line to name.
    public func value(from text: String) throws -> TOMLValue {
        let value = kind.value(from: text)
        var scratch = Config()
        try apply(value, &scratch)
        return value
    }
}

extension Setting.Kind {

    /// `text` as the value this kind expects, or as a string when it cannot be read that way.
    func value(from text: String) -> TOMLValue {
        let text = Self.unquoted(text)
        switch self {
        case .toggle:
            return text == "true" || text == "false" ? .bool(text == "true") : .string(text)
        case .number:
            return Self.scalar(text)
        case .choice:
            return .string(text)
        case .sizeList:
            // `[0.5, 1]` is how the file writes a list and `0.5 1` is how a shell hands one over, so
            // the brackets are optional and either separator will do.
            var body = Substring(text)
            if body.first == "[", body.last == "]" { body = body.dropFirst().dropLast() }
            let elements = body.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            return .array(elements.map { Self.scalar(String($0)) })
        }
    }

    private static func scalar(_ text: String) -> TOMLValue {
        Double(text).map(TOMLValue.number) ?? .string(text)
    }

    /// A word with the quotes the file wants stripped off. The file spells a word `"adopt"`, and a
    /// shell eats those quotes on the way past — so the word arrives both ways and means the same one.
    private static func unquoted(_ text: String) -> String {
        guard let first = text.first, let last = text.last, text.count >= 2, first == last,
              first == "\"" || first == "'"
        else { return text }
        return String(text.dropFirst().dropLast())
    }
}

/// Every setting emira has, in the order it is read and the order it is shown.
public enum ConfigSchema {

    public static let settings: [Setting] = layout + focus + mouse + animation + springs + guide

    /// The setting spelled `key`, or `nil` when the schema has no such key — which the three sections
    /// it doesn't describe are also on the wrong side of: `[keys]` and `[[window-rules]]` are edited
    /// as blocks, not as one value at a time.
    public static func setting(for key: String) -> Setting? {
        settings.first { $0.key == key }
    }

    /// The `[table]`s the settings are written under. Declared-but-empty is legal, so the reader has to
    /// accept the header itself and not only the keys beneath it — `[layuot]` contributes no key.
    static let tables: Set<String> = Set(settings.map(\.table))

    /// The three surfaces the table cannot describe, in the order the document writes them.
    ///
    /// Every consumer that walks `settings` has to decide what to do about these, and before this list
    /// existed each of them decided by hand: the document placed three named constants, the coverage
    /// test spelled three fragments into a string, and the settings window did nothing at all — which
    /// is how `outer-gap` came to have no editor without anyone choosing that.
    public static let bespoke: [Bespoke] = [
        Bespoke(key: "layout.outer-gap",
                label: "Outer gaps",
                help: "Points held clear at the top, left, bottom and right of the working area.",
                section: .layout,
                after: "layout.window-gap",
                reason: "One value with five spellings: `outer-gap` sets all four edges and each "
                      + "`outer-gap-<side>` replaces one, so no single entry can carry it and no "
                      + "single default can describe it.",
                documentation: outerGapBlock,
                sample: "outer-gap = 7"),

        Bespoke(key: "keys",
                label: "Keys",
                help: "Chords bound to commands, spelled exactly as the CLI spells them.",
                section: .keys,
                after: nil,
                reason: "An open table: its key names are chords the file's author invents, so there "
                      + "is no fixed set of keys to enumerate.",
                documentation: keysBlock,
                sample: """
                [keys]
                alt-h = "focus left"
                """),

        Bespoke(key: "window-rules",
                label: "Window rules",
                help: "What happens to a window the first time emira meets it.",
                section: .windowRules,
                after: nil,
                reason: "Repeating, ordered and cross-validated: file order is precedence, and a rule "
                      + "is refused unless it both matches something and does something.",
                documentation: windowRulesBlock,
                sample: """
                [[window-rules]]
                app-id = "com.example.app"
                float = true
                """),
    ]

    // The prose the three carry into the generated document. Here rather than beside the renderer
    // because it is the *entry's* — a `Setting` carries its own sentence for the same reason, and a
    // block kept next to the code that prints it is a block that can be printed for a surface the
    // schema no longer has.

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
    #
    # `fn` (spell it `fn` or `globe`) works on letters, digits, punctuation and space. It does not work
    # on the arrows, the F-keys or home/end/page-up/page-down: macOS marks those with the fn flag even
    # when fn is not held, so `fn-left` would take the bare left arrow, and it is refused by name.
    [keys]

    alt-h = "focus left"
    alt-shift-h = "move-window left"
    cmd-alt-period = "center-column"
    alt-space = "exec ghostty"
    fn-h = "focus left"
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

    # A rule can also match on the shape of an arriving window rather than on anything it is called.
    # Here: a window both small relative to the focused one and opened by the same app.
    [[window-rules]]

    # Both dimensions must be smaller than this fraction of the focused window — if the focused window
    # is 2000x1000, an arriving window needs a width under 400 and a height under 200 to match.
    smaller-than-focused = 0.2
    # …and opened by the app that already had focus, so background apps don't count.
    from-focused-app = true
    float = true
    """

    private static let layout: [Setting] = [
        Setting("layout.column-gap", \.columnGap, .number(atLeast: 0, unit: .points),
                label: "Column gap", help: "Points between adjacent columns on the strip.",
                section: .layout),

        Setting("layout.window-gap", \.windowGap, .number(atLeast: 0, unit: .points),
                label: "Window gap", help: "Points between windows stacked in one column.",
                section: .layout),

        Setting("layout.center-focused-column", \.centerFocusedColumn, .toggle,
                label: "Center the focused column",
                help: "Center a focused column rather than scrolling the least that reveals it.",
                section: .layout),

        Setting("layout.resize-detent", \.resizeDetent, .toggle,
                label: "Resize detent",
                help: "Stop a grow or shrink where it meets the working area boundary; again to pass it.",
                section: .layout),

        Setting("layout.interactive-resize", \.interactiveResize, .toggle,
                label: "Interactive resize",
                help: "Keep the size a window is left at when resized by its own handle.",
                section: .layout),

        Setting("layout.width-presets", \.widthPresets, .sizeList,
                label: "Column widths", help: "The widths cycle-width steps through.",
                section: .layout),

        Setting("layout.height-presets", \.heightPresets, .sizeList,
                label: "Window heights",
                help: "The heights cycle-height steps through.",
                section: .layout),
    ]

    private static let focus: [Setting] = [
        Setting("focus.system-events", \.systemFocusEvents, .word,
                label: "System focus events",
                help: "Which focus changes emira did not cause it honours.", section: .focus),

        // Beside `system-events` rather than under `[mouse]`: it is another source of focus changes,
        // and what a reader needs to find is "the things that move focus".
        Setting("focus.follows-mouse", \.focusFollowsMouse, .toggle,
                label: "Focus follows the mouse",
                help: "Focus a window when the pointer crosses into it.",
                section: .focus),
    ]

    /// The pointer plane. `hide` is also a *capability* — the shell clamps it off when macOS cannot do
    /// what it asks for, exactly as it clamps `animation.transition` — while `follows-focus` is public
    /// API throughout and nothing clamps it.
    private static let mouse: [Setting] = [
        Setting("mouse.hide", \.hidesCursor, .toggle,
                label: "Hide the pointer",
                help: "Hide the cursor on events such as focus change.",
                section: .mouse),

        Setting("mouse.follows-focus", \.mouseFollowsFocus, .word,
                label: "Pointer follows focus",
                help: "Send the pointer after focus; except-hover skips a hover, lazy skips already "
                    + "inside.",
                section: .mouse),

        Setting("mouse.trackpad-scroll", \.trackpadScroll, .word,
                label: "Trackpad scroll",
                help: "Scroll the strip with a three-finger swipe; magnet settles on a column edge.",
                section: .mouse),

        Setting("mouse.trackpad-scroll-direction", \.trackpadScrollDirection, .word,
                label: "Trackpad scroll direction",
                help: "Which way a swipe carries the strip; natural moves the columns with your fingers.",
                section: .mouse),
    ]

    private static let animation: [Setting] = [
        Setting("animation.transition", \.transitionMode, .word,
                label: "Transition mode",
                help: "smooth for spring animations, snap for no motion, off to disable.",
                section: .animation),

        Setting("animation.hold-timeout", \.holdTimeout, .number(greaterThan: 0, unit: .seconds),
                label: "Hold timeout",
                help: "Maximum seconds a cover can stay up waiting for windows to adjust.",
                section: .animation, advanced: true),

        Setting("animation.window", \.windowAnimation, .word,
                label: "Window animation",
                help: "How a window's still is painted into a rect it no longer fits.",
                section: .animation),

        Setting("animation.cover", \.coverMode, .word,
                label: "Cover mode",
                help: "exact waits for current screenshots; immediate uses stale screenshots to begin sooner.",
                section: .animation),
    ]

    /// The two guides, a table each, of which the reducer reads one key. Labels are short because the
    /// group a row is written under says which guide it belongs to; `width` is a bare fraction, and one
    /// over 1 is clamped by the geometry rather than refused — `Bound` has floors and no ceilings.
    private static let guide: [Setting] = [
        Setting("guide.preview.enabled", \.guide.preview.enabled, .toggle,
                label: "Enabled", help: "Show a minimap of the strip when the desktop changes.",
                section: .guide),

        Setting("guide.preview.content", \.guide.preview.content, .word,
                label: "Content", help: "What each tile draws: window stills, or app icons.",
                section: .guide),

        guide(.position, of: "preview", \.guide.preview),
        guide(.width, of: "preview", \.guide.preview),

        Setting("guide.preview.span", \.guide.preview.span, .number(greaterThan: 0, unit: .bare),
                label: "Span",
                help: "The most screens of strip it shows at once; a shorter strip shrinks it.",
                section: .guide),

        guide(.gap, of: "preview", \.guide.preview),
        guide(.duration, of: "preview", \.guide.preview),

        Setting("guide.names.enabled", \.guide.names.enabled, .toggle,
                label: "Enabled", help: "Name the strip's columns when the desktop changes.",
                section: .guide),

        guide(.position, of: "names", \.guide.names),
        guide(.width, of: "names", \.guide.names),
        guide(.gap, of: "names", \.guide.names),
        guide(.duration, of: "names", \.guide.names),

        Setting("guide.names.font-size", \.guide.names.fontSize,
                .number(greaterThan: 0, unit: .points),
                label: "Font size",
                help: "The type size the names are set at, which is the guide's only length.",
                section: .guide),

        Setting("guide.names.lowercase", \.guide.names.lowercase, .toggle,
                label: "Lowercase", help: "Lowercase each app's name.", section: .guide),

        Setting("guide.names.max-columns", \.guide.names.maxColumns, .count(atLeast: 0),
                label: "Max columns",
                help: "The most columns named at once, the ends beyond them elided; 0 is the whole strip.",
                section: .guide),
    ]

    /// The keys every guide answers with the same sentence — where it sits, how much of the screen it
    /// may take, how far it is held off the edge, and how long it stays. `enabled` is not among them:
    /// both guides carry the key, and what a reader needs to know about it is which guide it turns on.
    private enum GuideKey: String {
        case position, width, gap, duration
    }

    /// One of those keys, asked of one guide's table. Written once and asked twice, for the springs'
    /// reason — and by key rather than by table, because the two guides are not the same shape: one
    /// draws pictures and the other sets type, so only `GuideTable` is common to both.
    private static func guide<Table: GuideTable>(
        _ key: GuideKey, of name: String,
        _ table: WritableKeyPath<Config, Table> & Sendable
    ) -> Setting {
        let dotted = "guide.\(name).\(key.rawValue)"
        switch key {
        case .position:
            return Setting(dotted, .word, label: "Position",
                           help: "Which corner or edge of the working area the guide sits at.",
                           section: .guide,
                           get: { $0[keyPath: table].position },
                           set: { $0[keyPath: table].position = $1 })
        case .width:
            return Setting(dotted, .number(greaterThan: 0, unit: .bare), label: "Width",
                           help: "The most of the working width the guide may take, as a fraction.",
                           section: .guide,
                           get: { $0[keyPath: table].width },
                           set: { $0[keyPath: table].width = $1 })
        case .gap:
            return Setting(dotted, .number(atLeast: 0, unit: .points), label: "Gap",
                           help: "Points held clear between the guide and the working area's edge.",
                           section: .guide,
                           get: { $0[keyPath: table].gap },
                           set: { $0[keyPath: table].gap = $1 })
        case .duration:
            return Setting(dotted, .number(atLeast: 0, unit: .seconds), label: "Duration",
                           help: "Seconds the guide stays up after the last thing that moved.",
                           section: .guide,
                           get: { $0[keyPath: table].duration },
                           set: { $0[keyPath: table].duration = $1 })
        }
    }

    /// The four spring tables, one sub-schema: they differ in which motion they drive and in nothing
    /// else, so four special cases would be four chances to fix a bug twice.
    private static let springs: [Setting] =
        spring("scroll", \.scrollSpring, "Scroll", "the viewport scroll")
        + spring("resize", \.resizeSpring, "Resize", "a column's width")
        + spring("movement", \.moveSpring, "Movement", "a window the strip rearranged")
        + spring("glide", \.glideSpring, "Glide", "a trackpad scroll after the lift")

    /// The two keys an `[animation.<motion>]` table carries.
    ///
    /// **A spring is spelled `(k, ζ)` here, so each key holds the other coordinate when it is written.**
    /// A file that stiffens the scroll and says nothing about damping means the spring it had, stiffer —
    /// not one whose `c` stood still while `ζ` fell off to a scroll that never settles.
    private static func spring(_ motion: String, _ field: WritableKeyPath<Config, SpringParams> & Sendable,
                               _ title: String, _ drives: String) -> [Setting] {
        let table = "animation.\(motion)"
        return [
            Setting("\(table).stiffness", .number(greaterThan: 0, unit: .bare),
                    label: "\(title) stiffness",
                    help: "Spring constant k for \(drives) — larger is stiffer, and faster.",
                    section: .animation, advanced: true,
                    get: { $0[keyPath: field].stiffness },
                    set: { config, stiffness in
                        let spring = config[keyPath: field]
                        config[keyPath: field] = SpringParams(stiffness: stiffness,
                                                              dampingRatio: spring.dampingRatio)
                    }),

            Setting("\(table).damping-ratio", .number(atLeast: 0, unit: .bare),
                    label: "\(title) damping ratio",
                    help: "ζ for \(drives) — 1 settles without overshoot, less overshoots.",
                    section: .animation, advanced: true,
                    get: { $0[keyPath: field].dampingRatio },
                    set: { config, ratio in
                        let spring = config[keyPath: field]
                        config[keyPath: field] = SpringParams(stiffness: spring.stiffness,
                                                              dampingRatio: ratio)
                    }),
        ]
    }
}

extension String {
    /// A clause as a sentence: capitalized, and ended. The schema's legends are written as fragments so
    /// they compose, and read as sentences wherever one is shown.
    fileprivate var asSentence: String { prefix(1).uppercased() + dropFirst() + "." }
}
