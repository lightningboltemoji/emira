import AppKit
import EmiraCore
import Foundation

// Enumeration — how the truth plane gets its contents: at boot, and per-app in steady state, since an
// `AXWindowCreated` notification names the app rather than a bindable window.
//
// A scan reports what *changed*: `snapshots` is what was taken into management for the first time,
// `rebound` what we already knew. Re-announcing a known window would yank focus, since `Engine` focuses
// new windows. The join runs once, after every app has answered, so every window is matched against one
// window-list read and `.contested` is a real signal rather than an artifact of two different lists.

// MARK: - The boundary

/// One app worth scanning.
public struct ScanTarget: Sendable, Equatable {
    /// The process to address over AX.
    public let pid: pid_t
    /// Its bundle identifier — the core's app-grouping key, resolved here so the AX layer never has to.
    public let bundleId: String

    public init(pid: pid_t, bundleId: String) {
        self.pid = pid
        self.bundleId = bundleId
    }
}

/// A window as one scan found it: the pure observation the join works on, plus the AX element the
/// registry keeps for the write path.
public struct ScannedWindow: Sendable {
    public let observed: ObservedWindow
    /// Not `public`: outside this module a window is a `WindowId` and nothing else.
    let element: AXWindow

    init(observed: ObservedWindow, element: AXWindow) {
        self.observed = observed
        self.element = element
    }
}

/// Everything `AXEnumerator` needs from a live macOS. `windows(of:then:)` is asynchronous because the
/// real one crosses a thread and must not block the pump; the other two are cheap local reads.
@MainActor
public protocol WindowSource {
    /// The apps worth asking about windows, right now.
    func applications() -> [ScanTarget]
    /// One app's windows, delivered on the main actor. Must call `completion` exactly once — including
    /// when the app answers with nothing, the common case for an app with no AX support or one that
    /// has just quit.
    func windows(of target: ScanTarget, then completion: @escaping @MainActor ([ScannedWindow]) -> Void)
    /// The public window list, for identity binding.
    func windowList() -> [WindowListEntry]
}

// MARK: - The enumerator

/// Scans every running app, binds each window to its public window number, takes the bound ones into
/// the registry, and reports what happened.
@MainActor
public final class AXEnumerator {

    /// The outcome of one enumeration — the snapshots to dispatch, plus enough detail to explain the gap
    /// between "windows on the screen" and "windows emira manages".
    public struct Report: Sendable {
        /// Taken into management for the *first time*, in binding order — dispatch these as
        /// `windowCreated`, and only these.
        public let snapshots: [WindowSnapshot]
        /// Re-met: already managed, id unchanged, AX element refreshed.
        public let rebound: [WindowId]
        /// Managed windows whose id was moved onto a *different* window because AX stopped listing the
        /// one it held and something took its place — a native tab group selecting another tab. Already
        /// rebound in the registry by the time the caller sees this; what the caller owes them is a
        /// fresh window-level observer, since the element behind the id has changed.
        public let succeeded: [WindowId]
        /// Managed windows AX stopped listing with nothing standing in for them: merged into another
        /// window's tab group, or closed without a destroy notification reaching us. They are gone from
        /// the strip, and the caller forgets them.
        public let departed: [WindowId]
        /// Managed windows AX stopped listing that the window server still shows on screen. Not
        /// departures — a live window whose attributes this scan failed to read — so they stay on the
        /// strip and the scan asks again.
        public let undescribed: [WindowId]
        /// The apps this scan covered. Carried so the caller can re-scan exactly what failed without
        /// asking the source a second question it may answer differently.
        public let apps: [ScanTarget]
        /// How many windows AX reported in total, bound or not.
        public let seenWindows: Int
        /// The windows that could not be given a stable identity, and why.
        public let unbound: [Unbound]
        /// Windows of the scanned apps the window server lists but AX did not describe — one that
        /// appeared between the two reads, or one with unreadable AX attributes. A reason to ask again.
        public let unclaimed: Int

        public var scannedApps: Int { apps.count }
        public var boundWindows: Int { snapshots.count + rebound.count }
        /// Whether this scan saw something it could not account for, on either side of the join — or
        /// about a window it already manages.
        public var isIncomplete: Bool { mayHaveMissedAnArrival || !undescribed.isEmpty }
        /// Whether this scan could have missed a window *arriving*: one it described but could not bind,
        /// or one the window server listed that it never described. Narrower than `isIncomplete`, which
        /// also counts windows already managed — and those, whatever else is wrong with them, are not
        /// candidates to stand in for anybody.
        public var mayHaveMissedAnArrival: Bool { !unbound.isEmpty || unclaimed > 0 }

        /// A window AX described but that we declined to manage.
        public struct Unbound: Sendable, Equatable {
            public let bundleId: String
            public let title: String
            public let frame: Rect
            public let reason: WindowIdentity.Rejection.Reason
        }

