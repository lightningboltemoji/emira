import AppKit
import ApplicationServices
import EmiraCore
import Foundation

// `ObservationSource` against the real system. Three sources, each knowing something the others don't:
//
//  · `AXObserver`, per app — the only thing that reports windows, registered against *two* different
//    elements: AX delivers window creation and in-app focus changes only for registrations made on the
//    application element, and destruction/movement/miniaturization only for registrations made on the
//    window element. Registering the window set on the app element silently delivers nothing.
//  · `NSWorkspace` — the only thing that reports apps launching, terminating, activating. AX cannot
//    speak for a process that has no observer yet, which is every process the moment it starts.
//  · A global mouse monitor — the only thing that reports the end of a drag. AX says a window moved,
//    never that the user let go.
//
// Registration is IPC and goes on the app's lane: `AXObserverCreate` and `CFRunLoopAddSource` are local
// and main-thread, but `AXObserverAdd/RemoveNotification` are round trips that answer `.cannotComplete`
// when the app is busy or still starting. Callback *delivery* stays on the main run loop.

// Split by the element they must be registered against.
private enum AXNotification {

    /// Registered on the *application* element.
    static let application = [
        "AXWindowCreated",              // a window was born — which one, only a re-scan can say
        "AXFocusedWindowChanged",       // focus moved between this app's own windows
        "AXMainWindowChanged",          // …or the app's window *set* changed under us (native tabs)
    ]

    /// Registered on each *window* element.
    static let window = [
        "AXUIElementDestroyed",
        "AXWindowMoved",
        "AXWindowResized",
        "AXWindowMiniaturized",
        "AXWindowDeminiaturized",
    ]

    static let windowCreated = "AXWindowCreated"
    static let focusedWindowChanged = "AXFocusedWindowChanged"
    static let mainWindowChanged = "AXMainWindowChanged"
    static let uiElementDestroyed = "AXUIElementDestroyed"
    static let windowMoved = "AXWindowMoved"
    static let windowResized = "AXWindowResized"
    static let windowMiniaturized = "AXWindowMiniaturized"
    static let windowDeminiaturized = "AXWindowDeminiaturized"
}

/// What an `AXObserver` calls, on the run loop its source was added to — the main one.
///
/// The `refcon` is an unretained pointer to the source, which owns every observer that could call this;
/// retaining would be a cycle. The element is wrapped and the `CFString` copied *before* the hop, since
/// neither is `Sendable` and Swift 6 checks the crossing even on one thread.
private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let source = Unmanaged<AXObservationSource>.fromOpaque(refcon).takeUnretainedValue()
    let window = AXWindow(element)
    let name = notification as String
    MainActor.assumeIsolated {
        source.received(name, about: window)
    }
}

/// The facts about an app that a `NSWorkspace` notification carries, extracted as values because
/// `NSRunningApplication` is not `Sendable` and cannot travel into the main-actor hop.
private struct AppFacts: Sendable {
    let pid: pid_t
    let bundleId: String?
    let isRegular: Bool

    init?(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return nil }
        pid = app.processIdentifier
        bundleId = app.bundleIdentifier
        isRegular = app.activationPolicy == .regular
    }

    /// Ours, or a process id the kernel never issued. Neither is an app to manage.
    var isSelfOrInvalid: Bool {
        pid <= 0 || pid == ProcessInfo.processInfo.processIdentifier
    }
}

/// The live `ObservationSource`: per-app `AXObserver`s, `NSWorkspace` notifications, and a global
/// mouse monitor, translated into `WorldObservation`s.
@MainActor
public final class AXObservationSource: ObservationSource {

    /// An `AXObserver` and its callback context, boxed to cross onto an app's lane. Thread-safe by
    /// construction, which Swift cannot see through a C type.
    private struct ObserverHandle: @unchecked Sendable {
        let observer: AXObserver
        let refcon: UnsafeMutableRawPointer
    }

    private let client: AXClient
    private let registry: WindowRegistry

    /// Where observations go. Set by `start`; before that the source is inert.
    private var deliver: (@MainActor (WorldObservation) -> Void)?

