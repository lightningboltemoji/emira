import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// The camera's two rules: **a shot contains, whole, the object the value is measured against**, and it
// never goes closer than life size. Everything else here follows from refusing to crop and refusing to
// magnify.

@Suite struct CameraTests {

    static let display = Rect(x: 0, y: 0, width: 1800, height: 1169)

    /// The real thing's arithmetic: the slab is a fixed fraction of the display, so life size is one
    /// number and it is the same on every screen emira runs on.
    static let projection = Projection(displayFrame: display,
                                       workingArea: PreviewModelTests.workingArea,
                                       k: SettingsStyle.mockWidthFraction)

    static func frame(_ subject: Rect?, maximumScale: Double = 1) -> Rect {
        Camera.frame(containing: subject, display: display,
                     lifeSize: projection.lifeSizeWidth, maximumScale: maximumScale)
    }

    @Test func atRestItIsTheWholeDisplay() {
        #expect(Self.frame(nil) == Self.display)
    }

    @Test func theSubjectIsAlwaysWhollyInside() {
        // A tall thin column, an eighth of the screen wide, in three places across it.
        for x in [0.0, 800.0, 1580.0] {
            let subject = Rect(x: x, y: 200, width: 220, height: 600)
            let frame = Self.frame(subject)
            #expect(frame.minX <= subject.minX + 1e-9)
            #expect(frame.maxX >= subject.maxX - 1e-9)
            #expect(frame.minY <= subject.minY + 1e-9)
            #expect(frame.maxY >= subject.maxY - 1e-9)
        }
    }

    @Test func aSubjectRunningOffTheEdgeIsFramedByWhatIsOnScreen() {
        // `seams` adds slack past the last column, and a set deliberately parks one half off the right.
        // Only what is on the display can be looked at, so that is what the frame is centred on.
        let frame = Self.frame(Rect(x: 1600, y: 200, width: 600, height: 600))
        #expect(frame.maxX <= Self.display.maxX + 1e-9)
        #expect(frame.maxX >= 1799)
    }

    @Test func theFrameIsTheDisplaysOwnShape() {
        // Or the mock would scale x and y differently and every window on it would be the wrong shape.
        let aspect = Self.display.width / Self.display.height
        let frame = Self.frame(Rect(x: 400, y: 300, width: 500, height: 200))
        #expect(abs(frame.width / frame.height - aspect) < 1e-9)
    }

    @Test func itNeverLeavesTheDisplay() {
        // A frame half off the panel would show the bezel from the inside.
        for subject in [Rect(x: 0, y: 0, width: 60, height: 40),
                        Rect(x: 1780, y: 1150, width: 20, height: 19)] {
            let frame = Self.frame(subject)
            #expect(frame.minX >= -1e-9 && frame.minY >= -1e-9)
            #expect(frame.maxX <= Self.display.maxX + 1e-9)
            #expect(frame.maxY <= Self.display.maxY + 1e-9)
        }
    }

    @Test func itIsNeverCloserThanLifeSize() {
        // The house rule as arithmetic: one mock point drawn for one real point, and never more.
        let frame = Self.frame(Rect(x: 900, y: 580, width: 2, height: 2))
        #expect(frame.width >= Self.projection.lifeSizeWidth - 1e-9)
        #expect(abs(Self.projection.looking(at: frame).scale - 1) < 1e-9)
    }

