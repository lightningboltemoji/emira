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
        private(set) var veils: [ScrimVeil] = []
        private(set) var desktop: CGImage?
        private(set) var isRetired = false

        private(set) var changes: [ScrimChange] = []
        func setVeils(_ veils: [ScrimVeil], change: ScrimChange) {
            self.veils = veils
            changes.append(change)
        }
        func setDesktop(_ image: CGImage?) { desktop = image }
        func retire() { isRetired = true }
    }

    /// A `DelayScheduler` whose work runs only when a test says so — the settling re-reads hang off it.
    @MainActor final class ManualScheduler: DelayScheduler {
        private var work: [@MainActor () -> Void] = []
        private(set) var scheduled = 0

        func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            scheduled += 1
            self.work.append(work)
        }

        /// Fire everything pending — "the interval elapsed". Answers whether there was anything.
        @discardableResult
        func fire() -> Bool {
            let due = work
            work = []
            for item in due { item() }
            return !due.isEmpty
        }
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
    static func plane(stack: [StackedWindow], filmer: InstantFilmer = InstantFilmer(),
                      scheduler: ManualScheduler = ManualScheduler())
        -> (Scrims, RecordingSurface) {
        let surface = RecordingSurface()
        let scrims = Scrims(filmer: filmer,
                            identify: { WindowId(UInt64($0)) },
                            stack: { stack },
                            scheduler: scheduler,
                            build: { _, _, _ in surface })
        scrims.setDisplays([(monitor, display, 2)], geometry: ScreenGeometry(flipHeight: 800))
        return (scrims, surface)
    }

    /// A window-server answer two applies can see differently — what a correction is made of. It counts
    /// its reads, since a set that draws nothing must not take one.
    @MainActor final class Stack {
        var panes: [StackedWindow]
        private(set) var reads = 0
        init(_ panes: [StackedWindow]) { self.panes = panes }
        func read() -> [StackedWindow] {
            reads += 1
            return panes
        }
    }

    static func plane(stack: Stack, filmer: InstantFilmer = InstantFilmer(),
                      scheduler: ManualScheduler = ManualScheduler())
        -> (Scrims, RecordingSurface) {
        let surface = RecordingSurface()
        let scrims = Scrims(filmer: filmer,
                            identify: { WindowId(UInt64($0)) },
                            stack: { stack.read() },
                            scheduler: scheduler,
                            build: { _, _, _ in surface })
        scrims.setDisplays([(monitor, display, 2)], geometry: ScreenGeometry(flipHeight: 800))
        return (scrims, surface)
    }

    /// Window `n`, see-through on this display. Where it stands is whatever the stack says.
    static func binding(_ raw: UInt64, veil: Double = 0.3) -> ScrimBinding {
        ScrimBinding(window: WindowId(raw), veil: veil)
    }

    /// The whole of what a set is, on the one display these fixtures build.
    static func show(_ scrims: Scrims, _ bindings: [ScrimBinding], _ change: ScrimChange = .dissolve,
                     moving: Set<WindowId> = []) {
        scrims.setScrims(bindings, on: monitor, change: change, moving: moving)
    }

    /// One window's shape, or `nil` for a window the plane is drawing nothing for.
    static func shape(_ surface: RecordingSurface, _ raw: UInt64) -> CGPath? {
        surface.veils.first { $0.window == WindowId(raw) }?.shape
    }

    /// Whether the desktop shows through for `raw` at a point given in **core** (top-left) coordinates —
    /// the space the fixtures are written in. The shapes themselves are in the surface's, flipped.
    static func shows(_ surface: RecordingSurface, _ raw: UInt64, _ x: Double, _ y: Double) -> Bool {
        guard let shape = shape(surface, raw) else { return false }
        return shape.contains(CGPoint(x: x, y: display.maxY - y))
    }

    // The rule: a window is see-through only where the desktop is what lies behind it.

    @Test func aWindowWithNothingBehindItIsDrawnAtItsVeil() {
        let frame = Rect(x: 0, y: 0, width: 400, height: 400)
        let (scrims, surface) = Self.plane(stack: [Self.pane(1, frame)])
        Self.show(scrims, [Self.binding(1)])
        #expect(surface.veils.map(\.window) == [WindowId(1)])
        #expect(surface.veils.map(\.veil) == [0.3])
        #expect(Self.shows(surface, 1, 200, 200))
        #expect(!Self.shows(surface, 1, 500, 200), "and nowhere the window is not")
        #expect(scrims.veil(of: WindowId(1)) == 0.3)
    }

    /// The set arrives bottom→top, and the shapes keep that order — the convention every binding array
    /// carries. Nothing overlaps once the subtractions are made, so it decides nothing about the drawing.
    @Test func theShapesComeBackBottomToTop() {
        let front = Rect(x: 0, y: 0, width: 100, height: 100)
        let back = Rect(x: 500, y: 0, width: 100, height: 100)
        let (scrims, surface) = Self.plane(stack: [Self.pane(1, front), Self.pane(2, back)])
        Self.show(scrims, [Self.binding(1), Self.binding(2)])
        #expect(surface.veils.map(\.window) == [WindowId(2), WindowId(1)])
    }

    /// A window stops at its own silhouette, so it is rounded by the radius a capture measured off it —
    /// and only a window nothing has filmed takes the guess. Outside the corner is the window's own
    /// shadow, which a square silhouette would lighten by the veil.
    @Test func aWindowIsRoundedByItsMeasuredRadiusAndAnUnfilmedOneByTheFallback() {
        let measured = Rect(x: 0, y: 0, width: 400, height: 400)
        let unfilmed = Rect(x: 500, y: 0, width: 400, height: 400)
        let surface = RecordingSurface()
        let scrims = Scrims(filmer: InstantFilmer(),
                            identify: { WindowId(UInt64($0)) },
                            cornerRadius: { $0 == WindowId(1) ? 17 : nil },
                            stack: { [Self.pane(1, measured), Self.pane(2, unfilmed)] },
                            build: { _, _, _ in surface })
        scrims.setDisplays([(Self.monitor, Self.display, 2)], geometry: ScreenGeometry(flipHeight: 800))
        Self.show(scrims, [Self.binding(1), Self.binding(2)])

        // 4 pt in from the corner: outside a 17 pt rounding, inside the 12 pt fallback.
        #expect(!Self.shows(surface, 1, 4, 4))
        #expect(Self.shows(surface, 2, 504, 4))
        #expect(Self.shows(surface, 1, 40, 40) && Self.shows(surface, 2, 540, 40))
    }

    /// The rule's first clause, and the whole reason the effect belongs to a layout where windows never
    /// overlap: the photograph holds the desktop, so an **opaque** window behind would be replaced by
    /// wallpaper — the depth of the desktop read inside out.
    ///
    /// **Where it reaches, and no further**: the rule is about a region, so the decline is one.
    @Test func anOpaqueWindowBehindDeclinesTheOneInFrontWhereItReaches() {
        let front = Rect(x: 0, y: 0, width: 400, height: 400)
        let behind = Rect(x: 200, y: 200, width: 400, height: 400)
        let (scrims, surface) = Self.plane(stack: [Self.pane(1, front), Self.pane(2, behind)])
        Self.show(scrims, [Self.binding(1)])           // 2 is opaque — the window being worked in

        #expect(Self.shows(surface, 1, 100, 100), "where the one in front stands on the desktop")
        #expect(!Self.shows(surface, 1, 300, 300), "and not where the opaque one lies under it")
        // Still drawn, in part, which is what the cover is told.
        #expect(scrims.veil(of: WindowId(1)) == 0.3)
    }

    /// The rule's second clause, and the case the strip's promise does not cover: a pin stands beside
    /// the strip rather than over it, and the strip is never clipped to fit, so a column scrolled far
    /// enough runs under the band. Both are see-through, so the pin's veil crosses the band whole.
    @Test func aColumnUnderAPinLeavesThePinsVeilWhole() {
        let pin = Rect(x: 0, y: 0, width: 500, height: 800)        // half the display, left, frontmost
        let under = Rect(x: 200, y: 0, width: 400, height: 800)    // 300 pt of it under the pin
        let focused = Rect(x: 600, y: 0, width: 400, height: 800)
        let (scrims, surface) = Self.plane(stack: [Self.pane(1, pin),
                                                   Self.pane(3, focused),
                                                   Self.pane(2, under)])
        Self.show(scrims, [Self.binding(1), Self.binding(2)])

        #expect(Self.shows(surface, 1, 100, 400), "the pin where it stands on the desktop")
        #expect(Self.shows(surface, 1, 350, 400), "and over the column hidden under it")
        #expect(Self.shows(surface, 2, 550, 400), "the column where it shows")
        #expect(!Self.shows(surface, 2, 350, 400), "and not where the pin covers it")
    }

    // A window the core has written and the server has not yet moved. Every moment the core can name is
    // earlier than the reading becoming true, and a pin's band is the one place no cover hides that.

    /// The column focus has just left goes opaque in the set that teleports it, while the server still
    /// has it under the pin — so declining for it would cut the pin's veil to a sliver for a frame.
    @Test func aPaneTheServerHasNotCaughtUpWithDeclinesNothing() {
        let pin = Rect(x: 0, y: 0, width: 500, height: 800)
        let under = Rect(x: 200, y: 0, width: 400, height: 800)
        let (scrims, surface) = Self.plane(stack: [Self.pane(1, pin), Self.pane(2, under)])
        Self.show(scrims, [Self.binding(1)], .dissolve, moving: [WindowId(2)])

        #expect(Self.shows(surface, 1, 100, 400))
        #expect(Self.shows(surface, 1, 350, 400), "the pin keeps its veil over a window already on its way")
    }

    /// …and it is waited on only until the reading moves, which is the one evidence available that the
    /// server has caught up. A pane read at a frame it was never named at is simply where it is.
    @Test func theDeclineComesBackOnceTheServerHasShownTheMove() {
        let pin = Rect(x: 0, y: 0, width: 500, height: 800)
        let stack = Stack([Self.pane(1, pin), Self.pane(2, Rect(x: 200, y: 0, width: 400, height: 800))])
        let scheduler = ManualScheduler()
        let (scrims, surface) = Self.plane(stack: stack, scheduler: scheduler)
        Self.show(scrims, [Self.binding(1)], .dissolve, moving: [WindowId(2)])
        #expect(Self.shows(surface, 1, 350, 400))

        // The server shows the move — to somewhere that still overlaps, so the decline has work to do.
        stack.panes = [Self.pane(1, pin), Self.pane(2, Rect(x: 250, y: 0, width: 400, height: 800))]
        scheduler.fire()
        #expect(!Self.shows(surface, 1, 350, 400), "where the server has actually placed it, it declines")
        #expect(Self.shows(surface, 1, 100, 400), "and no further")
    }

    /// A write the server never shows — an app that refused the frame — is not waited on for ever. The
    /// watch ending is what says so, and it cuts once more on the way out.
    @Test func aMoveTheServerNeverShowsIsGivenUpOnWhenTheWatchEnds() {
        let pin = Rect(x: 0, y: 0, width: 500, height: 800)
        let under = Rect(x: 200, y: 0, width: 400, height: 800)
        let scheduler = ManualScheduler()
        let (scrims, surface) = Self.plane(stack: [Self.pane(1, pin), Self.pane(2, under)],
                                           scheduler: scheduler)
        Self.show(scrims, [Self.binding(1)], .dissolve, moving: [WindowId(2)])
        #expect(Self.shows(surface, 1, 350, 400), "suspended while the move is outstanding")

        for _ in 0..<Scrims.settleQuiet { scheduler.fire() }
        #expect(!Self.shows(surface, 1, 350, 400), "and standing there for good, it declines again")
    }

    /// A column at the edge of the viewport hangs off the screen, and its frame runs through the
    /// **parking lot** in the corner that every off-viewport window is stacked in. The overlap is a
    /// pixel wide on the glass, and only what is on the glass may decide anything.
    @Test func anOverlapBeyondTheScreenEdgeDoesNotDisqualifyTheWindowOnIt() {
        let scrimmed = Rect(x: 400, y: 0, width: 800, height: 700)     // 200 pt past the right edge
        let parked = Rect(x: 999, y: 650, width: 800, height: 700)     // the nub in the corner
        let (scrims, surface) = Self.plane(stack: [Self.pane(1, scrimmed), Self.pane(2, parked)])
        Self.show(scrims, [Self.binding(1)])   // the parked one is not on screen

        #expect(scrims.veil(of: WindowId(1)) == 0.3)
        #expect(Self.shows(surface, 1, 600, 300), "the window keeps the screen it is on")
        #expect(!Self.shows(surface, 1, 999.5, 680), "and loses only the sliver the nub reaches")
    }

    /// A window *in front* is not a decline and costs nothing: those pixels are not on the screen. It
    /// comes out of the shape all the same, which is the same subtraction the decline is.
    @Test func aWindowInFrontTakesItsOverlapOutToo() {
        let front = Rect(x: 0, y: 0, width: 200, height: 200)
        let scrimmed = Rect(x: 100, y: 100, width: 400, height: 400)
        let (scrims, surface) = Self.plane(stack: [Self.pane(9, front), Self.pane(1, scrimmed)])
        Self.show(scrims, [Self.binding(1)])

        #expect(scrims.veil(of: WindowId(1)) == 0.3)
        #expect(surface.veils.map(\.window) == [WindowId(1)], "the opaque one draws nothing of its own")
        #expect(Self.shows(surface, 1, 300, 300))
        #expect(!Self.shows(surface, 1, 150, 150))
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
        Self.show(scrims, [Self.binding(1)])

        #expect(scrims.veil(of: WindowId(1)) == 0.3)
        #expect(Self.shows(surface, 1, 50, 50))
        #expect(!Self.shows(surface, 1, 150, 150))
        // Outside the stranger's own rounded corner the window beneath keeps its veil.
        #expect(Self.shows(surface, 1, 101, 101))
    }

    /// A sheet is part of its window: a window emira never adopted, standing wholly on a see-through
    /// one, is veiled with it rather than taken out of it.
    @Test func anUnmanagedWindowWhollyOnAScrimIsVeiledWithIt() {
        let scrimmed = Rect(x: 0, y: 0, width: 400, height: 400)
        let sheet = Rect(x: 100, y: 100, width: 200, height: 100)
        let surface = RecordingSurface()
        let scrims = Scrims(filmer: InstantFilmer(),
                            identify: { $0 == 77 ? nil : WindowId(UInt64($0)) },
                            stack: { [Self.pane(77, sheet), Self.pane(1, scrimmed)] },
                            build: { _, _, _ in surface })
        scrims.setDisplays([(Self.monitor, Self.display, 2)], geometry: ScreenGeometry(flipHeight: 800))
        Self.show(scrims, [Self.binding(1)])

        #expect(surface.veils.map(\.window) == [WindowId(1)])
        #expect(Self.shows(surface, 1, 200, 150), "the sheet is veiled with the window it stands on")
    }

    /// Only wholly, and only on a see-through window. A popup hanging off the edge of a scrimmed
    /// window stays opaque rather than veiled where it overlaps, and so does a dialog on a focused one.
    @Test func anUnmanagedWindowPartlyOnAScrimOrOnAnOpaqueWindowStillOccludes() {
        let scrimmed = Rect(x: 0, y: 0, width: 400, height: 400)
        let focused = Rect(x: 420, y: 0, width: 400, height: 400)
        let popup = Rect(x: 350, y: 100, width: 150, height: 100)
        let dialog = Rect(x: 520, y: 100, width: 100, height: 100)
        let surface = RecordingSurface()
        let scrims = Scrims(filmer: InstantFilmer(),
                            identify: { $0 >= 77 ? nil : WindowId(UInt64($0)) },
                            stack: { [Self.pane(77, popup), Self.pane(78, dialog),
                                      Self.pane(1, scrimmed), Self.pane(2, focused)] },
                            build: { _, _, _ in surface })
        scrims.setDisplays([(Self.monitor, Self.display, 2)], geometry: ScreenGeometry(flipHeight: 800))
        Self.show(scrims, [Self.binding(1)])

        #expect(!Self.shows(surface, 1, 380, 150), "the popup overhangs, so it occludes")
        #expect(Self.shows(surface, 1, 200, 150))
    }

    /// **Every frame in the mask is the window server's**, the see-through windows' included, read when
    /// the set arrives. So the same set named again once the moves it describes have landed repaints
    /// where the windows now stand — which is what the core sends it again for (`Engine.settleScrims`).
    @Test func theSameSetNamedAgainRepaintsWhereTheWindowServerNowHasTheWindows() {
        let scrimmed = Rect(x: 0, y: 0, width: 400, height: 400)
        let stale = Rect(x: 100, y: 100, width: 200, height: 200)   // an occluder still where it was
        let settled = Rect(x: 600, y: 0, width: 200, height: 200)   // and where it has since landed
        let resized = Rect(x: 0, y: 0, width: 380, height: 400)     // the see-through one, landed too
        let stack = Stack([Self.pane(9, stale), Self.pane(1, scrimmed)])
        let (scrims, surface) = Self.plane(stack: stack)
        Self.show(scrims, [Self.binding(1)])
        #expect(!Self.shows(surface, 1, 200, 200), "the occluder is where the window server had it")
        #expect(Self.shows(surface, 1, 40, 40))

        stack.panes = [Self.pane(9, settled), Self.pane(1, resized)]
        Self.show(scrims, [Self.binding(1)])
        #expect(Self.shows(surface, 1, 200, 200), "and where it has since landed")
        #expect(!Self.shows(surface, 1, 390, 200), "the see-through one moved too — it shrank")
        #expect(scrims.veil(of: WindowId(1)) == 0.3)
    }

    // The settle — the window server catches up after the write that moved it, and says nothing.

    /// **A set is cut again while the window server is still catching up.** The reading a mask is cut
    /// against goes stale under it: an app's move reaches the server after the AX write has landed, and
    /// nothing reports when it does.
    @Test func aMaskIsCutAgainWhenTheWindowServerCatchesUp() {
        let scrimmed = Rect(x: 0, y: 0, width: 400, height: 400)
        let before = Rect(x: 600, y: 0, width: 200, height: 200)      // the occluder, where it was
        let after = Rect(x: 200, y: 200, width: 200, height: 200)     // and where the move lands it
        let stack = Stack([Self.pane(9, before), Self.pane(1, scrimmed)])
        let clock = ManualScheduler()
        let (scrims, surface) = Self.plane(stack: stack, scheduler: clock)
        Self.show(scrims, [Self.binding(1)])
        #expect(Self.shows(surface, 1, 300, 300), "nothing is over it yet")

        stack.panes[0] = Self.pane(9, after)
        clock.fire()
        #expect(!Self.shows(surface, 1, 300, 300), "the mask followed the window server")
        #expect(surface.changes.last == .cut, "the veils did not move, only what is under them")
    }

    /// And it stops: a reading with nothing new in it, `settleQuiet` times over, ends the watch. A set
    /// that draws nothing is never watched at all.
    @Test func theWatchEndsWhenTheReadingStopsChanging() {
        let stack = Stack([Self.pane(1, Rect(x: 0, y: 0, width: 400, height: 400))])
        let clock = ManualScheduler()
        let (scrims, _) = Self.plane(stack: stack, scheduler: clock)
        Self.show(scrims, [Self.binding(1)])

        for _ in 0..<Scrims.settleQuiet { #expect(clock.fire(), "still watching") }
        #expect(!clock.fire(), "nothing new, often enough, and the watch is over")

        Self.show(scrims, [], .cut)
        #expect(!clock.fire(), "a set that draws nothing has no desktop to wait for")
    }

    /// A reading that *does* change keeps the watch alive, which is what carries a desktop still moving.
    @Test func aReadingThatChangesKeepsTheWatchAlive() {
        let scrimmed = Rect(x: 0, y: 0, width: 400, height: 400)
        let stack = Stack([Self.pane(9, Rect(x: 600, y: 0, width: 100, height: 100)),
                           Self.pane(1, scrimmed)])
        let clock = ManualScheduler()
        let (scrims, _) = Self.plane(stack: stack, scheduler: clock)
        Self.show(scrims, [Self.binding(1)])

        for step in 0..<(Scrims.settleQuiet * 2) {
            // Over the see-through window throughout, so every reading cuts a different mask.
            stack.panes[0] = Self.pane(9, Rect(x: 100 + Double(step) * 10, y: 100, width: 100, height: 100))
            #expect(clock.fire(), "a desktop that is still moving is still watched (step \(step))")
        }
    }

    // The hand, and the other display.

    /// **A set that draws nothing takes no window list.** A cut to no veils is what a hand's lift is, and
    /// the mask it would build is the one being taken away.
    @Test func aSetThatDrawsNothingIsTakenOffWithoutReadingTheStacking() {
        let scrimmed = Rect(x: 0, y: 0, width: 600, height: 600)
        let stack = Stack([Self.pane(9, Rect(x: 100, y: 100, width: 200, height: 200)),
                           Self.pane(1, scrimmed)])
        let (scrims, surface) = Self.plane(stack: stack)
        Self.show(scrims, [Self.binding(1)])
        let read = stack.reads

        Self.show(scrims, [], .cut)
        #expect(stack.reads == read, "nothing to mask, nothing to mask it against")
        #expect(surface.veils.isEmpty)
        #expect(surface.changes.last == .cut)
        #expect(scrims.veil(of: WindowId(1)) == 0)
    }

    /// **A veil set back down is cut where the windows are now.** The core names the same set again when
    /// the hand lets go, so what moved is the stacking — read afresh, with the float where it landed.
    @Test func aVeilSetBackDownIsCutWhereTheHeldWindowCameToRest() {
        let scrimmed = Rect(x: 0, y: 0, width: 600, height: 600)
        let picked = Rect(x: 100, y: 100, width: 200, height: 200)
        let dropped = Rect(x: 300, y: 250, width: 150, height: 120)
        let stack = Stack([Self.pane(9, picked), Self.pane(1, scrimmed)])
        let (scrims, surface) = Self.plane(stack: stack)
        Self.show(scrims, [Self.binding(1)])
        #expect(!Self.shows(surface, 1, 200, 200), "the float, where it was picked up")

        Self.show(scrims, [], .cut)
        #expect(surface.veils.isEmpty)

        stack.panes[0] = Self.pane(9, dropped)
        Self.show(scrims, [Self.binding(1)])
        #expect(Self.shows(surface, 1, 200, 200), "and where it came to rest")
        #expect(!Self.shows(surface, 1, 350, 300))
        #expect(surface.changes.last == .dissolve)
    }

    /// **A set names one display and reaches no other.** Holding one screen's veil while another moves is
    /// the core's business (`Engine.settleScrims`), and it only works if the held one is left alone.
    @Test func aSetForAnotherDisplayLeavesThisOneAlone() {
        let here = Rect(x: 0, y: 0, width: 400, height: 400)
        let (scrims, surface) = Self.plane(stack: [Self.pane(1, here)])
        Self.show(scrims, [Self.binding(1)])
        let painted = surface.changes.count

        scrims.setScrims([Self.binding(2)], on: MonitorId(2), change: .dissolve, moving: [])
        #expect(surface.changes.count == painted)
        #expect(surface.veils.map(\.veil) == [0.3])
        #expect(scrims.veil(of: WindowId(1)) == 0.3)
        #expect(scrims.veil(of: WindowId(2)) == 0)
    }

    // The photograph. A film is a full-screen capture, so what has to hold is that one is taken exactly
    // when somebody is going to read it — the set the core names is the whole of that question.

    /// The plane with one window veiled on its display, which is what makes the photograph worth
    /// taking. The stack is left empty: these are about the film, not about the mask cut against it.
    static func filming(_ filmer: InstantFilmer = InstantFilmer()) -> (Scrims, RecordingSurface) {
        let (scrims, surface) = Self.plane(stack: [], filmer: filmer)
        scrims.setScrims([Self.binding(1)], on: Self.monitor, change: .cut, moving: [])
        return (scrims, surface)
    }

    @Test func aDisplayFilmsItsDesktopWhenTheFirstSetNamesIt() {
        let (_, surface) = Self.filming()
        #expect(surface.desktop != nil)
    }

    /// The setting off is the set never arriving, so this is how off costs nothing: no capture at boot,
    /// none every `desktopMaxAge` after, and no photograph held for a picture nobody reads.
    @Test func aDisplayNobodyIsVeilingFilmsNothing() {
        let filmer = InstantFilmer()
        let (scrims, surface) = Self.plane(stack: [], filmer: filmer)
        scrims.desktopMayHaveChanged()
        #expect(filmer.films.isEmpty)
        #expect(surface.desktop == nil)
        // …and the cover asks the same question by asking for the backdrop, so it builds no veil layer.
        #expect(scrims.backdrop(of: Self.monitor) == nil)
    }

    /// An old desktop is a better backdrop than none, and `nil` here would take every scrim down.
    /// Driven through `setBlur` because it is the one refilm the throttle does not stand in the way
    /// of: `desktopMayHaveChanged` inside `desktopMaxAge` of the film never reaches the filmer.
    @Test func aFailedFilmLeavesTheStandingPhotographAlone() {
        let filmer = InstantFilmer()
        let (scrims, surface) = Self.filming(filmer)
        #expect(surface.desktop != nil)
        filmer.answers = false
        scrims.setBlur(5)
        #expect(filmer.films.count == 2)
        #expect(surface.desktop != nil)
    }

    /// A failure is an attempt, and it stands against the throttle like any other: a desktop that
    /// declines to be filmed at all — no Screen Recording grant — would otherwise be asked again at
    /// every cover that comes down and every set the core names.
    @Test func aFilmThatFailedStillPacesTheNextOne() {
        let filmer = InstantFilmer()
        let (scrims, _) = Self.filming(filmer)
        filmer.answers = false
        scrims.setBlur(5)
        let attempts = filmer.films.count
        scrims.desktopMayHaveChanged()
        #expect(filmer.films.count == attempts)
    }

    // The frost. The blur is baked into the film, so the radius has to reach the filmer.

    /// A new radius does not make the standing photograph stale, it makes it wrong — so it is refilmed
    /// at once, outside the throttle that paces a desktop which may merely have changed.
    @Test func aNewRadiusRefilmsEveryDisplayAtOnce() {
        let filmer = InstantFilmer()
        let (scrims, _) = Self.filming(filmer)
        #expect(filmer.films.map(\.radius) == [0])
        scrims.setBlur(5)
        #expect(filmer.films.map(\.radius) == [0, 5])
    }

    /// Most reloads leave it alone, and a full-screen capture per display is not what one of those costs.
    @Test func theRadiusItAlreadyHasFilmsNothing() {
        let filmer = InstantFilmer()
        let (scrims, _) = Self.filming(filmer)
        scrims.setBlur(0)
        #expect(filmer.films.count == 1)
    }

    /// A radius nobody is reading refilms nothing either: there is no standing photograph to be wrong.
    @Test func aNewRadiusFilmsNothingOnADisplayNobodyIsVeiling() {
        let filmer = InstantFilmer()
        let (scrims, _) = Self.plane(stack: [], filmer: filmer)
        scrims.setBlur(5)
        #expect(filmer.films.isEmpty)
    }

    /// The plane holds the radius, not the photograph — so a display plugged in later films at it
    /// without anybody re-applying the config.
    ///
    /// The set arrives before the surface does, which is the real order: `screensChanged` reaches the
    /// core first so every cover is closed against the surface that raised it, and only then are the
    /// displays swapped. A set naming a display that does not exist yet films nothing and waits.
    @Test func aDisplayBuiltAfterTheRadiusWasSetFilmsAtIt() {
        let filmer = InstantFilmer()
        let (scrims, _) = Self.plane(stack: [], filmer: filmer)
        scrims.setBlur(5)
        scrims.setScrims([Self.binding(1)], on: MonitorId(2), change: .cut, moving: [])
        #expect(filmer.films.isEmpty)
        scrims.setDisplays([(MonitorId(2), Self.display, 2)],
                           geometry: ScreenGeometry(flipHeight: 800))
        #expect(filmer.films.last?.radius == 5)
    }

    @Test func retiringTakesEverySurfaceOffTheScreen() {
        let (scrims, surface) = Self.plane(stack: [])
        scrims.retireAll()
        #expect(surface.isRetired)
    }

    // Dissolve or cut — the core's word, carried through.

    static let left = Rect(x: 0, y: 0, width: 400, height: 700)
    static let right = Rect(x: 500, y: 0, width: 400, height: 700)

    /// **The plane keeps no memory of what it drew.** Whether a repaint is a veil moving or the mask
    /// catching up with the window server is what the core knows, and it says so with every set.
    @Test func theChangeThePlanePaintsIsTheOneTheCoreNamed() {
        let stack = Stack([Self.pane(1, Self.left), Self.pane(2, Self.right)])
        let (scrims, surface) = Self.plane(stack: stack)
        Self.show(scrims, [Self.binding(1)])
        #expect(surface.changes.last == .dissolve)

        // The same set again, against a stacking that moved *over* it: the core's word for that is a cut.
        stack.panes[1] = Self.pane(2, Rect(x: 200, y: 0, width: 400, height: 700))
        let painted = surface.changes.count
        Self.show(scrims, [Self.binding(1)], .cut)
        #expect(surface.changes.count > painted, "the mask was repainted at all")
        #expect(surface.changes.last == .cut)

        // And a veil moving is a dissolve, whatever the rectangles did — including the last one going,
        // which is focus landing on the window that was see-through.
        Self.show(scrims, [Self.binding(2)])
        #expect(surface.changes.last == .dissolve)
        Self.show(scrims, [])
        #expect(surface.veils.isEmpty)
        #expect(surface.changes.last == .dissolve)
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
        let image = try #require(frosted(Self.square(64), sigma: 6))
        #expect(image.width == 64 && image.height == 64)              // the extent it was given
        let inside = try #require(Self.sample(image, x: 32, y: 32))   // was black
        let outside = try #require(Self.sample(image, x: 46, y: 32))  // was white, 2 pt clear
        #expect(inside.light > 20)
        #expect(outside.light < 250)
    }

    /// Clamped to its own extent, or the blur reads transparency in from beyond the screen and leaves a
    /// band down every side of the display where the backdrop is see-through and the window shows raw.
    @Test func theDisplaysOwnEdgesStayOpaque() throws {
        let image = try #require(frosted(Self.square(64), sigma: 6))
        for (x, y) in [(0, 0), (63, 0), (0, 63), (63, 63), (32, 0), (0, 32)] {
            #expect(Self.sample(image, x: x, y: y)?.alpha == 255)
        }
    }

    /// Off is off: no context, no render, and the photograph the scrim draws is the one that was filmed.
    @Test func aRadiusOfZeroIsNotAskedFor() throws {
        let raw = Self.square(64)
        #expect(frosted(raw, sigma: 0) === raw)
    }

}

