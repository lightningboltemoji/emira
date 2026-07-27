// The `emira` CLI: argv in, exit code out. Parses a `Command`, writes one JSON line to the daemon's
// unix socket, prints the reply. Imports only EmiraCore and EmiraProtocol — no AppKit, no AX — so
// launch is instant; the transport lives in `SocketClient` because an executable can't be unit-tested.
// Exit codes: 0 accepted, 2 usage error, 69 (`EX_UNAVAILABLE`) daemon unreachable, 1 anything else.
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

/// Help text. The verb list comes from `Command.usage`, so the vocabulary is defined in one place.
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
        // Silence is success. `ok` means accepted, not completed — the work happens after we exit.
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
    // Worth its own exit code: a state of the system a script can act on, not a bad command.
    complain("\(SocketClientError.daemonUnreachable(path: path))")
    exit(ExitCode.unavailable)
} catch {
    complain("\(error)")
    exit(ExitCode.failure)
}
