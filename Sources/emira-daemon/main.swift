// emira-daemon — the long-running process that hosts the `Runtime` and every shell subsystem. It is
// now an **accessory `NSApplication`**: the compositor needs a window server connection for its
// overlay and a running app for `CADisplayLink`, so `RunLoop.main.run()` is replaced by `app.run()`
// and the activation policy is `.accessory` (no Dock icon, no menu bar — the M5 `LSUIElement`
// `Info.plist` and menu-bar item just make that permanent and bundled).
//
// **What is real and what is a stand-in, stated plainly.** The presentation plane is *real*: a real
// overlay window, real `CALayer`s, a real display link, the real cover lifecycle the core drives. The
// truth plane is now real in **all three** directions: `AXEnumerator` reads the actual windows on the
// actual desktop and binds each to its public `CGWindowID` (M3 part 1), `AXExecutor` writes their
// geometry and focus back over AX (M3 part 2a), and `WorldWatcher` keeps the two in agreement as the
// user works (M3 part 2b) — a window opened, closed, dragged, minimized or Cmd-Tabbed to is an `Event`
// like any other. The world is no longer a photograph, and the fake one that stood in for it is gone.
//
// **And as of M4 part 1, nothing here is a stand-in.** The last one — cover layers as coloured
// rectangles over a flat fill — is replaced by `CaptureService`: real ScreenCaptureKit stills of the
// scoped windows over the real desktop, captured with them cut out of it. Every plane of the §1 diagram
// is now the thing it was drawn as.
import AppKit
import Darwin
import Dispatch
import Foundation
import EmiraCore
import EmiraProtocol
import EmiraShell

/// Timestamped line to stderr. `os_log` behind a `Logging` wrapper is M5 (IMPLEMENTATION.md §6); until
/// then the daemon runs in a terminal and this is what a human wants.
func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] emira-daemon: \(message)\n".utf8))
}

/// One word for the log line — the reply's shape, not its payload (a state dump is thousands of lines).
func summary(of reply: Reply) -> String {
    switch reply.outcome {
    case .ok:                 return "ok"
    case .failed(let error):  return "failed (\(error.code.rawValue))"
    case .state(let json):    return "state (\(json.utf8.count) bytes)"
    }
}

/// A writable peer can vanish mid-reply; that must be a failed `write` we ignore, never a signal that
/// takes down the window manager.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Checked first and fatally: with the grant missing, every AX read returns nothing *without an error*,
// and a window manager that silently manages nothing is the worst failure there is. Now that writes
// land too, "first" also means before anything can move.
if !Permissions.accessibility.isGranted {
    Permissions.requestAccessibility()
    log("Accessibility permission is required. Grant emira access in System Settings › "
        + "Privacy & Security › Accessibility, then start the daemon again.")
    exit(1)
}

// MARK: - The presentation plane

let screens = NSScreen.screens
if screens.isEmpty {
    log("no displays attached — nothing to manage")
    exit(1)
}
let geometry = ScreenGeometry.current()
// One overlay for now; per-monitor covers land with per-monitor strips (M6). It has to be the *same*
// display the core lays its strip out on — `State.metrics()` resolves against `world.monitors.first`,
// i.e. `screens[0]` — or, on a two-display machine, the cover would go up over one screen while the
// real windows teleported on the other. (This read `NSScreen.main` until real windows started moving,
// where the two are the same display on the single-monitor setups M6 hasn't superseded yet.)
let screen = screens[0]
// The struts are read once and used twice, and that shared number is load-bearing: the core lays the
// strip out inside the working area, and the cover paints exactly the working area — so the chrome
// bands it deliberately leaves alone (M4 part 3, the doubled menu bar) can never contain a window it
// was supposed to be hiding.
let struts = ScreenGeometry.struts(of: screen)
let overlay = Overlay(screen: screen, geometry: geometry, insets: struts)

// MARK: - The truth plane's machinery
//
// One `AXClient` for the whole daemon: the per-app lanes are only serial if the enumerator, the writer
// and the observers all queue onto the same ones.

let registry = WindowRegistry()
let axClient = AXClient()

