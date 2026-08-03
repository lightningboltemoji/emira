import Foundation
import Testing
@testable import EmiraCore

// The displays as containers of workspaces. Everything here is provably inert while there is one
// display — an address orphaned by a departure, `shown` claiming what it shows, and the assignments a
// lid close has to survive are all silent failures on one screen, and this is where they can be proved.

@Suite struct MonitorsTests {

    private let m1 = MonitorId(1), m2 = MonitorId(2), m3 = MonitorId(3)
    private let a = WorkspaceName.first, b = WorkspaceName("3")!, c = WorkspaceName("z")!

    private func info(_ id: MonitorId, x: Double = 0) -> MonitorInfo {
        MonitorInfo(id: id, frame: Rect(x: x, y: 0, width: 1000, height: 800))
    }

    // Before any display exists

    /// The launch state has no display and still answers, because `State.layout` projects `shown` and
    /// every verb reads it — a `nil` here would be a crash at boot rather than the no-op `metrics()`
    /// already gives.
    @Test func theLaunchStateShowsTheFirstAddressWithNoDisplayAttached() {
        let monitors = Monitors()
        #expect(monitors.focused == nil)
        #expect(monitors.ids.isEmpty)
        #expect(monitors.shown == .first)
        #expect(monitors.owned == [.first])
        #expect(monitors.shownWorkspaces == [.first])
    }

    /// A workspace switch before the first `screensChanged` is an ordinary switch: the address is shown
    /// and claimed, and the display that arrives afterwards inherits both.
    @Test func aSwitchWithNoDisplayIsRememberedAndThenAdopted() {
        var monitors = Monitors()
        monitors.show(b, on: nil)
        #expect(monitors.shown == b)

        monitors.reconcile(materialized: [a, b], infos: [info(m1)])
        #expect(monitors.focused == m1)
        #expect(monitors.shown == b)                    // the arrival adopted what was on screen
        #expect(monitors.owned(of: m1) == [a, b])       // …and everything that had been assembled
    }

    // One display: the whole of phase 1's behaviour

