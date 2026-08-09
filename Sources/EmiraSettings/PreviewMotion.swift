import EmiraCore
import EmiraMotion

// The mock desktop's springs: a `RectAnimator` per window carrying how far behind the layout each layer
// still is, advanced by `dt` and retargeted whenever the arrangement changes.
//
// **The pointer is not here.** A cursor is either a hand — which tracks its own path linearly — or a
// warp, which the real `CGWarpMouseCursorPosition` performs in a single frame. Neither is a spring,
// so `PreviewModel` owns the whole of where a cursor is and this owns the windows.
//
// **Why not reuse `Motion`.** It is the right pattern and the wrong type — its machinery is sessions,
// capture phases, cover fences and landing waits, every one of which exists to sequence a cover over a
// truth plane. Strip those out and what is left is precisely this. Reusing the container would mean the
// preview holding a `TransitionSession` that can never open.
//
// The springs come from the draft, so the springs section previews itself: change `movement.stiffness`
// and the very next retarget travels under the number just typed.

/// Which spring drives which quantity, straight off the draft.
///
/// The schema already names these: each spring's help sentence says what it drives — *the viewport
/// scroll*, *a column's width*, *a window the strip rearranged*. This is that sentence as code, so the
/// springs section demonstrates itself rather than being demonstrated by a stand-in.
public struct PreviewSprings: Sendable, Equatable {
    public var scroll: SpringParams
    public var resize: SpringParams
    public var movement: SpringParams
    /// The coast after a trackpad lift, and nothing else — which is what its own help sentence says.
    public var glide: SpringParams

    public init(scroll: SpringParams, resize: SpringParams, movement: SpringParams,
                glide: SpringParams) {
        self.scroll = scroll
        self.resize = resize
        self.movement = movement
        self.glide = glide
    }

    public init(_ config: Config) {
        self.init(scroll: config.scrollSpring, resize: config.resizeSpring,
                  movement: config.moveSpring, glide: config.glideSpring)
    }
}

/// Per-window displacement under spring motion, plus the settled-ness that decides whether a clock has
/// to keep running.
public struct PreviewMotion: Sendable, Equatable {

    /// A displacement per window, every one of them heading to zero. A window with no entry is exactly
    /// where the layout says it is.
    public private(set) var windows: [WindowId: RectAnimator] = [:]

    /// The frames the last retarget was measured against — what a new arrangement is compared to in
    /// order to know how far each window just moved.
    private var placed: [WindowId: Rect] = [:]

    /// Where the strip was scrolled to when the frames were last placed — what says whether a window
    /// moved because the viewport did.
    private var placedOffset: Double?

    /// Windows that have not arrived yet: how long each still has to wait, and the displacement it
    /// holds until it does.
    ///
    /// **`animation.transition = off` is the only thing that puts one here.** With no cover, windows are
    /// placed by AX and arrive when they arrive — so for a quarter of a second the strip is genuinely
    /// half-arranged, one window overlapping space another has not left. That is the honest picture of
    /// what a cover is for, and it is a *wait then jump*, never a spring.
    private var pending: [WindowId: Arrival] = [:]

    private struct Arrival: Sendable, Equatable {
        var wait: Double
        let displacement: Rect
    }

    /// The stagger, in seconds, largest window last. **Fixed and identical every loop**: it has to read
    /// as latency, and latency that reshuffles reads as noise.
    public static let stagger: [Double] = [0, 0.06, 0.14, 0.21]

    /// The guide's panel, travelling. **A `RectAnimator` on the panel rect, the same one a window gets**
    /// — which is what makes picking `bottom-left` send the ribbon gliding across the desktop rather
    /// than cutting to it, and a nine-way menu feel like putting something down.
    public private(set) var panel: RectAnimator?
    private var placedPanel: Rect?

    public init() {}

    /// Settle instantly on `state`, with nothing in flight. The first frame of a take, and what a
    /// section arriving on screen starts from — a preview that sprang into place on being opened would
    /// be animating the act of opening rather than the setting.
    public mutating func snap(to state: PreviewState) {
        windows = [:]
        pending = [:]
        panel = nil
        placed = state.frames
        placedPanel = state.guide?.panel
        placedOffset = state.scrollOffset
    }

