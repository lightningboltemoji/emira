import Foundation

/// Analytic damped-spring integrator.
///
/// One `step` advances a `(position, velocity)` system by `dt` toward `target`. We use the
/// closed-form solution of the damped-harmonic-oscillator ODE rather than an explicit Euler step,
/// so the result is **numerically stable for any `dt`** — a 120 Hz frame and a hitchy 40 ms frame
/// both land on the physically-correct state, with no blow-up when a stiff spring meets a long dt.
public enum Spring {
    /// Advance one step of length `dt` toward `target`.
    /// - Returns: the new `(current, velocity)`. `dt <= 0` is a no-op.
    public static func step(
        current: Double,
        velocity: Double,
        target: Double,
        params: SpringParams,
        dt: Double
    ) -> (current: Double, velocity: Double) {
        guard dt > 0 else { return (current, velocity) }

        let omega = params.naturalFrequency
        guard omega > 0 else {
            // No restoring force: degenerate to constant-velocity drift.
            return (current + velocity * dt, velocity)
        }

        let zeta = params.dampingRatio
        let d0 = current - target          // displacement from equilibrium
        let v0 = velocity

        let newDisplacement: Double
        let newVelocity: Double

        if zeta < 1 - 1e-9 {
            // Underdamped — oscillates toward rest.
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega * dt)
            let cosT = cos(wd * dt)
            let sinT = sin(wd * dt)
            let a = d0
            let b = (v0 + zeta * omega * d0) / wd
            newDisplacement = decay * (a * cosT + b * sinT)
            newVelocity = decay * ((b * wd - zeta * omega * a) * cosT
                                   - (a * wd + zeta * omega * b) * sinT)
        } else if zeta <= 1 + 1e-9 {
            // Critically damped — fastest approach with no overshoot.
            let decay = exp(-omega * dt)
            let a = d0
            let b = v0 + omega * d0
            newDisplacement = (a + b * dt) * decay
            newVelocity = (b - omega * (a + b * dt)) * decay
        } else {
            // Overdamped — two real roots, no overshoot, slower settle.
            let root = omega * (zeta * zeta - 1).squareRoot()
            let r1 = -zeta * omega + root
            let r2 = -zeta * omega - root
            let c1 = (v0 - r2 * d0) / (r1 - r2)
            let c2 = d0 - c1
            let e1 = exp(r1 * dt)
            let e2 = exp(r2 * dt)
            newDisplacement = c1 * e1 + c2 * e2
            newVelocity = r1 * c1 * e1 + r2 * c2 * e2
        }

        return (target + newDisplacement, newVelocity)
    }
}
