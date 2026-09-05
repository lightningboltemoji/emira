import Foundation
import Testing
@testable import EmiraCore

// The pin verbs through the reducer: what leaves the strip, what places it, where focus goes, and what
// the strip does around it. Snapping throughout unless the test is about motion — these are about where
// things end up.

@Suite struct EnginePinTests {

    /// Two windows on a 1000-wide display, ½-width presets, no cover.
    static func world(_ count: UInt64 = 2) -> State {
        EngineFix.world(count, config: EngineFix.halfWidthSnap)
    }

    static func pin(_ s: State, _ intent: PinIntent) -> (State, [Effect]) {
        EngineFix.run(s, [.command(.pin(intent))])
    }

    // Membership

    @Test func aPinnedWindowLeavesTheStripAndKeepsFocus() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (after, _) = Self.pin(s, .left)
        #expect(!after.world.participatesInStrip(WindowId(2)))
        #expect(after.layout.columnIndex(ofWindow: WindowId(2)) == nil)
        #expect(after.world.focusedWindow == WindowId(2))
        #expect(after.world.isPinned(WindowId(2)))
        #expect(after.world.pinned(on: MonitorId(1), .left) == WindowId(2))
    }

    /// The place it vacated, so `focus-pinned` has somewhere to come back to.
    @Test func pinningHandsTheStripMemoryToTheColumnItLeft() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (after, _) = Self.pin(s, .left)
        #expect(after.world.lastStripFocus == WindowId(1))
    }

    @Test func pinOffPutsItBackOnTheStrip() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (pinned, fx) = Self.pin(s, .left)
        let (after, _) = Self.pin(EngineFix.settle(pinned, fx), .off)
        #expect(after.world.participatesInStrip(WindowId(2)))
        #expect(after.layout.columnIndex(ofWindow: WindowId(2)) != nil)
        #expect(!after.world.isPinned(WindowId(2)))
    }

    /// Reachable without visiting it: the subject is the focused window only when the focused window is
    /// itself a pin.
    @Test func pinOffFromTheStripReleasesWhatTheDisplayHolds() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (pinned, fx) = Self.pin(s, .left)
        var settled = EngineFix.settle(pinned, fx)
        settled.world.setFocus(WindowId(1))
        let (after, _) = Self.pin(settled, .off)
        #expect(after.world.pins.isEmpty)
    }

    @Test func toggleLetsGoOfTheSideItIsAlreadyOn() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (pinned, fx) = Self.pin(s, .toggleLeft)
        #expect(pinned.world.isPinned(WindowId(2)))
        let (after, _) = Self.pin(EngineFix.settle(pinned, fx), .toggleLeft)
        #expect(!after.world.isPinned(WindowId(2)))
    }

    @Test func pinningTheOtherSideMovesItRatherThanLettingItGo() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (left, fx) = Self.pin(s, .left)
        let (after, _) = Self.pin(EngineFix.settle(left, fx), .right)
        #expect(after.world.pins[WindowId(2)]?.side == .right)
        #expect(after.world.pinned(on: MonitorId(1), .left) == nil)
    }

    /// One window per side, and claiming a side dispossesses whoever held it — the rule `Monitors.show`
    /// runs on, one container over.
    @Test func claimingAHeldSideEvictsWhatWasThere() {
        var s = Self.world(3)
        s.world.setFocus(WindowId(2))
        let (first, fx) = Self.pin(s, .left)
        var settled = EngineFix.settle(first, fx)
        settled.world.setFocus(WindowId(3))
        let (after, _) = Self.pin(settled, .left)
        #expect(after.world.pinned(on: MonitorId(1), .left) == WindowId(3))
        #expect(!after.world.isPinned(WindowId(2)))
        #expect(after.world.participatesInStrip(WindowId(2)))
    }

    /// Both mean *off the strip*, so a second record of it would be a second authority on membership.
    @Test func floatingAndPinningAreExclusive() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (pinned, fx) = Self.pin(s, .left)
        var settled = EngineFix.settle(pinned, fx)
        settled.world.setFloating(WindowId(2), true)
        #expect(!settled.world.isPinned(WindowId(2)))

        settled.world.setPin(WindowId(2), on: MonitorId(1), side: .left)
        #expect(!settled.world.isFloatedByChoice(WindowId(2)))
    }

    // Placement

    @Test func thePinIsPlacedInItsBandAndTheStripBesideIt() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (after, fx) = Self.pin(s, .left)
        let settled = EngineFix.settle(after, fx)
        let metrics = try! #require(settled.metrics())
        let band = try! #require(metrics.pinFrame(.left))
        #expect(EngineFix.approx(settled.world.windows[WindowId(2)]!.frame, band))
        // The one still on the strip starts where the clear area does.
        #expect(EngineFix.approxScalar(settled.world.windows[WindowId(1)]!.frame.minX,
                                       metrics.contentArea.minX))
    }

    /// It is on the screen in every phase, so the record that answers "can the user see this" has to
    /// name it — `hoistBindings` and `[focus] system-events` both read that set.
    @Test func aPinIsOnScreen() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (after, fx) = Self.pin(s, .left)
        let settled = EngineFix.settle(after, fx)
        #expect(settled.world.placedOnScreen.contains(WindowId(2)))
        #expect(settled.world.isOnScreen(WindowId(2)))
    }

    /// Nothing new needed: `setPin` clears the float, and a hoist is only ever a float by choice.
    @Test func aPinIsNeverHoisted() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (after, fx) = Self.pin(s, .left)
        let settled = EngineFix.settle(after, fx)
        #expect(settled.hoistBindings().isEmpty)
    }

    // Focus

    @Test func focusLeftOffTheFirstColumnLandsOnALeftPin() {
        var s = Self.world(3)
        s.world.setFocus(WindowId(3))
        let (pinned, fx) = Self.pin(s, .left)
        var settled = EngineFix.settle(pinned, fx)
        settled.world.setFocus(WindowId(1))                 // the leftmost column
        let (after, effects) = EngineFix.run(settled, [.command(.focus(.left))])
        #expect(after.world.focusedWindow == WindowId(3))
        #expect(effects.contains(.focus(WindowId(3))))
    }

    @Test func focusRightOffALeftPinComesBackToWhereTheUserWas() {
        var s = Self.world(3)
        s.world.setFocus(WindowId(2))                       // the middle column
        let (pinned, fx) = Self.pin(s, .left)
        var settled = EngineFix.settle(pinned, fx)
        settled.world.setFocus(WindowId(3))
        settled.world.noteStripFocus(WindowId(3))
        let (onPin, pfx) = EngineFix.run(settled, [.command(.focusPinned)])
        #expect(onPin.world.focusedWindow == WindowId(2))
        let (after, _) = EngineFix.run(EngineFix.settle(onPin, pfx), [.command(.focus(.right))])
        #expect(after.world.focusedWindow == WindowId(3))
    }

    /// Only one of the four directions goes anywhere from a pin: the strip is one way and the display's
    /// own edge the other.
    @Test func focusOffTheOutsideOfAPinGoesNowhere() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (pinned, fx) = Self.pin(s, .left)
        let settled = EngineFix.settle(pinned, fx)
        for direction in [Direction.left, .up, .down] {
            let (after, effects) = EngineFix.run(settled, [.command(.focus(direction))])
            #expect(after.world.focusedWindow == WindowId(2), "\(direction) moved focus")
            #expect(effects.isEmpty, "\(direction) did something")
        }
    }

    @Test func focusPinnedIsAToggleWithOnePinAndACycleWithTwo() {
        var s = Self.world(3)
        s.world.setFocus(WindowId(2))
        let (left, lfx) = Self.pin(s, .left)
        var settled = EngineFix.settle(left, lfx)
        settled.world.setFocus(WindowId(3))
        let (both, bfx) = Self.pin(settled, .right)
        var start = EngineFix.settle(both, bfx)

        start.world.setFocus(WindowId(1))                   // the only window left on the strip
        let (onLeft, f1) = EngineFix.run(start, [.command(.focusPinned)])
        #expect(onLeft.world.focusedWindow == WindowId(2))
        let (onRight, f2) = EngineFix.run(EngineFix.settle(onLeft, f1), [.command(.focusPinned)])
        #expect(onRight.world.focusedWindow == WindowId(3))
        let (back, _) = EngineFix.run(EngineFix.settle(onRight, f2), [.command(.focusPinned)])
        #expect(back.world.focusedWindow == WindowId(1))
    }

    @Test func focusPinnedDoesNothingWithNoPin() {
        let (after, effects) = EngineFix.run(Self.world(), [.command(.focusPinned)])
        #expect(effects.isEmpty)
        #expect(after.world.focusedWindow == Self.world().world.focusedWindow)
    }

    // Where the strip is left

    /// **After pinning, returning to the strip must not move it.** The window that takes focus when the
    /// user comes back is decided the moment the pin is made, so the strip is framed on it then — and a
    /// scroll on the way back would be a move nobody asked for and nobody could predict.
    ///
    /// Two 70% columns and a pin seeded from one of them is the arrangement that exposes it: the strip
    /// is wider than what the pin leaves, so where it rests is a real choice rather than the only one.
    @Test func pinningLeavesTheStripWhereReturningToItWillFindIt() {
        let cfg = Config(widthPresets: PresetCycle([.proportion(0.7)]))
        var s = EngineFix.booted(config: cfg)
        for raw in 1...2 {
            let (next, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(UInt64(raw))))
            s = EngineFix.settle(next, fx)
        }
        let (right, rfx) = Engine.reduce(s, .command(.focus(.right)))
        s = EngineFix.settle(right, rfx)

        let (pinned, pfx) = Engine.reduce(s, .command(.pin(.left)))
        let settled = EngineFix.settle(pinned, pfx)
        let resting = settled.viewport.offset.current

        let (back, bfx) = Engine.reduce(settled, .command(.focusPinned))
        let returned = EngineFix.settle(back, bfx)
        #expect(returned.world.focusedWindow == WindowId(1), "focus-pinned did not reach the strip")
        #expect(EngineFix.approxScalar(returned.viewport.offset.current, resting),
                "the strip moved on the way back: \(resting) → \(returned.viewport.offset.current)")
    }

    /// …and what that framing buys: the column the strip rests on sits beside the pin rather than across
    /// it. The overlap is what the offset decides, so the two claims are one.
    @Test func theStripRestsBesideThePinRatherThanAcrossIt() {
        let cfg = Config(widthPresets: PresetCycle([.proportion(0.7)]))
        var s = EngineFix.booted(config: cfg)
        for raw in 1...2 {
            let (next, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(UInt64(raw))))
            s = EngineFix.settle(next, fx)
        }
        let (right, rfx) = Engine.reduce(s, .command(.focus(.right)))
        s = EngineFix.settle(right, rfx)
        let (pinned, pfx) = Engine.reduce(s, .command(.pin(.left)))
        let settled = EngineFix.settle(pinned, pfx)

        let band = try! #require(settled.metrics()?.pinFrame(.left))
        let onStrip = try! #require(settled.world.windows[WindowId(1)]?.frame)
        #expect(band.intersection(onStrip) == nil,
                "the strip rests across the pin: \(onStrip) over \(band)")
    }

    // Width

    /// The band starts at the width the column had, so pinning is a move and not a resize.
    @Test func aPinSeedsItsWidthFromTheColumnItLeft() {
        var s = EngineFix.world(2, config: Config(widthPresets: PresetCycle([.proportion(0.25)]),
                                                  transitionMode: .off))
        s.world.setFocus(WindowId(2))
        let (after, fx) = Self.pin(s, .left)
        let settled = EngineFix.settle(after, fx)
        #expect(EngineFix.approxScalar(settled.metrics()!.pinWidth(.left) ?? 0, 250))
    }

    @Test func growAndShrinkDriveTheFocusedPin() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (pinned, fx) = Self.pin(s, .left)
        let settled = EngineFix.settle(pinned, fx)
        let before = settled.metrics()!.pinWidth(.left)!

        let (grown, gfx) = EngineFix.run(settled, [.command(.grow(.percent(10)))])
        #expect(EngineFix.approxScalar(EngineFix.settle(grown, gfx).metrics()!.pinWidth(.left)!,
                                       before + 100))
        let (shrunk, sfx) = EngineFix.run(settled, [.command(.shrink(.points(50)))])
        #expect(EngineFix.approxScalar(EngineFix.settle(shrunk, sfx).metrics()!.pinWidth(.left)!,
                                       before - 50))
    }

    @Test func cycleWidthWalksThePinsOwnLadder() {
        let cycle = PresetCycle([.proportion(0.25), .proportion(0.5)])
        var s = EngineFix.world(2, config: Config(widthPresets: cycle, transitionMode: .off))
        s.world.setFocus(WindowId(2))
        let (pinned, fx) = Self.pin(s, .left)
        let settled = EngineFix.settle(pinned, fx)
        let (cycled, cfx) = EngineFix.run(settled, [.command(.cycleWidth)])
        #expect(EngineFix.approxScalar(EngineFix.settle(cycled, cfx).metrics()!.pinWidth(.left)!, 500))
    }

    /// The clamp is the geometry's, so the verb needs no ceiling of its own.
    @Test func aPinCannotBeGrownPastTheStrip() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (pinned, fx) = Self.pin(s, .left)
        var settled = EngineFix.settle(pinned, fx)
        for _ in 0..<20 {
            let (next, nfx) = EngineFix.run(settled, [.command(.grow(.percent(20)))])
            settled = EngineFix.settle(next, nfx)
        }
        #expect(settled.metrics()!.contentArea.width >= LayoutMetrics.minimumColumnWidth)
    }

    // Lifetime

    @Test func aDestroyedPinTakesItsRecordWithIt() {
        var s = Self.world()
        s.world.setFocus(WindowId(2))
        let (pinned, fx) = Self.pin(s, .left)
        let settled = EngineFix.settle(pinned, fx)
        let (after, _) = EngineFix.run(settled, [.windowDestroyed(WindowId(2))])
        #expect(after.world.pins.isEmpty)
        #expect(after.metrics()?.contentArea == after.metrics()?.nominalArea)
    }

    /// A pin belongs to a screen, so a screen leaving strands one — it goes to the display the user is
    /// on rather than quietly rejoining a strip nobody asked it to.
    @Test func aDepartedDisplaysPinFollowsTheUser() {
        let two = [MonitorInfo(id: MonitorId(1), frame: EngineFix.displayFrame),
                   MonitorInfo(id: MonitorId(2), frame: Rect(x: 1000, y: 0, width: 1000, height: 800))]
        var s = EngineFix.world(2, config: EngineFix.halfWidthSnap)
        let (attached, afx) = EngineFix.run(s, [.screensChanged(two)])
        s = EngineFix.settle(attached, afx)
        s.world.setPin(WindowId(2), on: MonitorId(2), side: .right)

        let (after, _) = EngineFix.run(s, [.screensChanged([two[0]])])
        #expect(after.world.pins[WindowId(2)]?.monitor == MonitorId(1))
        #expect(after.world.pins[WindowId(2)]?.side == .right)
    }
}

