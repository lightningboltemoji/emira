import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// The scripted world every reducer suite drives. `Engine.reduce` is a total function over
// (`State`, `Event`), so a fixture here is just a way of saying "a desktop in this shape" —
// no AX, Core Animation or ScreenCaptureKit anywhere.

enum EngineFix {

    /// A 1000×800 display at the origin, ⅓/½/⅔ widths, no gaps/struts — unless overridden.
    static let displayFrame = Rect(x: 0, y: 0, width: 1000, height: 800)

    /// Config with a single ½-width preset — makes off-viewport columns crisp: two 500-wide columns
    /// fill a 1000-wide viewport exactly, so a third column is unambiguously off-view.
    static let halfWidth = Config(widthPresets: PresetCycle([.proportion(0.5)]))

    /// `halfWidth`, but snapping — for tests about *where* windows end up, not how they get there:
    /// under the animated path the reals teleport at the cover's raise, not in the command's own batch.
    static let halfWidthSnap = Config(widthPresets: PresetCycle([.proportion(0.5)]),
                                      transitionMode: .off)

    /// Config with a single full-width preset — one column *is* the viewport, so every focus change
    /// across columns genuinely scrolls (each column exactly fills, the neighbours are off-view). This
    /// is what makes the animated-scroll paths fire; ½-width lets two columns coexist and often snaps.
    static let fullWidth = Config(widthPresets: PresetCycle([.proportion(1.0)]))

    /// A fresh state that already knows about one display.
    static func booted(config: Config = Config(), display: Rect = displayFrame) -> State {
        let (s, _) = Engine.reduce(State(config: config),
                                   .screensChanged([MonitorInfo(id: MonitorId(1), frame: display)]))
        return s
    }

    static func snapshot(_ raw: UInt64, bundle: String = "com.test.app", title: String = "w",
                         role: WindowRole = .standard, frame: Rect = Rect(x: 300, y: 300, width: 200, height: 200),
                         wasAlreadyOpen: Bool = false) -> WindowSnapshot {
        WindowSnapshot(id: WindowId(raw), bundleId: bundle, title: title, role: role, frame: frame,
                       wasAlreadyOpen: wasAlreadyOpen)
    }

    /// Drive a state to rest: answer every capture, land every AX set, and tick until the animators
    /// settle. What a real daemon does over ~300 ms, with no clock in it. An arrival animates, so a
    /// test wanting "a placed world" has to close the transition rather than assume instant placement.
    static func settle(_ start: State, _ effects: [Effect] = []) -> State {
        var s = start
        var queue = effects
        for _ in 0..<4000 {
            var feedback: [Event] = []
            for effect in queue {
                switch effect {
                case .capture(_, let w, _): feedback.append(.captureReady(w))
                case .beginTransition(let m, _): feedback.append(.coverOnScreen(m))
                case .setFrame(let w, _), .park(let w, _): feedback.append(.axLanded(w))
                default: continue
                }
            }
            queue = []
            if feedback.isEmpty {
                guard s.motion.isTransitioning else { return s }
                feedback = [.tick(dt: 1.0 / 120)]
            }
            for event in feedback {
                let (next, out) = Engine.reduce(s, event)
                s = next
                queue += out
            }
        }
        return s
    }

    /// A booted state holding `count` tiled windows, at rest — the ordinary "given a world" setup.
    static func world(_ count: UInt64, config: Config = Config()) -> State {
        var s = booted(config: config)
        for raw in 1...count {
            let (next, fx) = Engine.reduce(s, .windowCreated(snapshot(raw)))
            s = settle(next, fx)
        }
        return s
    }

    /// Drive a sequence of events, returning the final state and the concatenated effect stream.
    static func run(_ start: State, _ events: [Event]) -> (State, [Effect]) {
        var s = start
        var effects: [Effect] = []
        for e in events {
            let wasIdle = !s.motion.isTransitioning
            let (next, fx) = Engine.reduce(s, e)
            s = next
            effects += fx
            // World setup is not the thing under test: a `windowCreated` that *opened* a transition is
            // driven to rest here, or every test that builds a world would assert against a half-raised
            // cover. An arrival joining a transition already in flight is deliberately left alone.
            if wasIdle, isArrival(e), s.motion.isTransitioning { s = settle(s, fx) }
        }
        return (s, effects)
    }

    /// Whether an event puts a window *onto* the strip, and therefore animates.
    static func isArrival(_ event: Event) -> Bool {
        switch event {
        case .windowCreated, .windowDeminimized: return true
        default: return false
        }
    }

    static func approx(_ a: Rect, _ b: Rect, tol: Double = 0.01) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol &&
        abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    /// The `Rect` a `setFrame`/`park` effect targeted the given window with, or `nil`.
    static func placement(of id: WindowId, in effects: [Effect]) -> Rect? {
        for e in effects {
            switch e {
            case .setFrame(let w, let r) where w == id: return r
            case .park(let w, let r) where w == id: return r
            default: continue
            }
        }
        return nil
    }

    static func approxScalar(_ a: Double, _ b: Double, tol: Double = 0.5) -> Bool { abs(a - b) <= tol }

    /// The window ids a run of `.capture` effects requested, in order.
    static func capturedIds(in fx: [Effect]) -> [WindowId] {
        fx.compactMap { if case .capture(_, let w, _) = $0 { return w }; return nil }
    }

