import CoreGraphics
import Foundation
import Testing
@testable import EmiraShell

// The radii of the windows no cover has filmed at rest: filmed until one is, never while the capture plane
// is busy, and forgotten with the number that named them.

@Suite @MainActor struct CornerSurveyTests {

    typealias Scheduler = ScrimPlaneTests.ManualScheduler

    /// A `CornerMeter` that holds every measurement until a test answers it.
    final class Meter: CornerMeter {
        private(set) var asked: [CGWindowID] = []
        private var waiting: [@MainActor (CornerReading?) -> Void] = []

        func measure(_ number: CGWindowID, then: @escaping @MainActor (CornerReading?) -> Void) {
            asked.append(number)
            waiting.append(then)
        }

        /// Answer the oldest measurement still in flight, read off the window at rest unless it says not.
        func answer(_ radius: Double?, atRest: Bool = true) {
            waiting.removeFirst()(radius.map { CornerReading(radius: $0, isAtRest: atRest) })
        }
    }

    static func survey(idle: Bool = true) -> (CornerSurvey, Meter, Scheduler) {
        let meter = Meter(), scheduler = Scheduler()
        let survey = CornerSurvey(meter: meter, scheduler: scheduler)
        survey.isIdle = { idle }
        return (survey, meter, scheduler)
    }

    @Test func eachWindowIsMeasuredOnceAndItsAnswerKept() {
        let (survey, meter, _) = Self.survey()
        var measured = 0
        survey.onMeasured = { measured += 1 }

        survey.survey([7])
        meter.answer(17.15)
        survey.survey([7])

        #expect(meter.asked == [7])
        #expect(survey.corner(of: 7) == CornerReading(radius: 17.15, isAtRest: true))
        #expect(measured == 1)
    }

    /// The window server takes one screenshot at a time, so two in flight would only slow both.
    @Test func measurementsAreTakenOneAtATime() {
        let (survey, meter, _) = Self.survey()
        survey.survey([7, 8])
        #expect(meter.asked == [7])

        meter.answer(17.15)
        #expect(meter.asked == [7, 8])
    }

    /// A window caught opening, or before its app drew it, says nothing — so it is filmed again after a
    /// pause rather than at the next cut, and left alone once it has had `attemptLimit` films.
    @Test func anUnreadableWindowIsFilmedAgainAfterAPauseAndThenLeft() {
        let (survey, meter, scheduler) = Self.survey()
        var measured = 0
        survey.onMeasured = { measured += 1 }

        survey.survey([7])
        meter.answer(nil)
        survey.survey([7])
        #expect(meter.asked == [7], "resting: the next cut does not film it again")

        for _ in 1..<CornerSurvey.attemptLimit {
            scheduler.fire()
            meter.answer(nil)
        }
        #expect(meter.asked.count == CornerSurvey.attemptLimit)
        #expect(!scheduler.fire(), "nothing more is scheduled")
        survey.survey([7])
        #expect(meter.asked.count == CornerSurvey.attemptLimit)
        #expect(measured == 0)
    }

    @Test func aWindowReadOnASecondFilmIsMeasured() {
        let (survey, meter, scheduler) = Self.survey()
        survey.survey([7])
        meter.answer(nil)
        scheduler.fire()
        meter.answer(17.15)
        #expect(survey.corner(of: 7)?.radius == 17.15)
    }

    /// A window caught animating is near its corner: that reading is answered at once, and the window is
    /// filmed again after a pause until it is read at rest.
    @Test func aWindowCaughtAnimatingIsAnsweredAndFilmedAgain() {
        let (survey, meter, scheduler) = Self.survey()
        var measured = 0
        survey.onMeasured = { measured += 1 }

        survey.survey([7])
        meter.answer(16.93, atRest: false)
        #expect(survey.corner(of: 7) == CornerReading(radius: 16.93, isAtRest: false))
        #expect(measured == 1)
        survey.survey([7])
        #expect(meter.asked == [7], "resting: the next cut does not film it again")

        scheduler.fire()
        meter.answer(17.15)
        #expect(survey.corner(of: 7) == CornerReading(radius: 17.15, isAtRest: true))
        #expect(measured == 2)
        survey.survey([7])
        #expect(meter.asked == [7, 7], "read at rest: done")
        #expect(!scheduler.fire())
    }

    /// A reading coming to rest outranks a cover's taken animating, so it cuts again even at the radius the
    /// survey already had — or the mask keeps the cover's.
    @Test func aReadingComingToRestAtTheSameRadiusCutsAgain() {
        let (survey, meter, scheduler) = Self.survey()
        var measured = 0
        survey.onMeasured = { measured += 1 }

        survey.survey([7])
        meter.answer(17.1459, atRest: false)
        scheduler.fire()
        meter.answer(17.1459)

        #expect(survey.corner(of: 7) == CornerReading(radius: 17.1459, isAtRest: true))
        #expect(measured == 2)
    }

    /// Out of films, a window keeps the nearest reading it was given; a film that could not say takes
    /// nothing away, and one that reads the same cuts nothing again.
    @Test func aWindowNeverCaughtAtRestKeepsWhatItWasRead() {
        let (survey, meter, scheduler) = Self.survey()
        var measured = 0
        survey.onMeasured = { measured += 1 }

        survey.survey([7])
        meter.answer(16.93, atRest: false)
        scheduler.fire()
        meter.answer(nil)
        scheduler.fire()
        meter.answer(16.93, atRest: false)

        #expect(meter.asked.count == CornerSurvey.attemptLimit)
        #expect(!scheduler.fire(), "nothing more is scheduled")
        #expect(survey.corner(of: 7) == CornerReading(radius: 16.93, isAtRest: false))
        #expect(measured == 1)
    }

    /// A cover's batch is the latency anyone feels: a busy capture plane takes nothing, and the survey
    /// looks again on its own or the moment a cover comes down.
    @Test func aBusyCapturePlaneIsWaitedOut() {
        var idle = false
        let (survey, meter, scheduler) = Self.survey()
        survey.isIdle = { idle }

        survey.survey([7])
        #expect(meter.asked.isEmpty)
        scheduler.fire()
        #expect(meter.asked.isEmpty, "still busy")

        idle = true
        scheduler.fire()
        #expect(meter.asked == [7])
    }

    @Test func aCoverComingDownResumesTheSurveyAtOnce() {
        var idle = false
        let (survey, meter, _) = Self.survey()
        survey.isIdle = { idle }

        survey.survey([7])
        idle = true
        survey.resume()
        #expect(meter.asked == [7])
    }

    /// A number is reused once its window is gone, so an answer outlives neither the window nor a request
    /// for it.
    @Test func numbersNoLongerOnScreenAreForgotten() {
        let (survey, meter, _) = Self.survey()
        survey.survey([7])
        meter.answer(17.15)
        survey.survey([8, 9])                   // 8 in flight, 9 queued

        survey.retain([8])
        meter.answer(8)

        #expect(survey.corner(of: 7) == nil)
        #expect(meter.asked == [7, 8], "9 left the screen before its turn")
    }
}
