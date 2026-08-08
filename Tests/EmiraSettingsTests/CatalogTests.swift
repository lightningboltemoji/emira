import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// The catalog's one real claim: **a new setting cannot be added without a demo story.** The same shape
// as `ConfigSchemaTests`'s "every field of Config has a config story", one rung further out — and
// stronger than a per-section table would be, because the unit here is the setting.

@Suite struct CatalogTests {

    @Test func everySettingIsDemonstratedOrSaysWhyNot() {
        var orphans: [String] = []
        for setting in ConfigSchema.settings {
            if Catalog.notDemonstrable.contains(setting.key) { continue }
            if Catalog.take(for: setting.key) == nil { orphans.append(setting.key) }
        }

        #expect(orphans.isEmpty, """
        These settings have no take and are not on `Catalog.notDemonstrable`: \(orphans.sorted()). \
        Either give it a demonstration or name it on the list with a reason — a control with no picture \
        is honest, a picture that mimes one is not.
        """)
    }

    @Test func theNotDemonstrableListIsShortAndReal() {
        // Every entry has to be a setting the schema actually knows, or the list is protecting a typo.
        for key in Catalog.notDemonstrable {
            #expect(ConfigSchema.setting(for: key) != nil,
                    "`\(key)` is on notDemonstrable but is not a setting")
        }
        // A list that grows is a plan going quiet about what it can't show.
        #expect(Catalog.notDemonstrable.count <= 5)
    }

    @Test func aSettingWithNoTakeOfItsOwnFallsBackToItsSectionsSet() throws {
        // `column-gap` is geometry: it needs no script, and its section's set is the whole demo.
        let take = try #require(Catalog.take(for: "layout.column-gap"))
        #expect(take.isStatic)
        #expect(take.scene == Scenes.threeColumns)
    }

    @Test func settingsThatShareASectionShareTheirSet() throws {
        // Which is what stops a hover from being a slot machine: crossing from one to the next changes
        // nothing at all.
        let gap = try #require(Catalog.take(for: "layout.column-gap"))
        let window = try #require(Catalog.take(for: "layout.window-gap"))
        #expect(gap == window)
    }

    @Test func aSettingThatIsBehaviourCarriesBeats() throws {
        let take = try #require(Catalog.take(for: "focus.system-events"))
        #expect(!take.isStatic)
        // A spring with nothing to animate shows nothing.
        let spring = try #require(Catalog.take(for: "animation.scroll.stiffness"))
        #expect(!spring.isStatic)
    }

    @Test func aNotDemonstrableSettingHasNoTakeAtAll() {
        for key in Catalog.notDemonstrable {
            #expect(Catalog.take(for: key) == nil, "`\(key)` is on the list but answers a take")
        }
    }

    @Test func aKeyTheSchemaDoesNotKnowHasNoTake() {
        // The schema is the authority on what settings exist; a catalog with its own opinion would be a
        // second one.
        #expect(Catalog.take(for: "layout.colum-gap") == nil)
    }

    @Test func everyTakesBeatsFallInsideItsOwnLoop() {
        for setting in ConfigSchema.settings {
            guard let take = Catalog.take(for: setting.key), !take.isStatic else { continue }
            for (at, _) in take.beats {
                #expect(at >= 0 && at < take.period,
                        "\(setting.key)'s beat at \(at)s is outside its \(take.period)s loop")
            }
        }
    }

    @Test func everyTakeEndsWhereItStarted() {
        // A loop that drifted would walk the mock desktop off the strip over a few minutes of hovering.
        //
        // Compared as **frames rather than as sets**, and that is the point: `cycleWidth` runs its
        // preset index on unbounded and `PresetCycle` wraps it at resolution, so a take that cycles a
        // column all the way round ends on a different index and the same geometry. What must not drift
        // is what is on screen.
        let config = Config()
        let area = PreviewModelTests.workingArea
        for setting in ConfigSchema.settings {
            guard let take = Catalog.take(for: setting.key), !take.isStatic else { continue }
            let start = PreviewModel.state(of: take, at: 0, config: config, workingArea: area)
            let end = PreviewModel.state(of: take, at: take.period - 1e-6,
                                         config: config, workingArea: area)
            #expect(end.frames == start.frames,
                    "\(setting.key)'s take does not return to its own start")
            #expect(end.scene.focus == start.scene.focus,
                    "\(setting.key)'s take ends on a different window than it began on")
        }
    }

    @Test func everySectionAnswersASet() {
        for section in Setting.Section.allCases {
            #expect(!Catalog.take(for: section).scene.columns.isEmpty)
        }
    }
}
