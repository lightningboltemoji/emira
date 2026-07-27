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

    // MARK: - Fixtures

    /// A capturer that answers when told to, so a test can put a batch in flight. Completions are kept
    /// per batch, not one at a time, because the interesting race needs two live at once: a batch that
    /// was superseded and then answers anyway.
    @MainActor final class ManualCapturer: SurfaceCapturer {
        private(set) var requests: [[CaptureRequest]] = []
        /// Whether each batch was asked for a base — what separates a cover being opened from one
        /// being grown.
        private(set) var baseRequested: [Bool] = []
        private var completions: [@MainActor (CaptureBatch) -> Void] = []

        func capture(_ requests: [CaptureRequest], includeBase: Bool,
                     then completion: @escaping @MainActor (CaptureBatch) -> Void) {
            self.requests.append(requests)
            self.baseRequested.append(includeBase)
            completions.append(completion)
        }

        /// Answer batch `batch` (default: the most recent) with stills for `windows`.
        func answer(with windows: [WindowId] = [], base: Bool = true, batch: Int? = nil) {
            let index = batch ?? completions.count - 1
            guard completions.indices.contains(index) else { return }
            let surfaces = windows.reduce(into: [WindowId: CapturedSurface]()) { out, id in
                out[id] = CapturedSurface(image: Self.image, frame: Rect(x: Double(id.raw), y: 0,
                                                                        width: 100, height: 100))
            }
            completions[index](CaptureBatch(surfaces: surfaces, base: base ? Self.image : nil))
        }

        /// Answer the latest batch again — models a capturer that calls back twice.
        func answerAgain() { answer(with: []) }

        static let image: CGImage = {
            let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return context.makeImage()!
        }()
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

    static func service(_ ids: [UInt64])
        -> (CaptureService, ManualCapturer, ManualScheduler, EventLog) {
        let capturer = ManualCapturer()
        let scheduler = ManualScheduler()
        let service = CaptureService(registry: registry(ids), capturer: capturer,
                                     scheduler: scheduler, deadline: 0.25)
        return (service, capturer, scheduler, EventLog())
    }

    // MARK: - Every capture is answered, exactly once

    @Test func aBatchAcksEveryWindowItWasGiven() {
        let (service, capturer, _, log) = Self.service([1, 2, 3])
        service.capture([WindowId(1), WindowId(2), WindowId(3)], feedback: log.sink)
        #expect(log.events.isEmpty)                 // nothing acks before the batch resolves
        capturer.answer(with: [WindowId(1), WindowId(2), WindowId(3)])

        #expect(log.capturedIds == [WindowId(1), WindowId(2), WindowId(3)])
    }

    /// An id with no record has no window number to capture, but dropping it leaves the core waiting
    /// on a `captureReady` that never arrives — cover never raised, hold timer never armed.
    @Test func aWindowTheRegistryNeverKnewIsStillAcked() {
        let (service, capturer, _, log) = Self.service([1])          // 2 is unknown
        service.capture([WindowId(1), WindowId(2)], feedback: log.sink)

        #expect(capturer.requests.first?.map(\.id) == [WindowId(1)])  // only 1 could be requested
        capturer.answer(with: [WindowId(1)])

        #expect(log.capturedIds == [WindowId(1), WindowId(2)])        // both answered
        #expect(service.surface(for: WindowId(2)) == nil)             // …one of them with no pixels
    }

    /// The batch here grows an already-open cover, so the deadline's outcome is acks. A head batch
    /// that times out has nothing to cover with and takes the other path.
    @Test func aCapturerThatNeverAnswersIsBoundedByTheDeadline() {
        let (service, capturer, scheduler, log) = Self.service([1, 2, 3])
        service.capture([WindowId(1)], feedback: log.sink)       // opens the cover
        capturer.answer(with: [WindowId(1)])
        service.capture([WindowId(2), WindowId(3)], feedback: log.sink)   // …and never answers
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
        service.capture([WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        service.capture([WindowId(2)], feedback: log.sink)
        scheduler.fire()
        #expect(log.capturedIds == [WindowId(1), WindowId(2)])

        capturer.answer(with: [WindowId(2)], batch: 1)   // arrives after we gave up
        #expect(log.capturedIds == [WindowId(1), WindowId(2)])   // still once
        #expect(service.surface(for: WindowId(2)) == nil)        // and its late image is not adopted
    }

    @Test func theDeadlineAfterTheCapturerAnsweredAcksNothingFurther() {
        let (service, capturer, scheduler, log) = Self.service([1])
        service.capture([WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        scheduler.fire()

        #expect(log.capturedIds == [WindowId(1)])
    }

    @Test func aCapturerThatAnswersTwiceIsAbsorbed() {
        let (service, capturer, _, log) = Self.service([1])
        service.capture([WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        capturer.answerAgain()

        #expect(log.capturedIds == [WindowId(1)])
    }

    /// A retarget arriving before the cover is up captures the newcomers while the first batch is
    /// still out. Superseding the first batch instead would ack its windows with no pixels and raise
    /// the cover over the newcomers alone — every window already on screen, blank.
    @Test func twoBatchesInFlightEachPayTheirOwnAcks() {
        let (service, capturer, _, log) = Self.service([1, 2])
        service.capture([WindowId(1)], feedback: log.sink)      // batch 0 — opens the cover
        service.capture([WindowId(2)], feedback: log.sink)      // batch 1 — grows it

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
        service.capture([WindowId(1)], feedback: log.sink)      // batch 0
        service.capture([WindowId(2)], feedback: log.sink)      // batch 1
        capturer.answer(with: [WindowId(1)], batch: 0)
        scheduler.fire()                                        // both deadlines
        #expect(log.capturedIds == [WindowId(1), WindowId(2)])  // batch 1 paid by its deadline

        capturer.answer(with: [WindowId(2)], batch: 1)          // …and answers anyway
        #expect(log.capturedIds == [WindowId(1), WindowId(2)])  // still once each
        #expect(service.surface(for: WindowId(2)) == nil)       // its late image is not adopted
    }

    // MARK: - The cover session: one base, one lifetime

    /// The base is the display captured excluding the batch's windows. A batch growing a raised cover
    /// must not take a second one: the first batch's windows have already teleported, so a fresh base
    /// would carry them, frozen, behind their own sliding layers.
    @Test func onlyTheBatchThatOpensACoverTakesABase() {
        let (service, capturer, _, log) = Self.service([1, 2, 3])
        service.capture([WindowId(1), WindowId(2)], feedback: log.sink)
        service.capture([WindowId(3)], feedback: log.sink)

        #expect(capturer.baseRequested == [true, false])
        capturer.answer(with: [WindowId(1), WindowId(2)], batch: 0)
        capturer.answer(with: [WindowId(3)], base: false, batch: 1)
        #expect(service.base != nil)                            // the head's base, still there
        #expect(service.surface(for: WindowId(3)) != nil)       // and the newcomer merged in
    }

    /// After `closeCover` the next batch opens a *new* session: fresh base, fresh store. Without the
    /// clear, a transition would inherit the previous one's stills for any window it didn't re-capture.
    @Test func closingTheCoverStartsTheNextBatchFresh() {
        let (service, capturer, _, log) = Self.service([1, 2])
        service.capture([WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        #expect(service.surface(for: WindowId(1)) != nil)

        _ = service.closeCover()
        service.capture([WindowId(2)], feedback: log.sink)

        #expect(capturer.baseRequested == [true, true])          // a second cover, a second base
        #expect(service.surface(for: WindowId(1)) == nil)        // the old cover's stills are gone
        #expect(service.base == nil)
    }

    /// A command can arrive inside the 0.22 s cross-fade, so the new transition's stills must survive
    /// the old fade's discard — which is why `discard` takes a token rather than being bare.
    @Test func aStaleTokenCannotFreeTheNextCoversStills() {
        let (service, capturer, _, log) = Self.service([1, 2])
        service.capture([WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        let token = service.closeCover()                         // endTransition; the fade begins

        service.capture([WindowId(2)], feedback: log.sink)       // a new scroll, mid-fade
        capturer.answer(with: [WindowId(2)], batch: 1)
        service.discard(token)                                   // …and the old fade finally lands

        #expect(service.surface(for: WindowId(2)) != nil)        // the new cover keeps its pixels
        #expect(service.base != nil)
    }

    // MARK: - No pixels ⇒ no cover (never a black one)

    /// A head batch that resolves with no base leaves the reconstruction nothing to be opaque with,
    /// and the overlay's own fill is black — so it answers `coverUnavailable`, which the core turns
    /// into a snap, rather than painting the display black for the length of the transition.
    @Test func aHeadBatchWithNoBaseAsksTheCoreNotToCover() {
        let (service, _, scheduler, log) = Self.service([1, 2])
        service.capture([WindowId(1), WindowId(2)], feedback: log.sink)
        scheduler.fire()                                         // the deadline: nothing captured

        #expect(log.events == [.coverUnavailable])               // and *no* captureReady at all
        #expect(log.capturedIds.isEmpty)
    }

    /// …and the session ends with it, so the next scroll is a clean head batch rather than one that
    /// thinks it is growing a cover that was never raised.
    @Test func anAbandonedCoverLeavesTheNextBatchToOpenAFreshOne() {
        let (service, capturer, scheduler, log) = Self.service([1, 2])
        service.capture([WindowId(1)], feedback: log.sink)
        scheduler.fire()
        #expect(log.events == [.coverUnavailable])

        service.capture([WindowId(2)], feedback: log.sink)
        #expect(capturer.baseRequested == [true, true])
        capturer.answer(with: [WindowId(2)], batch: 1)
        #expect(log.capturedIds == [WindowId(2)])                // a normal transition again
    }

    /// A batch can outlive the cover it was captured for: its head sibling failed and a new transition
    /// has claimed the store. Its acks are still owed, but its images are a photograph of somebody
    /// else's desktop and must not reach the live cover.
    @Test func aBatchOutlivingItsCoverKeepsItsPixelsToItself() {
        let (service, capturer, _, log) = Self.service([1, 2, 3])
        service.capture([WindowId(1)], feedback: log.sink)       // batch 0 — head
        service.capture([WindowId(2)], feedback: log.sink)       // batch 1 — grows it, stays out
        capturer.answer(with: [], base: false, batch: 0)         // the head came back with nothing
        #expect(log.events == [.coverUnavailable])

        service.capture([WindowId(3)], feedback: log.sink)       // batch 2 — a fresh cover
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
        service.capture([WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        service.capture([WindowId(2)], feedback: log.sink)
        capturer.answer(with: [], base: false, batch: 1)         // its still failed

        #expect(log.capturedIds == [WindowId(1), WindowId(2)])   // acked like any other
        #expect(!log.events.contains(.coverUnavailable))
        #expect(service.base != nil)                             // the cover is still opaque
    }

    // MARK: - The read-out

    /// The head of a transition is invisible to frames-per-transition, which starts counting at the
    /// raise, so each batch reports its own cost and misses.
    @Test func everyBatchReportsWhatItCostAndWhatItMissed() {
        let (service, capturer, scheduler, log) = Self.service([1, 2, 3])
        var reports: [CaptureReport] = []
        service.onBatchResolved = { reports.append($0) }

        service.capture([WindowId(1), WindowId(2)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])                     // 2's still failed
        #expect(reports.count == 1)
        #expect(reports[0].windows == 2)
        #expect(reports[0].missing == 1)
        #expect(reports[0].isHead)
        #expect(!reports[0].timedOut)

        service.capture([WindowId(3)], feedback: log.sink)       // grows the cover
        scheduler.fire()
        #expect(reports.count == 2)
        #expect(!reports[1].isHead)
        #expect(reports[1].timedOut)
    }

    // MARK: - Ordering: images before acks

    /// The last `captureReady` re-enters the pump synchronously and comes back out as `raiseCover`,
    /// which reads the store. Acking first would raise the cover over an empty cache.
    @Test func theStoreIsPopulatedBeforeTheFirstAckIsDelivered() {
        let (service, capturer, _, log) = Self.service([1, 2])
        var seen: [Bool] = []
        log.onEvent = { seen.append(service.surface(for: WindowId(1)) != nil && service.base != nil) }

        service.capture([WindowId(1), WindowId(2)], feedback: log.sink)
        capturer.answer(with: [WindowId(1), WindowId(2)])

        #expect(seen == [true, true])               // true already at the *first* ack, not just the last
    }

    @Test func aSurfaceCarriesTheFrameItWasCapturedFrom() {
        let (service, capturer, _, log) = Self.service([7])
        service.capture([WindowId(7)], feedback: log.sink)
        capturer.answer(with: [WindowId(7)])

        #expect(service.surface(for: WindowId(7))?.frame == Rect(x: 7, y: 0, width: 100, height: 100))
    }

    // MARK: - Lifetime

    @Test func discardEmptiesTheStore() {
        let (service, capturer, _, log) = Self.service([1])
        service.capture([WindowId(1)], feedback: log.sink)
        capturer.answer(with: [WindowId(1)])
        #expect(service.surface(for: WindowId(1)) != nil)

        service.discard(service.closeCover())
        #expect(service.surface(for: WindowId(1)) == nil)
        #expect(service.base == nil)
    }

    /// A window whose still failed while the rest of the batch succeeded: it is acked like any other
    /// and simply has no pixels, which `Reconstruction` renders as no layer.
    @Test func aFailedStillIsAckedAndLeavesNoSurface() {
        let (service, capturer, _, log) = Self.service([1, 2])
        service.capture([WindowId(1), WindowId(2)], feedback: log.sink)
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
