import AppKit
import QuartzCore
import EmiraCore

// The guide's substrate: a borderless click-through `NSWindow` over the working area, hosting a
// **ribbon layer** that is the guide itself, with one pooled `CALayer` per window inside it. A sibling
// of `Overlay`, and most of it is copied because it is already right — `animationBehavior = .none` with
// the window ordered in permanently at `alpha 0` so a show is a pure alpha flip, `ignoresMouseEvents`,
// `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`, and `NSAnimationContext` for the fades.
//
// **The ribbon is a layer rather than the window's own frame**, and that is the one structural
// decision here. The guide is as long as the strip is (up to `span`), so its width changes whenever the
// strip does — including once per frame through an animated resize. A window that resized at 120 Hz
// would spend a window-server round trip and a backing-store reallocation on every one; a layer frame
// is an assignment inside the `CATransaction` the blit already opens. So the window is the working area
// and never moves, and everything that moves is inside it.
//
// Two further differences from `Overlay`. It sits one level *above* `.floating`, so the guide is over
// the cover rather than under it. And it is **not opaque**: the guide is a translucent HUD, so it can
// neither mark a window behind it occluded nor be asked to, and it goes up at full alpha rather than
// the thousandth short of it a cover needs.
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
//
// It is not baked into a cover's base either, and that needs no work: `SCKCapturer` excludes every
// window owned by our process from the base capture, not just the overlay.

/// What one tile draws. The panel stays ignorant of `GuideStyle`: the controller resolves a tile to
/// pixels, and the two cases differ only in how they are fitted.
public enum GuideContent: Equatable {
    /// The window's own still — the tile's own shape, so it fills it.
    case preview(CGImage)
    /// The app's icon — square, so it is inscribed in the tile rather than stretched across it.
    case placeholder(CGImage)
    /// Nothing to draw: the tile is its own silhouette.
    case blank
}

/// The guide's window and layer tree. Created once at launch; a show is an alpha flip.
@MainActor
public final class GuidePanel {

    private let geometry: ScreenGeometry
    private let window: NSWindow
    /// The whole working area, painting nothing — just somewhere for the ribbon to be placed.
    private let host: CALayer
    /// The guide itself: clipped and rounded, so a tile running off the strip's end is cut at the
    /// ribbon's boundary. Its frame is the only thing that moves when the strip grows or shrinks.
    private let ribbon: CALayer
    /// The live viewport, drawn under the tiles as an outline. The travelling part: it slides within
    /// the ribbon as the strip scrolls, and pins to an end when the strip does.
    private let viewport: RoundedLayer
    /// The focus ring, drawn over everything, at the focused window's frame plus its in-flight travel.
    private let ring: RoundedLayer
    /// Pooled by `WindowId`, built and torn down only as the id *set* changes; a frame is then an
    /// offer of content and a `place` per tile inside one `CATransaction`.
    private var tiles: [WindowId: RoundedLayer] = [:]
    /// The lines the strip divides along, under the tiles. Pooled by *count*: a boundary has no identity
    /// to key on, and the count changes only when the strip's shape does.
    private var separators: [CALayer] = []

    private let backingScale: CGFloat

    public private(set) var isShown = false

    /// Bumped by every show and every fade, so a fade's completion can tell whether it is still the
    /// current one — a re-show landing mid-fade must not be undone by the fade it interrupted.
    private var generation = 0

    /// `insets` must be the *same* struts the core lays the strip out with (`Config.struts`), so the
    /// window is exactly the working area the guide's anchors are measured against.
    public init(screen: NSScreen, geometry: ScreenGeometry, insets: EdgeInsets = .zero) {
        self.geometry = geometry
        self.backingScale = screen.backingScaleFactor

        let frame = geometry.cocoa(geometry.core(screen.frame).inset(by: insets))
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered,
                          defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.animationBehavior = .none
        window.alphaValue = 0
        window.isReleasedWhenClosed = false

        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        host = view.layer ?? CALayer()
        host.contentsScale = backingScale

        ribbon = CALayer()
        ribbon.contentsScale = backingScale
        ribbon.masksToBounds = true
        ribbon.cornerRadius = Self.panelRadius
        ribbon.backgroundColor = Self.panelFill
        ribbon.borderWidth = Self.panelEdgeWidth
        ribbon.borderColor = Self.panelEdge
        host.addSublayer(ribbon)

        viewport = RoundedLayer(scale: backingScale, fill: nil,
                                edge: (Self.viewportEdge, Self.viewportEdgeWidth))
        ribbon.addSublayer(viewport.layer)

        ring = RoundedLayer(scale: backingScale, fill: nil, edge: (Self.ringEdge, Self.ringWidth))
        ribbon.addSublayer(ring.layer)

        window.contentView = view
        // Ordered in now and left in forever, or the system's show-animation pops on the first show.
        window.orderFrontRegardless()
    }

