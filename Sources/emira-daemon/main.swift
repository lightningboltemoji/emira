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

//
// Answered before anything else exists, because it is the whole of this process: `--probe-capture` is how
// a *running* daemon finds out whether Screen Recording has been granted since it started, which its own
// preflight can no longer tell it (`Permissions.probeScreenRecording`). One read, one exit code, no
// `NSApplication`.
//
// Anything else *fails* rather than falling through, because the fall-through is a window manager that
// adopts the whole desktop — a lot to get from a typo.

switch Array(CommandLine.arguments.dropFirst()) {
case []:
    break
case [Permissions.captureProbeFlag]:
    exit(Permissions.screenRecording.isGranted ? 0 : 1)
case let unexpected:
    FileHandle.standardError.write(Data(
        ("emira-daemon: unexpected \(unexpected.joined(separator: " ")) — the only argument is "
            + "\(Permissions.captureProbeFlag)\n").utf8))
    exit(2)
}

/// A peer vanishing mid-reply must be a failed `write`, never a signal that kills the daemon.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

/// Die, having said why somewhere the user is looking: launched from `emira.app` nobody reads stderr,
/// so when bundled the message is also an alert.
@MainActor func die(_ message: String) -> Never {
    log(message)
    if LoginItem.isBundled {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "emira can't start"
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        app.activate()
        alert.runModal()
    }
    exit(1)
}

//
// Must be read *before* the grant checks below: whether Screen Recording is required depends on
// whether the user asked for the cover at all (`transition`).

let loader = ConfigLoader(path: Config.defaultPath(),
                          watcher: ConfigWatcher(watching: Config.defaultPath()),
                          scheduler: DispatchScheduler())

/// The config as the file spells it, before `applyEnvironment`. Kept separate because the grant check
/// below reads the user's *intent*.
var parsedConfig: Config
/// The boot diagnostic, held until there is a menu bar item to show it on. It is also the bit that
/// decides whether emira manages anything at all — see `startManaging`.
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
    log("config: \(error) — not managing windows until it parses")
}

//
// Both grants are required to start; only Accessibility is required to keep running — without it
// every AX read returns nothing *without an error*. Screen Recording is demanded only when the config
// asked for the cover, and a running daemon degrades rather than dies when macOS revokes it.
//
// `gate` holds boot until they are in, so everything below may assume it. It returns `.restart` whenever
// it had to open a window: a grant given to a *running* emira is only half a grant, and the next launch
// has the whole of it.

// A file we couldn't parse is a file whose intent we don't have, so both grants are asked for rather
// than the ones a `Config()` we invented happens to want: the config the user is about to fix may well
// ask for the cover, and a grant is the one thing a later reload cannot go back and collect.
let onboarding = OnboardingModel.live(
    wantsCover: bootConfigError != nil || parsedConfig.transitionMode.covers)
if !onboarding.isSatisfied {
    log("waiting for \(onboarding.missing.joined(separator: ", "))")
}

switch OnboardingWindow.gate(onboarding) {
case .granted:
    break

case .restart(let missing):
    log(missing.isEmpty
        ? "grants in place — quitting so the next launch starts with them"
        : "onboarding closed without \(missing.joined(separator: ", ")) — quitting")
    exit(0)
}

let screens = NSScreen.screens
if screens.isEmpty {
    die("No displays are attached — there is nothing to manage.")
}
let geometry = ScreenGeometry.current()

/// The attached displays as the core will know them — **read once, and this array is what both sides
/// get.** It builds this process's overlays and guide panels below, and it is the `screensChanged`
/// dispatched at adoption; `NSScreen.visibleFrame` is live, so reading it a second time there would let
/// a Dock that moved in between inset the cover by one number and the strip by another. Adoption can be
/// held back for as long as a broken config file takes to fix, which is how far apart the two reads can
/// drift.
///
/// That shared number is load-bearing per display: the core lays that display's strip out inside its
/// working area and its cover paints exactly that working area, so the chrome bands a cover leaves
/// alone can never contain a window it should have hidden.
let monitorInfos = geometry.monitors(screens)

/// Every attached display, paired with the `MonitorId` the core knows it by. **The id is the same one
/// `ScreenGeometry.monitors` reports**, so a screen the shell builds an overlay for and a monitor the
/// core lays a strip out on are the same thing named twice, never two things that happen to line up.
let displays: [(monitor: MonitorId, screen: NSScreen, struts: EdgeInsets)] =
    zip(monitorInfos, screens).map { info, screen in
        (info.id, screen, info.struts)
    }

