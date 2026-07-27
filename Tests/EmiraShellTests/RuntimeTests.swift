import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The pump's own tests. `EmiraCoreTests` proves what the reducer decides; these prove the loop around
// it: events reduce one at a time, in order, never inside one another; each event's effects reach the
// executor before the next event reduces; a whole transition cascade settles in one run-loop turn; and
// the frame clock runs exactly while there is motion to animate. All headless — `Runtime`, `Executor`
// and `FrameClock` import no framework.

@Suite @MainActor struct RuntimeTests {

    // MARK: - Fixtures

    /// A 1000×800 display at the origin.
    static let display = Rect(x: 0, y: 0, width: 1000, height: 800)

    /// One full-width preset — a column is the viewport, so every cross-column focus genuinely scrolls
    /// and therefore opens a transition.
    static let fullWidth = Config(widthPresets: PresetCycle([.proportion(1.0)]))

    /// One ½-width preset — two columns fill the viewport exactly, so a structural edit rearranges the
    /// strip without the viewport moving at all. That combination is what the hold-deadline tests need.
    static let halfWidth = Config(widthPresets: PresetCycle([.proportion(0.5)]))

    static func snapshot(_ raw: UInt64) -> WindowSnapshot {
        WindowSnapshot(id: WindowId(raw), bundleId: "com.test.app", title: "w", role: .standard,
                       frame: Rect(x: 300, y: 300, width: 200, height: 200))
    }

    /// A state that already knows one display and `windows` tiled windows, built by driving the
    /// reducer directly — the same bootstrap the daemon performs with real events, minus the shell.
    static func booted(config: Config = Config(), windows: Int = 0) -> State {
        var s = State(config: config)
        (s, _) = Engine.reduce(s, .screensChanged([MonitorInfo(id: MonitorId(1), frame: display)]))
        // Arrivals animate, and a fixture means "here is the desktop", not "here is one mid-transition".
        for i in 0..<max(windows, 0) {
            s = settledAfter(s, .windowCreated(snapshot(UInt64(i + 1))))
        }
        return s
    }

    /// Run the clock until it stops (the transition closed) or the budget runs out — so a spring that
    /// never converges fails loudly instead of hanging the suite. Returns the frames delivered.
    @discardableResult
    static func runClock(_ clock: ManualFrameClock, budget: Int = 5000) -> Int {
        var frames = 0
        while clock.isRunning && frames < budget {
            clock.fire()
            frames += 1
        }
        return frames
    }

    /// The window ids a run of effects focused, in order.
    static func focusedIds(in effects: [Effect]) -> [WindowId] {
        effects.compactMap { if case .focus(let w) = $0 { return w }; return nil }
    }

    // MARK: - The pump

    @Test func dispatchReducesAndHandsTheEffectsToTheExecutor() {
        // Unsmoothed, so the arrival places in the same batch it reduces in: this test is about the
        // pump (one event, one batch), and a cover would put the placement a round trip away.
        let executor = MockExecutor()
        let runtime = Runtime(state: Self.booted(config: Config(smoothTransitions: false)),
                              executor: executor)

        runtime.dispatch(.windowCreated(Self.snapshot(1)))

        // State advanced…
        #expect(runtime.state.world.focusedWindow == WindowId(1))
        #expect(runtime.state.layout.columns.count == 1)
        // …and the effects of that one event arrived as exactly one batch.
        #expect(executor.batches.count == 1)
        #expect(executor.effects.contains(.focus(WindowId(1))))
        #expect(executor.effects.contains { if case .setFrame(WindowId(1), _) = $0 { return true }; return false })
    }

    @Test func eventsThatProduceNoEffectsDeliverNoBatch() {
        let executor = MockExecutor()
        let runtime = Runtime(state: Self.booted(), executor: executor)

        runtime.dispatch(.crossfadeDone)                       // inert when idle
        runtime.dispatch(.windowFrameChanged(WindowId(9), Rect(x: 0, y: 0, width: 10, height: 10)))
        runtime.dispatch(.command(.dumpState))                 // deferred command, no-op

        #expect(executor.batches.isEmpty)                      // an executor never sees empty work
    }

    /// An event dispatched from inside `execute` must not reduce until the in-flight event's effects
    /// are issued: a re-entrant pump nests the batches, a queued one serializes them.
    @Test func dispatchDuringExecuteIsQueuedNotReentrant() {
        let executor = ScriptedExecutor()
        let runtime = Runtime(state: Self.booted(), executor: executor)
        executor.onExecute = { index, _, _ in
            guard index == 0 else { return }
            runtime.dispatch(.windowCreated(Self.snapshot(2)))  // re-enter the pump
        }

        runtime.dispatch(.windowCreated(Self.snapshot(1)))

        #expect(executor.trace == ["enter#0", "exit#0", "enter#1", "exit#1"])
        #expect(runtime.state.world.windows.count == 2)         // both events did reduce
    }

