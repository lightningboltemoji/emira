import Testing
import EmiraCore
import EmiraMotion
@testable import EmiraSettings

// The springs under the mock desktop. Two properties matter and neither needs a window: a change landing
// mid-flight must not cost the layer its speed, and everything must eventually stop.

@Suite struct PreviewMotionTests {

    /// Most of this suite is about the spring machinery rather than about which spring drives what, so
    /// it runs one spring everywhere and `theRightSpringDrivesEachQuantity` covers the split.
    static func uniform(_ spring: SpringParams) -> PreviewSprings {
        PreviewSprings(scroll: spring, resize: spring, movement: spring)
    }

    static let workingArea = PreviewModelTests.workingArea

    static func state(columnGap: Double, scene: Scene = Scenes.threeColumns) -> PreviewState {
        var config = Config()
        config.columnGap = columnGap
        return PreviewModel.state(of: scene, config: config, workingArea: workingArea)
    }

    static let third = Scenes.threeColumns.columns[2].windows[0].id

    @Test func aSnapLeavesNothingInFlight() {
        var motion = PreviewMotion()
        motion.snap(to: Self.state(columnGap: 8))

        #expect(motion.windows.isEmpty)
        #expect(motion.isSettled())
        // A preview that sprang into place on being opened would be animating the act of opening.
        let frames = motion.frames(of: Self.state(columnGap: 8))
        #expect(frames[Self.third] == Self.state(columnGap: 8).frames[Self.third])
    }

    @Test func aRetargetSeedsTheDisplacementItJustLost() throws {
        var motion = PreviewMotion()
        motion.snap(to: Self.state(columnGap: 8))
        motion.retarget(to: Self.state(columnGap: 18), springs: Self.uniform(.smooth))

        // The first frame reproduces the old layout exactly, so there is no pop at the raise.
        let drawn = motion.frames(of: Self.state(columnGap: 18))
        let before = try #require(Self.state(columnGap: 8).frames[Self.third])
        let shown = try #require(drawn[Self.third])
        #expect(abs(shown.minX - before.minX) < 1e-9)
    }

    @Test func aRetargetMidFlightKeepsTheVelocityAlreadyBuilt() throws {
        var motion = PreviewMotion()
        motion.snap(to: Self.state(columnGap: 8))
        motion.retarget(to: Self.state(columnGap: 18), springs: Self.uniform(.smooth))
        motion.advance(by: 0.05)

        let travelling = try #require(motion.windows[Self.third]).x.velocity
        #expect(travelling != 0)

        motion.retarget(to: Self.state(columnGap: 28), springs: Self.uniform(.smooth))
        let after = try #require(motion.windows[Self.third]).x.velocity

        // A `nudge`, not a fresh animator: the second change must lose neither the ground already
        // covered nor the speed.
        #expect(after == travelling)
    }

    @Test func retargetingToTheSameArrangementChangesNothing() {
        // The frame loop leans on this: it retargets every frame so that a beat firing since the last
        // one travels rather than cuts, which is only free if an unchanged arrangement is a no-op.
        var motion = PreviewMotion()
        motion.snap(to: Self.state(columnGap: 8))
        motion.retarget(to: Self.state(columnGap: 8), springs: Self.uniform(.smooth))
        #expect(motion.windows.isEmpty)

        motion.retarget(to: Self.state(columnGap: 18), springs: Self.uniform(.smooth))
        motion.advance(by: 0.05)
        let travelling = motion

        motion.retarget(to: Self.state(columnGap: 18), springs: Self.uniform(.smooth))
        #expect(motion == travelling)
    }

    @Test func everythingSettles() {
        var motion = PreviewMotion()
        motion.snap(to: Self.state(columnGap: 8))
        motion.retarget(to: Self.state(columnGap: 40), springs: Self.uniform(.smooth))
        #expect(!motion.isSettled())

        for _ in 0..<600 { motion.advance(by: 1.0 / 120.0) }

        #expect(motion.isSettled())
        // And a settled preview draws exactly the layout, with nothing left over.
        let target = Self.state(columnGap: 40)
        let drawn = motion.frames(of: target)
        for (id, frame) in target.frames {
            let shown = drawn[id] ?? .zero
            #expect(abs(shown.minX - frame.minX) < 0.5)
            #expect(abs(shown.width - frame.width) < 0.5)
        }
    }

    @Test func pruningDropsWhatHasArrived() {
        var motion = PreviewMotion()
        motion.snap(to: Self.state(columnGap: 8))
        motion.retarget(to: Self.state(columnGap: 40), springs: Self.uniform(.smooth))
        #expect(!motion.windows.isEmpty)

        for _ in 0..<600 { motion.advance(by: 1.0 / 120.0) }
        motion.prune()

        // A long-running take must not accumulate one entry per window it ever moved.
        #expect(motion.windows.isEmpty)
    }

    @Test func aWindowThatLeftTheSetTakesItsAnimatorWithIt() {
        var motion = PreviewMotion()
        motion.snap(to: Self.state(columnGap: 8))
        motion.retarget(to: Self.state(columnGap: 18), springs: Self.uniform(.smooth))
        #expect(motion.windows[Self.third] != nil)

        // A different set entirely — none of the three columns' ids are in it.
        motion.retarget(to: Self.state(columnGap: 18, scene: Scenes.twoColumns), springs: Self.uniform(.smooth))
        #expect(motion.windows.isEmpty)
    }

