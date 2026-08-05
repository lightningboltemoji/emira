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
// cross-validated). Each is read by a function named for it in `ConfigSyntax.swift`, and each gets an
// editor of its own in the settings window — forcing them in here would produce a worse GUI, not a
// better schema.

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
    /// no entries on purpose: they are the two sections the table cannot describe, and naming them here
    /// is what keeps a window's list of sections one list rather than "the schema's, plus two".
    public enum Section: String, CaseIterable, Sendable {
        case layout, focus, mouse, animation, springs, guide, keys, windowRules

        public var title: String {
            switch self {
            case .layout:      return "Layout"
            case .focus:       return "Focus"
            case .mouse:       return "Mouse"
            case .animation:   return "Animation"
            case .springs:     return "Springs"
            case .guide:       return "Guide"
            case .keys:        return "Keys"
            case .windowRules: return "Window rules"
            }
        }
    }

    /// The dotted `[table]` the key is written under — everything before its last segment.
    var table: String {
        let segments = key.split(separator: ".")
        return segments.dropLast().joined(separator: ".")
    }

    /// The key as it is written *inside* its table, which is the only part a line carries.
    var name: String { String(key.split(separator: ".").last ?? "") }
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
                label: "Adopt a hand resize",
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

    /// The guide — six keys, of which the reducer reads one. `width` is a fraction and nothing else,
    /// deliberately not `sizeList`'s dual "≤ 1 is a fraction, more is points" reading: a scalar version
    /// of that unit would need a `Kind` case serving exactly one key, which the note on `Kind` names as
    /// the sign the table has stopped paying for itself. `Bound` has floors and no ceilings, so a width
    /// over 1 is clamped by the geometry rather than refused here — a stop, not a reversal.
    private static let guide: [Setting] = [
        Setting("guide.style", \.guide.style, .word,
                label: "Guide style", help: "What the guide draws for each window, or off.",
                section: .guide),

        Setting("guide.position", \.guide.position, .word,
                label: "Guide position",
                help: "Which corner or edge of the working area the guide sits at.", section: .guide),

        Setting("guide.width", \.guide.width, .number(greaterThan: 0, unit: .bare),
                label: "Guide width",
                help: "How wide the guide is at its longest, as a fraction of the working width.",
                section: .guide),

        Setting("guide.span", \.guide.span, .number(greaterThan: 0, unit: .bare),
                label: "Guide span",
                help: "The most screens of strip it shows at once; a shorter strip shrinks it.",
                section: .guide),

        Setting("guide.gap", \.guide.gap, .number(atLeast: 0, unit: .points),
                label: "Guide gap",
                help: "Points held clear between the guide and the working area's edge.",
                section: .guide),

        Setting("guide.duration", \.guide.duration, .number(atLeast: 0, unit: .seconds),
                label: "Guide duration",
                help: "Seconds the guide stays up after the last thing that moved.", section: .guide),
    ]

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
                    section: .springs, advanced: true,
                    get: { $0[keyPath: field].stiffness },
                    set: { config, stiffness in
                        let spring = config[keyPath: field]
                        config[keyPath: field] = SpringParams(stiffness: stiffness,
                                                              dampingRatio: spring.dampingRatio)
                    }),

            Setting("\(table).damping-ratio", .number(atLeast: 0, unit: .bare),
                    label: "\(title) damping ratio",
                    help: "ζ for \(drives) — 1 settles without overshoot, less overshoots.",
                    section: .springs, advanced: true,
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
