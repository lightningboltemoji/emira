import ApplicationServices
import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The truth plane's tests. The AX round trips themselves need other processes, a TCC grant and a real
// desktop, so `WindowSource` exists to make them the only untestable thing; everything above that
// seam is decision, and is tested here — the tiling taxonomy, the identity join (whose wrong answers
// are permanent, so its refusals are asserted as hard as its matches), the registry, the enumerator's
// fan-out over N apps, and the one-serial-lane-per-app discipline.

/// A frame at a distinct place, so "same window" and "different window" are never accidental.
private func rect(_ x: Double, _ y: Double = 0, w: Double = 640, h: Double = 460) -> Rect {
    Rect(x: x, y: y, width: w, height: h)
}

/// An `ObservedWindow` with everything but the interesting field defaulted.
private func observed(pid: pid_t = 100, bundle: String = "com.test.app", title: String = "w",
                      role: WindowRole = .standard, frame: Rect, minimized: Bool = false)
-> ObservedWindow {
    ObservedWindow(pid: pid, bundleId: bundle, title: title, role: role,
                   frame: frame, isMinimized: minimized)
}

/// A `ScannedWindow` carrying a real (if unrelated) AX element — the registry only ever stores it, so
/// any valid element proves the storage without needing a window to exist.
private func scanned(pid: pid_t = 100, bundle: String = "com.test.app", title: String = "w",
                     role: WindowRole = .standard, frame: Rect, minimized: Bool = false)
-> ScannedWindow {
    ScannedWindow(
        observed: observed(pid: pid, bundle: bundle, title: title, role: role,
                           frame: frame, minimized: minimized),
        element: windowElement(pid: pid, frame: frame))
}

/// A distinct AX element per window, seeded from its app and frame. Real windows never share an
/// element and the registry refuses to bind one to two window numbers, so fixtures must not either.
private func windowElement(pid: pid_t, frame: Rect) -> AXWindow {
    AXWindow(AXUIElementCreateApplication(
        pid_t(truncatingIfNeeded: Int(pid) &* 1_000_003 &+ Int(frame.minX) &* 1009 &+ Int(frame.minY))))
}

private func entry(_ number: CGWindowID, pid: pid_t = 100, frame: Rect,
                   onScreen: Bool = true) -> WindowListEntry {
    WindowListEntry(number: number, pid: pid, frame: frame, isOnScreen: onScreen)
}

@Suite struct WindowTaxonomyTests {

    @Test func onlyAStandardWindowTiles() {
        let role = WindowRole(axRole: "AXWindow", axSubrole: "AXStandardWindow", isFullScreen: false)
        #expect(role == .standard)
        #expect(role?.tiles == true)
    }

    @Test func anElementThatIsNotAWindowIsDeclinedRatherThanFiledUnderOther() {
        // `kAXWindowsAttribute` does not contain only windows: Finder answers it with the desktop,
        // whose role is `AXScrollArea`. `.other` means "a real window emira leaves alone", so filing
        // the desktop there would leave it in `World`, unbindable, reported as a failure every scan.
        #expect(WindowRole(axRole: "AXScrollArea", axSubrole: nil, isFullScreen: false) == nil)
        #expect(WindowRole(axRole: "AXGroup", axSubrole: "AXStandardWindow", isFullScreen: false) == nil)
        // An app that won't say what it is, isn't something we can classify.
        #expect(WindowRole(axRole: nil, axSubrole: "AXStandardWindow", isFullScreen: false) == nil)
    }

    @Test func theFloatingKindsAreClassifiedFromTheSubrole() {
        let cases: [(String, WindowRole)] = [
            ("AXDialog", .dialog),
            ("AXSystemDialog", .dialog),
            ("AXFloatingWindow", .panel),
            ("AXSystemFloatingWindow", .panel),
        ]
        for (subrole, expected) in cases {
            #expect(WindowRole(axRole: "AXWindow", axSubrole: subrole, isFullScreen: false) == expected)
        }
    }

