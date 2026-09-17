import Foundation
import Testing
@testable import EmiraCore

// The scrim derivation (`State.scrimBindings`): which windows the shell is asked to draw see-through,
// at what veil, in what order, and on whose display — plus the post-pass that only speaks when the
// answer changes.

@Suite struct ScrimTests {

    /// A ½-width world of `count` windows on one display, at rest, with the setting on.
    static func world(_ count: UInt64, opacity: Double = 0.7) -> State {
        var config = EngineFix.halfWidth
        config.unfocusedOpacity = opacity
        return EngineFix.world(count, config: config)
    }

    static func windows(_ s: State) -> [WindowId] { s.scrims.map(\.window) }

    // Off is opacity 1.

    @Test func nothingIsSeeThroughAtFullOpacity() {
        let s = Self.world(2, opacity: 1)
        #expect(s.scrims.isEmpty)
    }

    @Test func turningItOffAgainTakesEveryScrimDown() {
        var s = Self.world(2)
        #expect(!s.scrims.isEmpty)
        var off = s.config
        off.unfocusedOpacity = 1
        let (next, effects) = Engine.reduce(s, .configChanged(off))
        s = next
        #expect(s.scrims.isEmpty)
        #expect(effects.contains(.setScrims([])))
    }

    // What the set holds.

    @Test func everyOnScreenWindowButTheFocusedOneIsSeeThrough() {
        let s = Self.world(2)
        let focused = s.world.focusedWindow
        #expect(focused != nil)
        #expect(Self.windows(s).count == 1)
        #expect(!Self.windows(s).contains(focused!))
    }

    @Test func aParkedWindowIsNotSeeThrough() {
        // Three ½-width columns on a 1000-wide viewport: one of them is off the strip, and a window
        // nobody can see is not a window to draw the desktop over.
        let s = Self.world(3)
        #expect(s.world.placedOnScreen.count == 2)
        #expect(Self.windows(s).allSatisfy { s.world.placedOnScreen.contains($0) })
    }

    @Test func theVeilIsWhatTheOpacityLeavesOver() {
        #expect(Self.world(2, opacity: 0.7).scrims.first.map { abs($0.veil - 0.3) < 1e-9 } == true)
        #expect(Self.world(2, opacity: 0.25).scrims.first.map { abs($0.veil - 0.75) < 1e-9 } == true)
    }

    /// The file can spell a floor but not a ceiling (`Setting.Bound`), so the reducer is where an
    /// opacity above 1 stops being a negative veil.
    @Test func anOpacityOverOneIsClampedRatherThanInverted() {
        #expect(Self.world(2, opacity: 2).scrims.isEmpty)
    }

    @Test func theSetIsOrderedBottomToTop() {
        let s = Self.world(3)
        let ordered = s.stackingOrder(of: Self.windows(s))
        #expect(Self.windows(s) == ordered)
    }

    // The display a scrim is backed by — the regression that made the effect vanish for exactly the
    // window a scrolling tiler leaves hanging off the edge of the screen.

    @Test func aColumnHangingOffTheEdgeIsBackedByTheDisplayShowingIt() {
        // Columns that do not tile the viewport: two 700-wide columns on a 1000-wide screen, so the
        // minimal scroll that reveals the second leaves the first hanging off the left edge — on the
        // screen, but with its centre in the parked region beyond it. A full-width preset cannot show
        // this, because there the neighbour goes fully off and is simply parked.
        var config = Config(widthPresets: PresetCycle([.proportion(0.7)]))
        config.unfocusedOpacity = 0.7
        config.fullscreenWhenAlone = false
        var s = EngineFix.world(2, config: config)
        s = EngineFix.settle(s)

        let hanging = try! #require(s.scrims.first { $0.frame.center.x < 0 })
        // Its centre is off every screen, so the geometric question has no answer for it.
        #expect(s.world.monitor(at: hanging.frame.center) == nil)
        #expect(hanging.monitor == MonitorId(1))
    }

    // The post-pass.

    @Test func theSetIsEmittedOnlyWhenItChanges() {
        let s = Self.world(2)
        // A tick with nothing in flight changes no window and no focus.
        let (_, effects) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(!effects.contains { if case .setScrims = $0 { true } else { false } })
    }