    @Test func theFirstDisplayOwnsEveryMaterializedAddress() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [a, b, c], infos: [info(m1)])
        #expect(monitors.owned(of: m1) == [a, b, c])
        #expect(monitors.monitor(of: c) == m1)
        #expect(monitors.shown == a)
    }

    /// Invariant 2 repaired rather than asserted: an address materialized by a verb that never touched
    /// this container — `move-to-workspace` onto a fresh address — is claimed at the next reconcile.
    @Test func anAddressMaterializedElsewhereIsClaimedByTheActingMonitor() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [a], infos: [info(m1)])
        #expect(monitors.monitor(of: c) == nil)
        monitors.reconcile(materialized: [a, c], infos: [info(m1)])
        #expect(monitors.monitor(of: c) == m1)
    }

    /// Invariant 1: there is no way to move `shown` without moving `owned` with it, so a monitor
    /// showing an address it does not hold is unrepresentable rather than checked for.
    @Test func showingAnAddressClaimsIt() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [a], infos: [info(m1), info(m2, x: 1000)])
        let elsewhere = monitors.shown(on: m2)!
        #expect(monitors.monitor(of: elsewhere) == m2)

        monitors.show(elsewhere, on: m1)
        #expect(monitors.shown(on: m1) == elsewhere)
        #expect(monitors.monitor(of: elsewhere) == m1)          // taken from m2…
        #expect(!monitors.owned(of: m2).contains(elsewhere))
        // …and m2, having lost what it was showing, took something it can have instead.
        #expect(monitors.owned(of: m2).contains(monitors.shown(on: m2)!))
    }

    // Two displays

    /// An arriving display owns nothing, so it shows the lowest address nobody holds — it must not take
    /// the launch address out from under the display already showing it.
    @Test func anArrivingDisplayTakesAnAddressNobodyElseHolds() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [a, b], infos: [info(m1)])
        monitors.reconcile(materialized: [a, b], infos: [info(m1), info(m2, x: 1000)])

        #expect(monitors.shown(on: m1) == a)                    // undisturbed
        #expect(monitors.shown(on: m2) != a)
        #expect(monitors.shown(on: m2) != monitors.shown(on: m1))
        #expect(monitors.focused == m1)                         // focus does not follow a new display
    }

    /// Every record's `owned` is disjoint from every other's — the property `monitor(of:)` being a
    /// function rests on, and the one a naive "claim" would break silently.
    @Test func ownershipIsDisjointAcrossDisplays() {
        var monitors = Monitors()
        let names = [a, b, c, WorkspaceName("5")!, WorkspaceName("g")!]
        monitors.reconcile(materialized: names, infos: [info(m1), info(m2, x: 1000), info(m3, x: 2000)])
        monitors.show(c, on: m2)
        monitors.show(b, on: m3)
        monitors.show(names[3], on: m2)

        let all = monitors.ids.flatMap { monitors.owned(of: $0) }
        #expect(Set(all).count == all.count)
        for name in names { #expect(monitors.monitor(of: name) != nil, "\(name) is orphaned") }
    }

    /// The acting monitor accumulates every address it has ever shown, so the unassigned set runs out
    /// long before the address space does. A display left with nothing then takes an address another
    /// display owns but is not *looking at* — which is what makes invariant 1 hold at two displays and
    /// not merely at 36.
    @Test func aDisplayLeftWithNothingTakesAnAddressNobodyIsLookingAt() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [a], infos: [info(m1), info(m2, x: 1000)])
        monitors.focus(m1)
        for name in WorkspaceName.all { monitors.show(name, on: m1) }

        let stranded = monitors.record(m2)!
        #expect(stranded.owned.contains(stranded.shown))            // invariant 1, under starvation
        #expect(stranded.shown != monitors.shown(on: m1))
        // Taken from m1's back catalogue, not from what m1 is showing.
        #expect(!monitors.owned(of: m1).contains(stranded.shown))
    }

    /// `shownWorkspaces` is what `placementOrder(shown:)` is handed, so the acting monitor has to come
    /// first — that is what keeps the strip the user is looking at out of the high park ordinals.
    @Test func shownWorkspacesPutsTheActingMonitorFirst() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [a, b], infos: [info(m1), info(m2, x: 1000)])
        #expect(monitors.shownWorkspaces.first == monitors.shown(on: m1))

        monitors.focus(m2)
        #expect(monitors.focused == m2)
        #expect(monitors.shownWorkspaces.first == monitors.shown(on: m2))
        #expect(Set(monitors.shownWorkspaces) == Set([m1, m2].compactMap { monitors.shown(on: $0) }))
    }

    @Test func focusingADisplayThatIsNotAttachedIsANoOp() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [a], infos: [info(m1)])
        monitors.focus(m3)
        #expect(monitors.focused == m1)
    }

    // Departure — the assignments a lid close has to survive

    /// A departing display's addresses go to the first survivor rather than being dropped: a KVM switch
    /// or a lid close must not scramble which workspaces exist.
    @Test func aDepartingDisplaysWorkspacesAreAdoptedByTheFirstSurvivor() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [a, b, c], infos: [info(m1), info(m2, x: 1000)])
        monitors.show(c, on: m2)
        #expect(monitors.monitor(of: c) == m2)

        monitors.reconcile(materialized: [a, b, c], infos: [info(m1)])
        #expect(monitors.ids == [m1])
        #expect(monitors.monitor(of: c) == m1)
        #expect(monitors.owned(of: m1) == [a, b, c])
    }

    /// The focused display leaving moves focus to a survivor, so the acting monitor always names one
    /// that exists.
    @Test func focusMovesToASurvivorWhenTheFocusedDisplayLeaves() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [a, b], infos: [info(m1), info(m2, x: 1000)])
        monitors.focus(m2)
        monitors.reconcile(materialized: [a, b], infos: [info(m1)])
        #expect(monitors.focused == m1)
        #expect(monitors.shown == monitors.shown(on: m1))
    }

    /// Zero displays is a transient state every lid close produces, and the desktop has to come back
    /// from it: the whole set is held detached, and the display that returns takes it all back.
    @Test func theLastDisplayLeavingKeepsTheDesktopAndAReturningOneReclaimsIt() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [a, b, c], infos: [info(m1)])
        monitors.show(b, on: m1)

        monitors.reconcile(materialized: [a, b, c], infos: [])
        #expect(monitors.focused == nil)
        #expect(monitors.ids.isEmpty)
        #expect(monitors.shown == b)                    // still looking at what we were looking at
        #expect(monitors.owned == [a, b, c])

        monitors.reconcile(materialized: [a, b, c], infos: [info(m1)])
        #expect(monitors.focused == m1)
        #expect(monitors.shown == b)
        #expect(monitors.owned(of: m1) == [a, b, c])
    }

    /// An address that lost its strip stops being owned — except the one a display is showing, which it
    /// holds by showing it whether or not anything has materialized it yet (invariant 1 outranks 2).
    @Test func addressesWithNoStripAreDroppedButNeverTheShownOne() {
        var monitors = Monitors()
        monitors.reconcile(materialized: [a, b, c], infos: [info(m1)])
        monitors.show(c, on: m1)
        monitors.reconcile(materialized: [a], infos: [info(m1)])
        #expect(monitors.owned(of: m1) == [a, c])
        #expect(monitors.shown == c)
    }

    @Test func theContainerRoundTripsThroughCodable() throws {
        var monitors = Monitors()
        monitors.reconcile(materialized: [a, b, c], infos: [info(m1), info(m2, x: 1000)])
        monitors.show(c, on: m2)
        monitors.focus(m2)

        let back = try JSONDecoder().decode(Monitors.self, from: try JSONEncoder().encode(monitors))
        #expect(back == monitors)
        #expect(back.focused == m2)
        #expect(back.shown == c)
    }
}

/// `State.setMonitors` — the one fold of `Event.screensChanged`, which has to move all three
/// containers together or the desktop has geometry nothing can lay out against.
@Suite struct StateMonitorFoldTests {

    private let m1 = MonitorId(1)

