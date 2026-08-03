import QuartzCore
import EmiraCore

// The presentation plane when there is more than one of it. **A composite of surfaces is a surface**,
// so `CompositingExecutor` is unchanged in shape; what moves here is the `CATransaction`, which now has
// to wrap the whole fan-out rather than one surface's share of it. Two displays blitting inside two
// transactions are two frames, and the strips on them shear apart by exactly one refresh.
//
// Two calls have an answer to give back, and both are gated on **every** surface rather than the first:
//
//  · `raiseCover` reports `coverOnScreen`, which is what entitles the reducer to teleport a real
//    window. A window may only move when the cover is up on every display it is visible on before *or*
//    after the move, and until a session names its own monitor the conservative form of that is "every
//    display". A fence that never fires leaves the report unmade and the hold deadline to rescue it,
//    which is the degradation the timeout is there for.
//  · `dismiss` reports `crossfadeDone`, and a cover half down is still a cover.
//
// Everything else fans out unconditionally and is filtered by the surfaces themselves: `setLayerFrame`,
// `refreshLayer` and `elevate` are all total over a layer the surface does not hold, so a layer built on
// one display costs the others a dictionary miss.

/// Every display's `CoverSurface`, driven as one.
@MainActor
public final class Compositor: CoverPlane {

    /// The surfaces, in display enumeration order. The `MonitorId` is read only to ask whether that
    /// screen is still there — one core session still covers every display — and it is carried because
    /// the alternative is an array whose elements cannot say which screen they are.
    private let surfaces: [(monitor: MonitorId, surface: any CoverSurface)]

    /// Whether a display this plane was built for is still attached. A departed display's overlay
    /// fences its raise on a `CADisplayLink` for a screen that is gone, so gating `coverOnScreen` on it
    /// would stall **every** transition until the hold deadline. Not consulted for a dismissal: taking
    /// a cover down is always safe, and an overlay that was never raised completes at once.
    public var isAttached: @MainActor (MonitorId) -> Bool = { _ in true }

    /// Bumped by every raise and every dismissal, so a report from a superseded one is dropped rather
    /// than counted against the current one. The same generation idiom `Overlay.fadeOut` uses.
    private var raiseGeneration = 0
    private var dismissGeneration = 0
    /// Surfaces that have yet to report, for the current raise and the current dismissal.
    private var fencesOwed = 0
    private var dismissalsOwed = 0

    public init(surfaces: [(monitor: MonitorId, surface: any CoverSurface)]) {
        self.surfaces = surfaces
    }

    /// One display's plane — the ordinary case, and what every test that does not care about the
    /// fan-out wants.
    public convenience init(monitor: MonitorId, surface: any CoverSurface) {
        self.init(surfaces: [(monitor, surface)])
    }

    public func beginFrame() {
        CATransaction.begin()
        // The core computes every frame's position; without this each blit starts an implicit 0.25 s
        // animation between them.
        CATransaction.setDisableActions(true)
    }

    public func endFrame() {
        CATransaction.commit()
    }

    public func raiseCover(_ bindings: [LayerBinding], onScreen: @escaping @MainActor () -> Void) {
        raiseGeneration &+= 1
        let mine = raiseGeneration
        let live = surfaces.filter { isAttached($0.monitor) }
        fencesOwed = live.count
        guard fencesOwed > 0 else { return onScreen() }   // no displays: nothing to wait for
        for entry in live {
            entry.surface.raiseCover(bindings) { [weak self] in
                guard let self, self.raiseGeneration == mine, self.fencesOwed > 0 else { return }
                self.fencesOwed -= 1
                guard self.fencesOwed == 0 else { return }
                onScreen()
            }
        }
    }

    public func extendCover(_ bindings: [LayerBinding]) {
        for entry in surfaces { entry.surface.extendCover(bindings) }
    }

    public func setLayerFrame(_ layer: LayerId, to rect: Rect) {
        for entry in surfaces { entry.surface.setLayerFrame(layer, to: rect) }
    }

    public func refreshLayer(_ layer: LayerId) {
        for entry in surfaces { entry.surface.refreshLayer(layer) }
    }

    public func elevate(_ layer: LayerId) {
        for entry in surfaces { entry.surface.elevate(layer) }
    }

    public func dismiss(over duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
        dismissGeneration &+= 1
        let mine = dismissGeneration
        dismissalsOwed = surfaces.count
        guard dismissalsOwed > 0 else { return completion() }
        for entry in surfaces {
            entry.surface.dismiss(over: duration) { [weak self] in
                guard let self, self.dismissGeneration == mine, self.dismissalsOwed > 0 else { return }
                self.dismissalsOwed -= 1
                guard self.dismissalsOwed == 0 else { return }
                completion()
            }
        }
    }
}
