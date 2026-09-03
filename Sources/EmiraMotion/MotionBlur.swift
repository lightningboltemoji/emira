import Foundation

/// How a fast frame is smeared — the shutter of a film camera, as two numbers. A frame is one still
/// held for a refresh, and a window a spring moves 100 pt between two stills reads as a strobe; a
/// shutter integrates the motion each frame covers, so it reads as a smear instead.
public struct MotionBlur: Sendable, Equatable, Codable {
    /// The fraction of one frame's step that is smeared: `0.5` is cinema's 180° shutter, `0` is off.
    public var shutter: Double
    /// Seconds a rising smear takes to reach nine tenths of its step; a falling one is followed at once.
    public var attack: Double

    public init(shutter: Double = 0.5, attack: Double = 0.05) {
        self.shutter = shutter
        self.attack = attack
    }

    /// No smear at all.
    public static let off = MotionBlur(shutter: 0, attack: 0)
}

/// One moving thing's smear, frame by frame: the σ of a Gaussian along its step, lagging a rise by the
/// blur's `attack` and following a fall at once, so the settle is as crisp as the still.
public struct Smear: Sendable, Equatable {
    /// The σ on screen, in points.
    public private(set) var sigma: Double = 0

    public init() {}

    /// The shortest step, in points per frame, worth smearing; under it the strobe is not visible.
    public static let minStep = 8.0
    /// The shortest σ, in points, worth an offscreen pass; under it the smear is a softened edge and
    /// nothing more. A step that clears `minStep` under a low shutter is what this stops.
    public static let minSigma = 0.5
    /// The longest σ ever asked for, in points: a longer smear is a fault in the spring, not a look.
    public static let maxSigma = 32.0
    /// The longest interval one frame is taken to cover, in seconds. A gap longer than this is a pause,
    /// and the lag runs over the frame that ends it — the one the display shows — not over the pause.
    public static let longestFrame = 1 / 60.0
    /// σ per point of smear. A shutter's even smear over `L` is a box whose σ is `L/√12`, and a
    /// Gaussian of that σ carries the same spread.
    public static let sigmaPerPoint = 1 / 12.0.squareRoot()

    /// Advance by one frame that moved `length` points over `elapsed` seconds: the σ to draw, or `nil`
    /// when there is nothing to smear. `scale` is the projection the points are in — the settings
    /// mock's, or 1 on the desktop — so the thresholds hold at any size.
    public mutating func advance(step length: Double, elapsed: Double, blur: MotionBlur,
                                 scale: Double = 1) -> Double? {
        let target = min(length * blur.shutter * Self.sigmaPerPoint, Self.maxSigma * scale)
        guard length >= Self.minStep * scale, target >= Self.minSigma * scale else {
            sigma = 0
            return nil
        }
        if target <= sigma || blur.attack <= 0 {
            sigma = target
        } else {
            // First order: nine tenths of the way to a held target after `attack` seconds.
            let frame = min(elapsed, Self.longestFrame)
            sigma += (target - sigma) * (1 - exp(-frame * log(10) / blur.attack))
        }
        return sigma
    }
}
