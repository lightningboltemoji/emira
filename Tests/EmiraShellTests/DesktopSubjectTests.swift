import Foundation
import Testing
import EmiraCore
import EmiraProtocol
@testable import EmiraShell

// The read that turns a `State` into what `watch` publishes: which facts a snapshot carries about a
// desktop, and which it leaves out so they cannot cost a watcher a line. The text itself is pinned in
// `EmiraProtocolTests/DesktopStatusTests`.

@Suite struct DesktopSubjectTests {

    static let working = Rect(x: 0, y: 0, width: 1000, height: 800)
    static let display = MonitorId(1)

    /// A bundle id's last word, capitalised — distinct from the id, so a test sees the name was asked.
    static func name(_ bundle: String) -> String { bundle.split(separator: ".").last!.capitalized }

    static func status(_ state: State) -> DesktopStatus {
        DesktopStatus(state: state, name: name)
    }

    static func reduce(_ state: State, _ events: Event...) -> State {
        events.reduce(state) { Engine.reduce($0, $1).0 }
    }

    static func snapshot(_ raw: UInt64, app: String, title: String = "w") -> WindowSnapshot {
        WindowSnapshot(id: WindowId(raw), bundleId: "com.test.\(app)", title: title, role: .standard,
                       frame: Rect(x: 0, y: 0, width: 10, height: 10))
    }

    /// Window 1 is `alpha`, window 2 `beta` and focused, one column each, on the main display.
    static func world(titles: (String, String) = ("w", "w"), guide: GuideSettings = GuideSettings())
        -> State {
        var state = State(config: Config(widthPresets: PresetCycle([.proportion(0.5)]),
                                         transitionMode: .off, guide: guide))
        state.setMonitors([MonitorInfo(id: display, frame: working, isMain: true, name: "Screen 1")])
        return reduce(state, .windowCreated(snapshot(1, app: "alpha", title: titles.0)),
                      .windowCreated(snapshot(2, app: "beta", title: titles.1)))
    }

    static func settled(_ start: State) -> State {
        var s = start
        for _ in 0..<2000 where s.motion.needsFrames { s = Engine.reduce(s, .tick(dt: 1.0 / 120)).0 }
        return s
    }

    @Test func aStripReadsAsItsColumnsInOrder() throws {
        let status = Self.status(Self.world())
        let display = try #require(status.displays.first)

        #expect(status.displays.count == 1)
        #expect(display.id == "1")
        #expect(display.name == "Screen 1")
        #expect(display.main && display.focused)
        #expect(display.workspace == .first)
        #expect(display.layout == .strip)
        #expect(display.columns.map(\.app) == ["Alpha", "Beta"])
        #expect(display.columns.map(\.focused) == [false, true])
        #expect(display.columns.flatMap(\.windows).map(\.id) == [WindowId(1), WindowId(2)])
        #expect(display.columns[1].windows.first?.bundle == "com.test.beta")
        #expect(display.pins.isEmpty)
    }

