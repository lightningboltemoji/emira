import AppKit
import Testing
@testable import EmiraSettings

// How the panel says it has more in it. Two claims, and both are arithmetic rather than taste:
//
// - **The fade is on the side that has more**, and on neither side of a list that fits. That is what
//   separates an affordance from a gradient someone liked the look of.
// - **The scroller is never a whole number of rows tall**, so a full row can never sit flush with the
//   bottom edge pretending to be the last one. It was 4.96 rows, which is the worst value there is.

@MainActor
@Suite struct ScrollFadeTests {

    static let length = 20.0

    static func fade(offset: Double, viewport: Double = 260, content: Double) -> ScrollFade {
        ScrollFade.over(offset: offset, viewport: viewport, content: content, length: length)
    }

    @Test func aListThatFitsFadesNeitherEnd() {
        #expect(Self.fade(offset: 0, content: 200) == .none)
        // Exactly full is still full — a content height that rounds to the viewport's is a list that
        // fits, and fading it would be the decoration this exists to avoid.
        #expect(Self.fade(offset: 0, content: 260) == .none)
    }

    @Test func atRestOnlyTheBottomFades() {
        let fade = Self.fade(offset: 0, content: 500)
        #expect(fade.top == 0)
        #expect(fade.bottom > 0)
    }

    @Test func atTheEndOnlyTheTopFades() {
        let fade = Self.fade(offset: 240, content: 500)
        #expect(fade.top > 0)
        #expect(fade.bottom == 0)
    }

    @Test func inTheMiddleBothFade() {
        let fade = Self.fade(offset: 120, content: 500)
        #expect(fade.top > 0 && fade.bottom > 0)
        // Symmetric here, which is the one place it should be: 120 down with 120 to go.
        #expect(abs(fade.top - fade.bottom) < 1e-9)
    }

    /// **The taper.** A fade that switched off on the last pixel of travel would read as a flicker at
    /// exactly the moment the user is looking at that edge, so the last `length` points of the run
    /// shrink it to nothing.
    @Test func theFadeTapersOverTheLastPointsOfTravel() {
        let far = Self.fade(offset: 100, content: 500)
        let near = Self.fade(offset: 230, content: 500)
        let last = Self.fade(offset: 239, content: 500)
        #expect(near.bottom < far.bottom)
        #expect(last.bottom < near.bottom)
        #expect(last.bottom > 0, "the fade must not be gone before the travel is")
    }

    @Test func aFadeIsAFractionOfTheScrollerNotOfTheContent() {
        // 20 points of a 260-point scroller, whatever is in it.
        let short = Self.fade(offset: 100, content: 500)
        let long = Self.fade(offset: 100, content: 5000)
        #expect(short.top == long.top)
        #expect(abs(short.top - Self.length / 260) < 1e-9)
    }

    @Test func aRefusedGeometryFadesNothing() {
        #expect(ScrollFade.over(offset: 0, viewport: 0, content: 500, length: 20) == .none)
        #expect(ScrollFade.over(offset: 0, viewport: 260, content: 500, length: 0) == .none)
    }

    /// The four stops never cross, which is what a gradient mask needs of them.
    @Test func theStopsAreOrderedWhereverTheScrollerIs() {
        for offset in stride(from: 0.0, through: 240.0, by: 7.5) {
            let locations = Self.fade(offset: offset, content: 500).locations
            #expect(locations.count == 4)
            for (a, b) in zip(locations, locations.dropFirst()) {
                #expect(a <= b, "stops cross at offset \(offset): \(locations)")
            }
        }
    }

    /// **Which end is which**, and it is worth a test of its own because it is the one fact here that no
    /// arrangement of views can be asked and the eye only catches at an edge. The stops run **top to
    /// bottom**, matching the geometry-flipped layer the mask sits on.
    ///
    /// Written after the first version put a fade at the top of a list scrolled to the top: the stops
    /// were spelled top-down while the mask flipped its own geometry, which cancelled the flip AppKit
    /// had already applied and reversed the axis under them.
    @Test func theLowStopsAreTheTopEdge() {
        // At rest there is more below and nothing above, so the *high* pair — the bottom edge — is the
        // one that opens, and the low pair sits shut against 0.
        let atTop = Self.fade(offset: 0, content: 500)
        #expect(atTop.locations[1] == 0, "the top pair must be shut when the list is scrolled to the top")
        #expect(atTop.locations[2] < 1, "the bottom pair must open when there is more below")

        // …and the other way at the end of the run.
        let atBottom = Self.fade(offset: 240, content: 500)
        #expect(atBottom.locations[1] > 0, "the top pair must open when there is more above")
        #expect(atBottom.locations[2] == 1, "the bottom pair must be shut at the end of the run")
    }

