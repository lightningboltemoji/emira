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
        #expect(!s.world.participatesInStrip(WindowId(2)))
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
        #expect(s.world.stripWindowIds == [WindowId(1)])    // w2 left the strip
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
        #expect(s.world.stripWindowIds.contains(WindowId(2)))
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(fx.contains(.focus(WindowId(2))))
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
                             .captureReady(WindowId(1)), .crossfadeDone, .holdTimeout] {
            let (s1, fx) = Engine.reduce(s0, event)
            #expect(fx.isEmpty)
            #expect(s1 == s0)
        }

        let (failed, fx) = Engine.reduce(s0, .axFailed(WindowId(1)))
        #expect(fx.isEmpty, "still emits nothing — the retry is the next real event, not this one")
        #expect(failed.world.unverified == [WindowId(1)])
    }

}
