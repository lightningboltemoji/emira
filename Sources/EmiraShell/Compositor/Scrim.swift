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
// mask is painted back-to-front over the window server's own ordering, so a window in front of a
// see-through one punches its own hole by simply being painted after it. Nothing has to reason about
// which rectangles overlap which.
//
// **The mask is grey, not black-and-white.** Its value at a pixel *is* the veil there, so each window
// carries its own transparency in one image and the window itself stays at `alpha 1`. A per-window
// alpha would otherwise need a window per window, which is the shape this file exists not to have.
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
    /// Show these windows as see-through, in the mask's own painting order (back to front), and hide
    /// the scrim entirely when the list is empty. `occluders` are the rectangles that must stay opaque
    /// — every other window on the display, painted after the ones that come before them in z-order.
    /// `fading` is whether this arrangement is an **event** rather than a correction — see `Scrims`.
    func setRegions(_ regions: [ScrimRegion], fading: Bool)
    /// Load this display's desktop photograph, or `nil` to say there is none. A scrim with no
    /// photograph shows nothing: an empty tint is not what was asked for, and a black one is worse.
    func setDesktop(_ image: CGImage?)
    /// Take it off the screen for good — the display has gone, or the daemon is quitting.
    func retire()
}

/// One window's silhouette in the mask, in core (top-left, global) coordinates. `veil` is how much of
/// the desktop shows there — `0` for a window that must stay opaque, which is how an occluder is spelled.
public struct ScrimRegion: Equatable, Sendable {
    public let frame: Rect
    public let veil: Double
    /// The window's own corner rounding, in points. Outside a rounded corner the frame holds what is
    /// beneath the window, so a square see-through one lightens its own shadow by the veil and a square
    /// opaque one leaves the window under its corners unveiled.
    public let cornerRadius: Double
    /// Another window's silhouette this one is painted only inside, or `nil` for all of it — how a
    /// window behind a see-through one is declined where the two overlap and nowhere else.
    public let within: Silhouette?

    public init(frame: Rect, veil: Double, cornerRadius: Double, within: Silhouette? = nil) {
        self.frame = frame
        self.veil = veil
        self.cornerRadius = cornerRadius
        self.within = within
    }

    /// A window's outline: its frame, rounded at the corners.
    public struct Silhouette: Equatable, Sendable {
        public let frame: Rect
        public let cornerRadius: Double

        public init(frame: Rect, cornerRadius: Double) {
            self.frame = frame
            self.cornerRadius = cornerRadius
        }
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
    /// The mask's own layer. Held rather than rebuilt so a repaint is one `contents` write.
    private let cut: CALayer
    private let scale: CGFloat

    private var desktop: CGImage?
    private var regions: [ScrimRegion] = []
    private var isShowing = false
    /// Bumped by every fade, so one still in flight when the next arrives owns nothing. `Overlay`'s
    /// idiom.
    private var generation = 0

    /// `display` is the whole screen in core (top-left) coordinates, and `scale` its backing scale, so
    /// the mask rasterizes at native resolution. Taken as numbers rather than as an `NSScreen` for the
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
        cut.contentsGravity = .resize
        host.mask = cut

        super.init()
        window.contentView = view
        // Ordered in now and left in forever, or the system's show-animation pops on the first fade in.
        window.orderFrontRegardless()
    }

    public func setDesktop(_ image: CGImage?) {
        desktop = image
        host.contents = image
        settle()
    }

    public func setRegions(_ regions: [ScrimRegion], fading: Bool) {
        guard regions != self.regions else { return }
        self.regions = regions
        // Painted before the fade, so a scrim coming up is never shown holding the last arrangement.
        repaint(fading: fading)
        settle()
    }

    /// **Actions off, and the dissolve asked for by name.** `cut` is ours rather than a view's, so
    /// nothing returns `NSNull` for `contents` and Core Animation's own quarter-second would apply to
    /// every repaint alike — a correction included. Which repaints are events is `Scrims`' answer.
    private func repaint(fading: Bool) {
        let next = Self.mask(regions, display: displayFrame, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Nothing to dissolve from on the first mask a scrim ever holds; `settle` fades that in whole.
        if fading, let previous = cut.contents {
            let dissolve = CABasicAnimation(keyPath: "contents")
            dissolve.fromValue = previous
            dissolve.duration = Self.fadeDuration
            cut.contents = next
            cut.add(dissolve, forKey: "veil")
        } else {
            cut.removeAnimation(forKey: "veil")
            cut.contents = next
        }
        CATransaction.commit()
    }

    public func retire() {
        generation &+= 1
        isShowing = false
        window.orderOut(nil)
    }

    /// Show or hide, on the one question that decides it: is there a photograph, and is anything
    /// see-through on this display? Either answer missing is a scrim with nothing honest to draw.
    private func settle() {
        let wanted = desktop != nil && regions.contains { $0.veil > 0 }
        guard wanted != isShowing else { return }
        isShowing = wanted
        // A scrim that went away dropped its mask; coming back needs it before the fade, not after.
        if wanted, cut.contents == nil { repaint(fading: false) }
        generation &+= 1
        let mine = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            window.animator().alphaValue = wanted ? 1 : 0
        } completionHandler: {
            MainActor.assumeIsolated {
                // Nothing to release — the photograph outlives the fade — but a scrim that has gone
                // has no reason to keep a mask the size of the display resident.
                guard self.generation == mine, !self.isShowing else { return }
                self.cut.contents = nil
            }
        }
    }

    /// The mask, the size of the display in pixels, painted **back to front** — so a window in front of
    /// a see-through one punches its own hole by being painted after it.
    ///
    /// The veil is in the **alpha** channel, the only one `CALayer.mask` reads, and painted in `.copy`,
    /// so an occluder replaces what is under it rather than blending toward it. Clear everywhere no
    /// window is: a scrim over bare desktop is the wallpaper drawn over itself.
    static func mask(_ regions: [ScrimRegion], display: Rect, scale: CGFloat) -> CGImage? {
        let width = Int((display.width * Double(scale)).rounded())
        let height = Int((display.height * Double(scale)).rounded())
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return nil }
        ctx.setBlendMode(.copy)
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // Every window stops at its silhouette, see-through or not: outside an occluder's corner is
        // whatever lies beneath it, which keeps the veil it was painted with.
        func outline(_ frame: Rect, _ cornerRadius: Double) -> CGPath {
            // Core is top-left and a bitmap context is bottom-left, so the rect is reflected about the
            // display's own mid-line — the same flip `ScreenGeometry.local(_:within:)` makes.
            let box = CGRect(x: (frame.minX - display.minX) * Double(scale),
                             y: (display.maxY - frame.maxY) * Double(scale),
                             width: frame.width * Double(scale),
                             height: frame.height * Double(scale))
            let radius = cornerRadius * Double(scale)
            guard radius > 0 else { return CGPath(rect: box, transform: nil) }
            return CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        for region in regions {
            ctx.saveGState()
            if let within = region.within {
                ctx.addPath(outline(within.frame, within.cornerRadius))
                ctx.clip()
            }
            ctx.setFillColor(gray: 1, alpha: CGFloat(min(max(region.veil, 0), 1)))
            ctx.addPath(outline(region.frame, region.cornerRadius))
            ctx.fillPath()
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}
