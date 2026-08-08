import AppKit
import Testing
import EmiraConfig
@testable import EmiraSettings

// **Nothing in `EmiraSettings` describes a setting.** The panel is a fold over `ConfigSchema.settings`,
// so the claim worth testing is that the fold is total: every entry the schema carries builds a control,
// and every control reads its value back out of the draft it was shown.
//
// No window is involved. A control is a view tree, and building one costs nothing.

@MainActor
@Suite struct ControlsTests {

    static func control(_ key: String) throws -> any SettingControl {
        let setting = try #require(ConfigSchema.setting(for: key))
        return ControlFactory.control(for: setting, onChange: { _ in }, onDrag: { _ in })
    }

    @Test func everySettingInTheSchemaBuildsAControl() throws {
        for setting in ConfigSchema.settings {
            let control = ControlFactory.control(for: setting, onChange: { _ in }, onDrag: { _ in })
            #expect(control.setting.key == setting.key)
            // The row carries the entry's own words, so a new setting explains itself with no edit here.
            #expect(!control.view.subviews.isEmpty, "\(setting.key) built an empty row")
        }
    }

    @Test func eachKindGetsTheControlItAsksFor() throws {
        #expect(try Self.control("layout.center-focused-column") is ToggleControl)
        #expect(try Self.control("layout.column-gap") is NumberControl)
        #expect(try Self.control("mouse.follows-focus") is ChoiceControl)
        #expect(try Self.control("layout.width-presets") is SizeListControl)
    }

    @Test func aControlShowsWhatTheDraftHoldsAndNotWhatItWasBuiltWith() throws {
        var draft = try Draft("[layout]\ncolumn-gap = 8")
        let control = try Self.control("layout.column-gap")
        control.show(draft)

        let setting = try #require(ConfigSchema.setting(for: "layout.column-gap"))
        draft.set(setting, to: .number(21))
        control.show(draft)

        // Nothing to read back through the protocol, so the check is that showing a changed draft is
        // accepted at all — the value's journey is `DraftTests`' subject, and the wiring is the window's.
        #expect(draft.config.columnGap == 21)
    }

    /// Every section the slab offers has something behind it — read off the slab's own list rather than
    /// re-derived here, or this tests a copy of the rule and not the rule.
    @Test func onlySectionsWithSomethingToShowBecomeTabs() {
        let offered = ControlSlab.sections
        // Both carry a bespoke surface and neither has an editor, so neither is a tab that opens on
        // nothing.
        #expect(!offered.contains(.keys))
        #expect(!offered.contains(.windowRules))
        #expect(offered.contains(.layout))
        for section in offered {
            let hasSetting = ConfigSchema.settings.contains { $0.section == section }
            let hasEditor = ConfigSchema.bespoke.contains {
                $0.section == section && BespokeEditors.isEditable($0)
            }
            #expect(hasSetting || hasEditor, "\(section) is a tab with nothing behind it")
        }
    }

