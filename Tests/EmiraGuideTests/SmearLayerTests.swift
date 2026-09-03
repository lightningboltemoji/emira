import CoreGraphics
import Foundation
import QuartzCore
import Testing
import EmiraMotion
@testable import EmiraGuide

// The smear's plumbing, off-screen: a `CALayer` answers whether the filter is on, what it was asked
// for and where the pad sits — everything but the look, which is the window server's.

@MainActor
@Suite struct SmearLayerTests {

    /// No attack, so a step's σ arrives whole and the test is not timing its own placements.
    static let blur = MotionBlur(shutter: 0.5, attack: 0)
    static let box = 1 / 12.0.squareRoot()

    static func rect(_ x: CGFloat, _ y: CGFloat = 100) -> CGRect {
        CGRect(x: x, y: y, width: 400, height: 300)
    }

    /// What the filter was asked for, read back the way it was written.
    static func radius(of smear: SmearLayer) -> Double? {
        smear.layer.value(forKeyPath: "filters.smear.inputRadius") as? Double
    }
    static func angle(of smear: SmearLayer) -> Double? {
        smear.layer.value(forKeyPath: "filters.smear.inputAngle") as? Double
    }

    @Test func theContentSitsInsideThePadByTheMargin() {
        let smear = SmearLayer(hosting: CALayer())
        smear.place(Self.rect(100), blur: Self.blur)
        let margin = SmearLayer.margin
        #expect(smear.layer.frame == Self.rect(100).insetBy(dx: -margin, dy: -margin))
        #expect(smear.content.frame == CGRect(x: margin, y: margin, width: 400, height: 300))
        #expect(smear.content.superlayer === smear.layer)
    }

    @Test func theMarginScalesWithTheProjection() {
        let smear = SmearLayer(hosting: CALayer())
        smear.place(Self.rect(100), blur: Self.blur, scale: 0.25)
        let margin = SmearLayer.margin / 4
        #expect(smear.content.frame.origin == CGPoint(x: margin, y: margin))
    }

    @Test func theFirstPlacementIsAnOriginNotAStep() {
        let smear = SmearLayer(hosting: CALayer())
        smear.place(Self.rect(1000), blur: Self.blur)
        #expect(smear.layer.filters == nil)
    }

    @Test func aStepInstallsTheFilterAlongItself() throws {
        let smear = SmearLayer(hosting: CALayer())
        smear.place(Self.rect(0), blur: Self.blur)
        smear.place(Self.rect(100), blur: Self.blur)
        #expect(smear.layer.filters?.count == 1)
        let radius = try #require(Self.radius(of: smear))
        #expect(abs(radius - 50 * Self.box) < 1e-9)
        #expect(Self.angle(of: smear) == 0)
        smear.place(Self.rect(100, 200), blur: Self.blur)          // straight up, y up
        let angle = try #require(Self.angle(of: smear))
        #expect(abs(angle - .pi / 2) < 1e-9)
    }

    @Test func aStepTooShortTakesTheFilterOff() {
        let smear = SmearLayer(hosting: CALayer())
        smear.place(Self.rect(0), blur: Self.blur)
        smear.place(Self.rect(100), blur: Self.blur)
        #expect(smear.layer.filters != nil)
        smear.place(Self.rect(102), blur: Self.blur)
        #expect(smear.layer.filters == nil)
    }

    @Test func aResizeAnchoredAtTheTopLeftIsNotAStep() {
        let smear = SmearLayer(hosting: CALayer())
        smear.place(CGRect(x: 100, y: 100, width: 400, height: 300), blur: Self.blur)
        // Wider and shorter, with the top-left where it was.
        smear.place(CGRect(x: 100, y: 200, width: 600, height: 200), blur: Self.blur)
        #expect(smear.layer.filters == nil)
    }

    @Test func forgetMakesTheNextPlacementAnOrigin() {
        let smear = SmearLayer(hosting: CALayer())
        smear.place(Self.rect(0), blur: Self.blur)
        smear.place(Self.rect(100), blur: Self.blur)
        smear.forget()
        #expect(smear.layer.filters == nil)
        smear.place(Self.rect(1000), blur: Self.blur)
        #expect(smear.layer.filters == nil)
    }

    /// A placement with the blur off draws nothing but still says where the content is, so the frame
    /// that turns it on measures from there — the mock's snaps, and the desktop's reload to a shutter.
    @Test func anUnsmearedPlacementStillRecordsTheOrigin() throws {
        let smear = SmearLayer(hosting: CALayer())
        smear.place(Self.rect(0), blur: .off)
        smear.place(Self.rect(100), blur: .off)
        #expect(smear.layer.filters == nil)
        smear.place(Self.rect(200), blur: Self.blur)
        let radius = try #require(Self.radius(of: smear))
        #expect(abs(radius - 50 * Self.box) < 1e-9)
    }
}
