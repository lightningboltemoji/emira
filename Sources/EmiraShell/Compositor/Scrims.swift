import AppKit
import EmiraCore

// The scrim plane: one `ScrimWindow` per display, the desktop photograph behind each, and the rule
// that decides which of the core's bindings the photograph is actually true for.
//
// **Two authorities, and each is asked only what it owns.** Where emira's own windows are is the core's
// (`ScrimBinding.frame` is AX-observed truth, folded into `World`). What *else* is on the screen, and in
// what order, is the window server's — it is the only thing that knows about the dialog an app just put
// up, the Spotlight panel, or anything else emira never placed. Mixing them is not a second opinion; it
// is the one question each can answer.
//
// **The rule, stated once: a window is drawn see-through only where the desktop is what lies behind it.**
// It falls out of one comparison against the window server's ordering, and it has three consequences
// that are really the same consequence:
//
//  · On the **strip** it is always satisfied, because `strip` promises windows never overlap
//    (`PRINCIPLES` §1). The whole feature rides on that promise, and is exact because of it.
//  · A **float** over a tile declines — the tile is behind it, and the photograph does not hold the
//    tile. So does a tile with anything at all under it.
//  · A **cascade** declines almost everywhere, which is the honest answer: a `stack` tile is backed by
//    another tile, and standing in for that needs a photograph per window, refilmed whenever anything
//    behind anything redraws. See `Scrims.swift` in the core for why that price is not paid.
//
// A window *in front* is a different matter and costs nothing: those pixels are not on the screen, so
// the mask simply paints it opaque afterwards and the painter's algorithm does the rest.
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
    /// Draw exactly these windows see-through, and take the scrim off every one not named.
    func setScrims(_ bindings: [ScrimBinding])
    /// Read the window server again and repaint, against the set last named. See `Scrims.restack`.
    func restack()
}

/// The plane on a machine that has none — no Screen Recording grant, or a test that does not care.
/// Accepting the set and drawing nothing is the same degradation the whole cover ladder makes:
/// placement is untouched and the desktop simply looks the way macOS drew it.
@MainActor
public final class NoScrims: ScrimPlane {
    public init() {}
    public func setScrims(_ bindings: [ScrimBinding]) {}
    public func restack() {}
}

/// One on-screen window as the window server reports it, front to back.
public struct StackedWindow: Equatable, Sendable {
    public let number: CGWindowID
    /// Core (top-left, global) coordinates — the space `ScrimBinding.frame` is already in.
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

    /// A window's corner rounding, in points. `Reconstruction.fallbackCornerRadius`'s value and its
    /// caveat — a guessed radius goes stale with the next macOS — but a standing scrim has no capture
    /// to measure one off, and what it costs is a corner-sized triangle of the window's own shadow
    /// lightened by the veil.
    static let cornerRadius: Double = 12

    private let build: @MainActor (Rect, CGFloat, ScreenGeometry) -> any ScrimSurface
    private let filmer: any DesktopFilmer
    /// Window number → the id the core knows it by, or `nil` for a window emira never adopted.
    private let identify: @MainActor (CGWindowID) -> WindowId?
    /// The window server's own ordering. Injected so the rule can be tested without a desktop.
    private let stack: @MainActor () -> [StackedWindow]

    private var surfaces: [MonitorId: any ScrimSurface] = [:]
    private var frames: [MonitorId: Rect] = [:]
    private var filmedAt: [MonitorId: Date] = [:]
    /// Bumped per display by every film, so one answering after its surface was rebuilt owns nothing.
    private var filmGeneration: [MonitorId: Int] = [:]

    /// How far the photographs are blurred, in points — `[focus] unfocused-blur`, read out here for
    /// `Reconstruction.motionBlur`'s reason: the core emits the same bindings under every setting of
    /// it. Held by the plane rather than the filmer, because the plane is what a change makes stale.
    private var blur: Double = 0

    /// The last set the core named, re-applied whenever the displays change under it — a surface is
    /// built against one screen, and the core has no reason to re-emit a set that did not change just
    /// because the screens did. `HoistPanels.current`'s reason.
    private var current: [ScrimBinding] = []

