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
//
// **This is where — and the *only* place where — `Config.windowAnimation` means anything.** A still is
// pixels of a window at the size it was when the shutter opened, and a transition routinely presents it
// at some other size. `.stretch` scales it to whatever rect the core names; `.crop` holds it at capture
// scale, anchored top-left, and lets the rect run past it or cut it off. The core emits the *same*
// `setLayerFrame` stream either way — it is describing where a window is, not how to paint one — so the
// whole of the difference is which layers this file builds and where it puts them. There is no second
// animator, no second transition lifecycle, and nothing above this file branches on the setting.

/// One window's stand-in: what the cover hosts, and what (if anything) is nested inside it.
///
/// One layer in `.stretch`, three in `.crop`, and the count is forced by two Core Animation facts that
/// pull against each other:
///
///  · **A layer with `masksToBounds` on cannot draw its own shadow** — the finding already recorded in
///    `makeLayer`, which is why `.stretch` never clips.
///  · **A crop has to clip**, or the corner of a still cut off mid-window covers the rounded corner of
///    the extent it is supposed to be sitting inside, and a shrinking window grows square corners.
///
/// So the shadow and the clip take a layer each: `root` casts, `clip` rounds, `still` draws. This is
/// the ordinary AppKit shadow-plus-corner idiom, and taking it removes every per-corner special case —
/// the mask is one rounded rect and it is right in both directions at once.
private struct CoverLayer {
    /// What the overlay hosts, what `setLayerFrame` positions, and what `elevate` re-stacks. Carries
    /// the image itself in `.stretch`; in `.crop` it carries only the shadow, and its bounds are the
    /// window's extent.
    let root: CALayer
    /// The rounded window silhouette, filled with the scrim and clipping the still to it — or `nil` in
    /// `.stretch`, where the capture's own transparent corners do this job for free.
    let clip: CALayer?
    /// The still at its captured scale, or `nil` in `.stretch` (where `root` carries it directly).
    let still: CALayer?
    /// The still's size in points — the natural extent every crop is measured against, and the one
    /// number that cannot be recovered from the layer tree once the layer has been resized.
    let natural: Size
}

/// The `CoverSurface` implementation: builds and animates the reconstruction inside an `Overlay`.
@MainActor
public final class Reconstruction: CoverSurface {

    private let overlay: Overlay
    /// Where the pixels come from — this transition's stills and its desktop base.
    private let store: any CaptureStore
    /// The current transition's layers, keyed by the core's `LayerId` (the only name the core uses for
    /// them, per `Effect.setLayerFrame`).
    private var layers: [LayerId: CoverLayer] = [:]

    /// How a still is painted into the rect the core hands it (`Config.windowAnimation`). Settable so
    /// a config reload reaches a running daemon, like the hotkey table and unlike the springs.
    ///
    /// Read only when a layer is **built**, never when one is moved: a `CoverLayer` already records
    /// which shape it was built in (`still != nil`), so a reload landing mid-transition changes the
    /// next cover rather than re-interpreting the layers of the one on screen. A cover half in each
    /// mode is not a state worth being able to reach.
    public var animation: WindowAnimation

    public init(overlay: Overlay, store: any CaptureStore, animation: WindowAnimation = .stretch) {
        self.overlay = overlay
        self.store = store
        self.animation = animation
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
        overlay.addLayer(target.root)
    }

