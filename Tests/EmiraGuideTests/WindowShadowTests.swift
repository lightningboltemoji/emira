import CoreGraphics
import Foundation
import QuartzCore
import Testing
import EmiraMotion
@testable import EmiraGuide

// The two shadows macOS draws, and the room anything standing in for a window has to leave them.

@Suite struct WindowShadowTests {

    /// The point of there being two: a stand-in shadowed with the wrong one is a halo. macOS's key
    /// window shadow is more than twice as broad as the other and drops nearly three times as far, so
    /// no single compromise stands in for both.
    @Test func theTwoShadowsAreNotAVariantOfEachOther() {
        #expect(WindowShadow.focused.radius > WindowShadow.unfocused.radius * 2)
        #expect(WindowShadow.focused.drop > WindowShadow.unfocused.drop * 2)
        #expect(WindowShadow.focused.opacity > WindowShadow.unfocused.opacity)
        #expect(WindowShadow.of(focused: true) == .focused)
        #expect(WindowShadow.of(focused: false) == .unfocused)
    }

    /// Every length scales with the projection and the opacity — which is not one — does not. The
    /// settings mock draws these at `k`, and an opacity that scaled would fade its panes.
    @Test func scalingTakesTheLengthsAndLeavesTheOpacity() {
        let half = WindowShadow.focused.scaled(by: 0.5)
        #expect(half.radius == WindowShadow.focused.radius / 2)
        #expect(half.drop == WindowShadow.focused.drop / 2)
        #expect(half.opacity == WindowShadow.focused.opacity)
        #expect(WindowShadow.focused.scaled(by: 1) == .focused)
    }

    /// Three σ is where a Gaussian's tail ends, and the silhouette is dropped before it is blurred, so
    /// the far side reaches by both.
    @Test func reachIsThreeSigmaPastTheDrop() {
        #expect(WindowShadow.focused.reach == 20 * 3 + 17.5)
        #expect(WindowShadow.maxReach == WindowShadow.focused.reach)
        #expect(WindowShadow.maxReach > WindowShadow.unfocused.reach)
    }

    /// The pad exists so a smear frame does not clip what it smears, and a `CIMotionBlur` clips to the
    /// layer carrying it. So the margin has to hold the longest smear *and* the widest shadow — a
    /// constant that stopped short of either is a hard edge that appears only while a window moves.
    @MainActor @Test func theSmearPadLeavesRoomForTheWidestShadowAndTheLongestSmear() {
        #expect(SmearLayer.margin >= CGFloat(WindowShadow.maxReach))
        #expect(SmearLayer.margin >= CGFloat(Smear.maxSigma) * 3)
        #expect(SmearLayer.margin == CGFloat(Smear.maxSigma) * 3 + CGFloat(WindowShadow.maxReach))
    }

    /// The layer property is a `y`-up offset, so a shadow that drops has a *negative* height. Getting
    /// the sign wrong lifts every shadow above its window.
    @MainActor @Test func applyingADropNegatesItForTheLayer() {
        let layer = CALayer()
        WindowShadow.focused.apply(to: layer)
        #expect(layer.shadowOpacity == WindowShadow.focused.opacity)
        #expect(layer.shadowRadius == CGFloat(WindowShadow.focused.radius))
        #expect(layer.shadowOffset == CGSize(width: 0, height: -WindowShadow.focused.drop))
    }
}
