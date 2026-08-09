import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// The cue, and the setting it exists for. `focus.system-events` has three words, and under two of them
// the desktop does *exactly the same thing* for two of the three targets — so what separates the rungs
// is the pattern of taken and declined, and a refusal with no picture is a preview that looks broken.

@Suite struct CueTests {

    static let area = PreviewModelTests.workingArea

    static func config(_ events: SystemFocusEvents) -> Config {
        var config = Config()
        config.systemFocusEvents = events
        return config
    }

    static func state(_ events: SystemFocusEvents, at t: Double) throws -> PreviewState {
        let config = Self.config(events)
        let take = try #require(Catalog.take(for: "focus.system-events", config: config))
        return PreviewModel.state(of: take, at: t, config: config, workingArea: area)
    }

    /// The three moments the take stages, sampled while each cue is still up.
    static let offScreen = 1.5, onScreen = 3.7, float = 5.9

    @Test func theSetCarriesAllThreeKindsOfTarget() throws {
        let state = try Self.state(.respect, at: 0)
        let onStrip = try #require(state.frames[WindowId(62)])
        let parked = try #require(state.frames[WindowId(63)])
        let float = try #require(state.frames[WindowId(64)])

        #expect(onStrip.intersection(Self.area) != nil)
        #expect(parked.minX >= Self.area.maxX, "the third column has to start off the right edge")
        #expect(float.intersection(Self.area) != nil)
        #expect(state.scene.isFloat(WindowId(64)))
        #expect(!state.scene.isFloat(WindowId(62)))
    }

    @Test func everyRungAnswersItsOwnPatternOfTakenAndDeclined() throws {
        func pattern(_ events: SystemFocusEvents) throws -> [Cue.Answer] {
            try [Self.offScreen, Self.onScreen, Self.float]
                .map { try #require(Self.state(events, at: $0).scene.cue).answer }
        }
        // `respect` honours all three; `on-screen` refuses the parked column; `ignore` honours only the
        // window emira does not place.
        #expect(try pattern(.respect) == [.taken, .taken, .taken])
        #expect(try pattern(.onScreen) == [.declined, .taken, .taken])
        #expect(try pattern(.ignore) == [.declined, .declined, .taken])
    }

    @Test func aTakenEventMovesTheRingAndADeclinedOneMovesNothing() throws {
        #expect(try Self.state(.respect, at: Self.offScreen).scene.focus == WindowId(63))
        #expect(try Self.state(.onScreen, at: Self.offScreen).scene.focus == WindowId(61))
        #expect(try Self.state(.ignore, at: Self.onScreen).scene.focus == WindowId(61))
    }

    @Test func revealingAParkedColumnScrollsTheStripAndRefusingItDoesNot() throws {
        let rest = try Self.state(.respect, at: 0).scrollOffset
        #expect(try Self.state(.respect, at: Self.offScreen).scrollOffset > rest)
        #expect(try Self.state(.onScreen, at: Self.offScreen).scrollOffset == rest)
    }

    @Test func focusOntoAFloatNeitherScrollsNorIsEverRefused() throws {
        // A float has no column, so there is nothing to frame on and nothing to scroll — and `ignore`
        // still honours it, which is the rung's entire content.
        for events in SystemFocusEvents.allCases {
            let state = try Self.state(events, at: Self.float)
            #expect(state.scene.focus == WindowId(64), "\(events) should honour a float")
            #expect(state.scrollOffset == (try Self.state(events, at: 0).scrollOffset))
        }
    }

    @Test func theCueIsUpOnlyForTheBeatWhoseCauseIsOffScreen() throws {
        // The badge is an input, so it is there while the input is and gone the rest of the time. A cue
        // that never left would be a caption.
        #expect(try Self.state(.respect, at: 0).scene.cue == nil)
        #expect(try Self.state(.respect, at: 2.6).scene.cue == nil)
        #expect(try Self.state(.respect, at: Self.onScreen).scene.cue != nil)
    }

    @Test func everyCommandCueIsSpelledTheWayTheConfigSpellsIt() throws {
        // The badge is text the reader can go and type, so it has to parse — and to re-emit unchanged,
        // which catches an alias or a stale verb as well as a typo. The fence keeps `Command` out of
        // `EmiraSettings`, so this is the seam where the two vocabularies are checked against each other.
        var checked = 0
        for setting in ConfigSchema.settings {
            guard let take = Catalog.take(for: setting.key, config: Config()) else { continue }
            for (_, beat) in take.beats {
                guard case .cue(.some(let cue)) = beat, case .command(let spelling) = cue.glyph else {
                    continue
                }
                let parsed = try Command.parse(line: spelling)
                #expect(parsed.words.joined(separator: " ") == spelling,
                        "`\(spelling)` on \(setting.key) is not the canonical spelling")
                checked += 1
            }
        }
        #expect(checked > 0, "no command cues found — this test is checking nothing")
    }

    @Test func aCauseEmiraDidNotActOnKeepsItsChord() throws {
        // `focus.system-events` is about focus emira did **not** cause, so there is no command to name.
        // A badge that invented one would claim the opposite of what the setting is about.
        let state = try Self.state(.respect, at: Self.onScreen)
        let cue = try #require(state.scene.cue)
        guard case .keys = cue.glyph else {
            Issue.record("a system focus event should be cued as a chord, not a command")
            return
        }
    }

    @Test func hidingTheCursorIsCausedByAKeycap() throws {
        // Nothing moves because a timer fired: the pointer goes because a command fired, and the command
        // is on screen.
        var config = Config()
        config.hidesCursor = true
        let take = try #require(Catalog.take(for: "mouse.hide", config: config))
        let struck = PreviewModel.state(of: take, at: 1.4, config: config, workingArea: Self.area)
        #expect(struck.scene.cue != nil)
        #expect(!struck.isPointerShown)

        // And the cursor's own movement is what brings it back.
        let moved = PreviewModel.state(of: take, at: 3.0, config: config, workingArea: Self.area)
        #expect(moved.isPointerShown)
    }
}