    @Test func sheetsAndPopoversAreClassifiedFromTheRoleBecauseTheyOftenHaveNoSubrole() {
        // Why the initializer takes the role at all: an attached sheet reports `AXSheet` and often
        // answers `AXSubrole` with nothing, so a subrole-only taxonomy would be right by accident.
        #expect(WindowRole(axRole: "AXSheet", axSubrole: nil, isFullScreen: false) == .sheet)
        #expect(WindowRole(axRole: "AXPopover", axSubrole: nil, isFullScreen: false) == .popover)
    }

    @Test func aNativeFullScreenWindowIsExcludedDespiteLookingOrdinary() {
        // A window in native full screen is on a macOS Space of its own, territory the charter says we
        // don't enter, so it must not tile.
        #expect(WindowRole(axRole: "AXWindow", axSubrole: "AXStandardWindow", isFullScreen: true) == .other)
        // Why full-screen is checked before the subrole: full-screen Safari reports its subrole as
        // `AXDialog` and its title as empty.
        let observedInTheWild = WindowRole(axRole: "AXWindow", axSubrole: "AXDialog", isFullScreen: true)
        #expect(observedInTheWild == .other)
        #expect(observedInTheWild?.tiles == false)
    }

    @Test func anUnknownOrAbsentSubroleFloatsRatherThanTiles() {
        // The safe direction: misclassifying as floating leaves a window alone; the opposite drags a
        // popover into the strip. The role already said "window", so there is something real here.
        #expect(WindowRole(axRole: "AXWindow", axSubrole: nil, isFullScreen: false) == .other)
        #expect(WindowRole(axRole: "AXWindow", axSubrole: "AXSomethingNew", isFullScreen: false) == .other)
    }
}

@Suite struct WindowIdentityTests {

