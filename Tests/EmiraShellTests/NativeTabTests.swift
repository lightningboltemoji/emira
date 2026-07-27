import ApplicationServices
import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// Native macOS tabs, which arrive as a shape nothing else on the desktop has: several real `NSWindow`s
// that AX describes as *one*. `kAXWindowsAttribute` lists only the selected tab, so a tab switch reaches
// emira as a window it has never seen appearing while the one it holds silently stops being described —
// no destroy notification, because nothing was destroyed.
//
// These pin the two halves of the answer. `WindowIdentity.succeed` decides, on frames alone, which
// newcomer is standing where a departed window stood; `WindowRegistry.rebind` moves the id onto it, so
// the core is never told anything happened and the group keeps its one column. What must stay true
// throughout: a tab switch is not a `windowCreated`, and an app that goes quiet is not a desktop that
// emptied.

// MARK: - Fixtures

/// Where the tab group sits — every member of a group reports the group's rectangle.
private let groupFrame = Rect(x: 0, y: 39, width: 600, height: 1100)

private let ghostty = ScanTarget(pid: 100, bundleId: "com.mitchellh.ghostty")

/// A distinct AX element per tab: the registry's reverse map is keyed on element equality.
private func element(_ seed: pid_t) -> AXWindow {
    AXWindow(AXUIElementCreateApplication(seed))
}

private func tab(_ seed: pid_t, title: String, frame: Rect = groupFrame,
                 pid: pid_t = ghostty.pid) -> ScannedWindow {
    ScannedWindow(
        observed: ObservedWindow(pid: pid, bundleId: ghostty.bundleId, title: title,
                                 role: .standard, frame: frame, isMinimized: false),
        element: element(seed))
}

private func entry(_ number: CGWindowID, frame: Rect = groupFrame, onScreen: Bool = true,
                   pid: pid_t = ghostty.pid) -> WindowListEntry {
    WindowListEntry(number: number, pid: pid, frame: frame, isOnScreen: onScreen)
}

@MainActor private final class StubSource: WindowSource {
    var targets: [ScanTarget] = [ghostty]
    var windowsByPid: [pid_t: [ScannedWindow]] = [:]
    var entries: [WindowListEntry] = []

    func applications() -> [ScanTarget] { targets }
    func windows(of target: ScanTarget,
                 then completion: @escaping @MainActor ([ScannedWindow]) -> Void) {
        completion(windowsByPid[target.pid] ?? [])
    }
    func windowList() -> [WindowListEntry] { entries }
}

/// A registry with one adopted tab group, ready for the second scan to change under it.
@MainActor private struct Group {
    let registry = WindowRegistry()
    let source = StubSource()
    let enumerator: AXEnumerator
    let id: WindowId

    /// Adopts tab 1 (element seed 1, number 1) as the group's window.
    init() {
        enumerator = AXEnumerator(source: source, registry: registry)
        source.windowsByPid = [ghostty.pid: [tab(1, title: "tab one")]]
        source.entries = [entry(1)]
        var report: AXEnumerator.Report?
        enumerator.enumerate(apps: [ghostty]) { report = $0 }
        id = report!.snapshots[0].id
    }

    /// Re-scan with whatever the source now says, and hand back the report.
    func rescan() -> AXEnumerator.Report {
        var report: AXEnumerator.Report?
        enumerator.enumerate(apps: [ghostty]) { report = $0 }
        return report!
    }
}

// MARK: - The succession itself

@Suite @MainActor struct NativeTabSuccessionTests {

    /// The whole point: ⌘T, or selecting a tab, keeps one window on the strip.
    @Test func selectingAnotherTabKeepsTheGroupsIdAndAnnouncesNothing() {
        let group = Group()

        // AX now describes tab 2 and has stopped describing tab 1 — which still exists, still holds a
        // window number, and is simply not the selected one any more.
        group.source.windowsByPid = [ghostty.pid: [tab(2, title: "tab two")]]
        group.source.entries = [entry(1, onScreen: false), entry(2, onScreen: true)]
        let report = group.rescan()

        #expect(report.succeeded == [group.id])
        #expect(report.snapshots.isEmpty, "a tab switch is not a new window")
        #expect(report.departed.isEmpty, "nor is it a closed one")

        // The id survived; everything under it moved to the newly selected tab.
        let record = group.registry.record(group.id)
        #expect(record?.number == 2)
        #expect(record?.element == element(2))
        #expect(group.registry.count == 1)
    }

