import AppKit
import QuartzCore
import EmiraCore
import EmiraGuide

// The tarp's surface: a click-through window over the strip of the lot's display where nubs can be,
// drawing a patch of the desktop over the parked windows standing there.
//
// **What it draws is the corner with nothing parked in it.** That is the desktop photograph — which holds
// no window and no shadow — with the shadow of every window that is *not* parked drawn back in, exactly as
// the cover's stand-ins draw theirs (`WindowShadow`), and each of those windows cut out so its own pixels
// stay live. The patch reaches as far past the nubs as their shadows do, and fades in over its inner
// edges, so what little of a shadow lies beyond it meets the desktop without a seam.
//
// **The window holds `alpha 0.999`, never 1**, for `Overlay.raisedAlpha`'s reason: at full alpha it marks
// the nubs beneath it occluded, and an occluded parked window is one its app may stop drawing — which is
// the flash on revealing it that parking at a sliver exists to prevent.
//
// The idioms are `ScrimWindow`'s, at its level and for its reasons.

/// One window near the tarp that it does not draw over: its shadow is drawn into the patch and its
/// silhouette is cut out of it. Core (top-left, global) coordinates.
public struct TarpNeighbour: Equatable, Sendable {
    public let frame: Rect
    public let cornerRadius: Double
    /// Whether it casts the key window's shadow rather than every other window's.
    public let isFocused: Bool

    public init(frame: Rect, cornerRadius: Double, isFocused: Bool) {
        self.frame = frame
        self.cornerRadius = cornerRadius
        self.isFocused = isFocused
    }
}

/// What a tarp draws for one reading of the window server: where, over which windows, and around which.
public struct TarpCut: Equatable, Sendable {
    /// The patch, in core coordinates and whole points: every parked window's on-screen part, padded by
    /// the reach of its shadow and clipped to the strip.
    public let region: Rect
    /// The parked windows drawn over, by number — what the cover's base leaves out to match.
    public let concealed: Set<CGWindowID>
    public let neighbours: [TarpNeighbour]
    /// How far each edge of `region` fades in: `TarpWindow.feather` where it is inside the display, 0
    /// where it is the display's own edge.
    public let feather: EdgeInsets

    public init(region: Rect, concealed: Set<CGWindowID>, neighbours: [TarpNeighbour],
                feather: EdgeInsets) {
        self.region = region
        self.concealed = concealed
        self.neighbours = neighbours
        self.feather = feather
    }

    /// The cut `tarp` asks for over this reading, or `nil` where no parked window stands in its slot.
    /// **A window is drawn over only where the server shows it in the slot it was parked in**: one still
    /// on its way, or one its app refused, is a neighbour like any other window.
    @MainActor
    static func cut(for tarp: Tarp,
                    over stacked: [(window: WindowId?, pane: StackedWindow)],
                    on display: Rect,
                    within strip: Rect,
                    cornerRadius: @MainActor (WindowId) -> Double? = { _ in nil }) -> TarpCut? {
        func parked(_ entry: (window: WindowId?, pane: StackedWindow)) -> Bool {
            guard let id = entry.window, let slot = tarp.slots[id] else { return false }
            let at = entry.pane.frame.origin
            return abs(at.x - slot.minX) <= Tolerance.identity && abs(at.y - slot.minY) <= Tolerance.identity
        }
        let nubs = stacked.filter(parked)
        let shown = nubs.compactMap { $0.pane.frame.intersection(display) }
        guard let first = shown.first else { return nil }

        // A parked window can hold the key window's shadow, which reaches further: one the core says is
        // focused, or any of them when it names none — a workspace with nothing on it leaves macOS's key
        // window wherever it was, parked.
        let keyMayBeParked = tarp.focused == nil || nubs.contains { $0.window == tarp.focused }
        let reach = keyMayBeParked ? WindowShadow.focused.reach : WindowShadow.unfocused.reach
        let padded = shown.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -reach, dy: -reach)
        guard let clipped = padded.intersection(display)?.intersection(strip) else { return nil }
        let region = Rect(x: clipped.minX.rounded(.down), y: clipped.minY.rounded(.down),
                          width: clipped.maxX.rounded(.up) - clipped.minX.rounded(.down),
                          height: clipped.maxY.rounded(.up) - clipped.minY.rounded(.down))

