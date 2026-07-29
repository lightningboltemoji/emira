import EmiraCore
import Foundation

// Our own focus writes come back to us as observations, and that round trip is not ordered.
//
// `Effect.focus` is one AX write on the target app's serial lane, and everything it produces returns by
// a different route than it left: an `AXFocusedWindowChanged` posted by the app, an `NSWorkspace`
// activation answered by a second read on that same lane. Lanes belong to different processes and
// nothing orders one against another (`AXClient`), so focusing a slow app and then a fast one delivers
// the fast one's news first and the slow one's after — naming a window the user has already moved off.
//
// Both halves of that are damage, and they are separate damage. The late *report* is read as an
// external focus change and retargets the scroll it arrives inside, which is a bounce the user watches;
// the late *activation* brings the wrong app forward for real, and no filter downstream can undo it. So
// the shell keeps the one fact that tells its own echo from the user's Cmd-Tab: which windows it asked
// for, and which of them it asked for last.

/// The shell's record of the focus changes it caused. Minted by `AXWindowWriter` as it issues a focus,
/// read by `AXWindowWriter` before it activates and by `WorldWatcher` before it believes a focus report.
/// One instance per daemon, shared like `WindowRegistry`.
@MainActor
public final class FocusIntent {

    /// How long a request stays on the record. Long enough for two AX round trips on a lane a JVM is
    /// servicing at its own pace, short enough that a genuine Cmd-Tab to a window we recently asked for
    /// is unreachable in the time — the one report this can wrongly swallow, and only within the window.
    ///
    /// A bound rather than a delay: nothing waits on it, it only decides when a request stops meaning
    /// anything. A record that never expired would make emira permanently deaf to real focus changes on
    /// every window it had ever focused, which is the failure `PRINCIPLES.md` §5 will not accept.
    public static let defaultGrace: TimeInterval = 0.5

    /// One issued focus request. Ordinal and opaque — `isCurrent` is the only thing that reads it.
    public struct Ticket: Equatable, Sendable {
        fileprivate let number: UInt64
    }

    /// What a focus report turned out to be.
    public enum Verdict: Equatable, Sendable {
        /// The echo of the focus we asked for most recently. Truthful, and the core already believes it.
        case expected
        /// The echo of a focus we asked for and then changed our mind about. News about the past.
        case stale
        /// Nobody here asked for this: a Cmd-Tab, a Dock click, an app raising a window of its own.
        case external
    }

    private let scheduler: any DelayScheduler
    private let grace: TimeInterval

    /// Tickets issued, ever. Monotone and never rewound, because `isCurrent` asks "has anything newer
    /// been wanted since" and must stay answerable long after the request itself is off the record.
    private var issued: UInt64 = 0

    /// The windows we have asked for inside the current grace, newest last. Append-only: a request
    /// produces up to *two* reports (the app's notification and the activation read), so consuming an
    /// entry when its first echo lands would let the second one back through as external.
    private var requested: [WindowId] = []

    public init(scheduler: any DelayScheduler, grace: TimeInterval = FocusIntent.defaultGrace) {
        self.scheduler = scheduler
        self.grace = grace
    }

    /// Record that we are about to ask for `id`, superseding whatever we asked for before it.
    public func request(_ id: WindowId) -> Ticket {
        issued += 1
        requested.append(id)
        let ticket = Ticket(number: issued)
        // Re-armed per request, never cancelled — `DelayScheduler` has none, so the generation check on
        // arrival is what keeps a superseded deadline from clearing a record still being written to.
        scheduler.schedule(after: grace) { [weak self] in
            guard let self, issued == ticket.number else { return }
            requested.removeAll()
        }
        return ticket
    }

    /// Whether `ticket` is still the newest request. False the moment a later one is issued, which is
    /// how a superseded activation is dropped rather than left to race the one the user actually asked
    /// for. Deliberately not cleared when the report arrives: the write's completion and its echo cross
    /// two different hops onto the main actor, and either may land first.
    public func isCurrent(_ ticket: Ticket) -> Bool { ticket.number == issued }

    /// Classify one focus report. Pure — a verdict is a reading of the record, never an edit to it.
    ///
    /// `nil` is `external` by construction: it names no window, so it can be nothing we asked for, and
    /// swallowing it would leave the core's focus on a window the user has stopped typing into.
    public func resolve(_ id: WindowId?) -> Verdict {
        guard let id, let newest = requested.last else { return .external }
        if id == newest { return .expected }
        return requested.contains(id) ? .stale : .external
    }
}
