import AppKit
import QuartzCore
import EmiraCore

// One display's scrim: a borderless, click-through window covering the whole screen, holding a
// photograph of that display's **desktop** — the wallpaper, the icons, the widgets, every window taken
// out of it — shown through a mask that is open exactly where an unfocused window stands.
//
// **One window per display rather than one per window**, which is the opposite of `HoistPanel` and for
// the opposite reason. A hoist has to *take* the clicks that land on it, and the only region the window
// server routes on is a window's frame, so the frames have to be the hoists. A scrim takes no clicks at
// all, so it is free to be one surface — and being one surface is what makes the occlusion exact: the
// mask holds one shape per see-through window, and a window in front of one takes its overlap out of
// that shape. The window itself stays at `alpha 1`; a per-window alpha would need a window per window,
// which is the shape this file exists not to have.
//
// **The mask is a layer tree, and the veil is a layer's opacity.** A shape carries where a window is and
// its opacity carries how see-through it is, so the two change independently: a window that moved is a
// path written with actions off, and a veil that moved is an opacity animation the render server runs.
// A mask rasterized into one image cannot separate them — every repaint replaces the whole image, so a
// window moving mid-fade ends the fade. Measured on the development display (3420×2214), the paths cost
// 0.24 ms against 2.1 ms for the image, and a fade survives a sibling's path, its own path, a layer
// arriving or leaving, and a cut that is not moving it; it retargets from wherever it has got to.
//
// **Below the cover, above everything else.** `Overlay.level` is `.floating`, so a scrim sits one under
// it: a transition's cover must hide the scrims completely, or the reconstruction would be tinted
// wherever a real window stood before it teleported. Above `.normal` because a foreign window's pixels
// can only be changed by drawing over them.
//
// The idioms are `Overlay`'s, and load-bearing for its reasons: `animationBehavior = .none` with the
// window ordered in at `alpha 0` from birth, so appearing is a pure alpha flip rather than a system
// show-animation; and `isReleasedWhenClosed = false`.

/// One display's scrim surface — what `Scrims` drives. A protocol for `CoverSurface`'s reason: the
/// policy above it is worth testing without a window server under it.
@MainActor
public protocol ScrimSurface: AnyObject {
    /// Draw exactly these windows see-through, each over its own shape, and take the scrim off the glass
    /// when the list is empty. `change` is how to get there (`ScrimChange`).
    func setVeils(_ veils: [ScrimVeil], change: ScrimChange)
    /// Load this display's desktop photograph, or `nil` to say there is none. A scrim with no
    /// photograph shows nothing: an empty tint is not what was asked for, and a black one is worse.
    func setDesktop(_ image: CGImage?)
    /// Take it off the screen for good — the display has gone, or the daemon is quitting.
    func retire()
}

/// One see-through window in the mask: the shape the desktop shows through, and how much of it shows. The
/// shape is its silhouette with every other window on the glass taken out — **the occluder and the decline
/// are one subtraction** — in the surface's own coordinates, which is the space its layers are in.
public struct ScrimVeil: Equatable {
    public let window: WindowId
    public let shape: CGPath
    public let veil: Double

    public init(window: WindowId, shape: CGPath, veil: Double) {
        self.window = window
        self.shape = shape
        self.veil = veil
    }
}

/// A borderless click-through window covering one display, holding the desktop photograph behind a
/// mask. Created once per display and left ordered in — a change repaints the mask, never the window.
@MainActor
public final class ScrimWindow: NSObject, ScrimSurface {

