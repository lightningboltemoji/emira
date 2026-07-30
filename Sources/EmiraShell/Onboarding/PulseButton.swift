import AppKit
import QuartzCore

// The one button emira ever asks anyone to press. Onboarding ends on a restart the *user* has to perform,
// so this control has a job no other part of the app has: to be obviously the next thing to do. A window
// that says "quit, then open it again" over a plain grey button reads as an error rather than an
// instruction.
//
// The drawing is deliberately not `NSButton`'s: a layer-backed button draws its cell into the layer's own
// contents, which any sublayer of ours would cover, so the title is a subview label and everything beneath
// it is layers. Clicks, target/action, the key equivalent and first responder stay `NSButton`'s.

/// A green, glowing, gently pulsing button.
@MainActor
final class PulseButton: NSButton {

    /// The wordmark's greens, so the button belongs to the window it sits in.
    private static let fill = [
        CGColor(srgbRed: 0.059, green: 0.545, blue: 0.302, alpha: 1),   // #0f8b4d
        CGColor(srgbRed: 0.137, green: 0.659, blue: 0.384, alpha: 1),   // #23a862
    ]

    private static let cornerRadius: CGFloat = 9

    private let base = CAGradientLayer()
    private let sheen = CAGradientLayer()
    private let label = NSTextField(labelWithString: "")

    init(title: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        // The cell must draw nothing at all: no bezel, no title, no focus ring of its own.
        self.title = ""
        isBordered = false
        focusRingType = .none
        setAccessibilityLabel(title)

        wantsLayer = true
        // The glow lives outside the bounds, so nothing above it may clip.
        layer?.masksToBounds = false
        layer?.shadowColor = Self.fill[0]
        layer?.shadowOffset = .zero
        layer?.shadowRadius = 6
        layer?.shadowOpacity = 0.35

        base.colors = Self.fill
        base.startPoint = CGPoint(x: 0.5, y: 0)
        base.endPoint = CGPoint(x: 0.5, y: 1)
        base.cornerRadius = Self.cornerRadius
        base.cornerCurve = .continuous
        base.masksToBounds = true                 // …and the sheen is clipped to the rounded rect
        layer?.addSublayer(base)

        // Five stops around a faint peak, spanning wider than the button: at mid-sweep the whole face is
        // inside the band, so it reads as a wash passing over rather than a line crossing. The extra pair
        // softens the ramp into the peak, a gradient interpolating its stops linearly.
        sheen.colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.04),
                        CGColor(gray: 1, alpha: 0.13), CGColor(gray: 1, alpha: 0.04),
                        CGColor(gray: 1, alpha: 0)]
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        sheen.locations = Self.sweepStart
        base.addSublayer(sheen)

        label.stringValue = title
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    required init?(coder: NSCoder) { return nil }     // never comes from a nib; there aren't any

    override func layout() {
        super.layout()
        base.frame = bounds
        sheen.frame = base.bounds
        // An explicit path, so the glow follows the rounded rect rather than the square bounds.
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius,
                                   cornerHeight: Self.cornerRadius, transform: nil)
    }

    /// A press has to feel like one, and nothing else here draws a highlight. `super.mouseDown` returns
    /// when the mouse comes up, which is exactly the span to dim for.
    override func mouseDown(with event: NSEvent) {
        layer?.opacity = 0.82
        super.mouseDown(with: event)
        layer?.opacity = 1
    }

    // MARK: - The animations

    /// Started on reaching a window, not at init: a layer with no window has nothing to commit its
    /// transaction to. They run inside the onboarding window's modal session because Core Animation is
    /// driven by the render server rather than by this process's run loop.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Someone who asked the system for less movement is not asking this button for an exception.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        breathe()
        sweep()
    }

    /// The glow, in and out. Both properties move together — a glow that brightens without spreading reads
    /// as a flat colour change.
    private func breathe() {
        let brightness = CABasicAnimation(keyPath: "shadowOpacity")
        brightness.fromValue = 0.25
        brightness.toValue = 0.8
        let spread = CABasicAnimation(keyPath: "shadowRadius")
        spread.fromValue = 5
        spread.toValue = 14

        let group = CAAnimationGroup()
        group.animations = [brightness, spread]
        group.duration = 1.3
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(group, forKey: "breathe")
    }

    /// Where the band rests: entirely off the leading edge, and 1.2 wide, so no edge of it is ever visible
    /// on the button's face.
    private static let sweepStart: [NSNumber] = [-1.2, -0.9, -0.6, -0.3, 0].map { NSNumber(value: $0) }
    private static let sweepEnd: [NSNumber] = [1.0, 1.3, 1.6, 1.9, 2.2].map { NSNumber(value: $0) }

    /// The band crossing the face, then waiting — half the cycle each way, because a shimmer with no rest
    /// in it reads as a progress indicator, and a quick one reads as a warning.
    private func sweep() {
        let band = CAKeyframeAnimation(keyPath: "locations")
        band.values = [Self.sweepStart, Self.sweepEnd, Self.sweepEnd]
        band.keyTimes = [0, 0.5, 1]
        band.duration = 3.2
        band.repeatCount = .infinity
        band.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sheen.add(band, forKey: "sweep")
    }
}
