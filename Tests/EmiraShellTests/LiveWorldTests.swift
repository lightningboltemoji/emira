import ApplicationServices
import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// `WorldWatcher`'s tests — the policy that turns a live desktop into `Event`s. Everything that needs a
// window server, a TCC grant and other people's processes sits behind `ObservationSource` and
// `WindowSource`, so what is exercised here is precisely the part with decisions in it:
//
//  1. **Adoption** — a scan's windows are announced *once*, and a re-scan of a known app announces
//     nothing. The failure this prevents is not a duplicate: `Engine` gives a new window focus, so a
//     re-announcement steals the user's focus every time any window of that app opens.
//  2. **The two "asked too early" races** — a window the window server has not listed yet, and an app
//     that is not ready to be observed. Both retried, both bounded, and the bound is asserted because
//     the alternative reading of either failure is "not ours", which must not become a busy loop.
//  3. **Coalescing** — a drag emits `AXWindowMoved` at the refresh rate and AX will not say *where*, so
//     answering every one is a poll that queues on the same lane our placement writes use.
//  4. **Teardown ordering** — nothing keyed on a pid or a `WindowId` outlives the thing it is keyed on:
//     the registry, the observer registrations, and the pending-read bookkeeping all let go together.
//
// The event stream is asserted against an `EventSink`, which is what the daemon really wires up — so
// these tests say what the *core* would be told, not merely what the watcher computed.

// MARK: - Fixtures

private func rect(_ x: Double, _ y: Double = 0, w: Double = 600, h: Double = 400) -> Rect {
    Rect(x: x, y: y, width: w, height: h)
}

/// A distinct AX element per window. Distinctness matters: the registry's reverse map is keyed on
/// element equality, so fixtures that shared one element would let a lookup bug pass.
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

    func applications() -> [ScanTarget] { targets }

    func windows(of target: ScanTarget,
                 then completion: @escaping @MainActor ([ScannedWindow]) -> Void) {
        completion(windowsByPid[target.pid] ?? [])
    }

    func windowList() -> [WindowListEntry] { entries }
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
}

/// A scheduler that never runs anything until the test says so — the whole retry chain, under the
/// test's thumb, with no wall clock in it.
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

/// The fixture, named `LiveWorld` rather than `World` so it can't be mistaken for — or shadow —
/// `EmiraCore.World`, which is the thing all of this is ultimately keeping true.
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

// MARK: - Adoption

@Suite @MainActor struct WorldWatcherAdoptionTests {

    @Test func bootAnnouncesEveryWindowAndWatchesEveryAppAndWindow() {
        let world = LiveWorld()

        world.watcher.start()

        #expect(world.source.started)
        #expect(world.created.map(\.title) == ["term", "one", "two"])
        #expect(world.source.watchedApps.sorted() == [100, 200])
        // Window-level notifications are registered per app, because AX delivers destroyed/moved/
        // resized/miniaturized only for registrations made against the *window* element.
        let byApp = Dictionary(uniqueKeysWithValues: world.source.watchedWindows.map { ($0.0, $0.1) })
        #expect(byApp[100]?.count == 1)
        #expect(byApp[200]?.count == 2)
        #expect(world.registry.count == 3)
    }

    @Test func aWindowIsWatchedBeforeItIsAnnounced() {
        // Announcing pumps the reducer synchronously, and its placement effects move the window we
        // just adopted. Registering second would leave that window observed only from its *next* move
        // onward — a window emira has moved but is not yet watching is a window whose next real drag
        // it can miss entirely.
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
        // The focus-theft guard, end to end: `AXWindowCreated` names the *app*, so the response is a
        // re-scan — and a re-scan that announced all three of TextEdit's windows would leave focus on
        // whichever sorted last rather than on the window that just opened.
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

    @Test func aWindowAppearingInAnAppWeDoNotTrackIsSilence() {
        // An accessory process, or an app that quit between the notification and here. There is
        // nothing to scan and nothing to say.
        let world = LiveWorld()
        world.watcher.start()
        let before = world.recorder.events.count

        world.watcher.handle(.windowAppeared(999))

        #expect(world.recorder.events.count == before)
    }

    @Test func aLaunchedAppIsBothWatchedAndScanned() {
        // Two halves answering different questions: `watch` is how we hear about the app's *future*
        // windows; the scan finds the ones a relaunched app came back with already open.
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
        // `.noCandidate`. Without a retry that window is never managed — a sticky, invisible failure
        // of exactly the kind first-sight binding is supposed to avoid.
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
        // about any window that app ever opens — the same permanent blindness as a failed bind, which
        // is why they share one retry budget.
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
        // A drag emits `AXWindowMoved` at the refresh rate and AX never says *where*. Answering each
        // one queues a round trip on the app's serial lane — the same lane the drag-end re-tile has to
        // use, so the snap-back would land a backlog late. One in flight, one dirty bit, and the user
        // gets the frame at the end of the burst, which is the only one that matters.
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
        // The window closed mid-drag. Inventing a frame for it would put a lie in `World` that only
        // the next scan could correct; `windowVanished` is what reports this.
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
        // would leave `World.focusedWindow` pointing at whatever we last knew — a window the user is
        // no longer typing into, which is the state §4a exists to prevent.
        let world = LiveWorld()
        world.watcher.start()
        let before = world.recorder.events.count

        world.watcher.handle(.focusMoved(nil))

        #expect(Array(world.recorder.events.dropFirst(before)) == [.focusChanged(nil)])
    }

    @Test func minimizingAWindowWeDoNotManageIsSilence() {
        let world = LiveWorld()
        world.watcher.start()
        let before = world.recorder.events.count

        world.watcher.handle(.windowMinimized(WindowId(9_999)))

        #expect(world.recorder.events.count == before)
    }
}