// The cover, held off the band its pins stand in

@Suite struct EnginePinCoverTests {

    /// Half-width presets and a pin taking half the screen, so the two columns left do not fit beside
    /// it and a focus change genuinely scrolls — which is what raises a cover to have a band cut out of.
    static let config = Config(widthPresets: PresetCycle([.proportion(0.5)]))

    static func pinnedWorld() -> (State, [Effect]) {
        var s = EngineFix.world(3, config: Self.config)
        s.world.setFocus(WindowId(3))
        let (pinned, fx) = EngineFix.run(s, [.command(.pin(.left))])
        return (EngineFix.settle(pinned, fx), fx)
    }

    static func clearings(_ fx: [Effect]) -> [EdgeInsets] {
        fx.compactMap { if case .setCoverClearing(_, let insets) = $0 { return insets } else { return nil } }
    }

    /// Answer the captures and the raise, and hand back everything emitted on the way — the clearing
    /// rides with `beginTransition`, which is two events after the command that asked for it.
    static func raised(_ start: State, _ effects: [Effect]) -> (State, [Effect]) {
        var s = start
        var queue = effects
        var all: [Effect] = []
        for _ in 0..<50 {
            var feedback: [Event] = []
            for effect in queue {
                switch effect {
                case .capture(_, let w, _): feedback.append(.captureReady(w))
                case .beginTransition(let m, _): feedback.append(.coverOnScreen(m))
                default: continue
                }
            }
            guard !feedback.isEmpty else { return (s, all) }
            queue = []
            for event in feedback {
                let (next, out) = Engine.reduce(s, event)
                s = next
                queue += out
                all += out
            }
        }
        return (s, all)
    }