    @Test func movingFocusMovesTheScrim() {
        let s = Self.world(2)
        let was = Self.windows(s)
        let (next, effects) = Engine.reduce(s, .command(.focus(.left)))
        let settled = EngineFix.settle(next, effects)
        #expect(Self.windows(settled) != was)
        #expect(Self.windows(settled).count == 1)
        #expect(!Self.windows(settled).contains(settled.world.focusedWindow!))
    }

    /// Nothing is held on a desktop that raises no cover: both columns are already on the glass, the
    /// focus change moves no window, and the veil has nothing to wait for.
    @Test func anUncoveredFocusChangeMovesTheVeilAtOnce() {
        let s = Self.world(2)
        let (next, effects) = Engine.reduce(s, .command(.focus(.left)))
        #expect(!next.motion.isTransitioning, "two ½-width columns both fit, so nothing scrolls")
        #expect(Self.setScrims(effects) != nil)
    }

    // The hand — every veil is lifted while a window is moving under it.

    /// Two veiled columns and a float in front of them, focused. The float is what the hand takes.
    static func withFloat() -> (State, WindowId) {
        let float = WindowId(9)
        let s = EngineFix.run(world(2), [.windowCreated(EngineFix.snapshot(9, role: .dialog))]).0
        return (s, float)
    }

    /// The mask is cut against the window server when a set arrives, so a hole left standing under a
    /// moving float stays where the float was picked up.
    @Test func aWindowInTheHandLiftsEveryVeil() {
        let (s, float) = Self.withFloat()
        #expect(!s.scrims.isEmpty)
        let (next, effects) = EngineFix.run(s, [.dragBegan, .windowFrameChanged(float, Rect(
            x: 340, y: 320, width: 200, height: 200))])
        #expect(Self.setScrims(effects) == [])
        #expect(next.scrims.isEmpty)
    }

    /// Set back down at `dragEnded` and not the mouse-up: an app is still draining the resize when the
    /// button comes up, and a veil cut then is cut around a window that has not finished moving.
    @Test func theVeilIsSetBackDownOnceTheWindowHasStopped() {
        let (s, float) = Self.withFloat()
        let before = s.scrims
        let moved = Rect(x: 340, y: 320, width: 160, height: 140)
        var (held, _) = EngineFix.run(s, [.dragBegan, .windowFrameChanged(float, moved)])

        var draining: [Effect] = []
        (held, draining) = EngineFix.run(held, [.dragReleased, .windowFrameChanged(float, moved)])
        #expect(Self.setScrims(draining) == nil)
        #expect(held.scrims.isEmpty)

        let (landed, effects) = Engine.reduce(held, .dragEnded)
        #expect(Self.setScrims(effects) == before)
        #expect(landed.scrims == before)
    }

    /// A click moves nothing, and a veil that blinked on every one would be flicker.
    @Test func aPressThatMovesNothingLeavesTheVeilDown() {
        let (s, _) = Self.withFloat()
        let (next, effects) = EngineFix.run(s, [.dragBegan, .dragReleased, .dragEnded])
        #expect(Self.setScrims(effects) == nil)
        #expect(next.scrims == s.scrims)
    }

    /// Lifted for any window in the hand, adopted or not: a tiled column dragged wider leaves its hole
    /// behind exactly as a float does.
    @Test func aTiledWindowInTheHandLiftsItWhateverTheSetting() throws {
        var s = Self.world(2)
        s.config.interactiveResize = false
        let focused = try #require(s.world.focusedWindow)
        let frame = try #require(s.world.windows[focused]?.frame)
        let (next, effects) = EngineFix.run(s, [.dragBegan, .windowFrameChanged(focused, Rect(
            x: frame.minX, y: frame.minY, width: frame.width + 120, height: frame.height))])
        #expect(Self.setScrims(effects) == [])
        #expect(next.scrims.isEmpty)
    }

    // The gate — `settleScrims`' half of D8.

    static func setScrims(_ effects: [Effect]) -> [ScrimBinding]? {
        for effect in effects { if case .setScrims(let bindings) = effect { return bindings } }
        return nil
    }

