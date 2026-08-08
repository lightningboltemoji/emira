import AppKit

// A scene names **roles**; this resolves each to an app actually installed on the machine and asks the
// workspace for its icon. That keeps a scene a scripted fact rather than a snapshot of whatever happens
// to be open, while still making the demo look like the user's own desktop.
//
// `NSWorkspace.icon(forFile:)` — no grant, no capture, and nothing about the running desktop.

enum MockIcons {

    /// Candidates per role, most-wanted first. Bundle identifiers rather than paths: an app the user
    /// moved or installed somewhere else still answers, and the system apps stay right whatever Apple
    /// does with `/Applications` next.
    static let candidates: [MockRole: [String]] = [
        .editor: ["com.microsoft.VSCode", "com.apple.dt.Xcode", "dev.zed.Zed",
                  "com.sublimetext.4", "com.apple.TextEdit"],
        .browser: ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
                   "company.thebrowser.Browser"],
        .terminal: ["com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
                    "com.mitchellh.ghostty"],
        .chat: ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS"],
        .notes: ["com.apple.Notes", "md.obsidian", "notion.id"],
        .music: ["com.apple.Music", "com.spotify.client"],
    ]

    /// The side, in device pixels, every icon is rasterized at. Comfortably above the largest a pane
    /// draws one at, so the layer is always *down*-scaling — which is sharp, where upscaling is not.
    static let rasterSide = 512

    /// The icon for `role`, rasterized and ready to be a layer's `contents`.
    ///
    /// **Not the `NSImage`.** `NSWorkspace.icon(forFile:)` answers an image whose `size` is 32 points
    /// even though it carries representations up to 2048 px, and `CALayer.contents` resolves an
    /// `NSImage` through that size — so a layer gets a 64 px bitmap and scales it up six-fold to fill a
    /// pane. Asking for the pixels wanted, once, is the whole fix.
    ///
    /// Cached: a scene asks for the same handful of roles on every rebuild, and this reads a bundle off
    /// disk and rasterizes half a megapixel.
    @MainActor
    static func icon(for role: MockRole) -> CGImage? {
        if let cached = cache[role] { return cached }
        let image = rasterize(resolve(role) ?? generic, side: rasterSide)
        cache[role] = image
        return image
    }

    /// `image` drawn into a bitmap `side` pixels square. For artwork that **is** square — an app icon.
    @MainActor
    static func rasterize(_ image: NSImage, side: Int) -> CGImage? {
        rasterize(image, pixels: CGSize(width: side, height: side))
    }

    /// `image` drawn `height` pixels tall, **at its own aspect ratio**.
    ///
    /// The distinction matters because `NSImage.draw(in:)` scales to *fill* the rect it is handed and
    /// does not preserve aspect. An SF Symbol is rarely square — a battery is about two to one — so
    /// rasterizing one into a square bitmap squashes it, and no `contentsGravity` downstream can undo
    /// that: by then the pixels themselves are wrong.
    @MainActor
    static func rasterize(_ image: NSImage, height: Int) -> CGImage? {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let width = max(1, Int((CGFloat(height) * aspect).rounded()))
        return rasterize(image, pixels: CGSize(width: width, height: height))
    }

    /// `draw(in:)` picks the best representation for the rect it is given, which is what reaches past a
    /// 32-point `size` to the 512 px artwork underneath it.
    @MainActor
    private static func rasterize(_ image: NSImage, pixels: CGSize) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = pixels
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: pixels),
                   from: .zero, operation: .sourceOver, fraction: 1)
        return rep.cgImage
    }

    @MainActor private static var cache: [MockRole: CGImage?] = [:]

    @MainActor
    private static func resolve(_ role: MockRole) -> NSImage? {
        for id in candidates[role] ?? [] {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                continue
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    /// The system's generic application icon — a real icon rather than a drawn placeholder, so a machine
    /// with none of the candidates installed still shows something that reads as an app.
    @MainActor
    private static var generic: NSImage {
        NSWorkspace.shared.icon(for: .application)
    }
}
