import Testing
@testable import EmiraMotion

/// Integrator-level properties of the analytic damped spring.
@Suite struct SpringTests {
    // 120 Hz frame, the display floor we design against.
    static let dt = 1.0 / 120.0

    /// Run a spring to rest, returning the peak displacement past the target (for overshoot checks).
    private func peakToward(_ target: Double, from start: Double,
                            _ params: SpringParams, steps: Int) -> (peak: Double, end: (Double, Double)) {
        var current = start
        var velocity = 0.0
        var peak = start
        for _ in 0..<steps {
            let next = Spring.step(current: current, velocity: velocity,
                                   target: target, params: params, dt: Self.dt)
            current = next.current
            velocity = next.velocity
            peak = max(peak, current)
        }
        return (peak, (current, velocity))
    }

    @Test func criticalIsStableForAnyDt() {
        // A stiff spring with a huge dt must not blow up — the reason we integrate analytically.
        let stiff = SpringParams.critical(frequency: 200)
        let next = Spring.step(current: 0, velocity: 0, target: 1_000,
                               params: stiff, dt: 10.0)
        #expect(next.current.isFinite)
        #expect(abs(next.current - 1_000) < 1e-6)  // fully settled after a 10 s step
        #expect(abs(next.velocity) < 1e-6)
    }

    @Test func criticallyDampedDoesNotOvershoot() {
        let (peak, end) = peakToward(100, from: 0, .critical(frequency: 25), steps: 900)
        #expect(peak <= 100 + 1e-6)                 // no overshoot
        #expect(abs(end.0 - 100) < 0.01)            // arrives
    }

    @Test func overdampedDoesNotOvershoot() {
        let over = SpringParams(response: 0.3, dampingRatio: 1.8)
        let (peak, end) = peakToward(10, from: 0, over, steps: 3000)
        #expect(peak <= 10 + 1e-6)
        #expect(abs(end.0 - 10) < 0.01)
    }

    @Test func underdampedOvershootsThenSettles() {
        let under = SpringParams(response: 0.3, dampingRatio: 0.35)
        let (peak, end) = peakToward(1, from: 0, under, steps: 1500)
        #expect(peak > 1)                           // characteristic overshoot
        #expect(abs(end.0 - 1) < 0.01)              // still converges
        #expect(abs(end.1) < 0.01)
    }

    @Test func atRestAtTargetStaysExactlyPut() {
        let next = Spring.step(current: 42, velocity: 0, target: 42,
                               params: .smooth, dt: Self.dt)
        #expect(next.current == 42)
        #expect(next.velocity == 0)
    }

    /// The spelling a config file uses (`stiffness`/`damping-ratio`) has to agree exactly with
    /// `critical(frequency:)` at ζ = 1, since `.smooth` is defined by the latter.
    @Test func theStiffnessAndRatioSpellingRoundTrips() {
        let spring = SpringParams(stiffness: 800, dampingRatio: 1.0)
        #expect(abs(spring.stiffness - SpringParams.smooth.stiffness) < 1e-9)
        #expect(abs(spring.damping - SpringParams.smooth.damping) < 1e-9)
        #expect(abs(spring.dampingRatio - 1.0) < 1e-12)

        let underdamped = SpringParams(stiffness: 400, dampingRatio: 0.5)
        #expect(abs(underdamped.dampingRatio - 0.5) < 1e-12)
        #expect(underdamped.damping == 2 * 0.5 * 20)          // c = 2ζ√k, √400 = 20
    }

    @Test func nonPositiveDtIsANoOp() {
        let a = Spring.step(current: 3, velocity: 7, target: 0, params: .smooth, dt: 0)
        #expect(a.current == 3 && a.velocity == 7)
        let b = Spring.step(current: 3, velocity: 7, target: 0, params: .smooth, dt: -0.5)
        #expect(b.current == 3 && b.velocity == 7)
    }
}
