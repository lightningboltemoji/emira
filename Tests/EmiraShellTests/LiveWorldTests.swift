import ApplicationServices
import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// `WorldWatcher`'s tests — the policy that turns a live desktop into `Event`s. The window server, the
// TCC grant and other people's processes all sit behind `ObservationSource` and `WindowSource`, both
// stubbed here, so what is exercised is the part with decisions in it: adoption, the two "asked too
// early" retries, move coalescing, and teardown ordering. The event stream is asserted against the
// `EventSink` the daemon really wires up, so these say what the core would be told.

// MARK: - Fixtures

private func rect(_ x: Double, _ y: Double = 0, w: Double = 600, h: Double = 400) -> Rect {
    Rect(x: x, y: y, width: w, height: h)
}

/// A distinct AX element per window: the registry's reverse map is keyed on element equality, so
/// fixtures sharing one element would let a lookup bug pass.
private func element(_ seed: pid_t) -> AXWindow {
    AXWindow(AXUIElementCreateApplication(seed))
}

private func scanned(pid: pid_t, seed: pid_t, bundle: String, title: String,
                     frame: Rect) -> ScannedWindow {
    ScannedWindow(
        observed: ObservedWindow(pid: pid, bundleId: bundle, title: title, role: .standard,
                                 frame: frame, isMinimized: false),
        element: element(seed))
}

// MARK: - Doubles

/// A `WindowSource` answering from arrays, scoped to whatever app set it is asked about.
@MainActor private final class StubWindowSource: WindowSource {
    var targets: [ScanTarget] = []
    var windowsByPid: [pid_t: [ScannedWindow]] = [:]
    var entries: [WindowListEntry] = []

    /// How many times each app has been asked for its windows — the instrument for the scan
    /// coalescer, which exists to keep this number off the app's serial AX lane.
    private(set) var scanCounts: [pid_t: Int] = [:]

    /// When true, `windows(of:then:)` parks its completion instead of answering, so a test can hold a
    /// scan open and drive a second request into it — the only way to reach two overlapping scans of
    /// one app.
    var holdsAnswers = false
    var pending: [(pid_t, @MainActor ([ScannedWindow]) -> Void)] = []

    func applications() -> [ScanTarget] { targets }

    func windows(of target: ScanTarget,
                 then completion: @escaping @MainActor ([ScannedWindow]) -> Void) {
        scanCounts[target.pid, default: 0] += 1
        guard holdsAnswers else {
            completion(windowsByPid[target.pid] ?? [])
            return
        }
        pending.append((target.pid, completion))
    }

    func windowList() -> [WindowListEntry] { entries }

    /// Answer the oldest parked scan.
    func answerScan() {
        guard !pending.isEmpty else { return }
        let (pid, completion) = pending.removeFirst()
        completion(windowsByPid[pid] ?? [])
    }
}

/// An `ObservationSource` that records what it was asked to watch and answers frame reads on command.
@MainActor private final class StubObservationSource: ObservationSource {
    private(set) var started = false
    private(set) var watchedApps: [pid_t] = []
    private(set) var watchedWindows: [(pid_t, [WindowId])] = []
    private(set) var unwatchedApps: [pid_t] = []
    private(set) var unwatchedWindows: [WindowId] = []
    private(set) var frameReads: [WindowId] = []

    /// What `watch(app:then:)` answers. `false` is an app that isn't ready to be observed yet.
    var watchSucceeds = true
    /// When true, frame reads park in `pendingReads` instead of answering.
    var holdsFrameReads = false
    var pendingReads: [(WindowId, @MainActor (Rect?) -> Void)] = []
    /// What a frame read answers when it isn't held.
    var frames: [WindowId: Rect] = [:]

    func start(_ deliver: @escaping @MainActor (WorldObservation) -> Void) { started = true }

    func watch(app: ScanTarget, then: @escaping @MainActor (Bool) -> Void) {
        watchedApps.append(app.pid)
        then(watchSucceeds)
    }

