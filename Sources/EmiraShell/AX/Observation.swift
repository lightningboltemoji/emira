import EmiraCore
import Foundation

// The seam that makes `World` live rather than a photograph the daemon writes to.
//
// The vocabulary is not `Event`, because two AX observations don't map onto one: `AXWindowCreated` hands
// back an element with no window number attached, so "a window appeared" can only reduce to "re-scan this
// app"; and AX says *that* a window moved, never where to, so a frame costs another round trip into that
// app's lane. Both need policy, which lives in `WorldWatcher` — `ObservationSource` (`AXObservers.swift`)
// is the decision-free half, and `WorldObservation` is the wire between them.

/// One thing the live system reported, in emira's vocabulary rather than AX's.
///
/// Every case is a *fact*, never an instruction: `windowAppeared` says an app made a window, not "scan".
public enum WorldObservation: Sendable, Equatable {

    /// A `.regular` app started. Its windows are often not there yet, and it may not even be ready to be
    /// observed (see `ObservationSource.watch(app:then:)`).
    case appLaunched(ScanTarget)

    /// An app exited. Everything keyed on its pid — windows, lane, observer — is now garbage.
    case appTerminated(pid_t)

    /// An app created a window. Which one only a re-scan of that app can answer, so this carries the pid
    /// and nothing else.
    case windowAppeared(pid_t)

    /// A managed window was destroyed.
    case windowVanished(WindowId)

    /// A managed window moved or was resized. One case because AX reports the two separately but "find
    /// out where it is now" answers either.
    case windowMoved(WindowId)

    /// A managed window went to the Dock. It leaves the strip like a close.
    case windowMinimized(WindowId)

    /// A managed window came back from the Dock.
    case windowDeminimized(WindowId)

    /// Keyboard focus landed on `window`, or on something emira does not manage (`nil` — a real answer,
    /// not an error).
    case focusMoved(WindowId?)

    /// A mouse button came up somewhere on the system — the end of a possible drag, and the moment a
    /// tiled window the user dragged off its target re-asserts its layout.
    case mouseUp
}

/// Everything the live world needs from macOS, and nothing more.
///
/// No decisions in any of it, so a test double answers the whole protocol from arrays and `WorldWatcher`
/// stays testable with no window server and no TCC grant.
@MainActor
public protocol ObservationSource: AnyObject {

    /// Begin delivering observations. Called once; installs the system-wide watchers (app
    /// launch/quit/activation, the global mouse monitor) that are not per-app.
    func start(_ deliver: @escaping @MainActor (WorldObservation) -> Void)

    /// Start watching one app for the things only an *app* reports: window creation and focus moving
    /// between its windows.
    ///
    /// Answers whether it worked, because it genuinely may not: an app still starting up fails this with
    /// `kAXErrorCannotComplete`, and ignoring that goes permanently blind to its windows. The retry is
    /// the watcher's.
    func watch(app: ScanTarget, then: @escaping @MainActor (Bool) -> Void)

    /// Start watching specific windows for the things only a *window* reports: destruction, movement,
    /// resizing, and (de)miniaturization. Idempotent — a window already watched is skipped.
    ///
    /// Separate from `watch(app:)` because AX delivers these only for registrations made against the
    /// *window* element.
    func watch(windows: [WindowId], of app: pid_t)

    /// Stop watching one window (it closed). Its registrations would otherwise accumulate against a
    /// dead element for as long as its app lives.
    func unwatch(window: WindowId, of app: pid_t)

    /// Stop watching an app entirely and release everything keyed on its pid — the observer, the
    /// run-loop source, and its AX lane.
    func unwatch(app: pid_t)

    /// Read a managed window's current frame, off the main actor, answering on it. `nil` when the window
    /// stopped answering — it closed between the notification and the read, a normal race.
    func readFrame(of window: WindowId, then: @escaping @MainActor (Rect?) -> Void)

    /// Whether a managed window still exists, off the main actor, answering on it.
    ///
    /// The notification stream cannot answer this: an app that loses its key window picks a new one and
    /// posts `AXFocusedWindowChanged` *before* the old element is destroyed, so a focus report means
    /// either "the user moved focus" or "macOS backfilled a dead window" and only a read tells them apart
    /// (`WorldWatcher.resolveFocus`). A window the registry has already forgotten is `false`.
    func isAlive(_ window: WindowId, then: @escaping @MainActor (Bool) -> Void)
}
