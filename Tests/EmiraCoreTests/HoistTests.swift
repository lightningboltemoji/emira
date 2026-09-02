import Foundation
import Testing
@testable import EmiraCore

// The hoist derivation (`State.hoistBindings`): which floats emira stands in for, which of those
// pictures are *showing*, in what order, and the three rules that decide it — covered, chosen, and
// covered *by a window emira placed*.

@Suite struct HoistTests {

    /// The floats whose picture is on the screen. Every on-screen float is named, so "not hoisted" is a
    /// claim about `.covered` rather than about the list being empty.
    static func shown(_ s: State) -> [WindowId] {
        s.hoists.filter { $0.state == .covered }.map(\.window)
    }

    /// A booted display with `w1` tiled full width and `w2` floated by hand at a rect that overlaps it.
    /// The `windowFrameChanged` is not decoration: a float keeps the frame it *had*, which is the tiled
    /// one, so the app putting it back to its own size is part of what a real float looks like.
    static func floatOverATile() -> State {
        var s = EngineFix.booted(config: EngineFix.fullWidth)
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(1)),
                              .windowCreated(EngineFix.snapshot(2))]).0
        // w2 is focused as the newer arrival; float it, then focus the tiled window, which is what
        // buries it on a real desktop.
        s = EngineFix.run(s, [.command(.float(.on)), .windowFrameChanged(WindowId(2), float)]).0
        return EngineFix.run(s, [.focusChanged(WindowId(1), origin: .system)]).0
    }

    /// Inside the 1000×800 display, and inside a full-width column's frame.
    static let float = Rect(x: 200, y: 200, width: 300, height: 200)

    @Test func aFloatBuriedByATiledWindowIsHoistedWhereItStands() {
        let s = Self.floatOverATile()
        #expect(Self.shown(s) == [WindowId(2)])
        #expect(s.hoists.first?.frame == Self.float)
        #expect(s.hoists.first?.monitor == MonitorId(1))
    }

    /// Rule 1, and the reason it is rule 1: a hoist is a photograph that cannot be dragged or scrolled,
    /// so a float nothing is covering is left alone as a real window.
    @Test func aFloatNothingCoversIsNotHoisted() {
        var s = EngineFix.booted(config: EngineFix.fullWidth)
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(1)),
                              .windowCreated(EngineFix.snapshot(2))]).0
        s = EngineFix.run(s, [.command(.float(.on)), .windowFrameChanged(WindowId(2), Self.float)]).0
        // The float still holds focus, so it is in front of the tiled window it overlaps — named, so
        // its picture is built and filmed against the burial to come, but not showing.
        #expect(Self.shown(s).isEmpty)
        #expect(s.hoists.map(\.state) == [.standby])
    }

    /// The float coming forward is the whole exit: it is then the front-most thing on the desktop and
    /// there is nothing left to stand in for. This is also the hand-off `Event.hoistClicked` relies on.
    @Test func focusingAHoistedFloatTakesItsHoistDown() {
        var s = Self.floatOverATile()
        #expect(!s.hoists.isEmpty)

        let (after, fx) = Engine.reduce(s, .hoistClicked(WindowId(2)))
        #expect(fx == [.focus(WindowId(2)), .raise(WindowId(2))])
        // The click alone does not take it down — the real window is not in front yet.
        #expect(Self.shown(after) == [WindowId(2)])

        s = EngineFix.run(after, [.focusChanged(WindowId(2), origin: .ours)]).0
        #expect(Self.shown(s).isEmpty)
    }

    /// Rule 2. The taxonomy floats every dialog, sheet and tool palette; hoisting reads the user's own
    /// answer instead, so a window emira merely declined to tile is never drawn back over the desktop.
    @Test func aFloatTheTaxonomyChoseIsNotHoisted() {
        var s = EngineFix.booted(config: EngineFix.fullWidth)
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(1)),
                              .windowCreated(EngineFix.snapshot(2, role: .dialog, frame: Self.float))]).0
        s = EngineFix.run(s, [.focusChanged(WindowId(1), origin: .system)]).0
        #expect(s.world.isFloating(WindowId(2)))            // it floats…
        #expect(s.hoists.isEmpty)                           // …and is still nobody's to stand in for
    }

    /// …until the user says so. `float on` over a window that already floats moves nothing, and
    /// recording the answer is the whole of what it does.
    @Test func floatOnAdoptsAWindowTheTaxonomyFloated() {
        var s = EngineFix.booted(config: EngineFix.fullWidth)
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(1)),
                              .windowCreated(EngineFix.snapshot(2, role: .dialog, frame: Self.float))]).0
        s = EngineFix.run(s, [.focusChanged(WindowId(2), origin: .system),
                              .command(.float(.on)),
                              .focusChanged(WindowId(1), origin: .system)]).0
        #expect(s.world.isFloatedByChoice(WindowId(2)))
        #expect(Self.shown(s) == [WindowId(2)])
    }

    /// Rule 3: only a window emira placed can bury one. A float overlapping nothing on the strip is a
    /// float nobody put anything in front of.
    @Test func aFloatOffTheStripsWayIsNotHoisted() {
        // `halfWidth`, so the one remaining column is 500 wide and there is screen to the right of it.
        var s = EngineFix.booted(config: EngineFix.halfWidth)
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(1)),
                              .windowCreated(EngineFix.snapshot(2))]).0
        s = EngineFix.run(s, [.command(.float(.on)),
                              // Beside the column, not over it.
                              .windowFrameChanged(WindowId(2), Rect(x: 600, y: 200,
                                                                    width: 300, height: 200)),
                              .focusChanged(WindowId(1), origin: .system)]).0
        #expect(Self.shown(s).isEmpty)
        // Named all the same, and this is the rule rather than an accident: standby is *on screen*, not
        // "something could cover it". A float overlapping a column would leave and re-enter that set
        // every time the strip scrolled out from under it, paying a film each way for a picture nobody
        // saw.
        #expect(s.hoists.map(\.state) == [.standby])
    }

    /// A minimized float has nothing to stand in for, and a picture of one would be a window in the
    /// Dock drawn over the desktop.
    @Test func aMinimizedFloatIsNotHoisted() {
        var s = Self.floatOverATile()
        #expect(!Self.shown(s).isEmpty)
        s = EngineFix.run(s, [.windowMinimized(WindowId(2))]).0
        #expect(s.hoists.isEmpty)                           // off the screen: nothing even to prepare
    }

    /// The float leaving takes its hoist with it — the shell is told by the same effect that would have
    /// placed it, so nothing has to notice the destroy on its own.
    @Test func aDestroyedFloatIsUnhoistedByTheSameEffect() {
        let s = Self.floatOverATile()
        let (after, fx) = Engine.reduce(s, .windowDestroyed(WindowId(2)))
        #expect(after.hoists.isEmpty)
        #expect(fx.contains(.setHoists([])))
    }

    /// The effect is a replacement, not an edit, and it is emitted only when the answer changes — the
    /// post-pass runs on every event including a display-link tick.
    @Test func anUnchangedAnswerEmitsNothing() {
        let s = Self.floatOverATile()
        let (_, fx) = Engine.reduce(s, .tick(dt: 1.0 / 120))
        #expect(!fx.contains { if case .setHoists = $0 { true } else { false } })
    }

    /// Two floats stacked over the strip keep the order the desktop had them in, bottom→top — and the
    /// closure is what puts the *upper* one in the array at all: only the lower one is covered by a
    /// tiled window, and hoisting it alone would draw it over a float that is really in front.
    @Test func overlappingHoistsKeepTheirOwnOrder() {
        // `halfWidth`: w1's column is 500 wide, so w3 can overlap w2 while clearing the strip entirely.
        var s = EngineFix.booted(config: EngineFix.halfWidth)
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(1)),
                              .windowCreated(EngineFix.snapshot(2)),
                              .windowCreated(EngineFix.snapshot(3))]).0
        // Float both, oldest first, so w3 is the more recently focused of the two. w2 straddles the
        // column and is covered on its own account; w3 clears it and is pulled in only by the closure.
        s = EngineFix.run(s, [.focusChanged(WindowId(2), origin: .system), .command(.float(.on)),
                              .windowFrameChanged(WindowId(2), Rect(x: 400, y: 200,
                                                                    width: 300, height: 200)),
                              .focusChanged(WindowId(3), origin: .system), .command(.float(.on)),
                              .windowFrameChanged(WindowId(3), Rect(x: 600, y: 250,
                                                                    width: 300, height: 200)),
                              .focusChanged(WindowId(1), origin: .system)]).0
        #expect(Self.shown(s) == [WindowId(2), WindowId(3)])
    }

    /// Nothing has been focused, so nothing is known to be behind anything: the float is prepared and
    /// shows nothing. The conservative answer at boot, and it falls out of the rank rather than being a
    /// case.
    @Test func aDesktopNothingHasFocusedShowsNothing() {
        var s = EngineFix.booted(config: EngineFix.fullWidth)
        s.world.insert(EngineFix.snapshot(1))
        s.world.insert(EngineFix.snapshot(2, frame: Self.float))
        s.world.setFloating(WindowId(2), true)
        #expect(s.hoistBindings().map(\.state) == [.standby])
    }
}
