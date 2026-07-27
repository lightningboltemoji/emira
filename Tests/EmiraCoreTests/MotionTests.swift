import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

/// `Motion` — the animation half of `State`: the viewport-offset scroll animator, the per-window
/// displacement animators, and the ephemeral transition session. Exercised in isolation (no reducer,
/// no macOS), including the unknown-id / wrong-phase no-ops the whole core keeps.
@Suite struct MotionTests {
    static let dt = 1.0 / 120.0

    private func advance(_ m: inout Motion, frames: Int) {
        for _ in 0..<frames { m.advance(by: Self.dt) }
    }

    // MARK: - Viewport scroll (the one scalar)

    @Test func startsIdleAndSettled() {
        let m = Motion(viewportOffset: 300)
        #expect(m.viewportOffset.current == 300)
        #expect(m.isSettled)
        #expect(!m.isTransitioning)
        #expect(m.transition == nil)
    }

    @Test func retargetViewportPreservesVelocityMidScroll() {
        var m = Motion(viewportOffset: 0, params: .snappy)
        m.retargetViewport(to: 100)
        advance(&m, frames: 10)
        let before = m.viewportOffset
        #expect(before.velocity != 0)             // genuinely in flight

        m.retargetViewport(to: -50)               // interrupt
        #expect(m.viewportOffset.current == before.current)   // position untouched
        #expect(m.viewportOffset.velocity == before.velocity) // velocity carried
        #expect(m.viewportOffset.target == -50)
    }

    @Test func snapViewportKillsMotion() {
        var m = Motion(viewportOffset: 0, params: .snappy)
        m.retargetViewport(to: 100)
        advance(&m, frames: 10)
        #expect(!m.isSettled)

        m.snapViewport(to: 250)
        #expect(m.viewportOffset.current == 250)
        #expect(m.viewportOffset.velocity == 0)
        #expect(m.isSettled)
    }

    // MARK: - Per-window displacements (the structural edit, in flight)

    static let displacement = Rect(x: -200, y: -40, width: 100, height: -300)

    @Test func advanceMovesTheViewportAndEveryDisplacement() {
        var m = Motion(viewportOffset: 0, params: .snappy)
        m.retargetViewport(to: 100)
        m.displaceWindow(WindowId(1), by: Self.displacement, params: .snappy)

        advance(&m, frames: 10)
        #expect(m.viewportOffset.current > 0)                 // strip scrolled
        #expect(m.displacement(of: WindowId(1)).minX > -200)  // and the lag is closing, independently
    }

    /// A displacement's destination is zero on every component — not "the window's new frame", which
    /// stays `Layout`'s. That is what makes dropping a settled animator a no-op rather than a decision.
    @Test func aDisplacementDecaysToZeroOnEveryComponent() {
        var m = Motion()
        m.displaceWindow(WindowId(1), by: Self.displacement, params: .snappy)
        #expect(m.displacement(of: WindowId(1)) == Self.displacement)   // t = 0 is the full lag

        advance(&m, frames: 3000)
        let settled = m.displacement(of: WindowId(1))
        #expect(abs(settled.minX) < 0.01)
        #expect(abs(settled.minY) < 0.01)
        #expect(abs(settled.width) < 0.01)
        #expect(abs(settled.height) < 0.01)
    }

    @Test func isSettledConsidersDisplacements() {
        var m = Motion()
        m.displaceWindow(WindowId(1), by: Self.displacement, params: .snappy)
        #expect(!m.isSettled)                     // viewport idle, but a window is rearranging

        advance(&m, frames: 3000)
        #expect(m.isSettled)
    }

    /// The double press. A second structural edit lands mid-flight and must *add* to the live
    /// displacement rather than replace it, or the layer teleports back to where the first press started.
    /// Velocity is the other half: rebuilding would restart from a dead stop.
    @Test func displacingAgainMidFlightAddsToThePositionAndKeepsTheVelocity() {
        var m = Motion()
        m.displaceWindow(WindowId(1), by: Rect(x: -600, y: 0, width: 0, height: 0), params: .snappy)
        advance(&m, frames: 6)

        let midX = m.displacement(of: WindowId(1)).minX
        let midVelocity = m.windowAnimator(WindowId(1))?.x.velocity ?? 0
        #expect(midX > -600 && midX < 0)          // genuinely mid-flight
        #expect(midVelocity != 0)

        m.displaceWindow(WindowId(1), by: Rect(x: -600, y: 0, width: 0, height: 0), params: .snappy)
        #expect(abs(m.displacement(of: WindowId(1)).minX - (midX - 600)) < 1e-9)   // added, not reset
        #expect(m.windowAnimator(WindowId(1))?.x.velocity == midVelocity)          // carried through
    }

