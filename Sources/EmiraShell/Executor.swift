import Foundation
import EmiraCore

// The shell's half of the §1 diagram — the seam where the pure core's `Effect`s become real macOS
// work and where their results come back as `Event`s. Two small types carry the whole contract:
//
//  · **`EventSink`** — the reply address *into* the pump. Every event source in the shell (an AX
//    observer, the display link, the socket server, an executor's ack) holds one of these instead of
//    a reference to the `Runtime`. It is `Sendable` but `@MainActor` to *call*, which is exactly the
//    boundary discipline `PRINCIPLES.md` §7 asks for: an AX setter completing on its serial per-app
//    queue may carry the sink across threads, but the event only ever enters the pump on the main
//    actor.
//  · **`Executor`** — the interpreter of `Effect`s. `EmiraCore` names AX / Core Animation /
//    ScreenCaptureKit only through the `Effect` enum; the executor is the one place those names turn
//    into calls. Swapping in a `MockExecutor` is therefore the whole of "test the brain with no macOS
//    in sight" (IMPLEMENTATION.md §8).
//
// **Why effects arrive batched.** `execute` takes *one event's worth* of effects, not one effect,
// because a tick's `setLayerFrame` blits must land in a single `CATransaction` (actions disabled) to
// hit the screen as one frame — the batch boundary *is* the frame boundary. It also mirrors the
// reducer's shape (`reduce` returns `[Effect]`) and keeps invariant 4 legible: every effect of event
// A is issued before event B reduces (`Runtime.swift`).
//
// **Effects are fire-and-forget; results are events (§1 invariant 3).** `execute` returns `Void` and
// returns *immediately* — a live AX set hands off to a serial per-app queue and answers later with
// `Event.axLanded`/`.axFailed` through the sink; a capture answers with `Event.captureReady`. Nothing
// here is `async`, so nothing can suspend the pump.

/// The reply address into the `Runtime`'s event pump — a one-way, retain-cycle-free handle that any
/// shell subsystem can hold to feed `Event`s to the core.
///
/// It is deliberately a *value* wrapping a closure rather than a reference to the `Runtime`: the
/// Runtime hands its sink out freely (to executors, observers, the clock) without anyone owning it,
/// and the closure's `[weak self]` capture means a torn-down Runtime simply stops accepting events
/// instead of being kept alive by its own subsystems.
///
/// `Sendable` + `@MainActor`-to-call is the AX boundary in one type (`PRINCIPLES.md` §7): the sink may
/// travel to a serial per-app queue with an in-flight AX set, but delivering the resulting event hops
/// back to the main actor, where all core state lives.
public struct EventSink: Sendable {
    private let send: @MainActor @Sendable (Event) -> Void

    /// Wrap a delivery closure. The `Runtime` builds the canonical one (`Runtime.sink`); tests build
    /// recording ones.
    public init(_ send: @escaping @MainActor @Sendable (Event) -> Void) {
        self.send = send
    }

    /// Feed one event to the pump. Callable as `sink(.axLanded(id))`.
    ///
    /// **Never re-entrant:** if this is called *during* a pump (an executor acking synchronously), the
    /// event is queued and reduced after the current event's effects are fully issued — see
    /// `Runtime.dispatch`.
    @MainActor public func callAsFunction(_ event: Event) { send(event) }
}

/// Interprets the core's `Effect`s against the real system. The single abstraction that keeps the
/// `Runtime` testable: in the daemon a `CompositingExecutor` splits the batch across the two planes —
/// `CoverSurface` for Core Animation, `AXExecutor` for the truth plane — while `MockExecutor` records.
///
/// `@MainActor` because the presentation plane is main-thread by construction (Core Animation) and the
/// core state is pinned there; an implementation that needs off-thread work (AX Mach IPC) dispatches
/// it to its own serial queue and marshals the result back through `feedback`.
@MainActor
public protocol Executor: AnyObject {
    /// Execute one event's worth of effects, **in order**, and return without blocking.
    ///
    /// - Parameters:
    ///   - effects: the effects one `Engine.reduce` produced. Never empty — the `Runtime` skips empty
    ///     batches so an implementation can treat every call as "there is a frame's worth of work
    ///     here" (e.g. open a `CATransaction`) without a guard.
    ///   - feedback: where to send the results (`axLanded`, `captureReady`, `crossfadeDone`, …), now
    ///     or later, from any thread (hopping to the main actor to deliver).
    func execute(_ effects: [Effect], feedback: EventSink)
}

