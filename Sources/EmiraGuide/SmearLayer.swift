import CoreImage
import QuartzCore
import EmiraMotion

// The presentation of `MotionBlur`, in one place for the desktop's stand-ins and the settings mock's
// panes: a `CIMotionBlur` in the render server, on a pad wider than the content it smears. The
// filter is Gaussian with `inputRadius` as its σ in the layer's own points — it scales with the
// display, so no backing-scale factor belongs on it — and its output is clipped to the bounds of the
// layer carrying it, which is what the pad's margin buys room for. Any filter at all is an offscreen
// pass whatever its radius, so the filter comes off entirely while the content is still.

/// A layer that smears what it hosts across its own motion. Owns a layer tree and no window, like a
/// guide renderer: the host adds `layer` to its tree and puts the content through `place`.
@MainActor
public final class SmearLayer {
    /// What the host adds to its tree; `place` positions it.
    public let layer = CALayer()
    /// The layer being smeared, inset in `layer` by the margin. The host builds it and owns its contents.
    public let content: CALayer

    /// Empty layer around the content on every side, in points: three σ of the longest smear, where a
    /// Gaussian's tail ends, plus a drop shadow's reach.
    public static let margin: CGFloat = CGFloat(Smear.maxSigma) * 3 + shadowReach
    /// How far past its silhouette the shadow either host casts extends: its radius, offset, and slack.
    private static let shadowReach: CGFloat = 32
    private static let filterName = "smear"

    private var smear = Smear()
    private var lastAnchor: CGPoint?
    private var lastPlacedAt: CFTimeInterval?

    public init(hosting content: CALayer) {
        self.content = content
        layer.addSublayer(content)
    }

    /// Put the content at `frame` — in the host's own y-up coordinates — smeared across the step from
    /// where the last placement put it. The step is the top-left's, so a resize anchored there is not
    /// one. `scale` is the projection the host's points are in: the settings mock's, or 1 on the desktop.
    public func place(_ frame: CGRect, blur: MotionBlur, scale: CGFloat = 1) {
        let margin = Self.margin * scale
        layer.frame = frame.insetBy(dx: -margin, dy: -margin)
        content.frame = CGRect(origin: CGPoint(x: margin, y: margin), size: frame.size)

        let anchor = CGPoint(x: frame.minX, y: frame.maxY)   // the top-left, y up
        let now = CACurrentMediaTime()
        let step = lastAnchor.map { CGVector(dx: anchor.x - $0.x, dy: anchor.y - $0.y) } ?? .zero
        let elapsed = lastPlacedAt.map { now - $0 } ?? 0
        lastAnchor = anchor
        lastPlacedAt = now

        guard let sigma = smear.advance(step: hypot(step.dx, step.dy), elapsed: elapsed,
                                        blur: blur, scale: scale) else {
            if layer.filters != nil { layer.filters = nil }
            return
        }
        if layer.filters == nil {
            guard let filter = CIFilter(name: "CIMotionBlur") else { return }
            filter.name = Self.filterName
            layer.filters = [filter]
        }
        // Through the key path, never on the filter object: mutating an installed filter is undefined.
        layer.setValue(sigma, forKeyPath: "filters.\(Self.filterName).inputRadius")
        layer.setValue(atan2(step.dy, step.dx), forKeyPath: "filters.\(Self.filterName).inputAngle")
    }

    /// Forget where the content was, so the next placement is where its steps begin rather than one
    /// of them — a teleport is not motion.
    public func forget() {
        lastAnchor = nil
        lastPlacedAt = nil
        smear = Smear()
        if layer.filters != nil { layer.filters = nil }
    }
}