    func watch(windows: [WindowId], of app: pid_t) {
        watchedWindows.append((app, windows.sorted()))
    }

    func unwatch(window: WindowId, of app: pid_t) { unwatchedWindows.append(window) }

    func unwatch(app: pid_t) { unwatchedApps.append(app) }

    func readFrame(of window: WindowId, then: @escaping @MainActor (Rect?) -> Void) {
        frameReads.append(window)
        guard holdsFrameReads else {
            then(frames[window])
            return
        }
        pendingReads.append((window, then))
    }

    /// Answer the oldest parked read.
    func answerRead(_ frame: Rect?) {
        guard !pendingReads.isEmpty else { return }
        let (_, completion) = pendingReads.removeFirst()
        completion(frame)
    }

    private(set) var aliveProbes: [WindowId] = []
    /// When true, aliveness probes park in `pendingProbes` instead of answering.
    var holdsProbes = false
    var pendingProbes: [(WindowId, @MainActor (Bool) -> Void)] = []
    /// Windows this source considers dead. Anything not listed is alive.
    var dead: Set<WindowId> = []

    func isAlive(_ window: WindowId, then: @escaping @MainActor (Bool) -> Void) {
        aliveProbes.append(window)
        guard holdsProbes else {
            then(!dead.contains(window))
            return
        }
        pendingProbes.append((window, then))
    }

    /// Answer the oldest parked probe.
    func answerProbe(_ alive: Bool) {
        guard !pendingProbes.isEmpty else { return }
        let (_, completion) = pendingProbes.removeFirst()
        completion(alive)
    }
}

/// A scheduler that never runs anything until the test says so — the retry chain with no wall clock.
@MainActor private final class ManualScheduler: DelayScheduler {
    private(set) var delays: [TimeInterval] = []
    private var work: [@MainActor () -> Void] = []

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        delays.append(seconds)
        self.work.append(work)
    }

    var pending: Int { work.count }

    /// Run everything scheduled so far. Anything scheduled *by* that work stays pending, so a retry
    /// chain advances one link per call and its length is observable.
    @discardableResult
    func fire() -> Int {
        let due = work
        work.removeAll()
        for item in due { item() }
        return due.count
    }
}

/// Somewhere for an ordering assertion to write from inside a `@Sendable` sink closure.
@MainActor private final class OrderProbe {
    var watchedAtFirstCreate: Int?
}

// MARK: - The world under test

/// The fixture, named `LiveWorld` rather than `World` so it can't shadow `EmiraCore.World`.
@MainActor private struct LiveWorld {
    let source: StubObservationSource
    let windows: StubWindowSource
    let registry: WindowRegistry
    let scheduler: ManualScheduler
    let recorder: Recorder
    let watcher: WorldWatcher

    /// Two apps: Ghostty with one window, TextEdit with two. Everything bindable.
    init() {
        source = StubObservationSource()
        windows = StubWindowSource()
        registry = WindowRegistry()
        scheduler = ManualScheduler()
        recorder = Recorder()
        windows.targets = [ScanTarget(pid: 100, bundleId: "com.mitchellh.ghostty"),
                           ScanTarget(pid: 200, bundleId: "com.apple.TextEdit")]
        windows.windowsByPid = [
            100: [scanned(pid: 100, seed: 1, bundle: "com.mitchellh.ghostty", title: "term",
                          frame: rect(0))],
            200: [scanned(pid: 200, seed: 2, bundle: "com.apple.TextEdit", title: "one",
                          frame: rect(700)),
                  scanned(pid: 200, seed: 3, bundle: "com.apple.TextEdit", title: "two",
                          frame: rect(1400))],
        ]
        windows.entries = [WindowListEntry(number: 1, pid: 100, frame: rect(0)),
                           WindowListEntry(number: 2, pid: 200, frame: rect(700)),
                           WindowListEntry(number: 3, pid: 200, frame: rect(1400))]
        watcher = WorldWatcher(
            source: source,
            enumerator: AXEnumerator(source: windows, registry: registry),
            registry: registry,
            scheduler: scheduler,
            sink: recorder.sink)
    }