    /// `displacement(of:)` is total so the per-frame emission can add it unconditionally.
    @Test func displacementIsZeroForAWindowThatIsNotRearranging() {
        let m = Motion()
        #expect(m.displacement(of: WindowId(42)) == .zero)
    }

    // MARK: - The retarget generation (what the shell's hold deadline keys on)

    /// It counts decisions, not frames. Every re-aim of every animated quantity bumps it, which is what
    /// lets `Runtime.syncHold` notice a redirect that never touches the viewport; `advance` never does,
    /// or a live transition would re-arm its deadline every tick and could never time out.
    @Test func theRetargetGenerationMovesOnEveryReAimAndNotOnAdvance() {
        var m = Motion()
        let start = m.retargetGeneration

        m.retargetViewport(to: 100)
        m.snapViewport(to: 0)
        m.animateColumnWidth(ColumnId(1), from: 300, to: 600)
        m.displaceWindow(WindowId(1), by: Self.displacement)
        #expect(m.retargetGeneration == start &+ 4)

        let afterAiming = m.retargetGeneration
        advance(&m, frames: 20)
        #expect(m.retargetGeneration == afterAiming)   // frames are not decisions
    }

    /// The cover comes down when the motion *looks* finished, not when the arithmetic is finished. A
    /// wall-clock feel guard: with a unit-agnostic `1e-3` tolerance a 900-point scroll is visually over
    /// at ~350 ms but does not report `isSettled` until ~1.1 s, and every other test here would still
    /// pass — they assert *that* a transition closes, not *when*.
    @Test func aScrollSettlesAssoonAsItLooksFinished() {
        // One column pitch on a laptop display — the everyday scroll distance.
        var m = Motion(viewportOffset: 0, params: .smooth)
        m.retargetViewport(to: 900)

        let dt = 1.0 / 120
        var elapsed = 0.0
        var lookedFinished: Double?
        while !m.isSettled && elapsed < 5 {
            m.advance(by: dt)
            elapsed += dt
            // Within a pixel of the target: from here on, no frame differs from the last one visibly.
            if lookedFinished == nil, abs(m.viewportOffset.current - 900) < 1 { lookedFinished = elapsed }
        }

        #expect(m.isSettled)                                   // it settles at all (not a hang)
        #expect(lookedFinished != nil)
        #expect(elapsed - (lookedFinished ?? 0) < 0.1)          // …within 100 ms of looking settled
    }

    // MARK: - Column widths (the strip's own geometry)

    @Test func aColumnWidthAnimatesFromTheOldPresetToTheNew() {
        var m = Motion()
        #expect(m.currentColumnWidths.isEmpty)                 // no override ⇒ the layout's presets

        m.animateColumnWidth(ColumnId(1), from: 300, to: 600, params: .snappy)
        #expect(m.currentColumnWidths[ColumnId(1)] == 300)     // starts at the width it is leaving
        #expect(!m.isSettled)                                  // …and holds the cover up while it moves

        advance(&m, frames: 10)
        let mid = try! #require(m.currentColumnWidths[ColumnId(1)])
        #expect(mid > 300 && mid < 600)

        advance(&m, frames: 3000)
        #expect(m.isSettled)
        #expect(abs((m.currentColumnWidths[ColumnId(1)] ?? 0) - 600) < Motion.settleEpsilon)
    }

