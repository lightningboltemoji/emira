import AppKit
import EmiraConfig

// One control per `Setting.Kind`, and **nothing here names a setting**. The schema already carries the
// rule this collects on — *one case per shape of control, never per setting* — so the panel is a fold
// over `ConfigSchema.settings` filtered by section, and adding an entry to the schema puts a correctly
// bounded, correctly explained control in the window with no edit to this file.
//
// Every control reports through one closure and reads through one `show`. A control never writes its own
// value back from that closure: the draft is the authority, and a control that trusted its own widget
// would drift from the file the moment an edit was refused.

/// A row of the panel: a view, and a way to be told what the draft holds.
///
/// The surface a bespoke editor shares with a schema-driven control — `OuterGapsControl` is one of
/// these and is not a `SettingControl`, because it has no `Setting` to be about.
@MainActor
protocol PanelRow: AnyObject {
    /// What this row is about, spelled the way the file spells it. A take is looked up by it, and it is
    /// what a hover reports.
    var key: String { get }
    /// The view to put in the panel — the whole row, label and all.
    var view: NSView { get }
    /// Show what the draft holds. Called on open, discard, reload, and after a refusal.
    func show(_ draft: Draft)
}

/// A row that is exactly one setting.
@MainActor
protocol SettingControl: PanelRow {
    var setting: Setting { get }
}

extension SettingControl {
    var key: String { setting.key }
}

/// Builds the control a setting's `kind` asks for. The one `switch` over `Setting.Kind` in the package,
/// so a new case is a compile error here and nowhere else.
@MainActor
enum ControlFactory {
    static func control(for setting: Setting,
                        onChange: @escaping @MainActor (Draft.Edit) -> Void,
                        onDrag: @escaping @MainActor (Bool) -> Void,
                        onHover: @escaping @MainActor (String) -> Void = { _ in })
        -> any SettingControl {
        let control: any SettingControl
        switch setting.kind {
        case .toggle:
            control = ToggleControl(setting: setting, onChange: onChange)
        case .number(let bound, let unit):
            control = NumberControl(setting: setting, bound: bound, unit: unit,
                                    onChange: onChange, onDrag: onDrag)
        case .choice(let words):
            control = ChoiceControl(setting: setting, words: words, onChange: onChange)
        case .sizeList:
            control = SizeListControl(setting: setting, onChange: onChange)
        }
        // Hovering a control puts that setting's take on the mock. Reported from the row rather than
        // the widget, so the whole line — label, sentence and all — is the target.
        (control.view as? RowView)?.onHover = { onHover(control.key) }
        return control
    }
}

/// A control's row, which knows when the pointer is over it.
///
/// **Only entering is reported.** Leaving holds the last take rather than reverting: nothing should move
/// because the pointer went somewhere on its way out of the panel.
@MainActor
final class RowView: NSView {
    var onHover: (@MainActor () -> Void)?

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
}

// The row every control is built on: the label, the help sentence, and a well on the right for whatever
// the setting's kind wants.

@MainActor
final class ControlRow {
    let view = RowView()
    private let label = NSTextField(labelWithString: "")
    private let help = NSTextField(labelWithString: "")

    /// Where the control itself goes — right-aligned, at a fixed column so a panel of mixed kinds reads
    /// as a table rather than as a ragged list.
    static let wellWidth: CGFloat = 260
    static let height: CGFloat = 46

    /// A row for a schema entry, which is where a label and a sentence come from when there is one.
    convenience init(_ setting: Setting, well: NSView) {
        self.init(label: setting.label, help: setting.help, well: well)
    }

    /// A row for anything with a name and a sentence — which a bespoke surface has and a `Setting` is
    /// not the only thing that can carry.
    init(label labelText: String, help helpText: String, well: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = labelText
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        help.stringValue = helpText
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.lineBreakMode = .byWordWrapping
        help.maximumNumberOfLines = 2
        help.translatesAutoresizingMaskIntoConstraints = false

        well.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        view.addSubview(help)
        view.addSubview(well)

        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),

            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: well.leadingAnchor, constant: -16),

            help.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            help.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),
            help.trailingAnchor.constraint(lessThanOrEqualTo: well.leadingAnchor, constant: -16),
            help.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -4),

            well.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            well.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            well.widthAnchor.constraint(equalToConstant: Self.wellWidth),
        ])
    }
}

// `.toggle`

@MainActor
final class ToggleControl: SettingControl {
    let setting: Setting
    var view: NSView { row.view }

    private let row: ControlRow
    private let control = NSSwitch()
    private let onChange: @MainActor (Draft.Edit) -> Void

    init(setting: Setting, onChange: @escaping @MainActor (Draft.Edit) -> Void) {
        self.setting = setting
        self.onChange = onChange
        // In a container so the switch sits at its natural size against the well's trailing edge rather
        // than stretching across it.
        let well = NSView()
        control.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(control)
        NSLayoutConstraint.activate([
            control.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            well.heightAnchor.constraint(equalTo: control.heightAnchor),
        ])
        row = ControlRow(setting, well: well)
        control.target = self
        control.action = #selector(flipped)
    }

