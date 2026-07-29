import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The record that tells emira's own focus echo from the user's Cmd-Tab. Everything here is about one
// asymmetry: a focus we asked for comes back to us by a route with no ordering in it, so "we asked for
// this" and "we asked for this *most recently*" are different questions and each has its own caller.

@Suite @MainActor struct FocusIntentTests {

    /// Records what was scheduled and fires it on demand — the grace, made explicit.
    final class ManualScheduler: DelayScheduler {
        private(set) var delays: [TimeInterval] = []
        private var work: [@MainActor () -> Void] = []

        func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            delays.append(seconds)
            self.work.append(work)
        }

        func fire() {
            let due = work
            work.removeAll()
            for item in due { item() }
        }

        /// Run only the deadline armed first — how a burst's timers actually arrive.
        func fireOldest() {
            guard !work.isEmpty else { return }
            work.removeFirst()()
        }
    }

    static func intent(_ scheduler: ManualScheduler) -> FocusIntent {
        FocusIntent(scheduler: scheduler, grace: 0.5)
    }

    static let w1 = WindowId(1)
    static let w2 = WindowId(2)
    static let w3 = WindowId(3)

    // MARK: - isCurrent: which activation is still wanted

    @Test func aTicketIsCurrentUntilSomethingNewerIsAskedFor() {
        let intent = Self.intent(ManualScheduler())
        let first = intent.request(Self.w1)
        #expect(intent.isCurrent(first))

        let second = intent.request(Self.w2)
        #expect(!intent.isCurrent(first))   // the slow app's activation is dropped
        #expect(intent.isCurrent(second))
    }

    @Test func aTicketStaysCurrentAfterItsOwnReportArrives() {
        // The write's completion and its echo take two different hops onto the main actor and either can
        // land first. If a report retired the ticket, an echo that beat the completion would cancel the
        // activation and the app would never come forward.
        let intent = Self.intent(ManualScheduler())
        let ticket = intent.request(Self.w1)
        #expect(intent.resolve(Self.w1) == .expected)
        #expect(intent.isCurrent(ticket))
    }

    @Test func aTicketStaysCurrentPastTheGrace() {
        // The grace expires the *record*, not the ordering. A request nothing superseded is still the
        // newest one, however long its lane took.
        let clock = ManualScheduler()
        let intent = Self.intent(clock)
        let ticket = intent.request(Self.w1)
        clock.fire()
        #expect(intent.isCurrent(ticket))
        #expect(intent.resolve(Self.w1) == .external)   // …but off the record, so no longer ours
    }

    // MARK: - resolve: which report is news

    @Test func aReportWithNothingOutstandingIsExternal() {
        let intent = Self.intent(ManualScheduler())
        #expect(intent.resolve(Self.w1) == .external)
    }

    @Test func theEchoOfTheNewestRequestIsExpected() {
        let intent = Self.intent(ManualScheduler())
        _ = intent.request(Self.w1)
        #expect(intent.resolve(Self.w1) == .expected)
    }

    @Test func theEchoOfASupersededRequestIsStale() {
        // The bug, in one line: two presses, and the first one's news arrives second.
        let intent = Self.intent(ManualScheduler())
        _ = intent.request(Self.w1)
        _ = intent.request(Self.w2)
        #expect(intent.resolve(Self.w1) == .stale)
    }

    @Test func aWindowNobodyAskedForIsExternalEvenMidBurst() {
        // The suppression is per window, not a blanket deafness for the length of the grace: a Cmd-Tab
        // landing between two focus presses is still the user, and still reveals.
        let intent = Self.intent(ManualScheduler())
        _ = intent.request(Self.w1)
        _ = intent.request(Self.w2)
        #expect(intent.resolve(Self.w3) == .external)
    }

    @Test func nilIsAlwaysExternal() {
        // It names no window, so it cannot be an echo of one we asked for — and swallowing it would
        // leave the core's focus on a window the user has stopped typing into.
        let intent = Self.intent(ManualScheduler())
        _ = intent.request(Self.w1)
        #expect(intent.resolve(nil) == .external)
    }

    @Test func aStaleEchoStaysStaleForARepeatReport() {
        // One request can produce two reports — the app's own notification and the read `NSWorkspace`
        // activation costs — so a verdict that consumed its entry would let the second one through.
        let intent = Self.intent(ManualScheduler())
        _ = intent.request(Self.w1)
        _ = intent.request(Self.w2)
        #expect(intent.resolve(Self.w1) == .stale)
        #expect(intent.resolve(Self.w1) == .stale)
    }

    // MARK: - The grace

    @Test func theRecordClearsAfterTheGraceSoRealFocusIsNeverLostForGood() {
        let clock = ManualScheduler()
        let intent = Self.intent(clock)
        _ = intent.request(Self.w1)
        _ = intent.request(Self.w2)
        #expect(intent.resolve(Self.w1) == .stale)

        clock.fire()

        // A Cmd-Tab back to `w1` a moment later is the user, and reaches.
        #expect(intent.resolve(Self.w1) == .external)
        #expect(intent.resolve(Self.w2) == .external)
    }

    @Test func aSupersededDeadlineDoesNotClearALiveRecord() {
        // Every request arms its own deadline and `DelayScheduler` has no cancellation, so the first
        // press's timer fires while the second press is still the one being waited on. The generation
        // check is the whole of what stops it wiping a record still in use.
        let clock = ManualScheduler()
        let intent = Self.intent(clock)
        _ = intent.request(Self.w1)
        _ = intent.request(Self.w2)

        clock.fireOldest()

        #expect(intent.resolve(Self.w1) == .stale, "the record outlived a deadline it had superseded")
        #expect(intent.resolve(Self.w2) == .expected)

        clock.fireOldest()      // the second press's own deadline, the one that matches
        #expect(intent.resolve(Self.w2) == .external)
    }

    @Test func eachRequestArmsExactlyOneDeadline() {
        let clock = ManualScheduler()
        let intent = Self.intent(clock)
        _ = intent.request(Self.w1)
        _ = intent.request(Self.w2)
        #expect(clock.delays == [0.5, 0.5])
    }
}
