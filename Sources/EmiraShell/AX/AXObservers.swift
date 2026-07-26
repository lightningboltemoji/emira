import AppKit
import ApplicationServices
import EmiraCore
import Foundation

// `ObservationSource` against the real system — the second (and last) file in emira that imports
// `ApplicationServices`, for the reason its header now records: `AXObserver` is an object with a C
// callback and a run-loop source, and there is no value type to hide it behind that wouldn't *be* this
// machinery. Everything with a decision in it lives above, in `WorldWatcher`.
//
// **Three sources of truth about a changing desktop, and each one knows something the others don't.**
//
//  · **`AXObserver`, per app** — the only thing that reports windows: created, destroyed, moved,
//    resized, miniaturized. Registered against *two* different elements, which is not a style choice:
//    the Accessibility API delivers window creation and in-app focus changes for registrations made on
//    the **application** element, and destruction/movement/miniaturization for registrations made on
//    the **window** element. Registering the window set on the app element silently delivers nothing —
//    the same shape of trap as `kAXWindowsAttribute` containing the Finder desktop, and the reason
//    every SIP-on prior art (AeroSpace's `MacWindow`, yabai's `AX_WINDOW_NOTIFICATION_LIST`) splits it
//    exactly here.
//  · **`NSWorkspace`** — the only thing that reports *apps*: launched, terminated, activated. AX cannot
//    tell us about a process that has no observer yet, which is every process the moment it starts, so
//    without this a newly launched app would never be seen at all.
//  · **A global mouse monitor** — the only thing that reports the end of a drag. AX says a window
//    moved, never that the user let go.
//
// **Registration is IPC and goes on the app's lane** (correcting the aside in `AXClient.swift`, which
// guessed that observing was a pure run-loop operation). `AXObserverCreate` and `CFRunLoopAddSource`
// are local and main-thread; `AXObserverAddNotification` and `AXObserverRemoveNotification` are round
// trips into the target app and return `.cannotComplete` when it is busy or still starting. Running
// them on the main actor would let a slow app stall the pump for the messaging timeout, once per
// notification — precisely what §5 forbids. Callback *delivery* is a different question and stays on
// the main run loop, which is where the pump lives.

// MARK: - The notification tables

// The AX notification names, split by the element they must be registered against. Spelled as literals
// for the same reason `AXAccess`'s attribute table is: they are all equally load-bearing strings in a C
// API, and a table that is half `kAX…` symbols and half literals reads as if the literals were the
// sloppy half.
private enum AXNotification {

    /// Registered on the **application** element.
    static let application = [
        "AXWindowCreated",              // a window was born — which one, only a re-scan can say
        "AXFocusedWindowChanged",       // focus moved between this app's own windows
    ]

    /// Registered on each **window** element.
    static let window = [
        "AXUIElementDestroyed",
        "AXWindowMoved",
        "AXWindowResized",
        "AXWindowMiniaturized",
        "AXWindowDeminiaturized",
    ]

    static let windowCreated = "AXWindowCreated"
    static let focusedWindowChanged = "AXFocusedWindowChanged"
    static let uiElementDestroyed = "AXUIElementDestroyed"
    static let windowMoved = "AXWindowMoved"
    static let windowResized = "AXWindowResized"
    static let windowMiniaturized = "AXWindowMiniaturized"
    static let windowDeminiaturized = "AXWindowDeminiaturized"
}

// MARK: - The C callback

/// What an `AXObserver` calls. Runs on the run loop its source was added to — the main one — so this
/// is an assertion of something already true rather than a hop.
///
/// The `refcon` is an **unretained** pointer to the source: it owns every observer that could call
/// this, so the pointer cannot outlive its referent, and retaining would be a cycle that keeps the
/// daemon's observer graph alive forever.
/// The raw `AXUIElement` is wrapped and the `CFString` copied to a `String` **before** the hop, because
/// neither is `Sendable` and Swift 6 checks the crossing even when — as here — both sides are the same
/// thread. `AXWindow` asserts that thread-safety once, in `AXAccess`, which is exactly what the wrapper
/// is for.
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

