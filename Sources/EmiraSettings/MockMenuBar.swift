import AppKit
import QuartzCore
import EmiraCore

// The mock menu bar's contents. The band's *height* is load-bearing — it is the real difference between
// the display's frame and its working area, and what lets the outer-gap preview be truthful about what
// it insets from — but an empty band reads as a grey stripe rather than as a menu bar, and the mock is
// trying to look like a desktop.
//
// Everything here is scaled from **real menu-bar metrics** through `Projection`, for the reason the
// layout is: a 13 pt menu title drawn at 13 pt on a mock would be twice the size it should be.
//
// **No background of its own**, which is how macOS draws it: the wallpaper runs straight up to the top
// of the display and the bar is only its contents. What that costs is contrast, and it is paid the way
// macOS pays it — `Wallpaper` samples the strip underneath and the whole bar, glyphs included, flips
// between black and white. A tinted band would have guaranteed contrast and stopped looking like a Mac.

@MainActor
final class MockMenuBar {

    /// The bold application name. macOS puts the focused app here; on the mock it is emira's own, since
    /// emira is what the picture is about.
    static let appName = "emira"

    /// The menus a Mac app has, near enough. Never interactive — the mock takes no input at all.
    static let menus = ["File", "Edit", "View", "Window", "Help"]

    /// Real menu-bar metrics, in true points, projected on the way to a layer.
    private enum Metric {
        static let fontSize: Double = 13
        static let leftInset: Double = 18
        static let rightInset: Double = 16
        static let gap: Double = 17
        /// Glyph **heights**. A symbol's width follows from its own aspect, never the other way round.
        static let logoHeight: Double = 15
        static let glyphHeight: Double = 13
    }

    /// A status glyph and the shape it wants to be drawn at.
    private struct Glyph {
        let layer: CALayer
        /// Width ÷ height of the rasterized artwork. A battery is about two; `wifi` is about one.
        let aspect: CGFloat
    }

    /// The status glyphs, right to left.
    private static let statusGlyphs = ["wifi", "battery.75percent"]

    let layer = CALayer()
    private let logo = CALayer()
    private let logoAspect: CGFloat
    private let name = CATextLayer()
    private var titles: [CATextLayer] = []
    private var glyphs: [Glyph] = []
    private let clock = CATextLayer()

    private var scale: CGFloat
    /// What the bar is currently drawn in. Held so a re-layout that did not change it re-rasterizes no
    /// symbols — the wallpaper only changes when the display or the desktop picture does.
    private var foreground: NSColor = .white

    init(scale: CGFloat) {
        self.scale = scale
        layer.contentsScale = scale
        // No fill: the wallpaper shows through, as it does on a real menu bar.
        layer.backgroundColor = nil

        logoAspect = Self.aspect(of: Self.symbol("apple.logo", tinted: .white))
        logo.contentsScale = scale
        logo.contentsGravity = .resizeAspect
        logo.minificationFilter = .trilinear
        layer.addSublayer(logo)

        layer.addSublayer(name)
        for _ in Self.menus {
            let title = CATextLayer()
            titles.append(title)
            layer.addSublayer(title)
        }
        for name in Self.statusGlyphs {
            let icon = CALayer()
            icon.contentsScale = scale
            icon.contentsGravity = .resizeAspect
            icon.minificationFilter = .trilinear
            glyphs.append(Glyph(layer: icon, aspect: Self.aspect(of: Self.symbol(name, tinted: .white))))
            layer.addSublayer(icon)
        }
        layer.addSublayer(clock)
        tint(.white)
    }

    /// Draw the whole bar in `color` — the text layers and every symbol, which has to be re-rasterized
    /// because a symbol is template art baked to pixels here rather than masked at draw time.
    private func tint(_ color: NSColor) {
        foreground = color
        logo.contents = Self.symbol("apple.logo", tinted: color)
        for (glyph, name) in zip(glyphs, Self.statusGlyphs) {
            glyph.layer.contents = Self.symbol(name, tinted: color)
        }
    }

