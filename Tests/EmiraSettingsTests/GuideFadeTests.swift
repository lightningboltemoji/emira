import Testing
import AppKit
import EmiraConfig
import EmiraCore
import EmiraGuide
@testable import EmiraSettings

// How a guide comes and goes on the mock: **instant up and gentle down**, which is the daemon's own
// pair rather than a second opinion about it. `guide.duration`'s whole subject is that exit, so a
// preview that cut it away would be wrong about the number in the field beside it.

@MainActor @Suite struct GuideFadeTests {

    static let projection = Projection(displayFrame: Rect(x: 0, y: 0, width: 1800, height: 1169),
                                       workingArea: Rect(x: 0, y: 39, width: 1800, height: 1130),
                                       k: 0.5)

    static func config() -> Config {
        var config = Config()
        config.guide.names.enabled = true
        return config
    }

    /// The state of the guide take at `t`, drawn into a fresh desktop view.
    static func desktop() -> DesktopView {
        DesktopView(projection: projection, backingScale: 2)
    }

    static func draw(_ view: DesktopView, at t: Double) {
        let config = config()
        let take = Catalog.take(for: "guide.names.duration", config: config) ?? Take(scene: Scenes.guided)
        let state = PreviewModel.state(of: take, at: t, config: config,
                                       workingArea: projection.workingArea)
        view.render(scene: state.scene, frames: state.frames, targets: state.frames,
                    camera: projection.displayFrame, guides: state.guides)
    }

    /// The renderer's root for `style`, which is the layer the fade is on.
    static func layer(_ view: DesktopView, _ style: GuideStyle) throws -> CALayer {
        try #require(view.guideLayer(style))
    }

    @Test func aGuideArrivesInOneFrame() throws {
        let view = Self.desktop()
        // 0.1 is before the first beat, 0.9 after it — the guide's whole arrival.
        Self.draw(view, at: 0.1)
        let layer = try Self.layer(view, .names)
        #expect(layer.opacity == 0)

        Self.draw(view, at: 0.9)
        #expect(layer.opacity == 1)
        // Nothing to animate: a guide answers *where am I* about the thing that just moved, so any
        // rise at all is late.
        #expect(layer.animation(forKey: "fade") == nil)
    }

    @Test func aGuideLeavesOverTheDaemonsOwnFade() throws {
        let view = Self.desktop()
        Self.draw(view, at: 0.9)
        let layer = try Self.layer(view, .names)
        #expect(layer.opacity == 1)

        // The beat is at 0.6 and `duration` defaults to 0.7, so by 2.0 the dwell has expired — and
        // the loop's second beat, at 2.4, has not raised it again.
        Self.draw(view, at: 2.0)
        #expect(layer.opacity == 0)
        let fade = try #require(layer.animation(forKey: "fade") as? CABasicAnimation)
        #expect(fade.duration == GuideFade.down)
        #expect(fade.fromValue as? Float == 1)
    }

    /// **Started once, not once a frame.** Re-adding the animation every frame is a fade that never
    /// finishes, which is the bug the remembered opacity exists to prevent.
    @Test func theFadeIsNotRestartedByTheFramesThatFollowIt() throws {
        let view = Self.desktop()
        Self.draw(view, at: 0.9)
        Self.draw(view, at: 2.0)
        let layer = try Self.layer(view, .names)
        let fade = try #require(layer.animation(forKey: "fade"))

        for t in [2.05, 2.1, 2.2] { Self.draw(view, at: t) }
        #expect(layer.animation(forKey: "fade") === fade)
    }
}