    var created: [WindowSnapshot] {
        recorder.events.compactMap { if case .windowCreated(let s) = $0 { return s } else { return nil } }
    }

    func id(titled title: String) -> WindowId? {
        created.first { $0.title == title }?.id
    }
}

// MARK: - Scans that overlap
//
// Four rapid ⌘N presses produce four `windowAppeared` notifications for one app. Answering each with
// its own full re-scan floods that app's single serial AX lane, so each answer is joined against a
// window list read later than the frames it contains — and that skew costs a window its identity.
// Hence: ask once, and ask again afterwards.

@Suite @MainActor struct WorldWatcherBurstTests {

    @Test func aSecondNotificationDuringAScanIsCoalescedIntoOneRepeatScan() {
        let world = LiveWorld()
        world.watcher.start()
        world.windows.holdsAnswers = true
        let before = world.windows.scanCounts[100] ?? 0

        // Four ⌘N presses land while the first scan is still out on the lane.
        for _ in 0..<4 { world.watcher.handle(.windowAppeared(100)) }
        #expect(world.windows.scanCounts[100] == before + 1, "only one scan is in flight")
        #expect(world.windows.pending.count == 1)

        // When it returns, the coalesced request is honoured exactly once — not three more times.
        world.windows.answerScan()
        #expect(world.windows.scanCounts[100] == before + 2)
        #expect(world.windows.pending.count == 1)

        world.windows.answerScan()
        #expect(world.windows.scanCounts[100] == before + 2, "and then it settles")
        #expect(world.windows.pending.isEmpty)
    }

    @Test func aWindowTheWindowListKnowsAndAXDoesNotIsAskedAboutAgain() {
        let world = LiveWorld()
        world.watcher.start()
        world.scheduler.fire()   // drain anything the boot scan scheduled

        // A new Ghostty window exists as far as the window server is concerned, but the app has not
        // described it over AX yet. It leaves no `unbound` entry, so only `unclaimed` can notice it.
        world.windows.entries.append(
            WindowListEntry(number: 9, pid: 100, frame: rect(2100), isOnScreen: true))
        world.watcher.handle(.windowAppeared(100))
        #expect(world.created.map(\.title) == ["term", "one", "two"], "nothing invented")
        #expect(world.scheduler.pending == 1, "a retry is scheduled")

        // By the retry, AX describes it — and it is adopted, once.
        world.windows.windowsByPid[100]?.append(
            scanned(pid: 100, seed: 9, bundle: "com.mitchellh.ghostty", title: "new", frame: rect(2100)))
        world.scheduler.fire()

        #expect(world.created.map(\.title) == ["term", "one", "two", "new"])
        #expect(world.registry.count == 4)
    }

    @Test func aKnownWindowIsReOfferedForWatchingSoAFailedRegistrationGetsAnotherChance() {
        // `watch(windows:of:)` is idempotent, so re-offering is free when the first attempt worked and
        // the only second chance when it didn't: a silently failed registration means no destroy
        // notification, i.e. a column that outlives its window.
        let world = LiveWorld()
        world.watcher.start()
        let term = world.id(titled: "term")

        world.watcher.handle(.windowAppeared(100))

        let offers = world.source.watchedWindows.filter { $0.0 == 100 }
        #expect(offers.count == 2, "boot, then the re-scan")
        #expect(offers.last?.1 == [term].compactMap { $0 })
    }
}

// MARK: - Adoption

@Suite @MainActor struct WorldWatcherAdoptionTests {

