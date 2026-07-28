import Foundation

// The system plane: `Effect.exec` becomes a child process. The whole subsystem, because there is
// nothing to reconcile — a spawn has no state in the core, no ack, and no relationship to a window
// until the process opens one, at which point it is an ordinary `AXWindowCreated` like any other.

/// Starts a child process for `Effect.exec`. `ShellLauncher` is the real one; tests record.
@MainActor
public protocol ProcessLauncher: AnyObject {
    /// Start `line` and return immediately, never waiting: the pump is main-thread, and an `exec`
    /// that blocked on its child would freeze the window manager for as long as the child ran.
    func launch(_ line: String)
}

/// Runs a command line through `/bin/sh -c`, fire and forget.
///
/// **Deliberately `sh`, not the user's login shell.** `$SHELL -lc` would source `.zprofile` and pick
/// up the PATH the user expects, at the cost of making emira's behaviour depend on a file it does not
/// own and of a shell startup on every keypress. A user who wants that writes it themselves —
/// `exec /bin/zsh -lc 'ghostty'` — and the reporting below is what makes the need visible.
@MainActor
public final class ShellLauncher: ProcessLauncher {

    /// Something a user needs to hear about. Never the happy path: both command surfaces already log
    /// the request (a key press, a socket line), so what neither can know is whether it *worked*.
    public enum Outcome: Equatable, CustomStringConvertible {
        /// The spawn itself failed — a missing `/bin/sh`, a process limit. Never a bad command line:
        /// `sh` accepts anything and reports its own opinion by exiting.
        case failed(line: String, reason: String)
        /// It ran and exited badly. `127` is `sh` saying it could not find the command, which is what
        /// a daemon launched by `launchd` with a bare `PATH` produces for a Homebrew binary.
        case exited(line: String, status: Int32)
        /// It died on a signal.
        case signalled(line: String, signal: Int32)

        public var description: String {
            switch self {
            case .failed(let line, let reason):    return "'\(line)' did not start — \(reason)"
            case .exited(let line, let status):
                let hint = status == 127 ? " (command not found — try an absolute path)" : ""
                return "'\(line)' exited \(status)\(hint)"
            case .signalled(let line, let signal): return "'\(line)' killed by signal \(signal)"
            }
        }
    }

    /// Where a bad outcome goes. The daemon logs it; nothing feeds back into the core.
    public var onOutcome: (@MainActor (Outcome) -> Void)?

    /// Children still running, held until they exit — a `Process` whose last reference drops takes
    /// its termination handler with it, and with it the only report anybody gets.
    private var running: [ObjectIdentifier: Process] = [:]

    public init() {}

    public func launch(_ line: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        // stdout/stderr are inherited on purpose. Draining a pipe nobody reads is how a chatty child
        // blocks forever at 64 KB, and the diagnostic is reachable anyway: `emira exec …` from a
        // terminal runs the same line in the same environment, with the output in front of you.

        let token = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] finished in
            // Read off the child before hopping: `Process` is not `Sendable` and must not travel.
            let status = finished.terminationStatus
            let signalled = finished.terminationReason == .uncaughtSignal
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.running[token] = nil
                guard status != 0 || signalled else { return }
                self.onOutcome?(signalled ? .signalled(line: line, signal: status)
                                          : .exited(line: line, status: status))
            }
        }

        do {
            running[token] = process
            try process.run()
        } catch {
            running[token] = nil
            onOutcome?(.failed(line: line, reason: "\(error)"))
        }
    }
}
