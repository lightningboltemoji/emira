import AppKit

// director TAPE [--rehearse]
//
// Plays TAPE on a virtual display of its own, under this checkout's emira, and records the take into
// .github/demo/takes/<tape>/: take.mov and timeline.json. --rehearse plays it without recording. See
// .agents/DEMO.md.

// AppKit's event loop, not Swift's async main: once AppKit has the WindowServer connection, display
// changes reach CoreGraphics only through events AppKit dequeues, and its run loop stops for each one
// it isn't asked for, which an async main takes for the end of the program.
let app = NSApplication.shared
// Its one window is the flash, which mustn't make it an app emira tiles.
app.setActivationPolicy(.accessory)
// Progress shows as it happens when the output is piped, too.
setvbuf(stdout, nil, _IOLBF, 0)

var arguments = Array(CommandLine.arguments.dropFirst())
let rehearse = arguments.contains("--rehearse")
arguments.removeAll { $0 == "--rehearse" }
guard arguments.count == 1 else {
    print("usage: director TAPE [--rehearse]")
    exit(2)
}

Task { @MainActor in
    do {
        let tapeURL = URL(filePath: arguments[0]).standardizedFileURL
        try await Director(tape: try Tape(contentsOf: tapeURL), tapeURL: tapeURL, record: !rehearse).run()
        exit(0)
    } catch {
        print("director: \(error)")
        exit(1)
    }
}
app.run()

@MainActor
final class Director {
    let tape: Tape
    let root: URL
    let take: URL
    let record: Bool
    let cli: EmiraCLI

    private var display: TakeDisplay!
    private let input: Input
    /// Every app the take started, the only ones it presses keys in.
    private var apps: [LaunchedApp] = []
    /// Host times; `finish` turns them into movie times.
    private var markers: [(name: String, time: Double, rect: CGRect)] = []
    private var steps: [(step: Step, start: Double, end: Double)] = []
    private var keys: [(time: Double, keys: String, action: String?)] = []
    private let bindings: [Set<String>: String]

