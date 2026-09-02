import AppKit
import EmiraCore

// The hoist plane: every `HoistPanel` on the desktop, and the diff that keeps them matching the core's
// answer. `Effect.setHoists` carries the whole set every time, so this file's whole job is the
// difference — film what is new, move what moved, restack, take down what left.
//
// **Nothing is gated on a film.** A hoist is not a cover: no raise waits for it, no window is held
// behind it, and the reducer counts nothing down. So the panel goes up at `alpha 0` the moment the core
// names it and becomes visible when its photograph lands — and a machine with no Screen Recording grant
// simply never sees one appear, which is the same degradation the cover ladder makes and ends in the
// same geometry.
//
// **A hoist is dropped on an AX report and comes down on the window server's answer.** The core drops
// the binding when `Event.focusChanged` says the float is in front, and that report says the app told
// us its focus moved — not that the raise has reached the glass. Cutting the picture away on it shows
// the window that is still in front for as long as the two are apart, which is the whole of the flash.
// So a released panel stops taking clicks, keeps its pixels, and asks `StackProbe` until the float is
// genuinely unobstructed; only then does it dissolve. The wait is bounded, and expiry dismisses anyway —
// a fence is a delay, not a veto, and a shell that kept a panel the core had dropped would be a second
// opinion about what is on the screen.
//
// **A photograph is taken when a float is buried and not again.** That instant is the freshest one
// available — the pixels are what the user was just looking at — and it is the only one that costs
// nothing to choose: a hoist that re-filmed on a timer would put a screenshot through the window
// server every few seconds for a window nobody is looking at, and one that mirrored the window live
// would hold a `SCStream` open and light the screen-recording indicator for as long as it floated. The
// price is that a hoisted float's content is frozen; a float that comes forward and goes back is filmed
// again, because it left the set and re-entered it.

/// Where `Effect.setHoists` goes. A protocol for `CoverPlane`'s reason: the daemon owns the AppKit
/// half, and `CompositingExecutor` routes to a seam a test can stand in for.
@MainActor
public protocol HoistPlane: AnyObject {
    /// Draw exactly these floats, bottom→top, and take down every hoist not named.
    func setHoists(_ bindings: [HoistBinding], feedback: EventSink)
}

/// One hoisted float's surface — `HoistPanel` is the real one. A protocol for `CoverSurface`'s reason:
/// the release fence above it is policy with races in it, and the window below it is AppKit.
@MainActor
public protocol HoistSurface: AnyObject {
    /// Where the real window is, in core coordinates — what the release fence asks about.
    var frame: Rect { get }
    /// Whether a photograph has arrived and the surface is on the screen.
    var isShown: Bool { get }
    /// What another surface orders itself against. `0` is the front of the level.
    var handle: Int { get }

    func place(at frame: Rect)
    func show(_ image: CGImage)
    func order(above handle: Int)
    /// The core has dropped this hoist: stop taking clicks, keep the pixels.
    func release()
    /// The float came back before the release finished: cancel the dissolve, take the clicks again.
    func reclaim()
    func dismiss(over duration: TimeInterval, completion: @escaping @MainActor () -> Void)
    func retire()
}

/// How a `HoistPanels` builds one. Injected so a test can hand it something that is not a window.
public typealias HoistSurfaceFactory =
    @MainActor (_ window: WindowId, _ frame: Rect, _ scale: CGFloat, _ geometry: ScreenGeometry,
                _ onClick: @escaping @MainActor (WindowId) -> Void) -> any HoistSurface

/// Every hoisted float's panel, keyed by the window it stands for.
@MainActor
public final class HoistPanels: HoistPlane {

