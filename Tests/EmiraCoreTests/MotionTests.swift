import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

/// `Motion` — the animation half of `State`: the viewport-offset scroll animator, the per-window
/// displacement animators, and the ephemeral transition session. Exercised in isolation (no reducer,
/// no macOS), including the unknown-id / wrong-phase no-ops the whole core keeps.
@Suite struct MotionTests {
    static let dt = 1.0 / 120.0

    /// The one display these tests are about, unless they say otherwise.
    static let one = MonitorId(1)

    /// Everything a test here animates. In the daemon this membership comes from `State.contents(of:)`
    /// — `Motion` cannot answer it, its displacements and widths being keyed by ids that outlive both a
    /// workspace and a display.
    static let everything = MonitorContents(windows: Set((1...9).map { WindowId(UInt64($0)) }),
                                            columns: Set((1...9).map { ColumnId(UInt64($0)) }))

    private func advance(_ m: inout Motion, frames: Int) {
        for _ in 0..<frames { m.advance(by: Self.dt, on: [Self.one], holding: Self.everything) }
    }

    // Viewport scroll (the one scalar)

    /// The launch viewport is the *detached* one — there is no display yet to hold a scroll — and the
    /// first display to arrive takes it whole, which is what makes a lid close and its reopening one
    /// continuous scroll rather than a jump home.
    @Test func startsIdleAndSettled() {
        var m = Motion(viewportOffset: 300)
        #expect(m.offset(of: nil).current == 300)
        m.reconcile([Self.one])
        #expect(m.offset(of: Self.one).current == 300)
        #expect(m.isSettled)
        #expect(!m.isTransitioning)
        #expect(m.transition(of: Self.one) == nil)
    }

    @Test func retargetViewportPreservesVelocityMidScroll() {
        var m = Motion(viewportOffset: 0, params: .snappy)
        m.retargetViewport(to: 100, on: Self.one)
        advance(&m, frames: 10)
        let before = m.offset(of: Self.one)
        #expect(before.velocity != 0)             // genuinely in flight

        m.retargetViewport(to: -50, on: Self.one)               // interrupt
        #expect(m.offset(of: Self.one).current == before.current)   // position untouched
        #expect(m.offset(of: Self.one).velocity == before.velocity) // velocity carried
        #expect(m.offset(of: Self.one).target == -50)
    }

    @Test func snapViewportKillsMotion() {
        var m = Motion(viewportOffset: 0, params: .snappy)
        m.retargetViewport(to: 100, on: Self.one)
        advance(&m, frames: 10)
        #expect(!m.isSettled)

        m.snapViewport(to: 250, on: Self.one)
        #expect(m.offset(of: Self.one).current == 250)
        #expect(m.offset(of: Self.one).velocity == 0)
        #expect(m.isSettled)
    }

    // Per-window displacements (the structural edit, in flight)

    static let displacement = Rect(x: -200, y: -40, width: 100, height: -300)

    @Test func advanceMovesTheViewportAndEveryDisplacement() {
        var m = Motion(viewportOffset: 0, params: .snappy)
        m.retargetViewport(to: 100, on: Self.one)
        m.displaceWindow(WindowId(1), by: Self.displacement, params: .snappy, on: Self.one)

        advance(&m, frames: 10)
        #expect(m.offset(of: Self.one).current > 0)                 // strip scrolled
        #expect(m.displacement(of: WindowId(1)).minX > -200)  // and the lag is closing, independently
    }

    /// A displacement's destination is zero on every component — not "the window's new frame", which
    /// stays `Layout`'s. That is what makes dropping a settled animator a no-op rather than a decision.
    @Test func aDisplacementDecaysToZeroOnEveryComponent() {
        var m = Motion()
        m.displaceWindow(WindowId(1), by: Self.displacement, params: .snappy, on: Self.one)
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
        m.displaceWindow(WindowId(1), by: Self.displacement, params: .snappy, on: Self.one)
        #expect(!m.isSettled)                     // viewport idle, but a window is rearranging

        advance(&m, frames: 3000)
        #expect(m.isSettled)
    }

