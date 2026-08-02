import Foundation
import Testing
@testable import EmiraCore

// The pointer plane's half of the reducer: one post-pass over a command's batch, one event that undoes
// it, and one that puts it back. What is asserted here is the *policy* — which events hide, which do
// not, and that a command does not pay a second hide for a pointer already hidden.
//
// The platform facts underneath are recorded in the change files rather than asserted: that a warp
// posts no event, that the private connection property is what makes a background app's hide take
// effect at all, and that another app activating **discards** that hide — which is why
// `Event.appActivated` exists and why `isCursorHidden` is an intent rather than a fact — are facts
// about the window server that no unit test can witness.

@Suite struct EnginePointerTests {

    /// The setting on, and a strip long enough that a focus command genuinely scrolls.
    static let hiding = Config(widthPresets: PresetCycle([.proportion(1.0)]), hidesCursor: true)

    /// A world of three full-width columns with the pointer setting on, at rest.
    static func world() -> State {
        EngineFix.world(3, config: hiding)
    }

    @Test func aCommandThatMovesTheDesktopHidesThePointer() {
        let s = Self.world()
        let (next, effects) = Engine.reduce(s, .command(.focus(.left)))
        #expect(effects.first == .setCursorHidden(true))
        #expect(next.pointer.isCursorHidden)
    }

