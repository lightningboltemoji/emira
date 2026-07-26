import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The pump's own tests (IMPLEMENTATION.md §1 invariant 4, §8). `EmiraCoreTests` proves the *brain* —
// what the reducer decides. These prove the *loop* around it: that events reduce one at a time, in
// order, never inside one another; that each event's effects reach the executor before the next event
// reduces; that a whole transition cascade settles in a single run-loop turn; and that the frame clock
// runs exactly while there is motion to animate.
//
// Everything here is headless — `Runtime`, `Executor`, and `FrameClock` import no framework, so the
// spine of the daemon is verified with no AppKit, AX, Core Animation, or ScreenCaptureKit in sight.

@Suite @MainActor struct RuntimeTests {

    // MARK: - Fixtures

    /// A 1000×800 display at the origin.
    static let display = Rect(x: 0, y: 0, width: 1000, height: 800)

    /// One full-width preset — a column *is* the viewport, so every cross-column focus genuinely
    /// scrolls (and therefore opens a transition). Same trick as `EngineTests.fullWidth`.
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
        for i in 0..<max(windows, 0) {
            (s, _) = Engine.reduce(s, .windowCreated(snapshot(UInt64(i + 1))))
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
        let executor = MockExecutor()
        let runtime = Runtime(state: Self.booted(), executor: executor)

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

    /// Invariant 4, stated as a trace: an event dispatched *from inside* `execute` must not reduce
    /// until the in-flight event's effects are fully issued. A re-entrant pump would nest the batches
    /// (`enter#0, enter#1, exit#1, exit#0`); a queued one serializes them.
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

    /// The cascade a real scroll command sets off — command → captures → cover raise → teleport →
    /// landings — all resolves inside the *single* `dispatch` call, because a perfectly responsive
    /// executor acks synchronously and the queue drains before returning.
    @Test func aScrollCommandRaisesTheCoverWithinOneDispatch() {
        let executor = MockExecutor(mode: .simulate)
        let runtime = Runtime(state: Self.booted(config: Self.fullWidth, windows: 3),
                              executor: executor)

        runtime.dispatch(.command(.focus(.left)))               // window 3 → window 2: a real scroll

        #expect(runtime.state.motion.isCovered)                 // captures in, cover up
        #expect(runtime.state.world.focusedWindow == WindowId(2))
        // Captured both scoped windows (visible at the start offset ∪ at the end offset), then raised.
        let bindings = executor.effects.compactMap { if case .beginTransition(let b) = $0 { return b }; return nil }
        #expect(bindings.count == 1)
        #expect(bindings.first?.map(\.window) == [WindowId(2), WindowId(3)])
        // …and the reals teleported behind it, in the same turn.
        #expect(executor.effects.contains { if case .setFrame(WindowId(2), _) = $0 { return true }; return false })
        #expect(executor.effects.contains { if case .park(WindowId(3), _) = $0 { return true }; return false })
    }

    /// The whole loop, closed: clock gated on, layers blitted every frame, transition torn down when
    /// the spring settles, clock gated back off. This is M2's shape with the pixels still fake.
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
        let runtime = Runtime(state: Self.booted(config: Self.fullWidth),
                              executor: MockExecutor(mode: .simulate), clock: clock)

        runtime.dispatch(.windowCreated(Self.snapshot(1)))      // snap placement — no cover, no motion
        runtime.dispatch(.windowCreated(Self.snapshot(2)))
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

    /// **The regression the structural-edit slice fixes.** The deadline is re-armed on every redirect,
    /// and what counts as a redirect used to be a change in `viewportOffset.target` — which is
    /// invisible when the redirect is a *structural* one. Two 500-wide columns fill this viewport
    /// exactly, so swapping them left and then back moves the viewport not one point; before the fix
    /// the second press inherited the first press's deadline and was liable to a `holdTimeout`
    /// mid-motion, which is precisely the "cover yanked out from under the user" failure `syncHold`
    /// exists to prevent.
    ///
    /// `Motion.retargetGeneration` counts re-aims of *every* animated quantity, which is the question
    /// actually being asked. The same latent defect existed for `cycleWidth`; the structural edits
    /// merely made it the common path.
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
