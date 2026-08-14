import Foundation
import Testing
@testable import EmiraCore

// The names guide's packing: what each column is called, what the row does when it will not fit, and
// where every rectangle lands. The **measurement is the test's own** — a stub face, six tenths of an em
// a character — so these numbers describe the packing rather than whatever the system font happens to
// do this release. `EmiraGuideTests/NamesTypeTests` is where the real face meets it.

@Suite struct NamesModelTests {

    static let working = Rect(x: 0, y: 0, width: 1000, height: 800)

    /// A face with no font behind it, and monospaced on purpose: a width the test can predict.
    static let face = GuideFace(width: { text, size in 0.6 * size * Double(text.count) },
                                lineHeight: { 1.2 * $0 })

    static func metrics(_ size: Double = 10) -> NamesModel.Metrics {
        NamesModel.Metrics(fontSize: size, lineHeight: face.lineHeight(size))
    }

    static func settings(position: GuidePosition = .topCenter, width: Double = 1, gap: Double = 16,
                         fontSize: Double = 10, lowercase: Bool = true,
                         maxColumns: Int = 0) -> NamesGuideSettings {
        NamesGuideSettings(enabled: true, position: position, width: width, gap: gap,
                           fontSize: fontSize, lowercase: lowercase, maxColumns: maxColumns)
    }

    /// A strip of `columns`, each a stack of `(id, app)` pairs, laid out left to right at 200 points a
    /// column — the geometry only has to say which window is largest and where the strip is.
    static func input(_ columns: [[(UInt64, String)]], focus: UInt64? = nil,
                      heights: [UInt64: Double] = [:]) -> GuideInput {
        var frames: [WindowId: Rect] = [:]
        var x = 0.0
        let strip = columns.enumerated().map { index, stack -> GuideInput.Column in
            var y = 0.0
            for (id, _) in stack {
                let height = heights[id] ?? (working.height / Double(stack.count))
                frames[WindowId(id)] = Rect(x: x, y: y, width: 200, height: height)
                y += height
            }
            x += 200
            return GuideInput.Column(id: ColumnId(UInt64(index + 1)),
                                     windows: stack.map {
                                         GuideInput.Window(id: WindowId($0.0), bundleId: $0.1)
                                     })
        }
        return GuideInput(workingArea: working, columns: strip, frames: frames,
                          focus: focus.map(WindowId.init))
    }

    /// A strip of `count` singleton columns, all named the same, for asking what a long row does.
    static func strip(_ count: Int, named name: String = "app", focus: UInt64? = nil) -> GuideInput {
        input((1...count).map { [(UInt64($0), name)] }, focus: focus)
    }

    /// The label is the bundle id, so a test reads what it wrote.
    static func model(_ input: GuideInput, _ settings: NamesGuideSettings) throws -> NamesModel {
        try #require(NamesModel.model(input, settings: settings, face: face, name: { $0 }))
    }

    // One cell per column, named after its largest window

    @Test func aCellPerColumnInStripOrder() throws {
        let model = try Self.model(Self.input([[(1, "Code")], [(2, "Safari")], [(3, "Music")]]),
                                   Self.settings())
        #expect(model.cells.map(\.label) == ["code", "safari", "music"])
        #expect(model.cells.allSatisfy { $0.depth == 1 })
        #expect(model.elidedLeading == 0 && model.elidedTrailing == 0)
    }

    @Test func aColumnIsNamedAfterItsLargestWindow() throws {
        // Two in one column, the second taking three quarters of it: the column is that app's.
        let input = Self.input([[(1, "Code"), (2, "Ghostty")]], heights: [1: 200, 2: 600])
        #expect(try Self.model(input, Self.settings()).cells.first?.label == "ghostty")
    }

