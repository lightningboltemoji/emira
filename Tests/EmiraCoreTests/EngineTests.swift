import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// The reducer scenarios (IMPLEMENTATION.md §8) — the whole point of the functional-core design is
// that the brain is verified here, with no AX / Core Animation / ScreenCaptureKit anywhere. Each test
// drives a scripted `Event` stream through `Engine.reduce` and asserts the resulting `State` and the
// emitted `Effect` stream. This slice covers the snap/idle reducer: truth-plane folding, instant
// correct placement, and focus/reveal by snapping (the M3-parity brain). The animated transition
// session and its interrupt/retarget scenarios land with the next slice.

@Suite struct EngineTests {

    // MARK: - Fixtures

    /// A 1000×800 display at the origin, ⅓/½/⅔ widths, no gaps/struts — unless overridden.
    static let displayFrame = Rect(x: 0, y: 0, width: 1000, height: 800)

    /// Config with a single ½-width preset — makes off-viewport columns crisp: two 500-wide columns
    /// fill a 1000-wide viewport exactly, so a third column is unambiguously off-view.
    static let halfWidth = Config(widthPresets: PresetCycle([.proportion(0.5)]))

    /// `halfWidth`, but snapping. The structural-arithmetic tests are about *where windows end up*,
    /// not how they get there — and once a structural edit animates, the reals teleport at the cover's
    /// raise rather than in the command's own batch, so asserting placements in that batch is asking
    /// the wrong question. `smoothTransitions = false` is a real supported configuration (§4a: a
    /// machine with no Screen Recording grant), not a test-only escape hatch, and the motion paths get
    /// their own tests below.
    static let halfWidthSnap = Config(widthPresets: PresetCycle([.proportion(0.5)]),
                                      smoothTransitions: false)

    /// Config with a single full-width preset — one column *is* the viewport, so every focus change
    /// across columns genuinely scrolls (each column exactly fills, the neighbours are off-view). This
    /// is what makes the animated-scroll paths fire; ½-width lets two columns coexist and often snaps.
    static let fullWidth = Config(widthPresets: PresetCycle([.proportion(1.0)]))

    /// A fresh state that already knows about one display.
    static func booted(config: Config = Config(), display: Rect = displayFrame) -> State {
        let (s, _) = Engine.reduce(State(config: config),
                                   .screensChanged([MonitorInfo(id: MonitorId(1), frame: display)]))
        return s
    }

    static func snapshot(_ raw: UInt64, bundle: String = "com.test.app", title: String = "w",
                         role: WindowRole = .standard, frame: Rect = Rect(x: 300, y: 300, width: 200, height: 200),
                         wasAlreadyOpen: Bool = false) -> WindowSnapshot {
        WindowSnapshot(id: WindowId(raw), bundleId: bundle, title: title, role: role, frame: frame,
                       wasAlreadyOpen: wasAlreadyOpen)
    }

    /// Drive a state to rest: answer every capture, land every AX set, and tick until the animators
    /// settle. What a real daemon does over ~300 ms, with no clock in it.
    ///
    /// Needed since 2026-07-26, when **arrival** started animating: building a world out of
    /// `windowCreated`s now opens a transition, so a test that wants "a placed world" has to close it
    /// the way the daemon does rather than assume placement was instant.
    static func settle(_ start: State, _ effects: [Effect] = []) -> State {
        var s = start
        var queue = effects
        for _ in 0..<4000 {
            var feedback: [Event] = []
            for effect in queue {
                switch effect {
                case .capture(let w): feedback.append(.captureReady(w))
                case .setFrame(let w, _), .park(let w, _): feedback.append(.axLanded(w))
                default: continue
                }
            }
            queue = []
            if feedback.isEmpty {
                guard s.motion.isTransitioning else { return s }
                feedback = [.tick(dt: 1.0 / 120)]
            }
            for event in feedback {
                let (next, out) = Engine.reduce(s, event)
                s = next
                queue += out
            }
        }
        return s
    }

    /// A booted state holding `count` tiled windows, at rest — the ordinary "given a world" setup.
    static func world(_ count: UInt64, config: Config = Config()) -> State {
        var s = booted(config: config)
        for raw in 1...count {
            let (next, fx) = Engine.reduce(s, .windowCreated(snapshot(raw)))
            s = settle(next, fx)
        }
        return s
    }

    /// Drive a sequence of events, returning the final state and the concatenated effect stream.
    static func run(_ start: State, _ events: [Event]) -> (State, [Effect]) {
        var s = start
        var effects: [Effect] = []
        for e in events {
            let wasIdle = !s.motion.isTransitioning
            let (next, fx) = Engine.reduce(s, e)
            s = next
            effects += fx
            // **World setup is not the thing under test.** Since 2026-07-26 an arrival animates, so a
            // `windowCreated` that *opened* a transition is driven to rest here — otherwise every test
            // that builds a world out of them would be asserting against a half-raised cover. An
            // arrival that joined a transition the test already had in flight is deliberately left
            // alone, which is the case `aRetargetSweepsInANewWindow…` and friends are about.
            if wasIdle, isArrival(e), s.motion.isTransitioning { s = settle(s, fx) }
        }
        return (s, effects)
    }

    /// Whether an event puts a window *onto* the strip, and therefore animates.
    static func isArrival(_ event: Event) -> Bool {
        switch event {
        case .windowCreated, .windowDeminimized: return true
        default: return false
        }
    }

    static func approx(_ a: Rect, _ b: Rect, tol: Double = 0.01) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol &&
        abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    /// The `Rect` a `setFrame`/`park` effect targeted the given window with, or `nil`.
    static func placement(of id: WindowId, in effects: [Effect]) -> Rect? {
        for e in effects {
            switch e {
            case .setFrame(let w, let r) where w == id: return r
            case .park(let w, let r) where w == id: return r
            default: continue
            }
        }
        return nil
    }

    static func approxScalar(_ a: Double, _ b: Double, tol: Double = 0.5) -> Bool { abs(a - b) <= tol }

    /// The window ids a run of `.capture` effects requested, in order.
    static func capturedIds(in fx: [Effect]) -> [WindowId] {
        fx.compactMap { if case .capture(let w) = $0 { return w }; return nil }
    }

    /// The `Rect` a `.setLayerFrame` targeted the given layer with (last wins), or `nil`.
    static func layerFrame(of layer: LayerId, in fx: [Effect]) -> Rect? {
        var found: Rect?
        for e in fx { if case .setLayerFrame(let l, let r) = e, l == layer { found = r } }
        return found
    }

    static func hasEffect(_ fx: [Effect], _ predicate: (Effect) -> Bool) -> Bool { fx.contains(where: predicate) }

    /// Every structural command in every direction — the set the totality/absence tests sweep.
    static let structuralCommands: [Command] =
        Direction.allCases.map { Command.moveWindow($0) }
        + Direction.allCases.map { Command.consumeOrExpel($0) }

    /// Drive an open transition to close: deliver every scoped `captureReady` (raises the cover and
    /// teleports the reals), land every awaited real, then tick until the animators settle and the
    /// session tears down. Bounded so a non-converging spring fails loudly instead of hanging. Returns
    /// the final state and the full concatenated effect stream. Idempotent from any mid-transition point.
    static func drive(_ start: State) -> (State, [Effect]) {
        var s = start
        var fx: [Effect] = []
        func feed(_ e: Event) { let (n, f) = Engine.reduce(s, e); s = n; fx += f }

        for w in s.motion.transition?.windows ?? [] { feed(.captureReady(w)) }
        for w in s.motion.transition?.awaitingLanding ?? [] { feed(.axLanded(w)) }
        var guardCount = 0
        while s.motion.isTransitioning && guardCount < 5000 {
            feed(.tick(dt: 1.0 / 120))
            guardCount += 1
        }
        return (s, fx)
    }

    // MARK: - Instant correct placement (the §4a floor)

    @Test func newStandardWindowIsFocusedAndPlaced() {
        // §4a's floor, so §4a's configuration: no capture capability ⇒ no cover, and the window is
        // placed in the same batch. (With a cover available the same arrival animates — see
        // `GhostWindowTests`.)
        let snap = Config(smoothTransitions: false)
        let (s, fx) = Engine.reduce(Self.booted(config: snap), .windowCreated(Self.snapshot(1)))
        // One column, one window, focused, placed to a ⅓-width tile at the working-area origin.
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(s.layout.columns.count == 1)
        #expect(fx.contains(.focus(WindowId(1))))
        let placed = Self.placement(of: WindowId(1), in: fx)
        #expect(placed != nil)
        #expect(Self.approx(placed!, Rect(x: 0, y: 0, width: 1000.0 / 3.0, height: 800)))
    }

    @Test func nonTilingWindowIsRecordedButNotPlacedOrFocused() {
        let (s, fx) = Engine.reduce(Self.booted(), .windowCreated(Self.snapshot(1, role: .dialog)))
        #expect(s.world.windows[WindowId(1)] != nil)   // recorded in truth
        #expect(s.world.focusedWindow == nil)          // a dialog doesn't steal focus
        #expect(s.layout.columns.isEmpty)              // never joins the strip
        #expect(fx.isEmpty)                            // the app positions it, not us
    }

    @Test func twoWindowsFormTwoColumns() {
        let (s, _) = Self.run(Self.booted(), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        #expect(s.layout.columns.count == 2)
        #expect(s.layout.columns.map(\.windowIds) == [[WindowId(1)], [WindowId(2)]])
        #expect(s.world.focusedWindow == WindowId(2))  // the newer window has focus
    }

    @Test func placementIsIdempotentWhenNothingChanged() {
        // Re-placing an already-correct strip emits nothing (diffed against truth).
        let (s, _) = Self.run(Self.booted(), [.windowCreated(Self.snapshot(1))])
        let (_, fx) = Engine.reduce(s, .dragEnded)     // dragEnded → re-assert layout
        #expect(fx.isEmpty)
    }

    @Test func dragEndedReassertsLayout() {
        // A tiled window the user dragged off-target snaps back on release.
        var (s, _) = Self.run(Self.booted(), [.windowCreated(Self.snapshot(1))])
        (s, _) = Engine.reduce(s, .windowFrameChanged(WindowId(1), Rect(x: 700, y: 500, width: 200, height: 200)))
        let (_, fx) = Engine.reduce(s, .dragEnded)
        let placed = Self.placement(of: WindowId(1), in: fx)
        #expect(placed != nil)
        #expect(Self.approx(placed!, Rect(x: 0, y: 0, width: 1000.0 / 3.0, height: 800)))
    }

    @Test func windowFrameChangedRecordsDriftButDoesNotRetile() {
        var (s, _) = Self.run(Self.booted(), [.windowCreated(Self.snapshot(1))])
        let drifted = Rect(x: 700, y: 500, width: 200, height: 200)
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowFrameChanged(WindowId(1), drifted))
        #expect(fx.isEmpty)                                    // no fighting the user mid-drag
        #expect(s.world.windows[WindowId(1)]?.frame == drifted) // but the drift is recorded
    }

    // MARK: - The desktop emira meets at boot (2026-07-26)
    //
    // emira keeps no layout across restarts (§10), so the widths on screen when the launch scan runs are
    // the only record of the user's arrangement there is. An adopted window keeps the width it already
    // has; a window opened afterwards is the app's default and belongs on the ladder.

    /// The whole of it: a window emira met already open is tiled at its own width, not at ⅓.
    @Test func aWindowAdoptedAtBootKeepsTheWidthItAlreadyHad() {
        let snap = Config(smoothTransitions: false)
        let adopted = Self.snapshot(1, frame: Rect(x: 120, y: 90, width: 640, height: 500),
                                    wasAlreadyOpen: true)
        let (s, fx) = Engine.reduce(Self.booted(config: snap), .windowCreated(adopted))

        #expect(Self.width(s) == 640)
        #expect(s.layout.columns[0].widthOverride == .proportion(0.64))
        // …and it is tiled there: only the *position* changes, so the arrival never resizes a window
        // the user did not ask to resize.
        let placed = Self.placement(of: WindowId(1), in: fx)
        #expect(placed != nil)
        #expect(Self.approx(placed!, Rect(x: 0, y: 0, width: 640, height: 800)))
    }

    /// The one correction we do make. Wider than the viewport is not a state the strip reaches on its
    /// own — neither the ladder nor `grow`'s ceiling goes past 100% — so an adopted window is brought to
    /// the edge of it rather than greeting the user with its right edge cut off.
    @Test func anAdoptedWindowWiderThanTheScreenIsClampedToOneHundredPercent() {
        let snap = Config(smoothTransitions: false)
        let huge = Self.snapshot(1, frame: Rect(x: -200, y: 0, width: 1400, height: 900),
                                 wasAlreadyOpen: true)
        let (s, _) = Engine.reduce(Self.booted(config: snap), .windowCreated(huge))

        #expect(Self.width(s) == 1000)                                   // the working width, exactly
        #expect(s.layout.columns[0].widthOverride == .proportion(1.0))
    }

    /// The seed is a *fraction*, like every other width on the strip — which is what makes the clamp
    /// survive the display changing under it.
    @Test func anAdoptedWidthTracksTheMonitorTheWayAPresetDoes() {
        let snap = Config(smoothTransitions: false)
        let half = Self.snapshot(1, frame: Rect(x: 0, y: 0, width: 500, height: 800),
                                 wasAlreadyOpen: true)
        var (s, _) = Engine.reduce(Self.booted(config: snap), .windowCreated(half))
        #expect(Self.width(s) == 500)

        (s, _) = Engine.reduce(s, .screensChanged([MonitorInfo(id: MonitorId(1),
                                                               frame: Rect(x: 0, y: 0, width: 2000, height: 800))]))
        #expect(Self.width(s) == 1000)   // still half the working width, not still 500 points
    }

    /// A window born under a running daemon has no arrangement to preserve: its width is whatever its
    /// app defaults to, and the ladder is where it belongs.
    @Test func aWindowOpenedAfterBootStillTakesTheFirstPreset() {
        let snap = Config(smoothTransitions: false)
        let born = Self.snapshot(1, frame: Rect(x: 120, y: 90, width: 640, height: 500))
        let (s, _) = Engine.reduce(Self.booted(config: snap), .windowCreated(born))

        #expect(Self.approxScalar(Self.width(s), Self.third))
        #expect(s.layout.columns[0].widthOverride == nil)
    }

    /// The seed costs the user nothing to undo, because it is a `widthOverride` and nothing new:
    /// `cycle-width` clears it and resumes the ladder exactly as it does after a `grow`.
    @Test func cycleWidthClearsAnAdoptedWidthLikeAnyOtherOverride() {
        let config = Config(smoothTransitions: false)                    // ⅓ / ½ / ⅔
        let adopted = Self.snapshot(1, frame: Rect(x: 0, y: 0, width: 640, height: 500),
                                    wasAlreadyOpen: true)
        var (s, _) = Engine.reduce(Self.booted(config: config), .windowCreated(adopted))

        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        #expect(s.layout.columns[0].widthOverride == nil)
        #expect(s.layout.columns[0].widthPreset == 1)
        #expect(Self.width(s) == 500)
    }

    /// Total against a window with no width to keep — the preset answers, as it did before.
    @Test func anAdoptedWindowWithNoWidthFallsBackToThePreset() {
        let snap = Config(smoothTransitions: false)
        let empty = Self.snapshot(1, frame: Rect(x: 0, y: 0, width: 0, height: 0), wasAlreadyOpen: true)
        let (s, _) = Engine.reduce(Self.booted(config: snap), .windowCreated(empty))

        #expect(s.layout.columns[0].widthOverride == nil)
        #expect(Self.approxScalar(Self.width(s), Self.third))
    }