    @Test func bootAnnouncesEveryWindowAndWatchesEveryAppAndWindow() {
        let world = LiveWorld()

        world.watcher.start()

        #expect(world.source.started)
        #expect(world.created.map(\.title) == ["term", "one", "two"])
        #expect(world.source.watchedApps.sorted() == [100, 200])
        // AX delivers destroyed/moved/resized/miniaturized only for registrations made against the
        // window element, so they are registered per app.
        let byApp = Dictionary(uniqueKeysWithValues: world.source.watchedWindows.map { ($0.0, $0.1) })
        #expect(byApp[100]?.count == 1)
        #expect(byApp[200]?.count == 2)
        #expect(world.registry.count == 3)
    }

    @Test func aWindowIsWatchedBeforeItIsAnnounced() {
        // Announcing pumps the reducer synchronously and its placement effects move the window just
        // adopted, so registering second would leave that window unwatched through its own placement
        // and miss the drag after it.
        let world = LiveWorld()
        let probe = OrderProbe()
        let source = world.source
        let watcher = WorldWatcher(
            source: source,
            enumerator: AXEnumerator(source: world.windows, registry: world.registry),
            registry: world.registry,
            scheduler: world.scheduler,
            sink: EventSink { [weak probe] event in
                guard case .windowCreated = event, probe?.watchedAtFirstCreate == nil else { return }
                probe?.watchedAtFirstCreate = source.watchedWindows.count
            })

        watcher.start()

        #expect(probe.watchedAtFirstCreate == 2)   // both apps' windows registered already
    }

    @Test func aWindowAppearingInAKnownAppAnnouncesOnlyTheNewOne() {
        // The focus-theft guard: `AXWindowCreated` names the app, so the response is a re-scan, and
        // announcing all three of TextEdit's windows would leave focus on whichever sorted last
        // rather than on the one that just opened.
        let world = LiveWorld()
        world.watcher.start()
        let beforeCount = world.recorder.events.count

        world.windows.windowsByPid[200]?.append(
            scanned(pid: 200, seed: 4, bundle: "com.apple.TextEdit", title: "three",
                    frame: rect(2100)))
        world.windows.entries.append(WindowListEntry(number: 4, pid: 200, frame: rect(2100)))

        world.watcher.handle(.windowAppeared(200))

        let fresh = world.recorder.events.dropFirst(beforeCount)
        #expect(fresh.count == 1)
        #expect(world.created.map(\.title) == ["term", "one", "two", "three"])
        #expect(world.registry.count == 4)
    }

    @Test func theBootScanSaysItsWindowsWereAlreadyOpenAndALaterScanDoesNot() {
        // The core keeps an adopted window's existing width instead of snapping it onto the narrowest
        // preset, so "the desktop I found" versus "a window that just opened" has to survive the trip.
        let world = LiveWorld()
        world.watcher.start()
        #expect(world.created.map(\.wasAlreadyOpen) == [true, true, true])

        world.windows.windowsByPid[200]?.append(
            scanned(pid: 200, seed: 4, bundle: "com.apple.TextEdit", title: "three",
                    frame: rect(2100)))
        world.windows.entries.append(WindowListEntry(number: 4, pid: 200, frame: rect(2100)))
        world.watcher.handle(.windowAppeared(200))

        #expect(world.created.last?.title == "three")
        #expect(world.created.last?.wasAlreadyOpen == false)   // born under a running daemon
    }

    @Test func aWindowAppearingInAnAppWeDoNotTrackIsSilence() {
        // An accessory process, or an app that quit between the notification and here.
        let world = LiveWorld()
        world.watcher.start()
        let before = world.recorder.events.count

        world.watcher.handle(.windowAppeared(999))

        #expect(world.recorder.events.count == before)
    }

