import AppKit
import EmiraCore

// The scrim plane: one `ScrimWindow` per display, the desktop photograph behind each, and the rule
// that decides which of the core's bindings the photograph is actually true for.
//
// **Two authorities, and each is asked only what it owns.** Which windows are see-through, and how far,
// is the core's (`ScrimBinding`). Where every window stands, and in what order, is the window server's —
// the only thing that knows about the dialog an app just put up or the Spotlight panel, and the only
// reading of emira's own windows taken at the same moment as those. The core sends a set once the moves
// it describes have landed, so that reading is of a desktop that has stopped (`Engine.settleScrims`).
//
// **The rule, stated once: a window is drawn see-through where what lies behind it is the desktop — or
// another window this set is also drawing see-through.** It falls out of one comparison against the
// window server's ordering, and it has three consequences:
//
//  · On the **strip** the first clause alone carries it, because `strip` promises windows never overlap
//    (`PRINCIPLES` §1). The whole feature rides on that promise, and is exact because of it.
//  · A **pin** is what the second clause is for. A pin stands beside the strip rather than over it, and
//    the strip is never clipped to fit, so a column scrolled far enough runs under the band — the one
//    overlap tiling produces. That column is see-through too, so the pin keeps its veil across it.
//  · Anything **opaque** behind declines: the focused window, a float over the tile you are working in,
//    a dialog or a panel emira never placed. That is where the photograph would stand wallpaper over a
//    window plainly in use, and the depth of the desktop would read inside out.
//
// **The second clause is the one approximation in the feature.** Behind a see-through window is the
// desktop *and* that window's own content at `1 − v`, and the photograph carries only the desktop — an
// error of `v(1 − v)·(desktop − window)`, spread smoothly across one photograph. Declining is not the
// exact alternative but the larger error: it leaves the front window's own pixels standing where that
// blend should be, and a step at the overlap's edge where the veil stops.
//
// A window *in front* is never a decline and costs nothing: those pixels are not on the screen, so it
// comes out of the shape whatever it is, and the painter's algorithm does the rest.
//
// **A pane the desktop is still showing and management has let go of is out of the walk entirely.** A
// window closes on the glass long after AX says it is gone, and nothing announces the moment it leaves —
// so it is skipped rather than subtracted, which is the mask the desktop is about to have.
//
// **The window server catches up in its own time, and says nothing when it does.** An app's move reaches
// it after the AX write that caused it has already landed — 8 to 42 ms later, measured — so the reading a
// mask was cut against goes stale under it with no event to hang a repaint on. A set is therefore painted
// at once and then cut again while the reading keeps changing, bounded by quiet and by a deadline
// (`settleQuiet`, `settleLimit`). It is `HoistPanels`' fence in another place: what the window server
// shows can only be found out by asking it. Cutting again costs a shape's path and nothing else, so a
// veil fading through it is undisturbed (`ScrimWindow`).
//
// **The photograph is refilmed when the desktop is quiet.** Never on a focus change: the window server
// serializes screenshots, and a focus change is also a cover, whose batch is the one latency in emira
// anybody can feel (`SCKCapturer`). So it is taken at build, when the screens change, when the Space
// does — and after a cover comes down, throttled, which is the moment the capture plane is idle and the
// desktop underneath may have changed.

/// Where `Effect.setScrims` goes. A protocol for `HoistPlane`'s reason: the daemon owns the AppKit
/// half, and `CompositingExecutor` routes to a seam a test can stand in for.
@MainActor
public protocol ScrimPlane: AnyObject {
    /// Draw exactly these windows see-through on `monitor`, against the window server as it stands now,
    /// and take the scrim off every one not named — dissolving or cutting as the core says. `moving`
    /// names the windows whose reported place the server may not have caught up with.
    func setScrims(_ bindings: [ScrimBinding], on monitor: MonitorId, change: ScrimChange,
                   moving: Set<WindowId>)
}

/// The plane on a machine that has none — no Screen Recording grant, or a test that does not care.
/// Accepting the set and drawing nothing is the same degradation the whole cover ladder makes:
/// placement is untouched and the desktop simply looks the way macOS drew it.
@MainActor
public final class NoScrims: ScrimPlane {
    public init() {}
    public func setScrims(_ bindings: [ScrimBinding], on monitor: MonitorId, change: ScrimChange,
                          moving: Set<WindowId>) {}
}

