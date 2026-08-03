import AppKit
import QuartzCore
import EmiraCore

// The layer tree inside an `Overlay`: one `CALayer` per window the core scoped into the transition,
// keyed by `LayerId`, over a base layer holding the captured desktop. Layers are built per transition,
// never pooled, and each starts at the rect its capture was taken from, so the raise is
// pixel-identical to what it replaces. This is the only place `Config.windowAnimation` means anything:
// the core emits the same `setLayerFrame` stream either way.

/// One window's stand-in: one layer in `.stretch`, three in `.crop`. The count is forced by two Core
/// Animation facts pulling against each other — a layer with `masksToBounds` on cannot draw its own
/// shadow, and a crop must clip or a shrinking window grows square corners.
private struct CoverLayer {
    /// The window this layer stands for — what `refreshLayer` needs to find its still in the store, and
    /// the one thing the `LayerId` key cannot answer.
    let window: WindowId
    /// What the overlay hosts and `setLayerFrame` positions. Carries the image in `.stretch`; in
    /// `.crop` only the shadow, with the window's extent as its bounds.
    let root: CALayer
    /// The rounded silhouette, filled with the scrim and clipping the still to it — `nil` in
    /// `.stretch`, where the capture's own transparent corners do this job.
    let clip: CALayer?
    /// The still at its captured scale, or `nil` in `.stretch` (where `root` carries it directly).
    let still: CALayer?
    /// The still's size in points — unrecoverable from the layer tree once the layer is resized.
    let natural: Size
}

/// The `CoverSurface` implementation: builds and animates the reconstruction inside an `Overlay`.
/// One per display — the base is a photograph of *this* screen, and the layers are the windows that
/// are on it.
@MainActor
public final class Reconstruction: CoverSurface {

    private let overlay: Overlay
    /// Which display this reconstruction covers — what picks its base out of the store.
    private let monitor: MonitorId
    /// Where the pixels come from — this transition's stills and this display's desktop base.
    private let store: any CaptureStore
    /// The current transition's layers, keyed by the core's `LayerId`.
    private var layers: [LayerId: CoverLayer] = [:]

    /// How a still is painted into the rect the core hands it. Read only when a layer is *built*, so a
    /// reload landing mid-transition changes the next cover, not the one on screen.
    public var animation: WindowAnimation

    public init(overlay: Overlay, monitor: MonitorId, store: any CaptureStore,
                animation: WindowAnimation = .stretch) {
        self.overlay = overlay
        self.monitor = monitor
        self.store = store
        self.animation = animation
    }

    public func raiseCover(_ bindings: [LayerBinding], onScreen: @escaping @MainActor () -> Void) {
        discardLayers()
        overlay.setBase(store.base(of: monitor))
        // The raise must be atomic — base swap, layer creation and initial placement reach the window
        // server together, inside the transaction `CompositingExecutor` has already opened.
        addLayers(bindings)                          // array order is z-order, bottom→top
        overlay.raise(onScreen: onScreen)
    }

    public func extendCover(_ bindings: [LayerBinding]) {
        // Same construction, no raise. The frame that places the new layers is this one.
        addLayers(bindings)
    }

    public func elevate(_ layer: LayerId) {
        // Core Animation treats `addSublayer` on a layer it already hosts as a reorder to the top, not
        // a duplicate. Total: the core can name a layer whose window had no still.
        guard let target = layers[layer] else { return }
        overlay.addLayer(target.root)
    }

    public func setLayerFrame(_ layer: LayerId, to rect: Rect) {
        // Total: a stale id from a closed session, or a window whose capture never arrived.
        guard let target = layers[layer] else { return }
        place(target, at: rect)
    }

    public func refreshLayer(_ layer: LayerId) {
        // Total, for the same reasons `setLayerFrame` is, plus one of its own: the still may have been
        // freed with its cover between the ack and this call.
        guard let cover = layers[layer],
              let surface = store.surface(for: cover.window) else { return }
        // `.crop` carries the image a layer down, under the clip that rounds it; `.stretch` on `root`.
        let target = cover.still ?? cover.root
        guard let previous = target.contents else { return }

        // Explicit: the surrounding frame has implicit animations disabled, and this is not a frame of
        // motion — the geometry is wherever the last tick left it and only the pixels inside change.
        let fade = CABasicAnimation(keyPath: "contents")
        fade.fromValue = previous
        fade.duration = Self.refreshDuration
        target.contents = surface.image
        target.add(fade, forKey: "refresh")
        // The corner radius and `natural` stand: a stand-in matches the window's size, so re-deriving
        // either from these pixels could only move a hard edge by a rounding error.
    }

    public func dismiss(over duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
        overlay.fadeOut(duration: duration) { [weak self] completed in
            // `completed == false` ⇒ a newer transition owns the layer tree; tearing it down here
            // would delete *its* layers.
            if completed { self?.discardLayers() }
            completion()
        }
    }

