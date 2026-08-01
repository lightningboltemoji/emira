import AppKit
import EmiraCore
import Foundation

// The truth plane's write half — same `AXClient` lanes as `AXEnumerator`, opposite direction of travel.
//
// The unit of work is one app's batch, not one window: one hop onto the app's lane instead of N, and one
// `AXEnhancedUserInterface` suspension instead of N (each toggle makes Chromium and JVM apps rebuild
// their whole accessibility tree). Ordering within a group is the lane's; between groups it is
// meaningless, since they are different processes with different run loops.

/// One window's requested placement: the registry record that says where to write, and the frame to
/// write.
public struct WindowMove: Sendable {
    /// The shell's private binding for the window — id, pid, and the live AX element.
    public let record: WindowRegistry.Record
    /// Where the core wants it, in core (top-left, global) coordinates. No flip at this boundary.
    public let target: Rect
    /// Whether this placement is a park rather than a tiled `setFrame`. The write is identical; the
    /// answer is not. A window at its 1 px off-viewport sliver can refuse a resize it accepts once
    /// scrolled back into view, so an app's answer at a park slot describes the *slot* and must never
    /// become a `SizeCorrection` (see `AXExecutor.report`).
    public let isPark: Bool

    public init(record: WindowRegistry.Record, target: Rect, isPark: Bool = false) {
        self.record = record
        self.target = target
        self.isPark = isPark
    }
}

/// What became of one window's placement — the two independent facts `AXWindow.place(at:)` reports,
/// carried back so the *executor* decides which events they become.
public struct WindowLanding: Sendable, Equatable {
    /// Which window this is about.
    public let id: WindowId
    /// Whether every AX write returned success. `false` means a timeout, a refused write, or an element
    /// that died mid-set.
    public let accepted: Bool
    /// Where the window actually is afterwards, when it could still be read. Not necessarily the
    /// requested frame: apps clamp to minimum sizes and quantize to character cells.
    public let frame: Rect?

    public init(id: WindowId, accepted: Bool, frame: Rect?) {
        self.id = id
        self.accepted = accepted
        self.frame = frame
    }
}

/// Everything `AXExecutor` needs from a live macOS, and nothing more.
///
/// `place` is asynchronous because it crosses onto an app's lane and must never block the pump; `focus`
/// and `raise` return nothing — the truth about focus comes back from the observers.
@MainActor
public protocol WindowWriter {
    /// Place a group of *one app's* windows, in order, and report each landing on the main actor.
    /// Must call `completion` exactly once, including when the group is empty or the app is gone.
    func place(_ moves: [WindowMove], of app: pid_t,
               then completion: @escaping @MainActor ([WindowLanding]) -> Void)

    /// Give a window keyboard focus: make it its app's key window, then bring the app forward. A writer
    /// that really writes also puts the request on the `FocusIntent` record, since the echo it provokes
    /// is only distinguishable from the user's own Cmd-Tab by what we asked for.
    func focus(_ window: WindowRegistry.Record)

    /// Raise a window within its app's stack, without touching focus.
    func raise(_ window: WindowRegistry.Record)

    /// Ask the window to close itself, as clicking its close button would. Reports nothing: the window
    /// actually going away arrives as a destroy observation, and an app is entitled to refuse (or to
    /// put up a save sheet and close later, or never).
    func close(_ window: WindowRegistry.Record)
}

/// `WindowWriter` against the real system: `AXClient` for the lanes and the messaging timeout,
/// `AXAccess` for the attributes, `NSRunningApplication` for activation.
@MainActor
public final class AXWindowWriter: WindowWriter {

    private let client: AXClient
    private let intent: FocusIntent

    /// - Parameters:
    ///   - client: the *same* `AXClient` the enumerator and observers use. The lanes are only serial —
    ///     and the size → position → size dance only atomic — if every AX caller shares them.
    ///   - intent: the *same* `FocusIntent` `WorldWatcher` reads. One record of the focus we asked for,
    ///     written here where the asking happens.
    public init(client: AXClient, intent: FocusIntent) {
        self.client = client
        self.intent = intent
    }

    public func place(_ moves: [WindowMove], of app: pid_t,
                      then completion: @escaping @MainActor ([WindowLanding]) -> Void) {
        client.perform(app: app) { application in
            // One suspension around the whole group, moves in reducer order. This closure *is* the app's
            // lane, so the sets cannot interleave with another batch.
            application.withEnhancedUserInterfaceSuspended {
                moves.map { move in
                    let outcome = move.record.element.place(at: move.target)
                    return WindowLanding(id: move.record.id,
                                         accepted: outcome.accepted, frame: outcome.actual)
                }
            }
        } then: { landings in
            completion(landings)
        }
    }

    /// Make the window key, then bring its app to the front — unless a newer focus has been asked for
    /// while this one was out on the lane.
    ///
    /// The order is load-bearing: activating an app surfaces whichever window is `AXMain` *at that
    /// moment*, so activating first raises the window the user last used and our `AXMain` write lands
    /// behind it. (`makeKey` is AX IPC on the app's lane; activation is AppKit on the main actor.)
    ///
    /// That deferral is also what makes activation *unordered*, and the ticket is what re-orders it.
    /// Two focus commands to two apps are two lanes with nothing between them, so a congested one can
    /// deliver its activation after a later command's and leave the wrong app in front — spam `focus`
    /// across a JVM and a terminal and it does. A superseded request drops its activation instead of
    /// racing: newest wins, exactly as a retargeted animator resolves the same contention.
    ///
    /// The `makeKey` itself is left to run. It cannot bring an app forward on its own, its own lane
    /// already orders it against the app's other writes, and the echo it may post is what `FocusIntent`
    /// exists to recognise on the way back.
    public func focus(_ window: WindowRegistry.Record) {
        let ticket = intent.request(window.id)
        let element = window.element
        let pid = window.pid
        client.perform(app: pid) { _ in
            element.makeKey()
        } then: { [intent] _ in
            guard intent.isCurrent(ticket) else { return }
            // Nil when the process exited between the two halves — a normal race, and the observers
            // will report the truth.
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    public func raise(_ window: WindowRegistry.Record) {
        let element = window.element
        client.perform(app: window.pid) { _ in
            element.raise()
        } then: { _ in }
    }

    public func close(_ window: WindowRegistry.Record) {
        let element = window.element
        client.perform(app: window.pid) { _ in
            element.close()
        } then: { _ in }
    }
}
