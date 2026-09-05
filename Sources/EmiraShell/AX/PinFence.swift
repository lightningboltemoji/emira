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

/// Asks the window server, until it agrees, that nothing foreign sits over a pin's band.
@MainActor
public final class PinFence {

    /// How long the fence goes on asking before it answers anyway. **A delay, not a veto**: a cover
    /// held open on an activation that never lands would be worse than one frame of a window drawn over
    /// the pin, and `[animation] hold-timeout` is what bounds the transition itself. Comfortably inside
    /// it, so the fence is never the thing that trips the deadline.
    public static let grace: TimeInterval = 0.4

    /// How long between askings. Roughly a refresh: the answer changes when the window server re-stacks,
    /// which it does on its own schedule, and asking faster only spends `CGWindowListCopyWindowInfo`
    /// calls on a queue that is already serialized.
    public static let interval: TimeInterval = 0.016

    private let probe: any StackProbe
    private let scheduler: any DelayScheduler
    private let grace: TimeInterval
    private let interval: TimeInterval

    /// The pins currently being asked about. One request per window at a time — a second asking would
    /// double the reads and answer the same thing.
    private var asking: Set<WindowId> = []

    public init(probe: any StackProbe, scheduler: any DelayScheduler = DispatchScheduler(),
                grace: TimeInterval = PinFence.grace, interval: TimeInterval = PinFence.interval) {
        self.probe = probe
        self.scheduler = scheduler
        self.grace = grace
        self.interval = interval
    }

    /// Report once `window` has nothing foreign over `band`, or once `grace` has run out. `then` runs
    /// exactly once per call, always — the reducer is counting down to a teleport on it.
    public func confirm(_ window: WindowId, over band: Rect,
                        then report: @escaping @MainActor () -> Void) {
        guard asking.insert(window).inserted else { return report() }
        ask(window, band, deadline: Date().addingTimeInterval(grace), report)
    }

    private func ask(_ window: WindowId, _ band: Rect, deadline: Date,
                     _ report: @escaping @MainActor () -> Void) {
        probe.isCovered(window, within: band) { [weak self] covered in
            guard let self else { return report() }
            guard covered, Date() < deadline else {
                asking.remove(window)
                return report()
            }
            scheduler.schedule(after: interval) { [weak self] in
                guard let self else { return report() }
                ask(window, band, deadline: deadline, report)
            }
        }
    }
}
