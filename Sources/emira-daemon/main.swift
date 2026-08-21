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

/// The attached displays as the core will know them — **read once, and this value is what every side
/// gets.** It builds this process's overlays and guide panels, and it is the `screensChanged`
/// dispatched at adoption; `NSScreen.visibleFrame` is live, so reading it a second time there would let
/// a Dock that moved in between inset the cover by one number and the strip by another. Adoption can be
/// held back for as long as a broken config file takes to fix, which is how far apart the two reads can
/// drift.
///
/// That shared number is load-bearing per display: the core lays that display's strip out inside its
/// working area and its cover paints exactly that working area, so the chrome bands a cover leaves
/// alone can never contain a window it should have hidden.
let bootDisplays = AttachedDisplays.current()
if bootDisplays.screens.isEmpty {
    die("No displays are attached — there is nothing to manage.")
}

/// Everything built per display, keyed by the id all of it is named by. **Rebuilt rather than
/// adjusted:** an overlay's window frame, its base placement and its backing scale are all fixed at
/// construction, so a display whose geometry moved gets a new one and the old one is retired.
struct DisplayParts {
    /// What this was built against — the equality that decides whether it can be kept.
    let info: MonitorInfo
    let overlay: Overlay
    let reconstruction: Reconstruction
    let capturer: SCKCapturer
    let panel: GuidePanel
    let guide: Guide
}

/// The live per-display machinery. Read by `on(_:)`, `applyShellConfig` and `onStateChanged`, all of
/// which run after `syncDisplays` has filled it.
var parts: [MonitorId: DisplayParts] = [:]

/// The flip line the current parts were built against. It is the primary display's height, so a new
/// primary — or a resolution change on it — moves it, and *every* overlay window frame derives from
/// it. `nan` compares unequal to anything, which is what makes the boot build unconditional.
var partsFlipHeight: Double = .nan

/// The last display reading. `startManaging` dispatches this rather than the boot one, so a config
/// broken for long enough to outlast a hot-plug still adopts the desktop that is actually there.
var currentDisplays = bootDisplays

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

/// The trackpad's tap, and the same probe on the other input: install it, keep the answer, take it
/// straight back down. Accessibility already covers the tap and boot gates on it
/// (`OnboardingWindow.gate`), so this should always succeed — a defensive branch of exactly the kind
/// `observesPointerMotion` documents itself as, and the capability `mouse.trackpad-scroll` is clamped
/// against. The standing idle cost the probe avoids is real: the tap fires for every finger on the pad.
let gestureTap = CGGestureTap()
let canTapGestures = gestureTap.install { _ in }
gestureTap.remove()

// One `FocusIntent` too, for the same reason and on the other axis: the writer records the focus it
// asks for and the watcher reads that record to tell our own echo from the user's Cmd-Tab.
let focusIntent = FocusIntent(scheduler: DispatchScheduler())

// One cache for the daemon's life: it outlives every cover, which is the whole of what it is for.
let surfaceCache = SurfaceCache()

/// The two containers the per-display machinery is handed to. Both start empty and are filled by
/// `syncDisplays` — at launch and on every reconfiguration — so that everything holding *them* (the
/// executor, the runtime) is wired once and never rebuilt.
///
/// The `Compositor` owns the `CATransaction` rather than each surface: two displays blitting inside
/// two transactions are two frames, and the strips on them shear apart by a refresh.
let capture = CaptureService(registry: registry, capturers: [], scheduler: DispatchScheduler(),
                             cache: surfaceCache)
let compositor = Compositor(surfaces: [])

/// A display can leave between macOS reporting the reconfiguration and anything acting on it, and a
/// departed display's capturer can produce no base at all while its overlay fences a raise on a
/// display link for a screen that is gone. Both would degrade every transition on every remaining
/// screen rather than costing the display that left, so both consult this and leave it out.
///
/// Read live rather than cached: this answers a question about *right now*, and `syncDisplays` runs a
/// notification later.
capture.isAttached = { ScreenGeometry.attached().contains($0) }
compositor.isAttached = { ScreenGeometry.attached().contains($0) }

