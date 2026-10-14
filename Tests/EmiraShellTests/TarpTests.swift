import CoreGraphics
import Foundation
import Testing
import EmiraCore
import EmiraGuide
@testable import EmiraShell

// The tarp's half in the shell: which of the parked windows the core names are drawn over, against the
// window server's reading, how far the patch reaches, and what it draws around — and the plane that
// films its strip, cuts it with the veils, and tells the cover's base what it hides.

@Suite @MainActor struct TarpCutTests {

    static let display = Rect(x: 0, y: 0, width: 1000, height: 800)
    /// The strip a tarp over this display's lot covers (`TarpWindow.band` inside its right edge).
    static let strip = Rect(x: 904, y: 0, width: 96, height: 800)
    /// The first slot of `ParkingLot(frame: display)`: one point of the window poking in, forty tall.
    static let slot = Rect(x: 999, y: 760, width: 500, height: 400)

    static func tarp(_ slots: [UInt64: Rect] = [1: slot], focused: UInt64? = 7) -> Tarp {
        Tarp(lot: display, slots: Dictionary(uniqueKeysWithValues: slots.map { (WindowId($0), $1) }),
             focused: focused.map(WindowId.init))
    }

    /// One pane of the reading: window `n` standing at `frame`.
    static func p(_ n: UInt64, _ frame: Rect) -> (UInt64, Rect) { (n, frame) }

    /// Window `n` is window number `n`, as `WindowRegistry` joins them on a real desktop.
    static func stack(_ panes: [(UInt64, Rect)]) -> [(window: WindowId?, pane: StackedWindow)] {
        panes.map { (WindowId($0.0), StackedWindow(number: CGWindowID($0.0), frame: $0.1)) }
    }

    static func cut(_ tarp: Tarp, _ panes: [(UInt64, Rect)], within strip: Rect = strip,
                    radius: Double? = nil) -> TarpCut? {
        TarpCut.cut(for: tarp, over: Self.stack(panes), on: display, within: strip,
                    cornerRadius: { _ in radius })
    }

    // What is drawn over.

    @Test func aParkedWindowStandingInItsSlotIsDrawnOver() throws {
        let cut = try #require(Self.cut(Self.tarp(), [Self.p(1, Self.slot)]))
        #expect(cut.concealed == [1])
    }

    /// A park the server has not caught up with — or one an app refused — is left in plain view rather
    /// than painted over wherever it happens to stand.
    @Test func aParkedWindowAnywhereElseIsNotDrawnOver() {
        let inView = Rect(x: 300, y: 47, width: 500, height: 400)
        #expect(Self.cut(Self.tarp(), [Self.p(1, inView)]) == nil)
    }

    @Test func anAppsRoundingStillStandsInTheSlot() throws {
        let rounded = Self.slot.offsetBy(dx: 0.5, dy: -1)
        #expect(try #require(Self.cut(Self.tarp(), [Self.p(1, rounded)])).concealed == [1])
    }

    // How far it reaches.