    @Test func aWindowBindsToTheEntryWithTheSameOwnerAndFrame() {
        let windows = [observed(frame: rect(0)), observed(frame: rect(700))]
        let entries = [entry(42, frame: rect(700)), entry(41, frame: rect(0))]

        let binding = WindowIdentity.bind(windows, to: entries)

        #expect(binding.rejections.isEmpty)
        #expect(binding.matches == [WindowIdentity.Match(observed: 0, number: 41),
                                    WindowIdentity.Match(observed: 1, number: 42)])
    }

    @Test func subPointDisagreementBetweenAXAndTheWindowListStillBinds() {
        // The tolerance's whole job: two subsystems describing one rectangle can round differently.
        let windows = [observed(frame: Rect(x: 100, y: 50, width: 640, height: 460))]
        let entries = [entry(7, frame: Rect(x: 100.4, y: 49.7, width: 640, height: 460.2))]

        #expect(WindowIdentity.bind(windows, to: entries).matches.count == 1)
    }

    @Test func aWindowThatMovedBetweenTheTwoReadsIsRejectedNotGuessed() {
        // Nearest-match would bind these and be wrong forever. 40 pt is far outside the rounding
        // tolerance, so it is a different window or a stale read; either way we decline.
        let windows = [observed(frame: rect(0))]
        let entries = [entry(9, frame: rect(40))]

        let binding = WindowIdentity.bind(windows, to: entries)

        #expect(binding.matches.isEmpty)
        #expect(binding.rejections == [WindowIdentity.Rejection(observed: 0, reason: .noCandidate)])
    }

    @Test func theOwnerNarrowsTheJoinBeforeFramesAreCompared() {
        // Two apps' windows at the same place (one behind the other) must not cross-bind.
        let windows = [observed(pid: 100, frame: rect(0))]
        let entries = [entry(9, pid: 200, frame: rect(0))]

        #expect(WindowIdentity.bind(windows, to: entries).rejections
            == [WindowIdentity.Rejection(observed: 0, reason: .noCandidate)])
    }

    @Test func twoEntriesAtTheSameFrameAreAmbiguousAndNeitherIsChosen() {
        let windows = [observed(frame: rect(0))]
        let entries = [entry(9, frame: rect(0)), entry(10, frame: rect(0))]

        let binding = WindowIdentity.bind(windows, to: entries)

        #expect(binding.matches.isEmpty)
        #expect(binding.rejections == [WindowIdentity.Rejection(observed: 0, reason: .ambiguous)])
    }

    @Test func aDuplicateEntryIsSeparatedByWhichOneIsActuallyOnScreen() {
        // Observed: a Safari window carries two layer-0 entries with byte-identical bounds and only
        // one of them on screen. Owner + frame call it ambiguous; the window server's own opinion of
        // what is visible settles it.
        let windows = [observed(frame: rect(0))]
        let entries = [entry(1027, frame: rect(0), onScreen: false),
                       entry(2220, frame: rect(0), onScreen: true)]

        let binding = WindowIdentity.bind(windows, to: entries)

        #expect(binding.rejections.isEmpty)
        #expect(binding.matches == [WindowIdentity.Match(observed: 0, number: 2220)])
    }

    @Test func onScreenNarrowingOnlyBreaksTiesItCanActuallyBreak() {
        // On-screen is evidence, not a preference: consulted only after owner and frame have failed,
        // and still declining when it doesn't separate them either.
        let windows = [observed(frame: rect(0))]
        let bothLive = [entry(1, frame: rect(0), onScreen: true), entry(2, frame: rect(0), onScreen: true)]
        let neither = [entry(1, frame: rect(0), onScreen: false), entry(2, frame: rect(0), onScreen: false)]

        #expect(WindowIdentity.bind(windows, to: bothLive).rejections
            == [WindowIdentity.Rejection(observed: 0, reason: .ambiguous)])
        #expect(WindowIdentity.bind(windows, to: neither).rejections
            == [WindowIdentity.Rejection(observed: 0, reason: .ambiguous)])
    }

    @Test func anUnambiguousOffScreenWindowStillBinds() {
        // A minimized window, or one on another Space, has no on-screen entry at all — and is still
        // identifiable, because nothing competes.
        let windows = [observed(frame: rect(0), minimized: true)]
        let entries = [entry(9, frame: rect(0), onScreen: false)]

        #expect(WindowIdentity.bind(windows, to: entries).matches
            == [WindowIdentity.Match(observed: 0, number: 9)])
    }

    @Test func twoWindowsClaimingOneEntryContestItAndBothAreRejected() {
        // The second uniqueness direction: each window sees exactly one candidate, so a per-window
        // check passes — but they see the same one, because the second window's entry is missing from
        // the list. Nothing can say which is entry 9, so neither is bound.
        let windows = [observed(frame: rect(0)), observed(frame: rect(0.5))]
        let entries = [entry(9, frame: rect(0))]

        let binding = WindowIdentity.bind(windows, to: entries)

        #expect(binding.matches.isEmpty)
        #expect(binding.rejections == [WindowIdentity.Rejection(observed: 0, reason: .contested),
                                       WindowIdentity.Rejection(observed: 1, reason: .contested)])
    }

    @Test func oneUnbindableWindowDoesNotCostTheOthersTheirIdentity() {
        // A scan is all-or-nothing per window and never per app: a Chrome window that moved mid-scan
        // must not take the rest of the desktop down with it.
        let windows = [observed(frame: rect(0)), observed(frame: rect(700)), observed(frame: rect(1400))]
        let entries = [entry(1, frame: rect(0)), entry(3, frame: rect(1400))]

        let binding = WindowIdentity.bind(windows, to: entries)

        #expect(binding.matches == [WindowIdentity.Match(observed: 0, number: 1),
                                    WindowIdentity.Match(observed: 2, number: 3)])
        #expect(binding.rejections == [WindowIdentity.Rejection(observed: 1, reason: .noCandidate)])
    }

    @Test func nothingObservedIsNotAnError() {
        let binding = WindowIdentity.bind([], to: [entry(1, frame: rect(0))])
        #expect(binding.matches.isEmpty)
        #expect(binding.rejections.isEmpty)
    }
}

@Suite @MainActor struct WindowRegistryTests {

    /// A distinct AX element per window: `adopt` refuses to bind one element to two window numbers.
    private func element(_ seed: pid_t) -> AXWindow { AXWindow(AXUIElementCreateApplication(seed)) }

