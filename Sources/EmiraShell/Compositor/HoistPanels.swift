import AppKit
import EmiraCore

// The hoist plane: every `HoistPanel` on the desktop, and the diff that keeps them matching the core's
// answer. `Effect.setHoists` carries the whole set every time, so this file's whole job is the
// difference — build and film what is new, move what moved, restack, reveal and conceal, and take down
// what left.
//
// **A panel exists for every on-screen float, not only the covered ones.** `HoistState.standby` is a
// panel built, filmed and invisible, so the burial that follows is `reveal()` — an alpha flip on a
// window that is already ordered in. Minting it at the moment of burial instead would be late by one
// screenshot, which is long enough to watch the float go behind and come back.
//
// **A hoist is decided on an AX report and comes down on the window server's answer.** The core stops
// covering a float when `Event.focusChanged` says it is in front, and that report says the app told us
// its focus moved — not that the raise has reached the glass. Concealing on it shows the window that is
// still in front for as long as the two are apart, which is the whole of the flash on the way out. So a
// released panel stops taking clicks, keeps its pixels, and asks `StackProbe` until the float is
// genuinely unobstructed; only then does it fade. The wait is bounded, and expiry conceals anyway — a
// fence is a delay, not a veto, and a shell that kept a picture the core had dropped would be a second
// opinion about what is on the screen.
//
// **Two photographs, and the second is the honest one.** A standby still is filmed while the float is in
// the open, so it carries the window's focused styling and whatever it looked like before the user's
// last interaction; the burial film that follows is what the desktop actually just showed. The reveal
// paints the first and cross-fades to the second, which is `CoverMode.immediate`'s trade in another
// place — a stand-in buys the instant, and its own capture overtakes it. Neither is live: a hoisted
// float's content is frozen, because the alternatives are a screenshot on a timer for a window nobody
// is looking at, or an `SCStream` holding the screen-recording indicator lit for as long as it floats.

/// Where `Effect.setHoists` goes. A protocol for `CoverPlane`'s reason: the daemon owns the AppKit
/// half, and `CompositingExecutor` routes to a seam a test can stand in for.
@MainActor
public protocol HoistPlane: AnyObject {
    /// Stand in for exactly these floats, bottom→top, and take down every one not named.
    func setHoists(_ bindings: [HoistBinding], feedback: EventSink)
}

/// One float's surface — `HoistPanel` is the real one. A protocol for `CoverSurface`'s reason: the
/// reveal/conceal policy above it has races in it, and the window below it is AppKit.
@MainActor
public protocol HoistSurface: AnyObject {
    /// Where the real window is, in core coordinates — what the release fence asks about.
    var frame: Rect { get }
    /// Whether the picture is on the screen and taking clicks.
    var isRevealed: Bool { get }
    /// What another surface orders itself against. `0` is the front of the level.
    var handle: Int { get }

    func place(at frame: Rect)
    /// Load the pixels, paying a reveal that was owed and cross-fading over one already showing.
    func setImage(_ image: CGImage)
    /// Show it and take clicks — instant where the pixels are loaded, owed where they are not.
    func reveal()
    /// Stop taking clicks. The picture stays until `conceal`.
    func release()
    /// Fade the picture out and stand by; the surface and its pixels stay.
    func conceal(over duration: TimeInterval, completion: @escaping @MainActor () -> Void)
    func order(above handle: Int)
    func retire()
}

/// How a `HoistPanels` builds one. Injected so a test can hand it something that is not a window.
public typealias HoistSurfaceFactory =
    @MainActor (_ window: WindowId, _ frame: Rect, _ scale: CGFloat, _ geometry: ScreenGeometry,
                _ onClick: @escaping @MainActor (WindowId) -> Void) -> any HoistSurface

/// Every float's panel, keyed by the window it stands for.
@MainActor
public final class HoistPanels: HoistPlane {

    private let filmer: any SurfaceFilmer
    private let probe: any StackProbe
    private let scheduler: any DelayScheduler
    private let build: HoistSurfaceFactory
    private var panels: [WindowId: any HoistSurface] = [:]
    /// The size each window's photograph was asked for — `SurfaceCache`'s freshness test, since a window
    /// that merely moved still shows the pixels it was filmed with. Written when a film is *requested*,
    /// so a second `setHoists` arriving mid-flight does not order a second photograph.
    private var pictured: [WindowId: Size] = [:]
    /// Bumped per window by every film, so one answering after its panel came down owns nothing.
    private var filmGeneration: [WindowId: Int] = [:]
    /// Bumped per window by every reveal and every conceal, so a fence answering late owns nothing.
    private var fenceGeneration: [WindowId: Int] = [:]

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