    @Test func focusSaysWhereItIs() throws {
        let focus = try #require(Self.status(Self.world()).focus)
        #expect(focus == DesktopStatus.Focus(display: "1", workspace: .first, window: WindowId(2),
                                             app: "Beta", bundle: "com.test.beta"))
    }

    /// Only an address with something on it, or on a screen, is listed — thirty-six rows of nothing
    /// would say nothing.
    @Test func workspacesAreTheOccupiedAndTheShown() {
        var state = Self.world()
        #expect(Self.status(state).workspaces
                == [DesktopStatus.Workspace(name: .first, display: "1", shown: true, windows: 2)])

        state = Self.reduce(state, .command(.moveToWorkspace(.name(WorkspaceName("3")!))))
        #expect(Self.status(state).workspaces == [
            DesktopStatus.Workspace(name: .first, display: "1", shown: true, windows: 1),
            DesktopStatus.Workspace(name: WorkspaceName("3")!, display: "1", shown: false, windows: 1),
        ])
    }

    @Test func anEmptyDesktopHasNoFocusAndNoColumns() throws {
        var state = State(config: Config(transitionMode: .off))
        state.setMonitors([MonitorInfo(id: Self.display, frame: Self.working, isMain: true, name: "Screen 1")])
        let status = Self.status(state)

        #expect(status.focus == nil)
        #expect(try #require(status.displays.first).columns.isEmpty)
        #expect(status.workspaces
                == [DesktopStatus.Workspace(name: .first, display: "1", shown: true, windows: 0)])
    }

    @Test func aCascadeSaysSo() throws {
        let state = Self.reduce(Self.world(), .command(.setLayout(.stack)))
        let display = try #require(Self.status(state).displays.first)
        #expect(display.layout == .stack)
        #expect(display.columns.flatMap(\.windows).map(\.id) == [WindowId(1), WindowId(2)])
    }

    /// A pinned window is on no workspace, so it is the display's rather than a column's, and focus on
    /// it names no workspace at all.
    @Test func aPinIsTheDisplaysNotAColumns() throws {
        let state = Self.reduce(Self.world(), .command(.pin(.left)))
        let status = Self.status(state)
        let display = try #require(status.displays.first)

        #expect(display.pins.map(\.side) == [.left])
        #expect(display.pins.map(\.window.id) == [WindowId(2)])
        #expect(display.columns.flatMap(\.windows).map(\.id) == [WindowId(1)])
        let focus = try #require(status.focus)
        #expect(focus.window == WindowId(2))
        #expect(focus.workspace == nil)
        #expect(focus.display == "1")
    }

    /// Two windows in one column are one name, and the window that earns it is the one taking most of
    /// the column — the names guide's own rule.
    @Test func aStackedColumnIsNamedByItsLargestWindow() throws {
        var state = Self.settled(Self.reduce(Self.world(), .command(.consumeOrExpel(.left))))
        let column = try #require(Self.status(state).displays.first?.columns.first)
        #expect(column.windows.map(\.id).sorted() == [WindowId(1), WindowId(2)])

        // Grow the focused window until it is the taller of the two, then ask again.
        func height(_ id: WindowId, in s: State) throws -> Double {
            let metrics = try #require(s.metrics(of: Self.display))
            return try #require(s.workspaces[.first].naturalFrames(scrollOffset: 0, metrics: metrics)[id])
                .height
        }
        var presses = 0
        while try height(WindowId(2), in: state) <= height(WindowId(1), in: state), presses < 3 {
            state = Self.settled(Self.reduce(state, .command(.cycleHeight)))
            presses += 1
        }
        try #require(try height(WindowId(2), in: state) > height(WindowId(1), in: state))
        #expect(try #require(Self.status(state).displays.first?.columns.first).app == "Beta")
    }

    /// A title changes whenever a terminal changes directory. It is not a fact a watcher is sent, so it
    /// cannot cost one a line.
    @Test func aTitleIsNotPublished() {
        #expect(Self.status(Self.world(titles: ("~", "~")))
                == Self.status(Self.world(titles: ("~/code", "vim notes.md"))))
    }

    /// A second display is listed with what it shows, and only one of them is the one verbs act on.
    @Test func everyDisplayIsListedAndOneIsFocused() throws {
        var state = Self.world()
        state.setMonitors([
            MonitorInfo(id: Self.display, frame: Self.working, isMain: true, name: "Screen 1"),
            MonitorInfo(id: MonitorId(2), frame: Rect(x: 1000, y: 0, width: 800, height: 600)),
        ])
        let status = Self.status(state)

        #expect(status.displays.map(\.id) == ["1", "2"])
        #expect(status.displays.map(\.focused) == [true, false])
        #expect(status.displays.map(\.main) == [true, false])
        let second = try #require(status.displays.last)
        #expect(second.columns.isEmpty)
        #expect(status.workspaces.contains(DesktopStatus.Workspace(name: second.workspace, display: "2",
                                                                   shown: true, windows: 0)))
    }

    /// `moving` is the core's own "something is in flight": a focus change sets the ring travelling,
    /// and it reads false again once the ring has arrived.
    @Test func movingIsTheCoresOwn() {
        let settled = Self.settled(Self.world())
        #expect(!Self.status(settled).moving)

        let focusing = Self.reduce(settled, .command(.focus(.left)))
        #expect(Self.status(focusing).moving == focusing.motion.needsFrames)
        #expect(!Self.status(Self.settled(focusing)).moving)
    }
}
