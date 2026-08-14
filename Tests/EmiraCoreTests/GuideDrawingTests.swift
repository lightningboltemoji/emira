import Foundation
import Testing
@testable import EmiraCore

// The vocabulary both hosts count in: which guides are on, how long they stay, and what one frame of
// one is. **Each of these is one answer for the daemon and the settings window together** — two hosts
// deciding for themselves what "enabled" or "the dwell" means would drift a setting at a time, and the
// drift would be invisible to either one's own tests.

@Suite struct GuideDrawingTests {

    static let working = Rect(x: 0, y: 0, width: 1000, height: 800)

    /// The stub face, shared with the packing's own suite.
    static let face = NamesModelTests.face

    static func input(_ windows: [UInt64]) -> GuideInput {
        var frames: [WindowId: Rect] = [:]
        var columns: [GuideInput.Column] = []
        for (index, id) in windows.enumerated() {
            frames[WindowId(id)] = Rect(x: Double(index) * 500, y: 0, width: 480, height: 800)
            columns.append(GuideInput.Column(id: ColumnId(UInt64(index + 1)),
                                             windows: [GuideInput.Window(id: WindowId(id),
                                                                         bundleId: "com.test.app")]))
        }
        return GuideInput(workingArea: working, columns: columns, frames: frames)
    }

    static func settings(preview: Bool = true, names: Bool = true,
                         previewDuration: Double = 1, namesDuration: Double = 2) -> GuideSettings {
        GuideSettings(preview: PreviewGuideSettings(enabled: preview, duration: previewDuration),
                      names: NamesGuideSettings(enabled: names, duration: namesDuration))
    }

    // What is on, and for how long

    @Test func theEnabledGuidesComeBackInDrawingOrder() {
        #expect(Self.settings().enabledStyles == [.preview, .names])
        #expect(Self.settings(preview: false).enabledStyles == [.names])
        #expect(Self.settings(preview: false, names: false).enabledStyles.isEmpty)
        // …which is `allCases`' own order, the one both hosts build their renderers from.
        #expect(GuideStyle.allCases == [.preview, .names])
    }

    /// **A guide's table is reached through `GuideTable`**, so what every guide carries is one lookup
    /// and not a switch per key — and a dwell is the guide's own, never the pair's.
    @Test func aStyleResolvesToItsOwnTable() {
        let settings = Self.settings()
        #expect(settings.table(of: .preview).duration == 1)
        #expect(settings.table(of: .names).duration == 2)
        #expect(settings.table(of: .preview).position == settings.preview.position)
        #expect(settings.table(of: .names).position == settings.names.position)
    }

    // One frame of one guide

    @Test func aDrawingCarriesTheStyleAndThePanelTheModelPlaced() throws {
        let settings = Self.settings()
        let preview = try #require(GuideDrawing.of(.preview, input: Self.input([1, 2]),
                                                   settings: settings, face: Self.face))
        let names = try #require(GuideDrawing.of(.names, input: Self.input([1, 2]),
                                                 settings: settings, face: Self.face))
        #expect(preview.style == .preview)
        #expect(names.style == .names)
        // The panel is the model's own, which is what lets a host frame a camera and seed a spring on
        // it without holding a font or a layer.
        #expect(preview.panel == GuideModel.layout(Self.input([1, 2]),
                                                   settings: settings.preview)?.panel)
        #expect(names.panel == NamesModel.model(Self.input([1, 2]), settings: settings.names,
                                                face: Self.face, name: { $0 })?.panel)
    }

    /// **Nothing to draw is `nil`, and the two guides answer an empty strip differently.** The screen
    /// you are on is still a screen, so the minimap draws an empty ribbon; a row of names has no column
    /// to name and has nothing to say at all. Both hosts show nothing for the `nil`, which is the whole
    /// of why it is one value rather than a decision each of them makes.
    @Test func anEmptyStripLeavesTheMinimapARibbonAndTheNamesGuideNothing() throws {
        let empty = Self.input([])
        let ribbon = try #require(GuideDrawing.of(.preview, input: empty, settings: Self.settings(),
                                                  face: Self.face))
        #expect(ribbon == .preview(try #require(GuideModel.layout(empty,
                                                                  settings: Self.settings().preview))))
        #expect(!ribbon.panel.isEmpty)

        #expect(GuideDrawing.of(.names, input: empty, settings: Self.settings(),
                                face: Self.face) == nil)
    }

    @Test func aDisplayWithNoWorkingAreaDrawsNeither() {
        let nothing = GuideInput(workingArea: .zero, columns: [], frames: [:])
        for style in GuideStyle.allCases {
            #expect(GuideDrawing.of(style, input: nothing, settings: Self.settings(),
                                    face: Self.face) == nil)
        }
    }

    /// **No guide is ever placed outside the display it is on**, whatever the strip does. Each bounds
    /// its own panel before it places one — the minimap through `width`/`span`, the row of names through
    /// its own `width` — because `place` is given a size and can only anchor what it is handed.
    @Test(arguments: [1, 3, 12, 60, 200])
    func neitherGuideOutgrowsTheWorkingArea(_ columns: Int) throws {
        let input = Self.input((1...UInt64(columns)).map { $0 })
        for style in GuideStyle.allCases {
            let panel = try #require(GuideDrawing.of(style, input: input, settings: Self.settings(),
                                                     face: Self.face,
                                                     name: { _ in "activity monitor" })).panel
            #expect(panel.minX >= Self.working.minX && panel.maxX <= Self.working.maxX,
                    "\(style) at \(columns) columns runs off the display: \(panel)")
            #expect(panel.minY >= Self.working.minY && panel.maxY <= Self.working.maxY,
                    "\(style) at \(columns) columns runs off the display: \(panel)")
        }
    }

    /// The word a cell is set in comes from the caller, because only one guide needs one and the input
    /// is shared.
    @Test func onlyTheNamesGuideAsksWhatAnAppIsCalled() throws {
        var asked: [String] = []
        _ = GuideDrawing.of(.preview, input: Self.input([1]), settings: Self.settings(),
                            face: Self.face, name: { asked.append($0); return $0 })
        #expect(asked.isEmpty)

        _ = GuideDrawing.of(.names, input: Self.input([1]), settings: Self.settings(),
                            face: Self.face, name: { asked.append($0); return "Editor" })
        #expect(asked == ["com.test.app"])
    }
}
