import AppKit
import EmiraCore
import Foundation

// **The truth plane's write half** — where `Effect.setFrame` / `.park` / `.focus` / `.raise` stop being
// values and start being other people's windows moving. `AXEnumerator` is this file's mirror image:
// same `AXClient` lanes, same "everything that needs a live macOS sits behind a narrow protocol" trick
// (`WindowSource` there, `WindowWriter` here), opposite direction of travel.
//
// **Why a seam at all, when the executor could just call `AXClient`.** Because the decisions worth
// getting right are not the AX calls — they are *which* windows go out together, what an unknown id
// does, and what "it landed" means when the app put the window somewhere else. Those live in
// `AXExecutor`, above this protocol, and are tested against arrays. What is left below it is three
// methods of straight-line framework calls with no policy in them at all, which is the smallest
// untestable surface this job admits.
//
// **The unit of work is one app's batch, not one window.** `place` takes a *group* — every window of a
// single app that one reduced event asked to move — for two reasons that both come from §5. It is one
// hop onto that app's lane instead of N, and it is one `AXEnhancedUserInterface` suspension instead of
// N (see `EnhancedUI.swift`: each toggle makes Chromium and JVM apps rebuild their accessibility tree).
// Serial ordering within the group is the lane's; ordering *between* groups is meaningless, because
// they are different processes with different run loops — which is exactly why the fan-out is parallel.

// MARK: - The vocabulary

/// One window's requested placement: the registry record that says where to write, and the frame to
/// write. The record carries the AX element (module-internal — outside `EmiraShell` a window is a
/// `WindowId` and nothing else), so this type is safe to hand across the seam.
public struct WindowMove: Sendable {
    /// The shell's private binding for the window — id, pid, and the live AX element.
    public let record: WindowRegistry.Record
    /// Where the core wants it, in core (top-left, global) coordinates. No flip at this boundary.
    public let target: Rect
    /// Whether this placement is a **park** (`Effect.park`) rather than a tiled `setFrame`.
    ///
    /// The write is identical either way — the distinction is entirely about what the answer *means*.
    /// A park puts a window at its 1 px off-viewport sliver, and PRINCIPLES.md §10 records the finding
    /// that a window parked there refused a resize it accepted the moment it scrolled back into view.
    /// So an app's answer at a park slot is an answer about the *slot*, not about the window, and it
    /// must never become a `SizeCorrection`. See `AXExecutor.report`.
    public let isPark: Bool

    public init(record: WindowRegistry.Record, target: Rect, isPark: Bool = false) {
        self.record = record
        self.target = target
        self.isPark = isPark
    }
}

/// What became of one window's placement — the two independent facts `AXWindow.place(at:)` reports,
/// carried back across the seam so the *executor* decides which events they become.
public struct WindowLanding: Sendable, Equatable {
    /// Which window this is about.
    public let id: WindowId
    /// Whether every AX write returned success. `false` means the app said no — a timeout, a refused
    /// write, an element that died mid-set.
    public let accepted: Bool
    /// Where the window actually is afterwards, when it could still be read. Not necessarily the
    /// requested frame: apps clamp to minimum sizes and quantize to character cells, and that is a
    /// truth to record rather than a failure to report.
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
/// and `raise` return nothing at all — the truth about focus comes back from the observers watching the
/// system (M3 part 2b), not from the call that asked for it, so inventing an ack here would be the
/// executor telling the core what it already assumed.
@MainActor
public protocol WindowWriter {
    /// Place a group of **one app's** windows, in order, and report each landing on the main actor.
    /// Must call `completion` exactly once, including when the group is empty or the app is gone.
    func place(_ moves: [WindowMove], of app: pid_t,
               then completion: @escaping @MainActor ([WindowLanding]) -> Void)

    /// Give a window keyboard focus: make it its app's key window, then bring the app forward.
    func focus(_ window: WindowRegistry.Record)

    /// Raise a window within its app's stack, without touching focus.
    func raise(_ window: WindowRegistry.Record)
}

// MARK: - The live writer

/// `WindowWriter` against the real system: `AXClient` for the lanes and the messaging timeout,
/// `AXAccess` for the attributes, `NSRunningApplication` for activation.
@MainActor
public final class AXWindowWriter: WindowWriter {

    private let client: AXClient

    /// - Parameter client: the *same* `AXClient` the enumerator and observers use. The per-app lanes
    ///   are only serial — and the "size → position → size" dance only atomic with respect to other
    ///   writes — if every AX caller in the daemon shares them.
    public init(client: AXClient) {
        self.client = client
    }

    public func place(_ moves: [WindowMove], of app: pid_t,
                      then completion: @escaping @MainActor ([WindowLanding]) -> Void) {
        client.perform(app: app) { application in
            // One suspension around the whole group (`EnhancedUI.swift`), and the moves in the order
            // the reducer emitted them — this closure *is* the app's lane, so the sets cannot interleave
            // with another batch's.
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

    /// Make the window key, then bring its app to the front.
    ///
    /// **Two steps in two places, and the order is load-bearing.** `makeKey` is AX IPC and goes on the
    /// app's lane; activation is AppKit and belongs on the main actor. It has to be second, because
    /// activating an app surfaces whichever of its windows is `AXMain` *at that moment* — activate
    /// first and the app comes forward showing the window the user last used, then our `AXMain` write
    /// lands behind it and nothing looks focused.
    public func focus(_ window: WindowRegistry.Record) {
        let element = window.element
        let pid = window.pid
        client.perform(app: pid) { _ in
            element.makeKey()
        } then: { _ in
            // Nil when the process exited between the two halves — a window that vanished mid-focus is
            // a normal race (§1 invariant 3), and the observers will report the truth.
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    public func raise(_ window: WindowRegistry.Record) {
        let element = window.element
        client.perform(app: window.pid) { _ in
            element.raise()
        } then: { _ in }
    }
}
