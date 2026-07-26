import EmiraCore
import Foundation

// The truth plane's third piece, and the one that makes the other two mean something: reads told the
// daemon what was on the desktop at boot, writes let it rearrange that, and this keeps the two in
// agreement as the user works. It is where a `WorldObservation` becomes an `Event`, which for most
// cases is a rename — and for three of them is the whole reason this file exists.
//
// **1. "A window appeared" is answered by re-scanning its app, not by binding an element.** The
// notification carries an `AXUIElement` and no window number; identity is a join against the public
// window list, and the join is only sound when an app's windows are compared *together*
// (`WindowRegistry`). So the response is `AXEnumerator.enumerate(apps: [thatApp])`, whose report says
// which windows are new. This is also why `Report.snapshots` means *newly adopted* — announcing a
// re-scan's whole answer would give focus to whichever window sorted last, every time any window of
// that app opened.
//
// **2. Two macOS races have no notification, and both are answered by trying again.** A window the AX
// API has already announced may not be in `CGWindowListCopyWindowInfo` yet (it binds as `.noCandidate`,
// and would then never be managed); an app that has just launched may not be ready to be observed at
// all (`watch` fails, and we go permanently blind to it). These look like different bugs and are the
// same bug — *asked too early* — so they share one bounded retry: re-scan the app after a beat, at most
// `maxScanAttempts` times. Bounded, because the other reading of both failures is "this window/app is
// genuinely not ours", and retrying that forever is a busy loop against the user's desktop.
//
// **3. A notification storm is a poll unless you coalesce it.** A drag emits `AXWindowMoved` at the
// refresh rate, and AX will not say *where* — each one costs a round trip into the app that is
// currently busy dragging. Worse, those reads queue on that app's serial lane (§5), which is the same
// lane our placement writes use: answer every notification and the `dragEnded` re-tile lands behind a
// backlog of stale reads, a second late and visibly wrong. So at most **one read per window is ever in
// flight**, and anything that arrives while it is out sets a dirty bit that is honoured exactly once
// when it returns. The user gets the frame at the end of the burst, which is the only one that matters.
//
// Everything else here is bookkeeping with a rule: **nothing keyed on a pid or a `WindowId` outlives
// the thing it is keyed on.** An app that quits takes its windows, its observer, its run-loop source
// and its AX lane with it; a window that closes takes its registrations and its pending frame read.

/// Turns the live system into `Event`s: enumerates at boot, watches everything it adopts, and keeps the
/// core's `World` in agreement with the desktop from then on.
///
/// Holds no core state — it dispatches through an `EventSink` like every other event source
/// (`Executor.swift`) — and no macOS state either, which all sits behind `ObservationSource`.
@MainActor
public final class WorldWatcher {

    /// How many times a scan of one app may be retried before we accept its answer.
    ///
    /// Three total attempts, ~150 ms apart. The failures this covers are startup races measured in
    /// frames, so the second attempt is nearly always the last one; the third exists because "nearly
    /// always" is not a guarantee and the cost of one more scan of one app is a few AX reads.
    public static let maxScanAttempts = 3

    /// How long to wait before re-scanning an app whose answer looked like a race.
    ///
    /// Long enough that the window server and the app have both moved on (a frame at 60 Hz is 16 ms),
    /// short enough that a window which needed the retry still tiles before the user notices it was
    /// briefly untiled.
    public static let rescanDelay: TimeInterval = 0.15

    private let source: any ObservationSource
    private let enumerator: AXEnumerator
    private let registry: WindowRegistry
    private let scheduler: any DelayScheduler
    private let sink: EventSink

    /// Called for every scan that could not account for something it saw — on either side of the join.
    ///
    /// Only the *boot* scan was ever reported (the daemon's `start` completion), so through 2026-07-26
    /// a steady-state window that failed to bind was invisible: no log line, no state-dump entry,
    /// nothing but a window sitting untiled on the desktop. `AXEnumerator`'s own header says a window
    /// manager quietly not managing something is the failure the user cannot debug; this is that
    /// sentence made true after launch as well.
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

    /// Apps with a scan out on a lane right now. The gate on the *scan* coalescer — the same shape as
    /// `reading`, for the same reason (2026-07-26).
    private var scanning: Set<pid_t> = []

