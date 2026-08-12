// The `emira` CLI: argv in, exit code out. Parses a `Command`, writes one JSON line to the daemon's
// unix socket, prints the reply. Imports only EmiraCore, EmiraProtocol and EmiraConfig — no AppKit, no
// AX — so launch is instant; the transport lives in `SocketClient` because an executable can't be
// unit-tested, and `ConfigCommand`'s schema knowledge lives in `EmiraConfig` for the same reason.
// Exit codes: 0 accepted, 2 usage error, 69 (`EX_UNAVAILABLE`) daemon unreachable, 1 anything else.
import Foundation
import EmiraConfig
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

/// The version `make app` stamped into the enclosing bundle, from the git tag. `Bundle.main` for an
/// executable inside `Contents/MacOS` resolves to the bundle around it, so the CLI reads the same
/// string the daemon does — one source, no codegen, and no way for the two to disagree. Run straight
/// out of `.build` there is no bundle to read, which is exactly the case that isn't a release.
func bundledVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

/// Help text. The verb list comes from `Vocabulary.usage` and the config subcommands from
/// `ConfigCommand.usage`, so each vocabulary is defined in exactly one place — and they stay two
/// vocabularies, because one is sent to the daemon and the other is a file on disk.
func help() -> String {
    """
    emira — scrollable tiling for macOS. Sends one command to the running daemon.

    Usage: emira [--dry-run] <command> [arguments]

    Commands:
    \(Vocabulary.usage)

    The config file, read and written here rather than sent:
    \(ConfigCommand.usage)

    Options:
      --dry-run     Print the request that would be sent, and exit.
      -h, --help    Show this help.
      --version     Show the build and wire protocol versions.
    """
}

var isDryRun = false
var words: [String] = []

for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "-h", "--help":
        print(help())
        exit(ExitCode.success)
    case "--version":
        print("emira \(bundledVersion()) — wire protocol v\(Wire.version)")
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

// `config` is local: it reads and writes a file and never dials the socket, so it branches off before
// `Command.parse` sees a word of it. It is not a verb and must not become one — the config file is not
// a thing you ask the daemon to do.
if words.first == ConfigCommand.name {
    guard !isDryRun else {
        complain("--dry-run prints the request that would be sent, and '\(ConfigCommand.name)' sends none")
        exit(ExitCode.usage)
    }
    exit(ConfigCommand.run(Array(words.dropFirst())))
}

// argv → Command → Request → wire

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
