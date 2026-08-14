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
// **The stroke is a per-frame argument rather than a fixed width**, because a guide drawn at `scale`
// wears a border of `scale` points: a settings window panning its camera changes every cosmetic in the
// tree between one frame and the next.
//
// The path is rebuilt only when the shape itself changes. A scroll translates a tile without resizing
// it, and only the tiles near an end of the ribbon change corners, so most frames rebuild nothing.
//
// **What a tile carries can change under it**, and it is one layer either way — the difference between
// the two `TileContent` cases that draw something is a contents gravity and whether it wears a mask. A
// tile is not rebuilt to change its picture, because the pool is keyed by window and a window that
// acquires a still is the same window it was.

/// What one tile draws. The two cases that draw something differ only in how they are fitted.
enum TileContent: Equatable {
    /// The window's own still — the tile's own shape, so it fills it.
    case still(CGImage)
    /// The app's icon — square, so it is inscribed in the tile rather than stretched across it.
    case icon(CGImage)
    /// Nothing to draw: the tile is its own silhouette.
    case blank
}

/// A rounded rect whose four corners can differ: a fill, an optional stroke inside it, and what it
/// carries.
@MainActor
final class RoundedLayer {

    /// The shape itself. The caller owns where it sits in the tree.
    let layer = CAShapeLayer()

    private let contentsScale: CGFloat

    /// The picture, built on first use and kept across content swaps. A shape layer's sublayers
    /// composite *above* its shape, so it draws over the fill; it never reaches the stroke, being either
    /// masked inside it or padded away from it.
    private var picture: CALayer?
    /// Cuts a still to the tile's corners. Only a `.still` wears one — an icon is inscribed well clear
    /// of them and would be paying for an offscreen pass per tile that buys it nothing.
    private var clip: CAShapeLayer?
    /// What `picture` draws now. The authority for how it is fitted, and what makes a re-offer of the
    /// content already on screen free.
    private var carried: TileContent = .blank

    /// The shape last drawn, so a frame that only moves the layer rebuilds no path.
    private var drawn: (size: CGSize, corners: Corners, stroke: CGFloat)?

    init(contentsScale: CGFloat) {
        self.contentsScale = contentsScale
        layer.contentsScale = contentsScale
    }

    /// The colours this shape wears. A no-op when they are what it already has, which is every frame
    /// but the one where the appearance changed.
    func style(fill: CGColor?, edge: CGColor?) {
        if layer.fillColor != fill { layer.fillColor = fill }
        if layer.strokeColor != edge { layer.strokeColor = edge }
    }

    /// Draw `content` from now on. A no-op when it is what the tile already carries, which is the
    /// ordinary frame — the renderer offers content every frame so that a still landing after the tile
    /// was built is picked up, and almost every offer is the same image object as the last.
    func carry(_ content: TileContent) {
        guard content != carried else { return }
        carried = content

        switch content {
        case .blank:
            picture?.removeFromSuperlayer()
            picture = nil
            clip = nil
        case .still(let image):
            // The still *is* the window, so it fills the tile and needs the silhouette as a mask to be
            // cut to its corners.
            let picture = adoptedPicture()
            picture.contents = image
            picture.contentsGravity = .resize
            picture.mask = adoptedClip()
        case .icon(let image):
            // A square icon in a rectangular tile: centred and padded by `GuideModel.placeholder`, so it
            // never reaches a corner and needs no mask.
            let picture = adoptedPicture()
            picture.contents = image
            picture.contentsGravity = .resizeAspect
            picture.mask = nil
        }
        // A swap between two frames of the same shape gets no `place`, so it fits itself to the shape
        // already drawn. Nothing to fit before the first one, which follows within the same transaction.
        if let drawn { fitPicture(to: drawn.size, corners: drawn.corners, stroke: drawn.stroke) }
    }

    /// Place the shape for this frame, in the parent layer's own coordinates.
    func place(_ frame: CGRect, corners: Corners, stroke: CGFloat = 0) {
        layer.frame = frame
        guard drawn?.size != frame.size || drawn?.corners != corners || drawn?.stroke != stroke else {
            return
        }
        drawn = (frame.size, corners, stroke)
        layer.lineWidth = stroke

        let bounds = CGRect(origin: .zero, size: frame.size)
        layer.path = Self.path(bounds.insetBy(dx: stroke / 2, dy: stroke / 2),
                               corners.inset(by: Double(stroke) / 2))
        fitPicture(to: frame.size, corners: corners, stroke: stroke)
    }

    /// Fit the picture to a shape of this size and curve — how it is fitted being the whole of the
    /// difference between the two cases that draw something.
    private func fitPicture(to size: CGSize, corners: Corners, stroke: CGFloat) {
        guard let picture else { return }
        let bounds = CGRect(origin: .zero, size: size)
        switch carried {
        case .still:
            picture.frame = bounds
            clip?.frame = bounds
            // Inside the stroke rather than under it: the stroke is the tile's own edge and has to read
            // at its full width against a still that fills everything up to it.
            clip?.path = Self.path(bounds.insetBy(dx: stroke, dy: stroke),
                                   corners.inset(by: Double(stroke)))
        case .icon:
            // Centred, which is why no reflection appears: the flip between the core's top-left rect and
            // the layer's bottom-left one is the identity on a rect centred in this very size.
            let rect = GuideModel.placeholder(in: Size(width: size.width, height: size.height))
            picture.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        case .blank:
            break
        }
    }

    private func adoptedPicture() -> CALayer {
        if let picture { return picture }
        let built = CALayer()
        built.contentsScale = contentsScale
        built.minificationFilter = .trilinear
        layer.addSublayer(built)
        picture = built
        return built
    }

    private func adoptedClip() -> CAShapeLayer {
        if let clip { return clip }
        let built = CAShapeLayer()
        built.contentsScale = contentsScale
        clip = built
        return built
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