        let concealed = Set(nubs.map(\.pane.number))
        let neighbours = stacked.compactMap { entry -> TarpNeighbour? in
            guard !concealed.contains(entry.pane.number) else { return nil }
            let focused = entry.window != nil && entry.window == tarp.focused
            let shadow = WindowShadow.of(focused: focused)
            guard entry.pane.frame.insetBy(dx: -shadow.reach, dy: -shadow.reach).intersects(region)
            else { return nil }
            let radius = entry.window.flatMap(cornerRadius) ?? Scrims.fallbackCornerRadius
            return TarpNeighbour(frame: entry.pane.frame, cornerRadius: radius, isFocused: focused)
        }
        let edge = TarpWindow.feather
        let feather = EdgeInsets(top: region.minY > display.minY ? edge : 0,
                                 left: region.minX > display.minX ? edge : 0,
                                 bottom: region.maxY < display.maxY ? edge : 0,
                                 right: region.maxX < display.maxX ? edge : 0)
        return TarpCut(region: region, concealed: concealed, neighbours: neighbours, feather: feather)
    }
}

/// The tarp's surface — what `Scrims` drives. A protocol for `ScrimSurface`'s reason.
@MainActor
public protocol TarpSurface: AnyObject {
    /// Draw this cut, or take the tarp off the glass for `nil`.
    func setCut(_ cut: TarpCut?)
    /// The desktop photograph of the strip, untouched — no frost, no shade. With none, nothing is drawn.
    func setDesktop(_ image: CGImage?)
    func retire()
}

/// A borderless click-through window over one strip of a display, drawing the tarp's patch.
@MainActor
public final class TarpWindow: NSObject, TarpSurface {

    /// `ScrimWindow.level`: under the cover, which must hide it outright, and over every app's window.
    public nonisolated static let level = ScrimWindow.level

    /// How far inside the lot's edge the strip begins: room for a nub four lanes deep and the key
    /// window's shadow past it (`WindowShadow.maxReach`).
    static let band: Double = 96

    /// How far a neighbour's hole reaches past its frame. macOS draws a window's dark rim just outside
    /// the frame, and the hole is what leaves it live.
    static let rim: Double = 1.25

    /// How far the patch fades in from an edge inside the display — enough that a shadow's tail still
    /// reaching that far meets the desktop without a step.
    static let feather: Double = 10

    /// What a showing tarp holds, for `Overlay.raisedAlpha`'s reason. See the file header.
    static let showingAlpha: CGFloat = 0.999

    private let geometry: ScreenGeometry
    private let strip: Rect
    private let window: NSWindow
    private let root: CALayer
    /// The photograph and the neighbours' shadows, masked by their holes.
    private let body: CALayer
    private let photo: CALayer
    private let holes: CAShapeLayer
    /// The patch's extent and its feathered edges — the mask over everything.
    private let extent: CAGradientLayer
    private let fadeDown: CAGradientLayer
    private let scale: CGFloat

    private var cut: TarpCut?
    private var desktop: CGImage?
    private var casters: [CALayer] = []

