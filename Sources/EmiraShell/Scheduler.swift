import Dispatch
import Foundation

// The shell's third time source: "try that again in a moment", the only answer to the macOS races that
// have no notification — an app not ready to be observed yet, a window the window server has not listed
// yet (`WorldWatcher`). A protocol rather than `asyncAfter` at the use site so the retry policy is
// testable without a real delay.

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
