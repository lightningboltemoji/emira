import AppKit
import QuartzCore
import EmiraCore

// The strip as a row of words: one cell per column, in strip order, inside a bounding rounded rect, with
// the focused column's cell on a filled chip.
//
// **The packing is the model's and the type is the renderer's.** `NamesModel` produces every rectangle,
// having measured the row through `GuideTypeface.face`; what is left here is the tree — two text layers
// per cell, a chip under the focused one, and the two concentric curves. Nothing in here measures, and
// the face it sets the row in is the one the row was measured with.
//
// **A cell is two runs, and only the first of them truncates.** The name gives up letters where the row
// is crowded; the superscript count keeps its width, because a column that says nothing about its depth
// is a column misreported rather than a column abbreviated.
//
// The ribbon's radius is the cell's plus the padding between them — `Corners.inset(by:)` states that
// relationship, and reusing it is what keeps the two curves concentric rather than merely both round.
//
// **The focus fill does not travel, and that is stated rather than missed.** The preview guide's ring
// animates because the core hands it the ring's in-flight displacement in screen space; a names cell's
// position is text-derived and the core cannot know it. The fill jumps.

/// The names guide's layer tree.
@MainActor public final class NamesGuideRenderer: GuideRenderer {

    public let style: GuideStyle = .names

    /// The ribbon: the row's bounding rounded rect, and the renderer's root.
    public let layer: CALayer = CALayer()

    /// The chip under the focused cell. Hidden when this display holds no focus.
    private let focus: RoundedLayer
    /// Pooled by position in the row — a cell has no identity of its own, and the count changes only
    /// when the strip's shape does. The word and its superscript are one cell's two runs.
    private var cells: [(label: CATextLayer, count: CATextLayer)] = []

    private let contentsScale: CGFloat
    private var painted: GuidePalette?

    public init(contentsScale: CGFloat) {
        self.contentsScale = contentsScale
        layer.contentsScale = contentsScale
        layer.masksToBounds = true

        focus = RoundedLayer(contentsScale: contentsScale)
        layer.addSublayer(focus.layer)
    }

    public func draw(_ drawing: GuideDrawing, settings: GuideSettings, scale: Double,
                     palette: GuidePalette, sources: GuideSources) {
        // A renderer draws its own style and the host is what pairs the two; a drawing of another
        // guide's is nothing rather than a wrong picture.
        guard case .names(let model) = drawing else { return }
        // The type the cells were packed for, not a second reading of the setting they were packed
        // from: a face a fraction off the model's would set words wider than the cells holding them.
        let metrics = model.metrics
        let type = GuideTypeface.font(size: metrics.fontSize * scale)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        restyle(to: palette)
        fitCells(to: model.cells.count)

        layer.bounds = CGRect(origin: .zero, size: CGSize(width: model.panel.width * scale,
                                                          height: model.panel.height * scale))
        layer.cornerRadius = CGFloat((Self.cellRadius(metrics) + metrics.padding) * scale)

        let focused = model.cells.first(where: \.isFocused)
        focus.layer.isHidden = focused == nil
        if let cell = focused {
            focus.place(local(cell.rect, in: model.panel, scale: scale),
                        corners: .uniform(Self.cellRadius(metrics) * scale))
        }
        for (runs, cell) in zip(cells, model.cells) {
            set(runs.label, to: cell.label, at: cell.labelRect,
                in: model.panel, scale: scale, type: type,
                colour: cell.isFocused ? palette.labelFocused : palette.label)
            set(runs.count, to: cell.count, at: cell.countRect,
                in: model.panel, scale: scale, type: type,
                colour: cell.isFocused ? palette.labelFocused : palette.label)
        }
        CATransaction.commit()
    }

    /// One run of one cell, placed at the rect the model measured it into.
    private func set(_ text: CATextLayer, to string: String, at rect: Rect, in panel: Rect,
                     scale: Double, type: NSFont, colour: CGColor) {
        text.isHidden = string.isEmpty
        text.frame = local(rect, in: panel, scale: scale)
        text.font = type
        text.fontSize = type.pointSize
        text.foregroundColor = colour
        if text.string as? String != string { text.string = string }
    }

    /// A cell's own curve, a little over a third of the type size — enough to read as a chip and not as
    /// a pill, and the radius the ribbon's own is measured concentric to.
    private static func cellRadius(_ metrics: NamesModel.Metrics) -> Double {
        0.4 * metrics.fontSize
    }

    /// A panel-local (top-left) rect in the ribbon's own (bottom-left) coordinates, at `scale`.
    private func local(_ rect: Rect, in panel: Rect, scale: Double) -> CGRect {
        CGRect(x: rect.minX * scale, y: (panel.height - rect.maxY) * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    /// Grow or shrink the cell pool. New cells go in above the chip, so the focused label draws over the
    /// fill it sits on.
    private func fitCells(to count: Int) {
        while cells.count > count {
            let last = cells.removeLast()
            last.label.removeFromSuperlayer()
            last.count.removeFromSuperlayer()
        }
        while cells.count < count {
            cells.append((label: run(truncates: true), count: run(truncates: false)))
        }
    }

    /// One text layer. Left-aligned because the model has already said where the run starts — a
    /// centring here would be a second opinion about a rect that was measured for the string in it.
    private func run(truncates: Bool) -> CATextLayer {
        let text = CATextLayer()
        text.contentsScale = contentsScale
        text.alignmentMode = .left
        text.truncationMode = truncates ? .end : .none
        text.isWrapped = false
        layer.addSublayer(text)
        return text
    }

    private func restyle(to palette: GuidePalette) {
        guard painted != palette else { return }
        painted = palette
        layer.backgroundColor = palette.panelFill
        layer.borderColor = palette.panelEdge
        layer.borderWidth = 0
        focus.style(fill: palette.focusFill, edge: nil)
    }
}
