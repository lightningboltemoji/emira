import ApplicationServices
import Dispatch
import EmiraCore
import Foundation

// **Where AX work happens, and where it does not.** `AXAccess` supplies the vocabulary; this file
// supplies the single rule that keeps a window manager from feeling like the thing that broke your
// Mac (PRINCIPLES.md §5, "never block our own run loop"):
//
//   Every AX call runs on a **serial queue belonging to the target app**, under a **short messaging
//   timeout**, and its result is delivered back on the **main actor**.
//
// Three properties, each load-bearing for a different failure:
//
//  · **Off the main thread** — AX getters and setters are synchronous Mach IPC serviced by the target
//    app's *own* main run loop. Calling one from ours means a busy Chrome decides how long emira's
//    display link is stalled. The compositor's whole claim (§4b: the cover masks slow AX) is only true
//    if slow AX cannot reach the compositor's thread.
//  · **Serial, per app** — one queue per pid, not one shared queue and not one queue per call. Shared,
//    and a single hung app stalls placement for every other app. Per call, and two sets racing into the
//    same window can land out of order, which is exactly the "size → position → size" clamping dance
//    (§5) coming apart. Per app is the granularity the OS itself imposes, so it is the granularity we
//    model.
//  · **Bounded** — `AXUIElementSetMessagingTimeout` on the application element. This protects *us*, not
//    the app: it converts "wait forever" into `.cannotComplete`, which `AXAccess` collapses to `nil` and
//    the reducer sees as `Event.axFailed`. A hung app becomes a normal state transition (§1 invariant 3)
//    instead of a wedged queue.
//
// **What this deliberately is not.** It is not `async`/`await`. The pump is a synchronous, non-
// re-entrant loop (§1 invariant 4) and `Executor.execute` returns `Void` immediately by contract
// (`Executor.swift`); a suspension point in the middle of effect execution is precisely the re-entrancy
// the invariant exists to forbid. Work goes out, the answer comes back later as an `Event`. That is the
// same shape as the display link and the socket server, and it is the shape the whole shell has.

/// Runs AX work on per-app serial queues and marshals the results back to the main actor.
///
/// One instance per daemon, shared by the enumerator, the writer and (M3 part 2b) the observers — the
/// lanes are only serial if everybody uses the same ones.
///
/// `@MainActor` for its *API*, which is where the lane table is read and written; the `work` closure it
/// takes runs off the main actor by construction. That split is the entire type: main-actor bookkeeping,
/// off-main IPC, main-actor delivery.
@MainActor
public final class AXClient {

    /// How long any single AX call may block before returning `.cannotComplete`.
    ///
    /// 250 ms is chosen against the measured distribution rather than a guess: the strip spike saw a
    /// **14 ms** worst-case landing across several apps including a slow Chrome (PRINCIPLES.md §10,
    /// checkpoint 3a), so this is roughly 20× the observed tail — long enough that no healthy app is
    /// ever cut off, short enough that a genuinely hung one is written off well inside the ~1 s
    /// transition hold-timeout (§3) that would otherwise be the only thing to notice.
    public static let defaultTimeout: Float = 0.25

    /// One app's lane: its AX application element and the serial queue every call through it runs on.
    private struct Lane {
        let application: AXApplication
        let queue: DispatchQueue
    }

    /// The per-app messaging timeout, applied once per lane at creation.
    private let timeout: Float

    /// The lanes, keyed by pid. Created lazily on first contact with an app and dropped when it quits.
    private var lanes: [pid_t: Lane] = [:]

    public init(timeout: Float = AXClient.defaultTimeout) {
        self.timeout = timeout
    }

    /// Run `work` against an app's AX element on that app's serial queue, then deliver its result on
    /// the main actor.
    ///
    /// Returns immediately. `work` must be self-contained AX reading/writing — it runs off the main
    /// actor and must touch nothing that lives there; `completion` is where anything stateful happens.
    ///
    /// The two closures are the boundary `EventSink` describes in prose (`Executor.swift`): cross a
    /// thread to do the slow thing, come back to the main actor to say what happened.
    public func perform<T: Sendable>(
        app pid: pid_t,
        _ work: @escaping @Sendable (AXApplication) -> T,
        then completion: @escaping @MainActor @Sendable (T) -> Void
    ) {
        let lane = lane(for: pid)
        lane.queue.async {
            let result = work(lane.application)
            Task { @MainActor in completion(result) }
        }
    }

    /// The AX application element for a pid, creating its lane if this is the first contact.
    ///
    /// Exposed because the write path and the observers need the *element* without necessarily
    /// dispatching through `perform` (registering an `AXObserver` is a main-thread run-loop operation,
    /// not IPC). Going through here rather than calling `AXApplication(pid:)` directly is what
    /// guarantees the messaging timeout is set exactly once and never forgotten.
    public func application(for pid: pid_t) -> AXApplication {
        lane(for: pid).application
    }

    /// Forget an app's lane — call when the process exits.
    ///
    /// A `DispatchQueue` with no work and no references is free, but the *element* holds a Mach port to
    /// a dead process, and a lane table that only grows would slowly accumulate one per app the user
    /// ever launched.
    public func forget(app pid: pid_t) {
        lanes[pid] = nil
    }

    /// How many apps currently have a lane. The observable half of the "one queue per app, created
    /// once" rule, and how the tests check it.
    public var laneCount: Int { lanes.count }

    /// Get or create an app's lane. The messaging timeout is set here, on the application element, at
    /// creation — every window element obtained *through* that application inherits it, so this is the
    /// one place it has to be right.
    private func lane(for pid: pid_t) -> Lane {
        if let existing = lanes[pid] { return existing }
        let application = AXApplication(pid: pid)
        application.setMessagingTimeout(timeout)
        let lane = Lane(
            application: application,
            queue: DispatchQueue(label: "xyz.emira.ax.\(pid)", qos: .userInitiated))
        lanes[pid] = lane
        return lane
    }
}