    /// Apps that produced another `windowAppeared` while their scan was out. Re-scanned exactly once
    /// when it returns.
    private var rescan: Set<pid_t> = []

    public init(source: any ObservationSource, enumerator: AXEnumerator, registry: WindowRegistry,
                scheduler: any DelayScheduler, sink: EventSink) {
        self.source = source
        self.enumerator = enumerator
        self.registry = registry
        self.scheduler = scheduler
        self.sink = sink
    }

    /// Enumerate the desktop, adopt it, and start watching. `completion` runs once the boot scan's
    /// windows have been dispatched — i.e. when `Runtime.state` first describes the real desktop.
    ///
    /// **This is the one scan whose windows emira did not watch open**, and it says so
    /// (`alreadyOpen`): the core keeps an adopted window's existing width instead of snapping it onto the
    /// first preset (`WindowSnapshot.wasAlreadyOpen`, 2026-07-26). The flag is a fact about *this scan*
    /// rather than about a window, which is why it lives here and not in `AXEnumerator` — the enumerator
    /// runs identical code at boot and in steady state, and only the watcher knows which call is which.
    public func start(completion: @escaping @MainActor (AXEnumerator.Report) -> Void = { _ in }) {
        source.start { [weak self] observation in self?.handle(observation) }
        enumerator.enumerate { [weak self] report in
            self?.absorb(report, attempt: 0, alreadyOpen: true)
            completion(report)
        }
    }

    /// Fold one observation into the core. Public because it is the whole of this type's behaviour and
    /// the tests drive it directly — the live source is the only thing that normally calls it.
    public func handle(_ observation: WorldObservation) {
        switch observation {

        case .appLaunched(let target):
            // Both halves, because they answer different questions: `watch` is how we hear about the
            // app's *future* windows, and the scan is how we find the ones it already made — a
            // re-launched app can come back with windows restored before we ever see a notification.
            ensureWatching(target, attempt: 0)
            scan([target], attempt: 0)

        case .appTerminated(let pid):
            apps[pid] = nil
            observing.remove(pid)
            scanning.remove(pid)
            rescan.remove(pid)
            source.unwatch(app: pid)
            // The registry is the authority on what the app owned; the core is told window by window,
            // because `World` has no notion of an app dying — only of windows going away.
            for id in registry.forget(app: pid) {
                reading.remove(id)
                moved.remove(id)
                sink(.windowDestroyed(id))
            }

        case .windowAppeared(let pid):
            // An app we aren't tracking (an accessory process, or one that quit between the
            // notification and here) has nothing to scan. Silence is the honest answer.
            guard let target = apps[pid] else { return }
            scan([target], attempt: 0)

        case .windowVanished(let id):
            guard let record = registry.record(id) else { return }
            source.unwatch(window: id, of: record.pid)
            registry.forget(id)
            reading.remove(id)
            moved.remove(id)
            sink(.windowDestroyed(id))

        case .windowMoved(let id):
            guard registry.record(id) != nil else { return }
            guard !reading.contains(id) else { moved.insert(id); return }
            readFrame(of: id)

        case .windowMinimized(let id):
            guard registry.record(id) != nil else { return }
            sink(.windowMinimized(id))

        case .windowDeminimized(let id):
            guard registry.record(id) != nil else { return }
            sink(.windowDeminimized(id))

        case .focusMoved(let id):
            sink(.focusChanged(id))

        case .mouseUp:
            sink(.dragEnded)
        }
    }

    // MARK: - Scanning

