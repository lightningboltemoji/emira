import Foundation
import EmiraCore

// A router, not a compositor: each effect goes to the machinery that runs it — Core Animation on our
// own layers (presentation), ScreenCaptureKit (capture), AX into other processes (truth), the
// filesystem (config). Order is preserved by chunking into maximal contiguous same-plane runs rather
// than partitioning by plane, so cover-before-teleport holds because the reducer emits it that way.
// One `CATransaction` per presentation run, since a tick's blits must reach the screen as one frame
// or the lockstep motion shears — and with a display's worth of it each, one frame across *every*
// surface, or two screens shear apart instead of two layers. The plane opens it, keeping this file
// framework-free.

/// One display's presentation mechanism: raise a cover built from the core's layer bindings, blit
/// layer frames, cross-fade away. `Reconstruction` is the real one; tests use a recording double.
@MainActor
public protocol CoverSurface: AnyObject {
    /// Build the reconstruction from the core's ordered bindings (z-order bottom→top) and show it. The
    /// cover is opaque from this moment but not yet *visible*: `onScreen` is the report that the display
    /// has shown it, which is what entitles the real windows to teleport behind it. At most once per
    /// raise, and never for a cover replaced or faded before it arrives.
    func raiseCover(_ bindings: [LayerBinding], onScreen: @escaping @MainActor () -> Void)

    /// Add layers to a cover that is already up, for windows a retarget pulled into scope — above
    /// everything already there. No-op for a binding already present.
    func extendCover(_ bindings: [LayerBinding])

    /// Move one reconstruction layer to `rect` (core top-left coordinates) for this frame.
    func setLayerFrame(_ layer: LayerId, to rect: Rect)

    /// Take one layer off the screen without dropping it — the core has no rect for it this frame. The
    /// next `setLayerFrame` brings it back. No-op for an absent layer.
    func hideLayer(_ layer: LayerId)

    /// Cross-fade one layer's contents to the window's own still, which has landed since the cover was
    /// built over a stand-in. Geometry is untouched: wherever the last tick put the layer is where it
    /// stays. No-op for an absent layer, or one whose window still has nothing better to show.
    func refreshLayer(_ layer: LayerId)

    /// Move one layer to the top of the cover's z-order, where it stays until something else is
    /// elevated — which window slides *over* the one it trades places with. No-op for an absent layer.
    func elevate(_ layer: LayerId)

    /// Take the cover away and drop the reconstruction. Runs *outside* the frame — a window-alpha
    /// animation, not a layer blit. `duration` is how long the dissolve lasts; every length reveals the
    /// same desktop, since a cover is only ever taken down once the reals have landed under it.
    func dismiss(over duration: TimeInterval, completion: @escaping @MainActor () -> Void)
}

/// The whole presentation plane — every display's surface, the frame boundary their blits share, and
/// the route from a `LayerId` to the display it was minted on.
///
/// A `CoverSurface` is one display's layer tree; a `CoverPlane` is all of them at once. The transaction
/// lives here and not there because with N surfaces a frame is only a frame if it wraps every blit in
/// the run. The **cover calls name their display and the layer calls do not**: a cover belongs to one
/// screen (D7), while a `LayerId` already names one layer on one screen, so the per-frame path routes
/// on what it carries rather than being told twice.
@MainActor
public protocol CoverPlane: AnyObject {
    /// Open the frame every subsequent call in this run blits inside. Always balanced by `endFrame()`.
    func beginFrame()

    func endFrame()

    /// Build `monitor`'s reconstruction from the core's ordered bindings and show it. `onScreen` is the
    /// report that *that display* has shown it, which is what entitles the windows it covers to
    /// teleport behind it.
    func raiseCover(on monitor: MonitorId, _ bindings: [LayerBinding],
                    onScreen: @escaping @MainActor () -> Void)

    /// Add layers to `monitor`'s already-raised cover, for windows a retarget pulled into scope.
    func extendCover(on monitor: MonitorId, _ bindings: [LayerBinding])

    /// Move one reconstruction layer to `rect` this frame, on whichever display holds it.
    func setLayerFrame(_ layer: LayerId, to rect: Rect)

    /// Take one layer off the screen until it is placed again, on whichever display holds it.
    func hideLayer(_ layer: LayerId)