    /// The double press. A second structural edit lands mid-flight and must *add* to the live
    /// displacement rather than replace it, or the layer teleports back to where the first press started.
    /// Velocity is the other half: rebuilding would restart from a dead stop.
    @Test func displacingAgainMidFlightAddsToThePositionAndKeepsTheVelocity() {
        var m = Motion()
        m.displaceWindow(WindowId(1), by: Rect(x: -600, y: 0, width: 0, height: 0), params: .snappy, on: Self.one)
        advance(&m, frames: 6)

        let midX = m.displacement(of: WindowId(1)).minX
        let midVelocity = m.windowAnimator(WindowId(1))?.x.velocity ?? 0
        #expect(midX > -600 && midX < 0)          // genuinely mid-flight
        #expect(midVelocity != 0)

        m.displaceWindow(WindowId(1), by: Rect(x: -600, y: 0, width: 0, height: 0), params: .snappy, on: Self.one)
        #expect(abs(m.displacement(of: WindowId(1)).minX - (midX - 600)) < 1e-9)   // added, not reset
        #expect(m.windowAnimator(WindowId(1))?.x.velocity == midVelocity)          // carried through
    }

    /// `displacement(of:)` is total so the per-frame emission can add it unconditionally.
    @Test func displacementIsZeroForAWindowThatIsNotRearranging() {
        let m = Motion()
        #expect(m.displacement(of: WindowId(42)) == .zero)
    }

    // The retarget generation (what the shell's hold deadline keys on)

    /// It counts decisions, not frames. Every re-aim of every animated quantity bumps it, which is what
    /// lets `Runtime.syncHold` notice a redirect that never touches the viewport; `advance` never does,
    /// or a live transition would re-arm its deadline every tick and could never time out.
    @Test func theRetargetGenerationMovesOnEveryReAimAndNotOnAdvance() {
        var m = Motion()
        let start = m.retargetGeneration(of: Self.one)

        m.retargetViewport(to: 100, on: Self.one)
        m.snapViewport(to: 0, on: Self.one)
        m.animateColumnWidth(ColumnId(1), from: 300, to: 600, on: Self.one)
        m.displaceWindow(WindowId(1), by: Self.displacement, on: Self.one)
        #expect(m.retargetGeneration(of: Self.one) == start &+ 4)

        let afterAiming = m.retargetGeneration(of: Self.one)
        advance(&m, frames: 20)
        #expect(m.retargetGeneration(of: Self.one) == afterAiming)   // frames are not decisions
    }

    /// The cover comes down when the motion *looks* finished, not when the arithmetic is finished. A
    /// wall-clock feel guard: with a unit-agnostic `1e-3` tolerance a 900-point scroll is visually over
    /// at ~350 ms but does not report `isSettled` until ~1.1 s, and every other test here would still
    /// pass — they assert *that* a transition closes, not *when*.
    @Test func aScrollSettlesAssoonAsItLooksFinished() {
        // One column pitch on a laptop display — the everyday scroll distance.
        var m = Motion(viewportOffset: 0, params: .smooth)
        m.retargetViewport(to: 900, on: Self.one)

        let dt = 1.0 / 120
        var elapsed = 0.0
        var lookedFinished: Double?
        while !m.isSettled && elapsed < 5 {
            m.advance(by: dt, on: [Self.one], holding: Self.everything)
            elapsed += dt
            // Within a pixel of the target: from here on, no frame differs from the last one visibly.
            if lookedFinished == nil, abs(m.offset(of: Self.one).current - 900) < 1 { lookedFinished = elapsed }
        }

        #expect(m.isSettled)                                   // it settles at all (not a hang)
        #expect(lookedFinished != nil)
        #expect(elapsed - (lookedFinished ?? 0) < 0.1)          // …within 100 ms of looking settled
    }

    // Column widths (the strip's own geometry)

    @Test func aColumnWidthAnimatesFromTheOldPresetToTheNew() {
        var m = Motion()
        #expect(m.currentColumnWidths.isEmpty)                 // no override ⇒ the layout's presets

        m.animateColumnWidth(ColumnId(1), from: 300, to: 600, params: .snappy, on: Self.one)
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
        m.animateColumnWidth(ColumnId(1), from: 300, to: 600, params: .snappy, on: Self.one)
        advance(&m, frames: 8)
        let cMid = try! #require(m.columnWidth(ColumnId(1))?.current)
        let vMid = try! #require(m.columnWidth(ColumnId(1))?.velocity)
        #expect(vMid > 0)

        // Second press: 600 → 900. `from` is the *new* preset's predecessor and must be ignored.
        m.animateColumnWidth(ColumnId(1), from: 600, to: 900, params: .snappy, on: Self.one)
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
        m.openTransition(scope: [WindowId(1)], on: Self.one)
        m.animateColumnWidth(ColumnId(1), from: 300, to: 600, on: Self.one)
        m.closeTransition(on: Self.one)
        #expect(m.currentColumnWidths.isEmpty)
        #expect(m.columnWidth(ColumnId(1)) == nil)
        #expect(m.isSettled)
    }