/// One overlay per display, each with its own struts and backing scale. `Overlay`'s own doc comment
/// has said "one per display" since it was written; this is that, finally.
let overlays = displays.map { display in
    (monitor: display.monitor,
     overlay: Overlay(screen: display.screen, geometry: geometry, insets: display.struts))
}

// The truth plane's machinery
//
// One `AXClient` for the whole daemon: the per-app lanes are only serial if the enumerator, the
// writer and the observers all queue onto the same ones.

let registry = WindowRegistry()
let axClient = AXClient()

// Both built here, and the pointer's monitor probed here, because `applyEnvironment` clamps the two
// `[mouse]`/`[focus]` pointer settings against what they can do, and the config has to be finished
// before anything reads it.
let observation = AXObservationSource(client: axClient, registry: registry)
/// Whether the pointer's **motion** can be observed at all. Both pointer settings rest on that one
/// monitor, for different reasons: hiding, because the only exit from a hidden pointer is seeing the
/// mouse move; hover, because a crossing is a thing you can only detect in samples.
///
/// Probed by installing the real monitor and taking it straight back down, not by asking the button
/// monitor whether *it* installed: buttons answer a different question, and the setting this gates is
/// the one whose failure mode is a desktop with no cursor and no way to get one. The idle cost that
/// keeps motion unobserved by default is paid once, at boot, rather than for the life of the process.
///
/// Honestly a **defensive branch rather than a machine anyone has met** — mouse masks need no grant
/// beyond the one boot already demands, and no macOS is known where the installer answers nil. Read
/// because a nullable return is not to be waved through, but not a capability the way `canHideCursor`
/// and the Screen Recording grant are, both of which are routinely absent.
let observesPointerMotion = observation.observePointerMotion(true)
observation.observePointerMotion(false)
let pointer = PointerExecutor(surface: SystemCursor())

// One `FocusIntent` too, for the same reason and on the other axis: the writer records the focus it
// asks for and the watcher reads that record to tell our own echo from the user's Cmd-Tab.
let focusIntent = FocusIntent(scheduler: DispatchScheduler())

// One cache for the daemon's life: it outlives every cover, which is the whole of what it is for.
let surfaceCache = SurfaceCache()
// One capturer per display: a base is a photograph of one screen. The window stills come from the
// first, at its backing scale — `SCContentFilter(desktopIndependentWindow:)` is display-independent,
// so a window is filmed once however many screens are covered.
let capture = CaptureService(
    registry: registry,
    capturers: displays.enumerated().map { index, display in
        (display.monitor,
         SCKCapturer(displayId: ScreenGeometry.displayId(of: display.screen, at: index),
                     scale: display.screen.backingScaleFactor) as any SurfaceCapturer)
    },
    scheduler: DispatchScheduler(),
    cache: surfaceCache)

/// One reconstruction per overlay, and the `Compositor` that drives them as one plane. The
/// `CATransaction` lives up there rather than in each surface: two displays blitting inside two
/// transactions are two frames, and the strips on them shear apart by a refresh.
let reconstructions = overlays.map { entry in
    (monitor: entry.monitor,
     reconstruction: Reconstruction(overlay: entry.overlay, monitor: entry.monitor, store: capture))
}
let compositor = Compositor(surfaces: reconstructions.map { ($0.monitor, $0.reconstruction) })

/// Hot-plug is not handled — no overlay, capturer or guide is built for a display that arrives after
/// launch — but a display that *leaves* must not take the whole presentation plane with it. Its
/// capturer can produce no base, and a head batch owing one abandons the cover; its overlay fences a
/// raise on a display link for a screen that is gone. Both would degrade every transition on every
/// remaining screen, for the rest of the session, rather than costing the display that left.
///
/// Read live rather than cached: nothing tells the daemon that the display list changed.
capture.isAttached = { ScreenGeometry.attached().contains($0) }
compositor.isAttached = { ScreenGeometry.attached().contains($0) }

//
// One guide per display, each drawing whatever workspace *its* monitor is showing — the core's own
// projection at another scale, so a display showing an empty address draws nothing at all.

