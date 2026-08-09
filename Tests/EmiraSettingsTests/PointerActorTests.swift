import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// The pointer as an actor. `focus.follows-mouse` is the cursor moving and focus answering it;
// `mouse.follows-focus` is focus moving and the cursor answering. Two settings, opposite directions.

@Suite struct PointerActorTests {

    static let area = PreviewModelTests.workingArea

    static func config(followsMouse: Bool = false,
                       followsFocus: MouseFollowsFocus = .off) -> Config {
        var config = Config()
        config.focusFollowsMouse = followsMouse
        config.mouseFollowsFocus = followsFocus
        return config
    }

    static func state(_ key: String, _ config: Config, at t: Double) throws -> PreviewState {
        let take = try #require(Catalog.take(for: key, config: config))
        return PreviewModel.state(of: take, at: t, config: config, workingArea: area)
    }

    // `focus.follows-mouse` — the pointer acts, focus answers.

    @Test func theRingTransfersOnTheSeamCrossingAndNotOnTheBeat() throws {
        // **The assertion of the setting.** The beat that starts the travel is at 1.0 s and the cursor
        // takes half a second to get there, so a ring that moved with the beat would move while the
        // cursor was still in the window it came from.
        let on = Self.config(followsMouse: true)
        let take = try #require(Catalog.take(for: "focus.follows-mouse", config: on))

        var transferred: Double?
        var crossed: Double?
        for step in 0...160 {
            let t = Double(step) * 0.01
            let state = PreviewModel.state(of: take, at: t, config: on, workingArea: Self.area)
            guard let cursor = state.pointer else { continue }
            let inside = state.frames[WindowId(42)]?.contains(cursor) == true
            if inside, crossed == nil { crossed = t }
            if state.scene.focus == WindowId(42), transferred == nil { transferred = t }
        }
        let seam = try #require(crossed)
        let ring = try #require(transferred)
        // The same sampled frame: one hundredth of a second is the sampling, not a lag.
        #expect(abs(seam - ring) <= 0.011)
        // And it is genuinely later than the beat that set the hand going.
        #expect(seam > 1.05)
    }

    @Test func offLeavesTheRingWhereItIsWhileTheCursorKeepsGoing() throws {
        let off = Self.config(followsMouse: false)
        let mid = try Self.state("focus.follows-mouse", off, at: 1.5)
        let after = try Self.state("focus.follows-mouse", off, at: 2.2)

        #expect(mid.scene.focus == WindowId(41))
        #expect(after.scene.focus == WindowId(41))
        // Legible precisely because the pointer visibly kept moving.
        let cursor = try #require(after.pointer)
        #expect(after.frames[WindowId(42)]?.contains(cursor) == true)
    }

    @Test func crossingIntoTheOffScreenColumnScrollsTheStripToRevealIt() throws {
        // The clause that makes emira's version of this setting unlike every other window manager's.
        let on = Self.config(followsMouse: true)
        let before = try Self.state("focus.follows-mouse", on, at: 2.3)
        let after = try Self.state("focus.follows-mouse", on, at: 3.4)

        #expect(after.scene.focus == WindowId(43))
        #expect(after.scrollOffset > before.scrollOffset)

        let off = Self.config(followsMouse: false)
        let never = try Self.state("focus.follows-mouse", off, at: 3.4)
        #expect(never.scrollOffset == before.scrollOffset)
    }

    @Test func theThirdColumnStartsPartlyOffTheRightEdge() throws {
        let state = try Self.state("focus.follows-mouse", Self.config(), at: 0)
        let third = try #require(state.frames[WindowId(43)])
        #expect(third.minX < Self.area.maxX)
        #expect(third.maxX > Self.area.maxX)
    }

    // `mouse.follows-focus` — four rungs, and every one gets a distinct picture.

