import AppKit
import ImageIO

// The window's heading: the README's wordmark, animated — each letter of "emira" is a window, emira's
// commands play on them, and the word rests whole before they start again. Drawn by `.github/logo`. An
// animated WebP that ImageIO decodes with its alpha, so one file carries both appearances.
//
// **One frame is decoded at a time.** All of them held at the size this draws is hundreds of MB for a
// decoration, which is exactly what a `CAKeyframeAnimation` over `contents` requires; a single frame costs
// ~1 ms. So the view keeps the clock itself: every display refresh asks which frame is due and decodes it
// if it changed. A refresh-driven clock is never late by its own decode, and a 60 Hz display shows every
// other frame of a 120 fps asset rather than playing it at half speed.

/// The animated wordmark, as a view that draws itself from the asset's frames.
@MainActor
final class Wordmark: NSView {

    /// The size it draws at, in points — the asset's aspect. `.github/logo` exports the app's copy at
    /// exactly twice this, so a frame decodes without resampling.
    static let size = NSSize(width: 295, height: 85)

    /// Frames are decoded to twice the drawn size, which is the backing scale of every display that has
    /// one. Asking for fewer pixels is what makes the per-frame decode cheap.
    private static let pixelWidth = size.width * 2

    /// What a frame that declares no delay gets: the rate the asset is written at.
    private static let defaultDelay: TimeInterval = 1.0 / 120

    private let source: CGImageSource
    /// When each frame comes due, in seconds into the loop.
    private let starts: [TimeInterval]
    private let loop: TimeInterval

    private var link: CADisplayLink?
    /// The refresh the loop started on — the first one after the view reached a window.
    private var origin: CFTimeInterval?
    private var shown = -1

    /// `nil` when the asset is missing or unreadable, and the window opens without a heading — a
    /// decoration may not be the reason onboarding can't be shown.
    init?(searching roots: [URL] = Wordmark.resourceRoots) {
        guard let url = Self.logoURL(searching: roots),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let delays = Self.delays(of: source)
        self.source = source
        self.starts = delays.indices.map { delays[..<$0].reduce(0, +) }
        self.loop = delays.reduce(0, +)
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
    /// cheap to take up front. Unclamped, because the clamped delay reads a 120 fps frame as 100 ms.
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

    /// The clock runs while the view is in a window. The link holds the view, so it has to be let go of
    /// here — nothing else ends it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        origin = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)       // `.common` covers onboarding's modal session
        self.link = link
    }

    /// Show the frame due when this refresh reaches the glass.
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let origin = self.origin ?? now
        self.origin = origin
        let t = (now - origin).truncatingRemainder(dividingBy: loop)
        // The last frame starting at or before `t`; `starts[0]` is 0, so there always is one.
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        show(lo - 1)
    }

    /// Draw one frame, unless it's the one already up. ImageIO composites animated WebP frames whole, so
    /// a frame is the picture and not a patch to blend.
    private func show(_ index: Int) {
        guard index != shown else { return }
        shown = index
        if let frame = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.pixelWidth,
        ] as CFDictionary) {
            layer?.contents = frame
        }
    }
}
