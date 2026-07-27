import Foundation
import EmiraMotion

// The element type of `Motion.windowAnimators`. It lives in `EmiraCore` rather than `EmiraMotion`
// because `Rect` does: `EmiraMotion` is scalar in, scalar out by charter.

/// A rect-valued *displacement* under spring motion: four scalar `Animator`s, one per component, every
/// one of them heading to zero.
///
/// Never a position: a structural edit inserts or removes a column, so before and after are two different
/// `Layout`s with no shared number to interpolate. `Layout` mutates immediately and stays the sole
/// authority on where a window belongs; this carries only how far behind that answer the layer is. Seeded
/// with `before − after` the first frame reproduces the old layout exactly (no pop at the raise), a
/// settled animator is indistinguishable from none, and a second edit mid-flight is a `nudge`.
public struct RectAnimator: Sendable, Equatable, Codable {
    public private(set) var x: Animator
    public private(set) var y: Animator
    public private(set) var width: Animator
    public private(set) var height: Animator

    /// A displacement of `delta` decaying to zero under `params`.
    public init(displacement delta: Rect, params: SpringParams = .smooth) {
        func component(_ value: Double) -> Animator {
            var animator = Animator(value: value, params: params)
            animator.retarget(to: 0)
            return animator
        }
        self.x = component(delta.minX)
        self.y = component(delta.minY)
        self.width = component(delta.width)
        self.height = component(delta.height)
    }

    /// The displacement at this instant — what `Engine.emitLayerFrames` adds to the layout-derived frame.
    public var current: Rect {
        Rect(x: x.current, y: y.current, width: width.current, height: height.current)
    }

    /// Advance every component by `dt` seconds (`Motion.advance`, off `Event.tick`).
    public mutating func advance(by dt: Double) {
        x.advance(by: dt)
        y.advance(by: dt)
        width.advance(by: dt)
        height.advance(by: dt)
    }

    /// Add `delta` to the live displacement, keeping every component's velocity — the second structural
    /// edit landing mid-flight, where the layer must lose neither ground already covered nor speed.
    public mutating func nudge(by delta: Rect) {
        x.nudge(by: delta.minX)
        y.nudge(by: delta.minY)
        width.nudge(by: delta.width)
        height.nudge(by: delta.height)
    }

    /// Whether every component has arrived at zero and stopped. `Motion.isSettled` supplies the
    /// point-valued tolerances — a displacement is in points, like the offset and the widths.
    public func isSettled(epsilon: Double, velocityEpsilon: Double) -> Bool {
        x.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon)
            && y.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon)
            && width.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon)
            && height.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon)
    }
}
