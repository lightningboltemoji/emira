import AppKit
import QuartzCore
import EmiraCore

// The cover itself — one borderless, click-through `NSWindow` we own per display, holding the layers
// the reconstruction is built from (PRINCIPLES.md §4b, IMPLEMENTATION.md §5
// `Compositor/Overlay.swift`). This is the entire presentation plane's substrate: **windows we own**,
// so we may translate/scale/fade their contents at refresh rate with zero foreign-app involvement.
//
// Everything here is harvested from the validated spikes rather than reasoned about fresh — the
// window flags below are the ones `spike/move-loop.swift` and `spike/strip-scroll.swift` proved
// produce a stand-in the eye cannot catch:
//
//  · **`animationBehavior = .none` + kept ordered-in at `alpha 0`.** The appear-pop killer
//    (`PRINCIPLES.md` §10, 2026-07-23). A window ordered front for the first time gets a system
//    show-animation; by keeping the overlay permanently ordered-in and invisible, *raising it is a
//    pure alpha flip* with no animation to catch.
//  · **Opaque.** The cover's job is that nothing behind it is ever exposed while the real windows
//    teleport (§4b step 3). An overlay with any transparency is a hole in that guarantee.
//  · **`ignoresMouseEvents` + never key.** A borderless window never becomes key on its own, and
//    click-through means the cover is invisible to input as well as inert — the user keeps typing at
//    whatever really has focus while we animate in front of it.
//  · **`.floating` level, `canJoinAllSpaces`, `stationary`.** Above ordinary windows, below the menu
//    bar (which the strut keeps clear of the strip anyway), and it does not slide when the desktop
//    does.
//
// **The cover is the working area, not the display (M4 part 3).** Being *below* the menu bar is not the
// same as not colliding with it. Our overlay is `.floating` (level 3) and the menu bar is `.mainMenu`
// (level 24), so the **real** menu bar always composites on top of the cover — over the base capture's
// own copy of it. The two coincide invisibly until they disagree, which any transition that changes the
// frontmost app guarantees: the base was captured with one app frontmost while the real bar already
// names the next, and both are on screen at once (`PRINCIPLES.md` §10, M4 part 2's finding — two apps'
// names superimposed).
//
// So the window is **inset by the struts**: the cover paints exactly the region the strip lives in, and
// the chrome bands are simply left alone, showing the real, live menu bar and Dock. This is safe for the
// same reason the strut exists — a managed window can never be in that band, tiled *or* parked, so there
// is nothing there for the cover to hide (§4b step 3's no-exposure rule is about *moving* windows). The
// one exception is a hair thin: since parks became corner nubs (`Layout/Park.swift`, 2026-07-26) a
// parked window's body crosses the Dock band on its way off the display — one point wide, at the far
// right, uncovered.
// Raising the cover above the menu bar instead would only substitute a stale menu bar for a doubled one.
// The desktop base is still the whole display; it is placed at the display's rect in local coordinates
// and clipped by the host layer, so the wallpaper behind the strip stays exactly where it was captured.
//
// **What lives here vs. in `Reconstruction`.** This type owns the *window* — its geometry, its
// coordinate conversion, and its raise/cross-fade. It knows nothing about `LayerId`s, bindings, or
// windows; it just hosts sublayers. `Reconstruction` owns the layer tree. `IMPLEMENTATION.md` §5 also
// lists a `Compositor/Transition.swift` for raise/cross-fade; with one overlay and no capture yet
// that would be a file holding two methods, so the alpha mechanics sit here until M4 gives them
// company (capture hand-off, per-display coordination).

/// A borderless click-through overlay window covering one display, with a layer host for the
/// reconstruction. Created once at launch and kept for the process's lifetime — a transition raises
/// and fades it, never builds or tears it down (building costs a window-server round trip we cannot
/// afford at the head of a transition).
@MainActor
public final class Overlay {

    /// The whole display's frame in **core** (top-left virtual-strip) coordinates. Larger than the
    /// cover: this is where the desktop *base* capture is placed, so the wallpaper lines up with the
    /// real one even though only the working area is painted.
    public let displayFrame: Rect

    /// The region this overlay actually covers — the display inset by its struts, i.e. the working area
    /// the strip is laid out in. Everything outside it (menu bar, notch, Dock) is deliberately left
    /// showing the real desktop; see the header.
    public let coverFrame: Rect

    /// The display's backing scale — stamped onto every layer so the reconstruction rasterizes at
    /// native resolution. Fidelity is make-or-break for the cross-fade (`PRINCIPLES.md` §6).
    public let backingScale: CGFloat

    private let geometry: ScreenGeometry
    private let window: NSWindow
    /// The layer everything is added to. Clipped, so a window layer sliding off the strip's edge is
    /// cut at the screen boundary instead of drawing past it.
    private let host: CALayer
    /// The bottom-most layer — the desktop the window layers sit on: the display captured *excluding*
    /// the windows this transition animates (`SCKCapturer`), so it carries the wallpaper, the menu bar
    /// and every window that is not moving, with window-shaped holes where the moving ones were.
    private let base: CALayer

