import Foundation
import EmiraCore

// **Stopping emira without stranding the desktop** (2026-07-26). The counterpart to `WorldWatcher`,
// which turns a live desktop into events: this is the last thing that runs, and it turns the strip
// back into something a user can work with by hand.
//
// The problem is structural rather than cosmetic. emira's workspaces and its off-viewport columns are
// both *off-screen parking* (`PRINCIPLES.md` §3): a window that isn't in the viewport is at a 1 pt nub
// in the corner of the working area. That is fine while the daemon is running, because scrolling and
// switching bring it back — and it is exactly as bad as it sounds the moment the daemon isn't, since
// nothing else on the machine knows those nubs mean anything. So the teardown places every managed
// window into the quit cascade (`Cascade`, `State.cascadeEffects()`) before the process exits.
//
// **What this type actually owns is the waiting**, and that is the whole reason it exists rather than
// four lines in `main.swift`. AX writes are asynchronous by construction — they cross onto a serial
// per-app queue and answer later (`AXWriter.swift`) — so `exit(0)` on the next line would kill the
// process with most of the sets still in flight, and the user would get a partial cascade with the
// remainder abandoned at their nubs. Every landing has to be waited for, and the wait has to be
// **bounded**: a hung app must delay a quit by a moment, never prevent it. Same shape as the
// transition hold-timeout (IMPLEMENTATION.md §3), for the same reason, one plane over.
//
// **The caller stops the world first.** Nothing here silences the event sources, because they are the
// daemon's to own — but the cascade *is* undone by a live `WorldWatcher`, whose `AXWindowMoved`
// observations would come back as `windowFrameChanged`, re-place every window on the strip, and fight
// the pile all the way to the deadline. `emira-daemon` stops the watcher, the hotkeys, the config
// watch and the socket before calling `run`; `WorldWatcher.stop()` exists for this and only this.

/// Places every managed window into the quit cascade and calls back once they have landed — or once
/// the deadline says stop waiting.
///
/// One-shot: `run` does nothing on a second call, so the three ways to stop emira (Ctrl-C, `kill`,
/// the menu bar's Quit) can all reach it and the second Ctrl-C of an impatient user is a no-op rather
/// than a second cascade.
@MainActor
public final class Teardown {

    /// How the cascade ended, for the log line the daemon prints on its way out.
    public struct Report: Sendable, Equatable {
        /// How many windows were placed.
        public let windows: Int
        /// How many of those never answered before the deadline. `0` on the ordinary path.
        public let unlanded: Int
        /// Whether the deadline is what ended the wait.
        public var timedOut: Bool { unlanded > 0 }

        public init(windows: Int, unlanded: Int) {
            self.windows = windows
            self.unlanded = unlanded
        }
    }

    /// How long to wait for the AX sets to land before exiting anyway.
    ///
    /// Generous against the measurements and cheap against the alternative: the truth plane lands in
    /// ~14 ms across N windows on a real desktop (`PRINCIPLES.md` §10, checkpoint 3a), so this is two
    /// orders of magnitude of slack for the tail — an app mid-beachball, or one being asked to place
    /// a dozen windows at once. The failure it bounds is a quit that appears to hang, which is worse
    /// than a window left at its nub, because the user cannot tell it from a crash.
    public static let defaultDeadline: TimeInterval = 1.5

    private let executor: any Executor
    private let scheduler: any DelayScheduler
    private let deadline: TimeInterval

    /// Windows whose set is still out. Emptied by landings; whatever is left when the deadline fires
    /// is what `Report.unlanded` counts.
    private var pending: Set<WindowId> = []
    private var placed = 0
    private var started = false
    private var finished = false
    private var completion: (@MainActor (Report) -> Void)?

    /// - Parameters:
    ///   - executor: the **truth-plane** executor (`AXExecutor` in the daemon). Deliberately not the
    ///     compositing one: a cascade emits nothing but `setFrame`/`raise`/`focus`, and routing it
    ///     through a cover that is about to stop existing would be machinery for nothing.
    ///   - scheduler: the deadline's clock — a seam, so the timeout path is a test rather than a wait.
    public init(executor: any Executor, scheduler: any DelayScheduler,
                deadline: TimeInterval = defaultDeadline) {
        self.executor = executor
        self.scheduler = scheduler
        self.deadline = deadline
    }

    /// Cascade `state`'s managed windows, then call `finish` exactly once — when every window has
    /// answered, or when the deadline runs out, whichever comes first.
    ///
    /// A state with nothing to place (no display yet, no managed windows) finishes immediately and
    /// synchronously: there is nothing to wait for, and making the caller's exit path depend on a
    /// timer for the empty case would be the one way this could hang.
    public func run(placing state: State, then finish: @escaping @MainActor (Report) -> Void) {
        guard !started else { return }
        started = true
        completion = finish

        let effects = state.cascadeEffects()
        pending = Set(effects.compactMap { effect in
            if case .setFrame(let id, _) = effect { return id } else { return nil }
        })
        placed = pending.count
        guard placed > 0 else { return complete() }

        // Armed *before* the effects go out, so an executor that answers synchronously (the mock, and
        // a real one rejecting an unknown window) finds the deadline already accounted for — and
        // `complete`'s guard makes the later firing a no-op rather than a second callback.
        scheduler.schedule(after: deadline) { [weak self] in self?.complete() }
        executor.execute(effects, feedback: EventSink { [weak self] event in self?.absorb(event) })
    }

    /// One window answered. `axFailed` counts as an answer: it is the app saying no, which is a
    /// finished conversation — waiting out the deadline for it would delay the quit to learn nothing.
    private func absorb(_ event: Event) {
        switch event {
        case .axLanded(let id), .axFailed(let id):
            pending.remove(id)
        default:
            // Everything else a placement can produce — a drifted landing (`placementCorrected`), the
            // focus echo — is truth about a strip that is being dismantled. Nothing left to tell.
            return
        }
        if pending.isEmpty { complete() }
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        let finish = completion
        completion = nil
        finish?(Report(windows: placed, unlanded: pending.count))
    }
}