    /// The reverse lookups have to move together, or a notification about the new tab resolves to
    /// nothing and one about the retired tab resolves to the group.
    @Test func rebindingMovesBothDirectionsOfTheLookup() {
        let group = Group()
        group.source.windowsByPid = [ghostty.pid: [tab(2, title: "tab two")]]
        group.source.entries = [entry(1, onScreen: false), entry(2)]
        _ = group.rescan()

        #expect(group.registry.id(for: element(2)) == group.id)
        #expect(group.registry.id(for: element(1)) == nil, "the retired tab speaks for nobody")
        #expect(group.registry.id(forNumber: 2) == group.id)
        #expect(group.registry.id(forNumber: 1) == nil)
    }

    /// Closing the *selected* tab: its element dies and its window number goes with it, so the frame is
    /// the only evidence left that the newcomer belongs to the same group. The column must not move.
    @Test func closingTheSelectedTabKeepsTheColumnTheGroupWasIn() {
        let group = Group()

        // Tab 1 is gone from the window list entirely — destroyed, not backgrounded.
        group.source.windowsByPid = [ghostty.pid: [tab(3, title: "tab three")]]
        group.source.entries = [entry(3)]
        let report = group.rescan()

        #expect(report.succeeded == [group.id])
        #expect(report.snapshots.isEmpty)
        #expect(group.registry.record(group.id)?.number == 3)
    }

    /// Dragging the selected tab out of the group makes AX describe two windows where it described one,
    /// and needs no succession at all: the window emira holds is the one that left, still the same
    /// element, just somewhere else. It keeps its column and the group's next tab is genuinely new.
    ///
    /// Here because it is the case a frame-matching rule could plausibly get wrong — the newcomer is
    /// sitting exactly where the departed window's rectangle used to be — and does not, because nothing
    /// departed.
    @Test func tearingTheSelectedTabOutIsAMoveAndACreation() {
        let group = Group()
        let tornOff = Rect(x: 900, y: 200, width: 600, height: 1100)

        group.source.windowsByPid = [ghostty.pid: [tab(2, title: "still tabbed"),
                                                   tab(1, title: "torn off", frame: tornOff)]]
        group.source.entries = [entry(2), entry(1, frame: tornOff)]
        let report = group.rescan()

        #expect(report.rebound == [group.id], "the torn-off window is the one we already had")
        #expect(report.succeeded.isEmpty)
        #expect(report.departed.isEmpty)
        #expect(report.snapshots.count == 1)
        #expect(report.snapshots.first?.title == "still tabbed")
        #expect(group.registry.record(group.id)?.frame == tornOff)
        #expect(group.registry.count == 2)
    }

    /// "Merge All Windows": two separate windows become one tab group, so one of them stops being
    /// described with nothing arriving to stand for it. It leaves the strip.
    @Test func aWindowMergedIntoAnotherGroupDepartsRatherThanSucceeding() {
        let group = Group()
        let elsewhere = Rect(x: 900, y: 39, width: 600, height: 1100)

        // Second scan adopts a second, separate window.
        group.source.windowsByPid = [ghostty.pid: [tab(1, title: "tab one"),
                                                   tab(2, title: "other", frame: elsewhere)]]
        group.source.entries = [entry(1), entry(2, frame: elsewhere)]
        let other = group.rescan().snapshots[0].id

        // Now they merge: only the survivor is described, on its own unchanged rectangle.
        group.source.windowsByPid = [ghostty.pid: [tab(1, title: "tab one")]]
        group.source.entries = [entry(1), entry(2, frame: groupFrame, onScreen: false)]
        let report = group.rescan()

        #expect(report.departed == [other])
        #expect(report.succeeded.isEmpty, "nothing arrived — the survivor was already bound")
        #expect(report.snapshots.isEmpty)
        // Reported, not acted on: retiring the id is `WorldWatcher`'s, so that the core hears about it.
        #expect(group.registry.record(group.id) != nil)
    }
}

// MARK: - What the succession refuses to guess

@Suite @MainActor struct NativeTabAmbiguityTests {