    /// Take a new arrangement, keeping whatever motion is already in flight.
    ///
    /// A window that moved gains the displacement it just lost — seeded with `before − after`, so the
    /// first frame reproduces the old layout exactly and there is no pop. One already travelling is
    /// `nudge`d instead, which keeps its velocity: a second change mid-flight must lose neither the
    /// ground already covered nor the speed.
    /// - Parameter mode: `animation.transition`, which decides the *shape* of every arrival rather than
    ///   its speed. `smooth` springs, `snap` changes every frame at once, and `off` staggers.
    /// - Parameter head: a pause before anything moves at all, which is `animation.cover = exact`
    ///   paying a capture round trip before it can raise anything.
    public mutating func retarget(to state: PreviewState, springs: PreviewSprings,
                                  mode: TransitionMode = .smooth, head: Double = 0) {
        // **A hand is not a spring.** Fingers on the strip mean the view draws exactly what the model
        // says, with nothing easing in between — the difference between a trackpad scroll and an
        // animation of one.
        guard state.travel != .hand else { return snap(to: state) }

        // **The one sanctioned cut in the whole window.** Under `snap` the arrangement changes in a
        // single frame, and the held frames either side are what make that read as atomicity rather
        // than as a dropped animation.
        guard mode != .snap else { return snap(to: state) }

        if mode == .off {
            return stagger(to: state, head: head)
        }

        let scrolled = placedOffset.map { $0 != state.scrollOffset } ?? false
        for (id, after) in state.frames {
            guard let before = placed[id] else { continue }
            let delta = before.delta(from: after)
            guard delta != .zero else { continue }
            let params = springs.spring(for: delta, scrolled: scrolled, travel: state.travel)
            if windows[id] != nil {
                // Nudged rather than re-sprung: a second change mid-flight must lose neither the ground
                // already covered nor the speed, and the spring it is already on is the one it started
                // under. A glide always begins from rest — the hand snapped every frame before it — so
                // the coast never has to take a spring off an animator that already exists.
                windows[id]?.nudge(by: delta)
            } else {
                windows[id] = RectAnimator(displacement: delta, params: params)
            }
        }
        // A window that left the set takes its animator with it; one that arrived has nothing to travel
        // from, so it is simply where the layout puts it.
        windows = windows.filter { state.frames[$0.key] != nil }
        placed = state.frames

        // The panel, on the same terms — but only while it is up either side of the change. A guide
        // that has just been raised has nowhere to travel from, and one that has gone has nothing left
        // to carry.
        if let after = state.guide?.panel, let before = placedPanel, before != after {
            let delta = before.delta(from: after)
            if panel != nil {
                panel?.nudge(by: delta)
            } else {
                panel = RectAnimator(displacement: delta, params: springs.movement)
            }
        }
        if state.guide == nil { panel = nil }
        placedPanel = state.guide?.panel
        placedOffset = state.scrollOffset
    }

    /// Every window that moved waits its turn and then **jumps**. No springs anywhere: with no cover
    /// there is nothing to animate under, and what the user is being shown is latency.
    private mutating func stagger(to state: PreviewState, head: Double) {
        // Smallest first, so the largest lands last — the window whose arrival is most conspicuous is
        // the one the eye is still waiting for.
        let moved = state.frames
            .compactMap { id, after -> (WindowId, Rect, Double)? in
                guard let before = placed[id] else { return nil }
                let delta = before.delta(from: after)
                guard delta != .zero else { return nil }
                return (id, delta, after.size.area)
            }
            .sorted { ($0.2, $0.0.raw) < ($1.2, $1.0.raw) }

        for (rank, entry) in moved.enumerated() {
            let wait = head + Self.stagger[min(rank, Self.stagger.count - 1)]
            pending[entry.0] = Arrival(wait: wait, displacement: entry.1)
        }
        windows = [:]
        pending = pending.filter { state.frames[$0.key] != nil }
        placed = state.frames
        placedOffset = state.scrollOffset
    }

    /// Advance every displacement by `dt` seconds.
    public mutating func advance(by dt: Double) {
        for id in windows.keys {
            windows[id]?.advance(by: dt)
        }
        for id in pending.keys {
            pending[id]?.wait -= dt
            if pending[id]!.wait <= 0 { pending.removeValue(forKey: id) }
        }
        panel?.advance(by: dt)
    }

    /// The guide with its panel where the spring has got to — `nil` when there is no guide up.
    public func guide(of state: PreviewState) -> GuidePreview? {
        guard let guide = state.guide else { return nil }
        guard let travel = panel?.current else { return guide }
        return guide.on(panel: guide.panel.displaced(by: travel))
    }

    /// `state`'s frames with the live displacements added — what the view actually draws. The same
    /// `layout frame + in-flight displacement` the compositor emits, which is what makes a mock window's
    /// motion the real one's at another scale.
    public func frames(of state: PreviewState) -> [WindowId: Rect] {
        state.frames.reduce(into: [:]) { result, entry in
            let (id, frame) = entry
            if let waiting = pending[id] { return result[id] = frame.displaced(by: waiting.displacement) }
            result[id] = windows[id].map { frame.displaced(by: $0.current) } ?? frame
        }
    }

    /// Whether everything has arrived. An unsettled preview is the only reason to run a display link, so
    /// this is what an idle settings window costs nothing on.
    public func isSettled(epsilon: Double = 0.5, velocityEpsilon: Double = 0.5) -> Bool {
        pending.isEmpty
            && windows.values.allSatisfy { $0.isSettled(epsilon: epsilon,
                                                        velocityEpsilon: velocityEpsilon) }
            && panel?.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon) != false
    }

    /// Drop every settled animator. Housekeeping, so a long-running take does not accumulate one entry
    /// per window it ever moved.
    public mutating func prune(epsilon: Double = 0.5, velocityEpsilon: Double = 0.5) {
        windows = windows.filter {
            !$0.value.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon)
        }
    }
}

extension PreviewSprings {
    /// Which spring carries a displacement of `delta`.
    ///
    /// A size that changed is a resize whatever else happened alongside it. Otherwise a pure
    /// translation is the viewport's if the viewport moved, and the strip's own rearrangement if it did
    /// not. **An approximation, and a stated one**: a beat that scrolls *and* rearranges in the same
    /// frame attributes both to the scroll. The alternative is decomposing every window's travel into
    /// two components in order to run two springs on one layer, which would animate no real quantity.
    /// A coast after a lift is the glide spring whatever else the frame is doing — that is the one
    /// sentence `animation.glide` has, and it is the only motion on the desktop when it happens.
    func spring(for delta: Rect, scrolled: Bool, travel: Travel) -> SpringParams {
        if travel == .glide { return glide }
        if delta.width != 0 || delta.height != 0 { return resize }
        return scrolled ? scroll : movement
    }
}
