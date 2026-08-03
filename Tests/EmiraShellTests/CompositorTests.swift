import CoreGraphics
import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The presentation plane's tests: the Y-flip (`ScreenGeometry`), where core top-left coordinates
// become Cocoa bottom-left ones and the inset cover's local space is computed, and the routing and
// framing (`CompositingExecutor`) — effects reaching the right plane in emission order, every
// presentation run wrapped in exactly one frame. `Overlay`, `Reconstruction` and `DisplayLinkDriver`
// need a window server and hold no decisions, hence `CoverSurface` and `FrameClock` being protocols.

@Suite struct ScreenGeometryTests {

    /// A 1000 pt-tall primary display.
    static let geometry = ScreenGeometry(flipHeight: 1000)

    @Test func aRectAtTheTopOfTheScreenLandsAtTheTopInCocoaToo() {
        // Core: 50 pt tall, hugging the top edge (y grows down). Cocoa: its *bottom* edge is at 950.
        let cocoa = Self.geometry.cocoa(Rect(x: 100, y: 0, width: 200, height: 50))
        #expect(cocoa == CGRect(x: 100, y: 950, width: 200, height: 50))
    }

    @Test func aRectAtTheBottomOfTheScreenLandsAtTheCocoaOrigin() {
        let cocoa = Self.geometry.cocoa(Rect(x: 0, y: 900, width: 300, height: 100))
        #expect(cocoa == CGRect(x: 0, y: 0, width: 300, height: 100))
    }

    @Test func theFlipIsItsOwnInverse() {
        // Including the cases the strip actually produces: negative x (parked far off the left of the
        // ribbon) and a rect taller than the screen.
        let rects = [Rect(x: 0, y: 0, width: 100, height: 100),
                     Rect(x: -4200, y: 37, width: 640, height: 460),
                     Rect(x: 1512, y: -300, width: 1000, height: 1400)]
        for rect in rects {
            #expect(Self.geometry.core(Self.geometry.cocoa(rect)) == rect)
        }
    }

    @Test func aDisplayAboveThePrimaryHasNegativeCoreY() {
        // A second screen stacked on top of the primary: Cocoa y 1000…1600, i.e. core y −600…0.
        let core = Self.geometry.core(CGRect(x: 0, y: 1000, width: 1920, height: 600))
        #expect(core == Rect(x: 0, y: -600, width: 1920, height: 600))
    }

    // The cover's local space

    /// The cover is inset past the menu bar, so `local` and `cocoa` differ — this is the arithmetic
    /// that decides whether a window layer is drawn where the window is.
    @Test func aWindowAtTheTopOfTheWorkingAreaSitsAtTheCoversTopEdge() {
        // A 1000-tall display with a 25 pt menu bar: the cover's Cocoa frame is y 0…975.
        let cover = Self.geometry.cocoa(Rect(x: 0, y: 25, width: 800, height: 975))
        #expect(cover == CGRect(x: 0, y: 0, width: 800, height: 975))
        // A window tiled at the very top of the working area sits flush with the cover's top edge.
        let top = Self.geometry.local(Rect(x: 100, y: 25, width: 200, height: 50), in: cover)
        #expect(top == CGRect(x: 100, y: 925, width: 200, height: 50))
    }

    /// The desktop base is a capture of the whole display, so inside an inset cover its layer hangs off
    /// each edge by that strut. Wrong, it slides the wallpaper by the height of the menu bar.
    @Test func theDisplayBaseOverhangsAnInsetCoverByTheStrut() {
        let display = Rect(x: 0, y: 0, width: 800, height: 1000)
        let cover = Self.geometry.cocoa(display.inset(by: EdgeInsets(top: 25, bottom: 60)))
        let base = Self.geometry.local(display, in: cover)
        #expect(base.width == 800 && base.height == 1000)        // still the whole display…
        #expect(base.origin == CGPoint(x: 0, y: -60))            // …hanging below by the Dock strut
        #expect(base.maxY == 940)                                // …and above by the menu bar's 25
    }

    /// A left-edge Dock (or an outer margin) insets horizontally, which the vertical-only cases above
    /// would not catch — the flip touches `y` only, so an `x` error here has nothing to cancel it.
    @Test func localHandlesAnInsetOnTheHorizontalEdgesToo() {
        let display = Rect(x: 0, y: 0, width: 800, height: 1000)
        let cover = Self.geometry.cocoa(display.inset(by: EdgeInsets(left: 70, right: 10)))
        #expect(cover.origin.x == 70)
        #expect(Self.geometry.local(display, in: cover).origin.x == -70)
        // A window at the working area's left edge is at the cover's local origin, not the display's.
        let tile = Self.geometry.local(Rect(x: 70, y: 0, width: 100, height: 1000), in: cover)
        #expect(tile == CGRect(x: 0, y: 0, width: 100, height: 1000))
    }
}

// Routing & frame boundaries

@Suite @MainActor struct CompositingExecutorTests {

    static let bindings = [LayerBinding(window: WindowId(1), layer: LayerId(1)),
                           LayerBinding(window: WindowId(2), layer: LayerId(2))]

    static func rect(_ x: Double) -> Rect { Rect(x: x, y: 0, width: 100, height: 100) }

