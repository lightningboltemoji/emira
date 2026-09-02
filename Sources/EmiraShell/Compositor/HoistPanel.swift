import AppKit
import QuartzCore
import EmiraCore

// One hoisted float's substrate: a borderless `NSWindow` standing exactly where the real window
// stands, holding a photograph of it, one level above the cover. A sibling of `Overlay` and
// `GuidePanel`, and it keeps their two proven idioms — `animationBehavior = .none` with the window
// ordered in at `alpha 0` from birth, so appearing is a pure alpha flip rather than a system show
// animation, and `isReleasedWhenClosed = false`.
//
// **A window per hoist, rather than one per display, and the mouse is the whole reason.** A hoist has
// to take the clicks that land on it and pass on every click that does not, and no window can do both:
// a fully transparent region of a non-opaque window **swallows** a click rather than passing it
// through, and an `NSView.hitTest` returning `nil` swallows it too. The only region the window server
// routes on is a window's frame, so the frames have to be the hoists.
//
// The shape pays for itself twice more. `hasShadow` is then macOS's own window shadow around the
// float's own silhouette rather than a synthesized approximation of it. And the collection behaviour is
// the whole answer to "do not follow the user into a full-screen app": with neither `.canJoinAllSpaces`
// nor `.fullScreenAuxiliary`, a panel belongs to the Space it was ordered in on and cannot appear over
// another app's full-screen one. Nothing observes Spaces; the window server declines on our behalf.
//
// It is not baked into a cover's base either, and that needs no work: `SCKCapturer` excludes every
// window owned by our process, not just the overlay.

/// One float's stand-in: a click target the size of the window, showing the window's own pixels.
@MainActor
public final class HoistPanel: HoistSurface {

    /// The window this panel stands for — what a click reports.
    public let window: WindowId

    private let geometry: ScreenGeometry
    private let panel: NSWindow
    /// Carries the photograph. The content view's own layer, so there is nothing between the pixels and
    /// the shadow macOS derives from their alpha.
    private let host: CALayer
    /// Fired on a click anywhere in the panel. A hoist is one window's whole extent, so where inside it
    /// the click landed says nothing and is not reported.
    private let onClick: @MainActor (WindowId) -> Void

    /// Whether a photograph has arrived. Until one has, the panel is up at `alpha 0` and takes no
    /// clicks: an empty window with a shadow is a hole in the desktop, and one that swallowed clicks
    /// would be worse than the burial it is fixing.
    public private(set) var isShown = false

    /// What another panel orders itself against — `NSWindow.windowNumber`, which is what
    /// `order(above:)` takes.
    public var handle: Int { panel.windowNumber }

