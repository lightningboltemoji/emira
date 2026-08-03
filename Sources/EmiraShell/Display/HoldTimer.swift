import Dispatch
import EmiraCore
import Foundation

// The transition's deadline: the second time source the pump gates alongside `FrameClock`. An AX
// write's landing depends on another process's run loop, so an app that answers slowly — or a window
// that closes mid-transition and never lands — would otherwise leave the cover up over a desktop the
// user can no longer interact with.

/// One-shot deadlines that deliver `Event.holdTimeout`, **one per display**: a cover is one screen's,
/// and an app hanging under one must not bound the wait the other screen is in.
///
/// Implementers: `arm` *replaces* that display's pending deadline — the `Runtime` re-arms when a
/// transition is redirected mid-flight, and two live deadlines for one cover would close the second
/// scroll early. `cancel` is idempotent. A late deadline is harmless; the reducer no-ops `holdTimeout`
/// with no session open on that display.
@MainActor
public protocol HoldTimer: AnyObject {
    /// Deliver `Event.holdTimeout(monitor)` to `sink` in `seconds`, cancelling any deadline already
    /// pending **for that display**.
    func arm(after seconds: TimeInterval, on monitor: MonitorId, sink: EventSink)

    /// Drop `monitor`'s pending deadline. Called when its transition closes on its own.
    func cancel(on monitor: MonitorId)
}

/// The real deadlines: one cancellable work item per display, on the main queue. `DispatchWorkItem`
/// rather than a `Task` because cancellation must be synchronous and total — a deadline that fires
/// after the transition closed is a second `closeTransition` against a session that no longer exists,
/// and a cancelled `Task` still has to reach a suspension point to notice.
@MainActor
public final class DispatchHoldTimer: HoldTimer {

    private var pending: [MonitorId: DispatchWorkItem] = [:]

    public init() {}

    public func arm(after seconds: TimeInterval, on monitor: MonitorId, sink: EventSink) {
        cancel(on: monitor)
        let item = DispatchWorkItem { [weak self] in
            // The main queue *is* the main actor's executor: an assertion, not a hop.
            MainActor.assumeIsolated {
                self?.pending[monitor] = nil
                sink(.holdTimeout(monitor))
            }
        }
        pending[monitor] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    public func cancel(on monitor: MonitorId) {
        pending.removeValue(forKey: monitor)?.cancel()
    }
}
