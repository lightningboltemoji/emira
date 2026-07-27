import Foundation
import EmiraCore

// The pump — the one place `Engine.reduce` is called, and the only writer of core `State` in the whole
// application (IMPLEMENTATION.md §1, §6 "Runtime — the `@MainActor` pump: turn Events into `reduce`,
// hand Effects to the Executor. The one place the two planes meet"). Everything else in `EmiraShell`
// is a peripheral hanging off it: event *sources* (IPC socket, hotkeys, AX/NSWorkspace observers, the
// frame clock) push `Event`s in through `dispatch`/`sink`; the `Executor` takes `Effect`s out.
//
// It is deliberately tiny and framework-free — no AppKit, no AX, no Core Animation — so the loop that
// holds the whole system together is provable headless. Three responsibilities, and no fourth:
//
//  1. **Drain events through the reducer**, FIFO, never re-entrantly (§1 invariant 4 — see below).
//  2. **Hand each event's effects to the `Executor`**, batched, before the next event reduces.
//  3. **Gate the time sources** on whether a transition is open: motion ⇒ ticks and a deadline to
//     bound the wait, idle ⇒ silence.
//
// **Invariant 4, and why it is not optional on macOS.** `dispatch` during an active pump appends to a
// FIFO queue and returns; `reduce` never runs inside `reduce`. macOS makes accidental recursion the
// default: an AX set can complete on the calling thread, `orderFront` fires delegate notifications
// synchronously, and a fast executor may ack an effect *inside* `execute`. Without the queue, event
// B would reduce against a `State` that event A had only half-issued effects for — the classic
// "mutated mid-reconcile" bug, except invisible because it happens on one thread. With the queue, B
// still runs in the same run-loop turn (nothing is deferred to a later frame), just *after* A is
// wholly done. This costs nothing and does not limit interruption/retargeting, which happen *between*
// pumps, never inside one.

/// The `@MainActor` event pump that hosts the core.
///
/// Wiring (the daemon's job): construct with an `Executor` and the time sources, then point every event
/// source at `sink`. Nothing else in the shell holds core state.
///
/// ```swift
/// let runtime = Runtime(executor: compositing, clock: DisplayLinkDriver(screen: screen),
///                       hold: DispatchHoldTimer())
/// runtime.dispatch(.screensChanged(displays))     // bootstrap
/// socketServer.onCommand = { runtime.sink(.command($0)) }
/// ```
@MainActor
public final class Runtime {

    /// The live core state — the authoritative `World` + `Layout` + `Motion` + `Config`. Readable by
    /// the shell (an `emira debug` state dump, the menu-bar item's workspace indicator) but writable
    /// only here, by `Engine.reduce`.
    public private(set) var state: State

    /// Interprets the effects the core emits.
    private let executor: any Executor

    /// The tick source, gated on transition activity. `nil` in headless contexts that drive ticks by
    /// hand (tests, replay) — the pump then simply never starts or stops a clock.
    private let clock: (any FrameClock)?

    /// The transition deadline, gated on the same bit as the clock. `nil` in contexts with no wall
    /// clock to bound (replay, most tests), where a transition simply runs to completion.
    private let hold: (any HoldTimer)?

    /// The FIFO of events waiting to reduce. Drained by `pump`; appended to by `dispatch` at any time,
    /// including from inside `Executor.execute` (that's invariant 4's whole purpose).
    private var queue: [Event] = []

    /// Read cursor into `queue` — an index rather than `removeFirst()` so draining a burst of feedback
    /// events stays O(n) instead of O(n²). Reset with the queue at the end of each drain.
    private var head = 0

    /// Whether a drain is in progress. The single bit that makes the pump non-re-entrant.
    ///
    /// Readable inside the module so a test can assert the thing invariant 4 actually promises —
    /// that an `onStateChanged` observer is never called mid-drain — rather than assert some proxy
    /// for it. Writable only here.
    private(set) var isPumping = false

    /// Whether the frame clock is currently running, so `start`/`stop` are each called exactly once
    /// per transition rather than on every event.
    private var clockRunning = false

    /// The core's retarget generation the pending hold deadline was armed against, or `nil` when none
    /// is armed. A `UInt64?` rather than a `Bool` because it answers two questions at once: whether a
    /// deadline is outstanding, and whether it is still bounding the wait the user is actually in
    /// (see `syncHold`).
    private var holdArmedFor: UInt64?

    /// Create a pump around a fresh (or restored) state.
    ///
    /// - Parameters:
    ///   - state: the initial core state. Defaults to empty — the daemon bootstraps it by dispatching
    ///     `screensChanged` + a `windowCreated` per enumerated window, so launch is just events.
    ///   - executor: the effect interpreter (`CompositingExecutor` over `AXExecutor` in the daemon,
    ///     `MockExecutor` in tests).
    ///   - clock: the tick source to gate, or `nil` to drive ticks manually.
    ///   - hold: the transition deadline to gate, or `nil` for an unbounded transition.
    public init(state: State = State(), executor: any Executor,
                clock: (any FrameClock)? = nil, hold: (any HoldTimer)? = nil) {
        self.state = state
        self.executor = executor
        self.clock = clock
        self.hold = hold
    }

    /// The handle event sources hold to feed this pump (see `EventSink`). Stored rather than rebuilt
    /// per access so it can be handed out freely — including to an executor on every `execute` — with
    /// no allocation per effect batch.
    public private(set) lazy var sink = EventSink { [weak self] event in self?.dispatch(event) }

