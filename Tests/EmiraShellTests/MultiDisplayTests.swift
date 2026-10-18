import ApplicationServices
import CoreGraphics
import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The shell's half of a desktop with more than one display: a window is drawn on the display holding the
// largest share of it and on no other. So the scrim walks only what its own display draws, a peek of ours
// is read as the column it stands in for, and an app is given time to notice its window changed displays.
//
// The desktop: left (0, 0, 1000×800) and right (1000, 0, 1200×900), side by side.

@Suite @MainActor struct MultiDisplayTests {

    static let left = MonitorId(1), right = MonitorId(2)
    static let leftFrame = Rect(x: 0, y: 0, width: 1000, height: 800)
    static let rightFrame = Rect(x: 1000, y: 0, width: 1200, height: 900)
    typealias Surface = ScrimPlaneTests.RecordingSurface

    /// A scrim plane over both displays, reading `stack`, with window `n` bound to number `n` and
    /// `standIns` answering for the numbers a peek of ours holds.
    static func plane(stack: [StackedWindow],
                      standIns: [CGWindowID: (window: WindowId, frame: Rect)] = [:])
        -> (Scrims, [MonitorId: Surface]) {
        let surfaces: [MonitorId: Surface] = [left: Surface(), right: Surface()]
        let scrims = Scrims(filmer: ScrimPlaneTests.InstantFilmer(),
                            identify: { standIns[$0] == nil ? WindowId(UInt64($0)) : nil },
                            standIn: { standIns[$0] },
                            stack: { stack },
                            build: { frame, _, _ in frame == leftFrame ? surfaces[left]! : surfaces[right]! })
        scrims.setDisplays([(left, leftFrame, 2), (right, rightFrame, 2)],
                           geometry: ScreenGeometry(flipHeight: 900))
        return (scrims, surfaces)
    }

    /// Whether `surface` lets the desktop through for window `raw` at a core point on `display`.
    static func shows(_ surface: Surface, _ raw: UInt64, _ x: Double, _ y: Double, on display: Rect) -> Bool {
        guard let shape = surface.veils.first(where: { $0.window == WindowId(raw) })?.shape
        else { return false }
        // Each surface draws in its own display's Cocoa space: flipped against the desktop, then local.
        let geometry = ScreenGeometry(flipHeight: 900)
        let box = geometry.cocoa(display)
        let point = geometry.cocoa(Rect(x: x, y: y, width: 0, height: 0)).origin
        return shape.contains(CGPoint(x: point.x - box.minX, y: point.y - box.minY))
    }

    // The scrim walks what its display draws