    /// The veil each window is **actually being drawn at** — the core's intent with the window server's
    /// answer folded in. A window on no display's scrim is absent; one the scrim declined in part still
    /// carries its veil, for `veil(of:)`'s reason. Kept because a second plane reads it: `veil(of:)`.
    private var applied: [WindowId: Double] = [:]

    /// The same, split by display and kept from the last apply — what tells an **event** from a
    /// **correction**. A veil that moved is something the user did and fades; a rectangle that moved
    /// under unchanged veils is us catching up with the window server, and cuts.
    private var drawn: [MonitorId: [WindowId: Double]] = [:]

    public init(filmer: any DesktopFilmer,
                identify: @escaping @MainActor (CGWindowID) -> WindowId?,
                stack: @escaping @MainActor () -> [StackedWindow] = StackedWindow.current,
                build: @escaping @MainActor (Rect, CGFloat, ScreenGeometry) -> any ScrimSurface
                    = { ScrimWindow(display: $0, scale: $1, geometry: $2) }) {
        self.filmer = filmer
        self.identify = identify
        self.stack = stack
        self.build = build
    }

    /// Rebuild against the attached displays. Surfaces are replaced rather than adjusted, for
    /// `HoistPanels.setDisplays`' reason: one is fixed to a screen at construction, so a display that
    /// changed resolution is as new as one just plugged in.
    public func setDisplays(_ displays: [(monitor: MonitorId, frame: Rect, scale: CGFloat)],
                            geometry: ScreenGeometry) {
        retireAll()
        for display in displays {
            surfaces[display.monitor] = build(display.frame, display.scale, geometry)
            frames[display.monitor] = display.frame
            refilm(display.monitor)
        }
        apply(current)
    }

    public func setScrims(_ bindings: [ScrimBinding]) {
        current = bindings
        apply(bindings)
    }

    /// Blur every photograph this far, in points. The blur is baked into the film (`DesktopCapturer`),
    /// so a new radius is a standing photograph gone stale — refilmed at once and not on the throttle,
    /// which paces a desktop that may have changed rather than one we know is wrong.
    public func setBlur(_ radius: Double) {
        guard radius != blur else { return }
        blur = radius
        for monitor in surfaces.keys { refilm(monitor) }
    }

    /// Re-read the window server and repaint, against the set the core last named. **The mask has two
    /// inputs and only one of them arrives as an effect**: the stacking a set is masked against moves
    /// on its own, so without this the mask holds whatever the desktop was when the set arrived.
    public func restack() { apply(current) }

    /// Take every scrim off the screen — the daemon is quitting, or the displays are being rebuilt.
    public func retireAll() {
        for (monitor, surface) in surfaces {
            surface.retire()
            filmGeneration[monitor, default: 0] &+= 1
        }
        surfaces.removeAll()
        frames.removeAll()
        filmedAt.removeAll()
        // A surface that has gone took its mask with it, so the next one has nothing to dissolve from.
        drawn.removeAll()
    }

    /// The desktop may have changed and the capture plane is idle — the moment a cover comes down, a
    /// Space switch, a display change. Throttled by `desktopMaxAge`, so a burst of transitions costs
    /// one photograph rather than one each.
    public func desktopMayHaveChanged() {
        let now = Date()
        for monitor in surfaces.keys {
            guard now.timeIntervalSince(filmedAt[monitor] ?? .distantPast) >= Self.desktopMaxAge else {
                continue
            }
            refilm(monitor)
        }
    }

    private func refilm(_ monitor: MonitorId) {
        filmedAt[monitor] = Date()
        filmGeneration[monitor, default: 0] &+= 1
        let mine = filmGeneration[monitor] ?? 0
        filmer.film(desktopOf: monitor, blurredBy: blur) { [weak self] image in
            guard let self, self.filmGeneration[monitor] == mine else { return }
            // A film that failed leaves the standing photograph alone: an old desktop is a better
            // backdrop than none, and `nil` here would take every scrim on that display down.
            guard let image else { return self.filmedAt[monitor] = .distantPast }
            self.surfaces[monitor]?.setDesktop(image)
        }
    }

