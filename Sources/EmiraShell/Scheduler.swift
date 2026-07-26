import Dispatch
import Foundation

// The shell's third time source, and the smallest one. `FrameClock` produces frames, `HoldTimer`
// produces a deadline; this produces "try that again in a moment", which is the only answer to a class
// of macOS races that has no notification: an app that is not ready to be observed yet, and a window
// the window server has not listed yet (`WorldWatcher`).
//
// **Why it is a protocol rather than a `DispatchQueue.main.asyncAfter` call at the use site.** Because
// the *policy* around retrying — how many times, against which apps, and when to stop — is exactly the
// kind of decision this codebase keeps testable, and a real delay makes a test either slow or flaky.
// With the seam, a test drives the retry chain by hand and asserts the bound; the untestable part is
// one line of Dispatch.

/// Runs work on the main actor after a delay.
///
/// **Contract for implementers:** every scheduled item runs at most once, in the order it was
/// scheduled when delays are equal, and on the main actor. There is no cancellation — a retry that has
/// become pointless discovers that when it runs (the watcher re-checks its own state), which is one
/// less handle to leak than a cancel token would be.
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
            // rather than hopping — the same pattern `DispatchHoldTimer` and the daemon's signal
            // sources use.
            MainActor.assumeIsolated { work() }
        }
    }
}
