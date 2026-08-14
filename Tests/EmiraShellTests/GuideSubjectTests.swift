import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The adapter between the truth plane and the guide's pure model: what one display's guide is drawn
// from, and what it is *about*. The arithmetic itself is `EmiraCoreTests/GuideModelTests` — what is
// asserted here is the read, which is the only half that needs a `State`.

@Suite struct GuideSubjectTests {

    static let working = Rect(x: 0, y: 0, width: 1000, height: 800)
    static let display = MonitorId(1)

    static func settings() -> GuideSettings {
        GuideSettings(preview: PreviewGuideSettings(enabled: true, position: .topRight, width: 0.3,
                                                    span: 3, gap: 16, duration: 1))
    }

    /// Two windows on a strip, at rest, with the guide on.
    static func world() -> State {
        var state = State(config: Config(widthPresets: PresetCycle([.proportion(1.0)]),
                                         transitionMode: .off,
                                         guide: settings()))
        state.setMonitors([MonitorInfo(id: display, frame: working)])
        for raw in UInt64(1)...2 {
            let (next, _) = Engine.reduce(state, .windowCreated(
                WindowSnapshot(id: WindowId(raw), bundleId: "com.test.app", title: "w",
                               role: .standard, frame: Rect(x: 0, y: 0, width: 10, height: 10))))
            state = next
        }
        return state
    }

    /// `world()`, plus a second display. Everything the core manages is still on the first, which is
    /// what "N in the shell, one managed" means.
    static func twoDisplays() -> State {
        var state = world()
        state.setMonitors([
            MonitorInfo(id: display, frame: working),
            MonitorInfo(id: MonitorId(2), frame: Rect(x: 1000, y: 0, width: 800, height: 600)),
        ])
        return state
    }

    /// …with the focus ring arrived, which the arrivals themselves set travelling.
    static func settled(_ start: State) -> State {
        var s = start
        for _ in 0..<2000 where s.motion.needsFrames { s = Engine.reduce(s, .tick(dt: 1.0 / 120)).0 }
        return s
    }

    static func input(_ state: State, on monitor: MonitorId = display) throws -> GuideInput {
        try #require(GuideInput(state: state, monitor: monitor))
    }

    static func layout(_ state: State, on monitor: MonitorId = display) throws -> GuideLayout {
        try #require(GuideModel.layout(try input(state, on: monitor), settings: state.config.guide.preview))
    }

    @Test func noDisplayYetMeansNothingToProjectOnto() {
        // A guide belongs to a display, and before the first `screensChanged` there is no display for
        // it to belong to.
        let state = State(config: Config(guide: Self.settings()))
        #expect(GuideInput(state: state, monitor: Self.display) == nil)
        #expect(GuideTrigger(state: state, monitor: Self.display) == nil)
    }

    @Test func aDetachedDisplayHasNeitherAnInputNorATrigger() {
        var state = Self.twoDisplays()
        state.setMonitors([MonitorInfo(id: Self.display, frame: Self.working)])
        #expect(GuideInput(state: state, monitor: MonitorId(2)) == nil)
        #expect(GuideTrigger(state: state, monitor: MonitorId(2)) == nil)
    }

    /// A guide draws the strips **its own display holds** and no others. On a second screen showing an
    /// empty address that is nothing at all — the panel is the bare viewport indicator, with none of
    /// the managed display's windows leaking into a panel they have nothing to do with.
    @Test func aSecondDisplayDrawsNoneOfTheFirstsWindows() throws {
        let state = Self.twoDisplays()
        let second = MonitorId(2)
        #expect(state.monitors.shown(on: second) != state.monitors.shown(on: Self.display))
        #expect(state.workspaces[state.monitors.shown(on: second)!].isEmpty)

        #expect(try Self.layout(state).tiles.count == 2)
        let empty = try Self.layout(state, on: second)
        #expect(empty.tiles.isEmpty)
        #expect(empty.separators.isEmpty)
    }

    /// The ring follows focus, not the panel: only the display holding the focused window draws one.
    @Test func onlyTheDisplayHoldingFocusDrawsARing() throws {
        let state = Self.settled(Self.twoDisplays())
        #expect(try Self.layout(state).ring != nil)
        #expect(try Self.layout(state, on: MonitorId(2)).ring == nil)
    }