    /// Cross-fade one layer's contents to the window's own still, which has landed since the cover was
    /// built over a stand-in.
    func refreshLayer(_ layer: LayerId)

    /// Move one layer to the top of its cover's z-order.
    func elevate(_ layer: LayerId)

    /// Take `monitor`'s cover away and drop its reconstruction. Runs *outside* the frame — a window
    /// alpha animation, not a layer blit.
    func dismiss(on monitor: MonitorId, over duration: TimeInterval,
                 completion: @escaping @MainActor () -> Void)
}

/// The `Executor` that splits an effect batch across the two planes.
@MainActor
public final class CompositingExecutor: Executor {

    /// Which machinery executes an effect.
    enum Plane: Equatable {
        case presentation
        case capture
        case truth
        /// The cursor. Not the presentation plane: it composites above our overlay as it does above
        /// every other window, which is the whole reason it needs hiding at all.
        case pointer
        /// Outside the desktop entirely: a child process. Its own plane rather than a corner of the
        /// truth plane, because it shares nothing with AX — no window, no per-app lane, no ack.
        case system
    }

    /// Called when a cover comes down, with the frames blitted while *it* was up. The one smoothness
    /// measurement there is: `Spring` is analytic, so a six-frame lurch and a seventy-six-frame glide
    /// trace the same offset-vs-wall-clock curve and no state dump separates them. Reported per
    /// display, since two covers are two transitions and averaging them would describe neither.
    public var onCoverDismissed: (@MainActor (_ monitor: MonitorId, _ framesBlitted: Int,
                                              _ duration: TimeInterval) -> Void)?

    /// The mode a cover being taken down was raised under, read for one decision: how long it takes to
    /// leave. What a mode does to the *geometry* is settled in the core.
    public var transitionMode: TransitionMode = .smooth

    /// A cover's exit, per mode — long enough to carry a window that redrew underneath it, short enough
    /// not to be the slowest thing in the transition it ends. Calibrated by eye, and free to be: a cover
    /// comes down only onto a desktop that already matches it, so no length hides a geometry difference.
    static let smoothFade: TimeInterval = 0.22
    static let snapFade: TimeInterval = 0.04

    var dismissalDuration: TimeInterval {
        switch transitionMode {
        case .smooth:     Self.smoothFade
        // `off` raises no cover of its own; it can only price the exit of one whose transition outlived a
        // reload, where two frames and the cut it would otherwise get are the same thing to look at.
        case .snap, .off: Self.snapFade
        }
    }

    private let surface: any CoverPlane
    private let store: any CaptureStore
    private let truth: any Executor
    private let pointer: any Executor
    private let launcher: any ProcessLauncher
    /// Per display, frames blitted since that cover was raised and when it went up. One run of blits
    /// counts as a frame for every cover that is up: a tick emits the layer frames of every cover with
    /// motion to make in one run, so the alternative would need this file to know which display a
    /// `LayerId` is on — which is exactly the routing D11 keeps in the plane.
    private var framesBlitted: [MonitorId: Int] = [:]
    private var coverRaisedAt: [MonitorId: Date] = [:]

    /// `store` is the same object that backs `surface`'s pixels.
    public init(surface: any CoverPlane, store: any CaptureStore, truth: any Executor,
                pointer: any Executor, launcher: any ProcessLauncher = ShellLauncher()) {
        self.surface = surface
        self.store = store
        self.truth = truth
        self.pointer = pointer
        self.launcher = launcher
    }