    /// One shared, ordered log across *both* planes — the only way to assert that a truth-plane effect
    /// ran between two presentation ones.
    @MainActor final class Timeline {
        private(set) var entries: [String] = []
        func record(_ entry: String) { entries.append(entry) }
    }

    @MainActor final class RecordingPlane: CoverPlane {
        let timeline: Timeline
        /// Hold the dismissal open instead of completing it, to model a cross-fade in flight.
        var completesDismissal = true
        private(set) var heldCompletion: (@MainActor () -> Void)?
        /// The last raise's presentation fence, always held: a real one is a refresh away, so firing it
        /// from inside `raiseCover` would model the very thing the fence exists to prevent.
        private(set) var heldFence: (@MainActor () -> Void)?

        init(_ timeline: Timeline) { self.timeline = timeline }

        func beginFrame() { timeline.record("beginFrame") }
        func endFrame() { timeline.record("endFrame") }
        func raiseCover(on monitor: MonitorId, _ bindings: [LayerBinding],
                        onScreen: @escaping @MainActor () -> Void) {
            timeline.record("raise@\(monitor.raw)(\(bindings.map { "\($0.layer.raw)" }.joined(separator: ",")))")
            heldFence = onScreen
        }
        func extendCover(on monitor: MonitorId, _ bindings: [LayerBinding]) {
            timeline.record("extend@\(monitor.raw)(\(bindings.map { "\($0.layer.raw)" }.joined(separator: ",")))")
        }
        func elevate(_ layer: LayerId) {
            timeline.record("elevate(\(layer.raw))")
        }
        func setLayerFrame(_ layer: LayerId, to rect: Rect) {
            timeline.record("blit(\(layer.raw)@\(Int(rect.minX)))")
        }
        func refreshLayer(_ layer: LayerId) {
            timeline.record("refresh(\(layer.raw))")
        }
        /// How long the last dismissal was asked to take — the number, where the timeline only keeps the
        /// fact that something left the screen.
        private(set) var dismissedOver: TimeInterval?

        func dismiss(on monitor: MonitorId, over duration: TimeInterval,
                     completion: @escaping @MainActor () -> Void) {
            dismissedOver = duration
            timeline.record("dismiss@\(monitor.raw)")
            if completesDismissal { completion() } else { heldCompletion = completion }
        }
    }

    @MainActor final class RecordingTruth: Executor {
        let timeline: Timeline
        private(set) var batches: [[Effect]] = []

        init(_ timeline: Timeline) { self.timeline = timeline }

        func execute(_ effects: [Effect], feedback: EventSink) {
            batches.append(effects)
            timeline.record("truth[\(effects.map(Self.name).joined(separator: ","))]")
        }

        static func name(_ effect: Effect) -> String {
            switch effect {
            case .setFrame(let w, _):  return "setFrame\(w.raw)"
            case .park(let w, _):      return "park\(w.raw)"
            case .capture(_, let w, _): return "capture\(w.raw)"
            case .focus(let w):        return "focus\(w.raw)"
            case .raise(let w):        return "raise\(w.raw)"
            default:                   return "?"
            }
        }
    }

    /// A `CaptureStore` that records rather than captures. It acks nothing — the ack is
    /// `CaptureService`'s job and is proved in `CaptureTests`; here we only care *what reached it*.
    @MainActor final class RecordingStore: CaptureStore {
        let timeline: Timeline
        private(set) var requests: [[CaptureTarget]] = []
        private(set) var discards = 0
        private(set) var closes = 0
        /// The tokens `discard` was handed, so a test can prove the executor gave back the one
        /// `closeCover` minted for *its* cover rather than whatever the store held at fade time.
        private(set) var discarded: [CoverToken] = []
        /// Handed out by `closeCover`, distinct per call.
        private var nextToken = 0

        init(_ timeline: Timeline) { self.timeline = timeline }

        func capture(_ targets: [CaptureTarget], on monitor: MonitorId, feedback: EventSink) {
            requests.append(targets)
            timeline.record("capture@\(monitor.raw)[\(targets.map { "\($0.id.raw)" }.joined(separator: ","))]")
        }
        func surface(for window: WindowId) -> CapturedSurface? { nil }
        func base(of monitor: MonitorId) -> CGImage? { nil }
        func closeCover(on monitor: MonitorId) -> CoverToken {
            closes += 1
            nextToken += 1
            timeline.record("closeCover@\(monitor.raw)")
            return CoverToken(monitor, nextToken)
        }
        func discard(_ token: CoverToken) {
            discards += 1
            discarded.append(token)
            timeline.record("discard")
        }
    }

    /// The pointer plane's recorder. Its own executor rather than a second `RecordingTruth`, so a test
    /// can say that a hide reached the cursor and *not* the AX lanes.
    @MainActor final class RecordingPointer: Executor {
        let timeline: Timeline
        private(set) var batches: [[Effect]] = []

        init(_ timeline: Timeline) { self.timeline = timeline }

        func execute(_ effects: [Effect], feedback: EventSink) {
            batches.append(effects)
            timeline.record("pointer[\(effects.map(Self.name).joined(separator: ","))]")
        }

        static func name(_ effect: Effect) -> String {
            switch effect {
            case .setCursorHidden(let hidden): return hidden ? "hide" : "show"
            case .warpPointer(let rect):      return "warp@\(Int(rect.midX))"
            default:                          return "?"
            }
        }
    }

