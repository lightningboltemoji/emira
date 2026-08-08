import EmiraConfig
import EmiraCore

// `(Take, t, Config, workingArea) → frames`, and it is one expression: the mock desktop is laid out by
// the code that lays out the real one.
//
// **The layout runs at real scale and only the result is projected.** Everything here is true points
// against the display's own working area; the AppKit half multiplies by `k` on the way to a layer. Run
// the layout against the small rect instead and an 8 pt gap becomes 8 pt of a 900-point screen — four
// times too wide, and every preview a lie about the number beside it.
//
// The scroll offset is a **fold over the beats**, not a function of the final set. `offsetToReveal` is
// relative to where the strip already is, so a take that focuses right twice must reveal from the offset
// the first one left behind — which is exactly what the reducer does, one command at a time.

/// A mock desktop at one instant: the set, where the strip is scrolled to, and where every window is.
public struct PreviewState: Sendable, Equatable {
    /// The set as of this instant — the roles and the focus the view draws.
    public let scene: Scene
    /// The strip's scroll offset, in true points.
    public let scrollOffset: Double
    /// Every mock window's frame, in true points on the display's own working area.
    public let frames: [WindowId: Rect]
    /// Where the mock pointer rests, in true points, or `nil` when the set carries none.
    public let pointer: Point?
    /// Whether the pointer is drawn. `mouse.hide` is what takes it away, and a pointer that vanished
    /// without travelling first would be showing the wrong setting.
    public let isPointerShown: Bool
    /// The guide, drawn small on the mock — `nil` when the set carries none or the guide is off.
    public let guide: GuidePreview?

    public var focus: WindowId { scene.focus }

    /// The focused window's frame — the ring, when there is one to draw.
    public var focusFrame: Rect? { frames[scene.focus] }
}

/// The mock desktop's geometry, derived and never stored.
public enum PreviewModel {

    /// The metrics a draft asks for on a display whose working area is `workingArea`.
    ///
    /// The state-derived half of `LayoutMetrics` is empty and that is honest: a preview has no world to
    /// correct and nothing parked, which is the same reason it may not reach the reducer at all.
    public static func metrics(for config: Config, workingArea: Rect) -> LayoutMetrics {
        LayoutMetrics(config: config, workingArea: workingArea)
    }

    /// The mock desktop `t` seconds into `take`, under `config`.
    public static func state(of take: Take, at t: Double,
                             config: Config, workingArea: Rect) -> PreviewState {
        let metrics = metrics(for: config, workingArea: workingArea)
        var scene = take.scene
        var offset = framedOffset(scene, config: config, metrics: metrics, from: 0)

        for (_, beat) in beats(of: take, upTo: t) {
            scene = beat.applied(to: scene)
            offset = framedOffset(scene, config: config, metrics: metrics, from: offset)
        }

        let frames = scene.layout.naturalFrames(scrollOffset: offset, metrics: metrics)
        return PreviewState(scene: scene, scrollOffset: offset, frames: frames,
                            pointer: pointer(for: scene, config: config, frames: frames,
                                             metrics: metrics),
                            isPointerShown: !config.hidesCursor,
                            guide: scene.hasGuide
                                ? GuidePreview.preview(config: config, workingArea: workingArea,
                                                       frames: frames, focus: scene.focus,
                                                       scrollOffset: offset)
                                : nil)
    }

    /// The set at rest, with no take playing — a static take's one and only state.
    public static func state(of scene: Scene, config: Config, workingArea: Rect) -> PreviewState {
        state(of: Take(scene: scene), at: 0, config: config, workingArea: workingArea)
    }

    /// Where the mock pointer sits.
    ///
    /// **`follows-focus` is the whole demonstration**: off leaves it where it started, and every other
    /// rung sends it after the focused window. The three "on" rungs differ over *when* they decline —
    /// a hover, a pointer already inside — and those are distinctions about a real pointer that a
    /// scripted take cannot stage without lying, so they play the same and the sentence explains them.
    private static func pointer(for scene: Scene, config: Config,
                                frames: [WindowId: Rect], metrics: LayoutMetrics) -> Point? {
        guard scene.hasPointer else { return nil }
        guard config.mouseFollowsFocus != .off, let focused = frames[scene.focus] else {
            // Parked a little in from the working area's top left: somewhere a pointer plausibly is,
            // and far enough from every window that "it did not move" reads as a fact rather than as a
            // coincidence.
            return Point(x: metrics.workingArea.minX + metrics.workingArea.width * 0.12,
                         y: metrics.workingArea.minY + metrics.workingArea.height * 0.22)
        }
        return focused.center
    }

    /// The beats that have fired by `t`, in order, `t` wrapped into one loop.
    private static func beats(of take: Take, upTo t: Double) -> [(at: Double, beat: Beat)] {
        guard !take.isStatic else { return [] }
        let phase = t.truncatingRemainder(dividingBy: take.period)
        let wrapped = phase < 0 ? phase + take.period : phase
        return take.beats.filter { $0.at <= wrapped }
    }

    /// Where the strip comes to rest with `scene`'s focused column framed, coming from `offset`.
    ///
    /// `Layout.scrollOffsetToFrame` is the reducer's own choice between centring and the minimal reveal,
    /// so `layout.center-focused-column` previews itself rather than being modelled a second time here.
    private static func framedOffset(_ scene: Scene, config: Config,
                                     metrics: LayoutMetrics, from offset: Double) -> Double {
        scene.layout.scrollOffsetToFrame(window: scene.focus, from: offset,
                                         metrics: metrics,
                                         center: config.centerFocusedColumn) ?? offset
    }
}
