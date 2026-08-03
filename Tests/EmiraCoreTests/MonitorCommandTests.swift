import Foundation
import Testing
@testable import EmiraCore

// The eight verbs that name a display, and the two resolution rules under them. Everything here is a
// silent no-op with one display attached — `MonitorRef` has exactly one answer, and "the addresses this
// monitor can cycle to" is all 36 of them — so this is the only place any of it can be proved.
//
// Snapping throughout (`transitionMode: .off`), for `WorkspaceCommandTests`' reason: these are about
// *where* windows and workspaces end up. Which screens raise a cover is `MonitorSessionTests`, plus the
// two-cover cases at the bottom of this file.

@Suite struct MonitorRefTests {

    private let left = MonitorId(1), right = MonitorId(2), below = MonitorId(3)

    /// Three displays: two side by side, the third under the left one. Enough to tell "nearest in a
    /// direction" apart from "next in enumeration order", which one display cannot.
    private func desktop() -> State {
        var s = State()
        s.setMonitors([
            MonitorInfo(id: left, frame: Rect(x: 0, y: 0, width: 1000, height: 800)),
            MonitorInfo(id: right, frame: Rect(x: 1000, y: 0, width: 1000, height: 800)),
            MonitorInfo(id: below, frame: Rect(x: 0, y: 800, width: 1000, height: 800)),
        ])
        return s
    }

    @Test func anIndexNamesTheNthDisplayOneBased() {
        let s = desktop()
        #expect(s.resolve(.index(1)) == left)
        #expect(s.resolve(.index(2)) == right)
        #expect(s.resolve(.index(3)) == below)
    }

    /// Clamps rather than wrapping, exactly as `WorkspaceRef` does — and resolving to the display you
    /// are already on is how "nowhere to go" is spelled, which every verb turns into silence.
    @Test func everyRelativeRefClampsAtTheEndsOfTheEnumeration() {
        var s = desktop()
        #expect(s.resolve(.previous) == left)         // already the first
        #expect(s.resolve(.next) == right)
        #expect(s.resolve(.index(99)) == below)       // past the end ⇒ the last
        s.monitors.focus(below)
        #expect(s.resolve(.next) == below)            // already the last
        #expect(s.resolve(.previous) == right)
    }

    /// Spatial, not positional: `down` finds the display *under* this one even though it sorts after
    /// the one beside it, which is the whole reason a direction is not a synonym for `next`.
    @Test func aDirectionFindsTheNearestDisplayThatWay() {
        var s = desktop()
        #expect(s.resolve(.direction(.right)) == right)
        #expect(s.resolve(.direction(.down)) == below)
        s.monitors.focus(below)
        #expect(s.resolve(.direction(.up)) == left)   // core y grows downward
    }

    /// The desktop has an edge where the strip does not (D2), so a direction with nothing that way is a
    /// no-op — spelled as the acting monitor, which is the same clamp every other ref uses.
    @Test func aDirectionWithNothingThatWayResolvesToTheActingMonitor() {
        let s = desktop()
        #expect(s.resolve(.direction(.left)) == left)
        #expect(s.resolve(.direction(.up)) == left)
    }

    /// Among displays in the half-plane, the nearest along the direction's own axis wins; the cross
    /// axis only breaks ties. A far display straight ahead must not beat a near one slightly off it.
    @Test func theNearerDisplayWinsEvenWhenItIsFurtherOffAxis() {
        var s = State()
        let near = MonitorId(7), far = MonitorId(8)
        s.setMonitors([
            MonitorInfo(id: left, frame: Rect(x: 0, y: 0, width: 1000, height: 800)),
            MonitorInfo(id: far, frame: Rect(x: 3000, y: 0, width: 1000, height: 800)),
            MonitorInfo(id: near, frame: Rect(x: 1000, y: 600, width: 1000, height: 800)),
        ])
        #expect(s.resolve(.direction(.right)) == near)
    }

    /// With no display attached there is nothing to name, and every verb reading this declines.
    @Test func aRefNamesNothingWithNoDisplayAttached() {
        let s = State()
        #expect(s.resolve(.index(1)) == nil)
        #expect(s.resolve(.next) == nil)
        #expect(s.resolve(.direction(.right)) == nil)
    }
}

/// D1 — **absolute workspace refs are global, relative ones are per-monitor.** Both halves are
/// invisible on one screen: a name has always resolved to itself, and "owned here or owned by nobody"
/// is the whole domain.
@Suite struct WorkspaceRefAcrossDisplaysTests {

    private let left = MonitorId(1), right = MonitorId(2)