/// One on-screen window as the window server reports it, front to back.
public struct StackedWindow: Equatable, Sendable {
    public let number: CGWindowID
    /// Core (top-left, global) coordinates.
    public let frame: Rect

    public init(number: CGWindowID, frame: Rect) {
        self.number = number
        self.frame = frame
    }

    /// The ordinary windows on the desktop, front to back.
    ///
    /// `.optionOnScreenOnly` rather than `WindowListEntry`'s `.optionAll`, and the difference is the
    /// whole point: only the on-screen list is in **z-order**, which is the one fact this plane needs
    /// and the only public place it exists. Layer 0 alone — anything above it composites over the scrim
    /// anyway, and anything below it is the desktop the photograph already holds.
    public static func current() -> [StackedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return StackedWindow(number: number,
                                 frame: Rect(x: Double(rect.minX), y: Double(rect.minY),
                                             width: Double(rect.width), height: Double(rect.height)))
        }
    }
}

/// Films one display's desktop — every window taken out of it. A seam for `SurfaceFilmer`'s reason.
@MainActor
public protocol DesktopFilmer: AnyObject {
    /// Photograph `monitor`'s desktop under a Gaussian of `radius` points, or answer `nil` — no grant,
    /// a departed display, a failed shot. The blur is the film's because the backdrop is.
    func film(desktopOf monitor: MonitorId, blurredBy radius: Double,
              then: @escaping @MainActor (CGImage?) -> Void)
}

/// Every display's scrim, and the rule that keeps them matching the core's answer.
@MainActor
public final class Scrims: ScrimPlane {

    /// How long a display's photograph stands before a quiet moment is allowed to replace it. The
    /// desktop under the windows is wallpaper, icons and widgets: it changes, but never urgently, and
    /// a re-film is a full-screen capture we are unwilling to spend at any rate the eye would notice.
    static let desktopMaxAge: TimeInterval = 2

    /// How often the window server is re-read while it catches up with a set, how many readings with
    /// nothing new in them end that, and how long it may go on regardless. `WorldWatcher.beginSettle`'s
    /// shape: quiet ends the wait, and a cap ends it whatever happens.
    static let settleInterval: TimeInterval = 1.0 / 60
    static let settleQuiet = 4
    static let settleLimit: TimeInterval = 0.4

    /// A window's corner rounding, in points, until a capture has measured it. A guess, and it goes stale
    /// with the next macOS: what it costs is a corner-sized triangle of the window's shadow lightened by
    /// the veil, or of the window left unveiled.
    static let fallbackCornerRadius: Double = 12

    private let build: @MainActor (Rect, CGFloat, ScreenGeometry) -> any ScrimSurface
    private let filmer: any DesktopFilmer
    /// Window number → the id the core knows it by, or `nil` for a window emira never adopted.
    private let identify: @MainActor (CGWindowID) -> WindowId?
    /// The numbers management has let go of that the glass may still be showing
    /// (`WindowRegistry.departedNumbers`) — a hole to the mask, as they are to a cover's base.
    private let departed: @MainActor () -> Set<CGWindowID>
    /// A window's corner radius as a capture last measured it, or `nil` for one never filmed
    /// (`SurfaceCache.cornerRadius(of:)`). A scrim films no window, so it asks the plane that does.
    private let cornerRadius: @MainActor (WindowId) -> Double?
    /// The window server's own ordering. Injected so the rule can be tested without a desktop.
    private let stack: @MainActor () -> [StackedWindow]
    /// The flip between core and Cocoa coordinates — the shapes are built in each surface's own space.
    private var geometry = ScreenGeometry(flipHeight: 0)
    /// What the settling re-reads are scheduled on.
    private let scheduler: any DelayScheduler

    private var surfaces: [MonitorId: any ScrimSurface] = [:]
    private var frames: [MonitorId: Rect] = [:]
    private var filmedAt: [MonitorId: Date] = [:]
    /// The photograph each display's scrim is drawing, kept for the cover (`backdrop(of:)`).
    private var photographs: [MonitorId: CGImage] = [:]
    /// Bumped per display by every film, so one answering after its surface was rebuilt owns nothing.
    private var filmGeneration: [MonitorId: Int] = [:]

