import Foundation
import Testing
@testable import EmiraCore

// The workspace verbs: `focus-workspace`, `move-to-workspace`, `move-to-workspace-and-focus`, the five
// ways to name an address, per-workspace scroll and focus memory, and the cross-workspace focus a real
// desktop produces.
//
// Everything here snaps (`smoothTransitions: false`), for `EngineTests.halfWidthSnap`'s reason: these
// tests are about *where windows end up*, and under the animated path the reals teleport at the cover's
// raise rather than in the command's own batch. The motion is `WorkspaceMotionTests`, below.

/// Ref resolution, which lives in `Workspaces` beside the ordering it depends on.
@Suite struct WorkspaceRefTests {

    private let w1 = WindowId(1), w2 = WindowId(2)
    private func name(_ c: Character) -> WorkspaceName { WorkspaceName(c)! }

    @Test func anAbsoluteNameResolvesToItselfFromAnywhere() {
        var ws = Workspaces()
        #expect(ws.resolve(.name(name("c"))) == name("c"))
        ws.focus(name("c"))
        #expect(ws.resolve(.name(.first)) == .first)
        #expect(ws.resolve(.name(.last)) == .last)
    }

    /// One address at a time, materialized or not — `next` is about the *domain*, so it walks straight
    /// through addresses nobody has ever visited, in key order (the number row runs into `0` first).
    @Test func nextAndPreviousStepOneAddressWhetherOrNotItExists() {
        var ws = Workspaces()                       // only the launch address materialized
        #expect(ws.resolve(.next) == name("2"))
        #expect(ws.materialized == [.first])        // …and resolving materialized nothing
        ws.focus(name("9"))
        #expect(ws.resolve(.next) == name("0"))
        #expect(ws.resolve(.previous) == name("8"))
        ws.focus(name("0"))
        #expect(ws.resolve(.next) == name("a"))     // the digit/letter seam is after "0", not before it
    }

    /// Clamps, never wraps — the same rule `focus left|right` keeps at the strip's edges. Resolving to
    /// the workspace you are on is how "nowhere to go" is spelled; the reducer turns that into silence.
    @Test func relativeMotionClampsAtBothEndsOfTheDomain() {
        var ws = Workspaces()
        #expect(ws.resolve(.previous) == .first)    // at "1" — the launch address — already
        ws.focus(.last)
        #expect(ws.resolve(.next) == .last)         // at "z"
    }

    /// `next-non-empty` walks what you have *open*, so it skips both never-visited addresses and
    /// visited-then-emptied ones. Being materialized is not being occupied.
    @Test func theOccupiedMotionsSkipEmptyAddressesIncludingVisitedOnes() {
        var ws = Workspaces()
        ws.focus(name("3"))
        ws.reconcile(stripWindowIds: [w1])          // "3" holds a window
        ws.focus(name("5"))                         // materialized, and left empty
        ws.focus(name("8"))
        ws.reconcile(stripWindowIds: [w1, w2])      // "8" holds one too
        ws.focus(.first)

        #expect(ws.materialized == [.first, name("3"), name("5"), name("8")])
        #expect(ws.resolve(.nextOccupied) == name("3"))
        #expect(ws.resolve(.next) == name("2"))               // the plain motion does not skip

        ws.focus(name("3"))
        #expect(ws.resolve(.nextOccupied) == name("8"))      // "5" is empty, so it is passed over
        #expect(ws.resolve(.previousOccupied) == name("3"))  // nothing occupied below ⇒ stay put
        ws.focus(name("8"))
        #expect(ws.resolve(.previousOccupied) == name("3"))
        #expect(ws.resolve(.nextOccupied) == name("8"))      // nothing above ⇒ stay put
    }
}

/// The three verbs, driven through the reducer.
@Suite struct WorkspaceCommandTests {

    // MARK: Fixtures

    /// One full-width preset on a 1000-pt display: one column *is* the viewport, so column *n* sits at
    /// strip offset `1000n` and every scroll number below is readable at a glance.
    static let oneColumn = Config(widthPresets: PresetCycle([.proportion(1.0)]),
                                  smoothTransitions: false)

    /// Two half-width columns fill the 1000-pt viewport exactly, so a two-window workspace is entirely
    /// on screen at offset 0. Used where the test is about *tiled versus parked*: the whole strip then
    /// changes state on a switch, so the placement diff has something to say about all of it.
    static let twoUp = EngineTests.halfWidthSnap

    private func name(_ c: Character) -> WorkspaceName { WorkspaceName(c)! }

    /// The launch address, `"1"`. Named rather than spelled, so a change to where the daemon starts is
    /// one line here.
    private let home = WorkspaceName.first
    /// Somewhere else to be. Any address that is not `home`.
    private let other = WorkspaceName("2")!

    /// A booted world of `count` tiled windows at rest, one per column.
    private func world(_ count: UInt64, config: Config = oneColumn) -> State {
        EngineTests.world(count, config: config)
    }

    /// Drive one command and settle whatever it started (a workspace verb starts nothing, but a
    /// `focus` in the same scenario does).
    private func run(_ s: State, _ events: [Event]) -> (State, [Effect]) {
        EngineTests.run(s, events)
    }

    private func focusWorkspace(_ name: WorkspaceName) -> Event {
        .command(.focusWorkspace(.name(name)))
    }

    private func moveToWorkspace(_ name: WorkspaceName) -> Event {
        .command(.moveToWorkspace(.name(name)))
    }

    /// The `.focus` effects in a stream, in order — what the shell would ask AX for.
    private func focused(in fx: [Effect]) -> [WindowId] {
        fx.compactMap { if case .focus(let w) = $0 { return w }; return nil }
    }

    /// The windows a stream `park`ed.
    private func parked(in fx: [Effect]) -> Set<WindowId> {
        Set(fx.compactMap { if case .park(let w, _) = $0 { return w }; return nil })
    }