    @Test func removeWindowAnimatorIsTotal() {
        var m = Motion()
        m.removeWindowAnimator(WindowId(99))      // never installed → no-op, no crash
        #expect(m.windowAnimator(WindowId(99)) == nil)

        m.displaceWindow(WindowId(1), by: Self.displacement, on: Self.one)
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
        m.animateColumnWidth(ColumnId(1), from: 300, to: 600, on: Self.one)
        #expect(!m.isSettled)                     // the in-flight width holds the gate

        m.removeColumnWidthAnimator(ColumnId(1))
        #expect(m.columnWidth(ColumnId(1)) == nil)
        #expect(m.currentColumnWidths.isEmpty)
        #expect(m.isSettled)                      // …and stops holding it once retired

        m.removeColumnWidthAnimator(ColumnId(1))  // repeat remove → no-op
        m.removeColumnWidthAnimator(ColumnId(99)) // never-installed id → no-op, no crash
    }

    // Transition lifecycle: capture → cover → land → close

    private static let scope = [WindowId(1), WindowId(2), WindowId(3)]

    @Test func openTransitionEntersCapturingScopedToTheWindowSet() {
        var m = Motion()
        m.openTransition(scope: Self.scope, on: Self.one)
        let t = try! #require(m.transition(of: Self.one))
        #expect(m.isTransitioning)
        #expect(t.phase == .capturing)
        #expect(t.pendingCaptures == Set(Self.scope))
        #expect(t.awaitingLanding == Set(Self.scope))
        #expect(t.bindings.isEmpty)               // no layers until the cover is raised
        #expect(!m.isReadyToRaise(on: Self.one))                // captures still outstanding
    }

    @Test func secondOpenIsANoOpOneSessionAtATime() {
        var m = Motion()
        m.openTransition(scope: Self.scope, on: Self.one)
        m.markCaptured(WindowId(1))
        m.openTransition(scope: [WindowId(9)], on: Self.one)    // ignored — a session is already open
        let t = try! #require(m.transition(of: Self.one))
        #expect(t.windows == Self.scope)
        #expect(t.pendingCaptures == Set([WindowId(2), WindowId(3)]))   // progress preserved
    }

    @Test func capturesCompleteGatesTheRaise() {
        var m = Motion()
        m.openTransition(scope: Self.scope, on: Self.one)
        m.markCaptured(WindowId(1))
        m.markCaptured(WindowId(2))
        #expect(!m.isReadyToRaise(on: Self.one))
        m.markCaptured(WindowId(3))
        #expect(m.isReadyToRaise(on: Self.one))                 // every capture in
        m.markCaptured(WindowId(3))               // repeat / unknown is total
        m.markCaptured(WindowId(42))
        #expect(m.isReadyToRaise(on: Self.one))
    }

    @Test func raiseCoverMintsOneOrderedUniqueLayerPerWindow() {
        var m = Motion()
        m.openTransition(scope: Self.scope, on: Self.one)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover(on: Self.one)

        let t = try! #require(m.transition(of: Self.one))
        #expect(t.phase == .raising)              // built and handed over; not yet on the glass
        #expect(!m.isReadyToRaise(on: Self.one))                // already raised
        // Deterministic minting from a fresh Motion: L1, L2, L3 in window z-order.
        #expect(t.bindings.map(\.window) == Self.scope)
        #expect(t.bindings.map(\.layer) == [LayerId(1), LayerId(2), LayerId(3)])
        #expect(m.layerIds(for: WindowId(2)).first == LayerId(2))
        #expect(m.layerIds(for: WindowId(42)).first == nil)   // not scoped
    }

    /// The raise is two steps, and only the second one lets a real window move. Between them the layers
    /// exist — the cover is real, just not composed yet — which is what `hasLayers` separates out.
    @Test func theCoverOwnsTheRealsOnlyOnceItIsOnScreen() {
        var m = Motion()
        m.openTransition(scope: Self.scope, on: Self.one)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover(on: Self.one)

        #expect(!m.isCovered(on: Self.one))                     // committed is not composed
        #expect(m.hasLayers(on: Self.one))                      // …but the layer tree is up and can be extended
        m.confirmCover(on: Self.one)
        #expect(m.isCovered(on: Self.one))
        #expect(m.phase(of: Self.one) == .covered)
    }

