import AppKit
import CoreGraphics

// App icons for the guide's placeholders, resolved once per bundle id and kept for the daemon's life.
//
// Two facts make the cache trivially safe. An app's icon does not change while it is running — and if
// it did, a stale one in a 6%-scale minimap is not a defect worth a file-system watch. And a bundle id
// that resolves to nothing is cached *as* nothing, so a window whose app has no icon costs one lookup
// rather than one per frame.

/// `bundleId → CGImage`, rasterized once at a fixed size.
@MainActor
public final class GuideIcons {

    /// Points on a side to rasterize at. Well above any tile the guide draws — a placeholder is scaled
    /// down into its tile, never up — and small enough that a desktop's worth costs a few hundred KB.
    private static let side = 64

    /// `nil` is a cached answer, not a miss: the outer optional is "have we looked".
    private var icons: [String: CGImage?] = [:]

    public init() {}

    /// The icon for `bundleId`, or `nil` if the app can't be found or won't rasterize.
    public func icon(for bundleId: String) -> CGImage? {
        if let known = icons[bundleId] { return known }
        let image = Self.rasterize(bundleId)
        icons[bundleId] = image
        return image
    }

    /// Drop everything — nothing calls this in the daemon; it is the seam a test needs.
    public func removeAll() { icons.removeAll() }

    private static func rasterize(_ bundleId: String) -> CGImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        // A rect, not `nil`: `NSImage` icons are multi-representation and `cgImage(forProposedRect:)`
        // picks the representation nearest the size asked for rather than the largest one.
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
