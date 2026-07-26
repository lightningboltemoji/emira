import Foundation

/// Parameters for a damped-spring integrator (unit mass).
///
/// A strip scroll animates **one scalar** — the viewport offset — and per-window motion
/// (consume/expel, move-between-columns) each animates one scalar too. All of them are driven
/// by this spring. The core owns the clock and advances the spring itself on `tick(dt)`; we do
/// *not* hand motion to `CAAnimation` (PRINCIPLES.md §7, IMPLEMENTATION.md §1 invariant 2), which
/// is what makes velocity-preserving retargeting mid-flight pure arithmetic.
public struct SpringParams: Sendable, Equatable, Codable {
    /// Spring constant `k` (unit mass, so `ω = √k`). Larger = stiffer = faster.
    public var stiffness: Double
    /// Damping coefficient `c`. `ζ = c / (2√k)`: `<1` overshoots, `1` is critical, `>1` is sluggish.
    public var damping: Double

    public init(stiffness: Double, damping: Double) {
        self.stiffness = stiffness
        self.damping = damping
    }

    /// The physical spelling — and the one a **config file** uses (`damping-ratio = 1.0`,
    /// `stiffness = 800`), so published constants can be copied across rather than converted.
    /// `c = 2ζ√k`, which is the same arithmetic `critical(frequency:)` does at `ζ = 1`.
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

    /// The default for viewport scrolling: critically damped, `stiffness: 800, ζ: 1.0`.
    ///
    /// The constants are copied rather than guessed: they are what a scrollable-tiling compositor
    /// already ships for its viewport scroll, which is the motion this project exists to reproduce —
    /// so they are evidence rather than taste, and the one number here we did not have to invent.
    ///
    /// **Retuned 2026-07-25 (M4 part 2), and the arithmetic is worth keeping.** This was
    /// `response: 0.4` (ω = 15.7), and the product measured a one-column scroll at **605 ms**. For a
    /// critically-damped spring the remaining distance is `D(1 + ωt)e^(−ωt)`, so the settle time is
    /// `u/ω` where `u` solves `(1 + u)e^(−u) = ε/D` — with `Motion`'s ε = 0.5 pt over a 600 pt column,
    /// `u ≈ 9.45`, i.e. 0.602 s. The measurement and the model agree to 3 ms, which means the knob can
    /// be turned by calculation: at ω = √800 = 28.3 the same scroll settles in **334 ms**. Against the
    /// ~110 ms capture head that opens every transition (`CaptureService`), that is ~445 ms end to end
    /// where it used to be ~715 ms — the gap `PRINCIPLES.md` §10 opened against a ~300 ms feel,
    /// closed from both sides.
    public static let smooth = SpringParams.critical(frequency: 800.0.squareRoot())
    /// Quick with a touch of life — a slight overshoot, and no production consumer.
    ///
    /// It read "for discrete window moves" until the structural edits were animated, at which point
    /// the discrete window move arrived and deliberately **didn't** take it: two columns trading
    /// places overshoot *through* each other and come back, which reads as sloppy rather than alive,
    /// so window displacement stays critically damped like everything else that moves.
    /// Kept because the tests lean on it to reach settle in few frames, and because an underdamped
    /// spring is the only thing that exercises `Motion.settleVelocityEpsilon`'s fly-through guard.
    public static let snappy = SpringParams(response: 0.25, dampingRatio: 0.85)
}

/// Time-parameterized easing over `t ∈ [0, 1]`. Used for fixed-duration, non-physical fades
/// (e.g. the reconstruction cross-fade) where velocity carryover is irrelevant — distinct from
/// the spring, which owns interruptible window motion.
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
