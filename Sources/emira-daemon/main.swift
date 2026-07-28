// The long-running process that hosts the `Runtime` and every shell subsystem. An accessory
// `NSApplication` rather than a bare run loop: the compositor needs a window server connection for
// its overlay and a running app for `CADisplayLink`; `.accessory` keeps it out of the Dock.
import AppKit
import Darwin
import Dispatch
import Foundation
import EmiraCore
import EmiraProtocol
import EmiraShell

/// Timestamped line to stderr.
func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] emira-daemon: \(message)\n".utf8))
}

/// The reply's shape for the log line, not its payload — a state dump is thousands of lines.
func summary(of reply: Reply) -> String {
    switch reply.outcome {
    case .ok:                 return "ok"
    case .failed(let error):  return "failed (\(error.code.rawValue))"
    case .state(let json):    return "state (\(json.utf8.count) bytes)"
    }
}

/// A peer vanishing mid-reply must be a failed `write`, never a signal that kills the daemon.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

/// Die, having said why somewhere the user is looking: launched from `emira.app` nobody reads stderr,
/// so when bundled the message is also an alert. `settings` is a pane to offer a button for.
@MainActor func die(_ message: String, settings: String? = nil) -> Never {
    log(message)
    if LoginItem.isBundled {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "emira can't start"
        alert.informativeText = message
        if settings != nil { alert.addButton(withTitle: "Open System Settings") }
        alert.addButton(withTitle: "Quit")
        app.activate()
        if alert.runModal() == .alertFirstButtonReturn, let settings,
           let url = URL(string: settings) {
            NSWorkspace.shared.open(url)
        }
    }
    exit(1)
}

// MARK: - The config file
//
// Must be read *before* the grant checks below: whether Screen Recording is required depends on
// whether the user asked for the cover at all (`smooth-transitions`).

let loader = ConfigLoader(path: ConfigLoader.defaultPath(),
                          watcher: ConfigWatcher(watching: ConfigLoader.defaultPath()),
                          scheduler: DispatchScheduler())

/// The config as the file spells it, before `applyEnvironment`. Kept separate because the grant check
/// below reads the user's *intent*.
var parsedConfig: Config
/// The boot diagnostic, held until there is a menu bar item to show it on. A config broken at launch
/// has no other trace — the daemon runs on defaults and the desktop looks plausible.
var bootConfigError: String?
switch loader.load() {
case .success(let parsed):
    parsedConfig = parsed
    log(FileManager.default.fileExists(atPath: loader.path)
        ? "config: \(loader.path)"
        : "config: \(loader.path) (not present — using defaults)")
case .failure(let error):
    parsedConfig = Config()
    bootConfigError = "\(error)"
    log("config: \(error) — using defaults")
}

// MARK: - Permissions
//
// Both grants are required to start; only Accessibility is required to keep running — without it
// every AX read returns nothing *without an error*. Screen Recording is demanded only when the config
// asked for the cover, and a running daemon degrades rather than dies when macOS revokes it, which is
// why `Permissions.screenRecording` is computed, never cached.

/// A grant emira won't start without, and everything needed to ask for it and to explain it.
struct RequiredGrant {
    let name: String
    /// Completes "emira needs <name> …".
    let purpose: String
    let pane: String
    /// The deep link the alert's button opens.
    let url: String
}