    @Test func aLaunchedAppIsBothWatchedAndScanned() {
        // `watch` is how we hear about the app's future windows; the scan finds the ones a relaunched
        // app came back with already open.
        let world = LiveWorld()
        world.watcher.start()
        world.windows.windowsByPid[300] = [
            scanned(pid: 300, seed: 5, bundle: "com.apple.Safari", title: "web", frame: rect(2100)),
        ]
        world.windows.entries.append(WindowListEntry(number: 5, pid: 300, frame: rect(2100)))

        world.watcher.handle(.appLaunched(ScanTarget(pid: 300, bundleId: "com.apple.Safari")))

        #expect(world.source.watchedApps.contains(300))
        #expect(world.created.map(\.title) == ["term", "one", "two", "web"])
    }
}

// MARK: - The two "asked too early" races

@Suite @MainActor struct WorldWatcherRetryTests {

    @Test func aWindowTheWindowListDoesNotKnowYetIsRetriedRatherThanLost() {
        // AX announces a window before `CGWindowListCopyWindowInfo` lists it, so the join answers
        // `.noCandidate`. Without a retry that window is never managed.
        let world = LiveWorld()
        world.windows.entries.removeAll { $0.number == 3 }   // "two" is not listed yet

        world.watcher.start()
        #expect(world.created.map(\.title) == ["term", "one"])
        #expect(world.scheduler.pending == 1)
        #expect(world.scheduler.delays == [WorldWatcher.rescanDelay])

        world.windows.entries.append(WindowListEntry(number: 3, pid: 200, frame: rect(1400)))
        world.scheduler.fire()

        #expect(world.created.map(\.title) == ["term", "one", "two"])
        #expect(world.scheduler.pending == 0)               // bound, so nothing more is scheduled
    }

    @Test func aBootWindowThatNeededTheRetryIsStillAWindowWeFoundAlreadyOpen() {
        // The `wasAlreadyOpen` flag has to ride the retry chain; losing it there would tile that one
        // window differently from the rest of the desktop.
        let world = LiveWorld()
        world.windows.entries.removeAll { $0.number == 3 }   // "two" is not listed yet

        world.watcher.start()
        world.windows.entries.append(WindowListEntry(number: 3, pid: 200, frame: rect(1400)))
        world.scheduler.fire()

        #expect(world.created.map(\.title) == ["term", "one", "two"])
        #expect(world.created.map(\.wasAlreadyOpen) == [true, true, true])
    }

    @Test func theRetryIsBoundedRatherThanARepeatingScanOfTheUsersDesktop() {
        // The other reading of a permanent `.noCandidate` is "this is not a window we can manage",
        // and retrying that forever is a busy loop against every app on the machine.
        let world = LiveWorld()
        world.windows.entries.removeAll { $0.number == 3 }

        world.watcher.start()
        var rounds = 0
        while world.scheduler.fire() > 0 { rounds += 1 }

        #expect(rounds == WorldWatcher.maxScanAttempts - 1)
        #expect(world.created.map(\.title) == ["term", "one"])
    }

    @Test func aRetryOnlyRevisitsTheAppsTheScanCovered() {
        // Re-asking `source.applications()` would turn a one-app retry into a full re-scan of every
        // app on the machine, on a path that fires whenever anything fails to bind.
        let world = LiveWorld()
        world.watcher.start()
        world.windows.windowsByPid[200]?.append(
            scanned(pid: 200, seed: 4, bundle: "com.apple.TextEdit", title: "three",
                    frame: rect(2100)))
        // Deliberately not listed, so the scan leaves it unbound and schedules a retry.

        world.watcher.handle(.windowAppeared(200))
        #expect(world.scheduler.pending == 1)

        // Ghostty gains a window in the meantime. The retry is TextEdit's, so it must not see it.
        world.windows.windowsByPid[100]?.append(
            scanned(pid: 100, seed: 6, bundle: "com.mitchellh.ghostty", title: "term2",
                    frame: rect(2800)))
        world.windows.entries.append(WindowListEntry(number: 6, pid: 100, frame: rect(2800)))
        world.scheduler.fire()

        #expect(world.created.map(\.title) == ["term", "one", "two"])
    }

