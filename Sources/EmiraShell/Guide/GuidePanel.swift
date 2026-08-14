import AppKit
import QuartzCore
import EmiraCore
import EmiraGuide

// The guides' substrate: a borderless click-through `NSWindow` over the working area, hosting one
// renderer root layer per enabled style. A sibling of `Overlay`, and most of it is copied because it is
// already right — `animationBehavior = .none` with the window ordered in permanently at `alpha 0` so a
// show is a pure alpha flip, `ignoresMouseEvents`, and `[.canJoinAllSpaces, .stationary,
// .fullScreenAuxiliary]`.
//
// **A panel is a layer rather than the window's own frame**, and that is the one structural decision
// here. A guide is as long as the strip is (up to `span`), so its width changes whenever the strip does
// — including once per frame through an animated resize. A window that resized at 120 Hz would spend a
// window-server round trip and a backing-store reallocation on every one; a layer frame is an assignment
// inside the `CATransaction` the blit already opens. So the window is the working area and never moves,
// and everything that moves is inside it.
//
// **One window for every style, and one exit each.** There is one set of levels and one click-through
// rule rather than a pair that could disagree, and a guide's own fade runs on its root layer's opacity
// — the same object the settings window fades — because two guides keep their own dwells. The window
// is up while any of them is on it or on its way off.
//
// Two further differences from `Overlay`. It sits one level *above* `.floating`, so a guide is over the
// cover rather than under it. And it is **not opaque**: a guide is a translucent HUD, so it can neither
// mark a window behind it occluded nor be asked to, and it goes up at full alpha rather than the
// thousandth short of it a cover needs.
//
// It is not baked into a cover's base either, and that needs no work: `SCKCapturer` excludes every
// window owned by our process from the base capture, not just the overlay.

/// The guides' window. Created once at launch; a show is an alpha flip.
@MainActor
public final class GuidePanel: GuideSurface {

    private let geometry: ScreenGeometry
    private let window: NSWindow
    /// The whole working area, painting nothing — just somewhere for a panel to be placed.
    private let host: CALayer

    /// What a renderer built for this display should rasterize at.
    public let backingScale: CGFloat

    /// The guides on screen, and the ones fading off it. The window is up while either holds anything.
    private var up: Set<GuideStyle> = []
    private var fading: Set<GuideStyle> = []
    public private(set) var isShown = false

    /// Bumped per style by every show and every fade, so a fade's completion can tell whether it is
    /// still the current one — a re-show landing mid-fade must not be undone by the fade it interrupted.
    private var generation: [GuideStyle: Int] = [:]

    private static let fadeKey = "fade"

    /// `insets` must be the *same* struts the core lays the strip out with (`Config.struts`), so the
    /// window is exactly the working area a guide's anchors are measured against.
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

        window.contentView = view
        // Ordered in now and left in forever, or the system's show-animation pops on the first show.
        window.orderFrontRegardless()
    }

    /// Take a renderer's root into the window. Called once per style, at build time, and the root
    /// arrives invisible: opacity is what a guide is shown and hidden by.
    public func adopt(_ renderer: any GuideRenderer) {
        renderer.layer.opacity = 0
        host.addSublayer(renderer.layer)
    }

    public func isShown(_ renderer: any GuideRenderer) -> Bool { up.contains(renderer.style) }

    /// Put a renderer's panel where the model says it goes. `panel` is in core (top-left, global) screen
    /// points, exactly as `render` answers it, and this is the whole of what the host decides.
    public func place(_ renderer: any GuideRenderer, at panel: Rect) {
        CATransaction.begin()
        // The panel's width changes once per frame through an animated resize; an implicit animation on
        // its frame would leave the ribbon a quarter-second behind the strip it is drawing.
        CATransaction.setDisableActions(true)
        renderer.layer.frame = geometry.local(panel, in: window.frame)
        CATransaction.commit()
    }

    /// Show one guide instantly, cancelling a fade it may be in the middle of.
    public func show(_ renderer: any GuideRenderer) {
        guard up.insert(renderer.style).inserted else { return }
        generation[renderer.style, default: 0] &+= 1
        fading.remove(renderer.style)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.removeAnimation(forKey: Self.fadeKey)
        renderer.layer.opacity = 1
        CATransaction.commit()

        guard !isShown else { return }
        isShown = true
        window.alphaValue = 1
        window.orderFrontRegardless()
    }

    /// Fade one guide away, or cut it at `duration` zero. The window follows the last of them off.
    public func hide(_ renderer: any GuideRenderer, over duration: TimeInterval) {
        let style = renderer.style
        guard up.remove(style) != nil else { return }
        generation[style, default: 0] &+= 1
        let mine = generation[style]
        let layer = renderer.layer

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard duration > 0 else {
            layer.removeAnimation(forKey: Self.fadeKey)
            layer.opacity = 0
            CATransaction.commit()
            return settle()
        }
        fading.insert(style)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                // A re-show landing mid-fade owns the layer now, and this fade is not what it is doing.
                guard let self, self.generation[style] == mine else { return }
                self.fading.remove(style)
                self.settle()
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.opacity
        fade.duration = duration
        layer.opacity = 0
        layer.add(fade, forKey: Self.fadeKey)
        CATransaction.commit()
    }

    /// Take this panel off the screen for good — its display has gone, or a replacement has been built
    /// for a display whose geometry changed. Instant, and it outranks a fade in flight.
    public func retire() {
        for style in up.union(fading) { generation[style, default: 0] &+= 1 }
        up.removeAll()
        fading.removeAll()
        isShown = false
        window.orderOut(nil)
    }

    /// Put the window down once nothing is on it — the last fade's own completion, so a guide leaving
    /// while another is still going is not cut short by the window going first.
    private func settle() {
        guard up.isEmpty, fading.isEmpty, isShown else { return }
        isShown = false
        window.alphaValue = 0
    }
}