    @Test func confirmingIsANoOpOutsideTheRaise() {
        var m = Motion()
        m.confirmCover(on: Self.one)                          // no session at all
        #expect(!m.isTransitioning)

        m.openTransition(scope: Self.scope, on: Self.one)
        m.confirmCover(on: Self.one)                          // still capturing — no cover to confirm
        #expect(m.phase(of: Self.one) == .capturing)

        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover(on: Self.one)
        m.confirmCover(on: Self.one)
        m.confirmCover(on: Self.one)                          // a second report changes nothing
        #expect(m.phase(of: Self.one) == .covered)
    }

    @Test func raiseCoverBeforeAnOpenSessionIsANoOp() {
        var m = Motion()
        m.raiseCover(on: Self.one)                            // no session
        #expect(!m.isTransitioning)
        #expect(m.layerIds(for: WindowId(1)).first == nil)
    }

    // The scope that grows

    @Test func extendingBeforeTheRaiseAddsToTheBatchTheCoverWaitsOn() {
        var m = Motion()
        m.openTransition(scope: Self.scope, on: Self.one)
        for w in Self.scope { m.markCaptured(w) }
        #expect(m.isReadyToRaise(on: Self.one))

        #expect(m.extendTransition(scope: [WindowId(4), WindowId(2)], on: Self.one) == [WindowId(4)])  // 2 already in
        #expect(!m.isReadyToRaise(on: Self.one))                // the newcomer owes a still, so the raise waits
        m.markCaptured(WindowId(4))
        m.raiseCover(on: Self.one)
        // One cover, built in one piece, with the newcomer last in z-order.
        #expect(m.transition(of: Self.one)?.bindings.map(\.window) == Self.scope + [WindowId(4)])
    }

    @Test func extendingAfterTheRaiseGrowsTheCoverWithFreshLayerIds() {
        var m = Motion()
        m.openTransition(scope: Self.scope, on: Self.one)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover(on: Self.one)
        #expect(m.extendCover(on: Self.one).isEmpty)          // nothing unbound — the cover is complete

        _ = m.extendTransition(scope: [WindowId(4)], on: Self.one)
        #expect(!m.isReadyToExtend(on: Self.one))               // …not until its still lands
        m.markCaptured(WindowId(4))
        #expect(m.isReadyToExtend(on: Self.one))

        let added = m.extendCover(on: Self.one)
        #expect(added == [LayerBinding(window: WindowId(4), layer: LayerId(4))])   // minted, not reused
        #expect(!m.isReadyToExtend(on: Self.one))               // idempotent: nothing left unbound
        #expect(m.extendCover(on: Self.one).isEmpty)
        #expect(m.layerIds(for: WindowId(4)).first == LayerId(4))
    }

    /// A still binds as soon as it lands, whatever else is outstanding. A session-wide gate starves under
    /// a stream of extensions — something is always pending, so it never reopens and the cover stops
    /// growing for the rest of the transition. Here w4's still is in while w5's is not, and w4 must not
    /// be made to wait for it.
    @Test func aPendingCaptureDoesNotHoldBackALayerWhoseStillHasLanded() {
        var m = Motion()
        m.openTransition(scope: Self.scope, on: Self.one)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover(on: Self.one)

        _ = m.extendTransition(scope: [WindowId(4)], on: Self.one)
        _ = m.extendTransition(scope: [WindowId(5)], on: Self.one)     // a second interrupt, before the first answers
        #expect(!m.isReadyToExtend(on: Self.one))                      // neither still is in yet

        m.markCaptured(WindowId(4))
        #expect(m.isReadyToExtend(on: Self.one))                       // w4 binds now; w5 is still out
        #expect(m.extendCover(on: Self.one).map(\.window) == [WindowId(4)])
        #expect(m.layerIds(for: WindowId(4)).first != nil)
        #expect(m.layerIds(for: WindowId(5)).first == nil)      // not named, so its one chance is not spent

        m.markCaptured(WindowId(5))
        #expect(m.extendCover(on: Self.one).map(\.window) == [WindowId(5)])
        #expect(m.layerIds(for: WindowId(5)).first != nil)
        #expect(!m.isReadyToExtend(on: Self.one))
    }

    @Test func extendAndExtendCoverAreTotal() {
        var m = Motion()
        #expect(m.extendTransition(scope: [WindowId(1)], on: Self.one).isEmpty)   // no session
        #expect(m.extendCover(on: Self.one).isEmpty)

        m.openTransition(scope: Self.scope, on: Self.one)
        #expect(m.extendTransition(scope: Self.scope, on: Self.one).isEmpty)      // all already in scope
        #expect(m.extendCover(on: Self.one).isEmpty)                            // not covered yet
    }

    // Abandoning a session that never got a cover