    /// The nub, padded by an unfocused shadow's reach, in whole points, out to the display's edges.
    @Test func thePatchIsTheNubPaddedByItsShadowsReach() throws {
        let cut = try #require(Self.cut(Self.tarp(), [Self.p(1, Self.slot)]))
        let reach = WindowShadow.unfocused.reach
        #expect(cut.region == Rect(x: (999 - reach).rounded(.down), y: (760 - reach).rounded(.down),
                                   width: 1000 - (999 - reach).rounded(.down),
                                   height: 800 - (760 - reach).rounded(.down)))
    }

    /// With no window named focused, macOS's key window may be parked — an empty workspace leaves it
    /// where it was — and the key shadow reaches further.
    @Test func aKeyWindowThatMayBeParkedPadsTheFurtherReach() throws {
        let unnamed = try #require(Self.cut(Self.tarp(focused: nil), [Self.p(1, Self.slot)]))
        let parked = try #require(Self.cut(Self.tarp(focused: 1), [Self.p(1, Self.slot)]))
        let reach = WindowShadow.focused.reach
        #expect(unnamed.region.minX == (999 - reach).rounded(.down))
        #expect(parked.region == unnamed.region)
    }

    @Test func thePatchStaysInsideItsStrip() throws {
        let narrow = Rect(x: 990, y: 0, width: 10, height: 800)
        let cut = try #require(Self.cut(Self.tarp(), [Self.p(1, Self.slot)], within: narrow))
        #expect(cut.region.minX == 990)
    }

    /// The edges inside the display fade; the display's own edges, against which the nubs stand, do not.
    @Test func onlyTheEdgesInsideTheDisplayFade() throws {
        let cut = try #require(Self.cut(Self.tarp(), [Self.p(1, Self.slot)]))
        #expect(cut.feather == EdgeInsets(top: TarpWindow.feather, left: TarpWindow.feather,
                                          bottom: 0, right: 0))
    }

    // What it draws around.

    @Test func aWindowWithinShadowReachIsANeighbourAtItsRadiusAndFocus() throws {
        let column = Rect(x: 510, y: 20, width: 470, height: 760)           // 20 pt from the corner
        let cut = try #require(Self.cut(Self.tarp(focused: 2), [Self.p(1, Self.slot), Self.p(2, column)],
                                        radius: 16))
        #expect(cut.neighbours == [TarpNeighbour(frame: column, cornerRadius: 16, isFocused: true)])
    }

    @Test func aWindowBeyondShadowReachIsNoNeighbour() throws {
        let far = Rect(x: 20, y: 20, width: 400, height: 400)
        let cut = try #require(Self.cut(Self.tarp(), [Self.p(1, Self.slot), Self.p(2, far)]))
        #expect(cut.neighbours.isEmpty)
    }

    /// A parked window not standing in its slot is still a window on the glass: drawn around, not over.
    @Test func aParkedWindowOnItsWayIsANeighbour() throws {
        let leaving = Rect(x: 600, y: 300, width: 390, height: 480)
        let cut = try #require(Self.cut(Self.tarp([1: Self.slot, 2: Self.slot.offsetBy(dx: 0, dy: -8)]),
                                        [Self.p(1, Self.slot), Self.p(2, leaving)]))
        #expect(cut.concealed == [1])
        #expect(cut.neighbours.map(\.frame) == [leaving])
    }

    @Test func aWindowEmiraNeverAdoptedIsANeighbourAtTheFallbackRadius() throws {
        let stranger = Rect(x: 600, y: 300, width: 390, height: 480)
        var stacked = Self.stack([Self.p(1, Self.slot)])
        stacked.append((nil, StackedWindow(number: 50, frame: stranger)))
        let cut = try #require(TarpCut.cut(for: Self.tarp(), over: stacked, on: Self.display,
                                           within: Self.strip))
        #expect(cut.neighbours == [TarpNeighbour(frame: stranger,
                                                 cornerRadius: Scrims.fallbackCornerRadius,
                                                 isFocused: false)])
    }
}

@Suite @MainActor struct TarpPlaneTests {

    /// A `TarpSurface` that is a record of calls rather than a window.
    final class RecordingTarp: TarpSurface {
        let strip: Rect
        private(set) var cut: TarpCut?
        private(set) var cuts = 0
        private(set) var desktop: CGImage?
        private(set) var isRetired = false
        init(strip: Rect) { self.strip = strip }
        func setCut(_ cut: TarpCut?) {
            self.cut = cut
            cuts += 1
        }
        func setDesktop(_ image: CGImage?) { desktop = image }
        func retire() { isRetired = true }
    }

    typealias Fix = ScrimPlaneTests
    static let monitor = Fix.monitor
    static let slot = Rect(x: 999, y: 760, width: 500, height: 400)

    /// The plane on the 1000×800 fixture display, against `stack`, recording the tarp surfaces it builds.
    static func plane(_ stack: Fix.Stack, filmer: Fix.InstantFilmer = Fix.InstantFilmer())
        -> (Scrims, Fix.RecordingSurface, () -> [RecordingTarp]) {
        let surface = Fix.RecordingSurface()
        var built: [RecordingTarp] = []
        let scrims = Scrims(filmer: filmer,
                            identify: { WindowId(UInt64($0)) },
                            stack: { stack.read() },
                            scheduler: Fix.ManualScheduler(),
                            build: { _, _, _ in surface },
                            buildTarp: { strip, _, _ in
                                let tarp = RecordingTarp(strip: strip)
                                built.append(tarp)
                                return tarp
                            })
        scrims.setDisplays([(monitor, Fix.display, 2)], geometry: ScreenGeometry(flipHeight: 800))
        return (scrims, surface, { built })
    }

