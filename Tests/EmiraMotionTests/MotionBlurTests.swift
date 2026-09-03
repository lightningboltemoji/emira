import Foundation
import Testing
@testable import EmiraMotion

/// The smear's envelope: σ from a step, an attack on the way up, none on the way down.
@Suite struct MotionBlurTests {
    static let frame = 1.0 / 60.0
    static let box = 1 / 12.0.squareRoot()

    /// One frame's advance, in a form the macros can hold: they cannot call a mutating member.
    private static func step(_ smear: inout Smear, _ length: Double, over elapsed: Double = frame,
                             blur: MotionBlur, scale: Double = 1) -> Double? {
        smear.advance(step: length, elapsed: elapsed, blur: blur, scale: scale)
    }

    @Test func aStepUnderTheThresholdSmearsNothing() {
        var smear = Smear()
        let sigma = Self.step(&smear, Smear.minStep - 1, blur: MotionBlur())
        #expect(sigma == nil)
        #expect(smear.sigma == 0)
    }

    @Test func aShutterOfZeroIsOffWhateverTheStep() {
        var smear = Smear()
        let sigma = Self.step(&smear, 500, blur: .off)
        #expect(sigma == nil)
    }

    /// A step past the threshold under a shutter so low that its smear would be a softened edge is not
    /// worth the offscreen pass; the same shutter over a longer step is.
    @Test func aSigmaUnderHalfAPointIsNotWorthAPass() throws {
        let faint = MotionBlur(shutter: 0.1, attack: 0)
        var smear = Smear()
        #expect(Self.step(&smear, Smear.minStep + 2, blur: faint) == nil)
        #expect(smear.sigma == 0)
        let sigma = try #require(Self.step(&smear, 50, blur: faint))
        #expect(abs(sigma - 5 * Self.box) < 1e-9)
    }

    @Test func sigmaIsTheShuttersShareOfTheStepAsABoxesSigma() throws {
        var smear = Smear()
        let sigma = try #require(Self.step(&smear, 100, blur: MotionBlur(shutter: 0.5, attack: 0)))
        #expect(abs(sigma - 50 * Self.box) < 1e-9)
    }

    @Test func sigmaIsCappedHoweverFarTheStep() throws {
        var smear = Smear()
        let sigma = try #require(Self.step(&smear, 10_000, blur: MotionBlur(shutter: 1, attack: 0)))
        #expect(sigma == Smear.maxSigma)
    }

    /// A step held for `attack` seconds is nine tenths smeared, not all of it at once.
    @Test func aRiseLagsByTheAttack() throws {
        let blur = MotionBlur(shutter: 0.5, attack: 0.05)
        let full = 50 * Self.box
        var smear = Smear()
        var sigma = try #require(Self.step(&smear, 100, blur: blur))
        #expect(sigma < full * 0.6)
        // Three 60 Hz frames are the attack.
        for _ in 0..<2 { sigma = try #require(Self.step(&smear, 100, blur: blur)) }
        #expect(abs(sigma - full * 0.9) < 1e-9)
    }

    /// A layer that sat still and then moved has a frame to lag over, not the pause before it — the
    /// first frame after a pause is as lagged as the first frame from rest.
    @Test func aPauseIsNotALongFrame() throws {
        let blur = MotionBlur(shutter: 0.5, attack: 0.05)
        var rested = Smear()
        let fromRest = try #require(Self.step(&rested, 100, over: Smear.longestFrame, blur: blur))
        var paused = Smear()
        let afterPause = try #require(Self.step(&paused, 100, over: 2, blur: blur))
        #expect(afterPause == fromRest)
        #expect(afterPause < 50 * Self.box * 0.6)
    }

    @Test func aFallIsFollowedAtOnce() throws {
        let blur = MotionBlur(shutter: 0.5, attack: 0.05)
        var smear = Smear()
        for _ in 0..<12 { _ = Self.step(&smear, 200, blur: blur) }   // four attacks: all there
        let fallen = try #require(Self.step(&smear, 40, blur: blur))
        #expect(abs(fallen - 20 * Self.box) < 1e-9)
        let stopped = Self.step(&smear, 0, blur: blur)
        #expect(stopped == nil)
        #expect(smear.sigma == 0)
    }

    /// The mock desktop is the same geometry through one scalar, so its thresholds are too.
    @Test func theThresholdsScaleWithTheProjection() throws {
        var smear = Smear()
        let under = Self.step(&smear, 10, blur: MotionBlur(), scale: 2)
        #expect(under == nil)
        let capped = try #require(Self.step(&smear, 10_000, over: 1,
                                            blur: MotionBlur(shutter: 1, attack: 0), scale: 0.25))
        #expect(capped == Smear.maxSigma * 0.25)
    }
}
