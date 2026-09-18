import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// Moving focus, and the reveal that follows it — both the focus we command and the one
// the system hands us.

@Suite struct EngineFocusTests {

    @Test func horizontalFocusScrollAnimatesAcrossColumns() {
        // Full-width columns: every focus change scrolls one viewport. After creating w1/w2/w3, focus
        // is on w3 at offset 2000 (each create-reveal snapped one viewport right).
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        #expect(s.world.focusedWindow == WindowId(3))
        #expect(s.viewport.offset.current == 2000)

        // focus left → w2. Focus moves *immediately* (truth), but the scroll now animates: a transition
        // opens, aimed at offset 1000, with the viewport not yet moved.
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .command(.focus(.left)))
        #expect(s.world.focusedWindow == WindowId(2))            // focus is a truth change, not animated
        #expect(fx.contains(.focus(WindowId(2))))
        #expect(s.motion.isTransitioning)
        #expect(s.motion.isCovered(on: s.monitors.focused) == false)                    // still capturing — cover not raised
        #expect(s.viewport.offset.target == 1000)         // aimed left one viewport
        #expect(s.viewport.offset.current == 2000)        // hasn't moved yet (no ticks)
        // Scope = {w2, w3} swept, plus w1 as the left shoulder — the column one further `focus left`
        // would pull in, captured now because a capture requested then would arrive too late. No real
        // teleport yet: nothing is exposed before the cover is up.
        #expect(Set(EngineFix.capturedIds(in: fx)) == Set([WindowId(1), WindowId(2), WindowId(3)]))
        #expect(!EngineFix.hasEffect(fx) { if case .setFrame = $0 { return true }; return false })
        #expect(!EngineFix.hasEffect(fx) { if case .beginTransition = $0 { return true }; return false })

