import AppKit
import QuartzCore
import EmiraCore

// The minimap of the strip: a **ribbon layer** carrying one pooled shape per window, a rule on every
// boundary between them, the live viewport and the focus ring.
//
// The ribbon is the renderer's root, so its bounds are the panel and everything inside is placed in its
// own coordinates. **The host frames it** — over the desktop in the daemon, inside a mock display in the
// settings window — and the two differ in nothing but that frame and `scale`.
//
// The ribbon is the only rounded thing here that is a `cornerRadius`. Everything inside it is a
// `RoundedLayer`, because a tile in the ribbon's corner has to round *to* the ribbon on the side it
// touches and to itself everywhere else — four radii, where a layer has one.
//
// A tile carries no edge of its own. What says where one window ends and the next begins is a
// **separator** on the boundary between them — a line drawn once for the two of them, running the full
// height of the columns it parts or the full width of the column it divides. Those are plain layers,
// pooled by count under the tiles: a boundary is a rectangle a fraction of a point wide, and nothing
// about it wants a path.

/// The preview guide's layer tree.
@MainActor public final class PreviewGuideRenderer: GuideRenderer {

    public let style: GuideStyle = .preview

    /// The ribbon: clipped and rounded, so a tile running off the strip's end is cut at its boundary.
    public let layer: CALayer = CALayer()

    /// The live viewport, drawn under the tiles as an outline. The travelling part: it slides within
    /// the ribbon as the strip scrolls, and pins to an end when the strip does.
    private let viewport: RoundedLayer
    /// The focus ring, drawn over everything, at the focused window's frame plus its in-flight travel.
    private let ring: RoundedLayer
    /// Pooled by `WindowId`, built and torn down only as the id *set* changes; a frame is then an
    /// offer of content and a `place` per tile.
    private var tiles: [WindowId: RoundedLayer] = [:]
    /// The lines the strip divides along, under the tiles. Pooled by *count*: a boundary has no identity
    /// to key on, and the count changes only when the strip's shape does.
    private var separators: [CALayer] = []

    private let contentsScale: CGFloat
    /// The colours on screen. Compared rather than re-assigned, so an appearance change is a restyle
    /// and every other frame costs one struct comparison.
    private var painted: GuidePalette?

    public init(contentsScale: CGFloat) {
        self.contentsScale = contentsScale
        layer.contentsScale = contentsScale
        layer.masksToBounds = true

        viewport = RoundedLayer(contentsScale: contentsScale)
        layer.addSublayer(viewport.layer)
        ring = RoundedLayer(contentsScale: contentsScale)
        layer.addSublayer(ring.layer)
    }

    // A frame

    /// Draw one frame of the guide.
    ///
    /// `sources` is asked for **every tile, every frame**: a window's pixels reach the still cache only
    /// when the cover they were filmed for comes down, which is strictly later than the frame its tile
    /// was built in, so a tile asked once would be asked at the one moment there is nothing to answer
    /// with. An answer costs a dictionary lookup, and only a tile whose answer changed touches a layer.
    public func draw(_ drawing: GuideDrawing, settings: GuideSettings, scale: Double,
                     palette: GuidePalette, sources: GuideSources) {
        // A renderer draws its own style and the host is what pairs the two; a drawing of another
        // guide's is nothing rather than a wrong picture.
        guard case .preview(let layout) = drawing else { return }
        let metrics = Metrics(scale: scale, panel: layout.panel)

        CATransaction.begin()
        // The guide's geometry comes from the core's own animators, frame by frame; without this each
        // assignment would start an implicit 0.25 s animation of its own — `contents` included, which is
        // why the pool is reconciled inside the transaction rather than ahead of it.
        CATransaction.setDisableActions(true)
        restyle(to: palette)
        reconcile(layout.tiles, content: settings.preview.content, sources: sources)

        layer.bounds = CGRect(origin: .zero, size: metrics.drawnSize)
        if layer.cornerRadius != metrics.panelRadius { layer.cornerRadius = metrics.panelRadius }
        layer.borderWidth = metrics.panelEdgeWidth

        for tile in layout.tiles {
            tiles[tile.window]?.place(metrics.local(tile.rect), corners: metrics.corners(tile.rect))
        }
        fitSeparators(to: layout.separators.count, palette: palette)
        for (line, rect) in zip(separators, layout.separators) {
            // A boundary is a line and arrives with no thickness, so it is fattened about itself — on
            // both axes, the half point it gains at each end being what closes the joint where two of
            // them meet.
            line.frame = metrics.local(rect).insetBy(dx: -metrics.separatorWidth / 2,
                                                     dy: -metrics.separatorWidth / 2)
        }
        viewport.place(metrics.local(layout.viewport), corners: metrics.corners(layout.viewport),
                       stroke: metrics.viewportEdgeWidth)
        ring.layer.isHidden = layout.ring == nil
        if let rect = layout.ring {
            ring.place(metrics.local(rect), corners: metrics.corners(rect), stroke: metrics.ringWidth)
        }
        CATransaction.commit()
    }

    /// Match the tile pool to `wanted`, then offer each tile its content.
    ///
    /// A tile survives everything but its own window leaving the strip, a newcomer arriving beside it
    /// included. What it is kept for is its drawn-shape cache: that is what lets a frame which only
    /// moves a tile rebuild no path.
    private func reconcile(_ wanted: [GuideTile], content: GuideContent, sources: GuideSources) {
        let live = Set(wanted.map(\.window))
        for id in Set(tiles.keys).subtracting(live) {
            tiles.removeValue(forKey: id)?.layer.removeFromSuperlayer()
        }
        for tile in wanted {
            let shape = tiles[tile.window] ?? build(tile.window)
            shape.carry(picture(of: tile, content: content, from: sources))
        }
    }

