import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

/// Outer gaps at the reducer. `Layout` owns the geometry; what belongs here is the one consequence only
/// `Engine` can show — a column bleeding into the margin is placed with `.setFrame`, not `.park`, which
/// is why the layout's visibility query is asked of the physical extent.
@Suite struct OuterGapEngineTests {

    /// Four ½-width columns on a 1000 pt display with a 50 pt margin: the content area is 900 wide, so
    /// a column is 450 and two of them fill it exactly. Scrolled to the origin, the columns land at
    /// screen 50 · 500 · 950 · 1400 — so the third begins inside the right margin and is still on the
    /// display, and the fourth is past it entirely.
    private static let config = Config(widthPresets: PresetCycle([.proportion(0.5)]),
                                       outerGaps: EdgeInsets(uniform: 50),
                                       transitionMode: .off)

    /// The placement effects for a settled four-column world scrolled to its origin. Focuses the first
    /// window, because creating windows leaves focus on the newest and the margin is only interesting at
    /// a known offset; and perturbs every frame first, because `placeAtRest` skips windows already
    /// where they belong, so a settled world would answer with a trivially-satisfying empty batch.
    private static func placements() -> (placed: [WindowId: Rect], parked: [WindowId], display: Rect) {
        var s = EngineFix.settle(EngineFix.world(4, config: config))
        (s, _) = Engine.reduce(s, .focusChanged(WindowId(1), origin: .system))
        s = EngineFix.settle(s)
        for raw in 1...4 {
            (s, _) = Engine.reduce(s, .windowFrameChanged(WindowId(UInt64(raw)),
                                                          Rect(x: 0, y: 0, width: 10, height: 10)))
        }
        let (after, effects) = Engine.reduce(s, .dragEnded)
        var placed: [WindowId: Rect] = [:]
        var parked: [WindowId] = []
        for effect in effects {
            switch effect {
            case .setFrame(let w, let r): placed[w] = r
            case .park(let w, _): parked.append(w)
            default: continue
            }
        }
        return (placed, parked, after.world.monitors.first!.frame)
    }

    @Test func aColumnInTheMarginIsPlacedNotParked() {
        let (placed, _, display) = Self.placements()
        #expect(placed[WindowId(1)] == Rect(x: 50, y: 50, width: 450, height: 700))
        #expect(placed[WindowId(2)] == Rect(x: 500, y: 50, width: 450, height: 700))
        // The one that matters: it starts inside the margin and runs off the display, and it is a
        // `setFrame` rather than a `park`.
        #expect(placed[WindowId(3)] == Rect(x: 950, y: 50, width: 450, height: 700))
        #expect(placed[WindowId(3)]!.maxX > display.maxX)
    }

    /// The complement, so the test above isn't just "nothing ever parks": the fourth column is past the
    /// display edge entirely and parks as it always did.
    @Test func aColumnPastTheDisplayStillParks() {
        let (placed, parked, _) = Self.placements()
        #expect(parked == [WindowId(4)])
        #expect(placed[WindowId(4)] == nil)
    }

    /// `grow`'s ceiling is the content width, so a full-width column leaves the margin showing rather
    /// than filling the display — the same 100% the preset ladder resolves against.
    @Test func growStopsAtTheContentWidthNotTheDisplayWidth() {
        var s = EngineFix.world(2, config: Self.config)
        for _ in 0..<10 {
            let (next, fx) = Engine.reduce(s, .command(.grow(.percent(25))))
            s = EngineFix.settle(next, fx)
        }
        let metrics = s.metrics()!
        let focused = s.world.focusedWindow!
        let column = s.layout.columns[s.layout.columnIndex(ofWindow: focused)!]
        #expect(s.layout.resolvedWidth(of: column, metrics: metrics) == 900)   // content, not 1000
    }
}