    @Test func theStripIsTheShownWorkspacesColumnsInOrder() throws {
        let state = Self.world()
        let input = try Self.input(state)
        let shown = try #require(state.monitors.shown(on: Self.display))
        #expect(input.columns.map(\.id) == state.workspaces[shown].columns.map(\.id))
        #expect(input.columns.flatMap { $0.windows.map(\.id) } == [WindowId(1), WindowId(2)])
        #expect(input.columns.allSatisfy { $0.windows.allSatisfy { $0.bundleId == "com.test.app" } })
        // Nothing is passing through: one workspace is materialized, and it is the shown one.
        #expect(input.passing.isEmpty)
    }

    @Test func theRingLeavesTheOldTileAndTravelsToTheNewOne() throws {
        // Settled first: the second window's *arrival* is itself a focus change, so a freshly built
        // world already has a ring in flight.
        let state = Self.settled(Self.world())
        let atRest = try Self.layout(state)
        // At rest the ring sits exactly on the focused window's tile.
        let tolerance = 4.0
        let resting = try #require(atRest.tiles.first { $0.window == WindowId(2) }?.rect)
        #expect(abs(try #require(atRest.ring).minX - resting.minX) < tolerance)

        let (moved, _) = Engine.reduce(state, .command(.focus(.left)))
        let seeded = try Self.layout(moved)
        // The instant focus moves, the ring is still drawn over the window it is *leaving* — that
        // equality is what makes the travel read as travel rather than as a jump-then-slide.
        let departed = try #require(seeded.tiles.first { $0.window == WindowId(2) }?.rect)
        #expect(abs(try #require(seeded.ring).minX - departed.minX) < tolerance)

        // …and it arrives on the newly focused one.
        let arrived = try Self.layout(Self.settled(moved))
        let target = try #require(arrived.tiles.first { $0.window == WindowId(1) }?.rect)
        #expect(abs(try #require(arrived.ring).minX - target.minX) < tolerance)
    }

    /// **One layout, two hosts.** An input assembled by hand — which is all the settings window's mock
    /// desktop is — lands on exactly the layout the truth plane's own read produces.
    @Test func anInputBuiltByHandProducesTheSameLayoutAsOneReadFromTheWorld() throws {
        let state = Self.settled(Self.world())
        let read = try Self.input(state)
        let byHand = GuideInput(workingArea: read.workingArea,
                                columns: read.columns.map {
                                    GuideInput.Column(id: $0.id, windows: $0.windows)
                                },
                                passing: read.passing,
                                frames: read.frames, focus: read.focus,
                                focusDisplacement: read.focusDisplacement)
        #expect(GuideModel.layout(byHand, settings: state.config.guide.preview)
                == GuideModel.layout(read, settings: state.config.guide.preview))
    }

    // What the guide is about

    @Test func eachDisplaysTriggerNamesItsOwnWorkspaceAndItsOwnFocus() throws {
        let state = Self.twoDisplays()
        let first = try #require(GuideTrigger(state: state, monitor: Self.display))
        let second = try #require(GuideTrigger(state: state, monitor: MonitorId(2)))
        #expect(first.workspace == state.monitors.shown(on: Self.display))
        #expect(second.workspace == state.monitors.shown(on: MonitorId(2)))
        #expect(first.focused == state.world.focusedWindow)
        #expect(second.focused == nil)
        #expect(first != second)
        #expect(second.columns.isEmpty)
    }

    @Test func theTriggerReportsAChangeInTheValueNotInTheThingCarryingIt() {
        let state = Self.world()
        // An AX landing is not a reason to summon a HUD.
        let (landed, _) = Engine.reduce(state, .axLanded(WindowId(1)))
        #expect(GuideTrigger(state: landed, monitor: Self.display)
                == GuideTrigger(state: state, monitor: Self.display))

        let (refocused, _) = Engine.reduce(state, .command(.focus(.left)))
        #expect(GuideTrigger(state: refocused, monitor: Self.display)
                != GuideTrigger(state: state, monitor: Self.display))
    }

    @Test func theTriggerDoesNotMoveWithTheScrollsCurrentValue() {
        // It carries the scroll's *target*: a target moves once per command, a current value 120 times
        // a second — and a trigger that moved per frame would re-arm the dwell forever.
        var state = Self.world()
        let before = GuideTrigger(state: state, monitor: Self.display)
        state.motion.advance(by: 1.0 / 120, on: [Self.display],
                             holding: state.contents(of: Self.display))
        #expect(GuideTrigger(state: state, monitor: Self.display) == before)
    }
}
