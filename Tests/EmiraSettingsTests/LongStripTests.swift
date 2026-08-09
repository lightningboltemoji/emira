import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// `layout.center-focused-column`, which needs a set that does **not** fit on one screen: where
// everything is already visible, centring and the minimal reveal are the same arrangement.
//
// The claim: on three screens of strip the two rungs put a revealed column in **different places**, and
// the difference is where it comes to rest.

@Suite struct LongStripTests {

    static let area = PreviewModelTests.workingArea

    static func config(center: Bool) -> Config {
        var config = Config()
        config.centerFocusedColumn = center
        return config
    }

    static func state(_ center: Bool, at t: Double) throws -> PreviewState {
        let config = Self.config(center: center)
        let take = try #require(Catalog.take(for: "layout.center-focused-column", config: config))
        return PreviewModel.state(of: take, at: t, config: config, workingArea: area)
    }

    @Test func theSetIsLongerThanTheScreen() throws {
        let state = try Self.state(false, at: 0)
        let strip = state.frames.values.reduce(Rect?.none) { union, frame in
            union.map { $0.union(frame) } ?? frame
        }
        let extent = try #require(strip)
        // Three screens, near enough — a reveal needs something off the edge to reveal.
        #expect(extent.width > Self.area.width * 2.5)
    }

    @Test func theTwoRungsRestInDifferentPlaces() throws {
        // Sampled after the second reveal has settled, which is where the hold is.
        let off = try Self.state(false, at: 2.9)
        let on = try Self.state(true, at: 2.9)
        #expect(off.scrollOffset != on.scrollOffset)
    }

    @Test func offStopsTheRevealedColumnFlushAgainstTheEdge() throws {
        let off = try Self.state(false, at: 2.9)
        let focused = try #require(off.focusFrame)
        // The minimal reveal: the column that was partly off the right edge is now just inside it.
        #expect(abs(focused.maxX - (Self.area.maxX)) < 1.0)
    }

    @Test func onCarriesItOnToTheMiddle() throws {
        let on = try Self.state(true, at: 2.9)
        let focused = try #require(on.focusFrame)
        #expect(abs(focused.midX - Self.area.midX) < 1.0)
    }

    @Test func togglingRetargetsTheViewportRatherThanTheSet() throws {
        // The set is the same either way; only where it rests differs. A take that changed its columns
        // under the toggle would be showing two desktops rather than one setting.
        let off = try Self.state(false, at: 2.9)
        let on = try Self.state(true, at: 2.9)
        #expect(off.scene == on.scene)
    }
}
