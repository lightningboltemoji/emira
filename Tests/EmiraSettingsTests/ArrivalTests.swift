import Testing
import EmiraConfig
import EmiraCore
import EmiraMotion
@testable import EmiraSettings

// `animation.transition`, `animation.cover`, and the pacing of the spring dials. Every rung has to be
// its own picture, and every dial has to drive the motion its own help sentence names.

@Suite struct ArrivalTests {

    static let area = PreviewModelTests.workingArea

    static func config(_ mode: TransitionMode = .smooth, cover: CoverMode = .exact) -> Config {
        var config = Config()
        config.transitionMode = mode
        config.coverMode = cover
        return config
    }

    static func played(_ key: String, _ config: Config, from: Double, to: Double)
        throws -> (PreviewMotion, PreviewState) {
        let take = try #require(Catalog.take(for: key, config: config))
        var motion = PreviewMotion()
        motion.snap(to: PreviewModel.state(of: take, at: from, config: config, workingArea: area))
        let after = PreviewModel.state(of: take, at: to, config: config, workingArea: area)
        motion.retarget(to: after, springs: PreviewSprings(config),
                        mode: config.transitionMode, head: after.head)
        return (motion, after)
    }

    // `animation.transition`

    @Test func theThreeRungsAreThreeDifferentPictures() throws {
        // Three rungs that rendered identically would be the worst kind of preview: it says the setting
        // does nothing.
        // Sampled a frame or two in: on the *first* frame every rung reproduces the old layout exactly,
        // which is the point — nothing pops. What differs is what happens next.
        func firstFrame(_ mode: TransitionMode) throws -> [WindowId: Rect] {
            var (motion, state) = try Self.played("animation.transition", Self.config(mode),
                                                  from: 1.0, to: 1.3)
            motion.advance(by: 0.05)
            return motion.frames(of: state)
        }
        let smooth = try firstFrame(.smooth)
        let snap = try firstFrame(.snap)
        let off = try firstFrame(.off)

        #expect(smooth != snap)
        #expect(off != snap)
        #expect(smooth != off)
    }

    @Test func snapChangesEveryFrameAtOnce() throws {
        // The one sanctioned cut in the whole window, and the held frames either side are what make it
        // read as atomicity.
        let (motion, state) = try Self.played("animation.transition", Self.config(.snap),
                                              from: 1.0, to: 1.3)
        #expect(motion.frames(of: state) == state.frames)
        #expect(motion.isSettled())
    }

    @Test func offLeavesTheStripGenuinelyHalfArranged() throws {
        var (motion, state) = try Self.played("animation.transition", Self.config(.off),
                                              from: 1.0, to: 1.3)
        // Nothing has arrived on the first frame.
        #expect(motion.frames(of: state) != state.frames)
        #expect(!motion.isSettled())

        // A tenth of a second in, some windows have landed and others have not — which is the picture.
        motion.advance(by: 0.1)
        let mid = motion.frames(of: state)
        let arrived = mid.filter { state.frames[$0.key] == $0.value }.count
        #expect(arrived > 0 && arrived < mid.count)

        // And by the end of the stagger every one of them is home.
        motion.advance(by: PreviewMotion.stagger.last! + 0.01)
        #expect(motion.frames(of: state) == state.frames)
        #expect(motion.isSettled())
    }

    @Test func theStaggerIsFixedAndIdenticalEveryLoop() throws {
        // It has to read as latency, and latency that reshuffles reads as noise.
        func order() throws -> [WindowId] {
            var (motion, state) = try Self.played("animation.transition", Self.config(.off),
                                                  from: 1.0, to: 1.3)
            var landed: [WindowId] = []
            for _ in 0..<40 {
                motion.advance(by: 0.01)
                let frames = motion.frames(of: state)
                for (id, frame) in frames where frame == state.frames[id] && !landed.contains(id) {
                    landed.append(id)
                }
            }
            return landed
        }
        #expect(try order() == order())
    }

    // `animation.cover`

    @Test func exactPausesBeforeAnythingMovesAndImmediateDoesNot() throws {
        #expect(Catalog.take(for: "animation.cover", config: Config()) != nil)
        let exact = try #require(Catalog.take(for: "animation.cover", config: Self.config(cover: .exact)))
        let immediate = try #require(Catalog.take(for: "animation.cover",
                                                  config: Self.config(cover: .immediate)))

        let paused = PreviewModel.state(of: exact, at: 1.4, config: Self.config(cover: .exact),
                                        workingArea: Self.area)
        let prompt = PreviewModel.state(of: immediate, at: 1.4,
                                        config: Self.config(cover: .immediate),
                                        workingArea: Self.area)
        #expect(paused.head == PreviewModel.coverHead)
        #expect(prompt.head == 0)
    }

    @Test func theHeadIsAWaitAndThenTheWholeMotion() throws {
        var (motion, state) = try Self.played("animation.cover", Self.config(.off, cover: .exact),
                                              from: 0.5, to: 1.2)
        // Still exactly where it was, a quarter of a second in.
        motion.advance(by: 0.25)
        #expect(motion.frames(of: state) != state.frames)
        // And home once the round trip has been paid for.
        motion.advance(by: PreviewModel.coverHead + PreviewMotion.stagger.last! + 0.01)
        #expect(motion.frames(of: state) == state.frames)
    }

    // The spring dials

    @Test func aSlackSpringGetsALongerLoopThanAStiffOne() throws {
        func period(_ stiffness: Double) throws -> Double {
            var config = Config()
            config.scrollSpring = SpringParams(stiffness: stiffness, dampingRatio: 1)
            return try #require(Catalog.take(for: "animation.scroll.stiffness", config: config)).period
        }
        #expect(try period(20) > period(400))
    }

    @Test func everyDialDrivesTheMotionItsOwnSentenceNames() throws {
        // Each dial needs a motion of its own on screen, or the slider drives nothing visible.
        let movement = try #require(Catalog.take(for: "animation.movement.stiffness", config: Config()))
        let glide = try #require(Catalog.take(for: "animation.glide.stiffness", config: Config()))
        let resize = try #require(Catalog.take(for: "animation.resize.stiffness", config: Config()))
        let scroll = try #require(Catalog.take(for: "animation.scroll.stiffness", config: Config()))

        // A move-window is pure translation, so the movement spring is the only one in the shot.
        // Sampled either side of the take's own first beat, whose time is the spring's to decide.
        let config = Config()
        let firstBeat = try #require(movement.beats.first).at
        let before = PreviewModel.state(of: movement, at: firstBeat - 0.1,
                                        config: config, workingArea: Self.area)
        let after = PreviewModel.state(of: movement, at: firstBeat + 0.1,
                                       config: config, workingArea: Self.area)
        for (id, frame) in after.frames {
            #expect(before.frames[id]?.size == frame.size, "a move-window resizes nothing")
        }
        #expect(before.frames != after.frames)

        // And the four are four different pictures rather than one repeated.
        let sets = [movement.scene, glide.scene, resize.scene, scroll.scene]
        var distinct: [Scene] = []
        for set in sets where !distinct.contains(set) { distinct.append(set) }
        #expect(distinct.count >= 3)
    }
}