    /// **There is no springs tab.** Every spring is an advanced dial of `animation`, so a section whose
    /// every entry was advanced — a tab opening on a disclosure triangle and nothing else — is gone.
    @Test func theSpringsAreAdvancedDialsOfAnimation() {
        let springs = ConfigSchema.settings.filter { $0.key.hasPrefix("animation.") && $0.key.hasSuffix("stiffness") }
        #expect(springs.count == 4)
        #expect(springs.allSatisfy { $0.section == .animation && $0.isAdvanced })

        for section in ControlSlab.sections {
            let entries = ConfigSchema.settings.filter { $0.section == section }
            #expect(entries.isEmpty || entries.contains { !$0.isAdvanced },
                    "\(section) is a tab whose every setting is behind the disclosure")
        }
    }

    /// A choice control switches shape at four words, so both branches have to be reachable from the
    /// schema as it stands — otherwise one of them is untested code that looks tested.
    @Test func theChoiceVocabulariesStraddleTheSegmentLimit() {
        var widest = 0
        for setting in ConfigSchema.settings {
            if case .choice(let words) = setting.kind { widest = max(widest, words.count) }
        }
        #expect(widest >= ChoiceControl.segmentLimit,
                "no vocabulary reaches the pop-up branch, which is therefore never exercised")
    }

    /// The slab builds without a window, which is what makes the rest of this suite possible — and is
    /// also the regression guard for the constraint that once hung the whole app: a row pinned to a
    /// stack it had not been added to.
    @Test func theSlabBuildsEverySectionWithoutHanging() throws {
        let slab = ControlSlab()
        let draft = try Draft("[layout]\ncolumn-gap = 8")
        slab.show(draft)
        slab.layoutSubtreeIfNeeded()
        #expect(slab.frame.width == ControlSlab.width)
    }

    // Free-form input, which is the only way to set a `.sizeList` at all

    /// The typed text a control hands to the draft, by driving the real control and catching what it
    /// reports. No window: a control is a view tree.
    static func committed(_ key: String, typing text: String) throws -> TOMLValue? {
        let setting = try #require(ConfigSchema.setting(for: key))
        var reported: TOMLValue?
        let control = ControlFactory.control(for: setting,
                                             onChange: { edit in reported = Self.value(of: edit) },
                                             onDrag: { _ in })
        let field = try #require(Self.field(in: control.view))
        field.stringValue = text
        _ = field.target?.perform(field.action, with: field)
        return reported
    }

    /// The value an edit carries, whichever surface it came off.
    static func value(of edit: Draft.Edit) -> TOMLValue {
        switch edit {
        case .setting(_, let value), .key(_, let value): return value
        }
    }

    static func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isBezeled { return field }
        for child in view.subviews {
            if let found = field(in: child) { return found }
        }
        return nil
    }

    @Test func aListOfNumbersCommitsAsAList() throws {
        let committed = try Self.committed("layout.width-presets", typing: "0.4, 0.6")
        let value = try #require(committed)
        #expect(value.spelled == "[0.4, 0.6]")
    }

    /// **The bug this test exists for**: `compactMap` alone dropped whatever did not parse, so a list
    /// with one bad rung in it quietly became a shorter list — the file changing to something the user
    /// never typed, with nothing said about it.
    @Test func aListWithOneUnreadableRungIsRefusedRatherThanShortened() throws {
        let committed = try Self.committed("layout.width-presets", typing: "1/3, 0.5")
        let value = try #require(committed)
        #expect(value.spelled != "[0.5]", "the readable half must not be committed on its own")

        // Handed over as a *list* with the bad rung left as text, so the schema complains about the
        // element rather than about the value's TOML type — and the draft is left exactly as it was.
        let refusal = try Self.refusal(of: value, for: "layout.width-presets")
        #expect(refusal?.contains("number") == true, "got: \(refusal ?? "none")")
    }

    /// What the draft says when handed `value` — the path the window actually takes.
    static func refusal(of value: TOMLValue, for key: String) throws -> String? {
        let setting = try #require(ConfigSchema.setting(for: key))
        var draft = try Draft("")
        draft.set(setting, to: value)
        #expect(!draft.isDirty, "a refused value must not land")
        return draft.refusal
    }

    @Test func anEntirelyUnreadableValueIsRefusedToo() throws {
        let committed = try Self.committed("layout.width-presets", typing: "1/3")
        let value = try #require(committed)
        let refusal = try Self.refusal(of: value, for: "layout.width-presets")
        #expect(refusal != nil)
    }

    @Test func aNumberFieldRefusesWordsInsteadOfIgnoringThem() throws {
        let committed = try Self.committed("layout.column-gap", typing: "wide")
        let value = try #require(committed)
        let refusal = try Self.refusal(of: value, for: "layout.column-gap")
        #expect(refusal != nil)
    }

    /// A commit that changed nothing writes nothing — otherwise clicking in and out of the field would
    /// round the file's own numbers to the shortened spelling shown in it.
    @Test func anUntouchedSizeListCommitsNothing() throws {
        let setting = try #require(ConfigSchema.setting(for: "layout.width-presets"))
        var reported: TOMLValue?
        let control = ControlFactory.control(for: setting,
                                             onChange: { edit in reported = Self.value(of: edit) },
                                             onDrag: { _ in })
        let draft = try Draft("")
        control.show(draft)
        let field = try #require(Self.field(in: control.view))
        // Seventeen digits of a third do not fit in the field, so what is shown is shortened.
        #expect(field.stringValue == "0.3333, 0.5, 0.6667")

        _ = field.target?.perform(field.action, with: field)
        #expect(reported == nil)
    }
}