    private var observers: [pid_t: AXObserver] = [:]

    /// The window elements currently registered, per app. Kept so registration is idempotent and so a
    /// closing window's notifications can be removed without asking the registry, which by then may have
    /// forgotten it.
    private var watchedWindows: [pid_t: [WindowId: AXWindow]] = [:]

    /// Held only to be released.
    private var workspaceTokens: [any NSObjectProtocol] = []

    /// The two global mouse monitors, and they are two because they are wanted on different terms.
    /// Buttons are always: a mouse-up ends a possible drag, which is a fact about the desktop and
    /// predates the pointer plane. Motion is a *setting*: it fires at the pointer's sample rate, and
    /// nothing wants it unless the pointer plane is switched on.
    private var buttonMonitor: Any?
    private var motionMonitor: Any?

    public init(client: AXClient, registry: WindowRegistry) {
        self.client = client
        self.registry = registry
    }

    // No `deinit` teardown: a `@MainActor` class is `Sendable`, so its `deinit` is nonisolated and may
    // not touch isolated state. The tokens and the mouse monitor capture `self` weakly anyway.

    public func start(_ deliver: @escaping @MainActor (WorldObservation) -> Void) {
        self.deliver = deliver
        observeWorkspace()
        // Buttons are watched whether or not anybody asked: drag-end predates the pointer plane and must
        // not become a thing a call site can forget. Motion is the opposite and is not started here —
        // nothing wants it until a setting does.
        observeMouse()
    }

    public func watch(app target: ScanTarget, then completion: @escaping @MainActor (Bool) -> Void) {
        if observers[target.pid] != nil {
            completion(true)
            return
        }
        var created: AXObserver?
        guard AXObserverCreate(target.pid, axObserverCallback, &created) == .success,
              let observer = created
        else {
            // Usually an app that is still starting; `WorldWatcher` retries.
            completion(false)
            return
        }
        // `.commonModes`, not `.defaultMode`: the main run loop switches modes while a menu or a
        // window-resize loop tracks, and going deaf for that long resumes with a stale world.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[target.pid] = observer

        let handle = ObserverHandle(observer: observer, refcon: selfPointer())
        client.perform(app: target.pid) { application in
            // Every notification attempted, not `allSatisfy`: a short-circuit leaves an app observed for
            // half of what it does, and the retry skips it because an observer exists.
            var ok = true
            for name in AXNotification.application {
                let result = AXObserverAddNotification(
                    handle.observer, application.element, name as CFString, handle.refcon)
                ok = (result == .success) && ok
            }
            return ok
        } then: { [weak self] ok in
            // The observer alone. A refusal is not the app quitting, and only that takes the lane.
            if !ok { self?.dropObserver(of: target.pid) }
            completion(ok)
        }
    }

    public func watch(windows ids: [WindowId], of app: pid_t) {
        guard let observer = observers[app] else { return }
        var fresh: [WindowId: AXWindow] = [:]
        for id in ids where watchedWindows[app]?[id] == nil {
            // `record.pid == app` is not paranoia: a mismatched pair would register a notification on
            // the wrong app's observer and the window would be silently unobservable.
            guard let record = registry.record(id), record.pid == app else { continue }
            fresh[id] = record.element
        }
        guard !fresh.isEmpty else { return }
        watchedWindows[app, default: [:]].merge(fresh) { existing, _ in existing }

        // A failed registration is rolled back so it can be retried: `AXObserverAddNotification` is a
        // round trip and a busy app answers `.cannotComplete`. Leaving `watchedWindows` marked makes that
        // permanent and silent — no `uiElementDestroyed`, so the strip carries an empty slot forever.
        let handle = ObserverHandle(observer: observer, refcon: selfPointer())
        let elements = fresh
        client.perform(app: app) { _ in
            elements.compactMap { id, element in
                // Every notification attempted rather than short-circuiting, as in `watch(app:)`.
                var ok = true
                for name in AXNotification.window {
                    let result = AXObserverAddNotification(
                        handle.observer, element.element, name as CFString, handle.refcon)
                    ok = (result == .success) && ok
                }
                return ok ? nil : id
            }
        } then: { [weak self] failed in
            for id in failed { self?.watchedWindows[app]?[id] = nil }
        }
    }