    // MARK: - Focus & reveal (snap)

    @Test func horizontalFocusScrollAnimatesAcrossColumns() {
        // Full-width columns: every focus change scrolls one viewport. After creating w1/w2/w3, focus
        // is on w3 at offset 2000 (each create-reveal snapped one viewport right).
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        #expect(s.world.focusedWindow == WindowId(3))
        #expect(s.motion.viewportOffset.current == 2000)

        // focus left → w2. Focus moves *immediately* (truth), but the scroll now animates: a transition
        // opens, aimed at offset 1000, with the viewport not yet moved.
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .command(.focus(.left)))
        #expect(s.world.focusedWindow == WindowId(2))            // focus is a truth change, not animated
        #expect(fx.contains(.focus(WindowId(2))))
        #expect(s.motion.isTransitioning)
        #expect(s.motion.isCovered == false)                    // still capturing — cover not raised
        #expect(s.motion.viewportOffset.target == 1000)         // aimed left one viewport
        #expect(s.motion.viewportOffset.current == 2000)        // hasn't moved yet (no ticks)
        // Scope = {w2, w3} swept, plus w1 as the left shoulder — the column one further `focus left`
        // would pull in, captured now because a capture requested then would arrive too late
        // (`Layout.sweptWindowIds`). A capture each, and *no* real teleport yet (nothing is exposed
        // before the cover is up).
        #expect(Set(Self.capturedIds(in: fx)) == Set([WindowId(1), WindowId(2), WindowId(3)]))
        #expect(!Self.hasEffect(fx) { if case .setFrame = $0 { return true }; return false })
        #expect(!Self.hasEffect(fx) { if case .beginTransition = $0 { return true }; return false })

