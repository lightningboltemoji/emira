import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// The guide's six settings. The guide is **raised by motion and lowered by `duration`**, as the daemon
// does it, so its whole life cycle is on screen every few seconds — and `off` genuinely means nothing
// appears.

@Suite struct GuideLifeTests {

    static let area = PreviewModelTests.workingArea

    static func config(_ change: (inout Config) -> Void = { _ in }) -> Config {
        var config = Config()
        config.guide.style = .placeholder
        change(&config)
        return config
    }

    static func state(_ key: String, _ config: Config, at t: Double) throws -> PreviewState {
        let take = try #require(Catalog.take(for: key, config: config))
        return PreviewModel.state(of: take, at: t, config: config, workingArea: area)
    }

    @Test func theSetIsThreeScreensLong() throws {
        // `scale = min(width,1)/span` shrinks the panel to a short strip, so a shorter set makes both
        // `width` and `span` read as broken rather than as settings.
        let state = try Self.state("guide.span", Self.config(), at: 0)
        let strip = state.frames.values.reduce(Rect?.none) { union, frame in
            union.map { $0.union(frame) } ?? frame
        }
        #expect(try #require(strip).width > Self.area.width * 2.5)
    }

    @Test func aLoopOpensWithNoGuideOnTheDesktop() throws {
        // And that is what makes the arrival something you watch happen.
        #expect(try Self.state("guide.style", Self.config(), at: 0.1).guide == nil)
        #expect(try Self.state("guide.style", Self.config(), at: 0.8).guide != nil)
    }

    @Test func theGuideIsLoweredByDuration() throws {
        let brief = Self.config { $0.guide.duration = 0.5 }
        let long = Self.config { $0.guide.duration = 3.0 }

        // The motion is at 0.6; sampled at 1.9 the short one has been away for most of a second and the
        // long one has not gone yet.
        #expect(try Self.state("guide.duration", brief, at: 1.9).guide == nil)
        #expect(try Self.state("guide.duration", long, at: 1.9).guide != nil)
    }

    @Test func thePeriodIsDerivedFromTheValue() throws {
        func period(_ duration: Double) throws -> Double {
            let config = Self.config { $0.guide.duration = duration }
            return try #require(Catalog.take(for: "guide.duration", config: config)).period
        }
        // At `duration = 4` the loop is long enough that the guide has been away before it starts again.
        #expect(try period(4) > period(1))
        #expect(try period(4) > 4)
    }

    @Test func offMeansNothingAppearsAtAll() throws {
        let off = Self.config { $0.guide.style = .off }
        for t in [0.1, 0.8, 1.4, 2.0] {
            #expect(try Self.state("guide.style", off, at: t).guide == nil)
        }
        // And the moment `placeholder` is picked it starts arriving on every loop.
        #expect(try Self.state("guide.style", Self.config(), at: 0.8).guide != nil)
    }

    @Test func eachSettingIsFramedWhereItsValueCanBeRead() throws {
        func camera(_ key: String) throws -> Camera {
            try #require(Catalog.take(for: key, config: Self.config())).camera
        }
        // Close on the guide, where a tile is what is being chosen.
        #expect(try camera("guide.style") == .guidePanel)
        #expect(try camera("guide.span") == .guidePanel)
        #expect(try camera("guide.duration") == .guidePanel)
        // Wide, because a corner is only a corner against the whole screen and a width is a fraction
        // of the working width.
        #expect(try camera("guide.position") == .wide)
        #expect(try camera("guide.width") == .wide)
        // The corner: the two working-area edges the gap is measured from.
        #expect(try camera("guide.gap") == .guideCorner)
    }

    @Test func theCornerFramingHoldsBothEdgesTheGapIsMeasuredFrom() throws {
        let config = Self.config { $0.guide.position = .bottomRight; $0.guide.gap = 30 }
        let state = try Self.state("guide.gap", config, at: 0.8)
        let panel = try #require(state.guide).panel
        let subject = try #require(Camera.guideCorner.subject(of: state))

        #expect(subject.maxX >= Self.area.maxX - 0.001)
        #expect(subject.maxY >= Self.area.maxY - 0.001)
        #expect(subject.minX <= panel.minX + 0.001)
    }

    @Test func aTileKnowsWhichWindowItIs() throws {
        // Which is the whole difference between `placeholder` and `preview`: one inscribes the app's
        // icon, the other draws that window's own still.
        let guide = try #require(Self.state("guide.style", Self.config(), at: 0.8).guide)
        let scene = try Self.state("guide.style", Self.config(), at: 0.8).scene
        for tile in guide.tiles {
            #expect(scene.role(of: tile.id) != nil)
        }
    }

    @Test func thePanelTravelsToItsNewCornerRatherThanCuttingToIt() throws {
        var motion = PreviewMotion()
        let here = Self.config { $0.guide.position = .topLeft }
        let there = Self.config { $0.guide.position = .bottomRight }
        motion.snap(to: try Self.state("guide.position", here, at: 0.8))
        let moved = try Self.state("guide.position", there, at: 0.8)
        motion.retarget(to: moved, springs: PreviewSprings(there))

        // The first frame is still in the old corner.
        let drawn = try #require(motion.guide(of: moved)).panel
        let was = try #require(Self.state("guide.position", here, at: 0.8).guide).panel
        #expect(abs(drawn.minX - was.minX) < 0.001)
        #expect(!motion.isSettled())

        for _ in 0..<600 { motion.advance(by: 1.0 / 120.0) }
        #expect(motion.isSettled())
        #expect(abs(try #require(motion.guide(of: moved)).panel.minX - moved.guide!.panel.minX) < 0.5)
    }
}
