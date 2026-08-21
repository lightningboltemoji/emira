import Foundation
import Testing
@testable import EmiraCore

// What a reconfiguration does to **what is on screen** — as distinct from `MonitorTests` (which
// addresses each display holds), `MonitorCommandTests` (the verbs that name one) and
// `MonitorSessionTests` (which screens raise a cover).
//
// Two rules meet here and they are deliberately not the same rule:
//
//  · **The main display carries the user's workspace.** macOS's main display is the user's own
//    statement about which screen is theirs, and it moves in the *same* report as the arrival or
//    departure that caused it — the window server sends `SET-MAIN` in one flag word with
//    `added`/`removed`, so there is no window in which the two disagree.
//  · **A reconfiguration may not leave focus on a strip nobody is showing** (`PRINCIPLES` §4). Total
//    where the first is deliberately narrow: it is what catches a display departing that never held
//    the role.
//
// Snapping throughout (`transitionMode: .off`): these are about *where* things end up.

@Suite struct MonitorReconfigurationTests {

    private let laptop = MonitorId(1), studio = MonitorId(2), third = MonitorId(3)
    private let one = WorkspaceName.first

    private func info(_ id: MonitorId, x: Double = 0, main: Bool = false) -> MonitorInfo {
        MonitorInfo(id: id, frame: Rect(x: x, y: 0, width: 1000, height: 800), isMain: main)
    }