    /// **The count is its own run**, so it is never part of the word and never truncated with it.
    @Test func aStackedColumnCarriesItsCountAndASingletonDoesNot() throws {
        let model = try Self.model(Self.input([[(1, "Code")], [(2, "Ghostty"), (3, "Code")]]),
                                   Self.settings())
        #expect(model.cells[0].count == "")                 // a `¹` on every cell would be noise
        #expect(model.cells[0].depth == 1)
        #expect(model.cells[1].depth == 2)
        #expect(model.cells[1].label == "ghostty")
        #expect(model.cells[1].count == "²")
    }

    @Test func aCountIsSpelledInSuperscriptDigits() {
        #expect(NamesModel.superscript(1) == "")
        #expect(NamesModel.superscript(2) == "²")
        #expect(NamesModel.superscript(12) == "¹²")
        #expect(NamesModel.superscript(0) == "")
    }

    @Test func lowercaseIsTheSettingAndNotTheRule() throws {
        let input = Self.input([[(1, "Code")]])
        #expect(try Self.model(input, Self.settings(lowercase: false)).cells[0].label == "Code")
        #expect(try Self.model(input, Self.settings(lowercase: true)).cells[0].label == "code")
    }

    @Test func theFocusedColumnsCellIsTheOneMarked() throws {
        let model = try Self.model(Self.input([[(1, "Code")], [(2, "Ghostty"), (3, "Code")]], focus: 3),
                                   Self.settings())
        #expect(model.cells.map(\.isFocused) == [false, true])   // focus is the *column*, not the window
    }

    @Test func aDisplayHoldingNoFocusMarksNothing() throws {
        let model = try Self.model(Self.input([[(1, "Code")], [(2, "Safari")]]), Self.settings())
        #expect(model.cells.allSatisfy { !$0.isFocused })
    }

    // Every length is the type size, and every width is measured

