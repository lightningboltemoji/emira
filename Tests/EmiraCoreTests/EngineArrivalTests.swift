import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// A window reaching the strip: the placement a fresh arrival gets, and the width an
// already-open window keeps when emira adopts it at boot.

@Suite struct EngineArrivalTests {

    /// Two full-width columns with a cover up and the scroll part-way from w1 to w2 — the state a click
    /// on the neighbouring window puts the strip in, halfway through the reveal it asked for.
    static func midScroll() -> State {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        var fx: [Effect]
        (s, fx) = Engine.reduce(s, .command(.focus(.left)))     // back to w1, at rest
        s = EngineFix.settle(s, fx)

        (s, fx) = Engine.reduce(s, .focusChanged(WindowId(2), origin: .system))
        for effect in fx {                                      // raise the cover
            if case .capture(let w, _) = effect { (s, _) = Engine.reduce(s, .captureReady(w)) }
        }
        (s, _) = Engine.reduce(s, .coverOnScreen)               // …and put it on the glass
        for _ in 0..<8 { (s, _) = Engine.reduce(s, .tick(dt: 1.0 / 120)) }
        return s
    }

    @Test func newStandardWindowIsFocusedAndPlaced() {
        // No capture capability ⇒ no cover, so the window is placed in the same batch. (With a cover
        // available the same arrival animates — see `GhostWindowTests`.)
        let snap = Config(transitionMode: .off)
        let (s, fx) = Engine.reduce(EngineFix.booted(config: snap), .windowCreated(EngineFix.snapshot(1)))
        // One column, one window, focused, placed to a ⅓-width tile at the working-area origin.
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(s.layout.columns.count == 1)
        #expect(fx.contains(.focus(WindowId(1))))
        let placed = EngineFix.placement(of: WindowId(1), in: fx)
        #expect(placed != nil)
        #expect(EngineFix.approx(placed!, Rect(x: 0, y: 0, width: 1000.0 / 3.0, height: 800)))
    }

    @Test func nonTilingWindowIsRecordedButNotPlacedOrFocused() {
        let (s, fx) = Engine.reduce(EngineFix.booted(), .windowCreated(EngineFix.snapshot(1, role: .dialog)))
        #expect(s.world.windows[WindowId(1)] != nil)   // recorded in truth
        #expect(s.world.focusedWindow == nil)          // a dialog doesn't steal focus
        #expect(s.layout.columns.isEmpty)              // never joins the strip
        #expect(fx.isEmpty)                            // the app positions it, not us
    }

    @Test func twoWindowsFormTwoColumns() {
        let (s, _) = EngineFix.run(EngineFix.booted(), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        #expect(s.layout.columns.count == 2)
        #expect(s.layout.columns.map(\.windowIds) == [[WindowId(1)], [WindowId(2)]])
        #expect(s.world.focusedWindow == WindowId(2))  // the newer window has focus
    }

    @Test func placementIsIdempotentWhenNothingChanged() {
        // Re-placing an already-correct strip emits nothing (diffed against truth).
        let (s, _) = EngineFix.run(EngineFix.booted(), [.windowCreated(EngineFix.snapshot(1))])
        let (_, fx) = Engine.reduce(s, .dragEnded)     // dragEnded → re-assert layout
        #expect(fx.isEmpty)
    }

    @Test func dragEndedReassertsLayout() {
        // A tiled window the user dragged off-target snaps back on release.
        var (s, _) = EngineFix.run(EngineFix.booted(), [.windowCreated(EngineFix.snapshot(1))])
        (s, _) = Engine.reduce(s, .windowFrameChanged(WindowId(1), Rect(x: 700, y: 500, width: 200, height: 200)))
        let (_, fx) = Engine.reduce(s, .dragEnded)
        let placed = EngineFix.placement(of: WindowId(1), in: fx)
        #expect(placed != nil)
        #expect(EngineFix.approx(placed!, Rect(x: 0, y: 0, width: 1000.0 / 3.0, height: 800)))
    }

    /// **Every click is a mouse-up**, so `dragEnded` routinely lands inside the reveal that same click
    /// started — and a placement pass there writes the *truth* plane at `viewportOffset.current`, the
    /// number the spring is feeding the layers. The reals would be dragged to a position the animation
    /// invented and the cross-fade would reveal it as a jump backwards.
    @Test func aMouseUpMidTransitionDoesNotDragTheRealsToTheSpringsOffset() {
        var s = Self.midScroll()
        let mid = s.motion.viewportOffset.current
        #expect(mid > 0 && mid < 1000, "the spring is between the two columns")

        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .dragEnded)
        #expect(fx.isEmpty, "the reals are already where the cover is taking them")
        #expect(s.motion.viewportOffset.current == mid, "and the animation is untouched")
    }

