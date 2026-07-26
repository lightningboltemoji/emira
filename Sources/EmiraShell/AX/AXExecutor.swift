import EmiraCore
import Foundation

// The truth plane's `Executor` — the half of the §1 diagram that `CompositingExecutor` has been
// routing to a `MockExecutor(.simulate)` since M2. Swapping this in underneath is the whole of "real
// windows move": nothing above it changes, because the seam was always the point.
//
// **What this file decides** (everything below it is framework calls, `AXWriter.swift`):
//
//  1. **A batch is grouped into one lane job per app.** The reducer emits placements in layout order —
//     column by column, which interleaves apps — and issuing them one at a time would mean N hops onto
//     N lanes and N `AXEnhancedUserInterface` toggles for an app with N windows on the strip. Grouping
//     preserves per-app order (which is the only order that means anything: separate processes have
//     separate run loops) and collapses the per-app overhead to once.
//  2. **An effect naming a window the registry doesn't know fails immediately.** Not silently: a
//     `setFrame` that evaporates would leave a transition waiting on a landing that can never arrive,
//     and the cover would sit there until the hold-timeout rescued it. `axFailed` is the honest answer
//     and the reducer already knows what to do with it.
//  3. **"Landed" and "landed *where we asked*" are different questions**, and only the first one is a
//     verdict. See `report`.
//  4. **Nothing here answers for a subsystem that isn't built.** Through M3 this file acked
//     `Effect.capture` on the spot, standing in for a `CaptureService` that didn't exist; M4 built it
//     and the effect routes elsewhere now (`CompositingExecutor`). The truth plane is only the truth
//     plane again.
//
// **Nothing here is async and nothing blocks.** `execute` hands work to lanes and returns; every answer
// arrives later as an `Event` through the sink (`Executor.swift`, §1 invariant 3). The feedback for an
// *unknown* window is delivered synchronously, from inside `execute` — which is fine, and deliberately
// exercised by the tests: the `Runtime` queues it rather than reducing re-entrantly (invariant 4).

/// Executes the truth-plane effects — AX geometry, focus and stacking — against real windows.
@MainActor
public final class AXExecutor: Executor {

    /// How far a window may land from its requested frame before we tell the core about it, in points.
    ///
    /// One point, because the drift we are *not* interested in is arithmetic: the layout engine works
    /// in `Double`s and happily asks for `x = 740.5`, while AX stores integers. Anything beyond a point
    /// is the app having an opinion — a minimum size, a character-cell grid, a refusal to sit under the
    /// menu bar — and that is truth the core should hold instead of our optimistic guess.
    ///
    /// Deliberately looser than `Engine`'s own 0.5 pt placement tolerance, and in the direction that
    /// keeps them consistent: drift we report is drift the reducer will also consider worth re-placing.
    public static let landingTolerance: Double = 1

    private let registry: WindowRegistry
    private let writer: any WindowWriter

    public init(registry: WindowRegistry, writer: any WindowWriter) {
        self.registry = registry
        self.writer = writer
    }

    public func execute(_ effects: [Effect], feedback: EventSink) {
        var groups: [pid_t: [WindowMove]] = [:]
        // Lane dispatch order, first-touched-first. A dictionary's order is not an order; a test that
        // asserts "Safari's group went out before Ghostty's" is asserting something real about the
        // batch, and a hash seed shouldn't be able to change it.
        var lanes: [pid_t] = []

        for effect in effects {
            switch effect {
            // Geometry: gathered now, dispatched per app below. `park` is the same *write* as
            // `setFrame` — the distinction is the core's (what it waits on, what it captures first),
            // not AX's — but it is carried along, because it decides what a drifted landing means
            // (`report`, and `WindowMove.isPark`).
            case .setFrame(let id, let rect), .park(let id, let rect):
                guard let record = registry.record(id) else {
                    feedback(.axFailed(id))
                    continue
                }
                let isPark = if case .park = effect { true } else { false }
                if groups[record.pid] == nil { lanes.append(record.pid) }
                groups[record.pid, default: []].append(
                    WindowMove(record: record, target: rect, isPark: isPark))

            // Focus and stacking: issued as encountered. They commute with placement — one is keyboard
            // and z-order, the other is geometry — so gathering the geometry and sending it afterwards
            // reorders nothing observable. An unknown id is dropped rather than acked: there is no
            // "focus failed" event, and inventing one would tell the core its own assumption back.
            case .focus(let id):
                guard let record = registry.record(id) else { continue }
                writer.focus(record)

            case .raise(let id):
                guard let record = registry.record(id) else { continue }
                writer.raise(record)

            // The other three planes. `CompositingExecutor` routes presentation effects to the
            // `CoverSurface`, `capture` to the `CaptureStore` and `reloadConfig` to the `ConfigSource`,
            // so none reaches here; handled exhaustively so that a new `Effect` case has to be assigned
            // a home rather than falling into a `default`. (`capture` *was* answered here — acked on
            // the spot — through M3, which is what M4's capture plane replaced.)
            case .capture, .beginTransition, .extendCover, .elevateLayer, .setLayerFrame, .endTransition,
                 .reloadConfig:
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

    /// Turn one app's landings into events.
    ///
    /// **Two facts, two events, and they are not alternatives.** `Engine.emitPlacements` updates the
    /// core's `World` *optimistically* — it records the target as the window's frame the moment it asks
    /// for the move — so anything the app does differently is a lie the core is now holding. This is
    /// where it gets corrected:
    ///
    ///  · **`placementCorrected`** when a **tiled** window is somewhere other than where we asked. It
    ///    carries the request alongside the reality, which `windowFrameChanged` cannot: an app clamping
    ///    our set is the only drift that says something about *what the window will accept*, and it says
    ///    it only in relation to the question. That pair is what lets the core stop building a column
    ///    around a width the app refuses (`SizeCorrection`).
    ///  · **`windowFrameChanged`** when a **parked** window drifted. Same truth, no lesson. A park slot
    ///    is a 1 px sliver hugging the working area's edge, and PRINCIPLES.md §10 records a window
    ///    refusing a resize there that it accepted the moment it scrolled back into view — so an answer
    ///    given at a park is an answer about off-viewport geometry, not about the window. Recording it
    ///    as a constraint would freeze a column at whatever width it happened to be parked at.
    ///  · **`axLanded` / `axFailed`** for the *write*, not the geometry. A terminal that quantizes to
    ///    character cells accepts every set and lands 8 pt short on every single placement; calling that
    ///    `axFailed` would fill the transition machinery with false alarms today and get terminals
    ///    dropped from the layout the day `axFailed` grows the retry/drop reconciliation §3 promises it.
    ///    `axFailed` is reserved for the app saying no.
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
                    ? .windowFrameChanged(landing.id, actual)
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