    /// The double-press. Cycling a width is a keybind, so the second press lands mid-flight — and it
    /// must re-aim the animator rather than rebuild it, or the column snaps back to the width the first
    /// press started from before setting off again. Same property the viewport interrupt has.
    @Test func cyclingAgainMidFlightRetargetsInsteadOfRestarting() {
        var m = Motion()
        m.animateColumnWidth(ColumnId(1), from: 300, to: 600, params: .snappy)
        advance(&m, frames: 8)
        let cMid = try! #require(m.columnWidth(ColumnId(1))?.current)
        let vMid = try! #require(m.columnWidth(ColumnId(1))?.velocity)
        #expect(vMid > 0)

        // Second press: 600 → 900. `from` is the *new* preset's predecessor and must be ignored.
        m.animateColumnWidth(ColumnId(1), from: 600, to: 900, params: .snappy)
        #expect(m.columnWidth(ColumnId(1))?.current == cMid)   // position untouched
        #expect(m.columnWidth(ColumnId(1))?.velocity == vMid)  // velocity carried
        #expect(m.columnWidth(ColumnId(1))?.target == 900)

        advance(&m, frames: 3000)
        #expect(abs((m.currentColumnWidths[ColumnId(1)] ?? 0) - 900) < Motion.settleEpsilon)
    }

    /// Closing drops the overrides rather than snapping them: with none left the presentation plane
    /// resolves widths from the column's stored preset, which is where the animator was heading anyway.
    /// A kept animator would be a second authority on a number `Layout` owns.
    @Test func closingATransitionDropsTheWidthOverrides() {
        var m = Motion()
        m.openTransition(scope: [WindowId(1)])
        m.animateColumnWidth(ColumnId(1), from: 300, to: 600)
        m.closeTransition()
        #expect(m.currentColumnWidths.isEmpty)
        #expect(m.columnWidth(ColumnId(1)) == nil)
        #expect(m.isSettled)
    }

    @Test func removeWindowAnimatorIsTotal() {
        var m = Motion()
        m.removeWindowAnimator(WindowId(99))      // never installed → no-op, no crash
        #expect(m.windowAnimator(WindowId(99)) == nil)

        m.displaceWindow(WindowId(1), by: Self.displacement)
        m.removeWindowAnimator(WindowId(1))
        #expect(m.windowAnimator(WindowId(1)) == nil)
        m.removeWindowAnimator(WindowId(1))       // repeat remove → no-op
    }

    /// A *consume* can merge a column away mid-resize, leaving an animator keyed on an id nothing will
    /// mention again. The geometry is never at risk (`Layout.strip` ignores an override for a column it
    /// doesn't have), but `isSettled` gates the transition's close — so the subject is the entry's
    /// absence and the gate it stops holding.
    @Test func removingAColumnWidthAnimatorIsTotalAndUngatesTheSettle() {
        var m = Motion()
        m.animateColumnWidth(ColumnId(1), from: 300, to: 600)
        #expect(!m.isSettled)                     // the in-flight width holds the gate

        m.removeColumnWidthAnimator(ColumnId(1))
        #expect(m.columnWidth(ColumnId(1)) == nil)
        #expect(m.currentColumnWidths.isEmpty)
        #expect(m.isSettled)                      // …and stops holding it once retired

        m.removeColumnWidthAnimator(ColumnId(1))  // repeat remove → no-op
        m.removeColumnWidthAnimator(ColumnId(99)) // never-installed id → no-op, no crash
    }

    // MARK: - Transition lifecycle: capture → cover → land → close

    private static let scope = [WindowId(1), WindowId(2), WindowId(3)]

    @Test func openTransitionEntersCapturingScopedToTheWindowSet() {
        var m = Motion()
        m.openTransition(scope: Self.scope)
        let t = try! #require(m.transition)
        #expect(m.isTransitioning)
        #expect(t.phase == .capturing)
        #expect(t.pendingCaptures == Set(Self.scope))
        #expect(t.awaitingLanding == Set(Self.scope))
        #expect(t.bindings.isEmpty)               // no layers until the cover is raised
        #expect(!m.isReadyToRaise)                // captures still outstanding
    }

    @Test func secondOpenIsANoOpOneSessionAtATime() {
        var m = Motion()
        m.openTransition(scope: Self.scope)
        m.markCaptured(WindowId(1))
        m.openTransition(scope: [WindowId(9)])    // ignored — a session is already open
        let t = try! #require(m.transition)
        #expect(t.windows == Self.scope)
        #expect(t.pendingCaptures == Set([WindowId(2), WindowId(3)]))   // progress preserved
    }

    @Test func capturesCompleteGatesTheRaise() {
        var m = Motion()
        m.openTransition(scope: Self.scope)
        m.markCaptured(WindowId(1))
        m.markCaptured(WindowId(2))
        #expect(!m.isReadyToRaise)
        m.markCaptured(WindowId(3))
        #expect(m.isReadyToRaise)                 // every capture in
        m.markCaptured(WindowId(3))               // repeat / unknown is total
        m.markCaptured(WindowId(42))
        #expect(m.isReadyToRaise)
    }

