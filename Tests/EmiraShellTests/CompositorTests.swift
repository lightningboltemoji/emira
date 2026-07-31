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

// MARK: - The Y-flip

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

    // MARK: The cover's local space

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

// MARK: - Routing & frame boundaries

@Suite @MainActor struct CompositingExecutorTests {

    // MARK: Fixtures

    static let bindings = [LayerBinding(window: WindowId(1), layer: LayerId(1)),
                           LayerBinding(window: WindowId(2), layer: LayerId(2))]

    static func rect(_ x: Double) -> Rect { Rect(x: x, y: 0, width: 100, height: 100) }

    /// One shared, ordered log across *both* planes — the only way to assert that a truth-plane effect
    /// ran between two presentation ones.
    @MainActor final class Timeline {
        private(set) var entries: [String] = []
        func record(_ entry: String) { entries.append(entry) }
    }

    @MainActor final class RecordingSurface: CoverSurface {
        let timeline: Timeline
        /// Hold the dismissal open instead of completing it, to model a cross-fade in flight.
        var completesDismissal = true
        private(set) var heldCompletion: (@MainActor () -> Void)?

        init(_ timeline: Timeline) { self.timeline = timeline }

        func beginFrame() { timeline.record("beginFrame") }
        func endFrame() { timeline.record("endFrame") }
        func raiseCover(_ bindings: [LayerBinding]) {
            timeline.record("raise(\(bindings.map { "\($0.layer.raw)" }.joined(separator: ",")))")
        }
        func extendCover(_ bindings: [LayerBinding]) {
            timeline.record("extend(\(bindings.map { "\($0.layer.raw)" }.joined(separator: ",")))")
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

        func dismiss(over duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
            dismissedOver = duration
            timeline.record("dismiss")
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
            case .capture(let w, _): return "capture\(w.raw)"
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

        func capture(_ targets: [CaptureTarget], feedback: EventSink) {
            requests.append(targets)
            timeline.record("capture[\(targets.map { "\($0.id.raw)" }.joined(separator: ","))]")
        }
        func surface(for window: WindowId) -> CapturedSurface? { nil }
        var base: CGImage? { nil }
        func closeCover() -> CoverToken {
            closes += 1
            nextToken += 1
            timeline.record("closeCover")
            return CoverToken(nextToken)
        }
        func discard(_ token: CoverToken) {
            discards += 1
            discarded.append(token)
            timeline.record("discard")
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
    static func harness() -> (CompositingExecutor, RecordingSurface, RecordingTruth, Timeline, EventLog) {
        let (executor, surface, truth, _, timeline, log) = fullHarness()
        return (executor, surface, truth, timeline, log)
    }

    /// The same, with the capture plane's recorder exposed.
    static func fullHarness() -> (CompositingExecutor, RecordingSurface, RecordingTruth,
                                  RecordingStore, Timeline, EventLog) {
        let timeline = Timeline()
        let surface = RecordingSurface(timeline)
        let truth = RecordingTruth(timeline)
        let store = RecordingStore(timeline)
        return (CompositingExecutor(surface: surface, store: store, truth: truth,
                                    launcher: RecordingLauncher(timeline)),
                surface, truth, store, timeline, EventLog())
    }

    /// The system plane's harness — the launcher is the only recorder a test about `exec` reads.
    static func execHarness() -> (CompositingExecutor, RecordingLauncher, Timeline, EventLog) {
        let timeline = Timeline()
        let launcher = RecordingLauncher(timeline)
        return (CompositingExecutor(surface: RecordingSurface(timeline),
                                    store: RecordingStore(timeline),
                                    truth: RecordingTruth(timeline),
                                    launcher: launcher),
                launcher, timeline, EventLog())
    }

    // MARK: Plane assignment

    @Test func everyEffectIsAssignedToAPlane() {
        #expect(CompositingExecutor.plane(of: .beginTransition([])) == .presentation)
        #expect(CompositingExecutor.plane(of: .extendCover([])) == .presentation)
        #expect(CompositingExecutor.plane(of: .setLayerFrame(LayerId(1), .zero)) == .presentation)
        #expect(CompositingExecutor.plane(of: .endTransition) == .presentation)
        #expect(CompositingExecutor.plane(of: .setFrame(WindowId(1), .zero)) == .truth)
        #expect(CompositingExecutor.plane(of: .park(WindowId(1), .zero)) == .truth)
        #expect(CompositingExecutor.plane(of: .focus(WindowId(1))) == .truth)
        #expect(CompositingExecutor.plane(of: .raise(WindowId(1))) == .truth)
        #expect(CompositingExecutor.plane(of: .closeWindow(WindowId(1))) == .truth)
        #expect(CompositingExecutor.plane(of: .capture(WindowId(1), size: .zero)) == .capture)
        #expect(CompositingExecutor.plane(of: .refreshLayer(LayerId(1))) == .presentation)
        #expect(CompositingExecutor.plane(of: .exec("ghostty")) == .system)
    }

    // MARK: The system plane

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
            .beginTransition(Self.bindings),
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

    // MARK: Ordering

    @Test func theCoverIsRaisedBeforeTheRealWindowsTeleport() {
        // The reducer's cover-raise batch: begin, then the teleports behind it. Nothing may reach the
        // truth plane before the raise — that ordering is the zero-exposure rule.
        let (executor, _, _, timeline, log) = Self.harness()
        executor.execute([.beginTransition(Self.bindings),
                          .setFrame(WindowId(1), Self.rect(0)),
                          .park(WindowId(2), Self.rect(9999))], feedback: log.sink)

        #expect(timeline.entries == ["beginFrame", "raise(1,2)", "endFrame", "truth[setFrame1,park2]"])
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

    // MARK: Frame boundaries

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

    // MARK: The capture plane

    /// A run of `capture`s reaches the store as one call, not one per window: the batch is the unit —
    /// one shareable-content fetch, one fan-out, one set of acks. Each window's recorded size travels
    /// with it, because that is what decides whether a kept still may stand in for a fresh capture.
    @Test func aRunOfCapturesReachesTheStoreAsASingleBatch() {
        let (executor, _, truth, store, timeline, log) = Self.fullHarness()
        let size = Size(width: 800, height: 600)
        executor.execute([.capture(WindowId(1), size: size),
                          .capture(WindowId(2), size: size),
                          .capture(WindowId(3), size: .zero)], feedback: log.sink)

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
                          .capture(WindowId(1), size: .zero), .capture(WindowId(2), size: .zero),
                          .setLayerFrame(LayerId(1), Self.rect(0))], feedback: log.sink)

        #expect(timeline.entries == ["truth[focus1]", "capture[1,2]",
                                     "beginFrame", "blit(1@0)", "endFrame"])
    }

