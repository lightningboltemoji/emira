import Foundation
import EmiraCore

// The trackpad subsystem's policy half — what counts as a swipe, how far the strip has travelled, and
// how fast the hand was going when it let go. The framework-bound half is behind `GestureTapper` in
// `GestureTap.swift`.
//
// **The precedent is the hotkey subsystem, not the observation source.** `WorldObservation` is the seam
// that makes `World` live and every case of it is a fact about the desktop; a gesture is not a fact
// about the desktop, it is user intent — which is what `HotkeyManager` handles. Same shape, same split,
// and the same consequence: what reaches the core is an `Event`, so this is an event *source*, not an
// effect, and the reducer never hears about a contact.
//
// Everything here is drivable from an array of synthesized `TouchSample`s with no window server and no
// TCC grant, which is the point — this is where the arithmetic is.

/// Turns contact frames into the three trackpad events, and nothing else into anything.
@MainActor
public final class GestureRecognizer {

    /// Normalized pad units the mean contact must travel before an episode is called a swipe. Low, and
    /// safely so: a false positive is a cover over an unmoved desktop, which is a photograph of exactly
    /// what is behind it, while a false negative is dead strip at the head of every gesture.
    public static let commitThreshold = 0.01

    /// How much straighter than the other axis that travel must be, so a diagonal commits to neither.
    public static let dominance = 1.5

    /// Seconds of silence with an episode open before the fingers are presumed gone. Longer than any
    /// observed inter-sample gap (~8 ms) by more than an order of magnitude, which is the only property
    /// it needs.
    public static let watchdogSilence = 0.2

    /// How many trailing samples the lift's velocity is measured over. The final pair alone is noise.
    public static let velocityWindow = 5

    /// Where one episode has got to. An episode opens on three contacts and closes when they leave.
    private enum Phase {
        /// Three fingers down, nothing dispatched yet.
        case watching
        /// Committed horizontal: the core has a session open and drains are flowing to it.
        case scrolling
        /// Committed vertical. **Latched dead**, so a diagonal that starts upward cannot become a
        /// scroll halfway through — the vertical term in this model is a sign rather than a distance,
        /// so there is nothing for a finger to be 1:1 with and a workspace switch is a different verb.
        case dead
    }

    private struct Episode {
        var phase: Phase = .watching
        /// Where the fingers went down — what the commit test measures against.
        let origin: Point
        var latest: Point
        /// Travel the frame has not been handed yet, in normalized units.
        var pending: Double = 0
        /// The trailing `(x, time)` pairs the lift's velocity is smoothed over.
        var trail: [(x: Double, time: Double)] = []
    }

    private let tapper: any GestureTapper
    private let scheduler: any DelayScheduler
    private let sink: EventSink

    private var episode: Episode?
    /// Monotonic count of folded samples. The watchdog compares two readings of it rather than two
    /// readings of a clock, which is what keeps this testable with no time source at all.
    private var samples: UInt64 = 0
    private var installed = false

    public init(tapper: any GestureTapper, scheduler: any DelayScheduler, sink: EventSink) {
        self.tapper = tapper
        self.scheduler = scheduler
        self.sink = sink
    }

    // Installation (the standing idle cost, paid only for a setting somebody turned on)

    /// Watch — or stop watching — the pad, and answer whether it is now observed. Driven by
    /// `applyShellConfig`, exactly as `AXObservationSource.observePointerMotion` is and for the
    /// identical reason: **the tap fires for any finger at all**, including one merely moving the
    /// cursor, so it is not installed for a setting nobody turned on.
    ///
    /// The answer is also the capability `mouse.trackpad-scroll` is clamped against, which is why this
    /// is callable ahead of the config being finished.
    @discardableResult
    public func observe(_ observed: Bool) -> Bool {
        guard observed != installed else { return installed }
        guard observed else {
            abandon()                       // no more samples ⇒ no lift report is coming
            tapper.remove()
            installed = false
            return false
        }
        installed = tapper.install { [weak self] sample in self?.fold(sample) }
        return installed
    }

    /// Release the tap. A live tap outliving the daemon is a leak nothing else surfaces.
    public func stop() {
        observe(false)
    }

    // Recognition

