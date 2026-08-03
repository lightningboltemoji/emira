import AppKit
import QuartzCore
import EmiraCore

// A `CADisplayLink` turned into `Event.tick(dt)`, running only while a transition is open. The link
// is *paused*, never invalidated, so the next transition starts on the following refresh.
//
// `dt` is measured, not assumed — ProMotion varies the refresh rate and a busy main thread drops
// frames — and clamped, or a multi-second stall would advance the spring past its target in one step.

/// `CADisplayLink` on one screen, delivering `Event.tick(dt)` while a transition is open. `NSObject`
/// only because `NSScreen.displayLink(target:selector:)` is a target/action API.
@MainActor
public final class DisplayLinkDriver: NSObject, FrameClock {

    /// The longest `dt` we will ever hand the core, in seconds (~6 frames at 60 Hz). A longer stall
    /// advances motion by this much and no more, so the animation finishes late rather than jumping.
    public static let maxFrameStep: Double = 0.1

    private var screen: NSScreen
    private var link: CADisplayLink?
    private var sink: EventSink?
    /// Timestamp of the previous *delivered* tick, `nil` at the start of a session — so the first tick
    /// of a transition carries one frame, not the idle seconds since the last one.
    private var lastTimestamp: CFTimeInterval?

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

    /// Re-home the clock on another screen — hot-plug, where the fastest display attached can change or
    /// leave. The link is **invalidated** rather than paused: it belongs to the old screen, and one for
    /// a display that has gone never fires again. A clock that was running resumes on the new screen in
    /// the same call, so a transition in flight loses at most a frame.
    ///
    /// Unconditional, because AppKit hands out fresh `NSScreen` objects on every reconfiguration: there
    /// is no identity here to compare against, and rebuilding a link is cheap.
    public func retarget(to screen: NSScreen) {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        self.screen = screen
        guard sink != nil else { return }        // not running; the next `start` builds it
        let link = makeLink()
        self.link = link
        link.isPaused = false
    }

    private func makeLink() -> CADisplayLink {
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        // `.common` so ticks keep arriving during event tracking, when a scroll must not freeze.
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
