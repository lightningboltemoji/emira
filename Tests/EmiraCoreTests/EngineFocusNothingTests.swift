import Foundation
import Testing
@testable import EmiraCore

// `Effect.focusNothing`: the keyboard taken off a window once a verb leaves focus on nothing. Which
// events send it is the whole of the rule — a verb's, and never a departure's or a report's.

@Suite struct EngineFocusNothingTests {

    private let display = MonitorId(1)
    private let empty = WorkspaceName("2")!

    private func world(_ count: UInt64) -> State {
        EngineFix.world(count, config: EngineFix.halfWidthSnap)
    }

    private func focusWorkspace(_ name: WorkspaceName) -> Event {
        .command(.focusWorkspace(.name(name)))
    }

    /// The displays a stream took the keyboard off every window on.
    private func nothing(in fx: [Effect]) -> [MonitorId] {
        fx.compactMap { if case .focusNothing(let monitor) = $0 { return monitor } else { return nil } }
    }

    /// The case as reported: macOS still has the window the switch left focused, now parked.
    @Test func aSwitchToAnEmptyWorkspaceTakesTheKeyboardOffTheWindowItLeft() {
        let (after, fx) = EngineFix.run(world(2), [focusWorkspace(empty)])
        #expect(after.world.focusedWindow == nil)
        #expect(nothing(in: fx) == [display])
    }

    @Test func sendingTheLastWindowAwayTakesTheKeyboardOffIt() {
        let (after, fx) = EngineFix.run(world(1), [.command(.moveToWorkspace(.name(empty)))])
        #expect(after.world.focusedWindow == nil)
        #expect(nothing(in: fx) == [display])
    }

    /// Once is enough: between two empty workspaces the keyboard is already on nothing.
    @Test func fromNothingToNothingAsksForNothingAgain() {
        let s = EngineFix.run(world(1), [focusWorkspace(empty)]).0
        let (_, fx) = EngineFix.run(s, [focusWorkspace(WorkspaceName("3")!)])
        #expect(nothing(in: fx).isEmpty)
    }

    @Test func aSwitchOntoAWindowFocusesThatWindowInstead() {
        let s = EngineFix.run(world(1), [focusWorkspace(empty)]).0
        let (_, fx) = EngineFix.run(s, [focusWorkspace(.first)])
        #expect(nothing(in: fx).isEmpty)
        #expect(fx.contains(.focus(WindowId(1))))
    }

    /// A departure is macOS's to answer. A close hands the keyboard to the app's next window, and a quit
    /// or ⌘H — which reach the core as the same departures — to another app, whose report is on its way.
    @Test func aDepartureLeavesTheKeyboardToMacOS() {
        for departure in [Event.windowDestroyed(WindowId(1)), .windowMinimized(WindowId(1))] {
            let (after, fx) = EngineFix.run(world(1), [departure])
            #expect(after.world.focusedWindow == nil)
            #expect(nothing(in: fx).isEmpty, "\(departure) sent \(fx)")
        }
    }

    /// A report of focus on nothing is focus already on something emira does not manage — Spotlight, a
    /// menu bar app — and taking it would break that.
    @Test func aReportOfNothingIsNotAnsweredWithNothing() {
        let (after, fx) = Engine.reduce(world(1), .focusChanged(nil, origin: .system))
        #expect(after.world.focusedWindow == nil)
        #expect(nothing(in: fx).isEmpty)
    }
}