    @Test func anAppThatIsNotReadyToBeObservedIsRetriedRatherThanGoingDeaf() {
        // A just-launched app answers AX with `.cannotComplete`. Shrugging at that means never hearing
        // about any window it opens, so it shares the retry budget with a failed bind.
        let world = LiveWorld()
        world.source.watchSucceeds = false

        world.watcher.start()
        #expect(world.source.watchedApps.sorted() == [100, 200])
        #expect(world.scheduler.pending == 2)               // one retry per app that refused

        world.source.watchSucceeds = true
        world.scheduler.fire()

        #expect(world.source.watchedApps.count == 4)        // both asked again
        #expect(world.scheduler.pending == 0)
    }

    @Test func aSecondScanArrivingMidRegistrationDoesNotWatchTheSameAppTwice() {
        let world = LiveWorld()
        world.watcher.start()
        #expect(world.source.watchedApps.sorted() == [100, 200])

        world.watcher.handle(.windowAppeared(200))
        world.watcher.handle(.windowAppeared(200))

        #expect(world.source.watchedApps.sorted() == [100, 200])
    }
}

// MARK: - Frame reads (the coalescer)

@Suite @MainActor struct WorldWatcherFrameTests {

    @Test func aMoveStormCollapsesToOneReadInFlightAndOneMoreAfterIt() {
        // A drag emits `AXWindowMoved` at the refresh rate and AX never says where, so answering each
        // one queues a round trip on the same serial lane the drag-end re-tile needs. One read in
        // flight plus one dirty bit yields the frame at the end of the burst, the only one that matters.
        let world = LiveWorld()
        world.watcher.start()
        let id = try! #require(world.id(titled: "term"))
        world.source.holdsFrameReads = true

        for _ in 0..<20 { world.watcher.handle(.windowMoved(id)) }
        #expect(world.source.frameReads.count == 1)

        world.source.answerRead(rect(40, 40))
        #expect(world.source.frameReads.count == 2)         // exactly one catch-up read
        world.source.answerRead(rect(80, 80))
        #expect(world.source.frameReads.count == 2)         // and then quiet

        let frames = world.recorder.events.compactMap {
            if case .windowFrameChanged(_, let r) = $0 { return r } else { return nil }
        }
        #expect(frames == [rect(40, 40), rect(80, 80)])
    }

    @Test func aReadThatComesBackEmptyIsNotReportedAsAFrameChange() {
        // The window closed mid-drag. Inventing a frame would put a lie in `World` that only the next
        // scan could correct; `windowVanished` is what reports this.
        let world = LiveWorld()
        world.watcher.start()
        let id = try! #require(world.id(titled: "term"))
        let before = world.recorder.events.count

        world.watcher.handle(.windowMoved(id))

        #expect(world.source.frameReads == [id])
        #expect(world.recorder.events.count == before)
    }

    @Test func aMoveOfAWindowWeDoNotManageCostsNoRoundTrip() {
        let world = LiveWorld()
        world.watcher.start()

        world.watcher.handle(.windowMoved(WindowId(9_999)))

        #expect(world.source.frameReads.isEmpty)
    }
}

// MARK: - Teardown

@Suite @MainActor struct WorldWatcherTeardownTests {

    @Test func aQuitAppTakesItsWindowsItsObserverAndItsLaneWithIt() {
        let world = LiveWorld()
        world.watcher.start()
        let one = try! #require(world.id(titled: "one"))
        let two = try! #require(world.id(titled: "two"))
        let term = try! #require(world.id(titled: "term"))

        world.watcher.handle(.appTerminated(200))

        #expect(world.source.unwatchedApps == [200])
        let destroyed = world.recorder.events.compactMap {
            if case .windowDestroyed(let id) = $0 { return id } else { return nil }
        }
        #expect(destroyed.sorted() == [one, two].sorted())
        #expect(world.registry.ids == [term])
        // And it is genuinely gone: a stale notification about it must not reach the core.
        let before = world.recorder.events.count
        world.watcher.handle(.windowMoved(one))
        world.watcher.handle(.windowAppeared(200))
        #expect(world.recorder.events.count == before)
    }

