import CoreGraphics
import Foundation
import QuartzCore
import Testing
import EmiraCore
@testable import EmiraShell

// The mask's own bookkeeping: which shapes stand, what each is drawn at, and which of them a set is
// allowed to disturb. The look is the render server's and is not asserted. The claim is that a veil on
// its way somewhere is left alone by everything that is not moving it — the desktop catches up under a
// mask for several frames after every set (`Scrims.watch`), and every one of those arrives as a `cut`.

@Suite @MainActor struct ScrimMaskTests {

    static let display = Rect(x: 0, y: 0, width: 1000, height: 800)

    /// A scrim with a photograph behind it — a mask with no desktop draws nothing, and the gate is not
    /// what these are about.
    static func scrim() -> ScrimWindow {
        let scrim = ScrimWindow(display: display, scale: 2, geometry: ScreenGeometry(flipHeight: 800))
        scrim.setDesktop(pixel)
        return scrim
    }

    /// Enough for "there is a photograph".
    static let pixel: CGImage = {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()

    static func box(_ x: Double) -> CGPath {
        CGPath(rect: CGRect(x: x, y: 0, width: 100, height: 100), transform: nil)
    }

    /// Window `raw`, see-through at `veil`, standing at `x` — the two things a set can move.
    static func veil(_ raw: UInt64, _ veil: Double = 0.3, at x: Double = 0) -> ScrimVeil {
        ScrimVeil(window: WindowId(raw), shape: box(x), veil: veil)
    }

    static func layer(_ scrim: ScrimWindow, _ raw: UInt64) -> CAShapeLayer? {
        scrim.veils[WindowId(raw)]
    }

    static func isFading(_ scrim: ScrimWindow, _ raw: UInt64) -> Bool {
        layer(scrim, raw)?.animation(forKey: "veil") != nil
    }

    @Test func aDissolveFadesTheVeilUpFromNothing() throws {
        let scrim = Self.scrim()
        scrim.setVeils([Self.veil(1)], change: .dissolve)

        let layer = try #require(Self.layer(scrim, 1))
        #expect(layer.opacity == 0.3, "the model is at the veil the set asked for")
        let fade = try #require(layer.animation(forKey: "veil") as? CABasicAnimation)
        #expect(fade.fromValue as? Float == 0, "and it is on its way there from see-through nothing")
        #expect(fade.duration == ScrimWindow.fadeDuration)
    }

    /// **The one this file exists for.** The window server catches up 8 to 42 ms after the write that
    /// moved a window, which is inside the fade: those re-cuts carry the shapes and the same veils, and
    /// a fade they stopped would be a fade nobody ever sees.
    @Test func aCutUnderAFadeLeavesItRunning() throws {
        let scrim = Self.scrim()
        scrim.setVeils([Self.veil(1)], change: .dissolve)
        #expect(Self.isFading(scrim, 1))

        scrim.setVeils([Self.veil(1, at: 40)], change: .cut)

        let layer = try #require(Self.layer(scrim, 1))
        #expect(Self.isFading(scrim, 1), "the desktop moved under the mask; the veil did not")
        #expect(layer.path == Self.box(40), "and the shape went at once, which is what a cut is for")
    }

    /// A cut that *does* move the veil is still a cut: a correction that faded would read as the window
    /// deciding to become transparent by itself.
    @Test func aCutThatMovesTheVeilTakesItAtOnce() throws {
        let scrim = Self.scrim()
        scrim.setVeils([Self.veil(1)], change: .dissolve)

        scrim.setVeils([Self.veil(1, 0.6)], change: .cut)

        let layer = try #require(Self.layer(scrim, 1))
        #expect(!Self.isFading(scrim, 1))
        #expect(layer.opacity == 0.6)
    }

    /// The same rule on the way out: a shape fading to nothing is the landing's to drop, so a cut under
    /// it leaves both the fade and the layer it is running on.
    @Test func aShapeOnItsWayOutSurvivesACutUnderIt() throws {
        let scrim = Self.scrim()
        scrim.setVeils([Self.veil(1), Self.veil(2, at: 200)], change: .cut)
        scrim.setVeils([Self.veil(1)], change: .dissolve)
        #expect(Self.isFading(scrim, 2), "the window that left the set is fading out")

        scrim.setVeils([Self.veil(1, at: 40)], change: .cut)

        #expect(Self.layer(scrim, 2) != nil, "a shape still going is not dropped by a cut under it")
        #expect(Self.isFading(scrim, 2))
    }

    /// And a hand's lift is unchanged by all of it: the veils it takes away are standing, so the cut
    /// moves every one of them and the shapes go with it.
    @Test func aCutToNothingTakesTheStandingShapesAtOnce() {
        let scrim = Self.scrim()
        scrim.setVeils([Self.veil(1), Self.veil(2, at: 200)], change: .cut)
        #expect(scrim.veils.count == 2)

        scrim.setVeils([], change: .cut)

        #expect(scrim.veils.isEmpty, "nothing is drawn and nothing is waiting to stop being drawn")
    }
}