// MARK: - The capture plane
//
// The second TCC grant, and — unlike Accessibility — a *non-fatal* one. Without it there are no pixels
// to build a cover from, so we don't build one: `Config.smoothTransitions` goes false and every scroll
// snaps, which is PRINCIPLES.md §4a, the behaviour the smoothness layer sits on top of. emira still
// tiles, still scrolls, still reveals — it just does it at once.

let screenRecording = Permissions.screenRecording
if !screenRecording.isGranted {
    Permissions.requestScreenRecording()
    log("Screen Recording is not granted — running without animated transitions (windows will snap). "
        + "Grant emira access in System Settings › Privacy & Security › Screen & System Audio "
        + "Recording, then start the daemon again for the smooth scroll.")
}

let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
let capture = CaptureService(
    registry: registry,
    capturer: SCKCapturer(displayId: displayId ?? CGMainDisplayID(),
                          scale: screen.backingScaleFactor),
    scheduler: DispatchScheduler())
let reconstruction = Reconstruction(overlay: overlay, store: capture)

// MARK: - The config file
//
// Read once here, then re-read on every save (`ConfigWatcher`) and on every `reload-config`
// (`Effect.reloadConfig` → `ConfigSource.reload`). A missing file is the zero-config strip; a broken
// one is a diagnostic and *no change at all*, because a typo must not be able to rearrange a desktop.

let loader = ConfigLoader(path: ConfigLoader.defaultPath(),
                          watcher: ConfigWatcher(watching: ConfigLoader.defaultPath()),
                          scheduler: DispatchScheduler())

/// The two values a config file may **not** decide, folded in over whatever it did say.
///
/// The struts are a fact about the hardware, and the same number has to reach the core and the
/// overlay or the cover stops matching the strip (M4 part 3). The Screen Recording grant is a
/// capability, not a preference: a file may ask for snaps (`smooth-transitions = false`) but it
/// cannot grant itself pixels. Re-evaluating the grant *here*, on every reload, is also the first
/// thing that notices macOS revoking it mid-session — §10's re-prompt is not theoretical.
func applyEnvironment(to config: Config) -> Config {
    var config = config
    config.struts = struts
    config.smoothTransitions = config.smoothTransitions && Permissions.screenRecording.isGranted
    return config
}

var config: Config
switch loader.load() {
case .success(let parsed):
    config = applyEnvironment(to: parsed)
    log(FileManager.default.fileExists(atPath: loader.path)
        ? "config: \(loader.path)"
        : "config: \(loader.path) (not present — using defaults)")
case .failure(let error):
    config = applyEnvironment(to: Config())
    log("config: \(error) — using defaults")
}

// The one config value that reaches the *compositor* rather than the reducer: how a still is painted
// into a rect that no longer matches it (`Config.windowAnimation`). Set here and again on every reload,
// for the same reason `applyKeys` is — the core cannot carry it, because the geometry it emits is
// identical under both settings.
reconstruction.animation = config.windowAnimation

// MARK: - The pump

let truth = AXExecutor(registry: registry, writer: AXWindowWriter(client: axClient))
let executor = CompositingExecutor(surface: reconstruction, store: capture, truth: truth,
                                   config: loader)

// The two halves of a transition's latency, and neither can see the other.
//
// Frames-per-transition is the only *smoothness* read-out there is — `Spring` is analytic, so a
// lurching six-frame scroll and a fluid 76-frame one trace the same curve through `emira debug`. But it
// is counted from the **raise**, and the capture batch that precedes it costs ~110 ms that the user
// waits through with nothing on screen having moved. Reporting only the first number understated every
// scroll by that much (`PRINCIPLES.md` §10, M4 part 1). So the head is measured here and stitched into
// the line the transition prints, which is the only number that describes what the keypress felt like.
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
    // Real AX writes mean a landing depends on another process's run loop; this is the bound on
    // waiting for one (§3).
    hold: DispatchHoldTimer())

// MARK: - The keyboard
//
// The last event source, and the one that makes emira usable without a terminal. It is wired here
// rather than driven by an `Effect` for the same reason the socket server and the AX observers are:
// it is a *source*, not a consequence of state changing. A press produces `Event.command` — the same
// value `emira focus left` sends over the socket (IMPLEMENTATION.md §2).

