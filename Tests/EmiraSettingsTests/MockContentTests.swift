import Testing
import AppKit
import EmiraCore
@testable import EmiraSettings

// The still's two claims. It is rasterized at the size the projection asks for — a picture drawn at
// mock points and stretched up would be soft at every `k` — and it is **cached by that pixel size**, so
// a set of windows walking a ladder costs a picture per rung and not one per frame.

@MainActor @Suite struct MockContentTests {

    static let projection = Projection(displayFrame: Rect(x: 0, y: 0, width: 1800, height: 1169),
                                       workingArea: Rect(x: 0, y: 39, width: 1800, height: 1130),
                                       k: 0.5)

    @Test func aStillIsRasterizedAtTheSizeItWillBeDrawnAt() throws {
        let image = try #require(MockContent.still(role: .editor,
                                                   size: Size(width: 600, height: 400),
                                                   projection: Self.projection, scale: 2))
        // 600 true points · k 0.5 · 2× backing = 600 device pixels.
        #expect(image.width == 600)
        #expect(image.height == 400)
    }

    @Test func theSamePictureIsDrawnOnce() throws {
        let size = Size(width: 512, height: 333)
        let first = try #require(MockContent.still(role: .browser, size: size,
                                                   projection: Self.projection, scale: 2))
        let again = try #require(MockContent.still(role: .browser, size: size,
                                                   projection: Self.projection, scale: 2))
        #expect(first === again)
    }

    @Test func aWindowTooSmallToDrawAnswersNothing() {
        #expect(MockContent.still(role: .terminal, size: .zero,
                                  projection: Self.projection, scale: 2) == nil)
    }

    @Test func everyRoleDrawsSomething() throws {
        // The switch in `draw` is total, and a role added without a recipe would be a blank pane rather
        // than a compile error — the recipes are inside one case each, so this is what notices.
        for role in MockRole.allCases {
            let image = try #require(MockContent.still(role: role,
                                                       size: Size(width: 700, height: 500),
                                                       projection: Self.projection, scale: 1))
            #expect(image.width == 350 && image.height == 250)
        }
    }
}