    @Test func idsAreMintedOncePerWindowNumber() {
        let registry = WindowRegistry()

        let first = registry.adopt(observed(frame: rect(0)), element: element(41), number: 41)!
        let second = registry.adopt(observed(frame: rect(700)), element: element(42), number: 42)!

        #expect(first.id != second.id)
        #expect(registry.count == 2)
        #expect(registry.ids == [first.id, second.id].sorted())
        #expect(registry.id(forNumber: 41) == first.id)
    }

    @Test func reAdoptingAKnownWindowReusesItsIdAndRefreshesItsElement() {
        // An AX element can go stale (an app relaunching its UI) while the window number does not,
        // which is why identity keys on the number. A re-scan must refresh the handle without minting
        // a second id, or the strip shows the same window twice.
        let registry = WindowRegistry()
        let stale = AXWindow(AXUIElementCreateApplication(100))
        let fresh = AXWindow(AXUIElementCreateApplication(200))

        let first = registry.adopt(observed(frame: rect(0)), element: stale, number: 41)!
        let again = registry.adopt(observed(title: "renamed", frame: rect(700)), element: fresh, number: 41)!

        #expect(again.id == first.id)
        #expect(registry.count == 1)
        #expect(registry.element(for: first.id).map { CFEqual($0.element, fresh.element) } == true)
    }

    @Test func theSnapshotCarriesEveryObservedFactToTheCore() {
        let registry = WindowRegistry()
        let window = observed(bundle: "com.apple.Safari", title: "Apple", role: .dialog,
                              frame: rect(120, 30), minimized: true)

        let snapshot = registry.adopt(window, element: element(7), number: 7)!

        #expect(snapshot.bundleId == "com.apple.Safari")
        #expect(snapshot.title == "Apple")
        #expect(snapshot.role == .dialog)
        #expect(snapshot.frame == rect(120, 30))
        // A window already in the Dock must arrive minimized, or the core tiles something the user
        // cannot see.
        #expect(snapshot.isMinimized)
    }

    @Test func forgettingAWindowReleasesItsNumberSoARecycledOneIsANewWindow() {
        // The window server reuses `CGWindowID`s after a window is destroyed, so a stale number → id
        // entry would hand a dead window's identity, and its place on the strip, to a new window.
        let registry = WindowRegistry()
        let first = registry.adopt(observed(frame: rect(0)), element: element(41), number: 41)!

        registry.forget(first.id)
        #expect(registry.count == 0)
        #expect(registry.id(forNumber: 41) == nil)
        #expect(registry.element(for: first.id) == nil)

        let reused = registry.adopt(observed(frame: rect(0)), element: element(41), number: 41)!
        #expect(reused.id != first.id)
    }

    @Test func quittingAnAppForgetsExactlyItsOwnWindows() {
        let registry = WindowRegistry()
        let a1 = registry.adopt(observed(pid: 100, frame: rect(0)), element: element(1), number: 1)!
        let a2 = registry.adopt(observed(pid: 100, frame: rect(700)), element: element(2), number: 2)!
        let b1 = registry.adopt(observed(pid: 200, frame: rect(1400)), element: element(3), number: 3)!

        let gone = registry.forget(app: 100)

        #expect(gone == [a1.id, a2.id].sorted())
        #expect(registry.ids == [b1.id])
    }

    @Test func anElementResolvesBackToItsWindowId() {
        // The reverse map is what lets an AX notification, which carries only an element, become an
        // `Event` without the private `_AXUIElementGetWindow`. It rests on `AXUIElement` comparing
        // structurally: the notification's element is a different allocation from the stored one.
        let registry = WindowRegistry()
        let a = AXWindow(AXUIElementCreateApplication(100))
        let b = AXWindow(AXUIElementCreateApplication(200))

        let first = registry.adopt(observed(pid: 100, frame: rect(0)), element: a, number: 1)!
        let second = registry.adopt(observed(pid: 200, frame: rect(700)), element: b, number: 2)!

        #expect(registry.id(for: AXWindow(AXUIElementCreateApplication(100))) == first.id)
        #expect(registry.id(for: AXWindow(AXUIElementCreateApplication(200))) == second.id)
        // An element we never bound is not an error — it is a window emira does not manage.
        #expect(registry.id(for: AXWindow(AXUIElementCreateApplication(300))) == nil)
    }

