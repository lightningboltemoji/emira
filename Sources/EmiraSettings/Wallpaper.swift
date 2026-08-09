import AppKit
import QuartzCore
import EmiraCore

// The user's own desktop picture, and the one question the mock menu bar has to ask of it: **is what is
// behind me light or dark?** macOS answers that by sampling the wallpaper under the bar and flipping its
// text between black and white, and a mock menu bar with a tinted band of its own to guarantee contrast
// is a mock menu bar that does not look like the real one.
//
// The sample has to come from the strip that is *actually shown*, not from the top of the file: under a
// fill the picture is cropped, so the layer's top row is some way into the image.

/// The user's desktop picture, resolved once: the pixels, how they are fitted, and what shows where they
/// do not reach.
struct Wallpaper {
    let image: CGImage?
    let gravity: CALayerContentsGravity
    let fill: NSColor

    /// Read the desktop picture for `screen`, fitted the way that screen fits it.
    ///
    /// **Clipping is what turns "proportionally" into fill.** macOS reports *Fill Screen* as
    /// `.scaleProportionallyUpOrDown` *with* `allowClipping`, and *Fit to Screen* as the same scaling
    /// *without* it. Reading the scaling alone letterboxes a filled desktop and paints the bars in the
    /// fill colour — a blue stripe down each side of a mock that should have none.
    @MainActor
    static func current(for screen: NSScreen) -> Wallpaper {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let fill = (options[.fillColor] as? NSColor) ?? .windowBackgroundColor
        let scaling = (options[.imageScaling] as? UInt).flatMap(NSImageScaling.init(rawValue:))
        let clips = (options[.allowClipping] as? Bool) ?? true

        var image: CGImage?
        if let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let loaded = NSImage(contentsOf: url) {
            // The native pixels, not the `NSImage` — `CALayer.contents` resolves one through its `size`
            // in points, which for a 4000 px photo reporting 4000 pt asks for an 8000 px image that does
            // not exist.
            var rect = CGRect(origin: .zero, size: loaded.size)
            image = loaded.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        return Wallpaper(image: image, gravity: Self.gravity(for: scaling, clipping: clips), fill: fill)
    }

    static func gravity(for scaling: NSImageScaling?,
                        clipping: Bool) -> CALayerContentsGravity {
        switch scaling {
        case .scaleAxesIndependently: return .resize                      // Stretch
        case .scaleNone:              return .center                      // Centre, at native size
        default:                      return clipping ? .resizeAspectFill : .resizeAspect
        }
    }

    /// The average relative luminance of `region` — a rect in the coordinates of a layer `size` points
    /// with its origin at the layer's **top** left, which is how `CGImage.cropping(to:)` measures.
    /// `0` is black, `1` is white.
    ///
    /// Rec. 709 coefficients, on the sRGB values as stored: the exact gamma treatment would move the
    /// number by less than the gap between "clearly light" and "clearly dark", which is the only
    /// distinction drawn from it.
    ///
    /// **Two things ask.** The menu bar flips between black and white on it, as macOS's own does; and
    /// the gutter band buys its contrast the same way, because it lies on the user's own picture and an
    /// accent-coloured stripe is invisible on an accent-coloured desktop.
    func luminance(of region: CGRect, layer size: CGSize) -> Double {
        guard let image, region.width > 0, region.height > 0, size.width > 0, size.height > 0 else {
            return Self.luminance(of: fill)
        }
        guard let source = sourceRect(for: region, layer: size, image: image),
              let cropped = image.cropping(to: source),
              let sampled = Self.average(of: cropped) else {
            return Self.luminance(of: fill)
        }
        return sampled
    }

    /// The strip `band` points tall across the top of a layer `size` points — the region a menu bar
    /// would sit over.
    func luminanceUnderMenuBar(layer size: CGSize, band: CGFloat) -> Double {
        luminance(of: CGRect(x: 0, y: 0, width: size.width, height: band), layer: size)
    }

    /// The region of `image`, in its own pixels, that is drawn into `destination` — a rect in layer
    /// coordinates with the origin at the layer's **top** left, which is where a menu bar lives and how
    /// `CGImage.cropping(to:)` measures.
    ///
    /// `nil` when the picture does not reach that part of the layer at all, which is a genuine
    /// letterbox: there the fill colour is the honest answer.
    private func sourceRect(for destination: CGRect, layer size: CGSize,
                            image: CGImage) -> CGRect? {
        let pixels = CGSize(width: image.width, height: image.height)
        guard pixels.width > 0, pixels.height > 0 else { return nil }

        let scale: CGSize
        switch gravity {
        case .resize:
            scale = CGSize(width: size.width / pixels.width, height: size.height / pixels.height)
        case .resizeAspectFill:
            let k = max(size.width / pixels.width, size.height / pixels.height)
            scale = CGSize(width: k, height: k)
        case .center:
            scale = CGSize(width: 1, height: 1)
        default:
            let k = min(size.width / pixels.width, size.height / pixels.height)
            scale = CGSize(width: k, height: k)
        }

        // Where the picture lands on the layer, centred — every gravity used here centres.
        let drawn = CGRect(x: (size.width - pixels.width * scale.width) / 2,
                           y: (size.height - pixels.height * scale.height) / 2,
                           width: pixels.width * scale.width,
                           height: pixels.height * scale.height)
        let shown = drawn.intersection(destination)
        guard !shown.isNull, shown.width > 0, shown.height > 0 else { return nil }

        return CGRect(x: (shown.minX - drawn.minX) / scale.width,
                      y: (shown.minY - drawn.minY) / scale.height,
                      width: shown.width / scale.width,
                      height: shown.height / scale.height)
    }

    /// `image` averaged, by drawing it into a small grid and taking the mean of that.
    ///
    /// A grid rather than a single pixel: downscaling to 1×1 leaves the result at the interpolator's
    /// discretion, and a bar that is dark at one end and bright at the other should answer somewhere in
    /// between rather than wherever the sampler happened to land.
    private static func average(of image: CGImage) -> Double? {
        let (w, h) = (16, 4)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1])
                + 0.0722 * Double(pixels[i + 2])
        }
        return total / Double(w * h) / 255
    }

    private static func luminance(of color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * Double(rgb.redComponent) + 0.7152 * Double(rgb.greenComponent)
            + 0.0722 * Double(rgb.blueComponent)
    }
}
