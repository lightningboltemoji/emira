import AppKit
import EmiraConfig
import EmiraCore

// The `[keys]` editor — the second of the three surfaces `ConfigSchema` cannot describe, and the one
// whose absence used to be written down as a reason.
//
// **One `PanelRow` for the whole surface, owning its own list.** Not one row per binding: the slab
// rebuilds its rows only when the section changes, so a list whose length moves under `show(draft)`
// would either need a new callback into the slab or would throw away the control under the cursor on
// every edit. This reconciles its own children instead, so `show(_:)` stays the single downward path.
//
// **The draft is still the authority.** A bubble never writes its own widget from its own callback; it
// reports an edit and waits to be told. The one thing decided here rather than there is what may be
// *offered*: a chord already bound elsewhere in the table is refused before it reaches the draft,
// because `[keys]` reads two spellings of one chord as one hotkey and would refuse the whole edit with
// a sentence at the bottom of the slab — which is a long way from the two bubbles that disagree.

/// `[keys]`, as a list of bindings you can edit.
@MainActor
final class KeysEditor: PanelRow {
    let key: String
    var view: NSView { container }

    /// Nothing is bound by default, deliberately — so the empty state is the surface's first sentence
    /// rather than a blank panel. The words are `ConfigSchema.keysBlock`'s own.
    static let emptyState = """
    Nothing is bound yet. Registering a hotkey takes that chord from every other app on the machine, \
    so emira binds none of them until you say so.
    """

    private let container = RowView()
    private let empty = NSTextField(labelWithString: KeysEditor.emptyState)
    private let list = NSStackView()
    private let add = NSButton()

    private let onChange: @MainActor (Draft.Edit) -> Void
    private let onHover: @MainActor (String) -> Void

    /// The rows on screen, in file order. Readable so a test can ask what the panel actually built.
    private(set) var rows: [BindingRow] = []
    /// The half-built binding, if one is open. Not in the draft and deliberately not: a binding with a
    /// chord and no command is not something `[keys]` can hold, and bending the panel's invariant to
    /// carry one would be bending it for the one row that is not yet a row.
    private(set) var composer: BindingRow?

    /// Every chord the draft carries, for the conflict check — read on `show` so it is the file's own
    /// answer rather than one accumulated here.
    private var bound: [KeyChord] = []

    /// Where each bound chord is *written*, which is not `"keys.\(chord)"`.
    ///
    /// **The table's names are chords, and a chord has more than one spelling.** `cmd-alt-h` and
    /// `alt-cmd-h` are one hotkey and two TOML keys, and so are `option-l` and `alt-l`; the modifiers
    /// may even follow the key. An edit keyed canonically asks the document to change a line the file
    /// does not carry, and a document leaves a key it cannot find alone — so ⊖ and a retyped chord
    /// would do nothing at all, silently. Read from the file on every `show`.
    private var written: [KeyChord: String] = [:]

