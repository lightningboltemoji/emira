import Foundation
import EmiraCore

// The pump — the one place `Engine.reduce` is called, and the only writer of core `State` in the whole
// application. Event sources push `Event`s in through `dispatch`/`sink`, the `Executor` takes `Effect`s
// out. Framework-free, so the loop that holds the system together is provable headless.
//
// Never re-entrant, and on macOS that is not optional: accidental recursion is the platform default — an
// AX set can complete on the calling thread, `orderFront` fires delegate notifications synchronously,
// and a fast executor may ack an effect *inside* `execute`. `dispatch` during an active pump appends to
// a FIFO and returns, so no event reduces against a `State` whose predecessor only half-issued its
// effects. Interruption and retargeting happen *between* pumps, still within one run-loop turn.

/// The `@MainActor` event pump that hosts the core.
///
/// Wiring (the daemon's job): construct with an `Executor` and the time sources, then point every event
/// source at `sink`. Nothing else in the shell holds core state.
@MainActor
public final class Runtime {

    /// The live core state. Readable by the shell (a state dump, the menu-bar indicator) but writable
    /// only here, by `Engine.reduce`.
    public private(set) var state: State

    /// Interprets the effects the core emits.
    private let executor: any Executor

    /// The tick source, gated on transition activity. `nil` in headless contexts that drive ticks by
    /// hand (tests, replay).
    private let clock: (any FrameClock)?

    /// The transition deadline, gated on the same bit as the clock. `nil` where there is no wall clock
    /// to bound and a transition simply runs to completion.
    private let hold: (any HoldTimer)?

    /// The FIFO of events waiting to reduce. Drained by `pump`; appended to by `dispatch` at any time,
    /// including from inside `Executor.execute`.
    private var queue: [Event] = []

    /// Read cursor into `queue` — an index rather than `removeFirst()` so draining a burst of feedback
    /// events stays O(n) instead of O(n²). Reset with the queue at the end of each drain.
    private var head = 0

    /// Whether a drain is in progress. The single bit that makes the pump non-re-entrant. Readable
    /// inside the module so a test can assert an `onStateChanged` observer is never called mid-drain.
    private(set) var isPumping = false

    /// Whether the frame clock is currently running, so `start`/`stop` are each called exactly once per
    /// transition rather than on every event.
    private var clockRunning = false

    /// The core's retarget generation the pending hold deadline was armed against, `nil` when none is.
    /// Answers both questions at once: whether a deadline is outstanding, and whether it still bounds the
    /// wait the user is in.
    private var holdArmedFor: UInt64?

    /// Create a pump around a fresh (or restored) state.
    ///
    /// - Parameters:
    ///   - state: the initial core state. Defaults to empty — the daemon bootstraps it by dispatching
    ///     `screensChanged` plus a `windowCreated` per enumerated window, so launch is just events.
    ///   - executor: the effect interpreter.
    ///   - clock: the tick source to gate, or `nil` to drive ticks manually.
    ///   - hold: the transition deadline to gate, or `nil` for an unbounded transition.
    public init(state: State = State(), executor: any Executor,
                clock: (any FrameClock)? = nil, hold: (any HoldTimer)? = nil) {
        self.state = state
        self.executor = executor
        self.clock = clock
        self.hold = hold
    }

    /// The handle event sources hold to feed this pump. Stored rather than rebuilt per access so it can
    /// be handed out freely — including to an executor on every `execute` — with no allocation.
    public private(set) lazy var sink = EventSink { [weak self] event in self?.dispatch(event) }

    /// Called once per *drain*, after the queue has emptied and the time sources are in step — never
    /// inside a reduce, never once per event. For shell peripherals that display state rather than change
    /// it: a single command cascades into many events, and a per-event observer would see states the user
    /// never does. Fires unconditionally rather than on change; `State` is too large to diff at 120 Hz.
    ///
    /// An observer must not `dispatch` from here — that would drain again and re-notify.
    public var onStateChanged: (@MainActor (State) -> Void)?

    /// Feed one event to the core.
    ///
    /// If a pump is already running (called from inside `Executor.execute`, or from an event source a
    /// `FrameClock.start` triggered synchronously), the event is queued and this returns immediately — it
    /// reduces after the in-flight event's effects are fully issued, still within this run-loop turn.
    public func dispatch(_ event: Event) {
        queue.append(event)
        guard !isPumping else { return }        // never reduce inside reduce
        pump()
        // Outside the drain, so a clock whose `start` synchronously delivers a tick re-enters `dispatch`
        // cleanly (`clockRunning` is already updated, so it can't recurse further).
        syncTimeSources()
        // Last, so an observer sees a state whose effects are issued *and* whose clock and deadline
        // already match it.
        onStateChanged?(state)
    }

    /// Drain the queue: reduce each event in turn and hand its effects to the executor before the next
    /// reduces. Events appended mid-drain join this same loop, so a whole cascade settles in one call.
    private func pump() {
        isPumping = true
        defer { isPumping = false }
        while head < queue.count {
            let event = queue[head]
            head += 1
            let (next, effects) = Engine.reduce(state, event)
            state = next
            // Skip empty batches so an executor can treat every call as real work (open a
            // `CATransaction`, take a lock) without guarding.
            if !effects.isEmpty {
                executor.execute(effects, feedback: sink)
            }
        }
        queue.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Match both time sources to the core's motion state: a transition session is open ⇒ frames to
    /// animate and a deadline to bound the wait; idle ⇒ neither.
    private func syncTimeSources() {
        syncClock()
        syncHold()
    }

    /// Start or stop the frame clock. The display link is the only always-on cost a window manager can
    /// accidentally pay, and an idle emira pays none of it.
    ///
    /// Gated on `isTransitioning`, not `isCovered`: the session opens a few milliseconds before the cover
    /// is up and those first ticks are inert in the reducer, so starting early buys the display link its
    /// spin-up time and the first covered frame lands on the next refresh.
    private func syncClock() {
        guard let clock else { return }
        let wanted = state.motion.isTransitioning
        guard wanted != clockRunning else { return }
        clockRunning = wanted                   // set first: a synchronous tick from `start` re-enters
        if wanted { clock.start(sink: sink) } else { clock.stop() }
    }

    /// Arm or cancel the transition deadline: armed when the session opens, re-armed whenever it is
    /// redirected. Arming only on the `false → true` edge would cut a live transition off, since an
    /// interrupt (a second `focus` mid-scroll) extends the motion without opening a new session; a
    /// genuinely stuck transition receives no commands, so re-arming weakens nothing.
    ///
    /// A redirect is `Motion.retargetGeneration`, not the scroll's destination — a resize or a structural
    /// edit re-aims a live transition without moving the offset by a point.
    private func syncHold() {
        guard let hold else { return }
        guard state.motion.isTransitioning else {
            guard holdArmedFor != nil else { return }
            holdArmedFor = nil
            hold.cancel()
            return
        }
        let generation = state.motion.retargetGeneration
        guard holdArmedFor != generation else { return }
        holdArmedFor = generation
        hold.arm(after: state.config.holdTimeout, sink: sink)
    }
}
