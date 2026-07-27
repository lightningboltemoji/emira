import Foundation
import Testing
@testable import EmiraCore

/// `World` — the truth-plane half of core `State`: fold an event through a mutator, assert the record.
/// Covers the two invariants (focus integrity, app ref-counting), the strip-participation taxonomy,
/// determinism of the derived views, and a `Codable` round-trip.
@Suite struct WorldTests {

    // A couple of snapshot builders to keep the tests terse.
    static func snap(
        _ id: UInt64, _ bundleId: String, role: WindowRole = .standard,
        title: String = "w", frame: Rect = Rect(x: 0, y: 0, width: 100, height: 100)
    ) -> WindowSnapshot {
        WindowSnapshot(id: WindowId(id), bundleId: bundleId, title: title, role: role, frame: frame)
    }

    // MARK: insert / app grouping

    @Test func insertRecordsWindowAndMintsApp() {
        var world = World()
        world.insert(Self.snap(1, "com.apple.Safari", title: "Start"))

        let window = try! #require(world.windows[WindowId(1)])
        #expect(window.bundleId == "com.apple.Safari")
        #expect(window.title == "Start")
        #expect(window.role == .standard)
        #expect(!window.isMinimized)
        #expect(world.apps["com.apple.Safari"]?.isHidden == false)
        #expect(world.apps.count == 1)
    }

    /// A window that is *already* minimized when we first meet it stays off the strip. This is launch
    /// enumeration's case (`AXEnumerator`): an enumerated window is met mid-life and may already be in
    /// the Dock, and no correcting `windowMinimized` event will ever come — nothing minimized it while
    /// we were watching.
    @Test func aWindowEnumeratedWhileMinimizedIsRecordedAsSuchAndStaysOffTheStrip() {
        var world = World()
        world.insert(WindowSnapshot(id: WindowId(1), bundleId: "com.apple.Safari", title: "Docked",
                                    role: .standard, frame: Rect(x: 0, y: 0, width: 100, height: 100),
                                    isMinimized: true))

        #expect(world.windows[WindowId(1)]?.isMinimized == true)
        #expect(!world.participatesInStrip(WindowId(1)))
        #expect(world.stripWindowIds.isEmpty)
        // Still truth, and still ref-counted: the app exists, the window just isn't tiled.
        #expect(world.apps["com.apple.Safari"] != nil)
    }

    /// Two windows of the same app share a single `AppState` — the grouping the Cmd-H flag rides on.
    @Test func twoWindowsOfSameAppShareOneAppRecord() {
        var world = World()
        world.insert(Self.snap(1, "com.apple.Safari"))
        world.insert(Self.snap(2, "com.apple.Safari"))
        #expect(world.windows.count == 2)
        #expect(world.apps.count == 1)
        #expect(world.windowIds(inApp: "com.apple.Safari") == [WindowId(1), WindowId(2)])
    }

    // MARK: remove — focus integrity + app ref-counting

    @Test func removeDropsWindowAndClearsFocusWhenItWasFocused() {
        var world = World()
        world.insert(Self.snap(1, "com.apple.Safari"))
        world.setFocus(WindowId(1))
        world.remove(WindowId(1))

        #expect(world.windows[WindowId(1)] == nil)
        #expect(world.focusedWindow == nil)          // invariant: focus can't dangle
        #expect(world.apps["com.apple.Safari"] == nil) // ref-count hit zero → app dropped
    }

    @Test func removeKeepsAppRecordWhileAnotherWindowRemains() {
        var world = World()
        world.insert(Self.snap(1, "com.apple.Safari"))
        world.insert(Self.snap(2, "com.apple.Safari"))
        world.remove(WindowId(1))
        #expect(world.apps["com.apple.Safari"] != nil) // sibling window keeps the app alive
        #expect(world.windowIds(inApp: "com.apple.Safari") == [WindowId(2)])
    }

    @Test func removeLeavesFocusAloneWhenADifferentWindowGoes() {
        var world = World()
        world.insert(Self.snap(1, "com.apple.Safari"))
        world.insert(Self.snap(2, "com.apple.Safari"))
        world.setFocus(WindowId(2))
        world.remove(WindowId(1))
        #expect(world.focusedWindow == WindowId(2))
    }

    /// A destroy racing a prior removal (or any unknown id) is a normal, total transition — no crash,
    /// no side effects.
    @Test func removeOfUnknownIdIsANoOp() {
        var world = World()
        world.insert(Self.snap(1, "com.apple.Safari"))
        world.remove(WindowId(99))
        #expect(world.windows.count == 1)
        #expect(world.apps.count == 1)
    }

    // MARK: updateFrame / setMinimized — tolerant of unknown ids

    @Test func updateFrameUpdatesKnownAndIgnoresUnknown() {
        var world = World()
        world.insert(Self.snap(1, "com.apple.Safari"))
        let moved = Rect(x: 40, y: 24, width: 800, height: 600)
        world.updateFrame(WindowId(1), to: moved)
        world.updateFrame(WindowId(2), to: moved)      // unknown → no-op, no crash
        #expect(world.windows[WindowId(1)]?.frame == moved)
        #expect(world.windows.count == 1)
    }