/// Watches for reconfigurations. A source, so it reports the new display set and nothing more; what
/// the daemon does about it is `syncDisplays` plus one `Event.screensChanged`.
let screenWatcher = ScreenWatcher()

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
    // **Last, and that position is load-bearing**: this reads the *post-clamp* transition mode, so a
    // machine with no Screen Recording grant cannot keep a live gesture with no cover to run it under.
    // The strip follows the hand on the presentation plane — a window cannot be moved at 120 Hz — so
    // without captured pixels there is nowhere for the scroll to happen. One clamp feeding another is
    // new in this function, and it is why the trackpad line is here rather than beside the grant check
    // it depends on.
    if !config.transitionMode.covers || !canTapGestures { config.trackpadScroll = .off }
    return config
}

var config = applyEnvironment(to: parsedConfig)
// So a user who asked for something this machine cannot do is told, once — and told *which* settings,
// since one machine can lose both (no motion monitor) or only the first (no cursor property). One line
// rather than one per setting: they have one cause between them and a list reads as one fact.
let clamped = [("mouse: hide", parsedConfig.hidesCursor && !config.hidesCursor),
               ("focus: follows-mouse",
                parsedConfig.focusFollowsMouse && !config.focusFollowsMouse),
               ("mouse: trackpad-scroll",
                parsedConfig.trackpadScroll.isLive && !config.trackpadScroll.isLive)]
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
// the raise, but the capture batch before it is time the user waits through. Stitched together below,
// and kept per display: two covers are two transitions, and one number for both describes neither.
var captureHeadMs: [MonitorId: Double] = [:]

/// Which display a line is about, or nothing at all while there is only one to be about. Asked per
/// line rather than answered once: displays come and go under a running daemon.
@MainActor func on(_ monitor: MonitorId) -> String {
    parts.count > 1 ? " [display \(monitor.raw)]" : ""
}

capture.onBatchResolved = { report in
    // The head is when the batch stopped blocking the raise, not when it finished; under
    // `CoverMode.immediate` those are different numbers.
    if report.isHead { captureHeadMs[report.monitor] = (report.gate ?? report.elapsed) * 1000 }
    log(String(format: "capture:%@ %@%d window%@ — raise at %@, done at %.0f ms%@%@%@",
               on(report.monitor),
               report.isHead ? "" : "+", report.windows, report.windows == 1 ? "" : "s",
               report.gate.map { String(format: "%.0f ms", $0 * 1000) } ?? "never",
               report.elapsed * 1000,
               report.base.map { String(format: " (base %.0f ms)", $0 * 1000) } ?? "",
               // Matched, over built-from: the two differing is a cover that came out exact anyway.
               report.stoodIn > 0 ? " (\(report.standing)/\(report.stoodIn) standing)" : "",
               report.missing > 0 ? " (\(report.missing) missing)" : "")
        + (report.timedOut ? " — DEADLINE" : ""))
}

executor.onCoverDismissed = { monitor, frames, seconds in
    let head = captureHeadMs[monitor] ?? 0
    log(String(format: "transition:%@ %d frames in %.0f ms (%.0f fps); %.0f ms capture head → %.0f ms",
               on(monitor), frames, seconds * 1000, Double(frames) / max(seconds, 0.001),
               head, head + seconds * 1000))
}

/// One clock, on the **fastest** display attached (`AttachedDisplays.fastest`). Named rather than
/// built inline because it is re-homed on every reconfiguration: the fastest display can change or be
/// unplugged, and a `CADisplayLink` for a screen that has gone never fires again.
let clock = DisplayLinkDriver(screen: bootDisplays.fastest ?? bootDisplays.screens[0])

let runtime = Runtime(
    state: State(config: config),
    executor: executor,
    clock: clock,
    // An AX write's landing depends on another process's run loop; this bounds the wait.
    hold: DispatchHoldTimer())

// Once per drain, not once per event, and one closure for both peripherals: they display state rather
// than change it, and a per-event observer would show them states the user never sees. `MenuBarItem`
// diffs and `Guide` diffs its own trigger, so a scroll costs neither of them a redraw.
/// The acting display's address for the title, the rest for the tooltip — `shownWorkspaces` is already
/// acting-monitor-first, which is the order both want.
@MainActor func showWorkspaces(_ state: State) {
    let shown = state.monitors.shownWorkspaces
    menuBar.setWorkspaces(state.monitors.shown, elsewhere: Array(shown.dropFirst()))
}

