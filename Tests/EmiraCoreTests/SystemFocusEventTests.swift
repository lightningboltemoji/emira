import Foundation
import Testing
@testable import EmiraCore

// `[focus] system-events`: which focus changes emira did not cause it honours.
//
// The whole feature is one guard on the `focusChanged` path, so almost every test here is a pair — the
// same event under two policies — and the assertion that carries the file is what a *refusal* costs:
// one `.focus` effect putting our own focus back, and no state change whatsoever. A refusal that moved
// the viewport, switched a workspace or raised a cover would be the transition the user is trying to
// stop seeing.
//
// Everything snaps (`transitionMode: .off`) for `EngineTests.halfWidthSnap`'s reason, except where
// a raised cover is the thing under test.

@Suite struct SystemFocusEventTests {

    // MARK: - Fixtures

    /// Two ½-width columns fill the 1000-pt viewport exactly, so a two-window world is entirely on
    /// screen and a third column is unambiguously off it.
    static let twoUp = EngineTests.halfWidthSnap

    /// One full-width column *is* the viewport, so column *n* is on screen only at offset 1000*n*.
    static let oneColumn = Config(widthPresets: PresetCycle([.proportion(1.0)]),
                                  transitionMode: .off)

    private static func policy(_ mode: SystemFocusEvents, _ base: Config) -> Config {
        var config = base
        config.systemFocusEvents = mode
        return config
    }

    private func world(_ count: UInt64, _ mode: SystemFocusEvents, _ base: Config = twoUp) -> State {
        EngineTests.world(count, config: Self.policy(mode, base))
    }

    private func run(_ s: State, _ events: [Event]) -> (State, [Effect]) {
        EngineTests.run(s, events)
    }

    /// One system focus event — the thing the config key is named for: a report nobody here asked for,
    /// which is a Cmd-Tab, a Dock click, a click on a window, or an app raising itself.
    private func systemEvent(_ id: WindowId?) -> Event { .focusChanged(id, origin: .system) }

    private func moveToWorkspace(_ name: Character) -> Event {
        .command(.moveToWorkspace(.name(WorkspaceName(name)!)))
    }

    private func focused(in fx: [Effect]) -> [WindowId] {
        fx.compactMap { if case .focus(let w) = $0 { return w }; return nil }
    }

    /// The windows on screen right now, asked of the *state* rather than of an effect diff.
    private func onScreen(_ s: State) -> Set<WindowId> {
        Set(s.layout.visibleWindowIds(scrollOffset: s.motion.viewportOffset.current,
                                      metrics: s.metrics()!))
    }

