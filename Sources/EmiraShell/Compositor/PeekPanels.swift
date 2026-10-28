import AppKit
import EmiraCore

// The peek plane: every `PeekPanel` on the desktop, and the diff that keeps them matching the core's
// answer. `Effect.setPeeks` carries the whole set every time, so this file's job is the difference —
// build what is new, move what moved, film what changed size, take down what left — and one more: telling
// the scrim which of the windows it reads are ours standing in for a column (`standIn`).
//
// **The photograph is the window as last filmed, and the first one is borrowed.** A column becomes a peek
// at the end of the transition that scrolled it there, whose cover filmed it at its size moments ago, so a
// kept still of that size shows at once (`still`). The peek's own film follows and replaces it, and a peek
// a later cover moves takes that cover's still the same way. None is live: a peek's content is frozen
// while it stands, which is the trade a picture always makes, and a peek is the part of the strip the
// user is not working in. A click reveals the column, and the real window.

/// Where `Effect.setPeeks` goes. A protocol for `HoistPlane`'s reason.
@MainActor
public protocol PeekPlane: AnyObject {
    /// Stand in for exactly these peeking columns, and take down every one not named.
    func setPeeks(_ bindings: [PeekBinding], feedback: EventSink)
}

/// The plane on a machine that has none — a test that does not care. Accepting the set and drawing
/// nothing leaves the peek's area showing the desktop, which is where a peek with no photograph stands.
@MainActor
public final class NoPeeks: PeekPlane {
    public init() {}
    public func setPeeks(_ bindings: [PeekBinding], feedback: EventSink) {}
}

/// One peek's surface — `PeekPanel` is the real one. A protocol for `HoistSurface`'s reason.
@MainActor
public protocol PeekSurface: AnyObject {
    /// The window server's number for it — what the scrim's reading of the desktop names it by.
    var number: CGWindowID { get }
    /// Stand over `slice`, the part of the column's whole `frame` its display shows.
    func place(slice: Rect, of frame: Rect)
    /// Load the pixels; the first ones show it.
    func setImage(_ image: CGImage)
    func retire()
}

/// How a `PeekPanels` builds one. Injected so a test can hand it something that is not a window.
public typealias PeekSurfaceFactory =
    @MainActor (_ window: WindowId, _ scale: CGFloat, _ geometry: ScreenGeometry,
                _ onClick: @escaping @MainActor (WindowId) -> Void) -> any PeekSurface

/// Every peek's panel, keyed by the window it stands for.
@MainActor
public final class PeekPanels: PeekPlane {

    private let filmer: any SurfaceFilmer
    /// A photograph already taken of a window at a size, if one is kept (`SurfaceCache.surface(for:at:)`).
    private let still: @MainActor (WindowId, Size) -> CapturedSurface?
    private let build: PeekSurfaceFactory

    private var panels: [WindowId: any PeekSurface] = [:]
    /// The binding each panel stands for — what `standIn` answers from.
    private var standing: [WindowId: PeekBinding] = [:]
    /// The size each window's photograph was asked for, so a peek that merely moved is not filmed again.
    private var pictured: [WindowId: Size] = [:]
    /// Bumped per window by every film, so one answering after its panel came down owns nothing.
    private var filmGeneration: [WindowId: Int] = [:]

    /// The last set the core named, re-applied when the displays change under it (`HoistPanels.current`).
    private var current: [PeekBinding] = []
    private var geometry: ScreenGeometry
    private var displays: [MonitorId: (frame: Rect, scale: CGFloat)] = [:]
    private var sink: EventSink?

    /// Told after a set has changed what stands on the glass, so the scrim cuts against it.
    public var onChange: @MainActor () -> Void = {}

    public init(filmer: any SurfaceFilmer,
                still: @escaping @MainActor (WindowId, Size) -> CapturedSurface? = { _, _ in nil },
                geometry: ScreenGeometry = ScreenGeometry(flipHeight: 0),
                build: @escaping PeekSurfaceFactory = PeekPanel.init) {
        self.filmer = filmer
        self.still = still
        self.geometry = geometry
        self.build = build
    }