    /// The `Rect` a `.setLayerFrame` targeted the given layer with (last wins), or `nil`.
    static func layerFrame(of layer: LayerId, in fx: [Effect]) -> Rect? {
        var found: Rect?
        for e in fx { if case .setLayerFrame(let l, let r) = e, l == layer { found = r } }
        return found
    }

    static func hasEffect(_ fx: [Effect], _ predicate: (Effect) -> Bool) -> Bool { fx.contains(where: predicate) }

    /// Drive an open transition to close: deliver every scoped `captureReady` (raises the cover), report
    /// the cover on screen (which teleports the reals), land every awaited real, then tick until the
    /// session tears down. Bounded so a non-converging spring fails loudly instead of hanging;
    /// idempotent from any point mid-flight.
    static func drive(_ start: State) -> (State, [Effect]) {
        var s = start
        var fx: [Effect] = []
        func feed(_ e: Event) { let (n, f) = Engine.reduce(s, e); s = n; fx += f }

        // Every display with a cover in flight, since a command can leave more than one open.
        for monitor in s.motion.transitioningMonitors {
            for w in s.motion.transition(of: monitor)?.windows ?? [] { feed(.captureReady(w)) }
            feed(.coverOnScreen(monitor))
        }
        for monitor in s.motion.transitioningMonitors {
            for w in s.motion.transition(of: monitor)?.awaitingLanding ?? [] { feed(.axLanded(w)) }
        }
        var guardCount = 0
        while s.motion.isTransitioning && guardCount < 5000 {
            feed(.tick(dt: 1.0 / 120))
            guardCount += 1
        }
        return (s, fx)
    }

    /// A frame-stepped world with latency — the one thing `drive` cannot model, since it acks every
    /// capture synchronously and so cannot see a hole that exists only between a `capture` and its
    /// `captureReady`. Here effects resolve a fixed number of frames later while commands keep arriving.
    /// Shared with `WorkspaceMotionTests`: a second copy of a clock is a second clock.
    struct LatentWorld {
        var state: State
        var frame = 0
        let captureLatency: Int
        let axLatency = 2
        /// A raise reaches the glass a refresh after it is committed — the one latency here that is a
        /// display fact rather than an IPC.
        let coverLatency = 1
        var inbox: [Int: [Event]] = [:]

        init(_ state: State, captureLatency: Int) {
            self.state = state
            self.captureLatency = captureLatency
        }

        mutating func send(_ event: Event) {
            let (next, fx) = Engine.reduce(state, event)
            state = next
            for e in fx {
                switch e {
                case .capture(_, let w, _):
                    inbox[frame + captureLatency, default: []].append(.captureReady(w))
                case .beginTransition(let m, _):
                    inbox[frame + coverLatency, default: []].append(.coverOnScreen(m))
                case .setFrame(let w, _), .park(let w, _):
                    inbox[frame + axLatency, default: []].append(.axLanded(w))
                default: break
                }
            }
        }

        mutating func step() {
            for e in inbox.removeValue(forKey: frame) ?? [] { send(e) }
            send(.tick(dt: 1.0 / 120))
            frame += 1
        }

        /// The thickest stripe of viewport a window wants to occupy and has no layer to be drawn with —
        /// i.e. how much wallpaper the cover is showing where a window should be. Zero unless the cover
        /// is up: before the raise the user is looking at the real desktop, which is not a hole.
        ///
        /// Asked of every workspace, clipped on both axes, and reported as the exposed rectangle's
        /// *shorter* side — a workspace one screen up or down overlaps horizontally the whole time it is
        /// off screen, so a horizontal-only measure would read as a permanent full-width hole. The
        /// shorter side is how far into the screen the exposure actually reaches.
        func hole() -> Double {
            guard let monitor = state.monitors.focused, state.motion.isCovered(on: monitor),
                  let metrics = state.metrics() else { return 0 }
            let view = metrics.workingArea
            let frames = state.workspaces.naturalFrames(
                shown: state.monitors.shown,
                among: state.monitors.owned,
                scrollOffset: state.viewport.offset.current,
                metrics: metrics,
                widths: state.motion.currentColumnWidths)
            var worst = 0.0
            for id in state.workspaces.allWindowIds where state.motion.layerIds(for: id).isEmpty {
                guard let natural = frames[id] else { continue }
                // Exactly the rect `Engine.emitLayerFrames` would blit, if this window had a layer.
                let f = natural.displaced(by: state.motion.displacement(of: id))
                let width = min(min(f.maxX, view.maxX) - max(f.minX, view.minX), view.width)
                let height = min(min(f.maxY, view.maxY) - max(f.minY, view.minY), view.height)
                guard width > 0, height > 0 else { continue }
                worst = max(worst, min(width, height))
            }
            return worst
        }
    }

    /// A snapping world with one preset, so a column's width is only ever what `grow`/`shrink` made it.
    /// Snapping because these tests are about *what* width results, not how it gets there.
    static func oneThirdSnap() -> State {
        let config = Config(widthPresets: PresetCycle([.proportion(1.0 / 3.0)]),
                            transitionMode: .off)
        return Self.run(Self.booted(config: config),
                        [.windowCreated(Self.snapshot(1))]).0
    }

    /// The column's resolved width right now.
    static func width(_ s: State, _ index: Int = 0) -> Double {
        s.layout.resolvedWidth(of: s.layout.columns[index], metrics: s.metrics()!)
    }

    /// Two ⅓ columns on a 1000-wide display: 333⅓ each, at x = 0 and x = 333⅓. `third` is that width.
    static let third = 1000.0 / 3.0

}
