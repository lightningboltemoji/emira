import Foundation
import Testing
@testable import EmiraCore

// The reducer on a cascading workspace: what is placed, what moves, what opens a cover, and — the
// longest list — what does nothing at all. `StackTests` has the arithmetic; this is the seam.
//
// **Inert must mean nothing happens, never something surprising happens**, which is why the whole
// inert half asserts the state is unchanged rather than only that the batch was empty.

@Suite struct LayoutKindTests {

    /// Three windows on a cascading workspace of the 1000×800 display, at rest.
    static func cascade(_ count: UInt64 = 3) -> State {
        EngineFix.world(count, config: EngineFix.stacked())
    }

    /// One event folded and driven to rest. The effects go back in: a command that opens a cover has
    /// captures to answer, and a `settle` handed none would sit in the head forever.
    static func after(_ s: State, _ event: Event) -> State {
        let (next, effects) = Engine.reduce(s, event)
        return EngineFix.settle(next, effects)
    }

    static func after(_ s: State, _ command: Command) -> State { after(s, .command(command)) }

    static func frames(_ s: State) -> [WindowId: Rect] {
        guard let metrics = s.metrics() else { return [:] }
        return s.layout.targetFrames(scrollOffset: s.viewport.offset.current, metrics: metrics)
    }

    // Placement

    @Test func everyTileIsTheSameSizeAndStaggeredDownRight() throws {
        let s = Self.cascade()
        let frames = Self.frames(s)
        #expect(frames.count == 3)

        let tiles = s.layout.allWindowIds.compactMap { frames[$0] }
        #expect(tiles.allSatisfy { $0.size == tiles[0].size })
        for (earlier, later) in zip(tiles, tiles.dropFirst()) {
            #expect(later.minX - earlier.minX == Stack.stagger)
            #expect(later.minY - earlier.minY == Stack.stagger)
        }
        // The region is the content area, so slot 0 starts at its corner and the last tile ends at the
        // far one — a pin would take its band off this exactly as it does off a strip.
        let region = try #require(s.metrics()).contentArea
        #expect(tiles[0].origin == region.origin)
        #expect(abs(try #require(tiles.last).maxX - region.maxX) < 0.5)
    }

    /// **Nothing parks on a shown cascade**, because everything on one is on screen — so no window is
    /// ever sent to a sliver in the corner while the workspace is in view.
    @Test func nothingIsParkedOrScrolled() {
        let s = Self.cascade(5)
        #expect(Set(s.layout.allWindowIds).isSubset(of: s.world.placedOnScreen))
        #expect(s.layout.visibleWindowIds(scrollOffset: 0, metrics: s.metrics()!).count == 5)
        #expect(s.viewport.offset.current == 0)
        #expect(s.viewport.offset.target == 0)
    }