    @Test func aClosedWindowIsForgottenAndUnwatchedBeforeItIsAnnouncedDead() {
        let world = LiveWorld()
        world.watcher.start()
        let id = try! #require(world.id(titled: "one"))

        world.watcher.handle(.windowVanished(id))

        #expect(world.source.unwatchedWindows == [id])
        #expect(world.registry.record(id) == nil)
        #expect(world.recorder.events.last == .windowDestroyed(id))
        // Unwatching needs the record's pid, so it has to happen before the registry lets go — a
        // reversed order silently leaks the registrations it was meant to remove.
        #expect(world.registry.count == 2)
    }

    @Test func aVanishedWindowWeNeverManagedIsSilence() {
        let world = LiveWorld()
        world.watcher.start()
        let before = world.recorder.events.count

        world.watcher.handle(.windowVanished(WindowId(9_999)))

        #expect(world.recorder.events.count == before)
        #expect(world.source.unwatchedWindows.isEmpty)
    }

    @Test func aWindowThatVanishesMidReadDoesNotGetReReadAfterwards() {
        let world = LiveWorld()
        world.watcher.start()
        let id = try! #require(world.id(titled: "term"))
        world.source.holdsFrameReads = true

        world.watcher.handle(.windowMoved(id))
        world.watcher.handle(.windowMoved(id))              // marks it dirty
        world.watcher.handle(.windowVanished(id))
        world.source.answerRead(rect(40, 40))               // the in-flight read finally answers

        #expect(world.source.frameReads.count == 1)         // no catch-up read for a dead window
    }
}

// MARK: - The pass-throughs

@Suite @MainActor struct WorldWatcherEventTests {