    /// The rule this suite exists for. "One left and one arrived, so they are the same window" would
    /// pair these, and a window would silently inherit a stranger's column — permanently, since a
    /// binding is never revisited.
    @Test func aWindowClosingWhileAnotherOpensElsewhereIsNotASuccession() {
        let group = Group()
        let elsewhere = Rect(x: 900, y: 200, width: 500, height: 700)

        group.source.windowsByPid = [ghostty.pid: [tab(2, title: "unrelated", frame: elsewhere)]]
        group.source.entries = [entry(2, frame: elsewhere)]
        let report = group.rescan()

        #expect(report.succeeded.isEmpty)
        #expect(report.departed == [group.id])
        #expect(report.snapshots.count == 1)
        #expect(report.snapshots[0].id != group.id, "a fresh identity, not an inherited one")
    }

    /// Uniqueness in both directions, as in `bind`: two departures sitting on one rectangle cannot both
    /// be the newcomer, and there is nothing to say which is.
    @Test func twoDeparturesOnOneRectangleBothDepartRatherThanOneWinning() {
        let registry = WindowRegistry()
        let source = StubSource()
        let enumerator = AXEnumerator(source: source, registry: registry)
        let stacked = Rect(x: 400, y: 39, width: 600, height: 1100)

        // Adopted apart, because the join cannot separate two windows on one rectangle in the first
        // place (they contest their entry and neither binds).
        source.windowsByPid = [ghostty.pid: [tab(1, title: "one"),
                                             tab(2, title: "two", frame: stacked)]]
        source.entries = [entry(1), entry(2, frame: stacked)]
        var first: AXEnumerator.Report?
        enumerator.enumerate(apps: [ghostty]) { first = $0 }
        #expect(first?.snapshots.count == 2)
        let ids = registry.ids

        // Then the user drags one onto the other, so both were last seen on the same rectangle.
        registry.noteFrame(ids[1], groupFrame)

        source.windowsByPid = [ghostty.pid: [tab(3, title: "three")]]
        source.entries = [entry(3)]
        var report: AXEnumerator.Report?
        enumerator.enumerate(apps: [ghostty]) { report = $0 }

        #expect(report?.succeeded.isEmpty == true)
        #expect(report?.departed == ids)
        #expect(report?.snapshots.count == 1, "the newcomer gets an identity of its own")
    }

    /// An app that answers with nothing is the shape of a timeout, a missing grant, and a process on
    /// its way out. Believing it would take the app's whole strip down on a slow frame.
    @Test func anAppThatDescribesNoWindowsIsNotEvidenceThatItHasNone() {
        let group = Group()

        group.source.windowsByPid = [ghostty.pid: []]
        group.source.entries = [entry(1)]
        let report = group.rescan()

        #expect(report.departed.isEmpty)
        #expect(report.succeeded.isEmpty)
        #expect(group.registry.record(group.id) != nil, "the group is still on the strip")
    }

    /// Only the apps this scan covered are reconciled — a one-app re-scan says nothing about anybody
    /// else's windows.
    @Test func anUnscannedAppsWindowsAreNeverTreatedAsDeparted() {
        let registry = WindowRegistry()
        let source = StubSource()
        let textEdit = ScanTarget(pid: 200, bundleId: "com.apple.TextEdit")
        let enumerator = AXEnumerator(source: source, registry: registry)
        let other = Rect(x: 900, y: 39, width: 600, height: 1100)

        source.targets = [ghostty, textEdit]
        source.windowsByPid = [ghostty.pid: [tab(1, title: "term")],
                               textEdit.pid: [tab(2, title: "doc", frame: other, pid: textEdit.pid)]]
        source.entries = [entry(1), entry(2, frame: other, pid: textEdit.pid)]
        var first: AXEnumerator.Report?
        enumerator.enumerate(apps: [ghostty, textEdit]) { first = $0 }
        #expect(first?.snapshots.count == 2)

        // Ghostty alone is re-scanned, and switches tab.
        source.windowsByPid[ghostty.pid] = [tab(3, title: "term two")]
        source.entries = [entry(3), entry(2, frame: other, pid: textEdit.pid)]
        var report: AXEnumerator.Report?
        enumerator.enumerate(apps: [ghostty]) { report = $0 }

        #expect(report?.departed.isEmpty == true, "TextEdit was not asked and is not judged")
        #expect(report?.succeeded.count == 1)
        #expect(registry.count == 2)
    }

