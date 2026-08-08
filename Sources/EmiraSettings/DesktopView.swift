import AppKit
import QuartzCore
import EmiraCore

// The mock monitor: a floating slab holding the user's own wallpaper, a menu-bar band at the real
// height, and one pooled `CALayer` per mock window — the guide's tile pool at another scale.
//
// **It takes no input, and it absorbs it.** Nothing inside the mock is reachable by the pointer — no
// hover, no focus, no drag — but a click on it is *swallowed* rather than passed through. Those are two
// different things and the difference is the whole of dismissal: the mock is the thing the user is
// looking at, so a click on it must not be a click on the scrim behind it.
//
// A pane is **opaque and shadowed**, because a translucent one stops reading as a window and starts
// reading as a diagram. It carries a suggestion of content — a header tinted from the icon and a few
// skeleton rules — for the same reason: at this scale a bare slab with a centred glyph reads as a
// diagram too. Suggestion, never simulation: it must not look like a screenshot of an app, because it
// isn't one.

@MainActor
final class DesktopView: NSView {

    private let monitor = CALayer()
    private let ground = CALayer()
    private let menuBar: MockMenuBar
    /// The mock pointer, above every pane. Hidden unless the set carries one.
    private let pointer = CAShapeLayer()
    /// The guide, above the panes and under the pointer — the order the real one keeps.
    private let ribbon = CALayer()
    private let viewport = CALayer()
    private let ring = CALayer()
    private var guideTiles: [CALayer] = []
    /// Pooled by mock window id, built and torn down only as the id *set* changes.
    private var panes: [WindowId: PaneLayer] = [:]

    private var projection: Projection
    private var backingScale: CGFloat
    /// The desktop picture and how it is fitted — also what the menu bar asks how bright it is.
    private var wallpaper = Wallpaper(image: nil, gravity: .resizeAspectFill, fill: .windowBackgroundColor)

    init(projection: Projection, backingScale: CGFloat) {
        self.projection = projection
        self.backingScale = backingScale
        self.menuBar = MockMenuBar(scale: backingScale)
        super.init(frame: CGRect(origin: .zero, size: projection.mockSize))
        wantsLayer = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The mock desktop is a picture, and a click lands on it and stops there.
    ///
    /// Answering `self` rather than `nil` is what keeps a click off the dim behind: `nil` would let the
    /// pointer fall straight through to the scrim, which dismisses. Nothing *inside* is addressable —
    /// `hitTest` never answers a sublayer or a pane, so there is still nothing here to drive.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // In this view's superview's coordinates, which is what `hitTest` is handed.
        frame.contains(point) ? self : nil
    }

    /// Swallowed. The mock is not a desktop to be operated, and it is not a way out of the window
    /// either — the way out is Escape, or a deliberate double click on the blur.
    override func mouseDown(with event: NSEvent) {}

    /// So the first click into a window that is not already active is swallowed here too, rather than
    /// activating and then reaching whatever is underneath.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func build() {
        guard let host = layer else { return }
        host.contentsScale = backingScale

        monitor.frame = CGRect(origin: .zero, size: projection.mockSize)
        monitor.contentsScale = backingScale
        monitor.cornerRadius = SettingsStyle.monitorRadius
        monitor.cornerCurve = .continuous
        monitor.backgroundColor = NSColor.black.cgColor
        monitor.borderWidth = 1
        monitor.borderColor = SettingsStyle.monitorEdge
        monitor.shadowColor = NSColor.black.cgColor
        monitor.shadowOpacity = SettingsStyle.monitorShadowOpacity
        monitor.shadowRadius = SettingsStyle.monitorShadowRadius
        monitor.shadowOffset = SettingsStyle.monitorShadowOffset
        host.addSublayer(monitor)

        // Clipped and rounded: a column running off the strip's end is cut at the display's edge, which
        // is what the real one does.
        ground.frame = CGRect(origin: .zero, size: projection.mockSize)
        ground.contentsScale = backingScale
        ground.cornerRadius = SettingsStyle.monitorRadius
        ground.cornerCurve = .continuous
        ground.masksToBounds = true
        ground.contentsGravity = .resizeAspectFill
        monitor.addSublayer(ground)

        ground.addSublayer(menuBar.layer)

        // **Above the panes by rank, not by insertion order.** A pane is pooled and added whenever its
        // window first appears, so anything added at build time is underneath every window that arrives
        // later — which for the guide and the pointer means never being seen at all.
        ribbon.zPosition = 10
        pointer.zPosition = 20
        ribbon.contentsScale = backingScale
        ribbon.masksToBounds = true
        ribbon.backgroundColor = SettingsStyle.guideFill
        ribbon.borderWidth = 1
        ribbon.borderColor = SettingsStyle.guideEdge
        ribbon.isHidden = true
        ground.addSublayer(ribbon)