    private let filmer: any SurfaceFilmer
    private let probe: any StackProbe
    private let scheduler: any DelayScheduler
    private let build: HoistSurfaceFactory
    private var panels: [WindowId: any HoistSurface] = [:]
    /// Panels the core has dropped that are still on the screen, waiting for the real window to come
    /// forward under them. Held apart from `panels` so a float re-hoisted mid-release reclaims its own
    /// panel rather than building a second one over it.
    private var releasing: [WindowId: any HoistSurface] = [:]
    /// Bumped per window by every release and every reclaim, so a fence answering late owns nothing.
    private var releaseGeneration: [WindowId: Int] = [:]
    /// The size each window's photograph was asked for — `SurfaceCache`'s freshness test, since a window
    /// that merely moved still shows the pixels it was filmed with. Written when a film is *requested*,
    /// so a second `setHoists` arriving mid-flight does not order a second photograph.
    private var pictured: [WindowId: Size] = [:]
    /// Bumped per window by every film, so one answering after the panel it was for came down (or after
    /// a newer film overtook it) owns nothing.
    private var filmGeneration: [WindowId: Int] = [:]

    /// The last set the core named, re-applied whenever the displays change under it — every panel is
    /// built against a `ScreenGeometry` and a backing scale, and the core has no reason to re-emit a set
    /// that did not change just because the screens did.
    private var current: [HoistBinding] = []

    private var geometry: ScreenGeometry
    /// Each display's backing scale, so a still is filmed and rasterized at native resolution.
    private var scales: [MonitorId: CGFloat] = [:]

    /// Where a click goes. Held rather than passed per call: a panel outlives the effect that built it.
    private var sink: EventSink?

    public init(filmer: any SurfaceFilmer, probe: any StackProbe, scheduler: any DelayScheduler,
                geometry: ScreenGeometry = ScreenGeometry(flipHeight: 0),
                grace: TimeInterval = HoistPanels.releaseGrace,
                build: @escaping HoistSurfaceFactory = HoistPanel.init) {
        self.filmer = filmer
        self.probe = probe
        self.scheduler = scheduler
        self.geometry = geometry
        self.grace = grace
        self.build = build
    }

    /// How long a release waits for the window server before dissolving regardless. Generous, because
    /// nothing is waiting on it — the panel it holds up is a pixel-identical copy of the window coming
    /// forward, so overshooting costs a stale title bar and undershooting costs the flash.
    public static let releaseGrace: TimeInterval = 0.5
    private let grace: TimeInterval

    /// How long between asks. The read is a window-server round trip and paces itself; this only keeps
    /// a server that answers instantly from turning the fence into a spin.
    private static let releaseInterval: TimeInterval = 1.0 / 120

    /// The displays changed: rebuild every panel against the new geometry and scales. Retired rather
    /// than adjusted, for `syncDisplays`' own reason — a panel is fixed at construction, so a display
    /// that changed resolution is as new as one just plugged in.
    public func setDisplays(geometry: ScreenGeometry, scales: [MonitorId: CGFloat]) {
        self.geometry = geometry
        self.scales = scales
        retireEvery()
        // The photographs are still good — a hoist's pixels are the window's own and no display's — but
        // the layers holding them went with the panels, so every one is re-shown from a fresh film.
        pictured.removeAll()
        apply(current)
    }

    public func setHoists(_ bindings: [HoistBinding], feedback: EventSink) {
        sink = feedback
        current = bindings
        apply(bindings)
    }

    /// Take every hoist off the screen — the daemon is quitting, and a picture of a window is the last
    /// thing a desktop being handed back should be holding.
    public func retireAll() {
        retireEvery()
        pictured.removeAll()
        current = []
    }

    /// Every panel off the screen at once, released ones included — a fence still out is answered by a
    /// generation that has moved on.
    private func retireEvery() {
        for panel in panels.values.map({ $0 }) + releasing.values.map({ $0 }) { panel.retire() }
        for id in panels.keys { releaseGeneration[id, default: 0] &+= 1 }
        for id in releasing.keys { releaseGeneration[id, default: 0] &+= 1 }
        panels.removeAll()
        releasing.removeAll()
    }