    /// A `ProcessLauncher` that records instead of spawning — the point of the seam.
    @MainActor final class RecordingLauncher: ProcessLauncher {
        let timeline: Timeline
        private(set) var launched: [String] = []

        init(_ timeline: Timeline) { self.timeline = timeline }

        func launch(_ line: String) {
            launched.append(line)
            timeline.record("exec[\(line)]")
        }
    }

    @MainActor final class EventLog {
        private(set) var events: [Event] = []
        lazy var sink = EventSink { [self] event in events.append(event) }
    }

    /// A wired-up executor plus the recorders behind it.
    static func harness() -> (CompositingExecutor, RecordingPlane, RecordingTruth, Timeline, EventLog) {
        let (executor, surface, truth, _, timeline, log) = fullHarness()
        return (executor, surface, truth, timeline, log)
    }

    /// The same, with the capture plane's recorder exposed.
    static func fullHarness() -> (CompositingExecutor, RecordingPlane, RecordingTruth,
                                  RecordingStore, Timeline, EventLog) {
        let timeline = Timeline()
        let surface = RecordingPlane(timeline)
        let truth = RecordingTruth(timeline)
        let store = RecordingStore(timeline)
        return (CompositingExecutor(surface: surface, store: store, truth: truth,
                                    pointer: RecordingPointer(timeline),
                                    launcher: RecordingLauncher(timeline)),
                surface, truth, store, timeline, EventLog())
    }

    /// The system plane's harness — the launcher is the only recorder a test about `exec` reads.
    static func execHarness() -> (CompositingExecutor, RecordingLauncher, Timeline, EventLog) {
        let timeline = Timeline()
        let launcher = RecordingLauncher(timeline)
        return (CompositingExecutor(surface: RecordingPlane(timeline),
                                    store: RecordingStore(timeline),
                                    truth: RecordingTruth(timeline),
                                    pointer: RecordingPointer(timeline),
                                    launcher: launcher),
                launcher, timeline, EventLog())
    }

    /// The pointer plane's harness — the cursor and the truth plane, so a test can say which one a
    /// batch reached.
    static func pointerHarness() -> (CompositingExecutor, RecordingPointer, RecordingTruth,
                                     Timeline, EventLog) {
        let timeline = Timeline()
        let pointer = RecordingPointer(timeline)
        let truth = RecordingTruth(timeline)
        return (CompositingExecutor(surface: RecordingPlane(timeline),
                                    store: RecordingStore(timeline),
                                    truth: truth, pointer: pointer,
                                    launcher: RecordingLauncher(timeline)),
                pointer, truth, timeline, EventLog())
    }

    @Test func everyEffectIsAssignedToAPlane() {
        #expect(CompositingExecutor.plane(of: .beginTransition(MonitorId(1), [])) == .presentation)
        #expect(CompositingExecutor.plane(of: .extendCover(MonitorId(1), [])) == .presentation)
        #expect(CompositingExecutor.plane(of: .setLayerFrame(LayerId(1), .zero)) == .presentation)
        #expect(CompositingExecutor.plane(of: .endTransition(MonitorId(1))) == .presentation)
        #expect(CompositingExecutor.plane(of: .setFrame(WindowId(1), .zero)) == .truth)
        #expect(CompositingExecutor.plane(of: .park(WindowId(1), .zero)) == .truth)
        #expect(CompositingExecutor.plane(of: .focus(WindowId(1))) == .truth)
        #expect(CompositingExecutor.plane(of: .raise(WindowId(1))) == .truth)
        #expect(CompositingExecutor.plane(of: .closeWindow(WindowId(1))) == .truth)
        #expect(CompositingExecutor.plane(of: .capture(MonitorId(1), WindowId(1), size: .zero)) == .capture)
        #expect(CompositingExecutor.plane(of: .refreshLayer(LayerId(1))) == .presentation)
        #expect(CompositingExecutor.plane(of: .setCursorHidden(true)) == .pointer)
        #expect(CompositingExecutor.plane(of: .warpPointer(into: .zero)) == .pointer)
        #expect(CompositingExecutor.plane(of: .exec("ghostty")) == .system)
    }

    /// The hide the reducer prepends reaches the cursor and nothing else, and it stays *in front of*
    /// the placement it was prepended to — the pointer is gone before the first window moves under it.
    @Test func aHideReachesThePointerPlaneAheadOfTheTruthPlane() {
        let (executor, pointer, truth, timeline, log) = Self.pointerHarness()
        executor.execute([.setCursorHidden(true), .setFrame(WindowId(1), .zero)], feedback: log.sink)
        #expect(timeline.entries == ["pointer[hide]", "truth[setFrame1]"])
        #expect(pointer.batches == [[.setCursorHidden(true)]])
        #expect(truth.batches.count == 1)
    }

    /// A spawn reaches the launcher and touches nothing else — it shares no machinery with AX, which
    /// is why it is a plane of its own rather than a corner of the truth plane.
    @Test func anExecReachesTheLauncherAndNoOtherPlane() {
        let (executor, launcher, timeline, log) = Self.execHarness()
        let line = "osascript -e 'tell application \"Ghostty\" to new window'"
        executor.execute([.exec(line)], feedback: log.sink)

        #expect(launcher.launched == [line])
        #expect(timeline.entries == ["exec[\(line)]"])
        #expect(log.events.isEmpty)             // unacked by contract
    }