    /// Whether the cover is currently visible.
    public private(set) var isRaised = false

    /// Bumped by every raise and every fade, so a fade's completion handler can tell whether it is
    /// still the current one. Without this, a transition that opens *during* the 0.22 s cross-fade of
    /// the previous one would have its fresh layers torn down by the old fade's completion.
    private var generation = 0

    /// Build the overlay for `screen`, covering that screen inset by `insets`, and order it in,
    /// invisible.
    ///
    /// `insets` must be the **same** struts the core lays the strip out with (`Config.struts`), not a
    /// separately-derived number: the invariant that makes leaving the chrome bands unpainted safe is
    /// "no managed window is ever outside the working area", and it holds only while the two agree.
    public init(screen: NSScreen, geometry: ScreenGeometry, insets: EdgeInsets = .zero) {
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
        // The whole display, in the cover's local space — so its origin is *negative* by the strut on
        // each inset edge and the host layer clips it. The base image is a capture of the entire
        // display; placing it anywhere else would slide the wallpaper by the height of the menu bar.
        base.frame = geometry.local(displayFrame, in: window.frame)
        base.contentsGravity = .resize
        base.contentsScale = screen.backingScaleFactor
        // The fallback beneath the capture, and it is a *fallback*, not a look: black is what a display
        // with nothing on it shows. If a raise ever gets here the desktop capture failed, and a flat
        // black cover is the least-wrong thing to hold for 300 ms — see `setBase`.
        base.backgroundColor = NSColor.black.cgColor
        host.addSublayer(base)

        window.contentView = view
        // Ordered in now and left in forever: see the header — the raise must be an alpha flip, not a
        // first `orderFront`, or the system's show-animation pops.
        window.orderFrontRegardless()
    }

    /// Add a reconstruction layer above the base. Call order is z-order, bottom→top.
    public func addLayer(_ layer: CALayer) {
        host.addSublayer(layer)
    }

    /// Put this transition's captured desktop behind the window layers, or `nil` to fall back to the
    /// flat black fill.
    ///
    /// Set at every raise rather than once, because the desktop is not a constant: a window that is not
    /// in the transition's scope may have moved, redrawn or closed since the last cover came down, and
    /// the base is the half of the reconstruction responsible for all of them. A cached base is a cover
    /// that shows the desktop as it was some scrolls ago.
    public func setBase(_ image: CGImage?) {
        base.contents = image
    }

    /// A core (top-left, global) rect in the overlay's **local** layer coordinates. The one conversion
    /// the compositor performs per layer per frame; the arithmetic lives in `ScreenGeometry` (with the
    /// rest of the coordinate handling) so it is testable with no display attached.
    public func localRect(_ rect: Rect) -> CGRect {
        geometry.local(rect, in: window.frame)
    }

    /// A core rect in the local coordinates of a *layer* whose frame is the core rect `parent` — the
    /// conversion a nested layer needs (`WindowAnimation.crop`'s still inside its window layer). Same
    /// arithmetic, one level down; see `ScreenGeometry.local(_:within:)`.
    public func localRect(_ rect: Rect, within parent: Rect) -> CGRect {
        geometry.local(rect, within: parent)
    }

    /// Show the cover **instantly** — a pure alpha flip on an already-ordered-in window.
    ///
    /// Written through the animator with a zero duration rather than as a bare `alphaValue = 1`: if a
    /// cross-fade from the previous transition is still running, a direct assignment would be
    /// overwritten by the next frame of that animation and the cover would fade out from under the new
    /// transition. A zero-duration animation replaces the in-flight one outright.
    public func raise() {
        generation &+= 1
        isRaised = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = 1
        }
        window.orderFrontRegardless()
    }

    /// Cross-fade the cover away, calling `completion` on the main actor when the fade resolves.
    ///
    /// `completion` runs **exactly once** per call, always — a fade with nothing raised resolves
    /// immediately — because it is what acks `Event.crossfadeDone` back into the pump, and a swallowed
    /// ack would break the "every effect that answers, answers" contract in `Executor.swift`.
    ///
    /// `completed` says whether this fade is still the one that owns the overlay. A transition that
    /// opens *during* the 0.22 s cross-fade raises the overlay again and moves `generation` on; the
    /// older fade then reports `false`, and the caller must **not** tear down the layer tree — the
    /// newer transition's layers are in it now. That one bit is the entire interrupt-during-crossfade
    /// story, and it is why the raise/fade pair is generation-counted rather than a bare bool.
    public func fadeOut(duration: TimeInterval = 0.22,
                        completion: @escaping @MainActor (_ completed: Bool) -> Void) {
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
