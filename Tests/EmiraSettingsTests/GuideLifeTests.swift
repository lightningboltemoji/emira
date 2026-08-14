import Testing
import EmiraConfig
import EmiraCore
import EmiraGuide
@testable import EmiraSettings

// The two guides' fifteen settings. A guide is **raised by motion and lowered by `duration`**, as the
// daemon does it, so its whole life cycle is on screen every few seconds — and disabled genuinely means
// nothing appears.

@Suite struct GuideLifeTests {

    static let area = PreviewModelTests.workingArea

    static func config(_ change: (inout Config) -> Void = { _ in }) -> Config {
        var config = Config()
        config.guide.preview.enabled = true
        change(&config)
        return config
    }

    /// The same, with the names guide on instead — the mock is one desktop and two guides in one corner
    /// would overlap, so each suite of settings gets the set to itself unless it is asking about both.
    static func named(_ change: (inout Config) -> Void = { _ in }) -> Config {
        var config = Config()
        config.guide.names.enabled = true
        change(&config)
        return config
    }

    /// Both on, in two corners — what a claim made about *every* guide setting has to be checked under,
    /// since a style that is off has no panel and therefore no framing to be wrong about.
    static func both() -> Config {
        var config = Config()
        config.guide.preview.enabled = true
        config.guide.preview.position = .topRight
        config.guide.names.enabled = true
        config.guide.names.position = .bottomCenter
        return config
    }

    static func state(_ key: String, _ config: Config, at t: Double) throws -> PreviewState {
        let take = try #require(Catalog.take(for: key, config: config))
        return PreviewModel.state(of: take, at: t, config: config, workingArea: area)
    }

    @Test func theSetIsThreeScreensLong() throws {
        // `scale = min(width,1)/span` shrinks the panel to a short strip, so a shorter set makes both
        // `width` and `span` read as broken rather than as settings.
        let state = try Self.state("guide.preview.span", Self.config(), at: 0)
        let strip = state.frames.values.reduce(Rect?.none) { union, frame in
            union.map { $0.union(frame) } ?? frame
        }
        #expect(try #require(strip).width > Self.area.width * 2.5)
    }

    @Test func aLoopOpensWithNoGuideOnTheDesktop() throws {
        // And that is what makes the arrival something you watch happen.
        #expect(try Self.state("guide.preview.enabled", Self.config(), at: 0.1).guides.isEmpty)
        #expect(try !Self.state("guide.preview.enabled", Self.config(), at: 0.8).guides.isEmpty)
    }

    @Test func theGuideIsLoweredByDuration() throws {
        let brief = Self.config { $0.guide.preview.duration = 0.5 }
        let long = Self.config { $0.guide.preview.duration = 3.0 }

        // The motion is at 0.6; sampled at 1.9 the short one has been away for most of a second and the
        // long one has not gone yet.
        #expect(try Self.state("guide.preview.duration", brief, at: 1.9).guides.isEmpty)
        #expect(try !Self.state("guide.preview.duration", long, at: 1.9).guides.isEmpty)
    }