// A press is logged here, not in `HotkeyManager` — the same arrangement as the socket server, which
// also reports its commands from the daemon rather than from inside `SocketServer`. It earns the
// wrapper: the keyboard is the *only* command surface with no other trace of itself. A socket command
// leaves a client, a shell history and an exit code; a keypress that changes nothing visible (an
// in-view `focus`, which correctly produces no motion — PRINCIPLES.md §4a) is otherwise
// indistinguishable from a chord that never registered at all. That ambiguity is not hypothetical: it
// is exactly what the M5 part 2 smoke ran into.
let hotkeys = HotkeyManager(binder: CarbonHotkeyBinder(), sink: EventSink { event in
    if case .command(let command) = event {
        log("key: \(command.words.joined(separator: " "))")
    }
    runtime.sink(event)
})

/// Register a config's bindings and say what happened. Zero bindings is reported *with the path*,
/// because "the keyboard does nothing" and "you have no `[keys]` table in this file" are the same
/// fact, and only the second one tells the user what to do about it.
@MainActor func applyKeys(_ config: Config) {
    let outcome = hotkeys.apply(config.keys)
    guard !outcome.isUnchanged else { return }
    log(config.keys.isEmpty
        ? "keys: none bound — add a [keys] table to \(loader.path)"
        : "keys: \(outcome.summary)")
}

applyKeys(config)

// Now that there is a pump, a reload has somewhere to go. Only a *successful* parse becomes an event;
// a failure is logged and the running config stands.
//
// Three subsystems care about a reload, and they are told separately: the reducer re-lays-out the
// strip, the hotkey manager re-takes the chords, and the compositor changes how it paints a still. All
// three read the *same* post-`applyEnvironment` value, so the keyboard, the layout and the cover can
// never be configured from different files.
loader.onLoad = { result in
    switch result {
    case .success(let parsed):
        let live = applyEnvironment(to: parsed)
        log("config: reloaded \(loader.path)")
        runtime.dispatch(.configChanged(live))
        applyKeys(live)
        reconstruction.animation = live.windowAnimation
    case .failure(let error):
        log("config: \(error) — keeping the previous settings")
    }
}
loader.start()

// MARK: - The truth plane
//
// Launch is just events (`Runtime`): `screensChanged`, then one `windowCreated` per window — the same
// path every later observation takes, which is now the point rather than a nicety: after the boot scan
// the watcher keeps feeding that same path as the user opens, closes, drags and Cmd-Tabs.

let watcher = WorldWatcher(
    source: AXObservationSource(client: axClient, registry: registry),
    enumerator: AXEnumerator(source: AXWindowSource(client: axClient), registry: registry),
    registry: registry,
    scheduler: DispatchScheduler(),
    sink: runtime.sink)

// A scan that gave up with something unaccounted for is the one failure the user cannot see from the
// outside: the window is simply not managed, and nothing else says so.
watcher.onIncompleteScan = { report in
    log("scan gave up: \(report.summary)")
}

runtime.dispatch(.screensChanged(geometry.monitors(screens)))
// Asynchronous by construction — every app is scanned on its own AX lane, so the boot cost is the
// slowest app, not the sum. The report lands back on the main actor a few milliseconds later, by which
// time its windows have already been dispatched and placed.
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
    log("cannot listen: \(error)")
    exit(1)
}
log("listening on \(socketPath) (pid \(ProcessInfo.processInfo.processIdentifier))")

// Ctrl-C / `kill` should take the socket file with them. (A crash won't get the chance — that's what
// `SocketServer`'s stale-socket handling is for.) `SIG_IGN` first: the default disposition still fires
// before a `DispatchSourceSignal` gets a look in.
let shutdownSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated {
            log("shutting down")
            server.stop()
        }
        exit(0)
    }
    source.resume()
    return source
}

// The app's run loop: it services the main dispatch queue (where the socket server hops to reach the
// Runtime), the display link, and — from M3 — the AX observers. `withExtendedLifetime` keeps the
// signal sources alive: a released `DispatchSourceSignal` stops delivering.
withExtendedLifetime(shutdownSources) {
    app.run()
}
