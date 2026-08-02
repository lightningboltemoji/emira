import EmiraCore
import Foundation

// The truth plane's `Executor`; the framework calls live below it in `AXWriter.swift`. A batch is
// grouped into one lane job per app — per-app order is the only order that means anything across
// separate processes, and grouping collapses the `AXEnhancedUserInterface` toggle to once. An effect
// naming an unknown window fails loudly rather than evaporating, and "landed" and "landed where we
// asked" are different questions (see `report`).
//
// Nothing here is async or blocks: `execute` hands work to lanes and returns. The feedback for an unknown
// window is delivered synchronously from inside `execute`; `Runtime` queues rather than re-reducing.

/// Executes the truth-plane effects — AX geometry, focus and stacking — against real windows.
@MainActor
public final class AXExecutor: Executor {

    /// How far a window may land from its requested frame before we tell the core about it, in points.
    /// One point: layout works in `Double`s and asks for `x = 740.5` while AX stores integers, so smaller
    /// drift is arithmetic. Anything beyond is the app having an opinion (a minimum size, a
    /// character-cell grid) that the core should hold instead of our optimistic guess.
    public static let landingTolerance: Double = 1

    private let registry: WindowRegistry
    private let writer: any WindowWriter
    private let scheduler: any DelayScheduler

    /// - Parameter scheduler: for the one turn `appActivated` waits (see `execute`). Defaulted because
    ///   it is the only asynchrony in this type and every other test of it is about geometry; a test
    ///   that cares injects a manual one rather than every test that doesn't naming a real one.
    public init(registry: WindowRegistry, writer: any WindowWriter,
                scheduler: any DelayScheduler = DispatchScheduler()) {
        self.registry = registry
        self.writer = writer
        self.scheduler = scheduler
    }

    public func execute(_ effects: [Effect], feedback: EventSink) {
        var groups: [pid_t: [WindowMove]] = [:]
        // Lane dispatch order, first-touched-first: a dictionary's order is not an order, and a hash
        // seed shouldn't be able to change which app's group goes out first.
        var lanes: [pid_t] = []

        for effect in effects {
            switch effect {
            // Geometry: gathered now, dispatched per app below. `park` is the same *write* as
            // `setFrame`, but carried along because it decides what a drifted landing means (`report`).
            case .setFrame(let id, let rect), .park(let id, let rect):
                guard let record = registry.record(id) else {
                    feedback(.axFailed(id))
                    continue
                }
                let isPark = if case .park = effect { true } else { false }
                if groups[record.pid] == nil { lanes.append(record.pid) }
                groups[record.pid, default: []].append(
                    WindowMove(record: record, target: rect, isPark: isPark))

            // Focus and stacking: issued as encountered. They commute with placement — keyboard and
            // z-order versus geometry — so sending the geometry afterwards reorders nothing observable.
            // An unknown id is dropped rather than acked; there is no "focus failed" event.
            case .focus(let id):
                guard let record = registry.record(id) else { continue }
                // The one thing focus acks, and it is not about focus: bringing an app forward discards
                // a background cursor hide, *including* the redundant activation that moves focus
                // between two windows of one app — which `NSWorkspace` announces to nobody, so the
                // writer that asked for it is the only witness there is.
                //
                // Reported a turn after the writer says it activated something, because the window
                // server re-establishes the cursor *after* the activation call returns and a hide
                // re-asserted inside that window is thrown away along with the one it replaced. The
                // delay is here rather than in the writer: what it defers is an **event**, which is
                // this type's half of the seam, and the writer has no business knowing a cursor exists.
                writer.focus(record) { [scheduler] in
                    scheduler.schedule(after: 0) { feedback(.appActivated) }
                }

            case .raise(let id):
                guard let record = registry.record(id) else { continue }
                writer.raise(record)

            // Lifetime: also issued as encountered, and also unacked. Whether the window actually goes
            // is the app's call, and the answer arrives as a destroy observation rather than here.
            case .closeWindow(let id):
                guard let record = registry.record(id) else { continue }
                writer.close(record)

            // The other planes, routed by `CompositingExecutor` before they reach here. Exhaustive so a
            // new `Effect` case must be assigned a home rather than falling through.
            case .capture, .beginTransition, .extendCover, .elevateLayer, .setLayerFrame, .refreshLayer,
                 .endTransition, .setCursorHidden, .warpPointer, .exec:
                break
            }
        }

        for pid in lanes {
            guard let moves = groups[pid] else { continue }
            writer.place(moves, of: pid) { landings in
                Self.report(landings, for: moves, to: feedback)
            }
        }
    }

    /// Turn one app's landings into events. Two facts, two events, not alternatives: `Engine` updates
    /// `World` optimistically, so anything the app did differently is corrected here.
    ///
    ///  · `placementCorrected` when a *tiled* window landed elsewhere. Carries the request alongside the
    ///    reality, which lets the core stop building a column around a width the app refuses.
    ///  · `parkCorrected` when a *parked* one did. Also carries the request, and the core reads only the
    ///    chrome out of it: a window can refuse a resize at its 1 px sliver that it accepts once scrolled
    ///    back into view, so the size half would freeze the column at its parked width — but how far off
    ///    the bottom edge the app will go is a fact about the window, and re-asking is a write per pass.
    ///  · `axLanded`/`axFailed` for the *write*, not the geometry. A terminal that quantizes to character
    ///    cells accepts every set and lands short every time; `axFailed` means the app said no.
    ///
    /// Order matters: truth first, then the verdict. `axLanded` can close a transition and snap the
    /// viewport, and the frame it snaps against should already be the real one.
    private static func report(_ landings: [WindowLanding], for moves: [WindowMove],
                               to feedback: EventSink) {
        let requested = Dictionary(moves.map { ($0.record.id, $0) },
                                   uniquingKeysWith: { _, last in last })
        for landing in landings {
            if let actual = landing.frame, let move = requested[landing.id],
               !approximatelyEqual(actual, move.target) {
                feedback(move.isPark
                    ? .parkCorrected(landing.id, requested: move.target, actual: actual)
                    : .placementCorrected(landing.id, requested: move.target, actual: actual))
            }
            feedback(landing.accepted ? .axLanded(landing.id) : .axFailed(landing.id))
        }
    }

    /// Whether a landing is close enough to the request to be silent. See `landingTolerance`.
    private static func approximatelyEqual(_ a: Rect, _ b: Rect) -> Bool {
        let tolerance = landingTolerance
        return abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
               abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