    // MARK: The cover that grows

    /// `extendCover` and the `setLayerFrame`s placing the new layers are one contiguous presentation
    /// run, so they reach the window server in a single transaction. Split across two frames, a
    /// newcomer shows for one refresh where its capture was taken — its 1 px park sliver.
    @Test func growingTheCoverAndPlacingTheNewLayerAreOneFrame() {
        let (executor, _, _, timeline, log) = Self.harness()
        executor.execute([.extendCover([LayerBinding(window: WindowId(3), layer: LayerId(3))]),
                          .setLayerFrame(LayerId(1), Self.rect(10)),
                          .setLayerFrame(LayerId(3), Self.rect(20))], feedback: log.sink)

        #expect(timeline.entries == ["beginFrame", "extend(3)", "blit(1@10)", "blit(3@20)", "endFrame"])
    }

    /// One run of blits is one frame however many layers it carries — and growing the cover does not
    /// mint an extra one, which would quietly inflate the only smoothness number we have.
    @Test func growingTheCoverCountsAsOneFrameNotTwo() {
        let (executor, _, _, _, log) = Self.harness()
        var reported: Int?
        executor.onCoverDismissed = { frames, _ in reported = frames }

        executor.execute([.beginTransition(Self.bindings)], feedback: log.sink)
        executor.execute([.setLayerFrame(LayerId(1), Self.rect(0))], feedback: log.sink)
        executor.execute([.extendCover([LayerBinding(window: WindowId(3), layer: LayerId(3))]),
                          .setLayerFrame(LayerId(3), Self.rect(1))], feedback: log.sink)
        executor.execute([.endTransition], feedback: log.sink)

        #expect(reported == 2)
    }

    /// The stills are released when the cover is down, not when `endTransition` is reduced: they are
    /// on screen for the whole cross-fade, held by `CALayer.contents`.
    @Test func theStillsAreReleasedOnlyAfterTheCrossFadeCompletes() {
        let (executor, surface, _, store, timeline, log) = Self.fullHarness()
        surface.completesDismissal = false
        executor.execute([.endTransition], feedback: log.sink)
        #expect(store.discards == 0)            // fading — the images are what's fading

        surface.heldCompletion?()
        #expect(store.discards == 1)
        // `closeCover` lands with `endTransition`, before the fade, so a command arriving mid-fade
        // opens a new cover with its own base. Only the release waits for the fade.
        #expect(timeline.entries == ["beginFrame", "endFrame", "closeCover", "dismiss", "discard"])
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
            executor.execute([.endTransition], feedback: log.sink)
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
        executor.execute([.endTransition], feedback: log.sink)

        #expect(timeline.entries == ["beginFrame", "endFrame", "closeCover", "dismiss", "discard"])
        #expect(store.discards == 1)
        #expect(log.events.contains(.crossfadeDone))
    }