    @Test func forgettingAWindowAlsoForgetsHowToResolveItsElement() {
        // Otherwise a stray late notification becomes an `Event` about a window the core has removed.
        let registry = WindowRegistry()
        let element = AXWindow(AXUIElementCreateApplication(100))
        let window = registry.adopt(observed(pid: 100, frame: rect(0)), element: element, number: 1)!

        registry.forget(window.id)

        #expect(registry.id(for: element) == nil)
    }
}

@Suite @MainActor struct AXEnumeratorTests {

    /// A `WindowSource` answering from arrays, with the option to hold app answers open so the test can
    /// deliver them in whatever order it likes.
    @MainActor final class FakeSource: WindowSource {
        var targets: [ScanTarget] = []
        var windowsByPid: [pid_t: [ScannedWindow]] = [:]
        var entries: [WindowListEntry] = []
        /// When true, `windows(of:then:)` parks its completion in `pending` instead of answering.
        var holdsAnswers = false
        var pending: [(pid_t, @MainActor (ScanAnswer) -> Void)] = []
        /// How many app answers carried a window list — the real source reads one per app, on the lane.
        private(set) var listReadsInAnswers = 0
        private(set) var windowListCalls = 0

        func applications() -> [ScanTarget] { targets }

        func windows(of target: ScanTarget,
                     then completion: @escaping @MainActor (ScanAnswer) -> Void) {
            guard holdsAnswers else {
                completion(answer(for: target.pid))
                return
            }
            pending.append((target.pid, completion))
        }

        func windowList() -> [WindowListEntry] {
            windowListCalls += 1
            return entries
        }

        /// Answer one parked app. The list is read *now*, as the real source does — so a test that
        /// changes `entries` between two apps answering reproduces exactly the skew this seam exists to
        /// keep out of the join.
        func answer(pid: pid_t) {
            guard let index = pending.firstIndex(where: { $0.0 == pid }) else { return }
            let (_, completion) = pending.remove(at: index)
            completion(answer(for: pid))
        }

        private func answer(for pid: pid_t) -> ScanAnswer {
            listReadsInAnswers += 1
            return ScanAnswer(windows: windowsByPid[pid] ?? [], entries: entries)
        }
    }

    /// Two apps, two windows each, all four present in the window list.
    private func populated() -> (FakeSource, WindowRegistry, AXEnumerator) {
        let source = FakeSource()
        source.targets = [ScanTarget(pid: 100, bundleId: "com.test.a"),
                          ScanTarget(pid: 200, bundleId: "com.test.b")]
        source.windowsByPid = [
            100: [scanned(pid: 100, bundle: "com.test.a", title: "a1", frame: rect(0)),
                  scanned(pid: 100, bundle: "com.test.a", title: "a2", frame: rect(700))],
            200: [scanned(pid: 200, bundle: "com.test.b", title: "b1", frame: rect(1400)),
                  scanned(pid: 200, bundle: "com.test.b", title: "b2", frame: rect(2100))],
        ]
        source.entries = [entry(1, pid: 100, frame: rect(0)), entry(2, pid: 100, frame: rect(700)),
                          entry(3, pid: 200, frame: rect(1400)), entry(4, pid: 200, frame: rect(2100))]
        let registry = WindowRegistry()
        return (source, registry, AXEnumerator(source: source, registry: registry))
    }

    @Test func everyBoundWindowReachesTheRegistryAndTheReport() {
        let (_, registry, enumerator) = populated()
        var report: AXEnumerator.Report?

        enumerator.enumerate { report = $0 }

        #expect(report?.snapshots.count == 4)
        #expect(report?.scannedApps == 2)
        #expect(report?.seenWindows == 4)
        #expect(report?.unbound.isEmpty == true)
        #expect(registry.count == 4)
        // Ids are distinct — the failure this guards is a join that maps two windows onto one number.
        #expect(Set(report?.snapshots.map(\.id) ?? []).count == 4)
    }

