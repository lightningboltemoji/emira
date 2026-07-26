import Dispatch
import EmiraCore
import Foundation

// The transition's deadline — the second time source the pump gates, and the reason a hung app can no
// longer freeze the screen (IMPLEMENTATION.md §3: *"bounded — a hold-timeout (~1 s, itself just an
// event, scheduled by the shell when the transition opened)"*).
//
// **Why it lives beside `FrameClock` rather than inside the reducer.** The core owns animation *time*
// but has no wall clock — it only ever learns that time passed because an event told it so
// (PRINCIPLES.md §7). A timeout is wall clock by definition, so it is shell mechanism producing one
// more `Event`, and the two time sources end up with the same shape and the same gate: a transition is
// open ⇒ ticks and a deadline; idle ⇒ neither. `Runtime.syncTimeSources` drives both off the one bit.
//
// **What it is defending against.** Until this iteration nothing in the daemon could actually hang:
// `MockExecutor(.simulate)` acked every `setFrame` synchronously and inside `execute`. With real AX
// writes, a window's landing now depends on another process's main run loop, and `AXClient`'s messaging
// timeout only bounds *one* call — a genuinely wedged app produces a bounded `axFailed` per set, but an
// app that answers slowly, or a window that closes mid-transition and never lands at all, leaves the
// cover up over a desktop the user can no longer interact with. That is the failure this exists for,
// and the policy is §3's: reveal the truth, keep reconciling underneath. A visibly hung app beats a
// frozen screen.

/// A one-shot deadline that delivers `Event.holdTimeout`. Implemented for real by `DispatchHoldTimer`
/// and by test doubles that fire on command.
///
/// **Contract for implementers:**
///
///  · `arm` **replaces** any deadline already pending — the `Runtime` re-arms when a transition is
///    redirected mid-flight, and two live deadlines would close the second scroll early.
///  · `cancel` is idempotent and safe when nothing is armed.
///  · Deliver through the `sink` and nothing else; a fired deadline is just another event, and a late
///    one is harmless (the reducer no-ops `holdTimeout` when no session is open).
@MainActor
public protocol HoldTimer: AnyObject {
    /// Deliver `Event.holdTimeout` to `sink` in `seconds`, cancelling any deadline already pending.
    func arm(after seconds: TimeInterval, sink: EventSink)

    /// Drop the pending deadline. Called when the transition closes on its own — the common case, and
    /// the one where this timer must stay silent.
    func cancel()
}

/// The real deadline: a cancellable work item on the main queue.
///
/// `DispatchWorkItem` rather than a `Task` because cancellation here must be *synchronous and total* —
/// when a transition closes, the pump has already emitted `endTransition` and a deadline that fires
/// anyway is a second `closeTransition` against a session that no longer exists. A cancelled work item
/// simply never runs; a cancelled `Task` still has to reach its next suspension point to notice.
@MainActor
public final class DispatchHoldTimer: HoldTimer {

    private var pending: DispatchWorkItem?

    public init() {}

    public func arm(after seconds: TimeInterval, sink: EventSink) {
        cancel()
        let item = DispatchWorkItem { [weak self] in
            // The main queue *is* the main actor's executor, so this is an assertion of something
            // already true rather than a hop — the same pattern the daemon's signal sources use.
            MainActor.assumeIsolated {
                self?.pending = nil
                sink(.holdTimeout)
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
    }
}
