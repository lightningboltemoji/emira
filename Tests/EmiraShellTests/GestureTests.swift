import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The trackpad subsystem's policy — everything above the tap, which is `GestureTapper`, two methods
// wide, with `CGGestureTap` untestable by construction. What is tested is the arithmetic: which
// episodes become a scroll, how much travel the frame is handed, how fast the hand was going when it
// let go, and what happens when the samples simply stop.
//
// Driven from synthesized contact frames, so no window server and no TCC grant.

@Suite @MainActor struct GestureTests {

    /// A `GestureTapper` a test pushes frames through.
    final class FakeTapper: GestureTapper {
        /// What the system pretends to answer when asked for a tap.
        var isAvailable = true
        private(set) var isInstalled = false
        private(set) var installs = 0
        private var onSample: (@MainActor (TouchSample) -> Void)?

        func install(_ onSample: @escaping @MainActor (TouchSample) -> Void) -> Bool {
            installs += 1
            guard isAvailable else { return false }
            self.onSample = onSample
            isInstalled = true
            return true
        }

        func remove() {
            isInstalled = false
            onSample = nil
        }

        func send(_ sample: TouchSample) { onSample?(sample) }
    }

    final class ManualScheduler: DelayScheduler {
        private var work: [@MainActor () -> Void] = []

        func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            self.work.append(work)
        }

        var pending: Int { work.count }

