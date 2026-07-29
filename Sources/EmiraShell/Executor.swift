import Foundation
import EmiraCore

// The seam where the pure core's `Effect`s become real macOS work and their results come back as
// `Event`s: `EventSink` is the reply address into the pump, `Executor` the interpreter of effects.
//
// `execute` takes one *event's* worth of effects, not one effect, because a tick's `setLayerFrame` blits
// must land in a single `CATransaction` (actions disabled) to hit the screen as one frame — the batch
// boundary *is* the frame boundary. It returns `Void`, immediately: a live AX set hands off to a serial
// per-app queue and answers later with `axLanded`/`axFailed` through the sink. Nothing here is `async`,
// so nothing can suspend the pump.

/// The reply address into the `Runtime`'s event pump — a one-way, retain-cycle-free handle any shell
/// subsystem can hold to feed `Event`s to the core.
///
/// A value wrapping a closure rather than a reference to the `Runtime`, so a torn-down Runtime stops
/// accepting events instead of being kept alive by its own subsystems. `Sendable` plus
/// `@MainActor`-to-call is the AX boundary in one type: the sink may travel to a serial per-app queue
/// with an in-flight AX set, but delivering the event hops back to the main actor.
public struct EventSink: Sendable {
    private let send: @MainActor @Sendable (Event) -> Void

    /// Wrap a delivery closure. The `Runtime` builds the canonical one; tests build recording ones.
    public init(_ send: @escaping @MainActor @Sendable (Event) -> Void) {
        self.send = send
    }

    /// Feed one event to the pump. Callable as `sink(.axLanded(id))`. Never re-entrant: called during a
    /// pump (an executor acking synchronously), the event queues and reduces afterwards.
    @MainActor public func callAsFunction(_ event: Event) { send(event) }
}

/// Interprets the core's `Effect`s against the real system. In the daemon a `CompositingExecutor` splits
/// the batch across the two planes — `CoverSurface` for Core Animation, `AXExecutor` for the truth plane.
///
/// `@MainActor` because the presentation plane is main-thread by construction and core state is pinned
/// there; an implementation needing off-thread work dispatches to its own serial queue and marshals the
/// result back through `feedback`.
@MainActor
public protocol Executor: AnyObject {
    /// Execute one event's worth of effects, *in order*, and return without blocking.
    ///
    /// - Parameters:
    ///   - effects: the effects one `Engine.reduce` produced. Never empty — the `Runtime` skips empty
    ///     batches so an implementation can treat every call as real work without a guard.
    ///   - feedback: where to send the results, now or later, from any thread (hopping to the main actor
    ///     to deliver).
    func execute(_ effects: [Effect], feedback: EventSink)
}

/// The no-macOS executor: records every batch it is handed and, in `.simulate` mode, acks each effect
/// immediately as an infinitely responsive system would. `.simulate` is the harshest test of the pump's
/// non-re-entrancy, since every ack arrives synchronously *inside* `execute`.
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
    public private(set) var batches: [[Effect]] = []

    public init(mode: Mode = .record) {
        self.mode = mode
    }

    /// Every recorded effect, flattened in execution order.
    public var effects: [Effect] { batches.flatMap { $0 } }

    /// Forget everything recorded so far (keeps the mode).
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
        case .capture(let id, _):
            feedback(.captureReady(id))

        // The real shell moves focus via AX and the observers echo it back, so the core absorbs its own
        // echo (a reveal of an already-revealed window is a no-op).
        case .focus(let id):
            feedback(.focusChanged(id))

        // The cross-fade finished and the cover is down.
        case .endTransition:
            feedback(.crossfadeDone)

        // No reply by contract: raising the cover is synchronous, layer blits are writes the core already
        // knows it made, and a raise has no observable completion. `closeWindow` is unacked for a
        // different reason — a real app may refuse, so simulating a destroy here would be inventing the
        // one fact only the app can supply. `exec` for a third: a child process is not a desktop fact,
        // and this being a *record* is what keeps a replayed session log from spawning anything.
        case .beginTransition, .extendCover, .elevateLayer, .setLayerFrame, .refreshLayer, .raise,
             .closeWindow, .exec:
            break
        }
    }
}