    /// And it takes its place in emission order like any other plane change.
    @Test func execKeepsItsPlaceInEmissionOrder() {
        let (executor, launcher, timeline, log) = Self.execHarness()
        executor.execute([.focus(WindowId(1)), .exec("a"), .exec("b"), .raise(WindowId(2))],
                         feedback: log.sink)

        // Two contiguous execs are one run, and each line is launched, in order.
        #expect(launcher.launched == ["a", "b"])
        #expect(timeline.entries == ["truth[focus1]", "exec[a]", "exec[b]", "truth[raise2]"])
    }

    @Test func aBatchIsSplitIntoMaximalContiguousRuns() {
        let runs = CompositingExecutor.runs(of: [
            .beginTransition(MonitorId(1), Self.bindings),
            .setFrame(WindowId(1), Self.rect(0)),
            .park(WindowId(2), Self.rect(0)),
            .setLayerFrame(LayerId(1), Self.rect(0)),
        ])
        #expect(runs.map(\.plane) == [.presentation, .truth, .presentation])
        #expect(runs.map(\.effects.count) == [1, 2, 1])
    }

    @Test func anEmptyBatchProducesNoRuns() {
        #expect(CompositingExecutor.runs(of: []).isEmpty)
    }

    @Test func theCoverIsRaisedBeforeTheRealWindowsTeleport() {
        // Emission order across a plane change, asked of a batch the reducer does not build — it holds
        // the teleports for `coverOnScreen`. The routing rule stands on its own: nothing may reach the
        // truth plane ahead of a presentation effect that precedes it.
        let (executor, _, _, timeline, log) = Self.harness()
        executor.execute([.beginTransition(MonitorId(1), Self.bindings),
                          .setFrame(WindowId(1), Self.rect(0)),
                          .park(WindowId(2), Self.rect(9999))], feedback: log.sink)

        #expect(timeline.entries == ["beginFrame", "raise@1(1,2)", "endFrame", "truth[setFrame1,park2]"])
    }

    /// The raise is handed a fence, and only the fence acks: a cover that has been committed but not
    /// composed hides nothing, so the call itself is not the report.
    @Test func theRaiseAcksOnlyWhenTheCoverReachesTheScreen() {
        let (executor, surface, _, _, log) = Self.harness()
        executor.execute([.beginTransition(MonitorId(1), Self.bindings)], feedback: log.sink)

        #expect(log.events.isEmpty)             // committed, not composed — nothing may move yet
        surface.heldFence?()
        #expect(log.events == [.coverOnScreen(MonitorId(1))])
    }

