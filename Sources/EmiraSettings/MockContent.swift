import AppKit
import CoreGraphics
import EmiraCore

// A mock window's **still**: the whole interior — title band, stoplights, the app's icon and a
// suggestion of the app itself — drawn in Core Graphics at whatever size the window happens to be.
//
// It replaces a 512 px icon floating in a rectangle, and it earns its place three times over. The pane
// stops reading as a diagram, because an editor has a sidebar and a browser has a URL bar and those are
// what an app looks like from across a room. The guide can ask for the same picture at *tile* size,
// which is the only thing that makes `guide.style = preview` differ from `placeholder`. And it is an
// **image**, so a rect it no longer fits can stretch it or crop it — which is `animation.window`.
//
// **Suggestion, never simulation.** No text, no colour beyond a tint, no attempt at a particular app.
// Every role is a short recipe over one vocabulary of furniture, and the vocabulary is the reason a
// seventh role would be five lines rather than a drawing.
//
// **Drawn in true points and rasterized at mock scale**, which is the same discipline `Projection`
// keeps: the constants below are a real window's — a 190 pt sidebar, a 28 pt title bar — and `k`
// applies once, in the context's transform. A sidebar in mock points would be a different sidebar on
// every display.

enum MockContent {

    /// The interior of a `role` window `size` true points big, rasterized for a mock at `projection`'s
    /// scale on a `scale`× backing store.
    ///
    /// Cached, and the cache is keyed by the **pixel** size actually rasterized: a still is captured
    /// when a window arrives at a new size, so a set of six windows walking a ladder asks for a couple
    /// of dozen distinct pictures over the life of a settings window and never one per frame.
    @MainActor
    static func still(role: MockRole, size: Size, projection: Projection,
                      scale: CGFloat) -> CGImage? {
        let pixels = CGSize(width: (size.width * projection.k * scale).rounded(),
                            height: (size.height * projection.k * scale).rounded())
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }

