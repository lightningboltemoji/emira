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

    // The bindings
    //
    // The house rule one rung out: **every verb has a take or a written reason.** The list of reasons is
    // longer than the settings one and is meant to be — the mock is one display showing one workspace,
    // and a third of the vocabulary is about the others.

    /// A file binding every verb in the vocabulary to a chord, so the catalogue can be asked about all
    /// twenty-one at once. Built off `Vocabulary` rather than listed, so a verb added to the table is
    /// covered here without this file being touched.
    static func everyVerbBound() throws -> Config {
        let spellings = Vocabulary.verbs.map { verb -> String in
            switch verb.argument {
            case .none:                    return verb.name
            case .words(let words, _):     return "\(verb.name) \(words[0])"
            case .address(let words, _, _): return "\(verb.name) \(words[0])"
            case .magnitude(let units):    return "\(verb.name) 100\(units[0])"
            case .line:                    return "\(verb.name) ghostty"
            }
        }
        // One letter per verb — twenty-six of them against twenty-one verbs, and every one a legal chord.
        let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        let lines = zip(letters, spellings).map { "ctrl-alt-\($0.0) = \"\($0.1)\"" }
        #expect(lines.count == Vocabulary.verbs.count, "not every verb got a chord")
        return try Config.parse("[keys]\n" + lines.joined(separator: "\n") + "\n")
    }

    @Test func everyVerbIsDemonstratedOrSaysWhyNot() throws {
        let config = try Self.everyVerbBound()
        var orphans: [String] = []
        for binding in config.keys {
            let verb = String(binding.spelling.prefix { !$0.isWhitespace })
            if Catalog.notDemonstrableVerbs[verb] != nil { continue }
            if Catalog.take(for: "keys.\(binding.chord)", config: config) == nil { orphans.append(verb) }
        }
        #expect(orphans.isEmpty, """
        These verbs have no take and are not on `Catalog.notDemonstrableVerbs`: \(orphans.sorted()). \
        Either give it a demonstration or name it with what a take would have had to invent — a row \
        with only its sentence under it is honest, a picture that mimes one is not.
        """)
    }

    /// A reason has to name a real verb and has to say what the take would have had to invent. A bare
    /// list would be a licence to forget.
    @Test func everyReasonNamesARealVerbAndSaysSomething() {
        let named = Set(Vocabulary.verbs.map(\.name))
        for (verb, reason) in Catalog.notDemonstrableVerbs {
            #expect(named.contains(verb), "`\(verb)` is on the list but is not a verb")
            #expect(reason.count > 80, "`\(verb)`'s reason does not say what a take would have to invent")
        }
    }

    /// …and a verb cannot be on both lists, which is how a demonstration quietly stops being watched.
    @Test func noVerbIsBothDemonstratedAndExcused() throws {
        let config = try Self.everyVerbBound()
        for binding in config.keys {
            let verb = String(binding.spelling.prefix { !$0.isWhitespace })
            guard Catalog.notDemonstrableVerbs[verb] != nil else { continue }
            #expect(Catalog.take(for: "keys.\(binding.chord)", config: config) == nil,
                    "`\(verb)` is excused and demonstrated at the same time")
        }
    }

    /// **A binding's take is badged with the command it runs.** A chord is one user's; the verb is what
    /// the row is about, and the desktop cannot show which verb moved a window.
    @Test func aBindingsTakeNamesTheCommandItRuns() throws {
        let config = try Config.parse("[keys]\nalt-h = \"focus left\"\n")
        let take = try #require(Catalog.take(for: "keys.alt-h", config: config))
        let cues = take.beats.compactMap { beat -> Cue? in
            if case .cue(let cue) = beat.beat { return cue }
            return nil
        }
        #expect(cues.first?.glyph == .command("focus left"))
        // …and it comes down again, so the badge is a moment rather than a label on the mock.
        #expect(take.beats.contains { beat in
            if case .cue(nil) = beat.beat { return true }
            return false
        })
    }

    /// The badge follows the command popup: retarget the binding and the mock says the new verb.
    @Test func retargetingABindingRetargetsItsDemonstration() throws {
        let before = try Config.parse("[keys]\nalt-h = \"focus left\"\n")
        let after = try Config.parse("[keys]\nalt-h = \"cycle-width\"\n")
        let one = try #require(Catalog.take(for: "keys.alt-h", config: before))
        let two = try #require(Catalog.take(for: "keys.alt-h", config: after))
        #expect(one.scene != two.scene, "two verbs demonstrated over the same set")
    }

    /// A chord the file does not carry has nothing to demonstrate — and `nil` means **hold the stage**,
    /// so a half-built row in the composer leaves whatever was playing exactly where it is.
    @Test func aChordTheFileDoesNotCarryHoldsTheStage() throws {
        let config = try Config.parse("[keys]\nalt-h = \"focus left\"\n")
        #expect(Catalog.take(for: "keys.cmd-j", config: config) == nil)
    }

    /// Every demonstration returns to where it started, exactly as a setting's does — a loop that drifts
    /// is one that looks broken by the third pass. **The badge is part of where it started**: a cue still
    /// up when the take restarts is lowered by nothing, so it cuts at the seam rather than landing.
    @Test func everyBindingTakeReturnsToItsOwnStart() throws {
        let config = try Self.everyVerbBound()
        let area = PreviewModelTests.workingArea
        for binding in config.keys {
            guard let take = Catalog.take(for: "keys.\(binding.chord)", config: config),
                  !take.isStatic else { continue }
            let start = PreviewModel.state(of: take, at: 0, config: config, workingArea: area)
            let end = PreviewModel.state(of: take, at: take.period - 1e-6,
                                         config: config, workingArea: area)
            #expect(end.frames == start.frames,
                    "\(binding.spelling)'s take does not return to its own start")
            #expect(end.scene.cue == nil,
                    "\(binding.spelling)'s badge is still up when its loop wraps")
        }
    }

    /// A binding take's beats fall inside its own loop, which is what
    /// `everyTakesBeatsFallInsideItsOwnLoop` claims one rung in for settings. A beat at or past the
    /// period never plays at all.
    @Test func everyBindingTakesBeatsFallInsideItsOwnLoop() throws {
        let config = try Self.everyVerbBound()
        for binding in config.keys {
            guard let take = Catalog.take(for: "keys.\(binding.chord)", config: config),
                  !take.isStatic else { continue }
            for (at, _) in take.beats {
                #expect(at >= 0 && at < take.period,
                        "\(binding.spelling)'s beat at \(at)s is outside its \(take.period)s loop")
            }
        }
    }

    /// …**including on a loop the user made short**, which is the case the fixtures above are all too
    /// comfortable to be. A ladder is as long as the preset list, so a single width preset is a 1.8 s
    /// loop against a 1.1 s dwell — and a down-beat past the wrap is one that never plays, leaving the
    /// badge up with nothing to lower it. The dwell shortens to fit rather than the badge outliving it.
    @Test func aBadgeOnAShortLoopStillComesDownInsideIt() throws {
        let config = try Config.parse("""
        [layout]
        width-presets = [0.5]

        [keys]
        alt-c = "cycle-width"
        """)
        let take = try #require(Catalog.take(for: "keys.alt-c", config: config))
        let lowered = try #require(take.beats.first { beat in
            if case .cue(nil) = beat.beat { return true }
            return false
        }, "a short loop dropped the badge rather than shortening it")

        #expect(lowered.at < take.period, "the badge is still up when the loop restarts")
        #expect(take.period - lowered.at >= Take.badgeTail, "the badge stops rather than lands")
    }
}
