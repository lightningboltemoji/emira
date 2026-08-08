import AppKit
import QuartzCore

// What the scrim carries: the mock monitor with the control slab under it, one centred stack, and the
// thing that is *placed* on the desktop rather than merely shown over it.
//
// It is a view because the presentation belongs to the stack as a whole. **A scrim cannot zoom** — its
// edges are the screen's, and a scaled one would show desktop down one side and crop the other — so
// what travels is the stack, and one container is what lets a single transform carry both halves of it
// about a single centre. It owns the stacking for the same reason: the window centres one rect, and
// the arithmetic that says the monitor is above the slab has one home.

@MainActor
final class Stage: NSView {

    /// The composition's two states. `lifted` is where it comes down from and where it goes back to:
    /// a few percent above the glass and not there at all, which are one state and not two — the
    /// dissolve and the travel are the same act seen at the scrim and at the stack.
    enum Placement {
        case seated
        case lifted

        var scale: CGFloat {
            switch self {
            case .seated: return 1
            case .lifted: return SettingsStyle.liftedScale
            }
        }

        /// What the scrim windows are worth at this placement.
        var alpha: CGFloat {
            switch self {
            case .seated: return 1
            case .lifted: return 0
            }
        }
    }

    let desktop: DesktopView
    let slab: ControlSlab

    private(set) var placement: Placement = .seated

    /// Stacked and centred, and the stage is exactly their bounds — so the window centring this rect
    /// centres the stack, and the zoom's fixed point is the composition's own middle.
    init(desktop: DesktopView, slab: ControlSlab) {
        self.desktop = desktop
        self.slab = slab
        let width = max(desktop.mockSize.width, slab.frame.width)
        let height = desktop.mockSize.height + SettingsStyle.stackGap + slab.frame.height
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        wantsLayer = true

        desktop.frame = CGRect(x: ((width - desktop.mockSize.width) / 2).rounded(),
                               y: (height - desktop.mockSize.height).rounded(),
                               width: desktop.mockSize.width, height: desktop.mockSize.height)
        slab.frame = CGRect(x: ((width - slab.frame.width) / 2).rounded(), y: 0,
                            width: slab.frame.width, height: slab.frame.height)
        addSubview(desktop)
        addSubview(slab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The gap between the monitor and the slab is blur, and a click there is a click on the blur.
    /// `NSView` answers `self` for any point inside its bounds, and taking that answer would punch a
    /// stack-sized hole in the one gesture that closes the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Put the composition at `placement`, taking `over` seconds to get there. Zero — the default —
    /// arrives already there, which is what a rebuild and Reduce Motion both want.
    func move(to placement: Placement, over duration: TimeInterval = 0) {
        guard let layer else { return }
        let from = self.placement
        self.placement = placement
        layer.transform = Self.zoom(placement.scale, size: bounds.size, anchor: layer.anchorPoint)
        guard duration > 0, from != placement else {
            return layer.removeAnimation(forKey: Self.travelKey)
        }
        let travel = CABasicAnimation(keyPath: "transform")
        travel.fromValue = Self.zoom(from.scale, size: bounds.size, anchor: layer.anchorPoint)
        travel.duration = duration
        travel.timingFunction = SettingsStyle.presentCurve
        layer.add(travel, forKey: Self.travelKey)
    }

    private static let travelKey = "placement"

    /// The transform that scales a layer about the middle of its bounds.
    ///
    /// **A layer's transform is applied about its anchor point**, and an AppKit backing layer anchors at
    /// its origin — so a bare `CATransform3DMakeScale` would drag the stack down and to the left as it
    /// shrank. Offsetting by the distance from the anchor to the centre is what pins the composition's
    /// middle, whatever anchor the view happens to carry.
    static func zoom(_ scale: CGFloat, size: CGSize, anchor: CGPoint) -> CATransform3D {
        let dx = (0.5 - anchor.x) * size.width
        let dy = (0.5 - anchor.y) * size.height
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -dx, -dy, 0)
    }
}
