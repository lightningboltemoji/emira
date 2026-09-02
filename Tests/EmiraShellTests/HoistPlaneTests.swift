import CoreGraphics
import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The hoist plane's policy: the diff that keeps the panels matching the core's set, the standby that
// makes a burial an alpha flip rather than a screenshot, and the fence that holds a released picture up
// until the window server says the real window is in front of it.

@Suite @MainActor struct HoistPlaneTests {

    /// A `HoistSurface` that is a record of calls rather than a window.
    final class RecordingSurface: HoistSurface {
        let window: WindowId
        private(set) var frame: Rect
        private(set) var isRevealed = false
        private(set) var log: [String] = []
        private var hasImage = false
        private var wantsReveal = false

        var handle: Int { Int(window.raw) }

        init(window: WindowId, frame: Rect) {
            self.window = window
            self.frame = frame
        }

        func place(at frame: Rect) { self.frame = frame; log.append("place") }
        func order(above handle: Int) { log.append("order>\(handle)") }
        func release() { log.append("release") }

        func setImage(_ image: CGImage) {
            log.append(hasImage ? "refresh" : "image")
            hasImage = true
            if wantsReveal { reveal() }
        }

        func reveal() {
            wantsReveal = true
            guard hasImage, !isRevealed else { return }
            isRevealed = true
            log.append("reveal")
        }

        func conceal(over duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
            wantsReveal = false
            guard isRevealed else { return completion() }
            isRevealed = false
            log.append("conceal")
            completion()
        }