    @Test func minimizeDeminimizeFocusAndMouseUpBecomeTheirEvents() {
        let world = LiveWorld()
        world.watcher.start()
        let id = try! #require(world.id(titled: "one"))
        let before = world.recorder.events.count

        world.watcher.handle(.windowMinimized(id))
        world.watcher.handle(.windowDeminimized(id))
        world.watcher.handle(.focusMoved(id))
        world.watcher.handle(.mouseUp)

        #expect(Array(world.recorder.events.dropFirst(before)) == [
            .windowMinimized(id), .windowDeminimized(id), .focusChanged(id), .dragEnded,
        ])
    }

    @Test func focusLandingOnAnUnmanagedWindowIsPassedThroughRatherThanSwallowed() {
        // `nil` is a real answer: the user clicked into a window we declined to bind. Swallowing it
        // leaves `World.focusedWindow` naming a window the user is no longer typing into.
        let world = LiveWorld()
        world.watcher.start()
        let before = world.recorder.events.count

        world.watcher.handle(.focusMoved(nil))

        #expect(Array(world.recorder.events.dropFirst(before)) == [.focusChanged(nil)])
    }

    // MARK: Focus reports macOS made up
    //
    // An app that loses its key window picks a replacement and announces it, byte-identical to what a
    // Cmd-Tab produces. Told apart by the only fact that separates them: whether the window the report
    // displaced still exists. See `WorldWatcher.resolveFocus`.

    @Test func theFirstFocusReportIsPassedStraightThroughWithNothingToAsk() {
        let world = LiveWorld()
        world.watcher.start()
        let id = try! #require(world.id(titled: "one"))
        let before = world.recorder.events.count

        world.watcher.handle(.focusMoved(id))

        #expect(world.source.aliveProbes.isEmpty, "nothing was displaced, so there is no question")
        #expect(Array(world.recorder.events.dropFirst(before)) == [.focusChanged(id)])
    }

    @Test func aFocusReportDisplacingALiveWindowIsTheUserAndReaches() {
        let world = LiveWorld()
        world.watcher.start()
        let one = try! #require(world.id(titled: "one"))
        let two = try! #require(world.id(titled: "two"))
        world.watcher.handle(.focusMoved(one))
        let before = world.recorder.events.count

        world.watcher.handle(.focusMoved(two))       // a Cmd-Tab: window `one` is still there

        #expect(world.source.aliveProbes == [one])
        #expect(Array(world.recorder.events.dropFirst(before)) == [.focusChanged(two)])
    }

    @Test func aFocusReportBackfillingADeadWindowIsDropped() {
        // ⌘W on the focused window, and the app hands focus to one of its own choosing before the
        // destroy notification arrives. The core has its own rule for where focus goes when a window
        // leaves, so it must never see this.
        let world = LiveWorld()
        world.watcher.start()
        let one = try! #require(world.id(titled: "one"))
        let two = try! #require(world.id(titled: "two"))
        world.watcher.handle(.focusMoved(one))
        world.source.dead = [one]                    // closed, but `windowVanished` hasn't landed yet
        let before = world.recorder.events.count

        world.watcher.handle(.focusMoved(two))

        #expect(world.source.aliveProbes == [one])
        #expect(world.recorder.events.count == before, "no focusChanged reached the core")
    }

    @Test func aReportArrivingAfterTheDestroyIsDroppedWithoutAskingAnyone() {
        // The other notification order: `windowVanished` first, so the registry has already forgotten
        // the window and answers the question for free.
        let world = LiveWorld()
        world.watcher.start()
        let one = try! #require(world.id(titled: "one"))
        let two = try! #require(world.id(titled: "two"))
        world.watcher.handle(.focusMoved(one))
        world.watcher.handle(.windowVanished(one))
        let before = world.recorder.events.count

        world.watcher.handle(.focusMoved(two))

        #expect(world.source.aliveProbes.isEmpty, "the registry knew; no round trip was spent")
        #expect(world.recorder.events.count == before)
    }

    @Test func aDestroyLandingWhileTheProbeIsOutRetiresTheReport() {
        // The probe answers "alive" because it was asked before the element died, and the destroy
        // arrives while it is out. The re-check on the way back is what catches it.
        let world = LiveWorld()
        world.watcher.start()
        let one = try! #require(world.id(titled: "one"))
        let two = try! #require(world.id(titled: "two"))
        world.watcher.handle(.focusMoved(one))
        world.source.holdsProbes = true

        world.watcher.handle(.focusMoved(two))
        world.watcher.handle(.windowVanished(one))
        let before = world.recorder.events.count
        world.source.answerProbe(true)               // stale: taken before the element was invalidated

        #expect(world.recorder.events.count == before)
    }

    @Test func onlyTheOneBackfilledReportIsLostAndFocusTracksNormallyAfterIt() {
        // The cost is bounded at exactly one report, because the dropped one still updates what the
        // next report is read against — focus must not go deaf after every close.
        let world = LiveWorld()
        world.watcher.start()
        let one = try! #require(world.id(titled: "one"))
        let two = try! #require(world.id(titled: "two"))
        let term = try! #require(world.id(titled: "term"))
        world.watcher.handle(.focusMoved(one))
        world.source.dead = [one]

        world.watcher.handle(.focusMoved(two))        // dropped: `one` is gone
        let before = world.recorder.events.count
        world.watcher.handle(.focusMoved(term))       // a real Cmd-Tab a moment later

        #expect(Array(world.recorder.events.dropFirst(before)) == [.focusChanged(term)],
                "read against `two`, which is alive")
    }

    @Test func minimizingAWindowWeDoNotManageIsSilence() {
        let world = LiveWorld()
        world.watcher.start()
        let before = world.recorder.events.count

        world.watcher.handle(.windowMinimized(WindowId(9_999)))

        #expect(world.recorder.events.count == before)
    }
}