    // A frame

    /// Draw one frame of the guide. `content` is asked for **every tile, every frame**: a window's
    /// pixels reach `SurfaceCache` only when the cover they were filmed for comes down, which is
    /// strictly later than the frame its tile was built in, so a tile asked once would be asked at the
    /// one moment there is nothing to answer with. An answer costs a dictionary lookup, and only a tile
    /// whose answer changed touches a layer.
    public func render(_ layout: GuideLayout, content: (GuideTile) -> GuideContent) {
        CATransaction.begin()
        // The guide's geometry comes from the core's own animators, frame by frame; without this each
        // assignment would start an implicit 0.25 s animation of its own — `contents` included, which is
        // why the pool is reconciled inside the transaction rather than ahead of it.
        CATransaction.setDisableActions(true)
        reconcile(layout.tiles, content: content)
        // The ribbon first: everything below is placed in *its* coordinates, and a growing strip must
        // not show its new tiles a frame before the ribbon that clips them.
        ribbon.frame = geometry.local(layout.panel, in: window.frame)

        // The ribbon's curve, held to a quarter of its short side — the ceiling the separation keeps,
        // for the same reason: a small guide should read as a rounded rectangle and not as a lozenge.
        let radius = min(Self.panelRadius,
                         CGFloat(min(layout.panel.width, layout.panel.height)) / 4)
        if ribbon.cornerRadius != radius { ribbon.cornerRadius = radius }
        // Everything inside rounds to the *inner* edge of that curve, a border's width in and a
        // border's width tighter, since that is the line a tile is actually held off.
        let inner = Rect(origin: .zero, size: layout.panel.size)
            .insetBy(dx: Double(Self.panelEdgeWidth), dy: Double(Self.panelEdgeWidth))
        func corners(_ rect: Rect) -> Corners {
            GuideModel.corners(of: rect, in: inner, radius: Double(Self.tileRadius),
                               outer: Double(radius - Self.panelEdgeWidth))
        }

        for tile in layout.tiles {
            tiles[tile.window]?.place(local(tile.rect, in: layout.panel.size),
                                      corners: corners(tile.rect))
        }
        fitSeparators(to: layout.separators.count)
        for (line, rect) in zip(separators, layout.separators) {
            // A boundary is a line and arrives with no thickness, so it is fattened about itself — on
            // both axes, the half point it gains at each end being what closes the joint where two of
            // them meet.
            line.frame = local(rect, in: layout.panel.size)
                .insetBy(dx: -Self.separatorWidth / 2, dy: -Self.separatorWidth / 2)
        }
        viewport.place(local(layout.viewport, in: layout.panel.size), corners: corners(layout.viewport))
        ring.layer.isHidden = layout.ring == nil
        if let rect = layout.ring {
            ring.place(local(rect, in: layout.panel.size), corners: corners(rect))
        }
        CATransaction.commit()
    }

    /// A panel-local (top-left) rect in the ribbon's own (bottom-left) coordinates. The reflection is
    /// about the ribbon's mid-line: both rects are measured from the same origin, so `flipHeight`
    /// cancels and never appears. Taken from `layout.panel.size` rather than the layer's bounds, so a
    /// tile never depends on when Core Animation applied the ribbon's new frame.
    private func local(_ rect: Rect, in size: Size) -> CGRect {
        geometry.local(rect, within: Rect(origin: .zero, size: size))
    }

    /// Match the tile pool to `wanted`, then offer each tile its content.
    ///
    /// A tile survives everything but its own window leaving the strip, a newcomer arriving beside it
    /// included. What it is kept for is its `drawn` cache: that is what lets a frame which only moves a
    /// tile rebuild no path.
    private func reconcile(_ wanted: [GuideTile], content: (GuideTile) -> GuideContent) {
        let live = Set(wanted.map(\.window))
        for id in Set(tiles.keys).subtracting(live) {
            tiles.removeValue(forKey: id)?.layer.removeFromSuperlayer()
        }
        for tile in wanted {
            let shape = tiles[tile.window] ?? build(tile.window)
            shape.carry(content(tile))
        }
    }