    @Test func aDesktopWithNoPinNeverClearsAnything() {
        var s = EngineFix.world(3, config: Self.config)
        s.world.setFocus(WindowId(2))
        let (scrolling, command) = EngineFix.run(s, [.command(.focus(.left))])
        let (after, fx) = Self.raised(scrolling, command)
        #expect(after.motion.hasLayers(on: MonitorId(1)), "the scroll has to raise a cover to be a test")
        #expect(Self.clearings(fx).isEmpty)
        #expect(after.coverClearing.isEmpty)
    }

    /// A scroll past a standing pin: the cover stops at the band, so the real window stays live in it.
    @Test func aCoverStopsAtTheBandOfAPinItIsNotDrawing() {
        var (s, _) = Self.pinnedWorld()
        s.world.setFocus(WindowId(2))
        let insets = s.metrics()!.pinInsets
        let (scrolling, command) = EngineFix.run(s, [.command(.focus(.left))])
        // Emitted with the raise, not with the command: nothing is on the glass while the stills are out.
        #expect(Self.clearings(command).isEmpty)
        let (after, fx) = Self.raised(scrolling, command)
        #expect(Self.clearings(fx).contains(insets))
        #expect(after.coverClearing[MonitorId(1)] == insets)
        #expect(insets.left > 0 && insets.right == 0)
    }