let guides = displays.map { display in
    Guide(panel: GuidePanel(screen: display.screen, geometry: geometry, insets: display.struts),
          monitor: display.monitor,
          icons: GuideIcons(),
          scheduler: DispatchScheduler(),
          // A `preview` tile draws whatever a cover last left behind, at any size — see
          // `SurfaceCache.anySurface(for:)`. A window nothing has filmed falls back to its icon.
          still: { [surfaceCache] id in surfaceCache.anySurface(for: id)?.image })
}

// The config, finished

/// Whether hiding the pointer is reachable on this machine at all: the mechanism has to be there, and
/// the pointer's motion has to be observable. Read once — neither answer changes while the process runs.
let canHidePointer = pointer.canHideCursor && observesPointerMotion

/// The values a config file may not decide: the Screen Recording grant and the two settings that need
/// the pointer, all three capabilities rather than preferences. Re-applied on every reload, which is
/// what notices macOS revoking the grant.
///
/// The struts are *not* here: they are per display and they move under a running daemon (the Dock
/// changes edge), so they ride on `Event.screensChanged` beside the frame they inset, where each
/// display's overlay reads the same number the core lays that display's strip out with.
func applyEnvironment(to config: Config) -> Config {
    var config = config
    // The whole ladder above `off`, not just `smooth`: a cover is captured pixels under either, so `snap`
    // needs the grant exactly as much. What runs under the cover is the core's own arithmetic and free.
    if !Permissions.screenRecording.isGranted { config.transitionMode = .off }
    // The interesting conjunct is `observesPointerMotion`: emira only hides the pointer because it can
    // see the motion that brings it back, so no monitor means no hide — better than any timeout, which
    // would also unhide on someone who is merely reading.
    if !canHidePointer { config.hidesCursor = false }
    // The same monitor, the other dependent. Nothing unsafe follows from leaving this on — a crossing
    // simply never arrives — which is exactly why it is clamped rather than left: a setting that
    // silently does nothing is the failure this philosophy refuses everywhere else.
    if !observesPointerMotion { config.focusFollowsMouse = false }
    return config
}

var config = applyEnvironment(to: parsedConfig)
// So a user who asked for something this machine cannot do is told, once — and told *which* settings,
// since one machine can lose both (no motion monitor) or only the first (no cursor property). One line
// rather than one per setting: they have one cause between them and a list reads as one fact.
let clamped = [("mouse: hide", parsedConfig.hidesCursor && !config.hidesCursor),
               ("focus: follows-mouse",
                parsedConfig.focusFollowsMouse && !config.focusFollowsMouse)]
    .filter(\.1).map(\.0)
if !clamped.isEmpty {
    log("\(clamped.joined(separator: ", ")) — not available on this system, and off for this run")
}

//
// Created before the pump so a config already broken at boot has somewhere to say so.

let menuBar = MenuBarItem(configPath: loader.path)
menuBar.configStatus = bootConfigError.map { .neverLoaded($0) } ?? .loaded
menuBar.onError = { log($0) }

let truth = AXExecutor(registry: registry,
                       writer: AXWindowWriter(client: axClient, intent: focusIntent))

// The system plane. Only failures are reported: both surfaces already log the request, so what a log
// line adds is whether it worked — and a keybind that silently does nothing is the failure this
// feature invites, since a bundled daemon inherits launchd's bare PATH and not the user's.
let launcher = ShellLauncher()
launcher.onOutcome = { log("exec: \($0)") }

let executor = CompositingExecutor(surface: compositor, store: capture, truth: truth,
                                   pointer: pointer, launcher: launcher)

// A transition's latency has two halves and neither subsystem sees the other: frames are counted from
// the raise, but the capture batch before it is time the user waits through. Stitched together below.
var captureHeadMs = 0.0

