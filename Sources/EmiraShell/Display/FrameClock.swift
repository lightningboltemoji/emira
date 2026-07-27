import Foundation
import EmiraCore

// Only the protocol, so the `Runtime` can gate the clock without importing AppKit.

/// A source of `Event.tick(dt)` at display refresh rate. Implemented for real by `DisplayLinkDriver`
/// and by test doubles that step time by hand.
///
/// Implementers: `start` and `stop` should be idempotent. `dt` is the interval since the previous
/// *delivered* tick, in seconds, and `start` resets the baseline — a first tick carrying the idle
/// seconds since the last session would teleport every spring to its target in one frame.
@MainActor
public protocol FrameClock: AnyObject {
    /// Begin delivering ticks to `sink`. Called when a transition session opens.
    func start(sink: EventSink)

    /// Stop delivering ticks. Pause the display link rather than tearing it down, so the next
    /// transition starts without re-acquiring it.
    func stop()
}
