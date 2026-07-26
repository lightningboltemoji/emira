// emira — the CLI: a thin socket client that parses argv into a `Command`, opens the daemon's
// unix-domain socket, writes one JSON line, and prints the reply (IMPLEMENTATION.md §4, §6).
//
// It imports `EmiraCore` (for `Command` and its surface syntax) and `EmiraProtocol` (for the
// envelope), and nothing else: no `EmiraShell`, no AppKit, no AX, no ScreenCaptureKit. That's what
// keeps launch instant — this process runs for a couple of milliseconds and exits; the daemon does
// all the work.
//
// The transport itself is `SocketClient` (EmiraProtocol), not this file: an executable can't be
// imported, so anything with logic in it is untested by construction — and sockets are precisely where
// a protocol breaks quietly. What's left here is argv in, exit code out. `--dry-run` prints the exact
// line that would go over the socket, without dialing.
//
// Exit codes are the conventional ones, so scripts can branch: 0 accepted, 2 usage error,
// 69 (`EX_UNAVAILABLE`) daemon unreachable, 1 anything else.
//
// No `swift-argument-parser`: the whole grammar is "verb, then at most one word", it is already
// defined once in `Command.parse` (so the config file's keybindings share it), and a subcommand type
// per verb would be more code in the *one* target that can't be unit-tested. Reconsider if the CLI
// ever grows real options.
import Foundation
import EmiraCore
import EmiraProtocol

enum ExitCode {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let unavailable: Int32 = 69      // EX_UNAVAILABLE — the daemon isn't there
}

/// Write a diagnostic to stderr, prefixed like every other Unix tool.
func complain(_ message: String) {
    FileHandle.standardError.write(Data("emira: \(message)\n".utf8))
}

/// Our own header wrapped around the core's verb table, so the vocabulary is listed from the one
/// place it is defined (`CommandSyntax.swift`).
func help() -> String {
    """
    emira — scrollable tiling for macOS. Sends one command to the running daemon.

    Usage: emira [--dry-run] <command> [arguments]

    Commands:
    \(Command.usage)

    Options:
      --dry-run     Print the request that would be sent, and exit.
      -h, --help    Show this help.
      --version     Show the wire protocol version.
    """
}

// MARK: - argv

var isDryRun = false
var words: [String] = []

for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "-h", "--help":
        print(help())
        exit(ExitCode.success)
    case "--version":
        print("emira — wire protocol v\(Wire.version)")
        exit(ExitCode.success)
    case "--dry-run":
        isDryRun = true
    default:
        words.append(argument)
    }
}

guard !words.isEmpty else {
    print(help())
    exit(ExitCode.usage)
}

// MARK: - argv → Command → Request → wire

do {
    let request = Request(try Command.parse(words))
    let line = try Wire.encode(request)

    if isDryRun {
        FileHandle.standardOutput.write(line)
        exit(ExitCode.success)
    }

    switch try SocketClient.send(request).outcome {
    case .ok:
        // Silence is success — the Unix default, and honest: `ok` means the daemon *accepted* the
        // command, and its real work (a teleport, a covered scroll) happens after we've exited.
        exit(ExitCode.success)
    case .state(let json):
        print(json)                                 // `emira debug`
        exit(ExitCode.success)
    case .failed(let error):
        complain("\(error)")
        exit(ExitCode.failure)
    }
} catch let error as CommandSyntaxError {
    complain("\(error)")
    complain("run 'emira --help' for the command list")
    exit(ExitCode.usage)
} catch SocketClientError.daemonUnreachable(let path) {
    // The one error worth its own exit code: the daemon isn't running, which is a *state of the
    // system* a script can act on, not a mistake in the command.
    complain("\(SocketClientError.daemonUnreachable(path: path))")
    exit(ExitCode.unavailable)
} catch {
    complain("\(error)")
    exit(ExitCode.failure)
}
