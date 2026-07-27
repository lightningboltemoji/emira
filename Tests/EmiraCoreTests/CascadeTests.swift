import Foundation
import Testing
@testable import EmiraCore

// The quit cascade (`Cascade.swift`) — the layout that isn't the strip. Two halves, tested apart
// because they fail differently: the arithmetic (a staggered, bottom-right-aligned stack that has to
// stay total for any count on any screen), and the *ordering* policy that decides which window ends
// up on top of the pile.

@Suite struct CascadeTests {

    /// An 1800×1130 working area — the ProMotion display every in-product measurement in
    /// `PRINCIPLES.md` §10 was taken on, minus its menu bar.
    static let working = Rect(x: 0, y: 39, width: 1800, height: 1130)

    // MARK: - The region

    @Test func theStackOccupiesTheCentreThreeQuarters() {
        let region = Cascade.region(in: Self.working)

        #expect(region.width == 1350)                        // ¾ of 1800
        #expect(region.height == 847.5)                      // ¾ of 1130
        // Centred: the margin left over is the same on both sides of each axis.
        #expect(region.minX - Self.working.minX == Self.working.maxX - region.maxX)
        #expect(region.minY - Self.working.minY == Self.working.maxY - region.maxY)
    }

    // MARK: - The stagger

    @Test func everyWindowIsThirtyPointsDownAndRightOfTheLast() {
        let frames = Cascade.frames(count: 5, in: Self.working)
        #expect(frames.count == 5)

        for (earlier, later) in zip(frames, frames.dropFirst()) {
            #expect(later.minX - earlier.minX == 30)
            #expect(later.minY - earlier.minY == 30)
        }
    }

    @Test func everyBottomRightCornerLandsOnTheSamePoint() {
        let region = Cascade.region(in: Self.working)
        let frames = Cascade.frames(count: 8, in: Self.working)

        // The resize is what makes the stagger legible: each window is 30 pt narrower and shorter
        // than the one behind it, so the corners coincide and window *i+1* sits strictly inside *i*.
        for frame in frames {
            #expect(frame.maxX == region.maxX)
            #expect(frame.maxY == region.maxY)
        }
        #expect(frames[0].size == region.size)
        #expect(frames[7].width == region.width - 7 * 30)
        #expect(frames[7].height == region.height - 7 * 30)
    }