/// The facts about an app that a `NSWorkspace` notification carries, extracted as values.
///
/// `NSRunningApplication` is not `Sendable`, so it cannot travel into the main-actor hop — and it does
/// not need to. Everything the watcher decides with is three scalars, read in the notification block
/// (which is already on the main queue) and carried across as a value.
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

// MARK: - The source

/// The live `ObservationSource`: per-app `AXObserver`s, `NSWorkspace` notifications, and a global
/// mouse monitor, translated into `WorldObservation`s.
@MainActor
public final class AXObservationSource: ObservationSource {

    /// An `AXObserver` and the callback context, boxed so they can cross onto an app's lane. Both are
    /// thread-safe by construction — a CF object and a pointer to a main-actor class we only ever
    /// dereference back on the main actor — which Swift cannot see through a C type.
    private struct ObserverHandle: @unchecked Sendable {
        let observer: AXObserver
        let refcon: UnsafeMutableRawPointer
    }

    private let client: AXClient
    private let registry: WindowRegistry

    /// Where observations go. Set by `start`; before that the source is inert, which is what makes
    /// construction order in the daemon a non-question.
    private var deliver: (@MainActor (WorldObservation) -> Void)?

    /// One observer per app, keyed by pid — the same granularity as the AX lanes, because it is the
    /// granularity the OS imposes.
    private var observers: [pid_t: AXObserver] = [:]

    /// The window elements currently registered, per app. Kept so registration is idempotent and so a
    /// closing window's notifications can be removed without asking the registry, which by then may
    /// already have forgotten it.
    private var watchedWindows: [pid_t: [WindowId: AXWindow]] = [:]

    /// `NSWorkspace` observer tokens and the global mouse monitor, held only to be released.
    private var workspaceTokens: [any NSObjectProtocol] = []
    private var mouseMonitor: Any?

    public init(client: AXClient, registry: WindowRegistry) {
        self.client = client
        self.registry = registry
    }

    // No `deinit` teardown, and that is a decision rather than an omission: a `@MainActor` class is
    // `Sendable`, so its `deinit` is nonisolated and may not touch isolated state at all — and the two
    // things there would be to release (`NotificationCenter` tokens, the mouse monitor) both capture
    // `self` weakly, so nothing is kept alive and nothing fires into a dead object. The daemon holds
    // exactly one of these for the life of the process; if a second lifetime ever appears, teardown
    // becomes an explicit `stop()` called by whoever created it, not a hidden hop in `deinit`.

    // MARK: Lifecycle

    public func start(_ deliver: @escaping @MainActor (WorldObservation) -> Void) {
        self.deliver = deliver
        observeWorkspace()
        observeMouse()
    }

    // MARK: Per-app observation

    public func watch(app target: ScanTarget, then completion: @escaping @MainActor (Bool) -> Void) {
        if observers[target.pid] != nil {
            completion(true)
            return
        }
        var created: AXObserver?
        guard AXObserverCreate(target.pid, axObserverCallback, &created) == .success,
              let observer = created
        else {
            // The usual cause is an app that is still starting; `WorldWatcher` retries. It can also be
            // a process that exited between the launch notification and here, where the retry budget
            // simply expires and nothing is lost.
            completion(false)
            return
        }
        // `.commonModes`, not `.defaultMode`: the main run loop switches modes while a menu or a
        // window-resize loop is tracking, and a window manager that goes deaf to window creation for
        // as long as a menu is open would resume with a stale world.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[target.pid] = observer

        let handle = ObserverHandle(observer: observer, refcon: selfPointer())
        client.perform(app: target.pid) { application in
            // Every notification attempted, not `allSatisfy` — a short-circuit on the first failure
            // would leave an app that answered one and refused the next observed for half of what it
            // does, and the retry would then skip it because an observer exists.
            var ok = true
            for name in AXNotification.application {
                let result = AXObserverAddNotification(
                    handle.observer, application.element, name as CFString, handle.refcon)
                ok = (result == .success) && ok
            }
            return ok
        } then: { [weak self] ok in
            if !ok { self?.unwatch(app: target.pid) }
            completion(ok)
        }
    }

