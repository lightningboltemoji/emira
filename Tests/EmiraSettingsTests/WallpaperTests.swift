import AppKit
import Testing
@testable import EmiraSettings

// The mock menu bar paints no background and flips between black and white on what is behind it, so the
// question "how bright is the wallpaper *where the bar sits*" is load-bearing — get it wrong and the bar
// is invisible on somebody's desktop. Two things can go wrong and neither is visible by eye: reading the
// wrong strip of the picture, and reading the picture at all when a letterbox means the fill colour is
// what is actually there.

@MainActor
@Suite struct WallpaperTests {

    /// An image whose top half is `top` and bottom half is `bottom`.
    ///
    /// A `CGContext` has its origin at the bottom left while a `CGImage`'s first row is its top, so the
    /// half filled at high `y` is the one that comes out on top.
    static func image(top: NSColor, bottom: NSColor, width: Int = 80, height: Int = 80) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(bottom.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(top.cgColor)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        return context.makeImage()!
    }

    static func wallpaper(_ image: CGImage?, _ gravity: CALayerContentsGravity = .resizeAspectFill,
                          fill: NSColor = .black) -> Wallpaper {
        Wallpaper(image: image, gravity: gravity, fill: fill)
    }

    /// A layer the shape of the measured display, and its menu-bar band.
    static let layer = CGSize(width: 1044, height: 678)
    static let band: CGFloat = 22.6

    @Test func aWhiteWallpaperReadsAsLightAndABlackOneAsDark() {
        let white = Self.wallpaper(Self.image(top: .white, bottom: .white))
        let black = Self.wallpaper(Self.image(top: .black, bottom: .black))

        #expect(white.luminanceUnderMenuBar(layer: Self.layer, band: Self.band) > 0.9)
        #expect(black.luminanceUnderMenuBar(layer: Self.layer, band: Self.band) < 0.1)
    }

    @Test func theBandReadsTheTopOfThePictureAndNotItsAverage() {
        // The half it does *not* sit over must not reach the answer, or a bar over a bright sky above a
        // dark forest comes out mid-grey and picks the wrong colour.
        let brightSky = Self.wallpaper(Self.image(top: .white, bottom: .black))
        let darkSky = Self.wallpaper(Self.image(top: .black, bottom: .white))

        #expect(brightSky.luminanceUnderMenuBar(layer: Self.layer, band: Self.band) > 0.9)
        #expect(darkSky.luminanceUnderMenuBar(layer: Self.layer, band: Self.band) < 0.1)
    }

    @Test func aFillCropsSoTheBandStillReadsTheTopOfWhatIsShown() {
        // 2:1 artwork into a 1.54 layer under a fill is cropped left and right, not top and bottom, so
        // the band still lands on the picture's own top rows.
        let wide = Self.image(top: .white, bottom: .black, width: 160, height: 80)
        #expect(Self.wallpaper(wide).luminanceUnderMenuBar(layer: Self.layer, band: Self.band) > 0.9)

        // Taller than the layer: the fill crops top and bottom, so the band starts *inside* the picture
        // — still in the white half, and still white.
        let tall = Self.image(top: .white, bottom: .black, width: 80, height: 160)
        #expect(Self.wallpaper(tall).luminanceUnderMenuBar(layer: Self.layer, band: Self.band) > 0.9)
    }

    @Test func aLetterboxAnswersWithTheFillColourRatherThanThePicture() {
        // Artwork far wider than the layer, fitted rather than filled: it sits as a band across the
        // middle and never reaches the top, where the fill colour is what is genuinely on screen.
        let wide = Self.image(top: .white, bottom: .white, width: 400, height: 20)
        let letterboxed = Self.wallpaper(wide, .resizeAspect, fill: .black)

        #expect(letterboxed.luminanceUnderMenuBar(layer: Self.layer, band: Self.band) < 0.1)
    }

    @Test func noPictureAtAllAnswersWithTheFillColour() {
        #expect(Self.wallpaper(nil, fill: .white)
            .luminanceUnderMenuBar(layer: Self.layer, band: Self.band) > 0.9)
        #expect(Self.wallpaper(nil, fill: .black)
            .luminanceUnderMenuBar(layer: Self.layer, band: Self.band) < 0.1)
    }

    @Test func luminanceIsWeightedTheWayAnEyeIs() {
        // Rec. 709: green carries most of it and blue almost none, so a saturated blue desktop is dark
        // enough to want white text while a green one is not.
        let blue = Self.wallpaper(Self.image(top: .systemBlue, bottom: .systemBlue))
        let green = Self.wallpaper(Self.image(top: .green, bottom: .green))

        #expect(blue.luminanceUnderMenuBar(layer: Self.layer, band: Self.band) < 0.5)
        #expect(green.luminanceUnderMenuBar(layer: Self.layer, band: Self.band) > 0.5)
    }

    // The fitting itself, which is what put a blue stripe down each side of the mock once

    @Test func clippingIsWhatTurnsProportionallyIntoFill() {
        // macOS reports *Fill Screen* as proportional **with** clipping and *Fit to Screen* as the same
        // scaling without it. Reading the scaling alone letterboxes a filled desktop.
        #expect(Wallpaper.gravity(for: .scaleProportionallyUpOrDown, clipping: true)
                == .resizeAspectFill)
        #expect(Wallpaper.gravity(for: .scaleProportionallyUpOrDown, clipping: false)
                == .resizeAspect)
    }

    @Test func theOtherTwoWallpaperModesMapToThemselves() {
        #expect(Wallpaper.gravity(for: .scaleAxesIndependently, clipping: true) == .resize)
        #expect(Wallpaper.gravity(for: .scaleNone, clipping: true) == .center)
        // An option macOS did not report is a filled desktop, which is the common one.
        #expect(Wallpaper.gravity(for: nil, clipping: true) == .resizeAspectFill)
    }
}