    private func desktop() -> State {
        var s = State(config: EngineFix.halfWidthSnap)
        s.setMonitors([MonitorInfo(id: left, frame: Rect(x: 0, y: 0, width: 1000, height: 800)),
                       MonitorInfo(id: right, frame: Rect(x: 1000, y: 0, width: 1000, height: 800))])
        return s
    }

    /// The generalization is exact: one display holds — or could hold — every address, so nothing here
    /// changes what a single-screen `next` does.
    @Test func oneDisplayReachesTheWholeDomain() {
        var s = State()
        s.setMonitors([MonitorInfo(id: left, frame: Rect(x: 0, y: 0, width: 1000, height: 800))])
        #expect(s.monitors.reachable == WorkspaceName.all)
    }

    /// `next` steps over an address the *other* display holds: the monitor is the container, and
    /// cycling should not leave it.
    @Test func relativeMotionStepsOverAnotherDisplaysAddresses() {
        var s = desktop()
        let here = s.monitors.shown
        let theirs = try! #require(s.monitors.shown(on: right))
        #expect(theirs == here.next, "the fixture wants the neighbouring address on the other screen")

        #expect(!s.monitors.reachable.contains(theirs))
        #expect(s.resolve(.next) == theirs.next)
    }

    /// …and an absolute name does not, because that is the "just work" requirement: `focus-workspace 5`
    /// goes to 5 wherever 5 is.
    @Test func anAbsoluteNameResolvesToItselfWhicheverDisplayHoldsIt() {
        let s = desktop()
        let theirs = try! #require(s.monitors.shown(on: right))
        #expect(s.resolve(.name(theirs)) == theirs)
    }
}

/// The verbs themselves, driven through the reducer against two side-by-side displays.
@Suite struct MonitorCommandTests {

    static let left = MonitorId(1), right = MonitorId(2)
    static let leftFrame = Rect(x: 0, y: 0, width: 1000, height: 800)
    static let rightFrame = Rect(x: 1000, y: 0, width: 1000, height: 800)