// The shade: how the photograph is prepared so a veil darkens a window by the desktop's lightness.

@Suite struct ScrimShadeTests {

    /// A flat grey, opaque.
    static func grey(_ level: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Big.rawValue)!
        ctx.setFillColor(gray: CGFloat(level) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return ctx.makeImage()!
    }

    /// What a window of lightness `window` shows under the shaded photograph of `desktop` at veil `v`,
    /// as the window server composites it: source-over, premultiplied, in encoded values.
    static func composite(window: Double, desktop: Int, veil v: Double) throws -> Double {
        let image = try #require(shaded(grey(desktop)))
        let pixel = try #require(ScrimFrostTests.sample(image, x: 1, y: 1))
        let alpha = Double(pixel.alpha) / 255, colour = Double(pixel.light) / 255
        return window * (1 - v * alpha) + v * colour
    }

    /// A white window keeps the veil a plain mix would give it, so the number means what it says there.
    @Test func aWhiteWindowIsVeiledAsAMixWouldVeilIt() throws {
        for desktop in [0, 64, 128, 200, 255] {
            let mixed = 0.5 + 0.5 * Double(desktop) / 255
            #expect(abs(try Self.composite(window: 1, desktop: desktop, veil: 0.5) - mixed) < 1.5 / 255)
        }
    }

    /// Over black, only the mixing share is left: the desktop shows at `1 − veilShade` of the mix.
    @Test func aBlackWindowShowsOnlyTheMixingShare() throws {
        let shown = try Self.composite(window: 0, desktop: 200, veil: 0.5)
        #expect(abs(shown - 0.5 * (1 - veilShade) * 200 / 255) < 1.5 / 255)
    }

    /// The photograph stays premultiplied-valid: no channel exceeds its alpha, even on white.
    @Test func noChannelExceedsItsAlpha() throws {
        for desktop in [0, 128, 255] {
            let image = try #require(shaded(Self.grey(desktop)))
            let pixel = try #require(ScrimFrostTests.sample(image, x: 2, y: 2))
            #expect(pixel.light <= pixel.alpha)
        }
    }

    @Test func aShadeOfZeroIsTheFilmItself() {
        let raw = Self.grey(90)
        #expect(shaded(raw, by: 0) === raw)
    }
}