capture.onBatchResolved = { report in
    // The head is when the batch stopped blocking the raise, not when it finished; under
    // `CoverMode.immediate` those are different numbers.
    if report.isHead { captureHeadMs = (report.gate ?? report.elapsed) * 1000 }
    log(String(format: "capture: %@%d window%@ — raise at %@, done at %.0f ms%@%@%@",
               report.isHead ? "" : "+", report.windows, report.windows == 1 ? "" : "s",
               report.gate.map { String(format: "%.0f ms", $0 * 1000) } ?? "never",
               report.elapsed * 1000,
               report.base.map { String(format: " (base %.0f ms)", $0 * 1000) } ?? "",
               // Matched, over built-from: the two differing is a cover that came out exact anyway.
               report.stoodIn > 0 ? " (\(report.standing)/\(report.stoodIn) standing)" : "",
               report.missing > 0 ? " (\(report.missing) missing)" : "")
        + (report.timedOut ? " — DEADLINE" : ""))
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
    // One clock, on the **fastest** display attached. `dt` is real elapsed time and the springs are
    // analytic in it, so a 60 Hz screen fed at 120 Hz simply drops frames while a 120 Hz one fed at
    // 60 Hz is visibly under-driven — picking the fastest means nobody is ever the latter.
    clock: DisplayLinkDriver(screen: screens.max { $0.maximumFramesPerSecond
                                                    < $1.maximumFramesPerSecond } ?? screens[0]),
    // An AX write's landing depends on another process's run loop; this bounds the wait.
    hold: DispatchHoldTimer())

// Once per drain, not once per event, and one closure for both peripherals: they display state rather
// than change it, and a per-event observer would show them states the user never sees. `MenuBarItem`
// diffs and `Guide` diffs its own trigger, so a scroll costs neither of them a redraw.
menuBar.workspace = runtime.state.monitors.shown
// Primed, not shown: a guide's first reaction should be the boot scan's arrivals, not its own birth.
for guide in guides { guide.prime(runtime.state) }
runtime.onStateChanged = { state in
    menuBar.workspace = state.monitors.shown
    for guide in guides { guide.stateChanged(state) }
}

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

// The keyboard waits on the config for the same reason the desktop does (`startManaging`): the
// bindings a broken file asks for are exactly the part we cannot read, and binding the empty set in
// their place would report the keyboard's silence as something the user chose.
if bootConfigError == nil { applyKeys(config) }

//
// Launch is just events: `screensChanged`, then one `windowCreated` per window — the same path every
// later observation takes as the user opens, closes, drags and Cmd-Tabs. *When* launch is, though, is
// the config file's to say — see `startManaging`.

let watcher = WorldWatcher(
    source: observation,
    enumerator: AXEnumerator(source: AXWindowSource(client: axClient), registry: registry),
    registry: registry,
    scheduler: DispatchScheduler(),
    intent: focusIntent,
    sink: runtime.sink,
    heartbeat: DispatchHeartbeat())

// A scan that gave up leaves a window simply unmanaged, with nothing else to say so.
watcher.onIncompleteScan = { report in
    log("scan gave up: \(report.summary)")
}

// The pointer plane's read direction: two consumers of the same samples, neither of which the watcher
// owns. Wired here because nothing owns anything else — the shape `capture.onBatchResolved` and
// `executor.onCoverDismissed` have.
//
// `PointerFocus` holds a `() -> State` reader, which the watcher deliberately does not; `PointerWake`
// holds the threshold that answers a hide. The hide arms the wake, so the anchor is taken at the moment
// the cursor goes.
let pointerFocus = PointerFocus(state: { runtime.state }, sink: runtime.sink)
let pointerWake = PointerWake(sink: runtime.sink)
pointer.onCursorHidden = { [pointerWake] hidden in pointerWake.setArmed(hidden) }

// Through `PointerSamples` rather than closures calling both: focus must read a sample before the wake
// clears the flag it reads, and an ordering rule that matters belongs beside the two types it orders
// rather than in a wiring line nothing can test. It takes the other direction too — a warp moves the
// cursor without the user touching it, so both readers are measuring against a place it no longer is.
let pointerSamples = PointerSamples(focus: pointerFocus, wake: pointerWake)
watcher.onPointerMoved = { [pointerSamples] point in pointerSamples.pointerMoved(to: point) }
pointer.onWarp = { [pointerSamples] point in pointerSamples.pointerWarped(to: point) }

