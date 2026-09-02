import Foundation

// Hoisting: what makes a float actually float.
//
// **The problem is macOS's window ordering, and we cannot write to it.** A window emira does not place
// is still a window macOS stacks, and clicking a tiled window puts it above whatever floats over it.
// `AXRaise` orders a window only within its own app (`Cascade`), so there is no cross-app raise, and
// re-levelling a foreign window needs SkyLight and therefore SIP off (`PRINCIPLES` §5). A float that
// goes behind stays behind, and the only route back is Cmd-Tab or the Dock.
//
// So it is answered on the **presentation plane**, which is the same answer §3 gives everything else:
// draw the float's own pixels over the desktop, in a window of ours, and let a click on that picture
// bring the real one forward. What is here is the half that decides — which floats, in what order, at
// what rect — and it is `State`'s, not the shell's, because "what is on the screen" is a fact the
// reducer already answers for (`World.isOnScreen`, `World.window(at:)`) and a second opinion about it
// is the mistake §1 names.
//
// Three rules, and the first is the one that keeps this honest.
//
//  1. **A float is hoisted only while something is actually covering it.** A hoisted float is a
//     photograph: it cannot be dragged, resized, scrolled or hovered, and its pixels stop at the moment
//     they were taken. That is the right trade for a window you cannot see and a bad one for a window
//     you can, so the lie is confined to exactly where the truth is already hidden. A float sitting in
//     the open is left alone and stays a real window in every respect.
//  2. **Only what the user chose to float** (`World.isFloatedByChoice`). The taxonomy floats every
//     dialog, sheet, popover and tool palette; pinning a background app's palettes over the window you
//     are typing in is not floating, it is in the way.
//  3. **Only a window emira placed can bury one.** The occluders are `World.placedOnScreen` — the strip
//     windows the last pass put on the glass. A float buried by a window emira never placed was not
//     buried by emira, and hoisting it would be an opinion about somebody else's desktop.

/// One float drawn over the desktop: which window, which display's screen it is on, and the rect it
/// occupies in core (top-left, global) coordinates. Array order is z-order, bottom→top — the same
/// convention `LayerBinding` carries, and for the same reason.
public struct HoistBinding: Sendable, Equatable, Codable {
    public let window: WindowId
    /// The display the shell films it for. A still is filmed at its destination's backing scale, so a
    /// hoist that could not name a screen could not be filmed sharply for one.
    public let monitor: MonitorId
    /// Where the real window is, which is where its picture goes. Never a frame emira computed: emira
    /// declines an opinion about where a float sits, and hoisting does not change that.
    public let frame: Rect

    public init(window: WindowId, monitor: MonitorId, frame: Rect) {
        self.window = window
        self.monitor = monitor
        self.frame = frame
    }
}

/// macOS's window ordering, reconstructed from the focus reports emira folds. The model has two levels
/// — activating an app lifts all of its windows above every other app's, and within an app the window
/// focused last is on top — so the order is lexicographic on `(app, window)`, an app ranking as the most
/// recent focus any of its windows took. It fails only toward "not covered", which is a float left
/// alone.
struct StackOrder {
    /// The most recent focus taken by any window of each app.
    private let apps: [String: Int]
    private let world: World

    init(_ world: World) {
        var apps: [String: Int] = [:]
        for (id, at) in world.focusedAt {
            guard let window = world.windows[id] else { continue }
            apps[window.bundleId] = max(apps[window.bundleId] ?? 0, at)
        }
        self.apps = apps
        self.world = world
    }

    /// Where `id` sits in the global order. Greater is nearer the front; a window nothing has focused
    /// ranks `(0, 0)`, which is below anything focused and above nothing.
    func rank(of id: WindowId) -> (app: Int, window: Int) {
        guard let window = world.windows[id] else { return (0, 0) }
        return (apps[window.bundleId] ?? 0, world.focusedAt[id] ?? 0)
    }

    /// Whether `a` is in front of `b`. Strict: `World.focusClock` is monotonic, so two windows can
    /// only tie by both being unfocused — and then neither is in front of the other.
    func isInFront(_ a: WindowId, of b: WindowId) -> Bool {
        let (x, y) = (rank(of: a), rank(of: b))
        return x.app == y.app ? x.window > y.window : x.app > y.app
    }
}

extension State {

    /// The floats to draw over the desktop right now, bottom→top. Cheap on the common desktop — one
    /// dictionary scan where nothing is floated by choice — because the post-pass that calls it runs on
    /// every event, including a display-link tick.
    public func hoistBindings() -> [HoistBinding] {
        // Rule 2, and the early out. `floating` is small and usually holds nothing explicit at all.
        guard world.floating.values.contains(true) else { return [] }

        let candidates = world.windows.values
            .filter { world.isFloatedByChoice($0.id) && world.isOnScreen($0.id) }
            .map(\.id)
            .sorted()                                   // deterministic before anything orders it
        guard !candidates.isEmpty else { return [] }

        let order = StackOrder(world)
        let frames = Dictionary(uniqueKeysWithValues: candidates.compactMap { id in
            world.windows[id].map { (id, $0.frame) }
        })

        // Rule 3: a strip window on the glass, in front of the float, over the same pixels.
        var hoisted = Set(candidates.filter { float in
            guard let frame = frames[float] else { return false }
            return world.placedOnScreen.contains { placed in
                guard let over = world.windows[placed]?.frame, over.intersects(frame) else { return false }
                return order.isInFront(placed, of: float)
            }
        })

        // The closure, and it exists to stop this inverting the order it is correcting: a float drawn
        // over the desktop is drawn over *every* real window, including another float that is genuinely
        // in front of it. So a float above a hoisted one, overlapping it, is hoisted too — and the two
        // then keep their real order among the pictures. Iterated because the float it pulls in can
        // pull in a third; bounded by the candidate count, since each pass adds at least one or stops.
        while true {
            let next = candidates.filter { above in
                guard !hoisted.contains(above), let frame = frames[above] else { return false }
                return hoisted.contains { below in
                    guard let under = frames[below], under.intersects(frame) else { return false }
                    return order.isInFront(above, of: below)
                }
            }
            if next.isEmpty { break }
            hoisted.formUnion(next)
        }

        return hoisted
            .compactMap { id -> HoistBinding? in
                guard let frame = frames[id],
                      // A float off every attached screen has no display to be filmed for. Asked of the
                      // centre rather than the origin: a window half off the left edge is still on the
                      // screen holding the rest of it.
                      let monitor = world.monitor(at: frame.center) else { return nil }
                return HoistBinding(window: id, monitor: monitor, frame: frame)
            }
            // Bottom→top. The tie-break is the id, which only reaches windows nothing has focused.
            .sorted { a, b in
                order.isInFront(b.window, of: a.window)
                    || (!order.isInFront(a.window, of: b.window) && a.window < b.window)
            }
    }
}