    /// The windows a stream `setFrame`d (i.e. tiled on screen).
    private func tiled(in fx: [Effect]) -> Set<WindowId> {
        Set(fx.compactMap { if case .setFrame(let w, _) = $0 { return w }; return nil })
    }

    /// The windows actually on screen — the focused strip's visible set, asked of the *state*.
    ///
    /// Distinct from `tiled(in:)` on purpose: the effect stream is a *diff*, so a window already at the
    /// frame it belongs at emits nothing. "What moved" and "where things are" are different questions.
    private func onScreen(_ s: State) -> Set<WindowId> {
        Set(s.layout.visibleWindowIds(scrollOffset: s.motion.viewportOffset.current,
                                      metrics: s.metrics()!))
    }

    // MARK: focus-workspace

    /// Leaving parks the whole outgoing strip, arriving tiles the incoming one — which is just what
    /// "everything that is not the focused strip is parked" already meant.
    @Test func switchingParksTheOutgoingStripAndTilesTheIncomingOne() {
        var s = world(2, config: Self.twoUp)
        #expect(onScreen(s) == [WindowId(1), WindowId(2)])

        let (afterSwitch, fx) = run(s, [focusWorkspace(other)])
        s = afterSwitch

        #expect(s.workspaces.focused == other)
        #expect(s.workspaces[.first].allWindowIds == [WindowId(1), WindowId(2)])
        #expect(s.workspaces[other].isEmpty)
        #expect(onScreen(s).isEmpty)                          // the whole desktop is parked
        #expect(parked(in: fx) == [WindowId(1), WindowId(2)])
        #expect(tiled(in: fx).isEmpty)

        // …and back: the two windows tile again, nothing is parked.
        let (back, backFx) = run(s, [focusWorkspace(home)])
        #expect(back.workspaces.focused == .first)
        #expect(onScreen(back) == [WindowId(1), WindowId(2)])
        #expect(tiled(in: backFx) == [WindowId(1), WindowId(2)])
        #expect(parked(in: backFx).isEmpty)
    }

    /// A switch to where you already are says nothing at all — which is also how `next` at `"z"` and an
    /// occupied motion with nowhere to go come out, since `Workspaces.resolve` clamps.
    @Test func switchingToTheFocusedWorkspaceIsSilent() {
        let s = world(2)
        for ref: WorkspaceRef in [.name(.first), .previous, .previousOccupied, .nextOccupied] {
            let (after, fx) = run(s, [.command(.focusWorkspace(ref))])
            #expect(fx.isEmpty, "\(ref) emitted \(fx)")
            #expect(after == s, "\(ref) changed the state")
        }
    }

    /// Scroll position survives a round trip, and it is one stored `Double` because the switch is the
    /// only thing that reads or writes it.
    @Test func scrollPositionSurvivesARoundTrip() {
        // Four full-width columns: focus the last, which scrolls the strip to 3000.
        var s = world(4)
        s = EngineTests.settle(s, [])
        let (scrolled, fx) = run(s, [.command(.focus(.right))])
        s = EngineTests.settle(scrolled, fx)
        let offset = s.motion.viewportOffset.current
        #expect(offset > 0, "the fixture did not actually scroll")

        s = run(s, [focusWorkspace(other)]).0
        #expect(s.motion.viewportOffset.current == 0)          // a fresh workspace starts at its origin
        #expect(s.workspaces[scrollOffsetOf: .first] == offset)

        s = run(s, [focusWorkspace(home)]).0
        #expect(EngineTests.approxScalar(s.motion.viewportOffset.current, offset))
        // A snap, not a spring: nothing is left travelling.
        #expect(s.motion.viewportOffset.target == s.motion.viewportOffset.current)
        #expect(!s.motion.isTransitioning)
    }

    /// Focus memory is the other half of the same record: come back to the window you left, not to the
    /// front of the strip.
    @Test func focusReturnsToTheWindowTheWorkspaceWasLeftOn() {
        var s = world(3)
        s = run(s, [.command(.focus(.left))]).0            // focus the middle column
        let left = s.world.focusedWindow
        #expect(left == WindowId(2))

        s = run(s, [focusWorkspace(other)]).0
        #expect(s.workspaces[lastFocusOf: .first] == WindowId(2))

        let (back, fx) = run(s, [focusWorkspace(home)])
        #expect(back.world.focusedWindow == WindowId(2))
        #expect(focused(in: fx) == [WindowId(2)])
    }

    /// An empty workspace has nothing to focus, so focus is left resting off the strip — an already-
    /// supported state, not a case wanting a rule of its own: the next `focus left|right` recovers.
    @Test func anEmptyWorkspaceLeavesFocusOffTheStripAndTheNextFocusRecovers() {
        var s = world(2)
        let (switched, fx) = run(s, [focusWorkspace(other)])
        s = switched
        #expect(focused(in: fx).isEmpty)
        // `World.focusedWindow` still names whatever the *system* has focused — we asked AX for
        // nothing, so claiming otherwise would be a fiction. What matters is that it has no column on
        // the strip in front of the user, which is the state `handleFocus` treats as an entry point.
        #expect(s.world.focusedWindow != nil)
        #expect(s.layout.columnIndex(ofWindow: s.world.focusedWindow!) == nil)

        // Back home the long way: `focus right` re-enters *this* (empty) strip and finds nothing…
        #expect(run(s, [.command(.focus(.right))]).1.isEmpty)
        // …and once there is a window here, it re-enters at the near end.
        let (populated, createFx) = Engine.reduce(s, .windowCreated(EngineTests.snapshot(9)))
        s = EngineTests.settle(populated, createFx)
        #expect(s.world.focusedWindow == WindowId(9))
        #expect(s.workspaces[other].allWindowIds == [WindowId(9)])
        #expect(s.workspaces[.first].allWindowIds == [WindowId(1), WindowId(2)])
    }

