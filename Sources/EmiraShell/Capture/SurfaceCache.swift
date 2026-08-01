import CoreGraphics
import Foundation
import EmiraCore

// The stills that outlive their cover, so `CoverMode.immediate` has something to raise one over before
// this transition's own captures land. Three rules, and the first forces the other two.
//
//  1. **A kept still is stored small.** A window at 2× is several megabytes and this holds one per window
//     on the desktop. A quarter on each axis is a sixteenth of that, and the softness an upscale back to
//     the window's own size produces is the point rather than the price: a still filmed minutes ago must
//     not be able to pass for the window as it is now.
//  2. **Size is the whole of freshness.** A window that moved is showing the pixels it was filmed with;
//     one whose app re-laid it out is not, and nothing here can see the difference. So the size the core
//     recorded (`Effect.capture`) is matched against the size the still was filmed at, and a mismatch is
//     a miss rather than a stretch.
//  3. **Nothing is invalidated on a window's death.** `WindowId`s are never reused, so a dead window's
//     entry is unreachable rather than wrong and the byte budget collects it. No window-lifecycle
//     observation reaches this file.

/// Downsampled stills kept between covers, under a byte budget.
@MainActor
public final class SurfaceCache {

    /// Linear scale a kept still is stored at, per axis — a sixteenth of the pixels. On a 2× display that
    /// is one stored pixel per 2×2 points: a stand-in keeps its layout and loses its text, which is the
    /// band between unrecognisable and believable.
    public nonisolated static let ratio = 0.25

    /// How many bytes of kept stills to hold before the oldest are dropped. A backstop, not a working
    /// limit: at this ratio a full-screen 2× window is under 2 MB.
    public static let defaultBudget = 48 << 20

    /// Per-edge slack when matching a kept still's size against the window's — the rounding between what
    /// AX answered and what ScreenCaptureKit filmed. The identity join allows the same.
    private static let tolerance = 2.0

    private let budget: Int
    private var entries: [WindowId: CapturedSurface] = [:]
    /// Insertion order, oldest first — the eviction order. Not recency of *use*: the still that has been
    /// read most is the one most likely to be stale.
    private var order: [WindowId] = []
    private var bytes = 0

    public init(budget: Int = SurfaceCache.defaultBudget) {
        self.budget = budget
    }

    /// The still kept for `id`, if one was filmed at the size the window is at now (rule 2). Its `frame`
    /// carries the *old* origin, which is not a position: a cover places every layer from the core's own
    /// geometry in the transaction it raises in.
    public func surface(for id: WindowId, at size: Size) -> CapturedSurface? {
        guard let kept = entries[id],
              abs(kept.frame.width - size.width) <= Self.tolerance,
              abs(kept.frame.height - size.height) <= Self.tolerance
        else { return nil }
        return kept
    }

    /// The still kept for `id` whatever size it was filmed at — what the guide draws a `preview` tile
    /// from. Deliberately *not* `surface(for:at:)`: that method's size match is load-bearing for
    /// `CoverMode.immediate`, where a stale still stands in for the window at full size and must not be
    /// allowed to pass for it. In a minimap at a few percent of scale the trade reverses — staleness is
    /// invisible and a hole is not.
    public func anySurface(for id: WindowId) -> CapturedSurface? { entries[id] }

    /// Take these stills — already reduced by `reduced(_:)` — as the stand-ins later covers may raise
    /// over, evicting oldest-first back under budget.
    public func keep(_ surfaces: [WindowId: CapturedSurface]) {
        for (id, surface) in surfaces.sorted(by: { $0.key < $1.key }) {
            if let previous = entries[id] {
                bytes -= Self.byteCount(previous)
                order.removeAll { $0 == id }
            }
            entries[id] = surface
            order.append(id)
            bytes += Self.byteCount(surface)
        }
        while bytes > budget, let oldest = order.first {
            order.removeFirst()
            if let dropped = entries.removeValue(forKey: oldest) { bytes -= Self.byteCount(dropped) }
        }
    }

    /// Drop everything — the Screen Recording grant lapsed, or the display changed under us, and every
    /// kept still describes a desktop that no longer exists.
    public func removeAll() {
        entries.removeAll()
        order.removeAll()
        bytes = 0
    }

    /// Bytes currently held. Read by the daemon's log and the tests; nothing decides on it but `keep`.
    public var byteCount: Int { bytes }

    /// How many stills are kept.
    public var count: Int { entries.count }

    // MARK: - Reduction

    /// One capture at cache resolution, or `nil` if the pixels could not be redrawn — keeping nothing is
    /// safe, since a miss costs latency and never accuracy. `nonisolated` so the scale-down runs off the
    /// main actor.
    ///
    /// The corner radius is carried, never re-measured: `measuredCornerRadius` inverts an alpha deficit
    /// against the scale the still was filmed at. Alpha is preserved, because a window capture is
    /// transparent outside its corners and `WindowAnimation.stretch` derives its drop shadow from that.
    public nonisolated static func reduced(_ surface: CapturedSurface,
                                           by ratio: Double = SurfaceCache.ratio) -> CapturedSurface? {
        let image = surface.image
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard width < image.width, height < image.height else { return nil }

        // The still's own colour space where it can host a context, the device's otherwise — a space
        // `CGBitmapContext` refuses (indexed, or a pattern) is worth a colour shift in a stand-in.
        let spaces = [image.colorSpace, CGColorSpaceCreateDeviceRGB()].compactMap { $0 }
        let context = spaces.lazy.compactMap {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: $0,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue)
        }.first
        guard let context else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let reduced = context.makeImage() else { return nil }
        return CapturedSurface(image: reduced, frame: surface.frame,
                               cornerRadius: surface.cornerRadius)
    }

    private static func byteCount(_ surface: CapturedSurface) -> Int {
        surface.image.height * surface.image.bytesPerRow
    }
}