    @Test func emissionOrderSurvivesAPlaneChangeInEitherDirection() {
        // A batch that goes truth → presentation → truth. A "presentation first, then the rest"
        // partition would reorder this; contiguous runs don't.
        let (executor, _, _, timeline, log) = Self.harness()
        executor.execute([.focus(WindowId(1)),
                          .setLayerFrame(LayerId(1), Self.rect(10)),
                          .raise(WindowId(2))], feedback: log.sink)

        #expect(timeline.entries == ["truth[focus1]", "beginFrame", "blit(1@10)", "endFrame",
                                     "truth[raise2]"])
    }

    @Test func aTicksBlitsAllLandInOneFrame() {
        let (executor, _, _, timeline, log) = Self.harness()
        executor.execute([.setLayerFrame(LayerId(1), Self.rect(10)),
                          .setLayerFrame(LayerId(2), Self.rect(20)),
                          .setLayerFrame(LayerId(3), Self.rect(30))], feedback: log.sink)

        #expect(timeline.entries == ["beginFrame", "blit(1@10)", "blit(2@20)", "blit(3@30)", "endFrame"])
    }

    @Test func aTruthOnlyBatchOpensNoFrame() {
        let (executor, _, truth, timeline, log) = Self.harness()
        executor.execute([.focus(WindowId(1)), .raise(WindowId(2))], feedback: log.sink)

        #expect(!timeline.entries.contains("beginFrame"))
        #expect(truth.batches == [[.focus(WindowId(1)), .raise(WindowId(2))]])
    }

    /// A run of `capture`s reaches the store as one call, not one per window: the batch is the unit —
    /// one shareable-content fetch, one fan-out, one set of acks. Each window's recorded size travels
    /// with it, because that is what decides whether a kept still may stand in for a fresh capture.
    @Test func aRunOfCapturesReachesTheStoreAsASingleBatch() {
        let (executor, _, truth, store, timeline, log) = Self.fullHarness()
        let size = Size(width: 800, height: 600)
        executor.execute([.capture(MonitorId(1), WindowId(1), size: size),
                          .capture(MonitorId(1), WindowId(2), size: size),
                          .capture(MonitorId(1), WindowId(3), size: .zero)], feedback: log.sink)

        #expect(store.requests == [[CaptureTarget(id: WindowId(1), size: size),
                                    CaptureTarget(id: WindowId(2), size: size),
                                    CaptureTarget(id: WindowId(3), size: .zero)]])
        #expect(truth.batches.isEmpty)          // the truth plane no longer answers for captures
        #expect(!timeline.entries.contains("beginFrame"))
    }

    /// The reducer's actual fresh-scroll batch is captures and nothing else, but a batch that mixes
    /// planes must still keep its order — the capture run is a run like any other.
    @Test func captureRunsKeepTheirPlaceAmongTheOtherPlanes() {
        let (executor, _, _, _, timeline, log) = Self.fullHarness()
        executor.execute([.focus(WindowId(1)),
                          .capture(MonitorId(1), WindowId(1), size: .zero), .capture(MonitorId(1), WindowId(2), size: .zero),
                          .setLayerFrame(LayerId(1), Self.rect(0))], feedback: log.sink)

        #expect(timeline.entries == ["truth[focus1]", "capture@1[1,2]",
                                     "beginFrame", "blit(1@0)", "endFrame"])
    }

    // The cover that grows

    /// `extendCover` and the `setLayerFrame`s placing the new layers are one contiguous presentation
    /// run, so they reach the window server in a single transaction. Split across two frames, a
    /// newcomer shows for one refresh where its capture was taken — its 1 px park sliver.
    @Test func growingTheCoverAndPlacingTheNewLayerAreOneFrame() {
        let (executor, _, _, timeline, log) = Self.harness()
        executor.execute([.extendCover(MonitorId(1), [LayerBinding(window: WindowId(3), layer: LayerId(3))]),
                          .setLayerFrame(LayerId(1), Self.rect(10)),
                          .setLayerFrame(LayerId(3), Self.rect(20))], feedback: log.sink)

        #expect(timeline.entries == ["beginFrame", "extend@1(3)", "blit(1@10)", "blit(3@20)", "endFrame"])
    }

    /// One run of blits is one frame however many layers it carries — and growing the cover does not
    /// mint an extra one, which would quietly inflate the only smoothness number we have.
    @Test func growingTheCoverCountsAsOneFrameNotTwo() {
        let (executor, _, _, _, log) = Self.harness()
        var reported: Int?
        executor.onCoverDismissed = { _, frames, _ in reported = frames }

        executor.execute([.beginTransition(MonitorId(1), Self.bindings)], feedback: log.sink)
        executor.execute([.setLayerFrame(LayerId(1), Self.rect(0))], feedback: log.sink)
        executor.execute([.extendCover(MonitorId(1), [LayerBinding(window: WindowId(3), layer: LayerId(3))]),
                          .setLayerFrame(LayerId(3), Self.rect(1))], feedback: log.sink)
        executor.execute([.endTransition(MonitorId(1))], feedback: log.sink)

        #expect(reported == 2)
    }

    /// The stills are released when the cover is down, not when `endTransition` is reduced: they are
    /// on screen for the whole cross-fade, held by `CALayer.contents`.
    @Test func theStillsAreReleasedOnlyAfterTheCrossFadeCompletes() {
        let (executor, surface, _, store, timeline, log) = Self.fullHarness()
        surface.completesDismissal = false
        executor.execute([.endTransition(MonitorId(1))], feedback: log.sink)
        #expect(store.discards == 0)            // fading — the images are what's fading

        surface.heldCompletion?()
        #expect(store.discards == 1)
        // `closeCover` lands with `endTransition`, before the fade, so a command arriving mid-fade
        // opens a new cover with its own base. Only the release waits for the fade.
        #expect(timeline.entries == ["beginFrame", "endFrame", "closeCover@1", "dismiss@1", "discard"])
        #expect(store.discarded.count == 1)     // …with the token this cover's close minted
    }

    /// Each mode's exit is a length rather than a yes-or-no: `smooth` takes the tail of its own motion and
    /// `snap` a couple of frames. `off` raises no cover of its own — it can only price one whose transition
    /// outlived a reload, and takes `snap`'s length because at two frames there is nothing to tell apart.
    /// Every length is safe, a cover coming down only onto a desktop that already matches it.
    @Test func eachModeLeavesOverItsOwnLength() {
        let expected: [TransitionMode: TimeInterval] = [
            .smooth: CompositingExecutor.smoothFade,
            .snap: CompositingExecutor.snapFade,
            .off: CompositingExecutor.snapFade,
        ]
        for mode in TransitionMode.allCases {
            let (executor, surface, _, _, log) = Self.harness()
            executor.transitionMode = mode
            executor.execute([.endTransition(MonitorId(1))], feedback: log.sink)
            #expect(surface.dismissedOver == expected[mode], "\(mode) left over the wrong length")
        }
        // The one calibration worth pinning as a number: two frames at 60 Hz, give or take, which is
        // what makes it read as a seam rather than as motion.
        #expect(CompositingExecutor.snapFade <= 0.05)
        #expect(CompositingExecutor.snapFade < CompositingExecutor.smoothFade)
    }

    /// A snapped dismissal is an ordinary one, not a skipped one: the same teardown runs in the same
    /// order, so the stills are released and `crossfadeDone` is acked exactly as `smooth`'s is.
    @Test func aSnappedDismissalTearsTheCoverDownLikeAnyOther() {
        let (executor, _, _, store, timeline, log) = Self.fullHarness()
        executor.transitionMode = .snap
        executor.execute([.endTransition(MonitorId(1))], feedback: log.sink)

        #expect(timeline.entries == ["beginFrame", "endFrame", "closeCover@1", "dismiss@1", "discard"])
        #expect(store.discards == 1)
        #expect(log.events.contains(.crossfadeDone(MonitorId(1))))
    }

    @Test func theCrossFadeStartsOnlyAfterTheFinalFrameIsCommitted() {
        // The last tick of a scroll emits its blits *and* `endTransition` in one batch; fading before
        // committing them would cross-fade away from a stale frame.
        let (executor, _, _, timeline, log) = Self.harness()
        executor.execute([.setLayerFrame(LayerId(1), Self.rect(42)), .endTransition(MonitorId(1))], feedback: log.sink)

        #expect(timeline.entries == ["beginFrame", "blit(1@42)", "endFrame",
                                     "closeCover@1", "dismiss@1", "discard"])
    }

    @Test func aFinishedCrossFadeAcksCrossfadeDone() {
        let (executor, _, _, _, log) = Self.harness()
        executor.execute([.endTransition(MonitorId(1))], feedback: log.sink)

        #expect(log.events == [.crossfadeDone(MonitorId(1))])
    }

    @Test func anInFlightCrossFadeAcksNothingUntilItLands() {
        let (executor, surface, _, _, log) = Self.harness()
        surface.completesDismissal = false
        executor.execute([.endTransition(MonitorId(1))], feedback: log.sink)
        #expect(log.events.isEmpty)             // still fading — the cover is up

        surface.heldCompletion?()
        #expect(log.events == [.crossfadeDone(MonitorId(1))])
    }

    @MainActor final class Counter { var frames: Int? }

    /// A frame is a run of blits, not a blit — three ticks moving two layers each is three frames, not
    /// six. It is the only number that says whether the scroll was smooth.
    @Test func theFrameCounterCountsFramesNotLayers() {
        let (executor, _, _, _, log) = Self.harness()
        let counter = Counter()
        executor.onCoverDismissed = { _, frames, _ in counter.frames = frames }

        executor.execute([.beginTransition(MonitorId(1), Self.bindings)], feedback: log.sink)
        for step in 0..<3 {
            executor.execute([.setLayerFrame(LayerId(1), Self.rect(Double(step))),
                              .setLayerFrame(LayerId(2), Self.rect(Double(step)))], feedback: log.sink)
        }
        executor.execute([.endTransition(MonitorId(1))], feedback: log.sink)

        #expect(counter.frames == 3)            // three frames, six blits
    }

    /// A layer sharpening in place is not a frame of motion, and counting it would inflate the one
    /// smoothness number there is — a transition whose stand-ins all resolved would read as smoother
    /// than the identical one that never needed to.
    @Test func aRefreshIsNotCountedAsAFrame() {
        let (executor, surface, _, _, log) = Self.harness()
        let counter = Counter()
        executor.onCoverDismissed = { _, frames, _ in counter.frames = frames }

        executor.execute([.beginTransition(MonitorId(1), Self.bindings)], feedback: log.sink)
        executor.execute([.setLayerFrame(LayerId(1), Self.rect(0))], feedback: log.sink)
        executor.execute([.refreshLayer(LayerId(1)), .refreshLayer(LayerId(2))], feedback: log.sink)
        executor.execute([.endTransition(MonitorId(1))], feedback: log.sink)

        #expect(counter.frames == 1)
        // …but it did reach the surface, inside a frame like every other presentation write.
        #expect(surface.timeline.entries.contains("refresh(1)"))
        #expect(surface.timeline.entries.contains("refresh(2)"))
    }

    /// A refresh arriving on the same tick as a blit rides in that tick's transaction rather than
    /// opening one of its own: they are one presentation run, so they reach the window server together.
    @Test func aRefreshSharesTheFrameOfTheBlitsAroundIt() {
        let (executor, surface, _, _, log) = Self.harness()
        executor.execute([.beginTransition(MonitorId(1), Self.bindings)], feedback: log.sink)
        surface.timeline.record("—")

        executor.execute([.setLayerFrame(LayerId(1), Self.rect(7)),
                          .refreshLayer(LayerId(1)),
                          .setLayerFrame(LayerId(2), Self.rect(7))], feedback: log.sink)

        let frame = surface.timeline.entries.drop { $0 != "—" }.dropFirst()
        #expect(Array(frame) == ["beginFrame", "blit(1@7)", "refresh(1)", "blit(2@7)", "endFrame"])
    }

    @Test func theFrameCounterResetsWithEachCover() {
        let (executor, _, _, _, log) = Self.harness()
        let counter = Counter()
        executor.onCoverDismissed = { _, frames, _ in counter.frames = frames }

        for _ in 0..<2 {
            executor.execute([.beginTransition(MonitorId(1), Self.bindings)], feedback: log.sink)
            executor.execute([.setLayerFrame(LayerId(1), Self.rect(0))], feedback: log.sink)
            executor.execute([.endTransition(MonitorId(1))], feedback: log.sink)
        }

        #expect(counter.frames == 1)            // the second cover's count, not the running total
    }

    @Test func presentationEffectsNeverReachTheTruthPlane() {
        let (executor, _, truth, _, log) = Self.harness()
        executor.execute([.beginTransition(MonitorId(1), Self.bindings),
                          .setLayerFrame(LayerId(1), Self.rect(0)),
                          .endTransition(MonitorId(1))], feedback: log.sink)

        #expect(truth.batches.isEmpty)
    }
}