        // Drive it home: w2 revealed at offset 1000, cover down.
        let (done, _) = EngineFix.drive(s)
        #expect(done.motion.isTransitioning == false)
        #expect(EngineFix.approxScalar(done.viewport.offset.current, 1000))
    }

    @Test func focusWithNoViewportMotionIsASnap() {
        // A focus change whose target column is *already in view* opens no transition — there's nothing
        // to animate, so it stays a snap. ½-width fits two columns, so focusing between w3 and w2 (both
        // on screen at offset 500) never scrolls.
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .command(.focus(.left)))       // w3 → w2, both visible
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(s.motion.isTransitioning == false)                // snap, not a transition
        #expect(s.viewport.offset.velocity == 0)
        #expect(s.viewport.offset.current == s.viewport.offset.target)  // settled, not moving
        #expect(EngineFix.capturedIds(in: fx).isEmpty)                 // no cover ⇒ no captures
    }

    @Test func horizontalFocusAtEdgeIsNoOp() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [.windowCreated(EngineFix.snapshot(1))])
        // Only one column — focusing right has no neighbour.
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .command(.focus(.right)))
        #expect(s.world.focusedWindow == WindowId(1))  // unchanged
        #expect(fx.isEmpty)
    }

    @Test func verticalFocusMovesWithinColumnWithoutScrolling() {
        // Build a two-window column by hand, then focus down.
        let world = { () -> World in
            var w = World()
            w.insert(EngineFix.snapshot(1)); w.insert(EngineFix.snapshot(2))
            w.setFocus(WindowId(1))
            return w
        }()
        let layout = Layout(columns: [ColumnLayout(id: ColumnId(1), windowIds: [WindowId(1), WindowId(2)])])
        var state = State(world: world, layout: layout, motion: Motion(), config: Config())
        state.setMonitors([MonitorInfo(id: MonitorId(1), frame: EngineFix.displayFrame)])

        let (s, fx) = Engine.reduce(state, .command(.focus(.down)))
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(fx.contains(.focus(WindowId(2))))
        #expect(fx.contains(.raise(WindowId(2))))
        #expect(s.viewport.offset.current == 0)                 // no scroll
        #expect(!fx.contains { if case .setFrame = $0 { return true }; return false })  // no re-place
    }

    @Test func focusWithNothingFocusedTakesTheFirstWindow() {
        // Insert two windows directly with no focus set, then a focus command grabs the first.
        var world = World()
        world.insert(EngineFix.snapshot(1)); world.insert(EngineFix.snapshot(2))
        var state = State(world: world, layout: Layout(), motion: Motion(), config: Config())
        state.setMonitors([MonitorInfo(id: MonitorId(1), frame: EngineFix.displayFrame)])

        let (s, fx) = Engine.reduce(state, .command(.focus(.right)))
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(fx.contains(.focus(WindowId(1))))
    }

    @Test func centerColumnScrollsFocusedColumnToCenter() {
        // Two ½-width windows both fit at the origin; focus w1 (a no-motion snap back to it).
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))       // w2 → w1, both visible ⇒ snap
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(s.motion.isTransitioning == false)
        #expect(s.viewport.offset.current == 0)

        // centerColumn: column 0 is [0,500]; centering it in a 1000 viewport ⇒ −(1000−500)/2 = −250.
        // That's a real scroll now, so it animates rather than snapping.
        let (c, fx) = Engine.reduce(s, .command(.centerColumn))
        #expect(c.motion.isTransitioning)                        // animated, not snapped
        #expect(c.viewport.offset.target == -250)          // aimed at the centered offset
        #expect(c.viewport.offset.current == 0)            // hasn't moved yet
        #expect(!EngineFix.capturedIds(in: fx).isEmpty)               // captures requested (a cover is coming)
        #expect(!fx.contains(.focus(WindowId(1))))               // centering never re-focuses

        // And it lands where it aimed.
        let (done, _) = EngineFix.drive(c)
        #expect(done.motion.isTransitioning == false)
        #expect(EngineFix.approxScalar(done.viewport.offset.current, -250))
    }

    @Test func externalFocusRevealsUnderACoverWithoutEmittingFocus() {
        // A window that scrolled off-view regains focus via Cmd-Tab — the strip scrolls to it like it
        // would for `focus left`, and we don't re-issue a focus effect (the shell already moved focus).
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),   // focus w3, scrolled to offset 500; w1 parked
        ])
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(s.motion.isTransitioning)
        #expect(s.viewport.offset.target == 0)     // aimed back at w1
        #expect(s.viewport.offset.current == 500)  // and has not jumped there
        #expect(!fx.contains(.focus(WindowId(1))))       // shell-initiated: no focus effect
        #expect(fx.contains { if case .capture = $0 { return true }; return false })
        #expect(EngineFix.settle(s, fx).viewport.offset.current == 0)
    }

    /// The order macOS actually produces when the focused window closes: the app hands key status to a
    /// survivor *before* it destroys the closing element, so the focus report arrives a beat ahead of the
    /// destroy. The reveal it asks for and the ranks the destroy closes are one scroll to one place, and
    /// it has to survive being delivered in two halves — a snapped reveal would spend the whole of it
    /// before the destroy that owes it ever arrives.
    @Test func aFocusBackfilledAheadOfTheDestroyLeavesTheCloseInMotion() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),   // focus w2, scrolled to offset 1000
        ])
        #expect(s.viewport.offset.current == 1000)

        var fx: [Effect]
        (s, fx) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))
        var pending = fx                                   // the session's captures are still owed
        #expect(s.motion.isTransitioning)
        #expect(s.viewport.offset.current == 1000)   // aimed at w1, not standing on it

        (s, fx) = Engine.reduce(s, .windowDestroyed(WindowId(2)))
        pending += fx
        #expect(s.motion.isTransitioning, "the close rides the session it found open")
        #expect(s.viewport.offset.target == 0)
        #expect(s.viewport.offset.current == 1000, "and still nothing has jumped")
        #expect(EngineFix.settle(s, pending).viewport.offset.current == 0)
    }

    @Test func externalFocusToNilJustClearsFocus() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [.windowCreated(EngineFix.snapshot(1))])
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .focusChanged(nil, origin: .system))
        #expect(s.world.focusedWindow == nil)
        #expect(fx.isEmpty)
    }

}