    @Test func theCrossFadeStartsOnlyAfterTheFinalFrameIsCommitted() {
        // The last tick of a scroll emits its blits *and* `endTransition` in one batch; fading before
        // committing them would cross-fade away from a stale frame.
        let (executor, _, _, timeline, log) = Self.harness()
        executor.execute([.setLayerFrame(LayerId(1), Self.rect(42)), .endTransition], feedback: log.sink)

        #expect(timeline.entries == ["beginFrame", "blit(1@42)", "endFrame",
                                     "closeCover", "dismiss", "discard"])
    }

    // MARK: The ack

    @Test func aFinishedCrossFadeAcksCrossfadeDone() {
        let (executor, _, _, _, log) = Self.harness()
        executor.execute([.endTransition], feedback: log.sink)

        #expect(log.events == [.crossfadeDone])
    }

    @Test func anInFlightCrossFadeAcksNothingUntilItLands() {
        let (executor, surface, _, _, log) = Self.harness()
        surface.completesDismissal = false
        executor.execute([.endTransition], feedback: log.sink)
        #expect(log.events.isEmpty)             // still fading — the cover is up

        surface.heldCompletion?()
        #expect(log.events == [.crossfadeDone])
    }

    // MARK: The smoothness read-out

    @MainActor final class Counter { var frames: Int? }

    /// A frame is a run of blits, not a blit — three ticks moving two layers each is three frames, not
    /// six. It is the only number that says whether the scroll was smooth.
    @Test func theFrameCounterCountsFramesNotLayers() {
        let (executor, _, _, _, log) = Self.harness()
        let counter = Counter()
        executor.onCoverDismissed = { frames, _ in counter.frames = frames }

        executor.execute([.beginTransition(Self.bindings)], feedback: log.sink)
        for step in 0..<3 {
            executor.execute([.setLayerFrame(LayerId(1), Self.rect(Double(step))),
                              .setLayerFrame(LayerId(2), Self.rect(Double(step)))], feedback: log.sink)
        }
        executor.execute([.endTransition], feedback: log.sink)

        #expect(counter.frames == 3)            // three frames, six blits
    }

    /// A layer sharpening in place is not a frame of motion, and counting it would inflate the one
    /// smoothness number there is — a transition whose stand-ins all resolved would read as smoother
    /// than the identical one that never needed to.
    @Test func aRefreshIsNotCountedAsAFrame() {
        let (executor, surface, _, _, log) = Self.harness()
        let counter = Counter()
        executor.onCoverDismissed = { frames, _ in counter.frames = frames }

        executor.execute([.beginTransition(Self.bindings)], feedback: log.sink)
        executor.execute([.setLayerFrame(LayerId(1), Self.rect(0))], feedback: log.sink)
        executor.execute([.refreshLayer(LayerId(1)), .refreshLayer(LayerId(2))], feedback: log.sink)
        executor.execute([.endTransition], feedback: log.sink)

        #expect(counter.frames == 1)
        // …but it did reach the surface, inside a frame like every other presentation write.
        #expect(surface.timeline.entries.contains("refresh(1)"))
        #expect(surface.timeline.entries.contains("refresh(2)"))
    }

    /// A refresh arriving on the same tick as a blit rides in that tick's transaction rather than
    /// opening one of its own: they are one presentation run, so they reach the window server together.
    @Test func aRefreshSharesTheFrameOfTheBlitsAroundIt() {
        let (executor, surface, _, _, log) = Self.harness()
        executor.execute([.beginTransition(Self.bindings)], feedback: log.sink)
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
        executor.onCoverDismissed = { frames, _ in counter.frames = frames }

        for _ in 0..<2 {
            executor.execute([.beginTransition(Self.bindings)], feedback: log.sink)
            executor.execute([.setLayerFrame(LayerId(1), Self.rect(0))], feedback: log.sink)
            executor.execute([.endTransition], feedback: log.sink)
        }

        #expect(counter.frames == 1)            // the second cover's count, not the running total
    }

    @Test func presentationEffectsNeverReachTheTruthPlane() {
        let (executor, _, truth, _, log) = Self.harness()
        executor.execute([.beginTransition(Self.bindings),
                          .setLayerFrame(LayerId(1), Self.rect(0)),
                          .endTransition], feedback: log.sink)

        #expect(truth.batches.isEmpty)
    }
}