    func show(_ draft: Draft) {
        control.state = draft.value(of: setting).spelled == "true" ? .on : .off
    }

    @objc private func flipped() {
        onChange(.setting(setting, .bool(control.state == .on)))
    }
}

// `.number(bound, unit)`

@MainActor
final class NumberControl: SettingControl {
    let setting: Setting
    var view: NSView { row.view }

    private let row: ControlRow
    private let slider = NSSlider()
    private let field = NSTextField()
    private let bound: Setting.Bound
    private let onChange: @MainActor (Draft.Edit) -> Void
    private let onDrag: @MainActor (Bool) -> Void

    init(setting: Setting, bound: Setting.Bound, unit: Setting.Unit,
         onChange: @escaping @MainActor (Draft.Edit) -> Void,
         onDrag: @escaping @MainActor (Bool) -> Void) {
        self.setting = setting
        self.bound = bound
        self.onChange = onChange
        self.onDrag = onDrag

        let (floor, ceiling) = Self.range(bound: bound, unit: unit, default: setting.defaultValue)
        slider.minValue = floor
        slider.maxValue = ceiling
        // Continuous, which is the whole point: the mock moves under the hand rather than on release.
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false

        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.translatesAutoresizingMaskIntoConstraints = false

        let well = NSView()
        well.addSubview(slider)
        well.addSubview(field)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            slider.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 58),
            well.heightAnchor.constraint(equalTo: field.heightAnchor),
        ])

        row = ControlRow(setting, well: well)
        slider.target = self
        slider.action = #selector(slid)
        field.target = self
        field.action = #selector(typed)
    }

    /// The span a slider covers. The schema gives a floor and never a ceiling — there is no largest
    /// legal gap — so the top of the slider is a *presentation* choice scaled off the default, and the
    /// field is what reaches past it. A slider that stopped at the largest sensible value would make
    /// the setting look bounded when it is not.
    private static func range(bound: Setting.Bound, unit: Setting.Unit,
                              default value: TOMLValue) -> (Double, Double) {
        let floor: Double
        switch bound {
        case .atLeast(let minimum):   floor = minimum
        case .greaterThan(let below): floor = below
        }
        let current = Double(value.spelled) ?? 0
        let ceiling: Double
        switch unit {
        case .points:  ceiling = max(floor + 40, current * 5)
        case .seconds: ceiling = max(floor + 2, current * 5)
        case .bare:    ceiling = max(floor + 1, current * 4)
        }
        return (floor, ceiling)
    }

    func show(_ draft: Draft) {
        let value = Double(draft.value(of: setting).spelled) ?? 0
        // A value typed past the slider's top stretches it rather than being clamped by it: the field is
        // the authority on what the setting is, and the slider is a handle on it.
        if value > slider.maxValue { slider.maxValue = value }
        slider.doubleValue = value
        // Never over the hand — `show` runs after every edit anywhere in the panel.
        guard field.currentEditor() == nil else { return }
        field.stringValue = TOMLValue.number(value).spelled
    }

    @objc private func slid() {
        let value = Self.rounded(slider.doubleValue, bound: bound)
        field.stringValue = TOMLValue.number(value).spelled
        onChange(.setting(setting, .number(value)))
        // `isContinuous` gives no phase, so the drag is bracketed by the event that started it.
        onDrag(NSApp.currentEvent?.type == .leftMouseDragged)
    }

    @objc private func typed() {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        // Handed over as text when it is not a number, so the schema refuses it in its own words. A
        // silent return would leave the user typing into a field that never answers.
        guard let value = Double(text) else { return onChange(.setting(setting, .string(text))) }
        onChange(.setting(setting, .number(value)))
    }

    /// Whole points and whole tenths elsewhere — a slider that produced `7.4183` would write that into
    /// the file, and no one means it.
    private static func rounded(_ value: Double, bound: Setting.Bound) -> Double {
        let step = (value.magnitude >= 10 ? 1.0 : 0.1)
        let snapped = (value / step).rounded() * step
        // Never below the floor, and never *on* an exclusive one.
        switch bound {
        case .atLeast(let minimum):
            return max(snapped, minimum)
        case .greaterThan(let below):
            return snapped > below ? snapped : below + step
        }
    }
}

// `.choice([String])`

@MainActor
final class ChoiceControl: SettingControl {
    let setting: Setting
    var view: NSView { row.view }

    private let row: ControlRow
    private let words: [String]
    private let segmented: NSSegmentedControl?
    private let popUp: NSPopUpButton?
    private let onChange: @MainActor (Draft.Edit) -> Void

    /// Segments up to four words, a pop-up beyond — past that the segments are too narrow to read and
    /// the row stops looking like a row.
    static let segmentLimit = 4

