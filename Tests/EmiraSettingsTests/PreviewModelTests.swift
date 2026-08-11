import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// The mock desktop's geometry. The claim under test is that it is not a second opinion: a gap the user
// types moves a mock window by the number they typed, because the frames come from `Layout` and not from
// arithmetic written here.

@Suite struct PreviewModelTests {

    /// A display, in true points. The measured one — 1800×1169 with a 39 pt menu bar.
    static let workingArea = Rect(x: 0, y: 0, width: 1800, height: 1130)

    static func config(columnGap: Double = 0, windowGap: Double = 0,
                       centerFocusedColumn: Bool = false) -> Config {
        var config = Config()
        config.columnGap = columnGap
        config.windowGap = windowGap
        config.centerFocusedColumn = centerFocusedColumn
        return config
    }

    static func state(_ config: Config, _ scene: Scene = Scenes.threeColumns) -> PreviewState {
        PreviewModel.state(of: scene, config: config, workingArea: workingArea)
    }

    // The one the phase is done when it passes.

    @Test func raisingColumnGapReflowsTheStripInsideTheSameWorkingArea() throws {
        let third = try #require(Scenes.threeColumns.columns.last?.windows.first?.id)

        let before = try #require(Self.state(Self.config(columnGap: 8)).frames[third])
        let after = try #require(Self.state(Self.config(columnGap: 18)).frames[third])

        // A proportion is a share of the extent *and* the gap it carries, so a wider gap narrows all
        // three columns and slides the later ones along. Both are ⅔ of the 10 pt rise — the third
        // column's left edge is `2(A + gap)/3` — and they cancel exactly…
        #expect(abs((after.minX - before.minX) - 20.0 / 3) < 1e-9)
        #expect(abs((before.width - after.width) - 20.0 / 3) < 1e-9)
        // …which is the property a user sees: three ⅓ columns and their two gaps fill the working area
        // at either setting, so the run ends flush with it rather than overflowing by a gap per boundary.
        #expect(abs(before.maxX - Self.workingArea.maxX) < 1e-9)
        #expect(abs(after.maxX - Self.workingArea.maxX) < 1e-9)
        #expect(after.minY == before.minY)
    }

    @Test func theWindowGapSplitsAStackedColumnAndNothingElse() throws {
        let stacked = Scenes.threeColumns.columns[1].windows
        let top = stacked[0].id
        let bottom = stacked[1].id

        let tight = Self.state(Self.config(windowGap: 0))
        let loose = Self.state(Self.config(windowGap: 10))

        // The gap opens between the two, so each takes five points out of its own height.
        let tightTop = try #require(tight.frames[top])
        let looseTop = try #require(loose.frames[top])
        #expect(tightTop.height - looseTop.height == 5)

        let looseBottom = try #require(loose.frames[bottom])
        #expect(looseBottom.minY - (looseTop.minY + looseTop.height) == 10)

        // A column that isn't stacked is untouched by it.
        let single = try #require(Scenes.threeColumns.columns.first?.windows.first?.id)
        #expect(tight.frames[single] == loose.frames[single])
    }

    @Test func theOuterGapInsetsEveryEdgeOfTheStrip() throws {
        let first = try #require(Scenes.threeColumns.columns.first?.windows.first?.id)
        var inset = Self.config()
        inset.outerGaps = EdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let flush = try #require(Self.state(Self.config()).frames[first])
        let held = try #require(Self.state(inset).frames[first])

        #expect(held.minX - flush.minX == 12)
        #expect(held.minY - flush.minY == 12)
        // Narrower by its share of the twenty-four points the strip lost.
        #expect(held.width < flush.width)
    }

    @Test func everyFrameIsInTruePointsAgainstTheRealWorkingArea() throws {
        let state = Self.state(Self.config())
        let first = try #require(Scenes.threeColumns.columns.first?.windows.first?.id)
        let frame = try #require(state.frames[first])

        // A third of an 1800 pt display, not a third of a mock. The projection by `k` happens on the way
        // to a layer and never before.
        #expect(frame.width == 600)
        #expect(frame.height == Self.workingArea.height)
    }

    @Test func centeringTheFocusedColumnReAimsTheScroll() throws {
        let plain = Self.state(Self.config(columnGap: 8, centerFocusedColumn: false),
                              Scenes.fourColumns)
        let centred = Self.state(Self.config(columnGap: 8, centerFocusedColumn: true),
                                 Scenes.fourColumns)

        // The first column is focused and already visible, so a minimal reveal does not move; centring
        // is an instruction about where the strip rests and moves it regardless.
        #expect(plain.scrollOffset == 0)
        #expect(centred.scrollOffset != plain.scrollOffset)
    }

    @Test func aStaticTakeIsTheSameAtEveryTime() {
        let take = Take(scene: Scenes.threeColumns)
        let config = Self.config(columnGap: 8)
        let first = PreviewModel.state(of: take, at: 0, config: config, workingArea: Self.workingArea)
        let later = PreviewModel.state(of: take, at: 97.3, config: config,
                                       workingArea: Self.workingArea)

        // Nothing playing means nothing moves, which is what lets an idle window run no display link.
        #expect(first == later)
    }

    @Test func theScrollOffsetIsAFoldOverTheBeatsAndNotOfTheFinalSet() {
        // The same column reached two ways. `offsetToReveal` is relative to where the strip already is,
        // so walking out to the end and stepping back lands the column against the *left* edge, while
        // arriving at it from rest leaves it against the right — same focus, two offsets.
        //
        // This is the property that would be lost if the offset were derived from the end state alone,
        // and it is what the reducer does one command at a time.
        let config = Self.config(columnGap: 8)
        let walked = Take(scene: Scenes.fourColumns,
                          beats: [(0.2, .focusRight), (0.4, .focusRight), (0.6, .focusRight),
                                  (0.8, .focusLeft)],
                          period: 10)
        let arrived = Take(scene: Scenes.fourColumns.focusing(WindowId(13)))

        let a = PreviewModel.state(of: walked, at: 1, config: config, workingArea: Self.workingArea)
        let b = PreviewModel.state(of: arrived, at: 1, config: config, workingArea: Self.workingArea)

        #expect(a.scene.focus == WindowId(13))
        #expect(b.scene.focus == WindowId(13))
        #expect(a.scrollOffset != b.scrollOffset)
        // Stepping back from the right end pulls the column's *left* edge in, so the viewport rests at
        // that edge; arriving from rest pushes its *right* edge in, a viewport-width earlier. So the
        // walked route ends further along the strip, by exactly the slack between the two framings.
        #expect(a.scrollOffset > b.scrollOffset)
    }
}
