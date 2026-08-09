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
            if Catalog.take(for: setting.key, config: Config()) == nil { orphans.append(setting.key) }
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
        // A list that grows is a plan going quiet about what it can't show. It is down to one — the
        // cover's own timeout, which a preview with no cover has nothing to mime.
        #expect(Catalog.notDemonstrable.count <= 1)
    }

    @Test func aSettingWithNoTakeOfItsOwnFallsBackToItsSectionsSet() throws {
        // `column-gap` is geometry: it needs no script, and its section's set is the whole demo.
        let take = try #require(Catalog.take(for: "layout.column-gap", config: Config()))
        #expect(take.isStatic)
        #expect(take.scene == Scenes.threeColumns)
    }

    @Test func settingsThatShareASectionShareTheirSet() throws {
        // Which is what stops a hover from being a slot machine: crossing from one to the next moves no
        // window at all. What may differ is where it is looked at from — see below.
        let gap = try #require(Catalog.take(for: "layout.column-gap", config: Config()))
        let window = try #require(Catalog.take(for: "layout.window-gap", config: Config()))
        #expect(gap.scene == window.scene)
        #expect(gap.isStatic && window.isStatic)
    }


    @Test func onlyTheOuterGapEdgeUnderTheHandIsMarked() throws {
        // Four controls on one row, so the mock has to say which one — and only that one.
        for edge in Mark.Edge.allCases {
            let take = try #require(Catalog.take(for: "layout.outer-gap-\(edge.rawValue)", config: Config()))
            #expect(take.mark == .outerGap(edge))
            // Wide, always: the value is measured from the screen's own edges, and a frame that lost
            // them would lose the setting.
            #expect(take.camera == .wide)
        }
    }

    @Test func aSettingThatIsPureGeometryDrawsNoFocusRing() throws {
        // The ring is a claim that focus is part of what the setting is about. A gap is the same number
        // whichever window is focused, so a blue border on one of them is a subject the setting does
        // not have — and the eye follows it instead of the thing that is actually changing.
        let geometry = ["layout.column-gap", "layout.window-gap"]
            + Mark.Edge.allCases.map { "layout.outer-gap-\($0.rawValue)" }
        for key in geometry {
            let take = try #require(Catalog.take(for: key, config: Config()))
            #expect(!take.showsFocus, "\(key) has no attachment to focus and should not ring one")
        }
        // And everything that acts on a window keeps it.
        for key in ["layout.center-focused-column", "layout.width-presets", "focus.follows-mouse"] {
            #expect(try #require(Catalog.take(for: key, config: Config())).showsFocus)
        }
    }

    @Test func aRowWithNothingToShowHoldsTheStage() {
        // `nil` means "leave what is playing alone", never "cut to the section". Crossing a row with no
        // picture on the way down the panel must not tear the mock off the setting above it.
        #expect(Catalog.take(for: "animation.hold-timeout", config: Config()) == nil)
    }

    @Test func aSettingThatIsBehaviourCarriesBeats() throws {
        let take = try #require(Catalog.take(for: "focus.system-events", config: Config()))
        #expect(!take.isStatic)
        // A spring with nothing to animate shows nothing.
        let spring = try #require(Catalog.take(for: "animation.scroll.stiffness", config: Config()))
        #expect(!spring.isStatic)
    }

    @Test func aNotDemonstrableSettingHasNoTakeAtAll() {
        for key in Catalog.notDemonstrable {
            #expect(Catalog.take(for: key, config: Config()) == nil, "`\(key)` is on the list but answers a take")
        }
    }

    @Test func aKeyTheSchemaDoesNotKnowHasNoTake() {
        // The schema is the authority on what settings exist; a catalog with its own opinion would be a
        // second one.
        #expect(Catalog.take(for: "layout.colum-gap", config: Config()) == nil)
    }

    @Test func everyTakesBeatsFallInsideItsOwnLoop() {
        for setting in ConfigSchema.settings {
            guard let take = Catalog.take(for: setting.key, config: Config()), !take.isStatic else { continue }
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
            guard let take = Catalog.take(for: setting.key, config: Config()), !take.isStatic else { continue }
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