    /// Scan a set of apps and absorb the result, carrying the attempt number so the report knows
    /// whether it is allowed to ask again.
    ///
    /// **At most one scan per app is ever in flight** (2026-07-26), the same rule `readFrame` keeps for
    /// frame reads and for the same reason: four rapid ⌘N presses produce four `windowAppeared`
    /// notifications, and answering each with its own full re-scan puts four × (7 AX round trips per
    /// window) onto the app's *single serial lane* — the same lane our placement writes queue on, under
    /// a 250 ms per-call timeout. The scans then answer progressively later than the window list they
    /// are joined against, which is precisely the skew that costs a window its identity. A request that
    /// arrives while a scan is out sets a dirty bit honoured once when it returns, so the app is always
    /// re-asked, never re-asked four times over.
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
    /// `alreadyOpen` marks the windows this scan announces as ones emira met mid-life rather than watched
    /// open (`start`). It is carried down the *retry* chain too: a boot window that took a second attempt
    /// to bind was no less already open than its siblings, and losing the flag there would tile it
    /// differently from every other window on the desktop for no reason the user could ever see.
    private func absorb(_ report: AXEnumerator.Report, attempt: Int, alreadyOpen: Bool = false) {
        for target in report.apps {
            scanning.remove(target.pid)
            ensureWatching(target, attempt: attempt, alreadyOpen: alreadyOpen)
        }

        // Watch before announcing. Dispatching `windowCreated` pumps the reducer synchronously and its
        // placement effects move the window we just adopted — if registration came second, the window
        // would be observed only from its *next* move onward. (Our own move then echoes back as a
        // `windowFrameChanged` that agrees with what the core already recorded optimistically, so it
        // costs one read and changes nothing. Being blind to a real move costs correctness.)
        //
        // **`rebound` is offered too** (2026-07-26). Registration is idempotent — `watch(windows:of:)`
        // skips anything already registered — so re-offering a known window costs nothing when the
        // first attempt worked, and is the *only* second chance when it didn't. A registration that
        // failed leaves a window whose destroy notification never arrives, i.e. a column that outlives
        // its window: an empty slot on the strip, forever.
        var byApp: [pid_t: [WindowId]] = [:]
        for id in report.snapshots.map(\.id) + report.rebound {
            guard let record = registry.record(id) else { continue }
            byApp[record.pid, default: []].append(id)
        }
        for (pid, ids) in byApp {
            source.watch(windows: ids, of: pid)
        }
        for snapshot in report.snapshots {
            sink(.windowCreated(alreadyOpen ? snapshot.metAlreadyOpen() : snapshot))
        }

        // Something appeared while the scan was out. Ask again now rather than through the retry
        // budget: this is not a race we are waiting out, it is a request we deliberately coalesced.
        let pending = report.apps.filter { rescan.remove($0.pid) != nil }
        if !pending.isEmpty { scan(pending, attempt: 0) }

        // A window one side of the join described and the other didn't is the race in §2 above — now
        // in both directions (`Report.unclaimed`). Ask again, once, against the same apps — not against
        // `source.applications()`, which may answer differently and turn a one-app retry into a full
        // re-scan.
        guard report.isIncomplete else { return }
        // Reported on the *last* attempt only: the earlier ones are the race being waited out, and
        // saying so every 150 ms would make the ordinary case look like a fault.
        if attempt + 1 >= Self.maxScanAttempts { onIncompleteScan?(report) }

        guard attempt + 1 < Self.maxScanAttempts else { return }
        let targets = report.apps
        scheduler.schedule(after: Self.rescanDelay) { [weak self] in
            self?.scan(targets, attempt: attempt + 1, alreadyOpen: alreadyOpen)
        }
    }

    /// Register an app's observer if it isn't already, retrying a failure inside the same budget as a
    /// failed bind — the two are the same "asked too early" race wearing different clothes. `alreadyOpen`
    /// rides along for the same reason it does through the other retry: an app that wasn't ready to be
    /// observed at boot still has boot's windows behind it.
    private func ensureWatching(_ target: ScanTarget, attempt: Int, alreadyOpen: Bool = false) {
        apps[target.pid] = target
        guard !observing.contains(target.pid) else { return }
        // Optimistic, and cleared below on failure: registration crosses onto the app's lane, so
        // without this a second scan arriving mid-flight would register the same app twice.
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

    // MARK: - Frame reads (the coalescer)

    /// Read one window's frame, then honour at most one move that arrived while we were asking.
    private func readFrame(of id: WindowId) {
        reading.insert(id)
        source.readFrame(of: id) { [weak self] frame in
            guard let self else { return }
            reading.remove(id)
            // A read that came back empty is a window that stopped answering — it closed mid-drag. Say
            // nothing: `windowVanished` is what reports that, and inventing a frame change for a dead
            // window would put a lie in `World` that only the next scan could correct.
            if let frame { sink(.windowFrameChanged(id, frame)) }
            guard moved.remove(id) != nil, registry.record(id) != nil else { return }
            readFrame(of: id)
        }
    }
}
