// `emira config` — the config file, read and written here rather than asked of the daemon. It is a
// file: the CLI opens it, `EmiraConfig` says what it means, and hot reload does the rest, so nothing
// on this path talks to a socket and there is no `config` verb for it to send. What it needs from the
// shell is nothing, which is what keeps the CLI framework-free and instant to launch.
//
// **No sentence about a setting is written down here.** The label, the help, what a legal value is,
// the default and the current reading all come off `ConfigSchema`; this file lays them out, decides
// exit codes, and touches the disk.
import Foundation
import EmiraCore
import EmiraConfig

enum ConfigCommand {

    /// The subcommands, in the order help prints them — the one place they are spelled. `Command.usage`
    /// is that place for the verbs, and these are deliberately not verbs: the config file is not a
    /// thing you ask the daemon to do.
    static let usage = """
      config check                Check the config file; print the diagnostic, if any.
      config explain [<key>]      What a setting is, what it may be, and what it is now.
      config get <key>            Print one setting's current value.
      config set <key> <value>    Write one setting. The daemon picks it up on its own.
    """

    /// The word that reaches this branch, before `Command.parse` ever sees it.
    static let name = "config"

    static func run(_ words: [String]) -> Int32 {
        guard let subcommand = words.first else {
            print(usage)
            return ExitCode.usage
        }
        let arguments = Array(words.dropFirst())
        switch subcommand {
        case "check":   return check(arguments)
        case "explain": return explain(arguments)
        case "get":     return get(arguments)
        case "set":     return set(arguments)
        default:
            complain("'\(subcommand)' is not something 'emira config' does")
            complain("run 'emira --help' for the list")
            return ExitCode.usage
        }
    }

    /// Parse the file and say nothing when it reads — the same reading the daemon does, including what
    /// it makes of a file that isn't there.
    private static func check(_ arguments: [String]) -> Int32 {
        guard arguments.isEmpty else { return tooMany("config check") }
        guard FileManager.default.fileExists(atPath: path) else {
            // Not a failure: an absent file is every setting at its default, which is what the daemon
            // runs on too. Worth saying, since the alternative is silence about a file being checked
            // that nothing is reading.
            complain("no file at \(path) — every setting is at its default")
            return ExitCode.success
        }
        return load() == nil ? ExitCode.failure : ExitCode.success
    }

    /// The whole schema, or one setting of it.
    private static func explain(_ arguments: [String]) -> Int32 {
        guard arguments.count <= 1 else { return tooMany("config explain [<key>]") }
        guard let config = load() else { return ExitCode.failure }
        guard let key = arguments.first else {
            print(ConfigSchema.summary(of: config))
            return ExitCode.success
        }
        guard let setting = ConfigSchema.setting(for: key) else { return unknown(key) }
        print(setting.explanation(in: config))
        return ExitCode.success
    }

    /// One value, spelled the way the file spells it — so what comes out of `get` goes into `set`.
    private static func get(_ arguments: [String]) -> Int32 {
        guard !arguments.isEmpty else { return tooFew("config get <key>") }
        guard arguments.count == 1 else { return tooMany("config get <key>") }
        guard let setting = ConfigSchema.setting(for: arguments[0]) else { return unknown(arguments[0]) }
        guard let config = load() else { return ExitCode.failure }
        print(setting.value(in: config).spelled)
        return ExitCode.success
    }

    /// Write one setting through `ConfigDocument`, which changes that key's line and nothing else in
    /// the file. Silence is success, and the running daemon reloads from the save itself.
    private static func set(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 2 else { return tooFew("config set <key> <value>") }
        let key = arguments[0]
        guard let setting = ConfigSchema.setting(for: key) else { return unknown(key) }

        let value: TOMLValue
        do {
            // The argument's words rejoined: `set layout.width-presets 0.5 1` is one list, and a shell
            // that split it on spaces did not mean two arguments.
            value = try setting.value(from: arguments.dropFirst().joined(separator: " "))
        } catch let error as ConfigSyntaxError {
            complain(error.message)                 // no line: this value came from an argument
            return ExitCode.usage
        } catch {
            complain("\(error)")
            return ExitCode.usage
        }

        guard var document = document() else { return ExitCode.failure }
        do {
            // Setting something to its default *unsets* it: an absent key already means that, and a
            // file that writes it down pins it against ever changing.
            if setting.isDefault(value) {
                try document.remove(key)
            } else {
                try document.set(key, to: value)
            }
            try save(document.rendered)
            return ExitCode.success
        } catch let error as ConfigSyntaxError {
            complain(diagnostic(error))
            return ExitCode.failure
        } catch {
            complain("\(path): \(error.localizedDescription)")
            return ExitCode.failure
        }
    }

    private static var path: String { Config.defaultPath() }

    /// The file's text. An absent file reads as empty, which is the same thing the daemon makes of one.
    private static func text() throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// The one way the file is read: `read` gets its text, and anything it objects to is printed as the
    /// file's own diagnostic. `refusal` is the extra sentence a *write* owes — what was not done, rather
    /// than only what was wrong.
    private static func reading<T>(refusal: String? = nil, _ read: (String) throws -> T) -> T? {
        do {
            return try read(try text())
        } catch let error as ConfigSyntaxError {
            complain(diagnostic(error))
            refusal.map(complain)
            return nil
        } catch {
            complain("\(path): \(error.localizedDescription)")
            return nil
        }
    }

    /// What the file says, or `nil` having said why it says nothing.
    private static func load() -> Config? { reading(Config.parse) }

    /// The file as something to edit, or `nil` having refused. **A file emira cannot read is one it
    /// must not write**: an edit is a splice into text whose meaning is unknown, and the rest of it is
    /// the user's work.
    private static func document() -> ConfigDocument? {
        reading(refusal: "nothing written — fix that line first, so an edit isn't made blind") {
            try ConfigDocument($0)
        }
    }

    /// Write it, atomically — `Data.write(.atomic)` *is* the temp-file-and-`rename(2)` dance, and it is
    /// the save `ConfigWatcher` was built to survive: the daemon reloads from the file changing, so
    /// there is no command to send after this.
    private static func save(_ text: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// `path:line: message`, which is what the daemon logs and what an editor's error parser reads.
    private static func diagnostic(_ error: ConfigSyntaxError) -> String {
        "\(path):\(error.line): \(error.message)"
    }

    /// A key the schema doesn't have — the file's own complaint about one, so there is one wording
    /// wherever the key came from.
    private static func unknown(_ key: String) -> Int32 {
        complain(ConfigSyntaxError.unknownKey(line: 0, key: key).message)
        complain("run 'emira config explain' for every setting emira has")
        return ExitCode.usage
    }

    private static func tooMany(_ signature: String) -> Int32 {
        complain("too many arguments — usage: emira \(signature)")
        return ExitCode.usage
    }

    private static func tooFew(_ signature: String) -> Int32 {
        complain("not enough arguments — usage: emira \(signature)")
        return ExitCode.usage
    }
}