    /// A workspace that has never been focused starts at its origin with its first window focused —
    /// the case `move-to-workspace` creates, where there is no memory to restore.
    @Test func aNeverVisitedWorkspaceFocusesItsFirstWindow() {
        var s = world(2)
        s = run(s, [moveToWorkspace(name("4"))]).0
        #expect(s.workspaces[name("4")].allWindowIds == [WindowId(2)])

        let (switched, fx) = run(s, [focusWorkspace(name("4"))])
        #expect(switched.world.focusedWindow == WindowId(2))
        #expect(focused(in: fx) == [WindowId(2)])
        #expect(switched.motion.viewportOffset.current == 0)
    }

    /// A remembered focus that has since closed names nothing, and the switch must not land on it.
    /// `Workspaces.reconcile` clears it, so this is an invariant of the container rather than a check
    /// at the switch.
    @Test func aRememberedFocusThatClosedIsForgottenNotFollowed() {
        var s = world(2)
        s = run(s, [focusWorkspace(other)]).0
        #expect(s.workspaces[lastFocusOf: .first] == WindowId(2))

        s = run(s, [.windowDestroyed(WindowId(2))]).0
        #expect(s.workspaces[lastFocusOf: .first] == nil)

        let (back, fx) = run(s, [focusWorkspace(home)])
        #expect(back.world.focusedWindow == WindowId(1))
        #expect(focused(in: fx) == [WindowId(1)])
    }

    // MARK: move-to-workspace

    /// It moves a *window*, not its column, so a window with stackmates leaves them behind and the
    /// column it left survives.
    @Test func aMoveTakesTheWindowAndLeavesItsStackmates() {
        var s = world(2)
        // Merge both windows into one column, then send the focused one away.
        s = run(s, [.command(.consumeOrExpel(.left))]).0
        #expect(s.layout.columns.count == 1)
        #expect(s.layout.columns[0].windowIds.count == 2)

        let moved = s.world.focusedWindow!
        let (after, _) = run(s, [.command(.moveToWorkspace(.name(name("3"))))])
        #expect(after.workspaces[.first].allWindowIds.count == 1)
        #expect(after.workspaces[.first].columns.count == 1)          // the column outlived the move
        #expect(after.workspaces[name("3")].allWindowIds == [moved])
        #expect(after.workspaces.workspace(of: moved) == name("3"))
    }

    /// Focus stays on this workspace and lands on the neighbour — the same `successor` call a close
    /// makes.
    @Test func focusStaysBehindOnTheNeighbour() {
        var s = world(3)
        s = run(s, [.command(.focus(.left))]).0                        // middle column focused
        #expect(s.world.focusedWindow == WindowId(2))

        let (after, fx) = run(s, [.command(.moveToWorkspace(.next))])
        #expect(after.workspaces.focused == .first)                    // did *not* follow
        #expect(after.world.focusedWindow == WindowId(3))              // the column that slid into place
        #expect(focused(in: fx) == [WindowId(3)])
        #expect(after.workspaces[other].allWindowIds == [WindowId(2)])
    }

    /// Moving the last window off a workspace leaves it empty with focus off the strip, and no trap.
    @Test func emptyingTheStripLeavesFocusOffItRatherThanTrapping() {
        let s = world(1)
        let (after, fx) = run(s, [.command(.moveToWorkspace(.name(name("z"))))])
        #expect(after.workspaces[.first].isEmpty)
        #expect(after.world.focusedWindow == nil)
        #expect(focused(in: fx).isEmpty)
        #expect(parked(in: fx) == [WindowId(1)])                       // parked on "z", not tiled here
    }

    /// The follow verb differs from its sibling in exactly one thing: where focus ends up. The moved
    /// window keeps it, on the destination.
    @Test func theFollowVerbSwitchesAndKeepsFocusOnTheMovedWindow() {
        let s = world(2, config: Self.twoUp)
        let moved = s.world.focusedWindow!
        let (after, fx) = run(s, [.command(.moveToWorkspaceAndFocus(.name(name("a"))))])

        #expect(after.workspaces.focused == name("a"))
        #expect(after.world.focusedWindow == moved)
        #expect(focused(in: fx) == [moved])
        #expect(onScreen(after) == [moved])                            // on screen where we followed it
        #expect(tiled(in: fx) == [moved])
        #expect(parked(in: fx) == [WindowId(1)])                       // what we left behind
        #expect(after.workspaces[.first].allWindowIds == [WindowId(1)])
    }

    /// A moved window becomes the destination's remembered focus, and the *next* window sent there opens
    /// beside it — so a run of moves builds a group in send order instead of scattering at the far end.
    @Test func successiveMovesLandBesideTheOneBeforeThem() {
        var s = world(3)
        // Send 3, then 2, then 1 — each becomes the anchor the next opens beside.
        for _ in 0..<3 {
            s = run(s, [.command(.moveToWorkspace(.name(name("7"))))]).0
        }
        #expect(s.workspaces[.first].isEmpty)
        #expect(s.workspaces[name("7")].allWindowIds == [WindowId(3), WindowId(2), WindowId(1)])
        #expect(s.workspaces[lastFocusOf: name("7")] == WindowId(1))
    }

    /// The width a window was given travels with it, exactly as it does through an `expel` — the size
    /// is one the user asked for out loud, and arriving one third as wide would be a second change
    /// nobody requested.
    @Test func theWidthIntentTravelsWithTheWindow() {
        var s = world(2, config: Config(widthPresets: PresetCycle([.proportion(1.0 / 3.0), .proportion(0.5)])))
        s = EngineTests.settle(run(s, [.command(.cycleWidth)]).0, [])
        let column = s.layout.columns[s.layout.columnIndex(ofWindow: s.world.focusedWindow!)!]
        #expect(column.widthPreset == 1)

        s = run(s, [.command(.moveToWorkspace(.name(name("6"))))]).0
        #expect(s.workspaces[name("6")].columns.map(\.widthPreset) == [1])
    }

