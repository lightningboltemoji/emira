import EmiraCore
import Foundation

// Where a `WorldObservation` becomes an `Event`. Mostly a rename; four cases are why this file exists.
//
// 1. "A window appeared" is answered by re-scanning its app, not by binding the element the notification
//    carries: it has no window number, and the identity join is only sound when an app's windows are
//    compared *together*. `Report.snapshots` therefore means *newly adopted*.
// 2. Two macOS races have no notification and both are answered by trying again: a window AX already
//    announced may not be in `CGWindowListCopyWindowInfo` yet (binds `.noCandidate`, never managed), and
//    a just-launched app may not be ready to be observed at all (`watch` fails, we go blind to it). Same
//    bug — asked too early — so one bounded retry covers both.
// 3. A notification storm is a poll unless you coalesce it. A drag emits `AXWindowMoved` at the refresh
//    rate and AX will not say *where*, so each one costs a round trip on the same serial lane our
//    placement writes use. At most one read per window is ever in flight; anything arriving while it is
//    out sets a dirty bit honoured exactly once when it returns.
// 4. A destroyed element is not always a window leaving the strip — a tab group's selected tab dies
//    while the group carries on — so a destroy is announced only after one scan has said whether
//    anything took its place (`vanish`). The single deferral in this file, and it is bounded.
//
// Everything else is bookkeeping, with one rule: nothing keyed on a pid or a `WindowId` outlives the
// thing it is keyed on.

/// Turns the live system into `Event`s: enumerates at boot, watches everything it adopts, and keeps the
/// core's `World` in agreement with the desktop from then on. Holds no core state (it dispatches through
/// an `EventSink`) and no macOS state (that all sits behind `ObservationSource`).
@MainActor
public final class WorldWatcher {

    /// How many times a scan of one app may be retried before we accept its answer. The failures this
    /// covers are startup races measured in frames, so the second attempt is nearly always the last.
    public static let maxScanAttempts = 3

    /// How long to wait before re-scanning an app whose answer looked like a race — long enough for the
    /// window server and the app to move on, short enough to tile before the user notices.
    public static let rescanDelay: TimeInterval = 0.15

    /// How long a destroyed window's id may wait for a scan to say whether anything took its place
    /// (`vanish`). A backstop rather than a delay: the ordinary answer arrives when the scan does, one
    /// lane round trip later, including the app that answers with no windows at all — which is what
    /// closing an app's *last* window looks like. This fires only when a scan settles nothing, and its
    /// cost when it does is one dead window on the strip for a quarter second.
    public static let successionGrace: TimeInterval = 0.25

    private let source: any ObservationSource
    private let enumerator: AXEnumerator
    private let registry: WindowRegistry
    private let scheduler: any DelayScheduler
    private let sink: EventSink

    /// Called for every scan that could not account for something it saw, on either side of the join.
    /// A window manager quietly not managing something is the failure a user cannot debug.
    public var onIncompleteScan: (@MainActor (AXEnumerator.Report) -> Void)?

    /// Every app we know how to re-scan, by pid. Populated from scan reports and from launches.
    private var apps: [pid_t: ScanTarget] = [:]

    /// The apps whose observer is registered (or whose registration is in flight — set optimistically,
    /// cleared on failure, so a retry can't stack two registrations for one app).
    private var observing: Set<pid_t> = []

    /// Windows with a frame read out on a lane right now. The gate on the coalescer.
    private var reading: Set<WindowId> = []

    /// Windows that moved again while their read was out. Re-read exactly once when it returns.
    private var moved: Set<WindowId> = []

    /// Apps with a scan out on a lane right now. The gate on the *scan* coalescer.
    private var scanning: Set<pid_t> = []

    /// Apps that produced another `windowAppeared` while their scan was out. Re-scanned exactly once
    /// when it returns.
    private var rescan: Set<pid_t> = []

    /// Windows whose element is destroyed and whose *id* has not been retired yet, because a scan may
    /// still hand it to a successor (`vanish`). Dead for every other purpose — see `isLive`.
    private var vanishing: Set<WindowId> = []

    /// Whether the watcher has been shut down (`stop()`). Once set, nothing reaches the core again.
    private var isStopped = false

    /// The window the *system* last reported as focused, whether or not we passed it on. It exists only
    /// to name the window a new report displaces (`resolveFocus`), so it tracks reports rather than
    /// deliveries and is deliberately not cleared when its window dies.
    private var focus: WindowId?

    public init(source: any ObservationSource, enumerator: AXEnumerator, registry: WindowRegistry,
                scheduler: any DelayScheduler, sink: EventSink) {
        self.source = source
        self.enumerator = enumerator
        self.registry = registry
        self.scheduler = scheduler
        self.sink = sink
    }