    public func unwatch(window id: WindowId, of app: pid_t) {
        guard let element = watchedWindows[app]?.removeValue(forKey: id),
              let observer = observers[app]
        else { return }
        let handle = ObserverHandle(observer: observer, refcon: selfPointer())
        client.perform(app: app) { _ in
            // The element is usually already dead and every removal fails, hence the ignored results.
            // The ones that come off keep a long-lived app from accumulating a set per window.
            for name in AXNotification.window {
                _ = AXObserverRemoveNotification(handle.observer, element.element, name as CFString)
            }
        } then: { _ in }
    }

    public func unwatch(app pid: pid_t) {
        dropObserver(of: pid)
        // The one place a lane is dropped: the process is gone, so its application element holds a Mach
        // port to nothing. Dropped for any lesser reason it is worse than kept — work already queued
        // runs on, and the next call mints a second serial queue beside it.
        client.forget(app: pid)
    }

    /// Release an app's observer and everything registered through it, leaving its lane alone.
    private func dropObserver(of pid: pid_t) {
        watchedWindows[pid] = nil
        if let observer = observers.removeValue(forKey: pid) {
            // Releasing the observer invalidates every registration it holds, so window elements need
            // no individual removal — unlike `unwatch(window:of:)`, where the observer lives on.
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    public func readFrame(of id: WindowId, then completion: @escaping @MainActor (Rect?) -> Void) {
        guard let record = registry.record(id) else {
            completion(nil)
            return
        }
        let element = record.element
        client.perform(app: record.pid) { _ in
            element.frame
        } then: { frame in
            completion(frame)
        }
    }

    public func isAlive(_ id: WindowId, then completion: @escaping @MainActor (Bool) -> Void) {
        // A window the registry has forgotten is one we were already told about — a free answer.
        guard let record = registry.record(id) else {
            completion(false)
            return
        }
        let element = record.element
        client.perform(app: record.pid) { _ in
            element.isAlive
        } then: { alive in
            completion(alive)
        }
    }

    // The callback's landing point

    /// Turn one AX notification into a `WorldObservation`. An unmanaged element produces silence.
    fileprivate func received(_ notification: String, about element: AXWindow) {
        switch notification {
        case AXNotification.windowCreated:
            // No id to resolve — this element has never been joined to a window number.
            deliver?(.windowAppeared(element.ownerPid))

        case AXNotification.mainWindowChanged:
            // Selecting a tab the group has shown before posts *only* this — not `AXWindowCreated`,
            // which fires once per tab and never again, and not `AXFocusedWindowChanged`, which a tab
            // switch does not post at all. So this is the sole notice that the window standing for a
            // group has changed, and it arrives naming a window AX may never have listed before.
            //
            // An element we already manage is an ordinary raise between an app's own windows and costs
            // one dictionary lookup to dismiss. Anything else means the app's window set may have moved
            // under us, and only a re-scan can say how.
            guard registry.id(for: element) == nil else { return }
            deliver?(.windowAppeared(element.ownerPid))

        case AXNotification.focusedWindowChanged:
            // `nil` is a real answer: the user focused a window we declined to bind, and passing it on
            // keeps `World.focusedWindow` honest rather than stuck on the last window we knew.
            deliver?(.focusMoved(registry.id(for: element)))

        case AXNotification.uiElementDestroyed:
            guard let id = registry.id(for: element) else { return }
            deliver?(.windowVanished(id))

        case AXNotification.windowMoved, AXNotification.windowResized:
            guard let id = registry.id(for: element) else { return }
            deliver?(.windowMoved(id))

        case AXNotification.windowMiniaturized:
            guard let id = registry.id(for: element) else { return }
            deliver?(.windowMinimized(id))

        case AXNotification.windowDeminiaturized:
            guard let id = registry.id(for: element) else { return }
            deliver?(.windowDeminimized(id))

        default:
            break
        }
    }

    // NSWorkspace + the mouse

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let facts = AppFacts(note) else { return }
                MainActor.assumeIsolated { self?.launched(facts) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let facts = AppFacts(note) else { return }
                MainActor.assumeIsolated {
                    // No `.regular` filter: an app's activation policy at *death* is not reliably the
                    // one it had in life, and the response to an unknown pid is nothing anyway.
                    self?.deliver?(.appTerminated(facts.pid))
                }
            },
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                               object: nil, queue: .main) { [weak self] note in
                guard let facts = AppFacts(note) else { return }
                MainActor.assumeIsolated { self?.activated(facts) }
            },
        ]
    }

    /// A global mouse-up ends a possible drag. Being *global*, the monitor never sees events destined for
    /// our own overlay, and the Accessibility grant already covers it — no new permission.
    private func observeMouse() {
        buttonMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.deliver?(.mouseUp) }
        }
    }

    /// Watch — or stop watching — the pointer itself, and answer whether it is now observed. Driven by
    /// `applyShellConfig`, so it tracks the two settings that want samples across every reload.
    ///
    /// **A monitor of its own, because motion is the one observation with a standing idle cost**: it
    /// fires at the pointer's sample rate for as long as it is installed, and with both settings off —
    /// the default — every sample would reach two readers that refuse it. So it is not installed until
    /// something wants it.
    ///
    /// The answer is what both settings are clamped against, and it must be *this* monitor's rather than
    /// the button monitor's: the only exit from a hidden pointer is seeing the mouse move, and buttons
    /// could only stand in for that question. Callable *ahead of* `start` for the same reason — the
    /// capability has to exist before the config is finished, and `start` waits on the config parsing.
    /// Samples arriving before `start` are dropped, `deliver` being the switch.
    ///
    /// Motion is three masks besides `mouseMoved`, since moving with a button held posts `*MouseDragged`
    /// and a pointer hidden by a command must not survive a window drag. Locations come off the
    /// `CGEvent`, already top-left global — the core's own space, and the one seam here with no Y-flip.
    @discardableResult
    public func observePointerMotion(_ observed: Bool) -> Bool {
        guard observed != (motionMonitor != nil) else { return motionMonitor != nil }
        guard observed else {
            motionMonitor.map(NSEvent.removeMonitor)
            motionMonitor = nil
            return false
        }
        let masks: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                            .otherMouseDragged]
        motionMonitor = NSEvent.addGlobalMonitorForEvents(matching: masks) { [weak self] event in
            MainActor.assumeIsolated {
                guard let location = event.cgEvent?.location else { return }
                self?.deliver?(.pointerMoved(Point(x: Double(location.x), y: Double(location.y))))
            }
        }
        return motionMonitor != nil
    }

    /// A launched app becomes a scan target if it is the kind we manage. Must stay the same filter
    /// `AXWindowSource.applications()` applies at boot; the two have to agree about which apps exist.
    private func launched(_ app: AppFacts) {
        guard app.isRegular, !app.isSelfOrInvalid, let bundleId = app.bundleId else { return }
        deliver?(.appLaunched(ScanTarget(pid: app.pid, bundleId: bundleId)))
    }

    /// An app came forward. `NSWorkspace` says *which app*, so the focused window has to be read — the
    /// one observation in this file that costs a round trip.
    private func activated(_ app: AppFacts) {
        // Reported before the `isRegular` filter below, and for every app but us: what this half of the
        // notification means is "the cursor has a new owner", which is true of an accessory app coming
        // forward as much as a regular one. A spurious one costs a re-assert of a hide that is already
        // in force, which the pointer plane's own depth count makes free; a missed one is a pointer
        // that stays visible.
        if !app.isSelfOrInvalid { deliver?(.appActivated) }
        guard app.isRegular, !app.isSelfOrInvalid else { return }
        client.perform(app: app.pid) { application in
            application.focusedWindow()
        } then: { [weak self] window in
            guard let self, let window else { return }   // unreadable ⇒ say nothing, don't guess `nil`
            deliver?(.focusMoved(registry.id(for: window)))
        }
    }

    /// The callback context. Unretained on purpose — see `axObserverCallback`.
    private func selfPointer() -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}