    /// The AppKit fact the axis rests on, asked of AppKit rather than remembered: **a flipped view's
    /// backing layer is geometry-flipped**, so layer-y 0 inside the scroller is its top edge. If this
    /// ever stops being true the fade silently inverts, and this is the only thing that would say so.
    @Test func theScrollersLayerRunsDownwardFromItsTopEdge() throws {
        let slab = ControlSlab()
        slab.show(try Draft(""))
        slab.layoutSubtreeIfNeeded()

        let scroll = try #require(Self.scroller(in: slab))
        let scrollLayer = try #require(scroll.layer)
        #expect(scroll.isFlipped)
        #expect(scrollLayer.isGeometryFlipped)

        // Where layer-y 0 lands in the slab, whose own layer is not flipped: the scroller's top edge.
        let slabLayer = try #require(slab.layer)
        let origin = scrollLayer.convert(CGPoint.zero, to: slabLayer)
        #expect(abs(origin.y - scroll.frame.maxY) < 0.5, """
        Layer-y 0 in the scroller lands at slab-y \(origin.y), not its top edge \(scroll.frame.maxY). \
        The gradient's stops are spelled top-down on the strength of that.
        """)
    }

    // The geometry the fade is describing

    /// **The scroller is half a row short of a whole number of them**, so a row is always cut. Measured
    /// off a laid-out slab rather than computed, because `chrome` is a number taken from AppKit's own
    /// button and tab metrics and this is what keeps it honest.
    @Test func theScrollerIsNeverAWholeNumberOfRowsTall() throws {
        let slab = ControlSlab()
        slab.show(try Draft(""))
        slab.layoutSubtreeIfNeeded()

        let viewport = try #require(Self.scroller(in: slab)).frame.height
        #expect(abs(viewport - ControlSlab.viewport) < 1.5, """
        The scroller measured \(viewport) against a declared \(ControlSlab.viewport). \
        `ControlSlab.chrome` is stale — re-measure it and the half-row peek comes back.
        """)

        let rows = viewport / ControlSlab.rowPitch
        let flushness = abs(rows - rows.rounded())
        #expect(flushness > 0.3, """
        The scroller is \(rows) rows tall, which lands a row flush with the bottom edge — the panel \
        then looks like it ends there. Half a row is the affordance.
        """)
    }

    /// **A section that spends a row on sub-tabs spends exactly one**, so the fold still cuts a row
    /// rather than landing in the gap between two — which would end the list on a whole row with
    /// nothing under it, the one reading the peek exists to prevent.
    @Test func aSubTabbedSectionKeepsTheHalfRowPeek() throws {
        let slab = ControlSlab()
        slab.show(try Draft(""))
        slab.select(section: try #require(ControlSlab.sections.firstIndex(of: .guide)))
        slab.layoutSubtreeIfNeeded()

        let viewport = try #require(Self.scroller(in: slab)).frame.height
        #expect(abs(viewport - (ControlSlab.viewport - ControlSlab.subtabRowHeight)) < 1.5)

        let rows = viewport / ControlSlab.rowPitch
        #expect(abs(rows - rows.rounded()) > 0.3,
                "the guide's scroller is \(rows) rows tall, which cuts nothing")
        // …and the sub-tab still leaves more than fits, or there is no peek to describe.
        let content = try #require(Self.scroller(in: slab)?.documentView).frame.height
        #expect(content > viewport, "a guide's seven rows no longer overflow")
    }

    /// The section that actually overflows does overflow, or the peek is describing nothing.
    @Test func theLayoutSectionHasMoreThanFits() throws {
        let slab = ControlSlab()
        slab.show(try Draft(""))
        slab.layoutSubtreeIfNeeded()

        let scroll = try #require(Self.scroller(in: slab))
        let content = try #require(scroll.documentView).frame.height
        #expect(content > scroll.frame.height, "Layout no longer overflows, so nothing is cut")

        let fade = ScrollFade.over(offset: 0, viewport: Double(scroll.frame.height),
                                   content: Double(content),
                                   length: Double(ControlSlab.fadeLength))
        #expect(fade.top == 0 && fade.bottom > 0, "opening on Layout should fade the bottom alone")
    }

    /// **The fade does not wait to be scrolled into existence.** The stops on the layer are what
    /// `ScrollFade` says of the geometry as it stands, with no scroll event ever having happened.
    ///
    /// Written for the bug where the panel opened with no fade at all and grew one the moment you
    /// nudged it: the update skipped its work whenever the numbers matched what it last wrote, and the
    /// first pass wrote `.none` off a viewport that had not been laid out — so the memory said "already
    /// correct" while the scroller carried no mask, and only a change in value could dislodge it.
    @Test func theFadeIsRightBeforeAnythingIsScrolled() throws {
        let slab = ControlSlab()
        slab.show(try Draft(""))
        slab.layoutSubtreeIfNeeded()

        let scroll = try #require(Self.scroller(in: slab))
        let mask = try #require(scroll.layer?.mask as? CAGradientLayer, """
        The panel opened with no mask, so it has no fade until something moves it.
        """)
        let stops = try #require(mask.locations).map(\.doubleValue)
        #expect(stops == slab.wantedFade.locations)
        // Opening on Layout: more below, nothing above.
        #expect(slab.wantedFade.top == 0 && slab.wantedFade.bottom > 0)
    }

    /// …and a mask that has gone missing is put back rather than waited for. The layer is the fact, so
    /// nothing about the slab's own bookkeeping can leave it absent.
    @Test func aMissingMaskIsPutBackOnTheNextPass() throws {
        let slab = ControlSlab()
        slab.show(try Draft(""))
        slab.layoutSubtreeIfNeeded()

        let scroll = try #require(Self.scroller(in: slab))
        scroll.layer?.mask = nil

        slab.layout()
        #expect(scroll.layer?.mask is CAGradientLayer, "the fade did not come back")
    }

    /// The content changing height is the other input, and it settles a pass after the rows do — so it
    /// is watched, not assumed. Opening the disclosure makes a short section long.
    @Test func moreContentIsEnoughToRaiseAFade() throws {
        let slab = ControlSlab()
        slab.show(try Draft(""))
        slab.layoutSubtreeIfNeeded()

        let scroll = try #require(Self.scroller(in: slab))
        let document = try #require(scroll.documentView)
        let before = slab.wantedFade

        // Grow the content behind the slab's back, exactly as a resolved layout pass does.
        document.setFrameSize(CGSize(width: document.frame.width,
                                     height: document.frame.height + 400))

        #expect(slab.wantedFade.bottom > 0)
        #expect(slab.wantedFade != before || before.bottom > 0)
        let mask = try #require(scroll.layer?.mask as? CAGradientLayer)
        let stops = try #require(mask.locations).map(\.doubleValue)
        #expect(stops == slab.wantedFade.locations, "the frame change did not reach the layer")
    }

    /// The mask goes on the scroller, whose bounds do not travel — and it does not flip its own
    /// geometry, which is the half of the bug a value type could not have caught.
    @Test func theMaskSitsOnTheScrollerAndDoesNotFlipItself() throws {
        let slab = ControlSlab()
        slab.show(try Draft(""))
        slab.layoutSubtreeIfNeeded()

        let scroll = try #require(Self.scroller(in: slab))
        let mask = try #require(scroll.layer?.mask as? CAGradientLayer,
                                "an overflowing section is not masked at all")
        #expect(mask.frame == scroll.bounds)
        #expect(mask.startPoint == CGPoint(x: 0.5, y: 0))
        #expect(mask.endPoint == CGPoint(x: 0.5, y: 1))
        #expect(!mask.isGeometryFlipped, """
        The scroller's layer is already geometry-flipped, so flipping the mask cancels it and the fade \
        comes out at the wrong end.
        """)
    }

    static func scroller(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = scroller(in: child) { return found }
        }
        return nil
    }
}
