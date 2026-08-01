import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// `Teardown` owns the waiting: AX writes answer later, so the exit is held until they land, and held
// for a bounded time so a beachballed app delays a quit rather than preventing one. Both halves are
// testable because the deadline is a `DelayScheduler` seam and the writes an `Executor` one.

@Suite @MainActor struct TeardownTests {

    /// A scheduler that runs nothing until a test says so — the deadline, held in the hand.
    final class ManualScheduler: DelayScheduler {
        private(set) var delays: [TimeInterval] = []
        private var work: [@MainActor () -> Void] = []

        func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            delays.append(seconds)
            self.work.append(work)
        }

        /// Fire every pending item — "the deadline arrived".
        func fire() {
            let pending = work
            work = []
            for item in pending { item() }
        }
    }

    /// An executor that records and answers on demand, so a test can land windows one at a time.
    final class DeferredExecutor: Executor {
        private(set) var effects: [Effect] = []
        private var feedback: EventSink?

        func execute(_ effects: [Effect], feedback: EventSink) {
            self.effects += effects
            self.feedback = feedback
        }

        func land(_ id: WindowId) { feedback?(.axLanded(id)) }
        func fail(_ id: WindowId) { feedback?(.axFailed(id)) }

        var placed: [WindowId] {
            effects.compactMap { if case .setFrame(let id, _) = $0 { return id } else { return nil } }
        }
    }

    /// A booted state holding `count` tiled windows — the same shape the daemon has at quit time.
    static func world(_ count: UInt64) -> State {
        var state = State()
        (state, _) = drive(state, .screensChanged([MonitorInfo(id: MonitorId(1),
                                                               frame: Rect(x: 0, y: 0,
                                                                           width: 1800, height: 1130))]))
        for raw in 1...count {
            (state, _) = drive(state, .windowCreated(WindowSnapshot(
                id: WindowId(raw), bundleId: "com.test.app", title: "w", role: .standard,
                frame: Rect(x: 100, y: 100, width: 400, height: 300))))
        }
        return state
    }

    /// Reduce one event and settle any transition it opened, so the fixture is a desktop at rest.
    static func drive(_ start: State, _ event: Event) -> (State, [Effect]) {
        var state = start
        var queue: [Effect]
        (state, queue) = Engine.reduce(state, event)
        for _ in 0..<2000 {
            var events: [Event] = []
            for effect in queue {
                switch effect {
                case .capture(let id, _): events.append(.captureReady(id))
                case .setFrame(let id, _), .park(let id, _): events.append(.axLanded(id))
                default: continue
                }
            }
            queue = []
            if events.isEmpty {
                guard state.motion.isTransitioning else { break }
                events = [.tick(dt: 1.0 / 120)]
            }
            for event in events {
                let (next, out) = Engine.reduce(state, event)
                state = next
                queue += out
            }
        }
        return (state, [])
    }

    @Test func itPlacesEveryWindowAndWaitsForAllOfThemToLand() {
        let executor = DeferredExecutor()
        let scheduler = ManualScheduler()
        let teardown = Teardown(executor: executor, scheduler: scheduler)

        var report: Teardown.Report?
        teardown.run(placing: Self.world(3)) { report = $0 }

        #expect(executor.placed.count == 3)
        // Nothing exits early: two of three landings is still a desktop with a window at its nub.
        executor.land(WindowId(1))
        executor.land(WindowId(2))
        #expect(report == nil)

        executor.land(WindowId(3))
        #expect(report == Teardown.Report(windows: 3, unlanded: 0))
        #expect(report?.timedOut == false)
    }

    @Test func aRefusedWriteIsAnAnswerLikeAnyOther() {
        let executor = DeferredExecutor()
        let teardown = Teardown(executor: executor, scheduler: ManualScheduler())

        var report: Teardown.Report?
        teardown.run(placing: Self.world(2)) { report = $0 }

        executor.land(WindowId(1))
        // `axFailed` is the app saying no — a finished conversation. Waiting out the deadline for it
        // would delay the quit to learn nothing.
        executor.fail(WindowId(2))
        #expect(report == Teardown.Report(windows: 2, unlanded: 0))
    }

    @Test func theCallbackFiresExactlyOnce() {
        let executor = DeferredExecutor()
        let scheduler = ManualScheduler()
        let teardown = Teardown(executor: executor, scheduler: scheduler)

        var calls = 0
        teardown.run(placing: Self.world(2)) { _ in calls += 1 }
        executor.land(WindowId(1))
        executor.land(WindowId(2))
        #expect(calls == 1)

        // The deadline still fires afterwards — it is never cancelled — and must be a no-op, or the
        // daemon would `exit(0)` twice.
        scheduler.fire()
        // A duplicate landing (an echo, a retry) likewise.
        executor.land(WindowId(1))
        #expect(calls == 1)
    }

    @Test func aWindowThatNeverAnswersCannotPreventTheQuit() {
        let executor = DeferredExecutor()
        let scheduler = ManualScheduler()
        let teardown = Teardown(executor: executor, scheduler: scheduler, deadline: 1.5)

        var report: Teardown.Report?
        teardown.run(placing: Self.world(3)) { report = $0 }
        #expect(scheduler.delays == [1.5])

        executor.land(WindowId(1))
        scheduler.fire()

        // Out we go, and the report says what was left behind rather than pretending it landed.
        #expect(report?.windows == 3)
        #expect(report?.unlanded == 2)
        #expect(report?.timedOut == true)
    }

    // Nothing to do

    @Test func anEmptyDesktopFinishesImmediatelyAndWithoutATimer() {
        let executor = DeferredExecutor()
        let scheduler = ManualScheduler()
        let teardown = Teardown(executor: executor, scheduler: scheduler)

        var report: Teardown.Report?
        teardown.run(placing: State()) { report = $0 }

        // Synchronous, and no deadline armed: an exit path that depended on a timer for the case with
        // no work in it is the one way this could hang.
        #expect(report == Teardown.Report(windows: 0, unlanded: 0))
        #expect(scheduler.delays.isEmpty)
        #expect(executor.effects.isEmpty)
    }

    @Test func aSecondQuitDoesNothing() {
        let executor = DeferredExecutor()
        let teardown = Teardown(executor: executor, scheduler: ManualScheduler())

        var calls = 0
        teardown.run(placing: Self.world(2)) { _ in calls += 1 }
        let first = executor.effects.count

        // Ctrl-C twice, or Ctrl-C into a menu-bar Quit. The desktop must not be cascaded on top of a
        // cascade already in flight.
        teardown.run(placing: Self.world(2)) { _ in calls += 1 }
        #expect(executor.effects.count == first)

        executor.land(WindowId(1))
        executor.land(WindowId(2))
        #expect(calls == 1)
    }
}