    /// Lay the bar out across a band `width` × `height` points, at `projection`'s scale, drawn in
    /// whichever of black or white reads over `luminance` — the average brightness of the wallpaper
    /// directly beneath it.
    func place(width: CGFloat, height: CGFloat, projection: Projection, luminance: Double) {
        let wanted: NSColor = luminance > 0.5 ? .black : .white
        if wanted != foreground { tint(wanted) }
        layer.frame = CGRect(x: 0, y: 0, width: width, height: height)

        let size = projection.mock(Metric.fontSize)
        let gap = projection.mock(Metric.gap)
        // Below the notch's own band on a display that has one: the real bar centres its text in the
        // *menu* height, and the strut this is drawn from can be taller than that.
        let mid = height / 2

        var x = projection.mock(Metric.leftInset)
        let logoHeight = projection.mock(Metric.logoHeight)
        let logoWidth = logoHeight * logoAspect
        logo.frame = CGRect(x: x, y: mid - logoHeight / 2, width: logoWidth, height: logoHeight)
        x += logoWidth + gap

        x += Self.set(name, Self.appName, size: size, weight: .bold, at: x, mid: mid, scale: scale, color: foreground)
        x += gap

        for (title, text) in zip(titles, Self.menus) {
            x += Self.set(title, text, size: size, weight: .regular, at: x, mid: mid, scale: scale, color: foreground)
            x += gap
        }
        // A bar too narrow for every menu drops the ones that would run under the status glyphs rather
        // than drawing them on top of each other.
        for title in titles {
            title.isHidden = title.frame.maxX > width * 0.62
        }

        var right = width - projection.mock(Metric.rightInset)
        let text = Self.timestamp()
        let clockWidth = Self.measure(text, size: size, weight: .regular)
        right -= clockWidth
        _ = Self.set(clock, text, size: size, weight: .regular, at: right, mid: mid, scale: scale, color: foreground)

        // Right to left, each glyph as wide as its own artwork asks to be. Laid out by width rather than
        // spaced on a fixed pitch, so a two-to-one battery does not crowd the wifi beside it.
        let glyphHeight = projection.mock(Metric.glyphHeight)
        for glyph in glyphs {
            let width = glyphHeight * glyph.aspect
            right -= width + gap * 0.6
            glyph.layer.frame = CGRect(x: right, y: mid - glyphHeight / 2,
                                       width: width, height: glyphHeight)
        }
    }

    func reproject(scale: CGFloat) {
        self.scale = scale
        layer.contentsScale = scale
    }

    /// Put `text` in `layer`, centred on `mid`, and answer how wide it came out.
    @discardableResult
    private static func set(_ layer: CATextLayer, _ text: String, size: CGFloat,
                            weight: NSFont.Weight, at x: CGFloat, mid: CGFloat,
                            scale: CGFloat, color: NSColor) -> CGFloat {
        layer.contentsScale = scale
        layer.string = attributed(text, size: size, weight: weight, color: color)
        let width = measure(text, size: size, weight: weight)
        // A shade more than the line height, so a descender is never clipped.
        let height = size * 1.4
        layer.frame = CGRect(x: x, y: mid - height / 2, width: width, height: height)
        layer.isHidden = false
        return width
    }

    private static func attributed(_ text: String, size: CGFloat, weight: NSFont.Weight,
                                   color: NSColor = .white) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ])
    }

    private static func measure(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        ceil(attributed(text, size: size, weight: weight).size().width)
    }

    /// The real time, spelled the way the menu bar spells it. A mock desktop showing the wrong time is a
    /// small lie for no gain, and this is read whenever the bar is laid out.
    private static func timestamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "EEE d MMM  h:mm a"
        // Twelve-hour whatever the locale would have chosen: the bar is a picture of a Mac rather than a
        // clock, and `a` is dropped entirely by a locale that formats 24-hour, which would read as a
        // missing suffix rather than as a different convention.
        format.locale = Locale(identifier: "en_US_POSIX")
        return format.string(from: Date())
    }

    /// The rasterized artwork's width ÷ height, which is what a glyph's frame is shaped from.
    private static func aspect(of image: CGImage?) -> CGFloat {
        guard let image, image.height > 0 else { return 1 }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    /// An SF Symbol as pixels, rasterized for the same reason an app icon is — and **at its own aspect**,
    /// since a symbol is rarely square.
    private static func symbol(_ name: String, tinted color: NSColor) -> CGImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let configured = image.withSymbolConfiguration(
            .init(pointSize: 128, weight: .regular)) ?? image
        configured.isTemplate = false
        // Symbols are template art — black by default, and the bar is dark. Tinted white here rather
        // than through a `CALayer` mask, which would cost a second layer per glyph.
        let tinted = NSImage(size: configured.size, flipped: false) { rect in
            color.set()
            rect.fill()
            configured.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        return MockIcons.rasterize(tinted, height: 128)
    }
}