    /// Mint and install one layer per binding, bottom→top. A binding whose layer already exists is
    /// skipped. A window with no still gets no layer, and the base shows through where it was.
    ///
    /// **A window that does not reach this display gets no layer either.** The bindings are the whole
    /// transition's, so every surface is offered every window; the still's own captured frame is what
    /// says which screens the window was on. Without the test each display would hold a clipped copy
    /// of every other display's strip.
    ///
    /// `intersects`, not "belongs to": a window straddling the boundary gets a layer on **both**, which
    /// is what draws it whole across the seam — `Effect.setLayerFrame` stays untagged, so the two
    /// halves move in lockstep and each overlay clips its own. That is also why every capturer excludes
    /// the transition's windows from its base, whether or not it filmed them: a display drawing a layer
    /// for a window whose frozen copy is still in its desktop would show it twice.
    private func addLayers(_ bindings: [LayerBinding]) {
        for binding in bindings {
            guard layers[binding.layer] == nil,
                  let surface = store.surface(for: binding.window),
                  surface.frame.intersects(overlay.displayFrame) else { continue }
            let layer = makeLayer(for: binding.window, with: surface)
            layers[binding.layer] = layer
            overlay.addLayer(layer.root)
        }
    }

    private func makeLayer(for window: WindowId, with surface: CapturedSurface) -> CoverLayer {
        let root = CALayer()
        root.contentsScale = overlay.backingScale
        // Synthesized, not captured: a window's system drop-shadow isn't part of its surface, and a
        // reconstruction without one reads as flat.
        root.shadowColor = NSColor.black.cgColor
        root.shadowOpacity = 0.35
        root.shadowRadius = 18
        root.shadowOffset = CGSize(width: 0, height: -8)

        let cover: CoverLayer
        switch animation {
        case .stretch:
            root.contents = surface.image
            // The still is `frame.size × backingScale` pixels, so `.resize` onto a layer of
            // `frame.size` points is an identity at rest — which is what keeps it sharp.
            root.contentsGravity = .resize
            // No `masksToBounds` and no `shadowPath`: a capture is transparent outside the window's
            // rounded corners, so CA derives the shadow from the contents' alpha. Clipping to bounds
            // would square it off and cut it away.
            cover = CoverLayer(window: window, root: root, clip: nil, still: nil,
                               natural: surface.frame.size)

        case .crop:
            // Measured off the capture, not a constant: a guessed radius goes stale with the next macOS.
            let radius = CGFloat(surface.cornerRadius ?? Self.fallbackCornerRadius)

            let clip = CALayer()
            clip.contentsScale = overlay.backingScale
            // `clip` is the window's extent and has to paint something: during a grow it is the only
            // thing covering the space the still hasn't reached. Translucent on purpose — see `scrim`.
            clip.backgroundColor = Self.scrim
            clip.cornerRadius = radius
            // This is the crop: it cuts the still off where the window has shrunk past it, rounding
            // as it cuts. It costs `root` its alpha-derived shadow, hence the shadow a layer up.
            clip.masksToBounds = true

            let still = CALayer()
            still.contentsScale = overlay.backingScale
            still.contents = surface.image
            // The still keeps its captured size and overflows the clip when the window shrinks below
            // it. No `contentsRect`: it measures from the *bottom*-left on a non-flipped layer, so
            // trimming would throw away the title bar of a shortening window.
            still.contentsGravity = .resize
            clip.addSublayer(still)
            root.addSublayer(clip)

            // `root` holds only the shadow and has no contents to derive one from, so the crop states
            // its silhouette outright. Re-stated every frame by `place`.
            root.shadowPath = Self.shadowPath(for: .zero, radius: radius)
            cover = CoverLayer(window: window, root: root, clip: clip, still: still,
                               natural: surface.frame.size)
        }

        // A layer starts at its capture's own rect, where the crop is the identity, so neither mode
        // can pop at the raise.
        place(cover, at: surface.frame)
        return cover
    }

    /// Put one stand-in at `rect` for this frame: the window's extent, and — in `.crop` — the part of
    /// its still that reaches.
    private func place(_ cover: CoverLayer, at rect: Rect) {
        let frame = overlay.localRect(rect)
        cover.root.frame = frame
        guard let clip = cover.clip, let still = cover.still else { return }   // `.stretch`: that's all
        clip.frame = CGRect(origin: .zero, size: frame.size)
        // Always the still's own size, pinned to the window's top-left, overflowing a shrunk clip.
        still.frame = overlay.localRect(rect.anchoring(cover.natural), within: rect)
        cover.root.shadowPath = Self.shadowPath(for: frame.size, radius: clip.cornerRadius)
    }

    private func discardLayers() {
        for layer in layers.values { layer.root.removeFromSuperlayer() }
        layers.removeAll()
    }

    /// The wash over the space a growing window has yet to fill. Translucent so the desktop behind it
    /// shows through; `windowBackgroundColor` follows the user's light/dark appearance for free.
    private static var scrim: CGColor {
        NSColor.windowBackgroundColor.withAlphaComponent(0.35).cgColor
    }

    /// Used only when a capture's alpha couldn't answer for itself — an opaque or square-cornered
    /// surface, where `CapturedSurface.measuredCornerRadius` returns `nil`.
    private static let fallbackCornerRadius: Double = 12

    /// How long a stand-in takes to become the window's own pixels (`CoverMode.immediate`). Well under
    /// the cross-fade that ends a transition, because this one happens *during* the motion and its job
    /// is to be finished before the eye has settled anywhere.
    private static let refreshDuration: TimeInterval = 0.12

    /// The silhouette the shadow is cast from — the window's whole extent, not the fraction the still
    /// currently covers.
    private static func shadowPath(for size: CGSize, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(origin: .zero, size: size),
               cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