let accessibilityGrant = RequiredGrant(
    name: "Accessibility",
    purpose: "to see and move your windows",
    pane: "Privacy & Security › Accessibility",
    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

let screenRecordingGrant = RequiredGrant(
    name: "Screen Recording",
    purpose: "to animate them smoothly",
    pane: "Privacy & Security › Screen & System Audio Recording",
    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")

var missingGrants: [RequiredGrant] = []

if !Permissions.accessibility.isGranted {
    Permissions.requestAccessibility()
    missingGrants.append(accessibilityGrant)
}

if parsedConfig.smoothTransitions && !Permissions.screenRecording.isGranted {
    Permissions.requestScreenRecording()
    missingGrants.append(screenRecordingGrant)
}

if !missingGrants.isEmpty {
    let needs = missingGrants.map { "\($0.name) \($0.purpose)" }.joined(separator: ", and ")
    let panes = missingGrants.map { "  • System Settings › \($0.pane)" }.joined(separator: "\n")
    die("emira needs \(needs).\n\n"
        + "\(missingGrants.count == 1 ? "Grant it here" : "Grant them here"):\n\(panes)\n\n"
        + "Then launch emira again."
        + (missingGrants.contains { $0.name == screenRecordingGrant.name }
           ? "\n\nTo run without the smooth scroll instead, set `smooth-transitions = false` in "
             + "\(loader.path)."
           : ""),
        settings: missingGrants[0].url)
}

// MARK: - The presentation plane

let screens = NSScreen.screens
if screens.isEmpty {
    die("No displays are attached — there is nothing to manage.")
}
let geometry = ScreenGeometry.current()
// Must be the *same* display the core lays its strip out on — `State.metrics()` resolves against
// `world.monitors.first`, i.e. `screens[0]`. Not `NSScreen.main`: on a two-display machine the cover
// would go up over one screen while the real windows teleported on the other.
let screen = screens[0]
// Read once, used twice, and that shared number is load-bearing: the core lays the strip out inside
// the working area and the cover paints exactly the working area, so the chrome bands the cover
// leaves alone can never contain a window it should have hidden.
let struts = ScreenGeometry.struts(of: screen)
let overlay = Overlay(screen: screen, geometry: geometry, insets: struts)

// MARK: - The truth plane's machinery
//
// One `AXClient` for the whole daemon: the per-app lanes are only serial if the enumerator, the
// writer and the observers all queue onto the same ones.

let registry = WindowRegistry()
let axClient = AXClient()

// MARK: - The capture plane

let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
let capture = CaptureService(
    registry: registry,
    capturer: SCKCapturer(displayId: displayId ?? CGMainDisplayID(),
                          scale: screen.backingScaleFactor),
    scheduler: DispatchScheduler())
let reconstruction = Reconstruction(overlay: overlay, store: capture)

// MARK: - The config, finished

/// The two values a config file may not decide: the struts (the same number must reach the core and
/// the overlay or the cover stops matching the strip) and the Screen Recording grant (a capability, not
/// a preference). Re-applied on every reload, which is what notices macOS revoking the grant.
func applyEnvironment(to config: Config) -> Config {
    var config = config
    config.struts = struts
    config.smoothTransitions = config.smoothTransitions && Permissions.screenRecording.isGranted
    return config
}

var config = applyEnvironment(to: parsedConfig)

// The one config value that reaches the compositor rather than the reducer: how a still is painted
// into a rect that no longer matches it. The core can't carry it — its geometry is identical either way.
reconstruction.animation = config.windowAnimation

// MARK: - The GUI
//
// Created before the pump so a config already broken at boot has somewhere to say so.

let menuBar = MenuBarItem()
menuBar.configError = bootConfigError
menuBar.onError = { log($0) }

// MARK: - The pump

let truth = AXExecutor(registry: registry, writer: AXWindowWriter(client: axClient))

// The system plane. Only failures are reported: both surfaces already log the request, so what a log
// line adds is whether it worked — and a keybind that silently does nothing is the failure this
// feature invites, since a bundled daemon inherits launchd's bare PATH and not the user's.
let launcher = ShellLauncher()
launcher.onOutcome = { log("exec: \($0)") }

let executor = CompositingExecutor(surface: reconstruction, store: capture, truth: truth,
                                   launcher: launcher)

// A transition's latency has two halves and neither subsystem sees the other: frames are counted from
// the raise, but the capture batch before it is time the user waits through. Stitched together below.
var captureHeadMs = 0.0

capture.onBatchResolved = { report in
    if report.isHead { captureHeadMs = report.elapsed * 1000 }
    log(String(format: "capture: %@%d window%@ in %.0f ms%@%@",
               report.isHead ? "" : "+", report.windows, report.windows == 1 ? "" : "s",
               report.elapsed * 1000,
               report.missing > 0 ? " (\(report.missing) missing)" : "",
               report.timedOut ? " — DEADLINE" : ""))
}

executor.onCoverDismissed = { frames, seconds in
    let head = captureHeadMs
    log(String(format: "transition: %d frames in %.0f ms (%.0f fps); %.0f ms capture head → %.0f ms",
               frames, seconds * 1000, Double(frames) / max(seconds, 0.001),
               head, head + seconds * 1000))
}

let runtime = Runtime(
    state: State(config: config),
    executor: executor,
    clock: DisplayLinkDriver(screen: screen),
    // An AX write's landing depends on another process's run loop; this bounds the wait.
    hold: DispatchHoldTimer())

// Once per drain, not once per event; `MenuBarItem` diffs, so a scroll costs no redraws.
menuBar.workspace = runtime.state.workspaces.focused
runtime.onStateChanged = { state in menuBar.workspace = state.workspaces.focused }

// MARK: - The keyboard
//
// A source, not a consequence of state changing, so it is wired here rather than driven by an
// `Effect`. A press produces the same `Event.command` value `emira focus left` sends over the socket.

// Logged here because a keypress that correctly changes nothing looks exactly like a chord that
// never registered, and the keyboard leaves no other trace.
let hotkeys = HotkeyManager(binder: CarbonHotkeyBinder(), sink: EventSink { event in
    if case .command(let command) = event {
        log("key: \(command.words.joined(separator: " "))")
    }
    runtime.sink(event)
})

/// Register a config's bindings and say what happened. Zero bindings is reported with the path, so
/// "the keyboard does nothing" comes with what to do about it.
@MainActor func applyKeys(_ config: Config) {
    let outcome = hotkeys.apply(config.keys)
    guard !outcome.isUnchanged else { return }
    log(config.keys.isEmpty
        ? "keys: none bound — add a [keys] table to \(loader.path)"
        : "keys: \(outcome.summary)")
}

applyKeys(config)

// Only a successful parse becomes an event. The three subsystems told separately — reducer, hotkeys,
// compositor — must all read the *same* post-`applyEnvironment` value.
loader.onLoad = { result in
    switch result {
    case .success(let parsed):
        let live = applyEnvironment(to: parsed)
        log("config: reloaded \(loader.path)")
        runtime.dispatch(.configChanged(live))
        applyKeys(live)
        reconstruction.animation = live.windowAnimation
        menuBar.configError = nil
    case .failure(let error):
        log("config: \(error) — keeping the previous settings")
        // A failed hot reload is otherwise silent, so this is the only signal the edit did nothing.
        menuBar.configError = "\(error)"
    }
}
loader.start()

// MARK: - The truth plane
//
// Launch is just events: `screensChanged`, then one `windowCreated` per window — the same path every
// later observation takes as the user opens, closes, drags and Cmd-Tabs.

let watcher = WorldWatcher(
    source: AXObservationSource(client: axClient, registry: registry),
    enumerator: AXEnumerator(source: AXWindowSource(client: axClient), registry: registry),
    registry: registry,
    scheduler: DispatchScheduler(),
    sink: runtime.sink)

// A scan that gave up leaves a window simply unmanaged, with nothing else to say so.
watcher.onIncompleteScan = { report in
    log("scan gave up: \(report.summary)")
}

runtime.dispatch(.screensChanged(geometry.monitors(screens)))
// Each app is scanned on its own AX lane, so boot costs the slowest app, not the sum. The report
// lands back on the main actor after its windows have already been dispatched and placed.
watcher.start { report in
    log("enumerated \(report.summary)")
    log("managing \(runtime.state.layout.columns.count) columns on workspace "
        + "\(runtime.state.workspaces.focused) of \(runtime.state.workspaces.materialized.count), "
        + "\(runtime.state.world.monitors.count) display(s)")
}

// MARK: - The CLI seam

let socketPath = Wire.socketPath()
let server = SocketServer(path: socketPath) { request in
    let reply = RequestRouter.reply(to: request, from: runtime)
    log("\(request.command.words.joined(separator: " ")) "
        + "(pid \(request.client.pid)) → \(summary(of: reply))")
    return reply
}

do {
    try server.start()
} catch {
    die("emira can't open its control socket at \(socketPath): \(error). "
        + "Another copy may already be running.")
}
log("listening on \(socketPath) (pid \(ProcessInfo.processInfo.processIdentifier))")

// MARK: - Stopping
//
// One shutdown path, reached three ways: Ctrl-C, `kill`, and the menu bar's Quit. Exiting on the spot
// would strand every parked window at its 1 pt sliver, so the desktop is handed back as a `Cascade`.
//
// The order below is load-bearing. Silence every event source *first*: our own cascade writes raise
// `AXWindowMoved`, and a live `WorldWatcher` would answer each by re-placing the window on the strip
// we are dismantling. Then place, then wait for the AX sets to land — bounded, because a hung app
// must delay a quit and never prevent one — then exit.
let teardown = Teardown(executor: truth, scheduler: DispatchScheduler())

/// A second Ctrl-C must not start a second cascade behind the first; `Teardown` latches too.
var isShuttingDown = false

@MainActor func shutdown() {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    log("shutting down")

    watcher.stop()          // our own placements stop being events that undo themselves
    hotkeys.stop()
    loader.stop()
    server.stop()

    teardown.run(placing: runtime.state) { report in
        log(report.windows == 0
            ? "no managed windows to place"
            : "cascaded \(report.windows) window\(report.windows == 1 ? "" : "s")"
              + (report.timedOut ? " (\(report.unlanded) did not answer)" : ""))
        exit(0)
    }
}

menuBar.onQuit = { shutdown() }

// Ctrl-C / `kill` should take the socket file with them; a crash won't, hence `SocketServer`'s
// stale-socket handling. `SIG_IGN` first — the default disposition still fires before a
// `DispatchSourceSignal` gets a look in.
let shutdownSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { shutdown() } }
    source.resume()
    return source
}

// The run loop services the main dispatch queue, the display link, and the AX observers.
// `withExtendedLifetime` is required: a released `DispatchSourceSignal` stops delivering.
withExtendedLifetime(shutdownSources) {
    app.run()
}
