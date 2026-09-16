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

        func setRegions(_ regions: [ScrimRegion]) { self.regions = regions }
        func setDesktop(_ image: CGImage?) { desktop = image }
        func retire() { isRetired = true }
    }

    /// A filmer that answers with a 1×1 image, immediately — enough for "there is a photograph".
    final class InstantFilmer: DesktopFilmer {
        var answers = true
        func film(desktopOf monitor: MonitorId, then: @escaping @MainActor (CGImage?) -> Void) {
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
    @Test func aFailedFilmLeavesTheStandingPhotographAlone() {
        let filmer = InstantFilmer()
        let (scrims, surface) = Self.plane(stack: [], filmer: filmer)
        #expect(surface.desktop != nil)
        filmer.answers = false
        scrims.desktopMayHaveChanged()
        #expect(surface.desktop != nil)
    }

    @Test func retiringTakesEverySurfaceOffTheScreen() {
        let (scrims, surface) = Self.plane(stack: [])
        scrims.retireAll()
        #expect(surface.isRetired)
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