    /// **The case a rule drawn around window movement gets wrong**, and the most common thing a
    /// keyboard user does: two columns both already on screen, so focus crosses between them with
    /// nothing to scroll and nothing to place. The batch is a bare `.focus` — and the pointer is left
    /// sitting over the window they just left unless that counts.
    @Test func aFocusThatScrollsNothingStillHidesThePointer() {
        // Two ½-width columns in a 1000-wide viewport: both fit, so no reveal and no cover.
        var s = EngineFix.world(2, config: Config(widthPresets: PresetCycle([.proportion(0.5)]),
                                                  transitionMode: .off, hidesCursor: true))
        s = EngineFix.settle(Engine.reduce(s, .pointerWoke).0)

        let (next, effects) = Engine.reduce(s, .command(.focus(.left)))
        #expect(effects.first == .setCursorHidden(true))
        #expect(effects.contains { if case .focus = $0 { true } else { false } })
        #expect(!effects.contains { if case .setFrame = $0 { true } else { false } },
                "the fixture should be a layout where nothing moves")
        #expect(next.pointer.isCursorHidden)
    }

    /// Prepended, not appended: the pointer has to be gone before the first window moves under it.
    @Test func theHideComesBeforeEverythingElseInTheBatch() {
        let s = Self.world()
        let (_, effects) = Engine.reduce(s, .command(.focus(.left)))
        #expect(effects.count > 1, "a focus across full-width columns should also do something")
        #expect(effects.dropFirst().allSatisfy { $0 != .setCursorHidden(true) })
    }

    /// The count `CGDisplayHideCursor` keeps is per connection, so the reducer's own record is what
    /// stops a second command paying a second hide the first show would not undo.
    @Test func aSecondCommandDoesNotHideAgain() {
        var s = Self.world()
        let (afterFirst, first) = Engine.reduce(s, .command(.focus(.left)))
        #expect(first.contains(.setCursorHidden(true)))
        s = EngineFix.settle(afterFirst, first)
        #expect(s.pointer.isCursorHidden)

        let (next, second) = Engine.reduce(s, .command(.focus(.right)))
        #expect(!second.contains(.setCursorHidden(true)))
        #expect(next.pointer.isCursorHidden)
    }

    @Test func theMotionThatEndsAHideShowsThePointer() {
        let (hidden, effects) = Engine.reduce(Self.world(), .command(.focus(.left)))
        let s = EngineFix.settle(hidden, effects)

        let (next, out) = Engine.reduce(s, .pointerWoke)
        #expect(out == [.setCursorHidden(false)])
        #expect(!next.pointer.isCursorHidden)
    }

    /// Edge-triggered: the shell's anchor and the core's flag are two records of one fact, and a wake
    /// arriving with nothing hidden is how they resynchronize rather than an error.
    @Test func aWakeWithNothingHiddenChangesNothing() {
        let s = Self.world()
        let (next, effects) = Engine.reduce(s, .pointerWoke)
        #expect(effects.isEmpty)
        #expect(!next.pointer.isCursorHidden)
    }

    /// **`exec` hides too, and that is the rule rather than a leak in it.** It rearranges no desktop —
    /// it spawns a process — but the gate is about the hand being on the keyboard, and a keybind that
    /// opens a terminal is as much that as a scroll is. Pinned because the alternative reading is
    /// tempting and would need `exec` named in a list, which is exactly what "emitted something" exists
    /// to avoid.
    @Test func aSpawnHidesThePointerLikeAnyOtherCommandThatDidSomething() {
        let s = Self.world()
        let (next, effects) = Engine.reduce(s, .command(.exec("true")))
        #expect(effects == [.setCursorHidden(true), .exec("true")])
        #expect(next.pointer.isCursorHidden)
    }

    /// A *read* is not a command that moves anything, and it emits no effects at all — which is what
    /// excludes it, rather than a name in a list.
    @Test func aStateDumpHidesNothing() {
        let s = Self.world()
        let (next, effects) = Engine.reduce(s, .command(.dumpState))
        #expect(effects.isEmpty)
        #expect(!next.pointer.isCursorHidden)
    }

    /// A window emira did not ask for is not the user looking away from the desktop, so the whole
    /// arrival — which does move the strip — leaves the pointer alone.
    @Test func aWindowArrivingByItselfHidesNothing() {
        let s = Self.world()
        let (next, effects) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(9)))
        #expect(!effects.contains(.setCursorHidden(true)))
        #expect(!next.pointer.isCursorHidden)
    }

    /// Nor is a focus report emira did not cause, even though it scrolls the strip exactly as a focus
    /// command does — the gate is the *event*, not what the batch turned out to contain.
    @Test func aSystemFocusReportHidesNothing() {
        let s = Self.world()
        let (next, effects) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))
        #expect(!effects.contains(.setCursorHidden(true)))
        #expect(!next.pointer.isCursorHidden)
    }

    /// Nor is a focus the *pointer* moved, which is the same gate reading the same way: hovering a
    /// window under `[focus] follows-mouse` scrolls the strip, and a hand on the mouse is the one
    /// thing this feature is not for.
    @Test func aHoveredFocusHidesNothing() throws {
        var s = EngineFix.world(3, config: Config(widthPresets: PresetCycle([.proportion(1.0)]),
                                                  focusFollowsMouse: true, hidesCursor: true))
        let target = try #require(s.world.stripWindowIds.first)
        s = EngineFix.settle(Engine.reduce(s, .command(.focus(.right))).0)
        s = EngineFix.settle(Engine.reduce(s, .pointerWoke).0)

        let (next, effects) = Engine.reduce(s, .pointerEntered(target))
        #expect(next.world.focusedWindow == target, "the hover still moves focus")
        #expect(!effects.contains(.setCursorHidden(true)))
        #expect(!next.pointer.isCursorHidden)
    }

    /// A command whose batch moves nothing — a focus into the wall at the end of the strip — leaves
    /// the pointer where it is. Hiding it would cost the user a mouse jiggle for a keystroke that did
    /// nothing at all.
    @Test func aCommandThatChangesNothingHidesNothing() {
        var s = Self.world()
        // Focus the leftmost column, settling the scroll it takes to get there.
        for _ in 0..<3 {
            let (next, effects) = Engine.reduce(s, .command(.focus(.left)))
            s = EngineFix.settle(next, effects)
        }
        s = EngineFix.settle(Engine.reduce(s, .pointerWoke).0)
        #expect(!s.pointer.isCursorHidden)

        let (next, effects) = Engine.reduce(s, .command(.focus(.left)))
        #expect(effects.isEmpty)
        #expect(!next.pointer.isCursorHidden)
    }

    /// With the setting off, nothing about the pointer is emitted at all — and the shell clamps the
    /// setting off whenever macOS cannot hide the cursor or emira cannot see the mouse move, so this
    /// is also what an unavailable capability looks like from the core's side.
    @Test func withTheSettingOffNothingIsEmitted() {
        let s = EngineFix.world(3, config: Config(widthPresets: PresetCycle([.proportion(1.0)])))
        let (next, effects) = Engine.reduce(s, .command(.focus(.left)))
        #expect(!effects.contains(.setCursorHidden(true)))
        #expect(!next.pointer.isCursorHidden)
        #expect(Engine.reduce(next, .pointerWoke).1.isEmpty)
    }

    /// In the dump the CLI prints — the only way to see the pointer's state, since no public API
    /// reports cursor visibility.
    @Test func theHiddenPointerIsInTheStateDump() throws {
        let (hidden, effects) = Engine.reduce(Self.world(), .command(.focus(.left)))
        let s = EngineFix.settle(hidden, effects)
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(json.contains("\"isCursorHidden\":true"))
    }

    // Activation, and why the hide is an assertion

    /// **What this event is for.** An app coming to the front discards a hide made from the background,
    /// so the hide is re-asserted for as long as one is wanted. The state does not move, because
    /// nothing is decided here: something has been undone.
    @Test func anActivationReassertsAHideThatIsStillWanted() {
        let (hidden, effects) = Engine.reduce(Self.world(), .command(.focus(.left)))
        let s = EngineFix.settle(hidden, effects)
        #expect(s.pointer.isCursorHidden)

        let (next, reasserted) = Engine.reduce(s, .appActivated)
        #expect(reasserted == [.setCursorHidden(true)])
        #expect(next.pointer.isCursorHidden)
        #expect(next == s, "a re-assertion restores the world's state, it does not advance it")
    }

    /// And it is genuinely repeatable: every activation for as long as the hide is owed. The shell's
    /// depth count is what keeps that safe — see `PointerTests`.
    @Test func everyActivationReassertsWhileTheHideIsOwed() {
        let (hidden, effects) = Engine.reduce(Self.world(), .command(.focus(.left)))
        var s = EngineFix.settle(hidden, effects)

        for _ in 0..<4 {
            let (next, reasserted) = Engine.reduce(s, .appActivated)
            #expect(reasserted == [.setCursorHidden(true)])
            s = next
        }
        #expect(s.pointer.isCursorHidden)
    }

    /// With nothing hidden it is silence, which is the ordinary case: every Cmd-Tab and Dock click on
    /// a desktop nobody has hidden the pointer on comes through here.
    @Test func anActivationWithNothingHiddenEmitsNothing() {
        let s = Self.world()
        let (next, effects) = Engine.reduce(s, .appActivated)
        #expect(effects.isEmpty)
        #expect(!next.pointer.isCursorHidden)
    }

    /// The wake still wins afterwards: a re-assertion must not make the hide un-endable, or the only
    /// exit from a hidden pointer would be gone.
    @Test func theWakeStillEndsAReassertedHide() {
        let (hidden, effects) = Engine.reduce(Self.world(), .command(.focus(.left)))
        var s = EngineFix.settle(hidden, effects)
        s = Engine.reduce(s, .appActivated).0

        let (next, woken) = Engine.reduce(s, .pointerWoke)
        #expect(woken == [.setCursorHidden(false)])
        #expect(!next.pointer.isCursorHidden)
        // And an activation after the wake is silence again.
        #expect(Engine.reduce(next, .appActivated).1.isEmpty)
    }

    /// With the setting off there is nothing to re-assert, so an activation stays free.
    @Test func withTheSettingOffAnActivationIsFree() {
        let s = EngineFix.world(3, config: Config(widthPresets: PresetCycle([.proportion(1.0)])))
        #expect(Engine.reduce(s, .appActivated).1.isEmpty)
    }

    // The setting withdrawn under a hidden pointer

    /// **The one case the mouse cannot rescue.** A hide is only ever taken while the setting is on, so
    /// a hidden pointer under a setting that is now off means the setting was withdrawn — and the
    /// shell has stopped watching for the motion that would ordinarily end it, because watching is
    /// what the setting was for. Paying it back here is the only way the cursor comes back at all.
    @Test func turningTheSettingOffShowsAPointerItHadHidden() {
        let (hidden, effects) = Engine.reduce(Self.world(), .command(.focus(.left)))
        var s = EngineFix.settle(hidden, effects)
        #expect(s.pointer.isCursorHidden)

        var off = s.config
        off.hidesCursor = false
        let (next, out) = Engine.reduce(s, .configChanged(off))
        #expect(out.contains(.setCursorHidden(false)))
        #expect(!next.pointer.isCursorHidden)

        // And it is idempotent: a second reload with the setting still off says nothing more.
        s = next
        #expect(!Engine.reduce(s, .configChanged(off)).1.contains(.setCursorHidden(false)))
    }

    /// The clamp is the same withdrawal by another route — `applyEnvironment` lowers the setting when
    /// macOS cannot hide the cursor or the mouse cannot be observed, and the config it lowers arrives
    /// as this same event. So the payout is written against the *invariant* rather than against a
    /// reload, and any later event finds the pointer already shown.
    @Test func anyEventFindsTheWithdrawnHidePaidOff() {
        let (hidden, effects) = Engine.reduce(Self.world(), .command(.focus(.left)))
        var s = EngineFix.settle(hidden, effects)
        s.config.hidesCursor = false        // as the clamp leaves it, with no event of its own

        let (next, out) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(out.contains(.setCursorHidden(false)))
        #expect(!next.pointer.isCursorHidden)
    }
}