    private func apply(_ bindings: [HoistBinding]) {
        let wanted = Set(bindings.map(\.window))
        for (id, panel) in panels where !wanted.contains(id) {
            panels[id] = nil
            filmGeneration[id, default: 0] &+= 1     // a film still out belongs to nothing
            // The pixels stay up and `pictured` with them: the panel is still on the screen, and a
            // float that comes straight back must reclaim what it is already showing rather than film
            // a second copy of it.
            releasing[id] = panel
            panel.release()
            fenceRelease(id, panel)
        }

        // Bottom→top, which is both the order the array carries and the order the restack needs: each
        // panel is put directly above the one before it.
        var below: (any HoistSurface)?
        for binding in bindings {
            guard let panel = panel(for: binding) else { continue }
            panel.place(at: binding.frame)
            panel.order(above: below?.handle ?? 0)
            below = panel
            guard pictured[binding.window] != binding.frame.size else { continue }
            film(binding)
        }
    }

    /// The panel for a binding, built if this is the first time the core has named it. `nil` for a
    /// display that has left between the core deciding and this running — there is no scale to
    /// rasterize at, and guessing one is a soft hoist beside a sharp desktop.
    private func panel(for binding: HoistBinding) -> (any HoistSurface)? {
        if let existing = panels[binding.window] { return existing }
        // Back before the release finished — the float was buried again while its own picture was still
        // dissolving. Reclaiming it is what stops the two crossing over.
        if let returning = releasing.removeValue(forKey: binding.window) {
            releaseGeneration[binding.window, default: 0] &+= 1
            returning.reclaim()
            panels[binding.window] = returning
            return returning
        }
        guard let scale = scales[binding.monitor] else { return nil }
        let made = build(binding.window, binding.frame, scale, geometry) { [weak self] id in
            self?.sink?(.hoistClicked(id))
        }
        panels[binding.window] = made
        return made
    }

    /// Hold `panel` up until the window server stops showing anything over the float, then dissolve it.
    /// Re-asked rather than awaited: there is no notification for "the raise reached the glass". Bounded
    /// by `grace`, after which it comes down regardless — see the file header.
    private func fenceRelease(_ id: WindowId, _ panel: any HoistSurface) {
        releaseGeneration[id, default: 0] &+= 1
        ask(id, panel, until: Date().addingTimeInterval(grace),
            generation: releaseGeneration[id] ?? 0)
    }

    private func ask(_ id: WindowId, _ panel: any HoistSurface, until deadline: Date,
                     generation mine: Int) {
        probe.isCovered(id, within: panel.frame) { [weak self] covered in
            guard let self, self.releaseGeneration[id] == mine else { return }
            guard covered, Date() < deadline else { return self.dissolve(id, panel, generation: mine) }
            self.scheduler.schedule(after: Self.releaseInterval) { [weak self] in
                guard let self, self.releaseGeneration[id] == mine else { return }
                self.ask(id, panel, until: deadline, generation: mine)
            }
        }
    }

    private func dissolve(_ id: WindowId, _ panel: any HoistSurface, generation mine: Int) {
        panel.dismiss(over: HoistPanel.dismissDuration) { [weak self] in
            guard let self, self.releaseGeneration[id] == mine else { return }
            self.releasing[id] = nil
            self.pictured[id] = nil
        }
    }

    private func film(_ binding: HoistBinding) {
        let id = binding.window
        pictured[id] = binding.frame.size
        filmGeneration[id, default: 0] &+= 1
        let mine = filmGeneration[id] ?? 0
        filmer.film(id, on: binding.monitor) { [weak self] surface in
            guard let self, self.filmGeneration[id] == mine else { return }
            guard let surface else {
                // Nothing came back — no grant, a departed display, a window that closed. Forget the
                // request so the next `setHoists` asks again rather than standing on a photograph that
                // does not exist; the panel stays invisible and click-through until one does.
                self.pictured[id] = nil
                return
            }
            self.panels[id]?.show(surface.image)
        }
    }
}
