import CoreGraphics
import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The scrim plane's half of the decision. The core names windows; this is where the window server's
// answer about what is actually in front of and behind them turns that into a mask — and where a
// binding the desktop photograph cannot honestly back is declined.

@Suite @MainActor struct ScrimPlaneTests {

    /// A `ScrimSurface` that is a record of calls rather than a window.
    final class RecordingSurface: ScrimSurface {
        private(set) var regions: [ScrimRegion] = []
        private(set) var desktop: CGImage?
        private(set) var isRetired = false

        private(set) var fades: [Bool] = []
        func setRegions(_ regions: [ScrimRegion], fading: Bool) {
            self.regions = regions
            fades.append(fading)
        }
        func setDesktop(_ image: CGImage?) { desktop = image }
        func retire() { isRetired = true }
    }

    /// A filmer that answers with a 1×1 image, immediately — enough for "there is a photograph".
    final class InstantFilmer: DesktopFilmer {
        var answers = true
        private(set) var films: [(monitor: MonitorId, radius: Double)] = []
        func film(desktopOf monitor: MonitorId, blurredBy radius: Double,
                  then: @escaping @MainActor (CGImage?) -> Void) {
            films.append((monitor, radius))
            then(answers ? Self.pixel : nil)
        }
        static let pixel: CGImage = {
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }()
    }

    static let display = Rect(x: 0, y: 0, width: 1000, height: 800)
    static let monitor = MonitorId(1)

    static func pane(_ number: CGWindowID, _ frame: Rect) -> StackedWindow {
        StackedWindow(number: number, frame: frame)
    }

    /// Window `n` is bound to window number `n` — the join `WindowRegistry` makes on a real desktop.
    static func plane(stack: [StackedWindow], filmer: InstantFilmer = InstantFilmer())
        -> (Scrims, RecordingSurface) {
        let surface = RecordingSurface()
        let scrims = Scrims(filmer: filmer,
                            identify: { WindowId(UInt64($0)) },
                            stack: { stack },
                            build: { _, _, _ in surface })
        scrims.setDisplays([(monitor, display, 2)], geometry: ScreenGeometry(flipHeight: 800))
        return (scrims, surface)
    }

    /// A window-server answer two applies can see differently — what a correction is made of.
    @MainActor final class Stack {
        var panes: [StackedWindow]
        init(_ panes: [StackedWindow]) { self.panes = panes }
    }

    static func plane(stack: Stack, filmer: InstantFilmer = InstantFilmer())
        -> (Scrims, RecordingSurface) {
        let surface = RecordingSurface()
        let scrims = Scrims(filmer: filmer,
                            identify: { WindowId(UInt64($0)) },
                            stack: { stack.panes },
                            build: { _, _, _ in surface })
        scrims.setDisplays([(monitor, display, 2)], geometry: ScreenGeometry(flipHeight: 800))
        return (scrims, surface)
    }

    static func binding(_ raw: UInt64, _ frame: Rect, veil: Double = 0.3) -> ScrimBinding {
        ScrimBinding(window: WindowId(raw), monitor: monitor, frame: frame, veil: veil)
    }

    // The painting order, and what it buys.

    @Test func regionsComeBackBackToFrontSoTheFrontMostIsPaintedLast() {
        // The window server lists front to back; the mask is painted back to front, so a window in
        // front punches its own hole by being painted last.
        let front = Rect(x: 0, y: 0, width: 100, height: 100)
        let back = Rect(x: 500, y: 0, width: 100, height: 100)
        let (scrims, surface) = Self.plane(stack: [Self.pane(1, front), Self.pane(2, back)])
        scrims.setScrims([])
        #expect(surface.regions.map(\.frame) == [back, front])
    }

