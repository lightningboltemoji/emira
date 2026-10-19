import AppKit
import ApplicationServices
import Foundation

struct DirectorError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) {
        self.description = description
    }
}

/// An app the take started, the only kind the director presses keys in, which it quits when the take
/// ends.
@MainActor
final class LaunchedApp {
    let name: String
    let pid: pid_t
    private let process: Process

    init(name: String, process: Process) {
        self.name = name
        self.pid = process.processIdentifier
        self.process = process
    }

    private var element: AXUIElement { AXUIElementCreateApplication(pid) }

    var isRunning: Bool { kill(pid, 0) == 0 }

    /// Read through AX, which answers for the app now rather than when this process last looked.
    var isFrontmost: Bool {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXFrontmostAttribute as CFString, &value)
        return (value as? Bool) == true
    }

    /// Brings the app forward through AX, which unlike activating it from here isn't something the
    /// system can decline.
    func bringToFront() async throws {
        for _ in 0..<10 {
            if isFrontmost { return }
            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            try await Task.sleep(for: .milliseconds(150))
        }
        throw DirectorError("couldn't bring \(name) to the front")
    }

    /// Quits as the Dock's Quit does; kills it if that takes too long.
    func quit() async {
        guard isRunning else { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
        for _ in 0..<50 where isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if isRunning { kill(pid, SIGKILL) }
        process.waitUntilExit()
    }
}

enum Launcher {
    /// A stand-in of `color` called `name`: the `standin` built beside the director, run through a
    /// link in `folder` named `name`, since macOS names an app without a bundle after the path it ran from.
    @MainActor
    static func standIn(_ name: String, color: String, in folder: URL) throws -> LaunchedApp {
        let executable = Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "standin")
        guard FileManager.default.isExecutableFile(atPath: executable.path()) else {
            throw DirectorError("no \(executable.path()): build the director's package, which builds it too")
        }
        let link = folder.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        let process = Process()
        process.executableURL = link
        process.arguments = [name, color]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return LaunchedApp(name: name, process: process)
    }
}
