import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// A strip holding exactly one window gives it the whole strip. The rule rides the shadow `fullscreen`
// already raises, and is seeded where a strip's population changes rather than derived from its shape —
// which is what leaves the width verbs something to say about a lone window.

@Suite struct EngineSoloFullscreenTests {

    /// ⅓ / ½ / ⅔ over a 1000-wide display, snapping: these are about *what* width results.
    static let config = Config(transitionMode: .off)

    static func booted() -> State { EngineFix.booted(config: config) }

    /// `count` windows opened in order onto the strip in view.
    static func opened(_ count: UInt64) -> State {
        EngineFix.run(booted(), (1...count).map { .windowCreated(EngineFix.snapshot($0)) }).0
    }

    // The rule itself

    /// The case the rule exists for: a rung is a share of a strip meant to be shared, and the first
    /// window on an empty workspace has nothing to share it with.
    @Test func theFirstWindowOnAStripTakesTheWholeStrip() {
        let s = Self.opened(1)
        #expect(EngineFix.width(s) == 1000)
        #expect(s.layout.columns[0].fullscreen?.origin == .solo)
    }

    /// …and gives it back the moment it has company, both columns landing on the ladder's first rung.
    @Test func aSecondWindowPutsBothOnTheLadder() {
        let s = Self.opened(2)
        #expect(s.layout.columns.allSatisfy { !$0.isFullscreen })
        #expect(EngineFix.approxScalar(EngineFix.width(s, 0), EngineFix.third))
        #expect(EngineFix.approxScalar(EngineFix.width(s, 1), EngineFix.third))
    }

    /// The half that makes the rule standing rather than a seed at arrival: closing back down to one
    /// window hands the strip to the survivor.
    @Test func closingBackToOneWindowGivesTheSurvivorTheStrip() {
        var s = Self.opened(2)
        (s, _) = Engine.reduce(s, .windowDestroyed(WindowId(2)))

        #expect(s.layout.columns.count == 1)
        #expect(EngineFix.width(s) == 1000)
        #expect(s.layout.columns[0].fullscreen?.origin == .solo)
    }