    // MARK: strip participation (the taxonomy, derived)

    @Test func onlyStandardNonMinimizedNonHiddenWindowsAreOnTheStrip() {
        var world = World()
        world.insert(Self.snap(1, "com.apple.Safari", role: .standard))   // tiles
        world.insert(Self.snap(2, "com.apple.Safari", role: .dialog))     // floats (role)
        world.insert(Self.snap(3, "org.x.Term", role: .standard))         // tiles
        world.setMinimized(WindowId(3), true)                             // now leaves the strip

        #expect(world.participatesInStrip(WindowId(1)))
        #expect(!world.participatesInStrip(WindowId(2)))
        #expect(!world.participatesInStrip(WindowId(3)))
        #expect(world.stripWindowIds == [WindowId(1)])

        world.setMinimized(WindowId(3), false)                            // restored → rejoins
        #expect(world.stripWindowIds == [WindowId(1), WindowId(3)])
    }

    /// Cmd-H hides *all* of an app's windows at once via the shared `AppState` flag.
    @Test func appHiddenRemovesEveryWindowOfThatAppFromTheStrip() {
        var world = World()
        world.insert(Self.snap(1, "com.apple.Safari"))
        world.insert(Self.snap(2, "com.apple.Safari"))
        world.insert(Self.snap(3, "org.x.Term"))
        #expect(world.stripWindowIds == [WindowId(1), WindowId(2), WindowId(3)])

        world.setAppHidden("com.apple.Safari", true)
        #expect(world.stripWindowIds == [WindowId(3)])   // only the other app survives
        #expect(!world.participatesInStrip(WindowId(1)))

        world.setAppHidden("com.apple.Safari", false)
        #expect(world.stripWindowIds == [WindowId(1), WindowId(2), WindowId(3)])
    }

    @Test func setAppHiddenOnUnknownAppIsANoOp() {
        var world = World()
        world.insert(Self.snap(1, "com.apple.Safari"))
        world.setAppHidden("com.nonexistent", true)      // no such app → no-op
        #expect(world.stripWindowIds == [WindowId(1)])
    }

    /// `stripWindowIds` must be deterministically ordered (by id) regardless of insertion order —
    /// the layout engine and golden replays depend on it, and dictionary iteration is not stable.
    @Test func stripWindowIdsAreSortedRegardlessOfInsertionOrder() {
        var world = World()
        for id: UInt64 in [7, 3, 10, 1, 5] {
            world.insert(Self.snap(id, "com.apple.Safari"))
        }
        #expect(world.stripWindowIds == [1, 3, 5, 7, 10].map { WindowId($0) })
    }

    // MARK: focus

    @Test func focusStoresAndClearsAndResolvesToRecord() {
        var world = World()
        world.insert(Self.snap(1, "com.apple.Safari", title: "Focused"))
        world.setFocus(WindowId(1))
        #expect(world.focusedWindow == WindowId(1))
        #expect(world.focusedWindowState?.title == "Focused")

        world.setFocus(nil)                              // focus left every managed window
        #expect(world.focusedWindow == nil)
        #expect(world.focusedWindowState == nil)
    }

    // MARK: monitors

    @Test func setMonitorsPreservesEnumerationOrderAndUpdatesFrames() {
        var world = World()
        world.setMonitors([
            MonitorInfo(id: MonitorId(1), frame: Rect(x: 0, y: 0, width: 1920, height: 1080)),
            MonitorInfo(id: MonitorId(2), frame: Rect(x: 1920, y: 0, width: 2560, height: 1440)),
        ])
        #expect(world.monitors.map(\.id) == [MonitorId(1), MonitorId(2)])
        #expect(world.monitors.count == 2)

        // Reconnect with monitor 1 dropped, 2 re-framed, 3 added — order follows the new enumeration.
        world.setMonitors([
            MonitorInfo(id: MonitorId(2), frame: Rect(x: 0, y: 0, width: 3000, height: 2000)),
            MonitorInfo(id: MonitorId(3), frame: Rect(x: 3000, y: 0, width: 1080, height: 1920)),
        ])
        #expect(world.monitors.map(\.id) == [MonitorId(2), MonitorId(3)])
        #expect(world.monitors.first?.frame == Rect(x: 0, y: 0, width: 3000, height: 2000))
    }

    // MARK: serialization (state dump / golden replay)

    @Test func populatedWorldRoundTripsThroughCodable() throws {
        var world = World()
        world.insert(Self.snap(1, "com.apple.Safari", title: "One"))
        world.insert(Self.snap(2, "org.x.Term", role: .dialog, title: "Two"))
        world.setMinimized(WindowId(1), true)
        world.setAppHidden("org.x.Term", true)
        world.setFocus(WindowId(2))
        world.setMonitors([MonitorInfo(id: MonitorId(1), frame: Rect(x: 0, y: 0, width: 800, height: 600))])

        let decoded = try JSONDecoder().decode(World.self, from: JSONEncoder().encode(world))
        #expect(decoded == world)
    }
}
