import ApplicationServices
import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The truth plane's write half — `AXExecutor`, the hold-timeout the pump arms around a transition, and
// struts. Everything with a decision in it sits above `WindowWriter` and is tested against arrays; the
// framework calls below it need a real desktop. So what is proved here is how a batch is carved up
// between apps, what happens to an effect naming a window nobody knows, and the difference between a
// window that failed to move and one that moved somewhere else.

@Suite @MainActor struct WritePathTests {

    // MARK: - Fixtures

    /// A 1000×800 display at the origin.
    static let display = Rect(x: 0, y: 0, width: 1000, height: 800)

    /// One full-width preset, so every cross-column focus genuinely scrolls and opens a transition.
    static let fullWidth = Config(widthPresets: PresetCycle([.proportion(1.0)]))

    static func rect(_ x: Double) -> Rect { Rect(x: x, y: 0, width: 200, height: 100) }

    /// Take a window into a registry and hand back its minted id. The AX element is addressed to a pid
    /// that isn't running — nothing here writes through it — and seeded from the window number, since
    /// `adopt` refuses to bind one element to two window numbers.
    @discardableResult
    static func adopt(_ registry: WindowRegistry, pid: pid_t, number: CGWindowID) -> WindowId {
        registry.adopt(
            ObservedWindow(pid: pid, bundleId: "app.\(pid)", title: "w", role: .standard,
                           frame: .zero, isMinimized: false),
            element: AXWindow(AXUIElementCreateApplication(pid_t(number))),
            number: number
        )!.id
    }

    /// A state with one display and one tiled window per entry in `apps`, each adopted into `registry`
    /// first so the core's ids and the shell's records agree, as they do after a real enumeration.
    static func boot(_ registry: WindowRegistry, apps: [pid_t]) -> State {
        var s = State(config: fullWidth)
        (s, _) = Engine.reduce(s, .screensChanged([MonitorInfo(id: MonitorId(1), frame: display)]))
        for (index, pid) in apps.enumerated() {
            let id = adopt(registry, pid: pid, number: CGWindowID(index + 1))
            let snapshot = WindowSnapshot(id: id, bundleId: "app.\(pid)", title: "w", role: .standard,
                                          frame: Rect(x: 300, y: 300, width: 200, height: 200))
            s = settledAfter(s, .windowCreated(snapshot))
        }
        return s
    }

    // MARK: - Batching: one lane job per app

    @Test("a batch is grouped into one job per app, in first-touched order")
    func aBatchIsGroupedIntoOneJobPerApp() {
        let registry = WindowRegistry()
        let a1 = Self.adopt(registry, pid: 100, number: 1)
        let b1 = Self.adopt(registry, pid: 200, number: 2)
        let a2 = Self.adopt(registry, pid: 100, number: 3)
        let writer = ScriptedWriter()
        let events = Recorder()

        // Layout order interleaves apps — which is exactly why grouping is worth doing.
        AXExecutor(registry: registry, writer: writer)
            .execute([.setFrame(a1, Self.rect(0)), .setFrame(b1, Self.rect(200)),
                      .park(a2, Self.rect(-400))], feedback: events.sink)

        #expect(writer.placements.count == 2)
        #expect(writer.placements.map(\.app) == [100, 200])
        #expect(writer.placements[0].moves.map(\.record.id) == [a1, a2])
        #expect(writer.placements[1].moves.map(\.record.id) == [b1])
    }

    @Test("one app's windows keep the reducer's order on its lane")
    func oneAppsWindowsKeepTheirOrder() {
        let registry = WindowRegistry()
        let ids = (1...4).map { Self.adopt(registry, pid: 100, number: CGWindowID($0)) }
        let writer = ScriptedWriter()
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer)
            .execute(ids.reversed().map { .setFrame($0, Self.rect(0)) }, feedback: events.sink)