    @Test func raiseCoverMintsOneOrderedUniqueLayerPerWindow() {
        var m = Motion()
        m.openTransition(scope: Self.scope)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover()

        let t = try! #require(m.transition)
        #expect(t.phase == .covered)
        #expect(!m.isReadyToRaise)                // already covered
        // Deterministic minting from a fresh Motion: L1, L2, L3 in window z-order.
        #expect(t.bindings.map(\.window) == Self.scope)
        #expect(t.bindings.map(\.layer) == [LayerId(1), LayerId(2), LayerId(3)])
        #expect(m.layerId(for: WindowId(2)) == LayerId(2))
        #expect(m.layerId(for: WindowId(42)) == nil)   // not scoped
    }

    @Test func raiseCoverBeforeAnOpenSessionIsANoOp() {
        var m = Motion()
        m.raiseCover()                            // no session
        #expect(!m.isTransitioning)
        #expect(m.layerId(for: WindowId(1)) == nil)
    }

    // MARK: - The scope that grows

    @Test func extendingBeforeTheRaiseAddsToTheBatchTheCoverWaitsOn() {
        var m = Motion()
        m.openTransition(scope: Self.scope)
        for w in Self.scope { m.markCaptured(w) }
        #expect(m.isReadyToRaise)

        #expect(m.extendTransition(scope: [WindowId(4), WindowId(2)]) == [WindowId(4)])  // 2 already in
        #expect(!m.isReadyToRaise)                // the newcomer owes a still, so the raise waits
        m.markCaptured(WindowId(4))
        m.raiseCover()
        // One cover, built in one piece, with the newcomer last in z-order.
        #expect(m.transition?.bindings.map(\.window) == Self.scope + [WindowId(4)])
    }

    @Test func extendingAfterTheRaiseGrowsTheCoverWithFreshLayerIds() {
        var m = Motion()
        m.openTransition(scope: Self.scope)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover()
        #expect(m.extendCover().isEmpty)          // nothing unbound — the cover is complete

        _ = m.extendTransition(scope: [WindowId(4)])
        #expect(!m.isReadyToExtend)               // …not until its still lands
        m.markCaptured(WindowId(4))
        #expect(m.isReadyToExtend)

        let added = m.extendCover()
        #expect(added == [LayerBinding(window: WindowId(4), layer: LayerId(4))])   // minted, not reused
        #expect(!m.isReadyToExtend)               // idempotent: nothing left unbound
        #expect(m.extendCover().isEmpty)
        #expect(m.layerId(for: WindowId(4)) == LayerId(4))
    }

    /// A still binds as soon as it lands, whatever else is outstanding. A session-wide gate starves under
    /// a stream of extensions — something is always pending, so it never reopens and the cover stops
    /// growing for the rest of the transition. Here w4's still is in while w5's is not, and w4 must not
    /// be made to wait for it.
    @Test func aPendingCaptureDoesNotHoldBackALayerWhoseStillHasLanded() {
        var m = Motion()
        m.openTransition(scope: Self.scope)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover()

        _ = m.extendTransition(scope: [WindowId(4)])
        _ = m.extendTransition(scope: [WindowId(5)])     // a second interrupt, before the first answers
        #expect(!m.isReadyToExtend)                      // neither still is in yet

        m.markCaptured(WindowId(4))
        #expect(m.isReadyToExtend)                       // w4 binds now; w5 is still out
        #expect(m.extendCover().map(\.window) == [WindowId(4)])
        #expect(m.layerId(for: WindowId(4)) != nil)
        #expect(m.layerId(for: WindowId(5)) == nil)      // not named, so its one chance is not spent

        m.markCaptured(WindowId(5))
        #expect(m.extendCover().map(\.window) == [WindowId(5)])
        #expect(m.layerId(for: WindowId(5)) != nil)
        #expect(!m.isReadyToExtend)
    }

    @Test func extendAndExtendCoverAreTotal() {
        var m = Motion()
        #expect(m.extendTransition(scope: [WindowId(1)]).isEmpty)   // no session
        #expect(m.extendCover().isEmpty)

        m.openTransition(scope: Self.scope)
        #expect(m.extendTransition(scope: Self.scope).isEmpty)      // all already in scope
        #expect(m.extendCover().isEmpty)                            // not covered yet
    }