    init(setting: Setting, words: [String],
         onChange: @escaping @MainActor (Draft.Edit) -> Void) {
        self.setting = setting
        self.words = words
        self.onChange = onChange

        let well = NSView()
        if words.count <= Self.segmentLimit {
            let control = NSSegmentedControl(labels: words, trackingMode: .selectOne,
                                             target: nil, action: nil)
            control.segmentDistribution = .fillEqually
            control.translatesAutoresizingMaskIntoConstraints = false
            segmented = control
            popUp = nil
            well.addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: well.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: well.trailingAnchor),
                control.centerYAnchor.constraint(equalTo: well.centerYAnchor),
                well.heightAnchor.constraint(equalTo: control.heightAnchor),
            ])
        } else {
            let control = NSPopUpButton()
            control.addItems(withTitles: words)
            control.translatesAutoresizingMaskIntoConstraints = false
            popUp = control
            segmented = nil
            well.addSubview(control)
            NSLayoutConstraint.activate([
                control.trailingAnchor.constraint(equalTo: well.trailingAnchor),
                control.centerYAnchor.constraint(equalTo: well.centerYAnchor),
                well.heightAnchor.constraint(equalTo: control.heightAnchor),
            ])
        }
        row = ControlRow(setting, well: well)
        segmented?.target = self
        segmented?.action = #selector(picked)
        popUp?.target = self
        popUp?.action = #selector(picked)
    }

    func show(_ draft: Draft) {
        // The file spells a word in quotes; the vocabulary does not.
        let spelled = draft.value(of: setting).spelled.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard let index = words.firstIndex(of: spelled) else { return }
        segmented?.selectedSegment = index
        popUp?.selectItem(at: index)
    }

    @objc private func picked() {
        let index = segmented?.selectedSegment ?? popUp?.indexOfSelectedItem ?? -1
        guard words.indices.contains(index) else { return }
        onChange(.setting(setting, .string(words[index])))
    }
}

// `.sizeList`

@MainActor
final class SizeListControl: SettingControl {
    let setting: Setting
    var view: NSView { row.view }

    private let row: ControlRow
    private let field = NSTextField()
    private let onChange: @MainActor (Draft.Edit) -> Void

    init(setting: Setting, onChange: @escaping @MainActor (Draft.Edit) -> Void) {
        self.setting = setting
        self.onChange = onChange

        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        // The entry's own default, spelled the way the field spells one. Written out here it would be a
        // second copy of `PresetCycle.defaultWidths` — and it was, at two decimal places, for a cycle
        // whose first rung is a third.
        field.placeholderString = Self.list(setting.defaultValue)
        field.translatesAutoresizingMaskIntoConstraints = false

        let well = NSView()
        well.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            well.heightAnchor.constraint(equalTo: field.heightAnchor),
        ])
        row = ControlRow(setting, well: well)
        field.target = self
        field.action = #selector(typed)
    }

    func show(_ draft: Draft) {
        // Never over the hand: writing `stringValue` into a field being edited resets the insertion
        // point, and `show` runs after *every* edit anywhere in the panel.
        guard field.currentEditor() == nil else { return }
        // `shown` is remembered so a commit that changed nothing writes nothing: without that, clicking
        // in and out of the field would round the file's own numbers.
        let spelled = Self.list(draft.value(of: setting))
        field.stringValue = spelled
        shown = spelled
    }

    /// What `show` last put in the field, so an untouched commit is a no-op.
    private var shown = ""

    /// `[0.33, 0.5, 0.67]` as the file writes it, shown without its brackets — and **shortened**,
    /// because a third spells as `0.3333333333333333` and seventeen digits of it fill the field three
    /// times over.
    private static func list(_ value: TOMLValue) -> String {
        value.spelled
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .map { short($0.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: ", ")
    }

    /// A number at four decimal places, with trailing zeros dropped. Enough to spell a third, a half
    /// and two thirds distinguishably, and short enough to read three of them at once.
    private static func short(_ text: String) -> String {
        guard let value = Double(text) else { return text }
        return TOMLValue.number((value * 10_000).rounded() / 10_000).spelled
    }

    @objc private func typed() {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard text != shown else { return }

        let tokens = text.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let numbers = tokens.compactMap(Double.init)

        // **All of it or none of it.** `compactMap` alone would silently drop whatever did not parse,
        // so `1/3, 0.5` would quietly become a one-rung cycle — worse than a refusal, because the file
        // would change to something the user never asked for.
        //
        // A list with something unreadable in it is still handed over **as a list**, with the offending
        // token left as text. The schema then refuses the *element* — "must be a number, not a string"
        // — rather than the whole value's type, which is the difference between a sentence about what
        // was typed and one about TOML.
        guard !tokens.isEmpty, numbers.count == tokens.count else {
            return onChange(.setting(setting, .array(tokens.map { Double($0).map(TOMLValue.number) ?? .string($0) })))
        }
        onChange(.setting(setting, .array(numbers.map { .number($0) })))
    }
}