    static func tarp(focused: UInt64? = 7) -> Tarp {
        Tarp(lot: Fix.display, slots: [WindowId(1): slot], focused: focused.map(WindowId.init))
    }

    @Test func aTarpIsBuiltOverTheStripInsideTheLotsEdge() throws {
        let (scrims, _, built) = Self.plane(Fix.Stack([Fix.pane(1, Self.slot)]))
        scrims.setTarp(Self.tarp(), on: Self.monitor)
        let surface = try #require(built().first)
        #expect(surface.strip == Rect(x: 1000 - TarpWindow.band, y: 0, width: TarpWindow.band,
                                      height: 800))
        #expect(surface.cut?.concealed == [1])
    }

    /// A tarp needs the desktop exactly as it is, and only its strip of it — and a display nobody is
    /// veiling still has no scrim photograph, for the cover to build no veil layer from.
    @Test func aTarpFilmsItsStripUntouchedAndNoVeiledPhotograph() throws {
        let filmer = Fix.InstantFilmer()
        let (scrims, scrim, built) = Self.plane(Fix.Stack([Fix.pane(1, Self.slot)]), filmer: filmer)
        scrims.setTarp(Self.tarp(), on: Self.monitor)
        let film = try #require(filmer.films.last)
        #expect(film.radius == nil)
        #expect(film.strip == Rect(x: 1000 - TarpWindow.band, y: 0, width: TarpWindow.band, height: 800))
        #expect(built().first?.desktop != nil)
        #expect(scrim.desktop == nil)
        #expect(scrims.backdrop(of: Self.monitor) == nil)
    }

    @Test func whatTheTarpHidesIsWhatTheCoversBaseLeavesOut() {
        let (scrims, _, built) = Self.plane(Fix.Stack([Fix.pane(1, Self.slot)]))
        scrims.setTarp(Self.tarp(), on: Self.monitor)
        #expect(scrims.concealedNumbers == [1])
        scrims.setTarp(nil, on: Self.monitor)
        #expect(scrims.concealedNumbers.isEmpty)
        #expect(built().first?.cut == nil)
    }

    /// Under a cover the tarp is cut once, while the parks may still be landing — so it is cut again
    /// the moment the cover starts to come down, before the fade can show a nub.
    @Test func theTarpIsCutAgainAsTheCoverComesDown() {
        let stack = Fix.Stack([Fix.pane(1, Rect(x: 300, y: 47, width: 500, height: 400))])
        let (scrims, _, built) = Self.plane(stack)
        scrims.setCovered(true, on: Self.monitor)
        scrims.setTarp(Self.tarp(), on: Self.monitor)
        #expect(built().first?.cut == nil, "the server has not moved it yet")

        stack.panes = [Fix.pane(1, Self.slot)]
        scrims.setCovered(false, on: Self.monitor)
        #expect(built().first?.cut?.concealed == [1])
    }

    /// A parked window behind a see-through one is not on the glass as far as the veil is concerned:
    /// the tarp is drawing over it, so it declines nothing.
    @Test func aWindowTheTarpHidesDeclinesNoVeil() {
        let peeking = Rect(x: 600, y: 47, width: 800, height: 740)
        let (scrims, scrim, _) = Self.plane(Fix.Stack([Fix.pane(2, peeking), Fix.pane(1, Self.slot)]))
        scrims.setTarp(Self.tarp(), on: Self.monitor)
        scrims.setScrims([Fix.binding(2)], on: Self.monitor, change: .cut, moving: [])
        let shape = scrim.veils.first { $0.window == WindowId(2) }?.shape
        // The nub's own corner, at the display's edge, inside the peeking column.
        #expect(shape?.contains(CGPoint(x: 999.5, y: 800 - 780)) == true)
    }

    @Test func aDisplayChangeRebuildsTheTarp() {
        let (scrims, _, built) = Self.plane(Fix.Stack([Fix.pane(1, Self.slot)]))
        scrims.setTarp(Self.tarp(), on: Self.monitor)
        scrims.setDisplays([(Self.monitor, Fix.display, 2)], geometry: ScreenGeometry(flipHeight: 800))
        #expect(built().count == 2)
        #expect(built().first?.isRetired == true)
        #expect(built().last?.cut?.concealed == [1])
    }
}
