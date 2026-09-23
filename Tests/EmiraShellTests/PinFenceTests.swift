import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

/// `PinFence` — the wait between a pin's activation and the teleport it entitles.
@MainActor
@Suite struct PinFenceTests {

    /// Holds each question until the test answers it, and keeps what it was asked.
    final class HeldProbe: StackProbe {
        private(set) var asked: [(window: WindowId, over: Set<WindowId>)] = []
        private var pending: [@MainActor (Bool) -> Void] = []

        func isCovered(_ window: WindowId, within frame: Rect, orBy others: Set<WindowId>,
                       then: @escaping @MainActor (Bool) -> Void) {
            asked.append((window, others))
            pending.append(then)
        }

        func answer(_ covered: Bool) {
            let due = pending
            pending = []
            for then in due { then(covered) }
        }
    }

    /// Timers the test fires, oldest first — the grace is armed before any re-ask.
    final class ManualScheduler: DelayScheduler {
        private(set) var delays: [TimeInterval] = []
        private var work: [@MainActor () -> Void] = []

        func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            delays.append(seconds)
            self.work.append(work)
        }

        func fireOldest() {
            guard !work.isEmpty else { return }
            work.removeFirst()()
        }

        func fireNewest() {
            guard !work.isEmpty else { return }
            work.removeLast()()
        }
    }

    static let pin = WindowId(1)
    static let band = Rect(x: 1200, y: 0, width: 500, height: 1000)

    /// **Nothing is read before the pin's app is activated** — the desktop then is the one from before
    /// anything was asked, and its order may be about to change.
    @Test func nothingIsAskedUntilThePinIsActivated() {
        let probe = HeldProbe()
        let fence = PinFence(probe: probe, scheduler: ManualScheduler())
        var reports = 0
        fence.confirm(Self.pin, over: [WindowId(2)], within: Self.band) { reports += 1 }
        #expect(probe.asked.isEmpty)

        fence.activated(Self.pin)
        #expect(probe.asked.count == 1)
        #expect(probe.asked.first?.over == [WindowId(2)], "the windows it must be above ride on the question")
        probe.answer(false)
        #expect(reports == 1)
    }

    /// A covered reading is asked again, and only the clear one reports.
    @Test func aCoveredPinIsAskedAgainUntilItIsNot() {
        let probe = HeldProbe()
        let scheduler = ManualScheduler()
        let fence = PinFence(probe: probe, scheduler: scheduler)
        var reports = 0
        fence.confirm(Self.pin, over: [WindowId(2)], within: Self.band) { reports += 1 }
        fence.activated(Self.pin)

        probe.answer(true)
        #expect(reports == 0)
        scheduler.fireNewest()                                  // the re-ask, not the grace
        #expect(probe.asked.count == 2)
        probe.answer(false)
        #expect(reports == 1)
    }

    /// **A delay, not a veto** — and an activation that never came is waited out rather than awaited,
    /// since a superseded or refused one never says so.
    @Test func anActivationThatNeverComesIsWaitedOut() {
        let probe = HeldProbe()
        let scheduler = ManualScheduler()
        let fence = PinFence(probe: probe, scheduler: scheduler)
        var reports = 0
        fence.confirm(Self.pin, over: [], within: Self.band) { reports += 1 }
        scheduler.fireOldest()
        #expect(reports == 1)
        #expect(probe.asked.isEmpty)

        fence.activated(Self.pin)                               // late: the question is already answered
        #expect(probe.asked.isEmpty)
    }

    /// The fence waits half the transition's own deadline, leaving the rest to the teleport and its
    /// landings — and follows that deadline when a reload changes it.
    @Test func theGraceIsHalfTheHoldTimeout() {
        let scheduler = ManualScheduler()
        let fence = PinFence(probe: HeldProbe(), scheduler: scheduler, holdTimeout: 1.0)
        fence.confirm(Self.pin, over: [], within: Self.band) {}
        fence.holdTimeout = 2.0
        fence.confirm(WindowId(2), over: [], within: Self.band) {}
        #expect(scheduler.delays == [0.5, 1.0])
    }

    /// **A second request for the same pin replaces the first**, which never reports: the event names
    /// only the window, so the first's reading would answer the second's question.
    @Test func aNewerRequestForThePinReplacesTheOlder() {
        let probe = HeldProbe()
        let scheduler = ManualScheduler()
        let fence = PinFence(probe: probe, scheduler: scheduler)
        var older = 0
        var newer = 0
        fence.confirm(Self.pin, over: [WindowId(2)], within: Self.band) { older += 1 }
        fence.activated(Self.pin)
        fence.confirm(Self.pin, over: [WindowId(2), WindowId(3)], within: Self.band) { newer += 1 }
        #expect(older == 0 && newer == 0, "the second request is not answered on the spot")

        probe.answer(false)                                     // the first request's reading lands
        #expect(older == 0 && newer == 0, "a reading taken for the older question answers nothing")

        fence.activated(Self.pin)
        #expect(probe.asked.last?.over == [WindowId(2), WindowId(3)])
        probe.answer(false)
        scheduler.fireOldest()                                  // the older grace expiring changes nothing
        #expect(older == 0)
        #expect(newer == 1)
    }
}
