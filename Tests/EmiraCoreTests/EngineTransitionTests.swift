import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// The animated transition session — the cover's lifecycle, and the guarantee that it
// never shows a hole no matter how fast commands arrive.

@Suite struct EngineTransitionTests {

    /// ⅓ columns with the gaps a real config carries. The gap is load-bearing: minimal-reveal scrolling
    /// leaves the next column exactly one `columnGap` past the destination already being aimed at, so it
    /// enters the viewport almost immediately after a retarget rather than comfortably later.
    static let spamConfig = Config(columnGap: 8, windowGap: 8)

    /// Settle a ten-column strip at one end, then hammer `command` and report the widest hole the
    /// cover ever showed.
    private static func worstHoleWhileSpamming(_ command: Command, settlingWith settle: Command,
                                               presses: Int, gapFrames: Int,
                                               captureLatency: Int) -> Double {
        var w = EngineFix.LatentWorld(EngineFix.booted(config: spamConfig), captureLatency: captureLatency)
        for i in 1...10 { w.send(.windowCreated(EngineFix.snapshot(UInt64(i)))) }
        for _ in 0..<12 {                                   // run to one end, unhurried
            w.send(.command(settle))
            var guardCount = 0
            while w.state.motion.isTransitioning && guardCount < 5000 { w.step(); guardCount += 1 }
        }

        var worst = 0.0
        for _ in 0..<presses {
            w.send(.command(command))
            worst = max(worst, w.hole())
            for _ in 0..<gapFrames { w.step(); worst = max(worst, w.hole()) }
        }
        var guardCount = 0
        while w.state.motion.isTransitioning && guardCount < 5000 {
            w.step(); worst = max(worst, w.hole()); guardCount += 1
        }
        return worst
    }

    /// Every command that can open a transition, paired with the one that settles the strip at the
    /// opposite end first so the spam has runway to travel.
    static let spammableCommands: [(Command, Command)] = [
        (.focus(.left), .focus(.right)),
        (.focus(.right), .focus(.left)),
        (.moveWindow(.left), .focus(.right)),
        (.moveWindow(.right), .focus(.left)),
        (.cycleWidth, .focus(.right)),
        (.centerColumn, .focus(.right)),
    ]

