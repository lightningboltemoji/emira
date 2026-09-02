import CoreGraphics
import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The hoist plane's policy: the diff that keeps the panels matching the core's set, and the release
// fence that holds a dropped one up until the window server says the real window is in front of it.

@Suite @MainActor struct HoistPlaneTests {

    /// A `HoistSurface` that is a record of calls rather than a window.
    final class RecordingSurface: HoistSurface {
        let window: WindowId
        private(set) var frame: Rect
        private(set) var isShown = false
        private(set) var log: [String] = []
        /// Held rather than run, so a test says when the dissolve finishes.
        private(set) var dismissal: (@MainActor () -> Void)?
        var handle: Int { Int(window.raw) }

        init(window: WindowId, frame: Rect) {
            self.window = window
            self.frame = frame
        }

        func place(at frame: Rect) { self.frame = frame; log.append("place") }
        func show(_ image: CGImage) { isShown = true; log.append("show") }
        func order(above handle: Int) { log.append("order>\(handle)") }
        func release() { log.append("release") }
        func reclaim() { log.append("reclaim") }
        func retire() { isShown = false; log.append("retire") }

        func dismiss(over duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
            log.append("dismiss")
            dismissal = completion
        }

        /// The dissolve finished.
        func finishDismissal() {
            let done = dismissal
            dismissal = nil
            retire()
            done?()
        }
    }

    /// Answers the stack question with whatever the test last said, and counts the asking.
    final class FakeProbe: StackProbe {
        var covered = false
        private(set) var asks = 0

        func isCovered(_ window: WindowId, within frame: Rect,
                       then: @escaping @MainActor (Bool) -> Void) {
            asks += 1
            then(covered)
        }
    }

    /// Hands back a 1×1 image for every film, immediately.
    final class InstantFilmer: SurfaceFilmer {
        private(set) var films: [WindowId] = []

        func film(_ window: WindowId, on monitor: MonitorId,
                  then: @escaping @MainActor (CapturedSurface?) -> Void) {
            films.append(window)
            then(CapturedSurface(image: Self.pixel, frame: .zero))
        }

        static let pixel: CGImage = {
            let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
            return context.makeImage()!
        }()
    }

    final class ManualScheduler: DelayScheduler {
        private var work: [@MainActor () -> Void] = []

        func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            self.work.append(work)
        }

