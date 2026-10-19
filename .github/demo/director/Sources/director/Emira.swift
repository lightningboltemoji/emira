import AppKit
import Foundation

/// emira as the take sees it: through its CLI, the daemon's public interface.
struct EmiraCLI {
    let executable: URL

    @discardableResult
    func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let problem = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DirectorError("emira \(arguments.joined(separator: " ")): "
                + String(decoding: problem, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    /// A command as the CLI spells it, `focus-monitor 2`.
    func send(_ command: String) throws {
        try run(command.split(separator: " ").map(String.init))
    }

    func state() throws -> EmiraState {
        try EmiraState(json: run(["debug"]))
    }
}

/// The `[keys]` table of a config: each chord, as the set of its parts, and the command it runs.
enum Bindings {
    static func read(_ config: URL) throws -> [Set<String>: String] {
        var bindings: [Set<String>: String] = [:]
        var inKeys = false
        for raw in try String(contentsOf: config, encoding: .utf8).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inKeys = line == "[keys]"
            } else if inKeys, let equals = line.firstIndex(of: "="), !line.hasPrefix("#") {
                let chord = line[..<equals].trimmingCharacters(in: .whitespaces)
                let command = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                bindings[Set(chord.split(separator: "-").map(String.init))] = command.trimmingCharacters(in: ["\""])
            }
        }
        return bindings
    }
}

/// What the director reads of `emira debug`: the displays, what each shows, and the windows.
struct EmiraState {
    struct Monitor {
        var id: CGDirectDisplayID
        var shown: String
        var owned: [String]
        /// Global points from the top left.
        var frame: CGRect
    }

    struct Window {
        var id: Int
        var frame: CGRect
    }

    /// In emira's order, which `focus-monitor N` counts from 1.
    var monitors: [Monitor]
    var focusedMonitor: CGDirectDisplayID?
    var windows: [Int: Window]
    var focusedWindow: Int?
    /// Each workspace's columns, each a column's windows from the top.
    var strips: [String: [[Int]]]
    /// Nothing emira draws is moving: no spring off its target, no window animating, no cover clearing.
    var isStill: Bool

    init(json data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let monitorState = root["monitors"] as? [String: Any],
              let world = root["world"] as? [String: Any],
              let workspaces = root["workspaces"] as? [String: Any]
        else { throw DirectorError("emira debug's state isn't what the director expects") }

        let frames = Dictionary(
            ((world["monitors"] as? [[String: Any]]) ?? []).compactMap { info -> (CGDirectDisplayID, CGRect)? in
                guard let id = info["id"] as? Int, let frame = Self.rect(info["frame"]) else { return nil }
                return (CGDirectDisplayID(id), frame)
            }, uniquingKeysWith: { first, _ in first })
        monitors = ((monitorState["records"] as? [[String: Any]]) ?? []).compactMap { record in
            guard let id = record["id"] as? Int else { return nil }
            return Monitor(
                id: CGDirectDisplayID(id), shown: record["shown"] as? String ?? "",
                owned: record["owned"] as? [String] ?? [], frame: frames[CGDirectDisplayID(id)] ?? .zero)
        }
        focusedMonitor = (monitorState["focused"] as? Int).map { CGDirectDisplayID($0) }

        windows = [:]
        for (_, value) in Self.pairs(world["windows"]) {
            guard let info = value as? [String: Any], let id = info["id"] as? Int else { continue }
            windows[id] = Window(id: id, frame: Self.rect(info["frame"]) ?? .zero)
        }
        focusedWindow = world["focusedWindow"] as? Int

        strips = [:]
        for (name, value) in (workspaces["strips"] as? [String: Any]) ?? [:] {
            let layout = (value as? [String: Any])?["layout"] as? [String: Any]
            let columns = (layout?["columns"] as? [[String: Any]]) ?? []
            strips[name] = columns.map { $0["windowIds"] as? [Int] ?? [] }
        }

        let motion = root["motion"] as? [String: Any] ?? [:]
        let springsAtRest = Self.pairs(motion["viewports"]).allSatisfy { _, value in
            guard let offset = (value as? [String: Any])?["offset"] as? [String: Any],
                  let current = offset["current"] as? Double, let target = offset["target"] as? Double
            else { return true }
            return abs(current - target) < 0.5 && abs(offset["velocity"] as? Double ?? 0) < 1
        }
        isStill = springsAtRest
            && ((motion["windowAnimators"] as? [Any]) ?? []).isEmpty
            && ((motion["columnWidths"] as? [Any]) ?? []).isEmpty
            && ((root["coverClearing"] as? [Any]) ?? []).isEmpty
    }