    @Test func aWindowWithNothingBehindItIsDrawnAtItsVeil() {
        let frame = Rect(x: 0, y: 0, width: 400, height: 400)
        let (scrims, surface) = Self.plane(stack: [Self.pane(1, frame)])
        scrims.setScrims([Self.binding(1, frame)])
        #expect(surface.regions == [ScrimRegion(frame: frame, veil: 0.3,
                                                cornerRadius: Scrims.cornerRadius)])
        #expect(scrims.veil(of: WindowId(1)) == 0.3)
    }

    /// The rule, and the whole reason the effect belongs to a layout where windows never overlap: the
    /// photograph holds the desktop, so a window with another *window* behind it would have that window
    /// replaced by wallpaper — the depth of the desktop read inside out.
    ///
    /// **Where it reaches, and no further**: the rule is about a region, so the decline is one.
    @Test func aWindowWithAnotherWindowBehindItIsDeclinedOnlyWhereThatWindowReaches() {
        let front = Rect(x: 0, y: 0, width: 400, height: 400)
        let behind = Rect(x: 200, y: 200, width: 400, height: 400)
        let overlap = Rect(x: 200, y: 200, width: 200, height: 200)
        let (scrims, surface) = Self.plane(stack: [Self.pane(1, front), Self.pane(2, behind)])
        scrims.setScrims([Self.binding(1, front), Self.binding(2, behind)])

        // Back to front: `2`, then `1` over it, then the patch of `1` that stands on `2` stamped back
        // to opaque. Both are drawn — `1` in part, which is what the cover is told.
        #expect(surface.regions.map(\.frame) == [behind, front, overlap])
        #expect(surface.regions.map(\.veil) == [0.3, 0.3, 0])
        #expect(scrims.veil(of: WindowId(1)) == 0.3)
        #expect(scrims.veil(of: WindowId(2)) == 0.3)
    }

    /// A column at the edge of the viewport hangs off the screen, and its frame runs through the
    /// **parking lot** in the corner that every off-viewport window is stacked in. The overlap is a
    /// pixel wide on the glass, and only what is on the glass may decide anything.
    @Test func anOverlapBeyondTheScreenEdgeDoesNotDisqualifyTheWindowOnIt() {
        let scrimmed = Rect(x: 400, y: 0, width: 800, height: 700)     // 200 pt past the right edge
        let parked = Rect(x: 999, y: 650, width: 800, height: 700)     // the nub in the corner
        let nub = Rect(x: 999, y: 650, width: 201, height: 50)
        let (scrims, surface) = Self.plane(stack: [Self.pane(1, scrimmed), Self.pane(2, parked)])
        scrims.setScrims([Self.binding(1, scrimmed)])                  // the parked one is not on screen

        #expect(scrims.veil(of: WindowId(1)) == 0.3)
        #expect(surface.regions.map(\.frame) == [parked, scrimmed, nub])
        #expect(surface.regions.map(\.veil) == [0, 0.3, 0])
    }

    /// A window *in front* costs nothing and is not a decline: those pixels are not on the screen, so
    /// the mask paints over them and the painter's algorithm does the rest.
    @Test func aWindowInFrontPunchesItsOwnHoleAndIsNotADecline() {
        let front = Rect(x: 0, y: 0, width: 200, height: 200)
        let scrimmed = Rect(x: 100, y: 100, width: 400, height: 400)
        let (scrims, surface) = Self.plane(stack: [Self.pane(9, front), Self.pane(1, scrimmed)])
        scrims.setScrims([Self.binding(1, scrimmed)])

        #expect(scrims.veil(of: WindowId(1)) == 0.3)
        // Back to front: the scrimmed one first, the occluder over it.
        #expect(surface.regions.map(\.frame) == [scrimmed, front])
        #expect(surface.regions.map(\.veil) == [0.3, 0])
    }

    /// A window emira never adopted — a dialog, a system panel. The core cannot name it, so the plane
    /// has to: it is opaque, and where it is *behind* a named window that window declines.
    @Test func anUnmanagedWindowIsAnOccluderAndDeclinesTheOneOverItWhereItReaches() {
        let scrimmed = Rect(x: 0, y: 0, width: 400, height: 400)
        let stranger = Rect(x: 100, y: 100, width: 100, height: 100)
        let surface = RecordingSurface()
        let scrims = Scrims(filmer: InstantFilmer(),
                            identify: { $0 == 1 ? WindowId(1) : nil },
                            stack: { [Self.pane(1, scrimmed), Self.pane(77, stranger)] },
                            build: { _, _, _ in surface })
        scrims.setDisplays([(Self.monitor, Self.display, 2)], geometry: ScreenGeometry(flipHeight: 800))
        scrims.setScrims([Self.binding(1, scrimmed)])

        #expect(scrims.veil(of: WindowId(1)) == 0.3)
        // The stranger is wholly inside the scrimmed window, so its own frame *is* the patch.
        #expect(surface.regions.map(\.frame) == [stranger, scrimmed, stranger])
        #expect(surface.regions.map(\.veil) == [0, 0.3, 0])
    }

    /// The mask has two inputs and only one of them is an effect. The stacking a set is masked against
    /// is the window server's and moves on its own — a transition's AX writes land after the core
    /// described them — so the plane can be asked to read it again with the set unchanged.
    @Test func restackingRepaintsAgainstTheWindowServerWithoutANewSet() {
        let scrimmed = Rect(x: 0, y: 0, width: 400, height: 400)
        let stale = Rect(x: 100, y: 100, width: 200, height: 200)   // an occluder still where it was
        let settled = Rect(x: 600, y: 0, width: 200, height: 200)   // and where it has since landed
        var front = stale
        let surface = RecordingSurface()
        let scrims = Scrims(filmer: InstantFilmer(),
                            identify: { WindowId(UInt64($0)) },
                            stack: { [Self.pane(9, front), Self.pane(1, scrimmed)] },
                            build: { _, _, _ in surface })
        scrims.setDisplays([(Self.monitor, Self.display, 2)], geometry: ScreenGeometry(flipHeight: 800))
        scrims.setScrims([Self.binding(1, scrimmed)])
        // Painted against the old reading: the occluder still stands on the window it will leave.
        #expect(surface.regions.map(\.frame) == [scrimmed, stale])

        front = settled
        scrims.restack()
        #expect(surface.regions.map(\.frame) == [scrimmed, settled])
        #expect(scrims.veil(of: WindowId(1)) == 0.3)
    }

    @Test func aWindowOnAnotherDisplayIsNotDrawnOnThisOne() {
        let here = Rect(x: 0, y: 0, width: 400, height: 400)
        let (scrims, surface) = Self.plane(stack: [Self.pane(1, here)])
        scrims.setScrims([ScrimBinding(window: WindowId(1), monitor: MonitorId(2), frame: here,
                                       veil: 0.3)])
        #expect(surface.regions.allSatisfy { $0.veil == 0 })
        #expect(scrims.veil(of: WindowId(1)) == 0)
    }

    // The photograph.

    @Test func aDisplayFilmsItsDesktopAsItIsBuilt() {
        let (_, surface) = Self.plane(stack: [])
        #expect(surface.desktop != nil)
    }

    /// An old desktop is a better backdrop than none, and `nil` here would take every scrim down.
    /// Driven through `setBlur` because it is the one refilm the throttle does not stand in the way
    /// of: `desktopMayHaveChanged` inside `desktopMaxAge` of the build never reaches the filmer.
    @Test func aFailedFilmLeavesTheStandingPhotographAlone() {
        let filmer = InstantFilmer()
        let (scrims, surface) = Self.plane(stack: [], filmer: filmer)
        #expect(surface.desktop != nil)
        filmer.answers = false
        scrims.setBlur(5)
        #expect(filmer.films.count == 2)
        #expect(surface.desktop != nil)
    }

    // The frost. The blur is baked into the film, so the radius has to reach the filmer.

    /// A new radius does not make the standing photograph stale, it makes it wrong — so it is refilmed
    /// at once, outside the throttle that paces a desktop which may merely have changed.
    @Test func aNewRadiusRefilmsEveryDisplayAtOnce() {
        let filmer = InstantFilmer()
        let (scrims, _) = Self.plane(stack: [], filmer: filmer)
        #expect(filmer.films.map(\.radius) == [0])
        scrims.setBlur(5)
        #expect(filmer.films.map(\.radius) == [0, 5])
    }

    /// Most reloads leave it alone, and a full-screen capture per display is not what one of those costs.
    @Test func theRadiusItAlreadyHasFilmsNothing() {
        let filmer = InstantFilmer()
        let (scrims, _) = Self.plane(stack: [], filmer: filmer)
        scrims.setBlur(0)
        #expect(filmer.films.count == 1)
    }

    /// The plane holds the radius, not the photograph — so a display plugged in later films at it
    /// without anybody re-applying the config.
    @Test func aDisplayBuiltAfterTheRadiusWasSetFilmsAtIt() {
        let filmer = InstantFilmer()
        let (scrims, _) = Self.plane(stack: [], filmer: filmer)
        scrims.setBlur(5)
        scrims.setDisplays([(MonitorId(2), Self.display, 2)],
                           geometry: ScreenGeometry(flipHeight: 800))
        #expect(filmer.films.last?.radius == 5)
    }

    @Test func retiringTakesEverySurfaceOffTheScreen() {
        let (scrims, surface) = Self.plane(stack: [])
        scrims.retireAll()
        #expect(surface.isRetired)
    }

    // An event or a correction — which repaints dissolve.

    static let left = Rect(x: 0, y: 0, width: 400, height: 700)
    static let right = Rect(x: 500, y: 0, width: 400, height: 700)

    /// **A veil that moves is something the user did**, so it fades. Focus crossing two columns that
    /// are both already on the glass raises no cover, so this is the only thing drawing the change.
    @Test func aVeilThatMovesIsAnEventAndFades() {
        let (scrims, surface) = Self.plane(stack: Stack([Self.pane(1, Self.left),
                                                         Self.pane(2, Self.right)]))
        scrims.setScrims([Self.binding(1, Self.left)])
        scrims.setScrims([Self.binding(2, Self.right)])
        #expect(surface.fades.last == true)
    }

    /// **A rectangle that moves under unchanged veils is us catching up with the window server**, and a
    /// correction that dissolves reads as the window deciding to change on its own.
    @Test func aRectangleThatMovesUnderTheSameVeilsIsACorrectionAndCuts() {
        let stack = Stack([Self.pane(1, Self.left), Self.pane(2, Self.right)])
        let (scrims, surface) = Self.plane(stack: stack)
        scrims.setScrims([Self.binding(1, Self.left)])
        let painted = surface.fades.count

        stack.panes[1] = Self.pane(2, Rect(x: 550, y: 0, width: 400, height: 700))
        scrims.restack()
        #expect(surface.fades.count > painted, "the mask was repainted at all")
        #expect(surface.fades.last == false)
    }

    /// The first mask a display's scrim holds has nothing to dissolve from — `settle` fades that one in
    /// whole, on the window's own alpha.
    @Test func theFirstMaskIsNotADissolve() {
        let (surface) = Self.plane(stack: Stack([Self.pane(1, Self.left)])).1
        #expect(surface.fades.first == false)
    }
}

