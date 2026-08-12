import AppKit
import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// The `[keys]` editor. Three claims carry the file:
//
// **Every verb builds a control** — `ControlsTests`' claim one vocabulary over, and the reason the
// argument shapes are a table rather than a `switch` per verb.
//
// **A binding added, retyped, retargeted and deleted lands as text**, because the file is what the user
// keeps and a control that produced the right `Config` and the wrong bytes would be wrong.
//
// **Reconciliation keeps the row under the hand.** The editor is one `PanelRow` owning a list, so it
// answers `show(draft)` by matching its own children rather than rebuilding them — and a row rebuilt
// under the cursor is the failure that costs a half-typed `exec` line.

@MainActor
@Suite struct KeysTests {

    static func editor(onChange: @escaping @MainActor (Draft.Edit) -> Void = { _ in },
                       onHover: @escaping @MainActor (String) -> Void = { _ in }) throws -> KeysEditor {
        let surface = try #require(ConfigSchema.bespoke.first { $0.key == "keys" })
        return KeysEditor(surface: surface, onChange: onChange, onHover: onHover)
    }

    static let bound = """
    [keys]
    alt-h = "focus left"
    alt-l = "focus right"
    alt-equal = "grow 100px"
    alt-space = "exec ghostty"
    """

    // The vocabulary, as controls