    init(tape: Tape, tapeURL: URL, record: Bool) throws {
        self.tape = tape
        self.record = record
        var root = tapeURL.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: ".github/demo/emira.toml").path()) {
            guard root.pathComponents.count > 1 else { throw DirectorError("the tape isn't in emira's repo") }
            root = root.deletingLastPathComponent()
        }
        self.root = root
        take = root.appending(path: ".github/demo/takes/\(tape.name)")
        cli = EmiraCLI(executable: root.appending(path: ".build/release/emira"))
        input = Input(seed: tape.seed)
        bindings = try Bindings.read(root.appending(path: ".github/demo/emira.toml"))
    }

    func run() async throws {
        let daemonExecutable = root.appending(path: ".build/release/emira-daemon")
        guard FileManager.default.isExecutableFile(atPath: daemonExecutable.path()) else {
            throw DirectorError("no \(daemonExecutable.path()): build it with `swift build -c release`")
        }
        try? FileManager.default.removeItem(at: take)
        try FileManager.default.createDirectory(at: take, withIntermediateDirectories: true)

        display = try await TakeDisplay(size: tape.display)
        var handover = DaemonHandover()
        var daemon: DemoDaemon?
        var recorder: Recorder?
        var flash = 0.0
        var end = 0.0
        var failure: Error?
        do {
            try await handover.stopAll()
            daemon = try DemoDaemon(
                executable: daemonExecutable, config: root.appending(path: ".github/demo/emira.toml"),
                log: take.appending(path: "daemon.log"))
            try await daemon!.waitUntilListening(cli)
            try await clearStage()
            // Out of the picture, on whichever display isn't the take's.
            if let elsewhere = NSScreen.screens.first(where: { $0.displayID != display.id }) {
                let frame = CGDisplayBounds(elsewhere.displayID)
                input.warp(to: CGPoint(x: frame.midX, y: frame.midY))
            }
            for step in tape.setup {
                try await perform(step)
            }

            if record {
                guard let number = display.captureNumber, let screen = NSScreen.screens.first(where: { $0.displayID == display.id })
                else { throw DirectorError("the take's display went away") }
                recorder = try Recorder(display: number, to: take.appending(path: "take.mov"))
                // screencapture takes a moment to start filming, and the flash has to be in the film.
                try await Task.sleep(for: .seconds(2))
                flash = await Flash.show(on: screen)
                try await Task.sleep(for: .milliseconds(600))
            }
            if !InputWatch.start() {
                print("warning: can't watch for your input, so touching the mouse or keyboard won't stop the take")
            }
            print(record ? "recording: hands off the mouse and keyboard" : "rehearsing")
            for step in tape.steps {
                if let interruption = InputWatch.interruption {
                    throw DirectorError("stopped by \(interruption) at line \(step.line): run it again with your hands off")
                }
                let began = hostNow()
                try await perform(step)
                steps.append((step, began, hostNow()))
            }
            try await Task.sleep(for: .milliseconds(500))
            end = hostNow()
        } catch {
            failure = error
        }

        // The desktop goes back as it was whatever happened: the take's apps first, so the daemon
        // handing windows back doesn't hand back theirs, then the daemon, then the display, so the
        // user's daemon never sees it.
        await input.releaseModifiers()
        if let recorder {
            do { try await recorder.stop() } catch { failure = failure ?? error }
        }
        for app in apps.reversed() {
            await app.quit()
        }
        await daemon?.stop()
        await display.remove()
        await handover.restart()
        if let failure { throw failure }

        if let recorder {
            try await finish(recorder, flash: flash, end: end)
        } else {
            print("rehearsed \(tape.steps.count) steps")
        }
    }

    /// Hands the take display an empty workspace 1, and puts what's already on screen elsewhere on
    /// workspace 9, so the tape has 1–8 to itself.
    private func clearStage() async throws {
        try await until("emira to see the take's display", .seconds(5)) { try self.cli.state().monitor(self.display.id) != nil }
        for other in try cli.state().monitors where other.id != display.id {
            let state = try cli.state()
            guard let number = state.number(of: other.id), let takeNumber = state.number(of: display.id) else { continue }
            try cli.send("focus-monitor \(number)")
            for _ in state.shownWindows(on: other.id) {
                try cli.send("move-to-workspace 9")
                try await Task.sleep(for: .milliseconds(150))
            }
            try await until("the windows to leave display \(other.id)", .seconds(5)) {
                try self.cli.state().shownWindows(on: other.id).isEmpty
            }
            // The emptied workspace goes to the take display, and this one falls back to 9; otherwise
            // `focus-workspace 1` would find 1 here.
            try cli.send("move-workspace-to-monitor \(takeNumber)")
            try await until("emira to settle", .seconds(5)) { try self.cli.state().isStill }
        }
        let state = try cli.state()
        guard let takeNumber = state.number(of: display.id) else { throw DirectorError("emira lost the take's display") }
        try cli.send("focus-monitor \(takeNumber)")
        try cli.send("focus-workspace 1")
        try await until("an empty workspace 1 on the take's display", .seconds(5)) {
            let state = try self.cli.state()
            return state.monitor(self.display.id)?.shown == "1" && state.shownWindows(on: self.display.id).isEmpty
                && state.focusedMonitor == self.display.id
        }
        try await until("emira to settle", .seconds(5)) { try self.cli.state().isStill }
    }

    private func finish(_ recorder: Recorder, flash: Double, end: Double) async throws {
        let movie = try await Recorder.firstFlash(in: recorder.url, patch: Flash.patch(display: tape.display, scale: 2))
        let time = { (host: Double) in host - flash + movie }
        let timeline = Timeline(
            tape: tape.name,
            display: .init(width: tape.display.width, height: tape.display.height),
            start: time(steps.first?.start ?? end),
            duration: time(end),
            markers: markers.map { .init(name: $0.name, time: time($0.time), rect: .init($0.rect)) },
            steps: steps.map { .init(line: $0.step.line, command: $0.step.text, start: time($0.start), end: time($0.end)) },
            keys: keys.map { .init(time: time($0.time), keys: $0.keys, action: $0.action) })
        try timeline.write(to: take.appending(path: "timeline.json"))
        let size = (try? recorder.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print(String(format: "recorded %.1fs (flash at %.2fs), %.0f MB, in %@", timeline.duration - timeline.start, movie,
                     Double(size) / 1e6, take.path()))
    }

    // MARK: Steps

    private func perform(_ step: Step) async throws {
        switch step.command {
        case .sleep(let duration):
            try await Task.sleep(for: duration)
        case .key(let combos):
            try requireOurs(step)
            for (index, combo) in combos.enumerated() {
                if index > 0 { try await Task.sleep(for: .milliseconds(160)) }
                keys.append((hostNow(), combo.description, bindings[combo.parts]))
                await input.press(combo)
            }
        case .open(let color):
            try await open(color, step)
        case .wait(let condition, let timeout):
            try await until(condition.description, timeout, step) { try self.holds(condition) }
        case .mark(let name, let target):
            markers.append((name, hostNow(), try rect(target)))
        }
    }

    private func open(_ color: String, _ step: Step) async throws {
        let before = Set(try cli.state().windows.keys)
        let standIn = try Launcher.standIn(color, color: tape.colors[color]!, in: take.appending(path: "standins"))
        apps.append(standIn)
        try await until("\(color)'s window on the take's display", .seconds(10), step) {
            let state = try self.cli.state()
            guard let focused = state.focusedWindow, !before.contains(focused) else { return false }
            return state.shownWindows(on: self.display.id).contains(focused)
        }
        try await standIn.bringToFront()
    }

    /// Input only goes to an app the take started, so it can never land in one of the user's.
    private func requireOurs(_ step: Step) throws {
        guard apps.contains(where: { $0.isRunning && $0.isFrontmost }) else {
            throw TapeError(line: step.line, message: "none of the take's apps is frontmost, so the take stopped")
        }
    }

    private func holds(_ condition: Condition) throws -> Bool {
        let state = try cli.state()
        switch condition {
        case .windows(let count):
            return state.shownWindows(on: display.id).count == count
        case .workspace(let name):
            return state.monitor(display.id)?.shown == name
        case .still:
            return state.isStill
        }
    }

    /// `target` now, in take display points.
    private func rect(_ target: Target) throws -> CGRect {
        let bounds = CGRect(origin: .zero, size: tape.display)
        let origin = display.frame.origin
        let state = try cli.state()
        switch target {
        case .display:
            return bounds
        case .focused:
            guard let window = state.focusedWindow.flatMap({ state.windows[$0] }) else { return bounds }
            return window.frame.offsetBy(dx: -origin.x, dy: -origin.y).intersection(bounds)
        case .column:
            let shown = state.monitor(display.id).flatMap { state.strips[$0.shown] } ?? []
            let column = shown.first { column in state.focusedWindow.map(column.contains) == true } ?? []
            return union(column.compactMap { state.windows[$0]?.frame })
        case .workspace:
            return union(state.shownWindows(on: display.id).compactMap { state.windows[$0]?.frame })
        case .rect(let rect):
            return rect
        }

        /// What of `frames` is on the take display, together.
        func union(_ frames: [CGRect]) -> CGRect {
            let visible = frames.map { $0.offsetBy(dx: -origin.x, dy: -origin.y).intersection(bounds) }.filter { !$0.isNull }
            return visible.dropFirst().reduce(visible.first ?? bounds) { $0.union($1) }
        }
    }

    private func until(_ what: String, _ timeout: Duration, _ step: Step? = nil, _ check: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(try check()) {
            guard ContinuousClock.now < deadline else {
                let message = "gave up waiting for \(what)"
                if let step { throw TapeError(line: step.line, message: message) }
                throw DirectorError(message)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
