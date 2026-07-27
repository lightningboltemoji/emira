import Dispatch
import EmiraCore
import Foundation

// The transition's deadline: the second time source the pump gates alongside `FrameClock`. An AX
// write's landing depends on another process's run loop, so an app that answers slowly — or a window
// that closes mid-transition and never lands — would otherwise leave the cover up over a desktop the
// user can no longer interact with.

/// A one-shot deadline that delivers `Event.holdTimeout`.
///
/// Implementers: `arm` *replaces* any pending deadline — the `Runtime` re-arms when a transition is
/// redirected mid-flight, and two live deadlines would close the second scroll early. `cancel` is
/// idempotent. A late deadline is harmless; the reducer no-ops `holdTimeout` with no session open.
@MainActor
public protocol HoldTimer: AnyObject {
    /// Deliver `Event.holdTimeout` to `sink` in `seconds`, cancelling any deadline already pending.
    func arm(after seconds: TimeInterval, sink: EventSink)

    /// Drop the pending deadline. Called when the transition closes on its own.
    func cancel()
}

/// The real deadline: a cancellable work item on the main queue. `DispatchWorkItem` rather than a
/// `Task` because cancellation must be synchronous and total — a deadline that fires after the
/// transition closed is a second `closeTransition` against a session that no longer exists, and a
/// cancelled `Task` still has to reach a suspension point to notice.
@MainActor
public final class DispatchHoldTimer: HoldTimer {

    private var pending: DispatchWorkItem?

    public init() {}

    public func arm(after seconds: TimeInterval, sink: EventSink) {
        cancel()
        let item = DispatchWorkItem { [weak self] in
            // The main queue *is* the main actor's executor: an assertion, not a hop.
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