        /// One line for the log.
        public var summary: String {
            var line = "\(boundWindows)/\(seenWindows) windows bound across \(scannedApps) apps"
            if !succeeded.isEmpty { line += "; \(succeeded.count) tab succession(s)" }
            if !departed.isEmpty { line += "; \(departed.count) no longer listed" }
            if !undescribed.isEmpty {
                line += "; \(undescribed.count) managed but undescribed (still on screen)"
            }
            if !unbound.isEmpty {
                line += "; unbound: " + unbound
                    .map { "\($0.bundleId) “\($0.title)” (\($0.reason.rawValue))" }
                    .joined(separator: ", ")
            }
            if unclaimed > 0 { line += "; \(unclaimed) listed but not described by AX" }
            return line
        }
    }

    private let source: any WindowSource
    private let registry: WindowRegistry

    public init(source: any WindowSource, registry: WindowRegistry) {
        self.source = source
        self.registry = registry
    }

    /// Scan every app the source knows about and report.
    public func enumerate(completion: @escaping @MainActor (Report) -> Void) {
        enumerate(apps: source.applications(), completion: completion)
    }

    /// Scan exactly these apps and report. Returns immediately; `completion` runs on the main actor
    /// once every app has answered.
    ///
    /// The fan-out is deliberately not sequential: apps are independent processes with independent main
    /// run loops, so scanning at once costs the *maximum* of their latencies rather than the sum.
    public func enumerate(apps targets: [ScanTarget],
                          completion: @escaping @MainActor (Report) -> Void) {
        guard !targets.isEmpty else {
            // No apps is a legitimate answer (usually a missing Accessibility grant), but a callback
            // that never fires would leave the daemon waiting forever.
            completion(Report(snapshots: [], rebound: [], succeeded: [], departed: [], undescribed: [],
                              apps: [], seenWindows: 0, unbound: [], unclaimed: 0))
            return
        }

        let gather = Gather(pending: targets.count)
        for target in targets {
            source.windows(of: target) { [self] windows in
                gather.windows += windows
                gather.pending -= 1
                guard gather.pending == 0 else { return }
                completion(finish(gather.windows, apps: targets))
            }
        }
    }