    /// What the desktop is drawing `window` at: the veil its scrim carries, or `0` for a window that is
    /// opaque — focused, or one the photograph could not honestly back anywhere.
    ///
    /// **Read by the cover**, the one other thing that draws these windows. A cover is a photograph of
    /// the desktop it replaces, so its stand-ins have to be as see-through as the windows were when it
    /// went up. Asking here rather than deciding again is what keeps the two planes to one decision.
    ///
    /// A scrim is declined per region, so a window can be see-through over part of itself while a cover
    /// layer has one opacity. The veil is reported regardless, because **the cover does not need the
    /// decline**: where a scrim declines, the cover's backdrop is that window's own layer drawn beneath
    /// this one, so a see-through stand-in shows what is really behind it.
    public func veil(of window: WindowId) -> Double { applied[window] ?? 0 }

    private func apply(_ bindings: [ScrimBinding]) {
        let stacked = stack()
        let identified = stacked.map { (window: identify($0.number), pane: $0) }
        applied = [:]
        for (monitor, surface) in surfaces {
            guard let display = frames[monitor] else { continue }
            let regions = Self.regions(for: bindings.filter { $0.monitor == monitor },
                                       over: identified, on: display)
            var veils: [WindowId: Double] = [:]
            for (window, veil) in regions.drawn where veil > 0 { veils[window] = veil }
            applied.merge(veils) { first, _ in first }
            // Per display, because a scrim is one screen's: a focus change on one is not an event on
            // the other, whose mask is only ever being corrected.
            let fading = drawn[monitor] != nil && veils != drawn[monitor]
            drawn[monitor] = veils
            surface.setRegions(regions.mask, fading: fading)
        }
    }

    /// The mask's painting order, back to front: every window on `display`, each either see-through at
    /// its binding's veil or opaque. The pure half of this file, and the only place the rule lives.
    ///
    /// `stacked` arrives front to back, which is the order the decline is decided in — "is anything
    /// behind me" is a question about the tail — and leaves reversed, which is the order it is painted
    /// in. A scrim takes the binding's frame and an occluder the window server's: each authority for
    /// its own.
    ///
    /// **The decline is a region, not a verdict**, because the rule is one: a window is see-through
    /// *where* the desktop is behind it. So a window behind stamps its overlap back to opaque rather
    /// than disqualifying the frame, and a stamp past the screen edge costs nothing — a fill is
    /// clipped to the bitmap, and the bitmap is the display.
    static func regions(for bindings: [ScrimBinding],
                        over stacked: [(window: WindowId?, pane: StackedWindow)],
                        on display: Rect) -> (mask: [ScrimRegion], drawn: [(WindowId, Double)]) {
        let veils = Dictionary(bindings.map { ($0.window, $0) }, uniquingKeysWith: { first, _ in first })
        let here = stacked.filter { $0.pane.frame.intersects(display) }
        var regions: [ScrimRegion] = []
        var drawn: [(WindowId, Double)] = []
        for (index, entry) in here.enumerated() {
            guard let id = entry.window, let binding = veils[id] else {
                regions.append(ScrimRegion(frame: entry.pane.frame, veil: 0, cornerRadius: cornerRadius))
                continue
            }
            // The rule. Anything still to come in a front-to-back walk is *behind* this window, and the
            // photograph does not hold it. Appended before the scrim because the list is reversed into
            // painting order below, which puts these back over it; square, for an occluder's reason.
            for hole in here[(index + 1)...].compactMap({ $0.pane.frame.intersection(binding.frame) }) {
                regions.append(ScrimRegion(frame: hole, veil: 0, cornerRadius: 0))
            }
            regions.append(ScrimRegion(frame: binding.frame, veil: binding.veil,
                                       cornerRadius: cornerRadius))
            drawn.append((id, binding.veil))
        }
        return (regions.reversed(), drawn)
    }
}