    @Test func onlyTheMinimapsOwnPanelIsMagnifiedPastIt() throws {
        // And it is allowed because nothing read at that framing is a length: a tile is a picture, and
        // `span` is a count. Everything measured in points keeps the cap — including the gap, which is
        // framed against the working area's own edges, and **the whole of the names guide**, every part
        // of which is type.
        for camera in [Camera.wide, .seams(slack: 0.25), .stack, .stackSeam,
                       .guideCorner(.preview), .guideCorner(.names), .guidePanel(.names)] {
            #expect(camera.maximumScale == 1, "\(camera) frames a length and may not magnify it")
        }
        #expect(Camera.guidePanel(.preview).maximumScale > 1)

        let tiny = Rect(x: 900, y: 580, width: 2, height: 2)
        #expect(Self.frame(tiny, maximumScale: Camera.readable).width
                    < Self.frame(tiny).width - 1)
    }

    @Test func aGapIsDrawnAtExactlyTheNumberInTheField() throws {
        // The whole job of a gap preview is that it can be eyeballed, and 4% over life size is a ruler
        // that lies by 4%. At the cap the points on the slab *are* the points in the field.
        for key in ["layout.column-gap", "layout.window-gap"] {
            var config = Config()
            config.columnGap = 40
            config.windowGap = 40
            let take = try #require(Catalog.take(for: key, config: config))
            let state = PreviewModel.state(of: take, at: 0, config: config,
                                           workingArea: PreviewModelTests.workingArea)
            let framing = Self.projection.looking(at: take.camera.frame(of: state,
                                                                       in: Self.projection))
            #expect(abs(framing.mock(40.0) - 40) < 0.001, "\(key) draws a 40 pt gap at \(framing.mock(40.0))")
        }
    }

    @Test func aFullHeightSubjectBarelyMovesTheLens() {
        // Which is the honest answer, not a shortcoming: containing a whole column means containing the
        // whole working height, and there is no zoom left after that. It is also why a gap is framed
        // against the two edges it holds apart rather than the two windows they belong to.
        let column = Rect(x: 400, y: 20, width: 500, height: 1100)
        #expect(Self.frame(column).width > Self.display.width * 0.9)
    }

    // The two Layout framings, resolved against a real set.

    static func state(_ take: Take) -> PreviewState {
        PreviewModel.state(of: take, at: 0, config: Config(),
                           workingArea: PreviewModelTests.workingArea)
    }

    @Test func bothGapsArePushedInAndTheyArePushedInEqually() throws {
        let between = try #require(Catalog.take(for: "layout.column-gap", config: Config()))
        let inside = try #require(Catalog.take(for: "layout.window-gap", config: Config()))

        let seams = between.camera.frame(of: Self.state(between), in: Self.projection)
        let seam = inside.camera.frame(of: Self.state(inside), in: Self.projection)

        // Both are the same shot a right angle apart: one window's height, and whatever width that
        // needs. A gap you cannot see is a setting with no picture, so neither may rest at wide.
        #expect(seams.width < Self.display.width * 0.75)
        #expect(seam.width < Self.display.width * 0.75)
        // A gap that read closer on one row than on the other would make the pan between them look
        // like a change of subject rather than a turn of the lens.
        #expect(abs(seams.width - seam.width) < Self.display.width * 0.05, "one push-in, two subjects")
    }

    @Test func theTwoGapsArePannedApart() throws {
        // The pan **is** the setting: crossing the two rows moves the lens from a seam between two
        // columns to the seam inside one, and two identical framings would make the rows one picture.
        let between = try #require(Catalog.take(for: "layout.column-gap", config: Config()))
        let inside = try #require(Catalog.take(for: "layout.window-gap", config: Config()))
        #expect(between.camera != inside.camera)
        #expect(between.camera.frame(of: Self.state(between), in: Self.projection)
                != inside.camera.frame(of: Self.state(inside), in: Self.projection))
    }

    @Test func theSeamInsideTheColumnIsWhatTheWindowGapFramesOn() throws {
        let take = try #require(Catalog.take(for: "layout.window-gap", config: Config()))
        var config = Config()
        config.windowGap = 24
        let state = PreviewModel.state(of: take, at: 0, config: config,
                                       workingArea: PreviewModelTests.workingArea)
        let seam = try #require(state.stackSeam)
        let frame = take.camera.frame(of: state, in: Self.projection)

        #expect(abs(seam.height - 24) < 0.001, "the seam is the gap, not an approximation of it")
        #expect(frame.minY < seam.minY && frame.maxY > seam.maxY)
        // Centred on the seam rather than on either window, or the gap drifts off the middle of the
        // shot as the stack's two windows take different heights.
        #expect(abs(frame.midY - seam.midY) < 1)
    }

    @Test func aColumnWithNoStackHasNoSeamAndIsFramedWhole() throws {
        // Nothing to look at inside a column of one, and the whole column is the honest answer.
        let take = Take(scene: Scenes.threeColumns.focusing(WindowId(1)), camera: .stackSeam)
        let state = Self.state(take)
        #expect(state.stackSeam == nil)
        #expect(take.camera.frame(of: state, in: Self.projection)
                == Camera.stack.frame(of: state, in: Self.projection))
    }

    @Test func aFramingOnAFocusedColumnHoldsBothOfItsSeams() throws {
        let take = try #require(Catalog.take(for: "layout.column-gap", config: Config()))
        let state = Self.state(take)
        let column = try #require(state.focusedColumnFrame)
        let frame = take.camera.frame(of: state, in: Self.projection)

        #expect(frame.minX < column.minX)
        #expect(frame.maxX > column.maxX)
    }
}