    /// The displays changed: rebuild every panel against the new geometry and scales, for
    /// `HoistPanels.setDisplays`' reason.
    public func setDisplays(geometry: ScreenGeometry,
                            displays: [(monitor: MonitorId, frame: Rect, scale: CGFloat)]) {
        self.geometry = geometry
        self.displays = Dictionary(displays.map { ($0.monitor, ($0.frame, $0.scale)) },
                                   uniquingKeysWith: { first, _ in first })
        retireEvery()
        apply(current)
    }

    public func setPeeks(_ bindings: [PeekBinding], feedback: EventSink) {
        sink = feedback
        current = bindings
        apply(bindings)
    }

    /// Take every panel off the screen — the daemon is quitting.
    public func retireAll() {
        retireEvery()
        current = []
    }

    /// The window a panel of ours stands in for, and the frame that window would stand at — or `nil` for
    /// a number that is not a peek. What lets the scrim veil a peek as the column it is.
    public func standIn(for number: CGWindowID) -> (window: WindowId, frame: Rect)? {
        guard let (id, _) = panels.first(where: { $0.value.number == number }),
              let binding = standing[id] else { return nil }
        return (id, binding.frame)
    }

    /// The window's id now names another window: whatever this peek shows is of the one it named
    /// before, so it is filmed again.
    public func forgetPicture(of id: WindowId) {
        pictured[id] = nil
        guard let binding = standing[id], let panel = panels[id] else { return }
        picture(binding, on: panel)
    }

    private func retireEvery() {
        for (id, panel) in panels {
            panel.retire()
            filmGeneration[id, default: 0] &+= 1
        }
        panels.removeAll()
        standing.removeAll()
        pictured.removeAll()
    }

    private func apply(_ bindings: [PeekBinding]) {
        let wanted = Set(bindings.map(\.window))
        for (id, panel) in panels where !wanted.contains(id) { take(id, panel) }
        for binding in bindings {
            let id = binding.window
            // A display that has gone, or a column not on it after all, has nothing to show.
            guard let display = displays[binding.monitor],
                  let slice = binding.frame.intersection(display.frame) else {
                if let panel = panels[id] { take(id, panel) }
                continue
            }
            let panel = panels[id] ?? build(id, display.scale, geometry) { [weak self] window in
                self?.sink?(.peekClicked(window))
            }
            panels[id] = panel
            let moved = standing[id].map { $0.frame != binding.frame } ?? false
            standing[id] = binding
            panel.place(slice: slice, of: binding.frame)
            if pictured[id] != binding.frame.size {
                picture(binding, on: panel)
            } else if moved, let kept = still(id, binding.frame.size) {
                // The cover that moved it filmed it on the way: the newest pixels there are, for free.
                panel.setImage(kept.image)
            }
        }
        onChange()
    }

    private func take(_ id: WindowId, _ panel: any PeekSurface) {
        panel.retire()
        panels[id] = nil
        standing[id] = nil
        pictured[id] = nil
        filmGeneration[id, default: 0] &+= 1
    }

    /// Show a kept still of the window at its size now, if there is one, and film it regardless.
    private func picture(_ binding: PeekBinding, on panel: any PeekSurface) {
        let id = binding.window
        pictured[id] = binding.frame.size
        if let kept = still(id, binding.frame.size) { panel.setImage(kept.image) }
        filmGeneration[id, default: 0] &+= 1
        let mine = filmGeneration[id] ?? 0
        filmer.film(id, on: binding.monitor) { [weak self] surface in
            guard let self, self.filmGeneration[id] == mine else { return }
            guard let surface else {
                // Nothing came back: forget the request, so the next set asks again.
                self.pictured[id] = nil
                return
            }
            self.panels[id]?.setImage(surface.image)
            self.onChange()
        }
    }
}