    /// How far the photographs are blurred, in points — `[focus] unfocused-blur`, read out here for
    /// `Reconstruction.motionBlur`'s reason: the core emits the same bindings under every setting of
    /// it. Held by the plane rather than the filmer, because the plane is what a change makes stale.
    private var blur: Double = 0

    /// The last set the core named per display, re-applied whenever the displays change under it — a
    /// surface is built against one screen, and the core has no reason to re-emit a set that did not
    /// change just because the screens did. `HoistPanels.current`'s reason.
    private var current: [MonitorId: [ScrimBinding]] = [:]

    /// The veil each window is **actually being drawn at**, by display — the core's intent with the
    /// window server's answer folded in. A window on no display's scrim is absent; one the scrim declined
    /// in part still carries its veil, for `veil(of:)`'s reason. Kept because a second plane reads it.
    private var applied: [MonitorId: [WindowId: Double]] = [:]

    /// What each display's mask is actually drawing, so a re-read that finds nothing new paints nothing.
    private var painted: [MonitorId: [ScrimVeil]] = [:]
    /// Bumped per display by every set, so a settling re-read from an older one owns nothing.
    private var settleGeneration: [MonitorId: Int] = [:]

    /// Each window the core named `moving`, at the frame the window server was still reporting for it
    /// when it was named — dropped the moment that reading changes, which is the server catching up.
    /// A pane standing at its stale frame declines nothing: it is not where the mask would put it.
    private var stale: [MonitorId: [WindowId: Rect]] = [:]
    /// What the last set named as moving, until the next reading records their frames.
    private var naming: [MonitorId: Set<WindowId>] = [:]

    public init(filmer: any DesktopFilmer,
                identify: @escaping @MainActor (CGWindowID) -> WindowId?,
                departed: @escaping @MainActor () -> Set<CGWindowID> = { [] },
                cornerRadius: @escaping @MainActor (WindowId) -> Double? = { _ in nil },
                stack: @escaping @MainActor () -> [StackedWindow] = StackedWindow.current,
                scheduler: any DelayScheduler = DispatchScheduler(),
                build: @escaping @MainActor (Rect, CGFloat, ScreenGeometry) -> any ScrimSurface
                    = { ScrimWindow(display: $0, scale: $1, geometry: $2) }) {
        self.scheduler = scheduler
        self.filmer = filmer
        self.identify = identify
        self.departed = departed
        self.cornerRadius = cornerRadius
        self.stack = stack
        self.build = build
    }

    /// Rebuild against the attached displays. Surfaces are replaced rather than adjusted, for
    /// `HoistPanels.setDisplays`' reason: one is fixed to a screen at construction, so a display that
    /// changed resolution is as new as one just plugged in.
    public func setDisplays(_ displays: [(monitor: MonitorId, frame: Rect, scale: CGFloat)],
                            geometry: ScreenGeometry) {
        retireAll()
        self.geometry = geometry
        for display in displays {
            surfaces[display.monitor] = build(display.frame, display.scale, geometry)
            frames[display.monitor] = display.frame
            if wantsPhotograph(display.monitor) { refilm(display.monitor) }
            // A new surface holds no mask, so there is nothing for its set to dissolve from.
            apply(current[display.monitor] ?? [], on: display.monitor, change: .cut)
        }
    }

    public func setScrims(_ bindings: [ScrimBinding], on monitor: MonitorId, change: ScrimChange,
                          moving: Set<WindowId>) {
        current[monitor] = bindings
        naming[monitor] = moving
        // The first set on a display is what makes its photograph worth taking, and it is applied
        // against one that is still coming: a surface with no desktop cuts its shapes and stays off the
        // glass until `setDesktop` gives it one, so the film lands behind a mask already in place.
        if photographs[monitor] == nil, !bindings.isEmpty { refilmIfStale(monitor) }
        apply(bindings, on: monitor, change: change)
    }