    @Test func aScanWithNoAppsStillCompletes() {
        // Usually this means the Accessibility grant is missing: every AX read answers nothing,
        // without an error. The empty case is a real path — a callback that never fires would leave
        // the daemon waiting forever.
        let source = FakeSource()
        let enumerator = AXEnumerator(source: source, registry: WindowRegistry())
        var completions = 0

        enumerator.enumerate { _ in completions += 1 }

        #expect(completions == 1)
        #expect(source.windowListCalls == 0)   // nothing to join; don't even ask
    }

    @Test func anAppThatAnswersWithNothingDoesNotStallTheScan() {
        let (source, _, enumerator) = populated()
        source.windowsByPid[100] = []
        var report: AXEnumerator.Report?

        enumerator.enumerate { report = $0 }

        #expect(report?.scannedApps == 2)
        #expect(report?.snapshots.count == 2)
    }

    @Test func appsAnsweringOutOfOrderCompleteTheScanExactlyOnce() {
        // Apps are independent processes on independent lanes, so arrival order is arbitrary and
        // whichever answer is last must be the one that finishes the scan.
        let (source, _, enumerator) = populated()
        source.holdsAnswers = true
        var completions = 0
        var report: AXEnumerator.Report?

        enumerator.enumerate { completions += 1; report = $0 }
        #expect(completions == 0)              // nothing has answered yet

        source.answer(pid: 200)
        #expect(completions == 0)              // one app still out — the join must not run yet

        source.answer(pid: 100)
        #expect(completions == 1)
        #expect(report?.snapshots.count == 4)
        // One list read per app, taken with that app's AX reads — and none for the scan as a whole.
        // An app's windows are still all matched against one view of the world, which is what makes
        // `.contested` a real signal rather than an artifact; that view was only ever per-app, since
        // `bind` narrows by owner before it compares frames and a window number belongs to one process.
        #expect(source.listReadsInAnswers == 2)
        #expect(source.windowListCalls == 0)
    }

    @Test func eachAppIsJoinedAgainstItsOwnListRatherThanTheSlowestApps() {
        // The boot failure this exists for. Apps answer in parallel but one list read lands after the
        // *slowest* of them, so every app that answered early is joined against a picture of the world
        // taken much later — and `bind` matches on the frame, so a window that moved in between matches
        // nothing and is never managed. The gap is the slowest app's latency, which is why the symptom
        // grows with the number of windows on the desktop rather than with anything about the window
        // that goes missing.
        let (source, registry, enumerator) = populated()
        source.holdsAnswers = true
        var report: AXEnumerator.Report?

        enumerator.enumerate { report = $0 }
        source.answer(pid: 100)                 // app A answers while its windows are where it says

        // App B is slow, and one of A's windows moves before it finally answers.
        source.entries.removeAll { $0.number == 1 }
        source.entries.append(entry(1, pid: 100, frame: rect(5000)))
        source.answer(pid: 200)

        #expect(report?.snapshots.count == 4)
        #expect(report?.unbound.isEmpty == true)
        #expect(report?.isIncomplete == false)
        #expect(registry.count == 4)
    }

    @Test func onlyTheAppsThatFailedAreWorthAskingAgain() {
        // The retry target set. Re-scanning the whole desktop to re-confirm what already bound is seven
        // round trips per window per attempt, on exactly the machines where the attempts are needed.
        let (source, _, enumerator) = populated()
        source.entries.removeAll { $0.number == 2 }   // app A's second window is not listed yet
        var report: AXEnumerator.Report?

        enumerator.enumerate { report = $0 }

        #expect(report?.isIncomplete == true)
        #expect(report?.apps.count == 2)
        #expect(report?.incompleteApps.map(\.pid) == [100])
    }