    /// Enumerate the desktop, adopt it, and start watching. `completion` runs once the boot scan's
    /// windows have been dispatched.
    ///
    /// The one scan whose windows emira did not watch open, and it says so (`alreadyOpen`): the core
    /// keeps an adopted window's existing width instead of snapping it onto the first preset. A fact
    /// about *this scan*, not about a window — the enumerator runs identical code at boot and after.
    public func start(completion: @escaping @MainActor (AXEnumerator.Report) -> Void = { _ in }) {
        source.start { [weak self] observation in self?.handle(observation) }
        enumerator.enumerate { [weak self] report in
            self?.absorb(report, attempt: 0, alreadyOpen: true)
            completion(report)
        }
    }

    /// Stop turning the desktop into events, permanently. Teardown calls this first because our own
    /// writes are observations: shutdown places every managed window into the quit cascade, and a live
    /// watcher would answer each placement with `windowFrameChanged` and re-tile the window it is being
    /// taken off. A latch, not an unregistration — tearing down live `AXObserver`s and their run-loop
    /// sources at exit buys nothing and crashes if subtly wrong.
    public func stop() {
        isStopped = true
    }

    /// Hand one event to the core, unless we have stopped. Every `sink` call in this file goes through
    /// here — especially the asynchronous ones, since a scan, frame read or liveness probe already out on
    /// a lane when `stop()` lands will still come back and try to speak.
    private func emit(_ event: Event) {
        guard !isStopped else { return }
        sink(event)
    }

    /// Fold one observation into the core. Public because it is the whole of this type's behaviour and
    /// the tests drive it directly.
    public func handle(_ observation: WorldObservation) {
        guard !isStopped else { return }
        switch observation {

        case .appLaunched(let target):
            // Both halves: `watch` hears about the app's future windows, the scan finds the ones it
            // already made — a re-launched app can restore windows before we see any notification.
            ensureWatching(target, attempt: 0)
            scan([target], attempt: 0)

        case .appTerminated(let pid):
            apps[pid] = nil
            observing.remove(pid)
            scanning.remove(pid)
            rescan.remove(pid)
            source.unwatch(app: pid)
            // Window by window: `World` has no notion of an app dying, only of windows going away.
            // Nothing here waits on a successor — the process that would have produced one is gone.
            for id in registry.forget(app: pid) {
                reading.remove(id)
                moved.remove(id)
                vanishing.remove(id)
                emit(.windowDestroyed(id))
            }

        case .windowAppeared(let pid):
            // An app we aren't tracking (accessory process, or one that quit in the meantime).
            guard let target = apps[pid] else { return }
            scan([target], attempt: 0)

        case .windowVanished(let id):
            vanish(id)

        case .windowMoved(let id):
            guard isLive(id) else { return }
            guard !reading.contains(id) else { moved.insert(id); return }
            readFrame(of: id)

        case .windowMinimized(let id):
            guard isLive(id) else { return }
            emit(.windowMinimized(id))

        case .windowDeminimized(let id):
            guard isLive(id) else { return }
            emit(.windowDeminimized(id))

        case .focusMoved(let id):
            resolveFocus(id)

        case .mouseUp:
            emit(.dragEnded)
        }
    }

    // MARK: - Retirement (the destroy that waits for one answer)

    /// Whether a window is still one the core should hear about. A vanished window is not: its element
    /// is destroyed and the only thing still open about it is where its *id* goes.
    private func isLive(_ id: WindowId) -> Bool {
        registry.record(id) != nil && !vanishing.contains(id)
    }

    /// Take a destroyed window off the strip — after asking, exactly once, whether anything took its
    /// place.
    ///
    /// `AXUIElementDestroyed` proves an *element* died. It does not prove the *window* left, and a
    /// native tab group is where those differ: ⌘W destroys the selected tab while the group it stood for
    /// carries on under the next one, which AX then starts describing in its place. Only a scan can see
    /// that (`AXEnumerator`'s second join), and the scan is asynchronous — so retiring the id here, the
    /// moment the notification lands, is a race the succession loses more often than not: the id is
    /// gone before the scan that would have moved it onto the successor even returns, and the group's
    /// column is torn down and rebuilt with its width, float state and workspace reset.
    ///
    /// So the id waits, and *only* the id: `isLive` is false from this moment, so no frame read, focus
    /// report or minimize notification about the window reaches the core in between. It is retired by
    /// `absorb` when the scan answers — rebound onto a successor, or gone — and by `successionGrace` if
    /// the scan settles nothing, which is what makes the wait terminate.
    private func vanish(_ id: WindowId) {
        guard let record = registry.record(id), !vanishing.contains(id) else { return }
        // The element is dead either way, so stop reading it now rather than at retirement.
        reading.remove(id)
        moved.remove(id)
        // Nobody to ask: an app we hold no scan target for cannot produce a successor.
        guard let target = apps[record.pid] else {
            retire(id)
            return
        }
        vanishing.insert(id)
        scan([target], attempt: 0)
        scheduler.schedule(after: Self.successionGrace) { [weak self] in
            guard let self, vanishing.contains(id) else { return }
            retire(id)
        }
    }