    /// Moving to the workspace the window is already on is a no-op, matching
    /// `Layout.move(window:toColumn:at:)`'s refusal to move a window into its own column.
    @Test func movingToTheWorkspaceYouAreOnIsSilent() {
        let s = world(2)
        let (after, fx) = run(s, [.command(.moveToWorkspace(.name(.first)))])
        #expect(fx.isEmpty)
        #expect(after == s)
    }

    /// A `ColumnId` minted on the destination cannot collide with one on the source — the hazard
    /// `ColumnAllocator` exists for, now reached through the verb rather than through `reconcile`.
    @Test func aCrossWorkspaceMoveMintsIntoTheOneIdSpace() {
        var s = world(3)
        s = run(s, [moveToWorkspace(other)]).0
        s = run(s, [moveToWorkspace(other)]).0
        let all = s.workspaces.materialized.flatMap { s.workspaces[$0].columns.map(\.id) }
        #expect(all.count == 3)
        #expect(Set(all).count == all.count)
    }

    // MARK: The cross-workspace focus a real desktop produces

    /// Cmd-Tab, a Dock click, an app raising its own window: `focusChanged` can name a window on a
    /// workspace nobody is looking at. The user must never be focused on something they cannot see, so
    /// it snap-switches and then reveals.
    @Test func externalFocusOnAnotherWorkspaceSwitchesToIt() {
        var s = world(2)
        s = run(s, [moveToWorkspace(other)]).0
        let away = WindowId(2)
        #expect(s.workspaces.workspace(of: away) == other)
        #expect(s.workspaces.focused == .first)

        let (after, fx) = run(s, [.focusChanged(away)])
        #expect(after.workspaces.focused == other)
        #expect(after.world.focusedWindow == away)
        #expect(tiled(in: fx) == [away])
        #expect(parked(in: fx) == [WindowId(1)])
        // No `.focus`: the shell already moved focus, so asking again is a redundant AX set — and an
        // echo we would have to absorb.
        #expect(focused(in: fx).isEmpty)
    }

    /// The echo, checked rather than assumed: a switch emits `.focus`, which comes back as
    /// `focusChanged`, which must not switch again. A switch that re-triggers a switch is a loop, not
    /// a wrong pixel.
    @Test func theFocusEchoOfASwitchIsAbsorbed() {
        var s = world(2)
        s = run(s, [moveToWorkspace(other)]).0

        let (switched, fx) = run(s, [focusWorkspace(other)])
        s = switched
        let announced = focused(in: fx)
        #expect(announced == [WindowId(2)])

        // Feed our own effect back as the shell's AX observer would. Emitting nothing is the proof: a
        // stream with no `.focus`, `.setFrame` or `.park` cannot echo again, so the sequence terminates.
        let (echoed, echoFx) = run(s, [.focusChanged(WindowId(2))])
        #expect(echoFx.isEmpty, "the echo re-emitted \(echoFx)")
        #expect(echoed.workspaces == s.workspaces)
        #expect(echoed.world == s.world)
        #expect(echoed.motion.viewportOffset.current == s.motion.viewportOffset.current)
    }

    /// Switching away and being Cmd-Tabbed back must not lose the outgoing workspace's own memory. The
    /// ordering is load-bearing: `World.focusedWindow` is recorded *inside* the switch, because setting
    /// it first would make the outgoing record read `nil`.
    @Test func anExternalSwitchStillRemembersTheWorkspaceItLeft() {
        var s = world(3)
        s = run(s, [.command(.focus(.left))]).0                 // focus window 2 at home
        s = run(s, [.command(.moveToWorkspaceAndFocus(.name(name("5"))))]).0
        #expect(s.workspaces.focused == name("5"))

        // Cmd-Tab back to a window that lives at home — window 1, not the one we left focused.
        s = run(s, [.focusChanged(WindowId(1))]).0
        #expect(s.workspaces.focused == .first)
        // "5" remembers the window we were on when we were pulled away.
        #expect(s.workspaces[lastFocusOf: name("5")] == WindowId(2))
    }

    /// External focus on a window of the *focused* workspace is unchanged — the plain snap-reveal it
    /// has always been. Only the cross-workspace case is new.
    @Test func externalFocusOnThisWorkspaceStillJustReveals() {
        let s = world(3)
        let (after, fx) = run(s, [.focusChanged(WindowId(1))])
        #expect(after.workspaces.focused == .first)
        #expect(after.world.focusedWindow == WindowId(1))
        #expect(focused(in: fx).isEmpty)
        #expect(tiled(in: fx).contains(WindowId(1)))
    }

    // MARK: Placement across the whole set

    /// Every parked window — on *any* unfocused workspace — gets a slot no other window shares, within
    /// the ±2 pt tolerance the first-sight identity join binds at.
    @Test func everyParkedWindowAcrossEveryWorkspaceGetsItsOwnSlot() {
        var s = world(6)
        // Scatter: two windows onto one other address, two onto a second, leaving two at home.
        for target in [other, other, name("3"), name("3")] {
            s = run(s, [moveToWorkspace(target)]).0
        }
        #expect(s.workspaces.materialized.count == 3)

        let metrics = s.metrics()!
        let frames = s.workspaces.targetFrames(scrollOffset: s.motion.viewportOffset.current,
                                               metrics: metrics)
        #expect(frames.count == 6)
        let visible = Set(s.layout.visibleWindowIds(scrollOffset: s.motion.viewportOffset.current,
                                                    metrics: metrics))
        let parkedFrames = s.workspaces.allWindowIds.filter { !visible.contains($0) }
            .compactMap { frames[$0] }
        #expect(parkedFrames.count >= 4)
        for i in parkedFrames.indices {
            for j in (i + 1)..<parkedFrames.count {
                let (x, y) = (parkedFrames[i], parkedFrames[j])
                let ambiguous = abs(x.minX - y.minX) <= 2 && abs(x.minY - y.minY) <= 2
                    && abs(x.width - y.width) <= 2 && abs(x.height - y.height) <= 2
                #expect(!ambiguous, "park slots \(i) and \(j) are indistinguishable at rebind")
            }
        }
    }

