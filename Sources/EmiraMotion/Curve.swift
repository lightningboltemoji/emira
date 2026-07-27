import Foundation

/// Parameters for a damped-spring integrator (unit mass).
public struct SpringParams: Sendable, Equatable, Codable {
    /// Spring constant `k` (unit mass, so `ω = √k`). Larger = stiffer = faster.
    public var stiffness: Double
    /// Damping coefficient `c`. `ζ = c / (2√k)`: `<1` overshoots, `1` is critical, `>1` is sluggish.
    public var damping: Double

    public init(stiffness: Double, damping: Double) {
        self.stiffness = stiffness
        self.damping = damping
    }

    /// The physical spelling, and the one a config file uses: `c = 2ζ√k`.
    /// - Parameters:
    ///   - stiffness: spring constant `k` (unit mass).
    ///   - dampingRatio: `ζ` — `1.0` = critically damped.
    public init(stiffness: Double, dampingRatio zeta: Double) {
        self.stiffness = stiffness
        self.damping = 2 * zeta * stiffness.squareRoot()
    }

    /// SwiftUI-style ergonomic constructor.
    /// - Parameters:
    ///   - response: approximate settle period in seconds (`ω = 2π / response`).
    ///   - dampingRatio: `ζ` — `1.0` = critically damped (fast, no overshoot).
    public init(response: Double, dampingRatio zeta: Double) {
        let omega = 2 * Double.pi / response
        self.stiffness = omega * omega
        self.damping = 2 * zeta * omega
    }

    /// Natural angular frequency `ω = √(k/m)` with `m = 1`.
    public var naturalFrequency: Double { stiffness.squareRoot() }

    /// Damping ratio `ζ = c / (2√k)`.
    public var dampingRatio: Double {
        let denom = 2 * stiffness.squareRoot()
        return denom > 0 ? damping / denom : 0
    }

    /// A critically-damped spring (`ζ = 1`) at the given natural frequency.
    public static func critical(frequency omega: Double) -> SpringParams {
        SpringParams(stiffness: omega * omega, damping: 2 * omega)
    }

    /// The default for viewport scrolling: critically damped at `k = 800`, i.e. ω = √800 ≈ 28.3. Turnable
    /// by calculation — remaining distance is `D(1 + ωt)e^(−ωt)`, so settle time is `u/ω` where `u` solves
    /// `(1 + u)e^(−u) = ε/D`; at `Motion`'s ε = 0.5 pt over a 600 pt column, ~334 ms.
    public static let smooth = SpringParams.critical(frequency: 800.0.squareRoot())
    /// Quick with a touch of life — a slight overshoot, and no production consumer: structural moves
    /// deliberately don't take it, because two columns trading places overshoot *through* each other and
    /// come back. Kept because the tests need few-frame settles and an underdamped spring to exercise
    /// `Motion.settleVelocityEpsilon`.
    public static let snappy = SpringParams(response: 0.25, dampingRatio: 0.85)
}

/// Time-parameterized easing over `t ∈ [0, 1]`, for fixed-duration non-physical fades (the reconstruction
/// cross-fade) where velocity carryover is irrelevant. The spring owns interruptible window motion.
public enum Easing: Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut

    /// Evaluate the eased progress. `t` is clamped to `[0, 1]`; every curve maps `0→0` and `1→1`.
    public func callAsFunction(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear:    return t
        case .easeIn:    return t * t * t
        case .easeOut:   return 1 - pow(1 - t, 3)
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }
    }
}
