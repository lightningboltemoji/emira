import ApplicationServices
import CoreGraphics
import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The capture plane's tests. ScreenCaptureKit itself is untestable and holds no decisions — that is
// what `SurfaceCapturer` is for — so what is tested is the policy a transition's liveness rests on:
// every `capture` is answered exactly once (the core raises the cover on the last `captureReady`, and
// nothing rescues a dropped ack, since the hold timer starts at the raise), and the store is written
// before the acks, because that last ack re-enters the pump and comes back out as `raiseCover`.

@Suite @MainActor struct CaptureServiceTests {

    /// The display every single-screen fixture here covers — a base belongs to a screen now, so asking
    /// for one has to say which.
    static let display = MonitorId(1)

    /// A capturer that answers when told to, so a test can put a batch in flight. Sinks are kept per
    /// batch, not one at a time, because the interesting race needs two live at once: a batch that was
    /// superseded and then answers anyway.
    ///
    /// Pieces can be delivered one at a time (`sendBase`, `send`, `close`) or all together (`answer`),
    /// and the difference is the point: a real batch's stills arrive ~10 ms apart, so which of them the
    /// cover waits for is a decision, not an implementation detail.
    @MainActor final class ManualCapturer: SurfaceCapturer {
        private(set) var requests: [[CaptureRequest]] = []
        /// Whether each batch was asked for a base — what separates a cover being opened from one
        /// being grown.
        private(set) var baseRequested: [Bool] = []
        private struct Sink {
            let piece: @MainActor (CapturePiece) -> Void
            let done: @MainActor () -> Void
        }
        private var sinks: [Sink] = []

        func capture(_ requests: [CaptureRequest], includeBase: Bool,
                     piece: @escaping @MainActor (CapturePiece) -> Void,
                     done: @escaping @MainActor () -> Void) {
            self.requests.append(requests)
            self.baseRequested.append(includeBase)
            sinks.append(Sink(piece: piece, done: done))
        }

        /// Hand batch `batch` (default: the most recent) its base, leaving it open.
        func sendBase(batch: Int? = nil) {
            sink(batch)?.piece(.base(Self.image))
        }

        /// Hand batch `batch` one window's still, leaving it open. `size` is what the still was filmed
        /// at, which is what a later stand-in has to match. `pixels` is how big the *image* is, which
        /// almost nothing cares about — only the cache, which will not keep a still it cannot shrink.
        func send(_ id: WindowId, size: Size = Size(width: 100, height: 100), pixels: Int = 1,
                  batch: Int? = nil) {
            sink(batch)?.piece(.window(id, Self.surface(id, size, pixels: pixels)))
        }

        /// Close batch `batch`: nothing further is coming.
        func close(batch: Int? = nil) {
            sink(batch)?.done()
        }

        /// Answer batch `batch` whole — its base (if it asked for one) and then every window in order.
        /// The shape every test that predates streaming was written against.
        func answer(with windows: [WindowId] = [], base: Bool = true, batch: Int? = nil) {
            let index = batch ?? sinks.count - 1
            guard sinks.indices.contains(index) else { return }
            if base, baseRequested[index] { sendBase(batch: index) }
            for id in windows { send(id, batch: index) }
            close(batch: index)
        }

        /// Answer the latest batch again — models a capturer that calls back twice.
        func answerAgain() { answer(with: []) }

        private func sink(_ batch: Int?) -> Sink? {
            let index = batch ?? sinks.count - 1
            return sinks.indices.contains(index) ? sinks[index] : nil
        }

        /// A distinct image per call, on purpose: a stand-in and the capture that replaces it are
        /// otherwise indistinguishable, and telling them apart is the whole of what `.immediate` does.
        static func surface(_ id: WindowId, _ size: Size = Size(width: 100, height: 100),
                            pixels: Int = 1) -> CapturedSurface {
            CapturedSurface(image: makeImage(side: pixels),
                            frame: Rect(x: Double(id.raw), y: 0,
                                        width: size.width, height: size.height))
        }

        static let image: CGImage = makeImage()

        /// One pixel by default: nothing in the capture plane reads these, and a still that cannot be
        /// shrunk is one the cache declines to keep — which is the point for every test but one.
        static func makeImage(side: Int = 1) -> CGImage {
            let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return context.makeImage()!
        }
    }

    /// A `DelayScheduler` whose deadline fires only when a test says so.
    @MainActor final class ManualScheduler: DelayScheduler {
        private var work: [(TimeInterval, @MainActor () -> Void)] = []

        func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            self.work.append((seconds, work))
        }

        var scheduledDelays: [TimeInterval] { work.map(\.0) }

