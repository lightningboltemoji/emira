import EmiraCore
import Foundation

// **The world stops being a photograph** (IMPLEMENTATION.md §9, M3: the second half of the truth
// plane). Reads told us what was there at boot; writes moved it. Neither notices that the user opened
// a window, closed one, dragged one, or hit Cmd-Tab — so until this file the daemon's `World` was a
// photograph it could write to. This is the seam that makes it live.
//
// **The vocabulary is deliberately *not* `Event`.** It would be tempting: most of these map one-to-one
// onto an `Event` the reducer has handled since M1, and the mapping could live inside the AX callback.
// Two of them don't, and they are the two that matter:
//
//  · **A window appearing is not a window we can name.** `AXWindowCreated` hands back an element with
//    no public window number attached; identity comes from a join against the window list, made when
//    an app's windows can be told apart (`WindowRegistry`). So "a window appeared" reduces to *"re-scan
//    this app"*, and the response involves the enumerator, the registry, a retry budget, and a race
//    with the window server. That is policy, and policy does not belong in a C callback.
//  · **A move is not a frame.** AX says *that* a window moved, never *where to*; reading the frame is
//    another round trip into the same app. Answering every notification of a 120 Hz drag with a round
//    trip is a poll wearing a notification's clothes — and worse, it queues behind our own placement
//    writes on that app's lane. The coalescing that fixes it is policy too.
//
// So the split is the same one this codebase makes everywhere: `ObservationSource` is the untestable
// half (six methods, no decisions, `AXObservers.swift`), `WorldWatcher` is the decisions, and
// `WorldObservation` is the wire between them — already in emira's terms, because resolving an
// `AXUIElement` to a `WindowId` is the one thing the AX layer can do and the watcher cannot.

/// One thing the live system reported, in emira's vocabulary rather than AX's.
///
/// Every case is a *fact*, never an instruction: `windowAppeared` says an app made a window, not
/// "scan"; `windowMoved` says a window moved, not "go read its frame". What to do about each is
/// `WorldWatcher`'s to decide, which is what makes this enum assertable in a test.
public enum WorldObservation: Sendable, Equatable {

    // MARK: Applications

    /// A `.regular` app started. Its windows are not necessarily there yet — often it has none for a
    /// beat — and it may not even be ready to be observed (see `ObservationSource.watch(app:then:)`).
    case appLaunched(ScanTarget)

    /// An app exited. Everything keyed on its pid — windows, lane, observer — is now garbage.
    case appTerminated(pid_t)

    // MARK: Windows

    /// An app created a window. Which one is a question only a re-scan of that app can answer, so this
    /// carries the pid and nothing else — deliberately, rather than an element we could not bind.
    case windowAppeared(pid_t)

    /// A managed window was destroyed.
    case windowVanished(WindowId)

    /// A managed window moved or was resized. The two are one case because they are one response: AX
    /// reports them separately, and a drag emits both dozens of times a second, but "go and find out
    /// where it is now" is the same answer to either.
    case windowMoved(WindowId)

    /// A managed window went to the Dock. It leaves the strip like a close (2026-07-23).
    case windowMinimized(WindowId)

    /// A managed window came back from the Dock.
    case windowDeminimized(WindowId)

    /// Keyboard focus landed on `window` — or, when `nil`, on something emira does not manage.
    ///
    /// Already resolved, because both sources of it (an app's `AXFocusedWindowChanged`, and an
    /// `NSWorkspace` activation whose focused window has to be *read*) end in an element that only the
    /// AX layer can turn into an id. `nil` is a real answer and not an error: the user clicked into a
    /// window we declined to bind, and §4a's promise is about windows we placed.
    case focusMoved(WindowId?)

    /// A mouse button came up somewhere on the system. The end of a possible drag — the moment a tiled
    /// window the user dragged off its target re-asserts its layout (§11).
    case mouseUp
}

/// Everything the live world needs from macOS, and nothing more.
///
/// Six methods, each of which is straight-line framework work with no decision in it. A test double
/// answers all six from arrays, which is what leaves `WorldWatcher` — the retry budget, the coalescing,
/// the adoption bookkeeping, the teardown ordering — fully testable with no window server, no TCC
/// grant, and no other processes.
@MainActor
public protocol ObservationSource: AnyObject {

    /// Begin delivering observations. Called once, and installs the system-wide watchers (application
    /// launch/quit/activation, the global mouse monitor) that are not per-app.
    func start(_ deliver: @escaping @MainActor (WorldObservation) -> Void)

    /// Start watching one app for the things only an *app* reports: a window being created, and focus
    /// moving between its windows.
    ///
    /// **Answers whether it worked**, because it genuinely may not: an app that is still starting up
    /// answers AX with `kAXErrorCannotComplete`, and a window manager that shrugged at that would go
    /// permanently blind to every window that app ever opens. The retry is the watcher's.
    func watch(app: ScanTarget, then: @escaping @MainActor (Bool) -> Void)

    /// Start watching specific windows for the things only a *window* reports: destruction, movement,
    /// resizing, and (de)miniaturization. Idempotent — a window already watched is skipped.
    ///
    /// Separate from `watch(app:)` because the Accessibility API is: these notifications are delivered
    /// for registrations made against the *window* element, not the application element, which is what
    /// every SIP-on prior art does (AeroSpace's `MacWindow`, yabai's `AX_WINDOW_NOTIFICATION_LIST`).
    func watch(windows: [WindowId], of app: pid_t)

    /// Stop watching one window (it closed). Its registrations would otherwise accumulate against a
    /// dead element for as long as its app lives.
    func unwatch(window: WindowId, of app: pid_t)

    /// Stop watching an app entirely and release everything keyed on its pid — the observer, the
    /// run-loop source, and its AX lane.
    func unwatch(app: pid_t)

    /// Read a managed window's current frame, off the main actor, answering on it. `nil` when the
    /// window stopped answering — it closed between the notification and the read, which is a normal
    /// race and not an error.
    func readFrame(of window: WindowId, then: @escaping @MainActor (Rect?) -> Void)
}