    @Test func anUnidentifiableWindowIsReportedWithEnoughDetailToRecogniseIt() {
        // "emira is not managing that window" must never be silent: this report line is the only way a
        // user finds out, so it carries who and why.
        let (source, registry, enumerator) = populated()
        source.entries.removeAll { $0.number == 2 }
        var report: AXEnumerator.Report?

        enumerator.enumerate { report = $0 }

        #expect(report?.seenWindows == 4)
        #expect(report?.snapshots.count == 3)
        #expect(registry.count == 3)
        #expect(report?.unbound == [AXEnumerator.Report.Unbound(
            bundleId: "com.test.a", title: "a2", frame: rect(700), reason: .noCandidate)])
        #expect(report?.summary.contains("3/4 windows bound across 2 apps") == true)
        #expect(report?.summary.contains("noCandidate") == true)
    }

    @Test func aSecondEnumerationAdoptsNothingAndAnnouncesNothing() {
        // Re-enumeration must be idempotent and silent: a re-scan is the standing response to "a
        // window appeared in this app", so re-announcing the app's other windows would hand focus to
        // whichever sorted last every time the user opened one.
        let (_, registry, enumerator) = populated()
        var first: AXEnumerator.Report?
        var second: AXEnumerator.Report?

        enumerator.enumerate { first = $0 }
        enumerator.enumerate { second = $0 }

        #expect(registry.count == 4)
        #expect(first?.snapshots.count == 4)
        #expect(second?.snapshots.isEmpty == true)
        // Still bound, still the same ids — refreshed rather than re-born.
        #expect(second?.rebound == first?.snapshots.map(\.id))
        #expect(second?.boundWindows == 4)
        #expect(second?.summary.contains("4/4 windows bound") == true)
    }

    @Test func aScanOfOneAppLeavesTheOthersAlone() {
        // The steady-state form: `AXWindowCreated` names an app, and only that app is re-scanned.
        let (source, registry, enumerator) = populated()
        enumerator.enumerate { _ in }

        // A third window appears in app A, and only app A is asked about it.
        source.windowsByPid[100]?.append(
            scanned(pid: 100, bundle: "com.test.a", title: "a3", frame: rect(2800)))
        source.entries.append(entry(5, pid: 100, frame: rect(2800)))
        var report: AXEnumerator.Report?

        enumerator.enumerate(apps: [ScanTarget(pid: 100, bundleId: "com.test.a")]) { report = $0 }

        #expect(report?.scannedApps == 1)
        #expect(report?.seenWindows == 3)               // app B was never asked
        #expect(report?.snapshots.map(\.title) == ["a3"])
        #expect(report?.rebound.count == 2)
        #expect(registry.count == 5)                    // B's two are untouched, not forgotten
    }
}

// The AX lane discipline

@Suite @MainActor struct AXClientTests {

    @Test func eachAppGetsExactlyOneLaneAndItIsCreatedOnce() {
        // Serial per app: one shared queue lets a hung app stall placement everywhere, and a queue per
        // call lets two sets into one window race — the clamping dance coming apart.
        let client = AXClient()
        #expect(client.laneCount == 0)

        _ = client.application(for: 100)
        _ = client.application(for: 100)
        #expect(client.laneCount == 1)

        _ = client.application(for: 200)
        #expect(client.laneCount == 2)
    }

    @Test func theSameAppAlwaysGetsTheSameApplicationElement() {
        let client = AXClient()
        let first = client.application(for: 100)
        let second = client.application(for: 100)

        #expect(first.pid == 100)
        #expect(CFEqual(first.element, second.element))
    }

    @Test func forgettingAnAppDropsItsLane() {
        let client = AXClient()
        _ = client.application(for: 100)
        _ = client.application(for: 200)

        client.forget(app: 100)

        #expect(client.laneCount == 1)
        // Recreating is legal — an app relaunching under a new pid is normal — but it is a *new* lane.
        _ = client.application(for: 100)
        #expect(client.laneCount == 2)
    }

    @Test func workLeavesTheMainThreadAndTheAnswerComesBackToIt() async {
        // AX IPC must not run where the display link lives, and the result must come back to main.
        // The work is trivially fast; what is asserted is where it ran.
        let client = AXClient()
        let (pid, ranOnMain) = await withCheckedContinuation { continuation in
            client.perform(app: 4242) { application in
                (application.pid, Thread.isMainThread)
            } then: { result in
                #expect(Thread.isMainThread)
                continuation.resume(returning: result)
            }
        }

        #expect(pid == 4242)
        #expect(!ranOnMain)
    }
}
