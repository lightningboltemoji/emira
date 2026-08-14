import AppKit
import Foundation
import EmiraCore

// The face a guide's words are set in, and the one place that answers how wide one is.
//
// **The model measures and the renderer sets, through the same function.** `NamesModel` packs a row it
// cannot see, so what it is handed is this — and a second reading of "the font" anywhere else would be
// two faces that agree until one of them is changed. `NamesGuideRenderer` asks `font(size:)` for the
// type it draws with; `face` measures with that same font.
//
// **Monospaced by choice rather than by necessity.** The packing is measurement now, so any face would
// pack correctly; the row is set in a monospaced one because a column of names reads as a row rather
// than as a sentence.
//
// Measurements are cached for the host's life. A name is resolved once per bundle id (`GuideNames`) and
// the strip's shape changes far less often than the guide is drawn, so the ordinary frame is a handful
// of dictionary lookups.

/// The guides' typography: the face, and what it measures.
public enum GuideTypeface {

    /// The face the names guide is set in at `size`. Floored at a point, below which a font is not a
    /// thing the text system will make.
    public static func font(size: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: CGFloat(max(size, 1)), weight: .medium)
    }

    /// What a model measures with. The one implementation both hosts pass.
    public static let face = GuideFace(width: { Measured.shared.width(of: $0, at: $1) },
                                       lineHeight: { Measured.shared.lineHeight(at: $0) })

    /// The measurements taken so far. A cache rather than a computation because the answers are
    /// stable — a name and a type size measure the same forever — and it is asked once per cell per
    /// frame.
    final class Measured: @unchecked Sendable {
        static let shared = Measured()

        private struct Key: Hashable {
            let text: String
            let size: Double
        }

        private let lock = NSLock()
        private var widths: [Key: Double] = [:]
        private var lines: [Double: Double] = [:]

        /// `text` at `size`, **rounded up to a half point**: a cell a fraction short of the word in it
        /// hands the word to the truncator, and half a point is below what any screen can show.
        func width(of text: String, at size: Double) -> Double {
            guard !text.isEmpty else { return 0 }
            let key = Key(text: text, size: size)
            if let known = lock.withLock({ widths[key] }) { return known }
            let font = GuideTypeface.font(size: size)
            let measured = Double((text as NSString).size(withAttributes: [.font: font]).width)
            let rounded = (measured * 2).rounded(.up) / 2
            lock.withLock { widths[key] = rounded }
            return rounded
        }

        /// The line box `size` sets on: the face's own ascent over descent, which is what a cell is
        /// tall enough for.
        func lineHeight(at size: Double) -> Double {
            if let known = lock.withLock({ lines[size] }) { return known }
            let font = GuideTypeface.font(size: size)
            let measured = Double(font.ascender - font.descender)
            lock.withLock { lines[size] = measured }
            return measured
        }
    }
}
