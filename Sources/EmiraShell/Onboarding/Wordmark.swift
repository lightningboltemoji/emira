import AppKit
import QuartzCore

// The window's heading: the README's wordmark, animated — each letter of "emira" is a window, emira's
// commands play on them, and the word rests whole before they start again. `WordmarkScene` says where
// every window is at an instant; this draws that as a few layers per window.
//
// The view keeps the clock itself: every display refresh asks the scene for the instant it will reach the
// glass and moves the layers there. Nothing is baked, so a 120 Hz display gets every frame and any backing
// scale is crisp. A refresh that would draw what is already up — most of a hold — commits nothing.

/// The animated wordmark, as a view that draws itself from the scene.
@MainActor
final class Wordmark: NSView {

    /// The size it draws at, in points: the scene's canvas at five eighths.
    static let size = NSSize(width: 295, height: 85)

    private static let scale = size.width / WordmarkScene.size.width

    private let tiles: [WordmarkScene.Letter: Tile]

    private var link: CADisplayLink?
    /// The refresh the loop started on — the first one after the view reached a window.
    private var origin: CFTimeInterval?
    private var shown: [WordmarkScene.Window] = []

    init() {
        let bounds = NSRect(origin: .zero, size: Self.size)
        tiles = Dictionary(uniqueKeysWithValues: WordmarkScene.Letter.allCases.map {
            ($0, Tile($0, in: bounds, scale: Self.scale))
        })
        super.init(frame: bounds)

        wantsLayer = true
        for letter in WordmarkScene.Letter.allCases { layer?.addSublayer(tiles[letter]!.group) }
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true

        show(WordmarkScene.windows(at: 0))
    }

    required init?(coder: NSCoder) { return nil }     // never comes from a nib; there aren't any

    /// The clock runs while the view is in a window, unless the system was asked for less movement. The
    /// link holds the view, so it has to be let go of here — nothing else ends it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        origin = nil
        show(WordmarkScene.windows(at: 0))
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)       // `.common` covers onboarding's modal session
        self.link = link
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for tile in tiles.values { tile.contentsScale = scale }
    }

    /// Show the instant this refresh reaches the glass.
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let origin = self.origin ?? now
        self.origin = origin
        show(WordmarkScene.windows(at: now - origin))
    }

    /// Move the layers to `windows`, unless that is what they already show to the hundredth of a point.
    private func show(_ windows: [WordmarkScene.Window]) {
        let windows = windows.map(\.snapped)
        guard windows != shown else { return }
        shown = windows
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (order, window) in windows.enumerated() {
            tiles[window.letter]!.show(window, order: order)
        }
        CATransaction.commit()
    }
}

/// One window's layers. The group carries the opacity, so a dimmed window fades as one picture — its
/// shadow doesn't show through its fill.
@MainActor
private final class Tile {

    let group = CALayer()
    /// Casts the shadow from a path, under the fill: the fill has to clip to its corners, and a layer that
    /// clips clips its own shadow.
    private let caster = CALayer()
    private let fill = CAGradientLayer()
    private let pen = CAShapeLayer()
    private let dot = CAShapeLayer()
    private let centreline: CGPath
    private let dotPath: CGPath?
    /// Points per canvas point.
    private let scale: CGFloat

    /// The app icon's greens, bottom to top; letters are white, which reads on a light window and a dark one.
    private static let colors = [
        CGColor(srgbRed: 0.059, green: 0.545, blue: 0.302, alpha: 1),   // #0f8b4d
        CGColor(srgbRed: 0.137, green: 0.659, blue: 0.384, alpha: 1),   // #23a862
    ]

    init(_ letter: WordmarkScene.Letter, in bounds: CGRect, scale: CGFloat) {
        centreline = WordmarkScene.Glyph.centreline(letter)
        dotPath = WordmarkScene.Glyph.dot(letter)
        self.scale = scale
        group.frame = bounds
        group.allowsGroupOpacity = true

        caster.shadowColor = .black
        caster.shadowOpacity = 0.22
        caster.shadowOffset = CGSize(width: 0, height: -1.5 * scale)
        caster.shadowRadius = 2.5 * scale
        group.addSublayer(caster)

        fill.colors = Self.colors
        fill.startPoint = CGPoint(x: 0.5, y: 0)
        fill.endPoint = CGPoint(x: 0.5, y: 1)
        fill.masksToBounds = true
        caster.addSublayer(fill)

        pen.frame = bounds
        pen.fillColor = nil
        pen.strokeColor = .white
        pen.lineCap = .round
        pen.lineJoin = .round
        group.addSublayer(pen)

        dot.frame = bounds
        dot.fillColor = .white
        group.addSublayer(dot)

        contentsScale = 2       // until the window says otherwise
    }

    /// The backing scale every layer rasterizes at.
    var contentsScale: CGFloat {
        get { pen.contentsScale }
        set { for layer in [group, caster, fill, pen, dot] { layer.contentsScale = newValue } }
    }

    /// Draw `window` third from the back if `order` is 2. The canvas is y down and the layers y up.
    func show(_ window: WordmarkScene.Window, order: Int) {
        let height = WordmarkScene.size.height
        let rect = CGRect(x: window.rect.minX * scale, y: (height - window.rect.maxY) * scale,
                          width: window.rect.width * scale, height: window.rect.height * scale)
        let radius = window.cornerRadius * scale

        group.opacity = Float(window.opacity)
        group.zPosition = CGFloat(order)

        caster.frame = rect
        caster.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size),
                                   cornerWidth: radius, cornerHeight: radius, transform: nil)
        fill.frame = caster.bounds
        fill.cornerRadius = radius

        let size = window.glyphScale * scale
        var transform = CGAffineTransform(translationX: window.glyphOrigin.x * scale,
                                          y: (height - window.glyphOrigin.y) * scale)
            .scaledBy(x: size, y: size)
        pen.path = centreline.copy(using: &transform)
        pen.lineWidth = WordmarkScene.Glyph.stroke * size
        dot.path = dotPath?.copy(using: &transform)
    }
}

private extension WordmarkScene.Window {
    /// Rounded past what any display resolves, so the tail of a spring compares equal to where it lands.
    var snapped: Self {
        func snap(_ value: Double) -> Double { (value * 100).rounded() / 100 }
        func snap(_ point: CGPoint) -> CGPoint { CGPoint(x: snap(point.x), y: snap(point.y)) }
        return Self(letter: letter,
                    rect: CGRect(origin: snap(rect.origin), size: CGSize(width: snap(rect.width),
                                                                         height: snap(rect.height))),
                    cornerRadius: snap(cornerRadius),
                    opacity: snap(opacity * 10) / 10,
                    glyphOrigin: snap(glyphOrigin),
                    glyphScale: snap(glyphScale))
    }
}