    /// Blur every photograph this far, in points. The blur is baked into the film (`DesktopCapturer`),
    /// so a new radius is a standing photograph gone stale — refilmed at once and not on the throttle,
    /// which paces a desktop that may have changed rather than one we know is wrong.
    public func setBlur(_ radius: Double) {
        guard radius != blur else { return }
        blur = radius
        for monitor in surfaces.keys where wantsPhotograph(monitor) { refilm(monitor) }
    }

    /// Take every scrim off the screen — the daemon is quitting, or the displays are being rebuilt.
    public func retireAll() {
        for (monitor, surface) in surfaces {
            surface.retire()
            filmGeneration[monitor, default: 0] &+= 1
        }
        surfaces.removeAll()
        frames.removeAll()
        filmedAt.removeAll()
        photographs.removeAll()
        // A surface that has gone is drawing nothing, whatever it was drawing a moment ago.
        applied.removeAll()
        painted.removeAll()
        stale.removeAll()
        naming.removeAll()
    }

    /// Cut every mask against the window server again: the reading one was cut against has moved with
    /// nothing in the core to say so — a window emira never placed has left the glass or arrived on it
    /// (`WorldWatcher.onStackChanged`). A cut that comes out the same paints nothing.
    public func recut() {
        for monitor in surfaces.keys.sorted() where current[monitor]?.isEmpty == false {
            paint(monitor, change: .cut)
        }
    }

    /// The desktop may have changed and the capture plane is idle — the moment a cover comes down, a
    /// Space switch, a display change. Throttled by `desktopMaxAge`, so a burst of transitions costs
    /// one photograph rather than one each.
    public func desktopMayHaveChanged() {
        for monitor in surfaces.keys where wantsPhotograph(monitor) { refilmIfStale(monitor) }
    }

    /// Whether `monitor`'s desktop is worth photographing at all. A film is a full-screen capture, and
    /// until the core names a window to veil there is nothing for the photograph to be the backdrop
    /// *of* — not on this plane, and not on the cover's, whose stand-ins draw their veils through the
    /// same one (`backdrop(of:)`). So the setting left off costs no capture rather than one every
    /// `desktopMaxAge` for a picture nobody reads, and no cover carries a veil layer it draws at zero.
    ///
    /// **Sticky once taken**, because an empty set is not only the setting going off: the core empties
    /// one for the length of a drag, and a hand putting a window down has to find the backdrop standing
    /// rather than wait out a capture. What that leaves behind is one photograph per display held until
    /// the daemon restarts by somebody who turned the setting off mid-session — never refreshed, since
    /// nothing asks for it again.
    private func wantsPhotograph(_ monitor: MonitorId) -> Bool {
        current[monitor]?.isEmpty == false || photographs[monitor] != nil
    }

    /// Refilm unless the standing photograph is younger than `desktopMaxAge`. The throttle paces a
    /// desktop that may merely have changed; `setBlur` and a rebuilt surface go around it, since what
    /// those hold is a photograph known to be wrong rather than one suspected of being stale.
    private func refilmIfStale(_ monitor: MonitorId) {
        guard Date().timeIntervalSince(filmedAt[monitor] ?? .distantPast) >= Self.desktopMaxAge else {
            return
        }
        refilm(monitor)
    }

    private func refilm(_ monitor: MonitorId) {
        // A display with no surface has no scrim to back, and `setScrims` can name one before the
        // screens it is on have been built.
        guard surfaces[monitor] != nil else { return }
        filmedAt[monitor] = Date()
        filmGeneration[monitor, default: 0] &+= 1
        let mine = filmGeneration[monitor] ?? 0
        filmer.film(desktopOf: monitor, blurredBy: blur) { [weak self] image in
            guard let self, self.filmGeneration[monitor] == mine else { return }
            // A film that failed leaves the standing photograph alone: an old desktop is a better
            // backdrop than none, and `nil` here would take every scrim on that display down. The
            // attempt still stands against the throttle, or a desktop that declines to be filmed at
            // all — no Screen Recording grant — is asked again at every cover and every set.
            guard let image else { return }
            self.photographs[monitor] = image
            self.surfaces[monitor]?.setDesktop(image)
        }
    }