        func retire() {
            isRevealed = false
            wantsReveal = false
            log.append("retire")
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

    /// Films on request and holds the answer, so a test says when the photograph lands.
    final class HeldFilmer: SurfaceFilmer {
        private(set) var films: [WindowId] = []
        private var pending: [@MainActor (CapturedSurface?) -> Void] = []

        func film(_ window: WindowId, on monitor: MonitorId,
                  then: @escaping @MainActor (CapturedSurface?) -> Void) {
            films.append(window)
            pending.append(then)
        }

        /// Every film in flight lands.
        func deliver() {
            let due = pending
            pending = []
            for then in due { then(CapturedSurface(image: Self.pixel, frame: .zero)) }
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

    static func harness() -> (HoistPanels, HeldFilmer, FakeProbe, ManualScheduler,
                              () -> [WindowId: RecordingSurface]) {
        let filmer = HeldFilmer()
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

    static func binding(_ raw: UInt64, _ state: HoistState = .covered,
                        _ frame: Rect = HoistPlaneTests.frame) -> HoistBinding {
        HoistBinding(window: WindowId(raw), monitor: monitor, frame: frame, state: state)
    }

    // Standby

    /// The point of standby: the panel is built and filmed while the float is still in the open, and
    /// shows nothing until something covers it.
    @Test func aStandbyFloatIsFilmedAndStaysInvisible() {
        let (panels, filmer, _, _, made) = Self.harness()
        panels.setHoists([Self.binding(1, .standby)], feedback: Self.nowhere)
        filmer.deliver()

        #expect(filmer.films == [WindowId(1)])
        #expect(made()[WindowId(1)]?.isRevealed == false)
        #expect(made()[WindowId(1)]?.log == ["place", "order>0", "image"])
    }

    /// …so burial costs no screenshot at all: the pixels are already loaded and revealing is the whole
    /// of it. This is the flash on the way in, closed.
    @Test func buryingAStandbyFloatRevealsItWithoutFilmingFirst() {
        let (panels, filmer, _, _, made) = Self.harness()
        panels.setHoists([Self.binding(1, .standby)], feedback: Self.nowhere)
        filmer.deliver()
        panels.setHoists([Self.binding(1, .covered)], feedback: Self.nowhere)

        let surface = made()[WindowId(1)]!
        #expect(surface.isRevealed)
        // Revealed before the burial's own film was even asked for, let alone landed.
        #expect(surface.log.firstIndex(of: "reveal")! < (surface.log.firstIndex(of: "refresh") ?? .max))
    }

    /// A float buried before its standby film lands owes the reveal, and the film pays it.
    @Test func aRevealBeforeThePixelsExistIsOwedAndThenPaid() {
        let (panels, filmer, _, _, made) = Self.harness()
        panels.setHoists([Self.binding(1, .standby)], feedback: Self.nowhere)
        panels.setHoists([Self.binding(1, .covered)], feedback: Self.nowhere)
        #expect(made()[WindowId(1)]?.isRevealed == false)      // nothing to show yet

        filmer.deliver()
        #expect(made()[WindowId(1)]?.isRevealed == true)
    }

    // The release fence

    /// The defect the fence exists for. The core stops covering a float on an AX focus report, which
    /// says the app told us its focus moved — not that the raise reached the glass. Concealing then
    /// shows the window still in front of it.
    @Test func aReleasedPictureStaysUpWhileTheWindowServerSaysItIsStillCovered() {
        let (panels, filmer, probe, scheduler, made) = Self.harness()
        panels.setHoists([Self.binding(1, .covered)], feedback: Self.nowhere)
        filmer.deliver()
        let surface = made()[WindowId(1)]!

        probe.covered = true
        panels.setHoists([Self.binding(1, .standby)], feedback: Self.nowhere)
        #expect(surface.log.contains("release"))          // clicks let go at once…
        #expect(surface.isRevealed)                       // …picture held

        scheduler.fire()                                  // still covered: asked again, still held
        #expect(probe.asks == 2)
        #expect(surface.isRevealed)

        probe.covered = false
        scheduler.fire()
        #expect(!surface.isRevealed)
        #expect(surface.log.contains("conceal"))
    }

    /// Nothing over it: the picture goes at once, on one ask.
    @Test func anUncoveredFloatConcealsWithoutWaiting() {
        let (panels, filmer, probe, _, made) = Self.harness()
        panels.setHoists([Self.binding(1, .covered)], feedback: Self.nowhere)
        filmer.deliver()
        probe.covered = false
        panels.setHoists([Self.binding(1, .standby)], feedback: Self.nowhere)

        #expect(made()[WindowId(1)]!.log == ["place", "order>0", "image", "reveal",
                                             "place", "order>0", "release", "conceal"])
        #expect(probe.asks == 1)
    }

    /// A fence is a delay, not a veto. An activation the system refused leaves the float genuinely
    /// behind, and a shell that kept a picture the core had dropped would be a second opinion about what
    /// is on the screen.
    @Test func aFenceThatNeverClearsGivesUp() {
        let (panels, filmer, probe, scheduler, made) = Self.harness()
        panels.setHoists([Self.binding(1, .covered)], feedback: Self.nowhere)
        filmer.deliver()
        probe.covered = true
        panels.setHoists([Self.binding(1, .standby)], feedback: Self.nowhere)

        let surface = made()[WindowId(1)]!
        let start = Date()
        while Date().timeIntervalSince(start) < 0.2, !surface.log.contains("conceal") {
            scheduler.fire()
        }
        #expect(surface.log.contains("conceal"))
    }

    /// The float was buried again while its picture was being let go. It keeps the panel and the pixels
    /// — nothing is rebuilt and nothing is refilmed, because neither ever left.
    @Test func aFloatBuriedAgainMidReleaseKeepsItsPictureUp() {
        let (panels, filmer, probe, scheduler, made) = Self.harness()
        panels.setHoists([Self.binding(1, .covered)], feedback: Self.nowhere)
        filmer.deliver()
        probe.covered = true
        panels.setHoists([Self.binding(1, .standby)], feedback: Self.nowhere)
        panels.setHoists([Self.binding(1, .covered)], feedback: Self.nowhere)

        let surface = made()[WindowId(1)]!
        #expect(surface.isRevealed)
        #expect(made().count == 1)
        #expect(filmer.films == [WindowId(1)])

        // …and the fence it left behind cannot take it down under the float that came back.
        probe.covered = false
        scheduler.fire()
        #expect(surface.isRevealed)
        #expect(!surface.log.contains("conceal"))
    }

    // Teardown

    /// A float that closed, stopped floating or left the screen has nothing left to stand in for.
    @Test func aFloatTheCoreStopsNamingIsRetired() {
        let (panels, filmer, probe, _, made) = Self.harness()
        panels.setHoists([Self.binding(1, .covered)], feedback: Self.nowhere)
        filmer.deliver()
        probe.covered = false
        panels.setHoists([], feedback: Self.nowhere)

        #expect(made()[WindowId(1)]!.log.last == "retire")
    }

    /// Quitting is the one exit that waits for nothing: there is no desktop left to hand back to.
    @Test func retireAllTakesDownAPictureMidFenceToo() {
        let (panels, filmer, probe, _, made) = Self.harness()
        panels.setHoists([Self.binding(1, .covered)], feedback: Self.nowhere)
        filmer.deliver()
        probe.covered = true
        panels.setHoists([], feedback: Self.nowhere)      // fence pending

        panels.retireAll()
        #expect(made()[WindowId(1)]!.log.last == "retire")
    }

    // The diff

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
        panels.setHoists([Self.binding(1, .covered, moved)], feedback: Self.nowhere)

        #expect(filmer.films == [WindowId(1)])
        #expect(made()[WindowId(1)]!.frame == moved)
    }

    /// A float its app resized is showing pixels of another size, so it is filmed again.
    @Test func aFloatThatResizedIsRefilmed() {
        let (panels, filmer, _, _, _) = Self.harness()
        panels.setHoists([Self.binding(1)], feedback: Self.nowhere)
        panels.setHoists([Self.binding(1, .covered, Rect(x: 100, y: 100, width: 400, height: 260))],
                         feedback: Self.nowhere)

        #expect(filmer.films == [WindowId(1), WindowId(1)])
    }
}