    func monitor(_ id: CGDirectDisplayID) -> Monitor? {
        monitors.first { $0.id == id }
    }

    /// `focus-monitor`'s number for a display.
    func number(of id: CGDirectDisplayID) -> Int? {
        monitors.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// The windows of what `display` shows, column by column.
    func shownWindows(on display: CGDirectDisplayID) -> [Int] {
        guard let shown = monitor(display)?.shown else { return [] }
        return (strips[shown] ?? []).flatMap { $0 }
    }

    /// emira writes a dictionary keyed by anything other than a string as `[key, value, key, value]`.
    private static func pairs(_ value: Any?) -> [(Any, Any)] {
        guard let flat = value as? [Any] else { return [] }
        return stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0], flat[$0 + 1]) }
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let rect = value as? [String: Any],
              let origin = rect["origin"] as? [String: Double], let size = rect["size"] as? [String: Double]
        else { return nil }
        return CGRect(x: origin["x"] ?? 0, y: origin["y"] ?? 0, width: size["width"] ?? 0, height: size["height"] ?? 0)
    }
}

/// The daemons running before the take, stopped so the take's can have the desktop, and started
/// again after it.
@MainActor
struct DaemonHandover {
    /// The executables of the daemons this stopped.
    private(set) var stopped: [String] = []

    /// Every running emira-daemon, by pid and executable.
    static func running() -> [(pid: pid_t, path: String)] {
        let count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(max(filled, 0))).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            let path = String(cString: buffer)
            return URL(filePath: path).lastPathComponent == "emira-daemon" ? (pid, path) : nil
        }
    }

    /// SIGTERM, which has a daemon hand every window back before it exits.
    static func stop(_ pid: pid_t) async throws {
        kill(pid, SIGTERM)
        for _ in 0..<100 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        if kill(pid, 0) == 0 { throw DirectorError("emira-daemon \(pid) didn't quit") }
    }

    mutating func stopAll() async throws {
        for daemon in Self.running() {
            print("stopping \(daemon.path) for the take")
            try await Self.stop(daemon.pid)
            stopped.append(daemon.path)
        }
    }

    /// An app bundle's daemon is opened as the app, and waited for: a launch still pending when the
    /// director exits never happens. One run from a build can only be named.
    func restart() async {
        for path in stopped {
            if let range = path.range(of: ".app/Contents/MacOS/") {
                let bundle = URL(filePath: String(path[..<range.lowerBound]) + ".app")
                print("starting \(bundle.path()) again")
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: bundle, configuration: NSWorkspace.OpenConfiguration())
                } catch {
                    print("warning: couldn't start \(bundle.path()): \(error.localizedDescription)")
                }
            } else {
                print("note: \(path) was running before the take; start it again yourself")
            }
        }
    }
}

/// The take's own daemon: this checkout's build, on .github/demo/emira.toml.
@MainActor
final class DemoDaemon {
    private let process = Process()

    init(executable: URL, config: URL, log: URL) throws {
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["EMIRA_CONFIG"] = config.path()
        process.environment = environment
        FileManager.default.createFile(atPath: log.path(), contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
    }

    func waitUntilListening(_ cli: EmiraCLI) async throws {
        for _ in 0..<100 {
            if (try? cli.state()) != nil { return }
            guard process.isRunning else { throw DirectorError("the take's emira-daemon exited at launch") }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DirectorError("the take's emira-daemon never answered")
    }

    func stop() async {
        guard process.isRunning else { return }
        try? await DaemonHandover.stop(process.processIdentifier)
    }
}
