import AppKit
import QuartzCore
import EmiraCore

// The input badge, drawn at the low centre of the mock.
//
// **It is furniture, so it is drawn at the settings window's scale and not the desktop's.** A keycap
// projected through `k` would be a couple of points across and unreadable, and a keycap is the one place
// on the mock where something has to be *read*. That is not a violation of "nothing is drawn larger than
// it is" — a cue is not on the desktop at all. It is the window saying what the user's hands did.
//
// Two states. **Taken** is the accent, at full strength; **declined** is neutral and dimmed, and that is
// the whole reason it exists: a rung whose answer is "nothing happens" needs a picture of a refusal, or
// it is indistinguishable from a preview that has stopped working.

@MainActor
final class CueLayer {

    let layer = CALayer()
    private let text = CATextLayer()
    private let contacts: [CAShapeLayer]
    private let arrow = CAShapeLayer()

    private var scale: CGFloat
    /// What is on screen, so a badge is laid out when it changes and not once a frame.
    private var shown: Cue?

    // Real points of the settings window, not of the mock desktop.
    private enum Metric {
        static let height: CGFloat = 34
        static let padding: CGFloat = 14
        static let font: CGFloat = 15
        /// Smaller than a chord's: a command is several words where a chord is two glyphs, and the
        /// badge stays a badge rather than growing into a banner across the mock.
        static let commandFont: CGFloat = 13
        static let contact: CGFloat = 7
        static let contactPitch: CGFloat = 11
        /// How far above the bottom of the display the badge floats, as a fraction of its height.
        static let lift: CGFloat = 0.09
    }

    init(scale: CGFloat) {
        self.scale = scale
        contacts = (0..<3).map { _ in
            let dot = CAShapeLayer()
            dot.contentsScale = scale
            return dot
        }

        layer.contentsScale = scale
        // **Circular, not continuous.** A squircle's corners want room either side of them, and at a
        // radius of exactly half the height there is none — the outline comes out inset with the
        // straight edges left behind as two stray ticks. A capsule is circular caps by definition.
        layer.cornerCurve = .circular
        layer.cornerRadius = Metric.height / 2
        layer.borderWidth = 1
        layer.isHidden = true
        layer.zPosition = 30

        text.contentsScale = scale
        text.alignmentMode = .center
        layer.addSublayer(text)
        for dot in contacts { layer.addSublayer(dot) }
        arrow.contentsScale = scale
        layer.addSublayer(arrow)
    }

    func reproject(scale: CGFloat) {
        self.scale = scale
        layer.contentsScale = scale
        text.contentsScale = scale
        for dot in contacts { dot.contentsScale = scale }
        arrow.contentsScale = scale
        shown = nil
    }

    /// Put the badge up, take it down, or leave it exactly as it is. `slab` is the mock's own bounds.
    func place(_ cue: Cue?, in slab: CGSize) {
        guard let cue else {
            layer.isHidden = true
            shown = nil
            return
        }
        layer.isHidden = false
        guard cue != shown || layer.bounds.height == 0 else { return }
        shown = cue

        let ink = cue.answer == .taken ? SettingsStyle.cueInk : SettingsStyle.cueDeclinedInk
        layer.backgroundColor = SettingsStyle.cueFill
        layer.borderColor = cue.answer == .taken
            ? SettingsStyle.cueEdge : SettingsStyle.cueDeclinedEdge

        let width: CGFloat
        switch cue.glyph {
        case .command(let spelling):
            // Monospaced, because this is literal config text — the string a `[keys]` binding takes,
            // rather than a label someone wrote for the occasion.
            width = label(spelling, ink: ink,
                          font: .monospacedSystemFont(ofSize: Metric.commandFont, weight: .medium),
                          size: Metric.commandFont)

        case .keys(let spelling):
            width = label(spelling, ink: ink,
                          font: .systemFont(ofSize: Metric.font, weight: .medium), size: Metric.font)

        case .swipe(let direction):
            text.isHidden = true
            // Three contacts and an arrow: a trackpad swipe has no keycap, and three fingers is what
            // separates it from a scroll wheel.
            let span = Metric.contactPitch * 2 + Metric.contact
            width = span + Metric.padding * 2 + 22
            for (i, dot) in contacts.enumerated() {
                dot.isHidden = false
                dot.fillColor = ink.cgColor
                dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0,
                                                    width: Metric.contact, height: Metric.contact),
                                  transform: nil)
                dot.frame = CGRect(x: Metric.padding + CGFloat(i) * Metric.contactPitch,
                                   y: (Metric.height - Metric.contact) / 2,
                                   width: Metric.contact, height: Metric.contact)
            }
            arrow.isHidden = false
            arrow.fillColor = ink.cgColor
            arrow.path = Self.chevron(pointing: direction, height: 12)
            arrow.frame = CGRect(x: Metric.padding + span + 8, y: (Metric.height - 12) / 2,
                                 width: 9, height: 12)
        }

        layer.bounds = CGRect(x: 0, y: 0, width: width, height: Metric.height)
        layer.position = CGPoint(x: slab.width / 2, y: slab.height * Metric.lift + Metric.height / 2)
    }

    /// Set the badge to one run of text, and answer the width it wants. The contacts and the arrow
    /// belong to the swipe alone, so anything with a label puts them away.
    private func label(_ spelling: String, ink: NSColor, font: NSFont, size: CGFloat) -> CGFloat {
        for dot in contacts { dot.isHidden = true }
        arrow.isHidden = true
        text.isHidden = false
        let attributed = NSAttributedString(string: spelling,
                                            attributes: [.font: font, .foregroundColor: ink])
        text.string = attributed
        let width = ceil(attributed.size().width) + Metric.padding * 2
        text.frame = CGRect(x: 0, y: (Metric.height - size * 1.4) / 2, width: width, height: size * 1.4)
        return width
    }

    /// A solid chevron. `right` is the only direction the swipe glyph is ever drawn in — the hand does
    /// not flip, the world does — but the shape is written both ways so nothing has to remember that.
    private static func chevron(pointing direction: Cue.Direction, height h: CGFloat) -> CGPath {
        let w: CGFloat = 9
        let path = CGMutablePath()
        switch direction {
        case .right:
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: w, y: h / 2))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: w * 0.45, y: h / 2))
        case .left:
            path.move(to: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: 0, y: h / 2))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: w * 0.55, y: h / 2))
        }
        path.closeSubpath()
        return path
    }
}
