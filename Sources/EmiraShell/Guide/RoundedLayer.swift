import AppKit
import QuartzCore
import EmiraCore

// `CALayer.cornerRadius` is one number for all four corners, and the guide needs four: a tile pushed
// into the end of the ribbon takes the ribbon's curve on the side it touches and keeps its own
// everywhere else (`GuideModel.corners`). So everything rounded *inside* the ribbon — a tile, the focus
// ring, the viewport — is a path rather than a radius. The ribbon itself is not: its four corners are
// always equal, and `cornerRadius` with `masksToBounds` is what clips the tiles running off its ends.
//
// **One path serves both the fill and the stroke**, because a `CAShapeLayer` has only one. It is the
// silhouette inset by half the line width, so the stroke straddles the silhouette's edge and covers the
// outer half the fill does not reach — which puts the whole of it inside the bounds, exactly where a
// `borderWidth` would have drawn it. A shape with no edge at all — a tile, since what divides those is
// the separators and not an outline each — insets by nothing and is its silhouette.
//
// The path is rebuilt only when the shape itself changes. A scroll translates a tile without resizing
// it, and only the tiles near an end of the ribbon change corners, so most frames rebuild nothing.

/// A rounded rect whose four corners can differ: a fill, an optional stroke inside it, and what it
/// carries.
@MainActor
final class RoundedLayer {

    /// What a tile carries, and how it is fitted — the whole of the difference between the two
    /// `GuideContent` cases that draw anything.
    private enum Content {
        /// The still *is* the window, so it fills the tile and needs the silhouette as a mask to be cut
        /// to its corners.
        case filling(CALayer, clip: CAShapeLayer)
        /// A square icon in a rectangular tile: centred and padded by `GuideModel.placeholder`, so it
        /// never reaches a corner and needs no mask — an offscreen pass per tile it does not cost.
        case inscribed(CALayer)
    }

    /// The shape itself. The caller owns where it sits in the tree.
    let layer = CAShapeLayer()

    private let stroke: CGFloat
    private let content: Content?

    /// The shape last drawn, so a frame that only moves the layer rebuilds no path.
    private var drawn: (size: CGSize, corners: Corners)?

    init(scale: CGFloat, fill: CGColor?, edge: (color: CGColor, width: CGFloat)?,
         content: GuideContent = .blank) {
        stroke = edge?.width ?? 0
        layer.contentsScale = scale
        layer.fillColor = fill
        layer.strokeColor = edge?.color
        layer.lineWidth = stroke

        // A shape layer's sublayers composite *above* its shape, so both of these draw over the fill.
        // Neither reaches the stroke: the still is masked inside it, and the icon is padded away from it.
        switch content {
        case .blank:
            self.content = nil
        case .preview(let image):
            let still = Self.picture(image, scale: scale, gravity: .resize)
            let clip = CAShapeLayer()
            clip.contentsScale = scale
            still.mask = clip
            layer.addSublayer(still)
            self.content = .filling(still, clip: clip)
        case .placeholder(let image):
            let icon = Self.picture(image, scale: scale, gravity: .resizeAspect)
            layer.addSublayer(icon)
            self.content = .inscribed(icon)
        }
    }

    /// Place the shape for this frame, in the parent layer's own coordinates.
    func place(_ frame: CGRect, corners: Corners) {
        layer.frame = frame
        guard drawn?.size != frame.size || drawn?.corners != corners else { return }
        drawn = (frame.size, corners)

        let bounds = CGRect(origin: .zero, size: frame.size)
        layer.path = Self.path(bounds.insetBy(dx: stroke / 2, dy: stroke / 2),
                               corners.inset(by: Double(stroke) / 2))

        switch content {
        case .filling(let still, let clip):
            still.frame = bounds
            clip.frame = bounds
            // Inside the stroke rather than under it: the stroke is the tile's own edge and has to read
            // at its full width against a still that fills everything up to it.
            clip.path = Self.path(bounds.insetBy(dx: stroke, dy: stroke),
                                  corners.inset(by: Double(stroke)))
        case .inscribed(let icon):
            // Centred, which is why no `ScreenGeometry` appears: the flip between the core's top-left
            // rect and the layer's bottom-left one is the identity on a rect centred in this very size.
            let rect = GuideModel.placeholder(in: Size(width: frame.width, height: frame.height))
            icon.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        case nil:
            break
        }
    }

    private static func picture(_ image: CGImage, scale: CGFloat,
                                gravity: CALayerContentsGravity) -> CALayer {
        let layer = CALayer()
        layer.contentsScale = scale
        layer.contents = image
        layer.contentsGravity = gravity
        return layer
    }

    /// A rounded rect with four independent radii, in a layer's own (bottom-left) coordinates.
    /// `Corners` is measured the way `Rect` is — `topLeft` is the corner the eye sees at the top — so
    /// the top pair belongs to `maxY` here. Radii are the caller's to keep within half the short side;
    /// `GuideModel.corners` caps them there and `Corners.inset` preserves it.
    private static func path(_ rect: CGRect, _ corners: Corners) -> CGPath {
        let path = CGMutablePath()
        guard rect.width > 0, rect.height > 0 else { return path }
        let (topLeft, topRight) = (CGFloat(corners.topLeft), CGFloat(corners.topRight))
        let (bottomLeft, bottomRight) = (CGFloat(corners.bottomLeft), CGFloat(corners.bottomRight))
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - topLeft))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: topLeft)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: topRight)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: bottomRight)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: bottomLeft)
        path.closeSubpath()
        return path
    }
}