    @Test func theFoldGivesTheDesktopMetricsAndAnActingMonitor() {
        var s = State()
        #expect(s.metrics() == nil)
        s.setMonitors([MonitorInfo(id: m1, frame: Rect(x: 0, y: 0, width: 1000, height: 800),
                                   struts: EdgeInsets(top: 25, left: 0, bottom: 0, right: 0))])
        #expect(s.monitors.focused == m1)
        #expect(s.metrics()?.workingArea == Rect(x: 0, y: 25, width: 1000, height: 775))
        #expect(s.metrics(of: m1)?.workingArea == s.metrics()?.workingArea)
        #expect(s.metrics(of: MonitorId(99)) == nil)
    }

    /// The struts are per display and live, so a Dock that moved between screens re-insets exactly the
    /// display it moved to — the reason they left `Config`.
    @Test func eachDisplayIsInsetByItsOwnStruts() {
        var s = State()
        s.setMonitors([
            MonitorInfo(id: m1, frame: Rect(x: 0, y: 0, width: 1000, height: 800),
                        struts: EdgeInsets(top: 25, left: 0, bottom: 0, right: 0)),
            MonitorInfo(id: MonitorId(2), frame: Rect(x: 1000, y: 0, width: 800, height: 600),
                        struts: EdgeInsets(top: 0, left: 0, bottom: 70, right: 0)),
        ])
        #expect(s.metrics(of: m1)?.workingArea == Rect(x: 0, y: 25, width: 1000, height: 775))
        #expect(s.metrics(of: MonitorId(2))?.workingArea == Rect(x: 1000, y: 0, width: 800, height: 530))
    }

    /// Every address a display ends up showing has a strip afterwards, so "shown ⇒ materialized" holds
    /// without any later caller having to remember it.
    @Test func everyShownAddressIsMaterializedByTheFold() {
        var s = State()
        s.setMonitors([MonitorInfo(id: m1, frame: Rect(x: 0, y: 0, width: 1000, height: 800)),
                       MonitorInfo(id: MonitorId(2), frame: Rect(x: 1000, y: 0, width: 800, height: 600))])
        for name in s.monitors.shownWorkspaces {
            #expect(s.workspaces.materialized.contains(name), "\(name) is shown with no strip")
        }
    }

    /// The same invariant through `State.show`, where it is **not** one address for one call: a claim
    /// dispossesses whichever display held the address, and that display falls back to one that may
    /// never have been materialized. The switch owes a strip to every address left on a screen, not
    /// just to the one it asked for.
    @Test func aClaimThatReHomesAnotherDisplayMaterializesWhatThatDisplayFallsTo() {
        var s = State()
        s.setMonitors([MonitorInfo(id: m1, frame: Rect(x: 0, y: 0, width: 1000, height: 800)),
                       MonitorInfo(id: MonitorId(2), frame: Rect(x: 1000, y: 0, width: 800, height: 600))])
        // Take what the second display is showing, which is the only way to force it off an address.
        let contested = s.monitors.shown(on: MonitorId(2))!
        s.show(contested)

        let fallback = s.monitors.shown(on: MonitorId(2))!
        #expect(fallback != contested)
        #expect(s.workspaces.materialized.contains(fallback), "\(fallback) is shown with no strip")
        // The contract `placementOrder(shown:)` states, and what the park run and the placement walk
        // are both handed: a name on screen that answers for no strip is a hole in the walk.
        let order = s.workspaces.placementOrder(shown: s.monitors.shownWorkspaces)
        #expect(order.allSatisfy { s.workspaces.materialized.contains($0) })
    }

    /// Invariant 2 through the verbs that materialize an address **without showing it** — the ones
    /// `show` cannot cover. Held at the moment of the edit, not repaired at the next display change,
    /// so `monitor(of:)` is total over every address a window is actually on.
    @Test func aWindowSentToAnUnseenAddressGivesThatAddressAHome() {
        var s = EngineFix.world(2)
        let elsewhere = WorkspaceName("5")!
        let (after, fx) = Engine.reduce(s, .command(.moveToWorkspace(.name(elsewhere))))
        s = EngineFix.settle(after, fx)

        #expect(s.workspaces.materialized.contains(elsewhere))
        #expect(s.monitors.monitor(of: elsewhere) == s.monitors.focused)
        for name in s.workspaces.materialized {
            #expect(s.monitors.monitor(of: name) != nil, "\(name) has a strip and no display")
        }
    }

    /// The same rule from the arrival side: a window rule naming a workspace the user has never been
    /// to materializes it, and an address a *rule* invented is no less assigned than one a verb did.
    @Test func aRuleAssignedWorkspaceIsAssignedToADisplayToo() {
        let config = Config(transitionMode: .off,
                            windowRules: [WindowRule(appId: "com.test.app",
                                                     workspace: WorkspaceName("7")!)])
        var s = EngineFix.booted(config: config)
        let (after, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(1)))
        s = EngineFix.settle(after, fx)

        #expect(s.workspaces.workspace(of: WindowId(1)) == WorkspaceName("7")!)
        #expect(s.monitors.monitor(of: WorkspaceName("7")!) == s.monitors.focused)
    }
}
