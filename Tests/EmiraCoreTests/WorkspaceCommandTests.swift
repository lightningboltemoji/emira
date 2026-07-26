import Foundation
import Testing
@testable import EmiraCore

// The workspace *verbs* (`WORKSPACE-B.md`) — the slice that made the model of 2026-07-26 usable:
// `focus-workspace`, `move-to-workspace`, `move-to-workspace-and-focus`, the five ways to name an
// address, per-workspace scroll and focus memory, and the cross-workspace focus a real desktop
// produces whether or not we handle it.
//
// Everything here **snaps** — no cover is raised for a switch and none is expected in these effect
// streams. That is `PRINCIPLES.md` §4a and a deliberate slice boundary, not a gap: the vertical
// transition is its own slice, and the last three times this project animated something it found a
// bug the snap had been hiding.

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
    /// through addresses nobody has ever visited. It follows the **key** order, so the number row runs
    /// off its right end into `0` before reaching the letters.
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

    /// **Clamps, never wraps** — the same rule `focus left|right` keeps at the strip's edges, one axis
    /// over. Resolving to the workspace you are on is how "nowhere to go" is spelled, and the reducer
    /// turns that into silence in one place.
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
    /// strip offset `1000n` and every scroll number below is readable at a glance. Used where the test
    /// is about *scrolling*.
    static let oneColumn = Config(widthPresets: PresetCycle([.proportion(1.0)]))

    /// Two half-width columns fill the 1000-pt viewport exactly, so a two-window workspace is entirely
    /// on screen at offset 0. Used where the test is about *tiled versus parked*, because then the
    /// whole strip changes state on a switch and the placement diff has something to say about all of
    /// it.
    static let twoUp = EngineTests.halfWidth

    private func name(_ c: Character) -> WorkspaceName { WorkspaceName(c)! }

    /// The launch address — `"1"` since the domain took the key order (2026-07-26). Named rather than
    /// spelled, so a later change to where the daemon starts is one line here.
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
    /// Distinct from `tiled(in:)` on purpose, and the distinction is worth stating once. The effect
    /// stream is a **diff**: a window already sitting at the frame it is meant to be at emits nothing,
    /// which is exactly what keeps an idle desktop quiet, and it means a park slot that happens not to
    /// change across a switch produces no `.park`. So "what moved" and "where things are" are two
    /// different questions and the tests below ask whichever one they mean.
    private func onScreen(_ s: State) -> Set<WindowId> {
        Set(s.layout.visibleWindowIds(scrollOffset: s.motion.viewportOffset.current,
                                      metrics: s.metrics()!))
    }

    // MARK: focus-workspace

    /// The headline: leaving parks the whole outgoing strip, arriving tiles the incoming one — and it
    /// needed no new mechanism, because "everything that is not the focused strip is parked" is what
    /// `Workspaces.targetFrames` already meant.
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

    /// A switch to where you already are says nothing at all. This is also how `next` at `"z"` and an
    /// occupied motion with nowhere to go come out — `Workspaces.resolve` clamps, and the reducer
    /// turns "resolved to here" into silence in exactly one place.
    @Test func switchingToTheFocusedWorkspaceIsSilent() {
        let s = world(2)
        for ref: WorkspaceRef in [.name(.first), .previous, .previousOccupied, .nextOccupied] {
            let (after, fx) = run(s, [.command(.focusWorkspace(ref))])
            #expect(fx.isEmpty, "\(ref) emitted \(fx)")
            #expect(after == s, "\(ref) changed the state")
        }
    }

    /// **The property Tanner asked for by name.** Scroll position survives `0 → 1 → 0`, and it is one
    /// stored `Double` because the switch is the only thing that reads or writes it.
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

    /// An **empty** workspace has nothing to focus, so focus is left resting off the strip — an
    /// already-supported state, not a case wanting a rule of its own. The proof is that the very next
    /// `focus left|right` recovers, which is `handleFocus`'s off-strip entry condition doing its job.
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

    /// It moves a **window**, not its column — `move-window`'s vocabulary — so a window with
    /// stackmates leaves them behind, and the column it left survives.
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

    /// Focus stays on this workspace and lands on the neighbour — literally the same `successor`
    /// call a close makes.
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
        var s = world(1)
        let (after, fx) = run(s, [.command(.moveToWorkspace(.name(name("z"))))])
        #expect(after.workspaces[.first].isEmpty)
        #expect(after.world.focusedWindow == nil)
        #expect(focused(in: fx).isEmpty)
        #expect(parked(in: fx) == [WindowId(1)])                       // parked on "z", not tiled here
    }

    /// The follow verb differs from its sibling in exactly one thing: where focus ends up. The moved
    /// window keeps it, on the destination.
    @Test func theFollowVerbSwitchesAndKeepsFocusOnTheMovedWindow() {
        var s = world(2, config: Self.twoUp)
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

    /// A moved window becomes the destination's remembered focus, and the *next* window sent there
    /// opens beside it — the same rule a freshly-opened window follows. So a run of
    /// moves builds a group in the order it was sent instead of scattering at the far end.
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

    /// Cmd-Tab, a Dock click, an app raising its own window: `focusChanged` can now name a window on a
    /// workspace nobody is looking at. §4a's promise is about the *window* — the user must never be
    /// focused on something they cannot see — so it snap-switches and then reveals.
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
        // **No `.focus`**: the shell already moved focus, and asking again is a redundant AX set — and
        // the echo we would then have to absorb.
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

        // Feed our own effect back exactly as the shell's AX observer would. **Emitting nothing is the
        // proof**: an effect stream with no `.focus`, no `.setFrame` and no `.park` in it cannot echo
        // again, so the sequence terminates rather than merely happening to.
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
        var s = world(3)
        let (after, fx) = run(s, [.focusChanged(WindowId(1))])
        #expect(after.workspaces.focused == .first)
        #expect(after.world.focusedWindow == WindowId(1))
        #expect(focused(in: fx).isEmpty)
        #expect(tiled(in: fx).contains(WindowId(1)))
    }

    // MARK: Placement across the whole set

    /// Every parked window — on *any* unfocused workspace — gets a slot no other window shares, within
    /// the ±2 pt tolerance the first-sight identity join binds at (`PRINCIPLES.md` §7). Asserted
    /// through the verbs, because that is how a real desktop reaches a populated workspace set.
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

    // MARK: Interaction with an in-flight transition

    /// A cover is a picture of **one** workspace, so a switch arriving mid-scroll abandons it rather
    /// than retargeting it — the layers are bound to windows that are about to be parked wholesale.
    @Test func aSwitchMidTransitionEndsTheCoverRatherThanRetargetingIt() {
        var s = world(4)
        let (scrolling, scrollFx) = Engine.reduce(s, .command(.focus(.left)))
        s = scrolling
        #expect(s.motion.isTransitioning, "the fixture did not open a transition")
        // Raise the cover, so this is the hardest case: real layers up, reals teleported behind them.
        for id in EngineTests.capturedIds(in: scrollFx) {
            s = Engine.reduce(s, .captureReady(id)).0
        }
        #expect(s.motion.isCovered)

        let (after, fx) = Engine.reduce(s, .command(.focusWorkspace(.name(other))))
        #expect(fx.contains { if case .endTransition = $0 { return true }; return false })
        #expect(!after.motion.isTransitioning)
        #expect(after.workspaces.focused == other)
        #expect(onScreen(after).isEmpty)                    // the strip under the cover is fully parked
        // The cover comes down before anything is re-placed, so the shell never blits a layer for a
        // window that has just been sent off screen.
        let endIndex = fx.firstIndex { if case .endTransition = $0 { return true }; return false }
        let firstPlacement = fx.firstIndex {
            switch $0 { case .setFrame, .park: return true; default: return false }
        }
        #expect(endIndex! < (firstPlacement ?? Int.max))
    }

    /// …and the offset the abandoned scroll was travelling *to* is what the workspace remembers, not
    /// wherever it happened to be when the key was pressed. `closeTransition` snaps to the target, so
    /// coming back resumes where the scroll would have come to rest.
    @Test func anAbandonedScrollIsRememberedAtItsDestination() {
        var s = world(4)
        let (scrolling, scrollFx) = Engine.reduce(s, .command(.focus(.left)))
        s = scrolling
        let destination = s.motion.viewportOffset.target
        #expect(destination != s.motion.viewportOffset.current, "the fixture did not scroll")
        for id in EngineTests.capturedIds(in: scrollFx) { s = Engine.reduce(s, .captureReady(id)).0 }

        s = Engine.reduce(s, .command(.focusWorkspace(.name(other)))).0
        #expect(EngineTests.approxScalar(s.workspaces[scrollOffsetOf: .first], destination))
        s = run(s, [focusWorkspace(home)]).0
        #expect(EngineTests.approxScalar(s.motion.viewportOffset.current, destination))
    }
}