    /// A tile's layer, in the tree and in the pool. It paints something whatever its content turns out
    /// to be: at this scale a hole reads as a missing window, and a window with no pixels is still on
    /// the strip. No edge — what says where one window ends and the next begins is the separator
    /// between them, drawn once for the two of them rather than twice, and running the whole length of
    /// what it divides.
    private func build(_ id: WindowId) -> RoundedLayer {
        let shape = RoundedLayer(scale: backingScale, fill: Self.tileFill, edge: nil)
        tiles[id] = shape
        // Below the ring and so above the separators, wherever the pool's older layers happen to sit:
        // tiles partition the strip and never overlap, so their order among themselves says nothing.
        ribbon.insertSublayer(shape.layer, below: ring.layer)
        return shape
    }

    /// Grow or shrink the separator pool to `count`. New lines go in directly above the viewport, so
    /// they stay under the tiles however the pool above them comes and goes.
    private func fitSeparators(to count: Int) {
        while separators.count > count { separators.removeLast().removeFromSuperlayer() }
        while separators.count < count {
            let line = CALayer()
            line.contentsScale = backingScale
            line.backgroundColor = Self.separatorEdge
            separators.append(line)
            ribbon.insertSublayer(line, above: viewport.layer)
        }
    }

    /// Show the guide instantly. Written through the animator at zero duration rather than as a bare
    /// assignment, for `Overlay.raise`'s reason: a direct one would be overwritten by the next frame of
    /// a fade still in flight.
    public func show() {
        generation &+= 1
        isShown = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = 1
        }
        window.orderFrontRegardless()
    }

    /// Take this panel off the screen for good — its display has gone, or a replacement has been built
    /// for a display whose geometry changed. Instant, and it outranks a fade in flight.
    public func retire() {
        generation &+= 1
        isShown = false
        window.orderOut(nil)
    }

    /// Fade the guide away. `completion` runs exactly once per call, and `completed == false` means a
    /// newer show owns the panel now — the caller must not treat it as hidden.
    public func hide(over duration: TimeInterval,
                     completion: @escaping @MainActor (_ completed: Bool) -> Void = { _ in }) {
        guard isShown else { return completion(true) }
        generation &+= 1
        let mine = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard self.generation == mine else { return completion(false) }
                self.isShown = false
                completion(true)
            }
        })
    }

    //
    // Resolved against the app's effective appearance when a layer is built, the way `Reconstruction`
    // resolves its scrim — so the guide follows light/dark from the next rebuild rather than the next
    // launch, and nothing here has to watch for an appearance change.

    /// The ribbon's curve at full size, and the radius everything inside it rounds *to* as it reaches a
    /// corner. Generous on purpose: it is what makes the guide read as one object rather than as a
    /// rectangle with rectangles in it, and `GuideModel.corners` is what keeps a tile from being clipped
    /// square by it.
    private static let panelRadius: CGFloat = 20
    /// A tile's own curve, away from the ribbon's corners.
    private static let tileRadius: CGFloat = 4

    private static let panelEdgeWidth: CGFloat = 1
    /// A hairline: one device pixel at 2×, and lighter than the ribbon's own edge on purpose, since a
    /// grid of interior rules as heavy as the frame around them reads as a cage.
    private static let separatorWidth: CGFloat = 0.5
    private static let viewportEdgeWidth: CGFloat = 1
    private static let ringWidth: CGFloat = 1.5

    private static var panelFill: CGColor {
        NSColor.windowBackgroundColor.withAlphaComponent(0.72).cgColor
    }
    private static var panelEdge: CGColor {
        NSColor.separatorColor.withAlphaComponent(0.6).cgColor
    }
    private static var tileFill: CGColor {
        NSColor.controlBackgroundColor.withAlphaComponent(0.9).cgColor
    }
    private static var separatorEdge: CGColor {
        NSColor.separatorColor.withAlphaComponent(0.8).cgColor
    }
    private static var viewportEdge: CGColor {
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor
    }
    private static var ringEdge: CGColor {
        NSColor.controlAccentColor.cgColor
    }
}