    /// Two displays, `count` windows on the acting monitor's strip, at rest and snapping.
    static func desktop(_ count: UInt64, config: Config = EngineFix.halfWidthSnap) -> State {
        var s = State(config: config)
        (s, _) = Engine.reduce(s, .screensChanged([MonitorInfo(id: left, frame: leftFrame),
                                                   MonitorInfo(id: right, frame: rightFrame)]))
        for raw in 1...max(count, 1) where count > 0 {
            let (next, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(raw)))
            s = EngineFix.settle(next, fx)
        }
        return s
    }

    static func run(_ s: State, _ command: Command) -> State {
        let (next, fx) = Engine.reduce(s, .command(command))
        return EngineFix.settle(next, fx)
    }

    /// Whether a window is tiled on a given display — the question every cross-display verb is
    /// ultimately about.
    static func sits(_ s: State, _ id: WindowId, on frame: Rect) -> Bool {
        guard let window = s.world.windows[id]?.frame else { return false }
        return frame.contains(Point(x: window.midX, y: window.midY)) && s.world.isOnScreen(id)
    }

    // focus-workspace, updated (D1)

    /// **The churn phase 4 exists to fix.** Naming an address another display is showing used to yank
    /// it onto the acting monitor, because `show` claims for whoever asked. Now the *user* moves, the
    /// address stays where it lives, and the display being left keeps its own screen.
    @Test func focusingAnAddressAnotherDisplayShowsMovesTheUserRatherThanTheWorkspace() {
        let s = Self.desktop(2)
        let here = s.monitors.shown
        let theirs = try! #require(s.monitors.shown(on: Self.right))

        let after = Self.run(s, .focusWorkspace(.name(theirs)))
        #expect(after.monitors.focused == Self.right)
        #expect(after.monitors.shown(on: Self.right) == theirs)
        #expect(after.monitors.shown(on: Self.left) == here, "the display we left kept its address")
    }

    /// An address nobody holds is claimed by the acting monitor and switched to there — single-display
    /// behaviour, unchanged, and the branch that keeps one screen the special case of several.
    @Test func focusingAnUnheldAddressSwitchesTheDisplayWeAreOn() {
        let s = Self.desktop(2)
        let free = try! #require(s.monitors.reachable.first { s.monitors.monitor(of: $0) == nil })

        let after = Self.run(s, .focusWorkspace(.name(free)))
        #expect(after.monitors.focused == Self.left)
        #expect(after.monitors.shown(on: Self.left) == free)
    }

    // focus-monitor

    @Test func focusMonitorMovesTheUserAndLeavesBothStripsAlone() {
        let s = Self.desktop(2)
        let here = s.monitors.shown
        let theirs = try! #require(s.monitors.shown(on: Self.right))

        let after = Self.run(s, .focusMonitor(.index(2)))
        #expect(after.monitors.focused == Self.right)
        #expect(after.monitors.shown == theirs)
        #expect(after.monitors.shown(on: Self.left) == here)
        // The second display is showing an empty address, so emira's focus rests on nothing at all.
        #expect(after.world.focusedWindow == nil)
    }

    /// Invariant 3's payoff, and the whole reason `Monitors.focused` is stored rather than derived: an
    /// empty display can hold focus, so the next window opens there through the unchanged newcomer rule.
    @Test func aWindowOpenedAfterFocusingAnEmptyDisplayLandsOnIt() {
        var s = Self.run(Self.desktop(2), .focusMonitor(.index(2)))
        let theirs = try! #require(s.monitors.shown(on: Self.right))

        let (next, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(9)))
        s = EngineFix.settle(next, fx)

        #expect(s.workspaces.workspace(of: WindowId(9)) == theirs)
        #expect(Self.sits(s, WindowId(9), on: Self.rightFrame))
    }

    @Test func focusingTheDisplayWeAreOnIsSilent() {
        let s = Self.desktop(2)
        let (_, fx) = Engine.reduce(s, .command(.focusMonitor(.index(1))))
        #expect(fx.isEmpty)
    }

    // move-to-monitor

    /// The window goes to the address the display is *showing*, so it tiles there rather than parking:
    /// the difference between this verb and `move-to-workspace` naming a parked address.
    @Test func moveToMonitorSendsTheWindowToWhatThatDisplayIsShowing() {
        let s = Self.desktop(2)
        let moved = try! #require(s.world.focusedWindow)
        let theirs = try! #require(s.monitors.shown(on: Self.right))

        let after = Self.run(s, .moveToMonitor(.index(2)))
        #expect(after.workspaces.workspace(of: moved) == theirs)
        #expect(Self.sits(after, moved, on: Self.rightFrame))
        // Focus stays behind, on this display, on the window the departure left in view.
        #expect(after.monitors.focused == Self.left)
        #expect(after.world.focusedWindow != moved)
        #expect(after.world.focusedWindow != nil)
    }

    @Test func moveToMonitorAndFocusFollowsTheWindowAcross() {
        let s = Self.desktop(2)
        let moved = try! #require(s.world.focusedWindow)

        let after = Self.run(s, .moveToMonitorAndFocus(.direction(.right)))
        #expect(after.monitors.focused == Self.right)
        #expect(after.world.focusedWindow == moved)
        #expect(Self.sits(after, moved, on: Self.rightFrame))
    }

    /// `move-to-workspace` naming an address another display holds crosses displays too, and always
    /// has — what phase 4 adds is that following it takes the user to the right screen.
    @Test func moveToWorkspaceAndFocusFollowsTheAddressToItsOwnDisplay() {
        let s = Self.desktop(2)
        let moved = try! #require(s.world.focusedWindow)
        let theirs = try! #require(s.monitors.shown(on: Self.right))

        let after = Self.run(s, .moveToWorkspaceAndFocus(.name(theirs)))
        #expect(after.monitors.focused == Self.right)
        #expect(after.world.focusedWindow == moved)
        #expect(Self.sits(after, moved, on: Self.rightFrame))
    }

    // move-workspace-to-monitor

    /// The acting monitor showing `5`, with occupied addresses at `3` and `7` either side of it and one
    /// far off at `1` — a fallback with something to choose *between*, and a deliberate tie: `3` and
    /// `7` are equidistant from `5`.
    static func addresses(_ text: String) -> [WorkspaceName] { text.map { WorkspaceName($0)! } }

    static func occupiedEitherSide(config: Config = EngineFix.halfWidthSnap) -> State {
        var s = desktop(1, config: config)                  // window 1 on the launch address
        for (offset, name) in addresses("357").enumerated() {
            s = run(s, .focusWorkspace(.name(name)))
            let (next, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(UInt64(offset + 2))))
            s = EngineFix.settle(next, fx)
        }
        return run(s, .focusWorkspace(.name(WorkspaceName("5")!)))
    }

    /// D3 — the destination shows the arrival, and its windows are re-laid-out against *its* working
    /// area. Nothing changed strips: what travelled is the address.
    @Test func moveWorkspaceToMonitorHandsTheAddressOverAndTheDestinationShowsIt() {
        let s = Self.desktop(2)
        let travelling = s.monitors.shown

        let after = Self.run(s, .moveWorkspaceToMonitor(.index(2)))
        #expect(after.monitors.shown(on: Self.right) == travelling)
        #expect(after.monitors.monitor(of: travelling) == Self.right)
        for id in after.workspaces[travelling].allWindowIds {
            #expect(Self.sits(after, id, on: Self.rightFrame), "\(id) is still on the old display")
        }
    }

    /// §3's fallback rule: the source lands on the **nearest occupied** address it still holds, with
    /// forward winning ties — `next`'s own bias, so a display losing `5` lands on `7` and not on `3`.
    @Test func theSourceFallsBackToItsNearestOccupiedAddressForwardWinningTies() {
        let s = Self.occupiedEitherSide()
        #expect(s.monitors.owned(of: Self.left) == Self.addresses("1357"))

        let after = Self.run(s, .moveWorkspaceToMonitor(.index(2)))
        #expect(after.monitors.shown(on: Self.left) == WorkspaceName("7")!)
        #expect(after.monitors.focused == Self.left, "the plain verb leaves the keyboard where it was")
        #expect(after.world.focusedWindow == WindowId(4), "…on what that address was last looking at")
    }

    @Test func theAndFocusVariantFollowsTheWorkspaceToItsNewDisplay() {
        let s = Self.occupiedEitherSide()
        let travelling = s.monitors.shown
        let wasFocused = try! #require(s.world.focusedWindow)

        let after = Self.run(s, .moveWorkspaceToMonitorAndFocus(.index(2)))
        #expect(after.monitors.focused == Self.right)
        #expect(after.monitors.shown == travelling)
        #expect(after.world.focusedWindow == wasFocused)
    }

    /// The workspace keeps its scroll across the desktop: the source's live viewport is the travelling
    /// address's authority right up to the hand-over, and the destination reads it back.
    @Test func theTravellingWorkspaceKeepsItsScrollOffset() {
        var s = Self.desktop(3, config: EngineFix.fullWidth)
        s = Self.run(s, .focus(.right))                 // scroll the strip off its origin
        let travelling = s.monitors.shown
        let scrolled = s.motion.offset(of: Self.left).current
        #expect(scrolled > 0)

        let after = Self.run(s, .moveWorkspaceToMonitor(.index(2)))
        #expect(EngineFix.approxScalar(after.workspaces[scrollOffsetOf: travelling], scrolled))
    }

    @Test func handingAWorkspaceToTheDisplayItIsAlreadyOnIsSilent() {
        let s = Self.desktop(2)
        let (_, fx) = Engine.reduce(s, .command(.moveWorkspaceToMonitor(.index(1))))
        #expect(fx.isEmpty)
    }

    // D2 — `focus <direction>` never crosses displays

    /// The strip is infinite and has no edge to fall off, so a second meaning for `Direction` at a
    /// boundary that does not exist would make the model ambiguous — for a convenience `focus-monitor
    /// right` already spells.
    @Test func focusDirectionStopsAtTheEndOfItsOwnStrip() {
        var s = Self.desktop(2, config: EngineFix.fullWidth)
        s = Self.run(s, .focus(.right))                 // onto the last column
        let last = s.world.focusedWindow

        let after = Self.run(s, .focus(.right))
        #expect(after.world.focusedWindow == last)
        #expect(after.monitors.focused == Self.left)
    }

    // How many covers each verb raises (§4)

    /// Both screens change what they show, so both raise a cover — the two-cover case D7's per-display
    /// sessions exist for, and the one a single session spanning displays could not express. The
    /// destination's slide-in is what `structuralSnapshot(travelling:)` buys: invariant 4 says the
    /// hand-over is two independent switches, so the arriving workspace has to come from one screen
    /// away rather than out of nowhere.
    @Test func handingAWorkspaceOverOpensACoverOnEachDisplay() {
        let s = Self.occupiedEitherSide(config: EngineFix.fullWidth)
        let (after, _) = Engine.reduce(s, .command(.moveWorkspaceToMonitor(.index(2))))
        #expect(after.motion.transitioningMonitors == [Self.left, Self.right])
    }

    /// …where sending a window to an address **nobody is showing** changes one screen only: it lands in
    /// the destination display's parking lot, where there is nothing visible to animate.
    @Test func sendingAWindowToAParkedAddressCoversOneScreen() {
        let s = Self.desktop(3, config: EngineFix.fullWidth)
        let parked = try! #require(s.resolve(WorkspaceRef.next))
        let (after, _) = Engine.reduce(s, .command(.moveToWorkspace(.name(parked))))
        #expect(after.motion.transitioningMonitors == [Self.left])
    }
}