    /// A minimized window keeps being described by AX — the one shape that looks like a background tab
    /// from the outside and must not be treated as one.
    @Test func aMinimizedWindowStaysListedAndSoIsNeverADeparture() {
        let group = Group()

        group.source.windowsByPid = [ghostty.pid: [
            ScannedWindow(
                observed: ObservedWindow(pid: ghostty.pid, bundleId: ghostty.bundleId,
                                         title: "tab one", role: .standard, frame: groupFrame,
                                         isMinimized: true),
                element: element(1)),
        ]]
        group.source.entries = [entry(1, onScreen: false)]
        let report = group.rescan()

        #expect(report.departed.isEmpty)
        #expect(report.succeeded.isEmpty)
        #expect(report.rebound == [group.id])
    }
}

// MARK: - What the rest of the shell is told

@Suite @MainActor struct NativeTabWatcherTests {

    @MainActor private final class StubObservationSource: ObservationSource {
        private(set) var watchedWindows: [(pid_t, [WindowId])] = []
        private(set) var unwatchedWindows: [WindowId] = []
        var frames: [WindowId: Rect] = [:]

        func start(_ deliver: @escaping @MainActor (WorldObservation) -> Void) {}
        func watch(app: ScanTarget, then: @escaping @MainActor (Bool) -> Void) { then(true) }
        func watch(windows: [WindowId], of app: pid_t) {
            watchedWindows.append((app, windows.sorted()))
        }
        func unwatch(window: WindowId, of app: pid_t) { unwatchedWindows.append(window) }
        func unwatch(app: pid_t) {}
        func readFrame(of window: WindowId, then: @escaping @MainActor (Rect?) -> Void) {
            then(frames[window])
        }
        func isAlive(_ window: WindowId, then: @escaping @MainActor (Bool) -> Void) { then(true) }
    }

    @MainActor private final class ImmediateScheduler: DelayScheduler {
        func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {}
    }

    @MainActor private struct Harness {
        let observation = StubObservationSource()
        let windows = StubSource()
        let registry = WindowRegistry()
        let recorder = Recorder()
        let watcher: WorldWatcher

        @MainActor init() {
            watcher = WorldWatcher(
                source: observation,
                enumerator: AXEnumerator(source: windows, registry: registry),
                registry: registry,
                scheduler: ImmediateScheduler(),
                sink: recorder.sink)
            windows.windowsByPid = [ghostty.pid: [tab(1, title: "tab one")]]
            windows.entries = [entry(1)]
            watcher.start()
        }
    }

    /// The core's whole experience of a tab switch: nothing. No column is built, none is torn down, so
    /// the group's width, workspace and float state are never touched.
    @Test func aTabSwitchReachesTheCoreAsSilence() {
        let harness = Harness()
        let created = harness.recorder.events.count

        harness.windows.windowsByPid = [ghostty.pid: [tab(2, title: "tab two")]]
        harness.windows.entries = [entry(1, onScreen: false), entry(2)]
        harness.watcher.handle(.windowAppeared(ghostty.pid))

        #expect(harness.recorder.events.count == created, "no event at all")
        #expect(harness.registry.count == 1)
    }

    /// The observer follows the id onto its new element. Without the un-watch first, `watch(windows:)`
    /// would see the id already registered and skip it — leaving the group's live window unobserved and
    /// its eventual destruction unheard.
    @Test func aSuccessionRewatchesTheIdOnItsNewElement() {
        let harness = Harness()
        let id = harness.registry.ids[0]

        harness.windows.windowsByPid = [ghostty.pid: [tab(2, title: "tab two")]]
        harness.windows.entries = [entry(1, onScreen: false), entry(2)]
        harness.watcher.handle(.windowAppeared(ghostty.pid))

        #expect(harness.observation.unwatchedWindows.contains(id))
        #expect(harness.observation.watchedWindows.last?.1 == [id])
        #expect(harness.registry.record(id)?.element == element(2))
    }

