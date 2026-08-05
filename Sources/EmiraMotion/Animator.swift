/// A single scalar under spring motion — `{current, velocity, target, params}`.
///
/// The atom the pure core advances, one per animated quantity. The core never surrenders it to Core
/// Animation, so retargeting mid-flight is pure arithmetic: set a new target, keep the velocity — which
/// is what makes an interrupted motion feel alive rather than restart from a dead stop.
public struct Animator: Sendable, Equatable, Codable {
    /// Where the quantity is *right now* (the value the shell blits this frame).
    public private(set) var current: Double
    /// Rate of change, carried across retargets.
    public private(set) var velocity: Double
    public private(set) var target: Double
    /// The spring driving `current → target`.
    public var params: SpringParams

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

    /// Aim at a new target without disturbing `current` or `velocity`. "Move a window, move it back, grab
    /// another, all before the first lands" is three `retarget`s, with the in-flight velocity carried.
    public mutating func retarget(to newTarget: Double) {
        target = newTarget
    }

    /// Shift `current` by `delta`, leaving `velocity` and `target` untouched — the partner of
    /// `retarget(to:)` for a quantity whose destination is fixed and whose *origin* moved under it. A
    /// displacement animator's target is permanently zero, so moving position is its only continuity.
    public mutating func nudge(by delta: Double) {
        current += delta
    }

    /// Set the rate of change without moving `current` or `target` — the only thing a quantity driven
    /// from outside owes when it is handed back to the spring. A hand's velocity is measured where the
    /// samples and their timestamps are, and this is where it lands.
    public mutating func launch(_ velocity: Double) {
        self.velocity = velocity
    }

    /// Jump instantly to `value`, killing motion — for snap paths that owe no animation.
    public mutating func snap(to value: Double) {
        current = value
        target = value
        velocity = 0
    }

    /// Whether the motion has arrived and stopped — both position error and velocity within tolerance.
    public func isSettled(epsilon: Double = 1e-3, velocityEpsilon: Double = 1e-3) -> Bool {
        abs(current - target) <= epsilon && abs(velocity) <= velocityEpsilon
    }
}