/// The plane as N surfaces. `Compositor` decides two things and nothing else: that a fan-out happens
/// inside **one** frame, and that every cover call reaches the display it names — and only that one.
@Suite @MainActor struct CompositorTests {

    typealias Timeline = CompositingExecutorTests.Timeline

    static let bindings = CompositingExecutorTests.bindings
    /// Layers minted for a second display's cover — a different range of the one watermark, which is
    /// what makes a `LayerId` name one layer on one screen.
    static let otherBindings = [LayerBinding(window: WindowId(3), layer: LayerId(3))]

    /// One display's layer tree, recording what reached it.
    @MainActor final class RecordingSurface: CoverSurface {
        let timeline: Timeline
        let name: String
        /// Hold the dismissal open instead of completing it, to model a cross-fade in flight.
        var completesDismissal = true
        private(set) var heldCompletion: (@MainActor () -> Void)?
        /// The last raise's presentation fence, always held: a real one is a refresh away.
        private(set) var heldFence: (@MainActor () -> Void)?
        private(set) var dismissedOver: TimeInterval?

        init(_ timeline: Timeline, _ name: String) {
            self.timeline = timeline
            self.name = name
        }

        func raiseCover(_ bindings: [LayerBinding], onScreen: @escaping @MainActor () -> Void) {
            timeline.record("raise\(name)(\(bindings.map { "\($0.layer.raw)" }.joined(separator: ",")))")
            heldFence = onScreen
        }
        func extendCover(_ bindings: [LayerBinding]) {
            timeline.record("extend\(name)(\(bindings.map { "\($0.layer.raw)" }.joined(separator: ",")))")
        }
        func elevate(_ layer: LayerId) { timeline.record("elevate\(name)(\(layer.raw))") }
        func setLayerFrame(_ layer: LayerId, to rect: Rect) {
            timeline.record("blit\(name)(\(layer.raw)@\(Int(rect.minX)))")
        }
        func refreshLayer(_ layer: LayerId) { timeline.record("refresh\(name)(\(layer.raw))") }
        func dismiss(over duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
            dismissedOver = duration
            timeline.record("dismiss\(name)")
            if completesDismissal { completion() } else { heldCompletion = completion }
        }
    }