    /// Where the cursor rests at each of the take's three staged moments, per rung.
    static func rests(_ rung: MouseFollowsFocus) throws -> [Point] {
        let config = Self.config(followsFocus: rung)
        // Sampled at the end of each beat's hold, where the travel has finished.
        return try [2.3, 3.7, 6.2].map { try #require(Self.state("mouse.follows-focus", config, at: $0).pointer) }
    }

    @Test func beatASeparatesOff() throws {
        // Focus moves to a window the pointer is not in: `off` leaves it, the other three send it.
        let config = Self.config(followsFocus: .off)
        let before = try #require(Self.state("mouse.follows-focus", config, at: 0.9).pointer)
        let after = try #require(Self.state("mouse.follows-focus", config, at: 2.3).pointer)
        #expect(before == after)

        for rung in [MouseFollowsFocus.lazy, .exceptHover, .force] {
            let live = Self.config(followsFocus: rung)
            let moved = try #require(Self.state("mouse.follows-focus", live, at: 2.3).pointer)
            #expect(moved != before, "\(rung) should have sent the pointer after focus")
        }
    }

    @Test func beatCSeparatesForce() throws {
        // The pointer crosses a seam and moves focus itself. `force` yanks the cursor to the centre,
        // visibly away from the spot the hand aimed at; the other two leave it where it was put.
        let aimed = PointerAt.inside(WindowId(21), x: 0.3, y: 0.72)
        for rung in [MouseFollowsFocus.off, .lazy, .exceptHover] {
            let config = Self.config(followsFocus: rung)
            let state = try Self.state("mouse.follows-focus", config, at: 3.7)
            let cursor = try #require(state.pointer)
            let intended = try #require(aimed.point(frames: state.frames, workingArea: Self.area))
            #expect(abs(cursor.x - intended.x) < 0.5, "\(rung) should leave the hand's own spot alone")
        }
        let forced = try Self.state("mouse.follows-focus", Self.config(followsFocus: .force), at: 3.7)
        let cursor = try #require(forced.pointer)
        let centre = try #require(forced.frames[forced.scene.focus]).center
        #expect(abs(cursor.x - centre.x) < 0.5)
    }

    @Test func beatBSeparatesLazy() throws {
        // Focus lands on the window the pointer is already inside. `lazy` declines and the pointer does
        // not twitch; `except-hover` and `force` recentre.
        let lazyState = try Self.state("mouse.follows-focus", Self.config(followsFocus: .lazy), at: 6.2)
        let lazyCursor = try #require(lazyState.pointer)
        let lazyCentre = try #require(lazyState.frames[lazyState.scene.focus]).center
        #expect(abs(lazyCursor.x - lazyCentre.x) > 1)

        for rung in [MouseFollowsFocus.exceptHover, .force] {
            let state = try Self.state("mouse.follows-focus", Self.config(followsFocus: rung), at: 6.2)
            let cursor = try #require(state.pointer)
            let centre = try #require(state.frames[state.scene.focus]).center
            #expect(abs(cursor.x - centre.x) < 0.5, "\(rung) should recentre")
        }
    }

    @Test func everyRungGetsADistinctReading() throws {
        // The point of three beats: no two rungs trace the same three resting places, so the control is
        // a comparison rather than four words with one picture.
        var seen: [[Point]] = []
        for rung in MouseFollowsFocus.allCases {
            let rests = try Self.rests(rung)
            #expect(!seen.contains(rests), "\(rung) is indistinguishable from a rung above it")
            seen.append(rests)
        }
    }

    // The hand

    @Test func aScriptedTravelAcceleratesCoastsAndDeceleratesAndIsBowed() throws {
        // A hand reaching for something does not set off and stop dead inside one frame, and one that
        // does is the tell that reads as a cursor teleporting and then sliding. It does not go in a
        // straight line either, which is the other difference between a person and a timer.
        let config = Self.config(followsMouse: true)
        let take = try #require(Catalog.take(for: "focus.follows-mouse", config: config))
        func at(_ t: Double) throws -> Point {
            try #require(PreviewModel.state(of: take, at: t, config: config,
                                            workingArea: Self.area).pointer)
        }
        // Four quarter-points of the first travel. The middle two steps are the fastest and the ends
        // are the slowest, which is the whole shape of a reach.
        let a = try at(1.0), b = try at(1.125), c = try at(1.25), d = try at(1.375), e = try at(1.5)
        let steps = [b.x - a.x, c.x - b.x, d.x - c.x, e.x - d.x].map(abs)
        #expect(steps[1] > steps[0] * 2, "it has to leave slowly")
        #expect(steps[2] > steps[3] * 2, "and arrive slowly")
        #expect(abs(steps[1] - steps[2]) < steps[1] * 0.2, "and be symmetric about the middle")
        // The path through space is unchanged: the middle of it is still off the line between its ends.
        let straight = (a.y + e.y) / 2
        #expect(abs(c.y - straight) > 5)
    }

    @Test func aTravelStillLandsExactlyAndOnTime() throws {
        // Easing the pace must not move the destination or the moment it is reached, or every beat
        // scheduled after a travel drifts.
        let config = Self.config(followsMouse: true)
        let take = try #require(Catalog.take(for: "focus.follows-mouse", config: config))
        func at(_ t: Double) throws -> Point {
            try #require(PreviewModel.state(of: take, at: t, config: config,
                                            workingArea: Self.area).pointer)
        }
        // The beat is at 1.0 and the travel takes `handTravel`; a hair before the end it is all but
        // there, and at the end it is exactly there.
        let landed = try at(1.0 + Scenes.handTravel)
        let nearly = try at(1.0 + Scenes.handTravel - 0.02)
        #expect(abs(landed.x - nearly.x) < 2)
        let target = try #require(PointerAt.window(WindowId(42))
            .point(frames: PreviewModel.state(of: take, at: 1.6, config: config,
                                              workingArea: Self.area).frames,
                   workingArea: Self.area))
        #expect(abs(landed.x - target.x) < 0.001)
    }
}