// The mask itself: the one image the whole effect is drawn through.

@Suite @MainActor struct ScrimMaskTests {

    static let display = Rect(x: 0, y: 0, width: 100, height: 80)

    /// The alpha at one pixel of the mask, 0–255. Redrawn into a known layout rather than read raw:
    /// an alpha-only image has no channel order to assume, but it does have a row padding.
    static func alpha(_ image: CGImage, x: Int, y: Int) -> Int? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data, x >= 0, x < w, y >= 0, y < h else { return nil }
        // Top-left addressing, which is the space the regions are given in.
        return Int(data.bindMemory(to: UInt8.self, capacity: w * h * 4)[y * w * 4 + x * 4])
    }

    /// The veil is in the alpha channel, the only one `CALayer.mask` reads. A grey image with no alpha
    /// is a mask that hides nothing, and the whole desktop is then drawn over the whole screen.
    @Test func theVeilIsWrittenAsAlpha() throws {
        let region = ScrimRegion(frame: Rect(x: 10, y: 10, width: 40, height: 40), veil: 0.5,
                                 cornerRadius: 0)
        let mask = try #require(ScrimWindow.mask([region], display: Self.display, scale: 1))
        #expect(Self.alpha(mask, x: 30, y: 30).map { abs($0 - 128) <= 2 } == true)
        #expect(Self.alpha(mask, x: 80, y: 60) == 0)          // bare desktop stays untouched
    }

    /// Painted back to front in `.copy`, so an occluder *replaces* what is under it. Blending instead
    /// would leave the window in front half-veiled by the one behind it.
    @Test func anOccluderPaintedOverAScrimClearsItRatherThanBlendingWithIt() throws {
        let scrim = ScrimRegion(frame: Rect(x: 0, y: 0, width: 80, height: 80), veil: 0.6,
                                cornerRadius: 0)
        let occluder = ScrimRegion(frame: Rect(x: 40, y: 0, width: 40, height: 80), veil: 0,
                                   cornerRadius: 0)
        let mask = try #require(ScrimWindow.mask([scrim, occluder], display: Self.display, scale: 1))
        #expect(Self.alpha(mask, x: 20, y: 40).map { abs($0 - 153) <= 2 } == true)
        #expect(Self.alpha(mask, x: 60, y: 40) == 0)
    }

    /// An occluder takes its whole frame and a scrim stops at its silhouette — see `mask`. Four lit
    /// crumbs in the corners of an opaque window is the worse of the two artefacts.
    @Test func anOccluderIsSquareWhereAScrimIsRounded() throws {
        let rounded = ScrimRegion(frame: Rect(x: 0, y: 0, width: 60, height: 60), veil: 1,
                                  cornerRadius: 12)
        let square = ScrimRegion(frame: Rect(x: 0, y: 0, width: 60, height: 60), veil: 0,
                                 cornerRadius: 12)
        let scrim = try #require(ScrimWindow.mask([rounded], display: Self.display, scale: 1))
        #expect(Self.alpha(scrim, x: 1, y: 1) == 0)           // outside the corner: the window's shadow
        #expect(Self.alpha(scrim, x: 30, y: 30) == 255)

        let over = try #require(ScrimWindow.mask([rounded, square], display: Self.display, scale: 1))
        #expect(Self.alpha(over, x: 1, y: 1) == 0)            // and the occluder leaves no crumb
        #expect(Self.alpha(over, x: 30, y: 30) == 0)
    }

    @Test func aMaskWithNothingOnItIsEntirelyClear() throws {
        let mask = try #require(ScrimWindow.mask([], display: Self.display, scale: 1))
        #expect(Self.alpha(mask, x: 50, y: 40) == 0)
    }
}

