import AppKit
import QuartzCore
import EmiraCore

// The layered reconstruction (PRINCIPLES.md §4b) — the layer tree inside an `Overlay`, one `CALayer`
// per window the core scoped into the transition, keyed by the `LayerId` the core minted.
//
// **Why layers and not one photograph.** A flat screenshot cover hides everything but can only slide
// as a unit; gappy per-window overlays can move independently but expose the real desktop between
// them (we cannot hide a foreign window without SkyLight). A *full, opaque, layered* stand-in has
// neither flaw: the base layer makes it gap-free, and each window is its own layer, so the strip
// scrolls as real per-window motion. That is the thesis `spike/strip.swift` validated at three
// windows, and this is its permanent home.
//
// **The stand-in is gone (M4).** Through M3 the layer *tree* was final and the layer **contents** were
// fake — a flat colour per window, because there was no `CaptureService` to ask. Now every layer
// carries that window's actual captured surface over a base that is the actual desktop, and the fake
// colours are deleted rather than kept as a fallback: a coloured rectangle sliding where a window
// should be is not a degraded cover, it is a worse experience than no cover at all, which is why the
// no-capture case is answered a level up by not opening a transition (`Config.smoothTransitions`).
//
// **A layer starts where its capture was taken, not where the core thinks the window is.** The two are
// the same number in the ordinary case and the difference is the whole of fidelity in every other one:
// the capture's frame is where those pixels actually were, and a cover raised on it is pixel-identical
// to what it replaces. This is also why layers are no longer built hidden and revealed by their first
// tick — with a real still there *is* a right place to be at the instant of the raise, and a
// one-frame-late reveal would be a visible hole.
//
// **Layers are built per transition, not pooled.** A session's scope is decided by the core and can
// differ every time; minting three `CALayer`s costs nothing measurable next to the capture that gates
// the raise, and a pool would have to answer "is this layer still showing the right window?" on every
// reuse — a class of staleness bug that not existing is the cheapest way to avoid.

/// The `CoverSurface` implementation: builds and animates the reconstruction inside an `Overlay`.
@MainActor
public final class Reconstruction: CoverSurface {

    private let overlay: Overlay
    /// Where the pixels come from — this transition's stills and its desktop base.
    private let store: any CaptureStore
    /// The current transition's layers, keyed by the core's `LayerId` (the only name the core uses for
    /// them, per `Effect.setLayerFrame`).
    private var layers: [LayerId: CALayer] = [:]

    public init(overlay: Overlay, store: any CaptureStore) {
        self.overlay = overlay
        self.store = store
    }

    // MARK: - CoverSurface

    public func beginFrame() {
        CATransaction.begin()
        // The core owns the clock (PRINCIPLES.md §7): every frame's position is *computed*, so Core
        // Animation must never interpolate between them. Without this, each blit would start an
        // implicit 0.25 s animation and the layer would chase the core's spring a quarter-second
        // behind it.
        CATransaction.setDisableActions(true)
    }

    public func endFrame() {
        CATransaction.commit()
    }

    public func raiseCover(_ bindings: [LayerBinding]) {
        discardLayers()
        overlay.setBase(store.base)
        // The raise is one frame's worth of work and must be atomic: the base swap, every layer's
        // creation *and* its initial placement all reach the window server together, or the cover goes
        // up mid-assembly. `raiseCover` is called inside `CompositingExecutor`'s frame, so the
        // transaction is already open — this is that frame's contents.
        addLayers(bindings)                          // array order is z-order, bottom→top
        overlay.raise()
    }

    public func extendCover(_ bindings: [LayerBinding]) {
        // Same construction, no raise — the cover is already up, and this call is running inside the
        // frame that will also place the new layers (`CompositingExecutor` keeps the run contiguous),
        // so nothing is ever displayed half-assembled.
        addLayers(bindings)
    }

    public func elevate(_ layer: LayerId) {
        // Re-adding an existing sublayer moves it to the end of `sublayers`, i.e. the top — Core
        // Animation treats `addSublayer` on a layer it already hosts as a reorder, not a duplicate.
        // That is the whole implementation, and it is why this cost no new machinery in `Overlay`.
        //
        // Total, like `setLayerFrame` and for the same reason: the core can name a layer whose window
        // had no still, and being asked to raise something that isn't there is not an error.
        guard let target = layers[layer] else { return }
        overlay.addLayer(target)
    }

    public func setLayerFrame(_ layer: LayerId, to rect: Rect) {
        // Total: a stale id from a closed session, or a window whose capture never arrived and so has
        // no layer to move.
        guard let target = layers[layer] else { return }
        target.frame = overlay.localRect(rect)
    }

    public func dismiss(completion: @escaping @MainActor () -> Void) {
        overlay.fadeOut { [weak self] completed in
            // `completed == false` ⇒ a newer transition raised the overlay mid-fade and owns the layer
            // tree now; tearing it down here would delete *its* layers (see `Overlay.fadeOut`).
            if completed { self?.discardLayers() }
            completion()
        }
    }

    // MARK: - Layers

    /// Mint and install one layer per binding, in the order given (bottom→top). A binding whose layer
    /// already exists is skipped, so growing the cover can never duplicate a window.
    ///
    /// A window with no still is a window we have no pixels for — most likely destroyed between the
    /// reducer scoping it and the shutter opening. It gets no layer, and the base shows through where
    /// it was, which for a window that no longer exists is the truthful picture.
    private func addLayers(_ bindings: [LayerBinding]) {
        for binding in bindings {
            guard layers[binding.layer] == nil,
                  let surface = store.surface(for: binding.window) else { continue }
            let layer = makeLayer(with: surface)
            layers[binding.layer] = layer
            overlay.addLayer(layer)
        }
    }

    private func makeLayer(with surface: CapturedSurface) -> CALayer {
        let layer = CALayer()
        layer.contentsScale = overlay.backingScale
        layer.contents = surface.image
        // The still was captured at exactly `frame.size × backingScale` pixels, so mapping it onto a
        // layer of `frame.size` points is 1:1 — `.resize` is an identity here, not a scale, and that is
        // the property that keeps the reconstruction sharp.
        layer.contentsGravity = .resize
        layer.frame = overlay.localRect(surface.frame)
        // The shadow is *synthesized*, not captured: a window's system drop-shadow isn't part of its
        // surface, so a reconstruction without one reads as flat. This was the single visible gap in
        // the first fidelity spike and these are the values that closed it (PRINCIPLES.md §10).
        //
        // No `masksToBounds` and no `shadowPath`: a window capture is transparent outside the window's
        // rounded corners, and with both left alone Core Animation derives the shadow from the
        // contents' own alpha — so the corners round themselves and the shadow follows their actual
        // shape. Clipping to bounds would square the shadow off and cut it away entirely.
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: -8)
        return layer
    }

    private func discardLayers() {
        for layer in layers.values { layer.removeFromSuperlayer() }
        layers.removeAll()
    }
}
