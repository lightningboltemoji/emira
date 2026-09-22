import Foundation
import Testing
@testable import EmiraCore

// The scrim derivation (`State.scrimBindings`): which windows the shell is asked to draw see-through,
// at what veil, in what order, and on whose display — plus the post-pass that speaks when the answer
// changes, and again when the desktop it is masked against has settled.

@Suite struct ScrimTests {

    /// A ½-width world of `count` windows on one display, at rest, with the setting on.
    static func world(_ count: UInt64, opacity: Double = 0.7) -> State {
        var config = EngineFix.halfWidth
        config.unfocusedOpacity = opacity
        return EngineFix.world(count, config: config)
    }

    /// One display's set — the fixtures below build a single display.
    static func set(_ s: State, _ monitor: MonitorId = MonitorId(1)) -> [ScrimBinding] {
        s.scrims[monitor] ?? []
    }

    static func windows(_ s: State) -> [WindowId] {
        s.scrims.keys.sorted().flatMap { s.scrims[$0] ?? [] }.map(\.window)
    }

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
        #expect(effects.contains(.setScrims(MonitorId(1), [], .dissolve, moving: [])))
    }

    // What the set holds.

    @Test func everyOnScreenWindowButTheFocusedOneIsSeeThrough() {
        let s = Self.world(2)
        let focused = s.world.focusedWindow
        #expect(focused != nil)
        #expect(Self.windows(s).count == 1)
        #expect(!Self.windows(s).contains(focused!))
    }

    @Test func focusRestingOnNothingKeepsTheVeilWhereItWas() throws {
        // A `nil` focus report is routine — an app focuses a window emira has not adopted, a launcher
        // takes the keyboard — and read literally it draws every window on the strip see-through,
        // including the one the user is working in, and rests there until something moves focus back.
        var s = Self.world(2)
        let working = try #require(s.world.focusedWindow)
        let before = Self.set(s)

        let (next, effects) = Engine.reduce(s, .focusChanged(nil, origin: .system))
        s = next

        #expect(s.world.focusedWindow == nil)
        #expect(!Self.windows(s).contains(working), "the window focus just left stays opaque")
        #expect(Self.set(s) == before)
        #expect(!effects.contains { if case .setScrims = $0 { true } else { false } },
                "and the plane is told nothing, the set not having moved")
    }

    @Test func aParkedWindowIsNotSeeThrough() {
        // Three ½-width columns on a 1000-wide viewport: one of them is off the strip, and a window
        // nobody can see is not a window to draw the desktop over.
        let s = Self.world(3)
        #expect(s.world.placedOnScreen.count == 2)
        #expect(Self.windows(s).allSatisfy { s.world.placedOnScreen.contains($0) })
    }

    @Test func theVeilIsWhatTheOpacityLeavesOver() {
        #expect(Self.set(Self.world(2, opacity: 0.7)).first.map { abs($0.veil - 0.3) < 1e-9 } == true)
        #expect(Self.set(Self.world(2, opacity: 0.25)).first.map { abs($0.veil - 0.75) < 1e-9 } == true)
    }

    /// The file can spell a floor but not a ceiling (`Setting.Bound`), so the reducer is where an
    /// opacity above 1 stops being a negative veil.
    @Test func anOpacityOverOneIsClampedRatherThanInverted() {
        #expect(Self.world(2, opacity: 2).scrims.isEmpty)
    }

    /// The effect belongs to the strip, and this is where it says so. A cascade's tiles are backed by
    /// each other rather than by the desktop, and the overlaps are the whole of what says which is on
    /// top — so `stack` is declined by the layout rather than rediscovered as an overlap by the plane.
    @Test func aCascadesTilesAreNotSeeThrough() {
        var config = EngineFix.stacked(EngineFix.halfWidth)
        config.unfocusedOpacity = 0.7
        let s = EngineFix.world(3, config: config)
        #expect(s.layout.kind == .stack)
        #expect(s.world.placedOnScreen.count == 3, "everything on a cascade is on screen")
        #expect(s.scrims.isEmpty)
    }

    /// A pin is on no layout, so the cascade it stands beside says nothing about it.
    @Test func aPinIsSeeThroughBesideACascade() {
        var config = EngineFix.stacked(EngineFix.halfWidth)
        config.unfocusedOpacity = 0.7
        var s = EngineFix.world(3, config: config)
        s.world.setFocus(WindowId(2))
        let (pinned, fx) = EngineFix.run(s, [.command(.pin(.left))])
        s = EngineFix.settle(pinned, fx)
        // Focus off the pin, through the reducer, or the post-pass that derives the set never runs.
        let (moved, effects) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))
        s = EngineFix.settle(moved, effects)

        #expect(s.world.isPinned(WindowId(2)))
        #expect(Self.windows(s) == [WindowId(2)], "the pin, and none of the tiles beside it")
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

        // On display 1's scrim, though its centre is off every screen — so the geometric question, which
        // is the one a hoist asks, has no answer for it.
        let hanging = try! #require(Self.set(s).first { s.world.windows[$0.window]!.frame.center.x < 0 })
        #expect(s.world.monitor(at: s.world.windows[hanging.window]!.frame.center) == nil)
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
        #expect(Self.change(effects) == .cut, "the mask is already wrong, so it goes at once")
        #expect(next.scrims.isEmpty)
    }

    /// Set back down at `dragEnded` and not the mouse-up: an app is still draining the resize when the
    /// button comes up, and a veil cut then is cut around a window that has not finished moving.
    @Test func theVeilIsSetBackDownOnceTheWindowHasStopped() {
        let (s, float) = Self.withFloat()
        let before = Self.set(s)
        let moved = Rect(x: 340, y: 320, width: 160, height: 140)
        var (held, _) = EngineFix.run(s, [.dragBegan, .windowFrameChanged(float, moved)])

        var draining: [Effect] = []
        (held, draining) = EngineFix.run(held, [.dragReleased, .windowFrameChanged(float, moved)])
        #expect(Self.setScrims(draining) == nil)
        #expect(held.scrims.isEmpty)

        let (landed, effects) = Engine.reduce(held, .dragEnded)
        #expect(Self.setScrims(effects) == before)
        #expect(Self.change(effects) == .dissolve, "an ordinary set, which fades in")
        #expect(Self.set(landed) == before)
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
        for effect in effects { if case .setScrims(_, let bindings, _, _) = effect { return bindings } }
        return nil
    }

    /// How the set in `effects` reaches the glass, or `nil` for no set at all.
    static func change(_ effects: [Effect]) -> ScrimChange? {
        for effect in effects { if case .setScrims(_, _, let change, _) = effect { return change } }
        return nil
    }

    /// The windows the set in `effects` names as still on their way, or `nil` for no set at all.
    static func moving(_ effects: [Effect]) -> Set<WindowId>? {
        for effect in effects { if case .setScrims(_, _, _, let moving) = effect { return moving } }
        return nil
    }

    /// **A set names what the window server has not caught up with.** The teleport writes the frames and
    /// the set goes with it, but the server trails an `axLanded` — so the shell is told which panes are
    /// merely where they were, or a window that has just gone opaque declines against its old place.
    @Test func theTeleportsSetNamesTheWindowsItIsStillMoving() throws {
        var s = Self.aboutToScroll()
        var effects: [Effect] = []
        func feed(_ event: Event) { let (n, f) = Engine.reduce(s, event); s = n; effects = f }

        feed(.command(.focus(.left)))
        for window in s.motion.transition(of: MonitorId(1))?.windows ?? [] { feed(.captureReady(window)) }
        feed(.coverOnScreen(MonitorId(1)))

        let named = try #require(Self.moving(effects), "the teleport pays the held set")
        let written = Set(effects.compactMap { effect -> WindowId? in
            if case .setFrame(let id, _) = effect { id } else if case .park(let id, _) = effect { id }
            else { nil }
        })
        #expect(!written.isEmpty, "the teleport is what writes the frames")
        #expect(written.isSubset(of: named), "and every one of them is named as still on its way")
    }

    /// A desktop nobody is moving names nobody, or every decline would be suspended for ever.
    @Test func aSetOnAStillDesktopNamesNothingAsMoving() {
        let s = Self.world(2)
        let (_, effects) = Engine.reduce(s, .command(.focus(.left)))
        let settled = EngineFix.settle(s, effects)
        let (_, quiet) = Engine.reduce(settled, .configChanged({
            var c = settled.config; c.unfocusedOpacity = 0.4; return c
        }()))
        #expect(Self.moving(quiet) == [])
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
        let before = Self.set(s)
        #expect(!before.isEmpty)

        let (capturing, opening) = Engine.reduce(s, .command(.focus(.left)))
        s = capturing
        #expect(s.motion.phase(of: MonitorId(1)) == .capturing, "the command opened a cover")
        #expect(s.world.focusedWindow != before.first?.window, "…and focus has already moved")
        #expect(Self.setScrims(opening) == nil, "the veil moved while the desktop stood still")
        #expect(Self.set(s) == before)
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
        let before = Self.set(s)
        var effects: [Effect] = []
        func feed(_ event: Event) { let (n, f) = Engine.reduce(s, event); s = n; effects = f }

        feed(.command(.focus(.left)))
        for window in s.motion.transition(of: MonitorId(1))?.windows ?? [] { feed(.captureReady(window)) }
        feed(.coverOnScreen(MonitorId(1)))

        let landed = try! #require(Self.setScrims(effects), "the held set is paid at the teleport")
        #expect(landed != before)
        #expect(effects.contains { if case .setFrame = $0 { true } else { false } },
                "…in the batch that moves the reals, not one of its own")
        #expect(Self.set(s) == landed)
        #expect(!landed.map(\.window).contains(s.world.focusedWindow!))
    }

    /// A set is one display's, so holding one display must not take another's answer down with it. The
    /// right display is idle throughout and keeps answering for itself.
    @Test func aHeldDisplayDoesNotHoldTheOtherOne() {
        var config = MonitorSessionTests.fullWidth
        config.unfocusedOpacity = 0.7
        // `moveToWorkspace` sends a window without following it, so this leaves one window on the
        // right with a scrim standing on it and focus still on the left's strip.
        var s = MonitorSessionTests.desktop(3, config: config)
        s = MonitorSessionTests.sendToRight(s)
        let right = MonitorSessionTests.right
        let standing = Self.set(s, right)
        #expect(!standing.isEmpty)

        let (capturing, _) = Engine.reduce(s, .command(.focus(.left)))
        s = capturing
        #expect(!s.motion.mayPlace(on: MonitorSessionTests.left))
        #expect(s.motion.mayPlace(on: right))
        #expect(Self.set(s, right) == standing,
                "the idle display's own answer is unchanged, not dropped with the held one's")
    }

    /// **A set names the display it is for, and reaches no other.** The right display's scrim is drawing
    /// its own windows against its own stacking, and a focus change on the left is nothing to it.
    @Test func aSetNamesOneDisplay() throws {
        // ½-width columns, so the focus change below is on the glass already and scrolls nothing.
        var config = EngineFix.halfWidth
        config.unfocusedOpacity = 0.7
        var s = MonitorSessionTests.desktop(3, config: config)
        s = MonitorSessionTests.sendToRight(s)

        let (next, effects) = Engine.reduce(s, .command(.focus(.left)))
        let sets = effects.compactMap { effect -> MonitorId? in
            if case .setScrims(let monitor, _, _, _) = effect { monitor } else { nil }
        }
        #expect(sets == [MonitorSessionTests.left], "one set, for the display whose veil moved")
        #expect(Self.set(next, MonitorSessionTests.right) == Self.set(s, MonitorSessionTests.right))
    }

    // The settle — a set is masked against the window server, so it waits for the writes that move it.

    /// `world`, but under `off`: every placement is a write with no cover over it.
    static func uncovered(_ count: UInt64) -> State {
        var config = EngineFix.halfWidthSnap
        config.unfocusedOpacity = 0.7
        return EngineFix.world(count, config: config)
    }

    /// The windows a batch writes, in order.
    static func written(_ effects: [Effect]) -> [WindowId] {
        effects.compactMap { effect -> WindowId? in
            switch effect {
            case .setFrame(let id, _), .park(let id, _): id
            default: nil
            }
        }
    }

    /// **A frame report is not a set.** The set names windows and veils, and where they stand is the
    /// window server's — so our own write echoing back a fraction of a point off its target is nothing.
    @Test func anEchoOfOurOwnWriteIsNotANewSet() throws {
        let s = Self.world(2)
        let veiled = try #require(Self.set(s).first).window
        let frame = try #require(s.world.windows[veiled]?.frame)
        let echo = Rect(x: frame.minX - 0.08, y: frame.minY, width: frame.width + 0.08, height: frame.height)
        let (next, effects) = Engine.reduce(s, .windowFrameChanged(veiled, echo))
        #expect(Self.setScrims(effects) == nil)
        #expect(next.scrims == s.scrims)
    }

    /// **An uncovered move holds the veil until it lands.** The batch that writes the frames reaches the
    /// plane before the window server has moved, so a set in it would be masked against where the windows
    /// were. It goes with the last landing instead.
    @Test func anUncoveredPlacementHoldsTheVeilUntilItsWritesLand() throws {
        // Focus on the middle of three ½-width columns, so the next `focus left` scrolls.
        var s = Self.uncovered(3)
        s = EngineFix.settle(s, Engine.reduce(s, .command(.focus(.left))).1)
        let before = Self.set(s)

        let (placing, effects) = Engine.reduce(s, .command(.focus(.left)))
        s = placing
        let written = Self.written(effects)
        #expect(!s.motion.isTransitioning, "`off` raises no cover")
        #expect(!written.isEmpty, "…and the scroll writes the reals")
        #expect(Self.setScrims(effects) == nil, "the veil waits for them")
        #expect(Self.set(s) == before)

        var landing: [Effect] = []
        for id in written.dropLast() {
            (s, landing) = Engine.reduce(s, .axLanded(id))
            #expect(Self.setScrims(landing) == nil, "not while one is still in flight")
        }
        (s, landing) = Engine.reduce(s, .axLanded(try #require(written.last)))
        let landed = try #require(Self.setScrims(landing), "the last landing pays it")
        #expect(landed != before)
        #expect(!landed.map(\.window).contains(try #require(s.world.focusedWindow)))
    }

    /// **A move that changes no veil still sends the set again when it lands**, so the plane recuts the
    /// mask where the window came to rest. Nothing else would: the set itself carries no geometry.
    @Test func aPlacementThatMovesNoVeilIsSentAgainWhenItLands() throws {
        let rest = Self.uncovered(2)
        let veiled = try #require(Self.set(rest).first).window
        let belongs = try #require(rest.world.windows[veiled]?.frame)
        var s = rest
        (s, _) = Engine.reduce(s, .windowFrameChanged(veiled, Rect(
            x: belongs.minX, y: belongs.minY, width: 300, height: 250)))

        let (placing, effects) = Engine.reduce(s, .windowSelfPlaced(veiled))
        s = placing
        #expect(EngineFix.placement(of: veiled, in: effects) != nil, "the strip puts it back")
        #expect(Self.setScrims(effects) == nil)

        let (landed, landing) = Engine.reduce(s, .axLanded(veiled))
        #expect(Self.setScrims(landing) == Self.set(rest))
        #expect(Self.change(landing) == .cut, "no veil moved, so the mask changes at once")
        #expect(landed.scrims == rest.scrims)
    }

    /// **Most `windowSelfPlaced`s are our own writes echoing back to a stop**, already recut when they
    /// landed. A window that stopped where the strip put it writes nothing and sends nothing.
    @Test func anEchoThatStopsIsNotARecut() throws {
        let s = Self.uncovered(2)
        let veiled = try #require(Self.set(s).first).window
        let (_, effects) = Engine.reduce(s, .windowSelfPlaced(veiled))
        #expect(effects.isEmpty)
    }

    /// **A window emira does not write back is recut when it stops.** Nothing was written for a float
    /// its app moved, so nothing will land, and its stopping is the moment the desktop settled.
    @Test func aFloatThatPlacedItselfIsRecutWhenItStops() throws {
        let float = WindowId(9)
        let (created, arriving) = Engine.reduce(Self.world(2), .windowCreated(
            EngineFix.snapshot(9, role: .dialog)))
        var s = EngineFix.settle(created, arriving)
        #expect(!s.scrims.isEmpty)
        #expect(s.world.inFlight.isEmpty)

        (s, _) = Engine.reduce(s, .windowFrameChanged(float, Rect(x: 600, y: 100, width: 240, height: 180)))
        let (_, effects) = Engine.reduce(s, .windowSelfPlaced(float))
        #expect(EngineFix.placement(of: float, in: effects) == nil, "a float is the app's to place")
        #expect(Self.setScrims(effects) == Self.set(s))
        #expect(Self.change(effects) == .cut)
    }

    /// **A hand resize sets the veil down once the neighbours it re-tiled have landed**, not at
    /// `dragEnded` itself: adopting a width moves them, and a mask cut first is cut where they were.
    @Test func aHandResizeSetsTheVeilDownOnceItsNeighboursLand() throws {
        var s = Self.uncovered(2)
        let wider = Rect(x: 0, y: 0, width: 620, height: 800)
        (s, _) = EngineFix.run(s, [.dragBegan, .windowFrameChanged(WindowId(1), wider), .dragReleased])
        #expect(s.scrims.isEmpty, "lifted while the hand is on it")

        let (ended, effects) = Engine.reduce(s, .dragEnded)
        s = ended
        let written = Self.written(effects)
        #expect(written.contains(WindowId(2)), "the neighbour makes room")
        #expect(Self.setScrims(effects) == nil)

        var landing: [Effect] = []
        for id in written { (s, landing) = Engine.reduce(s, .axLanded(id)) }
        #expect(!s.scrims.isEmpty)
        #expect(Self.setScrims(landing) == Self.set(s))
        #expect(Self.change(landing) == .dissolve, "an ordinary set, which fades in")
    }

    /// **A covered transition is recut ahead of its dismissal.** Its set went at the teleport, masked
    /// against writes still on their way; the last landing sends it again in front of `endTransition`,
    /// so the repaint is under the cover rather than revealed by it.
    @Test func aCoveredTransitionIsRecutAheadOfItsDismissal() throws {
        var config = EngineFix.halfWidth
        config.unfocusedOpacity = 0.7
        config.transitionMode = .snap
        var s = EngineFix.world(3, config: config)
        s = EngineFix.settle(s, Engine.reduce(s, .command(.focus(.left))).1)
        var effects: [Effect] = []
        func feed(_ event: Event) { let (n, f) = Engine.reduce(s, event); s = n; effects = f }

        let monitor = MonitorId(1)
        feed(.command(.focus(.left)))
        for window in s.motion.transition(of: monitor)?.windows ?? [] { feed(.captureReady(window)) }
        feed(.coverOnScreen(monitor))
        let taught = try #require(Self.setScrims(effects), "the set goes at the teleport")
        let written = Self.written(effects)
        #expect(!written.isEmpty)

        var closing: [Effect] = []
        for id in written {
            feed(.axLanded(id))
            if effects.contains(where: { if case .endTransition = $0 { true } else { false } }) {
                closing = effects
            }
        }
        let dismissal = try #require(closing.firstIndex { if case .endTransition = $0 { true } else { false } },
                                     "`snap` closes on its last landing")
        let recut = try #require(closing.firstIndex { if case .setScrims = $0 { true } else { false } })
        #expect(recut < dismissal)
        #expect(Self.setScrims(closing) == taught)
        #expect(Self.change(closing) == .cut)
    }
}
