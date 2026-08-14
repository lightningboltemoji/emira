import Foundation
import QuartzCore
import Testing
import EmiraCore
import EmiraGuide
@testable import EmiraShell

// What the controller puts on the panel, and for how long — the half of `Guide` that is decisions
// rather than AppKit, driven through the `GuideSurface` seam so none of it needs a window server.
//
// The claim under most of it is that **a guide with nothing to draw shows nothing**, which is the same
// answer the settings window gives by leaving that style out of its frame. A style left carrying its
// last frame would answer *where am I* with the workspace you just left.

@MainActor
@Suite struct GuideShowTests {

    /// A recording `GuideSurface`: what each style was last told, where its panel went, and every fade.
    final class Surface: GuideSurface {
        let backingScale: CGFloat = 2
        var shown: [GuideStyle: Bool] = [:]
        var placed: [GuideStyle: Rect] = [:]
        var fades: [(GuideStyle, TimeInterval)] = []

        /// Whether anything is on the panel at all — the window's own state, derived rather than told.
        var isShown: Bool { shown.values.contains(true) }

        func adopt(_ renderer: any GuideRenderer) {}
        func isShown(_ renderer: any GuideRenderer) -> Bool { shown[renderer.style] ?? false }
        func place(_ renderer: any GuideRenderer, at panel: Rect) { placed[renderer.style] = panel }
        func show(_ renderer: any GuideRenderer) { shown[renderer.style] = true }

        func hide(_ renderer: any GuideRenderer, over duration: TimeInterval) {
            shown[renderer.style] = false
            fades.append((renderer.style, duration))
        }

        func fades(of style: GuideStyle) -> [TimeInterval] {
            fades.filter { $0.0 == style }.map(\.1)
        }
    }

    /// A `DelayScheduler` whose dwells fire only when a test says so, and one at a time — two guides
    /// come due at two moments, which is the whole of what a shared arming could not express.
    final class ManualScheduler: DelayScheduler {
        private var work: [(TimeInterval, @MainActor () -> Void)] = []
        var scheduledDelays: [TimeInterval] { work.map(\.0) }

        func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            self.work.append((seconds, work))
        }