    /// A world where the next `focus left` genuinely scrolls. Three ½-width columns on a 1000-wide
    /// viewport shows two, so focus reaching the third is a cover rather than a bare focus write — and
    /// two on the glass is what leaves a scrim standing to hold.
    static func aboutToScroll() -> State {
        let s = world(3)
        return EngineFix.settle(s, Engine.reduce(s, .command(.focus(.left))).1)
    }

    /// **A covered transition's veil moves behind its cover.** A capture head is time with no cover in
    /// it: focus has moved in the core, and nothing on the glass has. The scrim is what the desktop
    /// looks like, and during the head it still looks like the old one — so the old set stands.
    @Test func aCoveredTransitionHoldsTheVeilThroughItsCaptureHead() {
        var s = Self.aboutToScroll()
        let before = s.scrims
        #expect(!before.isEmpty)

        let (capturing, opening) = Engine.reduce(s, .command(.focus(.left)))
        s = capturing
        #expect(s.motion.phase(of: MonitorId(1)) == .capturing, "the command opened a cover")
        #expect(s.world.focusedWindow != before.first?.window, "…and focus has already moved")
        #expect(Self.setScrims(opening) == nil, "the veil moved while the desktop stood still")
        #expect(s.scrims == before)
    }

    /// And through the raise, which is the moment that matters to the cover: `Reconstruction` reads the
    /// veil off the scrim plane when it *builds* a layer, so a set applied before `coverOnScreen` would
    /// put this transition's focus change on stand-ins filmed under the old one.
    @Test func theVeilIsStillTheOldOneWhenTheCoverIsBuilt() {
        var s = Self.aboutToScroll()
        let before = s.scrims
        var effects: [Effect] = []
        func feed(_ event: Event) { let (n, f) = Engine.reduce(s, event); s = n; effects = f }

        feed(.command(.focus(.left)))
        for window in s.motion.transition(of: MonitorId(1))?.windows ?? [] { feed(.captureReady(window)) }
        #expect(s.motion.phase(of: MonitorId(1)) == .raising)
        #expect(effects.contains { if case .beginTransition = $0 { true } else { false } },
                "the batch that builds the cover")
        #expect(Self.setScrims(effects) == nil)
        #expect(s.scrims == before)
    }

    /// The release: the cover is on the glass, the reals teleport behind it, and the new set rides in
    /// the same batch — under the cover, where every other correction a transition makes is made.
    @Test func theVeilLandsInTheBatchThatTeleportsTheReals() {
        var s = Self.aboutToScroll()
        let before = s.scrims
        var effects: [Effect] = []
        func feed(_ event: Event) { let (n, f) = Engine.reduce(s, event); s = n; effects = f }

        feed(.command(.focus(.left)))
        for window in s.motion.transition(of: MonitorId(1))?.windows ?? [] { feed(.captureReady(window)) }
        feed(.coverOnScreen(MonitorId(1)))

        let landed = try! #require(Self.setScrims(effects), "the held set is paid at the teleport")
        #expect(landed != before)
        #expect(effects.contains { if case .setFrame = $0 { true } else { false } },
                "…in the batch that moves the reals, not one of its own")
        #expect(s.scrims == landed)
        #expect(!landed.map(\.window).contains(s.world.focusedWindow!))
    }

    /// The set is one effect for the whole desktop, so holding one display must not take another's
    /// answer down with it. The right display is idle throughout and keeps answering for itself.
    @Test func aHeldDisplayDoesNotHoldTheOtherOne() {
        var config = MonitorSessionTests.fullWidth
        config.unfocusedOpacity = 0.7
        // `moveToWorkspace` sends a window without following it, so this leaves one window on the
        // right with a scrim standing on it and focus still on the left's strip.
        var s = MonitorSessionTests.desktop(3, config: config)
        s = MonitorSessionTests.sendToRight(s)
        let right = MonitorSessionTests.right
        let standing = s.scrims.filter { $0.monitor == right }
        #expect(!standing.isEmpty)

        let (capturing, _) = Engine.reduce(s, .command(.focus(.left)))
        s = capturing
        #expect(!s.motion.mayPlace(on: MonitorSessionTests.left))
        #expect(s.motion.mayPlace(on: right))
        #expect(s.scrims.filter { $0.monitor == right } == standing,
                "the idle display's own answer is unchanged, not dropped with the held one's")
    }
}