        func fire() {
            let due = work
            work.removeAll()
            for item in due { item() }
        }
    }

    @MainActor final class EventLog {
        private(set) var events: [Event] = []
        lazy var sink = EventSink { [self] event in events.append(event) }

        /// Every `trackpadScrolled` travel, in order.
        var travels: [Double] {
            events.compactMap { if case .trackpadScrolled(let d) = $0 { return d }; return nil }
        }

        var lift: Double? {
            for e in events { if case .trackpadScrollEnded(let v) = e { return v } }
            return nil
        }

        var began: Int {
            events.filter { if case .trackpadScrollBegan = $0 { return true }; return false }.count
        }
    }

    /// Three fingers whose mean sits at `(x, y)`, spread so no single contact is the mean.
    static func frame(_ x: Double, _ y: Double = 0.5, at time: Double) -> TouchSample {
        TouchSample(contacts: [Point(x: x - 0.05, y: y),
                               Point(x: x, y: y + 0.02),
                               Point(x: x + 0.05, y: y - 0.02)],
                    time: time)
    }

    static func lifted(at time: Double) -> TouchSample {
        TouchSample(contacts: [], time: time)
    }

    @MainActor struct Rig {
        let tapper = FakeTapper()
        let scheduler = ManualScheduler()
        let log = EventLog()
        let recognizer: GestureRecognizer

        init() {
            recognizer = GestureRecognizer(tapper: tapper, scheduler: scheduler, sink: log.sink)
            recognizer.observe(true)
        }

        @MainActor func swipe(_ xs: [Double], from t: Double = 0, step: Double = 0.008) {
            for (i, x) in xs.enumerated() { tapper.send(frame(x, at: t + Double(i) * step)) }
        }
    }

    // Committing (once, per episode)

    @Test func aHorizontalSwipeCommitsAndOpensTheSession() {
        let rig = Rig()
        rig.swipe([0.5, 0.505, 0.52, 0.55])
        #expect(rig.log.began == 1)
    }

    @Test func aRestingHandCommitsToNothing() {
        let rig = Rig()
        // Jitter well under the threshold, for a good long while.
        rig.swipe((0..<40).map { 0.5 + Double($0 % 3) * 0.001 })
        #expect(rig.log.events.isEmpty)
    }

    @Test func aVerticalSwipeLatchesTheEpisodeDead() {
        let rig = Rig()
        // Up first, then a long horizontal run: a diagonal that starts upward must not become a scroll
        // halfway through.
        for (i, y) in [0.5, 0.52, 0.56, 0.60].enumerated() {
            rig.tapper.send(Self.frame(0.5, y, at: Double(i) * 0.008))
        }
        rig.swipe([0.5, 0.6, 0.7, 0.8], from: 0.1)
        #expect(rig.log.events.isEmpty)
    }

    @Test func aDiagonalCommitsToNeitherUntilOneAxisDominates() {
        let rig = Rig()
        // 45°, so neither axis clears 1.5× the other.
        for (i, d) in [0.0, 0.02, 0.04, 0.06].enumerated() {
            rig.tapper.send(Self.frame(0.5 + d, 0.5 + d, at: Double(i) * 0.008))
        }
        #expect(rig.log.events.isEmpty)
    }

    @Test func liftingAFingerEndsTheEpisodeWithoutOneCommitted() {
        let rig = Rig()
        rig.swipe([0.5, 0.502])
        rig.tapper.send(TouchSample(contacts: [Point(x: 0.5, y: 0.5)], time: 0.1))
        #expect(rig.log.events.isEmpty)
        // …and the next episode is a fresh one.
        rig.swipe([0.5, 0.52, 0.55], from: 0.2)
        #expect(rig.log.began == 1)
    }

    @Test func onlyThreeFingersCount() {
        let rig = Rig()
        for (i, x) in [0.3, 0.4, 0.5, 0.6].enumerated() {
            rig.tapper.send(TouchSample(contacts: [Point(x: x, y: 0.5), Point(x: x + 0.1, y: 0.5)],
                                        time: Double(i) * 0.008))
        }
        #expect(rig.log.events.isEmpty)
    }

    // Draining (one write per painted frame, measured from the origin)

    @Test func theFirstDrainCarriesTheTravelFromBeforeTheCommit() {
        let rig = Rig()
        rig.swipe([0.5, 0.505, 0.52, 0.55])       // committed at 0.52; total travel 0.05
        rig.recognizer.drain()
        #expect(rig.log.travels.count == 1)
        #expect(abs((rig.log.travels[0]) - 0.05) < 1e-9)
    }

    @Test func aStillFingerDrainsNothingAtAll() {
        let rig = Rig()
        rig.swipe([0.5, 0.55])
        rig.recognizer.drain()
        #expect(rig.log.travels.count == 1)
        rig.recognizer.drain()
        rig.recognizer.drain()
        #expect(rig.log.travels.count == 1)       // nothing moved, so nothing entered the pump
    }

    @Test func everySampleBetweenTwoFramesArrivesAsOneEvent() {
        let rig = Rig()
        rig.swipe([0.5, 0.55])
        rig.recognizer.drain()
        rig.swipe([0.56, 0.57, 0.58, 0.59], from: 0.1)
        rig.recognizer.drain()
        #expect(rig.log.travels.count == 2)
        #expect(abs(rig.log.travels[1] - 0.04) < 1e-9)
    }

    @Test func theTravelIsTheSumOfEveryDrain() {
        let rig = Rig()
        rig.swipe([0.2, 0.3])
        rig.recognizer.drain()
        rig.swipe([0.4, 0.5, 0.6], from: 0.1)
        rig.recognizer.drain()
        rig.tapper.send(Self.lifted(at: 0.2))
        #expect(abs(rig.log.travels.reduce(0, +) - 0.4) < 1e-9)
    }

    // The lift

    @Test func theResidualTravelIsDispatchedAheadOfTheLift() {
        let rig = Rig()
        rig.swipe([0.5, 0.6])
        rig.recognizer.drain()
        rig.swipe([0.65], from: 0.1)              // never drained — the fingers left first
        rig.tapper.send(Self.lifted(at: 0.11))

        #expect(abs(rig.log.travels.reduce(0, +) - 0.15) < 1e-9)
        // Order matters: the projection starts from where the fingers actually left the strip.
        if case .trackpadScrolled = rig.log.events[rig.log.events.count - 2] {} else {
            Issue.record("the residual travel should be the event before the lift")
        }
        #expect(rig.log.lift != nil)
    }

    @Test func velocityIsSmoothedOverTheTrailingSamples() {
        let rig = Rig()
        // 0.02 of pad every 8 ms — 2.5 pads per second, held steady, then let go on the next frame.
        rig.swipe((0..<10).map { 0.2 + Double($0) * 0.02 })
        rig.tapper.send(Self.lifted(at: 0.08))
        let v = try! #require(rig.log.lift)
        #expect(abs(v - 2.5) < 0.2)
    }

    @Test func aHandThatStoppedBeforeLettingGoReadsAsTheStopItWas() {
        let rig = Rig()
        rig.swipe((0..<10).map { 0.2 + Double($0) * 0.02 })
        // …and then held still for a third of a second before lifting.
        rig.tapper.send(Self.lifted(at: 0.4))
        let v = try! #require(rig.log.lift)
        #expect(abs(v) < 0.6)
    }

    @Test func anEpisodeThatNeverCommittedReportsNoLift() {
        let rig = Rig()
        rig.swipe([0.5, 0.502])
        rig.tapper.send(Self.lifted(at: 0.1))
        #expect(rig.log.lift == nil)
    }

    // The watchdog (no state without an exit)

    @Test func silenceWithACommittedEpisodeSynthesizesALift() {
        let rig = Rig()
        rig.swipe([0.5, 0.6])
        #expect(rig.log.began == 1)
        rig.scheduler.fire()                      // samples arrived in this window; look again
        #expect(rig.log.lift == nil)
        rig.scheduler.fire()                      // …and this one was genuinely silent
        #expect(rig.log.lift == 0)                // nothing saw a lift, so no momentum is claimed
    }

    @Test func aLivePadRearmsTheWatchdogForAsLongAsItStaysAlive() {
        let rig = Rig()
        rig.swipe([0.5, 0.6])
        for i in 1...4 {
            rig.scheduler.fire()
            #expect(rig.log.lift == nil)
            #expect(rig.scheduler.pending == 1)   // one timer at a time, however long the gesture runs
            rig.swipe([0.6 + Double(i) * 0.01], from: Double(i) * 0.1)
        }
        rig.scheduler.fire()
        #expect(rig.log.lift == nil)
        rig.scheduler.fire()
        #expect(rig.log.lift == 0)
    }

    @Test func theWatchdogIsSilentForAnUncommittedEpisode() {
        let rig = Rig()
        rig.swipe([0.5, 0.502])
        rig.scheduler.fire()
        #expect(rig.log.events.isEmpty)
    }

    // Installation

    @Test func theTapIsNotInstalledUntilSomethingWantsIt() {
        let tapper = FakeTapper()
        let recognizer = GestureRecognizer(tapper: tapper, scheduler: ManualScheduler(),
                                           sink: EventLog().sink)
        #expect(!tapper.isInstalled)
        #expect(recognizer.observe(true))
        #expect(tapper.isInstalled)
        recognizer.observe(false)
        #expect(!tapper.isInstalled)
    }

    @Test func aTapTheSystemRefusesIsReportedRatherThanAssumed() {
        let tapper = FakeTapper()
        tapper.isAvailable = false
        let recognizer = GestureRecognizer(tapper: tapper, scheduler: ManualScheduler(),
                                           sink: EventLog().sink)
        #expect(!recognizer.observe(true))
        #expect(!tapper.isInstalled)
    }

    @Test func takingTheTapDownEndsAnOpenGesture() {
        let rig = Rig()
        rig.swipe([0.5, 0.6])
        // No more samples are coming, so no lift report ever would — the latch has to be let go of.
        rig.recognizer.observe(false)
        #expect(rig.log.lift == 0)
    }

    @Test func stoppingIsIdempotentAndReleasesTheTap() {
        let rig = Rig()
        rig.recognizer.stop()
        rig.recognizer.stop()
        #expect(!rig.tapper.isInstalled)
    }
}
