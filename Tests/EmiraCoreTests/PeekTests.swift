import Foundation
import Testing
@testable import EmiraCore

// A window is drawn on the display holding the largest share of it, and nowhere else. Everything here
// is silent with one display attached — a column hanging off the only screen has nowhere to be drawn
// but there — which is why the desktop these are written against has two, side by side:
//
//   left  (0, 0, 1000×800) — acting, holding the strip
//   right (1000, 0, 1200×900)
//
// Columns are 0.7 of the left display wide and the solo rule is off, so two windows make a strip whose
// second column, framed from the first, stands 300 on the left display and 400 on the right: a peek.

@Suite struct PeekTests {

    static let left = MonitorId(1), right = MonitorId(2)
    static let leftFrame = Rect(x: 0, y: 0, width: 1000, height: 800)
    static let rightFrame = Rect(x: 1000, y: 0, width: 1200, height: 900)
    static let wide = EngineFix.laddered(Config(widthPresets: PresetCycle([.proportion(0.7)])))

    /// Two displays, `count` windows on the left one's strip, at rest — focus on the newest.
    static func desktop(_ count: UInt64, config: Config = wide, alone: Bool = false) -> State {
        var s = State(config: config)
        let displays = alone ? [MonitorInfo(id: left, frame: leftFrame)]
            : [MonitorInfo(id: left, frame: leftFrame), MonitorInfo(id: right, frame: rightFrame)]
        (s, _) = Engine.reduce(s, .screensChanged(displays))
        for raw in 1...count {
            let (next, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(raw)))
            s = EngineFix.settle(next, fx)
        }
        return s
    }

    /// `desktop(2)` with the first column framed, which leaves the second hanging over the right display.
    static func peeking(config: Config = wide) -> State {
        let s = desktop(2, config: config)
        let (next, fx) = Engine.reduce(s, .command(.focus(.left)))
        return EngineFix.settle(next, fx)
    }

    static let peeker = WindowId(2)

    // What the window server draws where

    /// The rule the whole feature rests on: strictly more of a window here than on any other display.
    @Test func aDisplayDrawsAWindowItHoldsMoreOfThanAnyOther() {
        let here = Neighbourhood(frame: Self.leftFrame, others: [Self.rightFrame])
        #expect(here.draws(Rect(x: 600, y: 0, width: 700, height: 800)), "400 here, 300 there")
        #expect(!here.draws(Rect(x: 700, y: 0, width: 700, height: 800)), "300 here, 400 there")
        #expect(!here.draws(Rect(x: 650, y: 0, width: 700, height: 800)),
                "a tie is macOS's to break, so it is not counted as drawn here")
        #expect(here.draws(Rect(x: -400, y: 0, width: 700, height: 800)),
                "past an edge with nothing beyond, the window is drawn here, cut at the edge")
        #expect(Neighbourhood(frame: Self.leftFrame, others: [Self.leftFrame]).draws(
            Rect(x: 700, y: 0, width: 700, height: 800)), "a mirror is this display, not a neighbour")
    }

    /// Area, not width and not the centre: a window whose centre sits over the shorter display can
    /// still hold more of itself on the taller one.
    @Test func theDrawingDisplayIsTheLargestShareOfTheWindow() {
        var world = World()
        world.setMonitors([MonitorInfo(id: Self.left, frame: Self.leftFrame),
                           MonitorInfo(id: Self.right, frame: Rect(x: 1000, y: 0, width: 1200, height: 300))])
        // 250 wide on the left at the full 400 height, 150 wide on the right but only 300 of it tall.
        let window = Rect(x: 750, y: 0, width: 400, height: 400)
        #expect(world.monitor(drawing: window) == Self.left)
        #expect(world.monitor(drawing: Rect(x: 950, y: 0, width: 400, height: 200)) == Self.right)
        #expect(world.monitor(drawing: Rect(x: 5000, y: 0, width: 10, height: 10)) == nil)
    }

    // The placement pass

    /// The column the right display would draw is parked, and stood in for by a peek on the left one.
    @Test func aColumnHangingMostlyOverTheNeighbourIsParkedAndPeeks() {
        let s = Self.peeking()
        let peek = try! #require(s.world.peeks[Self.peeker])
        #expect(peek.monitor == Self.left)
        #expect(peek.frame.minX < Self.leftFrame.maxX && peek.frame.maxX > Self.leftFrame.maxX)
        #expect(!Neighbourhood(frame: Self.leftFrame, others: [Self.rightFrame]).draws(peek.frame))
        #expect(!s.world.placedOnScreen.contains(Self.peeker), "the real window is not on the glass…")
        #expect(s.world.parkedSlots[Self.peeker] != nil, "…it is in the lot…")
        #expect(s.world.isOnScreen(Self.peeker), "…and the user can still see its column")
        #expect(s.peeks == [peek], "and the shell has been told")
    }

    /// The same overhang the other way round: more of it on its own display, so macOS draws it there,
    /// cut at the edge, and it is placed like any column.
    @Test func aColumnHangingMostlyOverItsOwnDisplayIsPlaced() {
        let config = EngineFix.laddered(Config(widthPresets: PresetCycle([.proportion(0.55)])))
        let s = Self.peeking(config: config)
        #expect(s.world.placedOnScreen.contains(Self.peeker))
        #expect(s.world.peeks.isEmpty)
        #expect(s.peeks.isEmpty)
    }

    /// With nothing beyond the edge there is nobody to draw it instead, which is every single-display
    /// desktop: a peek is a fact about the arrangement, not about hanging off a screen.
    @Test func aColumnHangingOffADisplayWithNothingBeyondIsPlaced() {
        let s = EngineFix.settle(Engine.reduce(Self.desktop(2, alone: true), .command(.focus(.left))).0)
        #expect(s.world.placedOnScreen.contains(Self.peeker))
        #expect(s.world.peeks.isEmpty)
    }

    /// Hit-tested where it is seen: on its display's share of the column, never at the nub in the lot.
    @Test func thePointerFindsAPeekWhereItsPictureIs() {
        let s = Self.peeking()
        #expect(s.world.window(at: Point(x: 900, y: 400)) == Self.peeker)
        #expect(s.world.window(at: Point(x: 1100, y: 400)) == nil, "past the display's edge it is not drawn")
        let nub = try! #require(s.world.parkedSlots[Self.peeker])
        #expect(s.world.window(at: Point(x: nub.minX, y: nub.minY + 1)) != Self.peeker)
    }

    /// A peek is veiled like the column it stands for — on the display it is drawn on.
    @Test func thePeekIsVeiledOnItsOwnDisplay() {
        var config = Self.wide
        config.unfocusedOpacity = 0.5
        let s = Self.peeking(config: config)
        #expect(s.scrimBindings()[Self.left]?.map(\.window) == [Self.peeker])
        #expect(s.scrimBindings()[Self.right] == nil)
    }

    // Leaving a peek

    /// A click on the picture is a click on the column: it is focused and revealed, and back on the glass.
    @Test func clickingAPeekFocusesAndRevealsItsColumn() {
        let s = Self.peeking()
        let (clicked, fx) = Engine.reduce(s, .peekClicked(Self.peeker))
        #expect(fx.contains(.focus(Self.peeker)))
        let settled = EngineFix.settle(clicked, fx)
        #expect(settled.world.focusedWindow == Self.peeker)
        #expect(settled.world.placedOnScreen.contains(Self.peeker))
        #expect(settled.world.peeks.isEmpty && settled.peeks.isEmpty)
    }

    /// The click is the user going there, as a click on any window is: from the other display, focus
    /// crosses to the peek's, which reveals it while the display the user left keeps its strip.
    @Test func clickingAPeekOnTheOtherDisplayTakesTheUserThere() {
        var s = Self.peeking()
        s.monitors.focus(Self.right)
        s.world.setFocus(nil)
        let (clicked, fx) = Engine.reduce(s, .peekClicked(Self.peeker))
        let settled = EngineFix.settle(clicked, fx)
        #expect(settled.monitors.focused == Self.left)
        #expect(settled.world.focusedWindow == Self.peeker)
        #expect(settled.world.placedOnScreen.contains(Self.peeker))
        #expect(settled.peeks.isEmpty)
    }

    /// A click on a window that is not a peek asks for nothing: the picture it landed on is gone.
    @Test func aClickOnNoPeekDoesNothing() {
        let s = Self.desktop(2)
        #expect(Engine.reduce(s, .peekClicked(WindowId(1))).1.isEmpty)
    }

    /// The picture stands until the write putting the window back has landed: it is behind every window,
    /// so the window arriving over it is what hides it, and taken down first it leaves a hole.
    @Test func aPeekStandsUntilItsWindowIsBackOnTheGlass() {
        var config = Self.wide
        config.transitionMode = .off
        let s = Self.peeking(config: config)
        let (revealed, fx) = Engine.reduce(s, .peekClicked(Self.peeker))
        #expect(fx.contains { if case .setFrame(Self.peeker, _) = $0 { true } else { false } })
        #expect(revealed.world.peeks.isEmpty, "the placement pass has put it back…")
        #expect(revealed.peeks.map(\.window) == [Self.peeker], "…and the picture waits for it to land")

        let (landed, out) = Engine.reduce(revealed, .axLanded(Self.peeker))
        #expect(landed.peeks.isEmpty)
        #expect(out.contains(.setPeeks([])))
    }

    /// …and only for a window coming onto the glass. A column scrolled out of the viewport altogether
    /// is parked from lot to lot, with nothing landing over its picture, so the picture goes at once.
    @Test func aPeekScrolledAwayGoesAtOnce() {
        var s = Self.peeking()
        let peek = try! #require(s.world.peeks[Self.peeker])
        // A pass that parks it for good, with the write still out.
        s.world.notePlaced(onScreen: s.world.placedOnScreen, parked: s.world.parkedSlots, peeking: [:])
        s.world.noteWrite(Self.peeker, to: Rect(x: 990, y: 790, width: 700, height: 800))
        #expect(s.peeks == [peek], "what the shell is drawing…")
        #expect(s.peekBindings().isEmpty, "…comes down with the pass")
        // The same write putting it on the glass is what the picture waits for.
        s.world.notePlaced(onScreen: s.world.placedOnScreen.union([Self.peeker]), parked: [:], peeking: [:])
        #expect(s.peekBindings() == [peek])
    }

    // A window carried to another display

    /// A drop on another display moves the window there — beside what that display's strip holds, with
    /// focus and the user going with it — rather than taking it back across the desktop.
    @Test func aWindowPutDownOnAnotherDisplayMovesThere() {
        let s = Self.desktop(2)
        let carried = WindowId(1)
        let dropped = Rect(x: 1300, y: 100, width: 700, height: 700)
        let (after, fx) = EngineFix.run(s, [.dragBegan, .windowFrameChanged(carried, dropped),
                                             .dragReleased, .dragEnded])
        let settled = EngineFix.settle(after, fx)
        let home = try! #require(settled.workspaces.workspace(of: carried))
        #expect(settled.monitors.monitor(of: home) == Self.right)
        #expect(settled.monitors.focused == Self.right)
        #expect(settled.world.focusedWindow == carried)
        let frame = try! #require(settled.world.windows[carried]?.frame)
        #expect(Self.rightFrame.contains(frame.center), "placed on the strip it was dropped on")
        #expect(settled.workspaces.workspace(of: Self.peeker).flatMap(settled.monitors.monitor(of:))
                == Self.left, "and its neighbour stays where it was")
    }

    /// A drop that only moved the window on its own display is still taken back — and a size the system
    /// imposed on the way, fitting the window to the screen it was put down on, is not adopted as one the
    /// user drew: a carried window kept no edge where it was.
    @Test func aCarriedWindowsSizeIsNotADrawnOne() {
        var config = Self.wide
        config.transitionMode = .off
        let s = Self.desktop(2, config: config)
        let carried = Self.peeker
        let grabbed = try! #require(s.world.windows[carried]?.frame)
        // Moved down and left on its own display, and shortened by the move.
        let dropped = Rect(x: grabbed.minX - 100, y: grabbed.minY + 50, width: grabbed.width,
                           height: grabbed.height - 120)
        let (after, fx) = EngineFix.run(s, [.dragBegan, .windowFrameChanged(carried, dropped),
                                             .dragReleased, .dragEnded])
        #expect(after.workspaces.heightOverrides[carried] == nil, "no height was drawn")
        #expect(EngineFix.placement(of: carried, in: fx) == grabbed, "and the window goes back")
    }

    /// The same edge test keeps a real resize a resize: dragging the bottom edge holds the top one.
    @Test func aDraggedEdgeIsStillADrawnSize() {
        var config = Self.wide
        config.transitionMode = .off
        let s = Self.desktop(2, config: config)
        let grabbed = try! #require(s.world.windows[Self.peeker]?.frame)
        let drawn = Rect(x: grabbed.minX, y: grabbed.minY, width: grabbed.width, height: grabbed.height - 120)
        let (after, _) = EngineFix.run(s, [.dragBegan, .windowFrameChanged(Self.peeker, drawn),
                                            .dragReleased, .dragEnded])
        #expect(after.workspaces.heightOverrides[Self.peeker] != nil)
    }

    // The display a window leaves

    /// A window sent to another display can leave its own scrolled past the strip's end. The display it
    /// left frames nothing — focus went with the window — but it comes to rest inside its strip.
    @Test func theDisplayAWindowLeftComesToRestInsideItsStrip() {
        let s = Self.desktop(2, config: EngineFix.fullWidth)
        #expect(s.motion.offset(of: Self.left).current > 0, "framing the second of two full columns")
        let (moved, fx) = Engine.reduce(s, .command(.moveToMonitorAndFocus(.direction(.right))))
        let settled = EngineFix.settle(moved, fx)
        #expect(settled.monitors.focused == Self.right)
        #expect(settled.motion.offset(of: Self.left).current == 0)
        #expect(settled.world.placedOnScreen.contains(WindowId(1)), "the column left behind is in view")
    }
}
