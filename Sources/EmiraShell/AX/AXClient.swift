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
//  · Bounded — `AXUIElementSetMessagingTimeout` turns "wait forever" into `.cannotComplete`, which is
//    an app that did not answer to `AXAccess` and `Event.axFailed` to the reducer.
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

    /// The bound on a call asked to wait: one that always outlasts `defaultTimeout` is never answered by
    /// asking again. It holds its app's lane for as long, with that app's writes queued behind it.
    nonisolated public static let patientTimeout: Float = 1.5

    /// One app's lane: its AX application element and the serial queue every call through it runs on.
    private struct Lane {
        let application: AXApplication
        let queue: DispatchQueue
    }

    /// The lanes, keyed by pid. Created lazily on first contact with an app and dropped when it quits.
    private var lanes: [pid_t: Lane] = [:]

    /// Bounds every AX call this process makes, through the system-wide element: a timeout set on an
    /// application element stops there, and a window element obtained through it waits the system's 1.5 s.
    public init(timeout: Float = AXClient.defaultTimeout) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)
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

    /// The AX application element for a pid, creating its lane on first contact.
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

    /// Get or create an app's lane.
    private func lane(for pid: pid_t) -> Lane {
        if let existing = lanes[pid] { return existing }
        let lane = Lane(
            application: AXApplication(pid: pid),
            queue: DispatchQueue(label: "xyz.emira.ax.\(pid)", qos: .userInitiated))
        lanes[pid] = lane
        return lane
    }
}