    /// The laptop alone, main, with `count` windows on the launch address.
    private func laptopOnly(_ count: UInt64 = 2) -> State {
        var s = State(config: Config(transitionMode: .off))
        (s, _) = Engine.reduce(s, .screensChanged([info(laptop, main: true)]))
        for raw in 1...max(count, 1) where count > 0 {
            let (next, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(raw)))
            s = EngineFix.settle(next, fx)
        }
        return s
    }

    private func report(_ s: State, _ infos: [MonitorInfo]) -> State {
        let (next, fx) = Engine.reduce(s, .screensChanged(infos))
        return EngineFix.settle(next, fx)
    }

    /// Whether emira's focus is on a window the user can actually see — §4's promise, stated as a
    /// predicate because it is the thing a reconfiguration was quietly breaking.
    private func focusIsVisible(_ s: State) -> Bool {
        guard let focused = s.world.focusedWindow else { return true }
        return s.monitors.shownWorkspaces.contains { s.workspaces[$0].columnIndex(ofWindow: focused) != nil }
    }

    // The main display carrying the workspace

    /// Working on the laptop, dock a Studio that macOS makes main, then close the lid. The workspace
    /// the user is on is in front of them at every step.
    @Test func dockingAMainDisplayCarriesTheWorkspaceAndTheLidCloseKeepsIt() {
        var s = laptopOnly()
        #expect(s.monitors.shown == one)

        s = report(s, [info(studio, main: true), info(laptop, x: 1000)])
        #expect(s.monitors.shown(on: studio) == one, "the main display carries the workspace")
        #expect(s.monitors.focused == studio, "…and the acting monitor follows the role")
        #expect(s.monitors.shown(on: laptop) != one, "…and the laptop took what the studio had")
        #expect(focusIsVisible(s))

        s = report(s, [info(studio, main: true)])
        #expect(s.monitors.shown == one)
        #expect(focusIsVisible(s))
    }

    /// A display that arrives **without** taking the role leaves the desktop alone. The rule is keyed
    /// on main moving, not on a display arriving — otherwise plugging in a reference monitor would
    /// drag the user's strip onto it.
    @Test func aDisplayArrivingWithoutTheRoleChangesNothing() {
        var s = laptopOnly()
        s = report(s, [info(laptop, main: true), info(studio, x: 1000)])

        #expect(s.monitors.shown(on: laptop) == one, "undisturbed")
        #expect(s.monitors.focused == laptop, "focus does not follow a new display")
        #expect(s.monitors.shown(on: studio) != one)
    }

    /// The role moving is only the user's business if they were **on** the display that held it. A
    /// menu bar arriving somewhere the user is not working says nothing about where they are, and
    /// hauling a third display's strip across the desktop is not what dragging it asked for.
    @Test func theRoleMovingElsewhereLeavesAUserWorkingOnAThirdDisplayAlone() {
        var s = laptopOnly()
        s = report(s, [info(laptop, main: true), info(studio, x: 1000), info(third, x: 2000)])
        let (moved, fx) = Engine.reduce(s, .command(.focusMonitor(.index(3))))
        s = EngineFix.settle(moved, fx)
        let working = s.monitors.shown
        #expect(s.monitors.focused == third)

        // The role moves laptop → studio; the user is on neither.
        s = report(s, [info(laptop, x: 0), info(studio, x: 1000, main: true), info(third, x: 2000)])
        #expect(s.monitors.focused == third, "the user stays where they were")
        #expect(s.monitors.shown(on: third) == working)
    }

    /// A pure arrangement change — the menu bar dragged between two attached displays, no hardware
    /// moving — is the same rule, and the displays **trade**.
    @Test func draggingTheMenuBarBetweenAttachedDisplaysTradesTheirAddresses() {
        var s = laptopOnly()
        s = report(s, [info(laptop, main: true), info(studio, x: 1000)])
        let here = s.monitors.shown(on: laptop)!
        let there = s.monitors.shown(on: studio)!

        s = report(s, [info(laptop), info(studio, x: 1000, main: true)])
        #expect(s.monitors.shown(on: studio) == here)
        #expect(s.monitors.shown(on: laptop) == there, "a trade, not a fallback")
        #expect(s.monitors.focused == studio)
    }

    /// The trade leaves nothing behind: one address per display, and no spare claimed on the way.
    @Test func theTradeClaimsNoThirdAddress() {
        var s = laptopOnly()
        s = report(s, [info(studio, main: true), info(laptop, x: 1000)])

        let owned = s.monitors.ids.flatMap { s.monitors.owned(of: $0) }
        #expect(Set(owned).count == owned.count, "ownership stays disjoint")
        #expect(owned.count == 2, "one address per display, and no spare: \(owned)")
    }

    /// macOS repeats a reconfiguration report two or three times as a display settles, the last of them
    /// seconds late. Every repeat must change nothing.
    @Test func repeatedReportsAreIdempotent() {
        var s = laptopOnly()
        let docked = [info(studio, main: true), info(laptop, x: 1000)]
        s = report(s, docked)
        let after = (s.monitors.focused, s.monitors.shown,
                     s.monitors.shown(on: studio), s.monitors.shown(on: laptop))

        for _ in 0..<3 { s = report(s, docked) }
        #expect(s.monitors.focused == after.0)
        #expect(s.monitors.shown == after.1)
        #expect(s.monitors.shown(on: studio) == after.2)
        #expect(s.monitors.shown(on: laptop) == after.3)
    }

    // The reveal that makes it total

    /// **Unplugging a display that never held the role**, while working on it. Main does not move, so
    /// the rule above is silent — and the strip the user was on would be re-homed onto the survivor as
    /// *owned* and then parked. §4 is what says it cannot be.
    @Test func unpluggingANonMainDisplayYouAreWorkingOnBringsTheStripWithIt() {
        var s = laptopOnly()
        s = report(s, [info(laptop, main: true), info(studio, x: 1000)])
        // Go to the studio and open a window there, so focus genuinely lives on its strip.
        let (moved, fx) = Engine.reduce(s, .command(.focusMonitor(.index(2))))
        s = EngineFix.settle(moved, fx)
        let (opened, fx2) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(9)))
        s = EngineFix.settle(opened, fx2)
        let working = s.monitors.shown
        #expect(working != one)
        #expect(focusIsVisible(s))

        s = report(s, [info(laptop, main: true)])
        #expect(s.monitors.shown == working, "the strip the user was on comes with them")
        #expect(focusIsVisible(s), "focus is never left on something the user cannot see")
    }

    /// The same promise stated over the whole desktop rather than one sequence: focus is on a visible
    /// window after every step of a dock/undock cycle.
    @Test func focusStaysVisibleAcrossADockAndUndockCycle() {
        var s = laptopOnly(3)
        let sequence: [[MonitorInfo]] = [
            [info(studio, main: true), info(laptop, x: 1000)],
            [info(studio, main: true)],
            [info(studio, main: true), info(laptop, x: 1000)],
            [info(laptop, main: true)],
            [info(laptop, main: true), info(studio, x: 1000)],
        ]
        for (step, infos) in sequence.enumerated() {
            s = report(s, infos)
            #expect(focusIsVisible(s), "step \(step) left focus on a window nobody is showing")
        }
    }

    /// With **no display attached** the reveal is silent: there is no screen for it to happen on, and
    /// `Monitors.unattached` is the sole authority on what the desktop is showing while nothing is.
    /// A switch here would overwrite the address it went to the trouble of choosing.
    @Test func aZeroDisplayReportLeavesTheUnattachedAddressAlone() {
        var s = laptopOnly()
        let watching = s.monitors.shown

        s = report(s, [])
        #expect(s.monitors.ids.isEmpty)
        #expect(s.monitors.shown == watching, "the desktop keeps what the user was looking at")

        s = report(s, [info(studio, main: true)])
        #expect(s.monitors.shown == watching, "…and whichever display returns shows it")
        #expect(focusIsVisible(s))
    }

    // The acting monitor and the focused window, kept in agreement

    /// **The pointer crossing onto another screen is the user moving to it.** Without this the
    /// crossing lands `World.focusedWindow` on the far screen while `Monitors.focused` stays behind,
    /// so the next verb acts on the display just left.
    @Test func focusFollowsMouseAcrossDisplaysMovesTheActingMonitor() {
        var s = State(config: Config(focusFollowsMouse: true, transitionMode: .off))
        (s, _) = Engine.reduce(s, .screensChanged([info(laptop, main: true), info(studio, x: 1000)]))
        let (first, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(1)))
        s = EngineFix.settle(first, fx)
        // A window on the studio's strip, reached by sending one there.
        let there = s.monitors.shown(on: studio)!
        let (sent, fx2) = Engine.reduce(s, .command(.moveToWorkspace(.name(there))))
        s = EngineFix.settle(sent, fx2)
        let (opened, fx3) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(2)))
        s = EngineFix.settle(opened, fx3)
        #expect(s.monitors.focused == laptop)

        let far = try! #require(s.workspaces[there].allWindowIds.first)
        let (crossed, fx4) = Engine.reduce(s, .pointerEntered(far))
        s = EngineFix.settle(crossed, fx4)

        #expect(s.world.focusedWindow == far)
        #expect(s.monitors.focused == studio, "the acting monitor came with the pointer")
        #expect(s.monitors.shown == there)
    }
}