    /// Fold one contact frame.
    public func fold(_ sample: TouchSample) {
        samples &+= 1
        // Fewer or more than three fingers is not this gesture — and it is also how every episode ends,
        // since the pad reports the fingers lifting one at a time (3 → 2 → 0).
        guard sample.contacts.count == 3, let centre = sample.centre else {
            return end(at: sample.time)
        }
        guard var live = episode else {
            episode = Episode(origin: centre, latest: centre,
                              trail: [(centre.x, sample.time)])
            armWatchdog()
            return
        }
        defer { episode = live }

        let step = centre.x - live.latest.x
        live.latest = centre
        live.trail.append((centre.x, sample.time))
        if live.trail.count > Self.velocityWindow { live.trail.removeFirst() }
        guard live.phase != .dead else { return }
        // Accumulated **from the origin**, not from the commit: the first drain carries the whole
        // travel including the pre-threshold part, or the strip lags the hand by exactly the threshold
        // for the rest of the gesture.
        live.pending += step
        guard live.phase == .watching else { return }

        let dx = centre.x - live.origin.x
        let dy = centre.y - live.origin.y
        // Horizontal first: this is a scrollable tiler, and the strip runs left-right. `dy` is read as
        // a magnitude only, which is why the pad's bottom-left origin needs no flip here.
        if abs(dx) > Self.commitThreshold, abs(dx) > abs(dy) * Self.dominance {
            live.phase = .scrolling
            sink(.trackpadScrollBegan)
        } else if abs(dy) > Self.commitThreshold, abs(dy) > abs(dx) * Self.dominance {
            live.phase = .dead
        }
    }

    /// Hand the frame whatever the fingers have covered since the last one — the one caller is the
    /// display link's `onFrame`, immediately ahead of that frame's tick.
    ///
    /// **At most one event, and none at all if the finger did not move.** The rule this keeps is that
    /// nothing enters the pump at the refresh rate that is not a tick; riding the frame instead of the
    /// pad is what buys the exemption, and an event still has to earn its place in the replay log.
    public func drain() {
        guard var live = episode, live.phase == .scrolling, live.pending != 0 else { return }
        let travel = live.pending
        live.pending = 0
        episode = live
        sink(.trackpadScrolled(by: travel))
    }

    /// The fingers left. Dispatches the residue the last frame did not see, then the lift.
    ///
    /// The residual `trackpadScrolled` is off the frame boundary on purpose and costs nothing the rule
    /// above forbids: it is one event at an edge, not a stream, and without it the projection would
    /// start from where the strip was a frame ago rather than from where the fingers actually left it.
    private func end(at time: Double) {
        guard let live = episode else { return }
        episode = nil
        guard live.phase == .scrolling else { return }
        if live.pending != 0 { sink(.trackpadScrolled(by: live.pending)) }
        sink(.trackpadScrollEnded(velocity: velocity(of: live, at: time)))
    }

    /// Normalized units per second at the lift, over the trailing window rather than the final pair,
    /// which is noise.
    ///
    /// Then decayed by how **stale** the last sample is, so a hand that came to rest before letting go
    /// reads as the stop it was rather than as the flick it stopped being. Full decay at the watchdog's
    /// own window, which is the longest a live gesture is ever quiet for — so the ordinary one-frame gap
    /// between the last contact frame and the lift costs a few percent, and a third of a second of
    /// stillness costs the whole throw.
    private func velocity(of live: Episode, at time: Double) -> Double {
        guard let first = live.trail.first, let last = live.trail.last,
              last.time > first.time else { return 0 }
        let rate = (last.x - first.x) / (last.time - first.time)
        let staleness = min(max((time - last.time) / Self.watchdogSilence, 0), 1)
        return rate * (1 - staleness)
    }

    // The watchdog (no state without an exit)

    /// Re-armed rather than cancelled, because `DelayScheduler` has no cancellation and a re-arm per
    /// sample would queue 120 closures a second. One timer per silence window while an episode is open
    /// is the whole cost.
    private func armWatchdog() {
        let seen = samples
        scheduler.schedule(after: Self.watchdogSilence) { [weak self] in
            self?.checkSilence(since: seen)
        }
    }

    private func checkSilence(since seen: UInt64) {
        guard episode != nil else { return }
        guard samples == seen else { return armWatchdog() }   // the pad is alive; look again
        abandon()
    }

    /// End an open episode with nothing to say about it. The window server *does* disable a tap whose
    /// callback overruns, and the samples that would have reported the lift are the ones it dropped —
    /// which would leave a latch set, a cover up and a hold deadline suspended, forever. Velocity zero
    /// deliberately: nothing here saw a lift, so there is no momentum to claim.
    private func abandon() {
        guard let live = episode else { return }
        episode = nil
        guard live.phase == .scrolling else { return }
        sink(.trackpadScrollEnded(velocity: 0))
    }
}
