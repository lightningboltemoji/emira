import CoreGraphics
import Foundation
import ScreenCaptureKit
import EmiraCore

// The corner radius of every window no cover films, measured once each.
//
// The scrim cuts every window in front of a veil out of it, but only a window a cover has filmed has a radius
// (`SurfaceCache`): a dialog emira never adopted has none, and nor does a managed window before its first
// film. Cut at a guess, a window rounded more than the guess leaves a crescent of the veiled window behind it
// unveiled at each corner. So the scrim names the windows it outlined at a guess, and this films each one
// once, alone — children excluded, since a child filmed with its family is its parent squeezed into its frame
// (`surfaceShot`).
//
// **Keyed by window number.** An unmanaged window has no `WindowId`, and a managed one ordered out and back
// in keeps its number while AX hands it a new id. A number is reused once its window is gone, so an answer
// lives only while its number is on screen (`retain`).
//
// **Started only into an idle window server.** It takes one screenshot at a time, and a cover's batch is the
// latency anyone feels (`SCKCapturer`). A survey that finds any of emira's captures out looks again after
// `retryInterval`, or as soon as a cover comes down (`resume`). A capture that starts while one is out, a
// cover's included, waits behind it: a content read and one still, the price of measuring at all.

/// Films one window alone and reads its corner radius. A seam for `DesktopFilmer`'s reason.
@MainActor
public protocol CornerMeter: AnyObject {
    /// Answer window `number`'s corner radius in points, or `nil` where its pixels could not say.
    func measure(_ number: CGWindowID, then: @escaping @MainActor (Double?) -> Void)
}

/// The radii of the windows the scrim has asked about, one capture each, started while nothing else is out.
@MainActor
public final class CornerSurvey {

    /// How long a survey that found the capture plane busy waits before looking again, and how long a
    /// window whose pixels could not say waits before it is filmed again.
    static let retryInterval: TimeInterval = 0.25
    /// How many films a window gets before it is left unmeasured. A window caught opening, or before its
    /// app has drawn it, says nothing about the window it is about to be.
    static let attemptLimit = 3

    private let meter: any CornerMeter
    private let scheduler: any DelayScheduler

    /// Whether nothing of emira's is filming — no batch, no cover open, no desktop film.
    public var isIdle: @MainActor () -> Bool = { true }
    /// A radius has arrived, so a mask cut without it is wrong (`Scrims.cornersMeasured`).
    public var onMeasured: (@MainActor () -> Void)?

    private var radii: [CGWindowID: Double] = [:]
    /// Films each number has taken that could not say.
    private var failures: [CGWindowID: Int] = [:]
    /// Failed, and waiting out `retryInterval` before it may be queued again.
    private var resting: Set<CGWindowID> = []
    private var queue: [CGWindowID] = []
    private var measuring: CGWindowID?
    private var retryPending = false

    public init(meter: any CornerMeter = SCKCornerMeter(),
                scheduler: any DelayScheduler = DispatchScheduler()) {
        self.meter = meter
        self.scheduler = scheduler
    }

    /// Window `number`'s radius as measured, or `nil` for one not measured (yet, or at all).
    public func radius(of number: CGWindowID) -> Double? { radii[number] }

    /// Measure each of `numbers` that has no answer and is not already on its way.
    public func survey(_ numbers: [CGWindowID]) {
        for number in numbers where radii[number] == nil && failures[number, default: 0] < Self.attemptLimit
            && !resting.contains(number) && measuring != number && !queue.contains(number) {
            queue.append(number)
        }
        next()
    }

    /// The capture plane has gone idle: carry on with whatever is waiting.
    public func resume() { next() }

    /// Forget every number not in `live` — its window is gone, and the number may come back as another.
    public func retain(_ live: Set<CGWindowID>) {
        radii = radii.filter { live.contains($0.key) }
        failures = failures.filter { live.contains($0.key) }
        resting.formIntersection(live)
        queue.removeAll { !live.contains($0) }
    }

    private func next() {
        guard measuring == nil, let number = queue.first else { return }
        guard isIdle() else { return retry() }
        queue.removeFirst()
        measuring = number
        meter.measure(number) { [weak self] radius in
            guard let self else { return }
            measuring = nil
            if let radius {
                radii[number] = radius
                onMeasured?()
            } else {
                rest(number)
            }
            next()
        }
    }

    /// A film that could not say: count it, and let the number be asked about again after a pause.
    private func rest(_ number: CGWindowID) {
        failures[number, default: 0] += 1
        guard failures[number, default: 0] < Self.attemptLimit else { return }
        resting.insert(number)
        scheduler.schedule(after: Self.retryInterval) { [weak self] in
            // Gone in the meantime: `retain` has already let it go, and so does this.
            guard let self, resting.remove(number) != nil else { return }
            survey([number])
        }
    }

    private func retry() {
        guard !retryPending else { return }
        retryPending = true
        scheduler.schedule(after: Self.retryInterval) { [weak self] in
            self?.retryPending = false
            self?.next()
        }
    }
}

/// The real `CornerMeter`: one ScreenCaptureKit still of the window alone.
@MainActor
public final class SCKCornerMeter: CornerMeter {
    public init() {}

    public func measure(_ number: CGWindowID, then: @escaping @MainActor (Double?) -> Void) {
        Task { then(await cornerRadius(ofWindow: number)) }
    }
}

/// File scope for `SCKCapturer`'s reason: ScreenCaptureKit's descriptors are not `Sendable`.
private func cornerRadius(ofWindow number: CGWindowID) async -> Double? {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(true,
                                                                              onScreenWindowsOnly: true),
          let window = content.windows.first(where: { $0.windowID == number }),
          let shot = await surfaceShot(of: window, carryingChildren: false),
          let scale = shot.scale
    else { return nil }
    return CapturedSurface.measuredCornerRadius(of: shot.image, scale: CGFloat(scale))
}
