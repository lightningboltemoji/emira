import AppKit
import CoreGraphics
import QuartzCore
import Testing
import EmiraCore
@testable import EmiraGuide

// **The regression that lets a preview drift.** A cosmetic written as an absolute point count — a 20 pt
// panel radius, a 1 pt border, a half-point rule — frames a quarter-size ribbon four times too heavily,
// and that is arithmetic with no `scale` in it rather than a restyling problem.
//
// So this renders one `GuideInput` twice, at `1` and at `k`, and requires the second to be the first
// times `k` in **every** length: the panel, the tiles, the rules, the radii, the strokes and the type.
// Every guide answers for itself, because a second renderer is a second place to write a number down.

@MainActor
@Suite struct CosmeticScaleTests {

    static let working = Rect(x: 0, y: 0, width: 1600, height: 1000)

    /// Three columns, the middle one stacked two deep, focused — enough that every part of either tree
    /// is on screen: tiles, a column rule, a stack rule, the viewport and the ring for the minimap, and
    /// a stacked column's superscript for the row of names.
    static func input() -> GuideInput {
        var frames: [WindowId: Rect] = [:]
        var columns: [GuideInput.Column] = []
        var x = 0.0
        for (index, stack) in [[UInt64(1)], [2, 3], [4]].enumerated() {
            let share = working.height / Double(stack.count)
            for (row, id) in stack.enumerated() {
                frames[WindowId(id)] = Rect(x: x, y: Double(row) * share, width: 520, height: share)
            }
            x += 540
            columns.append(GuideInput.Column(id: ColumnId(UInt64(index + 1)),
                                             windows: stack.map {
                                                 GuideInput.Window(id: WindowId($0),
                                                                   bundleId: "com.test.app")
                                             }))
        }
        return GuideInput(workingArea: working, columns: columns, frames: frames, focus: WindowId(2))
    }

    static func settings() -> GuideSettings {
        GuideSettings(preview: PreviewGuideSettings(enabled: true, content: .icons,
                                                    position: .topRight, width: 0.4, span: 2,
                                                    gap: 24, duration: 1),
                      names: NamesGuideSettings(enabled: true, position: .bottomCenter, width: 1,
                                                gap: 24, fontSize: 12))
    }

    /// A rendered tree flattened to the numbers a scale has to carry, depth first. A `CAShapeLayer`
    /// keeps its curve in a `CGPath`, so the path's own box is measured rather than a stored radius —
    /// that is the number that would silently fail to scale — and a `CATextLayer` keeps its own in a
    /// point size.
    static func measured(_ layer: CALayer) -> [Double] {
        var numbers = [Double(layer.frame.minX), Double(layer.frame.minY),
                       Double(layer.frame.width), Double(layer.frame.height),
                       Double(layer.cornerRadius), Double(layer.borderWidth)]
        if let shape = layer as? CAShapeLayer {
            numbers.append(Double(shape.lineWidth))
            let box = shape.path?.boundingBoxOfPath ?? .zero
            numbers += [Double(box.minX), Double(box.minY), Double(box.width), Double(box.height)]
        }
        if let text = layer as? CATextLayer { numbers.append(Double(text.fontSize)) }
        for sublayer in layer.sublayers ?? [] { numbers += measured(sublayer) }
        return numbers
    }

    static func drawing(_ style: GuideStyle) -> GuideDrawing {
        GuideDrawing.of(style, input: input(), settings: settings(), face: GuideTypeface.face)!
    }

    static func rendered(_ style: GuideStyle, at scale: Double) -> any GuideRenderer {
        let renderer = style.renderer(contentsScale: 2)
        renderer.draw(drawing(style), settings: settings(), scale: scale, palette: .system,
                      sources: GuideSources())
        return renderer
    }

    @Test(arguments: GuideStyle.allCases, [0.25, 0.5, 2.0])
    func everyLengthInTheTreeIsTheSameGuideTimesTheScale(_ style: GuideStyle, _ k: Double) {
        let lifeSize = Self.measured(Self.rendered(style, at: 1).layer)
        let scaled = Self.measured(Self.rendered(style, at: k).layer)

        #expect(lifeSize.count == scaled.count)         // the same tree, or the comparison means nothing
        #expect(lifeSize.contains { $0 > 0 })           // …and one that actually drew something
        for (life, drawn) in zip(lifeSize, scaled) {
            #expect(abs(drawn - life * k) < 1e-9, "\(style): \(life) × \(k) drew \(drawn)")
        }
    }

    /// The ribbon's own curve and border are the two that were most conspicuously wrong: 20 pt of radius
    /// and a full point of border around a panel a quarter of the size.
    @Test func theRibbonsFrameThinsWithTheRibbon() {
        let lifeSize = Self.rendered(.preview, at: 1).layer
        let quarter = Self.rendered(.preview, at: 0.25).layer
        #expect(lifeSize.borderWidth == 1)
        #expect(abs(quarter.borderWidth - 0.25) < 1e-9)
        #expect(abs(quarter.cornerRadius - lifeSize.cornerRadius / 4) < 1e-9)
    }

    /// And the panel a *drawing* carries is in *core screen points*, unscaled — the host is what knows
    /// where those land, so one drawing is drawn at two scales and placed by two hosts.
    @Test(arguments: GuideStyle.allCases)
    func thePanelIsScreenPointsWhateverTheGuideIsDrawnAt(_ style: GuideStyle) {
        let panel = Self.drawing(style).panel
        #expect(abs(Self.rendered(style, at: 1).layer.bounds.width - panel.width) < 1e-9)
        #expect(abs(Self.rendered(style, at: 0.25).layer.bounds.width - panel.width / 4) < 1e-9)
    }
}
