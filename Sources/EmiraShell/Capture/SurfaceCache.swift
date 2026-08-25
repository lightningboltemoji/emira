import CoreGraphics
import Foundation
import EmiraCore

// One photograph per window — the most recent one taken of it — and, beside it, which live covers are
// entitled to paint that photograph at the resolution it was filmed at. Three rules, and the first
// forces the other two.
//
//  1. **A photograph nothing is showing is stored small.** A window at 2× is several megabytes and this
//     holds one per window on the desktop, so releasing the last entitlement reduces the photograph in
//     place: a quarter on each axis, a sixteenth of the pixels. The softness an upscale back to the
//     window's own size produces follows from that budget rather than standing beside it as a second
//     purpose — and it is welcome, because a photograph filmed minutes ago must not be able to pass for
//     the window as it is now.
//  2. **Size is the whole of freshness.** A window that moved is showing the pixels it was filmed with;
//     one whose app re-laid it out is not, and nothing here can see the difference. So the size the core
//     recorded (`Effect.capture`) is matched against the size the photograph was taken at, and a
//     mismatch is a miss rather than a stretch.
//  3. **Nothing is invalidated on a window's death.** `WindowId`s are never reused, so a dead window's
//     photograph is unreachable rather than wrong and the byte budget collects it. No window-lifecycle
//     observation reaches this file.
//
// A photograph is written when it is taken and is never removed by the cover that took it: entitlement,
// lifetime and recency are three relations over one key. The first two let pixels that were paid for
// outlive the batch, the generation, and the ack that failed to place them. The third orders the
// writes, because arrival order is not film order — a batch that runs long answers after the one that
// superseded it, and the older film must lose.

/// Every window's most recent photograph — full resolution while a cover is showing it, reduced after.
@MainActor
public final class SurfaceCache {

    /// Linear scale a released photograph is stored at, per axis — a sixteenth of the pixels. On a 2×
    /// display that is one stored pixel per 2×2 points: a stand-in keeps its layout and loses its text,
    /// which is the band between unrecognisable and believable.
    public nonisolated static let ratio = 0.25

    /// How many bytes of released photographs to hold before the oldest are dropped. A backstop, not a
    /// working limit: at this ratio a full-screen 2× window is under 2 MB.
    public static let defaultBudget = 48 << 20

    /// Per-edge slack when matching a photograph's size against the window's — the rounding between what
    /// AX answered and what ScreenCaptureKit filmed. The identity join allows the same.
    private static let tolerance = 2.0

    /// One window's most recent photograph, and the three things about it that are not in its pixels.
    private struct Photo {
        var surface: CapturedSurface
        /// The batch that took it, ordering every film the session has taken. The window server
        /// serializes screenshots, so a batch queued earlier shuttered this window earlier — and a
        /// one-shot `SCScreenshotManager` still carries no time of its own.
        var mint: Int
        /// The live covers entitled to paint it. Empty ⇒ nothing is showing it, so it is a stand-in and
        /// the budget may collect it.
        var pins: Set<MonitorId> = []
        /// Whether it has already been through `reduced(_:)`. Reducing a photograph twice fades a window
        /// that is never re-filmed to nothing, one transition at a time.
        var isReduced = false
    }

    private let budget: Int
    private var photos: [WindowId: Photo] = [:]
    /// Insertion order, oldest first — the eviction order. Not recency of *use*: the photograph that has
    /// been read most is the one most likely to be stale.
    private var order: [WindowId] = []
    /// Bytes of unpinned photographs. Eviction may take only those, so they are the only ones a budget
    /// can be about: counting a live cover's own would evict every stand-in on the desk to make room for
    /// pixels that are already on screen.
    private var bytes = 0

    /// Whether a photograph outlives the cover that took it. Off, the last cover to let one go forgets
    /// it instead of reducing it. Two features want it on and neither is the other's, so the daemon
    /// names the union of the two conditions in one place (`applyShellConfig`).
    public var keepsStills: Bool

    public init(budget: Int = SurfaceCache.defaultBudget, keepsStills: Bool = false) {
        self.budget = budget
        self.keepsStills = keepsStills
    }

    // The four operations

    /// Write the photograph batch `mint` just took of `id`, pinned to `monitor` when a live cover is
    /// entitled to paint it. The only writer, and it settles entitlement and pixels **separately**: the
    /// entitlement is unconditional, holding over whichever film turns out to be the best one on hand,
    /// and the pixels are taken only where they are newer than the ones already held.
    public func record(_ surface: CapturedSurface, mintedAt mint: Int, for id: WindowId,
                       pinnedBy monitor: MonitorId?) {
        let held = photos[id]
        guard mint > held?.mint ?? .min else {
            // A slower batch, answering with a film that has been overtaken. Its entitlement is still
            // news: this cover may paint what is here, which is the better photograph of the two.
            if let monitor { pin(id, to: monitor) }
            return
        }
        var pins = held?.pins ?? []
        if let monitor { pins.insert(monitor) }
        if !pins.isEmpty {
            store(Photo(surface: surface, mint: mint, pins: pins), for: id)
        } else if keepsStills, let small = Self.reduced(surface) {
            // Nothing may paint it at capture resolution, so nothing holds it there (rule 1) — and one
            // too small to reduce is not stored at all: a copy that is neither affordable nor honest is
            // worth less than the miss it becomes.
            store(Photo(surface: small, mint: mint, isReduced: true), for: id)
        }
    }

