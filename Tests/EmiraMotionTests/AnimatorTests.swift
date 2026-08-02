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