    /// A settled desktop re-places nothing: the placement diff has to see a switched-and-returned world
    /// as already correct, or every idle event would re-issue the whole set of AX writes forever.
    @Test func aRoundTripLeavesNothingToRePlace() {
        var s = world(3)
        s = run(s, [focusWorkspace(other)]).0
        s = run(s, [focusWorkspace(home)]).0
        #expect(run(s, [.dragEnded]).1.isEmpty)
    }

    /// The externally-focused switch snaps whatever the config says: the rule is about who initiated the
    /// motion, and a Cmd-Tab is not us. Asserted against a *smooth* config, so the absent cover means
    /// something.
    @Test func externalCrossWorkspaceFocusSnapsEvenWithACoverAvailable() {
        let s = WorkspaceMotionTests.settled(
            WorkspaceMotionTests.smoothWorld(2, config: WorkspaceMotionTests.twoUp),
            .moveToWorkspace(.name(other)))
        let away = WindowId(2)
        #expect(s.workspaces.workspace(of: away) == other)
        #expect(!s.motion.isTransitioning)

        let (after, fx) = Engine.reduce(s, .focusChanged(away))
        #expect(after.workspaces.focused == other)
        #expect(!after.motion.isTransitioning, "an external focus raised a cover")
        #expect(!EngineTests.hasEffect(fx) { if case .capture = $0 { return true }; return false })
        #expect(tiled(in: fx) == [away])
        #expect(parked(in: fx) == [WindowId(1)])
    }
}

// MARK: - The vertical transition

/// A workspace switch in motion: the outgoing strip slides out and the incoming one slides in, under
/// the cover.
///
/// The claim every test here rests on is that a switch is a *structural edit* in exactly the sense
/// `Engine.finishStructuralEdit` already meant — before and after are two geometries, so what animates
/// is each window's displacement from where it now belongs, decaying to zero. The only new term is a
/// workspace's vertical offset relative to the focused one (`Workspaces.verticalOffset`), and it is a
/// sign rather than a distance.
@Suite struct WorkspaceMotionTests {

    // MARK: Fixtures

    /// One screen of vertical travel. The fixture display is 1000×800 with no struts, so this is 800 —
    /// the *physical* working height.
    static let screen = EngineTests.displayFrame.height

    /// Two half-width columns fill the viewport exactly: a two-window workspace is entirely on screen,
    /// so a switch has both strips' worth of windows in scope and nothing incidental parked.
    static let twoUp = EngineTests.halfWidth

    /// One column *is* the viewport, so each workspace can rest at a different, legible scroll offset —
    /// what the horizontal-cancellation test needs.
    static let oneColumn = Config(widthPresets: PresetCycle([.proportion(1.0)]))

    static func smoothWorld(_ count: UInt64, config: Config = twoUp) -> State {
        EngineTests.world(count, config: config)
    }

    private func name(_ c: Character) -> WorkspaceName { WorkspaceName(c)! }
    private let home = WorkspaceName.first
    private let other = WorkspaceName("2")!

    /// Drive a command and stop the instant the cover is up — the moment every claim below is about.
    private func raiseCover(_ s: State, _ command: Command) -> (State, [Effect]) {
        var (next, fx) = Engine.reduce(s, .command(command))
        #expect(next.motion.isTransitioning, "\(command) opened no transition")
        var raiseFx: [Effect] = []
        for id in EngineTests.capturedIds(in: fx) {
            let (after, out) = Engine.reduce(next, .captureReady(id))
            next = after
            raiseFx += out
        }
        fx += raiseFx
        #expect(next.motion.isCovered, "\(command) never raised a cover")
        return (next, fx)
    }

    /// A window's seeded displacement — where its layer starts relative to where the new geometry
    /// puts it.
    private func seed(_ s: State, _ id: WindowId) -> Rect? { s.motion.windowAnimator(id)?.current }

    /// Run one command all the way to rest — a workspace verb now opens a transition, so the effects it
    /// emits have to be answered or `settle` has nothing to tick towards (a `.capturing` session is
    /// inert under `tick`).
    static func settled(_ s: State, _ command: Command) -> State {
        let (next, fx) = Engine.reduce(s, .command(command))
        return EngineTests.settle(next, fx)
    }

    /// Two workspaces, two windows each, at rest and focused on `home`.
    private func twoPopulatedWorkspaces(_ config: Config = twoUp) -> State {
        var s = EngineTests.world(4, config: config)
        // Send the two right-hand windows to `other`, then visit it once so it is materialized with a
        // memory of its own, and come back.
        for _ in 0..<2 { s = Self.settled(s, .moveToWorkspace(.name(other))) }
        s = Self.settled(s, .focusWorkspace(.name(other)))
        s = Self.settled(s, .focusWorkspace(.name(home)))
        #expect(s.workspaces.focused == home)
        #expect(s.workspaces[home].allWindowIds.count == 2)
        #expect(s.workspaces[other].allWindowIds.count == 2)
        #expect(!s.motion.isTransitioning)
        return s
    }

    // MARK: The one new term