    /// **The band stays clear for the whole cross-fade**, and this is the sharp edge of it: a cover
    /// holds its stand-ins until the fade completes, and the column that just scrolled off the strip's
    /// near end is at a natural frame reaching right across the band. Growing the cover back at
    /// `endTransition` unclips that stand-in and draws it over the pin for the length of the fade.
    @Test func theBandIsHeldClearUntilTheCoverIsActuallyDown() {
        var (s, _) = Self.pinnedWorld()
        s.world.setFocus(WindowId(2))
        let insets = s.metrics()!.pinInsets
        let (moved, fx) = EngineFix.run(s, [.command(.focus(.left))])
        let settled = EngineFix.settle(moved, fx)

        // The mechanism, stated rather than argued: the column that scrolled off the near end is drawn
        // at a natural frame reaching right across the band, and only the cover's clip holds it back.
        let band = Rect(x: 0, y: 0, width: insets.left, height: s.metrics()!.workingArea.height)
        let (covered, _) = Self.raised(moved, fx)
        let (_, blits) = Engine.reduce(covered, .tick(dt: 1.0 / 120))
        #expect(blits.contains { if case .setLayerFrame(_, let r) = $0 { return r.intersects(band) }
                                 else { return false } },
                "no stand-in reaches the band, so this no longer tests what it was written for")

        // `settle` answers every ack a live system gives *except* the cross-fade, so this is the state
        // the desktop is in for the whole 220 ms the cover takes to go.
        #expect(settled.coverClearing[MonitorId(1)] == insets, "the band was given back mid-fade")
        #expect(!settled.motion.isTransitioning)

        let (down, fx2) = Engine.reduce(settled, .crossfadeDone(MonitorId(1)))
        #expect(down.coverClearing.isEmpty)
        #expect(fx2.contains(.setCoverClearing(MonitorId(1), .zero)))
    }

    /// A command landing inside the cross-fade opens a new cover, and the shape then belongs to that
    /// one — the late report from the cover it superseded must not hand the band back under it.
    @Test func aCoverRaisedInsideTheFadeKeepsTheBand() {
        var (s, _) = Self.pinnedWorld()
        s.world.setFocus(WindowId(2))
        let insets = s.metrics()!.pinInsets
        let (moved, fx) = EngineFix.run(s, [.command(.focus(.left))])
        var settled = EngineFix.settle(moved, fx)
        settled.world.setFocus(WindowId(1))
        let (again, afx) = EngineFix.run(settled, [.command(.focus(.right))])
        let (raised, _) = EnginePinCoverTests.raised(again, afx)
        #expect(raised.motion.hasLayers(on: MonitorId(1)))

        let (after, out) = Engine.reduce(raised, .crossfadeDone(MonitorId(1)))
        #expect(after.coverClearing[MonitorId(1)] == insets)
        #expect(out.isEmpty)
    }

    /// A pin the session is *drawing* is a stand-in like any other window, so its band is covered —
    /// leaving it clear would show the real one teleporting beside its own layer.
    @Test func aPinBeingResizedIsCoveredRatherThanClearedFor() {
        let (s, _) = Self.pinnedWorld()
        #expect(s.world.focusedWindow == WindowId(3))     // still on the pin
        let (after, fx) = EngineFix.run(s, [.command(.grow(.percent(10)))])
        #expect(after.motion.transition(of: MonitorId(1))?.windows.contains(WindowId(3)) == true)
        #expect(after.coverClearing[MonitorId(1)] == nil)
        #expect(Self.clearings(fx).allSatisfy { $0 == .zero })
    }

    /// The band and the layer clip are the same edge, so a column sliding off the strip is cut where
    /// the pin begins rather than at the display's own edge.
    @Test func theClearedBandIsWhereTheStripStops() {
        let (s, _) = Self.pinnedWorld()
        let metrics = s.metrics()!
        #expect(metrics.pinInsets.left == metrics.screenArea.minX - metrics.workingArea.minX)
        #expect(metrics.screenArea.minX == metrics.pinFrame(.left)!.maxX)
    }
}

