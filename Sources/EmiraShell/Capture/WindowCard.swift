import AppKit
import EmiraCore

// What a window that refuses capture is drawn as: a card the window's shape, with its app's icon and title.
//
// An app can take a window out of every capture (`NSWindow.sharingType = .none` — a password manager, an SSO
// or MFA prompt), and ScreenCaptureKit still answers for it: an image the right size and entirely clear.
// Painted as a photograph, that is a hoist standing for the window with nothing — no picture, and no click,
// since a clear panel passes it through — and a cover the window vanishes from mid-transition. The window
// server says which windows these are (`kCGWindowSharingState`), so the capture plane draws this instead:
// where the window is and whose, its content kept out as its app asked.

/// The stand-in for a window that cannot be photographed.
@MainActor
enum WindowCard {

    /// The corner it is cut at: the floor every plane cuts a corner nothing has read at (`Reconstruction`).
    static let radius: CGFloat = 12

    /// A card `size` points at `scale` pixels per point, or `nil` for an empty size.
    static func image(size: Size, scale: Double, title: String, app: NSRunningApplication?) -> CGImage? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, scale > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        appearance.performAsCurrentDrawingAppearance {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                       xRadius: radius, yRadius: radius)
            NSColor.windowBackgroundColor.setFill()
            outline.fill()
            NSColor.separatorColor.setStroke()
            outline.stroke()
            draw(title: title.isEmpty ? app?.localizedName ?? "" : title, icon: app?.icon, in: bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// The icon over the title over the reason, centred as one block; the icon is dropped where the card is
    /// too short to hold all three.
    private static func draw(title: String, icon: NSImage?, in bounds: CGRect) {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.lineBreakMode = .byTruncatingTail
        let lines = [
            NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: centred]),
            NSAttributedString(string: "Hidden from screen capture", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centred]),
        ].filter { $0.length > 0 }
        let heights = lines.map { ceil($0.size().height) }
        let side = min(64, bounds.height * 0.4, bounds.width * 0.4)
        let showsIcon = icon != nil && side >= 16
        let gap: CGFloat = 8
        let block = heights.reduce(0, +) + (showsIcon ? side + gap : 0)
        var y = bounds.midY + block / 2               // top of the block, drawing downwards
        if showsIcon, let icon {
            y -= side
            icon.draw(in: CGRect(x: bounds.midX - side / 2, y: y, width: side, height: side))
            y -= gap
        }
        let inset = bounds.insetBy(dx: 16, dy: 0)
        for (line, height) in zip(lines, heights) {
            y -= height
            line.draw(with: CGRect(x: inset.minX, y: y, width: inset.width, height: height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

/// Whether a window server description (`CGWindowListCreateDescriptionFromArray`) says its window is kept
/// out of every capture. A description that does not say is taken to allow it, as every window but these does.
func refusesCapture(_ description: [String: Any]) -> Bool {
    (description[kCGWindowSharingState as String] as? Int) == Int(CGWindowSharingType.none.rawValue)
}

/// Which of `numbers` the window server says refuse capture — one round trip for a batch.
func refusingCapture(_ numbers: [CGWindowID]) -> Set<CGWindowID> {
    guard !numbers.isEmpty else { return [] }
    var pointers = numbers.map { UnsafeRawPointer(bitPattern: UInt($0)) }
    guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil),
          let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
    else { return [] }
    return Set(descriptions.filter(refusesCapture).compactMap {
        $0[kCGWindowNumber as String] as? CGWindowID
    })
}
