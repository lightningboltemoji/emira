import AppKit
import EmiraCore
import Foundation

// **Enumeration** — how the truth plane gets its contents (IMPLEMENTATION.md §9, M3: "instant, correct
// tiling of *real* windows"). emira keeps no layout across restarts by charter (§10), so this runs at
// boot, meets every window mid-life, and hands the core a `windowCreated` per window exactly as if it
// had watched each one appear. Launch is just events (`Runtime`), and this is the event source that
// makes the world real.
//
// **It is also how every *later* window is met (M3 part 2b).** An `AXWindowCreated` notification names
// the app, not a bindable window — identity is a join against the public window list (`WindowRegistry`),
// and the join is only sound when a window is compared against its *siblings*. So the response to
// "something appeared in this app" is to enumerate that one app again, which is why `enumerate` takes an
// app set. Two consequences shape the type:
//
//  · **A scan reports what *changed*, not what it saw.** `Report.snapshots` is the windows this scan
//    took into management for the **first** time; ones we already knew are `rebound` (their AX element
//    refreshed, their id untouched). The caller dispatches `windowCreated` for `snapshots` — and a
//    re-scan of a five-window app must not announce five births, because `Engine` gives a new window
//    focus, so a re-announcement would yank the user's focus onto whatever sorted last.
//  · **Re-scanning stays idempotent**, which it already was at the registry level (`adopt` is keyed on
//    the window number); this just makes the *report* honest about it too.
//
// **The shape is the same trick as `FrameClock` and `CoverSurface`.** Everything that needs a live
// macOS — `NSWorkspace`'s process list, AX round trips, the window list — sits behind `WindowSource`,
// three methods wide. `AXEnumerator` above it is pure orchestration: fan out over apps, gather, join,
// adopt, report. So the parts with decisions in them (which apps are worth scanning, what happens when
// an app answers with nothing, what happens when *no* app answers, what a window that can't be
// identified does to the rest of the scan) are all headlessly testable, and the untestable part is
// three methods of straight-line framework calls holding no policy at all.
//
// **Why the join happens after every app has answered, not per app.** Both sides of the identity join
// are snapshots of a moving system, and the window list is the cheaper one to take late: a window that
// moved between the AX read and the list read simply fails to bind and is reported, which is the
// correct outcome and a visible one. Taking the list once, after the fan-out, also means one syscall
// instead of one per app, and means every window is matched against the *same* view of the world —
// so `.contested` (two AX windows claiming one entry) is a real signal rather than an artifact of
// comparing two apps against two different lists.

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
    /// The framework-free description — what gets matched, classified and handed to the core.
    public let observed: ObservedWindow
    /// The live handle. Not `public`: outside this module a window is a `WindowId` and nothing else.
    let element: AXWindow

    init(observed: ObservedWindow, element: AXWindow) {
        self.observed = observed
        self.element = element
    }
}

/// Everything `AXEnumerator` needs from a live macOS, and nothing more.
///
/// Three methods, all of which a test double answers from arrays. `windows(of:then:)` is asynchronous
/// because the real one crosses a thread and must not block the pump; the other two are cheap local
/// reads that would gain nothing from being.
@MainActor
public protocol WindowSource {
    /// The apps worth asking about windows, right now.
    func applications() -> [ScanTarget]
    /// One app's windows, delivered on the main actor. Must call `completion` exactly once — including
    /// when the app answers with nothing, which is the common case for an app that has no AX support
    /// or has just quit.
    func windows(of target: ScanTarget, then completion: @escaping @MainActor ([ScannedWindow]) -> Void)
    /// The public window list, for identity binding.
    func windowList() -> [WindowListEntry]
}

// MARK: - The enumerator

/// Scans every running app, binds each window to its public window number, takes the bound ones into
/// the registry, and reports what happened.
@MainActor
public final class AXEnumerator {

    /// The outcome of one enumeration — the snapshots to dispatch, plus enough detail to explain the
    /// gap between "windows on the screen" and "windows emira manages". The daemon logs this at boot,
    /// because a window manager quietly not managing something is the failure the user cannot debug.
    public struct Report: Sendable {
        /// The windows taken into management for the **first time**, in binding order — dispatch these
        /// as `windowCreated`, and only these (see the file header).
        public let snapshots: [WindowSnapshot]
        /// The windows this scan re-met: already managed, id unchanged, AX element refreshed. Reported
        /// rather than dropped so `boundWindows` can be honest and a caller can see the difference
        /// between "nothing appeared" and "nothing answered".
        public let rebound: [WindowId]
        /// The apps this scan covered. Carried so the caller can watch exactly what was scanned, and
        /// re-scan exactly what failed, without asking the source a second question it may answer
        /// differently.
        public let apps: [ScanTarget]
        /// How many windows AX reported in total, bound or not.
        public let seenWindows: Int
        /// The windows that could not be given a stable identity, and why.
        public let unbound: [Unbound]