        viewport.contentsScale = backingScale
        viewport.borderWidth = 1
        viewport.borderColor = SettingsStyle.guideViewportEdge
        ribbon.addSublayer(viewport)

        ring.contentsScale = backingScale
        ring.borderWidth = 1.5
        ring.borderColor = SettingsStyle.paneFocusEdge
        ribbon.addSublayer(ring)

        pointer.contentsScale = backingScale
        pointer.fillColor = NSColor.white.cgColor
        pointer.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
        pointer.lineWidth = 0.75
        pointer.lineJoin = .round
        pointer.isHidden = true
        // Its own soft shadow, the way the real one reads over a busy desktop.
        pointer.shadowColor = NSColor.black.cgColor
        pointer.shadowOpacity = 0.4
        pointer.shadowRadius = 2
        pointer.shadowOffset = CGSize(width: 0, height: -1)
        ground.addSublayer(pointer)

        loadWallpaper()
        layoutChrome()
    }

    /// The slab's own size, for the scrim to place it by.
    var mockSize: CGSize { projection.mockSize }

    /// Take the appearance again. Every `CGColor` here was resolved when its layer was built, so a live
    /// light/dark switch is a restyle rather than a redraw.
    ///
    /// The panes are **dropped rather than repainted**: a pane owns half a dozen resolved colours across
    /// three layers, and the pool rebuilds one on the next frame anyway. Re-listing them here would be a
    /// second copy of `PaneLayer.init` to keep in step.
    func restyle() {
        monitor.borderColor = SettingsStyle.monitorEdge
        ribbon.backgroundColor = SettingsStyle.guideFill
        ribbon.borderColor = SettingsStyle.guideEdge
        viewport.borderColor = SettingsStyle.guideViewportEdge
        ring.borderColor = SettingsStyle.paneFocusEdge
        for tile in guideTiles { tile.backgroundColor = SettingsStyle.guideTileFill }
        for pane in panes.values { pane.layer.removeFromSuperlayer() }
        panes.removeAll()
        loadWallpaper()
        layoutChrome()
    }

    /// Re-home on a new projection — a display change, or the window moving to another screen.
    func reproject(_ projection: Projection, backingScale: CGFloat) {
        self.projection = projection
        self.backingScale = backingScale
        frame = CGRect(origin: frame.origin, size: projection.mockSize)
        monitor.frame = CGRect(origin: .zero, size: projection.mockSize)
        ground.frame = monitor.frame
        menuBar.reproject(scale: backingScale)
        // Every pooled layer holds the old display's `contentsScale`; moving between a Retina panel and
        // a 1× one without this leaves the mock rendered at the wrong resolution until its next rebuild.
        for pane in panes.values { pane.layer.removeFromSuperlayer() }
        panes.removeAll()
        for layer in [monitor, ground, ribbon, viewport, ring, pointer as CALayer] {
            layer.contentsScale = backingScale
        }
        loadWallpaper()
        layoutChrome()
    }

    /// Lay the menu bar out, in whichever of black or white reads over what is behind it. Called after
    /// `loadWallpaper`, since the pixels underneath are what decide the colour.
    private func layoutChrome() {
        let size = projection.mockSize
        let band = CGFloat(projection.menuBandHeight)
        menuBar.place(width: size.width, height: band, projection: projection,
                      luminance: wallpaper.luminanceUnderMenuBar(layer: size, band: band))
        // Bottom-left space: the band is at the top, so it sits a band's height down from the ceiling.
        menuBar.layer.frame = CGRect(x: 0, y: size.height - band, width: size.width, height: band)
    }

    /// The user's own wallpaper, fitted the way their own desktop fits it.
    private func loadWallpaper() {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        wallpaper = Wallpaper.current(for: screen)
        ground.contents = wallpaper.image
        ground.contentsGravity = wallpaper.gravity
        ground.minificationFilter = .trilinear
        // Shows wherever the image does not reach: the letterbox of a genuine "Fit to Screen", and
        // nothing at all under a fill.
        ground.backgroundColor = wallpaper.fill.cgColor
    }

    // A frame

    /// Draw one frame of the mock desktop. `frames` are true points on the display; `k` is applied here
    /// and nowhere earlier.
    func render(scene: Scene, frames: [WindowId: Rect],
                pointer location: Point? = nil, showsPointer: Bool = true,
                guide: GuidePreview? = nil) {
        CATransaction.begin()
        // The geometry comes from the preview's own animators, frame by frame; without this each
        // assignment would start an implicit quarter-second animation of its own.
        CATransaction.setDisableActions(true)

        reconcile(scene)
        for window in scene.windows {
            guard let frame = frames[window.id] else { continue }
            panes[window.id]?.place(projection.mock(frame),
                                    focused: window.id == scene.focus,
                                    projection: projection)
        }
        place(guide: guide)
        place(pointer: location, shown: showsPointer)

        CATransaction.commit()
    }

    /// The guide, at the mock's scale. Its panel arrives in true screen points and everything inside it
    /// in panel-local *guide* points — `GuideLayout`'s own convention — so the inner rects take `k`
    /// alone while the panel takes the whole projection.
    private func place(guide: GuidePreview?) {
        guard let guide else { return ribbon.isHidden = true }
        ribbon.isHidden = false
        let panel = projection.mock(guide.panel)
        ribbon.frame = panel
        ribbon.cornerRadius = min(SettingsStyle.guideRadius, min(panel.width, panel.height) / 4)

        while guideTiles.count > guide.tiles.count {
            guideTiles.removeLast().removeFromSuperlayer()
        }
        while guideTiles.count < guide.tiles.count {
            let tile = CALayer()
            tile.contentsScale = backingScale
            tile.backgroundColor = SettingsStyle.guideTileFill
            guideTiles.append(tile)
            ribbon.insertSublayer(tile, below: ring)
        }
        for (tile, rect) in zip(guideTiles, guide.tiles) { tile.frame = local(rect, in: panel.size) }
        viewport.frame = local(guide.viewport, in: panel.size)
        ring.isHidden = guide.ring == nil
        if let rect = guide.ring { ring.frame = local(rect, in: panel.size) }
    }

    /// A panel-local guide rect as a layer frame inside the ribbon: scaled by `k`, and reflected about
    /// the ribbon's own mid-line because Core Animation counts up from the bottom.
    private func local(_ rect: Rect, in size: CGSize) -> CGRect {
        let k = projection.k
        return CGRect(x: rect.minX * k, y: size.height - rect.maxY * k,
                      width: rect.width * k, height: rect.height * k)
    }

    /// The pointer, drawn at true scale like everything else: `k` applied once, here.
    ///
    /// Kept above the panes by re-adding it — a pane built later would otherwise be composited over the
    /// cursor, which no desktop does.
    private func place(pointer location: Point?, shown: Bool) {
        guard let location else { return pointer.isHidden = true }
        pointer.isHidden = !shown
        let side = projection.mock(Self.pointerHeight)
        pointer.path = Self.arrow(height: side)
        let origin = projection.mock(Rect(x: location.x, y: location.y, width: 0, height: 0))
        // A cursor's hotspot is its tip, and the tip is the path's top-left in a flipped-y layer.
        pointer.frame = CGRect(x: origin.minX, y: origin.minY - side, width: side * 0.62, height: side)
    }

    /// The macOS arrow's height in true points, so it projects like everything else.
    private static let pointerHeight: Double = 20

    /// The classic arrow, drawn rather than rasterized: a path is exact at any `k`, where a bitmap of a
    /// cursor would be resampled twice.
    private static func arrow(height: CGFloat) -> CGPath {
        let w = height * 0.62
        let path = CGMutablePath()
        // Bottom-left origin, tip at the top left.
        path.move(to: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: height * 0.22))
        path.addLine(to: CGPoint(x: w * 0.30, y: height * 0.42))
        path.addLine(to: CGPoint(x: w * 0.50, y: 0))
        path.addLine(to: CGPoint(x: w * 0.72, y: height * 0.08))
        path.addLine(to: CGPoint(x: w * 0.52, y: height * 0.48))
        path.addLine(to: CGPoint(x: w, y: height * 0.44))
        path.closeSubpath()
        return path
    }

    /// Match the pane pool to the set. A pane survives everything but its window leaving the scene.
    private func reconcile(_ scene: Scene) {
        let live = Set(scene.windows.map(\.id))
        for id in Set(panes.keys).subtracting(live) {
            panes.removeValue(forKey: id)?.layer.removeFromSuperlayer()
        }
        for window in scene.windows where panes[window.id] == nil {
            let pane = PaneLayer(role: window.role, scale: backingScale)
            panes[window.id] = pane
            ground.addSublayer(pane.layer)
        }
    }
}