    /// …and the queue is a *queue*: events enqueued mid-pump reduce in the order they arrived.
    @Test func queuedEventsReduceInFifoOrder() {
        let executor = ScriptedExecutor()
        let runtime = Runtime(state: Self.booted(), executor: executor)
        executor.onExecute = { index, _, _ in
            guard index == 0 else { return }
            runtime.dispatch(.windowCreated(Self.snapshot(2)))
            runtime.dispatch(.windowCreated(Self.snapshot(3)))
        }

        runtime.dispatch(.windowCreated(Self.snapshot(1)))

        // Each new window focuses itself, so the focus effects are a legible transcript of reduce order.
        #expect(Self.focusedIds(in: executor.effects) == [WindowId(1), WindowId(2), WindowId(3)])
        #expect(runtime.state.world.focusedWindow == WindowId(3))
    }

    @Test func sinkFeedsThePumpLikeDispatch() {
        let executor = MockExecutor()
        let runtime = Runtime(state: Self.booted(), executor: executor)

        runtime.sink(.windowCreated(Self.snapshot(1)))

        #expect(runtime.state.world.focusedWindow == WindowId(1))
        #expect(executor.batches.count == 1)
    }

    /// The sink is a value with a weak capture, so handing it to every subsystem in the shell can't
    /// keep a torn-down Runtime alive — and a late ack from an in-flight AX set is a no-op, not a crash.
    @Test func sinkDoesNotKeepTheRuntimeAlive() {
        var runtime: Runtime? = Runtime(executor: MockExecutor())
        weak let weakRuntime = runtime
        let sink = runtime!.sink

        runtime = nil

        #expect(weakRuntime == nil)
        sink(.axLanded(WindowId(1)))                            // safely ignored
    }

    // MARK: - The transition lifecycle, end to end through the pump

    /// The whole cascade — command → captures → cover raise → teleport → landings — resolves inside
    /// one `dispatch`, because a perfectly responsive executor acks synchronously.
    @Test func aScrollCommandRaisesTheCoverWithinOneDispatch() {
        let executor = MockExecutor(mode: .simulate)
        let runtime = Runtime(state: Self.booted(config: Self.fullWidth, windows: 3),
                              executor: executor)

        runtime.dispatch(.command(.focus(.left)))               // window 3 → window 2: a real scroll

        #expect(runtime.state.motion.isCovered)                 // captures in, cover up
        #expect(runtime.state.world.focusedWindow == WindowId(2))
        // Captured every scoped window — the two the scroll sweeps, plus w1 as the shoulder past its
        // left end (`Layout.sweptWindowIds`) — then raised.
        let bindings = executor.effects.compactMap { if case .beginTransition(let b) = $0 { return b }; return nil }
        #expect(bindings.count == 1)
        #expect(bindings.first?.map(\.window) == [WindowId(1), WindowId(2), WindowId(3)])
        // …and the reals teleported behind it, in the same turn.
        #expect(executor.effects.contains { if case .setFrame(WindowId(2), _) = $0 { return true }; return false })
        #expect(executor.effects.contains { if case .park(WindowId(3), _) = $0 { return true }; return false })
    }

    /// The whole loop, closed: clock gated on, layers blitted every frame, transition torn down when
    /// the spring settles, clock gated back off.
    @Test func aScrollRunsToCompletionAndTearsTheSessionDown() {
        let executor = MockExecutor(mode: .simulate)
        let clock = ManualFrameClock()
        let runtime = Runtime(state: Self.booted(config: Self.fullWidth, windows: 3),
                              executor: executor, clock: clock)

        runtime.dispatch(.command(.focus(.left)))
        #expect(clock.isRunning)                                // motion ⇒ ticks
        let frames = Self.runClock(clock)

        #expect(frames > 1)                                     // it actually animated
        #expect(!runtime.state.motion.isTransitioning)          // session torn down
        #expect(!clock.isRunning)                               // idle ⇒ no ticks
        #expect(clock.startCount == 1 && clock.stopCount == 1)  // exactly one start/stop per transition
        // Layers were blitted…
        #expect(executor.effects.contains { if case .setLayerFrame = $0 { return true }; return false })
        // …and the last thing the shell was asked to do was cross-fade the cover away.
        #expect(executor.effects.last == .endTransition)
        // The strip came to rest at the scroll's destination: column 1 (window 2) fills the viewport.
        #expect(abs(runtime.state.motion.viewportOffset.current - 1000) < 0.5)
    }

    // MARK: - Frame-clock gating

