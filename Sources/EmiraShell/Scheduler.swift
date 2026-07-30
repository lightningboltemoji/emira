import Dispatch
import Foundation

// The shell's third and fourth time sources, both answering a macOS that will not send a notification.
//
//  · `DelayScheduler` — "try that again in a moment": an app not ready to be observed yet, a window the
//    window server has not listed yet (`WorldWatcher`). Bounded, and each retry is a race being waited
//    out.
//  · `Heartbeat` — "ask again from scratch, forever": the standing check that the desktop still looks
//    the way `World` says it does. A retry ends; this does not, which is the whole point of separating
//    them — a heartbeat drained by a test's "run everything pending" loop would never terminate.
//
// Protocols rather than `asyncAfter` at the use site so both policies are testable without real delays.

/// Runs work on the main actor after a delay.
///
/// Implementers: every scheduled item runs at most once, in schedule order when delays are equal, and on
/// the main actor. There is no cancellation — a retry that has become pointless discovers that when it
/// runs.
@MainActor
public protocol DelayScheduler: AnyObject {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void)
}

/// The real one.
@MainActor
public final class DispatchScheduler: DelayScheduler {

    public init() {}

    public func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            // The main queue *is* the main actor's executor, so this asserts something already true
            // rather than hopping.
            MainActor.assumeIsolated { work() }
        }
    }
}

/// A repeating tick on the main actor.
///
/// Implementers: `start` *replaces* any tick already running and `stop` is idempotent. A tick after
/// `stop` is a bug, not a tolerable late arrival — teardown has decided the desktop is no longer ours.
@MainActor
public protocol Heartbeat: AnyObject {
    func start(every seconds: TimeInterval, _ tick: @escaping @MainActor () -> Void)
    func stop()
}

/// The real one. A `DispatchSourceTimer` rather than a self-rescheduling `asyncAfter` chain: the
/// cadence is then the timer's business rather than something every tick has to remember to continue,
/// and cancellation is synchronous and total.
@MainActor
public final class DispatchHeartbeat: Heartbeat {

    private var timer: (any DispatchSourceTimer)?

    public init() {}

    public func start(every seconds: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Leeway proportional to the period: waking the CPU on time buys nothing when the thing being
        // checked changes on a human timescale, and a fixed second of slack would swallow a sub-second
        // poll whole.
        timer.schedule(deadline: .now() + seconds, repeating: seconds,
                       leeway: .milliseconds(Int(seconds * 1000 / 3)))
        timer.setEventHandler {
            // The main queue *is* the main actor's executor: an assertion, not a hop.
            MainActor.assumeIsolated { tick() }
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }
}
