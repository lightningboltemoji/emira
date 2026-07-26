import Foundation
import EmiraCore

// The executor that finally *runs* the presentation plane — the second half of the §1 diagram's
// "executed by" arrow, and the piece that makes `Effect.beginTransition` / `.setLayerFrame` /
// `.endTransition` do something instead of being recorded by a mock.
//
// **It is a router, not a compositor.** `Effect` spans three kinds of machinery, and they have nothing
// in common: the presentation plane is Core Animation on layers we own (instant, main-thread), the
// truth plane is AX Mach IPC into other processes (slow, off-thread), and the capture plane is
// ScreenCaptureKit (asynchronous, and the only one gated on a second TCC grant). This type owns the
// *seam*: each effect goes to its owner, in order. That second executor was `MockExecutor(.simulate)`
// through M2 and is `AXExecutor` from M3 part 2a — the truth plane was swapped in underneath a working,
// judgeable presentation plane without a line of this file changing, which is what the seam was for.
//
// **Capture became a plane at M4, having been a lie until then.** `AXExecutor` acked `Effect.capture`
// on the spot because there was nothing to capture *for*; now it routes here, and the routing carries
// one thing the other two planes don't need: a whole run's ids reach `CaptureStore.capture` as **one
// call**, because a batch is what a capture is (`CaptureService`, decision 2). The other planes take
// their effects one at a time.
//
// **Order is preserved exactly, by chunking into contiguous runs.** A naive partition
// ("presentation first, then the rest") would be right for every batch the reducer emits today —
// `[.beginTransition, .setFrame, .setFrame]` puts the cover up before the reals move, which *is* the
// no-exposure rule (§4b step 3) — and silently wrong the first time a batch needs a truth-plane
// effect before a presentation one. So instead we walk the batch, split it at each plane change, and
// hand each run to its owner in order. The cover-before-teleport ordering then holds because the
// *reducer* emits it that way, which is where that policy belongs.
//
// **One `CATransaction` per presentation run** — the batch boundary is the frame boundary
// (`Executor.swift`): a tick's `setLayerFrame` blits must reach the screen as one frame or the
// lockstep motion the strip spike proved would shear. The transaction is opened by the surface
// (`beginFrame`/`endFrame`) rather than here, which keeps this file framework-free and lets a test
// double *prove* every run was wrapped exactly once.

/// The presentation plane's mechanism, as narrowly as it can be expressed: raise a cover built from
/// the core's layer bindings, blit layer frames, cross-fade away. Implemented for real by
/// `Reconstruction` (AppKit + Core Animation) and by a recording double in tests.
///
/// Same discipline as `FrameClock`: the parts that need a window server sit behind a protocol so the
/// *decisions* around them — routing, ordering, transaction framing, the ack — stay headlessly
/// testable, and the untestable surface is seven methods wide.
@MainActor
public protocol CoverSurface: AnyObject {
    /// Open the frame every subsequent call in this run blits inside (a `CATransaction` with actions
    /// disabled, for the real surface). Always balanced by `endFrame()`.
    func beginFrame()

    /// Commit the frame opened by `beginFrame()`.
    func endFrame()

    /// Build the reconstruction from the core's ordered bindings (z-order bottom→top) and show it.
    /// The cover is opaque from this moment, so the real windows may teleport behind it.
    func raiseCover(_ bindings: [LayerBinding])

    /// Add layers to the cover that is already up, for windows a retarget pulled into scope after it
    /// was built (z-order: above everything already there). No-op for a binding already present.
    func extendCover(_ bindings: [LayerBinding])

    /// Move one reconstruction layer to `rect` (core top-left coordinates) for this frame.
    func setLayerFrame(_ layer: LayerId, to rect: Rect)

    /// Move one layer to the top of the cover's z-order, where it stays until something else is
    /// elevated. The core's answer to "which window slides *over* the one it is trading places
    /// with" (`Effect.elevateLayer`). No-op for a layer the cover doesn't have.
    func elevate(_ layer: LayerId)

    /// Cross-fade the cover away and drop the reconstruction, calling `completion` when it is down.
    /// Runs **outside** the frame — the fade is a window-alpha animation, not a layer blit.
    func dismiss(completion: @escaping @MainActor () -> Void)
}

/// The `Executor` that splits an effect batch across the two planes.
@MainActor
public final class CompositingExecutor: Executor {

    /// Which machinery executes an effect.
    enum Plane: Equatable {
        /// Core Animation on our own overlay layers — the cover lifecycle.
        case presentation
        /// ScreenCaptureKit stills — the pixels the cover is made of.
        case capture
        /// AX geometry, focus and stacking — real windows in other processes.
        case truth
        /// The filesystem — re-reading the config file (M5). Not a plane of the *desktop* like the
        /// other three, and it is one anyway for the reason `plane(of:)` is an exhaustive switch: an
        /// effect belongs to whichever machinery runs it, and "the disk" is machinery that has
        /// nothing in common with AX Mach IPC or Core Animation. Calling it truth-plane work to save
        /// a case would be a lie in the one table whose job is to be right about this.
        case config
    }

    /// Called when a cover comes down, with the number of frames blitted while it was up.
    ///
    /// The one smoothness measurement that exists. It has to live here, because **the state dump
    /// cannot answer it**: `Spring` is an *analytic* integrator, so it lands on the physically correct
    /// position for any `dt` — a transition delivered in six lurching frames traces exactly the same
    /// offset-vs-wall-clock curve as one delivered in seventy-six, and no amount of polling
    /// `emira debug` distinguishes them. Frames blitted over duration is the difference between the
    /// signature scroll and a slideshow.
    public var onCoverDismissed: (@MainActor (_ framesBlitted: Int, _ duration: TimeInterval) -> Void)?

