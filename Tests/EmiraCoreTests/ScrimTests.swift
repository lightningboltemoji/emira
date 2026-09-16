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

    // Off is the default, and the default is what a window manager owes somebody who asked for nothing.

    @Test func nothingIsSeeThroughUntilTheSettingAsksForIt() {
        let s = EngineFix.world(2, config: EngineFix.halfWidth)
        #expect(s.config.unfocusedOpacity == 1)
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
}
