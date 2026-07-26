import AppKit
import QuartzCore
import EmiraCore

// The real frame clock: a `CADisplayLink` turned into `Event.tick(dt)` (PRINCIPLES.md §7 — *the core
// owns the clock; the shell is a dumb blitter*). `FrameClock.swift` explains why this is the only
// piece of the animation path that cannot be unit-tested — it needs a live `NSScreen` and a running
// app — and why it is therefore kept to two methods and no decisions.
//
// **Idle costs nothing.** The `Runtime` starts this when a transition session opens and stops it when
// the cover comes down, so a window manager sitting still delivers no ticks at all. The link is
// *paused*, never invalidated, so the next transition starts on the following refresh instead of
// paying for a fresh link.
//
// **`dt` is measured, not assumed.** ProMotion varies the refresh rate, and a busy main thread drops
// frames; a spring integrated with a hardcoded 1/60 would drift from wall-clock and settle at the
// wrong moment. We take the interval between delivered timestamps — and clamp it, because the one
// thing worse than a dropped frame is a *long* one: after a multi-second stall (a modal loop, a
// hitched app) an unclamped `dt` would advance the spring past its target in a single step, which the
// eye reads as a teleport, not a scroll.

/// `CADisplayLink` on one screen, delivering `Event.tick(dt)` to a sink while a transition is open.
///
/// `NSObject` because `NSScreen.displayLink(target:selector:)` is a target/action API; that is the
/// only reason.
@MainActor
public final class DisplayLinkDriver: NSObject, FrameClock {

    /// The longest `dt` we will ever hand the core, in seconds (~6 frames at 60 Hz). A stall longer
    /// than this advances motion by this much and no more: the animation finishes slightly late rather
    /// than jumping.
    public static let maxFrameStep: Double = 0.1

    private let screen: NSScreen
    private var link: CADisplayLink?
    private var sink: EventSink?
    /// Timestamp of the previous *delivered* tick, or `nil` at the start of a session. Reset by
    /// `start` so the first tick of a transition carries one frame, not the idle seconds since the
    /// last one (`FrameClock`'s contract).
    private var lastTimestamp: CFTimeInterval?

    /// - Parameter screen: the display whose refresh drives the animation. Single-display for now;
    ///   per-monitor strips (M6) give each overlay its own driver.
    public init(screen: NSScreen) {
        self.screen = screen
        super.init()
    }

    public func start(sink: EventSink) {
        self.sink = sink
        lastTimestamp = nil
        let link = self.link ?? makeLink()
        self.link = link
        link.isPaused = false
    }

    public func stop() {
        link?.isPaused = true
        sink = nil
    }

    private func makeLink() -> CADisplayLink {
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        // `.common` so ticks keep arriving during event tracking — a trackpad gesture (M7) drives the
        // same session, and a scroll that froze while the user's finger was down would be the one
        // moment smoothness matters most.
        link.add(to: .main, forMode: .common)
        return link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let sink else { return }          // stopped between the link firing and this call
        let now = link.timestamp
        let dt = lastTimestamp.map { now - $0 } ?? link.duration
        lastTimestamp = now
        sink(.tick(dt: min(max(dt, 0), Self.maxFrameStep)))
    }
}