    /// The shadow is over the width stack, never in it: the rung underneath is untouched, so coming off
    /// is exact rather than a guess at which preset a full-width column was nearest.
    @Test func theRungUnderneathIsUntouchedWhileTheRuleHoldsIt() {
        var s = Self.opened(1)
        #expect(s.layout.columns[0].widthPreset == 0)
        #expect(s.layout.columns[0].widthOverride == nil)

        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(2)))
        #expect(EngineFix.approxScalar(EngineFix.width(s, 0), EngineFix.third))
    }

    /// One *window*, not one column. A stack the user built with `consume` is an arrangement they chose,
    /// and nothing here expels anybody to make the rule true.
    @Test func aStackAloneOnTheStripKeepsTheWidthTheUserGaveIt() {
        var s = Self.opened(2)
        (s, _) = Engine.reduce(s, .command(.consumeOrExpel(.left)))

        #expect(s.layout.columns.count == 1)
        #expect(s.layout.columns[0].windowIds.count == 2)
        #expect(!s.layout.columns[0].isFullscreen)
        #expect(EngineFix.approxScalar(EngineFix.width(s), EngineFix.third))
    }

    // The transition it rides

    /// The incumbent shrinks from the whole strip to a rung *under the arrival's own cover*, which is
    /// what applying the rule before the new geometry is read buys. Asserted as the invariant every
    /// structural edit owes — `natural(after) + displacement(0) == natural(before)` on the first frame.
    @Test func theIncumbentsShrinkRidesTheArrivalsOwnCover() {
        // The default config, not `Self.config`: this one is about *how* the width gets there, so it
        // needs the cover the rest of the suite turns off.
        var (s, _) = EngineFix.run(EngineFix.booted(), [.windowCreated(EngineFix.snapshot(1))])
        (s, _) = EngineFix.drive(s)                              // settle the first arrival
        let metrics = try! #require(s.metrics())
        let before = s.layout.naturalFrames(scrollOffset: s.viewport.offset.current, metrics: metrics)
        #expect(EngineFix.approxScalar(try! #require(before[WindowId(1)]).width, 1000))

        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(2)))
        #expect(s.motion.isTransitioning)                        // …a cover, not a snap
        for w in s.transition?.windows ?? [] {
            (s, _) = Engine.reduce(s, .captureReady(w))
        }
        (s, _) = Engine.reduce(s, .coverOnScreen(MonitorId(1)))
        #expect(s.motion.isCovered(on: s.monitors.focused))

        let (_, tickFx) = Engine.reduce(s, .tick(dt: 1e-6))
        var checked = 0
        for effect in tickFx {
            guard case .setLayerFrame(let layer, let rect) = effect,
                  let window = s.transition?.bindings.first(where: { $0.layer == layer })?.window,
                  let was = before[window] else { continue }
            #expect(EngineFix.approx(rect, was), "layer for \(window) popped at the raise")
            checked += 1
        }
        #expect(checked > 0)                                     // the incumbent was actually drawn
    }

    // What takes it back off — the rule seeds, it never leashes

    /// `cycle-width` on a lone window is live, and what it chooses stands: the rule does not re-assert
    /// itself on the next pass, only at the next arrival or departure.
    @Test func cycleWidthOnALoneWindowIsLiveAndSticks() {
        var s = Self.opened(1)
        (s, _) = Engine.reduce(s, .command(.cycleWidth))            // ⅓ → ½
        #expect(!s.layout.columns[0].isFullscreen)
        #expect(EngineFix.width(s) == 500)

        // Any number of events that leave the population alone.
        (s, _) = Engine.reduce(s, .command(.focus(.right)))
        (s, _) = Engine.reduce(s, .dragEnded)
        #expect(EngineFix.width(s) == 500)
    }

    /// `grow` likewise, and the width it drew survives the second window arriving — the rule had already
    /// let go, so there is nothing for the arrival to hand back.
    @Test func aGrownLoneWindowKeepsItsWidthWhenTheSecondWindowOpens() {
        var s = Self.opened(1)
        (s, _) = Engine.reduce(s, .command(.grow(.points(100))))
        let grown = EngineFix.width(s)

        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(2)))
        #expect(EngineFix.approxScalar(EngineFix.width(s, 0), grown))
    }

    /// …and the next departure hands it back to the rule, which is what makes the escape an escape from
    /// *this* arrangement rather than a permanent opt-out.
    @Test func theNextDepartureHandsAnEscapedColumnBackToTheRule() {
        var s = Self.opened(1)
        (s, _) = Engine.reduce(s, .command(.cycleWidth))
        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(2)))
        #expect(EngineFix.width(s, 0) == 500)

        (s, _) = Engine.reduce(s, .windowDestroyed(WindowId(2)))
        #expect(EngineFix.width(s) == 1000)
        // The rung it escaped to is still underneath, so `fullscreen off` gives back ½ and not ⅓.
        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
        #expect(EngineFix.width(s) == 500)
    }

    /// `fullscreen off` reaches the rule's shadow exactly as it reaches the verb's own.
    @Test func fullscreenOffTakesALoneWindowOffTheRule() {
        var s = Self.opened(1)
        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))

        #expect(!s.layout.columns[0].isFullscreen)
        #expect(EngineFix.approxScalar(EngineFix.width(s), EngineFix.third))
    }

    // The `fullscreen` verb and the rule are two records, not one

    /// `fullscreen on` over the rule is the user adopting it. Nothing moves — the column is already full
    /// — but the record stops being the rule's, and the next window opened leaves it alone.
    @Test func fullscreenOnALoneWindowAdoptsTheRuleSoTheNextWindowLeavesItFull() {
        var s = Self.opened(1)
        let (adopted, fx) = Engine.reduce(s, .command(.fullscreen(.on)))
        s = adopted
        #expect(fx.isEmpty)                                          // nothing to look at…
        #expect(s.layout.columns[0].fullscreen?.origin == .asked)    // …but the record moved

        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(2)))
        #expect(s.layout.columns[0].isFullscreen)
        #expect(EngineFix.width(s, 0) == 1000)
    }

    /// The same asymmetry from the other end: a fullscreen the user asked for on a strip that already
    /// had company is untouched by the rule's arrivals and departures.
    @Test func anAskedFullscreenSurvivesANeighbourArriving() {
        var s = Self.opened(2)
        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        #expect(s.layout.columns.contains { $0.fullscreen?.origin == .asked })

        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(3)))
        #expect(s.layout.columns.contains { $0.fullscreen?.origin == .asked })
    }

    // The other ways a strip's population moves

    /// Floating the neighbour leaves the strip with one window on it, which is the rule's business —
    /// a float is on no strip, so what counts is what the *strip* still holds.
    @Test func floatingTheNeighbourLeavesTheSurvivorAlone() {
        var s = Self.opened(2)
        (s, _) = Engine.reduce(s, .command(.float(.on)))            // the focused one leaves the strip

        #expect(s.layout.columns.count == 1)
        #expect(EngineFix.width(s) == 1000)
    }

    /// A window sent away is a departure for the strip it leaves and an arrival for the one it joins,
    /// and both ends are answered in the same edit.
    @Test func aMoveAnswersForBothStrips() {
        var s = Self.opened(2)
        let away = WorkspaceName("2")!
        (s, _) = Engine.reduce(s, .command(.moveToWorkspace(.name(away))))

        #expect(EngineFix.width(s) == 1000)                          // the source, down to one
        #expect(s.workspaces[away].columns[0].fullscreen?.origin == .solo)
    }

    /// A parked strip is full *before* it is switched to, so arriving on it shows no pop.
    @Test func aParkedStripsLoneWindowIsFullBeforeTheSwitch() {
        var s = Self.opened(2)
        let away = WorkspaceName("2")!
        (s, _) = Engine.reduce(s, .command(.moveToWorkspace(.name(away))))
        (s, _) = Engine.reduce(s, .command(.focusWorkspace(.name(away))))

        #expect(s.layout.columns.count == 1)
        #expect(EngineFix.width(s) == 1000)
    }

    // What outranks it

    /// A config rule's `width` is a **seed**, and a seed chooses the rung the shadow sits on rather than
    /// competing with it. `width = 0.5` on a window with nobody to share with is the same empty half the
    /// rule exists to close, and the rung lands the instant there is company.
    @Test func aWindowRulesWidthIsTheRungUnderTheRule() {
        var config = Self.config
        config.windowRules = [WindowRule(appId: "com.test.app", width: .proportion(0.5))]
        var s = EngineFix.run(EngineFix.booted(config: config),
                              [.windowCreated(EngineFix.snapshot(1))]).0
        #expect(s.layout.columns[0].widthOverride == .proportion(0.5))   // the seed still landed
        #expect(EngineFix.width(s) == 1000)                              // …under the shadow

        (s, _) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(2)))
        #expect(EngineFix.width(s, 0) == 500)                            // …and it is what is left
    }

    /// The launch scan is not exempt either, and nothing in the rule knows what a boot is. Adoption seeds
    /// the rung from the width the window had; the rule shadows it exactly as it shadows any other rung,
    /// and `fullscreen off` gives the adopted width back.
    @Test func theLaunchScanIsNotExemptAndTheWidthItKeptIsUnderneath() {
        let open = EngineFix.snapshot(1, frame: Rect(x: 0, y: 0, width: 640, height: 500),
                                      wasAlreadyOpen: true)
        var s = EngineFix.run(Self.booted(), [.windowCreated(open)]).0
        #expect(s.layout.columns[0].fullscreen?.origin == .solo)
        #expect(EngineFix.width(s) == 1000)

        (s, _) = Engine.reduce(s, .command(.fullscreen(.off)))
        #expect(EngineFix.approxScalar(EngineFix.width(s), 640))
    }

    /// The whole of the precedence, in one statement: **a seed chooses the rung and a verb clears the
    /// shadow.** Neither source of a seeded width is special, so there is no boot case, no rule case, and
    /// nothing that has to be told which kind of arrival it is looking at.
    @Test func everySeededWidthIsARungUnderTheRuleAndEveryVerbTakesItOff() {
        var config = Self.config
        config.windowRules = [WindowRule(appId: "seeded", width: .proportion(0.5))]
        let seeds: [WindowSnapshot] = [
            EngineFix.snapshot(1),                                                    // the ladder
            EngineFix.snapshot(1, bundle: "seeded"),                                  // a rule's width
            EngineFix.snapshot(1, frame: Rect(x: 0, y: 0, width: 640, height: 500),
                               wasAlreadyOpen: true),                                 // the launch scan
        ]
        for seed in seeds {
            var s = EngineFix.run(EngineFix.booted(config: config), [.windowCreated(seed)]).0
            #expect(EngineFix.width(s) == 1000, "\(seed.bundleId) was exempt")

            (s, _) = Engine.reduce(s, .command(.cycleWidth))
            #expect(EngineFix.width(s) != 1000, "\(seed.bundleId) ignored a verb")
        }
    }

    // The setting

    /// Off, nothing about the strip changes — the ladder answers for a lone window as it always did.
    @Test func theSettingOffLeavesALoneWindowOnTheLadder() {
        let s = EngineFix.run(EngineFix.booted(config: EngineFix.laddered(Self.config)),
                              [.windowCreated(EngineFix.snapshot(1))]).0

        #expect(!s.layout.columns[0].isFullscreen)
        #expect(EngineFix.approxScalar(EngineFix.width(s), EngineFix.third))
    }

    /// The one pass over every strip: the setting itself moved, so a reload is what the user is watching
    /// for. Off lifts every shadow the rule raised, and on raises them again.
    @Test func aReloadAppliesTheSettingInBothDirections() {
        var s = Self.opened(1)
        #expect(EngineFix.width(s) == 1000)

        (s, _) = Engine.reduce(s, .configChanged(EngineFix.laddered(Self.config)))
        #expect(!s.layout.columns[0].isFullscreen)
        #expect(EngineFix.approxScalar(EngineFix.width(s), EngineFix.third))

        (s, _) = Engine.reduce(s, .configChanged(Self.config))
        #expect(s.layout.columns[0].fullscreen?.origin == .solo)
        #expect(EngineFix.width(s) == 1000)
    }

    /// Turning it off lifts the rule's shadows and leaves the verb's alone — the whole point of the two
    /// records being distinguishable.
    @Test func aReloadOffLeavesAnAskedFullscreenStanding() {
        var s = Self.opened(2)
        (s, _) = Engine.reduce(s, .command(.fullscreen(.on)))
        (s, _) = Engine.reduce(s, .configChanged(EngineFix.laddered(Self.config)))

        #expect(s.layout.columns.contains { $0.fullscreen?.origin == .asked })
    }
}