    @Test func theFirstWindowFillsTheRegionAndTheStackShrinksInwards() {
        let region = Cascade.region(in: Self.working)
        let frames = Cascade.frames(count: 4, in: Self.working)

        #expect(frames[0] == region)
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            #expect(later.width < earlier.width)
            #expect(later.height < earlier.height)
            // Strictly inside, which is exactly why z-order is a decision (`cascadeEffects`).
            #expect(later.minX > earlier.minX && later.maxX <= earlier.maxX)
        }
    }

    // MARK: - Totality (the cases a real desktop supplies and a demo never does)

    @Test func anEmptyDesktopCascadesNothing() {
        #expect(Cascade.frames(count: 0, in: Self.working).isEmpty)
    }

    @Test func aLoneWindowIsTheRegionItself() {
        // Nothing to be staggered against — shrinking it for a stack of one would be the arithmetic
        // showing through rather than a decision.
        #expect(Cascade.frames(count: 1, in: Self.working) == [Cascade.region(in: Self.working)])
    }

    @Test func aDeepStackCompressesTheStepInsteadOfCollapsing() {
        // 40 windows × 30 pt is 1170 pt of travel on an 847 pt-tall region: the naive stagger would
        // drive the last windows through zero height and out the other side.
        let frames = Cascade.frames(count: 40, in: Self.working)
        #expect(frames.count == 40)

        let step = frames[1].minY - frames[0].minY
        #expect(step < 30)                                   // it compressed
        #expect(step > 0)
        // Uniformly — a pile that got tighter unevenly would read as a mistake.
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            #expect(abs((later.minY - earlier.minY) - step) < 1e-9)
        }
        // And the floor held on both axes, which is what the compression is *for*.
        #expect(frames[39].width >= Cascade.minimumSize.width)
        #expect(frames[39].height >= Cascade.minimumSize.height)
    }

    @Test func theOrdinaryDesktopNeverReachesTheCompression() {
        // The floor is a backstop, not a participant: a dozen windows is a busy desktop and it still
        // gets the full 30 pt.
        for count in 2...18 {
            let frames = Cascade.frames(count: count, in: Self.working)
            #expect(frames[1].minY - frames[0].minY == 30, "count \(count)")
        }
    }

    @Test func aScreenTooSmallForACascadeStacksWithoutCollapsing() {
        // Region smaller than the floor ⇒ no travel at all. Every window lands on top of every other,
        // at full size and fully on screen, which is the honest answer rather than a negative size.
        let tiny = Rect(x: 0, y: 0, width: 400, height: 300)
        let frames = Cascade.frames(count: 6, in: tiny)

        #expect(frames.allSatisfy { $0 == Cascade.region(in: tiny) })
        #expect(frames.allSatisfy { !$0.isEmpty })
    }

    @Test func everyWindowStaysInsideTheWorkingArea() {
        for count in [1, 2, 7, 25, 60] {
            for frame in Cascade.frames(count: count, in: Self.working) {
                #expect(frame.minX >= Self.working.minX)
                #expect(frame.minY >= Self.working.minY)
                #expect(frame.maxX <= Self.working.maxX)
                #expect(frame.maxY <= Self.working.maxY)
                #expect(!frame.isEmpty)
            }
        }
    }

    // MARK: - The effects (which window ends up on top)

    @Test func everyManagedWindowIsPlacedExactlyOnce() {
        let state = EngineTests.world(4)
        let effects = state.cascadeEffects()

        let placements = effects.compactMap { effect -> WindowId? in
            if case .setFrame(let id, _) = effect { return id } else { return nil }
        }
        #expect(Set(placements) == Set(state.workspaces.allWindowIds))
        #expect(placements.count == 4)
        // A cascade never parks: the whole point is that nothing is left off screen.
        #expect(!effects.contains { if case .park = $0 { return true } else { return false } })
    }

    @Test func parkedWindowsAreRescuedToo() {
        // One full-width preset, so only the focused column is ever in view and the other three are
        // sitting at their 1 pt nubs — the state this whole slice exists to stop handing to the user.
        let state = EngineTests.world(4, config: EngineTests.fullWidth)
        let region = Cascade.region(in: state.metrics()!.workingArea)

        for effect in state.cascadeEffects() {
            guard case .setFrame(_, let frame) = effect else { continue }
            #expect(frame.width >= Cascade.minimumSize.width)
            #expect(frame.maxX == region.maxX)              // on screen, in the pile
        }
    }

    @Test func theFocusedWindowEndsUpOnTop() {
        var state = EngineTests.world(4)
        let wanted = WindowId(2)
        state.world.setFocus(wanted)

        let effects = state.cascadeEffects()
        let order = effects.compactMap { effect -> WindowId? in
            if case .setFrame(let id, _) = effect { return id } else { return nil }
        }

        // Later means smaller means drawn on top, and with the corners aligned the topmost window is
        // the only one guaranteed to be whole — so it is the one the user was working in.
        #expect(order.last == wanted)
        // Everything else keeps placement order behind it.
        #expect(order == [WindowId(1), WindowId(3), WindowId(4), wanted])
        // …and the last thing that happens is that window's app being brought forward. Focus doesn't
        // actually move: it is already there.
        #expect(effects.last == .focus(wanted))
    }

    @Test func theStackIsRaisedFromTheBackForwards() {
        let state = EngineTests.world(3)
        let effects = state.cascadeEffects()

        let placed = effects.compactMap { effect -> WindowId? in
            if case .setFrame(let id, _) = effect { return id } else { return nil }
        }
        let raised = effects.compactMap { effect -> WindowId? in
            if case .raise(let id) = effect { return id } else { return nil }
        }
        // Same order, so the innermost window is raised last and nothing buries it.
        #expect(raised == placed)
    }

    @Test func aWorldWithNoDisplayOrNoWindowsCascadesNothing() {
        #expect(State().cascadeEffects().isEmpty)            // no monitor yet
        #expect(EngineTests.booted().cascadeEffects().isEmpty)  // a display, no windows
    }
}
