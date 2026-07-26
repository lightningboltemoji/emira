import Foundation
import Testing
@testable import EmiraCore

/// The virtual-strip geometry primitives — top-left origin, framework-free, and the base every
/// layout computation is written against.
@Suite struct GeometryTests {

    // MARK: Point / Size

    @Test func pointOffsetMovesDownOnPositiveDy() {
        // Top-left origin: +dy is *down*.
        let p = Point(x: 10, y: 20).offsetBy(dx: 5, dy: 3)
        #expect(p == Point(x: 15, y: 23))
    }

    @Test func sizeAreaAndEmptiness() {
        #expect(Size(width: 4, height: 5).area == 20)
        #expect(Size.zero.isEmpty)
        #expect(Size(width: 0, height: 10).isEmpty)     // a zero dimension is empty
        #expect(Size(width: -1, height: 10).isEmpty)    // negative too
        #expect(!Size(width: 1, height: 1).isEmpty)
    }

    // MARK: Rect edges — the top-left convention

    @Test func edgesFollowTopLeftOrigin() {
        let r = Rect(x: 100, y: 200, width: 30, height: 40)
        #expect(r.minX == 100)
        #expect(r.maxX == 130)
        #expect(r.minY == 200)          // top
        #expect(r.maxY == 240)          // bottom (y grows down)
        #expect(r.width == 30)
        #expect(r.height == 40)
        #expect(r.midX == 115)
        #expect(r.midY == 220)
        #expect(r.center == Point(x: 115, y: 220))
        #expect(r.area == 1200)
    }

    @Test func offViewportRectInNegativeXBehavesNormally() {
        // The strip is infinite and columns routinely park at negative x — nothing special-cases it.
        let r = Rect(x: -5000, y: 0, width: 1, height: 40)
        #expect(r.minX == -5000)
        #expect(r.maxX == -4999)
        #expect(!r.isEmpty)
    }

    // MARK: contains — half-open [min, max)

    @Test func containsIsHalfOpen() {
        let r = Rect(x: 0, y: 0, width: 10, height: 10)
        #expect(r.contains(Point(x: 0, y: 0)))          // min edge included
        #expect(r.contains(Point(x: 5, y: 5)))
        #expect(!r.contains(Point(x: 10, y: 5)))        // max edge excluded
        #expect(!r.contains(Point(x: 5, y: 10)))
        #expect(!r.contains(Point(x: -1, y: 5)))
    }

    @Test func emptyRectContainsNothing() {
        let r = Rect(x: 5, y: 5, width: 0, height: 0)
        #expect(!r.contains(Point(x: 5, y: 5)))
    }

    // MARK: intersects — strict positive-area overlap

    @Test func intersectsDetectsOverlap() {
        let a = Rect(x: 0, y: 0, width: 10, height: 10)
        #expect(a.intersects(Rect(x: 5, y: 5, width: 10, height: 10)))   // partial
        #expect(a.intersects(Rect(x: 2, y: 2, width: 3, height: 3)))     // contained
        #expect(a.intersects(a))                                         // self
    }

    @Test func edgeTouchingRectsDoNotIntersect() {
        let a = Rect(x: 0, y: 0, width: 10, height: 10)
        #expect(!a.intersects(Rect(x: 10, y: 0, width: 10, height: 10))) // shares right edge only
        #expect(!a.intersects(Rect(x: 0, y: 10, width: 10, height: 10))) // shares bottom edge only
        #expect(!a.intersects(Rect(x: 20, y: 0, width: 5, height: 5)))   // fully disjoint
    }

    // MARK: intersection

    @Test func intersectionReturnsOverlapRegion() {
        let a = Rect(x: 0, y: 0, width: 10, height: 10)
        let b = Rect(x: 5, y: 5, width: 10, height: 10)
        #expect(a.intersection(b) == Rect(x: 5, y: 5, width: 5, height: 5))
    }

    @Test func intersectionIsNilWhenNoPositiveArea() {
        let a = Rect(x: 0, y: 0, width: 10, height: 10)
        #expect(a.intersection(Rect(x: 10, y: 0, width: 5, height: 5)) == nil) // edge-touch
        #expect(a.intersection(Rect(x: 50, y: 50, width: 5, height: 5)) == nil) // disjoint
    }

    // MARK: union

    @Test func unionIsBoundingBox() {
        let a = Rect(x: 0, y: 0, width: 10, height: 10)
        let b = Rect(x: 20, y: 5, width: 10, height: 10)
        #expect(a.union(b) == Rect(x: 0, y: 0, width: 30, height: 15))
    }

