import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// The two preset ladders. Both claims are about honesty rather than about motion: **the number of beats
// is the number of rungs the user typed**, and **a setting about heights animates a height**.

@Suite struct LadderTests {

    static let area = PreviewModelTests.workingArea

    static func config(widths: [Double]? = nil, heights: [Double]? = nil) -> Config {
        var config = Config()
        if let widths { config.widthPresets = PresetCycle(widths.map { .proportion($0) }) }
        if let heights { config.heightPresets = PresetCycle(heights.map { .proportion($0) }) }
        return config
    }

    static func take(_ key: String, _ config: Config) throws -> Take {
        try #require(Catalog.take(for: key, config: config))
    }

    static func state(_ take: Take, _ config: Config, at t: Double) -> PreviewState {
        PreviewModel.state(of: take, at: t, config: config, workingArea: area)
    }

    // Width

    @Test func threeWidthsIsThreeBeatsAndFiveIsFive() throws {
        for count in [2, 3, 5] {
            let config = Self.config(widths: (1...count).map { Double($0) / Double(count + 1) })
            let take = try Self.take("layout.width-presets", config)
            #expect(take.beats.count == count,
                    "\(count) widths typed should be \(count) rungs walked")
        }
    }

    @Test func theFocusedColumnVisitsEveryRung() throws {
        let config = Self.config(widths: [0.25, 0.5, 0.75])
        let take = try Self.take("layout.width-presets", config)
        let focus = take.scene.focus

        // One sample in the middle of each rung's beat, the resting rung included.
        let widths = (0...3).map { rung -> Double in
            let t = (Double(rung) + 0.5) * Scenes.rung
            return Self.state(take, config, at: t).frames[focus]?.width ?? 0
        }
        // Three distinct widths, and the fourth sample is back on the first — the loop returns to its
        // start by playing rather than by rewinding.
        #expect(Set(widths.prefix(3).map { ($0 * 100).rounded() }).count == 3)
        #expect(abs(widths[3] - widths[0]) < 0.001)
    }

    // Height

    @Test func theHeightLadderAnimatesAHeightAndNotAWidth() throws {
        // A setting about heights has to animate a height — the axis is the claim.
        let config = Self.config(heights: [0.25, 0.5, 0.75])
        let take = try Self.take("layout.height-presets", config)
        let focus = take.scene.focus

        let first = Self.state(take, config, at: 0.5 * Scenes.rung)
        let second = Self.state(take, config, at: 1.5 * Scenes.rung)

        let before = try #require(first.frames[focus])
        let after = try #require(second.frames[focus])
        #expect(before.height != after.height)
        #expect(before.width == after.width)
    }

    @Test func theStackmateTakesWhatTheFocusedWindowGivesUp() throws {
        // A vertical setting shown by a vertical motion — and the pair visibly *trade* the column
        // rather than one of them changing in isolation.
        let config = Self.config(heights: [0.25, 0.75])
        let take = try Self.take("layout.height-presets", config)
        let column = try #require(take.scene.focusedColumn)
        #expect(column.windows.count == 2)
        let focus = take.scene.focus
        let mate = try #require(column.windows.first { $0.id != focus }).id

        let low = Self.state(take, config, at: 1.5 * Scenes.rung)     // the first rung, a quarter
        let high = Self.state(take, config, at: 2.5 * Scenes.rung)    // the second, three quarters

        let focusedLow = try #require(low.frames[focus]).height
        let focusedHigh = try #require(high.frames[focus]).height
        let mateLow = try #require(low.frames[mate]).height
        let mateHigh = try #require(high.frames[mate]).height

        #expect(focusedHigh - focusedLow > 0)
        #expect(abs((focusedHigh - focusedLow) - (mateLow - mateHigh)) < 0.001)
    }

    @Test func theLadderIncludesTheRungTheFieldCannotSpell() throws {
        // `auto`, where the stack shares the column evenly. Cycling really does visit it, so a take
        // that stopped at the last typed height would be showing a shorter ladder than the command has.
        let config = Self.config(heights: [0.25, 0.75])
        let take = try Self.take("layout.height-presets", config)
        let focus = take.scene.focus
        let column = try #require(take.scene.focusedColumn)
        let mate = try #require(column.windows.first { $0.id != focus }).id

        // Two typed rungs plus auto is three beats, the last of which is the return to auto.
        #expect(take.beats.count == 3)
        let atRest = Self.state(take, config, at: 0.5 * Scenes.rung)
        let returned = Self.state(take, config, at: take.period - 1e-6)
        #expect(atRest.frames == returned.frames)
        // Auto is the two of them sharing.
        let top = try #require(atRest.frames[focus]).height
        let bottom = try #require(atRest.frames[mate]).height
        #expect(abs(top - bottom) < 0.001)
    }
}