        /// Fire everything scheduled so far.
        func fire() {
            let due = work
            work.removeAll()
            for (_, item) in due { item() }
        }
    }

    @MainActor final class EventLog {
        private(set) var events: [Event] = []
        /// Run at each event, so a test can inspect the store *at the moment of the ack*.
        var onEvent: (@MainActor () -> Void)?
        lazy var sink = EventSink { [self] event in
            events.append(event)
            onEvent?()
        }

        var capturedIds: [WindowId] {
            events.compactMap { if case .captureReady(let id) = $0 { id } else { nil } }
        }
    }

    /// A registry holding records for `ids`, so those windows have window numbers to capture.
    static func registry(_ ids: [UInt64]) -> WindowRegistry {
        let registry = WindowRegistry()
        for id in ids {
            _ = registry.adopt(
                ObservedWindow(pid: 100, bundleId: "com.test.app", title: "w\(id)", role: .standard,
                               frame: Rect(x: 0, y: 0, width: 100, height: 100), isMinimized: false),
                element: AXWindow(AXUIElementCreateApplication(pid_t(id))),   // distinct per window
                number: CGWindowID(id))
        }
        return registry
    }

    static func service(_ ids: [UInt64], mode: CoverMode = .exact,
                        cache: SurfaceCache = SurfaceCache())
        -> (CaptureService, ManualCapturer, ManualScheduler, EventLog) {
        let capturer = ManualCapturer()
        let scheduler = ManualScheduler()
        let service = CaptureService(registry: registry(ids), capturer: capturer,
                                     scheduler: scheduler, cache: cache, mode: mode,
                                     deadline: 0.25)
        return (service, capturer, scheduler, EventLog())
    }

    // Every capture is answered, exactly once

    @Test func aBatchAcksEveryWindowItWasGiven() {
        let (service, capturer, _, log) = Self.service([1, 2, 3])
        service.capture(windows: [WindowId(1), WindowId(2), WindowId(3)], feedback: log.sink)
        #expect(log.events.isEmpty)                 // nothing acks before the batch resolves
        capturer.answer(with: [WindowId(1), WindowId(2), WindowId(3)])

        #expect(log.capturedIds == [WindowId(1), WindowId(2), WindowId(3)])
    }

    /// An id with no record has no window number to capture, but dropping it leaves the core waiting
    /// on a `captureReady` that never arrives — cover never raised, hold timer never armed.
    @Test func aWindowTheRegistryNeverKnewIsStillAcked() {
        let (service, capturer, _, log) = Self.service([1])          // 2 is unknown
        service.capture(windows: [WindowId(1), WindowId(2)], feedback: log.sink)

        #expect(capturer.requests.first?.map(\.id) == [WindowId(1)])  // only 1 could be requested
        capturer.answer(with: [WindowId(1)])

        #expect(log.capturedIds == [WindowId(1), WindowId(2)])        // both answered
        #expect(service.surface(for: WindowId(2)) == nil)             // …one of them with no pixels
    }

    /// The batch here grows an already-open cover, so the deadline's outcome is acks. A head batch
    /// that times out has nothing to cover with and takes the other path.
    @Test func aCapturerThatNeverAnswersIsBoundedByTheDeadline() {
        let (service, capturer, scheduler, log) = Self.service([1, 2, 3])
        service.capture(windows: [WindowId(1)], feedback: log.sink)       // opens the cover
        capturer.answer(with: [WindowId(1)])
        service.capture(windows: [WindowId(2), WindowId(3)], feedback: log.sink)   // …and never answers
        #expect(scheduler.scheduledDelays == [0.25, 0.25])
        #expect(log.capturedIds == [WindowId(1)])

        scheduler.fire()
        #expect(log.capturedIds == [WindowId(1), WindowId(2), WindowId(3)])
        #expect(service.surface(for: WindowId(2)) == nil)   // acked, with nothing to show for it
    }

    /// Two racers for one batch — the capturer and the deadline — and whichever loses must do nothing
    /// rather than the same thing twice: a second `captureReady` would re-raise the cover.
    @Test func aLateAnswerAfterTheDeadlineDoesNotAckASecondTime() {
        let (service, capturer, scheduler, log) = Self.service([1, 2])
        service.capture(windows: [WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        service.capture(windows: [WindowId(2)], feedback: log.sink)
        scheduler.fire()
        #expect(log.capturedIds == [WindowId(1), WindowId(2)])

        capturer.answer(with: [WindowId(2)], batch: 1)   // arrives after we gave up
        #expect(log.capturedIds == [WindowId(1), WindowId(2)])   // still once
        #expect(service.surface(for: WindowId(2)) == nil)        // and its late image is not adopted
    }

    @Test func theDeadlineAfterTheCapturerAnsweredAcksNothingFurther() {
        let (service, capturer, scheduler, log) = Self.service([1])
        service.capture(windows: [WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        scheduler.fire()

        #expect(log.capturedIds == [WindowId(1)])
    }

    @Test func aCapturerThatAnswersTwiceIsAbsorbed() {
        let (service, capturer, _, log) = Self.service([1])
        service.capture(windows: [WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        capturer.answerAgain()

        #expect(log.capturedIds == [WindowId(1)])
    }

    /// A retarget arriving before the cover is up captures the newcomers while the first batch is
    /// still out. Superseding the first batch instead would ack its windows with no pixels and raise
    /// the cover over the newcomers alone — every window already on screen, blank.
    @Test func twoBatchesInFlightEachPayTheirOwnAcks() {
        let (service, capturer, _, log) = Self.service([1, 2])
        service.capture(windows: [WindowId(1)], feedback: log.sink)      // batch 0 — opens the cover
        service.capture(windows: [WindowId(2)], feedback: log.sink)      // batch 1 — grows it

        #expect(log.events.isEmpty)                             // neither has been paid yet
        capturer.answer(with: [WindowId(2)], batch: 1)          // out of order, on purpose
        #expect(log.capturedIds == [WindowId(2)])
        capturer.answer(with: [WindowId(1)], batch: 0)
        #expect(log.capturedIds == [WindowId(2), WindowId(1)])
        // Both sets of pixels survive: the store merges, it does not replace.
        #expect(service.surface(for: WindowId(1)) != nil)
        #expect(service.surface(for: WindowId(2)) != nil)
    }

    /// The generation guard: a batch that answers after its deadline already paid it does nothing.
    @Test func aBatchThatAnswersAfterItWasAlreadyResolvedDoesNothing() {
        let (service, capturer, scheduler, log) = Self.service([1, 2])
        service.capture(windows: [WindowId(1)], feedback: log.sink)      // batch 0
        service.capture(windows: [WindowId(2)], feedback: log.sink)      // batch 1
        capturer.answer(with: [WindowId(1)], batch: 0)
        scheduler.fire()                                        // both deadlines
        #expect(log.capturedIds == [WindowId(1), WindowId(2)])  // batch 1 paid by its deadline

        capturer.answer(with: [WindowId(2)], batch: 1)          // …and answers anyway
        #expect(log.capturedIds == [WindowId(1), WindowId(2)])  // still once each
        #expect(service.surface(for: WindowId(2)) == nil)       // its late image is not adopted
    }

    // The cover session: one base, one lifetime

    /// The base is the display captured excluding the batch's windows. A batch growing a raised cover
    /// must not take a second one: the first batch's windows have already teleported, so a fresh base
    /// would carry them, frozen, behind their own sliding layers.
    @Test func onlyTheBatchThatOpensACoverTakesABase() {
        let (service, capturer, _, log) = Self.service([1, 2, 3])
        service.capture(windows: [WindowId(1), WindowId(2)], feedback: log.sink)
        service.capture(windows: [WindowId(3)], feedback: log.sink)

        #expect(capturer.baseRequested == [true, false])
        capturer.answer(with: [WindowId(1), WindowId(2)], batch: 0)
        capturer.answer(with: [WindowId(3)], base: false, batch: 1)
        #expect(service.base(of: Self.display) != nil)                            // the head's base, still there
        #expect(service.surface(for: WindowId(3)) != nil)       // and the newcomer merged in
    }

    /// After `closeCover` the next batch opens a *new* session: fresh base, fresh store. Without the
    /// clear, a transition would inherit the previous one's stills for any window it didn't re-capture.
    @Test func closingTheCoverStartsTheNextBatchFresh() {
        let (service, capturer, _, log) = Self.service([1, 2])
        service.capture(windows: [WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        #expect(service.surface(for: WindowId(1)) != nil)

        _ = service.closeCover()
        service.capture(windows: [WindowId(2)], feedback: log.sink)

        #expect(capturer.baseRequested == [true, true])          // a second cover, a second base
        #expect(service.surface(for: WindowId(1)) == nil)        // the old cover's stills are gone
        #expect(service.base(of: Self.display) == nil)
    }

    /// A command can arrive inside the 0.22 s cross-fade, so the new transition's stills must survive
    /// the old fade's discard — which is why `discard` takes a token rather than being bare.
    @Test func aStaleTokenCannotFreeTheNextCoversStills() {
        let (service, capturer, _, log) = Self.service([1, 2])
        service.capture(windows: [WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        let token = service.closeCover()                         // endTransition; the fade begins

        service.capture(windows: [WindowId(2)], feedback: log.sink)       // a new scroll, mid-fade
        capturer.answer(with: [WindowId(2)], batch: 1)
        service.discard(token)                                   // …and the old fade finally lands

        #expect(service.surface(for: WindowId(2)) != nil)        // the new cover keeps its pixels
        #expect(service.base(of: Self.display) != nil)
    }

    // No pixels ⇒ no cover (never a black one)

    /// A head batch that resolves with no base leaves the reconstruction nothing to be opaque with,
    /// and the overlay's own fill is black — so it answers `coverUnavailable`, which the core turns
    /// into a snap, rather than painting the display black for the length of the transition.
    @Test func aHeadBatchWithNoBaseAsksTheCoreNotToCover() {
        let (service, _, scheduler, log) = Self.service([1, 2])
        service.capture(windows: [WindowId(1), WindowId(2)], feedback: log.sink)
        scheduler.fire()                                         // the deadline: nothing captured

        #expect(log.events == [.coverUnavailable(MonitorId(1))])               // and *no* captureReady at all
        #expect(log.capturedIds.isEmpty)
    }

    /// …and the session ends with it, so the next scroll is a clean head batch rather than one that
    /// thinks it is growing a cover that was never raised.
    @Test func anAbandonedCoverLeavesTheNextBatchToOpenAFreshOne() {
        let (service, capturer, scheduler, log) = Self.service([1, 2])
        service.capture(windows: [WindowId(1)], feedback: log.sink)
        scheduler.fire()
        #expect(log.events == [.coverUnavailable(MonitorId(1))])

        service.capture(windows: [WindowId(2)], feedback: log.sink)
        #expect(capturer.baseRequested == [true, true])
        capturer.answer(with: [WindowId(2)], batch: 1)
        #expect(log.capturedIds == [WindowId(2)])                // a normal transition again
    }

    /// A batch can outlive the cover it was captured for: its head sibling failed and a new transition
    /// has claimed the store. Its acks are still owed, but its images are a photograph of somebody
    /// else's desktop and must not reach the live cover.
    @Test func aBatchOutlivingItsCoverKeepsItsPixelsToItself() {
        let (service, capturer, _, log) = Self.service([1, 2, 3])
        service.capture(windows: [WindowId(1)], feedback: log.sink)       // batch 0 — head
        service.capture(windows: [WindowId(2)], feedback: log.sink)       // batch 1 — grows it, stays out
        capturer.answer(with: [], base: false, batch: 0)         // the head came back with nothing
        #expect(log.events == [.coverUnavailable(MonitorId(1))])

        service.capture(windows: [WindowId(3)], feedback: log.sink)       // batch 2 — a fresh cover
        capturer.answer(with: [WindowId(3)], batch: 2)
        capturer.answer(with: [WindowId(2)], batch: 1)           // the abandoned cover's batch, at last

        #expect(service.surface(for: WindowId(2)) == nil)        // not adopted…
        #expect(service.surface(for: WindowId(3)) != nil)        // …and the live cover is untouched
        #expect(log.capturedIds == [WindowId(3), WindowId(2)])   // both acks still paid
    }

    /// A growing batch never owes a base, so an empty one is an ordinary missing still — a hole where
    /// one window is, not a reason to tear the cover down under the user.
    @Test func anExtendingBatchWithNoBaseIsJustAMissingStill() {
        let (service, capturer, _, log) = Self.service([1, 2])
        service.capture(windows: [WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        service.capture(windows: [WindowId(2)], feedback: log.sink)
        capturer.answer(with: [], base: false, batch: 1)         // its still failed

        #expect(log.capturedIds == [WindowId(1), WindowId(2)])   // acked like any other
        #expect(!log.events.contains(.coverUnavailable(MonitorId(1))))
        #expect(service.base(of: Self.display) != nil)                             // the cover is still opaque
    }

    /// The head of a transition is invisible to frames-per-transition, which starts counting at the
    /// raise, so each batch reports its own cost and misses.
    @Test func everyBatchReportsWhatItCostAndWhatItMissed() {
        let (service, capturer, scheduler, log) = Self.service([1, 2, 3])
        var reports: [CaptureReport] = []
        service.onBatchResolved = { reports.append($0) }

        service.capture(windows: [WindowId(1), WindowId(2)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])                     // 2's still failed
        #expect(reports.count == 1)
        #expect(reports[0].windows == 2)
        #expect(reports[0].missing == 1)
        #expect(reports[0].isHead)
        #expect(!reports[0].timedOut)

        service.capture(windows: [WindowId(3)], feedback: log.sink)       // grows the cover
        scheduler.fire()
        #expect(reports.count == 2)
        #expect(!reports[1].isHead)
        #expect(reports[1].timedOut)
    }

    // Ordering: images before acks

    /// The last `captureReady` re-enters the pump synchronously and comes back out as `raiseCover`,
    /// which reads the store. Acking first would raise the cover over an empty cache.
    @Test func theStoreIsPopulatedBeforeTheFirstAckIsDelivered() {
        let (service, capturer, _, log) = Self.service([1, 2])
        var seen: [Bool] = []
        log.onEvent = { seen.append(service.surface(for: WindowId(1)) != nil && service.base(of: Self.display) != nil) }

        service.capture(windows: [WindowId(1), WindowId(2)], feedback: log.sink)
        capturer.answer(with: [WindowId(1), WindowId(2)])

        #expect(seen == [true, true])               // true already at the *first* ack, not just the last
    }

    @Test func aSurfaceCarriesTheFrameItWasCapturedFrom() {
        let (service, capturer, _, log) = Self.service([7])
        service.capture(windows: [WindowId(7)], feedback: log.sink)
        capturer.answer(with: [WindowId(7)])

        #expect(service.surface(for: WindowId(7))?.frame == Rect(x: 7, y: 0, width: 100, height: 100))
    }

    @Test func discardEmptiesTheStore() {
        let (service, capturer, _, log) = Self.service([1])
        service.capture(windows: [WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        #expect(service.surface(for: WindowId(1)) != nil)

        service.discard(service.closeCover())
        #expect(service.surface(for: WindowId(1)) == nil)
        #expect(service.base(of: Self.display) == nil)
    }

    /// A window whose still failed while the rest of the batch succeeded: it is acked like any other
    /// and simply has no pixels, which `Reconstruction` renders as no layer.
    @Test func aFailedStillIsAckedAndLeavesNoSurface() {
        let (service, capturer, _, log) = Self.service([1, 2])
        service.capture(windows: [WindowId(1), WindowId(2)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])        // 2's capture failed

        #expect(log.capturedIds == [WindowId(1), WindowId(2)])
        #expect(service.surface(for: WindowId(1)) != nil)
        #expect(service.surface(for: WindowId(2)) == nil)
    }
}

/// Reading a window's corner radius back out of its own capture, which `WindowAnimation.crop` draws
/// its silhouette from. Two details are invisible when wrong in one direction, hence the synthetic
/// images: Core Graphics draws from a bottom-left origin into a top-down buffer, so measuring the
/// bottom corner would look plausible, and the alpha byte's position depends on a bitmap-info flag.
@Suite struct CornerRadiusTests {

    /// A window-shaped image: opaque rounded rect, transparent outside it — what a
    /// `desktopIndependentWindow` capture of a real window looks like at its corners.
    static func window(radius: CGFloat, size: CGSize, scale: CGFloat = 1) -> CGImage {
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let rect = CGRect(origin: .zero, size: pixels)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius * scale,
                               cornerHeight: radius * scale, transform: nil))
        context.fillPath()
        return context.makeImage()!
    }

    @Test(arguments: [0.0, 6.0, 10.0, 12.0, 16.0, 26.0])
    func theRadiusIsReadBackOffTheAlpha(radius: Double) {
        let image = Self.window(radius: CGFloat(radius), size: CGSize(width: 400, height: 300))
        let measured = CapturedSurface.measuredCornerRadius(of: image, scale: 1)
        // Sub-quarter-pixel at every radius — the accuracy of measuring an area rather than hunting
        // for an edge (a threshold scan down the leftmost column answers 8.6 for radius 12).
        #expect(measured != nil)
        #expect(abs((measured ?? -1) - radius) <= 0.25)
    }

    /// The answer is in points, so a Retina capture of the same window measures the same radius.
    @Test func theRadiusIsScaleIndependent() {
        let oneX = Self.window(radius: 12, size: CGSize(width: 400, height: 300), scale: 1)
        let twoX = Self.window(radius: 12, size: CGSize(width: 400, height: 300), scale: 2)
        #expect(abs((CapturedSurface.measuredCornerRadius(of: oneX, scale: 1) ?? -1) - 12) <= 0.25)
        #expect(abs((CapturedSurface.measuredCornerRadius(of: twoX, scale: 2) ?? -1) - 12) <= 0.25)
    }

    /// Rounded at the bottom and square at the top, the honest answer is 0 — the only way to catch a
    /// measurement that reads the wrong corner.
    @Test func itMeasuresTheTopCornerNotTheBottom() {
        let size = CGSize(width: 400, height: 300)
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        // Core Graphics' origin is bottom-left, so this rounds the image's *bottom* corners and leaves
        // the top square.
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size),
                               cornerWidth: 20, cornerHeight: 20, transform: nil))
        context.addRect(CGRect(x: 0, y: 100, width: 400, height: 200))
        context.fillPath()
        #expect(CapturedSurface.measuredCornerRadius(of: context.makeImage()!, scale: 1) == 0)
    }

    /// A fully opaque surface — a natively full-screen window, or one whose capture carries no alpha —
    /// answers `nil` rather than 0, so the caller can tell "square" from "couldn't tell".
    @Test func anOpaqueSurfaceHasNoAnswer() {
        let image = Self.window(radius: 0, size: CGSize(width: 400, height: 300))
        // A zero radius is square, answered as 0. `nil` is a capture whose first 64 points down the
        // left edge are all transparent, which no real window produces.
        #expect(CapturedSurface.measuredCornerRadius(of: image, scale: 1) == 0)

        let blank = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Big.rawValue)!
        #expect(CapturedSurface.measuredCornerRadius(of: blank.makeImage()!, scale: 1) == nil)
    }
}

@Suite @MainActor struct CoverModeTests {

    typealias Capturer = CaptureServiceTests.ManualCapturer
    typealias Log = CaptureServiceTests.EventLog

    /// A cache already holding a still for `id` at `size` — a previous cover's, reduced and kept.
    static func warm(_ id: WindowId, _ size: Size) -> SurfaceCache {
        let cache = SurfaceCache()
        cache.keep([id: Capturer.surface(id, size)])
        return cache
    }

    static func refreshed(_ log: Log) -> [WindowId] {
        log.events.compactMap { if case .captureRefreshed(let id) = $0 { id } else { nil } }
    }

    static let size = Size(width: 800, height: 600)

    /// The whole point: a window a kept still fits does not wait for its own capture, so the batch the
    /// cover waits on is the base and nothing else. Its still lands ~10 ms later and is a *refresh*.
    @Test func aKeptStillAnswersForItsWindowWithoutWaiting() {
        let cache = Self.warm(WindowId(1), Self.size)
        let (service, capturer, _, log) = CaptureServiceTests.service([1, 2], mode: .immediate,
                                                                     cache: cache)
        service.capture([CaptureTarget(id: WindowId(1), size: Self.size),
                         CaptureTarget(id: WindowId(2), size: Self.size)], feedback: log.sink)

        capturer.sendBase()
        // 1 stood in and is ready on the base alone; 2 has nothing kept and is still owed.
        #expect(log.capturedIds == [WindowId(1)])
        #expect(service.surface(for: WindowId(1)) != nil)

        capturer.send(WindowId(2), size: Self.size)
        #expect(log.capturedIds == [WindowId(1), WindowId(2)])
        #expect(Self.refreshed(log).isEmpty)          // 2 never stood in, so it never refreshes
    }

    /// Rule 2, which is what `.immediate` actually trades on: the acks wait for the base and for
    /// nothing else. A raise before it would paint the overlay's black fill over the desktop.
    @Test func aStandInStillWaitsForTheBase() {
        let cache = Self.warm(WindowId(1), Self.size)
        let (service, capturer, _, log) = CaptureServiceTests.service([1], mode: .immediate,
                                                                     cache: cache)
        service.capture([CaptureTarget(id: WindowId(1), size: Self.size)], feedback: log.sink)

        #expect(log.events.isEmpty)                   // pixels in hand, and still nothing said
        capturer.sendBase()
        #expect(log.capturedIds == [WindowId(1)])
    }

    /// The sharpen: a stood-in window's own still arrives after the cover is up, and asks for a content
    /// swap rather than a second `captureReady` — which would re-raise the cover.
    @Test func aStoodInWindowsOwnStillArrivesAsARefresh() {
        let cache = Self.warm(WindowId(1), Self.size)
        let (service, capturer, _, log) = CaptureServiceTests.service([1], mode: .immediate,
                                                                     cache: cache)
        service.capture([CaptureTarget(id: WindowId(1), size: Self.size)], feedback: log.sink)
        capturer.sendBase()
        let standIn = service.surface(for: WindowId(1))

        capturer.send(WindowId(1), size: Self.size)
        #expect(log.capturedIds == [WindowId(1)])                  // still exactly one
        #expect(Self.refreshed(log) == [WindowId(1)])
        // …and the store now holds the window's own pixels, which is what the refresh paints.
        #expect(service.surface(for: WindowId(1))?.image !== standIn?.image)
    }

    /// A still that beats the base has no layer to refresh — the cover has not been raised — and needs
    /// none: the raise reads the store, and finds the window's own pixels already sitting there.
    @Test func aStillThatBeatsTheRaiseReplacesTheStandInSilently() {
        let cache = Self.warm(WindowId(1), Self.size)
        let (service, capturer, _, log) = CaptureServiceTests.service([1], mode: .immediate,
                                                                     cache: cache)
        service.capture([CaptureTarget(id: WindowId(1), size: Self.size)], feedback: log.sink)

        capturer.send(WindowId(1), size: Self.size)     // its own still, before the base
        #expect(log.events.isEmpty)                     // nothing may be said before the base lands
        capturer.sendBase()
        #expect(log.capturedIds == [WindowId(1)])
        #expect(Self.refreshed(log).isEmpty)
    }

    /// "Exactly once" has to survive a capturer delivering one piece twice, and the hold rule opened a
    /// second way to break it: two acks for one window would raise the cover, then raise it again.
    @Test func aPieceDeliveredTwiceBeforeTheBaseIsStillOneAck() {
        let (service, capturer, _, log) = CaptureServiceTests.service([1], mode: .exact)
        service.capture(windows: [WindowId(1)], feedback: log.sink)

        capturer.send(WindowId(1))
        capturer.send(WindowId(1))          // the same still again, both held on the base
        capturer.sendBase()

        #expect(log.capturedIds == [WindowId(1)])
    }

    /// A batch can outlive the cover it was captured for. Its stand-in's ack was already paid, but its
    /// pixels never reached the live store — so asking for a repaint would name a layer belonging to
    /// somebody else's transition, with nothing behind it to paint.
    @Test func aStandInOutlivingItsCoverDoesNotAskForARefresh() {
        let cache = Self.warm(WindowId(1), Self.size)
        let (service, capturer, _, log) = CaptureServiceTests.service([1, 2], mode: .immediate,
                                                                     cache: cache)
        service.capture([CaptureTarget(id: WindowId(1), size: Self.size)], feedback: log.sink)
        capturer.sendBase()                                  // batch 0's stand-in is acked
        #expect(log.capturedIds == [WindowId(1)])

        _ = service.closeCover()
        service.capture([CaptureTarget(id: WindowId(2), size: Self.size)], feedback: log.sink)
        capturer.answer(with: [WindowId(2)], batch: 1)       // a whole new cover claims the store

        capturer.send(WindowId(1), size: Self.size, batch: 0)   // …and the old batch answers at last
        #expect(Self.refreshed(log).isEmpty)
        #expect(service.surface(for: WindowId(1)) == nil)
    }

    // When a kept still may not stand in

    /// Size is the whole of freshness. A window its app re-laid-out is not showing the pixels it was
    /// filmed with, and painting them into the new rect distorts them — so a resized window is a miss,
    /// and pays the capture it would have paid anyway.
    @Test func aStillFilmedAtAnotherSizeDoesNotStandIn() {
        let cache = Self.warm(WindowId(1), Size(width: 400, height: 600))
        let (service, capturer, _, log) = CaptureServiceTests.service([1], mode: .immediate,
                                                                     cache: cache)
        service.capture([CaptureTarget(id: WindowId(1), size: Self.size)], feedback: log.sink)

        capturer.sendBase()
        #expect(log.events.isEmpty)                     // the base alone buys nothing here
        capturer.send(WindowId(1), size: Self.size)
        #expect(log.capturedIds == [WindowId(1)])
        #expect(Self.refreshed(log).isEmpty)
    }

    /// **A display change is the one thing rule 2 cannot see.** Size is the whole of freshness only
    /// while the geometry a size was computed against holds; a reconfiguration moves every working area
    /// at once, so a window that comes back at the size it left at would stand in with pixels from a
    /// desktop that no longer exists. Dropping them costs the next cover a round trip, which is the
    /// cold-cache latency this suite's `anEmptyCacheIsSimplyTheOldLatency` already prices.
    @Test func aDisplayChangeDropsEveryKeptStill() {
        let cache = Self.warm(WindowId(1), Self.size)
        let (service, capturer, _, log) = CaptureServiceTests.service([1], mode: .immediate,
                                                                     cache: cache)
        service.forgetKeptStills()
        service.capture([CaptureTarget(id: WindowId(1), size: Self.size)], feedback: log.sink)

        capturer.sendBase()
        #expect(log.events.isEmpty, "nothing stood in, so the base alone acks nobody")
        capturer.send(WindowId(1), size: Self.size)
        #expect(log.capturedIds == [WindowId(1)])
        #expect(Self.refreshed(log).isEmpty, "…and a window that never stood in never refreshes")
    }

    /// A cold cache is the first transition of a session, and it costs exactly what it always did.
    @Test func anEmptyCacheIsSimplyTheOldLatency() {
        let (service, capturer, _, log) = CaptureServiceTests.service([1], mode: .immediate)
        service.capture([CaptureTarget(id: WindowId(1), size: Self.size)], feedback: log.sink)

        capturer.sendBase()
        #expect(log.events.isEmpty)
        capturer.send(WindowId(1), size: Self.size)
        #expect(log.capturedIds == [WindowId(1)])
    }

    /// `.exact` does not read the cache at all, however warm it is — the mode is the whole difference.
    @Test func exactNeverStandsIn() {
        let cache = Self.warm(WindowId(1), Self.size)
        let (service, capturer, _, log) = CaptureServiceTests.service([1], mode: .exact, cache: cache)
        service.capture([CaptureTarget(id: WindowId(1), size: Self.size)], feedback: log.sink)

        capturer.sendBase()
        #expect(log.events.isEmpty)
        #expect(service.surface(for: WindowId(1)) == nil)   // nothing was installed to stand in
        capturer.send(WindowId(1), size: Self.size)
        #expect(log.capturedIds == [WindowId(1)])
    }

    /// Rule 2 is not `.immediate`'s alone: streaming means an `.exact` batch can deliver a still before
    /// its base too, and acking it could complete a one-window scope's countdown to a baseless raise.
    @Test func exactAlsoHoldsItsAcksForTheBase() {
        let (service, capturer, _, log) = CaptureServiceTests.service([1], mode: .exact)
        service.capture(windows: [WindowId(1)], feedback: log.sink)

        capturer.send(WindowId(1))
        #expect(log.events.isEmpty)
        capturer.sendBase()
        #expect(log.capturedIds == [WindowId(1)])
    }

    /// A stand-in is still filmed: it buys the raise, not the transition. Anything else would leave a
    /// window that never re-enters a cold scope showing the same stale pixels for the daemon's life.
    @Test func aStoodInWindowIsStillCaptured() {
        let cache = Self.warm(WindowId(1), Self.size)
        let (service, capturer, _, log) = CaptureServiceTests.service([1], mode: .immediate,
                                                                     cache: cache)
        service.capture([CaptureTarget(id: WindowId(1), size: Self.size)], feedback: log.sink)

        #expect(capturer.requests.first?.map(\.id) == [WindowId(1)])
    }

    /// The head latency is when the batch stopped *blocking the raise*, not when it finished — and
    /// under `.immediate` the gap between those is the entire feature.
    @Test func theReportSeparatesTheGateFromTheBatch() {
        let cache = Self.warm(WindowId(1), Self.size)
        let (service, capturer, _, log) = CaptureServiceTests.service([1], mode: .immediate,
                                                                     cache: cache)
        var reports: [CaptureReport] = []
        service.onBatchResolved = { reports.append($0) }
        service.capture([CaptureTarget(id: WindowId(1), size: Self.size)], feedback: log.sink)

        capturer.sendBase()
        capturer.send(WindowId(1), size: Self.size)     // the batch runs on after the gate opened
        capturer.close()

        let report = reports[0]
        #expect(report.gate != nil)
        #expect(report.base != nil)
        #expect(report.gate! <= report.elapsed)
        #expect(report.standing == 1)                   // built from the kept still
    }

    /// The silent failure this instrument exists for: every stand-in matched, and every one of them was
    /// overtaken by its own capture before the gate opened, so the cover is exact and the mode bought
    /// nothing. `stoodIn` alone cannot tell that apart from working — it counts matches, not layers.
    @Test func standInsOvertakenBeforeTheGateAreReportedAsNotStanding() {
        let cache = Self.warm(WindowId(1), Self.size)
        let (service, capturer, _, log) = CaptureServiceTests.service([1], mode: .immediate,
                                                                     cache: cache)
        var reports: [CaptureReport] = []
        service.onBatchResolved = { reports.append($0) }
        service.capture([CaptureTarget(id: WindowId(1), size: Self.size)], feedback: log.sink)

        capturer.send(WindowId(1), size: Self.size)     // the window's own still beats the base…
        capturer.sendBase()                             // …and only now does the gate open
        capturer.close()

        #expect(reports[0].stoodIn == 1)                // matched
        #expect(reports[0].standing == 0)               // …and never reached the screen
    }

    /// A batch that never stops owing acks has no gate to report, rather than a misleading one.
    @Test func aBatchThatNeverOpensItsGateReportsNone() {
        let (service, capturer, scheduler, log) = CaptureServiceTests.service([1, 2], mode: .exact)
        service.capture(windows: [WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        var reports: [CaptureReport] = []
        service.onBatchResolved = { reports.append($0) }

        service.capture(windows: [WindowId(2)], feedback: log.sink)   // grows the cover, never answers
        scheduler.fire()

        #expect(reports[0].gate == nil)
        #expect(reports[0].timedOut)
    }

    /// The read-out says how much of the head latency was actually removed.
    @Test func theReportCountsTheStandIns() {
        let cache = Self.warm(WindowId(1), Self.size)
        let (service, capturer, _, log) = CaptureServiceTests.service([1, 2], mode: .immediate,
                                                                     cache: cache)
        var reports: [CaptureReport] = []
        service.onBatchResolved = { reports.append($0) }
        service.capture([CaptureTarget(id: WindowId(1), size: Self.size),
                         CaptureTarget(id: WindowId(2), size: Self.size)], feedback: log.sink)
        capturer.answer(with: [WindowId(1), WindowId(2)])

        #expect(reports.count == 1)
        #expect(reports[0].windows == 2)
        #expect(reports[0].stoodIn == 1)
        #expect(reports[0].missing == 0)
    }
}

@Suite @MainActor struct SurfaceCacheTests {

    typealias Capturer = CaptureServiceTests.ManualCapturer

    /// A still 4 points wide would reduce to one, so these are big enough to survive the ratio.
    static func surface(_ id: UInt64, width: Int = 400, height: Int = 300,
                        radius: Double? = 12) -> CapturedSurface {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return CapturedSurface(image: context.makeImage()!,
                               frame: Rect(x: 0, y: 0, width: Double(width), height: Double(height)),
                               cornerRadius: radius)
    }

    // Who wants a still kept

    /// `keepsStills` is the union of the two features that want them — `CoverMode.immediate` raises
    /// over them, a preview guide drawing `stills` draws from them — and neither is the other's, so the bit is
    /// settable rather than a second read of `mode`. Off, a cover's stills are simply freed.
    @Test func aCoverKeepsItsStillsOnlyWhenSomethingWantsThem() async throws {
        func kept(_ keepsStills: Bool) async throws -> Int {
            let cache = SurfaceCache()
            let (service, capturer, _, log) = CaptureServiceTests.service([1], cache: cache)
            service.keepsStills = keepsStills
            service.capture(windows: [WindowId(1)], feedback: log.sink)
            capturer.sendBase()
            capturer.send(WindowId(1), pixels: 40)       // big enough to survive the reduction
            capturer.close()
            service.discard(service.closeCover())        // the cross-fade landed; the pixels are freed
            // The reduction is detached Core Graphics work, so this is the one wait in the suite: poll
            // until the still lands, and give the negative case its own grace before concluding that
            // nothing ever will.
            for _ in 0..<(keepsStills ? 200 : 20) where cache.count == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            return cache.count
        }
        #expect(try await kept(true) == 1)
        #expect(try await kept(false) == 0)
    }

    /// The guide asks for a still *whatever* size it was filmed at, where a cover may not. At a few
    /// percent of scale staleness is invisible and a hole is not, so the trade the size match makes for
    /// `CoverMode.immediate` reverses.
    @Test func theSizeAgnosticReadIgnoresAMatchTheCoverWouldRefuse() {
        let cache = SurfaceCache()
        cache.keep([WindowId(1): Capturer.surface(WindowId(1), Size(width: 800, height: 600))])

        #expect(cache.surface(for: WindowId(1), at: Size(width: 400, height: 600)) == nil)
        #expect(cache.anySurface(for: WindowId(1)) != nil)
        #expect(cache.anySurface(for: WindowId(2)) == nil)
    }

    @Test func aStillIsReturnedOnlyAtTheSizeItWasFilmedAt() {
        let cache = SurfaceCache()
        cache.keep([WindowId(1): Capturer.surface(WindowId(1), Size(width: 800, height: 600))])

        #expect(cache.surface(for: WindowId(1), at: Size(width: 800, height: 600)) != nil)
        #expect(cache.surface(for: WindowId(1), at: Size(width: 400, height: 600)) == nil)
        #expect(cache.surface(for: WindowId(1), at: Size(width: 800, height: 300)) == nil)
        #expect(cache.surface(for: WindowId(2), at: Size(width: 800, height: 600)) == nil)
    }

    /// AX and ScreenCaptureKit describe one rectangle to different precisions, so an exact comparison
    /// would miss on windows that never changed. The same slack the identity join allows.
    @Test func roundingBetweenTheTwoSubsystemsStillMatches() {
        let cache = SurfaceCache()
        cache.keep([WindowId(1): Capturer.surface(WindowId(1), Size(width: 800, height: 600))])

        #expect(cache.surface(for: WindowId(1), at: Size(width: 801, height: 599)) != nil)
        #expect(cache.surface(for: WindowId(1), at: Size(width: 805, height: 600)) == nil)
    }

    /// A window that only moved is showing the pixels it was filmed with, and the kept still's own
    /// origin is stale by construction — the caller places every layer from the core's geometry.
    @Test func positionIsNotPartOfTheMatch() {
        let cache = SurfaceCache()
        var moved = Capturer.surface(WindowId(1), Size(width: 800, height: 600))
        moved = CapturedSurface(image: moved.image,
                                frame: Rect(x: 4000, y: 12, width: 800, height: 600))
        cache.keep([WindowId(1): moved])

        #expect(cache.surface(for: WindowId(1), at: Size(width: 800, height: 600)) != nil)
    }

    /// The reduction is the budget *and* the disclosure: a sixteenth of the pixels, and the softness an
    /// upscale back to the window's own size produces is what stops a stale still passing for a live one.
    @Test func aReducedStillIsSmallerAndKeepsWhatTheLayerNeeds() throws {
        let full = Self.surface(1, width: 400, height: 300)
        let small = try #require(SurfaceCache.reduced(full))

        #expect(small.image.width == 100)               // 400 × 0.25
        #expect(small.image.height == 75)
        // The frame is in *points* and describes the window, not the raster — so it does not shrink.
        #expect(small.frame == full.frame)
        // Carried, never re-measured: `measuredCornerRadius` inverts an alpha deficit against the scale
        // the still was filmed at, and this image is no longer at it.
        #expect(small.cornerRadius == 12)
    }

    /// Alpha survives, because a window capture is transparent outside its rounded corners and
    /// `WindowAnimation.stretch` derives the layer's whole drop shadow from exactly that.
    @Test func reductionKeepsAnAlphaChannel() throws {
        let small = try #require(SurfaceCache.reduced(Self.surface(1)))
        let alpha = small.image.alphaInfo
        #expect(alpha == .premultipliedFirst || alpha == .premultipliedLast || alpha == .first
                    || alpha == .last)
    }

    /// A still that cannot shrink is not kept at all, rather than kept at its own size: the reduction is
    /// what makes the cache affordable *and* what stops a stale still passing for a live one, so a copy
    /// with neither property is worth less than the miss it becomes.
    @Test func aStillThatCannotShrinkIsNotKept() {
        #expect(SurfaceCache.reduced(Self.surface(1, width: 1, height: 1)) == nil)
        #expect(SurfaceCache.reduced(Self.surface(1), by: 1.0) == nil)
    }

    /// A desktop of many large windows must not grow the cache without bound. Oldest-first, because the
    /// still that has been *read* most is the one most likely to be stale.
    @Test func theOldestStillsAreDroppedAtTheBudget() throws {
        let one = try #require(SurfaceCache.reduced(Self.surface(1)))
        let cache = SurfaceCache(budget: 2 * one.image.height * one.image.bytesPerRow)

        cache.keep([WindowId(1): one])
        cache.keep([WindowId(2): one])
        #expect(cache.count == 2)

        cache.keep([WindowId(3): one])
        #expect(cache.count == 2)
        #expect(cache.surface(for: WindowId(1), at: one.frame.size) == nil)   // the oldest went
        #expect(cache.surface(for: WindowId(2), at: one.frame.size) != nil)
        #expect(cache.surface(for: WindowId(3), at: one.frame.size) != nil)
    }

    /// Re-filming a window replaces its entry rather than adding a second, and its bytes with it.
    @Test func keepingAWindowTwiceDoesNotDoubleCountIt() throws {
        let one = try #require(SurfaceCache.reduced(Self.surface(1)))
        let cache = SurfaceCache()
        cache.keep([WindowId(1): one])
        let after = cache.byteCount

        cache.keep([WindowId(1): one])
        #expect(cache.count == 1)
        #expect(cache.byteCount == after)
    }

    @Test func clearingDropsEverything() throws {
        let cache = SurfaceCache()
        cache.keep([WindowId(1): try #require(SurfaceCache.reduced(Self.surface(1)))])
        cache.removeAll()

        #expect(cache.count == 0)
        #expect(cache.byteCount == 0)
    }
}

/// Two displays' worth of capture plane: one base each, the windows filmed once by the first.
///
/// The point of every test here is a rule that is inert on one screen — a batch may not ack until
/// *every* covered display has a base, and a head batch that ends one short abandons the cover rather
/// than raising a black rectangle over that screen.
@Suite @MainActor struct MultiDisplayCaptureTests {

    typealias ManualCapturer = CaptureServiceTests.ManualCapturer
    typealias ManualScheduler = CaptureServiceTests.ManualScheduler
    typealias EventLog = CaptureServiceTests.EventLog
    static let left = MonitorId(1), right = MonitorId(2)

    static func service() -> (CaptureService, ManualCapturer, ManualCapturer, EventLog) {
        let a = ManualCapturer(), b = ManualCapturer()
        let service = CaptureService(registry: CaptureServiceTests.registry([1, 2]),
                                     capturers: [(left, a), (right, b)],
                                     scheduler: ManualScheduler(), deadline: 0.25)
        return (service, a, b, EventLog())
    }

    /// **A batch goes to the display whose cover it is for, and to no other.** That is what a session
    /// naming its own monitor buys the capture plane: an ordinary transition on one screen costs the
    /// other nothing — no base, and no `SCShareableContent` fetch, which is a window-server round trip
    /// at the head of the transition.
    @Test func aBatchAsksOnlyTheDisplayItsCoverIsOver() {
        let (service, a, b, log) = Self.service()
        service.capture(windows: [WindowId(1), WindowId(2)], on: Self.left, feedback: log.sink)

        #expect(a.requests.last?.map(\.id) == [WindowId(1), WindowId(2)])
        #expect(a.baseRequested == [true])
        #expect(b.requests.isEmpty)
    }

    /// …and the same batch aimed at the other screen goes there instead — the still is filmed by that
    /// display's capturer, which is the seam that carries the backing scale a cross-display move needs.
    @Test func aCoverOnTheSecondDisplayIsFilmedByTheSecondCapturer() {
        let (service, a, b, log) = Self.service()
        service.capture(windows: [WindowId(1)], on: Self.right, feedback: log.sink)

        #expect(b.requests.last?.map(\.id) == [WindowId(1)])
        #expect(b.baseRequested == [true])
        #expect(a.requests.isEmpty)
    }

    /// Rule 2, per cover: no ack leaves a head batch until the base it needs has landed. A cover raised
    /// over its own display's black fill is the failure this prevents — and it is one display's base
    /// now, not every attached display's.
    @Test func noAckLeavesTheBatchUntilItsOwnBaseHasLanded() {
        let (service, a, _, log) = Self.service()
        service.capture(windows: [WindowId(1)], on: Self.left, feedback: log.sink)

        a.send(WindowId(1))
        #expect(log.events.isEmpty)                     // this display has no desktop yet

        a.sendBase()
        #expect(log.events == [.captureReady(WindowId(1))])
        #expect(service.base(of: Self.left) != nil)
        #expect(service.base(of: Self.right) == nil)    // the other screen is not part of this cover
    }

    /// A head batch that ends without its base abandons **its own** cover and no other: the reducer
    /// snaps on that screen while the cover on the other one keeps running.
    @Test func aHeadBatchMissingItsBaseAbandonsOnlyItsOwnCover() {
        let (service, a, b, log) = Self.service()
        service.capture(windows: [WindowId(1)], on: Self.left, feedback: log.sink)
        a.answer(with: [WindowId(1)])                   // display 1's cover is up and holding stills

        let second = EventLog()
        service.capture(windows: [WindowId(2)], on: Self.right, feedback: second.sink)
        b.send(WindowId(2))
        b.close()                                       // …and display 2 never produced a base

        #expect(second.events == [.coverUnavailable(Self.right)])
        #expect(service.base(of: Self.right) == nil)
        #expect(service.base(of: Self.left) != nil)     // untouched
        #expect(service.surface(for: WindowId(1)) != nil)
    }

    /// One cover coming down must not free the pixels another is still showing. The stills are keyed by
    /// window and a window can be owed by two covers, so the release is per owner rather than a sweep.
    @Test func closingOneCoverLeavesTheOtherDisplaysStillsAlone() {
        let (service, a, b, log) = Self.service()
        service.capture(windows: [WindowId(1)], on: Self.left, feedback: log.sink)
        a.answer(with: [WindowId(1)])
        service.capture(windows: [WindowId(2)], on: Self.right, feedback: log.sink)
        b.answer(with: [WindowId(2)])

        service.discard(service.closeCover(on: Self.left))
        #expect(service.surface(for: WindowId(1)) == nil)   // display 1's cover is down
        #expect(service.surface(for: WindowId(2)) != nil)   // display 2's is still up
        #expect(service.base(of: Self.right) != nil)
    }

    /// A window both covers show is filmed once per cover and released by the **last** of them: a
    /// per-cover sweep would blank a layer that is still on screen.
    @Test func aStillTwoCoversShareOutlivesTheFirstOfThem() {
        let (service, a, b, log) = Self.service()
        service.capture(windows: [WindowId(1)], on: Self.left, feedback: log.sink)
        a.answer(with: [WindowId(1)])
        service.capture(windows: [WindowId(1)], on: Self.right, feedback: log.sink)
        b.answer(with: [WindowId(1)])

        service.discard(service.closeCover(on: Self.left))
        #expect(service.surface(for: WindowId(1)) != nil)   // display 2 is still showing it
        service.discard(service.closeCover(on: Self.right))
        #expect(service.surface(for: WindowId(1)) == nil)
    }

    /// A display that has left can produce no base, and a head batch owing one abandons that cover — so
    /// it is not asked at all, and the batch resolves rather than sitting out its deadline.
    @Test func aDepartedDisplayIsNotOwedABaseItCannotProduce() {
        let (service, _, b, log) = Self.service()
        service.isAttached = { $0 == Self.left }
        service.capture(windows: [WindowId(1)], on: Self.right, feedback: log.sink)

        #expect(b.requests.isEmpty)                     // never asked
        #expect(log.events == [.coverUnavailable(Self.right)])
    }

    /// A batch that *grows* a raised cover takes no base — a second base taken mid-transition would
    /// bake the first batch's windows, by then already teleported, into the desktop behind their own
    /// sliding layers — and it still resolves on the one capturer it asked.
    @Test func growingACoverTakesNoBaseAndStillResolves() {
        let (service, a, _, log) = Self.service()
        service.capture(windows: [WindowId(1)], on: Self.left, feedback: log.sink)
        a.answer(with: [WindowId(1)])

        let growth = EventLog()
        service.capture(windows: [WindowId(2)], on: Self.left, feedback: growth.sink)
        #expect(a.baseRequested == [true, false])
        a.send(WindowId(2), batch: 1)
        #expect(growth.events == [.captureReady(WindowId(2))])
    }

    /// Each display's cover session is its own: opening one on the second screen does not make the
    /// first screen's next batch a head batch, and does not take its base again.
    @Test func aCoverSessionIsPerDisplay() {
        let (service, a, b, log) = Self.service()
        service.capture(windows: [WindowId(1)], on: Self.left, feedback: log.sink)
        a.answer(with: [WindowId(1)])
        service.capture(windows: [WindowId(2)], on: Self.right, feedback: log.sink)
        b.answer(with: [WindowId(2)])

        service.capture(windows: [WindowId(1)], on: Self.left, feedback: log.sink)
        #expect(a.baseRequested == [true, false])       // display 1's cover was still open
        #expect(b.baseRequested == [true])
    }

    // Hot-plug — the capturers changing under a live store

    /// A display that arrives is filmed by its own capturer from the next batch on. Nothing else is
    /// rebuilt: the store, the cache and the deadline are the daemon's for its whole life.
    @Test func aCapturerAddedForANewDisplayTakesItsOwnBatches() {
        let (service, a, _, log) = Self.service()
        let arriving = ManualCapturer()
        service.setCapturers([(Self.left, a), (MonitorId(3), arriving)])

        service.capture(windows: [WindowId(1)], on: MonitorId(3), feedback: log.sink)
        #expect(arriving.requests.last?.map(\.id) == [WindowId(1)])
        #expect(a.requests.isEmpty)
    }

    /// A departing display's **base** goes with it. A photograph of a screen that is gone is the one
    /// thing in the store that cannot outlive its display: a re-plugged id at a new resolution would
    /// otherwise raise its first cover onto the desktop as it was two configurations ago.
    @Test func aRetiredDisplayLosesItsBaseAndItsOpenCover() {
        let (service, a, b, log) = Self.service()
        service.capture(windows: [WindowId(1)], on: Self.left, feedback: log.sink)
        a.answer(with: [WindowId(1)])
        #expect(service.base(of: Self.left) != nil)

        service.setCapturers([(Self.right, b)])
        #expect(service.base(of: Self.left) == nil)

        // …and its cover is closed with it, so the next batch for that id opens a fresh one and takes
        // a fresh base rather than growing a cover nothing is showing.
        service.setCapturers([(Self.left, a), (Self.right, b)])
        service.capture(windows: [WindowId(2)], on: Self.left, feedback: EventLog().sink)
        #expect(a.baseRequested == [true, true])
    }

    /// A still two covers were showing survives one of their displays leaving — the same rule that
    /// keeps one cover coming down from blanking a layer on the other.
    @Test func aStillTheOtherDisplayIsStillShowingSurvivesTheRetirement() {
        let (service, a, b, log) = Self.service()
        service.capture(windows: [WindowId(1)], on: Self.left, feedback: log.sink)
        a.answer(with: [WindowId(1)])
        service.capture(windows: [WindowId(1)], on: Self.right, feedback: log.sink)
        b.answer(with: [WindowId(1)])

        service.setCapturers([(Self.right, b)])
        #expect(service.surface(for: WindowId(1)) != nil)
    }
}

/// The call shapes a single-cover test wants: ids alone, at a size no still was ever filmed at (so
/// nothing kept can stand in), and a default display — a cover is one screen's, and a test about the
/// batch rather than about the routing should not have to say which.
extension CaptureService {
    func capture(windows ids: [WindowId], on monitor: MonitorId = MonitorId(1),
                 feedback: EventSink) {
        capture(ids.map { CaptureTarget(id: $0, size: .zero) }, on: monitor, feedback: feedback)
    }

    func capture(_ targets: [CaptureTarget], feedback: EventSink) {
        capture(targets, on: MonitorId(1), feedback: feedback)
    }

    func closeCover() -> CoverToken { closeCover(on: MonitorId(1)) }
}