    @Test func theSpringComesFromTheDraft() throws {
        // The springs section previews itself: a stiffer spring covers more ground in the same time.
        func travelled(stiffness: Double) throws -> Double {
            var motion = PreviewMotion()
            motion.snap(to: Self.state(columnGap: 8))
            motion.retarget(to: Self.state(columnGap: 40),
                            springs: Self.uniform(SpringParams(stiffness: stiffness, dampingRatio: 1)))
            motion.advance(by: 0.1)
            return abs(try #require(motion.windows[Self.third]).x.current)
        }

        // Both are displacements decaying to zero, so the stiffer one has less of it left.
        #expect(try travelled(stiffness: 400) < travelled(stiffness: 80))
    }

    // Which spring drives what

    static let split = PreviewSprings(scroll: SpringParams(stiffness: 111, dampingRatio: 1),
                                      resize: SpringParams(stiffness: 222, dampingRatio: 1),
                                      movement: SpringParams(stiffness: 333, dampingRatio: 1))

    static func played(_ take: Take, from: Double, to: Double,
                       config: Config = Config()) -> PreviewMotion {
        var motion = PreviewMotion()
        motion.snap(to: PreviewModel.state(of: take, at: from, config: config,
                                           workingArea: workingArea))
        motion.retarget(to: PreviewModel.state(of: take, at: to, config: config,
                                               workingArea: workingArea), springs: split)
        return motion
    }

    @Test func aWidthChangingTravelsUnderTheResizeSpring() throws {
        // `cycleWidth` is what the resize spring's own help sentence names: a column's width.
        let take = Take(scene: Scenes.threeColumns, beats: [(1, .cycleWidth)], period: 10)
        let motion = Self.played(take, from: 0, to: 2)

        let cycled = try #require(motion.windows[WindowId(2)])
        #expect(cycled.width.params.stiffness == 222)
    }

    @Test func aViewportThatMovedTravelsUnderTheScrollSpring() throws {
        // Four half-width columns overflow the strip, so focusing right scrolls it — and every window
        // shifts by the same amount without changing size.
        var config = Config()
        config.columnGap = 8
        let take = Take(scene: Scenes.fourColumns, beats: [(1, .focusRight)], period: 10)
        let motion = Self.played(take, from: 0, to: 2, config: config)

        let shifted = try #require(motion.windows[WindowId(11)])
        #expect(shifted.x.params.stiffness == 111)
        #expect(shifted.width.current == 0, "nothing resized, so this is a translation")
    }

    @Test func aRearrangementThatDidNotScrollTravelsUnderTheMovementSpring() throws {
        // A gap change slides the later columns along without resizing any of them and without moving
        // the viewport — which leaves exactly "a window the strip rearranged".
        var motion = PreviewMotion()
        motion.snap(to: Self.state(columnGap: 8))
        let after = Self.state(columnGap: 18)
        #expect(after.scrollOffset == Self.state(columnGap: 8).scrollOffset)
        motion.retarget(to: after, springs: Self.split)

        let slid = try #require(motion.windows[Self.third])
        #expect(slid.x.params.stiffness == 333)
    }

    // The mock pointer

    static func pointerState(follows: MouseFollowsFocus, focus: WindowId,
                             hides: Bool = false) -> PreviewState {
        var config = Config()
        config.mouseFollowsFocus = follows
        config.hidesCursor = hides
        return PreviewModel.state(of: Scenes.twoColumns.focusing(focus),
                                  config: config, workingArea: workingArea)
    }

    @Test func thePointerTravelsOnFocusAndStaysPutWhenItIsOff() throws {
        let left = Self.pointerState(follows: .force, focus: WindowId(21))
        let right = Self.pointerState(follows: .force, focus: WindowId(22))
        #expect(try #require(left.pointer).x != #require(right.pointer).x)

        // Off is the demonstration: focus moves and the pointer does not.
        let offLeft = Self.pointerState(follows: .off, focus: WindowId(21))
        let offRight = Self.pointerState(follows: .off, focus: WindowId(22))
        #expect(offLeft.pointer == offRight.pointer)
    }

    @Test func hidingThePointerLeavesItWhereItIsAndStopsDrawingIt() throws {
        let shown = Self.pointerState(follows: .force, focus: WindowId(22))
        let hidden = Self.pointerState(follows: .force, focus: WindowId(22), hides: true)

        #expect(shown.isPointerShown)
        #expect(!hidden.isPointerShown)
        // `hide` is about drawing, not about following — the two settings must stay separable.
        #expect(shown.pointer == hidden.pointer)
    }

    @Test func aSetWithNoPointerHasNone() {
        var config = Config()
        config.mouseFollowsFocus = .force
        let state = PreviewModel.state(of: Scenes.threeColumns, config: config,
                                       workingArea: Self.workingArea)
        #expect(state.pointer == nil)
    }

    @Test func thePointerSpringsToItsNewPlaceRatherThanJumping() throws {
        var motion = PreviewMotion()
        motion.snap(to: Self.pointerState(follows: .force, focus: WindowId(21)))
        let after = Self.pointerState(follows: .force, focus: WindowId(22))
        motion.retarget(to: after, springs: Self.uniform(.smooth))

        // The first frame is still where it was.
        let start = try #require(Self.pointerState(follows: .force, focus: WindowId(21)).pointer)
        let drawn = try #require(motion.pointer(of: after))
        #expect(abs(drawn.x - start.x) < 1e-9)

        #expect(!motion.isSettled())
        for _ in 0..<600 { motion.advance(by: 1.0 / 120.0) }
        #expect(motion.isSettled())
        #expect(abs(try #require(motion.pointer(of: after)).x - #require(after.pointer).x) < 0.5)
    }
}
