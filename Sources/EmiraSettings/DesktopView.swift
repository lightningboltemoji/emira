import AppKit
import QuartzCore
import EmiraCore
import EmiraGuide

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
    /// The display's own rounded edge, and the clip the camera moves inside. **Fixed** — the bezel never
    /// travels, or the slab would fight `Stage`'s own placement zoom.
    private let ground = CALayer()
    /// The desktop picture, placed at the camera's projection of the whole display: at rest it fills the
    /// clip exactly, and a push-in slides and enlarges it like everything else on the screen.
    private let paper = CALayer()
    private let menuBar: MockMenuBar
    /// The mock pointer, above every pane. Hidden unless the set carries one.
    private let pointer = CAShapeLayer()
    /// The guides, above the panes and under the pointer — the order the real ones keep. **The real
    /// renderers**, drawn at the mock's own scale rather than a second drawing of the same thing.
    private var guides: [GuideStyle: any GuideRenderer]
    /// The one non-geometric mark: the gutter under the hand, or the tick where a column edge landed.
    private let mark = CALayer()
    /// The rect the band's ink was last measured against, and what it came out. A wallpaper sample per
    /// frame would be a `CGImage` crop and a downscale to move a lens.
    private var sampledInk: (over: CGRect, ink: CGColor)?
    /// The input badge — the settings window supplying a cause the desktop cannot show.
    private let cue: CueLayer
    /// Pooled by mock window id, built and torn down only as the id *set* changes.
    private var panes: [WindowId: PaneLayer] = [:]

    /// The display at rest — the slab's size, and what a camera is resolved against.
    private var projection: Projection
    /// The projection **this frame** is drawn through: `projection` looking at wherever the camera has
    /// got to. Everything inside the clip is placed with it, so one number carries the push-in.
    private var framing: Projection
    /// The band the menu bar was last laid out across, so a still camera re-measures no text.
    private var placedBand: CGSize = .zero
    /// What the pointer's opacity is already on its way to, so a fade is started once rather than once
    /// a frame.
    private var pointerShown: Float?
    private var cueShown: Float?
    /// The same, per guide: two can be on their way out at once, and a shared memory would let one
    /// answer for the other.
    private var guideOpacity: [GuideStyle: Float] = [:]
    private var backingScale: CGFloat
    /// The desktop picture and how it is fitted — also what the menu bar asks how bright it is.
    private var wallpaper = Wallpaper(image: nil, gravity: .resizeAspectFill, fill: .windowBackgroundColor)

    init(projection: Projection, backingScale: CGFloat) {
        self.projection = projection
        self.framing = projection
        self.backingScale = backingScale
        self.menuBar = MockMenuBar(scale: backingScale)
        self.cue = CueLayer(scale: backingScale)
        self.guides = Self.renderers(contentsScale: backingScale)
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
        monitor.borderWidth = SettingsStyle.monitorEdgeWidth
        monitor.borderColor = SettingsStyle.monitorEdge
        monitor.shadowColor = NSColor.black.cgColor
        monitor.shadowOpacity = SettingsStyle.monitorShadowOpacity
        monitor.shadowRadius = SettingsStyle.monitorShadowRadius
        monitor.shadowOffset = SettingsStyle.monitorShadowOffset
        host.addSublayer(monitor)

        // Clipped and rounded: a column running off the strip's end is cut at the display's edge, which
        // is what the real one does — and it is the same clip the camera lives inside.
        ground.frame = CGRect(origin: .zero, size: projection.mockSize)
        ground.contentsScale = backingScale
        ground.cornerRadius = SettingsStyle.monitorRadius
        ground.cornerCurve = .continuous
        ground.masksToBounds = true
        monitor.addSublayer(ground)

        // Under everything, and the only layer whose *frame* is the whole display rather than a rect on
        // it — a camera pushing in enlarges the wallpaper exactly as it enlarges a window.
        paper.contentsScale = backingScale
        paper.contentsGravity = .resizeAspectFill
        paper.zPosition = -10
        ground.addSublayer(paper)

        ground.addSublayer(menuBar.layer)

        // **Above the panes by rank, not by insertion order.** A pane is pooled and added whenever its
        // window first appears, so anything added at build time is underneath every window that arrives
        // later — which for the guide and the pointer means never being seen at all.
        mark.zPosition = 5
        pointer.zPosition = 20

        mark.isHidden = true
        ground.addSublayer(mark)
        ground.addSublayer(cue.layer)
        adoptGuides()

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
        mark.backgroundColor = SettingsStyle.markInk
        cue.reproject(scale: backingScale)
        cueShown = nil
        // The guide takes its colours as an argument every frame, so the next one restyles it.
        for pane in panes.values { pane.layer.removeFromSuperlayer() }
        panes.removeAll()
        placedBand = .zero
        loadWallpaper()
        layoutChrome()
    }

    /// Re-home on a new projection — a display change, or the window moving to another screen.
    func reproject(_ projection: Projection, backingScale: CGFloat) {
        self.projection = projection
        self.framing = projection
        self.backingScale = backingScale
        frame = CGRect(origin: frame.origin, size: projection.mockSize)
        monitor.frame = CGRect(origin: .zero, size: projection.mockSize)
        ground.frame = monitor.frame
        menuBar.reproject(scale: backingScale)
        cue.reproject(scale: backingScale)
        cueShown = nil
        // Every pooled layer holds the old display's `contentsScale`; moving between a Retina panel and
        // a 1× one without this leaves the mock rendered at the wrong resolution until its next rebuild.
        for pane in panes.values { pane.layer.removeFromSuperlayer() }
        panes.removeAll()
        // Rebuilt rather than adjusted, like a pane: a renderer's whole tree carries the old display's
        // `contentsScale`, and moving between a Retina panel and a 1× one would otherwise leave a guide
        // rendered at the wrong resolution until its next rebuild.
        for renderer in guides.values { renderer.layer.removeFromSuperlayer() }
        guides = Self.renderers(contentsScale: backingScale)
        adoptGuides()
        for layer in [monitor, ground, paper, mark, pointer as CALayer] {
            layer.contentsScale = backingScale
        }
        placedBand = .zero
        loadWallpaper()
        layoutChrome()
    }

    /// Place the wallpaper and the menu bar for the framing this frame is drawn through.
    ///
    /// The bar's *contents* are re-measured only when the band's shape changes, which is never while the
    /// camera is still — laying out seven text layers per frame to move a lens would be paying for a
    /// pan in font metrics.
    private func layoutChrome() {
        paper.frame = framing.mock(projection.displayFrame)

        let band = CGFloat(framing.menuBandHeight)
        let width = paper.frame.width
        let size = CGSize(width: width, height: band)
        if size != placedBand {
            placedBand = size
            menuBar.place(width: width, height: band, projection: framing,
                          luminance: wallpaper.luminanceUnderMenuBar(layer: projection.mockSize,
                                                                     band: CGFloat(projection.menuBandHeight)))
        }
        // Bottom-left space, and against the *wallpaper* rather than the clip: the band belongs to the
        // display, so a camera that has slid the display sideways slides the bar with it.
        menuBar.layer.frame = CGRect(x: paper.frame.minX, y: paper.frame.maxY - band,
                                     width: width, height: band)
    }

    /// The user's own wallpaper, fitted the way their own desktop fits it.
    private func loadWallpaper() {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        wallpaper = Wallpaper.current(for: screen)
        paper.contents = wallpaper.image
        paper.contentsGravity = wallpaper.gravity
        paper.minificationFilter = .trilinear
        // Shows wherever the image does not reach: the letterbox of a genuine "Fit to Screen", and
        // nothing at all under a fill.
        paper.backgroundColor = wallpaper.fill.cgColor
        ground.backgroundColor = wallpaper.fill.cgColor
        // A different picture is a different answer to what reads over it.
        sampledInk = nil
    }

    // A frame

    /// Draw one frame of the mock desktop. `frames` are true points on the display; `k` is applied here
    /// and nowhere earlier.
    ///
    /// `targets` are the same windows where the *layout* puts them, with no in-flight displacement —
    /// which is what says whether a pane has arrived, and therefore when its still is taken again.
    func render(scene: Scene, frames: [WindowId: Rect], targets: [WindowId: Rect],
                camera: Rect, pointer location: Point? = nil, cursor: MockPointer? = nil,
                showsPointer: Bool = true, animation: WindowAnimation = .stretch,
                raised: WindowId? = nil, showsFocus: Bool = true,
                guides: [GuideFrame] = [], mark drawn: Mark.Drawn? = nil) {
        CATransaction.begin()
        // The geometry comes from the preview's own animators, frame by frame; without this each
        // assignment would start an implicit quarter-second animation of its own.
        CATransaction.setDisableActions(true)

        framing = projection.looking(at: camera)
        layoutChrome()

        reconcile(scene)
        for window in scene.windows {
            guard let frame = frames[window.id], let pane = panes[window.id] else { continue }
            capture(pane, drawn: frame.size, target: targets[window.id]?.size)
            pane.place(framing.mock(frame),
                       focused: showsFocus && window.id == scene.focus, projection: framing,
                       animation: animation)
            // A float is over the strip, wherever its app put it — which is what makes it the one kind
            // of window `focus.system-events`' `ignore` rung still honours. A window with a hand on its
            // edge is over it for the length of the drag, because it is growing across a neighbour that
            // has not moved.
            pane.layer.zPosition = window.id == raised ? 2 : (scene.isFloat(window.id) ? 1 : 0)
        }
        place(cue: scene.cue)
        place(mark: drawn)
        place(guides: guides)
        place(pointer: location, cursor: cursor, shown: showsPointer)

        CATransaction.commit()
    }

    /// The mark, in whichever of its two forms.
    ///
    /// **The band is the desktop's and the tick is the window's.** A gutter is a real region of the
    /// screen, so it is projected like everything else and it grows with the camera; a tick is an
    /// annotation on top, so it stays one point wide however far in the lens is — one that grew with the
    /// zoom would read as a rule someone had drawn on the wallpaper. Both are floored at a point,
    /// because a gutter of zero still has to say which edge the row is about.
    private func place(mark drawn: Mark.Drawn?) {
        guard let drawn else { return mark.isHidden = true }
        mark.isHidden = false
        let rect = framing.mock(drawn.rect)
        let thick = CGRect(x: rect.minX, y: rect.minY,
                           width: max(rect.width, Self.markThickness),
                           height: max(rect.height, Self.markThickness))
        switch drawn {
        case .flush:
            mark.backgroundColor = SettingsStyle.markInk
            mark.borderWidth = 0
        case .gutter:
            // **A washed region inside an accent outline**, and the two do different jobs: the outline
            // says *which* edge and where content starts, in the one colour everything the window says
            // about the desktop is drawn in; the wash says *how much*, and is measured because it lies
            // on the user's own picture. At `0` the rect is a point thick and the border fills it, so a
            // gap of nothing is an accent hairline without a special case anywhere.
            mark.backgroundColor = gutterInk(over: thick)
            mark.borderColor = SettingsStyle.markInk
            mark.borderWidth = Self.markThickness
        }
        // **Slid inside the panel's own edge.** At `outer-gap = 0` the hairline lies on the display's
        // outermost point, which is exactly where the monitor paints its border — and a mark nobody can
        // see is worse than none, since the row it explains is four numbers with no picture at all.
        let inside = ground.bounds.insetBy(dx: SettingsStyle.monitorEdgeWidth,
                                           dy: SettingsStyle.monitorEdgeWidth)
        mark.frame = CGRect(
            x: min(max(thick.minX, inside.minX), max(inside.maxX - thick.width, inside.minX)),
            y: min(max(thick.minY, inside.minY), max(inside.maxY - thick.height, inside.minY)),
            width: thick.width, height: thick.height)
    }

    /// A mark is never thinner than a point, which is what makes `outer-gap = 0` a row with a picture.
    private static let markThickness: CGFloat = 1

    /// Black or white over the desktop picture the band covers, whichever reads — the mock menu bar's
    /// own question asked of another strip.
    ///
    /// Sampled through the **wallpaper layer** rather than the slab: that layer is where the picture
    /// actually is, and under a push-in it is bigger than the clip and slid sideways. A band thinner
    /// than the sample depth asks about the ground it sits on instead, since a hairline is thinner than
    /// a pixel of a desktop picture and would answer whatever the interpolator felt like.
    private func gutterInk(over band: CGRect) -> CGColor {
        if let sampled = sampledInk, sampled.over == band { return sampled.ink }
        let depth = SettingsStyle.inkSampleDepth
        let wide = band.insetBy(dx: band.width < depth ? -(depth - band.width) / 2 : 0,
                                dy: band.height < depth ? -(depth - band.height) / 2 : 0)
        // The picture's own space, origin at its top left — where `Wallpaper` measures.
        let region = CGRect(x: wide.minX - paper.frame.minX, y: paper.frame.maxY - wide.maxY,
                            width: wide.width, height: wide.height)
        let ink = wallpaper.luminance(of: region, layer: paper.frame.size) > SettingsStyle.inkFlip
            ? SettingsStyle.gutterOverLight : SettingsStyle.gutterOverDark
        sampledInk = (band, ink)
        return ink
    }

    /// The badge, and its 140 ms in and 100 ms out. Placed against the **slab** rather than the camera:
    /// it belongs to the settings window rather than to the desktop, so a push-in leaves it where it is.
    private func place(cue badge: Cue?) {
        cue.place(badge, in: projection.mockSize)
        // Declined is a dimming as well as a colour, and it rides the same fade — so a cue that arrives
        // already refused arrives *as* a refusal rather than brightening and then giving up.
        let opacity: Float = switch badge?.answer {
        case nil: 0
        case .taken: 1
        case .declined: SettingsStyle.cueDeclinedOpacity
        }
        fade(cue.layer, to: opacity, from: &cueShown)
    }

    /// Bring a layer to `opacity`, over the house style's own in and out.
    ///
    /// **Furniture, so the window's curve and not the user's springs** — and it has to be an explicit
    /// animation, since the frame is drawn inside a transaction with implicit ones turned off. `was`
    /// remembers what is already on screen: re-adding the same animation every frame would restart it
    /// every frame, which is a fade that never finishes.
    private func fade(_ layer: CALayer, to opacity: Float, from was: inout Float?,
                      rising: CFTimeInterval = SettingsStyle.fadeIn,
                      falling: CFTimeInterval = SettingsStyle.fadeOut) {
        guard was != opacity else { return }
        let from = was ?? opacity
        was = opacity
        layer.opacity = opacity
        guard from != opacity else { return }
        let rises = opacity > from
        let duration = rises ? rising : falling
        // A zero duration is a cut asked for, which is what a guide's arrival is.
        guard duration > 0 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: rises ? .easeOut : .easeIn)
        layer.add(fade, forKey: "fade")
    }

    /// **A still is taken when the window arrives, never while it is travelling.** Mid-flight the pane
    /// paints the picture it had before the move into a rect that no longer fits it, which is what the
    /// compositor does with a real window's screenshot — and what `animation.window` is a choice about.
    /// A pane that has never had one takes it at once, since there is nothing to stand in for.
    private func capture(_ pane: PaneLayer, drawn: Size, target: Size?) {
        guard let target else { return }
        guard pane.capturedSize != nil else { return pane.capture(size: target, projection: projection) }
        let arrived = abs(drawn.width - target.width) < Self.arrivalEpsilon
            && abs(drawn.height - target.height) < Self.arrivalEpsilon
        if arrived { pane.capture(size: target, projection: projection) }
    }

    /// How close to its target a pane counts as arrived, in true points. `PreviewMotion`'s own settle
    /// epsilon, so a pruned animator and a re-taken still are the same moment.
    private static let arrivalEpsilon: Double = 0.5

    /// The guides, at the mock's scale — **the same renderers the daemon hosts**. A panel is the
    /// *sprung* one rather than the one the model placed, and the two agree in size because both are the
    /// same panel at the same scale.
    private func place(guides frames: [GuideFrame]) {
        // **Instant up and gentle down, which is the daemon's own pair** — and `duration` is a setting
        // whose whole subject is that exit, so a preview that cut it away would be wrong about the one
        // number beside it. A guide on the way out keeps the panel and the picture it went away with.
        let live = Set(frames.map(\.style))
        for (style, renderer) in guides {
            var shown = guideOpacity[style]
            fade(renderer.layer, to: live.contains(style) ? 1 : 0, from: &shown,
                 rising: GuideFade.up, falling: GuideFade.down)
            guideOpacity[style] = shown
        }
        for frame in frames {
            guard let renderer = guides[frame.style] else { continue }
            renderer.draw(frame.drawing, settings: frame.settings, scale: framing.scale,
                          palette: SettingsStyle.guidePalette, sources: mockSources)
            renderer.layer.frame = framing.mock(frame.panel)
        }
    }

    /// One guide's root layer — what the fade is carried on, readable so a test can ask what the view
    /// actually did rather than re-deriving what it should have.
    func guideLayer(_ style: GuideStyle) -> CALayer? { guides[style]?.layer }

    /// One renderer per style, from the same list the daemon builds its set from — so which class draws
    /// which guide, and in what order, is stated once.
    private static func renderers(contentsScale: CGFloat) -> [GuideStyle: any GuideRenderer] {
        GuideStyle.renderers(contentsScale: contentsScale)
            .reduce(into: [:]) { set, renderer in set[renderer.style] = renderer }
    }

    /// Put the guides' roots in the tree, above the panes by **rank rather than insertion order**: a
    /// pane is pooled and added whenever its window first appears, so a layer added at build time would
    /// otherwise be underneath every window that arrives later.
    private func adoptGuides() {
        guideOpacity = [:]
        for (index, style) in GuideStyle.allCases.enumerated() {
            guard let renderer = guides[style] else { continue }
            renderer.layer.zPosition = 10 + CGFloat(index)
            renderer.layer.opacity = 0
            guideOpacity[style] = 0
            ground.addSublayer(renderer.layer)
        }
    }

    /// Where a guide's pictures and words come from on a mock desktop. **The pane's own still rather
    /// than a fresh drawing at tile size**, which would put a 28 pt title bar across half of a 25 pt
    /// tile.
    private var mockSources: GuideSources {
        GuideSources(still: { [weak self] id in self?.panes[id]?.image },
                     icon: { MockRole(rawValue: $0).flatMap { MockIcons.icon(for: $0) } },
                     name: MockNames.name(for:))
    }

    /// The pointer, drawn at true scale like everything else: `k` applied once, here.
    ///
    /// Kept above the panes by re-adding it — a pane built later would otherwise be composited over the
    /// cursor, which no desktop does.
    private func place(pointer location: Point?, cursor: MockPointer?, shown: Bool) {
        guard let location else {
            pointer.isHidden = true
            pointerShown = nil
            return
        }
        pointer.isHidden = false
        fade(pointer, to: shown ? 1 : 0, from: &pointerShown)
        let side = framing.mock(Self.pointerHeight)
        let origin = framing.mock(Rect(x: location.x, y: location.y, width: 0, height: 0))

        switch cursor?.shape ?? .arrow {
        case .arrow:
            pointer.path = Self.arrow(height: side)
            // A cursor's hotspot is its tip, and the tip is the path's top-left in a flipped-y layer.
            pointer.frame = CGRect(x: origin.minX, y: origin.minY - side,
                                   width: side * 0.62, height: side)
        case .resizeEW:
            // The hotspot of a two-headed arrow is its middle, so it straddles the edge it grabs.
            let width = side * 0.9
            pointer.path = Self.resizeEW(width: width, height: side * 0.5)
            pointer.frame = CGRect(x: origin.minX - width / 2, y: origin.minY - side * 0.25,
                                   width: width, height: side * 0.5)
        }

        // **Pressed is a dimming, not a shrink.** A cursor that changed size under the button would be
        // the only thing on the mock drawn at a size it is not; going darker is the press without the
        // lie, and it is the same accent the ring and the marks use.
        pointer.fillColor = cursor?.isPressed == true
            ? SettingsStyle.markInk : NSColor.white.cgColor
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

    /// The east–west resize cursor: a bar with a head at each end. **The handle announcing itself**,
    /// which is what makes a drag read as a drag rather than as a window resizing on its own.
    private static func resizeEW(width w: CGFloat, height h: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let head = w * 0.22, bar = h * 0.3
        path.move(to: CGPoint(x: 0, y: h / 2))
        path.addLine(to: CGPoint(x: head, y: h))
        path.addLine(to: CGPoint(x: head, y: h / 2 + bar / 2))
        path.addLine(to: CGPoint(x: w - head, y: h / 2 + bar / 2))
        path.addLine(to: CGPoint(x: w - head, y: h))
        path.addLine(to: CGPoint(x: w, y: h / 2))
        path.addLine(to: CGPoint(x: w - head, y: 0))
        path.addLine(to: CGPoint(x: w - head, y: h / 2 - bar / 2))
        path.addLine(to: CGPoint(x: head, y: h / 2 - bar / 2))
        path.addLine(to: CGPoint(x: head, y: 0))
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

/// One mock window: an opaque rounded slab carrying a **still** of its own interior.
///
/// **Two layers, because a shadow and a clip cannot share one.** `masksToBounds` clips the shadow along
/// with the sublayers, so the outer layer carries the shadow and nothing else while the inner one is the
/// window: rounded, clipped, and therefore able to cut the still's square top corners to its own. It is
/// the same split `Reconstruction` makes for the same reason — "it costs `root` its alpha-derived
/// shadow, hence the shadow a layer up".
///
/// **The interior is one image, not a dozen layers.** `MockContent` draws the whole window — band,
/// stoplights, icon and furniture — at the size the window was when it last came to rest, and the pane
/// paints that image into whatever rect it now occupies. That is what a compositor does with a still,
/// and it is why `animation.window` is a `contentsGravity` here rather than a second mechanism.
@MainActor
final class PaneLayer {

    /// The outer layer: the shadow, and the frame everything else is measured against.
    let layer = CALayer()
    /// The window itself — rounded and clipping, so the still is cut to its corners.
    private let body = CALayer()
    /// The still. Its own layer rather than `body.contents`, so a crop can place it at its captured
    /// size inside a body that is a different one.
    private let still = CALayer()

    private let role: MockRole
    private var scale: CGFloat
    /// The true-point size the still was drawn at, or `nil` before the first capture. What says whether
    /// the picture on screen is the window's own size or a stand-in being stretched.
    private(set) var capturedSize: Size?

    /// The still itself. **The guide borrows it** rather than drawing its own: a guide drawing
    /// `stills` showing the window's last still is the relationship the real one has with the cover, and
    /// a tile that re-drew the furniture at tile size would be a different picture of the same app.
    var image: CGImage? { still.contents as! CGImage? }

    init(role: MockRole, scale: CGFloat) {
        self.role = role
        self.scale = scale

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

        still.contentsScale = scale
        still.contentsGravity = .resize
        still.minificationFilter = .trilinear
        body.addSublayer(still)
    }

    /// Draw the interior again, at `size` true points, **cross-fading over 80 ms**.
    ///
    /// That fade is the punchline of `animation.window` and it is what the compositor really does: what
    /// you were looking at was a stand-in, and this is the app catching up. Without it the take says a
    /// still is distorted and never says it stops.
    func capture(size: Size, projection: Projection) {
        guard size != capturedSize, !size.isEmpty else { return }
        let first = capturedSize == nil
        still.contents = MockContent.still(role: role, size: size, projection: projection, scale: scale)
        capturedSize = size
        guard !first else { return }
        let crossFade = CATransition()
        crossFade.type = .fade
        crossFade.duration = SettingsStyle.reRender
        still.add(crossFade, forKey: "re-render")
    }

    /// Put the pane at `frame` — a mock-local rect that already carries `k`.
    ///
    /// **`animation.window` is where the still is put, and nothing else.** `stretch` scales it to fill,
    /// so rules stretch wide and the title bar's icon goes oval; `crop` holds it at the scale it was
    /// captured at, anchored top-left — a growing window shows wallpaper through the strip it has not
    /// filled, and a shrinking one is cut off at the corner by the pane's own rounded clip.
    func place(_ frame: CGRect, focused: Bool, projection: Projection,
               animation: WindowAnimation = .stretch) {
        layer.frame = frame
        body.frame = CGRect(origin: .zero, size: frame.size)
        body.borderWidth = focused ? SettingsStyle.paneFocusEdgeWidth : SettingsStyle.paneEdgeWidth
        body.borderColor = focused ? SettingsStyle.paneFocusEdge : SettingsStyle.paneEdge

        switch animation {
        case .stretch:
            body.backgroundColor = SettingsStyle.paneFill
            still.frame = CGRect(origin: .zero, size: frame.size)
        case .crop:
            // Nothing paints the ground the still does not reach, which is what makes the shortfall
            // read as desktop showing through rather than as an empty window.
            body.backgroundColor = nil
            let captured = capturedSize.map {
                CGSize(width: projection.mock($0.width), height: projection.mock($0.height))
            } ?? frame.size
            // Top-left in a layer that counts up from the bottom.
            still.frame = CGRect(x: 0, y: frame.height - captured.height,
                                 width: captured.width, height: captured.height)
        }

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
    }
}
