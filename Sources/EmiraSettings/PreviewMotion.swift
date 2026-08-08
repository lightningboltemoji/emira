import EmiraCore
import EmiraMotion

// The mock desktop's springs: a `RectAnimator` per window carrying how far behind the layout each layer
// still is, advanced by `dt` and retargeted whenever the arrangement changes.
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

    public init(scroll: SpringParams, resize: SpringParams, movement: SpringParams) {
        self.scroll = scroll
        self.resize = resize
        self.movement = movement
    }

    public init(_ config: Config) {
        self.init(scroll: config.scrollSpring, resize: config.resizeSpring,
                  movement: config.moveSpring)
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

    /// The mock pointer's own displacement, travelling under the same springs the windows do — it is a
    /// thing on the desktop being moved, not a cursor being warped.
    public private(set) var pointer: RectAnimator?
    private var placedPointer: Point?
    /// Where the strip was scrolled to when the frames were last placed — what says whether a window
    /// moved because the viewport did.
    private var placedOffset: Double?

    public init() {}

    /// Settle instantly on `state`, with nothing in flight. The first frame of a take, and what a
    /// section arriving on screen starts from — a preview that sprang into place on being opened would
    /// be animating the act of opening rather than the setting.
    public mutating func snap(to state: PreviewState) {
        windows = [:]
        placed = state.frames
        pointer = nil
        placedPointer = state.pointer
        placedOffset = state.scrollOffset
    }

    /// Take a new arrangement, keeping whatever motion is already in flight.
    ///
    /// A window that moved gains the displacement it just lost — seeded with `before − after`, so the
    /// first frame reproduces the old layout exactly and there is no pop. One already travelling is
    /// `nudge`d instead, which keeps its velocity: a second change mid-flight must lose neither the
    /// ground already covered nor the speed.
    public mutating func retarget(to state: PreviewState, springs: PreviewSprings) {
        let scrolled = placedOffset.map { $0 != state.scrollOffset } ?? false
        for (id, after) in state.frames {
            guard let before = placed[id] else { continue }
            let delta = before.delta(from: after)
            guard delta != .zero else { continue }
            if windows[id] != nil {
                windows[id]?.nudge(by: delta)
            } else {
                windows[id] = RectAnimator(displacement: delta, params: springs.spring(for: delta,
                                                                                       scrolled: scrolled))
            }
        }
        // A window that left the set takes its animator with it; one that arrived has nothing to travel
        // from, so it is simply where the layout puts it.
        windows = windows.filter { state.frames[$0.key] != nil }
        placed = state.frames

        // The pointer, on the same terms. A set that never had one has nothing to carry.
        if let after = state.pointer, let before = placedPointer, before != after {
            let delta = Rect(x: before.x - after.x, y: before.y - after.y, width: 0, height: 0)
            if pointer != nil {
                pointer?.nudge(by: delta)
            } else {
                // A window the strip rearranged is the movement spring's own sentence, and a pointer
                // sent after focus is travelling for the same reason.
                pointer = RectAnimator(displacement: delta, params: springs.movement)
            }
        }
        if state.pointer == nil { pointer = nil }
        placedPointer = state.pointer
        placedOffset = state.scrollOffset
    }

    /// Advance every displacement by `dt` seconds.
    public mutating func advance(by dt: Double) {
        for id in windows.keys {
            windows[id]?.advance(by: dt)
        }
        pointer?.advance(by: dt)
    }

    /// `state`'s frames with the live displacements added — what the view actually draws. The same
    /// `layout frame + in-flight displacement` the compositor emits, which is what makes a mock window's
    /// motion the real one's at another scale.
    public func frames(of state: PreviewState) -> [WindowId: Rect] {
        state.frames.reduce(into: [:]) { result, entry in
            let (id, frame) = entry
            result[id] = windows[id].map { frame.displaced(by: $0.current) } ?? frame
        }
    }

    /// Whether everything has arrived. An unsettled preview is the only reason to run a display link, so
    /// this is what an idle settings window costs nothing on.
    public func isSettled(epsilon: Double = 0.5, velocityEpsilon: Double = 0.5) -> Bool {
        windows.values.allSatisfy { $0.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon) }
            && pointer?.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon) != false
    }

    /// Where the pointer is drawn: its resting place plus whatever travel is still in flight.
    public func pointer(of state: PreviewState) -> Point? {
        guard let resting = state.pointer else { return nil }
        guard let travel = pointer?.current else { return resting }
        return Point(x: resting.x + travel.minX, y: resting.y + travel.minY)
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
    func spring(for delta: Rect, scrolled: Bool) -> SpringParams {
        if delta.width != 0 || delta.height != 0 { return resize }
        return scrolled ? scroll : movement
    }
}
