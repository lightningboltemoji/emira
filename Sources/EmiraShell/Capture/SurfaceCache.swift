import CoreGraphics
import Foundation
import EmiraCore

// One photograph per window — the best one taken of it — and, beside it, which live covers are
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
// **A film with a hole in it is not the best one on hand**, and it is the one place the mint does not
// decide. An app that rasterizes what is on screen leaves a still transparent where the window hung off the
// display, so the newest photograph is not always the most complete one; a holed film loses to a held whole
// one *at the same size*, and to nothing else. Softness is what that costs — the held one has been through
// `reduced` — and a soft stand-in is a better answer than one with a band of nothing in it. Size is the
// condition because rule 2 governs which photograph may stand in at all, and a whole film of the wrong size
// could stand in for nothing.
//
// **A corner radius is not a photograph**, so it is kept beside them rather than in them: the scrim rounds a
// see-through window at rest, long after its photograph may have been reduced, evicted or forgotten. Rule 3
// holds for it too, and nothing collects it — it is a few bytes per window ever filmed.
//
// A photograph is written when it is taken and is never removed by the cover that took it: entitlement,
// lifetime and recency are three relations over one key. The first two let pixels that were paid for
// outlive the batch, the generation, and the ack that failed to place them. The third orders the
// writes, because arrival order is not film order — a batch that runs long answers after the one that
// superseded it, and the older film must lose unless it is the whole one.

/// Every window's best photograph — full resolution while a cover is showing it, reduced after.
@MainActor
public final class SurfaceCache {

    /// Linear scale a released photograph is stored at, per axis — a sixteenth of the pixels. On a 2×
    /// display that is one stored pixel per 2×2 points: a stand-in keeps its layout and loses its text,
    /// which is the band between unrecognisable and believable.
    public nonisolated static let ratio = 0.25

    /// How many bytes of released photographs to hold before the oldest are dropped. A backstop, not a
    /// working limit: at this ratio a full-screen 2× window is under 2 MB.
    public static let defaultBudget = 48 << 20

    /// One window's best photograph, and the three things about it that are not in its pixels.
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
        /// Released at capture resolution, its reduction in flight. Outside the budget until it lands, or
        /// stand-ins would be evicted to make room for pixels about to shrink sixteenfold.
        var isReducing = false
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
    /// Every window's corner as best read (`corner(of:)`), and the batch that read it. Outside `photos`, so
    /// nothing that drops a photograph drops the reading with it.
    private var corners: [WindowId: (corner: CornerReading, mint: Int)] = [:]

    /// Where a released photograph is scaled down — off the main actor in the daemon.
    private let reducer: Reducer

    /// Whether a photograph outlives the cover that took it. Off, the last cover to let one go forgets
    /// it instead of reducing it. Two features want it on and neither is the other's, so the daemon
    /// names the union of the two conditions in one place (`applyShellConfig`).
    public var keepsStills: Bool

    public init(budget: Int = SurfaceCache.defaultBudget, keepsStills: Bool = false,
                reducer: Reducer = .detached) {
        self.budget = budget
        self.keepsStills = keepsStills
        self.reducer = reducer
    }

    // The four operations

    /// Write the photograph batch `mint` just took of `id`, pinned to `monitor` when a live cover is
    /// entitled to paint it. The only writer, and it settles entitlement and pixels **separately**: the
    /// entitlement is unconditional, holding over whichever film turns out to be the best one on hand,
    /// and the pixels are taken only where they are newer *and* no worse than the ones already held.
    ///
    /// Answers whether the pixels were taken, which is what says a stand-in has been overtaken.
    @discardableResult
    public func record(_ surface: CapturedSurface, mintedAt mint: Int, for id: WindowId,
                       pinnedBy monitor: MonitorId?) -> Bool {
        if let corner = surface.corner, Self.outranks(corner, mint, corners[id]) {
            corners[id] = (corner, mint)
        }
        let held = photos[id]
        guard mint > held?.mint ?? .min else {
            // A slower batch, answering with a film that has been overtaken. Its entitlement is still
            // news: this cover may paint what is here, which is the better photograph of the two.
            if let monitor { pin(id, to: monitor) }
            return false
        }
        if !surface.isWhole, let held, held.surface.isWhole,
           Self.sameSize(held.surface.frame.size, surface.frame.size) {
            // Newer, and worse: a hole where the window hung off the display. The entitlement is news
            // for the reason above — what is held is the better photograph, and this cover may paint it.
            if let monitor { pin(id, to: monitor) }
            return false
        }
        var pins = held?.pins ?? []
        if let monitor { pins.insert(monitor) }
        if !pins.isEmpty {
            store(Photo(surface: surface, mint: mint, pins: pins), for: id)
            return true
        }
        // Nothing may paint it at capture resolution, so nothing holds it there (rule 1) — and one
        // too small to reduce is not stored at all: a copy that is neither affordable nor honest is
        // worth less than the miss it becomes.
        guard keepsStills, Self.reducedSize(of: surface.image) != nil else { return false }
        store(Photo(surface: surface, mint: mint, isReducing: true), for: id)
        reduce(id)
        return true
    }

    /// `monitor`'s cover may paint `id`'s photograph — what a stand-in match buys. It does not write:
    /// the photograph is whatever was last taken of the window, and raising a cover over one is not a
    /// film of it.
    public func pin(_ id: WindowId, to monitor: MonitorId) {
        guard var photo = photos[id] else { return }
        bytes -= Self.budgeted(photo)
        photo.pins.insert(monitor)
        photo.isReducing = false            // on screen at full size again; a reduction in flight is moot
        photos[id] = photo
    }

