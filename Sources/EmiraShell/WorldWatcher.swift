import CoreGraphics
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

    /// How often the window server is re-read to find windows nothing else accounted for. The retry
    /// chain answers races measured in frames; this answers the ones measured in seconds.
    public static let reconcileInterval: TimeInterval = 3

    /// How many consecutive reconciliations may ask about the same unmanaged window before it is
    /// accepted as one emira cannot manage. An on-screen layer-0 entry AX will never describe is a real
    /// thing, and without a cap it costs a scan of its app every interval, forever.
    public static let maxReconcileRounds = 3

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
    private let intent: FocusIntent
    private let sink: EventSink
    /// The reconciliation tick. Optional because the watcher is complete without it — it is a backstop,
    /// not a mechanism anything depends on — and a test that isn't about reconciliation leaves it out.
    private let heartbeat: (any Heartbeat)?

    /// Called for every scan that could not account for something it saw, on either side of the join.
    /// A window manager quietly not managing something is the failure a user cannot debug.
    public var onIncompleteScan: (@MainActor (AXEnumerator.Report) -> Void)?

    /// Every raw pointer sample, forwarded whole. This type owns the mouse monitor and therefore the
    /// fan-out, and owns nothing else about the pointer: what a sample *means* is `PointerFocus`'s (a
    /// crossing) and `PointerWake`'s (the motion that ends a hide), and the order those two run in is
    /// stated where they are wired together rather than decided here.
    public var onPointerMoved: (@MainActor (Point) -> Void)?

    /// Every app we know how to re-scan, by pid. Populated from scan reports and from launches.
    private var apps: [pid_t: ScanTarget] = [:]

    /// The apps whose observer is registered (or whose registration is in flight — set optimistically,
    /// cleared on failure, so a retry can't stack two registrations for one app).
    private var observing: Set<pid_t> = []

    /// Windows with a frame read out on a lane right now. The gate on the coalescer.
    private var reading: Set<WindowId> = []

    /// Windows that moved again while their read was out. Re-read exactly once when it returns.
    private var moved: Set<WindowId> = []

    /// Apps with a scan out on a lane right now, and whether that scan is asking about windows emira met
    /// already open. The gate on the *scan* coalescer, and the provenance a replay of it inherits.
    private var scanning: [pid_t: Bool] = [:]

    /// Apps whose scan was asked for again while one was out, and whether that request was for windows
    /// emira met already open. Re-scanned exactly once when the scan in flight returns; the flag merges
    /// with `||`, since a window wrongly announced as born now is resized and can take the desktop with it.
    private var rescan: [pid_t: Bool] = [:]

    /// Windows whose element is destroyed and whose *id* has not been retired yet, because a scan may
    /// still hand it to a successor (`vanish`). Dead for every other purpose — see `isLive`.
    private var vanishing: Set<WindowId> = []

    /// Whether the watcher has been shut down (`stop()`). Once set, nothing reaches the core again.
    private var isStopped = false

    /// On-screen windows the window server lists that emira does not manage, and how many consecutive
    /// reconciliations have asked about each. Cleared per number as soon as it binds or goes away, so a
    /// window that reappears at a recycled number starts with a full budget.
    private var unaccounted: [CGWindowID: Int] = [:]

    /// The window last reported as focused *in the present* — whether or not we passed it on, but not
    /// counting an echo of our own that arrived out of order. It exists only to name the window a new
    /// report displaces (`resolveFocus`), so it tracks reports rather than deliveries and is
    /// deliberately not cleared when its window dies.
    private var focus: WindowId?

    public init(source: any ObservationSource, enumerator: AXEnumerator, registry: WindowRegistry,
                scheduler: any DelayScheduler, intent: FocusIntent, sink: EventSink,
                heartbeat: (any Heartbeat)? = nil) {
        self.source = source
        self.enumerator = enumerator
        self.registry = registry
        self.scheduler = scheduler
        self.intent = intent
        self.sink = sink
        self.heartbeat = heartbeat
    }

    /// Enumerate the desktop, adopt it, and start watching. `completion` runs once the boot scan's
    /// windows have been dispatched.
    ///
    /// The one scan whose windows emira did not watch open, and it says so (`alreadyOpen`): the core
    /// keeps an adopted window's existing width instead of snapping it onto the first preset. A fact
    /// about *this scan*, not about a window — the enumerator runs identical code at boot and after.
    public func start(completion: @escaping @MainActor (AXEnumerator.Report) -> Void = { _ in }) {
        source.start { [weak self] observation in self?.handle(observation) }
        heartbeat?.start(every: Self.reconcileInterval) { [weak self] in self?.reconcile() }
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
        // Not merely latched: teardown places every managed window into the quit cascade, and a tick
        // landing mid-cascade would scan apps and re-adopt windows on their way off the strip.
        heartbeat?.stop()
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
            scanning[pid] = nil
            rescan[pid] = nil
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

        case .mouseDown:
            emit(.dragBegan)

        case .mouseUp:
            emit(.dragEnded)

        case .pointerMoved(let point):
            // Not an `Event`, and not this type's to filter either: a sample is not news, and 120 of
            // them a second through the pump would fill the replay log. Handed to the pointer plane's
            // two readers, which is all this file does with it.
            onPointerMoved?(point)

        case .appActivated:
            emit(.appActivated)
        }
    }

    // Retirement (the destroy that waits for one answer)

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
        // `alreadyOpen`, like the boot scan and reconciliation: what provoked this is a window *leaving*,
        // so anything else the scan finds is a window nothing announced — one emira met mid-life, and
        // the successor this is actually asking about is `succeeded` rather than an arrival at all.
        scan([target], attempt: 0, alreadyOpen: true)
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

    // Reconciliation (the standing question the notification stream cannot answer)

    /// Make the standing invariants true again: every app we know observed, every managed window still
    /// real, every on-screen window managed.
    ///
    /// The standing check behind an otherwise entirely edge-triggered design, where every discovery path
    /// is one notification at one moment and a missed one is never reissued. Level-triggered and cheap:
    /// the list is a window-server query, and AX is reached only when the two disagree.
    ///
    /// Each of the three is a state rather than a race, which is what separates them from the retry
    /// chain: a race resolves itself and is waited out under a budget, a state stays wrong until
    /// something asks again.
    private func reconcile() {
        guard !isStopped else { return }

        // The notification plane first, since every gap below is downstream of a gap in it. An app too
        // busy to answer when we asked is deaf to us from then on — no creation, no destroy, no move —
        // and nothing in the edge plane can fix that, because a budget must terminate and this must not.
        // `register` skips the apps already covered, so a healthy desktop pays one set lookup each.
        for (_, target) in apps.sorted(by: { $0.key < $1.key }) { register(target) }

        let list = enumerator.windowList()
        // An empty list is a failed read, not an empty desktop — `WindowListEntry.current()` answers `[]`
        // when `CGWindowListCopyWindowInfo` does — and believing it would retire the whole strip at once.
        guard !list.isEmpty else { return }
        let listed = Set(list.map(\.number))

        // Managed windows the window server no longer lists *at all*. Deliberately not `isOnScreen`,
        // which the discovery half below does consult: an ordinary desktop carries far more off-screen
        // layer-0 entries than on-screen ones — background tabs, other Spaces, the Dock — and every one
        // of them is a live window. Absence from the entire list is a different fact, and the strongest
        // evidence of death anything here holds: the window server owns the window rather than the app
        // does, so it is the one authority a beachballed app cannot keep quiet. Through `vanish`, so a
        // window that closed unheard still gets the succession its notification would have bought it.
        //
        // Nothing rests on this running first: `vanish` defers, and its scan is still out when the
        // strays below are gathered, so a removal lands a lane round trip later and races the arrivals
        // either way — bounded by `successionGrace`.
        for id in registry.ids {
            guard let record = registry.record(id), !listed.contains(record.number) else { continue }
            vanish(id)
        }

        // On-screen only, for the same reason `Report.unclaimed` is: an app's off-screen layer-0
        // oddments are not windows and never will be. A window on another Space or in the Dock is off
        // screen too — those are adopted by the notification that brings them back.
        let strays = list.filter { $0.isOnScreen && registry.id(forNumber: $0.number) == nil }
        // A number that bound, or whose window closed, forfeits its history.
        unaccounted = unaccounted.filter { number, _ in strays.contains { $0.number == number } }

        var targets: [pid_t: ScanTarget] = [:]
        var known: [pid_t: ScanTarget]?
        for stray in strays {
            let round = (unaccounted[stray.number] ?? 0) + 1
            unaccounted[stray.number] = round
            guard round <= Self.maxReconcileRounds, targets[stray.pid] == nil else { continue }
            if let target = apps[stray.pid] {
                targets[stray.pid] = target
                continue
            }
            // An app absent from `apps` is invisible to every notification we hold: it was running
            // before the daemon, so `appLaunched` never fires for it, and `windowAppeared` is gated on
            // already knowing it. The one question the retry chain deliberately never asks.
            if known == nil {
                known = Dictionary(enumerator.applications().map { ($0.pid, $0) }) { first, _ in first }
            }
            if let target = known?[stray.pid] { targets[stray.pid] = target }
        }

        guard !targets.isEmpty else { return }
        // `alreadyOpen`, like the boot scan: a window reconciliation finds is by definition one emira
        // did not watch open, so the core keeps its existing width rather than snapping it to a preset.
        scan(Array(targets.values), attempt: 0, alreadyOpen: true)
    }

    /// Scan a set of apps and absorb the result, carrying the attempt number so the report knows whether
    /// it may ask again.
    ///
    /// At most one scan per app is ever in flight, the same rule `readFrame` keeps: four rapid ⌘N presses
    /// would otherwise pile four full re-scans onto one serial lane under a 250 ms per-call timeout, and
    /// each would answer later than the window list it is joined against — the skew that costs a window
    /// its identity.
    private func scan(_ targets: [ScanTarget], attempt: Int, alreadyOpen: Bool = false) {
        let admitted = targets.filter { target in
            guard let inFlight = scanning[target.pid] else { return true }
            // The scan in flight is one of the requests that answer stands for, so its question merges
            // too: what the replay is left to announce is whatever that scan missed.
            rescan[target.pid] = (rescan[target.pid] ?? false) || alreadyOpen || inFlight
            return false
        }
        guard !admitted.isEmpty else { return }
        for target in admitted { scanning[target.pid] = alreadyOpen }
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
            scanning[target.pid] = nil
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

        // Something was asked for while the scan was out: ask again now rather than through the retry
        // budget, since this is a request we coalesced, not a race we are waiting out. Split by the
        // question that was asked, so the replay is the request rather than a default.
        var born: [ScanTarget] = []
        var met: [ScanTarget] = []
        for target in report.apps {
            guard let wasAlreadyOpen = rescan.removeValue(forKey: target.pid) else { continue }
            if wasAlreadyOpen { met.append(target) } else { born.append(target) }
        }
        if !born.isEmpty { scan(born, attempt: 0) }
        if !met.isEmpty { scan(met, attempt: 0, alreadyOpen: true) }

        // A window one side of the join described and the other didn't is the "asked too early" race.
        // Retry the apps that failed: not `source.applications()`, which may answer differently and turn
        // a one-app retry into a full re-scan, and not the whole scanned set, which at boot is every app
        // on the machine re-confirming what already bound.
        guard report.isIncomplete else { return }
        // Reported on the last attempt only — the earlier ones are the race being waited out, and saying
        // so every 150 ms would make the ordinary case look like a fault.
        if attempt + 1 >= Self.maxScanAttempts { onIncompleteScan?(report) }

        guard attempt + 1 < Self.maxScanAttempts else { return }
        let targets = report.incompleteApps
        scheduler.schedule(after: Self.rescanDelay) { [weak self] in
            self?.scan(targets, attempt: attempt + 1, alreadyOpen: alreadyOpen)
        }
    }

    /// Note an app and register its observer, retrying a failure inside the same budget as a failed bind
    /// — an app that is merely *starting* is the same "asked too early" race, and answering it in
    /// milliseconds rather than at the next tick is what keeps a launch from tiling late.
    ///
    /// The budget bounds the hurry, not the repair: an app still refusing when it runs out is left to
    /// `reconcile`, which asks again every interval for as long as the app lives.
    private func ensureWatching(_ target: ScanTarget, attempt: Int, alreadyOpen: Bool = false) {
        apps[target.pid] = target
        register(target) { [weak self] in
            guard let self, attempt + 1 < Self.maxScanAttempts, apps[target.pid] != nil else { return }
            scheduler.schedule(after: Self.rescanDelay) { [weak self] in
                self?.scan([target], attempt: attempt + 1, alreadyOpen: alreadyOpen)
            }
        }
    }

    /// Ask for an app's observer unless one is already registered or in flight, and say so when the app
    /// refuses. Whether a refusal is worth hurrying is the caller's: `ensureWatching` spends a retry on
    /// it, `reconcile` simply asks again next interval.
    private func register(_ target: ScanTarget, onFailure: @MainActor @escaping () -> Void = {}) {
        guard !observing.contains(target.pid) else { return }
        // Optimistic, cleared below on failure: registration crosses onto the app's lane, so without this
        // a second scan arriving mid-flight would register the same app twice.
        observing.insert(target.pid)
        source.watch(app: target) { [weak self] ok in
            guard let self, !ok else { return }
            observing.remove(target.pid)
            onFailure()
        }
    }

    // Focus (the report that isn't self-describing)

    /// Pass a focus report to the core — unless it is our own stale echo, or macOS backfilling the
    /// window that just died.
    ///
    /// `Event.focusChanged` means "focus moved, so scroll the viewport to reveal it", and carries whether
    /// *we* moved it — the fact `[focus] system-events` judges, and one only this file holds. Two other
    /// things post the identical notification, and each is filtered by the same record that answers that.
    ///
    /// **Our own focus, arriving late.** `Effect.focus` provokes the same report, and the design counts
    /// on absorbing that echo because a reveal of an already-revealed window is a no-op. It is only a
    /// no-op while the echo is *current*: the round trip crosses per-app lanes with no order between
    /// them (`FocusIntent`), so spamming `focus` across a slow app and a fast one delivers an echo
    /// naming a window two presses back, and the core — mid-scroll — retargets the live transition
    /// backwards to reveal it. Swallowed outright rather than passed on, because it says nothing the
    /// core does not already hold: the reducer wrote that focus optimistically when it emitted the
    /// effect, so the echo can only ever confirm it or corrupt it.
    ///
    /// **macOS filling a hole.** An app whose key window closes picks an arbitrary replacement, so
    /// closing the tenth Ghostty window can land focus on the first and snap the strip across the
    /// desktop. AppKit picks that replacement *synchronously* and destroys the closing element later, so
    /// `AXFocusedWindowChanged` normally arrives *before* `AXUIElementDestroyed` and the two cases are
    /// indistinguishable without asking whether the displaced window still exists — live means the user
    /// moved focus, dead means macOS filled a hole. The registry answers free when the destroy got here
    /// first; only the awkward order costs a round trip, and the re-check on the answer covers a destroy
    /// that arrived while we asked. Failing toward "dead" only drops a reveal (the next focus change
    /// reveals); the opposite mistake would drop a real window off the strip, which is why this never
    /// synthesizes a `windowVanished`.
    private func resolveFocus(_ id: WindowId?) {
        switch intent.resolve(id) {
        // News about the past. `focus` is deliberately not advanced: it names the window a *new* report
        // displaces, and a window we stopped considering focused two presses ago is not that.
        case .stale:
            return

        // Exactly what we asked for, so it cannot also be macOS covering for a window that died — we
        // named the replacement ourselves. Nothing to ask, and one lane round trip not spent.
        case .expected:
            focus = id
            emit(.focusChanged(id, origin: .ours))
            return

        case .external:
            break
        }

        let displaced = focus
        focus = id
        // Nothing displaced (boot), or a report that changes nothing: there is no question to ask.
        guard let displaced, displaced != id else {
            emit(.focusChanged(id, origin: .system))
            return
        }
        guard isLive(displaced) else { return }   // already known dead — free answer
        source.isAlive(displaced) { [weak self] alive in
            guard let self, alive, isLive(displaced) else { return }
            emit(.focusChanged(id, origin: .system))
        }
    }

    // Frame reads (the coalescer)

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