    /// How long a release waits for the window server before concealing regardless. Generous, because
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

    /// Take every panel off the screen — the daemon is quitting, and a picture of a window is the last
    /// thing a desktop being handed back should be holding.
    public func retireAll() {
        retireEvery()
        pictured.removeAll()
        current = []
    }

    private func retireEvery() {
        for (id, panel) in panels.merging(retiring, uniquingKeysWith: { held, _ in held }) {
            panel.retire()
            fenceGeneration[id, default: 0] &+= 1
            filmGeneration[id, default: 0] &+= 1
        }
        panels.removeAll()
        retiring.removeAll()
    }

    private func apply(_ bindings: [HoistBinding]) {
        let wanted = Set(bindings.map(\.window))
        for (id, panel) in panels where !wanted.contains(id) {
            // The float has gone off the screen, stopped floating, or closed. A picture of it stays only
            // as long as it takes the window server to agree there is nothing over it — after which
            // there is nothing left for it to stand in for. State first: a probe may answer at once.
            panels[id] = nil
            filmGeneration[id, default: 0] &+= 1
            retiring[id] = panel
            panel.release()
            fence(id, panel) { [weak self] in
                panel.retire()
                self?.retiring[id] = nil
                self?.pictured[id] = nil
            }
        }

        // Bottom→top, which is both the order the array carries and the order the restack needs: each
        // panel is put directly above the one before it.
        var below: (any HoistSurface)?
        for binding in bindings {
            guard let panel = panel(for: binding) else { continue }
            panel.place(at: binding.frame)
            panel.order(above: below?.handle ?? 0)
            below = panel
            if pictured[binding.window] != binding.frame.size { film(binding) }
            switch binding.state {
            case .covered:
                // Instant where a standby still is already loaded, which is the point of standby. The
                // burial's own film overtakes it when it lands (`film`).
                fenceGeneration[binding.window, default: 0] &+= 1
                panel.reveal()
            case .standby:
                guard panel.isRevealed else { continue }
                panel.release()
                fence(binding.window, panel) { panel.conceal(over: HoistPanel.concealDuration) {} }
            }
        }
    }

    /// Panels the core has dropped that are still fading. Held only so `retireAll` and `setDisplays`
    /// can reach them; nothing else reads it.
    private var retiring: [WindowId: any HoistSurface] = [:]

    /// The panel for a binding, built if this is the first time the core has named it — or reclaimed
    /// from a teardown that has not finished, which is a float that left and came straight back.
    private func panel(for binding: HoistBinding) -> (any HoistSurface)? {
        if let existing = panels[binding.window] { return existing }
        if let returning = retiring.removeValue(forKey: binding.window) {
            fenceGeneration[binding.window, default: 0] &+= 1
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

    /// Run `then` once the window server stops showing anything over the float. Re-asked rather than
    /// awaited: there is no notification for "the raise reached the glass". Bounded by `grace`, after
    /// which it runs regardless — see the file header.
    private func fence(_ id: WindowId, _ panel: any HoistSurface,
                       then: @escaping @MainActor () -> Void) {
        fenceGeneration[id, default: 0] &+= 1
        ask(id, panel, until: Date().addingTimeInterval(grace),
            generation: fenceGeneration[id] ?? 0, then: then)
    }

    private func ask(_ id: WindowId, _ panel: any HoistSurface, until deadline: Date,
                     generation mine: Int, then: @escaping @MainActor () -> Void) {
        probe.isCovered(id, within: panel.frame) { [weak self] covered in
            guard let self, self.fenceGeneration[id] == mine else { return }
            guard covered, Date() < deadline else { return then() }
            self.scheduler.schedule(after: Self.releaseInterval) { [weak self] in
                guard let self, self.fenceGeneration[id] == mine else { return }
                self.ask(id, panel, until: deadline, generation: mine, then: then)
            }
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
                // does not exist; the panel shows nothing and takes no clicks until one does.
                self.pictured[id] = nil
                return
            }
            self.panels[id]?.setImage(surface.image)
        }
    }
}