// The teleport gate: nothing moves over a live pin until the window server says the pin is on top

@Suite struct EnginePinGateTests {

    static let config = Config(widthPresets: PresetCycle([.proportion(0.5)]))

    /// A left pin 500 wide, two columns of 500 beside it, and window 2 sitting **over the band** — the
    /// state a teleport must not be allowed to happen in, since the cover leaves that band clear.
    static func overlapping() -> State {
        var s = EngineFix.world(3, config: Self.config)
        s.world.setFocus(WindowId(3))
        let (pinned, fx) = EngineFix.run(s, [.command(.pin(.left))])
        var settled = EngineFix.settle(pinned, fx)
        settled.world.setFocus(WindowId(2))
        let (drifted, _) = EngineFix.run(settled, [
            .windowFrameChanged(WindowId(2), Rect(x: 100, y: 0, width: 500, height: 800)),
        ])
        return drifted
    }

    static func requests(_ fx: [Effect]) -> [WindowId] {
        fx.compactMap { if case .confirmFocus(let id, _) = $0 { return id } else { return nil } }
    }

    static func focuses(_ fx: [Effect]) -> [WindowId] {
        fx.compactMap { if case .focus(let id) = $0 { return id } else { return nil } }
    }

    /// The ordinary desktop pays nothing: no pin means no fence on the path of every scroll.
    @Test func noPinAsksForNothing() {
        var s = EngineFix.world(3, config: Self.config)
        s.world.setFocus(WindowId(2))
        let (_, fx) = EngineFix.run(s, [.command(.focus(.left))])
        #expect(Self.requests(fx).isEmpty)
    }

    /// …and neither does a pin nothing is about to be drawn over.
    @Test func aPinNothingOverlapsAsksForNothing() {
        var (s, _) = EnginePinCoverTests.pinnedWorld()
        s.world.setFocus(WindowId(2))
        let (_, fx) = EngineFix.run(s, [.command(.focus(.left))])
        #expect(Self.requests(fx).isEmpty)
    }

    @Test func aWindowOverTheBandIsAskedAboutInTheHeadBatch() {
        let s = Self.overlapping()
        let (_, fx) = EngineFix.run(s, [.command(.focus(.left))])
        #expect(Self.requests(fx) == [WindowId(3)])
        // Beside the captures, so the activation round trip overlaps the capture head.
        #expect(EngineFix.hasEffect(fx) { if case .capture = $0 { return true } else { return false } })
    }