    /// One under `Overlay.level`: a cover must hide the scrims outright. See the file header.
    public nonisolated static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)

    /// How long a scrim takes to appear and to go. A focus change is the commonest event on the
    /// desktop and a hard cut on every one of them reads as flicker; long enough to be a fade, short
    /// enough to be over before the eye has finished moving. `HoistPanel.concealDuration`'s length and
    /// its reasoning.
    public static let fadeDuration: TimeInterval = 0.12

    private let geometry: ScreenGeometry
    private let displayFrame: Rect
    private let window: NSWindow
    /// Carries the photograph. The content view's own layer, so there is nothing between the desktop's
    /// pixels and the mask cutting them.
    private let host: CALayer
    /// The mask's root. Holds nothing of its own: what it masks with is its sublayers' alpha.
    private let cut: CALayer
    /// One shape per see-through window, keyed by it. `opacity` is that window's veil.
    private(set) var veils: [WindowId: CAShapeLayer] = [:]
    private let scale: CGFloat

    private var desktop: CGImage?
    /// Whether the window is on the glass — a gate, flipped at once and never faded (`present`).
    private var isShowing = false

    /// `display` is the whole screen in core (top-left) coordinates, and `scale` its backing scale, so
    /// the shapes rasterize at native resolution. Taken as numbers rather than as an `NSScreen` for the
    /// reason `HoistPanel` takes a frame and a scale: the policy above this has no business holding a
    /// window-server object, and a test has no way to make one.
    public init(display: Rect, scale: CGFloat, geometry: ScreenGeometry) {
        self.geometry = geometry
        self.displayFrame = display
        self.scale = scale

        let frame = geometry.cocoa(displayFrame)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = ScrimWindow.level
        // `.stationary` so it does not slide under a Spaces switch, and deliberately neither
        // `.canJoinAllSpaces` nor `.fullScreenAuxiliary`: `HoistPanel`'s answer to "do not follow the
        // user into a full-screen app", and the window server declines on our behalf.
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.animationBehavior = .none
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        // Nothing here is ever clicked. A scrim that swallowed one would make the window under it
        // unreachable, which is a far worse bargain than no transparency at all.
        window.ignoresMouseEvents = true

        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        host = view.layer ?? CALayer()
        host.contentsScale = scale
        // The window *is* the display, so the photograph fills it. Any other rect slides the wallpaper.
        host.contentsGravity = .resize

        cut = CALayer()
        cut.frame = CGRect(origin: .zero, size: frame.size)
        cut.contentsScale = scale
        host.mask = cut

        super.init()
        window.contentView = view
        // Ordered in now and left in forever, or the system's show-animation pops the first time it is on.
        window.orderFrontRegardless()
    }

    public func setDesktop(_ image: CGImage?) {
        desktop = image
        host.contents = image
        // The shapes stand; what a photograph arriving or leaving decides is only the gate.
        isShowing = image != nil && veils.values.contains { $0.opacity > 0 }
        window.alphaValue = isShowing ? 1 : 0
    }

    /// Bring the mask to `veils`. **Shapes are written as cuts and veils are animated**, so a window that
    /// moved never disturbs a veil that is moving.
    public func setVeils(_ veils: [ScrimVeil], change: ScrimChange) {
        let named = Set(veils.map(\.window))
        let wanted = desktop != nil && veils.contains { $0.veil > 0 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for veil in veils {
            let layer = self.veils[veil.window] ?? adopt(veil.window)
            // Compared, not assigned: an equal path is a new object, and writing it would have the render
            // server redraw a shape nobody can see change. Most re-sends are exactly that.
            if layer.path != veil.shape { layer.path = veil.shape }
            set(layer, to: Float(min(max(veil.veil, 0), 1)), change: change)
        }
        for (window, layer) in self.veils where !named.contains(window) {
            // Kept until the fade lands, so a window coming back inside it finds the shape it left
            // on — and one already on its way out is the landing's to drop, not this cut's.
            set(layer, to: 0, change: change)
            if change == .cut, layer.animation(forKey: "veil") == nil { drop(window) }
        }
        // **The window's alpha is a gate**: every change anybody sees is a shape's own opacity, which the
        // render server draws, where AppKit would step a window's alpha on the main thread at 60 Hz.
        isShowing = wanted
        if wanted { window.alphaValue = 1 }
        if !wanted, change == .cut { window.alphaValue = 0 }
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { self.settled(keeping: named) } }
        CATransaction.commit()
    }

    /// What holds once the veils a set asked for have arrived: a shape nobody named any longer, and that
    /// has finished going, is dropped — and a scrim with nothing left to draw comes off the glass. Read
    /// off the live state rather than the set that scheduled it, so a set landing inside a fade decides.
    private func settled(keeping named: Set<WindowId>) {
        for (window, layer) in veils
        where !named.contains(window) && layer.opacity == 0 && layer.animation(forKey: "veil") == nil {
            drop(window)
        }
        if !isShowing { window.alphaValue = 0 }
    }

    private func drop(_ window: WindowId) {
        veils[window]?.removeFromSuperlayer()
        veils[window] = nil
    }

    public func retire() {
        isShowing = false
        window.orderOut(nil)
    }

    /// A window's shape, minted see-through at nothing: a cut takes it to its veil in the same turn, and
    /// a dissolve fades it up from there.
    private func adopt(_ window: WindowId) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.frame = cut.bounds
        layer.contentsScale = scale
        layer.fillColor = CGColor(gray: 1, alpha: 1)
        layer.opacity = 0
        cut.addSublayer(layer)
        veils[window] = layer
        return layer
    }

    /// Take one shape to its veil: at once for a cut, over `fadeDuration` for a dissolve, and from
    /// wherever the shape has got to, so a retarget starts on the glass. **A cut to the veil a fade is
    /// already bound for leaves it alone** — most cuts move the shapes under a mask that did not change.
    private func set(_ layer: CAShapeLayer, to opacity: Float, change: ScrimChange) {
        switch change {
        case .cut:
            guard layer.opacity != opacity else { return }
            layer.removeAnimation(forKey: "veil")
            layer.opacity = opacity
        case .dissolve:
            let from = layer.presentation()?.opacity ?? layer.opacity
            layer.opacity = opacity
            guard abs(from - opacity) > 0.001 else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.duration = Self.fadeDuration
            layer.add(fade, forKey: "veil")
        }
    }

}