    @Test func transitionLifecycleRaisesCoverTeleportsAndCrossFades() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))       // open the scroll w3 → w2 (target 1000)
        let scope = s.transition?.windows ?? []
        #expect(Set(scope) == Set([WindowId(1), WindowId(2), WindowId(3)]))  // swept {w2,w3} + w1's shoulder
        #expect(s.motion.isCovered(on: s.monitors.focused) == false)                     // still capturing

        // Every capture in → raise the cover. Nothing real moves yet: the cover has been committed, not
        // composed, and a window that answered an AX set inside that gap would move where it shows.
        var fx: [Effect] = []
        for w in scope { let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; fx += f }
        #expect(s.motion.phase(of: s.monitors.focused) == .raising)
        #expect(EngineFix.hasEffect(fx) { if case .beginTransition = $0 { return true }; return false })
        #expect(!EngineFix.hasEffect(fx) { if case .setFrame = $0 { return true }; return false })
        #expect(!EngineFix.hasEffect(fx) { if case .park = $0 { return true }; return false })

        // The display shows it → teleport the reals to their end frames (offset 1000): w2 comes into
        // view (setFrame), w3 scrolls off (park).
        let teleports: [Effect]
        (s, teleports) = Engine.reduce(s, .coverOnScreen(MonitorId(1)))
        fx += teleports
        #expect(s.motion.isCovered(on: s.monitors.focused))
        #expect(EngineFix.hasEffect(teleports) { if case .setFrame(WindowId(2), _) = $0 { return true }; return false })
        #expect(EngineFix.hasEffect(teleports) { if case .park(WindowId(3), _) = $0 { return true }; return false })
        #expect(s.transition?.awaitingLanding == Set([WindowId(2), WindowId(3)]))

        // A covered tick blits one layer per scoped window but does not close (reals unlanded).
        let (t, tfx) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(EngineFix.hasEffect(tfx) { if case .setLayerFrame = $0 { return true }; return false })
        #expect(!tfx.contains(.endTransition(MonitorId(1))))
        s = t

        // Reals land, animators settle → endTransition + cover down, resting at the target offset.
        let (done, dfx) = EngineFix.drive(s)
        #expect(done.motion.isTransitioning == false)
        #expect(dfx.contains(.endTransition(MonitorId(1))))
        #expect(EngineFix.approxScalar(done.viewport.offset.current, 1000))
    }

    /// The degradation path for a machine with no Screen Recording grant (`transition = off`):
    /// with no pixels to cover with, the scroll becomes a plain snap-place. What must survive is the
    /// *placement* — the window ends up exactly where the smooth path would have put it.
    @Test func withTransitionOffAScrollSnapsAndCapturesNothing() {
        var config = EngineFix.fullWidth
        config.transitionMode = .off
        var (s, _) = EngineFix.run(EngineFix.booted(config: config), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        let (snapped, fx) = Engine.reduce(s, .command(.focus(.left)))
        s = snapped

        #expect(!s.motion.isTransitioning)                       // no session was ever opened
        #expect(!EngineFix.hasEffect(fx) { if case .capture = $0 { return true }; return false })
        #expect(!EngineFix.hasEffect(fx) { if case .beginTransition = $0 { return true }; return false })
        // Placed, focused, and resting at the offset the animated path would have converged on.
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(EngineFix.approxScalar(s.viewport.offset.current, 1000))
        #expect(EngineFix.placement(of: WindowId(2), in: fx) != nil)
    }

    /// The gate is on *motion*, not on focus: a focus change that doesn't scroll took the snap path
    /// already, and must be unaffected by the flag either way.
    @Test func withTransitionOffAnInViewFocusIsUnchanged() {
        var config = EngineFix.halfWidth
        config.transitionMode = .off
        var (s, _) = EngineFix.run(EngineFix.booted(config: config), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        let (next, fx) = Engine.reduce(s, .command(.focus(.left)))
        s = next

        #expect(s.world.focusedWindow == WindowId(1))
        #expect(!s.motion.isTransitioning)
        #expect(EngineFix.approxScalar(s.viewport.offset.current, 0))
        #expect(fx.contains(.focus(WindowId(1))))
    }

    @Test func interruptRetargetsInFlightScrollWithoutOpeningASecondSession() {
        // Settle focused on w2 at offset 1000 first (full-width, three windows).
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        (s, _) = EngineFix.drive(s)
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(s.motion.isTransitioning == false)
        #expect(EngineFix.approxScalar(s.viewport.offset.current, 1000))

        // Scroll right toward w3 (target 2000); raise the cover, tick a few frames so it's mid-flight.
        (s, _) = Engine.reduce(s, .command(.focus(.right)))
        #expect(s.viewport.offset.target == 2000)
        for w in s.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen(MonitorId(1)))               // …and the display shows it
        #expect(s.motion.isCovered(on: s.monitors.focused))
        for _ in 0..<6 { (s, _) = Engine.reduce(s, .tick(dt: 1.0 / 120)) }
        let vMid = s.viewport.offset.velocity
        let cMid = s.viewport.offset.current
        #expect(vMid != 0)
        #expect(cMid > 1000 && cMid < 2000)

        // INTERRUPT — focus back left to w2. A pure retarget: same session, velocity + position
        // untouched (that carry-through is what makes the reversal feel alive), reals re-teleported.
        let (i, ifx) = Engine.reduce(s, .command(.focus(.left)))
        #expect(i.world.focusedWindow == WindowId(2))
        #expect(ifx.contains(.focus(WindowId(2))))
        #expect(i.motion.isTransitioning)                        // still exactly one session
        #expect(i.motion.isCovered(on: i.monitors.focused))                              // under the same, still-raised cover
        #expect(i.viewport.offset.target == 1000)          // re-aimed at w2
        #expect(i.viewport.offset.velocity == vMid)        // velocity carried through the interrupt
        #expect(i.viewport.offset.current == cMid)         // a retarget never touches position
        #expect(EngineFix.capturedIds(in: ifx).isEmpty)               // scope reused — no fresh captures
        #expect(EngineFix.hasEffect(ifx) { if case .setFrame(WindowId(2), _) = $0 { return true }; return false })
        #expect(i.transition?.awaitingLanding == Set([WindowId(2), WindowId(3)]))  // landings re-armed

        // Land + settle → the interrupted scroll comes to rest at w2 / offset 1000.
        let (done, _) = EngineFix.drive(i)
        #expect(done.motion.isTransitioning == false)
        #expect(done.world.focusedWindow == WindowId(2))
        #expect(EngineFix.approxScalar(done.viewport.offset.current, 1000))
    }

    /// The invariant the whole scoping story exists to hold: while the cover is up, every window the
    /// layers would draw inside the viewport has a layer to be drawn with. One that doesn't is a
    /// window-shaped patch of wallpaper sliding across the cover.
    ///
    /// Two mechanisms hold it, and neither is reachable from a harness that acks instantly: a *shoulder*
    /// captured past each end of the sweep (`Layout.sweptWindowIds`), so a retarget's stills are already
    /// in; and a per-window capture gate (`TransitionSession.unboundWindows`), so a stream of interrupts
    /// cannot starve the cover's growth. The press rates bracket reality — 4 frames ≈ 33 ms is faster
    /// than a key repeat, 40 ≈ 333 ms is a full settle. No fixed lookahead is an absolute guarantee; the
    /// residual is characterized by `theShoulderBuysAtLeastOneCommandIntervalOfRunway` below.
    @Test(arguments: [4, 6, 10, 20, 40] as [Int], [4, 8] as [Int])
    func theCoverNeverShowsAHoleHoweverFastTheCommandsArrive(gapFrames: Int, captureLatency: Int) {
        for (command, settle) in Self.spammableCommands {
            let worst = Self.worstHoleWhileSpamming(command, settlingWith: settle, presses: 8,
                                                    gapFrames: gapFrames, captureLatency: captureLatency)
            #expect(worst == 0, "\(command) at \(gapFrames)-frame intervals, \(captureLatency)-frame captures")
        }
    }

    /// The shape of the residual, pinned. A shoulder is one column of lookahead, so what it buys is
    /// bounded. A *scroll* or *resize* moves the viewport over a strip whose column order is fixed, so
    /// the shoulder is the column that will arrive next by construction, and holes are unreachable at any
    /// capture latency. A *structural edit* re-orders the strip as well as scrolling it, bringing a
    /// column to the viewport edge earlier; the runway is then about one command interval, which is the
    /// honest floor this asserts, and it degrades into a narrower hole rather than a cliff.
    @Test(arguments: [6, 10, 15, 20, 30] as [Int])
    func theShoulderBuysAtLeastOneCommandIntervalOfRunway(gapFrames: Int) {
        for (command, settle) in Self.spammableCommands {
            let worst = Self.worstHoleWhileSpamming(command, settlingWith: settle, presses: 8,
                                                    gapFrames: gapFrames, captureLatency: gapFrames)
            #expect(worst == 0, "\(command) at \(gapFrames)-frame intervals and captures")
        }
    }

    /// A session's scope is fixed when it opens, but an interrupting command retargets the scroll and the
    /// new destination sweeps windows the original scope never named. The retarget widens the scope,
    /// captures the newcomer, and grows the cover mid-flight without re-raising anything.
    @Test func aRetargetSweepsInANewWindowCapturesItAndGrowsTheCover() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)), .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)), .windowCreated(EngineFix.snapshot(4)),
        ])
        // Scroll w4 → w3 and get the cover up. Scope is the two columns the motion touches, plus w2 as
        // the shoulder past its left end (`Layout.sweptWindowIds`); w4 is the last column, so there is
        // no shoulder to its right.
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(s.transition?.windows == [WindowId(2), WindowId(3), WindowId(4)])
        for w in s.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen(MonitorId(1)))               // …and the display shows it
        #expect(s.motion.isCovered(on: s.monitors.focused))
        for _ in 0..<4 { (s, _) = Engine.reduce(s, .tick(dt: 1.0 / 120)) }

        // INTERRUPT: aim at w2. The shoulder means its pixels are already on the cover — that is the
        // point of it — so what the widened scope newly names is w1, the *next* shoulder along.
        let (i, ifx) = Engine.reduce(s, .command(.focus(.left)))
        #expect(i.motion.isCovered(on: i.monitors.focused))                              // still the same cover
        #expect(EngineFix.capturedIds(in: ifx) == [WindowId(1)])      // …and it asked for the missing still
        #expect(i.transition?.windows == [WindowId(2), WindowId(3), WindowId(4), WindowId(1)])
        #expect(i.transition?.layerId(for: WindowId(2)) != nil)   // already covered: no hole
        #expect(i.transition?.layerId(for: WindowId(1)) == nil)   // no layer until it lands

        // The still lands → the cover grows, and the new layer is placed in the same batch.
        let (g, gfx) = Engine.reduce(i, .captureReady(WindowId(1)))
        let added: [LayerBinding] = gfx.compactMap { if case .extendCover(_, let b) = $0 { return b }; return nil }
            .flatMap { $0 }
        #expect(added.count == 1)
        #expect(added.first?.window == WindowId(1))
        let layer = try! #require(g.transition?.layerId(for: WindowId(1)))
        #expect(added.first?.layer == layer)
        // A fresh id, not one of the layers already on the cover.
        #expect(!(g.transition?.bindings.dropLast().map(\.layer).contains(layer) ?? true))
        // Created *and* positioned inside one presentation run — never a frame at its capture position.
        #expect(EngineFix.layerFrame(of: layer, in: gfx) != nil)

        // …and it still converges.
        let (done, _) = EngineFix.drive(g)
        #expect(done.motion.isTransitioning == false)
        #expect(done.world.focusedWindow == WindowId(2))
        #expect(EngineFix.approxScalar(done.viewport.offset.current, 1000))
    }

    /// The same widening, before the cover is up. There is nothing to grow yet, so the newcomer simply
    /// joins the batch the raise is waiting on — and the cover is built with it included, in one piece.
    @Test func aRetargetBeforeTheRaiseJoinsTheBatchInsteadOfGrowingTheCover() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)), .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)), .windowCreated(EngineFix.snapshot(4)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))       // opens the session; nothing captured
        let (i, ifx) = Engine.reduce(s, .command(.focus(.left))) // interrupt while still `.capturing`
        s = i

        #expect(EngineFix.capturedIds(in: ifx) == [WindowId(1)])      // the next shoulder along
        #expect(!s.motion.isCovered(on: s.monitors.focused))
        #expect(!EngineFix.hasEffect(ifx) { if case .setFrame = $0 { return true }; return false })  // nothing moved yet

        var raiseFx: [Effect] = []
        for w in s.transition?.windows ?? [] {
            let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; raiseFx += f
        }
        let bindings: [LayerBinding] = raiseFx
            .compactMap { if case .beginTransition(_, let b) = $0 { return b }; return nil }.flatMap { $0 }
        #expect(bindings.map(\.window) == [WindowId(2), WindowId(3), WindowId(4), WindowId(1)])
        #expect(!EngineFix.hasEffect(raiseFx) { if case .extendCover = $0 { return true }; return false })
    }

    /// A cover raised over stand-ins gets each window's own pixels as they land. The core's part is one
    /// translation — window to layer — because a content swap settles no gate and moves nothing: the
    /// transition's shape is already decided by the time one arrives.
    @Test func aRefreshedCaptureRepaintsThatWindowsLayerAndNothingElse() throws {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)), .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in s.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen(MonitorId(1)))               // …and the display shows it
        #expect(s.motion.isCovered(on: s.monitors.focused))

        let before = s
        let layer = try #require(s.transition?.layerId(for: WindowId(1)))
        let (after, fx) = Engine.reduce(s, .captureRefreshed(WindowId(1)))

        #expect(fx == [.refreshLayer(layer)])
        // Nothing about the transition changed: not its scope, not what it is still waiting on, not
        // where anything is. A refresh is the one effect that costs the core no state at all.
        #expect(after.motion == before.motion)
    }

    /// A refresh for a window with no layer — its still beat the raise, or it was never scoped — asks
    /// for nothing. The shell has already put those pixels in the store, and the raise will find them.
    @Test func aRefreshForAWindowWithNoLayerIsSilent() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)), .windowCreated(EngineFix.snapshot(2)),
            .windowCreated(EngineFix.snapshot(3)),
        ])
        // Mid-capture: a session is open and no layer has been minted yet.
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(s.motion.isTransitioning && !s.motion.isCovered(on: s.monitors.focused))
        let (mid, midFx) = Engine.reduce(s, .captureRefreshed(WindowId(1)))
        #expect(midFx.isEmpty)
        #expect(mid.motion == s.motion)

        // …and with no session at all, which is where a batch outliving its cover lands.
        let idle = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth),
                                 [.windowCreated(EngineFix.snapshot(1))]).0
        #expect(!idle.motion.isTransitioning)
        let (after, fx) = Engine.reduce(idle, .captureRefreshed(WindowId(1)))
        #expect(fx.isEmpty)
        #expect(after.motion == idle.motion)
    }

    /// No pixels ⇒ no cover, never a black one. A head capture batch that comes back without a desktop
    /// base answers `coverUnavailable`, and the session is abandoned *before* anything has moved — the
    /// user gets instant, correct placement instead of a blacked-out display.
    @Test func coverUnavailableAbandonsTheSessionAndSnaps() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)), .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(s.motion.isTransitioning)
        let target = s.viewport.offset.target

        let (a, afx) = Engine.reduce(s, .coverUnavailable(MonitorId(1)))
        #expect(a.motion.isTransitioning == false)               // no session, no cover, no ticks
        #expect(EngineFix.approxScalar(a.viewport.offset.current, target))   // snapped to the destination
        // …and every window is placed there at once, exactly as the no-grant path would have.
        #expect(EngineFix.placement(of: WindowId(1), in: afx) != nil)
        #expect(!EngineFix.hasEffect(afx) { if case .endTransition(MonitorId(1)) = $0 { return true }; return false })
    }

    /// Totality: the same event with a *raised* cover must not drop it — a cover that is up can only be
    /// taken down by the cross-fade. It cannot happen in practice; the reducer is total regardless.
    @Test func coverUnavailableNeverDropsARaisedCover() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)), .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in s.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .coverOnScreen(MonitorId(1)))               // …and the display shows it
        #expect(s.motion.isCovered(on: s.monitors.focused))

        let (a, afx) = Engine.reduce(s, .coverUnavailable(MonitorId(1)))
        #expect(a.motion.isCovered(on: a.monitors.focused))                              // untouched
        #expect(afx.isEmpty)
    }

}