    @Test func abortTransitionTearsDownAPreCoverSessionAndSnaps() {
        var m = Motion(viewportOffset: 0, params: .smooth)
        m.openTransition(scope: Self.scope, on: Self.one)
        m.retargetViewport(to: 900, on: Self.one)
        advance(&m, frames: 3)
        #expect(m.offset(of: Self.one).current > 0 && m.offset(of: Self.one).current < 900)

        m.abortTransition(on: Self.one)
        #expect(!m.isTransitioning)
        #expect(m.offset(of: Self.one).current == 900)  // snapped to the destination the spring was aiming at
    }

    /// A raised cover can only be taken down by the cross-fade — dropping the session under it would
    /// leave a full-screen overlay up with nothing driving its layers.
    @Test func abortTransitionRefusesOnceTheCoverIsUp() {
        var m = Motion()
        m.openTransition(scope: Self.scope, on: Self.one)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover(on: Self.one)

        m.abortTransition(on: Self.one)
        #expect(m.phase(of: Self.one) == .raising, "a cover on its way to the glass is still a cover")

        m.confirmCover(on: Self.one)
        m.abortTransition(on: Self.one)
        #expect(m.isCovered(on: Self.one))
    }

    @Test func closeIsGatedOnLandingAndSettle() {
        var m = Motion(viewportOffset: 0, params: .snappy)
        m.openTransition(scope: Self.scope, on: Self.one)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover(on: Self.one)
        m.confirmCover(on: Self.one)
        m.retargetViewport(to: 400, on: Self.one)               // the strip is scrolling under the cover
        advance(&m, frames: 5)

        #expect(!m.isReadyToClose(on: Self.one, holding: Self.everything))                // animating and nothing landed
        for w in Self.scope { m.markLanded(w) }
        #expect(!m.isReadyToClose(on: Self.one, holding: Self.everything))                // landed, but still animating
        m.snapViewport(to: 400, on: Self.one)                   // motion arrives
        #expect(m.isReadyToClose(on: Self.one, holding: Self.everything))                 // covered + landed + settled
    }

    @Test func closeTransitionTearsDownAndSnapsToTruth() {
        var m = Motion(viewportOffset: 0, params: .snappy)
        m.displaceWindow(WindowId(7), by: Self.displacement, on: Self.one)
        m.openTransition(scope: Self.scope, on: Self.one)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover(on: Self.one)
        m.retargetViewport(to: 400, on: Self.one)
        advance(&m, frames: 5)                    // mid-flight when the timeout closes it

        m.closeTransition(on: Self.one)
        #expect(!m.isTransitioning)
        #expect(m.transition(of: Self.one) == nil)
        #expect(m.windowAnimators.isEmpty)        // displacements dropped — resting value is zero
        #expect(m.offset(of: Self.one).current == 400)  // snapped to target = revealed truth
        #expect(m.isSettled)
    }

    @Test func markingWithNoSessionIsTotal() {
        var m = Motion()
        m.markCaptured(WindowId(1))               // all no-op with no open session
        m.markLanded(WindowId(1))
        m.closeTransition(on: Self.one)
        #expect(!m.isTransitioning)
        #expect(!m.isReadyToRaise(on: Self.one))
        #expect(!m.isReadyToClose(on: Self.one, holding: Self.everything))
    }

    @Test func layerIdsStayUniqueAcrossSuccessiveTransitions() {
        var m = Motion()
        m.openTransition(scope: [WindowId(1), WindowId(2)], on: Self.one)
        m.markCaptured(WindowId(1)); m.markCaptured(WindowId(2))
        m.raiseCover(on: Self.one)                            // mints L1, L2
        m.closeTransition(on: Self.one)

        m.openTransition(scope: [WindowId(1)], on: Self.one)
        m.markCaptured(WindowId(1))
        m.raiseCover(on: Self.one)                            // watermark continues → L3, not a reused L1
        #expect(m.layerIds(for: WindowId(1)).first == LayerId(3))
    }

    // Serialization (State dumps / replay)

    @Test func populatedMotionRoundTripsThroughCodable() throws {
        var m = Motion(viewportOffset: 0, params: .snappy)
        m.retargetViewport(to: 250, on: Self.one)
        m.displaceWindow(WindowId(7), by: Self.displacement, params: .snappy, on: Self.one)
        advance(&m, frames: 6)                    // in-flight: non-zero velocities to serialize
        m.openTransition(scope: Self.scope, on: Self.one)
        for w in Self.scope { m.markCaptured(w) }
        m.raiseCover(on: Self.one)
        m.markLanded(WindowId(1))

        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(Motion.self, from: data)
        #expect(decoded == m)
    }
}
