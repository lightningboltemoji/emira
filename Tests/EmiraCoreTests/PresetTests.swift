import Foundation
import Testing
@testable import EmiraCore

/// Cyclable width/height presets — resolution against a working extent and wrap-around cycling.
@Suite struct PresetTests {

    @Test func presetSizeResolvesProportionAndFixed() {
        let plain = Extent(span: 1000, gap: 0)
        #expect(plain.resolve(.proportion(0.5)) == 500)
        #expect(Extent(span: 900, gap: 0).resolve(.proportion(1.0 / 3.0)) == 300)
        #expect(plain.resolve(.fixed(800)) == 800)                    // ignores the span
        #expect(Extent(span: 1000, gap: 20).resolve(.fixed(800)) == 800)   // …and the gap
    }

    /// The identity the whole type exists for: proportions summing to 1 fill the span exactly, whatever
    /// the gap, however they partition it, and into however many pieces. `n` tiles pay `n` gaps and only
    /// `n − 1` sit between them; the odd one is the one folded into the span.
    @Test(arguments: [0.0, 8.0, 20.0, 64.0])
    func proportionsSummingToOneFillTheSpanExactly(gap: Double) {
        let extent = Extent(span: 1472, gap: gap)
        for parts in [[0.5, 0.5], [0.5, 0.25, 0.25], [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
                      [0.25, 0.25, 0.25, 0.25], [0.7, 0.3], [1.0]] {
            let widths = parts.map { extent.resolve(.proportion($0)) }
            let run = widths.reduce(0, +) + Double(parts.count - 1) * gap
            #expect(abs(run - extent.span) < 1e-9,
                    "\(parts) at gap \(gap) ran to \(run), not \(extent.span)")
        }
    }

    /// And when they don't sum to 1, what is left over (or overflows) is exactly the shortfall's share of
    /// the widened span — so a strip under-fills or scrolls by precisely what was over- or under-asked.
    @Test func aPartitionShortOfOneLeavesExactlyItsShortfall() {
        let extent = Extent(span: 1472, gap: 20)
        let parts = [0.25, 0.25, 0.25]                              // Σp = ¾
        let widths = parts.map { extent.resolve(.proportion($0)) }
        let run = widths.reduce(0, +) + Double(parts.count - 1) * 20
        #expect(abs((extent.span - run) - 0.25 * (extent.span + 20)) < 1e-9)
    }

    /// A full-extent proportion is the span itself whatever the gap — one tile pays a gap it also had
    /// folded in. `fullscreen` resolves through this, so it must not drift by a gap.
    @Test(arguments: [0.0, 20.0, 64.0])
    func aFullProportionIsTheSpanItself(gap: Double) {
        #expect(Extent(span: 1472, gap: gap).resolve(.proportion(1.0)) == 1472)
    }

    /// `proportion(of:)` is `resolve`'s inverse, which is what lets `grow` record a resolved width as an
    /// intent without the column shifting under it on the next pass.
    @Test(arguments: [0.0, 20.0])
    func proportionOfIsTheInverseOfResolve(gap: Double) {
        let extent = Extent(span: 1472, gap: gap)
        for points in [100.0, 353.0, 726.0, 1472.0] {
            #expect(abs(extent.resolve(extent.proportion(of: points)) - points) < 1e-9)
        }
    }

    /// At zero gap the fold vanishes and a proportion is the plain share it always was — which is what
    /// lets every zero-gap test in the suite stand as the guard on the rest.
    @Test func aZeroGapExtentIsThePlainShare() {
        for fraction in [0.25, 1.0 / 3.0, 0.5, 1.0, 1.5] {
            #expect(Extent(span: 900, gap: 0).resolve(.proportion(fraction)) == 900 * fraction)
        }
    }

    @Test func defaultWidthsAreTheThirdHalfTwoThirdsLadder() {
        let w = PresetCycle.defaultWidths
        #expect(w.count == 3)
        #expect(w.size(at: 0) == .proportion(1.0 / 3.0))
        #expect(w.size(at: 1) == .proportion(1.0 / 2.0))
        #expect(w.size(at: 2) == .proportion(2.0 / 3.0))
        #expect(w.resolved(at: 1, in: Extent(span: 1000, gap: 0)) == 500)
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
