import AppKit
import EmiraCore
import Foundation

// Where the keyboard rests while emira focuses nothing (`Effect.focusNothing`): an invisible window that
// swallows every key, in a second copy of this executable started with `FocusSink.flag`. A process of its
// own because bringing one forward raises every window it owns, and the daemon's must stay where they are.
// The daemon stands it on a display with a line on its stdin and brings it forward through AX
// (`AXWindowWriter.focusNothing`); that stdin closing is the daemon going away.

/// The daemon's handle on the focus sink process.
@MainActor
public final class FocusSink {

    /// The argument that makes this executable the sink rather than the daemon.
    public static let flag = "--focus-sink"

    /// Told when the sink exits, with its status. The next `readyPid` starts another.
    public var onExit: (@MainActor (Int32) -> Void)?

    private let executable: URL
    private var process: Process?
    private var input: FileHandle?

    /// - Parameter executable: this daemon's own binary, which `flag` turns into the sink.
    public init(executable: URL) {
        self.executable = executable
    }

    /// Start the sink, unless one is running. Started ahead of need: a process takes the keyboard only
    /// once it has checked in with the window server, which a sink launched on demand has not.
    public func start() {
        guard process?.isRunning != true else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.flag]
        let pipe = Pipe()
        process.standardInput = pipe
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onExit?(status) } }
        }
        do {
            try process.run()
        } catch {
            onExit?(-1)
            return
        }
        self.process = process
        input = pipe.fileHandleForWriting
    }

    /// The running sink's pid. A sink that has exited is started again and answers `nil` this once, for
    /// `start`'s reason.
    public func readyPid() -> pid_t? {
        if let process, process.isRunning { return process.processIdentifier }
        start()
        return nil
    }

    /// Stand the sink's window on `display`, in core coordinates, so the keyboard rests on that screen.
    public func stand(on display: Rect) {
        let frame = ScreenGeometry.current().cocoa(display)
        // A sink that died mid-write is `EPIPE`, which the next `readyPid` answers.
        try? input?.write(contentsOf: Data("\(Double(frame.midX)) \(Double(frame.midY))\n".utf8))
    }
}

extension FocusSink {

    /// The sink process's whole life: one window that takes the keyboard whenever the daemon brings
    /// this process forward, moved by `x y` lines on stdin, until stdin closes.
    public static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let sink = SinkProcess()
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { sink.receive(data) } }
        }
        app.run()
        exit(0)
    }
}

/// The sink's side of the pipe: its window, and the line it is part-way through reading.
@MainActor
private final class SinkProcess {

    private let window = SinkWindow()
    private var partial = ""

    init() {
        // Ordered in only once brought forward: a window put up at launch is taken by macOS as the
        // launch asking for the front, which would take the keyboard from whatever the user is in.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeKeyboard() }
        }
    }

    private func takeKeyboard() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
    }

    /// Fold one read from stdin. Empty is end of file: the daemon has gone.
    func receive(_ data: Data) {
        guard !data.isEmpty else { exit(0) }
        partial += String(decoding: data, as: UTF8.self)
        var lines = partial.split(separator: "\n", omittingEmptySubsequences: false)
        partial = String(lines.removeLast())
        // Only the newest place matters.
        guard let line = lines.last else { return }
        let numbers = line.split(separator: " ").compactMap { Double($0) }
        guard numbers.count == 2 else { return }
        window.setFrameOrigin(NSPoint(x: numbers[0], y: numbers[1]))
    }
}

/// A point of a window: transparent, beneath every app's window, and able to become key.
private final class SinkWindow: NSWindow {

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0
        hasShadow = false
        ignoresMouseEvents = true
        // Under the normal level, which also keeps it out of the window list emira reads
        // (`WindowRegistry.windowLevels`) and so out of the desktop it manages.
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        // On every Space, so taking the keyboard never switches one.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        animationBehavior = .none
        isReleasedWhenClosed = false
        contentView = SwallowingView()
    }

    override var canBecomeKey: Bool { true }
}

/// Takes every key and does nothing with it: a key pressed while emira focuses nothing is pressed at
/// nothing, rather than beeping.
private final class SwallowingView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}
}