    /// `strip` is the region this window covers, in core coordinates and whole points: the photograph
    /// it is handed is of exactly that.
    public init(strip: Rect, scale: CGFloat, geometry: ScreenGeometry) {
        self.geometry = geometry
        self.strip = strip
        self.scale = scale

        let frame = geometry.cocoa(strip)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = TarpWindow.level
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.animationBehavior = .none
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        // A nub is still a grab handle under the patch.
        window.ignoresMouseEvents = true

        let bounds = CGRect(origin: .zero, size: frame.size)
        let view = NSView(frame: bounds)
        view.wantsLayer = true
        root = view.layer ?? CALayer()
        root.contentsScale = scale

        body = CALayer()
        body.frame = bounds
        photo = CALayer()
        photo.frame = bounds
        photo.contentsScale = scale
        photo.contentsGravity = .resize
        body.addSublayer(photo)
        holes = CAShapeLayer()
        holes.frame = bounds
        holes.fillRule = .evenOdd
        body.mask = holes
        root.addSublayer(body)

        extent = CAGradientLayer()
        extent.startPoint = CGPoint(x: 0, y: 0.5)
        extent.endPoint = CGPoint(x: 1, y: 0.5)
        fadeDown = CAGradientLayer()
        // Bottom to top: a layer here is not flipped, so `y = 0` is the patch's lower edge.
        fadeDown.startPoint = CGPoint(x: 0.5, y: 0)
        fadeDown.endPoint = CGPoint(x: 0.5, y: 1)
        extent.mask = fadeDown
        root.mask = extent

        super.init()
        window.contentView = view
        // Ordered in now and left in forever, or the system's show-animation pops the first time it is on.
        window.orderFrontRegardless()
    }

    public func setDesktop(_ image: CGImage?) {
        desktop = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.contents = image
        CATransaction.commit()
        present()
    }

    public func setCut(_ cut: TarpCut?) {
        guard cut != self.cut else { return }
        self.cut = cut
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let cut { draw(cut) }
        CATransaction.commit()
        present()
    }

    public func retire() {
        cut = nil
        window.orderOut(nil)
    }

    /// The window's alpha is a gate, flipped at once: a patch moves with the nubs, which never fade.
    private func present() {
        window.alphaValue = cut != nil && desktop != nil ? Self.showingAlpha : 0
    }

    private func draw(_ cut: TarpCut) {
        let local = { (rect: Rect) in self.geometry.local(rect, within: self.strip) }
        let region = local(cut.region)

        extent.frame = region
        Self.fade(extent, in: cut.feather.left, out: cut.feather.right, across: region.width)
        fadeDown.frame = CGRect(origin: .zero, size: region.size)
        Self.fade(fadeDown, in: cut.feather.bottom, out: cut.feather.top, across: region.height)

        for caster in casters { caster.removeFromSuperlayer() }
        casters = []
        let mask = CGMutablePath()
        mask.addRect(holes.bounds)
        for neighbour in cut.neighbours {
            let frame = local(neighbour.frame)
            let corner = CGFloat(neighbour.cornerRadius)
            let shadow = WindowShadow.of(focused: neighbour.isFocused)
            // Only the silhouette near the patch casts into it: a window's far edges are past its reach.
            let near = region.insetBy(dx: -2 * shadow.reach, dy: -2 * shadow.reach)
            let silhouette = CGPath(roundedRect: frame, cornerWidth: corner, cornerHeight: corner,
                                    transform: nil)
            let caster = CALayer()
            caster.frame = holes.bounds
            caster.contentsScale = scale
            shadow.apply(to: caster)
            caster.shadowPath = silhouette.intersection(CGPath(rect: near, transform: nil))
            body.addSublayer(caster)
            casters.append(caster)

            let rim = CGFloat(Self.rim)
            mask.addPath(CGPath(roundedRect: frame.insetBy(dx: -rim, dy: -rim),
                                cornerWidth: corner + rim, cornerHeight: corner + rim, transform: nil))
        }
        holes.path = mask
    }

    /// Fade `layer` in over its first `start` points and out over its last `end`. An edge with no fade
    /// gets no clear stop at all, so it is solid to its last pixel — that edge is the display's, and the
    /// nubs stand against it.
    private static func fade(_ layer: CAGradientLayer, in start: Double, out end: Double,
                             across length: CGFloat) {
        let n = max(Double(length), 1)
        let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
        var stops: [(CGColor, Double)] = start > 0 ? [(clear, 0), (solid, min(start / n, 0.5))]
                                                   : [(solid, 0)]
        stops += end > 0 ? [(solid, max(1 - end / n, 0.5)), (clear, 1)] : [(solid, 1)]
        layer.colors = stops.map(\.0)
        layer.locations = stops.map { NSNumber(value: $0.1) }
    }
}