    /// A sign, not a distance: every unfocused workspace is exactly one screen away, which bounds a
    /// switch's capture scope to two screens of windows and makes `1 → z` the same motion as `1 → 2`.
    @Test func theVerticalOffsetIsASignAndNeverAMultiple() {
        var s = Self.smoothWorld(1)
        let metrics = s.metrics()!
        s.workspaces.focus(name("5"))
        #expect(s.workspaces.verticalOffset(of: name("5"), metrics: metrics) == 0)
        for after in ["6", "9", "0", "a", "z"] {
            #expect(s.workspaces.verticalOffset(of: name(Character(after)), metrics: metrics)
                    == Self.screen, "\(after)")
        }
        for before in ["4", "1"] {
            #expect(s.workspaces.verticalOffset(of: name(Character(before)), metrics: metrics)
                    == -Self.screen, "\(before)")
        }
    }

    /// The *physical* working height, not the content area: measured against `contentArea` a neighbour's
    /// edge would come to rest inside the outer-gap margin, which the cover paints.
    @Test func theTravelIsThePhysicalHeightNotTheContentArea() {
        var s = Self.smoothWorld(1, config: Config(widthPresets: PresetCycle([.proportion(0.5)]),
                                              outerGaps: EdgeInsets(uniform: 20)))
        let metrics = s.metrics()!
        #expect(metrics.contentArea.height < metrics.workingArea.height)
        s.workspaces.focus(other)
        #expect(s.workspaces.verticalOffset(of: home, metrics: metrics) == -metrics.workingArea.height)

        // …and a window on the strip above really does clear the screen rather than stopping in the gap.
        let frames = s.workspaces.naturalFrames(scrollOffset: 0, metrics: metrics)
        #expect(frames[WindowId(1)]!.maxY <= metrics.workingArea.minY)
    }

    // MARK: The switch, in flight

    /// One session, scoped to both strips, and both seeded with the *same* one-screen displacement —
    /// which is what makes them travel rigidly one screen apart rather than as two slides kept in step.
    @Test func bothStripsAreSeededWithOneIdenticalScreenOfDisplacement() {
        let s = twoPopulatedWorkspaces()
        let (after, _) = raiseCover(s, .focusWorkspace(.name(other)))

        #expect(after.workspaces.focused == other)
        // Two windows leaving, two arriving — and nothing else in the world to be in scope.
        #expect(Set(after.motion.transition!.windows) == Set(after.workspaces.allWindowIds))

        // `other` sorts after `home`, so the incoming strip comes up from below and both strips rise.
        for id in after.workspaces.allWindowIds {
            let d = seed(after, id)
            #expect(d != nil, "\(id) was not displaced")
            #expect(EngineTests.approx(d!, Rect(x: 0, y: Self.screen, width: 0, height: 0)),
                    "\(id) seeded \(d!)")
        }
    }

    /// The direction follows the lexicographic move, and it is the *only* thing that decides it: going
    /// back down the address space, both strips fall instead of rising.
    @Test func theDirectionFollowsTheLexicographicMove() {
        let s = Self.settled(twoPopulatedWorkspaces(), .focusWorkspace(.name(other)))
        #expect(s.workspaces.focused == other)

        let (after, _) = raiseCover(s, .focusWorkspace(.name(home)))
        for id in after.workspaces.allWindowIds {
            #expect(EngineTests.approx(seed(after, id)!,
                                       Rect(x: 0, y: -Self.screen, width: 0, height: 0)), "\(id)")
        }
    }

    /// The seed is purely vertical even when the two workspaces rest at different scrolls, and that is
    /// the ordering constraint the switch is written around: the outgoing offset is stored and the
    /// incoming one restored *between* the two `naturalFrames` reads, so the horizontal axis cancels.
    @Test func theSeedIsPurelyVerticalAcrossTwoDifferentScrollOffsets() {
        // Scroll `home` to its right-hand column; `other` is left resting at 0.
        let s = Self.settled(twoPopulatedWorkspaces(Self.oneColumn), .focus(.right))
        let homeOffset = s.motion.viewportOffset.current
        #expect(homeOffset > 0, "the fixture did not scroll")

        let (after, _) = raiseCover(s, .focusWorkspace(.name(other)))
        #expect(after.workspaces[scrollOffsetOf: home] == homeOffset)
        for id in after.workspaces.allWindowIds {
            guard let d = seed(after, id) else { continue }
            #expect(EngineTests.approxScalar(d.minX, 0), "\(id) was displaced sideways by \(d.minX)")
            #expect(EngineTests.approxScalar(abs(d.minY), Self.screen), "\(id) moved \(d.minY)")
        }
    }

    /// …and the outgoing strip stays put horizontally for the *whole* transition, not merely at the
    /// seed. It is drawn at its own stored offset, so a scroll happening on the workspace arriving
    /// cannot drag it along.
    @Test func theOutgoingStripDoesNotSlideSidewaysAsItLeaves() {
        let s = twoPopulatedWorkspaces(Self.oneColumn)
        var (after, _) = raiseCover(s, .focusWorkspace(.name(other)))
        // Only the windows that were *on screen* when we left are in scope — with one column to a
        // viewport that is one of the two, and the off-viewport one never had a layer to slide.
        let leaving = after.workspaces[home].allWindowIds.filter { after.motion.layerId(for: $0) != nil }
        #expect(!leaving.isEmpty, "nothing from the outgoing strip made it into the cover")

        var seen: [WindowId: Set<Double>] = [:]
        for _ in 0..<40 {
            guard after.motion.isCovered else { break }
            let (next, fx) = Engine.reduce(after, .tick(dt: 1.0 / 120))
            after = next
            for id in leaving {
                guard let layer = after.motion.layerId(for: id),
                      let frame = EngineTests.layerFrame(of: layer, in: fx) else { continue }
                seen[id, default: []].insert((frame.minX * 100).rounded() / 100)
            }
        }
        for id in leaving {
            #expect(seen[id]?.count == 1,
                    "\(id) took \(seen[id] ?? []) horizontal positions on its way out")
        }
    }

    /// The switch rides an open cover rather than abandoning it — an ordinary structural interrupt, so
    /// one session throughout and never a second.
    @Test func aSwitchMidScrollRidesTheOpenCover() {
        // `.left`, because the fixture comes back to `home` focused on its *rightmost* column, where
        // `.right` is the strip's no-wrap edge and opens nothing.
        let s = twoPopulatedWorkspaces(Self.oneColumn)
        var (scrolling, fx) = Engine.reduce(s, .command(.focus(.left)))
        for id in EngineTests.capturedIds(in: fx) {
            (scrolling, _) = Engine.reduce(scrolling, .captureReady(id))
        }
        #expect(scrolling.motion.isCovered, "the fixture never raised a cover to interrupt")
        let before = Set(scrolling.motion.transition!.windows)

        let (after, switchFx) = Engine.reduce(scrolling, .command(.focusWorkspace(.name(other))))
        #expect(!EngineTests.hasEffect(switchFx) { if case .endTransition = $0 { return true }; return false })
        #expect(after.motion.isCovered, "the switch tore the cover down")
        #expect(before.isSubset(of: Set(after.motion.transition!.windows)))
        #expect(after.workspaces.focused == other)

        // …and it settles onto the truth with nothing left in flight.
        let (done, _) = EngineTests.drive(after)
        #expect(!done.motion.isTransitioning)
        #expect(done.motion.windowAnimators.isEmpty)
        #expect(Engine.reduce(done, .dragEnded).1.isEmpty,
                "the settled desktop still wanted re-placing")
    }

    /// A second switch mid-flight is a nudge, not a restart: position continuous, velocity carried, still
    /// one session. And a strip you have already left is not moved again — the sign function's other
    /// half: `1` is one screen above `2` and above `3` alike, so the first press's outgoing strip
    /// finishes the slide it was on. That keeps a spammed switch a two-strip motion, not a ribbon.
    @Test func aSecondSwitchMidFlightIsOneSessionAndOneNudge() {
        let s = twoPopulatedWorkspaces()
        var (after, _) = raiseCover(s, .focusWorkspace(.next))
        for _ in 0..<4 { (after, _) = Engine.reduce(after, .tick(dt: 1.0 / 120)) }

        let arriving = after.workspaces[other].allWindowIds.first!
        let alreadyLeft = after.workspaces[home].allWindowIds.first!
        let midFlight = after.motion.windowAnimator(arriving)!.current
        let settling = after.motion.windowAnimator(alreadyLeft)!.current
        #expect(midFlight.minY < Self.screen && midFlight.minY > 0, "the fixture never got mid-flight")

        let (again, _) = Engine.reduce(after, .command(.focusWorkspace(.next)))
        #expect(again.workspaces.focused == name("3"))
        #expect(again.motion.isCovered, "the second press opened a second session")
        // `2` is the outgoing strip now: the nudge *adds* the new screen to what was still in flight,
        // so the layer never jumps — one continuous motion through two addresses.
        #expect(EngineTests.approxScalar(again.motion.windowAnimator(arriving)!.current.minY,
                                         midFlight.minY + Self.screen))
        // …while `1`, already one screen up and still one screen up, is left alone to finish.
        #expect(EngineTests.approxScalar(again.motion.windowAnimator(alreadyLeft)!.current.minY,
                                         settling.minY))
    }

    /// Switching onto an empty workspace still animates: the outgoing strip slides away and what is
    /// revealed is bare desktop, with focus left resting off the strip.
    @Test func switchingToAnEmptyWorkspaceStillSlidesTheOutgoingStripAway() {
        let s = Self.smoothWorld(2)
        let (after, _) = raiseCover(s, .focusWorkspace(.name(name("9"))))
        #expect(after.workspaces[name("9")].isEmpty)
        #expect(after.motion.transition!.windows.count == 2)
        for id in [WindowId(1), WindowId(2)] {
            #expect(EngineTests.approx(seed(after, id)!,
                                       Rect(x: 0, y: Self.screen, width: 0, height: 0)))
        }
        #expect(after.layout.columnIndex(ofWindow: after.world.focusedWindow ?? WindowId(0)) == nil)
    }

    // MARK: The two move verbs

    /// `move-to-workspace` without following falls out of the same table: the moved window's "after" is
    /// one screen away, so it flies toward its new workspace while the columns it left close ranks
    /// behind it — and it is the mover, so it is drawn over them on the way.
    @Test func movingWithoutFollowingFliesTheWindowTowardItsNewWorkspace() {
        let s = Self.smoothWorld(2)
        let moved = s.world.focusedWindow!
        let (after, fx) = raiseCover(s, .moveToWorkspace(.name(other)))

        #expect(after.workspaces.focused == home)
        #expect(after.workspaces[other].allWindowIds == [moved])
        // One screen *down*, because `other` sorts after the workspace we are still on — and the seed
        // carries the horizontal move too, because it flies to where it will genuinely be: the
        // destination's first column rather than the second column it is leaving.
        let flight = seed(after, moved)!
        #expect(EngineTests.approxScalar(flight.minY, -Self.screen))
        #expect(flight.minX > 0, "the moved window did not travel to its new column")
        // The survivor closes ranks — horizontally, on the strip it is still on.
        let stayed = WindowId(1)
        #expect(EngineTests.approxScalar(seed(after, stayed)?.minY ?? 0, 0))
        #expect(after.motion.elevatedLayer == after.motion.layerId(for: moved))
        #expect(EngineTests.hasEffect(fx) { if case .elevateLayer = $0 { return true }; return false })
    }

    /// The follow verb differs by geometry rather than choreography: the moved window is on the focused
    /// workspace both before *and* after, so its seed is purely horizontal — it glides into its new
    /// column while everything else on both strips travels a screen.
    @Test func theFollowVerbCarriesTheMovedWindowHorizontally() {
        let s = twoPopulatedWorkspaces()
        let moved = s.world.focusedWindow!
        let (after, _) = raiseCover(s, .moveToWorkspaceAndFocus(.name(other)))

        #expect(after.workspaces.focused == other)
        #expect(after.world.focusedWindow == moved)
        #expect(EngineTests.approxScalar(seed(after, moved)?.minY ?? 0, 0),
                "the followed window travelled vertically")
        for id in after.workspaces.allWindowIds where id != moved {
            #expect(EngineTests.approxScalar(abs(seed(after, id)?.minY ?? 0), Self.screen), "\(id)")
        }
    }

    // MARK: The raise blits

    /// A layer starts at its capture-time frame, and for a switch that is a screen away from where it
    /// belongs: the incoming workspace's windows are captured at their 1 px park slivers. So the raise
    /// must place every layer as well as create it, inside the same presentation run and before any real
    /// window moves, or the first frame shows the arriving strip stacked in the corner.
    @Test func theRaiseBlitsEveryLayerBeforeAnyRealWindowMoves() {
        let s = twoPopulatedWorkspaces()
        var (next, fx) = Engine.reduce(s, .command(.focusWorkspace(.name(other))))
        var raise: [Effect] = []
        for id in EngineTests.capturedIds(in: fx) {
            let (after, out) = Engine.reduce(next, .captureReady(id))
            next = after
            if !out.isEmpty { raise = out }
        }
        #expect(next.motion.isCovered)

        // Every binding is placed…
        let bindings = next.motion.transition!.bindings
        for binding in bindings {
            #expect(EngineTests.layerFrame(of: binding.layer, in: raise) != nil,
                    "\(binding.window) was raised without being placed")
        }
        // …and the whole presentation run precedes the first `setFrame`/`park`, so the shell wraps it
        // in one `CATransaction` and no real window has moved when it lands.
        let lastBlit = raise.lastIndex { if case .setLayerFrame = $0 { return true }; return false }
        let firstMove = raise.firstIndex {
            switch $0 { case .setFrame, .park: return true; default: return false }
        }
        #expect(lastBlit != nil && firstMove != nil && lastBlit! < firstMove!)

        // And the placement is the *old* geometry exactly, so the raise cannot pop: the arriving strip
        // sits one screen below, where the eye has not seen it yet.
        let metrics = next.metrics()!
        for binding in bindings where next.workspaces[other].columnIndex(ofWindow: binding.window) != nil {
            let placed = EngineTests.layerFrame(of: binding.layer, in: raise)!
            #expect(EngineTests.approxScalar(placed.minY, metrics.contentArea.minY + Self.screen),
                    "\(binding.window) was blitted to \(placed)")
        }
    }

    // MARK: The residual, characterized rather than hidden

    /// Spam `focus-workspace next` across a populated address space and report the widest hole the cover
    /// ever showed, using the same frame-stepped instrument as the scroll (`EngineTests.LatentWorld`).
    ///
    /// `gapFrames == nil` lets each press run to rest before the next one, whatever the capture latency
    /// costs; a number presses again after exactly that many frames, settled or not.
    private static func worstHoleWhileSwitching(presses: Int, gapFrames: Int?,
                                                captureLatency: Int) -> Double {
        var w = EngineTests.LatentWorld(EngineTests.world(8, config: twoUp),
                                        captureLatency: captureLatency)
        var worst = 0.0
        func run(to rest: Bool, frames: Int) {
            var step = 0
            while step < frames || (rest && w.state.motion.isTransitioning) {
                guard step < 5000 else { return }
                w.step()
                worst = max(worst, w.hole())
                step += 1
            }
        }
        // Two windows on each of "1"…"4", so every address the spam walks onto has something to draw.
        for target in ["4", "4", "3", "3", "2", "2"] {
            w.send(.command(.moveToWorkspace(.name(WorkspaceName(Character(target))!))))
            run(to: true, frames: 0)
        }
        worst = 0                                   // the fixture's own motion is not under test

        for _ in 0..<presses {
            w.send(.command(.focusWorkspace(.next)))
            worst = max(worst, w.hole())
            run(to: gapFrames == nil, frames: gapFrames ?? 0)
        }
        run(to: true, frames: 0)
        return worst
    }

    /// A switch allowed to finish never shows a hole, at any capture latency: an uninterrupted transition
    /// raises no cover until every still is in. This is the guarantee; the next test is its boundary.
    @Test(arguments: [4, 8, 30, 60] as [Int])
    func aSwitchAllowedToSettleNeverShowsAHole(captureLatency: Int) {
        #expect(Self.worstHoleWhileSwitching(presses: 4, gapFrames: nil,
                                             captureLatency: captureLatency) == 0)
    }

    /// A second press landing before the cover is up costs nothing — its captures join the batch the
    /// raise is already waiting on, which is most of the fast-spam case.
    @Test(arguments: [2, 4, 8, 16, 30] as [Int])
    func aSecondPressBeforeTheRaiseJoinsTheBatchForFree(captureLatency: Int) {
        #expect(Self.worstHoleWhileSwitching(presses: 8, gapFrames: captureLatency,
                                             captureLatency: captureLatency) == 0)
    }

    /// The residual, as a number. A second `next-workspace` pressed *after* the cover is up aims at a
    /// workspace nothing has captured, and the user sees a band of desktop at the screen edge the
    /// arriving strip enters from.
    ///
    /// Unlike a scroll, a switch has no runway: the next workspace is *flush* with the screen edge, so
    /// its layers expose the band on the first frame of motion, and the band is simply how far the spring
    /// travels during the capture round trip — 65 pt at a 2-frame batch, 195 at 4 (≈ the real 36 ms one),
    /// 450 at 8, on an 800 pt-tall screen. Accepted rather than closed (the fix is capturing shoulder
    /// *workspaces*, an extra screen of stills on every switch); bounded here so a regression fails.
    @Test(arguments: zip([2, 4, 8] as [Int], [70.0, 200.0, 460.0] as [Double]))
    func aSwitchInterruptedAfterTheRaiseExposesABandBoundedByTheSpring(
        captureLatency: Int, bound: Double
    ) {
        let worst = Self.worstHoleWhileSwitching(presses: 8, gapFrames: captureLatency * 3,
                                                 captureLatency: captureLatency)
        #expect(worst > 0, "the fixture stopped reproducing the residual it exists to bound")
        #expect(worst <= bound, "an interrupted switch exposed \(worst) pt of desktop")
    }
}
