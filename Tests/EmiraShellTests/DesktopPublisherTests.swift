import Foundation
import Testing
import EmiraCore
import EmiraProtocol
@testable import EmiraShell

// What reaches a watcher, and when: a line only when what is published changes, none while nobody is
// listening, and about two per command however many ticks it takes. The socket that carries them is
// `SocketServerTests`.

/// A stand-in for the socket server: whether anyone is listening is the test's to say, and every line
/// it is handed is kept, decoded.
final class RecordingWatchers: DesktopWatchers, @unchecked Sendable {
    var isWatched = true
    var lines: [DesktopStatus] = []

    func broadcast(_ reply: Reply) {
        guard case .desktop(let json) = reply.outcome,
              let status = try? JSONDecoder().decode(DesktopStatus.self, from: Data(json.utf8)) else {
            Issue.record("broadcast something other than a desktop: \(reply.outcome)")
            return
        }
        lines.append(status)
    }
}

@Suite @MainActor struct DesktopPublisherTests {

    static func publisher(_ watchers: RecordingWatchers) -> DesktopPublisher {
        let publisher = DesktopPublisher(names: GuideNames())
        publisher.watchers = watchers
        return publisher
    }

    static func world() -> State { DesktopSubjectTests.settled(DesktopSubjectTests.world()) }

    @Test func nobodyListeningIsSentNothing() {
        let watchers = RecordingWatchers()
        watchers.isWatched = false
        let publisher = Self.publisher(watchers)

        publisher.stateChanged(Self.world())
        publisher.stateChanged(DesktopSubjectTests.reduce(Self.world(), .command(.focus(.left))))
        #expect(watchers.lines.isEmpty)
    }

    /// A drain that changes nothing published — an AX write landing, a frame report — is no line.
    @Test func aLineIsAChangeInWhatIsPublished() {
        let watchers = RecordingWatchers()
        let publisher = Self.publisher(watchers)
        let state = Self.world()

        publisher.stateChanged(state)
        #expect(watchers.lines.count == 1)
        publisher.stateChanged(state)
        publisher.stateChanged(DesktopSubjectTests.reduce(state, .axLanded(WindowId(1))))
        #expect(watchers.lines.count == 1)
    }

    /// With the minimap on, a focus change sets its ring travelling: one line when focus moves and one
    /// when the ring arrives — never one per tick, though a tick is a drain.
    @Test func aCommandCostsTwoLinesNotOnePerTick() throws {
        let watchers = RecordingWatchers()
        let publisher = Self.publisher(watchers)
        var state = DesktopSubjectTests.settled(
            DesktopSubjectTests.world(guide: GuideSubjectTests.settings()))
        publisher.stateChanged(state)
        watchers.lines = []

        state = DesktopSubjectTests.reduce(state, .command(.focus(.left)))
        publisher.stateChanged(state)
        var ticks = 0
        while state.motion.needsFrames && ticks < 2000 {
            state = Engine.reduce(state, .tick(dt: 1.0 / 120)).0
            publisher.stateChanged(state)
            ticks += 1
        }

        #expect(ticks > 1, "the ring should take several frames to arrive")
        #expect(watchers.lines.map(\.moving) == [true, false])
        #expect(watchers.lines.map { $0.focus?.window } == [WindowId(1), WindowId(1)])
    }

    /// A new watcher is sent the desktop as it stands, and that is what the next drain is compared
    /// against — so nobody is sent it twice.
    @Test func aNewWatchersFirstLineIsTheDesktopAsItStands() throws {
        let watchers = RecordingWatchers()
        let publisher = Self.publisher(watchers)
        let state = Self.world()

        guard case .desktop(let json) = publisher.snapshot(state).outcome else {
            Issue.record("a watch should be answered with the desktop")
            return
        }
        let first = try JSONDecoder().decode(DesktopStatus.self, from: Data(json.utf8))
        #expect(first.focus?.window == WindowId(2))
        #expect(first.displays.first?.name == "Screen 1")

        publisher.stateChanged(state)
        #expect(watchers.lines.isEmpty)
    }
}
