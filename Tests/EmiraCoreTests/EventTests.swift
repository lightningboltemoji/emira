import Foundation
import Testing
@testable import EmiraCore

/// The exhaustive input vocabulary and its boundary DTOs. `Event` *is* the deterministic replay log,
/// so a faithful `Codable` round-trip is the contract that matters.
@Suite struct EventTests {

    /// One value of every case, including all three `focusChanged` shapes and payloads that carry the
    /// DTOs. This list is the exhaustiveness checklist for `Event`.
    static let all: [Event] = [
        .command(.focus(.left)),
        .command(.closeWindow),
        .tick(dt: 1.0 / 120.0),
        .windowCreated(WindowSnapshot(
            id: WindowId(1), bundleId: "com.google.Chrome", title: "Inbox",
            role: .standard, frame: Rect(x: 0, y: 0, width: 1280, height: 800))),
        .windowDestroyed(WindowId(2)),
        .windowFrameChanged(WindowId(3), Rect(x: 5, y: 5, width: 640, height: 480)),
        .focusChanged(WindowId(4), origin: .system),
        .focusChanged(WindowId(4), origin: .ours),
        .focusChanged(nil, origin: .system),
        .windowMinimized(WindowId(5)),
        .windowDeminimized(WindowId(5)),
        .dragEnded,
        .screensChanged([
            MonitorInfo(id: MonitorId(1), frame: Rect(x: 0, y: 0, width: 1920, height: 1080)),
            MonitorInfo(id: MonitorId(2), frame: Rect(x: 1920, y: 0, width: 2560, height: 1440)),
        ]),
        .axLanded(WindowId(6)),
        .axFailed(WindowId(7)),
        .captureReady(WindowId(8)),
        .coverOnScreen,
        .coverUnavailable,
        .crossfadeDone,
        .holdTimeout,
    ]

    @Test func everyEventRoundTrips() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for event in Self.all {
            let decoded = try decoder.decode(Event.self, from: encoder.encode(event))
            #expect(decoded == event, "round-trip changed \(event)")
        }
    }

    /// `focusChanged(nil)` (focus left every managed window) and `focusChanged(someWindow)` are
    /// genuinely different events and both must survive the log — the snap-reveal logic branches on
    /// exactly this distinction.
    @Test func focusChangedNilIsDistinctAndRoundTrips() throws {
        #expect(Event.focusChanged(nil, origin: .system)
                != Event.focusChanged(WindowId(1), origin: .system))
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let decoded = try decoder.decode(
            Event.self, from: encoder.encode(Event.focusChanged(nil, origin: .system)))
        #expect(decoded == .focusChanged(nil, origin: .system))
    }

    /// The origin is part of the event's identity, not a hint attached to it: `[focus] system-events` refuses
    /// on exactly this distinction, so a log that flattened the two would replay a refusal as an
    /// admission.
    @Test func focusOriginIsPartOfTheEventsIdentityAndSurvivesTheLog() throws {
        let ours = Event.focusChanged(WindowId(1), origin: .ours)
        #expect(ours != Event.focusChanged(WindowId(1), origin: .system))
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        #expect(try decoder.decode(Event.self, from: encoder.encode(ours)) == ours)
    }

    // MARK: WindowRole taxonomy

    /// Only `.standard` tiles; every other role floats.
    @Test func onlyStandardRoleTiles() {
        #expect(WindowRole.standard.tiles)
        for role in WindowRole.allCases where role != .standard {
            #expect(!role.tiles, "\(role) should float, not tile")
        }
    }

    @Test func windowRoleEncodesAsItsName() throws {
        let data = try JSONEncoder().encode([WindowRole.standard, .popover])
        #expect(String(decoding: data, as: UTF8.self) == #"["standard","popover"]"#)
    }

    // MARK: Boundary DTOs

    @Test func windowSnapshotRoundTrips() throws {
        let snap = WindowSnapshot(
            id: WindowId(42), bundleId: "org.mozilla.firefox", title: "docs — Firefox",
            role: .standard, frame: Rect(x: -100, y: 24, width: 900, height: 600))
        let decoded = try JSONDecoder().decode(
            WindowSnapshot.self, from: JSONEncoder().encode(snap))
        #expect(decoded == snap)
    }

    @Test func monitorInfoRoundTrips() throws {
        let mon = MonitorInfo(id: MonitorId(9), frame: Rect(x: 0, y: 0, width: 3456, height: 2234))
        let decoded = try JSONDecoder().decode(MonitorInfo.self, from: JSONEncoder().encode(mon))
        #expect(decoded == mon)
    }

    /// Pin the committed wire shape for one bare case and one integer-id payload case — no `Double`,
    /// so the assertion is independent of floating-point formatting (the `tick`/`Rect` cases carry
    /// `Double`s and are covered by round-trip instead).
    @Test func eventWireShapeIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let destroyed = String(
            decoding: try encoder.encode(Event.windowDestroyed(WindowId(4))), as: UTF8.self)
        #expect(destroyed == #"{"windowDestroyed":{"_0":4}}"#)

        let timeout = String(decoding: try encoder.encode(Event.holdTimeout), as: UTF8.self)
        #expect(timeout == #"{"holdTimeout":{}}"#)
    }
}
