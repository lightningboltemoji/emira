import Foundation
import EmiraCore

// A router, not a compositor: each effect goes to the machinery that runs it — Core Animation on our
// own layers (presentation), ScreenCaptureKit (capture), AX into other processes (truth), the
// filesystem (config). Order is preserved by chunking into maximal contiguous same-plane runs rather
// than partitioning by plane, so cover-before-teleport holds because the reducer emits it that way.
// One `CATransaction` per presentation run, since a tick's blits must reach the screen as one frame
// or the lockstep motion shears; the surface opens it, keeping this file framework-free.

/// The presentation plane's mechanism: raise a cover built from the core's layer bindings, blit layer
/// frames, cross-fade away. `Reconstruction` is the real one; tests use a recording double.
@MainActor
public protocol CoverSurface: AnyObject {
    /// Open the frame every subsequent call in this run blits inside. Always balanced by `endFrame()`.
    func beginFrame()

    func endFrame()

    /// Build the reconstruction from the core's ordered bindings (z-order bottom→top) and show it.
    /// The cover is opaque from this moment, so the real windows may teleport behind it.
    func raiseCover(_ bindings: [LayerBinding])

    /// Add layers to a cover that is already up, for windows a retarget pulled into scope — above
    /// everything already there. No-op for a binding already present.
    func extendCover(_ bindings: [LayerBinding])

    /// Move one reconstruction layer to `rect` (core top-left coordinates) for this frame.
    func setLayerFrame(_ layer: LayerId, to rect: Rect)

    /// Cross-fade one layer's contents to the window's own still, which has landed since the cover was
    /// built over a stand-in. Geometry is untouched: wherever the last tick put the layer is where it
    /// stays. No-op for an absent layer, or one whose window still has nothing better to show.
    func refreshLayer(_ layer: LayerId)

    /// Move one layer to the top of the cover's z-order, where it stays until something else is
    /// elevated — which window slides *over* the one it trades places with. No-op for an absent layer.
    func elevate(_ layer: LayerId)

    /// Cross-fade the cover away and drop the reconstruction. Runs *outside* the frame — a
    /// window-alpha animation, not a layer blit.
    func dismiss(completion: @escaping @MainActor () -> Void)
}

/// The `Executor` that splits an effect batch across the two planes.
@MainActor
public final class CompositingExecutor: Executor {

    /// Which machinery executes an effect.
    enum Plane: Equatable {
        case presentation
        case capture
        case truth
        /// Outside the desktop entirely: a child process. Its own plane rather than a corner of the
        /// truth plane, because it shares nothing with AX — no window, no per-app lane, no ack.
        case system
    }

    /// Called when a cover comes down, with the frames blitted while it was up. The one smoothness
    /// measurement there is: `Spring` is analytic, so a six-frame lurch and a seventy-six-frame glide
    /// trace the same offset-vs-wall-clock curve and no state dump separates them.
    public var onCoverDismissed: (@MainActor (_ framesBlitted: Int, _ duration: TimeInterval) -> Void)?

    private let surface: any CoverSurface
    private let store: any CaptureStore
    private let truth: any Executor
    private let launcher: any ProcessLauncher
    /// Frames blitted since the current cover was raised, and when it went up.
    private var framesBlitted = 0
    private var coverRaisedAt = Date()

    /// `store` is the same object that backs `surface`'s pixels.
    public init(surface: any CoverSurface, store: any CaptureStore, truth: any Executor,
                launcher: any ProcessLauncher = ShellLauncher()) {
        self.surface = surface
        self.store = store
        self.truth = truth
        self.launcher = launcher
    }

    public func execute(_ effects: [Effect], feedback: EventSink) {
        for run in Self.runs(of: effects) {
            switch run.plane {
            case .presentation: present(run.effects, feedback: feedback)
            case .capture:      store.capture(Self.captureTargets(run.effects), feedback: feedback)
            case .truth:        truth.execute(run.effects, feedback: feedback)
            case .system:       for line in Self.execLines(run.effects) { launcher.launch(line) }
            }
        }
    }

    /// The command lines named by a run of `exec` effects, in order — a total unwrap like
    /// `captureIds`, since a run is same-plane by construction.
    static func execLines(_ effects: [Effect]) -> [String] {
        effects.compactMap { if case .exec(let line) = $0 { line } else { nil } }
    }

    /// The windows named by a run of `capture` effects, in order, each with the size the core recorded
    /// for it. The run is same-plane by construction, so this is a total unwrap, not a filter.
    static func captureTargets(_ effects: [Effect]) -> [CaptureTarget] {
        effects.compactMap {
            if case .capture(let id, let size) = $0 { CaptureTarget(id: id, size: size) } else { nil }
        }
    }

    /// Maximal contiguous same-plane runs, in order — a tick's blits stay one run, hence one frame.
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

    /// Exhaustive on purpose: a new `Effect` case must be assigned a plane, never default into one.
    static func plane(of effect: Effect) -> Plane {
        switch effect {
        case .beginTransition, .extendCover, .elevateLayer, .setLayerFrame, .refreshLayer,
             .endTransition:
            return .presentation
        case .capture:
            return .capture
        case .setFrame, .park, .focus, .raise, .closeWindow:
            return .truth
        case .exec:
            return .system
        }
    }

    /// Every blit inside a single frame, then — if the batch closed the transition — the cross-fade,
    /// *after* the frame is committed. The last tick of a scroll emits its final blits and
    /// `endTransition` together, so fading first would cross-fade away from a stale frame.
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
                // The `setLayerFrame`s that place these are in this same run, so the new layers are
                // created and positioned inside one transaction.
                surface.extendCover(bindings)
            case .elevateLayer(let layer):
                // Not counted as a blit: re-stacking is not a frame of motion.
                surface.elevate(layer)
            case .setLayerFrame(let layer, let rect):
                surface.setLayerFrame(layer, to: rect)
                blitted = true
            case .refreshLayer(let layer):
                // Not counted as a blit either: a layer sharpening in place is not a frame of motion,
                // and counting it would inflate the one smoothness measurement there is.
                surface.refreshLayer(layer)
            case .endTransition:
                dismissing = true
            case .setFrame, .park, .capture, .focus, .raise, .closeWindow, .exec:
                break                       // routed to another plane; unreachable here
            }
        }
        surface.endFrame()
        if blitted { framesBlitted += 1 }    // one run of blits is one frame, however many layers
        guard dismissing else { return }
        let frames = framesBlitted
        let duration = Date().timeIntervalSince(coverRaisedAt)
        // Closed at `endTransition`, not when the fade lands: a command arriving during the cross-fade
        // opens a *new* cover and must take its own base, not inherit the fading one's desktop.
        let token = store.closeCover()
        surface.dismiss { [onCoverDismissed, store] in
            // Released only once the cover is *down* — `CALayer.contents` holds the stills for the
            // whole cross-fade. And only *these* stills: `discard` ignores a superseded token.
            store.discard(token)
            onCoverDismissed?(frames, duration)
            feedback(.crossfadeDone)
        }
    }
}