    /// The cover reaching the glass is no longer enough on its own.
    @Test func theCoverOnItsOwnDoesNotMoveAnything() {
        let start = Self.overlapping()
        let (s, command) = EngineFix.run(start, [.command(.focus(.left))])
        var state = s
        var effects: [Effect] = []
        for effect in command {
            if case .capture(_, let w, _) = effect {
                let (next, out) = Engine.reduce(state, .captureReady(w))
                state = next
                effects += out
            }
        }
        let raise = try! #require(effects.first { if case .beginTransition = $0 { return true } else { return false } })
        guard case .beginTransition(let monitor, _) = raise else { return }
        let (covered, teleport) = Engine.reduce(state, .coverOnScreen(monitor))
        #expect(covered.motion.isCovered(on: monitor))
        #expect(!covered.motion.mayPlace(on: monitor), "the pin has not come forward yet")
        #expect(!EngineFix.hasEffect(teleport) { if case .setFrame = $0 { return true } else { return false } })

        // …and the confirmation is what releases it.
        let (moved, fx) = Engine.reduce(covered, .focusConfirmed(WindowId(3)))
        #expect(moved.motion.mayPlace(on: monitor))
        #expect(EngineFix.hasEffect(fx) { if case .setFrame = $0 { return true } else { return false } })
    }

    /// Focusing the target is what puts its app back above the pin, so it goes last.
    @Test func theFocusTheCommandAskedForIsHeldBackAndThenPaid() {
        let start = Self.overlapping()
        let (s, command) = EngineFix.run(start, [.command(.focus(.left))])
        #expect(Self.focuses(command).isEmpty, "focus must not go out while the pin is coming forward")
        #expect(s.owedFocus[MonitorId(1)] == WindowId(1))
        #expect(s.world.focusedWindow == WindowId(1), "the core already believes the focus moved")

        let settled = EngineFix.settle(s, command)
        #expect(settled.owedFocus.isEmpty)
    }

    /// Every exit owes it, including the one where nothing ever answered.
    @Test func aTimedOutCoverStillPaysTheFocusItOwes() {
        let start = Self.overlapping()
        let (s, command) = EngineFix.run(start, [.command(.focus(.left))])
        #expect(s.owedFocus[MonitorId(1)] == WindowId(1))
        let (after, fx) = Engine.reduce(s, .holdTimeout(MonitorId(1)))
        #expect(after.owedFocus.isEmpty)
        #expect(Self.focuses(fx) == [WindowId(1)])
    }

    /// A second answer about a pin already confirmed finds the display clear and does nothing — which
    /// is what keeps a late poll from re-teleporting and clearing a landing wait that is still open.
    @Test func aDuplicateConfirmationChangesNothing() {
        let start = Self.overlapping()
        let (s, command) = EngineFix.run(start, [.command(.focus(.left))])
        let settled = EngineFix.settle(s, command)
        let (after, fx) = Engine.reduce(settled, .focusConfirmed(WindowId(3)))
        #expect(fx.isEmpty)
        #expect(after.motion.isTransitioning == settled.motion.isTransitioning)
    }
}

extension EnginePinGateTests {

    /// A 20% pin on the left and two 50% columns beside it, each window its own app — the arrangement
    /// where the strip's near-end column genuinely overhangs the band, because 2 × 50% of the *nominal*
    /// area does not fit in the 80% the pin leaves.
    static func overhanging() -> State {
        let cfg = Config(widthPresets: PresetCycle([.proportion(0.5)]))
        var s = EngineFix.booted(config: cfg)
        for raw in 1...3 {
            let (next, fx) = Engine.reduce(s, .windowCreated(
                EngineFix.snapshot(UInt64(raw), bundle: "com.test.app\(raw)")))
            s = EngineFix.settle(next, fx)
        }
        s.world.setFocus(WindowId(3))
        let (pinned, pfx) = Engine.reduce(s, .command(.pin(.left)))
        var st = EngineFix.settle(pinned, pfx)
        st.world.setPinWidth(WindowId(3), preset: 0, override: .proportion(0.2))
        let (folded, ffx) = Engine.reduce(st, .configChanged(st.config))
        return EngineFix.settle(folded, ffx)
    }