    /// The other half: a window genuinely dragged off-target mid-transition still snaps back — to the
    /// frame it has at the scroll's *end*, which is where the cover already put every other window.
    @Test func aDragEndingMidTransitionSnapsBackToTheDestinationFrame() {
        var s = Self.midScroll()
        (s, _) = Engine.reduce(s, .windowFrameChanged(WindowId(2), Rect(x: 640, y: 480, width: 300, height: 300)))

        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .dragEnded)
        let placed = EngineFix.placement(of: WindowId(2), in: fx)
        #expect(placed != nil)
        #expect(EngineFix.approx(placed!, Rect(x: 0, y: 0, width: 1000, height: 800)),
                "w2's frame at the destination offset, not at the spring's")
    }

    /// The third of `reassertTruthPlane`'s answers, and the one with no cover to forgive it: mid-*capture*
    /// nothing is over the desktop, so a placement pass here is a write in the open — and it would write
    /// at the offset the scroll is leaving, dragging the window backwards a frame before the raise takes
    /// it forward. The raise's own teleport is what reads the drag instead.
    @Test func aMouseUpInTheCaptureHeadDefersToTheRaisesTeleport() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))      // aimed at w1; cover not up yet
        #expect(s.motion.phase == .capturing)
        let scope = s.motion.transition?.windows ?? []

        // A drag lands w2 somewhere of its own, and the mouse-up arrives before the stills do.
        (s, _) = Engine.reduce(s, .windowFrameChanged(WindowId(2), Rect(x: 640, y: 480, width: 300, height: 300)))
        let dragFx: [Effect]
        (s, dragFx) = Engine.reduce(s, .dragEnded)
        #expect(dragFx.isEmpty, "no cover to write under: the raise owns the next move")

        var raised: [Effect] = []
        for w in scope { let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; raised += f }
        let teleports: [Effect]
        (s, teleports) = Engine.reduce(s, .coverOnScreen)
        raised += teleports
        #expect(s.motion.phase == .covered)
        // w2 belongs off-view at the destination, so the teleport parks it — carrying the drag with it.
        let parked = EngineFix.placement(of: WindowId(2), in: raised)
        #expect(parked != nil, "the raise picked the drag up; the deferral lost nothing")

        let done = EngineFix.settle(s, raised)
        #expect(EngineFix.approxScalar(done.motion.viewportOffset.current, 0))
        #expect(done.world.windows[WindowId(2)]?.frame == parked, "and w2 came to rest there")
    }

    /// The same rule one phase later, which is the one with teeth: between the raise and the display
    /// showing it, the desktop still belongs to the eye. Nothing may be written there — not the
    /// transition's own teleport, and not a placement pass an unrelated event walks in with.
    @Test func nothingReachesTheTruthPlaneWhileTheCoverIsStillOnItsWay() {
        var (s, _) = EngineFix.run(EngineFix.booted(config: EngineFix.fullWidth), [
            .windowCreated(EngineFix.snapshot(1)),
            .windowCreated(EngineFix.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        var raise: [Effect] = []
        for w in s.motion.transition?.windows ?? [] {
            let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; raise += f
        }
        #expect(s.motion.phase == .raising)
        #expect(!raise.contains { switch $0 { case .setFrame, .park: true; default: false } })

        // Every event that would otherwise re-place the world, while the cover is in flight.
        for event: Event in [.dragEnded,
                             .screensChanged([MonitorInfo(id: MonitorId(1), frame: EngineFix.displayFrame)]),
                             .windowFrameChanged(WindowId(2), Rect(x: 640, y: 480, width: 300, height: 300))] {
            let (next, fx) = Engine.reduce(s, event)
            #expect(!fx.contains { switch $0 { case .setFrame, .park: true; default: false } },
                    "\(event) wrote the truth plane with nothing on screen to hide it")
            s = next
        }

        // …and the teleport that was owed all along arrives with the report, carrying the drag.
        let teleports: [Effect]
        (s, teleports) = Engine.reduce(s, .coverOnScreen)
        #expect(s.motion.isCovered)
        #expect(EngineFix.placement(of: WindowId(2), in: teleports) != nil)
    }

    @Test func windowFrameChangedRecordsDriftButDoesNotRetile() {
        var (s, _) = EngineFix.run(EngineFix.booted(), [.windowCreated(EngineFix.snapshot(1))])
        let drifted = Rect(x: 700, y: 500, width: 200, height: 200)
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowFrameChanged(WindowId(1), drifted))
        #expect(fx.isEmpty)                                    // no fighting the user mid-drag
        #expect(s.world.windows[WindowId(1)]?.frame == drifted) // but the drift is recorded
    }

    // emira keeps no layout across restarts, so the widths on screen when the launch scan runs are the
    // only record of the user's arrangement. An adopted window keeps the width it already has; a window
    // opened afterwards is the app's default and belongs on the ladder.

    /// A window emira met already open is tiled at its own width, not at ⅓.
    @Test func aWindowAdoptedAtBootKeepsTheWidthItAlreadyHad() {
        let snap = Config(transitionMode: .off)
        let adopted = EngineFix.snapshot(1, frame: Rect(x: 120, y: 90, width: 640, height: 500),
                                         wasAlreadyOpen: true)
        let (s, fx) = Engine.reduce(EngineFix.booted(config: snap), .windowCreated(adopted))

        #expect(EngineFix.width(s) == 640)
        #expect(s.layout.columns[0].widthOverride == .proportion(0.64))
        // …and it is tiled there: only the *position* changes, so the arrival never resizes a window
        // the user did not ask to resize.
        let placed = EngineFix.placement(of: WindowId(1), in: fx)
        #expect(placed != nil)
        #expect(EngineFix.approx(placed!, Rect(x: 0, y: 0, width: 640, height: 800)))
    }

    /// The one correction we do make: wider than the viewport is not a state the strip reaches on its
    /// own, so an adopted window is brought to the edge of it rather than greeting the user with its
    /// right edge cut off.
    @Test func anAdoptedWindowWiderThanTheScreenIsClampedToOneHundredPercent() {
        let snap = Config(transitionMode: .off)
        let huge = EngineFix.snapshot(1, frame: Rect(x: -200, y: 0, width: 1400, height: 900),
                                      wasAlreadyOpen: true)
        let (s, _) = Engine.reduce(EngineFix.booted(config: snap), .windowCreated(huge))

        #expect(EngineFix.width(s) == 1000)                                   // the working width, exactly
        #expect(s.layout.columns[0].widthOverride == .proportion(1.0))
    }

    /// The seed is a *fraction*, like every other width on the strip — which is what makes the clamp
    /// survive the display changing under it.
    @Test func anAdoptedWidthTracksTheMonitorTheWayAPresetDoes() {
        let snap = Config(transitionMode: .off)
        let half = EngineFix.snapshot(1, frame: Rect(x: 0, y: 0, width: 500, height: 800),
                                      wasAlreadyOpen: true)
        var (s, _) = Engine.reduce(EngineFix.booted(config: snap), .windowCreated(half))
        #expect(EngineFix.width(s) == 500)

        (s, _) = Engine.reduce(s, .screensChanged([MonitorInfo(id: MonitorId(1),
                                                               frame: Rect(x: 0, y: 0, width: 2000, height: 800))]))
        #expect(EngineFix.width(s) == 1000)   // still half the working width, not still 500 points
    }

    /// A window born under a running daemon has no arrangement to preserve: its width is whatever its
    /// app defaults to, and the ladder is where it belongs.
    @Test func aWindowOpenedAfterBootStillTakesTheFirstPreset() {
        let snap = Config(transitionMode: .off)
        let born = EngineFix.snapshot(1, frame: Rect(x: 120, y: 90, width: 640, height: 500))
        let (s, _) = Engine.reduce(EngineFix.booted(config: snap), .windowCreated(born))

        #expect(EngineFix.approxScalar(EngineFix.width(s), EngineFix.third))
        #expect(s.layout.columns[0].widthOverride == nil)
    }

    /// The seed is an ordinary `widthOverride`: `cycle-width` clears it and resumes the ladder exactly
    /// as it does after a `grow`.
    @Test func cycleWidthClearsAnAdoptedWidthLikeAnyOtherOverride() {
        let config = Config(transitionMode: .off)                    // ⅓ / ½ / ⅔
        let adopted = EngineFix.snapshot(1, frame: Rect(x: 0, y: 0, width: 640, height: 500),
                                         wasAlreadyOpen: true)
        var (s, _) = Engine.reduce(EngineFix.booted(config: config), .windowCreated(adopted))

        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        #expect(s.layout.columns[0].widthOverride == nil)
        #expect(s.layout.columns[0].widthPreset == 1)
        #expect(EngineFix.width(s) == 500)
    }

    /// Total against a window with no width to keep — the preset answers.
    @Test func anAdoptedWindowWithNoWidthFallsBackToThePreset() {
        let snap = Config(transitionMode: .off)
        let empty = EngineFix.snapshot(1, frame: Rect(x: 0, y: 0, width: 0, height: 0), wasAlreadyOpen: true)
        let (s, _) = Engine.reduce(EngineFix.booted(config: snap), .windowCreated(empty))

        #expect(s.layout.columns[0].widthOverride == nil)
        #expect(EngineFix.approxScalar(EngineFix.width(s), EngineFix.third))
    }

}