    @Test func idleWorkNeverStartsTheClock() {
        let clock = ManualFrameClock()
        let runtime = Runtime(state: Self.booted(config: Self.fullWidth, windows: 2),
                              executor: MockExecutor(mode: .simulate), clock: clock)

        // Genuinely idle work — the world is already built and settled by the fixture. An arrival is
        // not idle: it animates.
        runtime.dispatch(.dragEnded)
        runtime.dispatch(.windowFrameChanged(Self.snapshot(1).id, Rect(x: 0, y: 0, width: 10, height: 10)))
        runtime.dispatch(.dragEnded)

        #expect(clock.startCount == 0)
        #expect(!clock.isRunning)
    }

    /// A second scroll command mid-flight retargets the *open* session (the interrupt the core is built
    /// for) — from the pump's side that must read as one clock start and one clock stop, not two.
    @Test func anInterruptDoesNotRestartTheClock() {
        let executor = MockExecutor(mode: .simulate)
        let clock = ManualFrameClock()
        let runtime = Runtime(state: Self.booted(config: Self.fullWidth, windows: 3),
                              executor: executor, clock: clock)

        runtime.dispatch(.command(.focus(.left)))               // → window 2
        for _ in 0..<3 { clock.fire() }                         // three frames in
        runtime.dispatch(.command(.focus(.right)))              // interrupt: back to window 3
        Self.runClock(clock)

        #expect(clock.startCount == 1 && clock.stopCount == 1)
        #expect(!runtime.state.motion.isTransitioning)
        #expect(runtime.state.world.focusedWindow == WindowId(3))
        #expect(abs(runtime.state.motion.viewportOffset.current - 2000) < 0.5)
    }

    // MARK: - Hold-deadline gating

    /// The ordinary shape: a session opens, the deadline is armed once, and closing on time cancels it.
    @Test func aTransitionArmsTheDeadlineAndClosingCancelsIt() {
        let clock = ManualFrameClock()
        let hold = ManualHoldTimer()
        let runtime = Runtime(state: Self.booted(config: Self.fullWidth, windows: 3),
                              executor: MockExecutor(mode: .simulate), clock: clock, hold: hold)

        runtime.dispatch(.command(.focus(.left)))
        #expect(hold.armCount == 1)
        #expect(hold.cancelCount == 0)

        Self.runClock(clock)
        #expect(!runtime.state.motion.isTransitioning)
        #expect(hold.cancelCount == 1)
    }

    /// A redirect must re-arm the deadline even when it is structural. Two 500-wide columns fill this
    /// viewport exactly, so swapping them left and back moves `viewportOffset.target` not one point —
    /// hence `Motion.retargetGeneration`, which counts re-aims of every animated quantity.
    @Test func aRedirectThatDoesNotMoveTheViewportStillReArmsTheDeadline() {
        let clock = ManualFrameClock()
        let hold = ManualHoldTimer()
        let runtime = Runtime(state: Self.booted(config: Self.halfWidth, windows: 2),
                              executor: MockExecutor(mode: .simulate), clock: clock, hold: hold)
        let resting = runtime.state.motion.viewportOffset.target

        runtime.dispatch(.command(.moveWindow(.left)))          // [w2, w1]
        #expect(hold.armCount == 1)
        #expect(runtime.state.motion.isTransitioning)

        for _ in 0..<3 { clock.fire() }
        runtime.dispatch(.command(.moveWindow(.right)))         // back to [w1, w2]
        #expect(runtime.state.motion.viewportOffset.target == resting)   // the viewport never moved
        #expect(hold.armCount == 2)                                      // …and it re-armed anyway

        Self.runClock(clock)
        #expect(!runtime.state.motion.isTransitioning)
    }
}

// MARK: - Test doubles

/// A `FrameClock` whose frames are delivered by hand, so a transition's animation runs at whatever
/// pace the test wants and never depends on a real display link.
@MainActor
final class ManualFrameClock: FrameClock {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false
    private var sink: EventSink?

    func start(sink: EventSink) {
        startCount += 1
        isRunning = true
        self.sink = sink
    }

    func stop() {
        stopCount += 1
        isRunning = false
        sink = nil
    }

    /// Deliver one frame. No-op (returning `false`) while stopped — which is what makes `runClock`'s
    /// loop terminate exactly when the Runtime gates the clock off.
    @discardableResult
    func fire(dt: Double = 1.0 / 120) -> Bool {
        guard isRunning, let sink else { return false }
        sink(.tick(dt: dt))
        return true
    }
}

/// An executor that traces its own call brackets and lets a test re-enter the pump from inside
/// `execute`. The bracket trace is what makes non-re-entrancy observable: nesting would interleave it.
@MainActor
final class ScriptedExecutor: Executor {
    private(set) var trace: [String] = []
    private(set) var batches: [[Effect]] = []
    var onExecute: ((Int, [Effect], EventSink) -> Void)?

    var effects: [Effect] { batches.flatMap { $0 } }

    func execute(_ effects: [Effect], feedback: EventSink) {
        let index = batches.count
        batches.append(effects)
        trace.append("enter#\(index)")
        onExecute?(index, effects, feedback)
        trace.append("exit#\(index)")
    }
}
