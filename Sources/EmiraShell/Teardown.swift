import Foundation
import EmiraCore

// Stopping emira without stranding the desktop: off-viewport columns and other workspaces sit at a 1 pt
// nub in the corner of the working area, which is fine while the daemon runs and terrible the moment it
// doesn't. Teardown places every managed window into the quit cascade before the process exits.
//
// What this type owns is the waiting. AX writes cross onto a per-app serial queue and answer later, so
// `exit(0)` on the next line would leave most windows at their nubs — and the wait must be bounded, so a
// hung app delays a quit rather than preventing it.
//
// The caller stops the world first: a live `WorldWatcher` would turn the cascade's own `AXWindowMoved`
// observations back into `windowFrameChanged` and fight it to the deadline.

/// Places every managed window into the quit cascade and calls back once they have landed — or once the
/// deadline says stop waiting.
///
/// One-shot: `run` does nothing on a second call, so an impatient user's second Ctrl-C is a no-op rather
/// than a second cascade.
@MainActor
public final class Teardown {

    /// How the cascade ended, for the log line the daemon prints on its way out.
    public struct Report: Sendable, Equatable {
        /// How many windows were placed.
        public let windows: Int
        /// How many of those never answered before the deadline. `0` on the ordinary path.
        public let unlanded: Int
        /// Whether the deadline is what ended the wait.
        public var timedOut: Bool { unlanded > 0 }

        public init(windows: Int, unlanded: Int) {
            self.windows = windows
            self.unlanded = unlanded
        }
    }

    /// How long to wait for the AX sets to land before exiting anyway. Two orders of magnitude over the
    /// ~14 ms a real desktop takes; it bounds a quit that appears to hang.
    public static let defaultDeadline: TimeInterval = 1.5

    private let executor: any Executor
    private let scheduler: any DelayScheduler
    private let deadline: TimeInterval

    /// Windows whose set is still out. Emptied by landings; whatever is left when the deadline fires is
    /// what `Report.unlanded` counts.
    private var pending: Set<WindowId> = []
    private var placed = 0
    private var started = false
    private var finished = false
    private var completion: (@MainActor (Report) -> Void)?

    /// - Parameters:
    ///   - executor: the *truth-plane* executor, not the compositing one — a cascade emits nothing but
    ///     `setFrame`/`raise`/`focus`, and the cover is about to stop existing.
    ///   - scheduler: the deadline's clock — a seam, so the timeout path is a test rather than a wait.
    public init(executor: any Executor, scheduler: any DelayScheduler,
                deadline: TimeInterval = defaultDeadline) {
        self.executor = executor
        self.scheduler = scheduler
        self.deadline = deadline
    }

    /// Cascade `state`'s managed windows, then call `finish` exactly once — when every window has
    /// answered, or when the deadline runs out, whichever comes first.
    ///
    /// A state with nothing to place finishes immediately and synchronously — making the empty case wait
    /// on a timer would be the one way this could hang.
    public func run(placing state: State, then finish: @escaping @MainActor (Report) -> Void) {
        guard !started else { return }
        started = true
        completion = finish

        let effects = state.cascadeEffects()
        pending = Set(effects.compactMap { effect in
            if case .setFrame(let id, _) = effect { return id } else { return nil }
        })
        placed = pending.count
        guard placed > 0 else { return complete() }

        // Armed *before* the effects go out, so a synchronous executor finds the deadline accounted for;
        // `complete`'s guard makes the later firing a no-op.
        scheduler.schedule(after: deadline) { [weak self] in self?.complete() }
        executor.execute(effects, feedback: EventSink { [weak self] event in self?.absorb(event) })
    }

    /// One window answered. `axFailed` counts as an answer — the app said no, and waiting out the
    /// deadline for it would delay the quit to learn nothing.
    private func absorb(_ event: Event) {
        switch event {
        case .axLanded(let id), .axFailed(let id):
            pending.remove(id)
        default:
            // Everything else a placement can produce is truth about a strip being dismantled.
            return
        }
        if pending.isEmpty { complete() }
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        let finish = completion
        completion = nil
        finish?(Report(windows: placed, unlanded: pending.count))
    }
}
