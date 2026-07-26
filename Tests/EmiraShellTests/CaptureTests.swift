import ApplicationServices
import CoreGraphics
import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The capture plane's tests. ScreenCaptureKit itself is not testable and holds no decisions (that is
// what `SurfaceCapturer` is for); what *is* testable is the policy above it, and it is the policy that
// a transition's liveness depends on:
//
//  1. **Every `capture` is answered, exactly once.** The core raises the cover on the *last*
//     `captureReady` and the real windows only teleport behind a raised cover — so a dropped ack is a
//     command that silently does nothing, with no hold-timeout to rescue it (the hold timer starts at
//     the raise). Most of this file is that one sentence, from every angle it can fail: a window the
//     registry never knew, a capturer that never answers, a capturer that answers twice, a capturer
//     that answers *after* the deadline already did.
//  2. **The store is written before the acks.** The last ack re-enters the pump synchronously and comes
//     straight back out as `raiseCover`, which reads the store — so "images first, then acks" is an
//     ordering the cover's fidelity depends on, and it is asserted from inside a sink that looks.
//
// `WindowRegistry` is used for real rather than faked: it is a value-ish store of records and the id →
// window-number lookup is precisely what this file wants to exercise (including its failure).

@Suite @MainActor struct CaptureServiceTests {

    // MARK: - Fixtures

    /// A capturer that answers when told to, so a test can put a batch "in flight".
    ///
    /// Completions are kept **per batch** rather than one-at-a-time, because the interesting race needs
    /// two live at once: a batch that was superseded and then answers anyway. A capturer that forgot
    /// the older completion could not model it, and the guard against it would look untested because it
    /// was unreachable in the fixture rather than in the code.
    @MainActor final class ManualCapturer: SurfaceCapturer {
        private(set) var requests: [[CaptureRequest]] = []
        /// Whether each batch was asked for a base — the fact that separates a cover being *opened*
        /// from one being *grown*, and the one a second base would silently ruin.
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

    /// The absence this whole file exists for: an id with no record cannot be captured — there is no
    /// window number to ask about — but dropping it would leave the core waiting on a `captureReady`
    /// that can never arrive, with the cover never raised and the hold timer never armed.
    @Test func aWindowTheRegistryNeverKnewIsStillAcked() {
        let (service, capturer, _, log) = Self.service([1])          // 2 is unknown
        service.capture([WindowId(1), WindowId(2)], feedback: log.sink)

        #expect(capturer.requests.first?.map(\.id) == [WindowId(1)])  // only 1 could be requested
        capturer.answer(with: [WindowId(1)])

        #expect(log.capturedIds == [WindowId(1), WindowId(2)])        // both answered
        #expect(service.surface(for: WindowId(2)) == nil)             // …one of them with no pixels
    }

    /// The batch under test grows an already-open cover, so the deadline's outcome here is *acks* —
    /// the cover exists and gains a hole. A head batch that times out has nothing to cover with at all
    /// and takes the other path (`aHeadBatchWithNoBaseAsksTheCoreNotToCover`).
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

    /// The two racers for one batch — the capturer and the deadline — and whichever loses must do
    /// nothing at all rather than the same thing twice. A second `captureReady` for a window the core
    /// has already counted would push `pendingCaptures` negative in spirit and, worse, re-raise.
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

    /// **Two batches can be live at once, and each pays its own acks (M4 part 2).**
    ///
    /// This test asserted the opposite until the cover learned to grow: a second batch used to
    /// *supersede* the first, paying its acks immediately with no pixels. That was harmless only while
    /// the reducer never issued a second batch. It does now — a retarget arriving before the cover is
    /// up widens the scope and captures the newcomers while the first batch is still out — and
    /// superseding it would ack the original windows with nothing and raise the cover over the
    /// newcomers alone: every window that was already on screen, blank.
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

    /// The generation guard: a batch that answers twice, or answers after its deadline already paid
    /// it, must do **nothing** the second time rather than the same thing again.
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

    /// The base is the display captured *excluding* the batch's windows. A batch that grows a raised
    /// cover must not take a second one: by then the first batch's windows have teleported to their end
    /// frames, so a fresh base would carry them — frozen — behind their own sliding layers.
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

    /// A cross-fade takes 0.22 s and a command can arrive inside it. The stills the new transition has
    /// already captured must survive the old fade's discard — which is the entire reason `discard`
    /// takes a token instead of being a bare `discard()`.
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

    /// The failure this slice named. A head batch that resolves with no base leaves the reconstruction
    /// with nothing to be opaque *with* — and the overlay's own fill is black, so acking would paint
    /// the whole display black for the length of the transition. It answers `coverUnavailable` instead,
    /// which the core turns into a snap.
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

    /// A batch can outlive the cover it was captured for: its head sibling failed, the session was
    /// abandoned, and a whole new transition has since claimed the store. Its acks are still owed — the
    /// core reduces them to nothing — but its images are a photograph of somebody else's desktop and
    /// must not reach a cover that is about to be raised over the current one.
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

    /// A *growing* batch never owes a base, so an empty one from it is an ordinary missing still — a
    /// hole where one window is, not a reason to tear the cover down under the user.
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

    /// The ~110 ms at the head of every transition that frames-per-transition structurally cannot see
    /// (it starts counting at the raise). Reported permanently so the deadline and the spring can be
    /// tuned against a number instead of a guess.
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
    /// which reads the store. Acking first would raise the cover over an empty cache — every layer
    /// blank, on the one frame where fidelity matters most.
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