    /// `monitor`'s cover is over. The last cover to let a photograph go has it reduced — never removed,
    /// never twice — or forgets it where nothing keeps stills. The release is synchronous, since the next
    /// head batch reads this store a line later; the reduction lands when it lands (`land`).
    public func unpin(_ monitor: MonitorId) {
        for (id, held) in photos where held.pins.contains(monitor) {
            var photo = held
            photo.pins.remove(monitor)
            guard photo.pins.isEmpty else { photos[id] = photo; continue }
            guard keepsStills else { forget(id); continue }
            photo.isReducing = !photo.isReduced && Self.reducedSize(of: photo.surface.image) != nil
            photos[id] = photo
            bytes += Self.budgeted(photo)
            if photo.isReducing { reduce(id) }
        }
        evict()
    }

    // The reads

    /// The photograph of `id`, if one was taken at the size the window is at now (rule 2). Its `frame`
    /// carries the *old* origin, which is not a position: a cover places every layer from the core's own
    /// geometry in the transaction it raises in.
    public func surface(for id: WindowId, at size: Size) -> CapturedSurface? {
        guard let photo = photos[id], Self.sameSize(photo.surface.frame.size, size) else { return nil }
        return photo.surface
    }

    /// Two sizes `Tolerance.still` calls one. The stand-in match and the hole rule ask the same question
    /// of it, so they ask it in one place.
    private static func sameSize(_ a: Size, _ b: Size) -> Bool {
        a.isClose(to: b, within: Tolerance.still)
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

    /// `id`'s corner as best read, whatever became of the photograph it was read off: the newest reading at
    /// rest, else the newest of the window animating. `nil` for a window never read.
    public func corner(of id: WindowId) -> CornerReading? { corners[id]?.corner }

    /// Whether `corner`, read by batch `mint`, replaces `held`. At rest outranks animating whatever the
    /// batches, so a later opening still cannot undo it; alike, the newer batch wins — ordered by its own,
    /// because the photograph it was read off may be long gone.
    private static func outranks(_ corner: CornerReading, _ mint: Int,
                                 _ held: (corner: CornerReading, mint: Int)?) -> Bool {
        guard let held else { return true }
        guard corner.isAtRest == held.corner.isAtRest else { return corner.isAtRest }
        return mint > held.mint
    }

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
            bytes -= Self.budgeted(previous)
            order.removeAll { $0 == id }
        }
        photos[id] = photo
        order.append(id)
        bytes += Self.budgeted(photo)
        evict()
    }

    private func forget(_ id: WindowId) {
        guard let photo = photos.removeValue(forKey: id) else { return }
        bytes -= Self.budgeted(photo)
        order.removeAll { $0 == id }
    }

    /// Send `id`'s photograph to be reduced, naming the film it was made from.
    private func reduce(_ id: WindowId) {
        guard let photo = photos[id] else { return }
        let mint = photo.mint
        reducer.run(photo.surface) { [weak self] small in self?.land(small, for: id, mint: mint) }
    }

    /// A reduction is taken only by the film it was made from, and only while that is still released: a
    /// newer film, a cover pinning it again, or a forget each leave it nobody's. A reduction that failed
    /// leaves the photograph as it is, marked so it is never tried again.
    private func land(_ small: CapturedSurface?, for id: WindowId, mint: Int) {
        guard var photo = photos[id], photo.mint == mint, photo.isReducing else { return }
        photo.isReducing = false
        photo.isReduced = true
        if let small { photo.surface = small }
        photos[id] = photo
        bytes += Self.budgeted(photo)
        evict()
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

    /// One capture at cache resolution, or `nil` if the pixels could not be redrawn — a miss costs latency,
    /// never accuracy. The corner is carried, not re-read off pixels no longer at the scale it was read at,
    /// and alpha kept: `WindowAnimation.stretch` derives its drop shadow from it. Callable off the main actor.
    public nonisolated static func reduced(_ surface: CapturedSurface,
                                           by ratio: Double = SurfaceCache.ratio) -> CapturedSurface? {
        let image = surface.image
        guard let (width, height) = reducedSize(of: image, by: ratio) else { return nil }

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
        // `isWhole` is carried for the radius's reason: scaling a still down moves no hole into or out
        // of it, and re-measuring a quarter-size copy could only be a worse reading of the same fact.
        return CapturedSurface(image: reduced, frame: surface.frame, corner: surface.corner,
                               isWhole: surface.isWhole)
    }

    /// The pixel size `reduced` would produce, or `nil` for an image too small to shrink.
    private nonisolated static func reducedSize(of image: CGImage,
                                                by ratio: Double = SurfaceCache.ratio) -> (Int, Int)? {
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard width < image.width, height < image.height else { return nil }
        return (width, height)
    }

    private static func byteCount(_ surface: CapturedSurface) -> Int {
        surface.image.height * surface.image.bytesPerRow
    }

    /// What a photograph costs the budget: nothing while a cover shows it or its reduction is in flight.
    private static func budgeted(_ photo: Photo) -> Int {
        photo.pins.isEmpty && !photo.isReducing ? byteCount(photo.surface) : 0
    }
}

/// How a released photograph is scaled down: handed the full one, answering on the main actor.
public struct Reducer: Sendable {
    let run: @MainActor @Sendable (CapturedSurface,
                                   @escaping @MainActor @Sendable (CapturedSurface?) -> Void) -> Void

    /// Off the main actor. A 5K still's draw costs tens of milliseconds, and releases land at the end of
    /// every cross-fade — where the next keypress's head batch wants the main thread.
    public static let detached = Reducer { surface, done in
        Task.detached(priority: .utility) {
            let small = SurfaceCache.reduced(surface)
            await done(small)
        }
    }

    /// In the caller's turn: what a test of the outcome, rather than of its timing, wants.
    public static let inline = Reducer { surface, done in done(SurfaceCache.reduced(surface)) }
}