    /// What one tile draws: the window's own still where the setting asks for stills and something has
    /// filmed it, and the app's icon otherwise. It paints something whatever the answer turns out to be
    /// — at this scale a hole reads as a missing window, and a window with no pixels is still on the
    /// strip.
    private func picture(of tile: GuideTile, content: GuideContent,
                         from sources: GuideSources) -> TileContent {
        if content == .stills, let image = sources.still(tile.window) { return .still(image) }
        if let icon = sources.icon(tile.bundleId) { return .icon(icon) }
        return .blank
    }

    /// A tile's layer, in the tree and in the pool. No edge — what says where one window ends and the
    /// next begins is the separator between them, drawn once for the two of them rather than twice, and
    /// running the whole length of what it divides.
    private func build(_ id: WindowId) -> RoundedLayer {
        let shape = RoundedLayer(contentsScale: contentsScale)
        shape.style(fill: painted?.tileFill, edge: nil)
        tiles[id] = shape
        // Below the ring and so above the separators, wherever the pool's older layers happen to sit:
        // tiles partition the strip and never overlap, so their order among themselves says nothing.
        layer.insertSublayer(shape.layer, below: ring.layer)
        return shape
    }

    /// Grow or shrink the separator pool to `count`. New lines go in directly above the viewport, so
    /// they stay under the tiles however the pool above them comes and goes.
    private func fitSeparators(to count: Int, palette: GuidePalette) {
        while separators.count > count { separators.removeLast().removeFromSuperlayer() }
        while separators.count < count {
            let line = CALayer()
            line.contentsScale = contentsScale
            line.backgroundColor = palette.separator
            separators.append(line)
            layer.insertSublayer(line, above: viewport.layer)
        }
    }

    /// Take the colours again. A no-op on every frame but the one where the appearance changed, or
    /// where a host handed over a different palette entirely.
    private func restyle(to palette: GuidePalette) {
        guard painted != palette else { return }
        painted = palette
        layer.backgroundColor = palette.panelFill
        layer.borderColor = palette.panelEdge
        viewport.style(fill: nil, edge: palette.viewportEdge)
        ring.style(fill: nil, edge: palette.ring)
        for tile in tiles.values { tile.style(fill: palette.tileFill, edge: nil) }
        for line in separators { line.backgroundColor = palette.separator }
    }

    /// One frame's cosmetics and one frame's geometry, both at `scale`. **Every length below is
    /// multiplied by it**: a ribbon at a quarter of the size wears a quarter-point border and a
    /// five-point curve.
    private struct Metrics {
        let scale: Double
        /// The panel in guide points, unscaled — what everything inside it is measured against.
        let panel: Rect

        var drawnSize: CGSize {
            CGSize(width: panel.width * scale, height: panel.height * scale)
        }

        /// The ribbon's curve, held to a quarter of its short side — the ceiling the separation keeps,
        /// for the same reason: a small guide should read as a rounded rectangle and not as a lozenge.
        var radius: Double { min(Self.panelRadius, min(panel.width, panel.height) / 4) }

        var panelRadius: CGFloat { CGFloat(radius * scale) }
        var panelEdgeWidth: CGFloat { CGFloat(Self.panelEdgeWidth * scale) }
        var separatorWidth: CGFloat { CGFloat(Self.separatorWidth * scale) }
        var viewportEdgeWidth: CGFloat { CGFloat(Self.viewportEdgeWidth * scale) }
        var ringWidth: CGFloat { CGFloat(Self.ringWidth * scale) }

        /// A panel-local (top-left) rect in the ribbon's own (bottom-left) coordinates, at `scale`. The
        /// reflection is about the ribbon's mid-line: both rects are measured from the same origin, so
        /// the display's own flip height cancels and never appears.
        func local(_ rect: Rect) -> CGRect {
            CGRect(x: rect.minX * scale, y: (panel.height - rect.maxY) * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }

        /// A tile's four radii. Computed in guide points and scaled afterwards, which is the same answer
        /// either way — every term of the rule is a length — and keeps the arithmetic readable.
        ///
        /// Everything inside rounds to the **inner** edge of the ribbon's curve, a border's width in and
        /// a border's width tighter, since that is the line a tile is actually held off.
        func corners(_ rect: Rect) -> Corners {
            let inner = Rect(origin: .zero, size: panel.size)
                .insetBy(dx: Self.panelEdgeWidth, dy: Self.panelEdgeWidth)
            return GuideModel.corners(of: rect, in: inner, radius: Self.tileRadius,
                                      outer: radius - Self.panelEdgeWidth)
                .scaled(by: scale)
        }

        /// The ribbon's curve at full size, and the radius everything inside it rounds *to* as it
        /// reaches a corner. Generous on purpose: it is what makes the guide read as one object rather
        /// than as a rectangle with rectangles in it, and `GuideModel.corners` is what keeps a tile from
        /// being clipped square by it.
        static let panelRadius: Double = 20
        /// A tile's own curve, away from the ribbon's corners.
        static let tileRadius: Double = 4

        static let panelEdgeWidth: Double = 1
        /// A hairline: one device pixel at 2×, and lighter than the ribbon's own edge on purpose, since
        /// a grid of interior rules as heavy as the frame around them reads as a cage.
        static let separatorWidth: Double = 0.5
        static let viewportEdgeWidth: Double = 1
        static let ringWidth: Double = 1.5
    }
}