    /// What the desktop is drawing `window` at, or `0` for an opaque one. Read by the cover, so the two
    /// planes keep one decision — and reported for the whole window even where the scrim declined part.
    public func veil(of window: WindowId) -> Double {
        applied.keys.sorted().compactMap { applied[$0]?[window] }.first ?? 0
    }

    /// The photograph `monitor`'s scrim draws through, already frosted and shaded — what a cover's
    /// stand-ins draw their veil from, so the two planes show one backdrop. `nil` before the first film.
    public func backdrop(of monitor: MonitorId) -> CGImage? { photographs[monitor] }

    private func apply(_ bindings: [ScrimBinding], on monitor: MonitorId, change: ScrimChange) {
        paint(monitor, change: change)
        guard !bindings.isEmpty else { return }
        watch(monitor)
    }

    /// Cut `monitor`'s mask against the window server as it stands now, for the set the core last named.
    /// Answers whether what the surface draws changed, which is what tells a settling desktop from a
    /// settled one.
    @discardableResult
    private func paint(_ monitor: MonitorId, change: ScrimChange) -> Bool {
        guard let surface = surfaces[monitor], let display = frames[monitor] else { return false }
        let bindings = current[monitor] ?? []
        // A set that draws nothing needs no stacking: there is no mask to cut against it.
        guard !bindings.isEmpty else {
            applied[monitor] = [:]
            // Nothing is cut, so nothing is waiting on a reading.
            stale[monitor] = nil
            naming[monitor] = nil
            guard painted[monitor]?.isEmpty == false else { return false }
            painted[monitor] = []
            surface.setVeils([], change: change)
            return true
        }
        // **A window management has let go of takes nothing out of anything.** Nothing announces the
        // moment its pixels leave the glass, so the mask that ignores it is the one that stays right.
        // **A window management has let go of takes nothing out of anything.** Nothing announces the
        // moment its pixels leave the glass, so the mask that ignores it is the one that stays right.
        let gone = departed()
        let identified = stack()
            .filter { !gone.contains($0.number) }
            .map { (window: identify($0.number), pane: $0) }
        let cut = Self.veils(for: bindings, over: identified, on: display, geometry: geometry,
                             cornerRadius: cornerRadius, stale: staleFrames(monitor, in: identified))
        var drawn: [WindowId: Double] = [:]
        for (window, veil) in cut.drawn where veil > 0 { drawn[window] = veil }
        applied[monitor] = drawn
        guard cut.veils != painted[monitor] else { return false }
        painted[monitor] = cut.veils
        surface.setVeils(cut.veils, change: change)
        return true
    }

    /// Where each named-moving window still stands, for this reading: recorded at the frame it was first
    /// read at after being named, and dropped once that reading changes — the only evidence available
    /// that the server has caught up. A name is consumed by the cut that records it, never held.
    private func staleFrames(_ monitor: MonitorId,
                             in identified: [(window: WindowId?, pane: StackedWindow)])
        -> [WindowId: Rect] {
        var here: [WindowId: Rect] = [:]
        for entry in identified { if let id = entry.window { here[id] = entry.pane.frame } }

        var pending = stale[monitor] ?? [:]
        // A window the reading has moved is where it says it is; one that has left the glass is nobody's.
        for (id, frame) in pending where here[id] != frame { pending[id] = nil }
        // Named once and recorded once: a window read at a new frame has arrived, and re-recording it
        // from a name the core has not withdrawn would suspend it again where it now stands for good.
        for id in naming[monitor] ?? [] where pending[id] == nil {
            if let frame = here[id] { pending[id] = frame }
        }
        naming[monitor] = nil
        stale[monitor] = pending.isEmpty ? nil : pending
        return pending
    }