    init(surface: Bespoke, onChange: @escaping @MainActor (Draft.Edit) -> Void,
         onHover: @escaping @MainActor (String) -> Void = { _ in }) {
        self.key = surface.key
        self.onChange = onChange
        self.onHover = onHover

        container.translatesAutoresizingMaskIntoConstraints = false

        empty.font = .systemFont(ofSize: 11)
        empty.textColor = .secondaryLabelColor
        empty.lineBreakMode = .byWordWrapping
        empty.maximumNumberOfLines = 3
        empty.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(empty)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = BindingRow.spacing
        list.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(list)

        // The `⊖` a row carries, the other way up — one affordance, so the pair reads as the list's
        // two ends rather than as two unrelated buttons.
        add.title = "Add a binding"
        add.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        // **The panel's own button, not an inline pill.** `.inline` sizes itself to the text with no
        // room either side of a symbol, so `⊕Add a binding` reads as one word; `.rounded` is what
        // Discard and Save wear, and its padding is AppKit's rather than a number guessed here.
        add.bezelStyle = .rounded
        add.controlSize = .small
        add.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(add)

        // **Collapsed rather than merely hidden.** `isHidden` on a label leaves its height behind, and
        // what that costs is a band of dead space above the first binding on every populated file —
        // the same trick, and the same reason, as the slab's changed-underneath-you banner. The gap
        // under it collapses with it, or the sentence's absence still costs eight points.
        emptyHeight = empty.heightAnchor.constraint(equalToConstant: 0)
        addGap = add.topAnchor.constraint(equalTo: empty.bottomAnchor, constant: 0)
        // **Above the list, not under it.** A populated file is taller than the viewport and the panel
        // is one height for every tab, so a button after the last row is one nobody can reach — it was
        // 226 pt below the fold on eight bindings. Above them it is where the tab opens, and the row it
        // opens is stacked directly beneath it — a binding not yet in the file has no place in file
        // order, and a control whose result lands at the far end of a scrolling list is one nobody
        // connects to what they just clicked.
        NSLayoutConstraint.activate([
            empty.topAnchor.constraint(equalTo: container.topAnchor),
            empty.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            addGap,
            add.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            list.topAnchor.constraint(equalTo: add.bottomAnchor, constant: 10),
            list.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        add.target = self
        add.action = #selector(addPressed)
    }

    /// Zero while there is something to show, and off while there is not.
    private var emptyHeight: NSLayoutConstraint!
    /// The space between the sentence and the button, which is nothing when there is no sentence.
    private var addGap: NSLayoutConstraint!

    /// Raise or collapse the empty state.
    private func showEmptyState(_ shown: Bool) {
        empty.isHidden = !shown
        emptyHeight.isActive = !shown
        addGap.constant = shown ? 8 : 0
    }

    /// Show what the draft holds — the bindings it carries, in file order.
    func show(_ draft: Draft) {
        let bindings = draft.config.keys
        bound = bindings.map(\.chord)
        written = Dictionary(
            draft.names(under: "keys").compactMap { name in
                (try? KeyChord.parse(name)).map { ($0, "keys.\(name)") }
            }, uniquingKeysWith: { first, _ in first })
        reconcile(bindings)
        showEmptyState(bindings.isEmpty && composer == nil)
    }

    /// The key a chord is written at: its own spelling where the file has one, and the canonical
    /// spelling for a binding the file does not carry yet — which is the only one a *new* binding has.
    private func key(for chord: KeyChord) -> String {
        written[chord] ?? "keys.\(chord)"
    }

    // Reconciliation
    //
    // **Chord first, then position.** A binding whose chord is unchanged keeps its row outright, which
    // is what makes an edit to one row leave every other row's controls exactly as they were. What is
    // left over is matched in order, so a chord *retyped* keeps its row too — the alternative is a row
    // destroyed and rebuilt under the hand at the exact moment the user is looking at it.

    private func reconcile(_ bindings: [KeyBinding]) {
        var spare = rows
        var matched = [BindingRow?](repeating: nil, count: bindings.count)

        // Pass one: the rows whose chord did not move.
        for (index, binding) in bindings.enumerated() {
            guard let found = spare.firstIndex(where: { $0.chord == binding.chord }) else { continue }
            matched[index] = spare.remove(at: found)
        }
        // Pass two: whatever is left, in order — a chord *retyped*, which is one row and not two.
        for index in bindings.indices where matched[index] == nil {
            matched[index] = spare.isEmpty ? nil : spare.removeFirst()
        }

        rows = zip(bindings, matched).map { binding, existing in
            let row = existing ?? makeRow()
            row.show(binding)
            return row
        }
        restack()
    }

    private func makeRow() -> BindingRow {
        let row = BindingRow()
        row.onChord = { [weak self, weak row] chord in self?.chordTyped(chord, on: row) }
        row.onSpelling = { [weak self, weak row] spelling in self?.commandPicked(spelling, on: row) }
        row.onRemove = { [weak self, weak row] in self?.removePressed(row) }
        row.onHover = { [weak self, weak row] in
            guard let self, let row, let chord = row.chord else { return }
            onHover(key(for: chord))
        }
        return row
    }

    /// Put the rows in the stack — the half-built one if there is one, then the bound ones.
    ///
    /// **Reordered, never rebuilt.** Taking a view out of the hierarchy ends any editing session inside
    /// it; `insertArrangedSubview(_:at:)` moves one that is already arranged without taking it out. Only
    /// an arriving row is constrained — one that never left still carries its width.
    private func restack() {
        let wanted = ([composer].compactMap { $0 } + rows).map(\.view)
        guard wanted != list.arrangedSubviews else { return }
        for view in list.arrangedSubviews where !wanted.contains(view) {
            view.removeFromSuperview()
        }
        for (index, view) in wanted.enumerated() {
            let arrived = view.superview == nil
            guard arrived || list.arrangedSubviews.firstIndex(of: view) != index else { continue }
            list.insertArrangedSubview(view, at: index)
            guard arrived else { continue }
            view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    // What a row asks for

    /// A chord was typed or clicked together. **Refused here when another row already holds it**, since
    /// `cmd-alt-h` and `alt-cmd-h` are two TOML keys and one hotkey — detected on `KeyChord`, which is
    /// `Hashable` for exactly this, and marked on both bubbles rather than as a sentence at the foot of
    /// the panel a long way from either of them.
    private func chordTyped(_ chord: KeyChord, on row: BindingRow?) {
        guard let row else { return }
        let clash = rows.first { $0 !== row && $0.chord == chord }
        guard clash == nil else {
            row.markConflict(true)
            clash?.markConflict(true)
            return
        }
        for other in rows { other.markConflict(false) }

        if row === composer {
            composer?.take(chord: chord)
            commitComposerIfComplete()
            return
        }
        guard let old = row.chord, old != chord else { return }
        onChange(.rename(key(for: old), to: "keys.\(chord)"))
    }

    private func commandPicked(_ spelling: String, on row: BindingRow?) {
        guard let row else { return }
        if row === composer {
            composer?.take(spelling: spelling)
            commitComposerIfComplete()
            return
        }
        guard let chord = row.chord else { return }
        onChange(.key(key(for: chord), .string(spelling)))
    }

    private func removePressed(_ row: BindingRow?) {
        guard let row else { return }
        if row === composer {
            // Said rather than left to deallocation: the monitor comes out when the row it belongs to
            // is discarded, not whenever the last reference to it happens to go.
            row.stopListening()
            composer = nil
            restack()
            showEmptyState(rows.isEmpty)
            return
        }
        guard let chord = row.chord else { return }
        onChange(.unset(key(for: chord)))
    }

    // The composer

    @objc private func addPressed() {
        guard composer == nil else {
            reveal(composer)
            composer?.record()
            return
        }
        let row = makeRow()
        row.beginComposing()
        composer = row
        showEmptyState(false)
        restack()
        reveal(row)
        row.record()
    }

    /// Bring a row into view. The list is what scrolls, so where a row sits in it is the whole of whether
    /// it is on screen — and a row that opens *listening* below the fold is a user pressing keys at
    /// something they cannot see.
    private func reveal(_ row: BindingRow?) {
        guard let row else { return }
        row.view.enclosingScrollView?.documentView?.layoutSubtreeIfNeeded()
        row.view.scrollToVisible(row.view.bounds)
    }

    /// A half-built binding reaches the draft only when it is a whole one. Until then it exists here and
    /// nowhere else, which is what keeps the draft from ever holding a binding `[keys]` cannot express.
    private func commitComposerIfComplete() {
        guard let row = composer, let chord = row.chord, let spelling = row.spelling else { return }
        guard !bound.contains(chord) else { return row.markConflict(true) }
        composer = nil
        // **The half-built row becomes the built one.** Handed to `rows` before the edit travels, so
        // reconciliation matches it by chord rather than finding a binding no row holds and building a
        // fresh one — which would throw away the control under the hand at the moment the work is done.
        rows.append(row)
        restack()
        onChange(.key("keys.\(chord)", .string(spelling)))
        // It opened under the button and it lands where the file puts it, which on a populated file is
        // the far end of the list. Followed rather than left for the eye to find.
        reveal(row)
    }
}

// One binding: the chord, the command, and the sentence the verb carries.
//
// Two capsules reading as one phrase, and a `RowView` around them so the mock can be told which binding
// the hand is on — the pattern `OuterGapsControl` already uses for its four edges.

@MainActor
final class BindingRow {
    static let spacing: CGFloat = 10

    var view: NSView { row }

    var onChord: (@MainActor (KeyChord) -> Void)?
    var onSpelling: (@MainActor (String) -> Void)?
    var onRemove: (@MainActor () -> Void)?
    var onHover: (@MainActor () -> Void)? {
        get { row.onHover }
        set { row.onHover = newValue }
    }

    /// The chord this row is about, or `nil` while it is being composed.
    private(set) var chord: KeyChord?
    /// The command as the file would spell it, or `nil` while the composer has no verb yet.
    private(set) var spelling: String?

    private let row = RowView()
    private let chordBubble = ChordBubble()
    private let commandBubble = CommandBubble()
    private let summary = NSTextField(labelWithString: "")
    private let remove = NSButton()
    /// What the sentence says when nothing is being recorded — the verb's own, or the composer's
    /// invitation. Held so the bubble can borrow the line and hand it back.
    private var resting = ""

    init() {
        row.translatesAutoresizingMaskIntoConstraints = false

        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.translatesAutoresizingMaskIntoConstraints = false

        remove.image = NSImage(systemSymbolName: "minus.circle",
                               accessibilityDescription: "Remove this binding")
        remove.bezelStyle = .accessoryBar
        remove.isBordered = false
        remove.translatesAutoresizingMaskIntoConstraints = false

        for child in [chordBubble, commandBubble, summary, remove] as [NSView] {
            row.addSubview(child)
        }

        NSLayoutConstraint.activate([
            chordBubble.topAnchor.constraint(equalTo: row.topAnchor),
            chordBubble.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            chordBubble.widthAnchor.constraint(equalToConstant: ChordBubble.width),

            commandBubble.topAnchor.constraint(equalTo: row.topAnchor),
            commandBubble.leadingAnchor.constraint(equalTo: chordBubble.trailingAnchor, constant: 10),
            commandBubble.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -8),
            commandBubble.heightAnchor.constraint(equalTo: chordBubble.heightAnchor),

            remove.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: chordBubble.centerYAnchor),

            summary.topAnchor.constraint(equalTo: chordBubble.bottomAnchor, constant: 3),
            summary.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            summary.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            summary.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

        chordBubble.onChord = { [weak self] chord in self?.onChord?(chord) }
        // The sentence under the row is the only place with room to say what listening means, so the
        // bubble borrows it and gives it back.
        chordBubble.onListening = { [weak self] listening, sentence in
            self?.summary.stringValue = listening ? sentence : (self?.resting ?? "")
        }
        commandBubble.onSpelling = { [weak self] spelling in self?.onSpelling?(spelling) }
        remove.target = self
        remove.action = #selector(removePressed)
    }

    /// Show a binding the draft carries.
    func show(_ binding: KeyBinding) {
        chord = binding.chord
        spelling = binding.spelling
        chordBubble.show(binding.chord)
        commandBubble.show(binding.spelling)
        resting = commandBubble.summary
        summary.stringValue = resting
        markConflict(false)
    }

    /// Open as the half-built row: visibly not a binding yet, and holding a `⊖` that discards it rather
    /// than unsetting anything.
    func beginComposing() {
        chord = nil
        spelling = nil
        chordBubble.show(nil)
        commandBubble.show(nil)
        // **Both ways in, named.** This is the sentence a user meets the feature through, and the chips
        // are the less discoverable of the two paths.
        resting = "Press a combination, or build one from the chips — then pick what it does."
        summary.stringValue = resting
        remove.toolTip = "Discard"
    }

    /// The composer took a chord.
    func take(chord: KeyChord) {
        self.chord = chord
        chordBubble.show(chord)
        markConflict(false)
    }

    /// The composer took a command.
    func take(spelling: String) {
        self.spelling = spelling
        commandBubble.show(spelling)
        resting = commandBubble.summary
        summary.stringValue = resting
    }

    /// Put the chord bubble into its recording state.
    func record() { chordBubble.record() }

    /// Take it back out — what discarding a half-built row does.
    func stopListening() { chordBubble.stopListening() }

    /// Whether this row's chord bubble is listening for a press.
    var isListening: Bool { chordBubble.isListening }

    /// Edge the chord bubble — two rows, one hotkey. **The sentence comes back with the edge**: a row
    /// whose clash was resolved on another row keeps no draft round trip to restore it, so unmarking
    /// has to say what the row said before.
    func markConflict(_ marked: Bool) {
        chordBubble.markConflict(marked)
        summary.stringValue = marked ? "That combination is already bound." : resting
    }

    @objc private func removePressed() { onRemove?() }
}

// The chord half
//
// **Modifier chips, not dropdowns.** `KeyModifiers` is an `OptionSet`, so the modifiers are a *set* and
// four independent toggles is the honest control — four dropdowns each saying on/off would be the wrong
// control four times over. The order is not this file's to pick: `KeyModifiers.canonical` already fixes
// it at macOS's own 🌐⌃⌥⇧⌘. The key is the one real choice, so it gets the popup.
//
// **Recording is a state of the bubble, not a widget beside it** — and it is a state the bubble wears
// rather than one it disappears into. The chips and the key popup stay up and stay live the whole time,
// so a chord is *always* reachable two ways: press it, or build it by hand. A capsule that replaced
// itself with "Press a combination" foreclosed the second one at exactly the moment the user first meets
// it, which is the wrong half to hide — recording is the shortcut, and clicking is the floor.
//
// What listening looks like is the edge: an accent border, breathing, and the dot filled. Touching a
// chip or the popup ends it, because the hand has answered the question the recorder was asking — and
// because a press arriving afterwards would overwrite what was just clicked.

/// A key combination, editable by hand or by pressing one.
@MainActor
final class ChordBubble: NSView {
    /// Wide enough for five chips, the key popup and the record dot — measured against the panel
    /// rather than guessed, since a bubble a few points short hides the dot behind the popup.
    static let width: CGFloat = 296
    static let height: CGFloat = 30
    /// One modifier chip. Square enough that five of them read as a row of keycaps.
    static let chipWidth: CGFloat = 24

    var onChord: (@MainActor (KeyChord) -> Void)?
    /// Whether the bubble is listening, and what to say while it is — the row puts it under the chips,
    /// which is the only place with room for a sentence.
    var onListening: (@MainActor (Bool, String) -> Void)?

    /// The bubble currently listening, if any. Starting one stops the other, so two rows cannot both
    /// be swallowing keystrokes — the recorder is a *local* monitor and two of them would race.
    private static weak var listening: ChordBubble?

    private let chips: [(modifier: KeyModifiers, button: NSButton)]
    private let keyPopUp = PressReportingPopUpButton()
    private let dot = NSButton()
    private let recorder = ChordRecorder()

    /// The keys the popup offers, in the order it offers them — the index it answers with is an index
    /// into this, never into `Key.allCases`, since the popup carries separators and headings too.
    private var offered: [Key?] = []
    private var modifiers: KeyModifiers = []
    private var key: Key?

    override init(frame: NSRect) {
        chips = KeyModifiers.canonical.map { entry in
            let button = NSButton(title: Keycap.glyph(for: entry.modifier), target: nil, action: nil)
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.toolTip = entry.word
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: ChordBubble.chipWidth).isActive = true
            return (entry.modifier, button)
        }
        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = SettingsStyle.slabEdge
        translatesAutoresizingMaskIntoConstraints = false

        buildKeyPopUp()
        keyPopUp.controlSize = .small
        keyPopUp.translatesAutoresizingMaskIntoConstraints = false
        keyPopUp.widthAnchor.constraint(equalToConstant: 118).isActive = true

        dot.bezelStyle = .accessoryBar
        dot.isBordered = false
        dot.translatesAutoresizingMaskIntoConstraints = false

        let well = NSStackView(views: chips.map(\.button) + [keyPopUp])
        well.orientation = .horizontal
        well.spacing = 2
        well.alignment = .centerY
        well.translatesAutoresizingMaskIntoConstraints = false
        addSubview(well)
        addSubview(dot)

        self.well = well
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            well.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            well.centerYAnchor.constraint(equalTo: centerYAnchor),
            well.trailingAnchor.constraint(equalTo: dot.leadingAnchor, constant: -6),

            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        for chip in chips {
            chip.button.target = self
            chip.button.action = #selector(chipFlipped)
        }
        refreshDot(listening: false)
        keyPopUp.target = self
        keyPopUp.action = #selector(keyPicked)
        // **On the way down, not on selection.** The menu runs its own event loop, so a recorder still
        // installed while it is open would be swallowing the arrow keys used to walk it.
        keyPopUp.onPress = { [weak self] in self?.handTookOver() }
        dot.target = self
        dot.action = #selector(dotPressed)
    }

    private var well: NSStackView!

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    convenience init() { self.init(frame: .zero) }

    /// The popup: six headings, and under each the keys of that group. A flat list of ninety is one
    /// nobody can find anything in.
    private func buildKeyPopUp() {
        keyPopUp.removeAllItems()
        offered = []
        // The rung a bubble with no key yet sits on. Removed the moment there is one, so a finished
        // chord never offers "no key" as a thing to go back to.
        keyPopUp.menu?.addItem(withTitle: "Key…", action: nil, keyEquivalent: "")
        offered.append(nil)
        for (group, keys) in Keycap.groups {
            keyPopUp.menu?.addItem(.separator())
            offered.append(nil)
            let heading = NSMenuItem(title: group.rawValue, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            keyPopUp.menu?.addItem(heading)
            offered.append(nil)
            for key in keys {
                keyPopUp.menu?.addItem(withTitle: Keycap.label(for: key), action: nil, keyEquivalent: "")
                offered.append(key)
            }
        }
    }

    /// Show a chord, or `nil` for a bubble that has not got one yet. **Never emits**: this is the
    /// downward path, and a control that reported its own `show` would loop.
    func show(_ chord: KeyChord?) {
        stopRecording()
        modifiers = chord?.modifiers ?? []
        key = chord?.key
        refreshChips()
        keyPopUp.selectItem(at: offered.firstIndex(of: key) ?? 0)
    }

    /// The chips against `modifiers`. **Tinted as well as toggled**: AppKit's recessed on-state is one
    /// shade apart from its off-state, which at chip size is a difference nobody can see across a list
    /// of eight bindings — and which modifiers a chord carries is the first thing the row has to say.
    ///
    /// **One rendering path, and the colour is the system's.** The glyph is coloured through
    /// `attributedTitle`, which is why every chip is text: `contentTintColor` reaches a template *image*
    /// and never a title, so a drawn chip among spelled ones is a chip that answers a different question
    /// about the theme. `Keycap.glyph(for:)` is where that decision is written down.
    ///
    /// **The held chip's ink is not the accent.** A recessed button in its on state is drawn by AppKit
    /// with an *accent-coloured fill*, so an accent glyph on top of it is a solid blue rectangle with
    /// nothing legible in it. `alternateSelectedControlTextColor` is the system's own answer to "text on
    /// an emphasized background", and it resolves to the readable side in both appearances.
    ///
    /// The fill is what says a modifier is held, and it says it far louder than a hue ever did.
    ///
    /// **Unheld is `secondaryLabelColor`, not `tertiary`.** A modifier that is not in the chord is still
    /// a label to be read, and tertiary over a dark chip on a dark panel is a glyph you have to hunt for.
    private func refreshChips() {
        for chip in chips {
            let held = modifiers.contains(chip.modifier)
            let ink: NSColor = held ? .alternateSelectedControlTextColor : .secondaryLabelColor
            chip.button.state = held ? .on : .off
            chip.button.attributedTitle = NSAttributedString(
                string: Keycap.glyph(for: chip.modifier),
                attributes: [.foregroundColor: ink,
                             .font: NSFont.systemFont(ofSize: 12,
                                                      weight: held ? .semibold : .regular)])
        }
    }

    /// Edge the bubble — this chord is one another row already holds.
    func markConflict(_ marked: Bool) {
        layer?.borderColor = marked ? NSColor.systemRed.cgColor : SettingsStyle.slabEdge
        layer?.borderWidth = marked ? 2 : 1
    }

    // Recording

    /// What the row says under the chips while the bubble is listening. Names **both** ways in, because
    /// this is the sentence a user meets the feature through and the manual one is the less discoverable
    /// of the two.
    static let listeningPrompt = "Press a combination — or build one from the chips."

    /// Start listening. The edge takes it up; the controls stay where they are and stay usable.
    func record() {
        guard Self.listening !== self else { return }
        Self.listening?.stopRecording()
        Self.listening = self

        refreshDot(listening: true)
        pulse(true)
        onListening?(true, Self.listeningPrompt)

        recorder.start { [weak self] reading in self?.took(reading) }
    }

    /// Whether this bubble is listening for a press.
    var isListening: Bool { recorder.isListening }

    /// Stop listening from outside — what a row cancelling a composer does.
    func stopListening() { stopRecording() }

    /// Stop listening, whatever ended it — a press, a hand on a chip, another bubble, or a second click
    /// on the dot. Idempotent, so every one of those paths can just say so.
    private func stopRecording() {
        guard recorder.isListening else { return }
        recorder.stop()
        if Self.listening === self { Self.listening = nil }
        refreshDot(listening: false)
        pulse(false)
        onListening?(false, "")
    }

    /// **The hand has answered.** Touching a chip or the popup ends the recording rather than racing it:
    /// a press arriving afterwards carries whatever modifiers are physically held and would overwrite
    /// what was just clicked, which reads as the control undoing itself.
    private func handTookOver() { stopRecording() }

    /// A press. A chord is taken and reported; a refusal is said under the row and the bubble goes on
    /// listening, because the user is still trying to bind something.
    private func took(_ reading: ChordRecorder.Reading) {
        guard case .chord(let chord) = reading else {
            onListening?(true, reading.refusal ?? Self.listeningPrompt)
            return
        }
        stopRecording()
        show(chord)
        onChord?(chord)
    }

    /// The dot: hollow at rest, filled and accented while listening. The one part of the capsule that
    /// changes shape, so the state is readable without waiting for the border to breathe.
    private func refreshDot(listening: Bool) {
        dot.image = NSImage(systemSymbolName: listening ? "record.circle.fill" : "record.circle",
                            accessibilityDescription: "Record a combination")
        dot.contentTintColor = listening ? .controlAccentColor : .secondaryLabelColor
        dot.toolTip = listening ? "Stop recording" : "Record a combination"
    }

    /// The accent edge, breathing. Under 120 ms would be a flicker; this is a heartbeat.
    private func pulse(_ on: Bool) {
        guard on else {
            layer?.removeAnimation(forKey: "recording")
            markConflict(false)
            return
        }
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        let breath = CABasicAnimation(keyPath: "borderColor")
        breath.fromValue = NSColor.controlAccentColor.cgColor
        breath.toValue = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        breath.duration = 0.7
        breath.autoreverses = true
        breath.repeatCount = .infinity
        layer?.add(breath, forKey: "recording")
    }

    // Editing by hand

    @objc private func chipFlipped(_ sender: NSButton) {
        handTookOver()
        guard let chip = chips.first(where: { $0.button === sender }) else { return }
        if sender.state == .on { modifiers.insert(chip.modifier) } else { modifiers.remove(chip.modifier) }
        refreshChips()
        compose()
    }

    @objc private func keyPicked() {
        let index = keyPopUp.indexOfSelectedItem
        guard offered.indices.contains(index), let picked = offered[index] else { return }
        key = picked
        compose()
    }

    /// Report the chord, when there is one. Modifiers alone are not a chord and never travel: the file
    /// says so (`KeyChordSyntaxError.noKey`) and so does this.
    private func compose() {
        guard let key else { return }
        // The fn flag cannot qualify a function-class key — macOS reports it on those whether or not fn
        // is held — so the chip is dropped rather than composing a chord the file refuses by name.
        var modifiers = self.modifiers
        if key.isFunctionClass, modifiers.contains(.function) {
            modifiers.remove(.function)
            self.modifiers = modifiers
            refreshChips()
        }
        onChord?(KeyChord(modifiers, key))
    }

    @objc private func dotPressed() {
        if recorder.isListening { stopRecording() } else { record() }
    }
}

// The command half
//
// A verb popup plus whatever the verb's `Verb.Argument` asks for — **the one `switch` over `Argument`
// in the package**, which is `ControlFactory`'s rule one vocabulary over: a shape gains a control here
// and nowhere else, and a verb gains one by naming a shape it already has.
//
// Nothing here validates. A spelling this composes goes to the draft, the draft re-parses the whole
// file, and the schema's own sentence is what comes back — so the GUI is the authority on what may be
// *offered* and never on what is legal.

/// What a chord does, as a verb and its argument.
@MainActor
final class CommandBubble: NSView {

    var onSpelling: (@MainActor (String) -> Void)?

    /// The sentence under the row — the verb's own, from the vocabulary.
    private(set) var summary = ""

    private let verbPopUp = NSPopUpButton()
    private let well = NSView()
    private var verb: Verb?
    /// The control the argument's shape asked for, rebuilt when the verb changes.
    private var argument: (any ArgumentControl)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = SettingsStyle.slabEdge
        translatesAutoresizingMaskIntoConstraints = false

        verbPopUp.addItem(withTitle: "Command…")
        for verb in Vocabulary.verbs { verbPopUp.addItem(withTitle: verb.name) }
        verbPopUp.controlSize = .small
        verbPopUp.translatesAutoresizingMaskIntoConstraints = false
        well.translatesAutoresizingMaskIntoConstraints = false

        addSubview(verbPopUp)
        addSubview(well)
        NSLayoutConstraint.activate([
            verbPopUp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            verbPopUp.centerYAnchor.constraint(equalTo: centerYAnchor),
            verbPopUp.widthAnchor.constraint(equalToConstant: 152),

            well.leadingAnchor.constraint(equalTo: verbPopUp.trailingAnchor, constant: 6),
            well.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            well.topAnchor.constraint(equalTo: topAnchor),
            well.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        verbPopUp.target = self
        verbPopUp.action = #selector(verbPicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    convenience init() { self.init(frame: .zero) }

    /// Show a command as the file spells it, or `nil` for a bubble that has not got one yet.
    func show(_ spelling: String?) {
        let words = (spelling ?? "").split(separator: " ", maxSplits: 1,
                                           omittingEmptySubsequences: false)
        let name = words.first.map(String.init) ?? ""
        let rest = words.count > 1 ? String(words[1]) : ""

        let found = Vocabulary.verb(named: name)
        if found?.name != verb?.name {
            verb = found
            verbPopUp.selectItem(withTitle: found?.name ?? "Command…")
            rebuildArgument()
        }
        summary = found?.summary ?? ""
        argument?.show(rest)
    }

    /// The verb's argument control, thrown away and rebuilt — a control for a different shape is a
    /// different control, and there is no state worth carrying across the change.
    ///
    /// **The well is a fixed budget**, since the bubble's width comes from the row. A control sized by
    /// its own content leaves the constraints below a required one to break, so the precondition is
    /// guaranteed here rather than remembered in five inits, and the control is told it may compress.
    private func rebuildArgument() {
        for view in well.subviews { view.removeFromSuperview() }
        guard let verb else { return argument = nil }

        let control = Self.control(for: verb.argument) { [weak self] in self?.compose() }
        argument = control
        let view = control.view
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        well.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            view.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])
    }

    /// **The one `switch` over `Verb.Argument`.** A new shape is a compile error here and nowhere else.
    private static func control(for argument: Verb.Argument,
                                onChange: @escaping @MainActor () -> Void) -> any ArgumentControl {
        switch argument {
        case .none:
            return NothingControl()
        case .words(let words, let fallback):
            return WordsControl(words: words, fallback: fallback, onChange: onChange)
        case .address(let words, let name, _):
            return AddressControl(words: words, name: name, onChange: onChange)
        case .magnitude(let units):
            return MagnitudeControl(units: units, onChange: onChange)
        case .line(let placeholder):
            return LineControl(placeholder: placeholder, onChange: onChange)
        }
    }

    /// The command as the file would spell it, or `nil` while it is not yet a whole one — a verb with
    /// no argument picked, or an `exec` with an empty line.
    var written: String? {
        guard let verb, let argument = argument?.written else { return nil }
        return argument.isEmpty ? verb.name : "\(verb.name) \(argument)"
    }

    /// Report the command, when it is a whole one. A verb with a half-filled argument reports nothing:
    /// the draft would refuse it, and a refusal for something the user is still typing is noise.
    private func compose() {
        guard let written else { return }
        onSpelling?(written)
    }

    @objc private func verbPicked() {
        verb = Vocabulary.verb(named: verbPopUp.titleOfSelectedItem ?? "")
        summary = verb?.summary ?? ""
        rebuildArgument()
        compose()
    }
}

// The five argument controls
//
// One per `Verb.Argument` case, never one per verb — `Setting.Kind`'s rule, one vocabulary over. Each
// answers `written`: the argument as the file spells it, or `nil` while it is not yet a whole one.

/// The control an argument's shape asks for.
@MainActor
protocol ArgumentControl: AnyObject {
    var view: NSView { get }
    /// The argument as the file would spell it, or `nil` while it is incomplete — which stops a
    /// half-typed `exec` from reaching the draft and being refused at every keystroke.
    var written: String? { get }
    /// Show an argument the file carries, spelled the way the file spells it.
    func show(_ text: String)
}

/// `.none` — a verb that is the whole command.
///
/// A control with nothing to draw is still a control: `written` answers `""` rather than `nil`, which is
/// what lets `cycle-width` be a whole command. It says its height, because a view with no size of its own
/// leaves the well's geometry a question.
@MainActor
final class NothingControl: ArgumentControl {
    let view = NSView()
    var written: String? { "" }
    func show(_ text: String) {}

    init() {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 0).isActive = true
    }
}

/// `.words` — a fixed set, so a popup, and there is nothing to spell wrong.
@MainActor
final class WordsControl: ArgumentControl {
    var view: NSView { popUp }
    private let popUp = NSPopUpButton()
    private let words: [String]
    /// What an omitted argument means, from the vocabulary — `nil` for a verb that requires one.
    private let fallback: String?
    private let onChange: @MainActor () -> Void

    init(words: [String], fallback: String?, onChange: @escaping @MainActor () -> Void) {
        self.words = words
        self.fallback = fallback
        self.onChange = onChange
        popUp.addItems(withTitles: words)
        popUp.controlSize = .small
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.target = self
        popUp.action = #selector(picked)
    }

    var written: String? {
        words.indices.contains(popUp.indexOfSelectedItem) ? words[popUp.indexOfSelectedItem] : nil
    }

    /// An omitted argument shows as the default — `fullscreen` with nothing after it *is* `toggle`, and
    /// a popup resting on the first rung would be saying `on`, which is the opposite half the time.
    func show(_ text: String) {
        guard let index = words.firstIndex(of: text.isEmpty ? (fallback ?? text) : text) else { return }
        popUp.selectItem(at: index)
    }

    @objc private func picked() { onChange() }
}

/// `.address` — a popup of the relative motions plus one rung that reveals a field.
///
/// **The field is not validated here.** A workspace is one of thirty-six characters and a display is a
/// number at or above one, and both rules live in the vocabulary; what this owes the user is the shape
/// of the answer, which is what `placeholderString` carries. Getting it wrong is the file's sentence to
/// deliver, not this control's.
@MainActor
final class AddressControl: ArgumentControl {
    var view: NSView { stack }

    /// The rung that reveals the field. Spelled with an ellipsis, which is macOS's own promise that
    /// picking it asks for something more.
    static let specific = "specific…"

    private let stack = NSStackView()
    private let popUp = NSPopUpButton()
    private let field = NSTextField()
    private let words: [String]
    private let onChange: @MainActor () -> Void

    init(words: [String], name: Verb.Argument.Name, onChange: @escaping @MainActor () -> Void) {
        self.words = words
        self.onChange = onChange

        popUp.addItems(withTitles: words + [Self.specific])
        popUp.controlSize = .small
        popUp.translatesAutoresizingMaskIntoConstraints = false

        field.controlSize = .small
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .center
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true
        switch name {
        case .alphabet(let addresses):
            field.placeholderString = "\(addresses.first ?? "1")–\(addresses.last ?? "z")"
            field.toolTip = "One of \(addresses.count) addresses: \(addresses.joined())"
        case .number(let floor):
            field.placeholderString = "≥ \(floor)"
            field.toolTip = "A display's place in the enumeration, counting from \(floor)."
        }

        stack.setViews([popUp, field], in: .leading)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        // **The popup is the part that gives.** Two controls in one well, and a popup sizes itself to its
        // widest item rather than its selected one — so this is the shape that overruns. Not the field:
        // an address is short, and truncating it hides the whole answer.
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        popUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        popUp.target = self
        popUp.action = #selector(picked)
        field.target = self
        field.action = #selector(typed)
        field.isHidden = true
    }

    var written: String? {
        guard popUp.titleOfSelectedItem == Self.specific else { return popUp.titleOfSelectedItem }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    func show(_ text: String) {
        if let index = words.firstIndex(of: text) {
            popUp.selectItem(at: index)
            field.isHidden = true
            return
        }
        popUp.selectItem(withTitle: Self.specific)
        field.isHidden = false
        // Never over the hand — `show` runs after every edit anywhere in the panel.
        guard field.currentEditor() == nil else { return }
        field.stringValue = text
    }

    @objc private func picked() {
        field.isHidden = popUp.titleOfSelectedItem != Self.specific
        if !field.isHidden { field.window?.makeFirstResponder(field) }
        onChange()
    }

    @objc private func typed() { onChange() }
}

/// `.magnitude` — a number and a unit, which is a control that cannot be spelled wrong, and the reason
/// `grow` needs no hint at all.
@MainActor
final class MagnitudeControl: ArgumentControl {
    var view: NSView { stack }

    private let stack = NSStackView()
    private let field = NSTextField()
    private let units: NSSegmentedControl
    private let spellings: [String]
    private let onChange: @MainActor () -> Void

    init(units spellings: [String], onChange: @escaping @MainActor () -> Void) {
        self.spellings = spellings
        self.onChange = onChange
        units = NSSegmentedControl(labels: spellings, trackingMode: .selectOne,
                                   target: nil, action: nil)
        units.selectedSegment = 0
        units.controlSize = .small
        units.translatesAutoresizingMaskIntoConstraints = false

        field.controlSize = .small
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true

        stack.setViews([field, units], in: .leading)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        field.target = self
        field.action = #selector(typed)
        units.target = self
        units.action = #selector(typed)
    }

    var written: String? {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, spellings.indices.contains(units.selectedSegment) else { return nil }
        return text + spellings[units.selectedSegment]
    }

    /// `100px`, `10%`, `100pt`, `100` — the file's four spellings of two units, split back into the
    /// number and the unit the toggle holds. An unrecognised suffix leaves the number where the field
    /// can show it, so a value the file carries is never silently emptied.
    func show(_ text: String) {
        var digits = Substring(text.trimmingCharacters(in: .whitespaces))
        var unit = spellings.first ?? ""
        for spelling in spellings where digits.hasSuffix(spelling) {
            digits = digits.dropLast(spelling.count)
            unit = spelling
            break
        }
        // `pt` is an accepted spelling of points rather than a unit in its own right.
        if digits.hasSuffix("pt") { digits = digits.dropLast(2) }
        if let index = spellings.firstIndex(of: unit) { units.selectedSegment = index }
        guard field.currentEditor() == nil else { return }
        field.stringValue = String(digits)
    }

    @objc private func typed() { onChange() }
}

/// `.line` — the one genuinely open argument in the vocabulary, and the case that earns its place by
/// being the only one a field is the honest control for.
@MainActor
final class LineControl: ArgumentControl {
    var view: NSView { field }

    private let field = NSTextField()
    private let onChange: @MainActor () -> Void

    init(placeholder: String, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        field.controlSize = .small
        field.placeholderString = placeholder
        field.toolTip = "Run through /bin/sh, without waiting for it."
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(typed)
    }

    /// **Not trimmed to nothing and reported.** An empty shell line is refused by the vocabulary, and a
    /// user halfway through typing one should not be told so on every keystroke.
    var written: String? {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    func show(_ text: String) {
        guard field.currentEditor() == nil else { return }
        field.stringValue = text
    }

    @objc private func typed() { onChange() }
}

/// A pop-up that says when it has been pressed, before its menu opens.
///
/// `NSPopUpButton`'s action fires on *selection*, which is too late for anything that has to be torn
/// down before the menu takes the keyboard — and a menu tracks in its own event loop, so a chord
/// recorder still installed would be eating the arrow keys used to walk it.
@MainActor
final class PressReportingPopUpButton: NSPopUpButton {
    var onPress: (@MainActor () -> Void)?

    override func mouseDown(with event: NSEvent) {
        onPress?()
        super.mouseDown(with: event)
    }
}