/// One mock window: an opaque rounded slab with a title band, three stoplights, the app's real icon and
/// a suggestion of content.
///
/// **Two layers, because a shadow and a clip cannot share one.** `masksToBounds` clips the shadow along
/// with the sublayers, so the outer layer carries the shadow and nothing else while the inner one is the
/// window: rounded, clipped, and therefore able to cut the square title band to its own corners. Without
/// the split the band paints over the top corners and the pane reads as a rectangle. It is the same
/// split `Reconstruction` makes for the same reason — "it costs `root` its alpha-derived shadow, hence
/// the shadow a layer up".
@MainActor
final class PaneLayer {

    /// The outer layer: the shadow, and the frame everything else is measured against.
    let layer = CALayer()
    /// The window itself — rounded and clipping, so every sublayer is cut to its corners.
    private let body = CALayer()
    private let band = CALayer()
    private let icon = CALayer()
    private var stoplights: [CALayer] = []
    private var rules: [CALayer] = []

    init(role: MockRole, scale: CGFloat) {
        layer.contentsScale = scale
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = SettingsStyle.paneShadowOpacity

        body.contentsScale = scale
        body.cornerCurve = .continuous
        body.masksToBounds = true
        body.backgroundColor = SettingsStyle.paneFill
        body.borderWidth = SettingsStyle.paneEdgeWidth
        body.borderColor = SettingsStyle.paneEdge
        layer.addSublayer(body)

        band.contentsScale = scale
        band.backgroundColor = SettingsStyle.paneTitleFill
        body.addSublayer(band)

        for fill in SettingsStyle.stoplights {
            let dot = CALayer()
            dot.contentsScale = scale
            dot.backgroundColor = fill
            stoplights.append(dot)
            band.addSublayer(dot)
        }

        // Four rules standing in for content. Never a simulation of an app — just enough that the pane
        // does not read as an empty rectangle.
        for _ in 0..<4 {
            let rule = CALayer()
            rule.contentsScale = scale
            rule.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
            rules.append(rule)
            body.addSublayer(rule)
        }

        icon.contentsScale = scale
        icon.contents = MockIcons.icon(for: role)
        icon.contentsGravity = .resizeAspect
        // Always shrinking a 512 px raster, so the filter that matters is the minifying one — trilinear
        // takes the mip chain rather than point-sampling it into aliasing.
        icon.minificationFilter = .trilinear
        icon.opacity = 0.9
        body.addSublayer(icon)
    }