//
// Focus following the pointer. The reducer's half is small — a hit test and the same tail
// `focus(Direction)` already reduces into — because the hazard this feature has is a *timing* one and
// the answer to it is the shell's: fired on pointer motion only, never on window motion. What is
// asserted here is the hit test's ordering and refusals, and that a crossing reduces to a reveal.

@Suite struct EngineHoverTests {

    static let hovering = Config(widthPresets: PresetCycle([.proportion(1.0)]),
                                 focusFollowsMouse: true, transitionMode: .off)

    /// A world of three full-width columns, at rest, with hover on.
    static func world() -> State {
        EngineFix.world(3, config: hovering)
    }

    // The hit test

    @Test func aPointInsideAnOnScreenWindowFindsIt() throws {
        let s = Self.world()
        let visible = try #require(s.world.placedOnScreen.sorted().first)
        let frame = try #require(s.world.windows[visible]?.frame)
        #expect(s.world.window(at: frame.center) == visible)
    }

    @Test func aPointOverNothingFindsNothing() {
        let s = Self.world()
        #expect(s.world.window(at: Point(x: -5000, y: -5000)) == nil)
    }

    /// **The parked nub is excluded for free**, by the same `isOnScreen` predicate `[focus]
    /// system-events = on-screen` uses. It sits at the bottom-right corner under a hot corner, and a
    /// stray sweep there would otherwise switch workspaces.
    @Test func aParkedNubIsNotHoverable() throws {
        let s = Self.world()
        let parked = try #require(s.world.stripWindowIds.first { !s.world.placedOnScreen.contains($0) })
        let nub = try #require(s.world.windows[parked]?.frame)
        #expect(s.world.window(at: nub.center) != parked)
    }