        /// Fire everything due at or before `seconds`, oldest first — the clock reaching that mark.
        func fire(through seconds: TimeInterval = .infinity) {
            let due = work.filter { $0.0 <= seconds }
            work.removeAll { $0.0 <= seconds }
            for (_, item) in due { item() }
        }
    }

    static let working = Rect(x: 0, y: 0, width: 1000, height: 800)
    static let first = MonitorId(1)
    static let second = MonitorId(2)

    /// Both guides on, asking for different dwells — the pair that has to keep its own time.
    static func settings() -> GuideSettings {
        GuideSettings(preview: PreviewGuideSettings(enabled: true, position: .topRight, width: 0.3,
                                                    span: 3, gap: 16, duration: 1),
                      names: NamesGuideSettings(enabled: true, position: .bottomCenter, duration: 2))
    }

    /// Two displays and two windows, all of them on the first. The second shows an empty address,
    /// which is a strip the minimap draws as an empty ribbon and the names guide cannot name at all.
    static func world(_ guide: GuideSettings = settings()) -> State {
        var state = State(config: Config(widthPresets: PresetCycle([.proportion(1.0)]),
                                         transitionMode: .off, guide: guide))
        state.setMonitors([MonitorInfo(id: first, frame: working),
                           MonitorInfo(id: second, frame: Rect(x: 1000, y: 0,
                                                               width: 800, height: 600))])
        for raw in UInt64(1)...2 {
            state = Engine.reduce(state, .windowCreated(
                WindowSnapshot(id: WindowId(raw), bundleId: "com.test.app", title: "w",
                               role: .standard,
                               frame: Rect(x: 0, y: 0, width: 10, height: 10)))).0
        }
        return state
    }

    static func guide(_ surface: Surface, _ scheduler: ManualScheduler,
                      on monitor: MonitorId = first) -> Guide {
        Guide(panel: surface, monitor: monitor, icons: GuideIcons(), names: GuideNames(),
              scheduler: scheduler)
    }

    @Test func everyEnabledGuideIsDrawnAndPlaced() {
        let surface = Surface()
        let guide = Self.guide(surface, ManualScheduler())

        guide.stateChanged(Self.world())

        #expect(surface.isShown)
        #expect(surface.shown == [.preview: true, .names: true])
        // Two panels, and each is its own: they were placed at the two corners the tables ask for.
        #expect(surface.placed[.preview]?.maxX ?? 0 > Self.working.midX)
        #expect(surface.placed[.names]?.maxY ?? 0 > Self.working.midY)
    }

    /// A style whose model has nothing to say is **taken down rather than left carrying the frame it
    /// last drew** — the answer the settings window gives by leaving it out of its own frame.
    @Test func aGuideThatRunsOutOfSomethingToSayIsTakenDown() {
        let surface = Surface()
        let guide = Self.guide(surface, ManualScheduler())
        var state = Self.world()
        guide.stateChanged(state)
        #expect(surface.shown[.names] == true)

        // Both windows leave. The strip is still a screen you are on, so the minimap draws an empty
        // ribbon; a row of names has no column left to name.
        for raw in UInt64(1)...2 {
            state = Engine.reduce(state, .windowDestroyed(WindowId(raw))).0
        }
        guide.stateChanged(state)

        #expect(surface.shown[.names] == false)
        #expect(surface.shown[.preview] == true)
    }

    /// The same thing on a display that never had anything to say.
    @Test func aDisplayShowingAnEmptyWorkspaceNamesNothing() {
        let surface = Surface()
        let guide = Self.guide(surface, ManualScheduler(), on: Self.second)

        guide.stateChanged(Self.world())

        #expect(surface.shown[.preview] == true)
        #expect(surface.shown[.names] == false)
    }

    @Test func aGuideThatIsOffShowsNothingWhateverElseIsUp() {
        var settings = Self.settings()
        settings.names.enabled = false
        let surface = Surface()
        let guide = Self.guide(surface, ManualScheduler())

        guide.stateChanged(Self.world(settings))

        #expect(surface.shown[.preview] == true)
        #expect(surface.shown[.names] == false)
        #expect(surface.placed[.names] == nil)
    }

    /// **A dwell is one guide's**: each style is armed for its own table's `duration`, so a pair asking
    /// for different ones is two timers rather than one reconciliation.
    @Test func eachGuideIsArmedForItsOwnDuration() {
        let scheduler = ManualScheduler()
        let guide = Self.guide(Surface(), scheduler)

        guide.stateChanged(Self.world())

        #expect(scheduler.scheduledDelays == [1, 2])
    }

    /// And the shorter of the two leaves first, over the fade both hosts run — the minimap goes while
    /// the row of names is still up, which is what two settings mean.
    @Test func theShorterGuideLeavesWhileTheOtherStaysUp() {
        let scheduler = ManualScheduler()
        let surface = Surface()
        let guide = Self.guide(surface, scheduler)
        guide.stateChanged(Self.world())

        scheduler.fire(through: 1)

        #expect(surface.fades(of: .preview) == [GuideFade.down])
        #expect(surface.shown[.preview] == false)
        #expect(surface.shown[.names] == true)

        scheduler.fire(through: 2)

        #expect(surface.fades(of: .names) == [GuideFade.down])
        #expect(!surface.isShown)
    }

    /// A guide the dwell has taken down is not redrawn until something raises it again — the frame a
    /// blit would spend on it is the one thing a per-style dwell must not go on spending.
    @Test func aGuideThatHasGoneIsNotDrawnAgainUntilTheTriggerChanges() {
        let scheduler = ManualScheduler()
        let surface = Surface()
        let guide = Self.guide(surface, scheduler)
        let state = Self.world()
        guide.stateChanged(state)
        scheduler.fire(through: 1)
        surface.placed.removeValue(forKey: .preview)

        // The same desktop again: nothing has moved, so nothing raises the minimap.
        guide.stateChanged(state)
        #expect(surface.placed[.preview] == nil)
        #expect(surface.shown[.preview] == false)

        // A column arrives, which is a trigger change, and both guides are up again.
        let moved = Engine.reduce(state, .windowCreated(
            WindowSnapshot(id: WindowId(3), bundleId: "com.test.app", title: "w", role: .standard,
                           frame: Rect(x: 0, y: 0, width: 10, height: 10)))).0
        guide.stateChanged(moved)
        #expect(surface.placed[.preview] != nil)
        #expect(surface.shown == [.preview: true, .names: true])
    }

    /// Every guide switched off is not a dwell — they go at once, and nothing is armed.
    @Test func switchingEveryGuideOffTakesThePanelDownImmediately() {
        let scheduler = ManualScheduler()
        let surface = Surface()
        let guide = Self.guide(surface, scheduler)
        guide.stateChanged(Self.world())

        var off = Self.settings()
        off.preview.enabled = false
        off.names.enabled = false
        guide.stateChanged(Self.world(off))

        #expect(surface.shown == [.preview: false, .names: false])
        #expect(surface.fades.suffix(2).allSatisfy { $0.1 == 0 })
        #expect(!surface.isShown)
    }
}