        #expect(writer.placements.count == 1)
        #expect(writer.placements[0].moves.map(\.record.id) == ids.reversed())
    }

    @Test("a park is written by the same path as a set frame — the distinction is the core's, not AX's")
    func parkAndSetFrameShareOnePath() {
        let registry = WindowRegistry()
        let id = Self.adopt(registry, pid: 100, number: 1)
        let writer = ScriptedWriter()
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer)
            .execute([.park(id, Self.rect(-999))], feedback: events.sink)

        #expect(writer.placements.count == 1)
        #expect(writer.placements[0].moves[0].target == Self.rect(-999))
    }

    // MARK: - The unknown window

    @Test("a placement for a window the registry never saw fails at once instead of vanishing")
    func anUnknownWindowFailsRatherThanVanishing() {
        // The failure this prevents is a hung cover, not a lost set: a scoped `setFrame` that
        // evaporates leaves the transition waiting on a landing that can never arrive.
        let registry = WindowRegistry()
        let known = Self.adopt(registry, pid: 100, number: 1)
        let ghost = WindowId(999)
        let writer = ScriptedWriter()
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer)
            .execute([.setFrame(ghost, Self.rect(0)), .setFrame(known, Self.rect(0))],
                     feedback: events.sink)

        #expect(events.events.contains(.axFailed(ghost)))
        #expect(writer.placements.count == 1)                      // only the real one went out
        #expect(writer.placements[0].moves.map(\.record.id) == [known])
    }

    @Test("focus for an unknown window is dropped, because there is no answer to give")
    func anUnknownFocusIsDropped() {
        let registry = WindowRegistry()
        let writer = ScriptedWriter()
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer)
            .execute([.focus(WindowId(7)), .raise(WindowId(8))], feedback: events.sink)

        #expect(writer.focused.isEmpty)
        #expect(writer.raised.isEmpty)
        // No `focusChanged`, no failure: the core already recorded the focus it asked for, and the only
        // honest correction would come from an observer watching the real system.
        #expect(events.events.isEmpty)
    }

    // MARK: - Landings: the write, and where the window ended up

    @Test("a window that lands where it was asked to acks the landing and says nothing else")
    func anExactLandingIsSilentApartFromTheAck() {
        let registry = WindowRegistry()
        let id = Self.adopt(registry, pid: 100, number: 1)
        let writer = ScriptedWriter()
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer)
            .execute([.setFrame(id, Self.rect(40))], feedback: events.sink)

        #expect(events.events == [.axLanded(id)])
    }

    @Test("a tiled window the app clamped reports the question and the answer, and still counts as landed")
    func aClampedWindowReportsRealityAndStillLands() {
        // A terminal quantizing to character cells accepts every write and lands short of the request
        // on every placement. Calling that `axFailed` would flood the transition machinery with false
        // alarms, and drop terminals from the layout once `axFailed` grows a retry/drop policy.
        let registry = WindowRegistry()
        let id = Self.adopt(registry, pid: 100, number: 1)
        let clamped = Rect(x: 40, y: 0, width: 188, height: 100)
        let writer = ScriptedWriter()
        writer.landing = { WindowLanding(id: $0.record.id, accepted: true, frame: clamped) }
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer)
            .execute([.setFrame(id, Self.rect(40))], feedback: events.sink)

        // Truth first, then the verdict: `axLanded` can close a transition and snap the viewport, so
        // the frame it snaps against must already be the real one. The request rides along because an
        // answer is only evidence in relation to its question.
        #expect(events.events == [
            .placementCorrected(id, requested: Self.rect(40), actual: clamped),
            .axLanded(id),
        ])
    }

    @Test("a parked window that drifted records truth and teaches nothing")
    func aParkedWindowThatDriftedIsNotACorrection() {
        // A park slot is a 1 px sliver at the working area's edge, and a window can refuse a resize
        // there that it accepts once it scrolls back into view. So the drift describes off-viewport
        // geometry, not the window: `windowFrameChanged`, which the reducer never learns from.
        let registry = WindowRegistry()
        let id = Self.adopt(registry, pid: 100, number: 1)
        let refused = Rect(x: -199, y: 0, width: 260, height: 100)
        let writer = ScriptedWriter()
        writer.landing = { WindowLanding(id: $0.record.id, accepted: true, frame: refused) }
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer)
            .execute([.park(id, Rect(x: -199, y: 0, width: 200, height: 100))], feedback: events.sink)

        #expect(events.events == [.windowFrameChanged(id, refused), .axLanded(id)])
    }

    @Test("sub-point rounding is not drift and is not reported")
    func subPointRoundingIsNotDrift() {
        // The layout engine asks for `x = 40.5`; AX stores integers. That disagreement is arithmetic,
        // not an opinion, and reporting it would have the core chasing half-points forever.
        let registry = WindowRegistry()
        let id = Self.adopt(registry, pid: 100, number: 1)
        let writer = ScriptedWriter()
        writer.landing = { move in
            WindowLanding(id: move.record.id, accepted: true,
                          frame: Rect(x: move.target.minX - 0.5, y: move.target.minY,
                                      width: move.target.width, height: move.target.height))
        }
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer)
            .execute([.setFrame(id, Rect(x: 40.5, y: 0, width: 200, height: 100))],
                     feedback: events.sink)

        #expect(events.events == [.axLanded(id)])
    }

    @Test("a write the app refused is an ax failure, which is a different fact from landing elsewhere")
    func aRefusedWriteIsAnAxFailure() {
        let registry = WindowRegistry()
        let id = Self.adopt(registry, pid: 100, number: 1)
        let writer = ScriptedWriter()
        // Accepted `false` with no readable frame: the window stopped answering — a timeout, or it
        // closed mid-set.
        writer.landing = { WindowLanding(id: $0.record.id, accepted: false, frame: nil) }
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer)
            .execute([.setFrame(id, Self.rect(0))], feedback: events.sink)

        #expect(events.events == [.axFailed(id)])
    }

    @Test("a window that both refused the write and drifted reports both facts")
    func aRefusedWriteThatAlsoDriftedReportsBoth() {
        let registry = WindowRegistry()
        let id = Self.adopt(registry, pid: 100, number: 1)
        let elsewhere = Rect(x: 500, y: 500, width: 200, height: 100)
        let writer = ScriptedWriter()
        writer.landing = { WindowLanding(id: $0.record.id, accepted: false, frame: elsewhere) }
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer)
            .execute([.setFrame(id, Self.rect(0))], feedback: events.sink)

        #expect(events.events == [
            .placementCorrected(id, requested: Self.rect(0), actual: elsewhere),
            .axFailed(id),
        ])
    }

    // MARK: - The rest of the vocabulary

    @Test("focus and raise are routed to the writer as themselves")
    func focusAndRaiseAreRouted() {
        let registry = WindowRegistry()
        let a = Self.adopt(registry, pid: 100, number: 1)
        let b = Self.adopt(registry, pid: 100, number: 2)
        let writer = ScriptedWriter()
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer)
            .execute([.focus(a), .raise(b)], feedback: events.sink)

        #expect(writer.focused == [a])
        #expect(writer.raised == [b])
    }

    @Test("close is routed to the writer and answers nothing")
    func closeIsRoutedAndUnacked() {
        let registry = WindowRegistry()
        let a = Self.adopt(registry, pid: 100, number: 1)
        let writer = ScriptedWriter()
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer)
            .execute([.closeWindow(a)], feedback: events.sink)

        #expect(writer.closed == [a])
        // Not even an `axLanded`: whether the window goes is the app's call, and the answer arrives as
        // a destroy observation. Acking here would tell the core a window died that may still be open.
        #expect(events.events.isEmpty)
    }

    @Test("closing an unknown window is dropped, like focus and raise")
    func anUnknownCloseIsDropped() {
        let registry = WindowRegistry()
        let writer = ScriptedWriter()
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer)
            .execute([.closeWindow(WindowId(9))], feedback: events.sink)

        #expect(writer.closed.isEmpty)
        #expect(events.events.isEmpty)
    }

    @Test("capture is not the truth plane's to answer")
    func captureIsNotAnsweredHere() {
        // `capture` routes to `CaptureService` via `CompositingExecutor`, so an ack from here would be
        // a second one — a window counted twice toward a raise, on a batch whose stills aren't in yet.
        let registry = WindowRegistry()
        let id = Self.adopt(registry, pid: 100, number: 1)
        let writer = ScriptedWriter()
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer).execute([.capture(id)], feedback: events.sink)

        #expect(events.events.isEmpty)
        #expect(writer.placements.isEmpty)
    }

    @Test("presentation-plane effects are ignored, because another executor owns them")
    func presentationEffectsAreIgnored() {
        let registry = WindowRegistry()
        let id = Self.adopt(registry, pid: 100, number: 1)
        let writer = ScriptedWriter()
        let events = Recorder()

        AXExecutor(registry: registry, writer: writer).execute(
            [.beginTransition([LayerBinding(window: id, layer: LayerId(1))]),
             .setLayerFrame(LayerId(1), Self.rect(0)),
             .endTransition],
            feedback: events.sink)

        #expect(events.events.isEmpty)
        #expect(writer.placements.isEmpty)
    }

    // MARK: - Through the pump

    @Test("a transition closes only once the real windows have landed")
    func aTransitionWaitsForRealLandings() {
        let registry = WindowRegistry()
        let state = Self.boot(registry, apps: [100, 200])
        let writer = ScriptedWriter()
        writer.defersCompletion = true              // the truth plane answers when we say so
        let clock = ManualFrameClock()
        let runtime = Runtime(state: state,
                              executor: InstantCaptures(AXExecutor(registry: registry, writer: writer)),
                              clock: clock)

        runtime.dispatch(.command(.focus(.left)))
        #expect(runtime.state.motion.isCovered)     // captures ack instantly, so the cover is up
        #expect(!writer.placements.isEmpty)         // and the reals were teleported behind it

        RuntimeTests.runClock(clock, budget: 600)
        #expect(runtime.state.motion.isTransitioning)   // settled, but nothing has landed

        writer.flush()
        #expect(!runtime.state.motion.isTransitioning)
        #expect(!clock.isRunning)
    }

    @Test("the landings that arrive are the ones the reducer was waiting for")
    func landingsMatchTheScopedWindows() {
        let registry = WindowRegistry()
        let state = Self.boot(registry, apps: [100, 200])
        let writer = ScriptedWriter()
        let executor = TeeExecutor(InstantCaptures(AXExecutor(registry: registry, writer: writer)))
        let runtime = Runtime(state: state, executor: executor, clock: ManualFrameClock())

        runtime.dispatch(.command(.focus(.left)))

        let placed = writer.placements.flatMap { $0.moves.map(\.record.id) }
        let asked: [WindowId] = executor.effects.compactMap {
            switch $0 {
            case .setFrame(let id, _), .park(let id, _): return id
            default: return nil
            }
        }
        #expect(!placed.isEmpty)
        #expect(placed.sorted() == asked.sorted())
    }

    // MARK: - The hold timeout

    @Test("the hold is armed when a transition opens and cancelled when it closes")
    func theHoldIsArmedWithTheTransition() {
        let hold = ManualHoldTimer()
        let clock = ManualFrameClock()
        let runtime = Runtime(state: Self.boot(WindowRegistry(), apps: [100, 200]),
                              executor: MockExecutor(mode: .simulate), clock: clock, hold: hold)

        runtime.dispatch(.command(.focus(.left)))
        #expect(hold.armCount == 1)
        #expect(hold.isArmed)

        RuntimeTests.runClock(clock, budget: 600)
        #expect(!runtime.state.motion.isTransitioning)
        #expect(hold.cancelCount == 1)
        #expect(!hold.isArmed)
    }

    @Test("the hold is armed for the configured timeout")
    func theHoldUsesTheConfiguredTimeout() {
        var config = Self.fullWidth
        config.holdTimeout = 2.5
        var state = Self.boot(WindowRegistry(), apps: [100, 200])
        state.config = config
        let hold = ManualHoldTimer()
        let runtime = Runtime(state: state, executor: MockExecutor(mode: .simulate),
                              clock: ManualFrameClock(), hold: hold)

        runtime.dispatch(.command(.focus(.left)))
        #expect(hold.lastDuration == 2.5)
    }

    @Test("the hold firing closes a transition that would otherwise hang forever")
    func theHoldClosesAHungTransition() {
        // A real AX landing depends on another process's run loop, so an app that never answers would
        // leave the cover up over a desktop the user can no longer interact with.
        let registry = WindowRegistry()
        let writer = ScriptedWriter()
        writer.defersCompletion = true              // the app never answers
        let hold = ManualHoldTimer()
        let clock = ManualFrameClock()
        let executor = TeeExecutor(InstantCaptures(AXExecutor(registry: registry, writer: writer)))
        let runtime = Runtime(state: Self.boot(registry, apps: [100, 200]),
                              executor: executor, clock: clock, hold: hold)

        runtime.dispatch(.command(.focus(.left)))
        RuntimeTests.runClock(clock, budget: 600)
        #expect(runtime.state.motion.isTransitioning)

        #expect(hold.fire())
        #expect(executor.effects.contains(.endTransition))
        #expect(!runtime.state.motion.isTransitioning)
        #expect(!clock.isRunning)
    }

    @Test("ticking a stuck transition does not renew its deadline")
    func ticksDoNotRenewTheDeadline() {
        let registry = WindowRegistry()
        let writer = ScriptedWriter()
        writer.defersCompletion = true
        let hold = ManualHoldTimer()
        let clock = ManualFrameClock()
        let runtime = Runtime(state: Self.boot(registry, apps: [100, 200]),
                              executor: AXExecutor(registry: registry, writer: writer),
                              clock: clock, hold: hold)

        runtime.dispatch(.command(.focus(.left)))
        RuntimeTests.runClock(clock, budget: 600)

        #expect(runtime.state.motion.isTransitioning)
        #expect(hold.armCount == 1)                 // a bound that renews itself bounds nothing
    }

    @Test("redirecting an open transition re-arms the hold")
    func redirectingReArmsTheHold() {
        // Otherwise a second scroll mid-flight inherits the first scroll's deadline, and a user moving
        // briskly across four columns gets the cover yanked out from under the last one.
        let hold = ManualHoldTimer()
        let clock = ManualFrameClock()
        let runtime = Runtime(state: Self.boot(WindowRegistry(), apps: [100, 200, 300]),
                              executor: MockExecutor(mode: .simulate), clock: clock, hold: hold)

        runtime.dispatch(.command(.focus(.left)))
        #expect(hold.armCount == 1)
        clock.fire()
        clock.fire()
        runtime.dispatch(.command(.focus(.left)))   // interrupt: one session, new destination
        #expect(runtime.state.motion.isTransitioning)
        #expect(hold.armCount == 2)
    }

    // MARK: - Struts (the number the write path made load-bearing)

    @Test("struts are the screen minus its visible area, with the vertical edges swapped")
    func strutsSwapTheVerticalEdges() {
        // Cocoa is bottom-left, the core is top-left, so the menu bar — at Cocoa's maxY — is the core's
        // `top`. Backwards, this reserves the menu bar's height at the bottom and tiles under it.
        let insets = ScreenGeometry.struts(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                           visible: CGRect(x: 0, y: 70, width: 1800, height: 1061))
        #expect(insets.top == 38)                   // 1169 − (70 + 1061), the menu bar
        #expect(insets.bottom == 70)                // the Dock
        #expect(insets.left == 0)
        #expect(insets.right == 0)
    }

    @Test("a display with a side Dock reserves that edge")
    func aSideDockReservesItsEdge() {
        let insets = ScreenGeometry.struts(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                           visible: CGRect(x: 80, y: 0, width: 1720, height: 1131))
        #expect(insets.left == 80)
        #expect(insets.right == 0)
        #expect(insets.top == 38)
    }

    @Test("a secondary display away from the origin reserves only what it actually reserves")
    func aSecondaryDisplayIsMeasuredAgainstItself() {
        // The insets are per-edge differences, so a screen sitting at x = 1800 must not report an
        // 1800 pt left strut.
        let insets = ScreenGeometry.struts(frame: CGRect(x: 1800, y: 0, width: 1280, height: 800),
                                           visible: CGRect(x: 1800, y: 0, width: 1280, height: 800))
        #expect(insets == EdgeInsets.zero)
    }

    @Test("a visible area larger than its screen yields no struts rather than negative ones")
    func strutsNeverGrowTheWorkingArea() {
        // `Rect.inset(by:)` takes negatives happily and would push tiled windows off the display.
        let insets = ScreenGeometry.struts(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                           visible: CGRect(x: -10, y: -10, width: 120, height: 120))
        #expect(insets == EdgeInsets.zero)
    }
}

