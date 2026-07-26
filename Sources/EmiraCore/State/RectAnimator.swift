import Foundation
import EmiraMotion

// The **third** animated quantity of the strip (`Motion.windowAnimators`), and the one that is not
// like the other two. `viewportOffset` and `columnWidths` animate numbers the layout *derives from* —
// change one and every affected frame follows in lockstep by construction. A structural edit has no
// such number: it inserts or removes a column, so before and after are two different `Layout`s.
//
// **So what animates is not a position — it is a displacement, and its target is always zero.**
// `Layout` mutates immediately and stays the sole authority on where a window belongs; a
// `RectAnimator` only carries how far *behind* that answer the layer currently is, and decays to
// nothing. The consequences are why this shape was chosen over interpolating between two layouts:
//
//  · **No pop at the raise.** Seeded with `before − after`, the very first frame reproduces the old
//    layout exactly — which is also the frame the shell gave the layer from its capture.
//  · **Dropping a settled animator is a no-op.** `Motion.closeTransition` discards these the same way
//    it discards `columnWidths`, and for the same reason: the resting value is what `Layout` already
//    derives, so an animator kept past the cross-fade would be a second, staler authority.
//  · **An orphan is harmless.** A displacement for a window whose column an edit destroyed adds zero
//    to a frame nobody asks for.
//  · **Interruption is arithmetic in the strict sense.** A second edit mid-flight `nudge`s by the new
//    `before − after`; position is continuous to the point and velocity carries through untouched
//    (`Motion.displaceWindow`).
//
// It lives in `EmiraCore` rather than `EmiraMotion` because `Rect` does. `EmiraMotion` is scalar in,
// scalar out by charter (IMPLEMENTATION.md §4) — teaching the physics target a vector abstraction to
// serve one client would be the wrong seam. Four scalar `Animator`s composed here is the right one.

/// A rect-valued **displacement** under spring motion: four scalar `Animator`s, one per component,
/// every one of them heading to zero.
///
/// Never a position. See the file header for why the target being permanently zero is the design
/// rather than an implementation detail.
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

    /// The displacement at this instant — what `Engine.emitLayerFrames` adds to the layout-derived
    /// frame via `Rect.displaced(by:)`.
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

    /// Add `delta` to the live displacement, **keeping every component's velocity**. The second
    /// structural edit landing mid-flight: the layer must lose neither the ground it has already
    /// covered nor the speed it was covering it at.
    public mutating func nudge(by delta: Rect) {
        x.nudge(by: delta.minX)
        y.nudge(by: delta.minY)
        width.nudge(by: delta.width)
        height.nudge(by: delta.height)
    }

    /// Whether every component has arrived at zero and stopped. `Motion.isSettled` supplies its own
    /// point-valued tolerances — a displacement is in points, exactly like the offset and the widths.
    public func isSettled(epsilon: Double, velocityEpsilon: Double) -> Bool {
        x.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon)
            && y.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon)
            && width.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon)
            && height.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon)
    }
}
