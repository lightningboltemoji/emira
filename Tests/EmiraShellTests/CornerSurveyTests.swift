import CoreGraphics
import Foundation
import Testing
@testable import EmiraShell

// The radii of the windows no cover films: one capture each, never while the capture plane is busy, and
// forgotten with the number that named them.

@Suite @MainActor struct CornerSurveyTests {

    typealias Scheduler = ScrimPlaneTests.ManualScheduler

    /// A `CornerMeter` that holds every measurement until a test answers it.
    final class Meter: CornerMeter {
        private(set) var asked: [CGWindowID] = []
        private var waiting: [@MainActor (Double?) -> Void] = []

        func measure(_ number: CGWindowID, then: @escaping @MainActor (Double?) -> Void) {
            asked.append(number)
            waiting.append(then)
        }

        /// Answer the oldest measurement still in flight.
        func answer(_ radius: Double?) { waiting.removeFirst()(radius) }
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
        #expect(survey.radius(of: 7) == 17.15)
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
        #expect(survey.radius(of: 7) == 17.15)
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

        #expect(survey.radius(of: 7) == nil)
        #expect(meter.asked == [7, 8], "9 left the screen before its turn")
    }
}