showWorkspaces(runtime.state)
runtime.onStateChanged = { state in
    showWorkspaces(state)
    for entry in parts.values { entry.guide.stateChanged(state) }
}

//
// A source, not a consequence of state changing, so it is wired here rather than driven by an
// `Effect`. A press produces the same `Event.command` value `emira focus left` sends over the socket.

// Logged here because a keypress that correctly changes nothing looks exactly like a chord that
// never registered, and the keyboard leaves no other trace.
// Two registries, because `fn` is not in the system one's vocabulary at any width.
let hotkeys = HotkeyManager(
    binder: SplitHotkeyBinder(carbon: CarbonHotkeyBinder(), function: FunctionKeyTap()),
    sink: EventSink { event in
        if case .command(let command) = event {
            log("key: \(command.words.joined(separator: " "))")
        }
        runtime.sink(event)
    })

// The other intent source, and the same wrapping for the same reason: a gesture that correctly changes
// nothing looks exactly like one that never registered, and the trackpad leaves no other trace. The
// edges only — the stream between them is one event per painted frame, and logging that is a log nobody
// can read.
let gestures = GestureRecognizer(tapper: gestureTap, scheduler: DispatchScheduler(),
                                 sink: EventSink { event in
    switch event {
    case .trackpadScrollBegan:
        log("trackpad: scroll began")
    case .trackpadScrollEnded(let velocity):
        log(String(format: "trackpad: scroll ended at %+.2f pads/s", velocity))
    default:
        break
    }
    runtime.sink(event)
})

// The frame boundary, ahead of that frame's tick. Two lines and no coupling inside either type: the
// trackpad is not phase-locked to the display, and what the core wants is one write per painted frame.
clock.onFrame = { [gestures] in gestures.drain() }

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
    for entry in parts.values { entry.reconstruction.animation = config.windowAnimation }
    capture.mode = config.coverMode
    executor.transitionMode = config.transitionMode
    // The pointer's rung, for the same reason as `windowAnimation` above it: the core emits the same
    // warp under all three, and the position the upper two decide against is only readable out here.
    pointer.recentres = config.mouseFollowsFocus.recentres
    // Two features want the stills a cover leaves behind and neither is the other's: `immediate` raises
    // over them, `preview` draws the guide's tiles from them. Either is reason enough to keep them.
    let keepsStills = config.coverMode == .immediate
        || (config.guide.preview.enabled && config.guide.preview.content == .stills)
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
    // The desk's other standing idle cost, gated the same way and for the same stated reason: the tap
    // fires for every finger on the pad, including one moving the cursor, so it is not installed for a
    // setting nobody turned on. `applyEnvironment` has already clamped this against the cover.
    gestures.observe(config.trackpadScroll.isLive)
}

applyShellConfig(config)

//
// Hot-plug: one of every display-shaped thing, per display, reconciled against what is attached.
// Defined here for `applyShellConfig`'s reason — it reaches `runtime` and `config`, both of which are
// initialized above it, and a top-level function that reached a global below it would read zeroed
// memory if it were ever called early.

/// Build everything one display needs. `index` is only for `ScreenGeometry.displayId`, which falls
/// back to the enumeration position for a screen AppKit gives no number.
@MainActor func buildDisplay(_ info: MonitorInfo, _ screen: NSScreen, at index: Int,
                             in geometry: ScreenGeometry) -> DisplayParts {
    let overlay = Overlay(screen: screen, geometry: geometry, insets: info.struts)
    let panel = GuidePanel(screen: screen, geometry: geometry, insets: info.struts)
    let guide = Guide(panel: panel, monitor: info.id, icons: GuideIcons(), names: GuideNames(),
                      scheduler: DispatchScheduler(),
                      // A `preview` tile draws whatever a cover last left behind, at any size — see
                      // `SurfaceCache.anySurface(for:)`. A window nothing has filmed falls back to
                      // its icon.
                      still: { [surfaceCache] id in surfaceCache.anySurface(for: id)?.image })
    // Primed, not shown: a guide's first reaction should be what the desktop does next, not the fact
    // that it has just been built. At launch that is the boot scan's arrivals; on a hot-plug it is
    // whatever the user does after plugging the display in.
    guide.prime(runtime.state)
    return DisplayParts(
        info: info,
        overlay: overlay,
        reconstruction: Reconstruction(overlay: overlay, monitor: info.id, store: capture),
        capturer: SCKCapturer(displayId: ScreenGeometry.displayId(of: screen, at: index),
                              scale: screen.backingScaleFactor),
        panel: panel,
        guide: guide)
}

