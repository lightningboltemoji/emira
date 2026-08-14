import CoreGraphics
import Foundation
import QuartzCore
import Testing
import EmiraCore
@testable import EmiraGuide

// The tile's own state machine: what it carries, and how what it carries is fitted. No window server —
// a `CALayer` off-screen answers all of this, which is why it is asserted here and the window around it
// (an `NSScreen`, an `NSWindow`) is not.
//
// The property under test is that **a tile outlives its content**. A window's still reaches
// `SurfaceCache` only when the cover it was filmed for comes down, which is strictly later than the
// frame the tile was built in, so every preview in the guide arrives at a tile already on screen.

@MainActor
@Suite struct GuideTileTests {

    static func image(_ side: Int = 8) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    static func tile() -> RoundedLayer {
        let tile = RoundedLayer(contentsScale: 2)
        tile.style(fill: CGColor(gray: 0, alpha: 1), edge: nil)
        return tile
    }

    static let square = CGRect(x: 10, y: 20, width: 100, height: 60)

    /// The one sublayer a tile ever has — its picture — or `nil` while it carries nothing.
    static func picture(of tile: RoundedLayer) -> CALayer? { tile.layer.sublayers?.first }

    // What a tile carries can change under it

    @Test func aTileBornBlankTakesAStillThatArrivesLater() throws {
        let tile = Self.tile()
        tile.place(Self.square, corners: .uniform(4))
        #expect(Self.picture(of: tile) == nil)

        tile.carry(.still(Self.image()))

        let picture = try #require(Self.picture(of: tile))
        #expect(picture.contents != nil)
        #expect(picture.contentsGravity == .resize)
        // Fitted to the shape it was placed at on an earlier frame: a content swap gets no `place` of
        // its own, so an unfitted picture would draw at zero size until the strip next changed shape.
        #expect(picture.frame == CGRect(origin: .zero, size: Self.square.size))
    }

    @Test func aStillReplacesThePlaceholderItStoodBehind() throws {
        let tile = Self.tile()
        tile.carry(.icon(Self.image()))
        tile.place(Self.square, corners: .uniform(4))

        let inscribed = try #require(Self.picture(of: tile))
        #expect(inscribed.contentsGravity == .resizeAspect)
        // An icon is square in a rectangular tile, so it is centred and padded well clear of the corners
        // — which is what lets it go without a mask.
        #expect(inscribed.frame.width == inscribed.frame.height)
        #expect(inscribed.frame.width < Self.square.width)
        #expect(inscribed.mask == nil)

        tile.carry(.still(Self.image()))

        // The same layer, refitted: a window that acquires a still is the window it already was, and
        // rebuilding its tile would throw away a path about to be drawn identically.
        let filling = try #require(Self.picture(of: tile))
        #expect(filling === inscribed)
        #expect(filling.contentsGravity == .resize)
        #expect(filling.frame == CGRect(origin: .zero, size: Self.square.size))
        #expect(filling.mask != nil)
    }

    @Test func onlyAStillWearsAMask() throws {
        let tile = Self.tile()
        tile.place(Self.square, corners: .uniform(4))

        tile.carry(.still(Self.image()))
        #expect(try #require(Self.picture(of: tile)).mask != nil)
        // An offscreen pass per tile that buys an inscribed icon nothing.
        tile.carry(.icon(Self.image()))
        #expect(try #require(Self.picture(of: tile)).mask == nil)
    }

    @Test func aTileThatLosesItsContentPaintsOnlyItself() {
        let tile = Self.tile()
        tile.place(Self.square, corners: .uniform(4))
        tile.carry(.still(Self.image()))
        #expect(Self.picture(of: tile) != nil)

        tile.carry(.blank)

        #expect(Self.picture(of: tile) == nil)
        #expect(tile.layer.path != nil)   // still its own silhouette
    }

    /// Content is offered every frame, so the frame that changes nothing has to cost nothing.
    @Test func reofferingTheContentOnScreenTouchesNoLayer() throws {
        let tile = Self.tile()
        tile.place(Self.square, corners: .uniform(4))
        let still = Self.image()
        tile.carry(.still(still))

        let picture = try #require(Self.picture(of: tile))
        let mask = picture.mask
        picture.frame = .zero   // a sentinel no re-fit would leave standing

        tile.carry(.still(still))

        #expect(Self.picture(of: tile) === picture)
        #expect(picture.mask === mask)
        #expect(picture.frame == .zero)
    }

    // Fitting follows the shape

    @Test func aResizedTileRefitsWhatItCarries() throws {
        let tile = Self.tile()
        tile.place(Self.square, corners: .uniform(4))
        tile.carry(.still(Self.image()))

        let wider = CGRect(x: 10, y: 20, width: 300, height: 60)
        tile.place(wider, corners: .uniform(4))

        let picture = try #require(Self.picture(of: tile))
        #expect(picture.frame == CGRect(origin: .zero, size: wider.size))
        #expect(picture.mask?.frame == CGRect(origin: .zero, size: wider.size))
    }

    /// A scroll translates a tile without resizing it — the case that must stay free.
    @Test func aMovedTileRebuildsNoPath() {
        let tile = Self.tile()
        tile.place(Self.square, corners: .uniform(4))
        let path = tile.layer.path

        tile.place(Self.square.offsetBy(dx: 40, dy: 0), corners: .uniform(4))

        #expect(tile.layer.path === path)
    }
}