    /// **A window scrolling *into* the band is the case the fence exists for**, and its current frame is
    /// still in the clear area when the command lands — so the at-risk set has to read where the teleport
    /// is going, not only where the windows are.
    ///
    /// The whole sequence, end to end: walk into the strip, to its near end, then right. That last step
    /// moves the near column across the band, and what it must leave behind is the pin on top of it.
    @Test func aColumnScrollingIntoTheBandEndsUpUnderThePin() {
        var st = Self.overhanging()
        let pin = try! #require(st.metrics()?.pinFrame(.left))
        for command in [Command.focusPinned, .focus(.left)] {
            let (next, fx) = Engine.reduce(st, .command(command))
            st = EngineFix.settle(next, fx)
        }

        let (moved, fx) = Engine.reduce(st, .command(.focus(.right)))
        // The fence fires on the destination, and the focus the command asked for waits behind it.
        #expect(Self.requests(fx) == [WindowId(3)])
        #expect(Self.focuses(fx).isEmpty)
        #expect(moved.owedFocus[MonitorId(1)] == WindowId(2))

        let settled = EngineFix.settle(moved, fx)
        let over = try! #require(settled.world.windows[WindowId(1)]?.frame)
        // The overhang is real — 2 × 50% cannot fit in the 80% the pin leaves — and that is the point:
        // the window is under the pin rather than not there.
        #expect(pin.intersection(over) != nil, "nothing overhangs, so this tests nothing")
        #expect(StackOrder(settled.world).isInFront(WindowId(3), of: WindowId(1)),
                "the pin was buried by the column that scrolled behind it")
        #expect(settled.world.focusedWindow == WindowId(2), "the focus the command asked for was not paid")
    }

    /// A pin released while its own confirmation is being taken leaves nothing to ask about, and a queue
    /// holding one nothing can answer would hold the teleport open until the deadline.
    @Test func aPinReleasedMidFenceDoesNotWedgeTheTeleport() {
        let start = Self.overlapping()
        let (gated, command) = EngineFix.run(start, [.command(.focus(.left))])
        #expect(!gated.motion.isPinCleared(on: MonitorId(1)))

        var released = gated
        released.world.clearPin(WindowId(3))
        let (after, _) = Engine.reduce(released, .focusConfirmed(WindowId(3)))
        #expect(after.motion.isPinCleared(on: MonitorId(1)))
        #expect(EngineFix.settle(after, command).motion.isTransitioning == false)
    }
}

extension EnginePinGateTests {

    /// Drive to the point the fence releases and no further: captures answered, cover on the glass, the
    /// pin confirmed — but nothing landed, so the windows crossing the band are still in flight.
    static func confirmed(_ start: State, _ effects: [Effect]) -> State {
        var s = start
        var queue = effects
        for _ in 0..<50 {
            var feedback: [Event] = []
            for effect in queue {
                switch effect {
                case .capture(_, let w, _): feedback.append(.captureReady(w))
                case .beginTransition(let m, _): feedback.append(.coverOnScreen(m))
                case .confirmFocus(let w, _):
                    feedback.append(.focusChanged(w, origin: .ours))
                    feedback.append(.focusConfirmed(w))
                default: continue                       // deliberately no `axLanded`
                }
            }
            guard !feedback.isEmpty else { return s }
            queue = []
            for event in feedback {
                let (next, out) = Engine.reduce(s, event)
                s = next
                queue += out
            }
        }
        return s
    }

    /// The overhanging world, walked onto the strip's near end — the state one `focus right` gates.
    static func atTheNearEnd() -> State {
        var s = Self.overhanging()
        for command in [Command.focusPinned, Command.focus(.left)] {
            let (next, fx) = Engine.reduce(s, .command(command))
            s = EngineFix.settle(next, fx)
        }
        return s
    }

    /// **The fence's write is a stacking operation, not the user's answer about where they are
    /// working.** Its echo says an app came forward; `owedFocus` is what holds the focus.
    @Test func theFencesOwnWriteDoesNotMoveTheUsersFocus() {
        let (gated, fx) = Engine.reduce(Self.atTheNearEnd(), .command(.focus(.right)))
        #expect(Self.requests(fx) == [WindowId(3)])

        let (echoed, out) = Engine.reduce(gated, .focusChanged(WindowId(3), origin: .ours))
        #expect(out.isEmpty)
        #expect(echoed.world.focusedWindow == WindowId(2), "the user is where the command put them")
        #expect(echoed.owedFocus[MonitorId(1)] == WindowId(2))
        // The activation is still recorded — a float behind the pin is buried by it either way.
        #expect(StackOrder(echoed.world).isInFront(WindowId(3), of: WindowId(1)))
    }

    /// …and so a command arriving while the pin is coming forward reads the strip, not the pin. Held
    /// keybinds land here: without it the second press resolves as *re-enter the strip* and is
    /// swallowed, and `focus-pinned` toggles the wrong way.
    @Test func aCommandDuringTheGateActsOnTheStripAndNotThePin() {
        let (gated, _) = Engine.reduce(Self.atTheNearEnd(), .command(.focus(.right)))
        let (echoed, _) = Engine.reduce(gated, .focusChanged(WindowId(3), origin: .ours))

        // Read off the pin, `left` is the direction *away* from the strip and goes nowhere at all.
        let (again, _) = Engine.reduce(echoed, .command(.focus(.left)))
        #expect(again.world.focusedWindow == WindowId(1), "the press moved a column, not nowhere")

        let (pinned, _) = Engine.reduce(echoed, .command(.focusPinned))
        #expect(pinned.world.focusedWindow == WindowId(3), "the toggle went to the pin, not back")
    }