    /// …and an *unshown* cascade parks in full, exactly as an unshown strip does: parking is not
    /// layout-dependent, only the sizes it carries are.
    @Test func anUnshownCascadeParksInFull() throws {
        var s = Self.cascade()
        let tiled = s.layout.allWindowIds
        s = Self.after(s, .focusWorkspace(.next))
        for id in tiled { #expect(!s.world.isOnScreen(id)) }
    }

    /// Sizing by `n` is the accepted cost: an arrival resizes every window on the workspace.
    @Test func anArrivalResizesEveryTile() {
        var s = Self.cascade(2)
        let before = Self.frames(s)
        s = EngineFix.settle(EngineFix.run(s, [.windowCreated(EngineFix.snapshot(3))]).0)
        let after = Self.frames(s)

        for id in [WindowId(1), WindowId(2)] {
            #expect(after[id]?.size != before[id]?.size)
            #expect(after[id]?.width == before[id]!.width - Stack.stagger)
        }
    }

    @Test func aDepartureResizesEveryTile() {
        var s = Self.cascade()
        let before = Self.frames(s)
        s = Self.after(s, .windowDestroyed(WindowId(3)))
        let after = Self.frames(s)

        for id in [WindowId(1), WindowId(2)] {
            #expect(after[id]?.width == before[id]!.width + Stack.stagger)
        }
    }

    // Focus

    /// Nothing moves on a focus change, so no cover opens — `.focus` plus `.raise` and nothing else,
    /// which is the shape the strip's own within-a-column focus already has.
    @Test func focusStepsTheDiagonalWithoutACover() {
        var s = Self.cascade()
        for direction in [Direction.left, .up] {
            let (next, effects) = Engine.reduce(s, .command(.focus(direction)))
            #expect(!next.motion.isTransitioning)
            #expect(effects == [.focus(WindowId(2)), .raise(WindowId(2)),
                                .setScrims(next.scrims, lifted: false)])
            s = next
            s = EngineFix.settle(s, effects)
            // …and back, so the second direction starts from the same place.
            s = Self.after(s, .focus(.right))
        }
    }

    /// Both members of each pair walk the same diagonal: `left`/`up` go back a slot, `right`/`down`
    /// forward one.
    @Test func bothAxesWalkTheOneDiagonal() {
        var s = Self.cascade()
        #expect(s.world.focusedWindow == WindowId(3))
        s = Self.after(s, .focus(.up))
        #expect(s.world.focusedWindow == WindowId(2))
        s = Self.after(s, .focus(.left))
        #expect(s.world.focusedWindow == WindowId(1))
        s = Self.after(s, .focus(.down))
        #expect(s.world.focusedWindow == WindowId(2))
        s = Self.after(s, .focus(.right))
        #expect(s.world.focusedWindow == WindowId(3))
    }

    @Test func focusStopsAtBothEndsOfTheDiagonal() {
        var s = Self.cascade()
        s = Self.after(s, .focus(.right))
        #expect(s.world.focusedWindow == WindowId(3))          // already at the far end
        for _ in 0..<4 { s = Self.after(s, .focus(.left)) }
        #expect(s.world.focusedWindow == WindowId(1))          // and stops at the near one
    }

    // move-window

    /// `move-window` mirrors `focus`: all four directions swap with the neighbouring slot.
    @Test func moveWindowSwapsWithTheNeighbouringSlot() {
        var s = Self.cascade()
        #expect(s.layout.allWindowIds == [WindowId(1), WindowId(2), WindowId(3)])

        s = Self.after(s, .moveWindow(.left))
        #expect(s.layout.allWindowIds == [WindowId(1), WindowId(3), WindowId(2)])
        s = Self.after(s, .moveWindow(.up))
        #expect(s.layout.allWindowIds == [WindowId(3), WindowId(1), WindowId(2)])
        s = Self.after(s, .moveWindow(.down))
        #expect(s.layout.allWindowIds == [WindowId(1), WindowId(3), WindowId(2)])
        s = Self.after(s, .moveWindow(.right))
        #expect(s.layout.allWindowIds == [WindowId(1), WindowId(2), WindowId(3)])
    }

    /// A tile travelling *back* along the diagonal is going behind its neighbour, so it must not be the
    /// one the cover draws on top.
    @Test func onlyAForwardMoveElevatesTheMover() throws {
        var s = Self.cascade()
        let back = Engine.reduce(s, .command(.moveWindow(.left))).0
        #expect(try #require(back.motion.transition(of: back.monitors.focused)).elevated == nil)

        s = Self.after(s, .focus(.left))   // focus slot 1
        let forward = Engine.reduce(s, .command(.moveWindow(.right))).0
        #expect(try #require(forward.motion.transition(of: forward.monitors.focused)).elevated
                    == WindowId(2))
    }

    // The cover's layer order

    /// **The cover stacks the way the desktop does, not the way the slots do.** The captures are issued
    /// in scope order, which is the cover's z-order bottom→top.
    @Test func theCoverIsOrderedByTheDesktopNotByTheSlots() {
        var s = Self.cascade()
        // Focus 2 then 1, so the desktop's order is 3, 2, 1 — the reverse of the slot order.
        s = Self.after(s, .focus(.left))
        s = Self.after(s, .focus(.left))
        #expect(s.stackingOrder(of: s.layout.allWindowIds)
                    == [WindowId(3), WindowId(2), WindowId(1)])

        let (_, effects) = Engine.reduce(s, .command(.moveWindow(.right)))
        let filmed = effects.compactMap { effect -> WindowId? in
            if case .capture(_, let id, _) = effect { return id }
            return nil
        }
        #expect(filmed == [WindowId(3), WindowId(2), WindowId(1)])
    }

    /// …and a strip is left alone, because nothing on one overlaps: its layer order is layout order.
    @Test func aStripKeepsLayoutOrder() {
        var s = EngineFix.world(3, config: EngineFix.fullWidth)
        s = Self.after(s, .focus(.left))
        let (next, effects) = Engine.reduce(s, .command(.moveWindow(.left)))
        let filmed = effects.compactMap { effect -> WindowId? in
            if case .capture(_, let id, _) = effect { return id }
            return nil
        }
        // Layout order, which after this edit is 2, 1, 3 — and deliberately not the desktop's, which
        // has 2 in front of everything for having just been focused.
        #expect(filmed == next.layout.allWindowIds.filter(filmed.contains))
        #expect(filmed != next.stackingOrder(of: filmed))
    }

    // fullscreen — the one size-changing verb a cascade keeps

    @Test func fullscreenTakesOneTileToTheWholeRegionAndBack() throws {
        var s = Self.cascade()
        let region = try #require(s.metrics()).contentArea

        s = Self.after(s, .fullscreen(.toggle))
        #expect(Self.frames(s)[WindowId(3)] == region)
        // Its neighbours keep their slots: fullscreen is a shadow over one tile's derived size.
        #expect(Self.frames(s)[WindowId(1)]?.origin == region.origin)

        s = Self.after(s, .fullscreen(.toggle))
        #expect(Self.frames(s)[WindowId(3)] != region)
    }

    /// The strip's own solo rule does not run here: a lone tile already *is* the region, so a record
    /// nothing reads would be lifted by the next arrival for no reason.
    @Test func theSoloRuleDoesNotApplyToACascade() {
        let s = Self.cascade(1)
        #expect(s.layout.columns.allSatisfy { !$0.isFullscreen })
    }

    // The inert half

    /// Every verb a cascade has no meaning for changes nothing at all — not the state, not the batch.
    @Test func theVerbsACascadeHasNoMeaningForAreInert() {
        let s = Self.cascade()
        let inert: [Command] = [
            .cycleWidth, .cycleHeight, .grow(.percent(10)), .shrink(.points(50)),
            .consumeOrExpel(.left), .consumeOrExpel(.right),
            .consumeOrExpel(.up), .consumeOrExpel(.down), .centerColumn,
        ]
        for command in inert {
            let (next, effects) = Engine.reduce(s, .command(command))
            #expect(effects.isEmpty, "\(command) emitted \(effects)")
            #expect(next == s, "\(command) moved the state")
        }
    }

    /// The pointer dials both assume windows that are somewhere distinct, and a cascade puts every tile
    /// in one region with thin bands. The guard is the reducer's: the shell keeps reporting crossings.
    @Test func focusFollowsMouseIsInertOnACascade() {
        var config = EngineFix.stacked()
        config.focusFollowsMouse = true
        let s = EngineFix.world(3, config: config)

        let (next, effects) = Engine.reduce(s, .pointerEntered(WindowId(1)))
        #expect(effects.isEmpty)
        #expect(next.world.focusedWindow == s.world.focusedWindow)
    }

    @Test func mouseFollowsFocusIsInertOnACascade() {
        var config = EngineFix.stacked()
        config.mouseFollowsFocus = .force
        let s = EngineFix.world(3, config: config)

        let (next, effects) = Engine.reduce(s, .command(.focus(.left)))
        #expect(next.pointer.pendingWarp == nil)
        #expect(!effects.contains { if case .warpPointer = $0 { return true } else { return false } })
    }

    /// Nothing on a cascade scrolls, so the hand has nothing to drive — and a cover raised over a
    /// gesture that cannot move anything would be the surprise an inert verb owes not to spring.
    @Test func aTrackpadScrollOpensNoCoverOnACascade() {
        var config = EngineFix.stacked()
        config.trackpadScroll = .magnet
        let s = EngineFix.world(3, config: config)

        let (next, effects) = Engine.reduce(s, .trackpadScrollBegan)
        #expect(effects.isEmpty)
        #expect(!next.motion.isTransitioning)
        #expect(next.trackpadScroll == .idle)
    }

    /// A hand-drawn size has no rung to be written to, so the next placement pass takes the window
    /// back — which is what a *move* drag already gets on the other axis.
    @Test func aHandResizeRevertsOnACascade() throws {
        var config = EngineFix.stacked()
        config.interactiveResize = true
        var s = EngineFix.world(2, config: config)

        let subject = WindowId(2)
        let target = try #require(Self.frames(s)[subject])
        let drawn = Rect(x: target.minX, y: target.minY, width: target.width - 120,
                         height: target.height - 90)
        s = EngineFix.run(s, [.dragBegan, .windowFrameChanged(subject, drawn)]).0
        #expect(s.drag.subject == subject)

        let (next, effects) = Engine.reduce(s, .dragEnded)
        #expect(effects.contains(.setFrame(subject, target)))
        #expect(next.workspaces.heightOverrides[subject] == nil)
    }

    // The verb

    /// Switching there and back is lossless: `stack` reads *through* the column partition and never
    /// writes to it, so the columns and their widths are exactly what they were.
    @Test func switchingLayoutAndBackKeepsTheArrangement() {
        var s = EngineFix.world(3, config: EngineFix.laddered())
        s = Self.after(s, .cycleWidth)
        s = Self.after(s, .consumeOrExpel(.left))
        let arrangement = s.layout.columns

        s = Self.after(s, .setLayout(.stack))
        #expect(s.layout.kind == .stack)
        #expect(s.layout.columns == arrangement)

        s = Self.after(s, .setLayout(.strip))
        #expect(s.layout.kind == .strip)
        #expect(s.layout.columns == arrangement)
    }

    /// Asking for the layout a workspace is already in is the no-op it looks like.
    @Test func settingTheLayoutItIsAlreadyInDoesNothing() {
        let s = Self.cascade()
        let (next, effects) = Engine.reduce(s, .command(.setLayout(.stack)))
        #expect(effects.isEmpty)
        #expect(next == s)
    }

    /// The switch is a structural edit like any other: it rides a cover, and every tile travels under
    /// the displacement the edit seeds.
    @Test func theSwitchRidesACover() throws {
        let s = EngineFix.world(3, config: EngineFix.fullWidth)
        let (next, _) = Engine.reduce(s, .command(.setLayout(.stack)))
        #expect(next.motion.isTransitioning)
        let session = try #require(next.motion.transition(of: next.monitors.focused))
        #expect(Set(session.windows) == Set(s.layout.allWindowIds))
    }

    /// `layout.default` is a seed and not a leash: it decides what an address materializes in, and a
    /// workspace already in existence keeps the layout it has.
    @Test func theDefaultSeedsAMaterializingWorkspaceOnly() {
        var s = Self.cascade()
        #expect(s.layout.kind == .stack)

        s = Self.after(s, .setLayout(.strip))
        var relaxed = s.config
        relaxed.defaultLayout = .strip
        s = Self.after(s, .configChanged(relaxed))
        #expect(s.layout.kind == .strip)

        // …and an address nothing has touched yet takes whatever the setting now says.
        s = Self.after(s, .focusWorkspace(.name(WorkspaceName("5")!)))
        #expect(s.layout.kind == .strip)
    }

    // Pins, which are on no workspace and so answer to no layout

    /// A pin's band comes off the content area either way, and the width verbs still walk its two rungs
    /// — the cascade's guards sit *after* the pin branch for exactly this reason.
    @Test func aPinnedWindowKeepsItsWidthVerbsOverACascade() throws {
        var s = Self.cascade()
        s = Self.after(s, .pin(.left))
        let pinned = try #require(s.world.focusedWindow)
        #expect(s.world.isPinned(pinned))

        let before = try #require(s.metrics()?.pinWidth(.left))
        s = Self.after(s, .cycleWidth)
        #expect(try #require(s.metrics()?.pinWidth(.left)) != before)

        // …and the cascade behind it is laid out in what the band left over.
        let region = try #require(s.metrics()).contentArea
        #expect(Self.frames(s)[s.layout.allWindowIds[0]]?.origin == region.origin)
    }
}