        /// How many apps were scanned.
        public var scannedApps: Int { apps.count }
        /// How many windows came away with an identity, new or already held.
        public var boundWindows: Int { snapshots.count + rebound.count }

        /// A window AX described but that we declined to manage.
        public struct Unbound: Sendable, Equatable {
            public let bundleId: String
            public let title: String
            public let frame: Rect
            public let reason: WindowIdentity.Rejection.Reason
        }

        /// One line for the boot log.
        public var summary: String {
            let base = "\(boundWindows)/\(seenWindows) windows bound across \(scannedApps) apps"
            guard !unbound.isEmpty else { return base }
            let detail = unbound
                .map { "\($0.bundleId) “\($0.title)” (\($0.reason.rawValue))" }
                .joined(separator: ", ")
            return base + "; unbound: " + detail
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
    /// The fan-out is deliberately **not** sequential. Apps are independent processes with independent
    /// main run loops, so scanning them one after another would make the boot cost the *sum* of the
    /// apps' latencies (and hostage to the slowest); scanning them at once — each on its own lane
    /// (`AXClient`) — makes it the *maximum*, bounded by the messaging timeout.
    ///
    /// A one-app set is the steady-state form (an `AXWindowCreated` notification, an app launching);
    /// the whole list is the boot form. Same code, because the join must see an app's windows together
    /// either way.
    public func enumerate(apps targets: [ScanTarget],
                          completion: @escaping @MainActor (Report) -> Void) {
        guard !targets.isEmpty else {
            // No apps is a legitimate answer (a freshly booted machine, or — far more likely — the
            // Accessibility grant is missing and nothing will ever answer). Complete anyway: a
            // callback that never fires would leave the daemon waiting forever on an empty desktop.
            completion(Report(snapshots: [], rebound: [], apps: [], seenWindows: 0, unbound: []))
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

    /// Join, adopt, and describe. Split out so the interesting half is one straight-line function over
    /// values.
    private func finish(_ scanned: [ScannedWindow], apps: [ScanTarget]) -> Report {
        let binding = WindowIdentity.bind(scanned.map(\.observed), to: source.windowList())
        var snapshots: [WindowSnapshot] = []
        var rebound: [WindowId] = []
        for match in binding.matches {
            // Asked *before* adopting, because adopting is what makes it known. This one line is the
            // difference between a re-scan being a silent refresh and a re-scan announcing five births.
            let known = registry.id(forNumber: match.number) != nil
            let snapshot = registry.adopt(scanned[match.observed].observed,
                                          element: scanned[match.observed].element,
                                          number: match.number)
            if known { rebound.append(snapshot.id) } else { snapshots.append(snapshot) }
        }
        let unbound = binding.rejections.map { rejection in
            let observed = scanned[rejection.observed].observed
            return Report.Unbound(bundleId: observed.bundleId, title: observed.title,
                                  frame: observed.frame, reason: rejection.reason)
        }
        return Report(snapshots: snapshots, rebound: rebound, apps: apps,
                      seenWindows: scanned.count, unbound: unbound)
    }

    /// The fan-out's accumulator. A reference type because several escaping completions append to it;
    /// `@MainActor` because they all arrive there, which is what makes the un-synchronized mutation
    /// safe rather than merely lucky — Swift 6 proves it.
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
/// windows, `CGWindowListCopyWindowInfo` for the numbers. No decisions beyond the app filter, which is
/// documented where it happens.
@MainActor
public final class AXWindowSource: WindowSource {

    private let client: AXClient

    public init(client: AXClient) {
        self.client = client
    }

    /// The ordinary, user-facing apps — `.regular` activation policy, still alive, not us.
    ///
    /// `.regular` only, on purpose: `.accessory` and `.prohibited` processes are menu-bar agents and
    /// background helpers, and touching their AX tree costs the footprint §5 warns about for windows
    /// the user does not tile. It is a default, not a law — an accessory app *can* open a real window,
    /// and when that turns out to matter it becomes a config rule rather than a change here.
    ///
    /// Apps with no bundle identifier are skipped: the core groups windows by `bundleId` and rules
    /// match on it (`World.swift`), so a window we cannot attribute to an app is one we cannot reason
    /// about.
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

    /// Read one app's windows on its own lane. Window-level only — `AXApplication.windows()` is the
    /// only traversal that exists (§5, no child walk).
    ///
    /// A window whose frame is unreadable is dropped here rather than reported unbound: without a frame
    /// there is nothing to join *on*, and nothing to place it with either.
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