    public func watch(windows ids: [WindowId], of app: pid_t) {
        guard let observer = observers[app] else { return }
        var fresh: [WindowId: AXWindow] = [:]
        for id in ids where watchedWindows[app]?[id] == nil {
            // `record.pid == app` is not paranoia: the caller groups by pid off the same registry, but
            // a mismatched pair would register a notification on the wrong app's observer and the
            // window would then be silently unobservable.
            guard let record = registry.record(id), record.pid == app else { continue }
            fresh[id] = record.element
        }
        guard !fresh.isEmpty else { return }
        watchedWindows[app, default: [:]].merge(fresh) { existing, _ in existing }

        let handle = ObserverHandle(observer: observer, refcon: selfPointer())
        let elements = Array(fresh.values)
        client.perform(app: app) { _ in
            for element in elements {
                for name in AXNotification.window {
                    _ = AXObserverAddNotification(
                        handle.observer, element.element, name as CFString, handle.refcon)
                }
            }
        } then: { _ in }
    }

    public func unwatch(window id: WindowId, of app: pid_t) {
        guard let element = watchedWindows[app]?.removeValue(forKey: id),
              let observer = observers[app]
        else { return }
        let handle = ObserverHandle(observer: observer, refcon: selfPointer())
        client.perform(app: app) { _ in
            // The element is usually already dead and every removal fails; that is fine and is why the
            // results are ignored. The registrations that *do* come off are the ones that matter — a
            // long-lived app opening and closing windows all day would otherwise accumulate one set
            // per window for the life of the daemon.
            for name in AXNotification.window {
                _ = AXObserverRemoveNotification(handle.observer, element.element, name as CFString)
            }
        } then: { _ in }
    }

    public func unwatch(app pid: pid_t) {
        watchedWindows[pid] = nil
        if let observer = observers.removeValue(forKey: pid) {
            // Releasing the observer invalidates every registration it holds, which is why the window
            // elements need no individual removal here — unlike `unwatch(window:of:)`, where the
            // observer lives on.
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        // The lane's application element holds a Mach port to what is now a dead process.
        client.forget(app: pid)
    }

    // MARK: Reads

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

    // MARK: The callback's landing point

    /// Turn one AX notification into a `WorldObservation`. The only translation in this file, and it is
    /// deliberately total in the direction that matters: an element we do not manage produces silence,
    /// never a guess.
    fileprivate func received(_ notification: String, about element: AXWindow) {
        switch notification {
        case AXNotification.windowCreated:
            // No id to resolve — this element has never been joined to a window number, which is the
            // whole reason the observation names the app instead (`Observation.swift`).
            deliver?(.windowAppeared(element.ownerPid))

        case AXNotification.focusedWindowChanged:
            // `nil` is a real answer here: the user focused a window we declined to bind, or a dialog
            // we classified as furniture. Passing it through is what keeps `World.focusedWindow`
            // honest rather than stuck on the last window we happened to know.
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

    // MARK: NSWorkspace + the mouse

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
                    // No `.regular` filter, deliberately: an app's activation policy at *death* is not
                    // reliably the one it had in life, and the watcher's response to a pid it never
                    // knew is already nothing.
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

    /// A global mouse-up. `.leftMouseUp` and `.rightMouseUp` both end a possible drag; the monitor is
    /// *global*, so it never sees events destined for our own (click-through, borderless) overlay.
    ///
    /// Allowed by the Accessibility grant we already require — this adds no new permission.
    private func observeMouse() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.deliver?(.mouseUp) }
        }
    }

    /// A launched app becomes a scan target if it is the kind we manage — the same filter
    /// `AXWindowSource.applications()` applies at boot, restated because the two see the world through
    /// different APIs and must agree about which apps exist.
    private func launched(_ app: AppFacts) {
        guard app.isRegular, !app.isSelfOrInvalid, let bundleId = app.bundleId else { return }
        deliver?(.appLaunched(ScanTarget(pid: app.pid, bundleId: bundleId)))
    }

    /// An app came forward. `NSWorkspace` says *which app*; §4a's promise is about a *window* ("the
    /// user must never be focused on something they can't see"), so the focused window has to be read —
    /// the one observation in this file that costs a round trip.
    private func activated(_ app: AppFacts) {
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
