import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// Editing the strip's shape — `move-window` and `consume-or-expel` — including the
// cases whose subject is an absence.

@Suite struct EngineStructuralEditTests {

    /// Every structural command in every direction — the set the totality/absence tests sweep.
    static let structuralCommands: [Command] =
        Direction.allCases.map { Command.moveWindow($0) }
        + Direction.allCases.map { Command.consumeOrExpel($0) }

    // `halfWidth`/`halfWidthSnap` throughout: two 500-wide columns fill the 1000-wide viewport exactly,
    // so nothing parks and nothing scrolls, and every frame is clean arithmetic on (0|500, 0, 500, 800)
    // — or, for a two-window column, its 400-tall halves. Tests that assert *where a window lands* use
    // the snapping fixture; the motion itself is the subject of the section after.

    /// Two windows side by side; `w2` is focused and alone in its column, so a sideways move takes the
    /// whole column with it. Focus is already on the window that moved, so no `.focus` is owed.
    @Test func moveWindowLeftSwapsAColumnWithItsNeighbourAndKeepsFocus() {
        let (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidthSnap), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),          // focused, column 1
        ])
        let (n, fx) = Engine.reduce(s, .command(.moveWindow(.left)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(2)], [WindowId(1)]])
        #expect(n.world.focusedWindow == WindowId(2))
        #expect(EngineFix.approx(EngineFix.placement(of: WindowId(2), in: fx) ?? .zero,
                                 Rect(x: 0, y: 0, width: 500, height: 800)))
        #expect(EngineFix.approx(EngineFix.placement(of: WindowId(1), in: fx) ?? .zero,
                                 Rect(x: 500, y: 0, width: 500, height: 800)))
        #expect(!fx.contains(.focus(WindowId(2))))     // focus never left; a redundant AX set can raise
        #expect(!fx.contains(.raise(WindowId(2))))     // tiled windows in a column don't overlap
    }

    @Test func moveWindowRightAtTheRightEdgeIsANoOp() {
        let (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),          // focused, already rightmost
        ])
        let (n, fx) = Engine.reduce(s, .command(.moveWindow(.right)))
        #expect(fx.isEmpty)
        #expect(n == s)
    }

    @Test func moveWindowLeftAtTheLeftEdgeIsANoOp() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))   // leftmost column
        let (n, fx) = Engine.reduce(s, .command(.moveWindow(.left)))
        #expect(fx.isEmpty)
        #expect(n == s)
    }

    /// The other half of the horizontal rule: with stackmates the *window* leaves rather than the
    /// column moving. Note the column it lands in is a fresh one — a consume followed by an expel
    /// restores the arrangement, not the identity.
    @Test func aStackedWindowMovedSidewaysPopsOutIntoItsOwnColumn() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        let original = s.layout.columns[1].id                   // w2's column, about to be merged away
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(s.layout.columns.map(\.windowIds) == [[WindowId(1), WindowId(2)]])

        let (n, _) = Engine.reduce(s, .command(.moveWindow(.right)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(1)], [WindowId(2)]])
        #expect(n.layout.columns[1].id != original)
    }

    @Test func moveWindowDownSwapsItWithTheWindowBelowItInTheStack() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidthSnap), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // → one column [w1, w2]
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))         // focus the top of the stack

        let (n, fx) = Engine.reduce(s, .command(.moveWindow(.down)))
        #expect(n.layout.columns[0].windowIds == [WindowId(2), WindowId(1)])
        // Two auto windows split the 800-tall area: rows at y 0 and y 400, now swapped.
        #expect(EngineFix.approx(EngineFix.placement(of: WindowId(2), in: fx) ?? .zero,
                                 Rect(x: 0, y: 0, width: 500, height: 400)))
        #expect(EngineFix.approx(EngineFix.placement(of: WindowId(1), in: fx) ?? .zero,
                                 Rect(x: 0, y: 400, width: 500, height: 400)))
    }

    @Test func moveWindowUpAtTheTopOfTheStackIsANoOp() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))         // already row 0
        let (n, fx) = Engine.reduce(s, .command(.moveWindow(.up)))
        #expect(fx.isEmpty)
        #expect(n == s)
    }

    @Test func consumeLeftMergesALoneWindowIntoTheBottomOfTheColumnOnItsLeft() {
        let (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidthSnap), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),          // focused, alone in column 1
        ])
        let (n, fx) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(n.layout.columns.count == 1)
        #expect(n.layout.columns[0].windowIds == [WindowId(1), WindowId(2)])   // landed at the bottom
        #expect(n.world.focusedWindow == WindowId(2))
        #expect(EngineFix.approx(EngineFix.placement(of: WindowId(1), in: fx) ?? .zero,
                                 Rect(x: 0, y: 0, width: 500, height: 400)))
        #expect(EngineFix.approx(EngineFix.placement(of: WindowId(2), in: fx) ?? .zero,
                                 Rect(x: 0, y: 400, width: 500, height: 400)))
    }

    @Test func consumeRightMergesALoneWindowIntoTheTopOfTheColumnOnItsRight() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        let rightColumn = s.layout.columns[1].id
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))         // the lone window on the left

        let (n, _) = Engine.reduce(s, .command(.consumeOrExpel(.right)))
        #expect(n.layout.columns.count == 1)
        #expect(n.layout.columns[0].windowIds == [WindowId(1), WindowId(2)])   // landed at the top
        #expect(n.layout.columns[0].id == rightColumn)                 // the survivor is the target
    }

    @Test func expelPushesAStackedWindowOutIntoANewColumnOnThatSide() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // → [[w1, w2]], w2 focused
        let (n, _) = Engine.reduce(s, .command(.consumeOrExpel(.right)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(1)], [WindowId(2)]])
    }

    /// The property that makes "adjacent in layout order" one rule rather than two conventions:
    /// consuming left then expelling right puts the strip back exactly as it was.
    @Test func consumeAndExpelAreEachOthersInverse() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        let arrangement = s.layout.columns.map(\.windowIds)
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.right)))
        #expect(s.layout.columns.map(\.windowIds) == arrangement)
        #expect(EngineFix.approxScalar(s.motion.viewportOffset.current, 0))
    }

    /// `down` consumes and `up` expels — the vertical axis is not one idea with two ends here, which
    /// is why the handler switches on the direction rather than on `direction.axis`. The *pulled*
    /// window moves, not the focused one, so focus is untouched and no `.focus` is owed.
    @Test func consumeDownPullsTheTopOfTheNextColumnIntoTheBottomOfThisOne() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))
        let (n, fx) = Engine.reduce(s, .command(.consumeOrExpel(.down)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(1), WindowId(2)], [WindowId(3)]])
        #expect(n.world.focusedWindow == WindowId(1))
        #expect(!fx.contains(.focus(WindowId(1))))
    }

    @Test func consumeUpPushesTheFocusedWindowOutIntoItsOwnColumnOnTheRight() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // → [[w1, w2]]
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))
        let (n, _) = Engine.reduce(s, .command(.consumeOrExpel(.up)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(2)], [WindowId(1)]])
    }

    @Test func consumeUpOnAWindowAlreadyAloneInItsColumnIsANoOp() {
        let (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        let (n, fx) = Engine.reduce(s, .command(.consumeOrExpel(.up)))
        #expect(fx.isEmpty)
        #expect(n == s)                                // catches a destroy-and-remint of the column
    }

    @Test func consumeWithNoColumnOnThatSideIsANoOp() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),          // focused, rightmost
        ])
        let (right, rfx) = Engine.reduce(s, .command(.consumeOrExpel(.right)))
        #expect(rfx.isEmpty)
        #expect(right == s)

        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))         // leftmost
        let (left, lfx) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(lfx.isEmpty)
        #expect(left == s)
    }

    @Test func consumeDownWithNoColumnToTheRightIsANoOp() {
        let (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),          // focused, rightmost
        ])
        let (n, fx) = Engine.reduce(s, .command(.consumeOrExpel(.down)))
        #expect(fx.isEmpty)
        #expect(n == s)
    }

    /// The strip has an origin, not an edge, and the two verbs disagree about it on purpose: a *consume*
    /// with no neighbour is a no-op, while an *expel* at the same place still creates its column —
    /// index 0 is an ordinary position on an unbounded axis and every other column shifts right.
    @Test func expellingAtTheStripOriginStillCreatesTheColumn() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // → one column at index 0
        let (n, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(2)], [WindowId(1)]])
    }

    @Test func structuralCommandsWithNothingFocusedAreSilent() {
        let s = EngineFix.booted()
        for command in Self.structuralCommands {
            let (n, fx) = Engine.reduce(s, .command(command))
            #expect(fx.isEmpty, "\(command)")
            #expect(n == s, "\(command)")
        }
    }

    /// The metrics guard sits before the mutation, as `handleCycleWidth`'s does: with no display known
    /// there is no correct frame to place the result at, so no *edit* happens. The membership bridge
    /// at the top of every handler still runs, which is why the comparison is against a bare reconcile
    /// rather than against the untouched layout.
    @Test func structuralCommandsMakeNoEditBeforeADisplayIsKnown() {
        let (s, _) = EngineFix.run(State(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        // Against the whole workspace set rather than the focused strip alone: `Workspaces`' equality
        // covers the shared `ColumnAllocator`, so a handler that minted a `ColumnId` on its way to doing
        // nothing is caught here too.
        var reconciled = s.workspaces
        reconciled.reconcile(stripWindowIds: s.world.stripWindowIds)
        for command in Self.structuralCommands {
            let (n, fx) = Engine.reduce(s, .command(command))
            #expect(fx.isEmpty, "\(command)")
            #expect(n.workspaces == reconciled, "\(command)")
        }
    }

    @Test func structuralCommandsAreSilentForAWindowNotOnTheStrip() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2, role: .dialog)),   // never joins the strip
        ])
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(2), origin: .system))  // …but can still hold focus
        for command in Self.structuralCommands {
            let (n, fx) = Engine.reduce(s, .command(command))
            #expect(fx.isEmpty, "\(command)")
            #expect(n == s, "\(command)")
        }
    }

    /// Every structural command that rearranges the strip opens a transition and captures its scope —
    /// here under `halfWidth`, where the reveal offset does not move at all. That is the case
    /// `scrollReveal` would snap on, and the one a structural edit most needs animated: a swap in full
    /// view is *entirely* structural motion.
    @Test func aStructuralEditOpensATransitionEvenWhenTheViewportNeverMoves() {
        let (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        for command in [Command.moveWindow(.left), .consumeOrExpel(.left)] {
            let (n, fx) = Engine.reduce(s, .command(command))
            #expect(n.motion.isTransitioning, "\(command)")
            #expect(!EngineFix.capturedIds(in: fx).isEmpty, "\(command)")
            #expect(!n.motion.windowAnimators.isEmpty, "\(command)")
            // Nothing has moved on the truth plane yet: the reals wait for the cover.
            #expect(!EngineFix.hasEffect(fx) { if case .setFrame = $0 { return true }; return false },
                    "\(command)")
            #expect(EngineFix.approxScalar(n.motion.viewportOffset.target,
                                           s.motion.viewportOffset.current), "\(command)")
        }
    }

    /// The reason the placement tests above can keep asserting what they assert: with no Screen
    /// Recording grant the strip rearranges instantly, with no cover, no captures and no displacement
    /// animators — across all twelve command cases.
    @Test func withTransitionOffAStructuralEditSnaps() {
        let (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidthSnap), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        for command in Self.structuralCommands {
            let (n, fx) = Engine.reduce(s, .command(command))
            #expect(!n.motion.isTransitioning, "\(command)")
            #expect(EngineFix.capturedIds(in: fx).isEmpty, "\(command)")
            #expect(n.motion.windowAnimators.isEmpty, "\(command)")
        }
    }

    /// The first frame under the cover must reproduce the layout the user was looking at —
    /// `natural(after) + displacement(0) == natural(before)` on every window, exactly, or the raise pops
    /// (the shell gives each layer its capture-time frame and emits no blit until the next tick).
    /// A consume proves it, because it changes heights as well as positions: the displacement carries a
    /// size, not just a translation.
    @Test func theFirstFrameOfAStructuralEditReproducesTheOldLayoutExactly() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        let metrics = try! #require(s.metrics())
        let before = s.layout.naturalFrames(scrollOffset: s.motion.viewportOffset.current,
                                            metrics: metrics)

        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        var fx: [Effect] = []
        for w in s.motion.transition?.windows ?? [] {
            let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; fx += f
        }
        (s, _) = Engine.reduce(s, .coverOnScreen)
        #expect(s.motion.isCovered)

        // The raise emits no blit, so the first frame is the next tick's — with dt small enough that
        // the springs have not meaningfully moved.
        let (ticked, tickFx) = Engine.reduce(s, .tick(dt: 1e-6))
        _ = ticked
        for effect in tickFx {
            guard case .setLayerFrame(let layer, let rect) = effect else { continue }
            let window = try! #require(s.motion.transition?.bindings.first { $0.layer == layer }?.window)
            let was = try! #require(before[window])
            #expect(EngineFix.approx(rect, was), "layer for \(window) popped at the raise")
        }
    }

    /// The two columns cross, and the window the command moved is drawn *over* the one it trades places
    /// with. Z-order is binding order at the raise, so the core states the elevation explicitly: after an
    /// `extendCover` the shell's stacking is create-order and nothing else can put the mover back on top.
    @Test func aSwapDrawsTheMovedWindowOverTheOneItTradesPlacesWith() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),          // focused, alone in column 1
        ])
        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        #expect(s.motion.transition?.elevated == WindowId(2))

        var fx: [Effect] = []
        for w in s.motion.transition?.windows ?? [] {
            let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; fx += f
        }
        let movers = try! #require(s.motion.layerId(for: WindowId(2)))
        #expect(fx.contains(.elevateLayer(movers)))

        // …and the elevation is emitted *inside* the raise's presentation run, before any teleport, so
        // the cover is never composited for a frame with the wrong window on top.
        let raiseIndex = try! #require(fx.firstIndex { if case .beginTransition = $0 { return true }
                                                       return false })
        let elevateIndex = try! #require(fx.firstIndex(of: .elevateLayer(movers)))
        let firstTruth = fx.firstIndex { if case .setFrame = $0 { return true }; return false }
        #expect(elevateIndex == raiseIndex + 1)
        #expect(firstTruth.map { elevateIndex < $0 } ?? true)
    }

    /// Growing the cover buries the mover, so the elevation is re-stated: `extendCover` appends its
    /// layers on top (create-order stacking, no `insertSublayer`), and the re-elevation rides in the same
    /// presentation run as the addition, so the wrong order is never composited even once.
    ///
    /// Five columns rather than three, so a scroll can reach past the shoulder the sweep already carries
    /// and produce a genuine newcomer.
    @Test func growingTheCoverReElevatesTheMoverOverTheNewcomer() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
            .windowCreated(EngineFix.snapshot(4)),
            .windowCreated(EngineFix.snapshot(5)),          // focused, rightmost
        ])
        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and the display shows it
        #expect(s.motion.isCovered)
        let scoped = Set(s.motion.transition?.windows ?? [])

        // A scroll mid-edit aims somewhere the session was not scoped for, pulling in a newcomer.
        var fx: [Effect] = []
        (s, fx) = Engine.reduce(s, .command(.focus(.left)))
        let newcomers = EngineFix.capturedIds(in: fx).filter { !scoped.contains($0) }
        try! #require(!newcomers.isEmpty)

        var extendFx: [Effect] = []
        for w in newcomers { let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; extendFx += f }

        let extendIndex = try! #require(extendFx.firstIndex { if case .extendCover = $0 { return true }
                                                              return false })
        let mover = try! #require(s.motion.layerId(for: WindowId(5)))
        let elevateIndex = try! #require(extendFx.firstIndex(of: .elevateLayer(mover)))
        #expect(elevateIndex > extendIndex)     // after the addition, or it would be buried again
    }

    /// Both halves of a swap animate, in opposite directions, and both land on the layout — the
    /// displacement is a *lag*, so "landed" means the animators are gone rather than parked at a value.
    @Test func bothColumnsOfASwapAnimateAndTheDisplacementsDecayToZero() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        // w2 was at x = 500 and now belongs at 0, so it lags to the *right*; w1 the other way.
        #expect(s.motion.displacement(of: WindowId(2)).minX == 500)
        #expect(s.motion.displacement(of: WindowId(1)).minX == -500)

        let (done, dfx) = EngineFix.drive(s)
        #expect(dfx.contains(.endTransition))
        #expect(done.motion.windowAnimators.isEmpty)
        #expect(!done.motion.isTransitioning)
    }

    /// The other half of the request: a consume must show the *stackmate* making room, not just the
    /// mover flying in. `w1` goes from filling its column to half of it, and the cover has to show
    /// that happening rather than jumping.
    @Test func aConsumeAnimatesTheStackmateHeightToMakeRoom() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(s.motion.displacement(of: WindowId(1)).height == 400)   // 800 was, 400 belongs

        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and the display shows it
        let (mid, midFx) = Engine.reduce(s, .tick(dt: 0.08))
        let layer = try! #require(mid.motion.layerId(for: WindowId(1)))
        let frame = try! #require(EngineFix.layerFrame(of: layer, in: midFx))
        #expect(frame.height < 800 && frame.height > 400)               // genuinely mid-contraction
    }

    /// A structural edit mid-scroll adds *only* the structural delta: the offset keeps travelling on
    /// its own spring and the displacement decays on its, and the emitted frame is their sum. Three
    /// orthogonal quantities is the claim; this is the test of it.
    @Test func aStructuralEditMidScrollComposesWithTheRunningOffset() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and the display shows it
        (s, _) = Engine.reduce(s, .tick(dt: 0.05))
        let travelling = s.motion.viewportOffset.current
        #expect(!s.motion.isSettled)

        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        #expect(s.motion.isCovered)                       // one session, never a second
        #expect(!s.motion.windowAnimators.isEmpty)
        // The scroll was not disturbed by the edit — position and velocity are exactly where the
        // spring left them.
        #expect(s.motion.viewportOffset.current == travelling)

        let (done, dfx) = EngineFix.drive(s)
        #expect(dfx.contains(.endTransition))
        #expect(done.motion.windowAnimators.isEmpty)
    }

    /// The double press. A second edit lands mid-flight, and the layer must not jump: the displacement
    /// is *nudged* by the new layout delta rather than rebuilt, so the emitted frame before and after
    /// the second command agree to within a point.
    @Test func aSecondEditMidFlightIsPositionContinuous() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(3), origin: .system))
        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and the display shows it
        var tickFx: [Effect] = []
        (s, tickFx) = Engine.reduce(s, .tick(dt: 0.05))

        let layer = try! #require(s.motion.layerId(for: WindowId(3)))
        let before = try! #require(EngineFix.layerFrame(of: layer, in: tickFx))
        #expect(s.motion.windowAnimator(WindowId(3))?.x.velocity != 0)   // genuinely mid-flight

        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        let (_, afterFx) = Engine.reduce(s, .tick(dt: 1e-6))
        let after = try! #require(EngineFix.layerFrame(of: layer, in: afterFx))
        #expect(abs(after.minX - before.minX) < 1.0, "the layer jumped: \(before) → \(after)")
        #expect(s.motion.windowAnimator(WindowId(3))?.x.velocity != 0)   // and kept its speed
    }

    /// The movement spring is its own knob, and it is the one a structural edit uses.
    @Test func aStructuralEditUsesTheMovementSpring() {
        var config = EngineFix.halfWidth
        config.moveSpring = .snappy
        let (s, _) = EngineFix.run(EngineFix.booted(config: config), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        let (n, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        #expect(n.motion.windowAnimator(WindowId(2))?.x.params == SpringParams.snappy)
    }

    /// A window can be closed while its displacement is still travelling. `Layout` drops it, so the
    /// animator is measuring a lag against nothing — and `isSettled` is the transition's close gate.
    @Test func destroyingAWindowMidTransitionRetiresItsDisplacement() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        #expect(s.motion.windowAnimator(WindowId(2)) != nil)

        (s, _) = Engine.reduce(s, .windowDestroyed(WindowId(2)))
        #expect(s.motion.windowAnimator(WindowId(2)) == nil)
    }

    /// Every handler reconciles at its top, so an arrangement the bridge undoes is a command that does
    /// nothing at all — and it would look perfectly correct in the single-command test above.
    @Test func aStructuralMoveSurvivesTheReconcileAtTheTopOfTheNextCommand() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        let arranged = s.layout.columns
        (s, _) = Engine.reduce(s, .dragEnded)
        #expect(s.layout.columns == arranged)
        (s, _) = Engine.reduce(s, .command(.focus(.right)))
        #expect(s.layout.columns == arranged)
    }

    /// The strip's two invariants, driven through the reducer rather than the primitives: a run of
    /// mixed commands must never leave an empty column, duplicate or lose a window, drift out of sync
    /// with `World`, or strand focus off the strip.
    @Test func aRunOfStructuralCommandsNeverBreaksTheStripsInvariants() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
            .windowCreated(EngineFix.snapshot(4)),
        ])
        let script: [Command] = [
            .consumeOrExpel(.left), .moveWindow(.down), .moveWindow(.left), .consumeOrExpel(.up),
            .moveWindow(.right), .consumeOrExpel(.down), .consumeOrExpel(.right), .moveWindow(.up),
            .consumeOrExpel(.left), .moveWindow(.right), .consumeOrExpel(.down),
        ]
        for command in script {
            (s, _) = Engine.reduce(s, .command(command))
            let ids = s.layout.allWindowIds
            #expect(s.layout.columns.allSatisfy { !$0.windowIds.isEmpty }, "empty column: \(command)")
            #expect(Set(ids).count == ids.count, "duplicate window: \(command)")
            #expect(Set(ids) == Set(s.world.stripWindowIds), "layout/world drift: \(command)")
            let focused = try! #require(s.world.focusedWindow)
            #expect(s.layout.columnIndex(ofWindow: focused) != nil, "focus stranded: \(command)")
        }
    }

    /// A *consume* can merge a column away while its width is still in flight, and the animator keyed on
    /// its id would otherwise hold the settle gate for a motion nobody can see. The subject is that
    /// entry's absence — without the retirement the transition still closes, since an orphan settles.
    @Test func aConsumeThatDestroysAColumnRetiresItsWidthAnimator() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),          // focused, column 1
        ])
        let doomed = s.layout.columns[1].id
        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and the display shows it
        #expect(s.motion.columnWidth(doomed) != nil)   // in flight, cover up

        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(s.layout.columnIndex(withId: doomed) == nil)
        #expect(s.motion.columnWidth(doomed) == nil)
        #expect(s.motion.currentColumnWidths.isEmpty)

        let (done, dfx) = EngineFix.drive(s)
        #expect(!done.motion.isTransitioning)
        #expect(dfx.contains(.endTransition))
        #expect(done.layout.columns.count == 1)
    }

    /// A raised cover holds real windows teleported into a layout that no longer exists, so an edit under
    /// one re-places the reals rather than snapping, and joins the running session.
    ///
    /// A *consume* is the edit to test it with: a column swap under `fullWidth` would rightly emit
    /// nothing (the focused column is flush left before and after), while merging two columns genuinely
    /// relocates all three.
    @Test func aStructuralEditMidTransitionRidesTheOpenSessionAndRePlacesTheReals() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))     // → w2, an animated scroll
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and the display shows it
        #expect(s.motion.isCovered)

        let (n, fx) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(1), WindowId(2)], [WindowId(3)]])
        #expect(n.motion.isCovered)                    // one session throughout, never a second
        #expect(!EngineFix.hasEffect(fx) { if case .beginTransition = $0 { return true }; return false })
        // …and the invariant that matters holds: every window the edit puts on screen is in the cover's
        // scope. `w1` moves from its park sliver into a column now on screen, and a window sliding into
        // view with no captured layer is a wallpaper hole.
        let scoped = Set(n.motion.transition?.windows ?? [])
        #expect(scoped.contains(WindowId(1)))
        #expect(scoped.isSuperset(of: n.layout.visibleWindowIds(
            scrollOffset: n.motion.viewportOffset.target, metrics: n.metrics()!)))
        // The reals teleported into the *new* structure behind the still-raised cover.
        #expect(EngineFix.approx(EngineFix.placement(of: WindowId(1), in: fx) ?? .zero,
                                 Rect(x: 0, y: 0, width: 1000, height: 400)))
        #expect(EngineFix.approx(EngineFix.placement(of: WindowId(2), in: fx) ?? .zero,
                                 Rect(x: 0, y: 400, width: 1000, height: 400)))

        let (done, dfx) = EngineFix.drive(n)
        #expect(!done.motion.isTransitioning)
        #expect(dfx.contains(.endTransition))
    }

}