    /// A window in the Dock is off the screen for a reason that has nothing to do with the strip, and
    /// its last known frame is still sitting in `World`.
    @Test func aMinimizedWindowIsNotHoverable() throws {
        var s = EngineFix.world(2, config: Self.hovering)
        let frame = try #require(s.world.windows[WindowId(1)]?.frame)
        s = EngineFix.settle(Engine.reduce(s, .windowMinimized(WindowId(1))).0)
        #expect(s.world.window(at: frame.center) != WindowId(1))
    }

    /// Floats and dialogs before tiled windows: emira declines an opinion about where a float sits, so
    /// a float over a column is on top of it.
    @Test func aFloatOverAColumnWins() throws {
        var s = Self.world()
        let tiled = try #require(s.world.placedOnScreen.sorted().first)
        let frame = try #require(s.world.windows[tiled]?.frame)
        // A dialog the app opened right on top of it.
        let float = EngineFix.snapshot(99, role: .dialog, frame: frame)
        s = EngineFix.settle(Engine.reduce(s, .windowCreated(float)).0)

        #expect(s.world.isFloating(WindowId(99)))
        #expect(s.world.window(at: frame.center) == WindowId(99))
    }

    /// Two floats on the same point is the only tie the hit test can be handed — the strip does not
    /// overlap itself — and it breaks on the lowest id rather than on whichever way the dictionary
    /// happened to enumerate. A stacking order is the one thing `World` cannot see; determinism is what
    /// it can offer instead.
    @Test func twoOverlappingFloatsResolveToTheSameOneEveryTime() throws {
        var s = Self.world()
        let tiled = try #require(s.world.placedOnScreen.sorted().first)
        let frame = try #require(s.world.windows[tiled]?.frame)
        for raw in [UInt64(98), 97, 99] {
            let float = EngineFix.snapshot(raw, role: .dialog, frame: frame)
            s = EngineFix.settle(Engine.reduce(s, .windowCreated(float)).0)
        }
        #expect(s.world.window(at: frame.center) == WindowId(97))
    }