/// Match the per-display machinery to what is attached: keep what still describes its display, build
/// what does not, retire the rest, and hand the result to the two containers that route by display.
///
/// **Kept only on exact geometry**, because everything here is fixed at construction — a window frame,
/// a base placement, a backing scale, a `CGDirectDisplayID` to film from. A display that merely
/// changed resolution is as new as one just plugged in, and the flip line moving makes *every* display
/// new, since every overlay frame is measured from it.
@MainActor func syncDisplays(_ displays: AttachedDisplays) {
    currentDisplays = displays
    let flipped = displays.geometry.flipHeight != partsFlipHeight
    partsFlipHeight = displays.geometry.flipHeight

    var next: [MonitorId: DisplayParts] = [:]
    for (index, info) in displays.monitors.enumerated() {
        if !flipped, let kept = parts[info.id], kept.info == info {
            next[info.id] = kept
            continue
        }
        parts[info.id].map(retireDisplay)
        next[info.id] = buildDisplay(info, displays.screens[index], at: index,
                                     in: displays.geometry)
    }
    for (id, gone) in parts where next[id] == nil { retireDisplay(gone) }
    parts = next

    compositor.setSurfaces(parts.map { ($0.key, $0.value.reconstruction as any CoverSurface) })
    capture.setCapturers(parts.map { ($0.key, $0.value.capturer as any SurfaceCapturer) })
    if let fastest = displays.fastest { clock.retarget(to: fastest) }
    for entry in parts.values { entry.reconstruction.animation = config.windowAnimation }
}

/// Take one display's machinery off the screen. Instant on both windows: a reconfiguration is not
/// something to fade through, and the replacement is going up in the same turn.
@MainActor func retireDisplay(_ gone: DisplayParts) {
    gone.overlay.retire()
    gone.panel.retire()
}

syncDisplays(bootDisplays)

// The core is told *first*: `screensChanged` closes every cover, so each dismissal reaches the surface
// that raised it rather than one already replaced. Only then are the surfaces swapped.
screenWatcher.onChange = { displays in
    log("displays: \(displays.monitors.map { "\($0.id.raw)" }.joined(separator: ", "))")
    runtime.dispatch(.screensChanged(displays.monitors))
    // Kept stills describe the desktop that just stopped existing, and the only thing standing between
    // one and the next cover is a size match against a working area that has now moved.
    capture.forgetKeptStills()
    syncDisplays(displays)
}
screenWatcher.start()

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
    runtime.dispatch(.screensChanged(currentDisplays.monitors))
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
    // The settings window, if one is up, so an edit made elsewhere does not get clobbered by a draft
    // that never saw it. It tells its own save from a foreign edit itself — this only says "the file
    // moved".
    menuBar.configFileChanged()
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
    screenWatcher.stop()    // …and a display change mid-cascade stops re-placing the strip too
    // Directly, not through `Teardown`: that takes the truth executor and emits only
    // `setFrame`/`raise`/`focus`, and quitting is the one moment there is no next command to unhide on.
    pointer.restoreCursor()
    hotkeys.stop()
    gestures.stop()         // a live tap outliving the daemon is a leak nothing else surfaces
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

// **Hotkeys are suspended while the settings window is up.** `RegisterEventHotKey` claims a chord at the
// window server, so a binding fires whatever is focused: with every display scrimmed, a stray chord
// would rearrange a desktop the user cannot see, and a bound `⌘A` would never reach a numeric field.
// `apply` is the same call a reload makes, so resuming is just re-applying what the config says.
menuBar.onSettingsVisible = { visible in
    if visible { hotkeys.suspend() } else { hotkeys.resume() }
}

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