    @Test func unionIgnoresEmptyOperand() {
        // Accumulating a bounding box from .zero must not drag the result to the origin.
        let r = Rect(x: 100, y: 100, width: 10, height: 10)
        #expect(Rect.zero.union(r) == r)
        #expect(r.union(.zero) == r)
    }

    // MARK: offset / inset

    @Test func offsetByTranslatesWithoutResizing() {
        let r = Rect(x: 10, y: 10, width: 30, height: 40).offsetBy(dx: 5, dy: -3)
        #expect(r == Rect(x: 15, y: 7, width: 30, height: 40))
    }

    @Test func insetBySymmetricShrinksAndGrows() {
        let r = Rect(x: 0, y: 0, width: 100, height: 100)
        #expect(r.insetBy(dx: 10, dy: 20) == Rect(x: 10, y: 20, width: 80, height: 60))
        // Negative insets grow the rect.
        #expect(r.insetBy(dx: -5, dy: -5) == Rect(x: -5, y: -5, width: 110, height: 110))
    }

    @Test func insetByEdgeInsetsReservesStruts() {
        // A menu-bar strut reserves the top; the origin moves down and height shrinks by that much.
        let screen = Rect(x: 0, y: 0, width: 1440, height: 900)
        let usable = screen.inset(by: EdgeInsets(top: 25))
        #expect(usable == Rect(x: 0, y: 25, width: 1440, height: 875))
    }

    @Test func uniformEdgeInsetsAreAGap() {
        let r = Rect(x: 0, y: 0, width: 100, height: 100)
        #expect(r.inset(by: EdgeInsets(uniform: 8)) == Rect(x: 8, y: 8, width: 84, height: 84))
    }

    // MARK: The crop — where `WindowAnimation.crop` pins a still
    //
    // The anchor, and only the anchor: the *cutting* is the compositor's rounded clip, so this
    // deliberately answers a rect that overflows rather than one that fits.

    @Test func aGrownWindowKeepsTheStillInItsTopLeftCorner() {
        // Grown 600×400 → 900×500. The still keeps its own size, pinned to the corner; the remaining
        // 300×100 is space the window has yet to fill.
        let rect = Rect(x: 100, y: 50, width: 900, height: 500)
        #expect(rect.anchoring(Size(width: 600, height: 400))
                == Rect(x: 100, y: 50, width: 600, height: 400))
    }

    /// The still **overflows** rather than being trimmed, and that is the correction of 2026-07-26:
    /// trimming it to fit left the clip nothing to round, so the cut edge stayed square.
    @Test func aShrunkWindowOverflowsInsteadOfBeingTrimmed() {
        // 600×400 → 300×400: the still still says 600 wide, hanging 300 pt past the right edge.
        let rect = Rect(x: 100, y: 50, width: 300, height: 400)
        let placed = rect.anchoring(Size(width: 600, height: 400))
        #expect(placed == Rect(x: 100, y: 50, width: 600, height: 400))
        #expect(placed.maxX > rect.maxX)
    }

    /// The `consume` case, and the one that caught the inverted vertical anchor in the product: the
    /// window loses height, so the still must hang past the **bottom**. Hanging past the top would
    /// throw away the title bar, which is what the first version did.
    @Test func aWindowLosingHeightHangsPastTheBottomNotTheTop() {
        let rect = Rect(x: 0, y: 100, width: 900, height: 200)
        let placed = rect.anchoring(Size(width: 600, height: 400))
        #expect(placed.minY == rect.minY)                        // tops flush — nothing cut off above
        #expect(placed.maxY > rect.maxY)                         // the overflow is all below
    }

    /// At the raise a layer sits at its own capture frame, where the placement is the identity — so
    /// `.stretch` and `.crop` put identical pixels on screen and neither mode can pop.
    @Test func theCaptureFrameIsTheIdentity() {
        let frame = Rect(x: 37, y: 91, width: 600, height: 400)
        #expect(frame.anchoring(frame.size) == frame)
    }

    /// Both axes at once, in opposite directions — a `consume` grows a window's width while halving
    /// its height. The anchor is one corner, so neither axis needs a case of its own.
    @Test func theAxesAreIndependent() {
        let rect = Rect(x: 0, y: 0, width: 900, height: 200)
        let placed = rect.anchoring(Size(width: 600, height: 400))
        #expect(placed.maxX < rect.maxX)                         // grown: room to spare on the right
        #expect(placed.maxY > rect.maxY)                         // shrunk: overflowing below
    }

    // MARK: Codable

    @Test func rectRoundTripsThroughCodable() throws {
        let original = Rect(x: -12.5, y: 34, width: 100, height: 200)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Rect.self, from: data)
        #expect(decoded == original)
    }
}