    // The crossing, reduced

    @Test func aCrossingMovesFocusAndRevealsIt() throws {
        var s = Self.world()
        let target = try #require(s.world.stripWindowIds.first)
        s = EngineFix.settle(Engine.reduce(s, .command(.focus(.right))).0)
        #expect(s.world.focusedWindow != target)

        let (next, effects) = Engine.reduce(s, .pointerEntered(target))
        #expect(next.world.focusedWindow == target)
        // The same tail `focus(Direction)` reduces into, so the echo comes home marked `.ours`.
        #expect(effects.contains(.focus(target)))
    }

    /// Idempotent: the shell dispatches on a crossing, but a report about the window that already has
    /// focus must change nothing rather than re-revealing it.
    @Test func aCrossingIntoTheFocusedWindowChangesNothing() throws {
        let s = Self.world()
        let focused = try #require(s.world.focusedWindow)
        let (next, effects) = Engine.reduce(s, .pointerEntered(focused))
        #expect(effects.isEmpty)
        #expect(next.world.focusedWindow == focused)
    }

    /// A float has no column to frame on and is already exactly where its app put it, so focusing it
    /// scrolls nothing.
    @Test func aCrossingIntoAFloatScrollsNothing() throws {
        var s = Self.world()
        let frame = Rect(x: 100, y: 100, width: 300, height: 200)
        s = EngineFix.settle(Engine.reduce(s, .windowCreated(
            EngineFix.snapshot(99, role: .dialog, frame: frame))).0)
        s = EngineFix.settle(Engine.reduce(s, .pointerEntered(try #require(s.world.stripWindowIds.first))).0)
        let offset = s.motion.viewportOffset.current

        let (next, effects) = Engine.reduce(s, .pointerEntered(WindowId(99)))
        #expect(effects == [.focus(WindowId(99))])
        #expect(next.motion.viewportOffset.current == offset)
    }

    @Test func withTheSettingOffACrossingChangesNothing() throws {
        var s = EngineFix.world(3, config: Config(widthPresets: PresetCycle([.proportion(1.0)]),
                                                  transitionMode: .off))
        let target = try #require(s.world.stripWindowIds.first)
        s = EngineFix.settle(Engine.reduce(s, .command(.focus(.right))).0)

        let (next, effects) = Engine.reduce(s, .pointerEntered(target))
        #expect(effects.isEmpty)
        #expect(next.world.focusedWindow != target)
    }

    /// A window that closed between the shell's hit test and the pump is a normal race, not a crash —
    /// the reducer is total over its vocabulary.
    @Test func aCrossingIntoAWindowThatIsGoneIsANoOp() {
        let s = Self.world()
        let (next, effects) = Engine.reduce(s, .pointerEntered(WindowId(4242)))
        #expect(effects.isEmpty)
        #expect(next.world.focusedWindow == s.world.focusedWindow)
    }
}