    // MARK: - Abandoning a session that never got a cover

    @Test func abortTransitionTearsDownAPreCoverSessionAndSnaps() {
        var m = Motion(viewportOffset: 0, params: .smooth)
        m.openTransition(scope: Self.scope)
        m.retargetViewport(to: 900)
        advance(&m, frames: 3)
        #expect(m.viewportOffset.current > 0 && m.viewportOffset.current < 900)

        m.abortTransition()
        #expect(!m.isTransitioning)
        #expect(m.viewportOffset.current == 900)  // snapped to the destination the spring was aiming at
    }

    /// A raised cover can only be taken down by the cross-fade — dropping the session under it would
    /// leave a full-screen overlay up with nothing driving its layers.
    @Test func abortTransitionRefusesOnceTheCoverIsUp() {
        var m = Motion()
        m.openTransition(scope: Self.scope)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover()

        m.abortTransition()
        #expect(m.isCovered)
    }

    @Test func closeIsGatedOnLandingAndSettle() {
        var m = Motion(viewportOffset: 0, params: .snappy)
        m.openTransition(scope: Self.scope)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover()
        m.retargetViewport(to: 400)               // the strip is scrolling under the cover
        advance(&m, frames: 5)

        #expect(!m.isReadyToClose)                // animating and nothing landed
        for w in Self.scope { m.markLanded(w) }
        #expect(!m.isReadyToClose)                // landed, but still animating
        m.snapViewport(to: 400)                   // motion arrives
        #expect(m.isReadyToClose)                 // covered + landed + settled
    }

    @Test func closeTransitionTearsDownAndSnapsToTruth() {
        var m = Motion(viewportOffset: 0, params: .snappy)
        m.displaceWindow(WindowId(7), by: Self.displacement)
        m.openTransition(scope: Self.scope)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover()
        m.retargetViewport(to: 400)
        advance(&m, frames: 5)                    // mid-flight when the timeout closes it

        m.closeTransition()
        #expect(!m.isTransitioning)
        #expect(m.transition == nil)
        #expect(m.windowAnimators.isEmpty)        // displacements dropped — resting value is zero
        #expect(m.viewportOffset.current == 400)  // snapped to target = revealed truth
        #expect(m.isSettled)
    }

    @Test func timeoutFlagRecordsWhyTheSessionClosed() {
        var m = Motion()
        m.openTransition(scope: Self.scope)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover()
        m.markLanded(WindowId(1))                 // only one of three lands
        m.markTimedOut()

        let t = try! #require(m.transition)
        #expect(t.didTimeout)
        #expect(t.awaitingLanding == Set([WindowId(2), WindowId(3)]))   // reducer reconciles these
    }

    @Test func markingWithNoSessionIsTotal() {
        var m = Motion()
        m.markCaptured(WindowId(1))               // all no-op with no open session
        m.markLanded(WindowId(1))
        m.markTimedOut()
        m.closeTransition()
        #expect(!m.isTransitioning)
        #expect(!m.isReadyToRaise)
        #expect(!m.isReadyToClose)
    }

    @Test func layerIdsStayUniqueAcrossSuccessiveTransitions() {
        var m = Motion()
        m.openTransition(scope: [WindowId(1), WindowId(2)])
        m.markCaptured(WindowId(1)); m.markCaptured(WindowId(2))
        m.raiseCover()                            // mints L1, L2
        m.closeTransition()

        m.openTransition(scope: [WindowId(1)])
        m.markCaptured(WindowId(1))
        m.raiseCover()                            // watermark continues → L3, not a reused L1
        #expect(m.layerId(for: WindowId(1)) == LayerId(3))
    }

    // MARK: - Serialization (State dumps / replay)

    @Test func populatedMotionRoundTripsThroughCodable() throws {
        var m = Motion(viewportOffset: 0, params: .snappy)
        m.retargetViewport(to: 250)
        m.displaceWindow(WindowId(7), by: Self.displacement, params: .snappy)
        advance(&m, frames: 6)                    // in-flight: non-zero velocities to serialize
        m.openTransition(scope: Self.scope)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover()
        m.markLanded(WindowId(1))

        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(Motion.self, from: data)
        #expect(decoded == m)
    }
}
