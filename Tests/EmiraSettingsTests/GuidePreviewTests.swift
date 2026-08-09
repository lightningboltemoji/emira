import Testing
import EmiraConfig
import EmiraCore
@testable import EmiraSettings

// The guide take's one real claim: it draws through **`GuideModel`'s own projection**, so the settings
// it previews are the same numbers that place the real guide. A guide scene that positioned its own
// ribbon would be a second opinion about `guide.position`, which is the setting on screen beside it.

@Suite struct GuidePreviewTests {

    static let workingArea = PreviewModelTests.workingArea

    static func state(_ change: (inout Config) -> Void) -> PreviewState {
        var config = Config()
        config.guide.style = .placeholder
        change(&config)
        return PreviewModel.state(of: Scenes.guided, config: config, workingArea: workingArea)
    }

    @Test func aSetWithNoGuideDrawsNone() {
        var config = Config()
        config.guide.style = .placeholder
        let plain = PreviewModel.state(of: Scenes.threeColumns, config: config,
                                       workingArea: Self.workingArea)
        #expect(plain.guide == nil)
    }

    @Test func turningTheGuideOffTakesItAway() {
        #expect(Self.state { $0.guide.style = .off }.guide == nil)
        #expect(Self.state { _ in }.guide != nil)
    }

    @Test func positionMovesThePanelAndNothingElse() throws {
        let topLeft = try #require(Self.state { $0.guide.position = .topLeft }.guide)
        let bottomRight = try #require(Self.state { $0.guide.position = .bottomRight }.guide)

        #expect(topLeft.panel.minX < bottomRight.panel.minX)
        #expect(topLeft.panel.minY < bottomRight.panel.minY)
        #expect(topLeft.panel.size == bottomRight.panel.size)
    }

    @Test func widthChangesHowLongTheRibbonIs() throws {
        let narrow = try #require(Self.state { $0.guide.width = 0.2 }.guide)
        let wide = try #require(Self.state { $0.guide.width = 0.4 }.guide)
        #expect(wide.panel.width > narrow.panel.width)
    }

    @Test func gapHoldsThePanelOffTheWorkingAreasEdge() throws {
        let tight = try #require(Self.state { $0.guide.position = .topLeft; $0.guide.gap = 0 }.guide)
        let held = try #require(Self.state { $0.guide.position = .topLeft; $0.guide.gap = 40 }.guide)
        #expect(held.panel.minX - tight.panel.minX == 40)
    }

    @Test func everyWindowOnTheStripGetsATileAndTheFocusedOneAlsoARing() throws {
        let guide = try #require(Self.state { _ in }.guide)
        #expect(guide.tiles.count == Scenes.guided.windows.count)
        #expect(guide.ring != nil)
        // Panel-local, so nothing is measured in screen points once it is inside the ribbon. Tiles
        // beyond the `span` project *past* the panel and the ribbon clips them — which is the low-span
        // regime the setting is a choice about, and the reason the set is eight columns long.
        #expect(guide.tiles.contains { $0.rect.minX >= -0.001
                                        && $0.rect.maxX <= guide.panel.width + 0.001 })
        for tile in guide.tiles {
            #expect(tile.rect.minY >= -0.001 && tile.rect.maxY <= guide.panel.height + 0.001)
        }
        // And each tile knows **which** window it is, which is what lets `preview` draw that window's
        // own still where `placeholder` inscribes its icon.
        #expect(Set(guide.tiles.map(\.id)) == Set(Scenes.guided.windows.map(\.id)))
    }
}