    /// Assert that a report was refused: focus put back where it was, and nothing else happened at all.
    private func expectRefused(_ before: State, _ report: Event,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        let restore = before.world.focusedWindow
        let (after, fx) = Engine.reduce(before, report)
        #expect(fx == [.focus(restore!)], "expected one restoring focus, got \(fx)",
                sourceLocation: sourceLocation)
        #expect(after == before, "a refusal changed the state", sourceLocation: sourceLocation)
    }

    /// Assert that a report was honoured: focus moved to the window it named.
    private func expectAdmitted(_ before: State, _ report: Event, _ id: WindowId,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        let (after, _) = Engine.reduce(before, report)
        #expect(after.world.focusedWindow == id, sourceLocation: sourceLocation)
    }

    // MARK: - The bug this exists for

    /// An app bringing its own parked window forward from a workspace nobody is looking at — dismissing
    /// a floating reminder is enough — drags the whole desktop to that workspace under `respect`. That
    /// is macOS's behaviour faithfully followed, and it is the thing being switched off.
    @Test func anAppRaisingItselfOnAnotherWorkspaceIsRefusedUnderOnScreen() {
        var s = world(2, .onScreen, Self.oneColumn)
        s = run(s, [moveToWorkspace("3")]).0        // window 2 leaves; focus falls to window 1
        let away = WindowId(2)
        #expect(s.workspaces.workspace(of: away) == WorkspaceName("3")!)
        #expect(s.workspaces.focused == .first)
        #expect(s.world.focusedWindow == WindowId(1))

        expectRefused(s, systemEvent(away))
    }

    /// The same event under the default policy, so the pair proves the config key is what decides and
    /// not something incidental to the fixture.
    @Test func theSameReportUnderRespectStillSwitchesWorkspaces() {
        var s = world(2, .respect, Self.oneColumn)
        s = run(s, [moveToWorkspace("3")]).0
        let away = WindowId(2)

        let (after, fx) = Engine.reduce(s, systemEvent(away))
        #expect(after.workspaces.focused == WorkspaceName("3")!)
        #expect(after.world.focusedWindow == away)
        #expect(focused(in: fx).isEmpty, "the shell already moved focus; asking again is an echo")
    }

    /// `respect` is not merely the default value — it is the absence of the mechanism. Swept over every
    /// shape the other two modes refuse.
    @Test func respectAdmitsEveryReportTheOtherModesRefuse() {
        var s = world(3, .respect, Self.oneColumn)
        s = run(s, [moveToWorkspace("3")]).0
        for id in s.world.windows.keys.sorted() {
            expectAdmitted(s, systemEvent(id), id)
        }
    }

    // MARK: - `on-screen`: honoured iff you can already see it

    /// The compromise the mode is named for. Two ½-width columns fill the viewport, so clicking the
    /// neighbour is a focus change that reveals nothing — and there is nothing to protect the user from.
    @Test func onScreenAdmitsAClickOnAWindowThatIsAlreadyVisible() {
        let s = world(2, .onScreen)
        #expect(onScreen(s) == [WindowId(1), WindowId(2)])
        #expect(s.world.focusedWindow == WindowId(2))

        expectAdmitted(s, systemEvent(WindowId(1)), WindowId(1))
    }

    /// The same workspace, so nothing switches — but the column is scrolled off the viewport, and
    /// honouring it would scroll the strip. Parked is parked whether or not a workspace boundary is
    /// involved, which is why the predicate asks about the viewport and not about the address.
    @Test func onScreenRefusesAColumnScrolledOffTheViewport() {
        let s = world(3, .onScreen, Self.oneColumn)      // one column fills the screen
        #expect(onScreen(s) == [WindowId(3)])
        #expect(s.world.focusedWindow == WindowId(3))

        expectRefused(s, systemEvent(WindowId(1)))
    }

    /// A window emira does not place is wherever its app put it, which is in view — so a float, a
    /// dialog or a sheet taking focus is honoured. Off the strip and off the screen are different sets,
    /// and this is the half of the difference that is visible.
    @Test func onScreenAdmitsAFloatBecauseAFloatIsInView() {
        var s = world(2, .onScreen, Self.oneColumn)
        let dialog = WindowId(9)
        s = run(s, [.windowCreated(EngineTests.snapshot(9, role: .dialog))]).0
        #expect(s.world.isFloating(dialog))
        #expect(s.workspaces.workspace(of: dialog) == nil, "a float is on no strip")
        s = run(s, [systemEvent(WindowId(2))]).0        // put focus somewhere refusable-from

        expectAdmitted(s, systemEvent(dialog), dialog)
    }

    /// And the other half: a minimized window is off the strip too, and it is in the Dock. Asking
    /// `participatesInStrip` alone would admit this one for the float's reason, which is why the
    /// predicate tests the two facts that are not about the strip *first*.
    @Test func onScreenRefusesAMinimizedWindowEvenThoughItIsOffTheStripLikeAFloat() {
        var s = world(2, .onScreen)
        let hidden = WindowId(1)
        s = run(s, [.windowMinimized(hidden)]).0
        #expect(s.world.windows[hidden]?.isMinimized == true)
        #expect(s.workspaces.workspace(of: hidden) == nil, "off the strip, exactly like a float")
        #expect(s.world.focusedWindow == WindowId(2))

        expectRefused(s, systemEvent(hidden))
    }

    /// `Cmd-H`, the third way off the strip: a fact about the app rather than about the window, and the
    /// one the on-screen test needs `World.isAppHidden` for. Driven by folding the flag directly, because
    /// no observation carries an app hide yet — `World` models it ahead of the wiring, and the predicate
    /// is written to the model rather than to what currently reaches it.
    @Test func onScreenRefusesAWindowOfAnAppThatIsHidden() {
        var s = world(2, .onScreen)
        s = run(s, [systemEvent(WindowId(2))]).0
        s.world.setAppHidden("com.test.app", true)
        s.workspaces.reconcile(stripWindowIds: s.world.stripWindowIds)
        #expect(!s.world.participatesInStrip(WindowId(1)))

        expectRefused(s, systemEvent(WindowId(1)))
    }

    // MARK: - `ignore`: honoured only for windows emira does not place

    /// The strictest mode takes focus between tiled windows for emira alone, so even a click on the
    /// visible neighbour bounces — the one thing `on-screen` exists to keep.
    @Test func ignoreRefusesEvenAWindowThatIsPlainlyOnScreen() {
        let s = world(2, .ignore)
        #expect(onScreen(s) == [WindowId(1), WindowId(2)])

        expectRefused(s, systemEvent(WindowId(1)))
    }

    /// …and still honours a float, which is not a grudging exception: emira already declines an opinion
    /// about where a float *sits*, and policing focus onto one is the same opinion. It is also what
    /// keeps a modal save sheet usable, since at this layer a sheet and a Cmd-Tab are one notification.
    @Test func ignoreStillAdmitsAWindowEmiraDoesNotPlace() {
        var s = world(2, .ignore)
        let sheet = WindowId(9)
        s = run(s, [.windowCreated(EngineTests.snapshot(9, role: .sheet))]).0
        #expect(s.world.isFloating(sheet))

        expectAdmitted(s, systemEvent(sheet), sheet)
    }

    /// The ladder is monotone, and it is asserted rather than argued: every window `ignore` admits,
    /// `on-screen` admits, and every window `on-screen` admits, `respect` admits. Over one fixture
    /// holding every shape that differs — a visible tiled neighbour, a window on another workspace, a
    /// float, and one in the Dock — so each containment is strict and the modes are told apart by
    /// something other than the default.
    ///
    /// Focus is arranged by the *arrangement*, never by a focus report: a report is the thing under
    /// test, and one refused mid-setup would leave the three runs standing somewhere different.
    @Test func theThreeModesFormANestedLadder() {
        let focus = WindowId(3)

        func admitted(_ mode: SystemFocusEvents) -> Set<WindowId> {
            var s = world(4, mode, Self.twoUp)
            s = run(s, [moveToWorkspace("3")]).0                             // window 4 goes away
            s = run(s, [.windowCreated(EngineTests.snapshot(9, role: .dialog))]).0   // a float
            s = run(s, [.windowMinimized(WindowId(1))]).0                    // and one in the Dock
            #expect(s.world.focusedWindow == focus, "\(mode) lost its footing")
            #expect(onScreen(s) == [WindowId(2), focus], "\(mode): \(onScreen(s))")
            return Set(s.world.windows.keys.filter { id in
                id != focus && Engine.reduce(s, systemEvent(id)).0.world.focusedWindow == id
            })
        }

        let strictest = admitted(.ignore)
        let middle = admitted(.onScreen)
        let loosest = admitted(.respect)
        #expect(strictest == [WindowId(9)], "\(strictest)")                  // the float alone
        #expect(middle == [WindowId(9), WindowId(2)], "\(middle)")           // …plus the neighbour
        #expect(loosest == [WindowId(9), WindowId(2), WindowId(1), WindowId(4)], "\(loosest)")
        #expect(strictest.isSubset(of: middle) && middle.isSubset(of: loosest))
    }

    // MARK: - What is never refused, whatever the policy

    /// Our own echo. The reducer wrote that focus optimistically when it emitted the effect, so a policy
    /// that could refuse it would make every focus command emira issues fight itself — and `ignore`,
    /// which refuses every tiled window, is where that would bite hardest.
    @Test func ourOwnFocusIsNeverRefusedEvenUnderIgnore() {
        let s = world(3, .ignore, Self.oneColumn)
        #expect(s.world.focusedWindow == WindowId(3))

        // The command moves focus and announces it…
        let (moved, fx) = Engine.reduce(s, .command(.focus(.left)))
        #expect(moved.world.focusedWindow == WindowId(2))
        #expect(focused(in: fx) == [WindowId(2)])
        // …and the AX echo of that announcement comes back, naming a window `ignore` would refuse from
        // any other source. Absorbed, not fought.
        let settled = EngineTests.settle(moved, fx)
        let (echoed, echoFx) = Engine.reduce(settled, .focusChanged(WindowId(2), origin: .ours))
        #expect(echoFx.isEmpty, "the echo produced \(echoFx)")
        #expect(echoed.world.focusedWindow == WindowId(2))
    }

    /// `nil` names no window, so there is nothing to ask the policy about — and refusing it would break
    /// ⌘N, since an app focuses its brand-new window before emira has adopted it and the resulting
    /// `focusChanged(nil)` lands a moment *before* the creation.
    @Test func focusLeavingEveryManagedWindowIsNeverRefused() {
        for mode in SystemFocusEvents.allCases {
            let s = world(2, mode)
            let (after, fx) = Engine.reduce(s, systemEvent(nil))
            #expect(after.world.focusedWindow == nil, "\(mode) held on to focus")
            #expect(fx.isEmpty, "\(mode) emitted \(fx)")
        }
    }

    /// …and the ⌘N sequence itself, end to end: the new window still arrives and still takes focus under
    /// the strictest policy, because an arrival is not a focus report.
    @Test func aNewWindowStillTakesFocusUnderIgnore() {
        var s = world(2, .ignore)
        s = run(s, [systemEvent(nil)]).0                    // the clear that precedes every ⌘N
        let (after, _) = run(s, [.windowCreated(EngineTests.snapshot(3))])
        #expect(after.world.focusedWindow == WindowId(3))
    }

    /// With no focus of our own there is nothing to answer with, and a desktop with no key window at all
    /// is worse than a focus we did not want. Reachable: `focusChanged(nil)` is admitted by the rule
    /// above, which is exactly how the core arrives here.
    @Test func aReportIsAdmittedWhenThereIsNoFocusToPutBack() {
        var s = world(3, .ignore, Self.oneColumn)
        s = run(s, [systemEvent(nil)]).0
        #expect(s.world.focusedWindow == nil)

        expectAdmitted(s, systemEvent(WindowId(1)), WindowId(1))
    }

    /// A report naming the window that already holds focus. Nothing to restore it to but itself, and
    /// emitting a `.focus` at it would be an AX set that can make an app raise a *different* window.
    @Test func aReportNamingTheAlreadyFocusedWindowEmitsNoRestore() {
        let s = world(3, .ignore, Self.oneColumn)
        #expect(s.world.focusedWindow == WindowId(3))

        let (after, fx) = Engine.reduce(s, systemEvent(WindowId(3)))
        #expect(!EngineTests.hasEffect(fx) { if case .focus = $0 { return true }; return false })
        #expect(after.world.focusedWindow == WindowId(3))
    }

    /// Before the first `screensChanged` there is no geometry to judge a window against, and no grounds
    /// to refuse is not a refusal. Otherwise the policy would swallow every focus report a booting
    /// daemon sees, on a strip it cannot yet lay out.
    @Test func nothingIsRefusedBeforeADisplayIsKnown() {
        var s = State(config: Self.policy(.ignore, Self.twoUp))
        for raw in UInt64(1)...2 { s = Engine.reduce(s, .windowCreated(EngineTests.snapshot(raw))).0 }
        #expect(s.metrics() == nil)

        expectAdmitted(s, systemEvent(WindowId(1)), WindowId(1))
    }

    // MARK: - Mid-transition

    /// The predicate reads `viewportOffset.target`, not `.current`, because `teleportBehindCover` moves
    /// the real windows to the destination's frames the moment a cover goes up. Mid-scroll the target is
    /// where they actually are — so a window the scroll is travelling *to* is on screen, and refusing it
    /// would fight a reveal already in flight.
    @Test func aWindowTheLiveScrollIsHeadedForCountsAsOnScreen() {
        var config = Self.policy(.onScreen, EngineTests.fullWidth)
        config.transitionMode = .smooth
        var s = EngineTests.world(3, config: config)
        #expect(s.world.focusedWindow == WindowId(3))

        // Scroll left to window 1 and raise the cover, but do not let it settle.
        var (moving, fx) = Engine.reduce(s, .command(.focus(.left)))
        (moving, fx) = Engine.reduce(moving, .command(.focus(.left)))
        for id in EngineTests.capturedIds(in: fx) {
            (moving, _) = Engine.reduce(moving, .captureReady(id))
        }
        s = moving
        #expect(s.motion.isTransitioning)
        let target = WindowId(1)
        #expect(!onScreen(s).contains(target), "the viewport has not arrived yet")

        expectAdmitted(s, systemEvent(target), target)
    }
}