        let key = Key(role: role, width: Int(pixels.width), height: Int(pixels.height))
        if let hit = cache[key] { return hit }
        let image = render(role: role, size: size, pixels: pixels)
        // Wholesale rather than least-recently-used: the working set is a handful of sizes per role,
        // and a cache that needs an eviction order is a cache that has stopped being a cache.
        if cache.count >= cacheCeiling { cache.removeAll() }
        cache[key] = image
        return image
    }

    private struct Key: Hashable {
        let role: MockRole
        let width: Int
        let height: Int
    }

    @MainActor private static var cache: [Key: CGImage?] = [:]
    private static let cacheCeiling = 96

    /// Draw one still. `size` is true points; `pixels` is what the bitmap is.
    @MainActor
    private static func render(role: MockRole, size: Size, pixels: CGSize) -> CGImage? {
        guard let context = CGContext(data: nil,
                                      width: Int(pixels.width), height: Int(pixels.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high

        // True points, **top-left origin** — emira's convention everywhere else, and the one the
        // furniture below is written in. Core Graphics counts up from the bottom, so the flip is here
        // and nowhere else.
        context.translateBy(x: 0, y: pixels.height)
        context.scaleBy(x: pixels.width / size.width, y: -pixels.height / size.height)

        let whole = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.setFillColor(SettingsStyle.paneFill)
        context.fill(whole)

        let band = min(SettingsStyle.paneTitleBandHeight, size.height / 3)
        let interior = CGRect(x: 0, y: band, width: size.width, height: max(0, size.height - band))
        if !interior.isEmpty { draw(role, in: interior, context: context) }
        titleBar(role, in: CGRect(x: 0, y: 0, width: size.width, height: band), context: context)

        return context.makeImage()
    }

    // The title bar
    //
    // The app's icon lives here, which is where macOS puts one — and moving it out of the middle of the
    // pane is half of what stops the pane reading as an icon on a slab.

    @MainActor
    private static func titleBar(_ role: MockRole, in band: CGRect, context: CGContext) {
        guard band.height > 1 else { return }
        context.setFillColor(SettingsStyle.paneTitleFill)
        context.fill(band)

        let dot = min(SettingsStyle.stoplightDiameter, band.height * 0.45)
        if dot >= 2, band.width > SettingsStyle.stoplightInset * 2 + SettingsStyle.stoplightPitch * 3 {
            for (i, fill) in SettingsStyle.stoplights.enumerated() {
                context.setFillColor(fill)
                context.fillEllipse(in: CGRect(
                    x: SettingsStyle.stoplightInset - dot / 2 + Double(i) * SettingsStyle.stoplightPitch,
                    y: band.midY - dot / 2, width: dot, height: dot))
            }
        }

        // The proxy icon and the title beside it, as a pair centred in the band — a title bar's whole
        // silhouette, and legible down to a couple of points where a word would not be.
        let side = min(band.height * 0.62, band.width * 0.2)
        let title = min(90.0, band.width * 0.28)
        guard side >= 2 else { return }
        let pair = side + 5 + title
        let x = band.midX - pair / 2
        if let icon = MockIcons.icon(for: role) {
            let rect = CGRect(x: x, y: band.midY - side / 2, width: side, height: side)
            context.saveGState()
            // The context is flipped; an image drawn into it without undoing that is upside down.
            context.translateBy(x: 0, y: rect.midY * 2)
            context.scaleBy(x: 1, y: -1)
            context.draw(icon, in: rect)
            context.restoreGState()
        }
        rule(CGRect(x: x + side + 5, y: band.midY - 2.5, width: title, height: 5),
             SettingsStyle.contentTitle, context)
    }

    // The recipes
    //
    // One per role, each a handful of furniture calls. What separates two apps at a glance is their
    // *chrome* — where the list is, whether there is a URL bar — so that is what these draw and the
    // content is the same few rules underneath.

    @MainActor
    private static func draw(_ role: MockRole, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        defer { context.restoreGState() }

        switch role {
        case .editor:
            let main = sidebar(in: rect, width: 190, rows: 6, context: context)
            lines(in: main.insetBy(dx: 22, dy: 20), lineHeight: 17,
                  indents: [0, 0, 1, 1, 2, 1, 0, 0, 1, 2, 2, 1],
                  widths: [0.62, 0.44, 0.78, 0.55, 0.40, 0.68, 0.30, 0.72, 0.50, 0.36, 0.58, 0.46],
                  color: SettingsStyle.contentRule, context: context)

        case .browser:
            let page = toolbar(in: rect, height: 40, pill: true, context: context)
            context.setFillColor(SettingsStyle.contentPage)
            context.fill(page)
            let body = page.insetBy(dx: 30, dy: 24)
            let hero = CGRect(x: body.minX, y: body.minY, width: body.width,
                              height: min(body.height * 0.42, 150))
            rule(hero, SettingsStyle.contentBlock, context, radius: 6)
            lines(in: CGRect(x: body.minX, y: hero.maxY + 20, width: body.width,
                             height: max(0, body.maxY - hero.maxY - 20)),
                  lineHeight: 18, indents: [0, 0, 0, 0, 0, 0],
                  widths: [0.95, 0.88, 0.94, 0.60, 0.90, 0.72],
                  color: SettingsStyle.contentRule, context: context)

        case .terminal:
            context.setFillColor(SettingsStyle.contentTerminal)
            context.fill(rect)
            lines(in: rect.insetBy(dx: 16, dy: 14), lineHeight: 15,
                  indents: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                  widths: [0.34, 0.72, 0.55, 0.90, 0.28, 0.63, 0.47, 0.81, 0.22, 0.68,
                           0.51, 0.39, 0.76, 0.30],
                  color: SettingsStyle.contentTerminalInk, context: context, prompts: true)

        case .chat:
            let thread = sidebar(in: rect, width: 200, rows: 5, context: context)
            bubbles(in: thread.insetBy(dx: 18, dy: 18), context: context)

        case .notes:
            let page = sidebar(in: rect, width: 180, rows: 7, context: context)
            let body = page.insetBy(dx: 24, dy: 22)
            rule(CGRect(x: body.minX, y: body.minY, width: body.width * 0.5, height: 9),
                 SettingsStyle.contentTitle, context)
            lines(in: CGRect(x: body.minX, y: body.minY + 26, width: body.width,
                             height: max(0, body.height - 26)),
                  lineHeight: 16, indents: [0, 0, 0, 0, 0, 0, 0, 0],
                  widths: [0.92, 0.80, 0.88, 0.44, 0.86, 0.72, 0.90, 0.38],
                  color: SettingsStyle.contentRule, context: context)

        case .music:
            let main = sidebar(in: rect, width: 190, rows: 6, context: context)
            let body = main.insetBy(dx: 22, dy: 20)
            let art = min(body.width * 0.32, body.height * 0.5)
            rule(CGRect(x: body.minX, y: body.minY, width: art, height: art),
                 SettingsStyle.contentBlock, context, radius: 5)
            lines(in: CGRect(x: body.minX + art + 20, y: body.minY,
                             width: max(0, body.width - art - 20), height: art),
                  lineHeight: 16, indents: [0, 0, 0],
                  widths: [0.7, 0.45, 0.3], color: SettingsStyle.contentRule, context: context)
            lines(in: CGRect(x: body.minX, y: body.minY + art + 22, width: body.width,
                             height: max(0, body.height - art - 22)),
                  lineHeight: 20, indents: [0, 0, 0, 0, 0, 0],
                  widths: [0.95, 0.95, 0.95, 0.95, 0.95, 0.95],
                  color: SettingsStyle.contentFaint, context: context)
        }
    }

    // The furniture

    /// A list down the left edge, with `rows` entries in it. Answers what is left for the main pane.
    @MainActor
    private static func sidebar(in rect: CGRect, width: Double, rows: Int,
                                context: CGContext) -> CGRect {
        let w = min(width, rect.width * 0.38)
        guard w >= 6 else { return rect }
        let bar = CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)
        context.setFillColor(SettingsStyle.contentSidebar)
        context.fill(bar)
        // The hairline between the list and the pane, which is what makes it a sidebar rather than a
        // patch of a different grey.
        context.setFillColor(SettingsStyle.contentSeam)
        context.fill(CGRect(x: bar.maxX - 0.75, y: bar.minY, width: 0.75, height: bar.height))

        let inset = min(14.0, w * 0.14)
        var y = bar.minY + 18
        for i in 0..<rows {
            guard y + 8 < bar.maxY else { break }
            rule(CGRect(x: bar.minX + inset, y: y,
                        width: (w - inset * 2) * [0.85, 0.62, 0.74, 0.5, 0.8, 0.58, 0.68][i % 7],
                        height: 5),
                 SettingsStyle.contentRule, context)
            y += 22
        }
        return CGRect(x: bar.maxX, y: rect.minY, width: max(0, rect.maxX - bar.maxX),
                      height: rect.height)
    }

    /// A chrome band across the top, optionally carrying a URL pill. Answers the page below it.
    @MainActor
    private static func toolbar(in rect: CGRect, height: Double, pill: Bool,
                                context: CGContext) -> CGRect {
        let h = min(height, rect.height * 0.4)
        guard h >= 5 else { return rect }
        let bar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
        context.setFillColor(SettingsStyle.contentSidebar)
        context.fill(bar)
        context.setFillColor(SettingsStyle.contentSeam)
        context.fill(CGRect(x: bar.minX, y: bar.maxY - 0.75, width: bar.width, height: 0.75))

        let dot = min(9.0, h * 0.28)
        for i in 0..<2 where bar.width > 120 {
            context.setFillColor(SettingsStyle.contentRule)
            context.fillEllipse(in: CGRect(x: bar.minX + 18 + Double(i) * 22,
                                           y: bar.midY - dot / 2, width: dot, height: dot))
        }
        if pill, bar.width > 160 {
            let w = bar.width * 0.55
            rule(CGRect(x: bar.midX - w / 2, y: bar.midY - h * 0.28, width: w, height: h * 0.56),
                 SettingsStyle.contentPill, context, radius: h * 0.28)
        }
        return CGRect(x: rect.minX, y: bar.maxY, width: rect.width,
                      height: max(0, rect.maxY - bar.maxY))
    }

    /// Ragged rules on a fixed rhythm — the one thing every role's content is made of.
    ///
    /// `indents` are in units of one indent step, so a code listing steps in and out the way one does.
    /// `prompts` draws a short accent tick before every other line, which is a shell and nothing else.
    private static func lines(in rect: CGRect, lineHeight: Double, indents: [Int], widths: [Double],
                              color: CGColor, context: CGContext, prompts: Bool = false) {
        guard rect.width > 8, rect.height > 4 else { return }
        let thickness = max(1.0, min(4.0, lineHeight * 0.28))
        let step = min(24.0, rect.width * 0.06)
        var y = rect.minY
        var i = 0
        while y + thickness <= rect.maxY {
            let indent = Double(indents[i % indents.count]) * step
            let width = (rect.width - indent) * widths[i % widths.count]
            if prompts, i % 2 == 0 {
                rule(CGRect(x: rect.minX, y: y, width: min(7, rect.width * 0.05), height: thickness),
                     SettingsStyle.contentPrompt, context)
                rule(CGRect(x: rect.minX + min(11, rect.width * 0.08), y: y,
                            width: max(0, width - 11), height: thickness), color, context)
            } else {
                rule(CGRect(x: rect.minX + indent, y: y, width: max(0, width), height: thickness),
                     color, context)
            }
            y += lineHeight
            i += 1
        }
    }

    /// A conversation: rounded blocks alternating sides, which is what a chat app is from a distance.
    private static func bubbles(in rect: CGRect, context: CGContext) {
        guard rect.width > 40, rect.height > 20 else { return }
        let plan: [(mine: Bool, width: Double, height: Double)] = [
            (false, 0.62, 34), (true, 0.48, 24), (false, 0.40, 24),
            (true, 0.70, 44), (false, 0.55, 34), (true, 0.36, 24),
        ]
        var y = rect.minY
        for bubble in plan {
            let h = min(bubble.height, rect.maxY - y)
            guard h > 6 else { break }
            let w = rect.width * bubble.width
            rule(CGRect(x: bubble.mine ? rect.maxX - w : rect.minX, y: y, width: w, height: h),
                 bubble.mine ? SettingsStyle.contentPill : SettingsStyle.contentBlock,
                 context, radius: min(9, h / 2))
            y += h + 10
        }
    }

    /// One rounded bar. Below about a point tall a radius is a smudge, so it is dropped.
    private static func rule(_ rect: CGRect, _ color: CGColor, _ context: CGContext,
                             radius: Double? = nil) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.setFillColor(color)
        let r = min(radius ?? rect.height / 2, min(rect.width, rect.height) / 2)
        guard r >= 0.5 else { return context.fill(rect) }
        context.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        context.fillPath()
    }
}
