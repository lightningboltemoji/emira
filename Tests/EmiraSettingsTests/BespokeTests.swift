import AppKit
import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// The claim `outer-gap` cost us: **a surface the table cannot describe either has an editor or says why
// it hasn't.** The same shape as `CatalogTests`' demo story and `ConfigSchemaTests`' config story, on
// the one list that had no such rule — which is how a Layout setting came to be missing from the Layout
// tab without anybody deciding that.

@MainActor
@Suite struct BespokeTests {

    static func editor(_ key: String, onChange: @escaping @MainActor (Draft.Edit) -> Void = { _ in })
        throws -> any PanelRow {
        let surface = try #require(ConfigSchema.bespoke.first { $0.key == key })
        return try #require(BespokeEditors.editor(for: surface, onChange: onChange))
    }

    @Test func everySurfaceHasAnEditorOrSaysWhyNot() {
        var orphans: [String] = []
        for surface in ConfigSchema.bespoke {
            if BespokeEditors.editor(for: surface, onChange: { _ in }) != nil { continue }
            if BespokeEditors.notEditable[surface.key] == nil { orphans.append(surface.key) }
        }
        #expect(orphans.isEmpty, """
        These surfaces build no editor and are not on `BespokeEditors.notEditable`: \
        \(orphans.sorted()). Either give it an editor or name it with a reason — file-only is a \
        decision, and a decision nobody wrote down is how `outer-gap` ended up with no control.
        """)
    }

    @Test func everyReasonNamesARealSurfaceAndSaysSomething() {
        for (key, reason) in BespokeEditors.notEditable {
            #expect(ConfigSchema.bespoke.contains { $0.key == key },
                    "`\(key)` is on notEditable but is not a bespoke surface")
            #expect(reason.count > 60, "`\(key)`'s reason does not say what the editor would have to do")
        }
    }

    @Test func aSurfaceWithNoEditorBuildsNothing() {
        for key in BespokeEditors.notEditable.keys {
            let surface = ConfigSchema.bespoke.first { $0.key == key }
            #expect(surface.flatMap { BespokeEditors.editor(for: $0, onChange: { _ in }) } == nil,
                    "`\(key)` is on the list but builds an editor")
        }
    }

    // Outer gaps

    @Test func theOuterGapEditorShowsWhateverSpellingTheFileUsed() throws {
        let editor = try Self.editor("layout.outer-gap")
        // The base key, which resolves to all four sides — the reading is off `Config`, so the five
        // spellings are one value here exactly as they are to the reducer.
        let draft = try Draft("[layout]\nouter-gap = 12\nouter-gap-left = 30")
        editor.show(draft)
        let fields = Self.fields(in: editor.view)
        #expect(fields.map(\.stringValue) == ["12", "30", "12", "12"])
    }

    @Test func typingAnEdgeWritesThatEdgeAlone() throws {
        var edits: [Draft.Edit] = []
        let editor = try Self.editor("layout.outer-gap", onChange: { edits.append($0) })
        var draft = try Draft("")
        editor.show(draft)

        let fields = Self.fields(in: editor.view)
        fields[2].stringValue = "18"
        _ = fields[2].target?.perform(fields[2].action, with: fields[2])

        let edit = try #require(edits.first)
        #expect(edit.key == "layout.outer-gap-bottom")
        draft.apply(edit)
        #expect(draft.config.outerGaps == EdgeInsets(bottom: 18))
        // The other three are untouched, which four rows of one number each would not have made obvious.
        #expect(draft.rendered.contains("outer-gap-bottom = 18"))
        #expect(!draft.rendered.contains("outer-gap-top"))
    }

    /// **The rule `setOrUnset` is for.** A side that matches the base key it resolves against is not
    /// written down: an absent line already means that, and a file that writes it pins the side against
    /// a later change to the base.
    @Test func anEdgeThatMatchesItsBaseKeyIsNotWrittenDown() throws {
        var draft = try Draft("[layout]\nouter-gap = 8")
        draft.apply(.key("layout.outer-gap-top", .number(8)))
        #expect(draft.refusal == nil)
        #expect(!draft.rendered.contains("outer-gap-top"), "a line repeating the base was written")
        #expect(draft.config.outerGaps.top == 8)

        // …and one that disagrees with it is.
        draft.apply(.key("layout.outer-gap-top", .number(20)))
        #expect(draft.rendered.contains("outer-gap-top = 20"))
        #expect(draft.config.outerGaps == EdgeInsets(top: 20, left: 8, bottom: 8, right: 8))
    }

    /// Setting an edge back to what the rest of the file already means takes the line out again — the
    /// same round trip `set(_ setting:to:)` makes for a schema entry.
    @Test func anEdgeSetBackToWhatTheFileMeansUnsetsItself() throws {
        var draft = try Draft("[layout]\nouter-gap = 8\n")
        let baseline = draft.rendered

        draft.apply(.key("layout.outer-gap-right", .number(24)))
        #expect(draft.isDirty)

        draft.apply(.key("layout.outer-gap-right", .number(8)))
        #expect(draft.rendered == baseline, "the file did not come back to where it started")
        #expect(!draft.isDirty)
    }

    /// With no base key, an edge back at zero unsets too — a bespoke key's default is whatever the file
    /// says elsewhere, and here the file says nothing.
    @Test func withNoBaseKeyAnEdgeUnsetsAtZero() throws {
        var draft = try Draft("[layout]\ncolumn-gap = 8\n")
        draft.apply(.key("layout.outer-gap-left", .number(14)))
        #expect(draft.rendered.contains("outer-gap-left = 14"))

        draft.apply(.key("layout.outer-gap-left", .number(0)))
        #expect(!draft.rendered.contains("outer-gap-left"))
        #expect(draft.config.outerGaps == .zero)
    }

    /// A number below the floor is refused in the file's own words rather than clamped — `NumberControl`'s
    /// rule, reaching a key the table does not describe.
    @Test func anEdgeBelowItsFloorIsRefusedAndDoesNotLand() throws {
        var draft = try Draft("[layout]\ncolumn-gap = 8\n")
        let baseline = draft.rendered
        draft.apply(.key("layout.outer-gap-top", .number(-4)))
        #expect(draft.refusal?.contains("at least") == true, "got: \(draft.refusal ?? "none")")
        #expect(draft.rendered == baseline, "a refused edit landed")
    }

    @Test func anEdgeTypedAsAWordIsRefusedTheSameWay() throws {
        var draft = try Draft("")
        draft.apply(.key("layout.outer-gap-top", .string("wide")))
        #expect(draft.refusal != nil)
        #expect(!draft.isDirty)
    }

    /// The mock re-derives from `Config`, so an outer gap moves it with nothing scripted — which is why
    /// the surface needs no take of its own and answers its section's set.
    @Test func anOuterGapMovesTheMock() throws {
        let area = PreviewModelTests.workingArea
        var draft = try Draft("")
        let before = PreviewModel.state(of: Scenes.threeColumns, config: draft.config,
                                        workingArea: area)
        draft.apply(.key("layout.outer-gap-left", .number(40)))
        let after = PreviewModel.state(of: Scenes.threeColumns, config: draft.config,
                                       workingArea: area)
        #expect(after.frames != before.frames)

        let take = try #require(Catalog.take(for: "layout.outer-gap", config: Config()))
        #expect(take.isStatic, "geometry needs no script")
        #expect(take.scene == Scenes.threeColumns)
    }

    /// **Outer gaps sit with the other gaps, not after the preset lists.** Asked of the panel the slab
    /// actually built, and pinned against the document by the golden file, which writes the block in the
    /// same place — one `after` on the entry drives both, so this is the half a test can reach.
    @Test func theOuterGapRowFollowsTheOtherGaps() throws {
        let slab = ControlSlab()
        slab.show(try Draft(""))
        let keys = slab.controls.map(\.key)
        #expect(keys.prefix(3) == ["layout.column-gap", "layout.window-gap", "layout.outer-gap"])

        // …and the document agrees, which is what `after` is for.
        let document = ConfigSchema.document
        let window = try #require(document.range(of: "window-gap = "))
        let outer = try #require(document.range(of: "outer-gap = "))
        let next = try #require(document.range(of: "center-focused-column = "))
        #expect(window.lowerBound < outer.lowerBound && outer.lowerBound < next.lowerBound)
    }

    /// The row lays out: four fields, in order, inside the well and clear of each other.
    ///
    /// **Written because the first version of this row was over-constrained** — four captioned fields
    /// chained leading-to-trailing and pinned to both edges of a fixed 260 pt well, whose intrinsic
    /// widths add to less than that. What that costs is a constraint broken at runtime and a row that
    /// looks nearly right, which is exactly the failure a headless layout can catch and an eye cannot.
    @Test func theOuterGapRowLaysOutInsideItsWell() throws {
        let slab = ControlSlab()
        slab.show(try Draft(""))
        slab.layoutSubtreeIfNeeded()

        let fields = Self.fields(in: slab).filter { $0.toolTip != nil }
        #expect(fields.count == 4)

        let frames = fields.map { $0.convert($0.bounds, to: slab) }.sorted { $0.minX < $1.minX }
        for frame in frames {
            #expect(frame.width > 0 && frame.height > 0, "a field laid out at zero size")
        }
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(left.maxX <= right.minX, "two edge fields overlap")
        }
        let span = frames[frames.count - 1].maxX - frames[0].minX
        #expect(span <= ControlRow.wellWidth, "the four fields do not fit the well")
    }

    static func fields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField, field.isBezeled { found.append(field) }
        for child in view.subviews { found += fields(in: child) }
        return found
    }
}
