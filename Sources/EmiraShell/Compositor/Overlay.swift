import AppKit
import QuartzCore
import EmiraCore

// The cover's substrate: one borderless, click-through `NSWindow` per display, hosting the layers
// `Reconstruction` builds. Three things are load-bearing. `animationBehavior = .none` with the window
// permanently ordered-in at `alpha 0` — a window ordered front for the first time gets a system
// show-animation, so a raise must be a pure alpha flip. Opacity — any transparency the eye can reach
// is a hole in the guarantee that nothing behind shows while the real windows teleport, so a raise
// stops one thousandth short of it and no further (`raisedAlpha`). And the cover is the *working
// area*, not the display: the real menu bar (`.mainMenu`, level 24) composites above our `.floating`
// window and would double with the base capture's own copy of it. The base is still the whole
// display, at a negative local origin, clipped.
//
// A raise is not done when it returns: it is on the glass a refresh later, and `raise(onScreen:)` is
// what says so.

/// A borderless click-through overlay window covering one display, with a layer host for the
/// reconstruction. Created once at launch — a transition raises and fades it, never builds it.
@MainActor
public final class Overlay: NSObject {

    /// The whole display in core (top-left) coordinates — where the desktop *base* capture is placed.
    public let displayFrame: Rect

    /// The region this overlay actually covers — the display inset by its struts. Everything outside
    /// it (menu bar, notch, Dock) deliberately shows the real desktop.
    public let coverFrame: Rect

    /// Stamped onto every layer so the reconstruction rasterizes at native resolution.
    public let backingScale: CGFloat

    private let screen: NSScreen
    private let geometry: ScreenGeometry
    private let window: NSWindow
    /// Clipped, so a window layer sliding off the strip's edge is cut at the screen boundary.
    private let host: CALayer
    /// The bottom-most layer: the display captured *excluding* the windows this transition animates,
    /// so it carries every window that is not moving, with holes where the moving ones were.
    private let base: CALayer

    public private(set) var isRaised = false

    /// Bumped by every raise and every fade, so a fade's completion can tell whether it is still the
    /// current one — otherwise a transition opening mid-fade loses its fresh layers to the old one.
    private var generation = 0

    /// `insets` must be the *same* struts the core lays the strip out with (`Config.struts`): leaving
    /// the chrome bands unpainted is safe only while no managed window can be outside the working area.
    public init(screen: NSScreen, geometry: ScreenGeometry, insets: EdgeInsets = .zero) {
        self.screen = screen
        self.geometry = geometry
        self.displayFrame = geometry.core(screen.frame)
        self.coverFrame = displayFrame.inset(by: insets)
        self.backingScale = screen.backingScaleFactor

        let frame = geometry.cocoa(coverFrame)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.animationBehavior = .none
        window.alphaValue = 0
        window.isReleasedWhenClosed = false

        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        host = view.layer ?? CALayer()
        host.masksToBounds = true
        host.contentsScale = screen.backingScaleFactor

        base = CALayer()
        // The whole display in the cover's local space: origin *negative* by the strut on each inset
        // edge, clipped by the host. Anywhere else slides the wallpaper by the menu bar's height.
        base.frame = geometry.local(displayFrame, in: window.frame)
        base.contentsGravity = .resize
        base.contentsScale = screen.backingScaleFactor
        // A fallback, not a look: reaching it means the desktop capture failed.
        base.backgroundColor = NSColor.black.cgColor
        host.addSublayer(base)

        super.init()

        window.contentView = view
        // Ordered in now and left in forever, or the system's show-animation pops on the first raise.
        window.orderFrontRegardless()
    }

    /// Add a reconstruction layer above the base. Call order is z-order, bottom→top.
    public func addLayer(_ layer: CALayer) {
        host.addSublayer(layer)
    }

    /// Put this transition's captured desktop behind the window layers, or `nil` for the black fill.
    /// Set at every raise, not once — an out-of-scope window may have moved or closed meanwhile.
    public func setBase(_ image: CGImage?) {
        base.contents = image
    }