        // Drive it home: w2 revealed at offset 1000, cover down.
        let (done, _) = Self.drive(s)
        #expect(done.motion.isTransitioning == false)
        #expect(Self.approxScalar(done.motion.viewportOffset.current, 1000))
    }

    @Test func focusWithNoViewportMotionIsASnap() {
        // A focus change whose target column is *already in view* opens no transition — there's nothing
        // to animate, so it stays a snap. ½-width fits two columns, so focusing between w3 and w2 (both
        // on screen at offset 500) never scrolls.
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .command(.focus(.left)))       // w3 → w2, both visible
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(s.motion.isTransitioning == false)                // snap, not a transition
        #expect(s.motion.viewportOffset.velocity == 0)
        #expect(s.motion.viewportOffset.current == s.motion.viewportOffset.target)  // settled, not moving
        #expect(Self.capturedIds(in: fx).isEmpty)                 // no cover ⇒ no captures
    }

    @Test func horizontalFocusAtEdgeIsNoOp() {
        var (s, _) = Self.run(Self.booted(), [.windowCreated(Self.snapshot(1))])
        // Only one column — focusing right has no neighbour.
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .command(.focus(.right)))
        #expect(s.world.focusedWindow == WindowId(1))  // unchanged
        #expect(fx.isEmpty)
    }

    @Test func verticalFocusMovesWithinColumnWithoutScrolling() {
        // Build a two-window column by hand (consume/expel isn't in this slice), then focus down.
        let world = { () -> World in
            var w = World()
            w.setMonitors([MonitorInfo(id: MonitorId(1), frame: Self.displayFrame)])
            w.insert(Self.snapshot(1)); w.insert(Self.snapshot(2))
            w.setFocus(WindowId(1))
            return w
        }()
        let layout = Layout(columns: [ColumnLayout(id: ColumnId(1), windowIds: [WindowId(1), WindowId(2)])])
        let state = State(world: world, layout: layout, motion: Motion(), config: Config())

        let (s, fx) = Engine.reduce(state, .command(.focus(.down)))
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(fx.contains(.focus(WindowId(2))))
        #expect(fx.contains(.raise(WindowId(2))))
        #expect(s.motion.viewportOffset.current == 0)                 // no scroll
        #expect(!fx.contains { if case .setFrame = $0 { return true }; return false })  // no re-place
    }

    @Test func focusWithNothingFocusedTakesTheFirstWindow() {
        // Insert two windows directly with no focus set, then a focus command grabs the first.
        var world = World()
        world.setMonitors([MonitorInfo(id: MonitorId(1), frame: Self.displayFrame)])
        world.insert(Self.snapshot(1)); world.insert(Self.snapshot(2))
        let state = State(world: world, layout: Layout(), motion: Motion(), config: Config())

        let (s, fx) = Engine.reduce(state, .command(.focus(.right)))
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(fx.contains(.focus(WindowId(1))))
    }

    @Test func centerColumnScrollsFocusedColumnToCenter() {
        // Two ½-width windows both fit at the origin; focus w1 (a no-motion snap back to it).
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))       // w2 → w1, both visible ⇒ snap
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(s.motion.isTransitioning == false)
        #expect(s.motion.viewportOffset.current == 0)

        // centerColumn: column 0 is [0,500]; centering it in a 1000 viewport ⇒ −(1000−500)/2 = −250.
        // That's a real scroll now, so it animates rather than snapping.
        let (c, fx) = Engine.reduce(s, .command(.centerColumn))
        #expect(c.motion.isTransitioning)                        // animated, not snapped
        #expect(c.motion.viewportOffset.target == -250)          // aimed at the centered offset
        #expect(c.motion.viewportOffset.current == 0)            // hasn't moved yet
        #expect(!Self.capturedIds(in: fx).isEmpty)               // captures requested (a cover is coming)
        #expect(!fx.contains(.focus(WindowId(1))))               // centering never re-focuses

        // And it lands where it aimed.
        let (done, _) = Self.drive(c)
        #expect(done.motion.isTransitioning == false)
        #expect(Self.approxScalar(done.motion.viewportOffset.current, -250))
    }

    // MARK: - External focus (snap-reveal, §4a)

    @Test func externalFocusRevealsWithoutEmittingFocus() {
        // A window that scrolled off-view regains focus via Cmd-Tab — we snap to it, but don't
        // re-issue a focus effect (the shell already moved focus).
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),   // focus w3, scrolled to offset 500; w1 parked
        ])
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .focusChanged(WindowId(1)))
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(s.motion.viewportOffset.current == 0)   // snapped back to reveal w1
        #expect(!fx.contains(.focus(WindowId(1))))       // shell-initiated: no focus effect
        #expect(fx.contains { if case .setFrame(WindowId(1), _) = $0 { return true }; return false })
    }

    @Test func externalFocusToNilJustClearsFocus() {
        var (s, _) = Self.run(Self.booted(), [.windowCreated(Self.snapshot(1))])
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .focusChanged(nil))
        #expect(s.world.focusedWindow == nil)
        #expect(fx.isEmpty)
    }

    // MARK: - Destroy / minimize (leave the strip, refocus, reflow)

    @Test func destroyingFocusedWindowRefocusesAndReflows() {
        var (s, _) = Self.run(Self.booted(), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),   // focus w2
        ])
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDestroyed(WindowId(2)))
        #expect(s.world.windows[WindowId(2)] == nil)
        #expect(s.layout.columns.count == 1)
        #expect(s.world.focusedWindow == WindowId(1))      // focus moved to the survivor
        #expect(fx.contains(.focus(WindowId(1))))
    }

    @Test func destroyingUnfocusedWindowKeepsFocusAndReflows() {
        var (s, _) = Self.run(Self.booted(), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),   // focus w2
        ])
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDestroyed(WindowId(1)))
        #expect(s.world.focusedWindow == WindowId(2))       // unchanged
        #expect(s.layout.columns.count == 1)
        #expect(!fx.contains(.focus(WindowId(2))))          // no spurious focus re-assert
    }

    @Test func minimizeLeavesTheStripAndRefocuses() {
        var (s, _) = Self.run(Self.booted(), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),   // focus w2
        ])
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowMinimized(WindowId(2)))
        #expect(s.world.stripWindowIds == [WindowId(1)])    // w2 left the strip
        #expect(s.layout.columns.count == 1)
        #expect(s.world.focusedWindow == WindowId(1))
        #expect(fx.contains(.focus(WindowId(1))))
    }

    @Test func deminimizeRejoinsTheStripAndFocuses() {
        var (s, _) = Self.run(Self.booted(), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .windowMinimized(WindowId(2)))
        let fx: [Effect]
        (s, fx) = Engine.reduce(s, .windowDeminimized(WindowId(2)))
        #expect(s.world.stripWindowIds.contains(WindowId(2)))
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(fx.contains(.focus(WindowId(2))))
    }

    // MARK: - Totality before a monitor is known

    @Test func geometryCommandsNoOpWithNoDisplay() {
        // No `screensChanged` yet: truth still folds, but nothing can be placed.
        var s = State()
        let fx1: [Effect]
        (s, fx1) = Engine.reduce(s, .windowCreated(Self.snapshot(1)))
        #expect(s.world.windows[WindowId(1)] != nil)  // truth recorded
        #expect(s.world.focusedWindow == WindowId(1)) // focus tracked
        #expect(fx1.isEmpty)                          // but no placement — nowhere to place

        let fx2: [Effect]
        (s, fx2) = Engine.reduce(s, .command(.focus(.left)))
        #expect(fx2.isEmpty)

        // First display arrives → everything gets placed.
        let fx3: [Effect]
        (s, fx3) = Engine.reduce(s, .screensChanged([MonitorInfo(id: MonitorId(1), frame: Self.displayFrame)]))
        #expect(Self.placement(of: WindowId(1), in: fx3) != nil)
    }

    @Test func transitionFeedbackEventsAreInertWhenIdle() {
        // With no session open (steady state), every transition-feedback event acks nothing and leaves
        // the state untouched — the totality guarantee for a stray ack that outlives its transition.
        //
        // `axFailed` is the one exception, and it is not about the transition: it says the frame the
        // core optimistically recorded never happened, which is true with or without a session open
        // (`World.unverified`, 2026-07-26). It still emits nothing — re-placing from here would be a
        // busy loop against a hung app — so what it changes is only what the *next* placement asks.
        let (s0, _) = Self.run(Self.booted(), [.windowCreated(Self.snapshot(1))])
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

    // MARK: - The animated transition session (§3/§4b)

    @Test func transitionLifecycleRaisesCoverTeleportsAndCrossFades() {
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))       // open the scroll w3 → w2 (target 1000)
        let scope = s.motion.transition?.windows ?? []
        #expect(Set(scope) == Set([WindowId(1), WindowId(2), WindowId(3)]))  // swept {w2,w3} + w1's shoulder
        #expect(s.motion.isCovered == false)                     // still capturing

        // Every capture in → raise the cover and teleport the reals to their end frames (offset 1000):
        // w2 comes into view (setFrame), w3 scrolls off (park).
        var fx: [Effect] = []
        for w in scope { let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; fx += f }
        #expect(s.motion.isCovered)
        #expect(Self.hasEffect(fx) { if case .beginTransition = $0 { return true }; return false })
        #expect(Self.hasEffect(fx) { if case .setFrame(WindowId(2), _) = $0 { return true }; return false })
        #expect(Self.hasEffect(fx) { if case .park(WindowId(3), _) = $0 { return true }; return false })
        #expect(s.motion.transition?.awaitingLanding == Set([WindowId(2), WindowId(3)]))

        // A covered tick blits one layer per scoped window but does not close (reals unlanded).
        let (t, tfx) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(Self.hasEffect(tfx) { if case .setLayerFrame = $0 { return true }; return false })
        #expect(!tfx.contains(.endTransition))
        s = t

        // Reals land, animators settle → endTransition + cover down, resting at the target offset.
        let (done, dfx) = Self.drive(s)
        #expect(done.motion.isTransitioning == false)
        #expect(dfx.contains(.endTransition))
        #expect(Self.approxScalar(done.motion.viewportOffset.current, 1000))
    }

    /// The degradation path for a machine with no Screen Recording grant (`Config.smoothTransitions`).
    /// The cover is made of captured pixels; with none to be had, animating an empty one is strictly
    /// worse than not covering at all, so the same scroll that opens a session above becomes the plain
    /// snap-place of §4a. What must survive is the *placement*: the window still ends up exactly where
    /// the smooth path would have put it, and the viewport rests at the same offset.
    @Test func withoutSmoothTransitionsAScrollSnapsAndCapturesNothing() {
        var config = Self.fullWidth
        config.smoothTransitions = false
        var (s, _) = Self.run(Self.booted(config: config), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        let (snapped, fx) = Engine.reduce(s, .command(.focus(.left)))
        s = snapped

        #expect(!s.motion.isTransitioning)                       // no session was ever opened
        #expect(!Self.hasEffect(fx) { if case .capture = $0 { return true }; return false })
        #expect(!Self.hasEffect(fx) { if case .beginTransition = $0 { return true }; return false })
        // Placed, focused, and resting at the offset the animated path would have converged on.
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(Self.approxScalar(s.motion.viewportOffset.current, 1000))
        #expect(Self.placement(of: WindowId(2), in: fx) != nil)
    }

    /// The gate is on *motion*, not on focus: a focus change that doesn't scroll took the snap path
    /// already, and must be unaffected by the flag either way.
    @Test func withoutSmoothTransitionsAnInViewFocusIsUnchanged() {
        var config = Self.halfWidth
        config.smoothTransitions = false
        var (s, _) = Self.run(Self.booted(config: config), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        let (next, fx) = Engine.reduce(s, .command(.focus(.left)))
        s = next

        #expect(s.world.focusedWindow == WindowId(1))
        #expect(!s.motion.isTransitioning)
        #expect(Self.approxScalar(s.motion.viewportOffset.current, 0))
        #expect(fx.contains(.focus(WindowId(1))))
    }

    @Test func interruptRetargetsInFlightScrollWithoutOpeningASecondSession() {
        // The scenario the whole core-owns-the-clock design exists for (§8). Settle focused on w2 at
        // offset 1000 first (full-width, three windows).
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        (s, _) = Self.drive(s)
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(s.motion.isTransitioning == false)
        #expect(Self.approxScalar(s.motion.viewportOffset.current, 1000))

        // Scroll right toward w3 (target 2000); raise the cover, tick a few frames so it's mid-flight.
        (s, _) = Engine.reduce(s, .command(.focus(.right)))
        #expect(s.motion.viewportOffset.target == 2000)
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        #expect(s.motion.isCovered)
        for _ in 0..<6 { (s, _) = Engine.reduce(s, .tick(dt: 1.0 / 120)) }
        let vMid = s.motion.viewportOffset.velocity
        let cMid = s.motion.viewportOffset.current
        #expect(vMid != 0)
        #expect(cMid > 1000 && cMid < 2000)

        // INTERRUPT — focus back left to w2. A pure retarget: same session, velocity + position
        // untouched (that carry-through is what makes the reversal feel alive), reals re-teleported.
        let (i, ifx) = Engine.reduce(s, .command(.focus(.left)))
        #expect(i.world.focusedWindow == WindowId(2))
        #expect(ifx.contains(.focus(WindowId(2))))
        #expect(i.motion.isTransitioning)                        // still exactly one session
        #expect(i.motion.isCovered)                              // under the same, still-raised cover
        #expect(i.motion.viewportOffset.target == 1000)          // re-aimed at w2
        #expect(i.motion.viewportOffset.velocity == vMid)        // velocity carried through the interrupt
        #expect(i.motion.viewportOffset.current == cMid)         // a retarget never touches position
        #expect(Self.capturedIds(in: ifx).isEmpty)               // scope reused — no fresh captures
        #expect(Self.hasEffect(ifx) { if case .setFrame(WindowId(2), _) = $0 { return true }; return false })
        #expect(i.motion.transition?.awaitingLanding == Set([WindowId(2), WindowId(3)]))  // landings re-armed

        // Land + settle → the interrupted scroll comes to rest at w2 / offset 1000.
        let (done, _) = Self.drive(i)
        #expect(done.motion.isTransitioning == false)
        #expect(done.world.focusedWindow == WindowId(2))
        #expect(Self.approxScalar(done.motion.viewportOffset.current, 1000))
    }

    // MARK: - The cover has no holes, at any command rate (2026-07-26)

    /// ⅓ columns with the gaps a real config carries — the geometry both hole defects below were
    /// measured on. The gap is not incidental: minimal-reveal scrolling leaves the next column exactly
    /// one `columnGap` past the destination the session is already aiming at, which is what makes it
    /// enter the viewport almost immediately after a retarget rather than comfortably later.
    static let spamConfig = Config(columnGap: 8, windowGap: 8)

    /// A frame-stepped world with **latency** — the one thing `drive` cannot model. `drive` acks every
    /// capture synchronously, so a hole that exists only between a `capture` and its `captureReady` is
    /// invisible to it. Here an effect resolves a fixed number of frames after it is emitted, and
    /// commands keep arriving while the answers are still out.
    private struct LatentWorld {
        var state: State
        var frame = 0
        let captureLatency: Int
        let axLatency = 2
        var inbox: [Int: [Event]] = [:]

        init(_ state: State, captureLatency: Int) {
            self.state = state
            self.captureLatency = captureLatency
        }

        mutating func send(_ event: Event) {
            let (next, fx) = Engine.reduce(state, event)
            state = next
            for e in fx {
                switch e {
                case .capture(let w):
                    inbox[frame + captureLatency, default: []].append(.captureReady(w))
                case .setFrame(let w, _), .park(let w, _):
                    inbox[frame + axLatency, default: []].append(.axLanded(w))
                default: break
                }
            }
        }

        mutating func step() {
            for e in inbox.removeValue(forKey: frame) ?? [] { send(e) }
            send(.tick(dt: 1.0 / 120))
            frame += 1
        }

        /// The widest band of viewport a window wants to occupy and has no layer to be drawn with —
        /// i.e. how much wallpaper the cover is showing where a window should be. Zero unless the cover
        /// is up: before the raise the user is looking at the real desktop, which is the truth and not
        /// a hole.
        func hole() -> Double {
            guard state.motion.isCovered, let metrics = state.metrics() else { return 0 }
            let view = metrics.workingArea
            let frames = state.layout.naturalFrames(scrollOffset: state.motion.viewportOffset.current,
                                                    metrics: metrics,
                                                    widths: state.motion.currentColumnWidths)
            var worst = 0.0
            for id in state.layout.allWindowIds where state.motion.layerId(for: id) == nil {
                guard let natural = frames[id] else { continue }
                // Exactly the rect `Engine.emitLayerFrames` would blit, if this window had a layer.
                let f = natural.displaced(by: state.motion.displacement(of: id))
                worst = max(worst, min(min(f.maxX, view.maxX) - max(f.minX, view.minX), view.width))
            }
            return worst
        }
    }

    /// Settle a ten-column strip at one end, then hammer `command` and report the widest hole the
    /// cover ever showed.
    private static func worstHoleWhileSpamming(_ command: Command, settlingWith settle: Command,
                                               presses: Int, gapFrames: Int,
                                               captureLatency: Int) -> Double {
        var w = LatentWorld(booted(config: spamConfig), captureLatency: captureLatency)
        for i in 1...10 { w.send(.windowCreated(snapshot(UInt64(i)))) }
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

    /// **The invariant the whole scoping story exists to hold:** while the cover is up, every window
    /// the layers would draw inside the viewport has a layer to be drawn with. One that doesn't is a
    /// window-shaped patch of wallpaper sliding across the cover — the artifact M4 part 1 photographed
    /// and M4 part 2 closed for an *uninterrupted* transition, which is why it only ever showed when
    /// commands were spammed.
    ///
    /// Two independent latency defects broke it, and neither is reachable from a harness that acks
    /// instantly:
    ///
    ///  · **The late extension.** A retarget widens the scope correctly, but the stills it asks for
    ///    arrive after the layers have already crossed into the territory they cover. Fixed by
    ///    capturing a **shoulder** past each end of the sweep (`Layout.sweptWindowIds`), so the column
    ///    a further command can reach is already on the cover. Measured before: 130–140 pt of hole.
    ///  · **The starved extension.** Under a *stream* of interrupts there is always a capture
    ///    outstanding, so a session-wide `captureComplete` gate never opens again and the cover stops
    ///    growing at all. Fixed by asking the question per window
    ///    (`TransitionSession.unboundWindows`). Measured before: 600 pt — an entire column.
    ///
    /// The press rates bracket reality: 4 frames ≈ 33 ms is faster than a key repeat, 40 ≈ 333 ms is a
    /// full settle. The capture latencies bracket the measured extension batch (36 ms ≈ 4 frames) at
    /// 1× and 2×.
    ///
    /// **What is *not* claimed.** No fixed lookahead can be an absolute guarantee — a user can always
    /// press faster than pixels can be fetched — so the residual is characterized rather than hidden,
    /// by `theShoulderBuysAtLeastOneCommandIntervalOfRunway` below.
    @Test(arguments: [4, 6, 10, 20, 40] as [Int], [4, 8] as [Int])
    func theCoverNeverShowsAHoleHoweverFastTheCommandsArrive(gapFrames: Int, captureLatency: Int) {
        for (command, settle) in Self.spammableCommands {
            let worst = Self.worstHoleWhileSpamming(command, settlingWith: settle, presses: 8,
                                                    gapFrames: gapFrames, captureLatency: captureLatency)
            #expect(worst == 0, "\(command) at \(gapFrames)-frame intervals, \(captureLatency)-frame captures")
        }
    }

    /// **The shape of the residual, pinned.** A shoulder is one column of lookahead, so what it buys is
    /// bounded — and the bound is worth knowing rather than discovering. It divides the vocabulary in
    /// two, for a reason that is about *what the command does to the strip*:
    ///
    ///  · A **scroll** or a **resize** moves the viewport over a strip whose column order is fixed, so
    ///    the shoulder is the column that will arrive next, by construction. Holes are unreachable at
    ///    any capture latency — swept to 500 ms in development, which is past the capture plane's own
    ///    250 ms deadline, i.e. past the point where the batch stops being a race and starts being a
    ///    timeout.
    ///  · A **structural edit** re-orders the strip *and* scrolls it, so a column reaches the viewport
    ///    edge earlier in the travel than a plain scroll would bring it. The runway is then about one
    ///    command interval — measured as tolerating a capture of `interval + 1` frames, i.e. this test
    ///    asserts the honest floor. Against the real 36 ms batch that is ~2× headroom even at a press
    ///    rate faster than key repeat, and it degrades into a *narrower* hole rather than a cliff.
    @Test(arguments: [6, 10, 15, 20, 30] as [Int])
    func theShoulderBuysAtLeastOneCommandIntervalOfRunway(gapFrames: Int) {
        for (command, settle) in Self.spammableCommands {
            let worst = Self.worstHoleWhileSpamming(command, settlingWith: settle, presses: 8,
                                                    gapFrames: gapFrames, captureLatency: gapFrames)
            #expect(worst == 0, "\(command) at \(gapFrames)-frame intervals and captures")
        }
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

    // MARK: - The cover that grows (M4 part 2)

    /// **The hole, closed.** A session's scope is fixed when it opens, but an interrupting command
    /// retargets the scroll — and the new destination sweeps windows the original scope never named.
    /// Through M4 part 1 those windows slid into the viewport with *no layer at all*, and what showed
    /// through was the base: wallpaper where a window should be (`PRINCIPLES.md` §10). Now the retarget
    /// widens the scope, captures the newcomer, and the cover grows to include it — mid-flight, without
    /// re-raising anything.
    @Test func aRetargetSweepsInANewWindowCapturesItAndGrowsTheCover() {
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)), .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)), .windowCreated(Self.snapshot(4)),
        ])
        // Scroll w4 → w3 and get the cover up. Scope is the two columns the motion touches, plus w2 as
        // the shoulder past its left end (`Layout.sweptWindowIds`); w4 is the last column, so there is
        // no shoulder to its right.
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(s.motion.transition?.windows == [WindowId(2), WindowId(3), WindowId(4)])
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        #expect(s.motion.isCovered)
        for _ in 0..<4 { (s, _) = Engine.reduce(s, .tick(dt: 1.0 / 120)) }

        // INTERRUPT: aim at w2. The shoulder means its pixels are already on the cover — that is the
        // point of it — so what the widened scope newly names is w1, the *next* shoulder along.
        let (i, ifx) = Engine.reduce(s, .command(.focus(.left)))
        #expect(i.motion.isCovered)                              // still the same cover
        #expect(Self.capturedIds(in: ifx) == [WindowId(1)])      // …and it asked for the missing still
        #expect(i.motion.transition?.windows == [WindowId(2), WindowId(3), WindowId(4), WindowId(1)])
        #expect(i.motion.transition?.layerId(for: WindowId(2)) != nil)   // already covered: no hole
        #expect(i.motion.transition?.layerId(for: WindowId(1)) == nil)   // no layer until it lands

        // The still lands → the cover grows, and the new layer is placed in the same batch.
        let (g, gfx) = Engine.reduce(i, .captureReady(WindowId(1)))
        let added: [LayerBinding] = gfx.compactMap { if case .extendCover(let b) = $0 { return b }; return nil }
            .flatMap { $0 }
        #expect(added.count == 1)
        #expect(added.first?.window == WindowId(1))
        let layer = try! #require(g.motion.transition?.layerId(for: WindowId(1)))
        #expect(added.first?.layer == layer)
        // A fresh id, not one of the layers already on the cover.
        #expect(!(g.motion.transition?.bindings.dropLast().map(\.layer).contains(layer) ?? true))
        // Created *and* positioned inside one presentation run — never a frame at its capture position.
        #expect(Self.layerFrame(of: layer, in: gfx) != nil)

        // …and it still converges.
        let (done, _) = Self.drive(g)
        #expect(done.motion.isTransitioning == false)
        #expect(done.world.focusedWindow == WindowId(2))
        #expect(Self.approxScalar(done.motion.viewportOffset.current, 1000))
    }

    /// The same widening, before the cover is up. There is nothing to grow yet, so the newcomer simply
    /// joins the batch the raise is waiting on — and the cover is built with it included, in one piece.
    @Test func aRetargetBeforeTheRaiseJoinsTheBatchInsteadOfGrowingTheCover() {
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)), .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)), .windowCreated(Self.snapshot(4)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))       // opens the session; nothing captured
        let (i, ifx) = Engine.reduce(s, .command(.focus(.left))) // interrupt while still `.capturing`
        s = i

        #expect(Self.capturedIds(in: ifx) == [WindowId(1)])      // the next shoulder along
        #expect(!s.motion.isCovered)
        #expect(!Self.hasEffect(ifx) { if case .setFrame = $0 { return true }; return false })  // nothing moved yet

        var raiseFx: [Effect] = []
        for w in s.motion.transition?.windows ?? [] {
            let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; raiseFx += f
        }
        let bindings: [LayerBinding] = raiseFx
            .compactMap { if case .beginTransition(let b) = $0 { return b }; return nil }.flatMap { $0 }
        #expect(bindings.map(\.window) == [WindowId(2), WindowId(3), WindowId(4), WindowId(1)])
        #expect(!Self.hasEffect(raiseFx) { if case .extendCover = $0 { return true }; return false })
    }

    /// No pixels ⇒ no cover, never a black one. A head capture batch that comes back without a desktop
    /// base answers `coverUnavailable`, and the session is abandoned *before* anything has moved — the
    /// user gets §4a's instant, correct placement instead of a blacked-out display.
    @Test func coverUnavailableAbandonsTheSessionAndSnaps() {
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)), .windowCreated(Self.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(s.motion.isTransitioning)
        let target = s.motion.viewportOffset.target

        let (a, afx) = Engine.reduce(s, .coverUnavailable)
        #expect(a.motion.isTransitioning == false)               // no session, no cover, no ticks
        #expect(Self.approxScalar(a.motion.viewportOffset.current, target))   // snapped to the destination
        // …and every window is placed there at once, exactly as the no-grant path would have.
        #expect(Self.placement(of: WindowId(1), in: afx) != nil)
        #expect(!Self.hasEffect(afx) { if case .endTransition = $0 { return true }; return false })
    }

    /// Totality: the same event with a *raised* cover must not drop it — a cover that is up can only be
    /// taken down by the cross-fade. (It cannot happen — an extension batch owes no base — but the
    /// reducer is total over every event in every state by contract.)
    @Test func coverUnavailableNeverDropsARaisedCover() {
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)), .windowCreated(Self.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        #expect(s.motion.isCovered)

        let (a, afx) = Engine.reduce(s, .coverUnavailable)
        #expect(a.motion.isCovered)                              // untouched
        #expect(afx.isEmpty)
    }

    // MARK: - The animated resize (M4 part 3, §4d)

    /// **`cycleWidth`, end to end.** The first command whose motion is not a scroll: the strip's own
    /// geometry changes, so the viewport-offset scalar cannot express it and the column's *resolved
    /// width* goes under its own spring. Note what does **not** happen — the viewport never moves — and
    /// that a transition opens anyway. That is the difference from `scrollReveal`, where start == end
    /// means there is nothing to animate.
    ///
    /// Two ⅓-width columns on a 1000-wide display: 333⅓ each. Cycling col1 to ½ makes it 500 wide.
    @Test func cycleWidthOpensATransitionEvenThoughTheViewportNeverMoves() {
        var (s, _) = Self.run(Self.booted(), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),          // focused, column 1
        ])
        let column = s.layout.columns[1].id
        #expect(Self.approxScalar(s.layout.strip(metrics: s.metrics()!).columnWidths[1], 1000.0 / 3.0))

        let (c, cfx) = Engine.reduce(s, .command(.cycleWidth))
        s = c
        #expect(s.motion.isTransitioning)                          // …despite zero viewport motion
        #expect(s.motion.viewportOffset.target == 0)
        #expect(s.motion.viewportOffset.current == 0)
        #expect(s.layout.columns[1].widthPreset == 1)              // ⅓ → ½, stored immediately
        #expect(Set(Self.capturedIds(in: cfx)) == Set([WindowId(1), WindowId(2)]))
        // The width animator starts at the width being left behind, not the one being arrived at.
        #expect(Self.approxScalar(s.motion.columnWidth(column)?.current ?? 0, 1000.0 / 3.0))
        #expect(s.motion.columnWidth(column)?.target == 500)
        #expect(!s.motion.isSettled)                               // …and it holds the cover up

        // Raise: the *real* window is resized to its final width at once, behind the cover (§4d — only
        // the owning app can produce resized pixels, so there is nothing to animate on the truth plane).
        var fx: [Effect] = []
        for w in s.motion.transition?.windows ?? [] {
            let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; fx += f
        }
        #expect(s.motion.isCovered)
        #expect(Self.placement(of: WindowId(2), in: fx)?.width == 500)
        #expect(Self.placement(of: WindowId(1), in: fx) == nil)    // untouched: left of the resize
        #expect(s.motion.transition?.awaitingLanding == Set([WindowId(2)]))

        // …while the *layer* grows across frames — the scaled still §4d cross-fades over the reflow.
        let layer = try! #require(s.motion.transition?.layerId(for: WindowId(2)))
        var mid: [Effect] = []
        for _ in 0..<5 { let (n, f) = Engine.reduce(s, .tick(dt: 1.0 / 120)); s = n; mid += f }
        let growing = try! #require(Self.layerFrame(of: layer, in: mid))
        #expect(growing.width > 1000.0 / 3.0 + 1)
        #expect(growing.width < 500)
        #expect(growing.minX == 1000.0 / 3.0)                      // anchored at the column's left edge

        // Land + settle: the layer converges onto the real window's frame, then the cover comes down.
        let (done, dfx) = Self.drive(s)
        #expect(done.motion.isTransitioning == false)
        #expect(dfx.contains(.endTransition))
        #expect(done.motion.currentColumnWidths.isEmpty)           // the override is dropped, not kept
        #expect(done.layout.strip(metrics: done.metrics()!).columnWidths[1] == 500)
    }

    /// Every column to the right of a resize slides, and nothing choreographs that — it falls out of
    /// the strip accumulating the animated width. Three ⅓ columns; growing the *middle* one pushes the
    /// third along by exactly what the second gained.
    @Test func columnsRightOfAResizeSlideInLockstepWithIt() {
        var (s, _) = Self.run(Self.booted(), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(2)))      // focus the middle column, no scroll
        #expect(s.motion.isTransitioning == false)

        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        let l2 = try! #require(s.motion.transition?.layerId(for: WindowId(2)))
        let l3 = try! #require(s.motion.transition?.layerId(for: WindowId(3)))

        var fx: [Effect] = []
        for _ in 0..<5 { let (n, f) = Engine.reduce(s, .tick(dt: 1.0 / 120)); s = n; fx += f }
        let grown = try! #require(Self.layerFrame(of: l2, in: fx))
        let pushed = try! #require(Self.layerFrame(of: l3, in: fx))
        #expect(grown.width > 1000.0 / 3.0 + 1)                    // the middle column is mid-growth…
        #expect(grown.width < 500)
        // …and col2 starts where col1 ends, at every instant of the motion.
        #expect(Self.approxScalar(pushed.minX, grown.maxX))
        #expect(pushed.minX > 1000.0 * 2 / 3 + 1)                  // i.e. strictly past where it was
        #expect(pushed.width == 1000.0 / 3.0)                      // …at its own, unchanged width
    }

    /// **Why the scope is a union of two geometries.** A column can be on screen *before* the resize and
    /// swept by nothing *after* it — a growing neighbour pushes it off the right edge. Scoping on the new
    /// geometry alone would give it no captured layer, and it would slide out of view as a hole showing
    /// the wallpaper: M4 part 1's finding, arriving by a different route.
    ///
    /// ¼/full presets on a 1000-wide display. Four 250-wide columns all on screen at offset 0; cycling
    /// col1 to full (1000) makes it fill the viewport by itself and evicts cols 2 **and** 3 — two
    /// columns, deliberately, so that one of them lands outside the shoulder the sweep already carries
    /// (`Layout.sweptWindowIds`) and the two-geometry union is the only thing that can account for it.
    @Test func aResizeScopesTheColumnItPushesOffTheScreen() {
        let config = Config(widthPresets: PresetCycle([.proportion(0.25), .proportion(1.0)]))
        var (s, _) = Self.run(Self.booted(config: config), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
            .windowCreated(Self.snapshot(4)),
        ])
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(2)))
        #expect(Self.approxScalar(s.motion.viewportOffset.current, 0))
        #expect(s.layout.visibleWindowIds(scrollOffset: 0, metrics: s.metrics()!)
                == [WindowId(1), WindowId(2), WindowId(3), WindowId(4)])

        let (c, cfx) = Engine.reduce(s, .command(.cycleWidth))
        s = c
        // Under the *new* geometry the viewport holds col1 alone; the sweep and its shoulders reach
        // only as far as w3. w4 is scoped and captured purely because it was on screen under the *old*
        // geometry and has to be drawn on its way out.
        #expect(s.layout.sweptWindowIds(from: 0, to: s.motion.viewportOffset.target,
                                        metrics: s.metrics()!)
                == [WindowId(1), WindowId(2), WindowId(3)])
        #expect(s.motion.transition?.windows                                  // layout order = z-order
                == [WindowId(1), WindowId(2), WindowId(3), WindowId(4)])
        #expect(Self.capturedIds(in: cfx)
                == [WindowId(1), WindowId(2), WindowId(3), WindowId(4)])

        let (done, _) = Self.drive(s)
        #expect(done.motion.isTransitioning == false)
        #expect(done.layout.strip(metrics: done.metrics()!).columnWidths == [250, 1000, 250, 250])
    }

    /// A resize arriving mid-scroll joins the open session rather than opening a second one — the same
    /// rule every other interrupt follows, now with two different animated quantities in flight at once.
    @Test func aResizeMidScrollRidesTheOpenSession() {
        // Full-width columns so a focus change genuinely scrolls, and a second preset so there is
        // something to cycle to (`fullWidth` has one preset, i.e. nothing a resize could change).
        let config = Config(widthPresets: PresetCycle([.proportion(1.0), .proportion(0.5)]))
        var (s, _) = Self.run(Self.booted(config: config), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))         // scroll w3 → w2, offset 2000 → 1000
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        for _ in 0..<6 { (s, _) = Engine.reduce(s, .tick(dt: 1.0 / 120)) }
        let scrolling = s.motion.viewportOffset.velocity
        #expect(scrolling != 0)
        #expect(s.motion.currentColumnWidths.isEmpty)              // a scroll animates no widths

        let (r, _) = Engine.reduce(s, .command(.cycleWidth))
        #expect(r.motion.isTransitioning)                          // still exactly one session…
        #expect(r.motion.isCovered)                                // …under the same raised cover
        #expect(r.motion.viewportOffset.velocity == scrolling)     // the scroll is undisturbed
        #expect(r.motion.currentColumnWidths.count == 1)           // …and now a width travels with it

        let (done, _) = Self.drive(r)
        #expect(done.motion.isTransitioning == false)
        #expect(done.motion.currentColumnWidths.isEmpty)
    }

    /// §4a for a machine with no Screen Recording grant: the resize still happens, at once. What must
    /// survive the degradation is the *placement* — the column ends up exactly the width the animated
    /// path would have converged on.
    @Test func withoutSmoothTransitionsAResizeHappensAtOnce() {
        var config = Config()
        config.smoothTransitions = false
        var (s, _) = Self.run(Self.booted(config: config), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        let (c, cfx) = Engine.reduce(s, .command(.cycleWidth))
        s = c
        #expect(!s.motion.isTransitioning)
        #expect(s.motion.currentColumnWidths.isEmpty)
        #expect(!Self.hasEffect(cfx) { if case .capture = $0 { return true }; return false })
        #expect(Self.placement(of: WindowId(2), in: cfx)?.width == 500)
    }

    // MARK: - The continuous resize (`grow` / `shrink`)

    /// A snapping world with one preset, so a column's width is only ever what `grow`/`shrink` made it.
    /// Snapping because these tests are about *what width the column ends up*, not how it gets there —
    /// the motion is `cycleWidth`'s, already covered above.
    static func oneThirdSnap() -> State {
        let config = Config(widthPresets: PresetCycle([.proportion(1.0 / 3.0)]),
                            smoothTransitions: false)
        return Self.run(Self.booted(config: config),
                        [.windowCreated(Self.snapshot(1))]).0
    }

    /// The column's resolved width right now.
    static func width(_ s: State, _ index: Int = 0) -> Double {
        s.layout.resolvedWidth(of: s.layout.columns[index], metrics: s.metrics()!)
    }

    /// `grow` is `cycleWidth`'s motion with a different arithmetic in front of it: the same second
    /// animated quantity, the same transition opened over a viewport that never moves, the same real
    /// window resized to its final width behind the cover.
    @Test func growAnimatesTheColumnWidthExactlyAsACycleDoes() {
        var (s, _) = Self.run(Self.booted(), [.windowCreated(Self.snapshot(1))])
        let column = s.layout.columns[0].id

        let (g, gfx) = Engine.reduce(s, .command(.grow(.points(100))))
        s = g
        #expect(s.motion.isTransitioning)                       // …despite zero viewport motion
        #expect(s.motion.viewportOffset.target == 0)
        #expect(Self.approxScalar(s.motion.columnWidth(column)?.current ?? 0, Self.third))
        #expect(Self.approxScalar(s.motion.columnWidth(column)?.target ?? 0, Self.third + 100))
        #expect(Self.capturedIds(in: gfx) == [WindowId(1)])

        let (done, dfx) = Self.drive(s)
        #expect(dfx.contains(.endTransition))
        #expect(Self.approxScalar(Self.placement(of: WindowId(1), in: dfx)?.width ?? 0,
                                  Self.third + 100))
        #expect(Self.approxScalar(Self.width(done), Self.third + 100))
        #expect(done.motion.currentColumnWidths.isEmpty)        // the override is dropped, not kept
    }

    /// **A percentage is of the working area, not of the current width** (2026-07-26). The consequence
    /// is the reason: steps are uniform however wide the column already is, and the two verbs are exact
    /// inverses. Under the compounding reading each step here would differ and the round trip would
    /// land 1% short of where it began.
    @Test func aPercentageIsOfTheWorkingAreaSoTheStepsAreUniformAndTheVerbsInvert() {
        var s = Self.oneThirdSnap()                             // 1000-wide working area ⇒ 10% = 100 pt
        let start = Self.width(s)

        for step in 1...3 {
            (s, _) = Engine.reduce(s, .command(.grow(.percent(10))))
            #expect(Self.approxScalar(Self.width(s), start + 100 * Double(step)),
                    "step \(step): \(Self.width(s))")
        }
        for step in stride(from: 2, through: 0, by: -1) {
            (s, _) = Engine.reduce(s, .command(.shrink(.percent(10))))
            #expect(Self.approxScalar(Self.width(s), start + 100 * Double(step)))
        }
        #expect(Self.approxScalar(Self.width(s), start))         // …back exactly, not 1% short
    }

    /// The unit the user typed is the unit that is stored, which is what makes a percentage track the
    /// monitor the way a preset does while points stay points (`ColumnLayout.widthOverride`).
    @Test func theStoredIntentKeepsTheUnitItWasAskedIn() throws {
        var s = Self.oneThirdSnap()
        (s, _) = Engine.reduce(s, .command(.grow(.percent(10))))
        guard case .proportion(let share) = try #require(s.layout.columns[0].widthOverride) else {
            Issue.record("a percentage stored something other than a proportion"); return
        }
        #expect(Self.approxScalar(share, Self.third / 1000 + 0.1, tol: 1e-9))

        (s, _) = Engine.reduce(s, .command(.grow(.points(100))))
        guard case .fixed(let points) = try #require(s.layout.columns[0].widthOverride) else {
            Issue.record("points stored something other than a fixed width"); return
        }
        #expect(Self.approxScalar(points, Self.third + 200))
    }

    /// Bounded above by 100% of the working area, and a `grow` that has nothing left to give is silent —
    /// no transition, no AX set, not even a redundant re-place.
    @Test func growIsBoundedByTheWorkingWidth() {
        var s = Self.oneThirdSnap()
        (s, _) = Engine.reduce(s, .command(.grow(.percent(500))))
        #expect(Self.width(s) == 1000)

        let (again, fx) = Engine.reduce(s, .command(.grow(.points(100))))
        #expect(Self.width(again) == 1000)
        #expect(fx.isEmpty)
        #expect(!again.motion.isTransitioning)
    }

    /// Bounded below by `minimumColumnWidth` — the backstop for apps that accept any size at all, where
    /// there is no `SizeCorrection` to discover a real floor from.
    @Test func shrinkIsBoundedByAMinimumWidth() {
        var s = Self.oneThirdSnap()
        (s, _) = Engine.reduce(s, .command(.shrink(.points(1000))))
        #expect(Self.width(s) == Engine.minimumColumnWidth)

        let (again, fx) = Engine.reduce(s, .command(.shrink(.percent(1))))
        #expect(Self.width(again) == Engine.minimumColumnWidth)
        #expect(fx.isEmpty)
        // …and the way back out is immediate: a clamp that stopped the resize stored nothing to undo.
        let (grown, _) = Engine.reduce(again, .command(.grow(.points(50))))
        #expect(Self.width(grown) == Engine.minimumColumnWidth + 50)
    }

    /// **The clamp can stop a resize; it may never reverse one.** A config that deliberately asks for
    /// columns wider than the screen (`width-presets = [1.5]`) is honored by `Presets`, so a `grow` that
    /// clamped to the working width would answer "wider, please" with a sudden 500 pt *shrink*.
    @Test func aClampNeverMovesAColumnTheWayItWasNotAsked() {
        let config = Config(widthPresets: PresetCycle([.proportion(1.5)]), smoothTransitions: false)
        var s = Self.run(Self.booted(config: config), [.windowCreated(Self.snapshot(1))]).0
        #expect(Self.width(s) == 1500)

        let (grown, fx) = Engine.reduce(s, .command(.grow(.points(100))))
        #expect(Self.width(grown) == 1500)                       // stopped…
        #expect(fx.isEmpty)                                      // …and silent about it
        (s, _) = Engine.reduce(s, .command(.shrink(.points(100))))
        #expect(Self.width(s) == 1400)                           // …while the other way still moves
    }

    /// **A failed shrink stops at the app's own floor, and converges there.** The user's "known minimum
    /// dimensions": we never learn a minimum (2026-07-26 — there is no public attribute for one), we
    /// only remember what the app answered to the question we asked. Taking each delta from the
    /// *resolved* width rather than the stored intent is what makes that a fixed point instead of a dead
    /// zone — by the second press the question repeats, the recorded answer applies, and the command
    /// goes quiet.
    @Test func aRefusedShrinkSettlesAtTheAppsFloorAndGrowStillMovesAtOnce() {
        var s = Self.oneThirdSnap()                              // 333⅓
        /// The app under test: it will not go below 300 pt wide.
        func refuseBelow300(_ s: inout State, _ fx: [Effect]) {
            guard let asked = Self.placement(of: WindowId(1), in: fx), asked.width < 300 else { return }
            var landed = asked
            landed.size = Size(width: 300, height: asked.height)
            (s, _) = Engine.reduce(s, .placementCorrected(WindowId(1), requested: asked, actual: landed))
        }

        var (next, fx) = Engine.reduce(s, .command(.shrink(.points(100))))   // asks 233⅓
        s = next
        refuseBelow300(&s, fx)
        #expect(Self.width(s) == 300)                            // the column is built around the answer

        (next, fx) = Engine.reduce(s, .command(.shrink(.points(100))))       // from 300, asks 200
        s = next
        refuseBelow300(&s, fx)
        #expect(Self.width(s) == 300)

        // Third press: 300 − 100 is the question already answered, so nothing is asked and nothing moves.
        (next, fx) = Engine.reduce(s, .command(.shrink(.points(100))))
        s = next
        #expect(fx.isEmpty)
        #expect(!s.motion.isTransitioning)
        #expect(Self.width(s) == 300)

        // …and growing out of the floor works on the first press — no dead zone to walk back through.
        (s, _) = Engine.reduce(s, .command(.grow(.points(100))))
        #expect(Self.width(s) == 400)
    }

    /// The ladder and the continuous knob are alternatives, and `cycle-width` is how you get back on the
    /// ladder: it clears the override and takes the next rung after wherever the ladder was left — not a
    /// guess at which rung the grown width was nearest.
    @Test func cycleWidthClearsAGrowAndResumesTheLadder() {
        let config = Config(smoothTransitions: false)            // ⅓ / ½ / ⅔
        var s = Self.run(Self.booted(config: config), [.windowCreated(Self.snapshot(1))]).0

        (s, _) = Engine.reduce(s, .command(.grow(.points(200))))
        #expect(s.layout.columns[0].widthOverride != nil)
        #expect(Self.approxScalar(Self.width(s), Self.third + 200))

        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        #expect(s.layout.columns[0].widthOverride == nil)
        #expect(s.layout.columns[0].widthPreset == 1)            // ⅓ → ½, from where the ladder was
        #expect(Self.width(s) == 500)
    }

    /// An expelled window keeps the width it is on screen at, override included — otherwise a grown
    /// column would silently snap back to its ladder rung as a side effect of a structural edit.
    @Test func anExpelledWindowCarriesItsGrownWidthIntoItsNewColumn() {
        let config = Config(smoothTransitions: false)
        var s = Self.run(Self.booted(config: config), [.windowCreated(Self.snapshot(1))]).0
        (s, _) = Engine.reduce(s, .command(.grow(.points(200))))
        (s, _) = Engine.reduce(s, .windowCreated(Self.snapshot(2)))
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // w2 joins w1's column
        #expect(s.layout.columns.count == 1)

        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.right)))  // …and pops back out
        #expect(s.layout.columns.count == 2)
        #expect(s.layout.columns.allSatisfy { $0.widthOverride == .fixed(Self.third + 200) })
    }

    /// Total against a world with nothing to resize, like every other command.
    @Test func growAndShrinkWithNothingFocusedAreSilent() {
        for command in [Command.grow(.points(100)), .shrink(.percent(10))] {
            let (s, fx) = Engine.reduce(Self.booted(), .command(command))
            #expect(fx.isEmpty)
            #expect(s.layout.isEmpty)
        }
    }


    /// **The reported sequence, in full** (2026-07-26). A window that will not grow, at the right-hand
    /// end of a strip: `grow`, `focus` away and back, `grow`, `shrink`, `grow`, `grow`. What was
    /// observed was phantom desktop tacked onto the side after every `grow` — surviving until the next
    /// command, which snapped it away with no animation.
    ///
    /// The column was never the problem: it collapsed back to 333⅓ each time, correctly. The **viewport**
    /// did not. Every scroll target derives from the same column widths a correction changes, so a
    /// session that keeps the destination it was given is travelling to a place computed for a strip
    /// that no longer exists — measured here at **316 against a strip whose end is 16**, i.e. 300 pt of
    /// bare desktop. Two animated quantities over one geometry, and only one of them was being corrected.
    ///
    /// The invariant this pins is the general one, not the six steps: **after any command settles, the
    /// viewport is inside the strip it describes.**
    @Test func aRefusedResizeNeverLeavesTheViewportPastTheStripsEnd() {
        let config = Config(widthPresets: PresetCycle([.proportion(1.0 / 3.0)]), columnGap: 8)
        var (s, _) = Self.run(Self.booted(config: config), [
            .windowCreated(Self.snapshot(1)), .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Self.drive(s)

        /// The stubborn app: w3 answers ⅓ of the working width to every question, in either direction.
        func refuse(_ fx: [Effect]) {
            guard let asked = Self.placement(of: WindowId(3), in: fx),
                  abs(asked.width - Self.third) > 0.5 else { return }
            var landed = asked
            landed.size = Size(width: Self.third, height: asked.height)
            (s, _) = Engine.reduce(s, .placementCorrected(WindowId(3), requested: asked, actual: landed))
        }

        for command: Command in [.grow(.points(300)), .focus(.left), .focus(.right),
                                 .grow(.points(300)), .shrink(.points(100)),
                                 .grow(.points(300)), .grow(.points(300))] {
            var (next, fx) = Engine.reduce(s, .command(command))
            s = next
            for w in s.motion.transition?.windows ?? [] {
                (next, fx) = Engine.reduce(s, .captureReady(w))
                s = next
            }
            refuse(fx)
            (s, _) = Self.drive(s)

            let metrics = s.metrics()!
            let offset = s.motion.viewportOffset.current
            let end = s.layout.clampScrollOffset(offset, metrics: metrics)
            #expect(Self.approxScalar(offset, end),
                    "after \(command): viewport at \(offset), strip ends at \(end)")
            // …and the column is always the width the window will actually be, never the one it refused.
            #expect(Self.approxScalar(Self.width(s, 2), Self.third), "after \(command)")
        }
    }

    // MARK: - Fullscreen (the strip's, not the system's)

    /// **The whole feature, as it was asked for:** a column at 40% goes to 100% and comes back to 40%.
    /// Exactly 40% — because `isFullscreen` shadows the width intent instead of replacing it, so there
    /// is nothing stored to restore and nothing to round.
    @Test func fullscreenTogglesBetweenTheColumnsOwnWidthAndTheFullStripWidth() {
        var s = Self.oneThirdSnap()                              // 1000-wide content area
        (s, _) = Engine.reduce(s, .command(.grow(.points(400.0 - Self.third))))
        #expect(Self.approxScalar(Self.width(s), 400))           // …a 40% column

        (s, _) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        #expect(s.layout.columns[0].isFullscreen)
        #expect(Self.width(s) == 1000)

        (s, _) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        #expect(!s.layout.columns[0].isFullscreen)
        #expect(Self.approxScalar(Self.width(s), 400))           // back exactly, not near it
    }

    /// The same round trip from a **ladder rung**, which is the case a saved point count would have to
    /// get right and this one doesn't have to think about: the preset is never touched, so a config
    /// reload or a display change under a fullscreen column still uncovers the right width.
    @Test func fullscreenUncoversALadderRungEvenAfterThePresetsChange() {
        let config = Config(smoothTransitions: false)             // ⅓ / ½ / ⅔ of 1000
        var s = Self.run(Self.booted(config: config), [.windowCreated(Self.snapshot(1))]).0
        (s, _) = Engine.reduce(s, .command(.cycleWidth))          // ⅓ → ½
        #expect(Self.width(s) == 500)

        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        #expect(Self.width(s) == 1000)

        // The presets change *while* the column is fullscreen. It stays full-width…
        let rewritten = Config(widthPresets: PresetCycle([.proportion(0.25), .proportion(0.75)]),
                               smoothTransitions: false)
        (s, _) = Engine.reduce(s, .configChanged(rewritten))
        #expect(Self.width(s) == 1000)
        // …and uncovers the rung it was on, resolved against the *new* ladder. A stored 500 would have
        // been a number about a config that no longer exists.
        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
        #expect(Self.width(s) == 750)                             // index 1, now ¾
    }

    /// `fullscreen` is `cycleWidth`'s motion with a different intent in front of it — the same second
    /// animated quantity, the same transition over a viewport that need not move, the same real window
    /// teleported to its final width behind the cover. Nothing downstream learned a new concept.
    @Test func fullscreenAnimatesTheColumnWidthExactlyAsACycleDoes() {
        var (s, _) = Self.run(Self.booted(), [.windowCreated(Self.snapshot(1))])
        let column = s.layout.columns[0].id

        let (f, ffx) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        s = f
        #expect(s.motion.isTransitioning)
        #expect(Self.approxScalar(s.motion.columnWidth(column)?.current ?? 0, Self.third))
        #expect(Self.approxScalar(s.motion.columnWidth(column)?.target ?? 0, 1000))
        #expect(Self.capturedIds(in: ffx) == [WindowId(1)])

        let (done, dfx) = Self.drive(s)
        #expect(dfx.contains(.endTransition))
        #expect(Self.approxScalar(Self.placement(of: WindowId(1), in: dfx)?.width ?? 0, 1000))
        #expect(Self.width(done) == 1000)
        #expect(done.motion.currentColumnWidths.isEmpty)
    }

    /// **The strip is still the strip.** Nothing is hidden and no Space is created: the neighbouring
    /// column is simply pushed out of the viewport and parks at its sliver, exactly as it would for a
    /// `grow` to the ceiling — and scrolls back in when fullscreen comes off.
    ///
    /// With a `columnGap`, deliberately: gapless, the revealed column's left edge lands exactly on the
    /// departing one's right edge and which side of "visible" that falls on is decided by the last bit
    /// of a `Double` (`Strip.visibleColumnIndices` is a strict overlap, and ⅓ of 1000 doesn't round).
    /// That degeneracy is not what this test is about, and no real config has it.
    @Test func fullscreenPushesTheNeighbouringColumnOffTheViewportAndBack() {
        let config = Config(columnGap: 8, smoothTransitions: false)
        var s = Self.run(Self.booted(config: config), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),                     // focused, column 1
        ]).0

        let (full, ffx) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        s = full
        #expect(Self.hasEffect(ffx) { if case .park(WindowId(1), _) = $0 { return true }; return false })
        #expect(Self.width(s, 1) == 1000)

        let (back, bfx) = Engine.reduce(s, .command(.fullscreen(.toggle)))
        #expect(Self.hasEffect(bfx) { if case .setFrame(WindowId(1), _) = $0 { return true }; return false })
        #expect(Self.approxScalar(Self.width(back, 1), Self.third))
    }

    /// An explicit width verb clears fullscreen, and the press that clears it is **continuous**: the
    /// delta comes off the *resolved* width, which while fullscreen is the full width. Without the
    /// clear, `shrink` here would write a number nothing can show — a dead knob.
    @Test func anExplicitWidthVerbClearsFullscreenAndActsAtOnce() {
        var s = Self.oneThirdSnap()
        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        #expect(Self.width(s) == 1000)

        (s, _) = Engine.reduce(s, .command(.shrink(.percent(10))))
        #expect(!s.layout.columns[0].isFullscreen)
        #expect(Self.width(s) == 900)                             // 100% − 10%, on the first press

        // …and the ladder resumes the same way it does after a `grow`, with no nearest-rung guess.
        let laddered = Config(smoothTransitions: false)           // ⅓ / ½ / ⅔
        var t = Self.run(Self.booted(config: laddered), [.windowCreated(Self.snapshot(1))]).0
        (t, _) = Engine.reduce(t, .command(.fullscreen(.on)))
        (t, _) = Engine.reduce(t, .command(.cycleWidth))
        #expect(!t.layout.columns[0].isFullscreen)
        #expect(t.layout.columns[0].widthPreset == 1)             // ⅓ → ½, from where the ladder was
        #expect(Self.width(t) == 500)
    }

    /// A column already at the full width has nothing to animate, so the command is silent — but the
    /// *state* still moved, which is what makes the next press restore rather than do nothing twice.
    @Test func fullscreenOnAnAlreadyFullWidthColumnIsSilentAndStillToggles() {
        let config = Config(widthPresets: PresetCycle([.proportion(1.0)]), smoothTransitions: false)
        var s = Self.run(Self.booted(config: config), [.windowCreated(Self.snapshot(1))]).0
        #expect(Self.width(s) == 1000)

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
        var s = Self.oneThirdSnap()
        for _ in 0..<2 {
            (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
            #expect(s.layout.columns[0].isFullscreen)
        }
        for _ in 0..<2 {
            (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
            #expect(!s.layout.columns[0].isFullscreen)
        }
    }

    /// **A window that refuses to *grow* must stop being asked, exactly as one that refuses to shrink
    /// does.** Reported from use (2026-07-26): fullscreen System Settings — which is 723 pt wide and
    /// will not be anything else — and it stretches, snaps back, and then **stretches and snaps back
    /// again on every subsequent `focus left`/`right`**.
    ///
    /// The record was never the problem: `SizeCorrection` is symmetric and had `{wanted: full, actual:
    /// 723}` on file throughout. What was asymmetric is who *consumes* it. A refused **shrink** answers
    /// wider, so `Layout.resolvedWidth` widens the column and the target simply becomes the answer —
    /// geometry quiets it, robustly. A refused **grow** answers narrower, geometry deliberately does not
    /// follow (an under-filled column is a cosmetic gap), so quieting it rested entirely on
    /// `isAlreadyPlaced` — which requires the **position** to match too. A scroll moves the window, so
    /// the diff legitimately re-emits, and the rect it re-emitted carried the *aspirational* width. We
    /// knew the answer and asked the question anyway, once per scroll, forever.
    @Test func aWindowThatRefusedToGrowIsNotAskedAgainOnEveryScroll() {
        let config = Config(widthPresets: PresetCycle([.proportion(1.0 / 3.0)]),
                            columnGap: 8, smoothTransitions: false)
        var s = Self.run(Self.booted(config: config), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ]).0
        (s, _) = Engine.reduce(s, .command(.focus(.left)))        // focus w1, the stubborn one

        // Fullscreen it: the column goes to 1000, and the app answers 400 and will not budge.
        var (next, fx) = Engine.reduce(s, .command(.fullscreen(.on)))
        s = next
        let asked = try! #require(Self.placement(of: WindowId(1), in: fx))
        #expect(asked.width == 1000)
        var landed = asked
        landed.size = Size(width: 400, height: asked.height)
        (s, _) = Engine.reduce(s, .placementCorrected(WindowId(1), requested: asked, actual: landed))

        // The column follows the answer down — no phantom 600 pt of strip nobody can fill…
        #expect(Self.width(s, 0) == 400)
        // …and the window is therefore asked for the width it actually gives, at every offset the strip
        // reaches. This is the assertion the bug fails: before the fix, each scroll re-asked for 1000.
        for direction in [Direction.right, .left, .right] {
            (next, fx) = Engine.reduce(s, .command(.focus(direction)))
            s = next
            if let re = Self.placement(of: WindowId(1), in: fx) {
                #expect(re.width == 400, "focus \(direction) re-asked for \(re.width)")
            }
        }
    }

    /// **The half the user actually watches, and the reason the fix belongs in the width and not at the
    /// write.** The real window never grew — what stretched was the *cover's layer*, and the "snap
    /// back" was the cross-fade retiring it over a window that had always been 400.
    ///
    /// Because the refusal now reaches the column's resolved width, and that width is already an
    /// animated quantity, the layer **springs back** rather than being clamped: it expands toward 1000,
    /// the answer lands, and it settles onto 400 continuously. That collapse is the feedback — "it said
    /// no" — and the continuity is what distinguishes it from the one-frame jump a clamp produces.
    @Test func aRefusedGrowSpringsTheLayerBackInsteadOfJumping() throws {
        let config = Config(widthPresets: PresetCycle([.proportion(1.0 / 3.0)]), columnGap: 8)
        var (s, _) = Self.run(Self.booted(config: config), [.windowCreated(Self.snapshot(1))])
        (s, _) = Self.drive(s)                                   // settle the arrival

        // Fullscreen opens a transition; the cover raises and the real is teleported to 1000…
        var (next, fx) = Engine.reduce(s, .command(.fullscreen(.on)))
        s = next
        (next, fx) = Engine.reduce(s, .captureReady(WindowId(1)))
        s = next
        let layer = try #require(s.motion.transition?.bindings.first?.layer)
        let asked = try #require(Self.placement(of: WindowId(1), in: fx))
        #expect(asked.width == 1000)

        // …the layer is on its way out to 1000…
        var widths: [Double] = []
        for _ in 0..<8 {
            (next, fx) = Engine.reduce(s, .tick(dt: 1.0 / 120))
            s = next
            if let f = Self.layerFrame(of: layer, in: fx) { widths.append(f.width) }
        }
        #expect(widths.last! > Self.third + 1)                   // genuinely stretching

        // …and then the app answers 400, under the raised cover.
        var landed = asked
        landed.size = Size(width: 400, height: asked.height)
        (s, _) = Engine.reduce(s, .placementCorrected(WindowId(1), requested: asked, actual: landed))

        widths = []
        for _ in 0..<600 {
            (next, fx) = Engine.reduce(s, .tick(dt: 1.0 / 120))
            s = next
            if let f = Self.layerFrame(of: layer, in: fx) { widths.append(f.width) }
            if !s.motion.isTransitioning { break }
        }
        // It collapses to what the window is…
        #expect(Self.approxScalar(widths.last!, 400))
        // …and gets there continuously, which is the property that separates this fix from the patch
        // it replaced. The layer peaks near 739 and settles on 400; a clamp shows up as a single
        // frame-to-frame step of ~340 pt, a spring at 120 fps as ~29. The bound sits between them with
        // room on both sides rather than hugging the measurement.
        let biggestStep = zip(widths, widths.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(biggestStep < 100, "layer jumped \(biggestStep) pt in one frame")
    }

    /// Total against a world with nothing to fullscreen, like every other command.
    @Test func fullscreenWithNothingFocusedIsSilent() {
        for toggle in [Toggle.on, .off, .toggle] {
            let (s, fx) = Engine.reduce(Self.booted(), .command(.fullscreen(toggle)))
            #expect(fx.isEmpty)
            #expect(s.layout.isEmpty)
        }
    }

    @Test func cyclingWidthWrapsBackToTheFirstPreset() {
        var (s, _) = Self.run(Self.booted(), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        for expected in [1, 2, 0] {                                // ⅓ → ½ → ⅔ → ⅓
            (s, _) = Engine.reduce(s, .command(.cycleWidth))
            (s, _) = Self.drive(s)
            #expect(s.layout.columns[1].widthPreset == expected)
        }
        #expect(Self.approxScalar(s.layout.strip(metrics: s.metrics()!).columnWidths[1], 1000.0 / 3.0))
    }

    /// Totality: nothing focused, no display, and a cycle that resolves to the same width are all
    /// silent — never a transition that cannot close.
    @Test func aResizeThatChangesNothingIsSilent() {
        // A single-preset cycle: the index advances (wrapping onto itself) and no geometry moves.
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        let (c, cfx) = Engine.reduce(s, .command(.cycleWidth))
        #expect(!c.motion.isTransitioning)
        #expect(cfx.isEmpty)

        // Nothing focused at all.
        s = Self.booted()
        let (empty, efx) = Engine.reduce(s, .command(.cycleWidth))
        #expect(!empty.motion.isTransitioning)
        #expect(efx.isEmpty)
    }

    @Test func layerFramesFollowNaturalPositionsWhileRealsPark() {
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))       // scroll w3 → w2
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        #expect(s.motion.isCovered)

        // w3's *real* window is parked (a corner sliver, off-screen left); its reconstruction *layer*
        // rides the natural, un-parked position (sliding off the *right* edge). The two disagree by
        // design — that's what makes a scrolled-off window glide off-screen instead of jumping to a
        // sliver. Assert every layer frame equals the natural frame, and w3's layer ≠ its parked real.
        let realW3 = s.world.windows[WindowId(3)]!.frame
        let (t, tfx) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        let metrics = t.metrics()!
        let natural = t.layout.naturalFrames(scrollOffset: t.motion.viewportOffset.current, metrics: metrics)
        for binding in t.motion.transition?.bindings ?? [] {
            let lf = Self.layerFrame(of: binding.layer, in: tfx)
            #expect(lf != nil)
            #expect(Self.approx(lf!, natural[binding.window]!))
        }
        let w3layer = t.motion.transition!.layerId(for: WindowId(3))!
        #expect(!Self.approx(Self.layerFrame(of: w3layer, in: tfx)!, realW3))
    }

    @Test func holdTimeoutForceClosesTheTransition() {
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        #expect(s.motion.isCovered)
        // Never land the reals — the ~1 s hold-timeout closes the cover regardless (§3).
        let (done, fx) = Engine.reduce(s, .holdTimeout)
        #expect(done.motion.isTransitioning == false)
        #expect(fx == [.endTransition])
        // Snapped to the target so resting truth matches the reveal, even though we bailed mid-flight.
        #expect(done.motion.viewportOffset.current == done.motion.viewportOffset.target)
        #expect(Self.approxScalar(done.motion.viewportOffset.current, 1000))
    }

    @Test func axFailedDoesNotWedgeTheTransition() {
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        let awaiting = Array(s.motion.transition?.awaitingLanding ?? [])
        #expect(awaiting.count == 2)
        (s, _) = Engine.reduce(s, .axFailed(awaiting[0]))        // one real never makes it…
        (s, _) = Engine.reduce(s, .axLanded(awaiting[1]))        // …the other lands
        // The failure resolved its landing (no forever-wait on a stuck window), so settling closes it —
        // without the hold-timeout backstop, which we never fire here.
        let (done, _) = Self.drive(s)
        #expect(done.motion.isTransitioning == false)
    }

    @Test func midTransitionStateRoundTripsThroughCodable() throws {
        // A live session (cover raised, mid-animation) must serialize — replay + `emira debug` (§7).
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(s.motion.isTransitioning)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(State.self, from: data)
        #expect(back == s)
    }

    // MARK: - Windows that refuse the size we ask for

    /// Two ⅓ columns on a 1000-wide display: 333⅓ each, at x = 0 and x = 333⅓. `third` is that width.
    static let third = 1000.0 / 3.0

    /// A state with two tiled windows, both already placed at their targets.
    static func twoColumns() -> State {
        Self.run(Self.booted(), [.windowCreated(Self.snapshot(1)),
                                 .windowCreated(Self.snapshot(2))]).0
    }

    @Test func aClampedTiledLandingWidensItsColumnAndPushesTheNeighbourAlong() {
        // The case the whole slice exists for. w1's app refuses 333⅓ and takes 500; without a record
        // of that, `Layout` keeps col1 at 333⅓ and the two real windows *overlap* by 167 pt — the one
        // thing the strip promises never happens.
        var s = Self.twoColumns()
        let asked = Rect(x: 0, y: 0, width: Self.third, height: 800)
        let got = Rect(x: 0, y: 0, width: 500, height: 800)

        let (next, fx) = Engine.reduce(s, .placementCorrected(WindowId(1), requested: asked, actual: got))
        s = next

        // The answer is recorded against the question it answers.
        let correction = try! #require(s.world.corrections[WindowId(1)])
        #expect(correction.actual == Size(width: 500, height: 800))
        #expect(Self.approxScalar(correction.wanted.width, Self.third))
        // …and the column is now built around it.
        #expect(s.layout.resolvedWidth(ofColumn: s.layout.columns[0].id, metrics: s.metrics()!) == 500)
        // w1 is already at the answer, so nothing is asked of it again; w2 slides right by the 167 pt
        // w1 took, which is derived — the strip accumulates from the same widths.
        #expect(Self.placement(of: WindowId(1), in: fx) == nil)
        let moved = try! #require(Self.placement(of: WindowId(2), in: fx))
        #expect(Self.approx(moved, Rect(x: 500, y: 0, width: Self.third, height: 800)))
    }

    @Test func aCorrectedWindowIsNeverAskedTheSameQuestionAgain() {
        // The convergence claim, as a test: one round of writes, then silence. Before this record
        // existed, `World.frame` held the clamped rect while the target held the preset, so the diff
        // never matched and *every* subsequent placement re-issued the same doomed set, forever.
        var s = Self.twoColumns()
        (s, _) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: Self.third, height: 800),
            actual: Rect(x: 0, y: 0, width: 500, height: 800)))

        let (_, again) = Engine.reduce(s, .dragEnded)      // any re-place trigger
        #expect(again.isEmpty)
    }

    @Test func aNarrowerAnswerNarrowsTheColumnToWhatTheWindowCanBe() {
        // **Corrected 2026-07-26.** This asserted the opposite — the column kept its preset and
        // quiescence was the placement diff's job — on the grounds that an under-filled column is "a
        // gap, which is cosmetic". It is not: a column's width is strip extent, so the shortfall is
        // desktop that scroll targets, tile-vs-park and the sweep all treat as content. The column now
        // follows the answer down, and quiescence comes free because the target *is* what the window is.
        var s = Self.twoColumns()
        let narrow = Rect(x: 0, y: 0, width: Self.third - 8, height: 800)
        let (next, _) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: Self.third, height: 800), actual: narrow))
        s = next

        let width = try! #require(s.layout.resolvedWidth(ofColumn: s.layout.columns[0].id,
                                                         metrics: s.metrics()!))
        #expect(Self.approxScalar(width, Self.third - 8))              // …to what it can be
        let (_, again) = Engine.reduce(s, .dragEnded)
        #expect(Self.placement(of: WindowId(1), in: again) == nil)     // and goes quiet
    }

    /// **The recursion guard** — a narrower answer teaches only when it answered the *question*.
    /// Because the column now follows an answer down, the next request is the answer rather than the
    /// question; an app that always returns a little less would otherwise walk the column toward
    /// nothing, one placement at a time. At most one narrowing per question.
    @Test func anAppThatAlwaysReturnsLessCannotWalkTheColumnDown() {
        var s = Self.twoColumns()
        let question = Self.third

        // First refusal, given to the question itself: learned, and the column follows.
        (s, _) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: question, height: 800),
            actual: Rect(x: 0, y: 0, width: question - 8, height: 800)))
        #expect(Self.approxScalar(Self.width(s), question - 8))

        // Every later refusal answers a request we made *because* of the first one, so it teaches
        // nothing — the column holds, rather than stepping down 8 pt per event forever.
        for step in 1...5 {
            (s, _) = Engine.reduce(s, .placementCorrected(
                WindowId(1), requested: Rect(x: 0, y: 0, width: question - 8, height: 800),
                actual: Rect(x: 0, y: 0, width: question - 8 - Double(step) * 8, height: 800)))
            #expect(Self.approxScalar(Self.width(s), question - 8), "step \(step)")
        }

        // …while the *widening* direction keeps learning unconditionally, because too wide overlaps a
        // neighbour and that is the invariant the strip promises.
        (s, _) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: question - 8, height: 800),
            actual: Rect(x: 0, y: 0, width: 500, height: 800)))
        #expect(Self.approxScalar(Self.width(s), 500))
    }

    @Test func aReportThatAnswersAQuestionNobodyIsAskingRecordsTruthAndTeachesNothing() {
        // The write went out and the layout moved on before the ack came back. Recording this would
        // key an answer to a question that was never asked, which is exactly how a learned minimum
        // ratchets. Truth is still recorded — it is where the window is.
        var s = Self.twoColumns()
        let stale = Rect(x: 0, y: 0, width: 220, height: 800)      // nothing on this strip wants 200
        let (next, fx) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: 200, height: 800), actual: stale))
        s = next

        #expect(fx.isEmpty)
        #expect(s.world.corrections.isEmpty)
        #expect(s.world.windows[WindowId(1)]?.frame == stale)      // …but reality is reality
    }

    @Test func positionOnlyDriftIsNotAFactAboutSize() {
        // A window that went somewhere else at the size we asked is telling us about *position*.
        // That is a real and separate problem (the 1 px park sliver is one) and it never overlaps a
        // neighbour, so nothing about the column's geometry follows from it.
        var s = Self.twoColumns()
        let asked = Rect(x: 0, y: 0, width: Self.third, height: 800)
        let elsewhere = Rect(x: 0, y: 40, width: Self.third, height: 800)
        let (next, _) = Engine.reduce(s, .placementCorrected(WindowId(1), requested: asked, actual: elsewhere))
        s = next

        #expect(s.world.corrections.isEmpty)
        #expect(s.world.windows[WindowId(1)]?.frame == elsewhere)
    }

    @Test func externalDriftNeverBecomesAConstraint() {
        // `windowFrameChanged` is the user dragging, and a *parked* landing (`AXExecutor` splits them
        // deliberately). Neither knows what question it answers, so neither may teach.
        var s = Self.twoColumns()
        (s, _) = Engine.reduce(s, .windowFrameChanged(WindowId(1), Rect(x: 700, y: 500, width: 60, height: 60)))
        #expect(s.world.corrections.isEmpty)
    }

    @Test func aCorrectionIsForgottenWithItsWindow() {
        var s = Self.twoColumns()
        (s, _) = Engine.reduce(s, .placementCorrected(
            WindowId(1), requested: Rect(x: 0, y: 0, width: Self.third, height: 800),
            actual: Rect(x: 0, y: 0, width: 500, height: 800)))
        #expect(s.world.corrections.count == 1)

        (s, _) = Engine.reduce(s, .windowDestroyed(WindowId(1)))
        #expect(s.world.corrections.isEmpty)   // a stale answer must not greet the next window to reuse
    }

    @Test func aCorrectionUnderARaisedCoverSpringsTheColumnRatherThanJumpingIt() {
        // Every layer frame is re-derived from the strip's geometry each tick, so a column that
        // changes width between two frames *jumps*. Under a cover the change goes under the resize
        // spring — the same quantity `cycleWidth` animates, retargeted in place.
        var s = Self.twoColumns()
        var fx: [Effect] = []
        (s, _) = Engine.reduce(s, .command(.cycleWidth))          // col1 (focused, w2): ⅓ → ½ = 500
        let column = s.layout.columns[1].id
        #expect(s.motion.columnWidth(column)?.target == 500)

        for w in s.motion.transition?.windows ?? [] {
            let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; fx += f
        }
        #expect(s.motion.isCovered)

        // The app takes 600 instead of the 500 it was just teleported to.
        let (next, _) = Engine.reduce(s, .placementCorrected(
            WindowId(2), requested: Rect(x: Self.third, y: 0, width: 500, height: 800),
            actual: Rect(x: Self.third, y: 0, width: 600, height: 800)))
        s = next

        // Retargeted, not restarted: the layer keeps travelling from wherever it had got to.
        #expect(s.motion.columnWidth(column)?.target == 600)
        #expect(!s.motion.isSettled)

        // …and it converges on the width the real window actually took, so the cross-fade has nothing
        // to pop against.
        let (done, _) = Self.drive(s)
        #expect(!done.motion.isTransitioning)
        #expect(done.layout.strip(metrics: done.metrics()!).columnWidths[1] == 600)
    }

    @Test func cycleWidthAnimatesFromTheCorrectedWidthNotThePreset() {
        // A column an app has already widened *is* at the corrected width, so starting the spring at
        // the raw preset would begin the motion somewhere the layers are not — a visible jump on the
        // first frame of every resize of a stubborn window.
        var s = Self.twoColumns()
        (s, _) = Engine.reduce(s, .placementCorrected(
            WindowId(2), requested: Rect(x: Self.third, y: 0, width: Self.third, height: 800),
            actual: Rect(x: Self.third, y: 0, width: 400, height: 800)))
        let column = s.layout.columns[1].id
        #expect(s.layout.resolvedWidth(ofColumn: column, metrics: s.metrics()!) == 400)

        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        #expect(s.motion.columnWidth(column)?.current == 400)    // where it actually is…
        #expect(s.motion.columnWidth(column)?.target == 500)     // …to the ½ preset, a fresh question
    }

    @Test func aTallerAnswerFloorsTheWindowInItsColumnAndTheStackmateRedivides() {
        // The vertical axis, reachable through `consume-or-expel`: two windows in one column are each
        // asked for half its height, and an app that refuses gets its floor while its stackmate takes
        // what is left.
        var s = Self.run(Self.booted(config: Self.halfWidthSnap),
                         [.windowCreated(Self.snapshot(1)), .windowCreated(Self.snapshot(2))]).0
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // w2 joins w1's column
        #expect(s.layout.columns.count == 1)

        let asked = try! #require(s.layout.targetFrames(scrollOffset: 0, metrics: s.metrics()!)[WindowId(2)])
        #expect(asked.height == 400)                                  // 800 split two ways, no gaps
        var taller = asked
        taller.size.height = 500
        (s, _) = Engine.reduce(s, .placementCorrected(WindowId(2), requested: asked, actual: taller))

        let frames = s.layout.targetFrames(scrollOffset: 0, metrics: s.metrics()!)
        #expect(frames[WindowId(1)]?.height == 300)                   // the stackmate re-divides…
        #expect(frames[WindowId(2)]?.height == 500)                   // …around the floor
        #expect(s.layout.resolvedWidth(ofColumn: s.layout.columns[0].id, metrics: s.metrics()!) == 500)
    }

    // MARK: - Structural edits (move-window / consume-or-expel — the strip rearranged)
    //
    // `halfWidth`/`halfWidthSnap` throughout: two 500-wide columns fill the 1000-wide viewport exactly,
    // so nothing parks and nothing scrolls, and every frame is clean arithmetic on (0|500, 0, 500, 800)
    // — or, for a two-window column, its 400-tall halves. The tests that assert *where a window lands*
    // use the snapping fixture, because under the animated path the reals teleport at the cover's raise
    // rather than in the command's own batch; the motion itself is the subject of the section after.

    /// Two windows side by side; `w2` is focused and alone in its column, so a sideways move takes the
    /// whole column with it. Focus is already on the window that moved, so no `.focus` is owed.
    @Test func moveWindowLeftSwapsAColumnWithItsNeighbourAndKeepsFocus() {
        let (s, _) = Self.run(Self.booted(config: Self.halfWidthSnap), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),          // focused, column 1
        ])
        let (n, fx) = Engine.reduce(s, .command(.moveWindow(.left)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(2)], [WindowId(1)]])
        #expect(n.world.focusedWindow == WindowId(2))
        #expect(Self.approx(Self.placement(of: WindowId(2), in: fx) ?? .zero,
                            Rect(x: 0, y: 0, width: 500, height: 800)))
        #expect(Self.approx(Self.placement(of: WindowId(1), in: fx) ?? .zero,
                            Rect(x: 500, y: 0, width: 500, height: 800)))
        #expect(!fx.contains(.focus(WindowId(2))))     // focus never left; a redundant AX set can raise
        #expect(!fx.contains(.raise(WindowId(2))))     // tiled windows in a column don't overlap
    }

    @Test func moveWindowRightAtTheRightEdgeIsANoOp() {
        let (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),          // focused, already rightmost
        ])
        let (n, fx) = Engine.reduce(s, .command(.moveWindow(.right)))
        #expect(fx.isEmpty)
        #expect(n == s)
    }

    @Test func moveWindowLeftAtTheLeftEdgeIsANoOp() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1)))   // leftmost column
        let (n, fx) = Engine.reduce(s, .command(.moveWindow(.left)))
        #expect(fx.isEmpty)
        #expect(n == s)
    }

    /// The other half of the horizontal rule: with stackmates the *window* leaves rather than the
    /// column moving. Note the column it lands in is a fresh one — a consume followed by an expel
    /// restores the arrangement, not the identity.
    @Test func aStackedWindowMovedSidewaysPopsOutIntoItsOwnColumn() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        let original = s.layout.columns[1].id                   // w2's column, about to be merged away
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(s.layout.columns.map(\.windowIds) == [[WindowId(1), WindowId(2)]])

        let (n, _) = Engine.reduce(s, .command(.moveWindow(.right)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(1)], [WindowId(2)]])
        #expect(n.layout.columns[1].id != original)
    }

    @Test func moveWindowDownSwapsItWithTheWindowBelowItInTheStack() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidthSnap), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // → one column [w1, w2]
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1)))         // focus the top of the stack

        let (n, fx) = Engine.reduce(s, .command(.moveWindow(.down)))
        #expect(n.layout.columns[0].windowIds == [WindowId(2), WindowId(1)])
        // Two auto windows split the 800-tall area: rows at y 0 and y 400, now swapped.
        #expect(Self.approx(Self.placement(of: WindowId(2), in: fx) ?? .zero,
                            Rect(x: 0, y: 0, width: 500, height: 400)))
        #expect(Self.approx(Self.placement(of: WindowId(1), in: fx) ?? .zero,
                            Rect(x: 0, y: 400, width: 500, height: 400)))
    }

    @Test func moveWindowUpAtTheTopOfTheStackIsANoOp() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1)))         // already row 0
        let (n, fx) = Engine.reduce(s, .command(.moveWindow(.up)))
        #expect(fx.isEmpty)
        #expect(n == s)
    }

    @Test func consumeLeftMergesALoneWindowIntoTheBottomOfTheColumnOnItsLeft() {
        let (s, _) = Self.run(Self.booted(config: Self.halfWidthSnap), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),          // focused, alone in column 1
        ])
        let (n, fx) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(n.layout.columns.count == 1)
        #expect(n.layout.columns[0].windowIds == [WindowId(1), WindowId(2)])   // landed at the bottom
        #expect(n.world.focusedWindow == WindowId(2))
        #expect(Self.approx(Self.placement(of: WindowId(1), in: fx) ?? .zero,
                            Rect(x: 0, y: 0, width: 500, height: 400)))
        #expect(Self.approx(Self.placement(of: WindowId(2), in: fx) ?? .zero,
                            Rect(x: 0, y: 400, width: 500, height: 400)))
    }

    @Test func consumeRightMergesALoneWindowIntoTheTopOfTheColumnOnItsRight() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        let rightColumn = s.layout.columns[1].id
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1)))         // the lone window on the left

        let (n, _) = Engine.reduce(s, .command(.consumeOrExpel(.right)))
        #expect(n.layout.columns.count == 1)
        #expect(n.layout.columns[0].windowIds == [WindowId(1), WindowId(2)])   // landed at the top
        #expect(n.layout.columns[0].id == rightColumn)                 // the survivor is the target
    }

    @Test func expelPushesAStackedWindowOutIntoANewColumnOnThatSide() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // → [[w1, w2]], w2 focused
        let (n, _) = Engine.reduce(s, .command(.consumeOrExpel(.right)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(1)], [WindowId(2)]])
    }

    /// The property that makes "adjacent in layout order" one rule rather than two conventions:
    /// consuming left then expelling right puts the strip back exactly as it was.
    @Test func consumeAndExpelAreEachOthersInverse() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        let arrangement = s.layout.columns.map(\.windowIds)
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.right)))
        #expect(s.layout.columns.map(\.windowIds) == arrangement)
        #expect(Self.approxScalar(s.motion.viewportOffset.current, 0))
    }

    /// `down` consumes and `up` expels — the vertical axis is not one idea with two ends here, which
    /// is why the handler switches on the direction rather than on `direction.axis`. The *pulled*
    /// window moves, not the focused one, so focus is untouched and no `.focus` is owed.
    @Test func consumeDownPullsTheTopOfTheNextColumnIntoTheBottomOfThisOne() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1)))
        let (n, fx) = Engine.reduce(s, .command(.consumeOrExpel(.down)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(1), WindowId(2)], [WindowId(3)]])
        #expect(n.world.focusedWindow == WindowId(1))
        #expect(!fx.contains(.focus(WindowId(1))))
    }

    @Test func consumeUpPushesTheFocusedWindowOutIntoItsOwnColumnOnTheRight() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // → [[w1, w2]]
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1)))
        let (n, _) = Engine.reduce(s, .command(.consumeOrExpel(.up)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(2)], [WindowId(1)]])
    }

    @Test func consumeUpOnAWindowAlreadyAloneInItsColumnIsANoOp() {
        let (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        let (n, fx) = Engine.reduce(s, .command(.consumeOrExpel(.up)))
        #expect(fx.isEmpty)
        #expect(n == s)                                // catches a destroy-and-remint of the column
    }

    @Test func consumeWithNoColumnOnThatSideIsANoOp() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),          // focused, rightmost
        ])
        let (right, rfx) = Engine.reduce(s, .command(.consumeOrExpel(.right)))
        #expect(rfx.isEmpty)
        #expect(right == s)

        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1)))         // leftmost
        let (left, lfx) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(lfx.isEmpty)
        #expect(left == s)
    }

    @Test func consumeDownWithNoColumnToTheRightIsANoOp() {
        let (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),          // focused, rightmost
        ])
        let (n, fx) = Engine.reduce(s, .command(.consumeOrExpel(.down)))
        #expect(fx.isEmpty)
        #expect(n == s)
    }

    /// The strip has an **origin, not an edge**, and the two verbs disagree about it on purpose: a
    /// *consume* with no neighbour is a no-op because there is nothing to merge into, while an *expel*
    /// at the same place still creates its column — index 0 is an ordinary position on an unbounded
    /// axis, and every other column simply shifts right.
    @Test func expellingAtTheStripOriginStillCreatesTheColumn() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))   // → one column at index 0
        let (n, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(2)], [WindowId(1)]])
    }

    // MARK: Structural edits — totality and absences

    @Test func structuralCommandsWithNothingFocusedAreSilent() {
        let s = Self.booted()
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
        let (s, _) = Self.run(State(), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        var reconciled = s.layout
        reconciled.reconcile(stripWindowIds: s.world.stripWindowIds)
        for command in Self.structuralCommands {
            let (n, fx) = Engine.reduce(s, .command(command))
            #expect(fx.isEmpty, "\(command)")
            #expect(n.layout == reconciled, "\(command)")
        }
    }

    @Test func structuralCommandsAreSilentForAWindowNotOnTheStrip() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2, role: .dialog)),   // never joins the strip
        ])
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(2)))  // …but can still hold focus
        for command in Self.structuralCommands {
            let (n, fx) = Engine.reduce(s, .command(command))
            #expect(fx.isEmpty, "\(command)")
            #expect(n == s, "\(command)")
        }
    }

    /// **The inverse of what this file pinned before the animated slice.** Every structural command
    /// that actually rearranges the strip now opens a transition and captures its scope, and does so
    /// under `halfWidth` — where two columns fill the viewport exactly and the reveal offset does not
    /// move at all. That is the case `scrollReveal` would snap on (`end ≈ start`) and the one a
    /// structural edit most needs animated: a swap in full view is *entirely* structural motion.
    @Test func aStructuralEditOpensATransitionEvenWhenTheViewportNeverMoves() {
        let (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        for command in [Command.moveWindow(.left), .consumeOrExpel(.left)] {
            let (n, fx) = Engine.reduce(s, .command(command))
            #expect(n.motion.isTransitioning, "\(command)")
            #expect(!Self.capturedIds(in: fx).isEmpty, "\(command)")
            #expect(!n.motion.windowAnimators.isEmpty, "\(command)")
            // Nothing has moved on the truth plane yet: the reals wait for the cover.
            #expect(!Self.hasEffect(fx) { if case .setFrame = $0 { return true }; return false },
                    "\(command)")
            #expect(Self.approxScalar(n.motion.viewportOffset.target,
                                      s.motion.viewportOffset.current), "\(command)")
        }
    }

    /// The §4a floor, and the reason the placement tests above can keep asserting what they assert: a
    /// machine with no Screen Recording grant rearranges instantly and correctly, with no cover, no
    /// captures and no displacement animators — across every one of the twelve command cases.
    @Test func withoutSmoothTransitionsAStructuralEditSnaps() {
        let (s, _) = Self.run(Self.booted(config: Self.halfWidthSnap), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        for command in Self.structuralCommands {
            let (n, fx) = Engine.reduce(s, .command(command))
            #expect(!n.motion.isTransitioning, "\(command)")
            #expect(Self.capturedIds(in: fx).isEmpty, "\(command)")
            #expect(n.motion.windowAnimators.isEmpty, "\(command)")
        }
    }

    /// **The property everything else rests on.** The very first frame under the cover must reproduce
    /// the layout the user was looking at — `natural(after) + displacement(0) == natural(before)` on
    /// every window, exactly. If it doesn't, the raise pops: the shell gives each layer its
    /// *capture-time* frame and emits no blit until the next tick, so a first frame that disagrees is
    /// a visible jump at the moment the cover goes up.
    ///
    /// A consume is the edit to prove it with, because it changes heights as well as positions — so
    /// this also pins that the displacement carries a **size**, not just a translation.
    @Test func theFirstFrameOfAStructuralEditReproducesTheOldLayoutExactly() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        let metrics = try! #require(s.metrics())
        let before = s.layout.naturalFrames(scrollOffset: s.motion.viewportOffset.current,
                                            metrics: metrics)

        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        var fx: [Effect] = []
        for w in s.motion.transition?.windows ?? [] {
            let (n, f) = Engine.reduce(s, .captureReady(w)); s = n; fx += f
        }
        #expect(s.motion.isCovered)

        // The raise emits no blit, so the first frame is the next tick's — with dt small enough that
        // the springs have not meaningfully moved.
        let (ticked, tickFx) = Engine.reduce(s, .tick(dt: 1e-6))
        _ = ticked
        for effect in tickFx {
            guard case .setLayerFrame(let layer, let rect) = effect else { continue }
            let window = try! #require(s.motion.transition?.bindings.first { $0.layer == layer }?.window)
            let was = try! #require(before[window])
            #expect(Self.approx(rect, was), "layer for \(window) popped at the raise")
        }
    }

    /// The swap, and the thing the user actually asked for: the two columns cross, and the window the
    /// command moved is drawn **over** the one it trades places with. Z-order is binding order at the
    /// raise, so the mover being last in `windows` is not enough on its own — the core says it out
    /// loud, because after an `extendCover` the shell's stacking is create-order and nothing else can
    /// put it back on top.
    @Test func aSwapDrawsTheMovedWindowOverTheOneItTradesPlacesWith() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),          // focused, alone in column 1
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

    /// **Growing the cover buries the mover, so the elevation has to be re-stated.** `extendCover`
    /// appends its layers on top — the shell's stacking is create-order and it has no `insertSublayer`
    /// — so a window that merely scrolled into scope would end up drawn over the window the user is
    /// moving. The re-elevation rides in the same contiguous presentation run as the addition, i.e.
    /// the same `CATransaction`, so the wrong order is never composited even once.
    ///
    /// Five columns rather than three, so the strip is long enough that a scroll can still reach past
    /// the shoulder the sweep already carries and produce a genuine newcomer to be buried by.
    @Test func growingTheCoverReElevatesTheMoverOverTheNewcomer() {
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
            .windowCreated(Self.snapshot(4)),
            .windowCreated(Self.snapshot(5)),          // focused, rightmost
        ])
        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        #expect(s.motion.isCovered)
        let scoped = Set(s.motion.transition?.windows ?? [])

        // A scroll mid-edit aims somewhere the session was not scoped for, pulling in a newcomer.
        var fx: [Effect] = []
        (s, fx) = Engine.reduce(s, .command(.focus(.left)))
        let newcomers = Self.capturedIds(in: fx).filter { !scoped.contains($0) }
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
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        // w2 was at x = 500 and now belongs at 0, so it lags to the *right*; w1 the other way.
        #expect(s.motion.displacement(of: WindowId(2)).minX == 500)
        #expect(s.motion.displacement(of: WindowId(1)).minX == -500)

        let (done, dfx) = Self.drive(s)
        #expect(dfx.contains(.endTransition))
        #expect(done.motion.windowAnimators.isEmpty)
        #expect(!done.motion.isTransitioning)
    }

    /// The other half of the request: a consume must show the *stackmate* making room, not just the
    /// mover flying in. `w1` goes from filling its column to half of it, and the cover has to show
    /// that happening rather than jumping.
    @Test func aConsumeAnimatesTheStackmateHeightToMakeRoom() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(s.motion.displacement(of: WindowId(1)).height == 400)   // 800 was, 400 belongs

        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        let (mid, midFx) = Engine.reduce(s, .tick(dt: 0.08))
        let layer = try! #require(mid.motion.layerId(for: WindowId(1)))
        let frame = try! #require(Self.layerFrame(of: layer, in: midFx))
        #expect(frame.height < 800 && frame.height > 400)               // genuinely mid-contraction
    }

    /// A structural edit mid-scroll adds **only** the structural delta: the offset keeps travelling on
    /// its own spring and the displacement decays on its, and the emitted frame is their sum. Three
    /// orthogonal quantities is the claim; this is the test of it.
    @Test func aStructuralEditMidScrollComposesWithTheRunningOffset() {
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .tick(dt: 0.05))
        let travelling = s.motion.viewportOffset.current
        #expect(!s.motion.isSettled)

        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        #expect(s.motion.isCovered)                       // one session, never a second
        #expect(!s.motion.windowAnimators.isEmpty)
        // The scroll was not disturbed by the edit — position and velocity are exactly where the
        // spring left them.
        #expect(s.motion.viewportOffset.current == travelling)

        let (done, dfx) = Self.drive(s)
        #expect(dfx.contains(.endTransition))
        #expect(done.motion.windowAnimators.isEmpty)
    }

    /// The double press. A second edit lands mid-flight, and the layer must not jump: the displacement
    /// is *nudged* by the new layout delta rather than rebuilt, so the emitted frame before and after
    /// the second command agree to within a point.
    @Test func aSecondEditMidFlightIsPositionContinuous() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(3)))
        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        var tickFx: [Effect] = []
        (s, tickFx) = Engine.reduce(s, .tick(dt: 0.05))

        let layer = try! #require(s.motion.layerId(for: WindowId(3)))
        let before = try! #require(Self.layerFrame(of: layer, in: tickFx))
        #expect(s.motion.windowAnimator(WindowId(3))?.x.velocity != 0)   // genuinely mid-flight

        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        let (_, afterFx) = Engine.reduce(s, .tick(dt: 1e-6))
        let after = try! #require(Self.layerFrame(of: layer, in: afterFx))
        #expect(abs(after.minX - before.minX) < 1.0, "the layer jumped: \(before) → \(after)")
        #expect(s.motion.windowAnimator(WindowId(3))?.x.velocity != 0)   // and kept its speed
    }

    /// The movement spring is a knob of its own, and it is the one a structural edit uses — mirrors
    /// `aResizeUsesTheResizeSpring`.
    @Test func aStructuralEditUsesTheMovementSpring() {
        var config = Self.halfWidth
        config.moveSpring = .snappy
        let (s, _) = Self.run(Self.booted(config: config), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        let (n, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        #expect(n.motion.windowAnimator(WindowId(2))?.x.params == SpringParams.snappy)
    }

    /// A window can be closed while its displacement is still travelling. `Layout` drops it, so the
    /// animator is measuring a lag against nothing — and `isSettled` is the transition's close gate.
    @Test func destroyingAWindowMidTransitionRetiresItsDisplacement() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        (s, _) = Engine.reduce(s, .command(.moveWindow(.left)))
        #expect(s.motion.windowAnimator(WindowId(2)) != nil)

        (s, _) = Engine.reduce(s, .windowDestroyed(WindowId(2)))
        #expect(s.motion.windowAnimator(WindowId(2)) == nil)
    }

    /// Every handler reconciles at its top, so an arrangement the bridge undoes is a command that does
    /// nothing at all — and it would look perfectly correct in the single-command test above.
    @Test func aStructuralMoveSurvivesTheReconcileAtTheTopOfTheNextCommand() {
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
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
        var (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
            .windowCreated(Self.snapshot(4)),
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

    /// A *consume* can merge a column away while its width is still in flight. `Layout` drops the
    /// column; the animator keyed on its id would otherwise survive until the session closed, holding
    /// the settle gate for a motion nobody can see. The subject here is that entry's absence — without
    /// the retirement the transition still closes, because an orphan settles on its own.
    @Test func aConsumeThatDestroysAColumnRetiresItsWidthAnimator() {
        var (s, _) = Self.run(Self.booted(), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),          // focused, column 1
        ])
        let doomed = s.layout.columns[1].id
        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        #expect(s.motion.columnWidth(doomed) != nil)   // in flight, cover up

        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(s.layout.columnIndex(withId: doomed) == nil)
        #expect(s.motion.columnWidth(doomed) == nil)
        #expect(s.motion.currentColumnWidths.isEmpty)

        let (done, dfx) = Self.drive(s)
        #expect(!done.motion.isTransitioning)
        #expect(dfx.contains(.endTransition))
        #expect(done.layout.columns.count == 1)
    }

    /// `reveal` is transition-safe but cannot know the *structure* changed, and a raised cover holds
    /// real windows teleported into a layout that no longer exists. So an edit under a cover re-places
    /// the reals rather than snapping — and joins the running session instead of opening a second one.
    ///
    /// A *consume* is the edit to test it with. A column swap under `fullWidth` would emit nothing, and
    /// rightly so: the focused column sits flush at the viewport's left edge before and after, so the
    /// diff says no real window needs to move. Merging two columns genuinely relocates all three —
    /// `w1` from its park sliver into the top half, `w2` down into the bottom half.
    @Test func aStructuralEditMidTransitionRidesTheOpenSessionAndRePlacesTheReals() {
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))     // → w2, an animated scroll
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        #expect(s.motion.isCovered)

        let (n, fx) = Engine.reduce(s, .command(.consumeOrExpel(.left)))
        #expect(n.layout.columns.map(\.windowIds) == [[WindowId(1), WindowId(2)], [WindowId(3)]])
        #expect(n.motion.isCovered)                    // one session throughout, never a second
        #expect(!Self.hasEffect(fx) { if case .beginTransition = $0 { return true }; return false })
        // …and the invariant that matters holds: every window the edit puts on screen is in the
        // cover's scope. The edit relocates `w1` from its park sliver into the top half of a column
        // that is now on screen, and a window sliding into view with no captured layer is the hole
        // that showed wallpaper in M4 part 1. Riding `driveTransition` is what closed it — whether a
        // given window arrives via this widening or via the shoulder the original sweep already
        // carried (`Layout.sweptWindowIds`) is an implementation detail of *when* it was captured.
        let scoped = Set(n.motion.transition?.windows ?? [])
        #expect(scoped.contains(WindowId(1)))
        #expect(scoped.isSuperset(of: n.layout.visibleWindowIds(
            scrollOffset: n.motion.viewportOffset.target, metrics: n.metrics()!)))
        // The reals teleported into the *new* structure behind the still-raised cover.
        #expect(Self.approx(Self.placement(of: WindowId(1), in: fx) ?? .zero,
                            Rect(x: 0, y: 0, width: 1000, height: 400)))
        #expect(Self.approx(Self.placement(of: WindowId(2), in: fx) ?? .zero,
                            Rect(x: 0, y: 400, width: 1000, height: 400)))

        let (done, dfx) = Self.drive(n)
        #expect(!done.motion.isTransitioning)
        #expect(dfx.contains(.endTransition))
    }

    // MARK: - The config file reaching the running daemon (M5 part 1)

    /// The observable effect of editing the file: the strip is re-resolved against the new metrics
    /// and every window re-placed, with no window having moved and no command having been given.
    @Test func aConfigReloadRelaysOutInPlace() {
        // Quarter-width columns, so both stay on screen and the gap is the only thing that moves.
        let narrow = Config(widthPresets: PresetCycle([.proportion(0.25)]))
        let (s, _) = Self.run(Self.booted(config: narrow), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
        ])
        var gapped = narrow
        gapped.columnGap = 40
        let (next, fx) = Engine.reduce(s, .configChanged(gapped))
        #expect(next.config.columnGap == 40)
        #expect(Self.approx(Self.placement(of: WindowId(2), in: fx) ?? .zero,
                            Rect(x: 290, y: 0, width: 250, height: 800)))
        // The first column's target didn't change, so it isn't re-sent: a reload re-places only what
        // the new geometry actually moved, and touching an app over AX is never free (§5).
        #expect(Self.placement(of: WindowId(1), in: fx) == nil)
        #expect(Self.approx(next.world.windows[WindowId(1)]?.frame ?? .zero,
                            Rect(x: 0, y: 0, width: 250, height: 800)))
    }

    /// The spring is *seeded* into the animator at construction, so storing the new config isn't
    /// enough — a file that only changed the feel would otherwise take effect at the next daemon
    /// start rather than the next scroll.
    @Test func aConfigReloadRetunesTheLiveScrollSpring() {
        let s = Self.booted()
        var slower = Config()
        slower.scrollSpring = SpringParams(stiffness: 100, dampingRatio: 1.0)
        let (next, _) = Engine.reduce(s, .configChanged(slower))
        #expect(next.motion.viewportOffset.params.stiffness == 100)
    }

    /// A reload mid-scroll must not snap the viewport out from under a raised cover — the same rule
    /// `reveal` already keeps for every other snap-path event.
    @Test func aConfigReloadMidTransitionRedirectsRatherThanSnapping() {
        var (s, _) = Self.run(Self.booted(config: Self.fullWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        (s, _) = Engine.reduce(s, .command(.focus(.left)))
        for w in s.motion.transition?.windows ?? [] { (s, _) = Engine.reduce(s, .captureReady(w)) }
        (s, _) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(s.motion.isTransitioning)
        let mid = s.motion.viewportOffset.current

        var gapped = Self.fullWidth
        gapped.columnGap = 12
        let (after, _) = Engine.reduce(s, .configChanged(gapped))
        // Still one session, still travelling from where it was — not teleported to the new target.
        #expect(after.motion.isTransitioning)
        #expect(after.motion.viewportOffset.current == mid)
    }

    /// `reload-config` is an `Effect`, not a router special-case, so it reaches the shell from any
    /// surface — a keybinding never touches the socket the way `emira reload-config` does.
    @Test func theReloadCommandAsksTheShellToReadTheFile() {
        let (s, fx) = Engine.reduce(Self.booted(), .command(.reloadConfig))
        #expect(fx == [.reloadConfig])
        #expect(s == Self.booted())              // the core changes nothing by itself
    }

    /// `cycleWidth` animates the *resize* spring, which exists so it can differ from the scroll's.
    @Test func aResizeUsesTheResizeSpring() {
        var config = Config(widthPresets: PresetCycle([.proportion(0.5), .proportion(1.0)]))
        config.resizeSpring = SpringParams(stiffness: 123, dampingRatio: 1.0)
        var (s, _) = Self.run(Self.booted(config: config), [.windowCreated(Self.snapshot(1))])
        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        let column = s.layout.columns.first!.id
        #expect(s.motion.columnWidth(column)?.params.stiffness == 123)
    }

    // MARK: - Replay / serialization (§7)

    @Test func stateRoundTripsThroughCodable() throws {
        let (s, _) = Self.run(Self.booted(config: Self.halfWidth), [
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .windowCreated(Self.snapshot(3)),
        ])
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(State.self, from: data)
        #expect(back == s)
    }

    @Test func replayingAnEventLogReproducesStateExactly() {
        // The deterministic-replay payoff (§7): the same event log through a fresh Engine → same state.
        let events: [Event] = [
            .screensChanged([MonitorInfo(id: MonitorId(1), frame: Self.displayFrame)]),
            .windowCreated(Self.snapshot(1)),
            .windowCreated(Self.snapshot(2)),
            .command(.focus(.left)),
            .windowCreated(Self.snapshot(3)),
            // Structural edits mint `ColumnId`s, so replay only reproduces if the allocator watermark
            // is state rather than a fresh count — which is exactly what §7 promises.
            .command(.consumeOrExpel(.left)),
            .command(.moveWindow(.right)),
            .windowDestroyed(WindowId(2)),
            .command(.centerColumn),
        ]
        let (a, fxA) = Self.run(State(), events)
        let (b, fxB) = Self.run(State(), events)
        #expect(a == b)
        #expect(fxA == fxB)
    }
}

/// Outer gaps at the reducer (2026-07-26). `Layout` owns the geometry and `OuterGapTests` owns its
/// arithmetic; what belongs here is the one consequence only `Engine` can show — that a column bleeding
/// into the margin is placed with `.setFrame`, not `.park`. That switch is the reason the layout's
/// visibility query is asked of the physical extent, and it is a fact about effects, not about rects.
@Suite struct OuterGapEngineTests {

    /// Four ½-width columns on a 1000 pt display with a 50 pt margin: the content area is 900 wide, so
    /// a column is 450 and two of them fill it exactly. Scrolled to the origin, the columns land at
    /// screen 50 · 500 · 950 · 1400 — so the third begins inside the right margin and is still on the
    /// display, and the fourth is past it entirely.
    private static let config = Config(widthPresets: PresetCycle([.proportion(0.5)]),
                                       outerGaps: EdgeInsets(uniform: 50),
                                       smoothTransitions: false)

    /// The placement effects for a settled four-column world scrolled to its origin.
    ///
    /// Two things this has to do that a plain `world(4)` doesn't. **Focus the first window**, because a
    /// world built by creating windows leaves focus on the newest and the viewport scrolled to it, and
    /// the margin is only interesting at a known offset. **Perturb every frame first**, because
    /// `emitPlacements` skips windows already where they belong — a settled world re-asserts *nothing*,
    /// so asking it for effects would answer with an empty batch that trivially satisfies any claim
    /// about what is in it.
    private static func placements() -> (placed: [WindowId: Rect], parked: [WindowId], display: Rect) {
        var s = EngineTests.settle(EngineTests.world(4, config: config))
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1)))
        s = EngineTests.settle(s)
        for raw in 1...4 {
            (s, _) = Engine.reduce(s, .windowFrameChanged(WindowId(UInt64(raw)),
                                                          Rect(x: 0, y: 0, width: 10, height: 10)))
        }
        let (after, effects) = Engine.reduce(s, .dragEnded)
        var placed: [WindowId: Rect] = [:]
        var parked: [WindowId] = []
        for effect in effects {
            switch effect {
            case .setFrame(let w, let r): placed[w] = r
            case .park(let w, _): parked.append(w)
            default: continue
            }
        }
        return (placed, parked, after.world.monitors.first!.frame)
    }

    @Test func aColumnInTheMarginIsPlacedNotParked() {
        let (placed, _, display) = Self.placements()
        #expect(placed[WindowId(1)] == Rect(x: 50, y: 50, width: 450, height: 700))
        #expect(placed[WindowId(2)] == Rect(x: 500, y: 50, width: 450, height: 700))
        // The one that matters: it starts inside the margin and runs off the display, and it is a
        // `setFrame` rather than a `park`.
        #expect(placed[WindowId(3)] == Rect(x: 950, y: 50, width: 450, height: 700))
        #expect(placed[WindowId(3)]!.maxX > display.maxX)
    }

    /// The complement, so the test above isn't just "nothing ever parks": the fourth column is past the
    /// display edge entirely and parks as it always did.
    @Test func aColumnPastTheDisplayStillParks() {
        let (placed, parked, _) = Self.placements()
        #expect(parked == [WindowId(4)])
        #expect(placed[WindowId(4)] == nil)
    }

    /// `grow`'s ceiling is the content width, so a full-width column leaves the margin showing rather
    /// than filling the display — the same 100% the preset ladder resolves against.
    @Test func growStopsAtTheContentWidthNotTheDisplayWidth() {
        var s = EngineTests.world(2, config: Self.config)
        for _ in 0..<10 {
            let (next, fx) = Engine.reduce(s, .command(.grow(.percent(25))))
            s = EngineTests.settle(next, fx)
        }
        let metrics = s.metrics()!
        let focused = s.world.focusedWindow!
        let column = s.layout.columns[s.layout.columnIndex(ofWindow: focused)!]
        #expect(s.layout.resolvedWidth(of: column, metrics: metrics) == 900)   // content, not 1000
    }
}