// The frost itself: the Gaussian baked into the photograph, and the edge it must not eat.

@Suite struct ScrimFrostTests {

    /// White, with a black square in the middle — a hard edge to soften and a flat border to check.
    static func square(_ size: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Big.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))
        return ctx.makeImage()!
    }

    /// Luminance and alpha at one pixel, 0–255. Redrawn into a known layout for the reason
    /// `ScrimMaskTests.alpha` is: the channel order of an image Core Image made is not ours to assume.
    static func sample(_ image: CGImage, x: Int, y: Int) -> (light: Int, alpha: Int)? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data, x >= 0, x < w, y >= 0, y < h else { return nil }
        let pixel = data.bindMemory(to: UInt8.self, capacity: w * h * 4) + (y * w * 4 + x * 4)
        return (light: Int(pixel[1]), alpha: Int(pixel[0]))
    }

    /// The whole point: a busy backdrop comes out uniform, so what is overlaid on it stops competing.
    @Test func aHardEdgeComesOutSoft() throws {
        let frosted = try #require(frosted(Self.square(64), sigma: 6))
        #expect(frosted.width == 64 && frosted.height == 64)          // the extent it was given
        let inside = try #require(Self.sample(frosted, x: 32, y: 32)) // was black
        let outside = try #require(Self.sample(frosted, x: 46, y: 32))// was white, 2 pt clear
        #expect(inside.light > 20)
        #expect(outside.light < 250)
    }

    /// Clamped to its own extent, or the blur reads transparency in from beyond the screen and leaves a
    /// band down every side of the display where the backdrop is see-through and the window shows raw.
    @Test func theDisplaysOwnEdgesStayOpaque() throws {
        let frosted = try #require(frosted(Self.square(64), sigma: 6))
        for (x, y) in [(0, 0), (63, 0), (0, 63), (63, 63), (32, 0), (0, 32)] {
            #expect(Self.sample(frosted, x: x, y: y)?.alpha == 255)
        }
    }

    /// Off is off: no context, no render, and the photograph the scrim draws is the one that was filmed.
    @Test func aRadiusOfZeroIsNotAskedFor() throws {
        let raw = Self.square(64)
        #expect(frosted(raw, sigma: 0) === raw)
    }

}