    /// `monitor`'s cover may paint `id`'s photograph — what a stand-in match buys. It does not write:
    /// the photograph is whatever was last taken of the window, and raising a cover over one is not a
    /// film of it.
    public func pin(_ id: WindowId, to monitor: MonitorId) {
        guard var photo = photos[id] else { return }
        if photo.pins.isEmpty { bytes -= Self.byteCount(photo.surface) }
        photo.pins.insert(monitor)
        photos[id] = photo
    }

    /// `monitor`'s cover is over. The last cover to let a photograph go reduces it in place — never
    /// removed, never twice — or forgets it where nothing keeps stills. **Synchronous**: the next
    /// transition's head batch releases the outgoing cover a line before it reads this store.
    public func unpin(_ monitor: MonitorId) {
        for (id, held) in photos where held.pins.contains(monitor) {
            var photo = held
            photo.pins.remove(monitor)
            guard photo.pins.isEmpty else { photos[id] = photo; continue }
            guard keepsStills else { forget(id); continue }
            if !photo.isReduced, let small = Self.reduced(photo.surface) {
                photo.surface = small
                photo.isReduced = true
            }
            photos[id] = photo
            bytes += Self.byteCount(photo.surface)
        }
        evict()
    }

    // The reads

    /// The photograph of `id`, if one was taken at the size the window is at now (rule 2). Its `frame`
    /// carries the *old* origin, which is not a position: a cover places every layer from the core's own
    /// geometry in the transaction it raises in.
    public func surface(for id: WindowId, at size: Size) -> CapturedSurface? {
        guard let photo = photos[id],
              abs(photo.surface.frame.width - size.width) <= Self.tolerance,
              abs(photo.surface.frame.height - size.height) <= Self.tolerance
        else { return nil }
        return photo.surface
    }

    /// The photograph a live cover is entitled to paint — what `CaptureStore.surface(for:)` answers
    /// from. Gated, because `Reconstruction.addLayers` builds a layer for every window the store answers
    /// for: ungated it would paint an unmatched photograph where the base should show through.
    public func pinnedSurface(for id: WindowId) -> CapturedSurface? {
        guard let photo = photos[id], !photo.pins.isEmpty else { return nil }
        return photo.surface
    }

    /// The photograph of `id` whatever size it was taken at — what the guide draws a `preview` tile
    /// from. Deliberately *not* `surface(for:at:)`: that size match is load-bearing where a stand-in
    /// must not pass for the window, and in a minimap the trade reverses — a hole is the visible one.
    public func anySurface(for id: WindowId) -> CapturedSurface? { photos[id]?.surface }

    /// Drop every photograph nothing is showing — the Screen Recording grant lapsed, or the display
    /// changed under us, and they describe a desktop that no longer exists. A live cover's own stay:
    /// `Event.screensChanged` takes those transitions down itself.
    public func removeAll() {
        photos = photos.filter { !$0.value.pins.isEmpty }
        order = order.filter { photos[$0] != nil }
        bytes = 0
    }

    /// Bytes of the photographs nothing is showing — what the budget governs. Read by the tests;
    /// nothing decides on it but `evict`.
    public var byteCount: Int { bytes }

    /// How many photographs are held, pinned and released alike.
    public var count: Int { photos.count }

    // Housekeeping

    /// Replace `id`'s photograph, moving it to the back of the eviction order: it was just taken.
    private func store(_ photo: Photo, for id: WindowId) {
        if let previous = photos[id] {
            if previous.pins.isEmpty { bytes -= Self.byteCount(previous.surface) }
            order.removeAll { $0 == id }
        }
        photos[id] = photo
        order.append(id)
        guard photo.pins.isEmpty else { return }
        bytes += Self.byteCount(photo.surface)
        evict()
    }

    private func forget(_ id: WindowId) {
        guard let photo = photos.removeValue(forKey: id) else { return }
        if photo.pins.isEmpty { bytes -= Self.byteCount(photo.surface) }
        order.removeAll { $0 == id }
    }

    /// Back under budget, oldest first, over the photographs nothing is showing. **A pinned photograph
    /// is never evicted**: it is on screen, and it costs the budget nothing to leave there because it is
    /// coming down with its cover either way.
    private func evict() {
        var index = 0
        while bytes > budget, index < order.count {
            let id = order[index]
            guard photos[id]?.pins.isEmpty == true else { index += 1; continue }
            forget(id)                                  // …which takes it out of `order` at `index`
        }
    }

    /// One capture at cache resolution, or `nil` if the pixels could not be redrawn — keeping nothing is
    /// safe, since a miss costs latency and never accuracy. `nonisolated` so the scale-down is callable
    /// off the main actor.
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
