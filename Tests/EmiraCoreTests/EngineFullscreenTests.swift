import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// Fullscreen as the strip understands it — the takeover, and its exact undo.

@Suite struct EngineFullscreenTests {

    /// The strip every test below starts from: `[w1] [w2 w3] [w4]`, focus on `w3`, the first two columns
    /// in view and the third scrolled off. ½-width presets over a 1000-wide display, snapping — these
    /// are about *where* things end up.
    static func stackedStrip() -> State {
        var s = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidthSnap), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ]).0
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // w3 joins w2's column
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(4))]).0         // …opening beside that column
        // Back to w3 by way of w1, which is what scrolls the strip home.
        for command in [Command.focus(.left), .focus(.left), .focus(.right), .focus(.down)] {
            (s, _) = Engine.reduce(s, .command(command))
        }

        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(2), WindowId(3)], [WindowId(4)]])
        #expect(s.world.focusedWindow == WindowId(3))
        #expect(s.motion.viewportOffset.current == 0)
        return s
    }

    /// A column at 40% goes to 100% and comes back to exactly 40% — `isFullscreen` shadows the width
    /// intent instead of replacing it, so there is nothing stored to restore and nothing to round.
    @Test func fullscreenTogglesBetweenTheColumnsOwnWidthAndTheFullStripWidth() {
        var s = EngineFix.oneThirdSnap()                              // 1000-wide content area
        (s, _) = Engine.reduce(s, .command(.grow(.points(400.0 - EngineFix.third))))
        #expect(EngineFix.approxScalar(EngineFix.width(s), 400))           // …a 40% column

        (s, _) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        #expect(s.layout.columns[0].isFullscreen)
        #expect(EngineFix.width(s) == 1000)

        (s, _) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        #expect(!s.layout.columns[0].isFullscreen)
        #expect(EngineFix.approxScalar(EngineFix.width(s), 400))           // back exactly, not near it
    }

    /// The same round trip from a ladder rung: the preset is never touched, so a config reload or a
    /// display change under a fullscreen column still uncovers the right width.
    @Test func fullscreenUncoversALadderRungEvenAfterThePresetsChange() {
        let config = Config(transitionMode: .off)             // ⅓ / ½ / ⅔ of 1000
        var s = EngineFix.run(EngineFix.booted(config: config), [.windowCreated(EngineFix.snapshot(1))]).0
        (s, _) = Engine.reduce(s, .command(.cycleWidth))          // ⅓ → ½
        #expect(EngineFix.width(s) == 500)

        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        #expect(EngineFix.width(s) == 1000)

        // The presets change *while* the column is fullscreen. It stays full-width…
        let rewritten = Config(widthPresets: PresetCycle([.proportion(0.25), .proportion(0.75)]),
                               transitionMode: .off)
        (s, _) = Engine.reduce(s, .configChanged(rewritten))
        #expect(EngineFix.width(s) == 1000)
        // …and uncovers the rung it was on, resolved against the *new* ladder. A stored 500 would have
        // been a number about a config that no longer exists.
        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
        #expect(EngineFix.width(s) == 750)                             // index 1, now ¾
    }

    /// `fullscreen` is `cycleWidth`'s motion with a different intent in front of it — the same width
    /// spring, the same transition over a viewport that need not move.
    @Test func fullscreenAnimatesTheColumnWidthExactlyAsACycleDoes() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [.windowCreated(EngineFix.snapshot(1))])
        let column = s.layout.columns[0].id

        let (f, ffx) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        s = f
        #expect(s.motion.isTransitioning)
        #expect(EngineFix.approxScalar(s.motion.columnWidth(column)?.current ?? 0, EngineFix.third))
        #expect(EngineFix.approxScalar(s.motion.columnWidth(column)?.target ?? 0, 1000))
        #expect(EngineFix.capturedIds(in: ffx) == [WindowId(1)])

        let (done, dfx) = EngineFix.drive(s)
        #expect(dfx.contains(.endTransition))
        #expect(EngineFix.approxScalar(EngineFix.placement(of: WindowId(1), in: dfx)?.width ?? 0, 1000))
        #expect(EngineFix.width(done) == 1000)
        #expect(done.motion.currentColumnWidths.isEmpty)
    }

    /// Nothing is hidden and no Space is created: the neighbouring column is pushed out of the viewport
    /// and parks at its sliver, then scrolls back in when fullscreen comes off.
    ///
    /// The `columnGap` is deliberate — gapless, the revealed column's left edge lands exactly on the
    /// departing one's right edge, and which side of "visible" that falls on comes down to the last bit
    /// of a `Double`.
    @Test func fullscreenPushesTheNeighbouringColumnOffTheViewportAndBack() {
        let config = Config(columnGap: 8, transitionMode: .off)
        var s = EngineFix.run(EngineFix.booted(config: config), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),                     // focused, column 1
        ]).0

        let (full, ffx) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        s = full
        #expect(EngineFix.hasEffect(ffx) { if case .park(WindowId(1), _) = $0 { return true }; return false })
        #expect(EngineFix.width(s, 1) == 1000)

        let (back, bfx) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        #expect(EngineFix.hasEffect(bfx) { if case .setFrame(WindowId(1), _) = $0 { return true }; return false })
        #expect(EngineFix.approxScalar(EngineFix.width(back, 1), EngineFix.third))
    }

    /// An explicit width verb clears fullscreen, and the press that clears it is continuous: the delta
    /// comes off the *resolved* width, which while fullscreen is the full width. Without the clear,
    /// `shrink` here would write a number nothing can show — a dead knob.
    @Test func anExplicitWidthVerbClearsFullscreenAndActsAtOnce() {
        var s = EngineFix.oneThirdSnap()
        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        #expect(EngineFix.width(s) == 1000)

        (s, _) = Engine.reduce(s, .command(.shrink(.percent(10))))
        #expect(!s.layout.columns[0].isFullscreen)
        #expect(EngineFix.width(s) == 900)                             // 100% − 10%, on the first press

        // …and the ladder resumes the same way it does after a `grow`, with no nearest-rung guess.
        let laddered = Config(transitionMode: .off)           // ⅓ / ½ / ⅔
        var t = EngineFix.run(EngineFix.booted(config: laddered), [.windowCreated(EngineFix.snapshot(1))]).0
        (t, _) = Engine.reduce(t, .command(.fullscreen(.on)))
        (t, _) = Engine.reduce(t, .command(.cycleWidth))
        #expect(!t.layout.columns[0].isFullscreen)
        #expect(t.layout.columns[0].widthPreset == 1)             // ⅓ → ½, from where the ladder was
        #expect(EngineFix.width(t) == 500)
    }

    /// A column already at the full width has nothing to animate, so the command is silent — but the
    /// *state* still moved, which is what makes the next press restore rather than do nothing twice.
    @Test func fullscreenOnAnAlreadyFullWidthColumnIsSilentAndStillToggles() {
        let config = Config(widthPresets: PresetCycle([.proportion(1.0)]), transitionMode: .off)
        var s = EngineFix.run(EngineFix.booted(config: config), [.windowCreated(EngineFix.snapshot(1))]).0
        #expect(EngineFix.width(s) == 1000)

        let (full, ffx) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        s = full
        #expect(ffx.isEmpty)                                     // nothing to look at…
        #expect(!s.motion.isTransitioning)
        #expect(s.layout.columns[0].isFullscreen)                // …but the flag moved

        (s, _) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        #expect(!s.layout.columns[0].isFullscreen)
    }

    /// `.on`/`.off` assert an absolute state for a script or a rule, so repeating one is idempotent —
    /// the whole reason `Toggle` has three cases rather than being a bare flip.
    @Test func fullscreenOnAndOffAreAbsoluteAndIdempotent() {
        var s = EngineFix.oneThirdSnap()
        for _ in 0..<2 {
            (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
            #expect(s.layout.columns[0].isFullscreen)
        }
        for _ in 0..<2 {
            (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
            #expect(!s.layout.columns[0].isFullscreen)
        }
    }

    /// A window that refuses to *grow* must stop being asked, exactly as one that refuses to shrink does.
    /// A refused shrink answers wider, so `Layout.resolvedWidth` widens the column and the target becomes
    /// the answer; a refused grow answers narrower and geometry deliberately does not follow, so nothing
    /// but this quiets the re-ask a scroll would otherwise trigger, once per scroll, forever.
    @Test func aWindowThatRefusedToGrowIsNotAskedAgainOnEveryScroll() {
        let config = Config(widthPresets: PresetCycle([.proportion(1.0 / 3.0)]),
                            columnGap: 8, transitionMode: .off)
        var s = EngineFix.run(EngineFix.booted(config: config), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ]).0
        (s, _) = Engine.reduce(s, .command(.focus(.left)))        // focus w1, the stubborn one

        // Fullscreen it: the column goes to 1000, and the app answers 400 and will not budge.
        var (next, fx) = Engine.reduce(s, .command(.fullscreen(.on)))
        s = next
        let asked = try! #require(EngineFix.placement(of: WindowId(1), in: fx))
        #expect(asked.width == 1000)
        var landed = asked
        landed.size = Size(width: 400, height: asked.height)
        (s, _) = Engine.reduce(s, .placementCorrected(WindowId(1), requested: asked, actual: landed))

        // The column follows the answer down — no phantom 600 pt of strip nobody can fill…
        #expect(EngineFix.width(s, 0) == 400)
        // …and the window is therefore asked for the width it actually gives, at every offset the strip
        // reaches. This is the assertion the bug fails: before the fix, each scroll re-asked for 1000.
        for direction in [Direction.right, .left, .right] {
            (next, fx) = Engine.reduce(s, .command(.focus(direction)))
            s = next
            if let re = EngineFix.placement(of: WindowId(1), in: fx) {
                #expect(re.width == 400, "focus \(direction) re-asked for \(re.width)")
            }
        }
    }

    /// The half the user watches. The refusal reaches the column's resolved width, which is already an
    /// animated quantity, so the layer *springs back* rather than being clamped: it expands toward 1000,
    /// the answer lands, and it settles onto 400 continuously. The continuity is the point — a clamp
    /// would show up as a one-frame jump.
    @Test func aRefusedGrowSpringsTheLayerBackInsteadOfJumping() throws {
        let config = Config(widthPresets: PresetCycle([.proportion(1.0 / 3.0)]), columnGap: 8)
        var (s, _) = EngineFix.run(EngineFix.booted(config: config), [.windowCreated(EngineFix.snapshot(1))])
        (s, _) = EngineFix.drive(s)                                   // settle the arrival

        // Fullscreen opens a transition; the cover raises, reaches the glass, and the real is teleported
        // to 1000…
        var (next, fx) = Engine.reduce(s, .command(.fullscreen(.on)))
        s = next
        (next, _) = Engine.reduce(s, .captureReady(WindowId(1)))
        s = next
        (next, fx) = Engine.reduce(s, .coverOnScreen)
        s = next
        let layer = try #require(s.motion.transition?.bindings.first?.layer)
        let asked = try #require(EngineFix.placement(of: WindowId(1), in: fx))
        #expect(asked.width == 1000)

        // …the layer is on its way out to 1000…
        var widths: [Double] = []
        for _ in 0..<8 {
            (next, fx) = Engine.reduce(s, .tick(dt: 1.0 / 120))
            s = next
            if let f = EngineFix.layerFrame(of: layer, in: fx) { widths.append(f.width) }
        }
        #expect(widths.last! > EngineFix.third + 1)                   // genuinely stretching

        // …and then the app answers 400, under the raised cover.
        var landed = asked
        landed.size = Size(width: 400, height: asked.height)
        (s, _) = Engine.reduce(s, .placementCorrected(WindowId(1), requested: asked, actual: landed))

        widths = []
        for _ in 0..<600 {
            (next, fx) = Engine.reduce(s, .tick(dt: 1.0 / 120))
            s = next
            if let f = EngineFix.layerFrame(of: layer, in: fx) { widths.append(f.width) }
            if !s.motion.isTransitioning { break }
        }
        // It collapses to what the window is…
        #expect(EngineFix.approxScalar(widths.last!, 400))
        // …and gets there continuously: the layer peaks near 739 and settles on 400, so a clamp would
        // show a single frame-to-frame step of ~340 pt where a spring at 120 fps shows ~29. The bound
        // sits between them with room on both sides.
        let biggestStep = zip(widths, widths.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(biggestStep < 100, "layer jumped \(biggestStep) pt in one frame")
    }

    /// Total against a world with nothing to fullscreen, like every other command.
    @Test func fullscreenWithNothingFocusedIsSilent() {
        for toggle in [Toggle.on, .off, .toggle] {
            let (s, fx) = Engine.reduce(EngineFix.booted(), .command(.fullscreen(toggle)))
            #expect(fx.isEmpty)
            #expect(s.layout.isEmpty)
        }
    }

    /// The whole feature in one round trip. Fullscreen is a **window** operation: a window with
    /// stackmates pops out into a column of its own — which is how it gets full *height* too, with no
    /// per-window height intent needed — and the second press is an *undo* rather than a second width
    /// change. The column it returns to is the same `ColumnId` it left, not a rebuild.
    @Test func fullscreenExpelsAStackedWindowAndPutsItBackWhereItCameFrom() {
        var s = Self.stackedStrip()
        let home = s.layout.columns[1].id

        (s, _) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        // Popped out **in place**: the column it left slides right, so the strip does not rearrange
        // around the window the user is looking at.
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(3)], [WindowId(2)], [WindowId(4)]])
        #expect(EngineFix.width(s, 1) == 1000)
        #expect(s.layout.visibleWindowIds(scrollOffset: s.motion.viewportOffset.current,
                                          metrics: s.metrics()!) == [WindowId(3)])

        (s, _) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(2), WindowId(3)], [WindowId(4)]])
        #expect(s.layout.columns[1].id == home)
        #expect(EngineFix.width(s, 1) == 500)
        // …and the scroll position too, which is the half a column that merely shrinks again never had.
        #expect(s.motion.viewportOffset.current == 0)
    }

    /// The row, not just the column: a window taken out of the middle of a stack goes back to the
    /// middle. `Layout.move(window:toColumn:at:)` clamps, so a stack that changed depth meanwhile lands
    /// it at the nearest end rather than refusing.
    @Test func fullscreenRestoresTheRowWithinTheStackNotJustTheColumn() {
        var s = Self.stackedStrip()
        (s, _) = Engine.reduce(s, .command(.focus(.down)))            // w4 is still its own column…
        s = EngineFix.run(s, []).0
        (s, _) = Engine.reduce(s, .command(.focus(.right)))           // …so go get it
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // [w1] [w2 w3 w4]
        (s, _) = Engine.reduce(s, .command(.focus(.up)))              // the middle one, w3
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(2), WindowId(3), WindowId(4)]])
        #expect(s.world.focusedWindow == WindowId(3))

        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(3)], [WindowId(2), WindowId(4)]])

        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(2), WindowId(3), WindowId(4)]])
    }

    /// A window already alone in its column has nothing to expel, so fullscreen stays the pure resize it
    /// has always been — the same branch `move-window` and `consume-or-expel` make. Nothing is minted and
    /// nothing is merged, which is what keeps the width spring (and its correction spring-back) in play.
    @Test func fullscreenOnASoloWindowMovesNothingStructural() {
        var s = Self.stackedStrip()
        (s, _) = Engine.reduce(s, .command(.focus(.left)))            // w1, alone in column 0
        let before = s.layout.columns.map(\.id)

        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        #expect(s.layout.columns.map(\.id) == before)
        #expect(EngineFix.width(s, 0) == 1000)

        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
        #expect(s.layout.columns.map(\.id) == before)
        #expect(EngineFix.width(s, 0) == 500)
    }

    /// The stack can vanish while the window is fullscreen — the stackmate closed, or moved away. There
    /// is then nothing to merge into, so the window keeps the column it is in and simply stops being full
    /// width, which is exactly what fullscreen did before it remembered anything. The anchor names that
    /// same column, so the scroll falls back to the ordinary reveal in the same breath.
    @Test func unFullscreenKeepsItsOwnColumnWhenTheStackItLeftHasGone() {
        var s = Self.stackedStrip()
        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(3)], [WindowId(2)], [WindowId(4)]])

        s = EngineFix.run(s, [.windowDestroyed(WindowId(2))]).0            // the column's last window

        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(3)], [WindowId(4)]])
        #expect(EngineFix.width(s, 1) == 500)                              // its own width, all that was owed
        #expect(!s.layout.columns[1].isFullscreen)
    }

    /// Why the record stores a column and a distance rather than a scroll offset. A column that changed
    /// width to the *left* of the anchor moves every strip coordinate right of it, so a remembered
    /// offset would put the strip back somewhere it never was. Re-reading the anchor's left edge absorbs
    /// exactly that, and the column comes to rest the same distance from the viewport's edge it left at.
    @Test func theViewportAnchorSurvivesAColumnResizingToItsLeft() {
        var s = Self.stackedStrip()
        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))

        // Widen column 0 while w3 is fullscreen, then come back to it.
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        (s, _) = Engine.reduce(s, .command(.grow(.points(100))))
        #expect(EngineFix.width(s, 0) == 600)
        (s, _) = Engine.reduce(s, .command(.focus(.right)))
        #expect(s.world.focusedWindow == WindowId(3))

        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(2), WindowId(3)], [WindowId(4)]])
        // 500 pt from the content area's left edge — where it was — rather than the remembered 0, which
        // is now 100 pt of somebody else's column.
        let strip = s.layout.strip(metrics: s.metrics()!)
        #expect(strip.leftEdge(of: 1) - s.motion.viewportOffset.current == 500)
        #expect(s.motion.viewportOffset.current == 100)
    }

    /// The anchor can survive while everything that *put* it where it was does not. Its `dx` then asks
    /// for an offset left of the strip's origin — there is no longer anything there to show — and the
    /// clamp every scroll target passes through absorbs it: the strip lands flush left and the column
    /// gives up the distance rather than being pushed right with nothing behind it.
    @Test func aRestoredAnchorWithNothingLeftOfItCollapsesFlushInsteadOfPushingRight() {
        var s = Self.stackedStrip()
        // A fourth column, so the strip is still scrollable after the loss and the *floor* is what bites
        // rather than the ceiling collapsing to zero anyway.
        (s, _) = Engine.reduce(s, .command(.focus(.right)))
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(5))]).0
        for command in [Command.focus(.left), .focus(.left), .focus(.left), .focus(.right), .focus(.down)] {
            (s, _) = Engine.reduce(s, .command(command))
        }
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(2), WindowId(3)], [WindowId(4)], [WindowId(5)]])
        #expect(s.world.focusedWindow == WindowId(3))
        #expect(s.motion.viewportOffset.current == 0)      // …so the anchor's dx is a full column, 500

        // Animated, deliberately: the snap path re-clamps the resting offset in `placeAtRest`, so
        // only a transition can tell whether the *restore itself* clamps. Aimed past the origin, the
        // scroll would travel there and sit there — `closeTransition` snaps to the target it was given.
        (s, _) = Engine.reduce(s, .configChanged(EngineFix.halfWidth))
        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        (s, _) = EngineFix.drive(s)
        s = EngineFix.run(s, [.windowDestroyed(WindowId(1))]).0  // the column the 500 was measured across
        (s, _) = EngineFix.drive(s)

        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
        #expect(s.motion.viewportOffset.target == 0)       // aimed at the origin, not 500 pt past it
        (s, _) = EngineFix.drive(s)
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(2), WindowId(3)], [WindowId(4)], [WindowId(5)]])
        // 0 − 500 asks to look past the strip's origin; the clamp floors it, so the column comes to rest
        // at the content area's left edge instead of 500 pt into empty space.
        #expect(EngineFix.approxScalar(s.motion.viewportOffset.current, 0))
        #expect(EngineFix.approxScalar(s.layout.strip(metrics: s.metrics()!).leftEdge(of: 0)
                                       - s.motion.viewportOffset.current, 0))
    }

    /// An explicit width verb ends the operation, record and all — the same decision that already clears
    /// the flag, for the same reason. What the user asked for out loud is where things now are, so a
    /// later fullscreen undoes to *here* rather than teleporting the window back into a stack it left
    /// two commands ago.
    @Test func aWidthVerbClearsTheUndoRecordAndNotJustTheFlag() {
        var s = Self.stackedStrip()
        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        (s, _) = Engine.reduce(s, .command(.shrink(.percent(10))))
        #expect(s.layout.columns[1].fullscreen == nil)
        #expect(EngineFix.width(s, 1) == 900)

        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(3)], [WindowId(2)], [WindowId(4)]])
    }

    /// Still not exclusive: two fullscreen windows is two full-width columns, an arrangement `grow`
    /// already reaches. Each carries its own record, so each undoes on its own and in either order.
    @Test func twoWindowsCanBeFullscreenAtOnceAndEachUndoesOnItsOwn() {
        var s = Self.stackedStrip()
        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))          // w3 pops out
        for _ in 0..<2 { (s, _) = Engine.reduce(s, .command(.focus(.right))) }
        #expect(s.world.focusedWindow == WindowId(4))
        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))          // w4, already alone
        #expect(EngineFix.width(s, 1) == 1000 && EngineFix.width(s, 3) == 1000)

        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))         // w4 first
        #expect(EngineFix.width(s, 3) == 500)
        #expect(EngineFix.width(s, 1) == 1000)                              // w3 untouched by it

        for _ in 0..<2 { (s, _) = Engine.reduce(s, .command(.focus(.left))) }
        #expect(s.world.focusedWindow == WindowId(3))
        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(2), WindowId(3)], [WindowId(4)]])
    }

    /// A cross-workspace move carries the fullscreen *width*, because that is a size the user asked for
    /// out loud — but not the record, whose columns are on the strip it left. It arrives fullscreen with
    /// nothing to undo, which is the state `Fullscreen.plain` exists to name.
    @Test func aFullscreenWindowMovedToAnotherWorkspaceCarriesTheWidthButNotTheUndo() {
        var s = Self.stackedStrip()
        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        (s, _) = Engine.reduce(s, .command(.moveToWorkspaceAndFocus(.name(WorkspaceName("2")!))))
        #expect(s.layout.columns.map(\.windowIds) == [[WindowId(3)]])
        #expect(s.layout.columns[0].fullscreen == .plain)
        #expect(EngineFix.width(s, 0) == 1000)

        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
        #expect(EngineFix.width(s, 0) == 500)
        // The strip it left closed ranks and is not reached into from here.
        #expect(s.workspaces[WorkspaceName("1")!].columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(2)], [WindowId(4)]])
    }

    /// The expel is a **structural edit**, and the growth to full width rides that rather than the width
    /// spring: the popped-out column is born at 100% and never resizes, so exactly one animator has an
    /// opinion about its width — the same division of labour `springHeightChange` keeps on the other axis.
    @Test func fullscreensExpelAnimatesAsAStructuralEditNotAWidthSpring() {
        var s = Self.stackedStrip()
        (s, _) = Engine.reduce(s, .configChanged(EngineFix.halfWidth))      // …now animating

        let (full, ffx) = Engine.reduce(s, .command(.fullscreen(.on)))
        #expect(full.motion.isTransitioning)
        #expect(full.motion.columnWidth(full.layout.columns[1].id) == nil)
        #expect(full.motion.windowAnimator(WindowId(3)) != nil)
        #expect(EngineFix.capturedIds(in: ffx).contains(WindowId(3)))

        let (done, dfx) = EngineFix.drive(full)
        #expect(dfx.contains(.endTransition))
        #expect(EngineFix.approxScalar(EngineFix.placement(of: WindowId(3), in: dfx)?.width ?? 0, 1000))
        #expect(EngineFix.width(done, 1) == 1000)
        #expect(done.motion.currentColumnWidths.isEmpty)
    }

    /// A fullscreen press landing on a scroll still in flight *redirects* that session rather than
    /// opening a second one — the expel is a structural edit and rides `driveTransition` like every
    /// other. The anchor is read off `viewportOffset.target`, not `.current`, so what it remembers is
    /// where the interrupted scroll was going to come to rest and not the frame it was passing through.
    @Test func fullscreenLandingMidScrollRidesTheOpenTransitionAndAnchorsOnItsDestination() {
        var s = Self.stackedStrip()
        (s, _) = Engine.reduce(s, .configChanged(EngineFix.halfWidth))

        // `center-column` scrolls without moving focus, so the press below lands on w3 with the strip
        // genuinely in flight — 0 → 250, interrupted three frames in.
        (s, _) = Engine.reduce(s, .command(.centerColumn))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and the display shows it
        for _ in 0..<3 { (s, _) = Engine.reduce(s, .tick(dt: 1.0 / 120)) }
        let destination = s.motion.viewportOffset.target
        #expect(destination == 250)
        #expect(!EngineFix.approxScalar(s.motion.viewportOffset.current, destination))

        let generation = s.motion.retargetGeneration
        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        #expect(s.motion.retargetGeneration > generation)          // redirected…
        #expect(s.motion.transition != nil)                        // …the same session, not a second one
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(3)], [WindowId(2)], [WindowId(4)]])

        (s, _) = EngineFix.drive(s)
        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
        (s, _) = EngineFix.drive(s)
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(2), WindowId(3)], [WindowId(4)]])
        // Where the interrupted scroll was coming to rest, not the frame it was passing through — the
        // two are ~250 pt apart here, so an anchor read off `.current` would land visibly short.
        #expect(EngineFix.approxScalar(s.motion.viewportOffset.current, destination))
    }

    @Test func cyclingWidthWrapsBackToTheFirstPreset() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        for expected in [1, 2, 0] {                                // ⅓ → ½ → ⅔ → ⅓
            (s, _) = Engine.reduce(s, .command(.cycleWidth))
            (s, _) = EngineFix.drive(s)
            #expect(s.layout.columns[1].widthPreset == expected)
        }
        #expect(EngineFix.approxScalar(s.layout.strip(metrics: s.metrics()!).columnWidths[1], 1000.0 / 3.0))
    }

    /// Totality: nothing focused, no display, and a cycle that resolves to the same width are all
    /// silent — never a transition that cannot close.
    @Test func aResizeThatChangesNothingIsSilent() {
        // A single-preset cycle: the index advances (wrapping onto itself) and no geometry moves.
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.halfWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        let (c, cfx) = Engine.reduce(s, .command(.cycleWidth))
        #expect(!c.motion.isTransitioning)
        #expect(cfx.isEmpty)

        // Nothing focused at all.
        s = EngineFix.booted()
        let (empty, efx) = Engine.reduce(s, .command(.cycleWidth))
        #expect(!empty.motion.isTransitioning)
        #expect(efx.isEmpty)
    }

    @Test func layerFramesFollowNaturalPositionsWhileRealsPark() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))       // scroll w3 → w2
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and the display shows it
        #expect(s.motion.isCovered)

        // w3's *real* window is parked (a corner nub); its layer rides the natural, un-parked position,
        // sliding off the right edge. The two disagree by design — that is what makes a scrolled-off
        // window glide off-screen instead of jumping to a sliver.
        let realW3 = s.world.windows[WindowId(3)]!.frame
        let (t, tfx) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        let metrics = t.metrics()!
        let natural = t.layout.naturalFrames(scrollOffset: t.motion.viewportOffset.current, metrics: metrics)
        for binding in t.motion.transition?.bindings ?? [] {
            let lf = EngineFix.layerFrame(of: binding.layer, in: tfx)
            #expect(lf != nil)
            #expect(EngineFix.approx(lf!, natural[binding.window]!))
        }
        let w3layer = t.motion.transition!.layerId(for: WindowId(3))!
        #expect(!EngineFix.approx(EngineFix.layerFrame(of: w3layer, in: tfx)!, realW3))
    }

    @Test func holdTimeoutForceClosesTheTransition() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and the display shows it
        #expect(s.motion.isCovered)
        // Never land the reals — the ~1 s hold-timeout closes the cover regardless.
        let (done, fx) = Engine.reduce(s, .holdTimeout)
        #expect(done.motion.isTransitioning == false)
        #expect(fx == [.endTransition])
        // Snapped to the target so resting truth matches the reveal, even though we bailed mid-flight.
        #expect(done.motion.viewportOffset.current == done.motion.viewportOffset.target)
        #expect(EngineFix.approxScalar(done.motion.viewportOffset.current, 1000))
    }

    /// The same timeout one phase earlier, where the close is not free. A session that dies in its capture
    /// head never raised a cover and so never teleported anything, but closing it still snaps the viewport
    /// to the destination — leaving the strip claiming a scroll no window performed. The placement pass is
    /// what settles that, and it is the whole difference between the two phases.
    @Test func aHoldTimeoutInTheCaptureHeadStillPlacesTheWindows() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))      // aimed at offset 0; no still ever lands
        #expect(s.motion.phase == .capturing)

        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .holdTimeout)
        #expect(s.motion.phase == .idle)
        #expect(fx.contains(.endTransition))
        #expect(EngineFix.approxScalar(s.motion.viewportOffset.current, 0))
        // w1 comes into view and w2 leaves it — the moves the abandoned transition owed.
        #expect(EngineFix.placement(of: WindowId(1), in: fx) != nil)
        #expect(EngineFix.placement(of: WindowId(2), in: fx) != nil)
    }

    /// The fourth and last way out of a capture head, and the one whose re-place belongs to somebody else:
    /// `abandonTransition`, reached when a switch is handed no before-geometry. `switchWorkspace` closes
    /// the session and `finishStructuralEdit` places behind it, so the deferral `reassertTruthPlane` makes
    /// while capturing — emit nothing, the raise will read it — is still honoured by a raise that never
    /// comes. Enumerated because the branch is *silent* when it breaks: a head that exits without placing
    /// leaves the strip claiming a scroll no window performed, and nothing scheduled to correct it.
    @Test func aWorkspaceSwitchAbandoningTheCaptureHeadStillPlacesTheWindows() {
        var config = EngineFix.fullWidth
        config.windowRules = [WindowRule(appId: "com.other.app", workspace: WorkspaceName("3")!)]
        var (s, _) = EngineFix.run(EngineFix.booted(config: config), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(s.motion.phase == .capturing)

        // A rule-assigned window opens on "3" and takes the user with it — a switch with nothing to
        // animate from, which abandons the head rather than retargeting it.
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(3, bundle: "com.other.app")))
        #expect(s.motion.phase == .idle)
        #expect(fx.contains(.endTransition))
        #expect(s.workspaces.focused == WorkspaceName("3")!)
        // Every window answered for: the newcomer on the glass, the strip left behind parked. The stream
        // is a diff, so it names w2 leaving the glass and w3 arriving; w1 was already at its park slot.
        #expect(s.world.placedOnScreen == [WindowId(3)])
        #expect(EngineFix.placement(of: WindowId(2), in: fx) != nil)
        #expect(EngineFix.placement(of: WindowId(3), in: fx) != nil)
    }

    @Test func axFailedDoesNotWedgeTheTransition() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and the display shows it
        let awaiting = Array(s.motion.transition?.awaitingLanding ?? [])
        #expect(awaiting.count == 2)
        (s, _) = Engine.reduce(s, .axFailed(awaiting[0]))        // one real never makes it…
        (s, _) = Engine.reduce(s, .axLanded(awaiting[1]))        // …the other lands
        // The failure resolved its landing (no forever-wait on a stuck window), so settling closes it —
        // without the hold-timeout backstop, which we never fire here.
        let (done, _) = EngineFix.drive(s)
        #expect(done.motion.isTransitioning == false)
    }

    @Test func midTransitionStateRoundTripsThroughCodable() throws {
        // A live session (cover raised, mid-animation) must serialize — replay and `emira debug`.
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and the display shows it
        (s, _) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(s.motion.isTransitioning)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(State.self, from: data)
        #expect(back == s)
    }

}