        /// Fire every pending item — "the interval elapsed".
        func fire() {
            let due = work
            work = []
            for item in due { item() }
        }
    }

    /// Nothing here clicks, so no test reads what a hoist reports.
    static let nowhere = EventSink { _ in }

    static let monitor = MonitorId(1)
    static let frame = Rect(x: 100, y: 100, width: 300, height: 200)

    static func harness() -> (HoistPanels, InstantFilmer, FakeProbe, ManualScheduler,
                              () -> [WindowId: RecordingSurface]) {
        let filmer = InstantFilmer()
        let probe = FakeProbe()
        let scheduler = ManualScheduler()
        final class Box { var made: [WindowId: RecordingSurface] = [:] }
        let box = Box()
        // A grace measured in milliseconds: the fence reads a clock, and a test should not spend half a
        // second proving it eventually stops looking at it.
        let panels = HoistPanels(filmer: filmer, probe: probe, scheduler: scheduler,
                                 grace: 0.01) { window, frame, _, _, _ in
            let surface = RecordingSurface(window: window, frame: frame)
            box.made[window] = surface
            return surface
        }
        panels.setDisplays(geometry: ScreenGeometry(flipHeight: 1000), scales: [monitor: 2])
        return (panels, filmer, probe, scheduler, { box.made })
    }

    static func binding(_ raw: UInt64, _ frame: Rect = HoistPlaneTests.frame) -> HoistBinding {
        HoistBinding(window: WindowId(raw), monitor: monitor, frame: frame)
    }

    @Test func namingAFloatFilmsItAndShowsIt() {
        let (panels, filmer, _, _, made) = Self.harness()
        panels.setHoists([Self.binding(1)], feedback: Self.nowhere)

        #expect(filmer.films == [WindowId(1)])
        #expect(made()[WindowId(1)]?.isShown == true)
    }

    /// The defect this fence exists for. The core drops a hoist on an AX focus report, which says the
    /// app told us its focus moved — not that the raise reached the glass. Cutting the picture away then
    /// shows the window still in front of it.
    @Test func aDroppedHoistStaysUpWhileTheWindowServerSaysItIsStillCovered() {
        let (panels, _, probe, scheduler, made) = Self.harness()
        panels.setHoists([Self.binding(1)], feedback: Self.nowhere)
        let surface = made()[WindowId(1)]!

        probe.covered = true
        panels.setHoists([], feedback: Self.nowhere)
        #expect(surface.log.contains("release"))          // clicks let go at once…
        #expect(!surface.log.contains("dismiss"))         // …pixels held

        scheduler.fire()                                  // still covered: asked again, still held
        #expect(probe.asks == 2)
        #expect(!surface.log.contains("dismiss"))

        probe.covered = false
        scheduler.fire()
        #expect(surface.log.contains("dismiss"))
    }

    /// The whole point of a released panel keeping its pixels: nothing is cut, so nothing flashes.
    @Test func anUncoveredFloatDissolvesWithoutWaiting() {
        let (panels, _, probe, _, made) = Self.harness()
        panels.setHoists([Self.binding(1)], feedback: Self.nowhere)
        probe.covered = false
        panels.setHoists([], feedback: Self.nowhere)

        let surface = made()[WindowId(1)]!
        #expect(surface.log == ["place", "order>0", "show", "release", "dismiss"])
        #expect(probe.asks == 1)
    }

    /// A fence is a delay, not a veto. An activation the system refused leaves the float genuinely
    /// behind, and a shell that kept a panel the core had dropped would be a second opinion about what
    /// is on the screen.
    @Test func aFenceThatNeverClearsGivesUp() {
        let (panels, _, probe, scheduler, made) = Self.harness()
        panels.setHoists([Self.binding(1)], feedback: Self.nowhere)
        probe.covered = true
        panels.setHoists([], feedback: Self.nowhere)

        // Past the grace, which the fence reads off the clock rather than a tick count.
        let surface = made()[WindowId(1)]!
        let start = Date()
        while Date().timeIntervalSince(start) < 0.2, !surface.log.contains("dismiss") {
            scheduler.fire()
        }
        #expect(surface.log.contains("dismiss"))
    }

    /// The float was buried again while its own picture was still dissolving. It reclaims the panel it
    /// is already showing rather than building a second one over it — and films nothing, since the
    /// pixels never left the screen.
    @Test func aFloatBuriedAgainMidReleaseReclaimsItsOwnPanel() {
        let (panels, filmer, probe, _, made) = Self.harness()
        panels.setHoists([Self.binding(1)], feedback: Self.nowhere)
        probe.covered = true
        panels.setHoists([], feedback: Self.nowhere)
        panels.setHoists([Self.binding(1)], feedback: Self.nowhere)

        let surface = made()[WindowId(1)]!
        #expect(made().count == 1)                        // one panel, not two
        #expect(surface.log.contains("reclaim"))
        #expect(filmer.films == [WindowId(1)])            // filmed once
    }

    /// …and the fence it left behind cannot then take it down under the float that came back.
    @Test func aReclaimedPanelIsNotDismissedByItsOwnStaleFence() {
        let (panels, _, probe, scheduler, made) = Self.harness()
        panels.setHoists([Self.binding(1)], feedback: Self.nowhere)
        probe.covered = true
        panels.setHoists([], feedback: Self.nowhere)
        panels.setHoists([Self.binding(1)], feedback: Self.nowhere)

        probe.covered = false
        scheduler.fire()
        #expect(!made()[WindowId(1)]!.log.contains("dismiss"))
    }

    /// Quitting is the one exit that waits for nothing: there is no desktop left to hand back to.
    @Test func retireAllTakesDownAReleasingPanelToo() {
        let (panels, _, probe, _, made) = Self.harness()
        panels.setHoists([Self.binding(1)], feedback: Self.nowhere)
        probe.covered = true
        panels.setHoists([], feedback: Self.nowhere)

        panels.retireAll()
        #expect(made()[WindowId(1)]!.log.last == "retire")
    }

    /// Bottom→top, each above the one before it. `0` is the front of the level, so the first is simply
    /// put there and the rest stack on it.
    @Test func theSetIsStackedInTheOrderItArrives() {
        let (panels, _, _, _, made) = Self.harness()
        panels.setHoists([Self.binding(1), Self.binding(2)], feedback: Self.nowhere)

        #expect(made()[WindowId(1)]!.log.contains("order>0"))
        #expect(made()[WindowId(2)]!.log.contains("order>1"))
    }

    /// A float that only moved keeps its photograph — the size is the freshness test, as it is in
    /// `SurfaceCache`.
    @Test func aFloatThatMovedIsNotRefilmed() {
        let (panels, filmer, _, _, made) = Self.harness()
        panels.setHoists([Self.binding(1)], feedback: Self.nowhere)
        let moved = Rect(x: 500, y: 400, width: 300, height: 200)
        panels.setHoists([Self.binding(1, moved)], feedback: Self.nowhere)

        #expect(filmer.films == [WindowId(1)])
        #expect(made()[WindowId(1)]!.frame == moved)
    }

    /// A float its app resized is showing pixels of another size, so it is filmed again.
    @Test func aFloatThatResizedIsRefilmed() {
        let (panels, filmer, _, _, _) = Self.harness()
        panels.setHoists([Self.binding(1)], feedback: Self.nowhere)
        panels.setHoists([Self.binding(1, Rect(x: 100, y: 100, width: 400, height: 260))], feedback: Self.nowhere)

        #expect(filmer.films == [WindowId(1), WindowId(1)])
    }
}