    /// The debt is paid **on top of** the pin, and that write reasserts a focus the core already holds,
    /// so the ordering is the core's to record rather than two apps' notifications to race over.
    @Test func theOwedFocusIsRecordedAsActivatedAfterThePin() {
        let (gated, fx) = Engine.reduce(Self.atTheNearEnd(), .command(.focus(.right)))
        let settled = EngineFix.settle(gated, fx)
        #expect(settled.owedFocus.isEmpty)
        #expect(StackOrder(settled.world).isInFront(WindowId(2), of: WindowId(3)),
                "the focus the command asked for ended up above the pin")
    }

    /// **A gate speaks for its own display only.** A pin coming forward on one screen says nothing
    /// about a focus landing on another, and stealing it would also drop the debt already owed here.
    @Test func aGateHoldsOnlyItsOwnDisplaysFocus() {
        var s = EngineFix.booted(config: Self.config)
        let (wide, _) = Engine.reduce(s, .screensChanged([
            MonitorInfo(id: MonitorId(1), frame: EngineFix.displayFrame),
            MonitorInfo(id: MonitorId(2), frame: Rect(x: 1000, y: 0, width: 1000, height: 800))]))
        s = wide
        for raw in 1...3 {
            let (next, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(UInt64(raw))))
            s = EngineFix.settle(next, fx)
        }
        // Window 4 belongs to the second display's workspace.
        let (across, xfx) = Engine.reduce(s, .command(.focusMonitor(.direction(.right))))
        s = EngineFix.settle(across, xfx)
        let (made, cfx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(4)))
        s = EngineFix.settle(made, cfx)
        let (home, hfx) = Engine.reduce(s, .command(.focusMonitor(.direction(.left))))
        s = EngineFix.settle(home, hfx)

        // A pin on display 1, with window 2 standing over its band, and a gate open there.
        s.world.setFocus(WindowId(3))
        let (pinned, pfx) = Engine.reduce(s, .command(.pin(.left)))
        s = EngineFix.settle(pinned, pfx)
        s.world.setFocus(WindowId(2))
        let (drifted, _) = Engine.reduce(s, .windowFrameChanged(
            WindowId(2), Rect(x: 100, y: 0, width: 500, height: 800)))
        let (gated, _) = Engine.reduce(drifted, .command(.focus(.left)))
        let owed = try! #require(gated.owedFocus[MonitorId(1)])

        let (jumped, fx) = Engine.reduce(gated, .command(.focusMonitor(.direction(.right))))
        #expect(Self.focuses(fx) == [WindowId(4)], "the other display's focus is not this gate's")
        #expect(jumped.owedFocus[MonitorId(1)] == owed, "and it did not overwrite the debt owed here")
    }

    /// The hold and the pay are one predicate. A focus arriving after the pin is confirmed but while a
    /// window is still crossing the band would otherwise go out at once — putting its app back over the
    /// pin, which is the whole thing the sequence exists to prevent.
    @Test func aFocusArrivingWhileAWindowStillCrossesTheBandWaitsToo() {
        let (gated, fx) = Engine.reduce(Self.atTheNearEnd(), .command(.focus(.right)))
        let s = Self.confirmed(gated, fx)
        #expect(s.motion.isPinCleared(on: MonitorId(1)))
        #expect(!s.motion.pinClearance(on: MonitorId(1)).isEmpty, "still in flight over the band")

        // `focus-pinned` opens no transition, so nothing re-arms the gate on its behalf.
        let (asked, out) = Engine.reduce(s, .command(.focusPinned))
        #expect(Self.focuses(out).isEmpty)
        #expect(asked.owedFocus[MonitorId(1)] == WindowId(3), "the newer intent is what is owed")
    }

    /// A display's cover goes with it and never reports its cross-fade, so the shape it was holding has
    /// nothing left to release it — and a returning display is rebuilt flush with its own screen.
    @Test func aDepartedDisplayDoesNotLeaveItsCoverShapeBehind() {
        var (s, _) = EnginePinCoverTests.pinnedWorld()
        s.world.setFocus(WindowId(2))
        let (open, fx) = Engine.reduce(s, .command(.focus(.left)))
        let covered = Self.confirmed(open, fx)
        #expect(covered.coverClearing[MonitorId(1)] != nil)

        let (gone, _) = Engine.reduce(covered, .screensChanged([]))
        #expect(gone.coverClearing.isEmpty, "the shape went with the display")

        let (backAgain, bfx) = Engine.reduce(gone, .screensChanged([
            MonitorInfo(id: MonitorId(1), frame: EngineFix.displayFrame)]))
        let back = EngineFix.settle(backAgain, bfx)
        #expect(back.coverClearing.isEmpty)

        let (again, afx) = Engine.reduce(back, .command(.focus(.right)))
        let (after, emitted) = EnginePinCoverTests.raised(again, afx)
        #expect(after.motion.hasLayers(on: MonitorId(1)), "the scroll has to raise a cover to be a test")
        #expect(!EnginePinCoverTests.clearings(emitted).isEmpty,
                "the returning display's cover is cut back out")
    }
}