/// The no-macOS executor (IMPLEMENTATION.md §5 "Live + Mock impls", §8). Records every batch it is
/// handed, and — in `.simulate` mode — plays the part of a *perfectly responsive* system by acking
/// each effect immediately.
///
/// Two modes, two jobs:
///
///  · **`.record`** — pure observation. Assert the exact `Effect` stream a scripted event sequence
///    produced, with nothing feeding back. This is the `MockExecutor` of §8.
///  · **`.simulate`** — observation *plus* the acks that make a transition actually complete: a
///    `setFrame`/`park` lands instantly, a `capture` returns instantly, an `endTransition` cross-fades
///    instantly, and a `focus` echoes back as the `focusChanged` the real AX observer would report.
///    This is the M2 stand-in for the truth plane: it lets the full cover lifecycle run end-to-end
///    against fake pixels, and it is the harshest possible test of invariant 4 — every ack arrives
///    *synchronously, inside* `execute`.
///
/// Real macOS is of course slower and lossier; that asymmetry is the point of `axFailed` and the
/// hold-timeout, which are exercised by the core's own scenario tests.
@MainActor
public final class MockExecutor: Executor {
    /// What the mock does beyond recording.
    public enum Mode: Sendable, Equatable {
        /// Record only — no feedback events at all.
        case record
        /// Record, then immediately ack every effect that has a reply, as an infinitely fast system.
        case simulate
    }

    /// Whether this mock feeds results back.
    public let mode: Mode

    /// Every batch handed to `execute`, in order — one entry per reduced event that produced effects.
    /// Batch boundaries are worth keeping: they're the frame boundaries (see the file header) and they
    /// make the pump's ordering guarantees assertable.
    public private(set) var batches: [[Effect]] = []

    public init(mode: Mode = .record) {
        self.mode = mode
    }

    /// Every recorded effect, flattened in execution order — the convenient form for "was this
    /// emitted?" assertions.
    public var effects: [Effect] { batches.flatMap { $0 } }

    /// Forget everything recorded so far (keeps the mode). Useful to isolate the effects of one phase
    /// of a longer scenario.
    public func reset() { batches.removeAll() }

    public func execute(_ effects: [Effect], feedback: EventSink) {
        batches.append(effects)
        guard mode == .simulate else { return }
        for effect in effects { ack(effect, to: feedback) }
    }

    /// The reply a perfectly responsive system would give for one effect.
    private func ack(_ effect: Effect, to feedback: EventSink) {
        switch effect {
        // Truth plane: the real window arrived at its AX target.
        case .setFrame(let id, _), .park(let id, _):
            feedback(.axLanded(id))

        // Capture: the still is in the (imaginary) image cache.
        case .capture(let id):
            feedback(.captureReady(id))

        // Focus: the real shell moves focus via AX, and the AX/NSWorkspace observers report it back —
        // so the *echo* is part of the truth, and the core is designed to absorb it (a reveal of an
        // already-revealed window is a no-op). Simulating it keeps the mock honest about the event
        // traffic a real focus command generates.
        case .focus(let id):
            feedback(.focusChanged(id))

        // The cross-fade finished and the cover is down.
        case .endTransition:
            feedback(.crossfadeDone)

        // No reply by contract: raising the cover is synchronous, per-frame layer blits are writes the
        // core already knows it made (it owns the clock), and a raise has no observable completion.
        //
        // `reloadConfig` is in this list for a different reason: it *does* have a reply
        // (`configChanged`), but only a real file can say what it contains. A mock that invented one
        // would be asserting a config nobody wrote — so the reload is recorded and left unanswered,
        // which is also exactly what a daemon whose config file failed to parse does.
        case .beginTransition, .extendCover, .elevateLayer, .setLayerFrame, .raise, .reloadConfig:
            break
        }
    }
}
