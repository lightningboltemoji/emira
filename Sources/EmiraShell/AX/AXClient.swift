import ApplicationServices
import Dispatch
import EmiraCore
import Foundation

// The single rule that keeps AX from wedging the daemon: every AX call runs on a serial queue belonging
// to the target app, under a short messaging timeout, with its result delivered back on the main actor.
//
//  · Off the main thread — AX getters and setters are synchronous Mach IPC serviced by the target app's
//    *own* main run loop, so calling one from ours lets a busy Chrome stall our display link.
//  · Serial per app — shared lanes let one hung app stall placement everywhere; per-call lanes let two
//    sets race into one window out of order, breaking the size → position → size clamping dance.
//  · Bounded — `AXUIElementSetMessagingTimeout` turns "wait forever" into `.cannotComplete`, which
//    `AXAccess` collapses to `nil` and the reducer sees as `Event.axFailed`.
//
// Not `async`/`await`: `Executor.execute` returns immediately by contract, so a suspension point inside
// effect execution would be exactly the re-entrancy the pump forbids.

/// Runs AX work on per-app serial queues and marshals the results back to the main actor.
///
/// One instance per daemon, shared by the enumerator, the writer and the observers — the lanes are only
/// serial if everybody uses the same ones. `@MainActor` for its API, where the lane table lives; the
/// `work` closure runs off the main actor by construction.
@MainActor
public final class AXClient {

    /// How long any single AX call may block before returning `.cannotComplete`. 250 ms is ~20× the
    /// measured worst-case landing (14 ms, slow Chrome included) and well inside the ~1 s transition
    /// hold-timeout that would otherwise be the only thing to notice a hung app.
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

    /// Run `work` against an app's AX element on that app's serial queue, then deliver its result on the
    /// main actor. Returns immediately. `work` runs off the main actor and must touch nothing that lives
    /// there; `completion` is where anything stateful happens.
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

    /// The AX application element for a pid, creating its lane on first contact. Go through here rather
    /// than `AXApplication(pid:)` — it is what guarantees the messaging timeout is set.
    public func application(for pid: pid_t) -> AXApplication {
        lane(for: pid).application
    }

    /// Forget an app's lane — call when the process exits. The element holds a Mach port to a dead
    /// process, and a lane table that only grows accumulates one per app the user ever launched.
    public func forget(app pid: pid_t) {
        lanes[pid] = nil
    }

    /// How many apps currently have a lane.
    public var laneCount: Int { lanes.count }

    /// Get or create an app's lane. The messaging timeout is set once here, on the application element:
    /// every window element obtained *through* it inherits the timeout.
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
