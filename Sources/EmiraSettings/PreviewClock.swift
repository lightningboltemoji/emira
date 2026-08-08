import AppKit
import QuartzCore

// The preview's frame clock, and the discipline the daemon already keeps: **the link runs only while
// there is something to draw.** A settled preview with a static take playing runs no display link at
// all, which is most of the time a settings window is open.
//
// The link is *paused*, never invalidated, so the next drag starts on the following refresh rather than
// paying to build one. `dt` is measured and clamped for `DisplayLinkDriver`'s reasons: ProMotion varies
// the refresh rate, and a multi-second stall must advance a spring by one clamped step rather than past
// its target in one jump.

@MainActor
final class PreviewClock: NSObject {

    /// The longest step ever handed to the springs, in seconds — about six frames at 60 Hz.
    static let maxFrameStep: Double = 0.1

    private var screen: NSScreen
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private let onFrame: @MainActor (Double) -> Void

    private(set) var isRunning = false

    init(screen: NSScreen, onFrame: @escaping @MainActor (Double) -> Void) {
        self.screen = screen
        self.onFrame = onFrame
        super.init()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // `nil`, so the first tick of a run carries one frame and not the idle seconds since the last.
        lastTimestamp = nil
        let link = self.link ?? makeLink()
        self.link = link
        link.isPaused = false
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        link?.isPaused = true
    }

    /// Re-home on another screen — the window moved, or the display it was on went away.
    func move(to screen: NSScreen) {
        guard screen != self.screen else { return }
        self.screen = screen
        link?.invalidate()
        link = nil
        guard isRunning else { return }
        let link = makeLink()
        self.link = link
        link.isPaused = false
    }

    func invalidate() {
        link?.invalidate()
        link = nil
        isRunning = false
    }

    private func makeLink() -> CADisplayLink {
        let link = screen.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        return link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard let last = lastTimestamp else { return }
        onFrame(min(now - last, Self.maxFrameStep))
    }
}
