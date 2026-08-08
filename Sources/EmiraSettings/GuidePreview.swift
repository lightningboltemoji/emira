import EmiraConfig
import EmiraCore

// The guide, drawn on the mock desktop — the reconstruction's projection at a *third* scale, after the
// cover and the guide itself.
//
// **Through `GuideModel`'s own projection**, which is why that type moved into `EmiraCore`. A guide
// scene that placed its own ribbon would be a second opinion about where `guide.position` puts one, and
// the settings it previews are exactly the numbers that decide it.
//
// `GuideModel.layout(for:on:)` is not reachable from here and must not be: it takes a `State`, and a
// preview has no truth plane. What is shared is `projection(settings:working:strip:)`, which is pure —
// so the panel is the real one's and the tiles are the mock's own frames put through it.

/// One frame of the guide on the mock desktop. Panel in true screen points; everything inside it in
/// panel-local guide points, which is `GuideLayout`'s own convention.
public struct GuidePreview: Sendable, Equatable {
    public let panel: Rect
    public let tiles: [Rect]
    public let viewport: Rect
    public let ring: Rect?

    /// The guide `config` asks for over a mock desktop whose windows are at `frames`.
    ///
    /// `nil` when the guide is off or its numbers are degenerate — the same answer `GuideModel` gives,
    /// and the setting that turns it off is one of the ones on screen.
    static func preview(config: Config, workingArea: Rect, frames: [WindowId: Rect],
                        focus: WindowId, scrollOffset: Double) -> GuidePreview? {
        guard config.guide.style != .off else { return nil }
        // The strip's extent as the guide means it: the bounding box of what is on the strip.
        let strip = frames.values.reduce(Rect?.none) { union, frame in
            union.map { $0.union(frame) } ?? frame
        } ?? .zero
        guard let projection = GuideModel.projection(settings: config.guide, working: workingArea,
                                                     strip: strip) else { return nil }
        return GuidePreview(
            panel: projection.panel,
            tiles: frames.keys.sorted().compactMap { frames[$0].map(projection.project) },
            viewport: projection.project(Rect(x: workingArea.minX + scrollOffset, y: workingArea.minY,
                                              width: workingArea.width, height: workingArea.height)),
            ring: frames[focus].map(projection.project))
    }
}