    /// A core (top-left, global) rect in the overlay's local layer coordinates.
    public func localRect(_ rect: Rect) -> CGRect {
        geometry.local(rect, in: window.frame)
    }

    /// A core rect in the local coordinates of a *layer* whose frame is the core rect `parent` — what
    /// a nested layer needs (`WindowAnimation.crop`'s still inside its window layer).
    public func localRect(_ rect: Rect, within parent: Rect) -> CGRect {
        geometry.local(rect, within: parent)
    }

    /// What a raised cover holds. A window at *full* alpha marks everything beneath it occluded, and an
    /// occluded app may stop feeding a separately-composited plane — a playing video is the case that
    /// bites. Any alpha under 1 disqualifies it, and a thousandth is below one 8-bit level.
    private static let raisedAlpha: CGFloat = 0.999

    /// Show the cover; `onScreen` fires a refresh later, when the display has shown it. Written through
    /// the animator at zero duration, not as a bare assignment: a direct one would be overwritten by the
    /// next frame of a cross-fade still in flight, where a zero-duration animation replaces that fade
    /// outright. `onScreen` fires at most once, and not at all for a cover replaced or faded first.
    public func raise(onScreen: @escaping @MainActor () -> Void) {
        generation &+= 1
        isRaised = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = Self.raisedAlpha
        }
        window.orderFrontRegardless()
        armFence(onScreen)
    }

    //
    // Nothing in AppKit or Core Animation reports a commit reaching the glass, so the display is asked
    // instead. `CADisplayLink.targetTimestamp` is when the frame being composed at this callback will be
    // shown, and a commit made before the callback is in that frame or an earlier one — so the cover has
    // been displayed once the clock passes it. Two callbacks, one refresh.

    /// Fired at most once per raise, then cleared. Non-`nil` ⇒ a fence is armed.
    private var fence: (@MainActor () -> Void)?

    /// When the frame carrying the raise reaches the display, latched at the first callback after it.
    /// `nil` while the fence is armed but that callback has yet to arrive.
    private var presentedBy: CFTimeInterval?

    /// Paused between fences, never invalidated — same reasoning as the pump's clock.
    private var fenceLink: CADisplayLink?

    private func armFence(_ onScreen: @escaping @MainActor () -> Void) {
        fence = onScreen
        presentedBy = nil
        let link = fenceLink ?? {
            let made = screen.displayLink(target: self, selector: #selector(fenceStep(_:)))
            // `.common` for the same reason the pump's clock uses it: a transition begun during event
            // tracking must not stall until the tracking ends.
            made.add(to: .main, forMode: .common)
            fenceLink = made
            return made
        }()
        link.isPaused = false
    }

    private func cancelFence() {
        fence = nil
        presentedBy = nil
        fenceLink?.isPaused = true
    }

    @objc private func fenceStep(_ link: CADisplayLink) {
        guard let fence else { return cancelFence() }        // paused between callbacks
        guard let deadline = presentedBy else {
            presentedBy = link.targetTimestamp
            return
        }
        guard link.timestamp >= deadline else { return }
        cancelFence()
        fence()
    }

    /// Cross-fade the cover away over `duration`, which must be positive — `completion` releases the
    /// stills and tears down the layer tree, and that must not ride on whether AppKit schedules a handler
    /// for an animation with no work to do. It runs exactly once per call, always: it acks
    /// `Event.crossfadeDone` back into the pump, so a fade with nothing raised resolves immediately.
    /// `completed == false` means a newer transition raised the overlay mid-fade and owns the layer tree
    /// now — the caller must **not** tear it down.
    public func fadeOut(duration: TimeInterval,
                        completion: @escaping @MainActor (_ completed: Bool) -> Void) {
        // A cover on its way down has nothing left to report having arrived. Dropping the fence rather
        // than firing it keeps `coverOnScreen` a fact about a live cover; the core tolerates either.
        cancelFence()
        guard isRaised else { return completion(true) }
        generation &+= 1
        let mine = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard self.generation == mine else { return completion(false) }
                self.isRaised = false
                completion(true)
            }
        })
    }
}