    public func execute(_ effects: [Effect], feedback: EventSink) {
        for run in Self.runs(of: effects) {
            switch run.plane {
            case .presentation: present(run.effects, feedback: feedback)
            case .capture:
                // One batch per cover, because a batch either opens one — and owes that display's
                // base — or grows one. Grouped rather than split per effect, so a scope stays one
                // batch and pays one `SCShareableContent` fetch.
                for batch in Self.captureTargets(run.effects) {
                    store.capture(batch.targets, on: batch.monitor, feedback: feedback)
                }
            case .truth:        truth.execute(run.effects, feedback: feedback)
            case .pointer:      pointer.execute(run.effects, feedback: feedback)
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
    /// for it — grouped into one batch per cover, in the order the covers first appear. The run is
    /// same-plane by construction, so this is a total unwrap, not a filter.
    static func captureTargets(_ effects: [Effect]) -> [(monitor: MonitorId, targets: [CaptureTarget])] {
        var order: [MonitorId] = []
        var batches: [MonitorId: [CaptureTarget]] = [:]
        for effect in effects {
            guard case .capture(let monitor, let id, let size) = effect else { continue }
            if batches[monitor] == nil { order.append(monitor) }
            batches[monitor, default: []].append(CaptureTarget(id: id, size: size))
        }
        return order.map { ($0, batches[$0] ?? []) }
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
        case .beginTransition, .extendCover, .elevateLayer, .setLayerFrame, .hideLayer, .refreshLayer,
             .endTransition:
            return .presentation
        case .capture:
            return .capture
        case .setFrame, .park, .focus, .raise, .closeWindow:
            return .truth
        case .setCursorHidden, .warpPointer:
            return .pointer
        case .exec:
            return .system
        }
    }

    /// Every blit inside a single frame, then — for each display the batch closed — that dismissal,
    /// *after* the frame is committed. The last tick of a scroll emits its final blits and
    /// `endTransition` together, so dismissing first would fade away from, or cut to, a stale frame.
    ///
    /// One frame still spans every display in the run (that is what the transaction is for), while the
    /// raises and dismissals inside it are each one screen's.
    private func present(_ effects: [Effect], feedback: EventSink) {
        surface.beginFrame()
        var dismissing: [MonitorId] = []
        var blitted = false
        for effect in effects {
            switch effect {
            case .beginTransition(let monitor, let bindings):
                surface.raiseCover(on: monitor, bindings) { feedback(.coverOnScreen(monitor)) }
                framesBlitted[monitor] = 0
                coverRaisedAt[monitor] = Date()
            case .extendCover(let monitor, let bindings):
                // The `setLayerFrame`s that place these are in this same run, so the new layers are
                // created and positioned inside one transaction.
                surface.extendCover(on: monitor, bindings)
            case .elevateLayer(let layer):
                // Not counted as a blit: re-stacking is not a frame of motion.
                surface.elevate(layer)
            case .setLayerFrame(let layer, let rect):
                surface.setLayerFrame(layer, to: rect)
                blitted = true
            case .hideLayer(let layer):
                // Not counted as a blit: a stand-in leaving the screen is a correction, not a frame of
                // motion, and the pass that emits it emits the moving layers' frames in the same run.
                surface.hideLayer(layer)
            case .refreshLayer(let layer):
                // Not counted as a blit either: a layer sharpening in place is not a frame of motion,
                // and counting it would inflate the one smoothness measurement there is.
                surface.refreshLayer(layer)
            case .endTransition(let monitor):
                dismissing.append(monitor)
            case .setFrame, .park, .capture, .focus, .raise, .closeWindow, .setCursorHidden,
                 .warpPointer, .exec:
                break                       // routed to another plane; unreachable here
            }
        }
        surface.endFrame()
        // One run of blits is one frame, however many layers and however many screens they reached.
        if blitted { for monitor in Array(framesBlitted.keys) { framesBlitted[monitor]? += 1 } }
        for monitor in dismissing { dismiss(monitor, feedback: feedback) }
    }

    /// Take one display's cover down and report what it cost.
    private func dismiss(_ monitor: MonitorId, feedback: EventSink) {
        let frames = framesBlitted.removeValue(forKey: monitor) ?? 0
        let duration = Date().timeIntervalSince(coverRaisedAt.removeValue(forKey: monitor) ?? Date())
        // Closed at `endTransition`, not when the fade lands: a command arriving during the cross-fade
        // opens a *new* cover on that display and must take its own base, not inherit the fading one's
        // desktop.
        let token = store.closeCover(on: monitor)
        surface.dismiss(on: monitor, over: dismissalDuration) { [onCoverDismissed, store] in
            // Released only once the cover is *down* — `CALayer.contents` holds the stills for the
            // whole cross-fade. And only *these* stills: `discard` ignores a superseded token.
            store.discard(token)
            onCoverDismissed?(monitor, frames, duration)
            feedback(.crossfadeDone(monitor))
        }
    }
}