    @Test func aCellsWidthTracksTheTypeSize() throws {
        func width(_ size: Double) throws -> Double {
            try #require(Self.model(Self.input([[(1, "Code")]]),
                                    Self.settings(fontSize: size)).cells.first).rect.width
        }
        // Doubling the type doubles the cell, padding and all — one number sizes the guide.
        let (small, large) = (try width(10), try width(20))
        #expect(abs(large - small * 2) < 1e-9)
        // And it is the *measured* word that fills it, plus the gutter it carries either side.
        let long = try #require(Self.model(Self.input([[(1, "Terminal")]]),
                                           Self.settings()).cells.first)
        #expect(abs(long.rect.width - (Self.face.width("terminal", 10)
                                       + Self.metrics().hPad * 2)) < 1e-9)
    }

    @Test func thePanelIsTheRowPlusItsPaddingAndSitsWhereTheAnchorSays() throws {
        let metrics = Self.metrics()
        let model = try Self.model(Self.input([[(1, "Code")], [(2, "Safari")]]),
                                   Self.settings(position: .topLeft, gap: 16))
        let row = model.cells.map(\.rect.width).reduce(0, +)
        #expect(abs(model.panel.width - (row + metrics.padding * 2)) < 1e-9)
        #expect(abs(model.panel.height - (metrics.cellHeight + metrics.padding * 2)) < 1e-9)
        // The shared anchoring, so a text-derived size lands where a projected one would.
        #expect(model.panel == GuideModel.place(size: model.panel.size, within: Self.working,
                                                position: .topLeft, gap: 16))
    }

    /// **The cells tile the row**, so the gutter between two of them belongs to both — half from each
    /// side. A gap here would be ribbon belonging to neither, and the focus fill would stop short of it.
    @Test func theCellsRunLeftToRightInsideThePaddingAndAbut() throws {
        let metrics = Self.metrics()
        let model = try Self.model(Self.input([[(1, "Code")], [(2, "Safari")], [(3, "Music")]]),
                                   Self.settings())
        #expect(abs(model.cells[0].rect.minX - metrics.padding) < 1e-9)
        for (left, right) in zip(model.cells, model.cells.dropFirst()) {
            #expect(abs(right.rect.minX - left.rect.maxX) < 1e-9)
        }
        #expect(abs(model.panel.width - model.cells[2].rect.maxX - metrics.padding) < 1e-9)
        #expect(model.cells.allSatisfy { $0.rect.minY == metrics.padding })
    }

    /// The gutter is shared, so the fill's edge lands **exactly halfway between the two words** it comes
    /// between — which is the whole of what tiling buys, stated in the terms a reader sees.
    @Test func theSeamBetweenTwoCellsIsTheMidpointOfTheirWords() throws {
        let metrics = Self.metrics()
        let model = try Self.model(Self.input([[(1, "Code")], [(2, "Safari")]]), Self.settings())
        let (left, right) = (model.cells[0], model.cells[1])
        // Where the words themselves end and start: the cell, less the half-gutter it carries.
        let wordEnds = left.rect.maxX - metrics.hPad
        let wordStarts = right.rect.minX + metrics.hPad
        #expect(abs(left.rect.maxX - (wordEnds + wordStarts) / 2) < 1e-9)
        // …and the words stand one whole gutter apart, not two paddings and a gap.
        #expect(abs(wordStarts - wordEnds - metrics.hPad * 2) < 1e-9)
    }

    /// A word sits on one line box in the middle of its cell, and the count follows it immediately —
    /// the renderer places these and measures nothing.
    @Test func theRunsAreLaidOutInsideTheGutters() throws {
        let metrics = Self.metrics()
        let model = try Self.model(Self.input([[(1, "Ghostty"), (2, "Code")]]), Self.settings())
        let cell = try #require(model.cells.first)
        #expect(abs(cell.labelRect.width - Self.face.width("ghostty", 10)) < 1e-9)
        #expect(abs(cell.countRect.minX - cell.labelRect.maxX) < 1e-9)
        #expect(abs(cell.countRect.width - Self.face.width("²", 10)) < 1e-9)
        #expect(cell.labelRect.height == metrics.lineHeight)
        // Centred in the cell, top and bottom.
        #expect(abs(cell.labelRect.minY - (cell.rect.minY + metrics.vPad)) < 1e-9)
        // …and inside the gutters, so no run reaches the seam it shares with its neighbour.
        #expect(cell.labelRect.minX >= cell.rect.minX + metrics.hPad - 1e-9)
        #expect(cell.countRect.maxX <= cell.rect.maxX - metrics.hPad + 1e-9)
    }

    // What does not fit

    @Test func theWholeStripIsNamedByDefault() throws {
        let model = try Self.model(Self.strip(9), Self.settings(maxColumns: 0))
        #expect(model.cells.count == 9)
        #expect(model.cells.allSatisfy { $0.label != NamesModel.ellipsis })
    }

    @Test func maxColumnsElidesTheEndAwayFromFocus() throws {
        let strip = (1...9).map { [(UInt64($0), "App\($0)")] }
        // Focus at the left end: the window pins there and the right-hand columns are what go.
        let left = try Self.model(Self.input(strip, focus: 1), Self.settings(maxColumns: 3))
        #expect(left.elidedLeading == 0)
        #expect(left.elidedTrailing == 6)
        #expect(left.cells.map(\.label) == ["app1", "app2", "app3", NamesModel.ellipsis])

        // …and at the right end it is the left-hand ones.
        let right = try Self.model(Self.input(strip, focus: 9), Self.settings(maxColumns: 3))
        #expect(right.elidedLeading == 6)
        #expect(right.elidedTrailing == 0)
        #expect(right.cells.map(\.label) == [NamesModel.ellipsis, "app7", "app8", "app9"])

        // In the middle the window follows focus, centred on it, and both ends are marked.
        let middle = try Self.model(Self.input(strip, focus: 5), Self.settings(maxColumns: 3))
        #expect(middle.elidedLeading == 3 && middle.elidedTrailing == 3)
        #expect(middle.cells.first?.label == NamesModel.ellipsis)
        #expect(middle.cells.last?.label == NamesModel.ellipsis)
        #expect(middle.cells.contains { $0.isFocused })
    }

    @Test func anElisionCellIsACellLikeAnyOther() throws {
        let model = try Self.model(Self.strip(9, focus: 1), Self.settings(maxColumns: 3))
        let ellipsis = try #require(model.cells.last)
        // Placed and sized by the same packing, so the renderer has one kind of thing to draw…
        #expect(ellipsis.rect.height == model.cells[0].rect.height)
        // …and it stands for columns rather than being one, which `depth` says.
        #expect(ellipsis.depth == 0)
        #expect(!ellipsis.isFocused)
    }

    @Test func aLimitTheStripDoesNotReachElidesNothing() throws {
        let model = try Self.model(Self.input([[(1, "Code")], [(2, "Safari")]]),
                                   Self.settings(maxColumns: 5))
        #expect(model.cells.count == 2)
        #expect(model.elidedLeading == 0 && model.elidedTrailing == 0)
    }

    // What does not fit the width

    /// **The row never outgrows the display it is on.** A strip is infinite and a screen is not, so
    /// without a ceiling a long one places its panel off the edge and the columns nearest you are the
    /// ones that go missing.
    @Test(arguments: [1, 4, 12, 40, 120])
    func theRowIsAlwaysInsideTheWorkingArea(_ columns: Int) throws {
        let model = try Self.model(Self.strip(columns, named: "activity monitor"), Self.settings())
        #expect(model.panel.minX >= Self.working.minX)
        #expect(model.panel.maxX <= Self.working.maxX)
        #expect(model.panel.minY >= Self.working.minY)
        #expect(model.panel.maxY <= Self.working.maxY)
    }

    /// `width` is the ceiling, and the row takes only what it needs below it.
    @Test func widthCapsTheRowAndDoesNotStretchIt() throws {
        let narrow = try Self.model(Self.strip(20, named: "terminal"), Self.settings(width: 0.5))
        #expect(narrow.panel.width <= 0.5 * Self.working.width + 1e-9)
        // A row that already fits is left alone — a ceiling, not a frame.
        let short = try Self.model(Self.input([[(1, "Code")]]), Self.settings(width: 1))
        let capped = try Self.model(Self.input([[(1, "Code")]]), Self.settings(width: 0.9))
        #expect(short.panel.width == capped.panel.width)
    }

    /// **Crowding is shared, not taken from one end.** Every cell that asked for more than its share
    /// gets the same width, and the ones that asked for less keep what they asked for.
    @Test func aCrowdedRowGivesEveryLongWordTheSameWidth() throws {
        let input = Self.input([[(1, "a")], [(2, "an extremely long application name")],
                                [(3, "another extremely long application name")],
                                [(4, "bb")]])
        let model = try Self.model(input, Self.settings(width: 0.25))
        let metrics = Self.metrics()
        // The two short ones are under the fair share, so they are untouched…
        #expect(abs(model.cells[0].rect.width
                    - (Self.face.width("a", 10) + metrics.hPad * 2)) < 1e-9)
        #expect(abs(model.cells[3].rect.width
                    - (Self.face.width("bb", 10) + metrics.hPad * 2)) < 1e-9)
        // …and the two that did not fit are crowded to exactly the same width as each other.
        #expect(abs(model.cells[1].rect.width - model.cells[2].rect.width) < 1e-9)
        #expect(model.cells[1].labelRect.width < Self.face.width(model.cells[1].label, 10))
        // The row is the budget, spent.
        #expect(model.panel.width <= 0.25 * Self.working.width + 1e-9)
    }

    /// The share is max-min fair, which is what a run of rounds converges to and this reaches directly.
    @Test func theShareIsWhatRoundsWouldHaveConvergedTo() {
        #expect(NamesModel.share([1, 2, 3], within: 12) == [1, 2, 3])       // room to spare
        #expect(NamesModel.share([2, 5, 5], within: 12) == [2, 5, 5])       // exactly enough
        // 2 is under its third, so the other two split the 10 that are left.
        #expect(NamesModel.share([2, 8, 8], within: 12) == [2, 5, 5])
        #expect(NamesModel.share([9, 9, 9], within: 12) == [4, 4, 4])
        // Order is the caller's, not the sort's.
        #expect(NamesModel.share([8, 2, 8], within: 12) == [5, 2, 5])
    }

    /// **The floor is a crowding rule and not a column limit.** A row the words already fit into is
    /// never cut for it — a short name has every right to a cell narrower than the floor, because
    /// nothing is being taken away from it.
    @Test func aRowThatFitsIsNeverCutForTheFloor() throws {
        let model = try Self.model(Self.strip(19, named: "safari"), Self.settings())
        #expect(model.cells.count == 19)
        #expect(model.elidedLeading == 0 && model.elidedTrailing == 0)
        #expect(model.cells.contains { $0.rect.width < Self.metrics().minimumCell })
    }

    /// **A word squeezed past legibility is a column not worth naming.** Below the floor the row elides
    /// from the ends instead of handing out slivers.
    @Test func aRowTooCrowdedToReadElidesRatherThanSmearing() throws {
        let model = try Self.model(Self.strip(60, named: "terminal", focus: 30),
                                   Self.settings(width: 0.3))
        let metrics = Self.metrics()
        #expect(model.cells.count < 60)
        // Every column still named has room to be a word. An elision mark is one glyph and asks for
        // less, which is why the floor is a claim about the cells that carry names.
        #expect(model.cells.filter { $0.depth > 0 }
            .allSatisfy { $0.rect.width >= metrics.minimumCell - 1e-9 })
        // What went is stated at both ends, since focus is in the middle of the strip.
        #expect(model.elidedLeading > 0 && model.elidedTrailing > 0)
        #expect(model.cells.first?.label == NamesModel.ellipsis)
        #expect(model.cells.last?.label == NamesModel.ellipsis)
    }

    /// A crowded cell gives up letters of its **name** and keeps its count, which is the whole reason
    /// the two are separate runs.
    @Test func theCountSurvivesACellTooNarrowForItsName() throws {
        let input = Self.input([[(1, "an extremely long application name"), (2, "Code")],
                                [(3, "another extremely long application name")]])
        let model = try Self.model(input, Self.settings(width: 0.1))
        let cell = try #require(model.cells.first)
        #expect(cell.count == "²")
        #expect(abs(cell.countRect.width - Self.face.width("²", 10)) < 1e-9)
        // The name is what gave way, and the two runs still abut inside the gutters.
        #expect(cell.labelRect.width < Self.face.width(cell.label, 10))
        #expect(abs(cell.countRect.minX - cell.labelRect.maxX) < 1e-9)
        #expect(cell.countRect.maxX <= cell.rect.maxX - Self.metrics().hPad + 1e-9)
    }

    // Nothing to draw

    @Test func anEmptyStripHasNoGuideAtAll() {
        let empty = GuideInput(workingArea: Self.working, columns: [], frames: [:])
        #expect(NamesModel.model(empty, settings: Self.settings(), face: Self.face,
                                 name: { $0 }) == nil)
        // …and a column whose windows have no frames is a column with nothing on it.
        let unplaced = GuideInput(workingArea: Self.working,
                                  columns: [GuideInput.Column(id: ColumnId(1), windows: [
                                      GuideInput.Window(id: WindowId(1), bundleId: "Code"),
                                  ])],
                                  frames: [:])
        #expect(NamesModel.model(unplaced, settings: Self.settings(), face: Self.face,
                                 name: { $0 }) == nil)
    }

    @Test func aDegenerateTypeSizeDrawsNothing() {
        #expect(NamesModel.model(Self.input([[(1, "Code")]]), settings: Self.settings(fontSize: 0),
                                 face: Self.face, name: { $0 }) == nil)
    }

    /// A width with no room left in it after the ribbon's own inset is a guide with nowhere to draw,
    /// which is `nil` rather than a panel of padding.
    @Test func aWidthTooSmallToHoldACellDrawsNothing() {
        #expect(NamesModel.model(Self.input([[(1, "Code")]]),
                                 settings: Self.settings(width: 0.001), face: Self.face,
                                 name: { $0 }) == nil)
    }
}