    private let surface: any CoverSurface
    private let store: any CaptureStore
    private let truth: any Executor
    private let config: (any ConfigSource)?
    /// Frames blitted since the current cover was raised, and when it went up.
    private var framesBlitted = 0
    private var coverRaisedAt = Date()

    /// - Parameters:
    ///   - surface: the presentation plane (`Reconstruction` in the daemon).
    ///   - store: the capture plane (`CaptureService`). The same object backs `surface`'s pixels.
    ///   - truth: the executor for everything else — `MockExecutor(.simulate)` at M2, the AX executor
    ///     from M3.
    ///   - config: the config file (M5). Optional because a daemon can run without hot reload — and
    ///     because every test that predates it constructs this type with three arguments.
    public init(surface: any CoverSurface, store: any CaptureStore, truth: any Executor,
                config: (any ConfigSource)? = nil) {
        self.surface = surface
        self.store = store
        self.truth = truth
        self.config = config
    }

    public func execute(_ effects: [Effect], feedback: EventSink) {
        for run in Self.runs(of: effects) {
            switch run.plane {
            case .presentation: present(run.effects, feedback: feedback)
            case .capture:      store.capture(Self.captureIds(run.effects), feedback: feedback)
            case .truth:        truth.execute(run.effects, feedback: feedback)
            // A run of reloads is one reload: the file can only be in one state, and re-reading it
            // twice in a batch would send the core two identical `configChanged` events.
            case .config:       config?.reload()
            }
        }
    }

    /// The windows named by a run of `capture` effects, in order. The run is contiguous and same-plane
    /// by construction, so this is a total unwrap rather than a filter.
    static func captureIds(_ effects: [Effect]) -> [WindowId] {
        effects.compactMap { if case .capture(let id) = $0 { id } else { nil } }
    }

    /// Split a batch into maximal contiguous same-plane runs, in order. `[begin, setFrame, setFrame]`
    /// becomes one presentation run and one truth run; a tick's blits stay a single run (and therefore
    /// a single frame).
    static func runs(of effects: [Effect]) -> [(plane: Plane, effects: [Effect])] {
        var runs: [(plane: Plane, effects: [Effect])] = []
        var index = effects.startIndex
        while index < effects.endIndex {
            let plane = self.plane(of: effects[index])
            var end = index
            while end < effects.endIndex, self.plane(of: effects[end]) == plane { end += 1 }
            runs.append((plane, Array(effects[index..<end])))
            index = end
        }
        return runs
    }

    /// Which plane executes an effect. An exhaustive `switch` on purpose: a new `Effect` case must be
    /// consciously assigned a plane rather than defaulting into one.
    static func plane(of effect: Effect) -> Plane {
        switch effect {
        case .beginTransition, .extendCover, .elevateLayer, .setLayerFrame, .endTransition:
            return .presentation
        case .capture:
            return .capture
        case .setFrame, .park, .focus, .raise:
            return .truth
        case .reloadConfig:
            return .config
        }
    }

    /// Run one presentation batch: every blit inside a single frame, then — if the batch closed the
    /// transition — the cross-fade, *after* the frame is committed. The last tick of a scroll emits its
    /// final `setLayerFrame`s and `endTransition` together, and starting the fade before committing
    /// those blits would cross-fade away from a stale frame.
    private func present(_ effects: [Effect], feedback: EventSink) {
        surface.beginFrame()
        var dismissing = false
        var blitted = false
        for effect in effects {
            switch effect {
            case .beginTransition(let bindings):
                surface.raiseCover(bindings)
                framesBlitted = 0
                coverRaisedAt = Date()
            case .extendCover(let bindings):
                // The cover grows for windows a retarget pulled into scope. The `setLayerFrame`s that
                // place them are in this same run by construction (`Engine.captureReady`), so the new
                // layers are created and positioned inside this one transaction.
                surface.extendCover(bindings)
            case .elevateLayer(let layer):
                // Deliberately *not* counted as a blit: re-stacking a layer is not a frame of motion,
                // and counting it would inflate the one smoothness instrument we have.
                surface.elevate(layer)
            case .setLayerFrame(let layer, let rect):
                surface.setLayerFrame(layer, to: rect)
                blitted = true
            case .endTransition:
                dismissing = true
            case .setFrame, .park, .capture, .focus, .raise, .reloadConfig:
                break                       // routed to another plane; unreachable here
            }
        }
        surface.endFrame()
        if blitted { framesBlitted += 1 }    // one run of blits is one frame, however many layers
        guard dismissing else { return }
        let frames = framesBlitted
        let duration = Date().timeIntervalSince(coverRaisedAt)
        // Closed here, at `endTransition`, not when the fade lands: a command arriving during the
        // 0.22 s cross-fade opens a *new* cover, and it must take its own base rather than inherit the
        // desktop of the transition currently fading away. The token keeps the two straight.
        let token = store.closeCover()
        surface.dismiss { [onCoverDismissed, store] in
            // The stills are released only once the cover is *down*. They are still on screen for the
            // whole cross-fade — `CALayer.contents` holds them — so dropping them at `endTransition`
            // would free the images the fade is fading, on the frame the user is looking hardest at.
            // And only *these* stills: `discard` ignores a token a newer cover has superseded.
            store.discard(token)
            onCoverDismissed?(frames, duration)
            feedback(.crossfadeDone)
        }
    }
}
