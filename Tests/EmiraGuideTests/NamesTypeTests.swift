import AppKit
import Testing
import EmiraCore
@testable import EmiraGuide

// **The one place the packing and the real face have to agree.** `NamesModel` sizes a cell by asking
// `GuideTypeface.face` how wide a word is, and `NamesGuideRenderer` then sets that word in the font the
// same type vends. If the two ever answered differently, a cell would be a fraction short of the word
// in it and the renderer would truncate a name that fits.
//
// The samples are deliberately not Latin alone. `GuideNames` resolves the **localized** name, so the
// row sets whatever the user's machine calls an app — and a character count is not a width in any
// script where a glyph is not one advance wide.

@MainActor
@Suite struct NamesTypeTests {

    /// Names a real desktop can produce: Latin, the two the guide adds itself, CJK and Kana at
    /// double width, Hangul, a combining mark, and an emoji.
    static let samples = ["terminal", "Code", "activity monitor", NamesModel.ellipsis, "²",
                          "微信", "カレンダー", "메모", "café", "Ｍail", "🅰pp"]

    static func measured(_ text: String, at size: Double) -> Double {
        Double((text as NSString).size(withAttributes: [.font: GuideTypeface.font(size: size)]).width)
    }

    @Test(arguments: [9.0, 12.0, 18.0, 32.0])
    func theFaceMeasuresWhatTheRendererWillSet(_ size: Double) {
        for text in Self.samples {
            let asked = GuideTypeface.face.width(text, size)
            let real = Self.measured(text, at: size)
            // Never short, or the renderer truncates a word the packing said would fit…
            #expect(asked >= real, "`\(text)` at \(size) packs \(asked) for \(real) of type")
            // …and never long enough to read as a gap: half a point is the rounding, and nothing more.
            #expect(asked - real < 0.5, "`\(text)` at \(size) packs \(asked - real) pt of slack")
        }
    }

    @Test func theLineBoxIsTheFacesOwn() {
        let font = GuideTypeface.font(size: 12)
        #expect(GuideTypeface.face.lineHeight(12) == Double(font.ascender - font.descender))
    }

    @Test func anEmptyRunMeasuresNothing() {
        #expect(GuideTypeface.face.width("", 12) == 0)
        // The cache answers the second ask with the first one's number, whatever order they arrive in.
        #expect(GuideTypeface.face.width("terminal", 12) == GuideTypeface.face.width("terminal", 12))
    }

    /// **The claim the whole seam exists for**, asked of the packing and the face together: a name in
    /// any script gets a cell wide enough to set it in. A character count answers this for `terminal`
    /// and gets `カレンダー` wrong by half again.
    @Test func everyNameFitsTheCellThePackingGaveIt() throws {
        let working = Rect(x: 0, y: 0, width: 4000, height: 1000)
        var frames: [WindowId: Rect] = [:]
        let columns = Self.samples.enumerated().map { index, name -> GuideInput.Column in
            let id = WindowId(UInt64(index + 1))
            frames[id] = Rect(x: Double(index) * 100, y: 0, width: 100, height: 1000)
            return GuideInput.Column(id: ColumnId(UInt64(index + 1)),
                                     windows: [GuideInput.Window(id: id, bundleId: name)])
        }
        let input = GuideInput(workingArea: working, columns: columns, frames: frames)
        let model = try #require(NamesModel.model(input,
                                                  settings: NamesGuideSettings(enabled: true,
                                                                               lowercase: false),
                                                  face: GuideTypeface.face, name: { $0 }))

        #expect(model.cells.count == Self.samples.count)   // nothing elided, or the claim is thinner
        for cell in model.cells {
            #expect(cell.labelRect.width >= Self.measured(cell.label, at: model.metrics.fontSize),
                    "`\(cell.label)` is wider than the \(cell.labelRect.width) pt cell packed for it")
        }
    }
}