    /// Called once per *drain*, after the queue has emptied and the time sources are in step — never
    /// inside a reduce, and never once per event. For shell peripherals that display state rather
    /// than change it: today, the menu bar item's workspace indicator.
    ///
    /// **Once per drain, not once per event, and the difference is the whole point.** A single
    /// command cascades — capture, cover raise, a teleport per window, a landing per window — and an
    /// observer that saw each step would see states the user never does. Firing after the drain means
    /// an observer only ever sees a *settled* state, which is the same guarantee §1 invariant 4 gives
    /// `RequestRouter` for `dumpState`.
    ///
    /// It fires unconditionally rather than on a change, because `State` is large and comparing all
    /// of it at 120 Hz to save an observer a comparison of its own is the wrong trade. Observers
    /// diff their own projection; `MenuBarItem` does, and a scroll costs it nothing.
    ///
    /// An observer must not `dispatch` from here — that would drain again and re-notify. Nothing in
    /// the shell needs to; this is a display seam, and events have their own door.
    public var onStateChanged: (@MainActor (State) -> Void)?

    /// Feed one event to the core.
    ///
    /// If a pump is already running (i.e. we were called from inside `Executor.execute`, or from an
    /// event source that a `FrameClock.start` triggered synchronously), the event is **queued and this
    /// returns immediately** — it will reduce after the in-flight event's effects are fully issued,
    /// still within this run-loop turn. Otherwise it drains the queue here and now.
    public func dispatch(_ event: Event) {
        queue.append(event)
        guard !isPumping else { return }        // §1 invariant 4: never reduce inside reduce
        pump()
        // Outside the drain — so a clock whose `start` synchronously delivers a tick re-enters
        // `dispatch` cleanly (and `clockRunning` is already updated, so it can't recurse further).
        syncTimeSources()
        // Last, so an observer sees a state whose effects are issued *and* whose clock and deadline
        // already match it — i.e. exactly the state the daemon is now sitting in.
        onStateChanged?(state)
    }

    /// Drain the queue: reduce each event in turn and hand its effects to the executor before the next
    /// one reduces. New events appended mid-drain (feedback acks, an observer firing) are picked up by
    /// this same loop, so a whole cascade — command → capture → captureReady → cover raise → teleport
    /// → landings — settles in one call.
    private func pump() {
        isPumping = true
        defer { isPumping = false }
        while head < queue.count {
            let event = queue[head]
            head += 1
            let (next, effects) = Engine.reduce(state, event)
            state = next
            // Skip empty batches: an executor can then treat every call as real work (open a
            // `CATransaction`, take a lock) without guarding, and the recorded batch stream stays a
            // faithful list of the events that actually *did* something.
            if !effects.isEmpty {
                executor.execute(effects, feedback: sink)
            }
        }
        queue.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Match both time sources to the core's motion state. A transition session is open ⇒ we need
    /// frames to animate and a deadline to bound the wait; idle steady state ⇒ neither.
    private func syncTimeSources() {
        syncClock()
        syncHold()
    }

    /// Start or stop the frame clock: a transition session is open ⇒ we need ticks; idle steady state
    /// ⇒ absolutely none (IMPLEMENTATION.md §6 — the display link is the only always-on cost a window
    /// manager can accidentally pay, and we don't).
    ///
    /// Gated on `isTransitioning` rather than `isCovered` on purpose: the session opens a few
    /// milliseconds before the cover is up (captures are in flight), and those first ticks are inert in
    /// the reducer, so starting early buys the display link its spin-up time and the first *covered*
    /// frame lands on the very next refresh.
    private func syncClock() {
        guard let clock else { return }
        let wanted = state.motion.isTransitioning
        guard wanted != clockRunning else { return }
        clockRunning = wanted                   // set first: a synchronous tick from `start` re-enters
        if wanted { clock.start(sink: sink) } else { clock.stop() }
    }

    /// Arm or cancel the transition deadline (IMPLEMENTATION.md §3, `HoldTimer.swift`).
    ///
    /// **Armed when the session opens, and re-armed whenever it is redirected.** The naive gate — arm
    /// once on the `false → true` edge — bounds a *stuck* transition correctly and cuts a *live* one
    /// off: the signature interrupt (a second `focus` mid-scroll, velocity carried, §4b) extends the
    /// motion without opening a new session, so a user scrolling briskly through four columns would
    /// have the cover yanked out from under the last one. Re-arming on every redirect fixes that
    /// without weakening anything: the deadline bounds *the wait we are currently in*, and a genuinely
    /// stuck transition receives no commands, so it stops being redirected by definition.
    ///
    /// **What counts as a redirect is `Motion.retargetGeneration`, not the scroll's destination.**
    /// This keyed on `viewportOffset.target` while every transition *was* a scroll, and that reading
    /// was silently wrong the moment one wasn't: a resize re-aims a column's width and a structural
    /// edit re-aims a set of window displacements, either of which can redirect a live transition
    /// without moving the offset by a point — a swap in full view doesn't scroll at all. The second
    /// press of a keybind would then ride a deadline armed for the first. The generation counts every
    /// re-aim of every animated quantity, which is exactly the question being asked.
    ///
    /// Reading it is the pump snooping on core state, which it also does for `isTransitioning` — both
    /// are it asking the same question it exists to answer ("is there motion, and has it been
    /// redirected?") in order to point the shell's machinery at it.
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
