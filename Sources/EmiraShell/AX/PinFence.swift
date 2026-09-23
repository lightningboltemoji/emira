import Foundation
import EmiraCore

// *Is the pinned window on top yet?* — the fence between a focus write and the teleport it entitles.
//
// A cover with a band cut out of it hides nothing in that band, so a real window teleporting to or from
// there is drawn over the pin unless the pin is above it. emira may not re-level a foreign window
// (`PRINCIPLES.md` §5), so activating its app is the whole of the lever — and `Event.focusChanged` says
// the app moved its focus, not that the raise reached the glass. The two are far enough apart to see,
// which is the same gap `HoistPanels` fences against and the same question `StackProbe` already asks.
//
// So the answer is the window server's, asked repeatedly until it comes back clear. Off the main thread
// for `StackProbe`'s reason: what is being waited out is another app's activation, and its length is not
// ours to block for.
//
// **The question is an order, asked once the pin's app has been activated.** The windows the gate
// protects are mostly still on their way into the band, so they are named rather than looked for there;
// and an app's windows rise on its own schedule after `activate()` returns, so nothing read before it
// is an answer.

/// Asks the window server, until it agrees, that a pin is above what it must be above.
@MainActor
public final class PinFence {

    /// The share of `[animation] hold-timeout` the fence may wait before it answers anyway — **a delay,
    /// not a veto**. The rest is the teleport's and its landings': a session that times out closes over
    /// reals still in flight, which is worse than a pin briefly under a window.
    public static let share = 0.5

    /// How long between askings. Roughly a refresh: the answer changes when the window server re-stacks,
    /// which it does on its own schedule, and asking faster only spends `CGWindowListCopyWindowInfo`
    /// calls on a queue that is already serialized.
    public static let interval: TimeInterval = 0.016

    private let probe: any StackProbe
    private let scheduler: any DelayScheduler
    private let interval: TimeInterval

    /// The transition's deadline, which the fence's is cut from. Both are armed as a session opens or
    /// retargets, so they count from the same moment; read per request, so a reload applies to the next.
    public var holdTimeout: TimeInterval

    private struct Request {
        let generation: Int
        let over: Set<WindowId>
        let band: Rect
        let report: @MainActor () -> Void
        var isActivated = false
    }

    /// The request outstanding per pin. **One per window, the newest**: `Event.focusConfirmed` names
    /// only the window, so a report from a request the core has since asked again would answer the
    /// new question with the old one's reading.
    private var requests: [WindowId: Request] = [:]
    private var generation = 0

    public init(probe: any StackProbe, scheduler: any DelayScheduler = DispatchScheduler(),
                holdTimeout: TimeInterval = Config().holdTimeout,
                interval: TimeInterval = PinFence.interval) {
        self.probe = probe
        self.scheduler = scheduler
        self.holdTimeout = holdTimeout
        self.interval = interval
    }

    /// Report once `window` is stacked above each of `over` and anything foreign over `band`, or once its
    /// `share` of `holdTimeout` runs out — counted from here, so an activation that is superseded or
    /// refused is waited out. Nothing is asked until `activated(window)`; a newer request replaces this.
    public func confirm(_ window: WindowId, over: Set<WindowId>, within band: Rect,
                        then report: @escaping @MainActor () -> Void) {
        generation &+= 1
        let mine = generation
        requests[window] = Request(generation: mine, over: over, band: band, report: report)
        scheduler.schedule(after: holdTimeout * Self.share) { [weak self] in
            guard let self, requests[window]?.generation == mine else { return }
            finish(window)
        }
    }

    /// The pin's app has been activated, so what the window server shows from here on is an answer.
    /// Before it, a clear reading is only the order the desktop had before anything was asked.
    public func activated(_ window: WindowId) {
        guard var request = requests[window], !request.isActivated else { return }
        request.isActivated = true
        requests[window] = request
        ask(window, generation: request.generation)
    }

    private func ask(_ window: WindowId, generation mine: Int) {
        guard let request = requests[window], request.generation == mine else { return }
        probe.isCovered(window, within: request.band, orBy: request.over) { [weak self] covered in
            guard let self, requests[window]?.generation == mine else { return }
            guard covered else { return finish(window) }
            scheduler.schedule(after: interval) { [weak self] in
                self?.ask(window, generation: mine)
            }
        }
    }

    private func finish(_ window: WindowId) {
        requests.removeValue(forKey: window)?.report()
    }
}
