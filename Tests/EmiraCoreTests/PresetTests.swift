import Foundation
import Testing
@testable import EmiraCore

/// Cyclable width/height presets — resolution against a working extent and wrap-around cycling.
@Suite struct PresetTests {

    @Test func presetSizeResolvesProportionAndFixed() {
        #expect(PresetSize.proportion(0.5).resolved(available: 1000) == 500)
        #expect(PresetSize.proportion(1.0 / 3.0).resolved(available: 900) == 300)
        #expect(PresetSize.fixed(800).resolved(available: 1000) == 800)   // ignores available
    }

    @Test func defaultWidthsAreTheThirdHalfTwoThirdsLadder() {
        let w = PresetCycle.defaultWidths
        #expect(w.count == 3)
        #expect(w.size(at: 0) == .proportion(1.0 / 3.0))
        #expect(w.size(at: 1) == .proportion(1.0 / 2.0))
        #expect(w.size(at: 2) == .proportion(2.0 / 3.0))
        #expect(w.resolved(at: 1, available: 1000) == 500)
    }

    @Test func cyclingWrapsForwardAndBackward() {
        let c = PresetCycle.defaultWidths        // count 3
        #expect(c.nextIndex(after: 0) == 1)
        #expect(c.nextIndex(after: 1) == 2)
        #expect(c.nextIndex(after: 2) == 0)      // wrap to start
        #expect(c.previousIndex(before: 0) == 2) // wrap to end
        #expect(c.previousIndex(before: 1) == 0)
    }

    @Test func accessorsAreTotalForDriftedIndices() {
        let c = PresetCycle.defaultWidths        // count 3
        #expect(c.size(at: 5) == c.size(at: 2))  // 5 mod 3 == 2
        #expect(c.size(at: -1) == c.size(at: 2)) // negative normalizes into range
        #expect(c.nextIndex(after: 5) == 0)      // normalize (→2) then step (→0)
    }

    @Test func emptyCycleStaysTotal() {
        let empty = PresetCycle([])
        #expect(empty.isEmpty)
        #expect(empty.count == 0)
        #expect(empty.size(at: 0) == .proportion(1.0))   // full-extent fallback, no trap
        #expect(empty.nextIndex(after: 0) == 0)
        #expect(empty.previousIndex(before: 0) == 0)
    }

    @Test func presetsRoundTripThroughCodable() throws {
        let cycle = PresetCycle([.proportion(0.25), .fixed(640), .proportion(1.0)])
        let data = try JSONEncoder().encode(cycle)
        let back = try JSONDecoder().decode(PresetCycle.self, from: data)
        #expect(back == cycle)
    }
}
