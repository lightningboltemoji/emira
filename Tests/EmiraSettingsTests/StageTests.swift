import AppKit
import QuartzCore
import Testing
import EmiraCore
@testable import EmiraSettings

// The composition as one object: what it is made of, and how it is placed.
//
// The zoom is the part worth pinning. It is applied about a layer's **anchor point** rather than about
// anything the eye would call a centre, and an AppKit backing layer anchors at its origin — so the
// difference between a correct transform and one that slides the whole stack towards a corner as it
// travels is the offset these tests measure.

@MainActor
@Suite struct StageTests {

    /// A 1512 × 982 display drawn at the mock's own fraction, which is what the window builds.
    static func stage() -> Stage {
        let projection = Projection(displayFrame: Rect(x: 0, y: 0, width: 1512, height: 982),
                                    workingArea: Rect(x: 0, y: 25, width: 1512, height: 957),
                                    k: SettingsStyle.mockWidthFraction)
        return Stage(desktop: DesktopView(projection: projection, backingScale: 2),
                     slab: ControlSlab())
    }

    static func apply(_ transform: CATransform3D, to point: CGPoint) -> CGPoint {
        #expect(CATransform3DIsAffine(transform), "the zoom is a scale and a translation, nothing more")
        return point.applying(CATransform3DGetAffineTransform(transform))
    }

    /// The point the eye is watching. In the space a layer's transform acts in, the origin is the
    /// anchor point, so the middle of the bounds is however far the anchor is from it.
    static func centre(size: CGSize, anchor: CGPoint) -> CGPoint {
        CGPoint(x: (0.5 - anchor.x) * size.width, y: (0.5 - anchor.y) * size.height)
    }

    // The zoom

    @Test func theCentreDoesNotMove() {
        let size = CGSize(width: 786, height: 934)
        // Whatever the anchor: the bottom-left AppKit hands a backing layer, the middle Core Animation
        // defaults to, and one that is neither.
        for anchor in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 0.25)] {
            let centre = Self.centre(size: size, anchor: anchor)
            let moved = Self.apply(Stage.zoom(1.04, size: size, anchor: anchor), to: centre)
            #expect(abs(moved.x - centre.x) < 1e-9)
            #expect(abs(moved.y - centre.y) < 1e-9)
        }
    }

    @Test func aCornerTravelsItsOwnDistanceFromTheCentre() {
        let size = CGSize(width: 786, height: 934)
        let anchor = CGPoint(x: 0, y: 0)
        let scale: CGFloat = 1.04
        let centre = Self.centre(size: size, anchor: anchor)
        let corner = CGPoint(x: 0, y: 0)
        let moved = Self.apply(Stage.zoom(scale, size: size, anchor: anchor), to: corner)
        // Outward, by the fraction of its own offset — which is what makes the zoom uniform rather
        // than a stack that also drifts.
        #expect(abs(moved.x - (centre.x + (corner.x - centre.x) * scale)) < 1e-9)
        #expect(abs(moved.y - (centre.y + (corner.y - centre.y) * scale)) < 1e-9)
    }

    @Test func seatedIsTheIdentity() {
        let size = CGSize(width: 786, height: 934)
        let anchor = CGPoint(x: 0, y: 0)
        #expect(Stage.Placement.seated.scale == 1)
        #expect(CATransform3DIsIdentity(Stage.zoom(Stage.Placement.seated.scale,
                                                  size: size, anchor: anchor)))
        // Lifted is above the glass and gone, and both halves of that are one state.
        #expect(Stage.Placement.lifted.scale > 1)
        #expect(Stage.Placement.lifted.alpha == 0)
        #expect(Stage.Placement.seated.alpha == 1)
    }

    // The stack

    @Test func theStageIsExactlyTheStack() {
        let stage = Self.stage()
        let height = stage.desktop.mockSize.height + SettingsStyle.stackGap + stage.slab.frame.height
        #expect(stage.frame.height == height)
        #expect(stage.frame.width == max(stage.desktop.mockSize.width, stage.slab.frame.width))
    }

    @Test func theMonitorSitsOverTheSlabAndBothAreCentred() {
        let stage = Self.stage()
        #expect(stage.slab.frame.minY == 0)
        #expect(abs(stage.desktop.frame.minY - (stage.slab.frame.maxY + SettingsStyle.stackGap)) <= 1)
        #expect(abs(stage.desktop.frame.midX - stage.bounds.midX) <= 1)
        #expect(abs(stage.slab.frame.midX - stage.bounds.midX) <= 1)
    }

    @Test func theGapBetweenThemIsBlurAndNotTheStage() {
        let stage = Self.stage()
        let host = NSView(frame: CGRect(origin: .zero, size: stage.frame.size))
        host.addSubview(stage)

        // Between the monitor and the slab there is nothing but scrim, and a click there has to reach
        // it — that is the double click that dismisses.
        let gap = CGPoint(x: stage.bounds.midX, y: stage.slab.frame.maxY + SettingsStyle.stackGap / 2)
        #expect(stage.hitTest(gap) == nil)
        // Beside the slab, inside the stage's own width, for the same reason.
        #expect(stage.hitTest(CGPoint(x: 1, y: stage.slab.frame.midY)) == nil)

        #expect(stage.hitTest(CGPoint(x: stage.bounds.midX, y: stage.desktop.frame.midY))
                    === stage.desktop)
        #expect(stage.hitTest(CGPoint(x: stage.slab.frame.midX, y: stage.slab.frame.midY)) != nil)
    }

    // Placement

    @Test func movingWithNoDurationArrivesAtOnce() {
        let stage = Self.stage()
        stage.move(to: .lifted)
        #expect(stage.placement == .lifted)
        #expect(stage.layer?.animation(forKey: "placement") == nil)
        let expected = Stage.zoom(Stage.Placement.lifted.scale, size: stage.bounds.size,
                                  anchor: stage.layer?.anchorPoint ?? .zero)
        #expect(CATransform3DEqualToTransform(stage.layer?.transform ?? CATransform3DIdentity,
                                              expected))
    }

    @Test func travellingLeavesTheModelAtTheDestination() {
        let stage = Self.stage()
        stage.move(to: .lifted)
        stage.move(to: .seated, over: SettingsStyle.present)

        // The animation is the journey; the layer already holds where it ends up, so an interrupted
        // one still leaves the composition seated.
        #expect(stage.placement == .seated)
        #expect(CATransform3DIsIdentity(stage.layer?.transform ?? CATransform3DIdentity))
        let travel = stage.layer?.animation(forKey: "placement") as? CABasicAnimation
        #expect(travel?.duration == SettingsStyle.present)
        // Setting down is lifting off reversed, which needs the two to be one curve.
        #expect(travel?.timingFunction == SettingsStyle.presentCurve)
    }
}
