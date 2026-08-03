import QuartzCore
import EmiraCore

// The presentation plane when there is more than one of it. A `CoverSurface` is one display's layer
// tree; this is all of them, plus the two things only the whole plane can own:
//
//  · **The frame boundary.** Two displays blitting inside two `CATransaction`s are two frames, and the
//    strips on them shear apart by exactly one refresh. So the transaction wraps the whole run.
//  · **The route.** A cover belongs to one display (D7), so `beginTransition` and `extendCover` name
//    theirs and the layers they mint are recorded against it. That is what lets the per-frame
//    `setLayerFrame` stay untagged (D11) — the hottest path in the reducer carries nothing extra, and
//    the routing is one dictionary read.
//
// A raise now fences on **one** surface rather than all of them, which is the whole of what per-monitor
// sessions buy the shell: a transition on one screen leaves the other's desktop alone, its pixels live,
// its own cover free to come down on its own schedule.

/// Every display's `CoverSurface`, with each cover routed to the one it belongs to.
@MainActor
public final class Compositor: CoverPlane {

    /// The surfaces, keyed by the display each covers. Mutable because the display set is: hot-plug
    /// builds one for a display that arrives and takes down the one a departing display had.
    private var surfaces: [MonitorId: any CoverSurface]

    /// Which display a `LayerId` was minted on — the route for every untagged layer call. Layers are
    /// minted from one watermark for the whole desktop, so an id names one layer on one screen, and an
    /// id whose cover has come down simply misses.
    private var route: [LayerId: MonitorId] = [:]

    /// Whether a display this plane was built for is still attached. A departed display's overlay
    /// fences its raise on a `CADisplayLink` for a screen that is gone, so waiting for it would stall
    /// that transition until the hold deadline; the report is made at once instead, which is honest —
    /// nothing is visible there to be covered. Not consulted for a dismissal: taking a cover down is
    /// always safe, and an overlay that was never raised completes immediately.
    public var isAttached: @MainActor (MonitorId) -> Bool = { _ in true }

    /// Bumped per display by every raise and every dismissal, so a report from a superseded one is
    /// dropped rather than counted against the current one. The same generation idiom `Overlay.fadeOut`
    /// uses.
    private var raiseGeneration: [MonitorId: Int] = [:]
    private var dismissGeneration: [MonitorId: Int] = [:]
    /// Displays whose raise still owes its report. A presentation fence can fire more than once, and a
    /// second `coverOnScreen` is a teleport the reducer has already made.
    private var fenceOwed: Set<MonitorId> = []

    public init(surfaces: [(monitor: MonitorId, surface: any CoverSurface)]) {
        self.surfaces = Dictionary(surfaces.map { ($0.monitor, $0.surface) },
                                   uniquingKeysWith: { first, _ in first })
    }

    /// One display's plane — the ordinary case, and what every test that does not care about the
    /// routing wants.
    public convenience init(monitor: MonitorId, surface: any CoverSurface) {
        self.init(surfaces: [(monitor, surface)])
    }

    /// Replace the plane's surfaces — hot-plug, and a display whose geometry changed under a rebuilt
    /// overlay. Two things go with a surface that leaves: its **routes**, so a `LayerId` minted on it
    /// stops naming anything, and its **generations**, bumped rather than dropped so a fence or a fade
    /// still in flight on the retired surface is answered as superseded rather than as current.
    ///
    /// The core has already closed every session by the time this is called (`State.setMonitors`), so
    /// no cover is in flight to be stranded — but a report can still be on its way.
    public func setSurfaces(_ surfaces: [(monitor: MonitorId, surface: any CoverSurface)]) {
        self.surfaces = Dictionary(surfaces.map { ($0.monitor, $0.surface) },
                                   uniquingKeysWith: { first, _ in first })
        let live = Set(self.surfaces.keys)
        route = route.filter { live.contains($0.value) }
        fenceOwed = fenceOwed.filter(live.contains)
        for monitor in raiseGeneration.keys where !live.contains(monitor) {
            raiseGeneration[monitor]? &+= 1
        }
        for monitor in dismissGeneration.keys where !live.contains(monitor) {
            dismissGeneration[monitor]? &+= 1
        }
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

    public func raiseCover(on monitor: MonitorId, _ bindings: [LayerBinding],
                           onScreen: @escaping @MainActor () -> Void) {
        let mine = (raiseGeneration[monitor] ?? 0) &+ 1
        raiseGeneration[monitor] = mine
        // A raise replaces whatever this display was showing, so its old layers stop being routable.
        route = route.filter { $0.value != monitor }
        bind(bindings, to: monitor)
        guard let surface = surfaces[monitor], isAttached(monitor) else {
            fenceOwed.remove(monitor)
            return onScreen()
        }
        fenceOwed.insert(monitor)
        surface.raiseCover(bindings) { [weak self] in
            guard let self, self.raiseGeneration[monitor] == mine,
                  self.fenceOwed.remove(monitor) != nil else { return }
            onScreen()
        }
    }

    public func extendCover(on monitor: MonitorId, _ bindings: [LayerBinding]) {
        bind(bindings, to: monitor)
        surfaces[monitor]?.extendCover(bindings)
    }

    public func setLayerFrame(_ layer: LayerId, to rect: Rect) {
        surface(of: layer)?.setLayerFrame(layer, to: rect)
    }

    public func refreshLayer(_ layer: LayerId) {
        surface(of: layer)?.refreshLayer(layer)
    }

    public func elevate(_ layer: LayerId) {
        surface(of: layer)?.elevate(layer)
    }

    public func dismiss(on monitor: MonitorId, over duration: TimeInterval,
                        completion: @escaping @MainActor () -> Void) {
        let mine = (dismissGeneration[monitor] ?? 0) &+ 1
        dismissGeneration[monitor] = mine
        route = route.filter { $0.value != monitor }
        guard let surface = surfaces[monitor] else { return completion() }
        surface.dismiss(over: duration) { [weak self] in
            guard let self, self.dismissGeneration[monitor] == mine else { return }
            completion()
        }
    }

    private func bind(_ bindings: [LayerBinding], to monitor: MonitorId) {
        for binding in bindings { route[binding.layer] = monitor }
    }

    private func surface(of layer: LayerId) -> (any CoverSurface)? {
        route[layer].flatMap { surfaces[$0] }
    }
}
