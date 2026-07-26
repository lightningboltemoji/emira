/// A single scalar under spring motion — `{current, velocity, target, params}`.
///
/// This is the atom the pure core advances. The core holds one per animated quantity (the
/// viewport offset; a window's independent slide) and never surrenders it to Core Animation, so
/// **retargeting mid-flight is pure arithmetic**: set a new target, keep the velocity. That
/// carried velocity is what makes an interrupted motion feel alive instead of restarting from a
/// dead stop (PRINCIPLES.md §7). A value type so State stays trivially copyable and replayable.
public struct Animator: Sendable, Equatable, Codable {
    /// Where the quantity is *right now* (the value the shell blits this frame).
    public private(set) var current: Double
    /// Rate of change, carried across retargets.
    public private(set) var velocity: Double
    /// Where it's heading.
    public private(set) var target: Double
    /// The spring driving `current → target`.
    public var params: SpringParams

    /// Create an Animator at rest at `value`.
    public init(value: Double, params: SpringParams = .smooth) {
        self.current = value
        self.velocity = 0
        self.target = value
        self.params = params
    }

    /// Advance the spring by `dt` seconds. The core calls this on every `Event.tick(dt)`.
    public mutating func advance(by dt: Double) {
        let next = Spring.step(current: current, velocity: velocity,
                               target: target, params: params, dt: dt)
        current = next.current
        velocity = next.velocity
    }

    /// Aim at a new target **without disturbing `current` or `velocity`**.
    ///
    /// The whole point of core-owned motion: "move a window, move it back, grab another, all
    /// before the first lands" is just three `retarget`s — the in-flight velocity carries through,
    /// which `CASpringAnimation` cannot do cleanly.
    public mutating func retarget(to newTarget: Double) {
        target = newTarget
    }

    /// Shift `current` by `delta`, leaving **`velocity` and `target` untouched** — the partner of
    /// `retarget(to:)` for a quantity whose destination is fixed and whose *origin* moved under it.
    ///
    /// `retarget` says "we changed our mind about where this is going"; this says "the thing it is
    /// measured against jumped". A **displacement** animator (`EmiraCore/RectAnimator`) needs the
    /// second and can't use the first: its target is permanently zero, so the only way to keep an
    /// interrupted motion continuous is to move the position. It is strictly weaker than
    /// `snap(to:)`, which already writes `current` — and unlike `snap` it leaves the velocity
    /// alone, which is the entire point.
    public mutating func nudge(by delta: Double) {
        current += delta
    }

    /// Jump instantly to `value`, killing motion — for snap paths that owe no animation
    /// (e.g. revealing an externally-focused window, PRINCIPLES.md §4a).
    public mutating func snap(to value: Double) {
        current = value
        target = value
        velocity = 0
    }

    /// Whether the motion has effectively arrived and stopped — the core's settle test for
    /// closing a transition. Both position error and velocity must be within tolerance.
    public func isSettled(epsilon: Double = 1e-3, velocityEpsilon: Double = 1e-3) -> Bool {
        abs(current - target) <= epsilon && abs(velocity) <= velocityEpsilon
    }
}