    /// A window AX stopped describing with nothing to replace it leaves the strip like a close — the
    /// blank column is the bug this whole seam exists to prevent.
    @Test func aDepartureBecomesAWindowDestroyedAndIsForgotten() {
        let harness = Harness()
        let id = harness.registry.ids[0]
        let elsewhere = Rect(x: 900, y: 200, width: 500, height: 700)

        harness.windows.windowsByPid = [ghostty.pid: [tab(2, title: "unrelated", frame: elsewhere)]]
        harness.windows.entries = [entry(2, frame: elsewhere)]
        harness.watcher.handle(.windowAppeared(ghostty.pid))

        let destroyed = harness.recorder.events.compactMap {
            if case .windowDestroyed(let id) = $0 { return id } else { return nil }
        }
        #expect(destroyed == [id])
        #expect(harness.observation.unwatchedWindows.contains(id))
        #expect(harness.registry.record(id) == nil)
    }

    /// A departure is retired before an arrival is announced, so the reducer never holds both the
    /// window leaving the strip and the one taking its place.
    @Test func aDepartureIsAnnouncedBeforeTheCreationThatDisplacedIt() {
        let harness = Harness()
        let elsewhere = Rect(x: 900, y: 200, width: 500, height: 700)
        let baseline = harness.recorder.events.count   // the boot scan's own creation

        harness.windows.windowsByPid = [ghostty.pid: [tab(2, title: "unrelated", frame: elsewhere)]]
        harness.windows.entries = [entry(2, frame: elsewhere)]
        harness.watcher.handle(.windowAppeared(ghostty.pid))

        let kinds: [String] = harness.recorder.events.dropFirst(baseline).compactMap {
            switch $0 {
            case .windowDestroyed: return "destroyed"
            case .windowCreated: return "created"
            default: return nil
            }
        }
        #expect(kinds == ["destroyed", "created"])
    }

    /// A drag moves a window without a scan, so the registry has to hear about it — otherwise the next
    /// tab switch looks for the group at the rectangle it left.
    @Test func aFrameReadKeepsTheRegistrysRectangleInStep() {
        let harness = Harness()
        let id = harness.registry.ids[0]
        let dragged = Rect(x: 320, y: 500, width: 600, height: 1100)
        harness.observation.frames = [id: dragged]

        harness.watcher.handle(.windowMoved(id))
        #expect(harness.registry.record(id)?.frame == dragged)

        // …and a tab selected from there is recognised at the frame the drag left behind.
        harness.windows.windowsByPid = [ghostty.pid: [tab(2, title: "tab two", frame: dragged)]]
        harness.windows.entries = [entry(1, frame: dragged, onScreen: false),
                                   entry(2, frame: dragged)]
        harness.watcher.handle(.windowAppeared(ghostty.pid))

        #expect(harness.registry.record(id)?.number == 2)
        #expect(harness.registry.count == 1)
    }
}

// MARK: - Absence is only read from a complete answer

@Suite @MainActor struct NativeTabIncompleteScanTests {

    /// A window AX described that the window list has not caught up with means the scan cannot see
    /// every arrival — so it cannot be trusted about what left either. The successor here is real and
    /// simply unbindable yet; retiring the group on this evidence would destroy a live column.
    @Test func anUnbindableArrivalSuspendsJudgementAboutTheAppsDepartures() {
        let group = Group()

        // The newly selected tab is described by AX but has no window-list entry yet.
        group.source.windowsByPid = [ghostty.pid: [tab(2, title: "tab two")]]
        group.source.entries = []
        let report = group.rescan()

        #expect(report.departed.isEmpty, "the group keeps its column until the picture is complete")
        #expect(report.succeeded.isEmpty)
        #expect(report.isIncomplete, "and the scan says it is worth asking again")
        #expect(group.registry.record(group.id) != nil)
    }

    /// The mirror: the window list carries an on-screen window of this app that AX did not describe.
    /// Same conclusion from the other side of the join.
    @Test func anOnScreenWindowAXDidNotDescribeSuspendsJudgementToo() {
        let group = Group()
        let elsewhere = Rect(x: 900, y: 39, width: 600, height: 1100)

        group.source.windowsByPid = [ghostty.pid: [tab(2, title: "tab two")]]
        group.source.entries = [entry(2), entry(9, frame: elsewhere)]
        let report = group.rescan()

        #expect(report.departed.isEmpty)
        #expect(report.succeeded.isEmpty)
        #expect(report.unclaimed == 1)
    }