    /// `count` displays sharing one timeline, so what reached which is visible in order.
    static func plane(_ count: Int) -> (Compositor, [RecordingSurface], Timeline) {
        let timeline = Timeline()
        let surfaces = (0..<count).map { RecordingSurface(timeline, "@\($0 + 1)") }
        let compositor = Compositor(surfaces: surfaces.enumerated().map {
            (MonitorId(UInt64($0.offset + 1)), $0.element as any CoverSurface)
        })
        return (compositor, surfaces, timeline)
    }

    /// **A cover belongs to one display** (D7), so the raise reaches that surface and no other. This is
    /// the whole of what per-monitor sessions buy the shell: a transition on one screen leaves the
    /// other's desktop untouched, its pixels live.
    @Test func aRaiseReachesOnlyTheDisplayItNames() {
        let (compositor, _, timeline) = Self.plane(2)
        compositor.raiseCover(on: MonitorId(2), Self.otherBindings) { }
        #expect(timeline.entries == ["raise@2(3)"])
    }

    /// …and the per-frame calls route on the layer, which is why they carry no display (D11). The
    /// hottest path in the reducer stays byte-identical to the single-display one.
    @Test func aLayerCallGoesToTheDisplayThatMintedIt() {
        let (compositor, _, timeline) = Self.plane(2)
        compositor.raiseCover(on: MonitorId(1), Self.bindings) { }
        compositor.raiseCover(on: MonitorId(2), Self.otherBindings) { }

        compositor.setLayerFrame(LayerId(1), to: Rect(x: 10, y: 0, width: 1, height: 1))
        compositor.setLayerFrame(LayerId(3), to: Rect(x: 20, y: 0, width: 1, height: 1))
        compositor.elevate(LayerId(3))
        compositor.refreshLayer(LayerId(1))
        #expect(timeline.entries == ["raise@1(1,2)", "raise@2(3)",
                                     "blit@1(1@10)", "blit@2(3@20)", "elevate@2(3)", "refresh@1(1)"])
    }

    /// A layer whose cover has come down is routable by nobody — total, rather than fanned out to
    /// everyone on the chance that somebody still holds it.
    @Test func aLayerFromAClosedCoverReachesNoSurface() {
        let (compositor, _, timeline) = Self.plane(2)
        compositor.raiseCover(on: MonitorId(1), Self.bindings) { }
        compositor.dismiss(on: MonitorId(1), over: 0.04) { }
        compositor.setLayerFrame(LayerId(1), to: .zero)
        #expect(timeline.entries == ["raise@1(1,2)", "dismiss@1"])
    }

    /// An extension binds its new layers to the same display, so the frames that place them in the same
    /// transaction land there too.
    @Test func anExtensionsLayersRouteToTheCoverTheyGrew() {
        let (compositor, _, timeline) = Self.plane(2)
        compositor.raiseCover(on: MonitorId(2), Self.otherBindings) { }
        compositor.extendCover(on: MonitorId(2), Self.bindings)
        compositor.setLayerFrame(LayerId(2), to: Rect(x: 5, y: 0, width: 1, height: 1))
        #expect(timeline.entries == ["raise@2(3)", "extend@2(1,2)", "blit@2(2@5)"])
    }

    /// `coverOnScreen` entitles the reducer to teleport the windows **that cover shows**, so it is owed
    /// by one display's fence — not, as it was while one session spanned every screen, by all of them.
    @Test func theOnScreenReportComesFromItsOwnDisplaysFence() {
        let (compositor, surfaces, _) = Self.plane(2)
        var first = 0, second = 0
        compositor.raiseCover(on: MonitorId(1), Self.bindings) { first += 1 }
        compositor.raiseCover(on: MonitorId(2), Self.otherBindings) { second += 1 }
        #expect(first == 0 && second == 0)

        surfaces[1].heldFence?()
        #expect(first == 0 && second == 1)      // display 2's cover is up; display 1 is still waiting
        surfaces[0].heldFence?()
        #expect(first == 1 && second == 1)
    }

    /// …and exactly once per raise. A fence firing twice would report a cover on screen twice, and the
    /// second report is a teleport the reducer has already made.
    @Test func theOnScreenReportIsMadeOnlyOnce() {
        let (compositor, surfaces, _) = Self.plane(2)
        var reports = 0
        compositor.raiseCover(on: MonitorId(1), Self.bindings) { reports += 1 }
        surfaces[0].heldFence?()
        surfaces[0].heldFence?()
        #expect(reports == 1)
    }

    /// A fence from a superseded raise must not count against the current one, or a cover that replaced
    /// another would be reported on screen before it is.
    @Test func aFenceFromASupersededRaiseIsDropped() {
        let (compositor, surfaces, _) = Self.plane(2)
        var first = 0, second = 0
        compositor.raiseCover(on: MonitorId(1), Self.bindings) { first += 1 }
        let stale = surfaces[0].heldFence
        compositor.raiseCover(on: MonitorId(1), Self.bindings) { second += 1 }

        stale?()                                                // the old raise's fence, arriving late
        #expect(first == 0 && second == 0)
        surfaces[0].heldFence?()
        #expect(first == 0 && second == 1)
    }

    /// A departed display's overlay fences its raise on a display link for a screen that is gone, so a
    /// report gated on it never comes and the hold deadline pays for that transition. The report is
    /// made at once instead — nothing is visible there to be covered — and no surface is raised.
    @Test func aDepartedDisplayIsNotWaitedOnAndIsNotRaised() {
        let (compositor, _, timeline) = Self.plane(2)
        compositor.isAttached = { $0 == MonitorId(1) }

        var reports = 0
        compositor.raiseCover(on: MonitorId(2), Self.otherBindings) { reports += 1 }
        #expect(timeline.entries.isEmpty)       // the gone display's surface was left alone
        #expect(reports == 1)                   // …and the reducer is not left waiting on it
    }

    /// A dismissal is not gated the same way: taking a cover down is always safe, and a surface that
    /// was never raised completes at once — so a display that left cannot be left holding a stale
    /// photograph when it comes back.
    @Test func aDismissalIsNotGatedOnBeingAttached() {
        let (compositor, _, timeline) = Self.plane(2)
        compositor.isAttached = { $0 == MonitorId(1) }
        compositor.dismiss(on: MonitorId(2), over: 0.2) { }
        #expect(timeline.entries == ["dismiss@2"])
    }

    /// A cover half down is still a cover, so `crossfadeDone` waits for *its* dissolve.
    @Test func theDismissalCompletesWhenItsOwnSurfaceHasFaded() {
        let (compositor, surfaces, _) = Self.plane(2)
        for surface in surfaces { surface.completesDismissal = false }
        var done = 0
        compositor.dismiss(on: MonitorId(1), over: 0.22) { done += 1 }
        #expect(surfaces[0].dismissedOver == 0.22)
        #expect(surfaces[1].dismissedOver == nil)

        surfaces[1].heldCompletion?()           // the other display's, from nothing
        #expect(done == 0)
        surfaces[0].heldCompletion?()
        #expect(done == 1)
    }

    /// A display the plane was never built for is answered rather than trapped — the hot-plug case the
    /// shell does not build for yet, which must not leave a report unmade.
    @Test func aRaiseForAnUnknownDisplayReportsAtOnce() {
        let (compositor, _, timeline) = Self.plane(1)
        var reports = 0
        compositor.raiseCover(on: MonitorId(9), Self.bindings) { reports += 1 }
        compositor.dismiss(on: MonitorId(9), over: 0.04) { reports += 1 }
        #expect(reports == 2)
        #expect(timeline.entries.isEmpty)
    }

    /// One display is the ordinary case and must cost nothing: the plane is a pass-through, and both
    /// reports land the moment its one surface makes them.
    @Test func aSingleSurfacePlaneIsAPassThrough() {
        let timeline = Timeline()
        let surface = RecordingSurface(timeline, "")
        let compositor = Compositor(monitor: MonitorId(1), surface: surface)
        var onScreen = 0, done = 0
        compositor.raiseCover(on: MonitorId(1), Self.bindings) { onScreen += 1 }
        surface.heldFence?()
        compositor.dismiss(on: MonitorId(1), over: 0.04) { done += 1 }
        #expect(onScreen == 1 && done == 1)
        #expect(timeline.entries == ["raise(1,2)", "dismiss"])
    }
}