// The container's own half of the trade.
@Suite struct MonitorExchangeTests {

    private let a = MonitorId(1), b = MonitorId(2)
    private func info(_ id: MonitorId, x: Double = 0) -> MonitorInfo {
        MonitorInfo(id: id, frame: Rect(x: x, y: 0, width: 1000, height: 800))
    }

    @Test func exchangeTradesTwoDisplaysAddressesWithoutAFallback() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [.first], infos: [info(a), info(b, x: 1000)])
        let (here, there) = (monitors.shown(on: a)!, monitors.shown(on: b)!)
        #expect(here != there)

        monitors.exchange(here, to: b, with: a)
        #expect(monitors.shown(on: b) == here)
        #expect(monitors.shown(on: a) == there)
        #expect(monitors.owned(of: b) == [here])
        #expect(monitors.owned(of: a) == [there], "no third address claimed on the way")
    }

    /// Invariant 1 survives it: a display shows only what it owns, on both sides of the trade.
    @Test func exchangeKeepsShownInsideOwned() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [.first], infos: [info(a), info(b, x: 1000)])
        monitors.exchange(monitors.shown(on: a)!, to: b, with: a)
        for id in monitors.ids {
            #expect(monitors.owned(of: id).contains(monitors.shown(on: id)!))
        }
    }

    /// A donor that is not attached has nothing to trade — the departed-main case, which the caller
    /// answers with a plain `show` instead.
    @Test func exchangeWithADetachedDonorIsSilent() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [.first], infos: [info(b)])
        let before = monitors.shown(on: b)
        monitors.exchange(WorkspaceName("7")!, to: b, with: a)
        #expect(monitors.shown(on: b) == before)
    }
}
