import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// Hand-driven travel, and where it comes to rest. A swipe, a direction and a detent are each about the
// strip under a hand, so each is shown by one — the strip tracking the fingers 1:1 and then coasting.

@Suite struct HandTravelTests {

    static let area = PreviewModelTests.workingArea

    static func config(_ mode: TrackpadScrollMode = .magnet,
                       direction: TrackpadScrollDirection = .standard,
                       detent: Bool = false) -> Config {
        var config = Config()
        config.trackpadScroll = mode
        config.trackpadScrollDirection = direction
        config.resizeDetent = detent
        return config
    }

    static func state(_ key: String, _ config: Config, at t: Double) throws -> PreviewState {
        let take = try #require(Catalog.take(for: key, config: config))
        return PreviewModel.state(of: take, at: t, config: config, workingArea: area)
    }

    static func swipe(_ config: Config, at t: Double) throws -> PreviewState {
        try state("mouse.trackpad-scroll", config, at: t)
    }

    // The swipe

    @Test func theStripTracksTheFingersLinearly() throws {
        // A hand does not ease. Equal steps of time are equal steps of strip.
        let config = Self.config()
        let samples = try [1.0, 1.2, 1.4, 1.6].map { try Self.swipe(config, at: $0).scrollOffset }
        let steps = zip(samples.dropFirst(), samples).map(-)
        for step in steps { #expect(abs(step - steps[0]) < 0.001) }
        #expect(steps[0] > 0)
    }

    @Test func theViewDrawsAHandExactlyWhereTheModelPutsIt() throws {
        // Which is what `Travel.hand` is for: a spring easing under the fingers is the single most
        // common way a demo feels fake.
        #expect(try Self.swipe(Self.config(), at: 1.2).travel == .hand)
        #expect(try Self.swipe(Self.config(), at: 2.0).travel == .glide)
    }

    @Test func thePointerDoesNotMoveAtAll() throws {
        // A trackpad scroll moves the strip, not the cursor.
        let config = Self.config()
        let before = try #require(Self.swipe(config, at: 0.5).pointer)
        let during = try #require(Self.swipe(config, at: 1.3).pointer)
        let after = try #require(Self.swipe(config, at: 2.5).pointer)
        #expect(before == during)
        #expect(before == after)
    }

    @Test func magnetSettlesFlushAndFreeDoesNot() throws {
        let magnet = try Self.swipe(Self.config(.magnet), at: 2.5)
        let free = try Self.swipe(Self.config(.free), at: 2.5)
        #expect(magnet.scrollOffset != free.scrollOffset)

        // Flush means a column edge on the viewport's edge, which is exactly what the magnet answers.
        let take = try #require(Catalog.take(for: "mouse.trackpad-scroll", config: Self.config()))
        let metrics = PreviewModel.metrics(for: Self.config(), workingArea: Self.area)
        let nearest = take.scene.layout.magnetScrollOffset(nearest: free.scrollOffset,
                                                           metrics: metrics, centered: false)
        #expect(abs(magnet.scrollOffset - magnet.scrollOffset) < 0.001)
        #expect(abs(free.scrollOffset - nearest) > 1, "free must rest plainly between two edges")
    }

    @Test func theFlushTickIsDrawnOnlyWhereThereIsSomethingFlush() throws {
        // A mark claiming an alignment that is not there would be the one lie in the window.
        #expect(try Self.swipe(Self.config(.magnet), at: 2.5).mark != nil)
        #expect(try Self.swipe(Self.config(.free), at: 2.5).mark == nil)
        // And it is brief: asked for over one beat and gone by the next.
        #expect(try Self.swipe(Self.config(.magnet), at: 3.2).mark == nil)
    }

    @Test func offNeverMovesTheStripAndSaysSoWithTheCue() throws {
        let config = Self.config(.off)
        let rest = try Self.swipe(config, at: 0.2).scrollOffset
        for t in [1.2, 1.8, 2.5, 3.0] {
            #expect(try Self.swipe(config, at: t).scrollOffset == rest)
        }
        let cue = try #require(Self.swipe(config, at: 1.2).scene.cue)
        #expect(cue.answer == .declined)
    }

    @Test func theGlyphIsFixedRightwardAndTheStripIsWhatFlips() throws {
        // You cannot change which way you swiped, only what it does. Fixing the hand and flipping the
        // world is the right way round.
        let standard = try Self.swipe(Self.config(.free, direction: .standard), at: 1.4)
        let natural = try Self.swipe(Self.config(.free, direction: .natural), at: 1.4)

        #expect(standard.scene.cue == natural.scene.cue)
        #expect(standard.scene.cue?.glyph == .swipe(.right))
        // Opposite sides of where the strip started.
        let rest = try Self.swipe(Self.config(.free), at: 0.2).scrollOffset
        #expect((standard.scrollOffset - rest) * (natural.scrollOffset - rest) < 0)
    }

    // The detent

    /// The width at rest, and after each of the two presses.
    static func widths(_ detent: Bool) throws -> [Double] {
        let config = Self.config(detent: detent)
        return try [0.4, 1.6, 3.0].map { t in
            let state = try Self.state("layout.resize-detent", config, at: t)
            return try #require(state.frames[state.scene.focus]).width
        }
    }

    /// What one press asks for, in true points on the test display.
    static var step: Double {
        PreviewModel.metrics(for: Self.config(), workingArea: Self.area).contentArea.width
            * Scenes.growStep / 100
    }

    @Test func theFirstPressTakesItsWholeDeltaAndTheSecondArrivesShort() throws {
        let caught = try Self.widths(true)
        let straight = try Self.widths(false)

        // The first is the same either way — a detent catches, it never pulls — and it is the whole
        // delta, so the two presses are visibly the same press.
        #expect(abs(caught[0] - straight[0]) < 0.001)
        #expect(abs(caught[1] - (caught[0] + Self.step)) < 0.001)
        #expect(abs(straight[2] - (straight[1] + Self.step)) < 0.001)
        // And the second arrives at a fraction of it. A quarter is the number the set is built for;
        // what the test pins is that nobody has to be told which is which.
        let notch = caught[2] - caught[1]
        #expect(notch > 0, "the press still moves the column")
        #expect(notch < Self.step / 3)
    }

    @Test func theCatchIsWhereTheStripMeetsTheScreensEdge() throws {
        // Not a number written into the take: the column stops where the strip runs out of screen, and
        // that is what the mark then claims.
        let state = try Self.state("layout.resize-detent", Self.config(detent: true), at: 3.0)
        let area = PreviewModel.metrics(for: Self.config(), workingArea: Self.area).contentArea
        let strip = state.scene.columns.compactMap { column in
            column.windows.compactMap { state.frames[$0.id] }.first
        }
        #expect(abs((strip.map(\.maxX).max() ?? 0) - area.maxX) < 0.5)
    }

    @Test func offCarriesTheNeighbourOffTheScreen() throws {
        // The other half of the same picture, and the reason the take is wide: unchecked, the second
        // press pushes the strip clean past the edge it would have stopped at.
        let state = try Self.state("layout.resize-detent", Self.config(detent: false), at: 3.0)
        let area = PreviewModel.metrics(for: Self.config(), workingArea: Self.area).contentArea
        let neighbour = try #require(state.frames[WindowId(72)])
        #expect(neighbour.maxX > area.maxX + area.width * 0.15)
    }

    @Test func theCatchIsMarkedAndOnlyWhenItCatches() throws {
        #expect(try Self.state("layout.resize-detent", Self.config(detent: true), at: 3.0).mark != nil)
        #expect(try Self.state("layout.resize-detent", Self.config(detent: false), at: 3.0).mark == nil)
    }

    @Test func bothPressesAreCuedAsTheCommandTheyAre() throws {
        // A grow has no cause the desktop can show, and the two presses say the same words — what
        // differs is what is done with them.
        for t in [1.2, 2.8] {
            let cue = try #require(Self.state("layout.resize-detent", Self.config(detent: true),
                                              at: t).scene.cue)
            #expect(cue.glyph == .command("grow 30%"))
            #expect(cue.answer == .taken, "a grow cut short is still a grow taken")
        }
    }

    @Test func theSetStagesItsOwnDistanceToTheEdge() throws {
        // The detent is a distance to the screen's edge, and off a user's own ladder that distance is
        // anything at all. These two widths are the take's, so the first press always completes and the
        // second always catches — whatever `width-presets` says.
        var wide = Self.config(detent: true)
        wide.widthPresets = PresetCycle([.proportion(0.9), .proportion(1.0)])
        let take = try #require(Catalog.take(for: "layout.resize-detent", config: wide))
        let rest = PreviewModel.state(of: take, at: 0.4, config: wide, workingArea: Self.area)
        let first = PreviewModel.state(of: take, at: 1.6, config: wide, workingArea: Self.area)
        let resting = try #require(rest.frames[rest.scene.focus]).width
        #expect(abs((try #require(first.frames[first.scene.focus])).width - (resting + Self.step))
                    < 0.001)
    }
}