    /// Stop watching a window, forget it, and tell the core it is gone. The one place a `windowDestroyed`
    /// comes from, whether the window announced its own death (`vanish`) or a scan noticed it (`absorb`).
    private func retire(_ id: WindowId) {
        vanishing.remove(id)
        guard let record = registry.record(id) else { return }
        source.unwatch(window: id, of: record.pid)
        registry.forget(id)
        reading.remove(id)
        moved.remove(id)
        emit(.windowDestroyed(id))
    }

    // MARK: - Scanning

    /// Scan a set of apps and absorb the result, carrying the attempt number so the report knows whether
    /// it may ask again.
    ///
    /// At most one scan per app is ever in flight, the same rule `readFrame` keeps: four rapid ⌘N presses
    /// would otherwise pile four full re-scans onto one serial lane under a 250 ms per-call timeout, and
    /// each would answer later than the window list it is joined against — the skew that costs a window
    /// its identity.
    private func scan(_ targets: [ScanTarget], attempt: Int, alreadyOpen: Bool = false) {
        let admitted = targets.filter { target in
            guard scanning.contains(target.pid) else { return true }
            rescan.insert(target.pid)
            return false
        }
        guard !admitted.isEmpty else { return }
        for target in admitted { scanning.insert(target.pid) }
        enumerator.enumerate(apps: admitted) { [weak self] report in
            self?.absorb(report, attempt: attempt, alreadyOpen: alreadyOpen)
        }
    }

    /// Take a scan's answer into the world: watch what it covered, announce what is new, and decide
    /// whether the gaps in it are worth asking about again.
    ///
    /// `alreadyOpen` marks the windows this scan announces as ones emira met mid-life. Carried down the
    /// retry chain too: a boot window that needed a second attempt is no less already open.
    private func absorb(_ report: AXEnumerator.Report, attempt: Int, alreadyOpen: Bool = false) {
        for target in report.apps {
            scanning.remove(target.pid)
            ensureWatching(target, attempt: attempt, alreadyOpen: alreadyOpen)
        }

        // Watch before announcing: dispatching `windowCreated` pumps the reducer synchronously and its
        // placement effects move the window we just adopted, so registering second would miss that move.
        // `rebound` is offered too — registration is idempotent, and a registration that failed the first
        // time leaves a window whose destroy notification never arrives (an empty slot on the strip).
        // A succession kept the id and changed the element under it, so the registration the old element
        // holds is now watching the wrong window — and `watch(windows:)` is idempotent *by id*, which
        // would skip the new one entirely. Dropping it first makes the re-registration below land, and
        // takes the retired tab's notifications off the observer on the way past.
        for id in report.succeeded {
            guard let record = registry.record(id) else { continue }
            source.unwatch(window: id, of: record.pid)
        }

        var byApp: [pid_t: [WindowId]] = [:]
        for id in report.snapshots.map(\.id) + report.rebound + report.succeeded {
            guard let record = registry.record(id) else { continue }
            byApp[record.pid, default: []].append(id)
        }
        for (pid, ids) in byApp {
            source.watch(windows: ids, of: pid)
        }

        // Retired before anything is announced: these windows are leaving the strip, and letting a new
        // column arrive first would tile against a layout still holding the ones it replaces.
        for id in report.departed { retire(id) }

        // The deferred destroys (`vanish`) this scan can settle, on the same principle and so before the
        // same arrivals. A succession gave the id somewhere to go; a departure has already retired it
        // just above. A scan that still *listed* the window read AX before the element died and settles
        // nothing, so that one waits for the next scan — or, failing everything, for the grace deadline.
        // Anything else is the answer the wait was for: the app has been asked, and nothing stood in.
        let inherited = Set(report.succeeded)
        let stillListed = Set(report.rebound)
        let asked = Set(report.apps.map(\.pid))
        for id in vanishing.sorted() {
            guard let record = registry.record(id) else { vanishing.remove(id); continue }
            guard asked.contains(record.pid) else { continue }
            if inherited.contains(id) { vanishing.remove(id); continue }
            // A scan that may have missed an *arrival* has not ruled a successor out — the successor is
            // a window the join could not place yet, which is the ordinary "asked too early" race and
            // already has a retry behind it. Waiting for that costs a retry interval; not waiting costs
            // the column.
            guard !stillListed.contains(id), !report.mayHaveMissedAnArrival else { continue }
            retire(id)
        }

        for snapshot in report.snapshots {
            emit(.windowCreated(alreadyOpen ? snapshot.metAlreadyOpen() : snapshot))
        }

        // Something appeared while the scan was out: ask again now rather than through the retry budget,
        // since this is a request we coalesced, not a race we are waiting out.
        let pending = report.apps.filter { rescan.remove($0.pid) != nil }
        if !pending.isEmpty { scan(pending, attempt: 0) }

        // A window one side of the join described and the other didn't is the "asked too early" race.
        // Retry the same apps, not `source.applications()`, which may answer differently and turn a
        // one-app retry into a full re-scan.
        guard report.isIncomplete else { return }
        // Reported on the last attempt only — the earlier ones are the race being waited out, and saying
        // so every 150 ms would make the ordinary case look like a fault.
        if attempt + 1 >= Self.maxScanAttempts { onIncompleteScan?(report) }

        guard attempt + 1 < Self.maxScanAttempts else { return }
        let targets = report.apps
        scheduler.schedule(after: Self.rescanDelay) { [weak self] in
            self?.scan(targets, attempt: attempt + 1, alreadyOpen: alreadyOpen)
        }
    }