    public init(window: WindowId, frame: Rect, scale: CGFloat, geometry: ScreenGeometry,
                onClick: @escaping @MainActor (WindowId) -> Void) {
        self.window = window
        self.geometry = geometry
        self.onClick = onClick

        let cocoa = geometry.cocoa(frame)
        panel = NSWindow(contentRect: cocoa, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // macOS's own, cast from the photograph's alpha — a window capture is transparent outside its
        // rounded corners, so the silhouette is already in the pixels.
        panel.hasShadow = true
        panel.level = HoistPanel.level
        // Deliberately neither `.canJoinAllSpaces` nor `.fullScreenAuxiliary`: see the file header.
        panel.collectionBehavior = [.stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.isReleasedWhenClosed = false
        // Nothing here types, and a borderless window declines key anyway — which is what keeps a click
        // on a hoist from activating the daemon instead of the window the user is asking for.
        panel.ignoresMouseEvents = true

        let view = ClickView(frame: CGRect(origin: .zero, size: cocoa.size))
        view.wantsLayer = true
        host = view.layer ?? CALayer()
        host.contentsScale = scale
        // The still is `frame.size × scale` pixels onto a layer of `frame.size` points: an identity at
        // rest, which is what keeps it sharp, and a stretch only where the app resized between the
        // decision and the film.
        host.contentsGravity = .resize

        view.onClick = { [weak self] in
            guard let self, self.isShown else { return }
            self.onClick(self.window)
        }
        panel.contentView = view
        // Ordered in now and left in, so showing is an alpha flip. Nothing waits on this call, which
        // matters: the window server can defer an ordering change for as long as another app animates.
        panel.orderFrontRegardless()
    }

    /// One above the cover, one below the guides: a hoist is over the reconstruction (a float that
    /// stays on top through a scroll is the point) and under a HUD that answers *where am I*.
    public static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

    /// Where the real window is, in core coordinates — what the release fence asks the window server
    /// about, and by then the only record of it.
    public private(set) var frame: Rect = .zero

    /// Put the panel where the real window is. Called whenever the core's rect changes, which for a
    /// float is whenever its app moves it.
    public func place(at frame: Rect) {
        self.frame = frame
        let cocoa = geometry.cocoa(frame)
        panel.setFrame(cocoa, display: false)
        host.frame = CGRect(origin: .zero, size: cocoa.size)
        // The shadow is cast from the content's alpha and does not recompute on a resize by itself.
        panel.invalidateShadow()
    }

    /// The photograph landed: show it. The first one is what brings the panel onto the screen and puts
    /// it in the way of the mouse; a later one replaces the pixels of a panel already up.
    public func show(_ image: CGImage) {
        host.contents = image
        panel.invalidateShadow()
        guard !isShown else { return }
        isShown = true
        panel.ignoresMouseEvents = false
        setAlpha(1)
    }

    /// Every alpha write but the fade's own. Through the animator at zero duration, not as a bare
    /// assignment: a direct one is overwritten by the next frame of a dissolve still in flight, where a
    /// zero-duration animation replaces that dissolve outright. `Overlay.raise` writes the same way.
    private func setAlpha(_ alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = alpha
        }
    }

    /// Restack: this panel sits directly above `handle`, or at the front of its level when `0`.
    /// Ordering is what keeps two overlapping hoists in the order the desktop had them.
    public func order(above handle: Int) {
        panel.order(.above, relativeTo: handle)
    }

    /// The core has dropped this hoist: stop taking clicks, keep the pixels. The panel is a picture
    /// waiting to dissolve from here, and the click that caused the release has already been spent —
    /// anything after it belongs to the real window coming forward underneath.
    public func release() {
        panel.ignoresMouseEvents = true
    }

    /// The float came back before the release finished. Cancel the dissolve and take the clicks again.
    public func reclaim() {
        generation &+= 1                            // a fade in flight owns nothing now
        setAlpha(isShown ? 1 : 0)
        panel.ignoresMouseEvents = !isShown
    }

    /// Dissolve the picture into the real window now standing under it, then order out. Not a cut: the
    /// still was filmed while the float was behind and unfocused, so it hands over to a window whose
    /// focus styling differs — the absence the cover's own cross-fade exists to carry. `completion` runs
    /// exactly once, including for a panel that was never shown.
    public func dismiss(over duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
        guard isShown else { return completion() }
        generation &+= 1
        let mine = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard self.generation == mine else { return }    // reclaimed mid-fade
                self.retire()
                completion()
            }
        })
    }

    /// How long that dissolve takes. `Reconstruction.refreshDuration`'s value and its reasoning: this is
    /// the same event in the other direction — a stand-in becoming the window's own pixels, finished
    /// before the eye has settled anywhere.
    public static let dismissDuration: TimeInterval = 0.12

    /// Take it off the screen for good — a display changed under it, or the daemon is quitting. Instant,
    /// and the one exit that does not wait for anything: there is no desktop left to hand back to.
    public func retire() {
        generation &+= 1
        isShown = false
        panel.ignoresMouseEvents = true
        setAlpha(0)
        panel.orderOut(nil)
    }

    /// Bumped by every dissolve and every reclaim, so a fade's completion can tell whether it is still
    /// the current one. The idiom `Overlay.fadeOut` already uses.
    private var generation = 0
}

/// The panel's content view: pixels and one gesture. `mouseDown` rather than `mouseUp` — this is a
/// raise, and a raise should feel like the click that caused it.
private final class ClickView: NSView {
    var onClick: (@MainActor () -> Void)?

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { onClick?() }
    }
}