    /// A managed window can fall out of its app's own answer without having gone anywhere: `snapshot`
    /// is seven round trips under a messaging timeout, and a busy app can fail one of them for one
    /// window while answering for the rest. Nothing on the AX side distinguishes that from a
    /// backgrounded tab — but the window server does, and the list has already been read: an entry
    /// still on screen is a live window. Retiring it instead would be unrecoverable, since no second
    /// `AXWindowCreated` is coming for a window that never closed.
    @Test func aWindowTheWindowServerStillShowsOnScreenIsNotADeparture() {
        let group = Group()
        let elsewhere = Rect(x: 900, y: 39, width: 600, height: 1100)

        // A second window of the same app, adopted normally.
        group.source.windowsByPid = [ghostty.pid: [tab(1, title: "tab one"),
                                                   tab(2, title: "other", frame: elsewhere)]]
        group.source.entries = [entry(1), entry(2, frame: elsewhere)]
        let other = group.rescan().snapshots[0].id

        // Now AX drops it from the answer while the window server still shows it, on screen, exactly
        // where it has always been. (Contrast `aWindowMergedIntoAnotherGroupDepartsRatherThanSucceeding`,
        // where the same silence comes with an entry that has gone off screen, and is believed.)
        group.source.windowsByPid = [ghostty.pid: [tab(1, title: "tab one")]]
        group.source.entries = [entry(1), entry(2, frame: elsewhere)]
        let report = group.rescan()

        #expect(report.departed.isEmpty)
        #expect(report.undescribed == [other])
        #expect(report.isIncomplete, "so the scan asks again rather than accepting the silence")
        #expect(group.registry.record(other) != nil, "the column is still on the strip")
    }

    /// The corroboration is asked only about departures with *no* successor. A tab switch has one — a
    /// window standing on the departed tab's rectangle — and that is the stronger evidence, so a window
    /// server that has not yet flipped the retired tab off screen cannot veto it.
    @Test func aSuccessionIsNotSecondGuessedByAWindowServerThatHasNotCaughtUp() {
        let group = Group()

        group.source.windowsByPid = [ghostty.pid: [tab(2, title: "tab two")]]
        group.source.entries = [entry(1, onScreen: true), entry(2, onScreen: true)]
        let report = group.rescan()

        #expect(report.succeeded == [group.id])
        #expect(report.undescribed.isEmpty)
        #expect(group.registry.record(group.id)?.number == 2)
    }

    /// The guard is per app, not global: one app answering badly must not freeze everyone else's
    /// reconciliation.
    @Test func oneAppsIncompleteAnswerDoesNotSuspendAnothersSuccession() {
        let registry = WindowRegistry()
        let source = StubSource()
        let textEdit = ScanTarget(pid: 200, bundleId: "com.apple.TextEdit")
        let enumerator = AXEnumerator(source: source, registry: registry)
        let docFrame = Rect(x: 900, y: 39, width: 600, height: 1100)

        source.targets = [ghostty, textEdit]
        source.windowsByPid = [ghostty.pid: [tab(1, title: "term")],
                               textEdit.pid: [tab(2, title: "doc", frame: docFrame,
                                                  pid: textEdit.pid)]]
        source.entries = [entry(1), entry(2, frame: docFrame, pid: textEdit.pid)]
        var first: AXEnumerator.Report?
        enumerator.enumerate(apps: [ghostty, textEdit]) { first = $0 }
        let ghosttyId = first!.snapshots.first { $0.bundleId == ghostty.bundleId }!.id

        // Ghostty switches tab cleanly; TextEdit answers with a window the list cannot place.
        source.windowsByPid = [ghostty.pid: [tab(3, title: "term two")],
                               textEdit.pid: [tab(4, title: "doc two", frame: docFrame,
                                                  pid: textEdit.pid)]]
        source.entries = [entry(3), entry(2, frame: docFrame, pid: textEdit.pid)]
        var report: AXEnumerator.Report?
        enumerator.enumerate(apps: [ghostty, textEdit]) { report = $0 }

        #expect(report?.succeeded == [ghosttyId], "Ghostty's answer stands on its own")
        #expect(report?.departed.isEmpty == true)
        #expect(registry.record(ghosttyId)?.number == 3)
    }
}