    /// A window hanging over the edge is drawn by one display: where it is on the glass it is in front of
    /// things, and where it is not it is in front of nothing. Walked on both, its overhang cut a hole in
    /// the neighbour's veil over a window it was not even drawn over.
    @Test func aWindowIsInTheWalkOfTheDisplayDrawingItAlone() {
        // 2 is opaque and in front, 400 on the left and 300 over the right, so drawn on the left only.
        let overhang = StackedWindow(number: 2, frame: Rect(x: 600, y: 0, width: 700, height: 400))
        let veiled = StackedWindow(number: 1, frame: Rect(x: 1000, y: 0, width: 600, height: 800))
        let (scrims, surfaces) = Self.plane(stack: [overhang, veiled])
        scrims.setScrims([ScrimBinding(window: WindowId(1), veil: 0.3)], on: Self.right, change: .cut,
                         moving: [])
        let surface = try! #require(surfaces[Self.right])
        #expect(Self.shows(surface, 1, 1100, 200, on: Self.rightFrame),
                "the overhang is not on this display, so it takes nothing out of the veil")
    }

    /// A peek of ours is the column it stands for: veiled as that window, and shaped by the column's
    /// whole frame — so its corners at the display's edge are the screen's square ones, not a rounding.
    @Test func aPeekIsVeiledAsTheColumnItStandsFor() {
        let column = Rect(x: 700, y: 0, width: 700, height: 800)
        let panel = StackedWindow(number: 99, frame: Rect(x: 700, y: 0, width: 300, height: 800))
        let (scrims, surfaces) = Self.plane(stack: [panel], standIns: [99: (WindowId(3), column)])
        scrims.setScrims([ScrimBinding(window: WindowId(3), veil: 0.3)], on: Self.left, change: .cut,
                         moving: [])
        let surface = try! #require(surfaces[Self.left])
        #expect(surface.veils.map(\.window) == [WindowId(3)])
        #expect(Self.shows(surface, 3, 850, 400, on: Self.leftFrame))
        #expect(Self.shows(surface, 3, 998, 2, on: Self.leftFrame), "the display's edge is not a corner")
        #expect(!Self.shows(surface, 3, 702, 2, on: Self.leftFrame), "the window's own corner is")
        #expect(scrims.veil(of: WindowId(3)) == 0.3, "and the cover reads the same answer")
    }

    // The peek plane

    final class RecordingPeek: PeekSurface {
        let number: CGWindowID
        private(set) var slice: Rect?
        private(set) var whole: Rect?
        private(set) var images = 0
        private(set) var isRetired = false
        init(number: CGWindowID) { self.number = number }
        func place(slice: Rect, of frame: Rect) { self.slice = slice; whole = frame }
        func setImage(_ image: CGImage) { images += 1 }
        func retire() { isRetired = true }
    }

    static let sink = EventSink { _ in }

    /// A peek stands over its display's share of the column, and its number answers for the column.
    @Test func aPeekStandsOverItsDisplaysShareOfTheColumn() {
        let filmer = HoistPlaneTests.HeldFilmer()
        let built = Self.peekPlaneBuilt(filmer: filmer)
        let column = Rect(x: 700, y: 0, width: 700, height: 800)
        built.plane.setPeeks([PeekBinding(window: WindowId(3), monitor: Self.left, frame: column)],
                             feedback: Self.sink)
        let surface = try! #require(built.surfaces.surfaces[WindowId(3)])
        #expect(surface.slice == Rect(x: 700, y: 0, width: 300, height: 800))
        #expect(surface.whole == column)
        #expect(filmer.films == [WindowId(3)])
        let standIn = try! #require(built.plane.standIn(for: surface.number))
        #expect(standIn.window == WindowId(3) && standIn.frame == column)
        #expect(built.plane.standIn(for: 4242) == nil)
    }

    /// A photograph is taken per size: a peek that moved shows the pixels it has, and one whose column
    /// changed width is filmed again. A kept still of the right size shows before the film lands.
    @Test func aPeekIsFilmedPerSizeAndShowsAKeptStillAtOnce() {
        let filmer = HoistPlaneTests.HeldFilmer()
        let kept = CapturedSurface(image: ScrimPlaneTests.InstantFilmer.pixel, frame: .zero)
        let built = Self.peekPlaneBuilt(filmer: filmer, kept: kept)
        let column = Rect(x: 700, y: 0, width: 700, height: 800)
        built.plane.setPeeks([PeekBinding(window: WindowId(3), monitor: Self.left, frame: column)],
                             feedback: Self.sink)
        let surface = try! #require(built.surfaces.surfaces[WindowId(3)])
        #expect(surface.images == 1, "the kept still, before any film has landed")

        built.plane.setPeeks([PeekBinding(window: WindowId(3), monitor: Self.left,
                                          frame: column.offsetBy(dx: 50, dy: 0))], feedback: Self.sink)
        #expect(filmer.films.count == 1, "moved, not resized: the same photograph")

        built.plane.setPeeks([PeekBinding(window: WindowId(3), monitor: Self.left,
                                          frame: Rect(x: 600, y: 0, width: 800, height: 800))],
                             feedback: Self.sink)
        #expect(filmer.films.count == 2)
        filmer.deliver()
        #expect(surface.images >= 3)
    }

    /// A peek the core stops naming comes down, and its number answers for nothing.
    @Test func aPeekNoLongerNamedIsRetired() {
        let built = Self.peekPlaneBuilt()
        built.plane.setPeeks([PeekBinding(window: WindowId(3), monitor: Self.left,
                                          frame: Rect(x: 700, y: 0, width: 700, height: 800))],
                             feedback: Self.sink)
        let surface = try! #require(built.surfaces.surfaces[WindowId(3)])
        built.plane.setPeeks([], feedback: Self.sink)
        #expect(surface.isRetired)
        #expect(built.plane.standIn(for: surface.number) == nil)
    }

    /// A box the factory fills as it builds, so a test can reach the surfaces made after the plane was.
    final class Built { var surfaces: [WindowId: RecordingPeek] = [:] }

    static func peekPlaneBuilt(filmer: HoistPlaneTests.HeldFilmer = HoistPlaneTests.HeldFilmer(),
                               kept: CapturedSurface? = nil) -> (plane: PeekPanels, surfaces: Built) {
        let built = Built()
        let plane = PeekPanels(filmer: filmer, still: { _, _ in kept }) { window, _, _, _ in
            let surface = RecordingPeek(number: CGWindowID(1000 + window.raw))
            built.surfaces[window] = surface
            return surface
        }
        plane.setDisplays(geometry: ScreenGeometry(flipHeight: 900),
                          displays: [(left, leftFrame, 2), (right, rightFrame, 2)])
        return (plane, built)
    }

    // A write onto another display

    /// A tiled write taking a window onto another display is marked as such, so its corrective pass
    /// waits for the app to notice; a write within one display, and any park, is not.
    @Test func aWriteOntoAnotherDisplayIsMarkedCrossing() {
        let registry = WindowRegistry()
        func adopt(_ number: CGWindowID, at frame: Rect) -> WindowId {
            registry.adopt(ObservedWindow(pid: 100, bundleId: "app", title: "w", role: .standard,
                                          frame: frame, isMinimized: false),
                           element: AXWindow(AXUIElementCreateApplication(pid_t(number))),
                           number: number)!.id
        }
        let leaving = adopt(1, at: Rect(x: 100, y: 0, width: 400, height: 400))
        let staying = adopt(2, at: Rect(x: 500, y: 0, width: 400, height: 400))
        let parking = adopt(3, at: Rect(x: 100, y: 400, width: 400, height: 400))
        let writer = ScriptedWriter()
        AXExecutor(registry: registry, writer: writer,
                   displays: { [Self.leftFrame, Self.rightFrame] })
            .execute([.setFrame(leaving, Rect(x: 1200, y: 0, width: 400, height: 400)),
                      .setFrame(staying, Rect(x: 300, y: 0, width: 400, height: 400)),
                      .park(parking, Rect(x: 2199, y: 860, width: 400, height: 400))],
                     feedback: Recorder().sink)
        let crossing = Dictionary(uniqueKeysWithValues: writer.placements.flatMap(\.moves)
            .map { ($0.record.id, $0.crossesDisplays) })
        #expect(crossing[leaving] == true)
        #expect(crossing[staying] == false)
        #expect(crossing[parking] == false)
    }
}