// MARK: - Doubles

/// Records the `Event`s a subsystem feeds back — the reply address, without a pump behind it.
@MainActor
final class Recorder {
    private(set) var events: [Event] = []
    lazy var sink = EventSink { [weak self] event in self?.events.append(event) }
}

/// A `WindowWriter` that answers from a script instead of a desktop. `defersCompletion` models real
/// AX answering later, from another process's run loop — the gap the hold-timeout exists to bound.
@MainActor
final class ScriptedWriter: WindowWriter {

    struct Placement {
        let app: pid_t
        let moves: [WindowMove]
    }

    private(set) var placements: [Placement] = []
    private(set) var focused: [WindowId] = []
    private(set) var raised: [WindowId] = []
    private(set) var closed: [WindowId] = []

    /// How each move answers. Default: accepted, landed exactly where it was asked to.
    var landing: ((WindowMove) -> WindowLanding)?

    /// Hold every completion until `flush()`.
    var defersCompletion = false
    private var held: [@MainActor () -> Void] = []

    func place(_ moves: [WindowMove], of app: pid_t,
               then completion: @escaping @MainActor ([WindowLanding]) -> Void) {
        placements.append(Placement(app: app, moves: moves))
        let answer = moves.map { move in
            landing?(move) ?? WindowLanding(id: move.record.id, accepted: true, frame: move.target)
        }
        guard defersCompletion else { return completion(answer) }
        held.append { completion(answer) }
    }

