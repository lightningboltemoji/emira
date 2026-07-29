import ApplicationServices
import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The identity join under a burst of window creation. The two sides of the join are read at different
// instants — AX frames on the app's serial lane, the CG window list later in `AXEnumerator.finish` —
// and the thing moving windows in between is us, so a stale read reports window A at the frame window
// B has since taken. These pin the two rules that make that unreachable: a window already bound is
// never re-joined, and an entry already bound is never a candidate.

@Suite struct GhostIdentityTests {

    private static let ghostty = ScanTarget(pid: 100, bundleId: "com.mitchellh.ghostty")

    /// Ghostty's default new-window frame — where every ⌘N lands before emira tiles it.
    private static let defaultFrame = Rect(x: 100, y: 100, width: 800, height: 600)
    /// Where emira tiled the first window to.
    private static let tiledFrame = Rect(x: 0, y: 39, width: 500, height: 761)

    private static func element(_ seed: pid_t) -> AXWindow {
        AXWindow(AXUIElementCreateApplication(seed))
    }

    private static func scanned(_ element: AXWindow, title: String, frame: Rect) -> ScannedWindow {
        ScannedWindow(
            observed: ObservedWindow(pid: ghostty.pid, bundleId: ghostty.bundleId, title: title,
                                     role: .standard, frame: frame, isMinimized: false),
            element: element)
    }

    @MainActor private final class StubSource: WindowSource {
        var windows: [ScannedWindow] = []
        var entries: [WindowListEntry] = []
        func applications() -> [ScanTarget] { [GhostIdentityTests.ghostty] }
        func windows(of target: ScanTarget,
                     then completion: @escaping @MainActor (ScanAnswer) -> Void) {
            completion(ScanAnswer(windows: windows, entries: entries))
        }
        func windowList() -> [WindowListEntry] { entries }
    }

    @MainActor
    @Test func aStaleAXFrameCannotMintASecondIdForAWindowThatIsAlreadyBound() {
        let registry = WindowRegistry()
        let source = StubSource()
        let enumerator = AXEnumerator(source: source, registry: registry)

        let first = Self.element(1)     // the window opened by the first ⌘N
        let second = Self.element(2)    // the window opened by the second ⌘N

        // --- Scan 1: one window, AX and the window list agree. Clean adoption.
        source.windows = [Self.scanned(first, title: "one", frame: Self.defaultFrame)]
        source.entries = [WindowListEntry(number: 1, pid: Self.ghostty.pid,
                                          frame: Self.defaultFrame, isOnScreen: true)]
        var report: AXEnumerator.Report?
        enumerator.enumerate(apps: [Self.ghostty]) { report = $0 }
        #expect(report?.snapshots.count == 1)
        let firstId = report!.snapshots[0].id

        // emira now tiles `first`; a second ⌘N opens `second` at the default frame.
        //
        // --- Scan 2: its AX read was queued on Ghostty's lane before our placement write landed, so
        // it still reports `first` at the default frame and does not see `second` at all. The window
        // list, read afterwards, sees both.
        source.windows = [Self.scanned(first, title: "one", frame: Self.defaultFrame)]
        source.entries = [
            WindowListEntry(number: 1, pid: Self.ghostty.pid, frame: Self.tiledFrame, isOnScreen: true),
            WindowListEntry(number: 2, pid: Self.ghostty.pid, frame: Self.defaultFrame, isOnScreen: true),
        ]
        enumerator.enumerate(apps: [Self.ghostty]) { report = $0 }

        // `first` is already bound, so its frame is not matched against anything: no ghost is minted.
        #expect(report?.snapshots.isEmpty == true, "no birth is announced")
        #expect(report?.rebound == [firstId], "it is a silent refresh, which is what a re-scan is")
        #expect(registry.count == 1)
        #expect(registry.id(for: first) == firstId, "its element still resolves to its own id")

        // The real newcomer is reported rather than silently lost: the window server lists a window of
        // this app that AX did not describe, which is what makes `WorldWatcher` ask again.
        #expect(report?.unclaimed == 1)
        #expect(report?.isIncomplete == true, "so the scan is retried rather than accepted")

        // --- Scan 3: the retry, by which time AX describes both windows.
        source.windows = [Self.scanned(first, title: "one", frame: Self.tiledFrame),
                          Self.scanned(second, title: "two", frame: Self.defaultFrame)]
        enumerator.enumerate(apps: [Self.ghostty]) { report = $0 }

        #expect(report?.snapshots.count == 1, "the newcomer is adopted, once")
        #expect(report?.snapshots.first?.title == "two")
        #expect(report?.unclaimed == 0)
        #expect(registry.id(for: second) == report?.snapshots.first?.id)
        #expect(registry.id(for: first) == firstId, "and the first window kept its identity throughout")
    }

    @MainActor
    @Test func anElementIsNeverBoundToTwoWindowNumbers() {
        // Even asked directly, the registry refuses: binding would move `idByElement` onto the new id,
        // so the original window's notifications would resolve to a window that does not exist.
        let registry = WindowRegistry()
        let element = Self.element(1)
        let observed = ObservedWindow(pid: 100, bundleId: "app", title: "w", role: .standard,
                                      frame: Self.defaultFrame, isMinimized: false)

        let bound = registry.adopt(observed, element: element, number: 1)
        #expect(bound != nil)
        #expect(registry.adopt(observed, element: element, number: 2) == nil)
        #expect(registry.count == 1)
        #expect(registry.id(forNumber: 2) == nil, "number 2 is still free for its real window")
        #expect(registry.id(for: element) == bound?.id)
    }
}
