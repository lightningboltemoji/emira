import Foundation
import Testing
@testable import EmiraMotion

/// An animator the core advances itself, with velocity-preserving retargeting (IMPLEMENTATION.md §1).
@Suite struct AnimatorTests {
    static let dt = 1.0 / 120.0

    private func advance(_ a: inout Animator, frames: Int) {
        for _ in 0..<frames { a.advance(by: Self.dt) }
    }

    @Test func startsAtRestAndSettled() {
        let a = Animator(value: 42)
        #expect(a.current == 42)
        #expect(a.velocity == 0)
        #expect(a.target == 42)
        #expect(a.isSettled())
    }

    @Test func convergesToTarget() {
        var a = Animator(value: 0, params: .smooth)
        a.retarget(to: 100)
        advance(&a, frames: 600)
        #expect(a.isSettled())
        #expect(abs(a.current - 100) < 0.01)
    }

    /// Retarget touches only the target — position and live velocity carry straight through.
    @Test func retargetPreservesCurrentAndVelocity() {
        var a = Animator(value: 0, params: .snappy)
        a.retarget(to: 100)
        advance(&a, frames: 10)

        let currentBefore = a.current
        let velocityBefore = a.velocity
        #expect(velocityBefore != 0)               // genuinely in flight

        a.retarget(to: -50)
        #expect(a.current == currentBefore)        // position untouched
        #expect(a.velocity == velocityBefore)      // velocity carried, bit-for-bit
        #expect(a.target == -50)
    }

    /// Move a window, move it back, grab another, all before the first lands: the interrupt path is
    /// successive retargets, and it still converges to the final target.
    @Test func interruptedMotionConvergesToFinalTarget() {
        var a = Animator(value: 0, params: .snappy)
        a.retarget(to: 100)
        advance(&a, frames: 15)
        a.retarget(to: -50)     // reverse mid-flight
        advance(&a, frames: 8)
        a.retarget(to: 30)      // grab a third target
        advance(&a, frames: 3000)
        #expect(a.isSettled())
        #expect(abs(a.current - 30) < 0.01)
    }

    /// `Animator` is `Codable` so the core's `Motion` state round-trips for replay. An in-flight
    /// animator (non-zero velocity) must survive that bit-for-bit.
    @Test func roundTripsThroughCodableMidFlight() throws {
        var a = Animator(value: 0, params: .snappy)
        a.retarget(to: 100)
        advance(&a, frames: 7)
        #expect(a.velocity != 0)

        let decoded = try JSONDecoder().decode(Animator.self, from: JSONEncoder().encode(a))
        #expect(decoded == a)
    }

    @Test func snapKillsMotionInstantly() {
        var a = Animator(value: 0, params: .snappy)
        a.retarget(to: 100)
        advance(&a, frames: 10)
        #expect(!a.isSettled())

        a.snap(to: 250)
        #expect(a.current == 250)
        #expect(a.target == 250)
        #expect(a.velocity == 0)
        #expect(a.isSettled())
    }

    /// `nudge` moves the origin rather than the destination — the only way to keep a displacement
    /// animator, whose target is permanently zero, continuous across an interrupt.
    @Test func nudgeShiftsThePositionAndLeavesVelocityAndTargetAlone() {
        var a = Animator(value: 0, params: .snappy)
        a.retarget(to: 100)
        advance(&a, frames: 5)
        let position = a.current
        let velocity = a.velocity
        #expect(velocity != 0)

        a.nudge(by: -40)
        #expect(a.current == position - 40)
        #expect(a.velocity == velocity)     // the distinction from `snap`, which zeroes it
        #expect(a.target == 100)            // and from `retarget`, which moves it
    }

    // The glide identity (what a trackpad lift is aimed at)
    //
    // A glide is not a new solver: it is a critically damped spring aimed at exactly `v/ω` ahead, where
    // `b = v + ωd₀` vanishes identically and the `(1 + …t)` term of the critical solution goes with it.
    // Asserted against the closed form rather than against a golden trace, because the closed form is
    // the claim.

    @Test func launchSetsVelocityAndMovesNothingElse() {
        var a = Animator(value: 30, params: .smooth)
        a.retarget(to: 90)
        a.launch(250)
        #expect(a.current == 30)
        #expect(a.target == 90)
        #expect(a.velocity == 250)
    }

    @Test func aSpringAimedAtVOverOmegaDecaysPurelyExponentially() {
        let omega = 10.0
        let spring = SpringParams(stiffness: omega * omega, dampingRatio: 1)
        let v = 600.0
        let start = 200.0
        let throwDistance = v / omega                     // 60 pt — the horizon `1/ω` names

        var a = Animator(value: start, params: spring)
        a.retarget(to: start + throwDistance)
        a.launch(v)

        var t = 0.0
        for _ in 0..<240 {
            a.advance(by: Self.dt)
            t += Self.dt
            let decay = exp(-omega * t)
            // error(t) = D·e^(−ωt), velocity(t) = v·e^(−ωt) — no `(1 + ωt)` term anywhere.
            #expect(abs((a.target - a.current) - throwDistance * decay) < 1e-6)
            #expect(abs(a.velocity - v * decay) < 1e-6)
        }
    }

    @Test func aGlideNeverOvershootsItsProjection() {
        let omega = 10.0
        let spring = SpringParams(stiffness: omega * omega, dampingRatio: 1)
        for v in [-4000.0, -600, -1, 1, 600, 4000] {
            var a = Animator(value: 0, params: spring)
            let rest = v / omega
            a.retarget(to: rest)
            a.launch(v)
            for _ in 0..<600 {
                a.advance(by: Self.dt)
                // Approached strictly from the side it started on, never through it.
                #expect(v > 0 ? a.current <= rest + 1e-9 : a.current >= rest - 1e-9)
            }
            #expect(abs(a.current - rest) < 1e-6)
        }
    }

    /// Settle is **logarithmic** in the throw, which is what makes the hold-timeout constraint
    /// satisfiable at any flick speed: quadrupling the velocity quadruples the distance and adds one
    /// `ln 4 / ω` to the wait.
    @Test func glideSettleGrowsLogarithmicallyWithTheThrow() {
        let omega = 10.0
        let spring = SpringParams(stiffness: omega * omega, dampingRatio: 1)
        func settle(_ v: Double) -> Double {
            var a = Animator(value: 0, params: spring)
            a.retarget(to: v / omega)
            a.launch(v)
            var t = 0.0
            // `Motion`'s own criterion: half a point, 30 pt/s.
            while !a.isSettled(epsilon: 0.5, velocityEpsilon: 30), t < 5 {
                a.advance(by: Self.dt)
                t += Self.dt
            }
            return t
        }
        let slow = settle(6000)          // 600 pt of throw
        let fast = settle(24_000)        // 2400 pt — four times as far
        #expect(slow < 0.75)             // both inside a 1 s hold-timeout, with margin
        #expect(fast < 0.9)
        #expect(fast - slow < 0.2)       // …and the extra distance costs ln(4)/ω ≈ 139 ms
    }

    /// The second press of a keybind arriving after the first has landed.
    @Test func nudgingASettledAnimatorPutsItBackInMotion() {
        var a = Animator(value: 0, params: .snappy)
        #expect(a.isSettled())

        a.nudge(by: 300)
        #expect(!a.isSettled())
        advance(&a, frames: 3000)
        #expect(a.isSettled())
        #expect(abs(a.current) < 0.01)      // back to the target it never left
    }
}