/// The config values that reach the shell rather than the reducer — the core's emitted geometry is
/// identical under every setting of them. One function, called at boot and again on every reload, so
/// that the shell and the reducer read the same post-`applyEnvironment` value by construction.
///
/// Defined *below* everything it writes to, deliberately. Top-level `let`s in `main.swift` are
/// initialized in execution order and are not lazy, so a function up here that reached a global down
/// there would compile clean and read zeroed memory if it were ever called early. Keeping the
/// definition after the last thing it touches makes that unrepresentable rather than merely avoided.
@MainActor func applyShellConfig(_ config: Config) {
    for entry in reconstructions { entry.reconstruction.animation = config.windowAnimation }
    capture.mode = config.coverMode
    executor.transitionMode = config.transitionMode
    // The pointer's rung, for the same reason as `windowAnimation` above it: the core emits the same
    // warp under all three, and the position the upper two decide against is only readable out here.
    pointer.recentres = config.mouseFollowsFocus.recentres
    // Two features want the stills a cover leaves behind and neither is the other's: `immediate` raises
    // over them, `preview` draws the guide's tiles from them. Either is reason enough to keep them.
    let keepsStills = config.coverMode == .immediate || config.guide.style == .preview
    capture.keepsStills = keepsStills
    // Wanted by nobody now, so the stills already kept retire rather than sitting there until the byte
    // budget collects them. A no-op at boot, where there is nothing kept yet.
    if !keepsStills { surfaceCache.removeAll() }
    // The pointer's samples, and the only observation in the daemon with a standing idle cost: the
    // monitor fires at the pointer's rate for as long as it is installed. Two settings want it and
    // neither is the other's — hiding, because the only exit from a hidden pointer is seeing the mouse
    // move; hover, because a crossing is a thing you can only detect in samples — so it is installed
    // for either and taken down for neither. With both off, which is the default, emira observes the
    // mouse's buttons and not its motion.
    observation.observePointerMotion(config.focusFollowsMouse || config.hidesCursor)
    // …and the second reader still asks per sample whether it is wanted, because the first setting can
    // keep the samples flowing on its own.
    pointerFocus.isEnabled = config.focusFollowsMouse
}

applyShellConfig(config)

/// Whether the desktop has been adopted. A latch: adoption happens once, and the only open question
/// is when.
var isManaging = false

/// Adopt the desktop — the boot scan, and every observation after it.
///
/// Held back when the config file is already broken at launch, and started by the first save that
/// makes it parse. A broken *reload* has the settings from before it broke to carry on with, which is
/// why it changes nothing; a broken boot has nothing behind it, and the defaults emira would otherwise
/// adopt the desktop under are settings nobody chose — every window snapped onto a gapless, full-width
/// strip, with none of the user's own keys bound to undo it and no way to tell that apart from emira
/// working as intended. So it waits, says so in the menu bar, and leaves the desktop as it found it.
@MainActor func startManaging() {
    guard !isManaging else { return }
    isManaging = true
    runtime.dispatch(.screensChanged(monitorInfos))
    // Each app is scanned on its own AX lane, so boot costs the slowest app, not the sum. The report
    // lands back on the main actor after its windows have already been dispatched and placed.
    watcher.start { report in
        log("enumerated \(report.summary)")
        log("managing \(runtime.state.layout.columns.count) columns on workspace "
            + "\(runtime.state.monitors.shown) of \(runtime.state.workspaces.materialized.count), "
            + "\(runtime.state.world.monitors.count) display(s)")
    }
}

if bootConfigError == nil { startManaging() }

//
// Only a successful parse becomes an event. The three subsystems told separately — reducer, hotkeys,
// shell — must all read the *same* post-`applyEnvironment` value.

loader.onLoad = { result in
    switch result {
    case .success(let parsed):
        let live = applyEnvironment(to: parsed)
        log("config: reloaded \(loader.path)")
        runtime.dispatch(.configChanged(live))
        applyKeys(live)
        applyShellConfig(live)
        menuBar.configStatus = .loaded
        // The parse a held emira has been waiting for. Last, so the boot scan places windows against a
        // core that already holds the config it was waiting for; the latch makes every later one an
        // ordinary reload.
        startManaging()
    case .failure(let error):
        // A failed reload is otherwise silent, so the menu bar is the only signal the edit did
        // nothing. A held emira stays held and says so: there are still no settings behind the file.
        if isManaging {
            log("config: \(error) — keeping the previous settings")
            menuBar.configStatus = .broken("\(error)")
        } else {
            log("config: \(error) — still not managing windows")
            menuBar.configStatus = .neverLoaded("\(error)")
        }
    }
}
loader.start()

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
    // Directly, not through `Teardown`: that takes the truth executor and emits only
    // `setFrame`/`raise`/`focus`, and quitting is the one moment there is no next command to unhide on.
    pointer.restoreCursor()
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