    @Test func thePeriodIsDerivedFromTheValueOfTheGuideBeingEdited() throws {
        func period(_ key: String, _ config: Config) throws -> Double {
            try #require(Catalog.take(for: key, config: config)).period
        }
        // At `duration = 4` the loop is long enough that the guide has been away before it starts again.
        #expect(try period("guide.preview.duration", Self.config { $0.guide.preview.duration = 4 })
                    > period("guide.preview.duration", Self.config { $0.guide.preview.duration = 1 }))
        #expect(try period("guide.preview.duration", Self.config { $0.guide.preview.duration = 4 }) > 4)
        // …and the names guide's own loop is paced by *its* duration, not by the minimap's.
        #expect(try period("guide.names.duration", Self.named { $0.guide.names.duration = 4 })
                    > period("guide.names.duration", Self.named { $0.guide.names.duration = 1 }))
    }

    /// **Two guides, two clocks.** The one whose `duration` has run out goes while the other stays,
    /// which is the daemon's own arming and the whole of what two duration settings mean.
    @Test func theShorterGuideLeavesWhileTheOtherStaysUp() throws {
        var config = Self.both()
        config.guide.preview.duration = 0.5
        config.guide.names.duration = 3

        // The motion is at 0.6. Both are up a beat later; by 1.9 the minimap has been away for most of
        // a second and the row of names has two thirds of its own dwell left.
        #expect(try Self.state("guide.names.duration", config, at: 0.8).guides.map(\.style)
                    == [.preview, .names])
        #expect(try Self.state("guide.names.duration", config, at: 1.9).guides.map(\.style) == [.names])
    }

    /// **A life-cycle loop shows its own guide leave.** The period is derived from the setting under
    /// the pointer and the guide is lowered by that same number, so a loop always ends with that guide
    /// gone — whatever the guide beside it was asked for.
    @Test(arguments: [GuideStyle.preview, .names])
    func aLifeCycleLoopEndsWithItsOwnGuideGone(_ style: GuideStyle) throws {
        var config = Self.both()
        config.guide.preview.duration = style == .preview ? 0.5 : 4
        config.guide.names.duration = style == .names ? 0.5 : 4
        let key = "guide.\(style.rawValue).duration"
        let period = try #require(Catalog.take(for: key, config: config)).period

        #expect(try Self.state(key, config, at: 0.8).guides.map(\.style).contains(style))
        #expect(try !Self.state(key, config, at: period - 0.01).guides.map(\.style).contains(style))
    }

    @Test func offMeansNothingAppearsAtAll() throws {
        let off = Self.config { $0.guide.preview.enabled = false }
        for t in [0.1, 0.8, 1.4, 2.0] {
            #expect(try Self.state("guide.preview.content", off, at: t).guides.isEmpty)
        }
        // And the moment it is enabled it is there — on a still take, for as long as the row is hovered.
        #expect(try !Self.state("guide.preview.content", Self.config(), at: 0.8).guides.isEmpty)
    }

    /// **A close framing and a life cycle are exclusive.** A lens pushed in on a guide that is not up
    /// frames the wallpaper where one would be, so a loop under a close shot pulls out and back every
    /// few seconds — with the setting off screen for most of its own demonstration.
    @Test func nothingFramedCloseOnAGuideAlsoRaisesAndLowersOne() throws {
        for key in ConfigSchema.settings.filter({ $0.section == .guide }).map(\.key) {
            let take = try #require(Catalog.take(for: key, config: Self.both()))
            switch take.camera {
            case .guidePanel, .guideCorner:
                #expect(take.isStatic, "\(key) is framed close on a guide that comes and goes")
                // …and what is framed close is up the whole time the pointer is on the row.
                for t in [0.0, 0.9, 2.4, 6.0] {
                    #expect(try !Self.state(key, Self.both(), at: t).guides.isEmpty)
                }
            case .wide, .seams, .stack, .stackSeam:
                break
            }
        }
    }

    /// **The two settings whose subject is the life cycle, and no others.** Everything else about a
    /// guide is geometry, and geometry re-derives under the hand with nothing playing.
    @Test func onlyEnabledAndDurationPlayTheLifeCycle() throws {
        let looping = try ConfigSchema.settings.filter { $0.section == .guide }.map(\.key)
            .filter { try !#require(Catalog.take(for: $0, config: Self.both())).isStatic }
        #expect(looping == ["guide.preview.enabled", "guide.preview.duration",
                            "guide.names.enabled", "guide.names.duration"])
    }

    /// **Life size, exactly.** `font-size` is a length the user is judging by eye, so at that framing
    /// twelve points is twelve points — the same claim the gap settings make, which the minimap is
    /// exempt from because nothing read on it is a length.
    @Test func theNamesGuideIsFramedAtLifeSize() throws {
        let projection = Projection(displayFrame: Rect(x: 0, y: 0, width: 1800, height: 1169),
                                    workingArea: Self.area, k: SettingsStyle.mockWidthFraction)
        for key in ["guide.names.font-size", "guide.names.lowercase", "guide.names.max-columns"] {
            let state = try Self.state(key, Self.named(), at: 0.8)
            let frame = state.camera.frame(of: state, in: projection)
            #expect(abs(projection.looking(at: frame).scale - 1) < 0.001,
                    "\(key) frames the names guide at \(projection.looking(at: frame).scale)×")
        }
        // The minimap is the exception, and it is the one framing allowed closer than life.
        let close = try Self.state("guide.preview.span", Self.config(), at: 0.8)
        #expect(projection.looking(at: close.camera.frame(of: close, in: projection)).scale
                    > 1.0001)
    }

    /// **Two guides at once, and each is its own object**: two panels, two positions, and neither on
    /// top of the other.
    @Test func bothGuidesCanBeUpAtOnceInDifferentCorners() throws {
        let both = Self.config {
            $0.guide.preview.position = .topRight
            $0.guide.names.enabled = true
            $0.guide.names.position = .bottomCenter
        }
        let state = try Self.state("guide.preview.position", both, at: 0.8)
        #expect(state.guides.map(\.style) == [.preview, .names])
        let preview = try #require(state.guide(.preview)).panel
        let names = try #require(state.guide(.names)).panel
        #expect(preview.intersection(names) == nil)
        #expect(names.minY > preview.minY)
    }

    @Test func eachSettingIsFramedWhereItsValueCanBeRead() throws {
        func camera(_ key: String, _ config: Config) throws -> Camera {
            try #require(Catalog.take(for: key, config: config)).camera
        }
        // Close on the minimap, where a tile is what is being chosen.
        #expect(try camera("guide.preview.content", Self.config()) == .guidePanel(.preview))
        #expect(try camera("guide.preview.span", Self.config()) == .guidePanel(.preview))
        // Wide, because a corner is only a corner against the whole screen and a width is a fraction
        // of the working width — and because a life cycle has no guide on screen to push in on.
        #expect(try camera("guide.preview.position", Self.config()) == .wide)
        #expect(try camera("guide.preview.width", Self.config()) == .wide)
        #expect(try camera("guide.preview.duration", Self.config()) == .wide)
        #expect(try camera("guide.preview.enabled", Self.config()) == .wide)
        // The corner: the two working-area edges the gap is measured from.
        #expect(try camera("guide.preview.gap", Self.config()) == .guideCorner(.preview))
        // …and each names setting frames the **names** guide, never the minimap beside it.
        #expect(try camera("guide.names.font-size", Self.named()) == .guidePanel(.names))
        #expect(try camera("guide.names.max-columns", Self.named()) == .guidePanel(.names))
        #expect(try camera("guide.names.position", Self.named()) == .wide)
        #expect(try camera("guide.names.gap", Self.named()) == .guideCorner(.names))
    }

    @Test func theCornerFramingHoldsBothEdgesTheGapIsMeasuredFrom() throws {
        let config = Self.config { $0.guide.preview.position = .bottomRight; $0.guide.preview.gap = 30 }
        let state = try Self.state("guide.preview.gap", config, at: 0.8)
        let panel = try #require(state.guide(.preview)).panel
        let subject = try #require(Camera.guideCorner(.preview).subject(of: state))

        #expect(subject.maxX >= Self.area.maxX - 0.001)
        #expect(subject.maxY >= Self.area.maxY - 0.001)
        #expect(subject.minX <= panel.minX + 0.001)
    }

    /// **The mock hands the real model a real input**, which is the whole of what replaced a second
    /// drawing of the guide: every column on the set, in strip order, keyed by something `MockIcons` and
    /// `MockNames` can answer — and no floats, exactly as the real guide draws none.
    @Test func theMockBuildsAnInputTheRealModelCanDraw() throws {
        let state = try Self.state("guide.preview.content", Self.config(), at: 0.8)
        let frame = try #require(state.guide(.preview))
        let input = GuideInput(scene: state.scene, workingArea: Self.area, frames: state.frames)
        #expect(input.columns.map(\.id) == state.scene.columns.map(\.id))
        for column in input.columns {
            for window in column.windows {
                // The stand-in for a bundle id, and the key the mock's own icons are looked up by.
                #expect(MockRole(rawValue: window.bundleId) == state.scene.role(of: window.id))
                #expect(input.frames[window.id] != nil)
            }
        }
        // …and what the frame carries **is** `GuideModel`'s own drawing, rather than a panel that
        // happens to agree with one: the renderer is handed this value and draws nothing else.
        let layout = try #require(GuideModel.layout(input, settings: frame.settings.preview))
        #expect(frame.drawing == .preview(layout))
        #expect(layout.panel == frame.panel)
        #expect(layout.tiles.count == Scenes.guided.windows.count)
        #expect(layout.ring != nil)
        // Separators, tile radii and the separation inset are not optional: the preview has them
        // because it is the same object, not because someone remembered to draw them twice.
        #expect(!layout.separators.isEmpty)
    }

    /// The names guide over the same mock, through `NamesModel` — with the set's one stacked column
    /// carrying the superscript that makes the count demonstrable.
    @Test func theNamesGuideNamesTheMocksOwnColumns() throws {
        let state = try Self.state("guide.names.font-size", Self.named(), at: 0.8)
        let frame = try #require(state.guide(.names))
        let input = GuideInput(scene: state.scene, workingArea: Self.area, frames: state.frames)
        let model = try #require(NamesModel.model(input, settings: frame.settings.names,
                                                  face: GuideTypeface.face,
                                                  name: MockNames.name(for:)))
        #expect(frame.drawing == .names(model))
        #expect(model.panel == frame.panel)
        #expect(model.cells.count == Scenes.guided.columns.count)
        #expect(model.cells.contains { $0.isFocused })
        // The stacked column, and only it, is counted.
        #expect(model.cells.filter { $0.depth > 1 }.count == 1)
        #expect(model.cells.contains { $0.count == "²" })
        // Lowercased by default, which is what makes the row read as a row.
        #expect(model.cells.allSatisfy { $0.label == $0.label.lowercased() })
    }

    @Test func eachGuidesPanelTravelsToItsNewCornerRatherThanCuttingToIt() throws {
        var motion = PreviewMotion()
        let here = Self.config { $0.guide.preview.position = .topLeft }
        let there = Self.config { $0.guide.preview.position = .bottomRight }
        motion.snap(to: try Self.state("guide.preview.position", here, at: 0.8))
        let moved = try Self.state("guide.preview.position", there, at: 0.8)
        motion.retarget(to: moved, springs: PreviewSprings(there))

        // The first frame is still in the old corner.
        let drawn = try #require(motion.guides(of: moved).first).panel
        let was = try #require(Self.state("guide.preview.position", here, at: 0.8)
                                   .guide(.preview)).panel
        #expect(abs(drawn.minX - was.minX) < 0.001)
        #expect(!motion.isSettled())

        for _ in 0..<600 { motion.advance(by: 1.0 / 120.0) }
        #expect(motion.isSettled())
        let landed = try #require(motion.guides(of: moved).first).panel
        #expect(abs(landed.minX - (try #require(moved.guide(.preview)).panel.minX)) < 0.5)
    }
}
