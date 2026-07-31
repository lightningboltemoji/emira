import AppKit
import ImageIO

// The window's heading: the README's wordmark, animated — a pen writes "emira", the word lights, and it
// rests before writing again. An animated WebP that ImageIO decodes with its alpha, so one file carries
// both appearances.
//
// **One frame is decoded at a time.** All 101 of them held at the size this draws is ~35 MB for a
// decoration, which is exactly what a `CAKeyframeAnimation` over `contents` requires; a single frame costs
// ~1 ms. So the animation is a chain rather than an animation object — which the asset's own delays force
// anyway, being 40 ms per stroke and two and a half seconds of stillness at the end.

/// The animated wordmark, as a view that draws itself from the asset's frames.
@MainActor
final class Wordmark: NSView {

    /// The size it draws at, in points — the asset's aspect exactly, at half the README's scale.
    static let size = NSSize(width: 236, height: 96)

    /// Frames are decoded to twice the drawn size, which is the backing scale of every display that has
    /// one. Asking for fewer pixels is what makes the per-frame decode cheap.
    private static let pixelWidth = size.width * 2

    /// What a frame that declares no delay gets: the rate the asset was written at.
    private static let defaultDelay: TimeInterval = 0.05

    private let source: CGImageSource
    private let delays: [TimeInterval]
    private let scheduler: any DelayScheduler

    /// `nil` when the asset is missing or unreadable, and the window opens without a heading — a
    /// decoration may not be the reason onboarding can't be shown.
    init?(scheduler: any DelayScheduler = DispatchScheduler()) {
        guard let url = Self.logoURL(),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        self.source = source
        self.delays = Self.delays(of: source)
        self.scheduler = scheduler
        super.init(frame: NSRect(origin: .zero, size: Self.size))

        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.contentsScale = 2
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true

        show(0)
    }

    required init?(coder: NSCoder) { return nil }     // never comes from a nib; there aren't any

    // MARK: - Finding the asset

    /// SwiftPM's name for a target's resources — the name `make app` copies it into the bundle under.
    static let resourceBundleName = "Emira_EmiraShell.bundle"

    /// Where to look, in order: the `.app`'s `Contents/Resources`, then beside the executable.
    static var resourceRoots: [URL] {
        [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap(\.self)
    }

    /// The wordmark asset, or `nil` if it isn't where the build put it.
    ///
    /// Not `Bundle.module`: which paths its generated accessor searches depends on the toolchain, and
    /// it `fatalError`s on a miss. Resolution stays optional so `init?` can do what it promises.
    static func logoURL(searching roots: [URL] = Wordmark.resourceRoots) -> URL? {
        for root in roots {
            guard let bundle = Bundle(url: root.appendingPathComponent(resourceBundleName)) else { continue }
            if let url = bundle.url(forResource: "logo", withExtension: "webp") { return url }
        }
        return nil
    }

    /// Each frame's delay in file order, from the WebP's own metadata — no decoding, so the whole list is
    /// cheap to take up front.
    private static func delays(of source: CGImageSource) -> [TimeInterval] {
        (0..<CGImageSourceGetCount(source)).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
            let webp = properties?[kCGImagePropertyWebPDictionary as String] as? [String: Any]
            let delay = webp?[kCGImagePropertyWebPUnclampedDelayTime as String] as? TimeInterval
                ?? webp?[kCGImagePropertyWebPDelayTime as String] as? TimeInterval
                ?? defaultDelay
            // A zero delay means "as fast as you can", which for a decoration means the default.
            return delay > 0 ? delay : defaultDelay
        }
    }

    /// Draw one frame and queue the next. ImageIO composites animated WebP frames whole, so a frame is the
    /// picture and not a patch to blend. The chain ends with the view, nothing else holding its closure.
    private func show(_ index: Int) {
        if let frame = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.pixelWidth,
        ] as CFDictionary) {
            layer?.contents = frame
        }
        scheduler.schedule(after: delays[index]) { [weak self] in
            guard let self else { return }
            show((index + 1) % delays.count)
        }
    }
}