    /// Join, adopt, and describe.
    ///
    /// A window we already know is never re-joined: the two sides of the join are read at different
    /// instants and *we* are what moves windows in between, so under a burst of window creation a stale
    /// read can report window A at the frame B has since taken and match B's entry uniquely.
    private func finish(_ scanned: [ScannedWindow], apps: [ScanTarget]) -> Report {
        let entries = source.windowList()

        var rebound: [WindowId] = []
        var fresh: [ScannedWindow] = []
        for window in scanned {
            if let id = registry.id(for: window.element) {
                // Refresh element and metadata against the id it already has; the number is on file,
                // so the join is not consulted.
                if let record = registry.record(id) {
                    registry.adopt(window.observed, element: window.element, number: record.number)
                }
                rebound.append(id)
            } else {
                fresh.append(window)
            }
        }

        // An entry already bound to a live window is not a candidate for anything: its identity is
        // settled. Withholding it stops a stale frame from claiming a *known* window's entry.
        let available = entries.filter { registry.id(forNumber: $0.number) == nil }
        let binding = WindowIdentity.bind(fresh.map(\.observed), to: available)

        // The second join: managed windows of these apps that AX did not describe this time. Almost
        // always a native tab going to the background, which posts nothing at all — hence a set
        // difference rather than a notification.
        //
        // Two ways an app's answer is not a picture to judge absence from, and both cost a column if
        // believed. It described *nothing* — the shape of a timeout, a missing grant and a process on
        // its way out alike, where trusting it would take the app's whole strip down at once. Or the two
        // sides of the join disagree about it, which is the same race `unclaimed` reports and is exactly
        // what a successor looks like a moment before we can see it. Either way the app is skipped here
        // and `isIncomplete` asks again. A tab group always leaves its selected tab behind, so the case
        // this exists for never rides on a scan that came back short.
        let matched = Set(binding.matches.map(\.number))
        var unreliable = Set(binding.rejections.map { fresh[$0.observed].observed.pid })
        for entry in available where entry.isOnScreen && !matched.contains(entry.number) {
            unreliable.insert(entry.pid)
        }
        let answered = Set(scanned.map(\.observed.pid))
            .intersection(apps.map(\.pid))
            .subtracting(unreliable)
        let listed = Set(rebound)
        let departures = registry.records(ofApps: answered)
            .filter { !listed.contains($0.id) }
            .map { WindowIdentity.Departure(id: $0.id, pid: $0.pid, frame: $0.frame) }
        let arrivals = binding.matches.map { fresh[$0.observed].observed }
        let (successions, orphaned) = WindowIdentity.succeed(departed: departures, arrived: arrivals)

        // Applied before anything is adopted: a succeeded arrival must not also mint an id of its own.
        var succeeded: [WindowId] = []
        var leaving = orphaned
        var inherited: Set<Int> = []
        for succession in successions {
            let match = binding.matches[succession.arrived]
            let window = fresh[match.observed]
            guard registry.rebind(succession.departed, to: match.number,
                                  observed: window.observed, element: window.element) else {
                // The new number already belongs to someone: the arrival keeps its own identity below
                // and the departure leaves, which is the same answer as having found no successor.
                leaving.append(succession.departed)
                continue
            }
            inherited.insert(succession.arrived)
            succeeded.append(succession.departed)
        }

        // Corroboration, and only where it is needed. A succession is *evidenced* — a window is standing
        // on the departed one's rectangle — but a departure with no successor rests on the app's silence
        // alone, and that is the one answer here nobody can take back: no second `AXWindowCreated` is
        // coming for a window that never closed, so a wrongly retired id is a live window off the strip
        // for good. AX's silence has a second reading. `snapshot` is seven round trips under a messaging
        // timeout, and a busy app that fails one of them drops a window out of its own answer — which
        // looks exactly like a backgrounded tab from here.
        //
        // The window server tells the two apart for free, since the list is already read: a background
        // tab is ordered out and a closed window is not listed at all, so an entry that is *still on
        // screen* is a live window AX declined to describe. Believe a departure only when the window
        // server agrees there is nothing there to see. (It cannot separate a backgrounded tab from a
        // minimized window — both are simply off screen — but AX keeps listing minimized windows, so
        // they never reach this point.)
        let visible = Set(entries.lazy.filter(\.isOnScreen).map(\.number))
        var departed: [WindowId] = []
        var undescribed: [WindowId] = []
        for id in leaving.sorted() {
            guard let number = registry.record(id)?.number else { continue }
            if visible.contains(number) { undescribed.append(id) } else { departed.append(id) }
        }

        var snapshots: [WindowSnapshot] = []
        var claimed: Set<CGWindowID> = []
        for (index, match) in binding.matches.enumerated() {
            // An inherited arrival is bound — to an id that already exists, so it is not news.
            guard !inherited.contains(index) else {
                claimed.insert(match.number)
                continue
            }
            guard let snapshot = registry.adopt(fresh[match.observed].observed,
                                                element: fresh[match.observed].element,
                                                number: match.number) else { continue }
            claimed.insert(match.number)
            snapshots.append(snapshot)
        }
        let unbound = binding.rejections.map { rejection in
            let observed = fresh[rejection.observed].observed
            return Report.Unbound(bundleId: observed.bundleId, title: observed.title,
                                  frame: observed.frame, reason: rejection.reason)
        }

        // The mirror image of `unbound`, feeding the same bounded retry. Only on-screen entries count:
        // ordinary apps carry layer-0 entries that are not windows and never will be (Ghostty, Safari and
        // Finder each answer with four off-screen `1800×39` strips at the origin, plus 64×64 and 0×0
        // oddments), and counting those would make every scan of those apps incomplete forever. A window
        // on another Space or in the Dock is off screen too, and is adopted by the notification that
        // brings it back.
        let scannedPids = Set(apps.map(\.pid))
        let unclaimed = available.filter {
            $0.isOnScreen && scannedPids.contains($0.pid) && !claimed.contains($0.number)
        }

        return Report(snapshots: snapshots, rebound: rebound, succeeded: succeeded.sorted(),
                      departed: departed, undescribed: undescribed, apps: apps,
                      seenWindows: scanned.count, unbound: unbound, unclaimed: unclaimed.count)
    }

    /// The fan-out's accumulator. A reference type because several escaping completions append to it;
    /// `@MainActor` because they all arrive there, which is what makes the mutation safe.
    @MainActor
    private final class Gather {
        var windows: [ScannedWindow] = []
        var pending: Int

        init(pending: Int) {
            self.pending = pending
        }
    }
}

// MARK: - The live source

/// `WindowSource` against the real system: `NSWorkspace` for the process list, `AXClient` for the
/// windows, `CGWindowListCopyWindowInfo` for the numbers.
@MainActor
public final class AXWindowSource: WindowSource {

    private let client: AXClient

    public init(client: AXClient) {
        self.client = client
    }

    /// The ordinary, user-facing apps — `.regular` activation policy, still alive, not us. `.accessory`
    /// and `.prohibited` processes are menu-bar agents and background helpers whose AX trees cost
    /// footprint for nothing tileable. Apps with no bundle identifier are skipped: the core groups by it.
    public func applications() -> [ScanTarget] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier != me, app.processIdentifier > 0,
                  let bundleId = app.bundleIdentifier
            else { return nil }
            return ScanTarget(pid: app.processIdentifier, bundleId: bundleId)
        }
    }

    /// Read one app's windows on its own lane. A window whose frame is unreadable is dropped here
    /// rather than reported unbound: without a frame there is nothing to join *on*.
    public func windows(of target: ScanTarget,
                        then completion: @escaping @MainActor ([ScannedWindow]) -> Void) {
        client.perform(app: target.pid) { application in
            application.windows().compactMap { window in
                window.snapshot(bundleId: target.bundleId)
                    .map { ScannedWindow(observed: $0, element: window) }
            }
        } then: { windows in
            completion(windows)
        }
    }

    public func windowList() -> [WindowListEntry] {
        WindowListEntry.current()
    }
}
