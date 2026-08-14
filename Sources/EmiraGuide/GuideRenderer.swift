import AppKit
import QuartzCore
import EmiraCore

// The guide's drawing, in a target of its own: AppKit over `EmiraCore`, and nothing else. It owns a
// layer tree and no window, which is what lets the daemon host it over the desktop and the settings
// window host it inside a mock display **as the same object**.
//
// **`scale` is the whole of that.** Every cosmetic length — a radius, a border, a separator's width, a
// font size — multiplies by it, so the preview is the same guide seen smaller rather than a second
// drawing that resembles it. The daemon passes `1`; the settings window passes its mock's own scale.
// An absolute point count anywhere in here is a frame four times too heavy for the ribbon it frames.
//
// `palette` stays a parameter, because the higher contrast a guide needs over a mock wallpaper is a
// real requirement rather than drift — but it is one struct of colours, not a second layer tree.
//
// `ImportFenceTests` scans this module too: the renderer must not name the reducer, and the module
// graph cannot say so on its own.

/// A guide's drawing surface. One instance per style per host — the renderer owns the inside of the
/// panel, and the host owns where the panel goes.
@MainActor public protocol GuideRenderer: AnyObject {
    /// Which guide this draws. What pairs it with a drawing, a spring and a camera, and what a host
    /// counts its renderers in rather than by position in an array.
    var style: GuideStyle { get }

    /// The renderer's root, which **is** the panel: its bounds are the panel's size and everything
    /// inside is placed in its own coordinates. The host adds it to a tree and frames it.
    var layer: CALayer { get }

    /// Draw one frame of `drawing`, which is **the model already run** — by the host, since the settings
    /// window needs the panel before it draws — so nothing in here derives a geometry twice. `settings`
    /// is the whole `[guide]` table, of which a renderer reads only what is not geometry.
    ///
    /// Runs inside its own `CATransaction` with actions disabled: the geometry comes from the core's
    /// own animators frame by frame, and without that every assignment would start an implicit
    /// quarter-second animation of its own.
    func draw(_ drawing: GuideDrawing, settings: GuideSettings, scale: Double, palette: GuidePalette,
              sources: GuideSources)
}

extension GuideStyle {
    /// The renderer that draws this guide — **the one place a style becomes a class**.
    @MainActor public func renderer(contentsScale: CGFloat) -> any GuideRenderer {
        switch self {
        case .preview: return PreviewGuideRenderer(contentsScale: contentsScale)
        case .names:   return NamesGuideRenderer(contentsScale: contentsScale)
        }
    }

    /// One renderer per style, in `allCases`' own order: the minimap first and the names over it. Both
    /// hosts build their set from this, so the drawing order is stated once.
    @MainActor public static func renderers(contentsScale: CGFloat) -> [any GuideRenderer] {
        allCases.map { $0.renderer(contentsScale: contentsScale) }
    }
}

/// How a guide comes and goes, in seconds. **Instant up and gentle down**: it answers *where am I* about
/// the thing that just moved, so any rise is late — and nothing is hidden behind it, so the fade is the
/// whole of the exit rather than a seam over a change. Here rather than in either host, because both run
/// it on the renderer root's own opacity — two guides keep their own dwells and leave on their own.
public enum GuideFade {
    public static let up: TimeInterval = 0
    public static let down: TimeInterval = 0.35
}

/// Where a guide's pictures and words come from. **The seam that keeps `NSWorkspace` out of this
/// module** — and what lets the settings window's mock desktop inject its own everything, so the
/// preview draws mock stills and mock icons through the real renderer.
@MainActor public struct GuideSources {
    /// A window's last still, or `nil` for one nothing has filmed. `SurfaceCache` in the daemon; the
    /// mock pane's own picture in the settings window.
    public var still: (WindowId) -> CGImage?
    /// An app's icon, or `nil` where there is none to find.
    public var icon: (String) -> CGImage?
    /// The word that stands for an app — what the names guide sets. `NSWorkspace` in the daemon, a
    /// scripted table in the settings window, and the bundle id itself where nothing answers.
    public var name: (String) -> String

    public init(still: @escaping (WindowId) -> CGImage? = { _ in nil },
                icon: @escaping (String) -> CGImage? = { _ in nil },
                name: @escaping (String) -> String = { $0 }) {
        self.still = still
        self.icon = icon
        self.name = name
    }
}

/// A guide's colours. Resolved by the host, because the answer differs: over the real desktop a guide
/// is a system-tinted HUD, and over a mock wallpaper at a quarter of the size it has to carry further.
public struct GuidePalette: Equatable {
    public var panelFill: CGColor
    public var panelEdge: CGColor
    public var tileFill: CGColor
    public var separator: CGColor
    public var viewportEdge: CGColor
    public var ring: CGColor
    /// The names guide's three: a word, a word on the focus chip, and the chip itself.
    public var label: CGColor
    public var labelFocused: CGColor
    public var focusFill: CGColor

    public init(panelFill: CGColor, panelEdge: CGColor, tileFill: CGColor, separator: CGColor,
                viewportEdge: CGColor, ring: CGColor,
                label: CGColor, labelFocused: CGColor, focusFill: CGColor) {
        self.panelFill = panelFill
        self.panelEdge = panelEdge
        self.tileFill = tileFill
        self.separator = separator
        self.viewportEdge = viewportEdge
        self.ring = ring
        self.label = label
        self.labelFocused = labelFocused
        self.focusFill = focusFill
    }

    /// The guide over the real desktop: system colours, resolved against the app's effective appearance
    /// at the moment they are asked for — so light/dark follows the next frame rather than the next
    /// launch, and nothing here has to watch for an appearance change.
    @MainActor public static var system: GuidePalette {
        GuidePalette(panelFill: NSColor.windowBackgroundColor.withAlphaComponent(0.72).cgColor,
                     panelEdge: NSColor.separatorColor.withAlphaComponent(0.6).cgColor,
                     tileFill: NSColor.controlBackgroundColor.withAlphaComponent(0.9).cgColor,
                     separator: NSColor.separatorColor.withAlphaComponent(0.8).cgColor,
                     viewportEdge: NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor,
                     ring: NSColor.controlAccentColor.cgColor,
                     label: NSColor.secondaryLabelColor.cgColor,
                     labelFocused: NSColor.white.cgColor,
                     focusFill: NSColor.controlAccentColor.cgColor)
    }
}

extension Corners {
    /// The same corners on a rect drawn `k` times the size. Every radius is a length, so the curve
    /// survives the scale rather than being four times too round in a quarter-size ribbon.
    func scaled(by k: Double) -> Corners {
        Corners(topLeft: topLeft * k, topRight: topRight * k,
                bottomRight: bottomRight * k, bottomLeft: bottomLeft * k)
    }
}