    func focus(_ window: WindowRegistry.Record) { focused.append(window.id) }

    func raise(_ window: WindowRegistry.Record) { raised.append(window.id) }

    func close(_ window: WindowRegistry.Record) { closed.append(window.id) }

    /// Deliver every held answer, in the order the placements were made.
    func flush() {
        let pending = held
        held = []
        for deliver in pending { deliver() }
    }
}

/// Answers `Effect.capture` instantly and forwards everything else — `CaptureService`'s part, played
/// by a stub. A transition raises no cover, and so teleports no real window, until every scoped
/// `captureReady` is in, so tests driving whole transitions must supply the capture plane themselves.
@MainActor
final class InstantCaptures: Executor {
    private let inner: any Executor

    init(_ inner: any Executor) { self.inner = inner }

    func execute(_ effects: [Effect], feedback: EventSink) {
        inner.execute(effects, feedback: feedback)
        for case .capture(let id) in effects { feedback(.captureReady(id)) }
    }
}

/// Records an effect stream on its way to a real executor — so a test can assert both what the core
/// asked for and what the executor did with it.
@MainActor
final class TeeExecutor: Executor {
    private let inner: any Executor
    private(set) var batches: [[Effect]] = []

    var effects: [Effect] { batches.flatMap { $0 } }

    init(_ inner: any Executor) {
        self.inner = inner
    }

    func execute(_ effects: [Effect], feedback: EventSink) {
        batches.append(effects)
        inner.execute(effects, feedback: feedback)
    }
}

/// A hold timer that fires on command.
@MainActor
final class ManualHoldTimer: HoldTimer {
    private(set) var armCount = 0
    private(set) var cancelCount = 0
    private(set) var lastDuration: TimeInterval?
    private var sink: EventSink?

    var isArmed: Bool { sink != nil }

    func arm(after seconds: TimeInterval, sink: EventSink) {
        armCount += 1
        lastDuration = seconds
        self.sink = sink
    }

    func cancel() {
        cancelCount += 1
        sink = nil
    }

    /// Deliver the deadline. `false` when nothing was armed, which makes "the hold stayed silent"
    /// assertable rather than merely unobserved.
    @discardableResult
    func fire() -> Bool {
        guard let sink else { return false }
        self.sink = nil
        sink(.holdTimeout)
        return true
    }
}