    public func setLayerFrame(_ layer: LayerId, to rect: Rect) {
        // Total: a stale id from a closed session, or a window whose capture never arrived and so has
        // no layer to move.
        guard let target = layers[layer] else { return }
        place(target, at: rect)
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
            overlay.addLayer(layer.root)
        }
    }

    private func makeLayer(with surface: CapturedSurface) -> CoverLayer {
        let root = CALayer()
        root.contentsScale = overlay.backingScale
        // The shadow is *synthesized*, not captured: a window's system drop-shadow isn't part of its
        // surface, so a reconstruction without one reads as flat. This was the single visible gap in
        // the first fidelity spike and these are the values that closed it (PRINCIPLES.md §10).
        root.shadowColor = NSColor.black.cgColor
        root.shadowOpacity = 0.35
        root.shadowRadius = 18
        root.shadowOffset = CGSize(width: 0, height: -8)

        let cover: CoverLayer
        switch animation {
        case .stretch:
            root.contents = surface.image
            // The still was captured at exactly `frame.size × backingScale` pixels, so mapping it onto
            // a layer of `frame.size` points is 1:1 — `.resize` is an identity at rest, not a scale,
            // and that is the property that keeps the reconstruction sharp. It stops being an identity
            // the moment a resize animates the frame, which is precisely what `.crop` exists to avoid.
            root.contentsGravity = .resize
            // No `masksToBounds` and no `shadowPath`: a window capture is transparent outside the
            // window's rounded corners, and with both left alone Core Animation derives the shadow from
            // the contents' own alpha — so the corners round themselves and the shadow follows their
            // actual shape. Clipping to bounds would square the shadow off and cut it away entirely.
            cover = CoverLayer(root: root, clip: nil, still: nil, natural: surface.frame.size)

        case .crop:
            // The radius comes off the capture rather than out of a constant (`measuredCornerRadius`),
            // because we are drawing a window's *silhouette* at a size no capture of it exists at, and
            // a guessed radius is a guess that goes stale with the next macOS.
            let radius = CGFloat(surface.cornerRadius ?? Self.fallbackCornerRadius)

            let clip = CALayer()
            clip.contentsScale = overlay.backingScale
            // `clip` is the window's extent, and it has to paint something: during a grow it is the
            // only thing covering the space the still hasn't reached. A **translucent** wash rather
            // than an opaque fill, deliberately — the desktop showing through the space a window is
            // expanding into is the intended read here, not the wallpaper-through-a-hole defect of M4
            // part 1 (that was a whole missing column under an opaque cover; this is a margin the user
            // is watching a window grow into).
            clip.backgroundColor = Self.scrim
            clip.cornerRadius = radius
            // **This is what does the cropping**, and it is load-bearing in both directions: it cuts
            // the still off where the window has shrunk past it, and — because it rounds while it
            // cuts — the cut ends in the window's own corner instead of a square edge. It costs
            // `root` its alpha-derived shadow, which is why the shadow moved up a layer.
            clip.masksToBounds = true

            let still = CALayer()
            still.contentsScale = overlay.backingScale
            still.contents = surface.image
            // The still is always its captured size, 1:1 with its own pixels, and simply **overflows**
            // the clip when the window has shrunk below it — no `contentsRect`, no trimming. Trimming
            // it to fit was the first version and it broke both directions at once: `contentsRect`
            // measures from the *bottom*-left on a non-flipped layer, so a window losing height threw
            // away its title bar, and a still that never crossed the clip's bounds left the clip
            // nothing to round. `.resize` over a layer that is exactly the contents' size is the
            // identity, as it is in `.stretch` at rest.
            still.contentsGravity = .resize
            clip.addSublayer(still)
            root.addSublayer(clip)

            // `root` holds only the shadow now, and has nothing left to derive one from — so the crop
            // states its silhouette outright, at the same radius the clip rounds to. Re-stated every
            // frame by `place`, because the bounds it describes change every frame.
            root.shadowPath = Self.shadowPath(for: .zero, radius: radius)
            cover = CoverLayer(root: root, clip: clip, still: still, natural: surface.frame.size)
        }

        // A layer starts where its capture was taken (see the header). At that rect the crop is the
        // identity — the still is exactly the size of the window it came from — so both modes put
        // identical pixels on screen at the raise, and neither can pop.
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
        // Always the still's own size, pinned to the window's top-left — bigger than the clip when the
        // window has shrunk, which is exactly when `clip.masksToBounds` earns its place.
        still.frame = overlay.localRect(rect.anchoring(cover.natural), within: rect)
        cover.root.shadowPath = Self.shadowPath(for: frame.size, radius: clip.cornerRadius)
    }

    private func discardLayers() {
        for layer in layers.values { layer.root.removeFromSuperlayer() }
        layers.removeAll()
    }

    // MARK: - The crop's cosmetics
    //
    // What a window looks like at a size no capture of it exists at. The shadow values above were
    // judged by a spike against a real window; these describe space the window has not drawn into yet,
    // so there is nothing to compare them against and they are kept together to be turnable by eye.
    // The corner radius is the exception, and deliberately so — it is *measured*, not chosen.

    /// The wash over the space a growing window has yet to fill. Translucent on purpose: the desktop
    /// behind it is meant to show through. `windowBackgroundColor` because it is, literally, the colour
    /// of an empty window — and because it follows the user's light/dark appearance for free.
    private static var scrim: CGColor {
        NSColor.windowBackgroundColor.withAlphaComponent(0.35).cgColor
    }

    /// The radius used only when a capture's alpha couldn't answer for itself
    /// (`CapturedSurface.measuredCornerRadius` returned `nil`) — an opaque or square-cornered surface.
    /// Roughly a macOS 26 window's own radius: a guess, and reached only when the measurement isn't
    /// available, which is the whole reason the measurement exists.
    private static let fallbackCornerRadius: Double = 12

    /// The silhouette the shadow is cast from — the window's whole extent, corners included, rather
    /// than whatever fraction of the still currently covers it.
    private static func shadowPath(for size: CGSize, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(origin: .zero, size: size),
               cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