    /// Watch the window server catch up with the moves this set describes, and cut the mask again each
    /// time it does. Every re-cut is a `cut`: the veils are the ones already on the glass, and only the
    /// rectangles under them are moving.
    private func watch(_ monitor: MonitorId) {
        settleGeneration[monitor, default: 0] &+= 1
        let mine = settleGeneration[monitor] ?? 0
        let deadline = Date().addingTimeInterval(Self.settleLimit)
        func again(_ quiet: Int) {
            // A reading that has stopped changing is the server caught up, and a deadline is the answer
            // to a write it will never show. Either way nothing is waited on any longer, so a window
            // still standing where it was named is standing there for good and declines again.
            guard quiet < Self.settleQuiet, Date() < deadline else {
                guard stale[monitor] != nil else { return }
                stale[monitor] = nil
                paint(monitor, change: .cut)
                return
            }
            scheduler.schedule(after: Self.settleInterval) { [weak self] in
                guard let self, settleGeneration[monitor] == mine else { return }
                again(paint(monitor, change: .cut) ? 0 : quiet + 1)
            }
        }
        again(0)
    }

    /// The shape the desktop shows through for each see-through window on `display`, bottom→top, and what
    /// each is drawn at. The only place the rule lives: **a window is see-through where the desktop is
    /// behind it, or another this set draws see-through**. `stale` is where a moving pane was last read.
    static func veils(for bindings: [ScrimBinding],
                      over stacked: [(window: WindowId?, pane: StackedWindow)],
                      on display: Rect,
                      geometry: ScreenGeometry,
                      cornerRadius: @MainActor (WindowId) -> Double? = { _ in nil },
                      stale: [WindowId: Rect] = [:])
        -> (veils: [ScrimVeil], drawn: [(WindowId, Double)]) {
        let wanted = Dictionary(bindings.map { ($0.window, $0.veil) }, uniquingKeysWith: { a, _ in a })
        func radius(_ id: WindowId?) -> Double { id.flatMap(cornerRadius) ?? fallbackCornerRadius }
        let surface = geometry.cocoa(display)
        /// A window's outline in the surface's own coordinates. Outside a rounded corner is whatever the
        /// window stands on, so a square silhouette would veil a shadow or clear a corner of its neighbour.
        func silhouette(_ frame: Rect, _ id: WindowId?) -> CGPath {
            let box = geometry.local(frame, in: surface)
            let corner = radius(id)
            guard corner > 0 else { return CGPath(rect: box, transform: nil) }
            return CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil)
        }

        // Front to back, which is the order the sheet rule is decided in: "is anything behind me" is a
        // question about the tail. A sheet is left out rather than subtracted, so its window's veil
        // carries it — the photograph standing in for the window behind the sheet is the same one.
        let here = stacked.filter { $0.pane.frame.intersects(display) }
        let panes = here.enumerated().filter { index, entry in
            guard entry.window == nil,
                  let beneath = here[(index + 1)...].first(where: {
                      $0.pane.frame.intersects(entry.pane.frame)
                  })
            else { return true }
            let isSheet = beneath.window.flatMap { wanted[$0] } != nil
                && beneath.pane.frame.intersection(entry.pane.frame) == entry.pane.frame
            return !isSheet
        }.map { (id: $0.element.window, frame: $0.element.pane.frame) }

        let shapes = panes.map { silhouette($0.frame, $0.id) }

        /// Whether the pane at `other` comes out of the pane at `index`'s shape. `panes` runs front to
        /// back, so a lower index is in front — and in front always comes out, those pixels not being
        /// this window's. Behind, only an opaque pane does — and only one the server has caught up with,
        /// a decline being a claim about what is behind a window rather than about what has left.
        func cuts(_ other: Int, from index: Int) -> Bool {
            guard panes[other].frame.intersects(panes[index].frame) else { return false }
            if other < index { return true }
            guard let id = panes[other].id else { return true }
            return wanted[id] == nil && stale[id] != panes[other].frame
        }

        var veils: [ScrimVeil] = []
        var drawn: [(WindowId, Double)] = []
        for (index, pane) in panes.enumerated() {
            guard let id = pane.id, let veil = wanted[id] else { continue }
            var shape = shapes[index]
            for other in panes.indices where other != index && cuts(other, from: index) {
                shape = shape.subtracting(shapes[other])
            }
            veils.append(ScrimVeil(window: id, shape: shape, veil: veil))
            drawn.append((id, veil))
        }
        // Bottom→top, the convention every binding array carries. Nothing overlaps, so it decides
        // nothing about the drawing; it decides what a reader of this list expects.
        return (veils.reversed(), drawn)
    }
}
