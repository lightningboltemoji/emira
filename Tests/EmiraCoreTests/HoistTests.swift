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
        #expect(fx.prefix(2) == [.focus(WindowId(2)), .raise(WindowId(2))])
        // The click is a focus verb: written ahead of its echo, since an app need not post one. The
        // picture is held by the shell until the window server shows the real window in front.
        #expect(after.world.focusedWindow == WindowId(2))
        #expect(Self.shown(after).isEmpty)

        // The echo then confirms what the core already holds, and changes nothing.
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

    /// …or a rule says so: floating a kind the taxonomy already floats is choosing it, so a background
    /// app's dialog buried under the work is drawn back over it.
    @Test func aDialogARoleRuleFloatsIsHoisted() {
        var config = EngineFix.fullWidth
        config.windowRules = [WindowRule(role: .dialog, float: true)]
        var s = EngineFix.booted(config: config)
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(1)),
                              .windowCreated(EngineFix.snapshot(2, bundle: "com.example.vpn", role: .dialog,
                                                                frame: Self.float))]).0
        s = EngineFix.run(s, [.focusChanged(WindowId(2), origin: .system),
                              .focusChanged(WindowId(1), origin: .system)]).0
        #expect(s.world.isFloatedByChoice(WindowId(2)))
        #expect(Self.shown(s) == [WindowId(2)])
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

    /// A float its app has stopped drawing without closing — ordered out, or faded to nothing, and kept.
    /// A picture of it would stand over the desktop showing a window nobody can see, and a click on the
    /// picture would hand focus to it. It is off the screen until the window server draws it again.
    @Test func aFloatTheServerStoppedDrawingIsNotHoisted() {
        var s = Self.floatOverATile()
        s = EngineFix.run(s, [.windowShown(WindowId(2), false)]).0
        #expect(s.hoists.isEmpty)
        #expect(Engine.reduce(s, .hoistClicked(WindowId(2))).1.isEmpty, "and nothing is left to click")

        // The same window drawn again — a reminder that comes back is the window that left.
        s = EngineFix.run(s, [.windowShown(WindowId(2), true)]).0
        #expect(Self.shown(s) == [WindowId(2)])
    }

    /// The fact is about where a window the app places is. A tiled window's place is the strip's, which
    /// the last placement pass already answered.
    @Test func aTiledWindowTheServerStoppedDrawingKeepsItsPlace() {
        var s = Self.floatOverATile()
        s = EngineFix.run(s, [.windowShown(WindowId(1), false)]).0
        #expect(s.world.isOnScreen(WindowId(1)))
        #expect(Self.shown(s) == [WindowId(2)])
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

    /// The arrival's own rank, and what it stops. A float emira does not focus has no `focusedAt`
    /// entry unless the arrival writes one, and with none it ranks *behind* the window it opened out
    /// of — its own app's, which is precisely rule 3's test. The picture would go up over a window the
    /// user is looking at, filmed before the app had drawn anything into it.
    @Test func aFloatIsNotHoistedByTheWindowItOpenedOutOf() {
        var config = EngineFix.fullWidth
        config.windowRules = [WindowRule(smallerThanFocused: 0.8, fromFocusedApp: true, float: true)]
        var s = EngineFix.booted(config: config)
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(1))]).0
        // Small enough for the rule, and over the full-width column it opened out of.
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(2, frame: Self.float))]).0

        #expect(s.world.isFloatedByChoice(WindowId(2)))     // the rule fired…
        #expect(s.world.focusedWindow == WindowId(1))       // …without the dialog stealing focus
        #expect(Self.shown(s).isEmpty)
        #expect(s.hoists.map(\.state) == [.standby])
    }

    /// The stacking record outlives focus leaving every managed window, which is a different fact and
    /// the one an app reports while opening a window emira has not bound yet.
    @Test func aStaleNilFocusReportDoesNotBuryAFreshFloat() {
        var config = EngineFix.fullWidth
        config.windowRules = [WindowRule(smallerThanFocused: 0.8, fromFocusedApp: true, float: true)]
        var s = EngineFix.booted(config: config)
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(1)),
                              .windowCreated(EngineFix.snapshot(2, frame: Self.float))]).0
        s = EngineFix.run(s, [.focusChanged(nil, origin: .system)]).0
        #expect(Self.shown(s).isEmpty)
    }

    /// …and the record is asked of the screen rather than written unconditionally: a window that
    /// arrives in the Dock is on top of nothing, so it keeps the rank a desktop nothing has focused
    /// gives it.
    @Test func aMinimizedArrivalIsOnTopOfNothing() {
        var s = EngineFix.booted(config: EngineFix.fullWidth)
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(1))]).0
        let minimized = WindowSnapshot(id: WindowId(2), bundleId: "com.test.app", title: "w",
                                       role: .standard, frame: Self.float, isMinimized: true)
        s = EngineFix.run(s, [.windowCreated(minimized)]).0
        #expect(s.world.focusedAt[WindowId(2)] == nil)
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

    /// A float can be buried while it holds the keyboard — an app may raise its main window over a
    /// dialog it keeps focused — and the server's reading is then the only news. A click on the picture
    /// is a raise all the same, though focus does not move.
    @Test func clickingAFloatBuriedWhileFocusedRaisesIt() {
        var s = EngineFix.booted(config: EngineFix.fullWidth)
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(1)),
                              .windowCreated(EngineFix.snapshot(2))]).0
        s = EngineFix.run(s, [.command(.float(.on)), .windowFrameChanged(WindowId(2), Self.float),
                              .stackRead(WindowId(2), over: [WindowId(1)])]).0
        #expect(s.world.focusedWindow == WindowId(2))
        #expect(Self.shown(s) == [WindowId(2)])

        s = EngineFix.run(s, [.hoistClicked(WindowId(2))]).0
        #expect(Self.shown(s).isEmpty)
    }

    // The window server's reading (`Event.stackRead`)

    /// The order is reconstructed from focus reports, and an app can hold a window over its own others
    /// whatever they say — a JVM lifts an owned dialog above the frame it belongs to. The server drawing
    /// nothing over the float is the answer, and the picture comes down.
    @Test func aFloatTheServerShowsInFrontIsNotHoisted() {
        var s = Self.floatOverATile()
        #expect(Self.shown(s) == [WindowId(2)])
        s = EngineFix.run(s, [.stackRead(WindowId(2), over: [])]).0
        #expect(Self.shown(s).isEmpty)
        #expect(s.hoists.map(\.state) == [.standby])
        // Only the stacking half: nobody's focus moved.
        #expect(s.world.focusedWindow == WindowId(1))
    }

    /// The other way round: a focus report that never arrived leaves the float ranked in front of a
    /// window the server draws over it. The window drawn over it is the one ranked wrong.
    @Test func aFloatTheServerShowsBuriedIsHoisted() {
        var s = EngineFix.booted(config: EngineFix.fullWidth)
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(1)),
                              .windowCreated(EngineFix.snapshot(2))]).0
        s = EngineFix.run(s, [.command(.float(.on)), .windowFrameChanged(WindowId(2), Self.float)]).0
        #expect(Self.shown(s).isEmpty)

        s = EngineFix.run(s, [.stackRead(WindowId(2), over: [WindowId(1)])]).0
        #expect(Self.shown(s) == [WindowId(2)])
        #expect(s.world.focusedWindow == WindowId(2))
    }

    /// A reading that agrees with the record changes nothing, and nor does one about a window nothing
    /// hoists — a dialog the taxonomy floated is still nobody's to stand in for.
    @Test func aReadingThatAgreesOrDoesNotApplyChangesNothing() {
        let s = Self.floatOverATile()
        let (agreed, _) = Engine.reduce(s, .stackRead(WindowId(2), over: [WindowId(1)]))
        #expect(agreed == s)

        var t = EngineFix.booted(config: EngineFix.fullWidth)
        t = EngineFix.run(t, [.windowCreated(EngineFix.snapshot(1)),
                              .windowCreated(EngineFix.snapshot(2, role: .dialog, frame: Self.float))]).0
        let (declined, fx) = Engine.reduce(t, .stackRead(WindowId(2), over: [WindowId(1)]))
        #expect(declined == t)
        #expect(fx.isEmpty)
    }

    /// Rule 3 holds against the reading too: a window emira never placed over the float is not one that
    /// buried it, and a float drawn under only that is not hoisted.
    @Test func aReadingNamesOnlyWindowsEmiraPlacedAsBuryingOne() {
        var s = Self.floatOverATile()
        s = EngineFix.run(s, [.windowCreated(EngineFix.snapshot(3, role: .dialog,
                                                                frame: Rect(x: 250, y: 250, width: 100, height: 100)))]).0
        s = EngineFix.run(s, [.stackRead(WindowId(2), over: [WindowId(3)])]).0
        #expect(Self.shown(s).isEmpty)
    }
}
