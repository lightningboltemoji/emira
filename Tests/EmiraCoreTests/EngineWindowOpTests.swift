import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// The per-window operations that are not resize: height cycling, floating, closing,
// exec, and the destroy/minimize paths that take a window off the strip.

@Suite struct EngineWindowOpTests {

    /// A stacked column, `halfWidthSnap` so the frames are readable in the command's own batch.
    /// 800 pt of column height, two windows, no gaps: 400 each until one is pinned.
    static func stackedPair() -> State {
        var s = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidthSnap),
                              [.windowCreated(EngineFix.snapshot(1)), .windowCreated(EngineFix.snapshot(2))]).0
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // w2 joins w1's column
        return s
    }

    static func heights(_ s: State) -> [WindowId: Double] {
        s.layout.targetFrames(scrollOffset: 0, metrics: s.metrics()!).mapValues(\.height)
    }

    /// Pinning one window re-divides the column: the water-fill hands what it gave up to the autos.
    @Test func cyclingHeightPinsTheFocusedWindowAndTheStackmateRedivides() {
        var s = Self.stackedPair()
        #expect(Self.heights(s)[WindowId(2)] == 400)                  // auto: 800 split two ways

        (s, _) = Engine.reduce(s, .command(.cycleHeight))             // w2 → ⅓
        #expect(s.workspaces.heightSelections[WindowId(2)] == 0)
        let after = Self.heights(s)
        #expect(EngineFix.approxScalar(after[WindowId(2)]!, 800.0 / 3.0))
        #expect(EngineFix.approxScalar(after[WindowId(1)]!, 800 - 800.0 / 3.0))   // the auto absorbs the rest
        // The column still fills its box exactly — a pin must not leave a hole.
        #expect(EngineFix.approxScalar(after[WindowId(1)]! + after[WindowId(2)]!, 800))
    }

    /// Auto is a **rung of the ladder**, not a state you can only leave: ⅓ → ½ → ⅔ → auto. One verb
    /// reaches every selection and gets home again, so there is no second "un-pin" verb to invent.
    @Test func theHeightCycleWrapsBackThroughAuto() {
        var s = Self.stackedPair()
        var seen: [Int?] = [s.workspaces.heightSelections[WindowId(2)]]
        for _ in 0..<4 {
            (s, _) = Engine.reduce(s, .command(.cycleHeight))
            seen.append(s.workspaces.heightSelections[WindowId(2)])
        }
        #expect(seen == [nil, 0, 1, 2, nil])                          // three presets, then home
        #expect(Self.heights(s)[WindowId(2)] == 400)                  // and auto really is auto again
    }

    /// The selection is keyed by window and held for the whole workspace set, so it survives every
    /// structural edit — including the one that changes which strip the window is on.
    @Test func aPinnedHeightFollowsItsWindowToAnotherWorkspace() {
        var s = Self.stackedPair()
        (s, _) = Engine.reduce(s, .command(.cycleHeight))
        #expect(s.workspaces.heightSelections[WindowId(2)] == 0)

        (s, _) = Engine.reduce(s, .command(.moveToWorkspaceAndFocus(.name(WorkspaceName("2")!))))
        #expect(s.workspaces.workspace(of: WindowId(2)) == WorkspaceName("2")!)
        #expect(s.workspaces.heightSelections[WindowId(2)] == 0)      // carried, not dropped
    }

    /// And it dies with the window rather than outliving it — `reconcile` is where that happens, so a
    /// window that merely *floats* off the strip loses its pin too, and re-tiles as an auto.
    @Test func aPinnedHeightDoesNotOutliveItsWindow() {
        var s = Self.stackedPair()
        (s, _) = Engine.reduce(s, .command(.cycleHeight))
        (s, _) = Engine.reduce(s, .windowDestroyed(WindowId(2)))
        #expect(s.workspaces.heightSelections[WindowId(2)] == nil)
    }

    /// Totality: nothing focused, and no display yet, are both silent.
    @Test func aHeightCycleWithNothingToActOnIsSilent() {
        let s = EngineFix.booted()
        let (after, fx) = Engine.reduce(s, .command(.cycleHeight))
        #expect(fx.isEmpty)
        #expect(after == s)

        let blind = State(config: Config())                           // no `screensChanged` yet
        let (still, bfx) = Engine.reduce(blind, .command(.cycleHeight))
        #expect(bfx.isEmpty)
        #expect(still == blind)
    }

    /// Floating is a departure with `minimize`'s shape and one difference: focus stays on the window,
    /// because unlike a minimize the window is still there to look at.
    @Test func floatingTakesAWindowOffTheStripAndKeepsFocusOnIt() {
        var s = EngineFix.world(2)                       // w2 focused, two columns
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .command(.float(.toggle)))

        #expect(s.world.isFloating(WindowId(2)))
        #expect(!s.world.participatesInTiling(WindowId(2)))
        #expect(s.layout.columns.count == 1)        // the survivor closed ranks
        #expect(s.world.focusedWindow == WindowId(2))   // still focused, just not tiled
        // No `.focus` handoff: nothing lost focus, so nothing needs to be given it.
        #expect(!fx.contains(.focus(WindowId(1))))
    }

    /// And back again — the arrival path, so the strip opens for it in motion like a restore.
    @Test func tilingAFloatedWindowPutsItBackOnTheStrip() {
        var s = EngineFix.world(2)
        (s, _) = Engine.reduce(s, .command(.float(.on)))
        s = EngineFix.settle(s)
        #expect(s.layout.columns.count == 1)

        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .command(.float(.off)))
        #expect(!s.world.isFloating(WindowId(2)))
        #expect(s.layout.columns.count == 2)
        #expect(s.world.focusedWindow == WindowId(2))
        // It already holds focus; re-asserting it is an AX set that can make an app raise something else.
        #expect(!fx.contains(.focus(WindowId(2))))
    }

    /// The reason the override is tri-state rather than a flag: `float off` has to *tile* a window
    /// macOS classed as a dialog, or half the verb is unreachable. `AXDialog` is a claim about
    /// presentation (§10 — a full-screen Safari window reports it), not a verdict the user can't overrule.
    @Test func floatOffTilesAWindowWhoseRoleSaysItShouldFloat() {
        var s = EngineFix.booted()
        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(1)))
        s = EngineFix.settle(s)
        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(2, role: .dialog)))
        s = EngineFix.settle(s)

        #expect(s.world.isFloating(WindowId(2)))    // the role's answer, unopposed
        #expect(s.layout.columns.count == 1)

        s.world.setFocus(WindowId(2))
        (s, _) = Engine.reduce(s, .command(.float(.off)))
        #expect(!s.world.isFloating(WindowId(2)))
        #expect(s.layout.columns.count == 2)        // the dialog now holds a column
    }

    /// Stored explicitly, so it outranks a role that moves *and* survives the re-`insert` a re-scan
    /// does — `WindowState` is rebuilt wholesale there, which is why this lives beside `corrections`
    /// rather than on the window record.
    @Test func theFloatAnswerSurvivesAReScanAndDiesWithTheWindow() {
        var s = EngineFix.world(1)
        (s, _) = Engine.reduce(s, .command(.float(.on)))

        // A re-scan re-inserts the same id with a fresh record.
        s.world.insert(EngineFix.snapshot(1))
        #expect(s.world.isFloating(WindowId(1)))

        s.world.remove(WindowId(1))
        #expect(s.world.floating[WindowId(1)] == nil)
    }

    /// Totality: asking for the state it is already in, and asking with nothing focused, are both silent.
    @Test func aFloatThatChangesNothingIsSilent() {
        var s = EngineFix.world(1)
        let (same, fx) = Engine.reduce(s, .command(.float(.off)))    // already tiled
        #expect(fx.isEmpty)
        #expect(same == s)

        s = EngineFix.booted()
        let (empty, efx) = Engine.reduce(s, .command(.float(.toggle)))
        #expect(efx.isEmpty)
        #expect(empty == s)
    }

    /// `close-window` asks and changes nothing. The window is still open until its app says otherwise —
    /// an unsaved document is entitled to put up a sheet and stay — so removing it here would be the
    /// core asserting a fact only the app owns. The strip closes ranks on `windowDestroyed`, which is
    /// the same path a user-clicked close already takes.
    @Test func closingAsksTheAppAndLeavesTheStripAlone() {
        let s = EngineFix.world(2)                       // w2 focused
        let (after, fx) = Engine.reduce(s, .command(.closeWindow))

        #expect(fx == [.closeWindow(WindowId(2))])
        #expect(after == s)                         // not one byte of state
    }

    /// And the window really does leave only when the destroy arrives — the two halves in sequence.
    @Test func theStripClosesRanksOnlyWhenTheDestroyArrives() {
        var s = EngineFix.world(2)
        (s, _) = Engine.reduce(s, .command(.closeWindow))
        #expect(s.layout.columns.count == 2)        // asked, not gone

        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDestroyed(WindowId(2)))
        #expect(s.layout.columns.count == 1)
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(fx.contains(.focus(WindowId(1))))
    }

    /// Totality: nothing focused is silence, not a close of something arbitrary.
    @Test func closingWithNothingFocusedIsSilent() {
        let (s, fx) = Engine.reduce(EngineFix.booted(), .command(.closeWindow))
        #expect(fx.isEmpty)
        #expect(s == EngineFix.booted())
    }

    /// `exec` is the whole of a spawn: one effect, no state, no transition. A process is not a fact
    /// about the desktop, and it has no window until it makes one — at which point that window arrives
    /// as an ordinary `windowCreated` and animates by the arrival path like anything else.
    @Test func execEmitsOneEffectAndChangesNothing() {
        let s = EngineFix.world(2)
        let line = "osascript -e 'tell application \"Ghostty\" to new window'"
        let (after, fx) = Engine.reduce(s, .command(.exec(line)))

        #expect(fx == [.exec(line)])
        #expect(after == s)
        #expect(!after.motion.isTransitioning)      // nothing to animate; no cover
    }

    /// It needs nothing of the world, unlike every other verb — no focused window, no strip, no
    /// display. A keybind that launches a terminal has to work on an empty desktop most of all.
    @Test func execWorksWithAnEmptyDesktop() {
        let (s, fx) = Engine.reduce(State(), .command(.exec("ghostty")))
        #expect(fx == [.exec("ghostty")])
        #expect(s == State())
    }

    /// `override` passes through for `exec`'s reason: the layer is the shell's, and the setting it
    /// moves comes back as `configChanged`. Nothing about the desktop changes on the way out.
    @Test func overrideEmitsOneEffectAndChangesNothing() {
        let s = EngineFix.world(2)
        let intent = OverrideIntent.toggle(key: "focus.unfocused-opacity", value: "1")
        let (after, fx) = Engine.reduce(s, .command(.override(intent)))

        #expect(fx == [.override(intent)])
        #expect(after == s)
        #expect(!after.motion.isTransitioning)
        // …and it needs no desktop at all: a reset from an empty one still reaches the shell.
        let (empty, resetFx) = Engine.reduce(State(), .command(.override(.reset(key: nil))))
        #expect(resetFx == [.override(.reset(key: nil))])
        #expect(empty == State())
    }

    @Test func destroyingFocusedWindowRefocusesAndReflows() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),   // focus w2
        ])
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDestroyed(WindowId(2)))
        #expect(s.world.windows[WindowId(2)] == nil)
        #expect(s.layout.columns.count == 1)
        #expect(s.world.focusedWindow == WindowId(1))      // focus moved to the survivor
        #expect(fx.contains(.focus(WindowId(1))))
    }

    @Test func destroyingUnfocusedWindowKeepsFocusAndReflows() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),   // focus w2
        ])
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDestroyed(WindowId(1)))
        #expect(s.world.focusedWindow == WindowId(2))       // unchanged
        #expect(s.layout.columns.count == 1)
        #expect(!fx.contains(.focus(WindowId(2))))          // no spurious focus re-assert
    }

    @Test func minimizeLeavesTheStripAndRefocuses() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),   // focus w2
        ])
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowMinimized(WindowId(2)))
        #expect(s.world.tiledWindowIds == [WindowId(1)])    // w2 left the strip
        #expect(s.layout.columns.count == 1)
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(fx.contains(.focus(WindowId(1))))
    }

    @Test func deminimizeRejoinsTheStripAndFocuses() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .windowMinimized(WindowId(2)))
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDeminimized(WindowId(2)))
        #expect(s.world.tiledWindowIds.contains(WindowId(2)))
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(fx.contains(.focus(WindowId(2))))
    }

    // Native full screen: a Space of the window's own, its column kept while it is there. macOS's own
    // animation is the whole transition both ways, so nothing on the desktop moves for it.

    /// What entering or leaving full screen must not emit: anything that moves a window or films one.
    static func moves(_ effects: [Effect]) -> [Effect] {
        effects.filter {
            switch $0 {
            case .setFrame, .park, .capture, .beginTransition: true
            default: false
            }
        }
    }

    static func touches(_ effects: [Effect], _ id: WindowId) -> Bool {
        effects.contains {
            switch $0 {
            case .setFrame(let w, _), .park(let w, _), .capture(_, let w, _): w == id
            default: false
            }
        }
    }

    /// The window keeps its column and the keyboard — it is the one in front, and handing focus on would
    /// take the user straight back out of full screen. Nothing closes up over its place.
    @Test func fullScreenKeepsTheColumnAndTheKeyboardAndMovesNothing() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),   // focus w2
        ])
        let columns = s.layout.columns
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowFullScreen(WindowId(2), true))
        #expect(s.layout.columns == columns)
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(Self.moves(fx).isEmpty)
        #expect(!s.world.isOnScreen(WindowId(2)))
    }

    /// A window in full screen is not one emira places: its frame changing — macOS animating it to the
    /// display — writes nothing back, where a tiled window would be re-placed on every report.
    @Test func aWindowInFullScreenIsNotPlaced() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        s = EngineFix.settle(Engine.reduce(s, .windowFullScreen(WindowId(2), true)).0)
        let display = Rect(x: 0, y: 0, width: 1000, height: 800)
        let (_, fx) = EngineFix.run(s, [.windowFrameChanged(WindowId(2), display),
                                        .windowSelfPlaced(WindowId(2))])
        #expect(!fx.contains { if case .setFrame(WindowId(2), _) = $0 { true } else { false } })
    }

    /// Back at the frame its app restores, which is the slot nothing moved: no write, no cover, and no
    /// focus asked for — the window coming out of full screen is already the one in front.
    @Test func leavingFullScreenMovesNothing() throws {
        var (s, _) = EngineFix.run(EngineFix.booted(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        let slot = try #require(s.world.windows[WindowId(2)]?.frame)
        s = EngineFix.settle(Engine.reduce(s, .windowFullScreen(WindowId(2), true)).0)
        s = EngineFix.run(s, [.windowFrameChanged(WindowId(2), Rect(x: 0, y: 0, width: 1000, height: 800)),
                              .windowFrameChanged(WindowId(2), slot)]).0
        let (next, fx) = Engine.reduce(s, .windowFullScreen(WindowId(2), false))
        #expect(Self.moves(fx).isEmpty)
        #expect(!fx.contains(.focus(WindowId(2))))
        #expect(next.world.isOnScreen(WindowId(2)))
    }

    /// The strip can still change while the window is away, and a cover for it neither films the window
    /// nor writes it: the desktop shows its slot empty. Back, it is put in the slot as it now stands.
    @Test func aColumnMovedWhileAwayIsWhereTheWindowIsPutBack() throws {
        var (s, _) = EngineFix.run(EngineFix.booted(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),   // focus w2
        ])
        let left = try #require(s.world.windows[WindowId(2)]?.frame)
        s = EngineFix.settle(Engine.reduce(s, .windowFullScreen(WindowId(2), true)).0)

        let (moved, moving) = Engine.reduce(s, .command(.moveWindow(.left)))
        let (settled, sequence) = EngineFix.settleRecording(moved, moving)
        s = settled
        #expect(sequence.contains { if case .beginTransition = $0 { true } else { false } })
        #expect(!Self.touches(sequence, WindowId(2)))
        #expect(s.layout.columnIndex(ofWindow: WindowId(2)) == 0)

        s = EngineFix.run(s, [.windowFrameChanged(WindowId(2), left)]).0
        let (_, fx) = Engine.reduce(s, .windowFullScreen(WindowId(2), false))
        let target = try #require(fx.compactMap { effect -> Rect? in
            if case .setFrame(WindowId(2), let frame) = effect { frame } else { nil }
        }.first)
        #expect(target != left)
    }

    /// The column keeps whatever width it had: there is nothing to remember, since it never closed.
    @Test func theColumnKeepsItsWidthWhileTheWindowIsAway() throws {
        var s = EngineFix.world(3)                                    // w1 | w2 | w3, w3 focused
        s = EngineFix.settle(Engine.reduce(s, .command(.grow(.percent(20)))).0)
        let before = try #require(s.layout.columns.last)
        #expect(before.windowIds == [WindowId(3)])

        s = EngineFix.settle(Engine.reduce(s, .windowFullScreen(WindowId(3), true)).0)
        #expect(s.layout.columns.last == before)
        s = EngineFix.settle(Engine.reduce(s, .windowFullScreen(WindowId(3), false)).0)
        #expect(s.layout.columns.last == before)
        #expect(s.workspaces.awayPlaces.isEmpty)
    }

    /// A window opened meanwhile is a new column on the ladder beside the one in front, as ever.
    @Test func aWindowOpenedWhileAnotherIsFullScreenStartsOnTheLadder() throws {
        var s = EngineFix.world(2)
        s = EngineFix.settle(Engine.reduce(s, .command(.grow(.percent(20)))).0)
        let grown = try #require(s.layout.columns.last?.widthOverride)
        s = EngineFix.settle(Engine.reduce(s, .windowFullScreen(WindowId(2), true)).0)
        s = EngineFix.settle(Engine.reduce(s, .windowCreated(EngineFix.snapshot(3))).0)

        let fresh = try #require(s.layout.columns.first { $0.windowIds == [WindowId(3)] })
        #expect(fresh.widthOverride == nil)
        #expect(fresh.widthPreset == 0)
        #expect(s.layout.columns.first { $0.windowIds == [WindowId(2)] }?.widthOverride == grown)
    }

    /// A window that closes in full screen takes its column with it, like any close.
    @Test func aWindowClosedInFullScreenTakesItsColumn() {
        var s = EngineFix.world(3)
        s = EngineFix.settle(Engine.reduce(s, .windowFullScreen(WindowId(3), true)).0)
        s = EngineFix.settle(Engine.reduce(s, .windowDestroyed(WindowId(3))).0)
        #expect(s.layout.allWindowIds == [WindowId(1), WindowId(2)])
        #expect(s.workspaces.awayPlaces.isEmpty)
    }

    // Away and back: the Dock and ⌘H return a window to where it stood.

    /// A settled strip of one window per entry, each of the app named, left to right.
    private func apps(_ bundles: [String]) -> State {
        var s = EngineFix.booted()
        for (i, bundle) in bundles.enumerated() {
            s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(UInt64(i + 1), bundle: bundle))]).0
            s = EngineFix.settle(s)
        }
        return s
    }

    /// ⌘H arrives a window at a time. The focused one leaving first must not hand focus to its sibling —
    /// still standing, and about to go too — since focusing a hidden app's window unhides it.
    @Test func hidingAnAppHandsFocusPastItsOtherWindows() {
        var s = focusing(apps(["a", "b", "b", "c"]), 2)
        let first: [Effect]
        (s, first) = EngineFix.run(s, [.windowHidden(WindowId(2))])
        #expect(!first.contains(.focus(WindowId(3))))
        #expect(first.contains(.focus(WindowId(4))))
        let second: [Effect]
        (s, second) = EngineFix.run(s, [.windowHidden(WindowId(3))])
        #expect(!second.contains { if case .focus = $0 { true } else { false } })
        #expect(s.layout.allWindowIds == [WindowId(1), WindowId(4)])

        for id: UInt64 in [2, 3] { s = EngineFix.settle(EngineFix.run(s, [.windowUnhidden(WindowId(id))]).0) }
        #expect(s.layout.allWindowIds == [WindowId(1), WindowId(2), WindowId(3), WindowId(4)])
        #expect(s.world.focusedWindow == WindowId(4))
    }

    /// A minimize hands focus to the neighbour whatever app it is — the Dock takes one window, not an app.
    @Test func minimizingHandsFocusToTheNeighbourOfTheSameApp() {
        var s = focusing(apps(["a", "b", "b", "c"]), 2)
        let fx: [Effect]
        (s, fx) = EngineFix.run(s, [.windowMinimized(WindowId(2))])
        #expect(fx.contains(.focus(WindowId(3))))
    }

    /// Focus `id`'s column by walking left from the right end of a settled strip.
    private func focusing(_ s: State, _ id: UInt64) -> State {
        var s = s
        while let focused = s.world.focusedWindow, focused != WindowId(id) {
            s = EngineFix.settle(Engine.reduce(s, .command(.focus(.left))).0)
        }
        return s
    }

    /// The middle of three, grown, goes to the Dock and comes back: same place, same width, focused.
    @Test func aRestoredWindowComesBackWhereItStoodAtItsWidth() throws {
        var s = focusing(EngineFix.world(3), 2)
        s = EngineFix.settle(Engine.reduce(s, .command(.grow(.percent(20)))).0)
        let grown = try #require(s.layout.columns[1].widthOverride)

        s = EngineFix.settle(Engine.reduce(s, .windowMinimized(WindowId(2))).0)
        #expect(s.layout.allWindowIds == [WindowId(1), WindowId(3)])
        let fx: [Effect]
        (s, fx) = EngineFix.run(s, [.windowDeminimized(WindowId(2))])

        #expect(s.layout.allWindowIds == [WindowId(1), WindowId(2), WindowId(3)])
        #expect(s.layout.columns[1].widthOverride == grown)
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(fx.contains(.focus(WindowId(2))))
        #expect(s.workspaces.awayPlaces.isEmpty)
    }

    /// ⌘H undone puts the window back where it stood, but focus is the app's to say: a window the user is
    /// not in comes back without taking the keyboard or moving the viewport onto itself.
    @Test func anUnhiddenWindowComesBackWithoutTakingFocus() throws {
        var s = focusing(apps(["a", "b", "c"]), 2)
        s = EngineFix.settle(Engine.reduce(s, .command(.grow(.percent(20)))).0)
        let grown = try #require(s.layout.columns[1].widthOverride)
        s = EngineFix.settle(Engine.reduce(s, .windowHidden(WindowId(2))).0)
        s = EngineFix.settle(Engine.reduce(s, .focusChanged(WindowId(1), origin: .system)).0)

        let fx: [Effect]
        (s, fx) = EngineFix.run(s, [.windowUnhidden(WindowId(2))])
        #expect(s.layout.allWindowIds == [WindowId(1), WindowId(2), WindowId(3)])
        #expect(s.layout.columns[1].widthOverride == grown)
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(!fx.contains(.focus(WindowId(2))))
    }

    /// Two neighbours away at once come back in their order, whichever left first and whichever returns
    /// first — the second to leave remembers it stood beside a window already gone.
    @Test(arguments: [[2, 3], [3, 2]], [[2, 3], [3, 2]])
    func neighboursComeBackInTheirOrder(leaving: [UInt64], returning: [UInt64]) {
        var s = EngineFix.world(4)                                    // w1 | w2 | w3 | w4
        for id in leaving {
            s = EngineFix.settle(Engine.reduce(s, .windowMinimized(WindowId(id))).0)
        }
        #expect(s.layout.allWindowIds == [WindowId(1), WindowId(4)])
        for id in returning {
            s = EngineFix.run(s, [.windowDeminimized(WindowId(id))]).0
            s = EngineFix.settle(s)
        }
        #expect(s.layout.allWindowIds == [WindowId(1), WindowId(2), WindowId(3), WindowId(4)])
    }

    /// A window that left a stack goes back into it, at its row, while the stack is still there.
    @Test func aWindowComesBackIntoTheStackItLeft() throws {
        var s = EngineFix.world(3)                                    // w3 focused
        s = EngineFix.settle(Engine.reduce(s, .command(.consumeOrExpel(.left))).0)
        let stack = try #require(s.layout.columns.last)
        #expect(stack.windowIds == [WindowId(2), WindowId(3)])

        s = EngineFix.settle(Engine.reduce(s, .windowMinimized(WindowId(2))).0)
        #expect(s.layout.columns.last?.windowIds == [WindowId(3)])
        s = EngineFix.run(s, [.windowDeminimized(WindowId(2))]).0
        #expect(s.layout.columns.count == 2)
        #expect(s.layout.columns.last?.id == stack.id)
        #expect(s.layout.columns.last?.windowIds == [WindowId(2), WindowId(3)])
    }

    // Away from a workspace the user has left.

    private static let two = WorkspaceName("2")!

    /// w1 on workspace 1, w2 on workspace 2, the user on 1 and w2 away.
    private func awayOnTwo(hidden: Bool = false) -> State {
        var s = apps(["a", "b"])
        s = EngineFix.settle(Engine.reduce(s, .command(.moveToWorkspaceAndFocus(.name(Self.two)))).0)
        let leave: Event = hidden ? .windowHidden(WindowId(2)) : .windowMinimized(WindowId(2))
        s = EngineFix.settle(Engine.reduce(s, leave).0)
        s = EngineFix.settle(Engine.reduce(s, .command(.focusWorkspace(.name(.first)))).0)
        return s
    }

    /// Restored from the Dock while the user is elsewhere: it goes back to its own workspace, and the
    /// user follows it there — they asked for that window.
    @Test func aWindowRestoredFromAnotherWorkspaceTakesTheUserToIt() {
        var s = awayOnTwo()
        #expect(s.monitors.shown == .first)
        s = EngineFix.settle(EngineFix.run(s, [.windowDeminimized(WindowId(2))]).0)
        #expect(s.workspaces.workspace(of: WindowId(2)) == Self.two)
        #expect(s.monitors.shown == Self.two)
        #expect(s.world.focusedWindow == WindowId(2))
    }

    /// Unhidden while the user is elsewhere and in another window: it goes back to its own workspace
    /// and nobody follows it.
    @Test func anUnhiddenWindowOutOfViewStaysThere() {
        var s = awayOnTwo(hidden: true)
        s = EngineFix.settle(EngineFix.run(s, [.windowUnhidden(WindowId(2))]).0)
        #expect(s.workspaces.workspace(of: WindowId(2)) == Self.two)
        #expect(s.monitors.shown == .first)
        #expect(s.world.focusedWindow == WindowId(1))
    }

    /// The app's focus report decides, in either order: before the window is back, or after.
    @Test(arguments: [true, false])
    func anUnhiddenWindowTheAppFocusesTakesTheUserToIt(focusFirst: Bool) {
        var s = awayOnTwo(hidden: true)
        let focus = Event.focusChanged(WindowId(2), origin: .system)
        let events: [Event] = focusFirst ? [focus, .windowUnhidden(WindowId(2))]
                                         : [.windowUnhidden(WindowId(2)), focus]
        for event in events { s = EngineFix.settle(Engine.reduce(s, event).0) }
        #expect(s.workspaces.workspace(of: WindowId(2)) == Self.two)
        #expect(s.monitors.shown == Self.two)
        #expect(s.world.focusedWindow == WindowId(2))
    }

    // Where focus goes when a window with no *place* on the strip leaves it. The strip's own answer is
    // positional — a stackmate, then whatever stands at the departed column's index — and a float has
    // neither, so these pin the third clause: the last place focus held on this strip.

    /// Floating w3 takes it off the strip while it keeps focus, so the memory of where the user was
    /// working moves to the place w3 vacated — w2 — rather than dangling on a window that is no longer
    /// on the strip. Closing the float then hands focus back to it, not to the strip's front.
    @Test func closingAFloatFocusesTheStripPlaceItLeftRatherThanTheStripsFront() {
        var s = EngineFix.world(3)                          // w1 | w2 | w3, w3 focused
        (s, _) = Engine.reduce(s, .command(.float(.on)))    // w3 floats, still focused
        s = EngineFix.settle(s)
        #expect(s.layout.allWindowIds == [WindowId(1), WindowId(2)])
        #expect(s.world.lastTiledFocus == WindowId(2))      // the place it vacated, not the window that left

        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDestroyed(WindowId(3)))
        #expect(s.world.focusedWindow == WindowId(2))       // *not* w1
        #expect(fx.contains(.focus(WindowId(2))))
    }

    /// The commoner case, and the one macOS sometimes backfills for us: a dialog opens over w2, the app
    /// focuses it, and dismissing it comes back to w2. Nothing off the strip is ever `lastTiledFocus`,
    /// so the memory was never the dialog and this needs only the placeless clause.
    @Test func closingADialogFocusesTheWindowItOpenedOver() {
        var s = EngineFix.world(2)                          // w1 | w2, w2 focused
        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(3, role: .dialog)))
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(3), origin: .system))
        s = EngineFix.settle(s)
        #expect(s.world.focusedWindow == WindowId(3))
        #expect(s.layout.columns.count == 2)                // the dialog holds no column

        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDestroyed(WindowId(3)))
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(fx.contains(.focus(WindowId(2))))
    }

    /// The memory follows the *place*, not the window: with focus parked on a float, closing the strip
    /// window it points at moves it to that window's own successor instead of going blank.
    @Test func theStripMemoryWalksToTheSuccessorWhenItsWindowCloses() {
        var s = EngineFix.world(3)                          // w1 | w2 | w3
        (s, _) = Engine.reduce(s, .command(.float(.on)))    // w3 floats; the memory becomes w2
        s = EngineFix.settle(s)

        (s, _) = Engine.reduce(s, .windowDestroyed(WindowId(2)))
        #expect(s.world.focusedWindow == WindowId(3))       // the float still holds focus
        #expect(s.world.lastTiledFocus == WindowId(1))      // w2's place, now w1's

        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDestroyed(WindowId(3)))
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(fx.contains(.focus(WindowId(1))))
    }

    /// Nesting, which is the whole of what the focus stack buys over the strip memory: a dialog opens
    /// out of a dialog, and closing the inner one comes back to the outer rather than skipping past it
    /// to the strip. Nothing off the strip is ever `lastTiledFocus`, so the memory cannot answer this.
    @Test func closingADialogReturnsToTheDialogItOpenedOutOf() {
        var s = EngineFix.world(2)                          // w1 | w2, w2 focused
        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(3, role: .dialog)))
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(3), origin: .system))
        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(4, role: .dialog)))
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(4), origin: .system))
        s = EngineFix.settle(s)
        #expect(s.layout.columns.count == 2)                // neither dialog holds a column

        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDestroyed(WindowId(4)))
        #expect(s.world.focusedWindow == WindowId(3))       // *not* w2, the strip place behind both
        #expect(fx.contains(.focus(WindowId(3))))
    }

    /// The stack is asked of the screen, not of history: a window in the Dock is a memory of somewhere
    /// focus cannot be handed, however recently it held it.
    @Test func theStackSkipsAWindowInTheDock() {
        var s = EngineFix.world(2)                          // w1 | w2, w2 focused
        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(3, role: .dialog)))
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(3), origin: .system))
        (s, _) = Engine.reduce(s, .windowMinimized(WindowId(2)))   // newer than w1, and unreachable
        s = EngineFix.settle(s)
        #expect(s.world.focusedWindow == WindowId(3))

        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDestroyed(WindowId(3)))
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(fx.contains(.focus(WindowId(1))))
    }

    /// From the other side: the strip's last column closing hands focus to a float standing in the
    /// open, which is the only thing left to focus. The positional clauses have nothing to answer with
    /// and the strip memory went with the column.
    @Test func theLastColumnClosingHandsFocusToAFloatStandingInTheOpen() {
        var s = EngineFix.world(2)                          // w1 | w2, w2 focused
        (s, _) = Engine.reduce(s, .command(.float(.on)))    // w2 floats, still focused
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))
        s = EngineFix.settle(s)
        #expect(s.layout.allWindowIds == [WindowId(1)])

        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDestroyed(WindowId(1)))
        #expect(s.layout.columns.isEmpty)
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(fx.contains(.focus(WindowId(2))))
    }

    /// Totality: a float closing over an empty strip focuses nothing. Focus on nothing is a resting
    /// state (§4), and the last resort has nothing to reach for.
    @Test func closingTheLastFloatLeavesFocusNowhere() {
        var s = EngineFix.world(1)
        (s, _) = Engine.reduce(s, .command(.float(.on)))
        s = EngineFix.settle(s)
        #expect(s.layout.columns.isEmpty)

        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDestroyed(WindowId(1)))
        #expect(s.world.focusedWindow == nil)
        #expect(!fx.contains { if case .focus = $0 { return true }; return false })
    }

    @Test func geometryCommandsNoOpWithNoDisplay() {
        // No `screensChanged` yet: truth still folds, but nothing can be placed.
        var s = State()
        let fx1: [Effect]
        (s, fx1) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(1)))
        #expect(s.world.windows[WindowId(1)] != nil)  // truth recorded
        #expect(s.world.focusedWindow == WindowId(1)) // focus tracked
        #expect(fx1.isEmpty)                          // but no placement — nowhere to place

        let fx2: [Effect]
        (s, fx2) = Engine.reduce(s, .command(.focus(.left)))
        #expect(fx2.isEmpty)

        // First display arrives → everything gets placed.
        let fx3: [Effect]
        (s, fx3) = Engine.reduce(s, .screensChanged([MonitorInfo(id: MonitorId(1), frame: EngineFix.displayFrame)]))
        #expect(EngineFix.placement(of: WindowId(1), in: fx3) != nil)
    }

    @Test func transitionFeedbackEventsAreInertWhenIdle() {
        // With no session open, every transition-feedback event acks nothing and leaves the state
        // untouched — totality for a stray ack that outlives its transition. `axFailed` is the exception:
        // it records that an optimistic frame never happened (`World.unverified`), changing only what the
        // *next* placement asks. It still emits nothing; re-placing here would busy-loop a hung app.
        let (s0, _) = EngineFix.run(EngineFix.booted(), [.windowCreated(EngineFix.snapshot(1))])
        for event: Event in [.tick(dt: 0.016), .axLanded(WindowId(1)),
                             .captureReady(WindowId(1)), .crossfadeDone(MonitorId(1)), .holdTimeout(MonitorId(1))] {
            let (s1, fx) = Engine.reduce(s0, event)
            #expect(fx.isEmpty)
            #expect(s1 == s0)
        }

        let (failed, fx) = Engine.reduce(s0, .axFailed(WindowId(1)))
        #expect(fx.isEmpty, "still emits nothing — the retry is the next real event, not this one")
        #expect(failed.world.unverified == [WindowId(1)])
    }

}