    /// Register an app's observer if it isn't already, retrying a failure inside the same budget as a
    /// failed bind — both are the same "asked too early" race.
    private func ensureWatching(_ target: ScanTarget, attempt: Int, alreadyOpen: Bool = false) {
        apps[target.pid] = target
        guard !observing.contains(target.pid) else { return }
        // Optimistic, cleared below on failure: registration crosses onto the app's lane, so without this
        // a second scan arriving mid-flight would register the same app twice.
        observing.insert(target.pid)
        source.watch(app: target) { [weak self] ok in
            guard let self, !ok else { return }
            observing.remove(target.pid)
            guard attempt + 1 < Self.maxScanAttempts, apps[target.pid] != nil else { return }
            scheduler.schedule(after: Self.rescanDelay) { [weak self] in
                self?.scan([target], attempt: attempt + 1, alreadyOpen: alreadyOpen)
            }
        }
    }

    // MARK: - Focus (the report that isn't self-describing)

    /// Pass a focus report to the core — unless it is macOS backfilling the window that just died.
    ///
    /// `Event.focusChanged` means "focus moved and we did not move it, so snap the viewport to reveal
    /// it". Right for a Cmd-Tab; wrong for the other thing that posts the same notification: an app whose
    /// key window closes picks an arbitrary replacement, so closing the tenth Ghostty window can land
    /// focus on the first and snap the strip across the desktop.
    ///
    /// AppKit picks that replacement *synchronously* and destroys the closing element later, so
    /// `AXFocusedWindowChanged` normally arrives *before* `AXUIElementDestroyed` and the two cases are
    /// indistinguishable without asking whether the displaced window still exists — live means the user
    /// moved focus, dead means macOS filled a hole. The registry answers free when the destroy got here
    /// first; only the awkward order costs a round trip, and the re-check on the answer covers a destroy
    /// that arrived while we asked.
    ///
    /// Failing toward "dead" only drops a reveal (the next focus change reveals); the opposite mistake
    /// would drop a real window off the strip, which is why this never synthesizes a `windowVanished`.
    private func resolveFocus(_ id: WindowId?) {
        let displaced = focus
        focus = id
        // Nothing displaced (boot), or a report that changes nothing: there is no question to ask.
        guard let displaced, displaced != id else {
            emit(.focusChanged(id))
            return
        }
        guard isLive(displaced) else { return }   // already known dead — free answer
        source.isAlive(displaced) { [weak self] alive in
            guard let self, alive, isLive(displaced) else { return }
            emit(.focusChanged(id))
        }
    }

    // MARK: - Frame reads (the coalescer)

    /// Read one window's frame, then honour at most one move that arrived while we were asking.
    private func readFrame(of id: WindowId) {
        reading.insert(id)
        source.readFrame(of: id) { [weak self] frame in
            guard let self else { return }
            reading.remove(id)
            // An empty read is a window that closed mid-drag. Say nothing — `windowVanished` reports it,
            // and inventing a frame for a dead window puts a lie in `World`.
            if let frame {
                // Kept in step so a tab succession has an up-to-date rectangle to recognise: between
                // scans, a drag is the one thing that moves a window without our asking.
                registry.noteFrame(id, frame)
                emit(.windowFrameChanged(id, frame))
            }
            guard moved.remove(id) != nil, isLive(id) else { return }
            readFrame(of: id)
        }
    }
}