    /// **Every verb builds a control.** The claim the argument table exists for: twenty-one verbs, five
    /// shapes, and not one of them falling through to a blank well.
    @Test func everyVerbBuildsAControl() throws {
        for verb in Vocabulary.verbs {
            let bubble = CommandBubble()
            bubble.show(verb.name)
            #expect(bubble.summary == verb.summary, "\(verb.name) showed no summary")
            let controls = Self.controls(in: bubble)
            switch verb.argument {
            case .none:
                #expect(controls.popUps.count == 1, "\(verb.name) built a control for no argument")
            case .words(let words, _):
                #expect(controls.popUps.count == 2, "\(verb.name) has no word popup")
                #expect(controls.popUps.last?.itemTitles == words)
            case .address(let words, _, _):
                #expect(controls.popUps.count == 2, "\(verb.name) has no address popup")
                #expect(controls.popUps.last?.itemTitles == words + [AddressControl.specific])
            case .magnitude(let units):
                #expect(controls.fields.count == 1, "\(verb.name) has no number field")
                #expect(controls.segments.first?.segmentCount == units.count)
            case .line:
                #expect(controls.fields.count == 1, "\(verb.name) has no line field")
                #expect(controls.fields.first?.placeholderString?.isEmpty == false,
                        "\(verb.name)'s open argument carries no hint")
            }
        }
    }

    /// **An omitted argument shows as the vocabulary's default, not as the popup's first rung.** A bare
    /// `fullscreen` *is* `fullscreen toggle`, and a control resting on `on` would be saying the opposite
    /// half the time. `Command.words` always spells the toggle out, so this is the offer rather than the
    /// file — which is precisely why nothing else would have caught it.
    @Test func anOmittedArgumentShowsAsWhatItMeans() {
        for verb in Vocabulary.verbs {
            guard case .words(_, let fallback) = verb.argument, let fallback else { continue }
            let bubble = CommandBubble()
            bubble.show(verb.name)
            #expect(bubble.written == "\(verb.name) \(fallback)",
                    "a bare '\(verb.name)' offers '\(bubble.written ?? "nothing")'")
        }
    }

    /// …and every verb's own spelling shows and comes back out unchanged, which is the round trip a
    /// control has to make before it can be trusted to edit one.
    @Test func everyVerbsCanonicalSpellingSurvivesTheBubble() {
        for binding in Self.everyVerbSpelled() {
            let bubble = CommandBubble()
            bubble.show(binding)
            #expect(bubble.written == binding,
                    "'\(binding)' came back as '\(bubble.written ?? "nothing")'")
        }
    }

    /// One canonical spelling per verb, built off the vocabulary rather than listed here — so a verb
    /// added to the table is covered without this file being touched.
    static func everyVerbSpelled() -> [String] {
        Vocabulary.verbs.map { verb in
            switch verb.argument {
            case .none:
                return verb.name
            case .words(let words, _):
                return "\(verb.name) \(words[0])"
            case .address(let words, _, _):
                return "\(verb.name) \(words[0])"
            case .magnitude(let units):
                return "\(verb.name) 100\(units[0])"
            case .line:
                return "\(verb.name) ghostty"
            }
        }
    }

    // The list

    @Test func theEditorShowsOneRowPerBinding() throws {
        let editor = try Self.editor()
        editor.show(try Draft(Self.bound))
        #expect(editor.rows.count == 4)
        #expect(editor.rows.map { $0.chord?.description }
                == ["alt-h", "alt-l", "alt-equal", "alt-space"])
    }

    /// Nothing is bound by default and the panel says so rather than opening on a blank list.
    @Test func anEmptyTableShowsWhyItIsEmpty() throws {
        let editor = try Self.editor()
        editor.show(try Draft(""))
        #expect(editor.rows.isEmpty)
        #expect(KeysEditor.emptyState.contains("every other app on the machine"))
    }

    // The four edits, as text

    @Test func removingABindingUnsetsItsWholeLine() throws {
        var edits: [Draft.Edit] = []
        let editor = try Self.editor(onChange: { edits.append($0) })
        var draft = try Draft(Self.bound)
        editor.show(draft)

        try Self.press(remove: editor.rows[1])
        let edit = try #require(edits.first)
        #expect(edit.key == "keys.alt-l")

        draft.apply(edit)
        #expect(draft.config.keys.map(\.chord.description) == ["alt-h", "alt-equal", "alt-space"])
        #expect(!draft.rendered.contains("alt-l"))
    }

    @Test func retypingAChordRenamesTheLineInPlace() throws {
        var edits: [Draft.Edit] = []
        let editor = try Self.editor(onChange: { edits.append($0) })
        var draft = try Draft(Self.bound)
        editor.show(draft)

        editor.rows[0].onChord?(KeyChord([.control, .option], .h))
        draft.apply(try #require(edits.first))

        #expect(draft.refusal == nil)
        #expect(draft.config.keys.map(\.chord.description)
                == ["ctrl-alt-h", "alt-l", "alt-equal", "alt-space"])
        // In place: the retyped binding is still the first line of the table.
        #expect(draft.rendered.contains("[keys]\nctrl-alt-h = \"focus left\""))
    }

    @Test func retargetingABindingWritesTheNewCommand() throws {
        var edits: [Draft.Edit] = []
        let editor = try Self.editor(onChange: { edits.append($0) })
        var draft = try Draft(Self.bound)
        editor.show(draft)

        editor.rows[0].onSpelling?("move-window left")
        draft.apply(try #require(edits.first))

        #expect(draft.refusal == nil)
        #expect(draft.config.keys.first?.spelling == "move-window left")
        #expect(draft.rendered.contains("alt-h = \"move-window left\""))
    }

    /// The composer commits **only when both halves are there**. A binding with a chord and no command
    /// is not something `[keys]` can hold, and the panel's invariant is not bent to carry one.
    @Test func theComposerReachesTheDraftOnlyWhenItIsWhole() throws {
        var edits: [Draft.Edit] = []
        let editor = try Self.editor(onChange: { edits.append($0) })
        var draft = try Draft(Self.bound)
        editor.show(draft)

        try Self.pressAdd(editor)
        let composer = try #require(editor.composer)
        #expect(editor.rows.count == 4, "the half-built row joined the bound ones")

        composer.onChord?(KeyChord([.command, .option], .j))
        #expect(edits.isEmpty, "a chord with no command reached the draft")

        composer.onSpelling?("cycle-width")
        let edit = try #require(edits.first)
        // Spelled the canonical way — 🌐⌃⌥⇧⌘ — whichever order the modifiers were composed in.
        #expect(edit.key == "keys.alt-cmd-j")

        draft.apply(edit)
        #expect(draft.refusal == nil)
        #expect(draft.config.keys.last?.spelling == "cycle-width")
        #expect(editor.composer == nil, "the composer stayed open after committing")

        editor.show(draft)
        #expect(editor.rows.count == 5)
    }

    // Recording is a state the capsule wears, not one it disappears into

    /// **The manual controls stay up and stay live while listening.** The first version replaced the
    /// capsule with a prompt, which foreclosed building a chord by hand at exactly the moment the user
    /// first meets the feature — recording is the shortcut, and the chips are the floor.
    @Test func theChipsAndTheKeyPopUpSurviveRecording() throws {
        let bubble = ChordBubble()
        bubble.show(KeyChord([.option], .h))
        let before = Self.controls(in: bubble)

        bubble.record()
        let during = Self.controls(in: bubble)

        #expect(during.popUps.count == before.popUps.count, "the key popup went away while listening")
        #expect(Self.buttons(in: bubble).count == Self.buttons(in: bubble).count)
        for view in Self.buttons(in: bubble) + during.popUps {
            #expect(!view.isHiddenOrHasHiddenAncestor, "\(type(of: view)) hid itself while listening")
        }
        bubble.stopListening()
    }

    /// The composer opens listening — press a combination and it is taken — but a hand on a chip is an
    /// answer too, and it ends the recording rather than racing it: a press arriving afterwards carries
    /// whatever modifiers are physically held and would overwrite what was just clicked.
    @Test func aHandOnAChipEndsTheRecording() throws {
        var reported: [KeyChord] = []
        let bubble = ChordBubble()
        bubble.onChord = { reported.append($0) }
        bubble.show(KeyChord([], .h))
        bubble.record()
        #expect(bubble.isListening)

        let chip = try #require(Self.buttons(in: bubble).first { $0.toolTip == "alt" })
        chip.state = .on
        _ = chip.target?.perform(chip.action, with: chip)

        #expect(!bubble.isListening, "a chip was clicked and the bubble went on listening")
        #expect(reported == [KeyChord([.option], .h)], "the hand's chord was not reported")
    }

    /// …and so is the popup, which has to be caught on the way *down*: a menu runs its own event loop,
    /// so a recorder still installed would swallow the arrow keys used to walk it.
    @Test func openingTheKeyPopUpEndsTheRecording() throws {
        let bubble = ChordBubble()
        bubble.show(KeyChord([.option], .h))
        bubble.record()
        #expect(bubble.isListening)

        let popUp = try #require(Self.controls(in: bubble).popUps.first as? PressReportingPopUpButton)
        popUp.onPress?()
        #expect(!bubble.isListening, "the popup opened over a live recorder")
    }

    /// The composer still opens listening, so the quick path is one click and a press.
    @Test func theComposerOpensListening() throws {
        let editor = try Self.editor()
        editor.show(try Draft(""))
        try Self.pressAdd(editor)
        let composer = try #require(editor.composer)
        #expect(composer.isListening)
    }

    /// **The whole binding built by hand, no press anywhere.** The path the first version had no way of
    /// offering: chips for the modifiers, the popup for the key, the popup for the verb — and it lands
    /// in the file as text like any other.
    @Test func aBindingCanBeBuiltEntirelyByHand() throws {
        var edits: [Draft.Edit] = []
        let editor = try Self.editor(onChange: { edits.append($0) })
        var draft = try Draft("")
        editor.show(draft)
        try Self.pressAdd(editor)
        let composer = try #require(editor.composer)

        // A modifier, clicked. Alone it is not a chord and nothing travels — the file says so too.
        let bubble = try #require(Self.chordBubble(in: composer.view))
        let chip = try #require(Self.buttons(in: bubble).first { $0.toolTip == "alt" })
        chip.state = .on
        _ = chip.target?.perform(chip.action, with: chip)
        #expect(!composer.isListening, "the hand took over and the bubble kept listening")
        #expect(composer.chord == nil, "modifiers alone were read as a chord")

        // …then the key, picked.
        let popUp = try #require(Self.controls(in: bubble).popUps.first)
        let index = try #require(popUp.itemTitles.firstIndex(of: Keycap.label(for: .j)))
        popUp.selectItem(at: index)
        _ = popUp.target?.perform(popUp.action, with: popUp)
        #expect(composer.chord == KeyChord([.option], .j))
        #expect(edits.isEmpty, "a chord with no command reached the draft")

        // …and the command, picked.
        composer.onSpelling?("cycle-width")
        draft.apply(try #require(edits.first))
        #expect(draft.refusal == nil)
        #expect(draft.rendered.contains("alt-j = \"cycle-width\""))
    }

    // Conflicts

    /// `cmd-alt-h` and `alt-cmd-h` are two TOML keys and one hotkey. **Caught before it reaches the
    /// draft**, which would refuse the whole edit with a sentence at the foot of the slab, a long way
    /// from either bubble.
    @Test func twoSpellingsOfOneChordAreMarkedRatherThanSent() throws {
        var edits: [Draft.Edit] = []
        let editor = try Self.editor(onChange: { edits.append($0) })
        editor.show(try Draft(Self.bound))

        // Retype `alt-l` as a chord `alt-h` already holds — canonically the same hotkey.
        editor.rows[1].onChord?(KeyChord([.option], .h))
        #expect(edits.isEmpty, "a conflicting chord was sent to the draft")
    }

    /// A chord that clashes with nothing goes through, so the check is a check and not a wall.
    @Test func aChordThatClashesWithNothingIsSent() throws {
        var edits: [Draft.Edit] = []
        let editor = try Self.editor(onChange: { edits.append($0) })
        editor.show(try Draft(Self.bound))

        editor.rows[1].onChord?(KeyChord([.option], .k))
        #expect(edits.count == 1)
        #expect(edits.first?.key == "keys.alt-k")
    }

    // The names are the user's
    //
    // **A `[keys]` name is a chord, and a chord has more than one spelling.** `cmd-alt-h` and
    // `alt-cmd-h` are one hotkey and two TOML keys; so are `option-l` and `alt-l`, and the modifiers
    // may follow the key. Every fixture above is spelled canonically, which is exactly why an editor
    // that keyed its edits by `KeyChord.description` passed the whole suite while doing nothing at all
    // to a file written any other way — the document leaves a key it cannot find alone.

    static let spelledOtherwise = """
    [keys]
    cmd-alt-h = "focus left"
    option-l = "focus right"
    """

    @Test func aBindingSpelledAnyOtherWayIsStillRemovable() throws {
        var edits: [Draft.Edit] = []
        let editor = try Self.editor(onChange: { edits.append($0) })
        var draft = try Draft(Self.spelledOtherwise)
        editor.show(draft)

        try Self.press(remove: editor.rows[0])
        // The file's own spelling, not the row's.
        #expect(try #require(edits.first).key == "keys.cmd-alt-h")

        draft.apply(try #require(edits.first))
        #expect(draft.refusal == nil)
        #expect(draft.isDirty, "the line was never found, so nothing was written")
        #expect(draft.config.keys.map(\.chord.description) == ["alt-l"])
    }

    @Test func aBindingSpelledAnyOtherWayIsStillRetargetable() throws {
        var edits: [Draft.Edit] = []
        let editor = try Self.editor(onChange: { edits.append($0) })
        var draft = try Draft(Self.spelledOtherwise)
        editor.show(draft)

        editor.rows[1].onSpelling?("cycle-width")
        draft.apply(try #require(edits.first))

        // Not a second line under a second spelling, which the schema would then refuse as one hotkey
        // set twice — a complaint naming a key the file does not contain.
        #expect(draft.refusal == nil)
        #expect(draft.rendered.contains("option-l = \"cycle-width\""))
        #expect(draft.config.keys.count == 2)
    }

    /// A chord retyped keeps the *line*, so the spelling it lands as is the canonical one — the file's
    /// old spelling was the user's, and the new chord is the panel's.
    @Test func aBindingSpelledAnyOtherWayIsStillRetypable() throws {
        var edits: [Draft.Edit] = []
        let editor = try Self.editor(onChange: { edits.append($0) })
        var draft = try Draft(Self.spelledOtherwise)
        editor.show(draft)

        editor.rows[0].onChord?(KeyChord([.control], .k))
        draft.apply(try #require(edits.first))

        #expect(draft.refusal == nil)
        #expect(draft.config.keys.map(\.chord.description) == ["ctrl-k", "alt-l"])
        #expect(draft.rendered.contains("[keys]\nctrl-k = \"focus left\""))
    }

    /// …and the mock follows it, because the take is looked up by the same key the edit carries.
    @Test func aBindingSpelledAnyOtherWayStillDemonstratesItsVerb() throws {
        let config = try Config.parse(Self.spelledOtherwise)
        #expect(Catalog.take(for: "keys.cmd-alt-h", config: config) != nil)
    }

    // Reconciliation

    /// **Row identity survives an edit anywhere in the panel.** `show` runs after every one of them, and
    /// a list that rebuilt its children each time would drop the field under the cursor.
    @Test func showingTheSameBindingsKeepsTheSameRows() throws {
        let editor = try Self.editor()
        let draft = try Draft(Self.bound)
        editor.show(draft)
        let first = editor.rows

        editor.show(draft)
        #expect(zip(first, editor.rows).allSatisfy { $0 === $1 }, "a row was rebuilt for nothing")
    }

    /// …and it survives a **rename**, which is the case chord-keyed matching alone would get wrong: the
    /// chord moved, so the row has to be found by position instead.
    @Test func aRenamedBindingKeepsItsRow() throws {
        let editor = try Self.editor()
        var draft = try Draft(Self.bound)
        editor.show(draft)
        let renamed = editor.rows[0]

        draft.apply(.rename("keys.alt-h", to: "keys.ctrl-alt-h"))
        editor.show(draft)

        #expect(editor.rows.first === renamed, "the renamed row was rebuilt")
        #expect(editor.rows.first?.chord?.description == "ctrl-alt-h")
    }

    /// …and the rows keep their **place in the view hierarchy** across an edit, which is the half row
    /// identity alone does not buy. Taking a view out of the hierarchy ends any editing session inside
    /// it, so a stack rebuilt on every `show` drops the field editor under the hand — the exact failure
    /// reconciliation exists to prevent, one level down.
    @Test func anEditLeavesTheOtherRowsWhereTheyAreInTheHierarchy() throws {
        var edits: [Draft.Edit] = []
        let editor = try Self.editor(onChange: { edits.append($0) })
        var draft = try Draft(Self.bound)
        editor.show(draft)
        let stacks = editor.rows.map(\.view.superview)

        editor.rows[0].onSpelling?("move-window left")
        draft.apply(try #require(edits.first))
        editor.show(draft)

        #expect(zip(stacks, editor.rows).allSatisfy { $0 === $1.view.superview },
                "a row left the hierarchy for an edit that moved nothing")
        #expect(editor.rows.allSatisfy { $0.view.superview != nil })
    }

    /// A clash marked on another row comes back off it **with its sentence**, since the row that was
    /// marked never sees a draft round trip to restore what it said.
    @Test func resolvingAClashPutsTheOtherRowsSentenceBack() throws {
        let editor = try Self.editor()
        editor.show(try Draft(Self.bound))
        let summary = try #require(Self.labels(in: editor.rows[0].view).last)
        let resting = summary.stringValue

        editor.rows[1].onChord?(KeyChord([.option], .h))
        #expect(summary.stringValue == "That combination is already bound.")

        editor.rows[1].onChord?(KeyChord([.option], .k))
        #expect(summary.stringValue == resting, "the row kept a clash it no longer has")
    }

    /// The same four bindings written the other way up — a reorder that moves every row and changes
    /// nothing else.
    static let boundReversed = """
    [keys]
    alt-space = "exec ghostty"
    alt-equal = "grow 100px"
    alt-l = "focus right"
    alt-h = "focus left"
    """

    /// **The stack reorders in place rather than being rebuilt**, and the field editor is the only thing
    /// that can say so: row *identity* survives a rebuild either way, since `reconcile` matches by chord.
    /// What does not survive one is the editing session, because taking a view out of the hierarchy ends
    /// it. So this needs a real window and a real first responder — the claim is that a list whose order
    /// moved does not cost the user the line they were typing.
    @Test func reorderingTheListKeepsTheFieldUnderTheHand() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = try #require(window.contentView)
        let slab = ControlSlab()
        root.addSubview(slab)
        NSLayoutConstraint.activate([
            slab.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            slab.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        slab.select(section: try #require(ControlSlab.sections.firstIndex(of: .keys)))

        var draft = try Draft(Self.bound)
        slab.show(draft)
        slab.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)

        let editor = try #require(slab.controls.compactMap { $0 as? KeysEditor }.first)
        let typing = try #require(editor.rows.last, "no row to put the hand on")
        let field = try #require(Self.controls(in: typing.view).fields.first,
                                 "the shell line has no field")
        #expect(window.makeFirstResponder(field), "the field would not take the keyboard")
        #expect(field.currentEditor() != nil, "nothing was being edited to begin with")

        // The row under the hand goes from the bottom of the list to the top.
        try draft.reload(Self.boundReversed)
        slab.show(draft)

        #expect(editor.rows.first === typing, "the row moved by being rebuilt")
        #expect(editor.rows.map { $0.chord?.description }
                == ["alt-space", "alt-equal", "alt-l", "alt-h"])
        #expect(field.currentEditor() != nil,
                "the reorder ended the editing session in the row it moved")
        window.orderOut(nil)
    }

    /// **The half-built row opens under the button that made it.** It is not in the file yet, so file
    /// order has no claim on where it sits — and a control whose result appears at the far end of a
    /// scrolling list is one nobody connects to what they just clicked.
    @Test func theComposerOpensAboveTheBoundRows() throws {
        let editor = try Self.editor()
        editor.show(try Draft(Self.many))
        try Self.pressAdd(editor)

        let composer = try #require(editor.composer)
        let stack = try #require(composer.view.superview as? NSStackView)
        #expect(stack.arrangedSubviews.first === composer.view,
                "the composer opened below \(stack.arrangedSubviews.count - 1) bound rows")
    }

    /// …and committing it **keeps that row**, rather than leaving `show` to find a binding no row holds
    /// and build a fresh one. A row rebuilt at the moment the work is finished takes the control under
    /// the hand with it — for an `exec` line, the field the user was still typing in.
    @Test func committingTheComposerKeepsTheRowItWasBuiltIn() throws {
        var edits: [Draft.Edit] = []
        let editor = try Self.editor(onChange: { edits.append($0) })
        var draft = try Draft(Self.bound)
        editor.show(draft)

        try Self.pressAdd(editor)
        let composer = try #require(editor.composer)
        composer.onChord?(KeyChord([.command, .option], .j))
        composer.onSpelling?("exec ghostty")
        draft.apply(try #require(edits.first))
        editor.show(draft)

        #expect(draft.refusal == nil)
        #expect(editor.rows.last === composer, "the finished row was rebuilt from scratch")
        #expect(composer.view.superview != nil, "the finished row left the hierarchy")
    }

    /// A discard puts the file back, and the rows come back with it rather than piling up.
    @Test func aDiscardBringsTheRowsBack() throws {
        let editor = try Self.editor()
        var draft = try Draft(Self.bound)
        editor.show(draft)

        draft.apply(.unset("keys.alt-h"))
        editor.show(draft)
        #expect(editor.rows.count == 3)

        draft.discard()
        editor.show(draft)
        #expect(editor.rows.count == 4)
        #expect(editor.rows.first?.chord?.description == "alt-h")
    }

    /// A reload is a new file underneath, and the list is what the new file says.
    @Test func aReloadShowsTheNewFile() throws {
        let editor = try Self.editor()
        var draft = try Draft(Self.bound)
        editor.show(draft)

        try draft.reload("[keys]\ncmd-j = \"cycle-height\"\n")
        editor.show(draft)
        #expect(editor.rows.map { $0.chord?.description } == ["cmd-j"])
    }

    // Hover

    @Test func hoveringABindingNamesItsOwnKey() throws {
        var hovered: [String] = []
        let editor = try Self.editor(onHover: { hovered.append($0) })
        editor.show(try Draft(Self.bound))

        (editor.rows[2].view as? RowView)?.onHover?()
        #expect(hovered == ["keys.alt-equal"])
    }

    // The keycap vocabulary

    /// Every key is in exactly one group, so the popup offers the whole vocabulary and offers nothing
    /// twice.
    @Test func everyKeyIsOfferedExactlyOnce() {
        let offered = Keycap.groups.flatMap(\.keys)
        #expect(Set(offered) == Set(Key.allCases))
        #expect(offered.count == Key.allCases.count)
    }

    /// A glyph is never empty, and the ones with a keycap of their own carry it.
    @Test func everyKeyHasALabel() {
        for key in Key.allCases {
            #expect(!Keycap.label(for: key).isEmpty, "\(key.rawValue) has no label")
        }
        #expect(Keycap.glyph(for: .backspace) == "⌫")
        #expect(Keycap.glyph(for: .left) == "←")
        #expect(Keycap.label(for: .period) == ".")
        #expect(Keycap.label(for: .h) == "H")
    }

    /// **All five chips are text, and that is the point rather than an accident.** A drawn chip among
    /// spelled ones is coloured by a different mechanism — `contentTintColor` reaches an image and never
    /// a title — so the two drift, which is exactly how the fn chip once stayed at full strength while
    /// the four beside it went dim on a dark panel.
    @Test func everyModifierHasItsOwnGlyphAndAllOfThemAreText() {
        let glyphs = KeyModifiers.canonical.map { Keycap.glyph(for: $0.modifier) }
        #expect(glyphs == ["fn", "⌃", "⌥", "⇧", "⌘"])

        let bubble = ChordBubble()
        bubble.show(KeyChord([.option], .h))
        let chips = Self.buttons(in: bubble).filter { button in
            KeyModifiers.canonical.contains { $0.word == button.toolTip }
        }
        #expect(chips.count == 5)
        for chip in chips {
            #expect(chip.image == nil, "a chip is drawn rather than spelled and will colour differently")
            #expect(!chip.attributedTitle.string.isEmpty, "a chip carries no glyph")
        }
    }

    /// The colour comes off the system's semantic palette in both states, so the chips follow the theme
    /// rather than a pair of constants that happen to suit one of them.
    ///
    /// **A held chip is not inked with the accent**, and this is the assertion that says why: AppKit
    /// draws a recessed button's on state with an accent-coloured *fill*, so an accent glyph on it is a
    /// solid blue rectangle with nothing in it. Invisible in both appearances, and invisible only while
    /// the window is **active** — which is how it survived a screenshot taken from an inactive harness.
    @Test func aChipsInkIsTheSystemsAndSaysWhetherItIsHeld() throws {
        let bubble = ChordBubble()
        bubble.show(KeyChord([.option], .h))
        let chips = Self.buttons(in: bubble).filter { button in
            KeyModifiers.canonical.contains { $0.word == button.toolTip }
        }
        let held = try #require(chips.first { $0.toolTip == "alt" })
        let unheld = try #require(chips.first { $0.toolTip == "cmd" })

        func ink(_ button: NSButton) -> NSColor? {
            button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        #expect(ink(held) == .alternateSelectedControlTextColor)
        #expect(ink(held) != .controlAccentColor, "the glyph is the same colour as the fill under it")
        // Not `tertiaryLabelColor`: an unheld modifier is still a label to be read, and tertiary over a
        // dark chip on a dark panel is a glyph you have to hunt for.
        #expect(ink(unheld) == .secondaryLabelColor)
    }

    // The panel

    /// **The tab is built by the slab, not by this suite.** `ControlSlab` folds the schema, so the editor
    /// reaching the screen at all is a claim about the fold rather than about the editor — and it is the
    /// half `BespokeTests` cannot make, since a surface with an editor still has to be *placed*.
    @Test func theKeysTabBuildsTheEditorAndShowsTheFile() throws {
        let slab = ControlSlab()
        let index = try #require(ControlSlab.sections.firstIndex(of: .keys))
        slab.select(section: index)
        slab.show(try Draft(Self.bound))

        let editor = try #require(slab.controls.compactMap { $0 as? KeysEditor }.first)
        #expect(slab.controls.count == 1, "the Keys tab carries something other than the editor")
        #expect(editor.rows.count == 4)

        // …and it lays out, which is the failure a headless suite can catch and an eye cannot.
        slab.layoutSubtreeIfNeeded()
        for row in editor.rows {
            let frame = row.view.convert(row.view.bounds, to: slab)
            #expect(frame.width > 0 && frame.height > 0, "a binding row laid out at zero size")
        }
    }

    /// **The one control that adds a binding is above the list, and this is a claim about the fold.**
    /// The panel is one height for every tab and eight bindings are twice the viewport, so a button
    /// after the last row is a button nobody can reach — it sat 226 pt past the bottom. Asserted against
    /// the laid-out panel rather than the editor, because the fold is the slab's and not the editor's.
    @Test func theAddButtonIsAboveTheFoldOnAPopulatedFile() throws {
        let slab = ControlSlab()
        slab.select(section: try #require(ControlSlab.sections.firstIndex(of: .keys)))
        slab.show(try Draft(Self.many))
        slab.layoutSubtreeIfNeeded()

        let editor = try #require(slab.controls.compactMap { $0 as? KeysEditor }.first)
        let button = try #require(Self.buttons(in: editor.view).first { $0.title.contains("Add a binding") })
        let scroller = try #require(button.enclosingScrollView)
        let frame = button.convert(button.bounds, to: scroller.contentView)

        #expect(editor.rows.count == 8)
        #expect(scroller.contentView.bounds.intersects(frame),
                "the only way to add a binding is \(frame.minY - scroller.contentView.bounds.maxY) pt below the fold")
        // Above the rows rather than merely on screen: the list is what scrolls, and the button is not
        // part of it.
        let first = try #require(editor.rows.first).view
        #expect(frame.maxY <= first.convert(first.bounds, to: scroller.contentView).minY)
    }

    /// Eight bindings — twice what the viewport holds, which is an ordinary file and the case the
    /// fixtures above are all too short to be.
    static let many = """
    [keys]
    alt-h = "focus left"
    alt-l = "focus right"
    alt-j = "focus down"
    alt-k = "focus up"
    alt-equal = "grow 100px"
    alt-minus = "shrink 10%"
    alt-f = "fullscreen toggle"
    alt-space = "exec ghostty"
    """

    /// One binding per argument shape, including the longest verb name the vocabulary offers and the
    /// address popup in the state that reveals its field — the two rows a fixture of `focus` and `grow`
    /// never builds.
    static let everyShape = """
    [keys]
    alt-c = "cycle-width"
    alt-1 = "focus-workspace 1"
    alt-2 = "focus-monitor 2"
    alt-equal = "grow 100px"
    cmd-alt-f = "fullscreen toggle"
    alt-space = "exec ghostty"
    alt-w = "move-workspace-to-monitor-and-focus next"
    """

    /// **Every argument shape fits the well it is given, and this is a claim about the laid-out panel.**
    /// The bubble's width comes from the row, so a control sized by its own content leaves the engine a
    /// layout with a required constraint to break — and it breaks both ways: the well collapses and
    /// strands the ⊖, or it overruns and the ⊖ is drawn over, which is a binding nobody can delete.
    /// Neither is visible to a suite that builds a bubble and never lays it out.
    @Test func everyArgumentShapeFitsTheRowItIsGiven() throws {
        let slab = ControlSlab()
        slab.select(section: try #require(ControlSlab.sections.firstIndex(of: .keys)))
        slab.show(try Draft(Self.everyShape))
        slab.layoutSubtreeIfNeeded()

        let editor = try #require(slab.controls.compactMap { $0 as? KeysEditor }.first)
        let list = try #require(editor.rows.first?.view.superview)
        #expect(editor.rows.count == 7)

        var edges: Set<Int> = []
        for row in editor.rows {
            let spelling = row.spelling ?? "?"
            #expect(row.view.frame.width == list.frame.width,
                    "'\(spelling)' left its row \(list.frame.width - row.view.frame.width) pt short")

            let remove = try #require(Self.buttons(in: row.view).first {
                $0.image?.accessibilityDescription?.contains("Remove") == true
            }, "'\(spelling)' has no remove button")
            #expect(remove.convert(remove.bounds, to: row.view).maxX <= row.view.bounds.maxX + 0.5,
                    "'\(spelling)' pushed its ⊖ off the row")

            let bubble = try #require(Self.commandBubble(in: row.view))
            let box = bubble.convert(bubble.bounds, to: row.view)
            #expect(box.maxX <= remove.convert(remove.bounds, to: row.view).minX,
                    "'\(spelling)' runs its command bubble into the ⊖")
            edges.insert(Int(box.maxX.rounded()))
        }
        // The rows read as a column, which they only do if no shape moved the edge it shares.
        #expect(edges.count == 1, "the command bubbles end in \(edges.count) places: \(edges.sorted())")
    }

    // Poking the built views

    static func pressAdd(_ editor: KeysEditor) throws {
        let button = try #require(buttons(in: editor.view).first { $0.title.contains("Add a binding") })
        _ = button.target?.perform(button.action, with: button)
    }

    static func press(remove row: BindingRow) throws {
        let button = try #require(buttons(in: row.view).first {
            $0.image?.accessibilityDescription?.contains("Remove") == true
        })
        _ = button.target?.perform(button.action, with: button)
    }

    static func chordBubble(in view: NSView) -> ChordBubble? {
        if let bubble = view as? ChordBubble { return bubble }
        for child in view.subviews {
            if let found = chordBubble(in: child) { return found }
        }
        return nil
    }

    static func commandBubble(in view: NSView) -> CommandBubble? {
        if let bubble = view as? CommandBubble { return bubble }
        for child in view.subviews {
            if let found = commandBubble(in: child) { return found }
        }
        return nil
    }

    /// The plain labels in a row, in the order they are laid out — the last is the sentence under it.
    static func labels(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let label = view as? NSTextField, !label.isEditable { found.append(label) }
        for child in view.subviews { found += labels(in: child) }
        return found
    }

    static func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for child in view.subviews { found += buttons(in: child) }
        return found
    }

    static func controls(in view: NSView)
        -> (popUps: [NSPopUpButton], fields: [NSTextField], segments: [NSSegmentedControl]) {
        var popUps: [NSPopUpButton] = []
        var fields: [NSTextField] = []
        var segments: [NSSegmentedControl] = []
        func walk(_ view: NSView) {
            if let popUp = view as? NSPopUpButton { popUps.append(popUp) }
            else if let field = view as? NSTextField, field.isBezeled { fields.append(field) }
            else if let segment = view as? NSSegmentedControl { segments.append(segment) }
            for child in view.subviews { walk(child) }
        }
        walk(view)
        return (popUps, fields, segments)
    }
}
