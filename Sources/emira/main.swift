// The `emira` CLI: argv in, exit code out. Parses a `Command`, writes one JSON line to the daemon's unix
// socket, prints the reply — or, for `watch`, every reply until the daemon goes, which is exit 1.
// Imports only EmiraCore, EmiraProtocol and EmiraConfig — no AppKit, no AX — so launch is instant; the
// transport lives in `SocketClient` because an executable can't be unit-tested, and `ConfigCommand`'s
// schema knowledge lives in `EmiraConfig` for the same reason. Exit codes: 0 accepted, 2 usage error, 69
// (`EX_UNAVAILABLE`) daemon unreachable, 1 anything else.
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
/// `ConfigCommand.usage`, so each is defined in exactly one place. `config override` is a verb, and is
/// listed with the rest of `config` rather than with the verbs.
func help() -> String {
    """
    emira — scrollable tiling for macOS. Sends one command to the running daemon.

    Usage: emira [--dry-run] <command> [arguments]

    Commands:
    \(Vocabulary.usage(of: Vocabulary.verbs.filter { $0.name != ConfigCommand.name }))

    The config — the file is read and written here, and an override is sent to the running daemon:
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

// `config` is local — it reads and writes the file and never dials the socket — except `config override`,
// which changes the running daemon's settings and so is a verb like any other, sent below.
if words.first == ConfigCommand.name, words.dropFirst().first != OverrideIntent.word {
    guard !isDryRun else {
        let named = ([ConfigCommand.name] + words.dropFirst().prefix(1)).joined(separator: " ")
        complain("--dry-run prints the request that would be sent, and '\(named)' sends none")
        exit(ExitCode.usage)
    }
    exit(ConfigCommand.run(Array(words.dropFirst())))
}

// argv → Command → Request → wire

do {
    let command = try Command.parse(words)
    // The one verb naming a setting, which the core cannot check and this binary can: a typo is refused
    // where it was typed, rather than logged by a daemon nobody is reading.
    if case .override(let intent) = command { try ConfigOverrides.check(intent) }
    let request = Request(command)
    let line = try Wire.encode(request)

    if isDryRun {
        FileHandle.standardOutput.write(line)
        exit(ExitCode.success)
    }

    // A line per change, flushed as it comes: whatever reads this is reading it live.
    if request.command == .watch {
        try SocketClient.watch(request) { json in
            print(json)
            fflush(stdout)
        }
    }

    switch try SocketClient.send(request).outcome {
    case .ok:
        // Silence is success. `ok` means accepted, not completed — the work happens after we exit.
        exit(ExitCode.success)
    case .state(let json):
        print(json)                                 // `emira debug`
        exit(ExitCode.success)
    case .desktop(let json):
        print(json)
        exit(ExitCode.success)
    case .failed(let error):
        complain("\(error)")
        exit(ExitCode.failure)
    }
} catch let error as CommandSyntaxError {
    complain("\(error)")
    complain("run 'emira --help' for the command list")
    exit(ExitCode.usage)
} catch let error as ConfigSyntaxError {
    complain("'config override': \(error.message)")
    complain("run 'emira config explain' for every setting emira has")
    exit(ExitCode.usage)
} catch SocketClientError.daemonUnreachable(let path) {
    // Worth its own exit code: a state of the system a script can act on, not a bad command.
    complain("\(SocketClientError.daemonUnreachable(path: path))")
    exit(ExitCode.unavailable)
} catch {
    complain("\(error)")
    exit(ExitCode.failure)
}