    /// Put the pane at `frame` — a mock-local rect that already carries `k`.
    func place(_ frame: CGRect, focused: Bool, projection: Projection) {
        layer.frame = frame
        body.frame = CGRect(origin: .zero, size: frame.size)
        body.borderWidth = focused ? SettingsStyle.paneFocusEdgeWidth : SettingsStyle.paneEdgeWidth
        body.borderColor = focused ? SettingsStyle.paneFocusEdge : SettingsStyle.paneEdge

        // The compositor's own shadow spec, at mock scale. Cast from the pane's own rounded silhouette
        // rather than derived from its alpha: the outer layer paints nothing, so there is no alpha to
        // derive one from.
        layer.shadowRadius = projection.mock(SettingsStyle.paneShadowRadius)
        layer.shadowOffset = CGSize(width: projection.mock(Double(SettingsStyle.paneShadowOffset.width)),
                                    height: projection.mock(Double(SettingsStyle.paneShadowOffset.height)))
        // Every dimension below is a **real** window's, projected — a fixed mock radius is a different
        // real radius at every `k`, and next to an actual desktop that reads as the wrong window.
        let radius = min(projection.mock(SettingsStyle.paneRadius), min(frame.width, frame.height) / 4)
        body.cornerRadius = radius
        layer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: frame.size),
                                  cornerWidth: radius, cornerHeight: radius, transform: nil)

        let bandHeight = min(projection.mock(SettingsStyle.paneTitleBandHeight), frame.height / 3)
        band.frame = CGRect(x: 0, y: frame.height - bandHeight, width: frame.width, height: bandHeight)

        let dot = min(projection.mock(SettingsStyle.stoplightDiameter), bandHeight * 0.45)
        let pitch = projection.mock(SettingsStyle.stoplightPitch)
        let inset = projection.mock(SettingsStyle.stoplightInset)
        for (i, light) in stoplights.enumerated() {
            light.frame = CGRect(x: inset - dot / 2 + CGFloat(i) * pitch,
                                 y: (bandHeight - dot) / 2, width: dot, height: dot)
            light.cornerRadius = dot / 2
            // Below about a point across they are three smudges rather than three lights.
            light.isHidden = dot < 2 || frame.width < inset * 2 + pitch * 3
        }

        let content = frame.height - bandHeight
        let side = min(frame.width, content) * 0.34
        icon.frame = CGRect(x: (frame.width - side) / 2, y: (content - side) / 2,
                            width: side, height: side)
        icon.isHidden = side < 12

        // The rules sit above the icon, top-aligned, like the first lines of a document.
        let margin = min(14, frame.width * 0.12)
        let lineHeight = max(1, min(3, content * 0.012))
        for (i, rule) in rules.enumerated() {
            let width = (frame.width - margin * 2) * [1.0, 0.82, 0.9, 0.55][i]
            rule.frame = CGRect(x: margin,
                                y: frame.height - bandHeight - CGFloat(i + 1) * lineHeight * 4.5,
                                width: max(0, width), height: lineHeight)
            rule.isHidden = content < 80 || frame.width < 90
        }
    }
}
