import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The system plane's real half. It spawns actual processes, as `SocketServerTests` opens actual
// sockets: what is worth proving here is exactly what a double cannot say — that the line reaches a
// shell with its quoting intact, and that a failure is reported rather than swallowed. The report is
// the whole feature's safety net: a keybind that silently does nothing is what `exec` invites, since
// a bundled daemon inherits launchd's bare PATH and not the user's.
@Suite @MainActor struct ShellLauncherTests {

    /// Wait for `condition`, up to two seconds. A spawn is not synchronous and the alternative — a
    /// fixed sleep long enough to be safe — is slower every run and flaky anyway.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The happy path, proved by its side effect: the line really reached `/bin/sh` — quoting and all
    /// — and a run that worked says nothing, because both command surfaces already logged the ask.
    @Test func aSuccessfulRunIsSilentAndReachesTheShellIntact() async throws {
        // A path with a space in it, so a naive argv split would fail this.
        let path = NSTemporaryDirectory() + "emira exec \(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let launcher = ShellLauncher()
        var reported: [ShellLauncher.Outcome] = []
        launcher.onOutcome = { reported.append($0) }

        launcher.launch("touch '\(path)'")
        await eventually { FileManager.default.fileExists(atPath: path) }

        #expect(FileManager.default.fileExists(atPath: path))
        #expect(reported.isEmpty)
    }

    /// A command that exits badly is reported, late and asynchronously — which is the only way an
    /// `exec` ever reports anything, since the launch itself never waits.
    @Test func aNonzeroExitIsReported() async {
        let launcher = ShellLauncher()
        var reported: [ShellLauncher.Outcome] = []
        launcher.onOutcome = { reported.append($0) }

        launcher.launch("exit 3")
        await eventually { !reported.isEmpty }

        #expect(reported == [.exited(line: "exit 3", status: 3)])
    }

    /// The one status worth naming: `sh` could not find the command. It is what a Homebrew binary
    /// produces under launchd's PATH, so the diagnostic carries the fix rather than the number.
    @Test func commandNotFoundExplainsItself() async {
        let launcher = ShellLauncher()
        var reported: [ShellLauncher.Outcome] = []
        launcher.onOutcome = { reported.append($0) }

        launcher.launch("emira-no-such-command-\(UUID().uuidString)")
        await eventually { !reported.isEmpty }

        let outcome = reported.first
        guard case .exited(_, let status) = outcome else {
            Issue.record("expected an exit, got \(String(describing: outcome))")
            return
        }
        #expect(status == 127)
        #expect("\(outcome!)".contains("absolute path"))
    }

    /// A child killed by a signal is not an exit status, and reads as one thing rather than as `0`.
    @Test func aSignalledChildIsReportedAsSuch() async {
        let launcher = ShellLauncher()
        var reported: [ShellLauncher.Outcome] = []
        launcher.onOutcome = { reported.append($0) }

        launcher.launch("kill -TERM $$")
        await eventually { !reported.isEmpty }

        guard case .signalled(_, let signal) = reported.first else {
            Issue.record("expected a signal, got \(String(describing: reported.first))")
            return
        }
        #expect(signal == SIGTERM)
    }

    /// Several at once, each reported against its own line — the handler must not capture whichever
    /// launch happened to be last.
    @Test func concurrentLaunchesAreReportedAgainstTheirOwnLines() async {
        let launcher = ShellLauncher()
        var reported: [ShellLauncher.Outcome] = []
        launcher.onOutcome = { reported.append($0) }

        for status in 1...5 { launcher.launch("exit \(status)") }
        await eventually { reported.count == 5 }

        // Keyed by line, so the assertion is about the *pairing* and not about completion order.
        let byLine: [String: Int32] = reported.reduce(into: [:]) { into, outcome in
            if case .exited(let line, let status) = outcome { into[line] = status }
        }
        #expect(byLine == ["exit 1": 1, "exit 2": 2, "exit 3": 3, "exit 4": 4, "exit 5": 5])
    }
}
