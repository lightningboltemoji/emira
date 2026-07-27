import CoreGraphics
import Foundation
import EmiraCore

// The capture plane: the pixels the cover is built from. ScreenCaptureKit itself is in
// `SCKCapturer.swift`; the policy here is four rules.
//
//  1. Every `capture` answers, exactly once, within a deadline. The core emits `beginTransition` on the
//     *last* `captureReady`, so a still that never arrives is a command that silently does nothing with
//     no cover raised and no hold timer to rescue it. Failure, timeout and unknown-window all answer.
//  2. A batch is atomic — per-window acks would let the core count down to a raise the base isn't ready
//     for, and the base is what makes the cover opaque.
//  3. The store is written before the acks go out: the last `captureReady` re-enters the pump
//     synchronously and comes back out as `raiseCover`, which reads this store.
//  4. Stills live exactly as long as the cover. A window image at 2× is several megabytes.

/// One window's captured surface, and the frame it was taken from.
///
/// The frame travels *with* the image because the core only knows where the window was supposed to be,
/// while the capture knows where it actually was. Core (top-left, global) space — no flip here.
public struct CapturedSurface: Sendable {
    /// Captured at native backing resolution.
    public let image: CGImage
    /// Where the window was when it was captured, in core coordinates.
    public let frame: Rect
    /// The corner radius baked into `image`, in points — `nil` when the pixels couldn't say. Needed only
    /// by `WindowAnimation.crop`, which paints a window's extent rather than its pixels.
    public let cornerRadius: Double?

    public init(image: CGImage, frame: Rect, cornerRadius: Double? = nil) {
        self.image = image
        self.frame = frame
        self.cornerRadius = cornerRadius
    }

    /// Read a window's corner radius *out of its own capture*, in points. No public API reports another
    /// window's radius and a constant would be wrong on the next macOS, but a window capture is
    /// transparent outside its rounded corners, so the shape is already in the pixels.
    ///
    /// Measures the corner's *area*, not an edge walk, and that is the whole trick: the arc is tangent to
    /// the left edge and leaves it quadratically, so scanning a column for the first opaque pixel answers
    /// about `r − √r` (28% short at r = 12). A quarter-disc leaves `r²(1 − π/4)` of its bounding square
    /// uncovered and antialiasing conserves coverage — a boundary pixel's alpha *is* its covered fraction
    /// — so the alpha deficit inverts straight to `r` whatever the rasterizer did.
    ///
    /// A square-cornered window answers 0; `nil` means the pixels couldn't say and the caller should
    /// supply its own fallback.
    public static func measuredCornerRadius(of image: CGImage, scale: CGFloat) -> Double? {
        guard scale > 0, image.width > 0, image.height > 0 else { return nil }
        // Comfortably past any plausible window corner, so a wedge filling much of the block is
        // evidence we measured something other than a corner.
        let probe = min(96 * Int(scale.rounded()), min(image.width, image.height))
        guard probe > 0 else { return nil }

        // `byteOrder32Big` with `premultipliedFirst` pins the layout to A,R,G,B in memory, so byte 0 of
        // each pixel is unambiguously the alpha. `CGBitmapContext` has no legal alpha-only format.
        let stride = probe * 4
        guard let context = CGContext(
            data: nil, width: probe, height: probe, bitsPerComponent: 8, bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }

        // Core Graphics draws from a bottom-left origin into a top-down buffer, so aligning the image's
        // *top* with the block's top means placing its origin `probe − height` below zero. Backwards
        // measures the bottom-left corner instead: plausible, and wrong.
        context.draw(image, in: CGRect(x: 0, y: CGFloat(probe - image.height),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let data = context.data else { return nil }

        let bytes = data.bindMemory(to: UInt8.self, capacity: probe * stride)
        var uncovered = 0.0
        for row in 0..<probe {
            for column in 0..<probe {
                uncovered += Double(255 - bytes[row * stride + column * 4])
            }
        }
        uncovered /= 255

        // `r²(1 − π/4)` inverted. The bound rejects a mostly-transparent block, which is not a rounded
        // corner: a capture with no alpha information, or a probe that wandered off the window.
        let radius = (uncovered / (1 - Double.pi / 4)).squareRoot()
        guard radius <= Double(probe) / 2 else { return nil }
        return radius / Double(scale)
    }
}

/// One window to capture: the core's id and the public window number the capturer keys on. Translated
/// here so nothing below this file knows what a `WindowId` is.
public struct CaptureRequest: Sendable {
    public let id: WindowId
    public let number: CGWindowID

    public init(id: WindowId, number: CGWindowID) {
        self.id = id
        self.number = number
    }
}

/// What one capture batch yielded. Optional-by-absence: a window whose still failed is missing from
/// `surfaces`, a base that failed is `nil`. No errors, because there is no decision to make from one.
public struct CaptureBatch: Sendable {
    public let surfaces: [WindowId: CapturedSurface]
    /// The display *excluding* every requested window — the desktop the layers slide over.
    public let base: CGImage?

    public init(surfaces: [WindowId: CapturedSurface], base: CGImage?) {
        self.surfaces = surfaces
        self.base = base
    }
}

/// The untestable half: ScreenCaptureKit behind one method.
///
/// Implementers must call `completion` exactly once, on the main actor, however the batch turns out —
/// including when the grant is missing and nothing can be captured at all.
///
/// `includeBase` is `false` for a batch *growing* an existing cover: a second base taken mid-transition
/// would bake the first batch's windows, by then already teleported, into the desktop behind their own
/// sliding layers.
@MainActor
public protocol SurfaceCapturer: AnyObject {
    func capture(_ requests: [CaptureRequest], includeBase: Bool,
                 then completion: @escaping @MainActor (CaptureBatch) -> Void)
}

/// Names one cover's worth of stills, so a cross-fade finishing *after* a newer transition started
/// capturing cannot free the newer one's pixels. A token rather than an `Int` because the only way to
/// hold one is to have been handed it by `closeCover()`.
public struct CoverToken: Sendable, Equatable {
    let generation: Int
    init(_ generation: Int) { self.generation = generation }
}

/// The reconstruction's source of pixels: ask for a batch, read what arrived, drop it when the cover
/// comes down. `CompositingExecutor` drives `capture`/`discard` and `Reconstruction` reads
/// `surface(for:)`/`base`; one object because those writes and reads are ordered against each other
/// (rule 3 above).
@MainActor
public protocol CaptureStore: AnyObject {
    /// Capture these windows — and, if no cover session is open, the desktop behind them — then ack each
    /// window through `feedback` as `Event.captureReady`, exactly once and within a bounded time. A batch
    /// that finds a session already open is *growing* a cover and takes no new base.
    func capture(_ windows: [WindowId], feedback: EventSink)

    /// This cover's still for `window`, if one arrived.
    func surface(for window: WindowId) -> CapturedSurface?

    /// This cover's desktop base, if one arrived.
    var base: CGImage? { get }

    /// The cover session is over: the next `capture` starts a fresh one and takes a fresh base. The
    /// stills stay alive — on screen for the whole cross-fade — until the token reaches `discard`.
    func closeCover() -> CoverToken

    /// Release the stills of the cover `token` named. Ignored if a newer cover claimed the store.
    func discard(_ token: CoverToken)
}

/// What one batch cost and yielded. Reported because the other instrument cannot see it:
/// frames-per-transition is counted from the raise, and everything measured here precedes it.
public struct CaptureReport: Sendable {
    /// How many windows the batch owed an ack for.
    public let windows: Int
    /// How many of them still have no still afterwards — holes in the cover.
    public let missing: Int
    /// Wall-clock from the request to the resolution: `SCShareableContent` plus the fan-out.
    public let elapsed: TimeInterval
    /// Whether the deadline resolved it rather than the capturer.
    public let timedOut: Bool
    /// Whether this batch opened the cover (and so took the base), or grew one already raised.
    public let isHead: Bool
}

/// The capture plane's policy: batch, bound, ack, cache.
@MainActor
public final class CaptureService: CaptureStore {

    /// How long a batch may take before we proceed without it.
    ///
    /// A user-latency budget, not a safety margin: this wait sits at the head of the transition, before
    /// anything has moved or been covered, so every millisecond looks like a keypress doing nothing. A
    /// four-window batch measures 104–140 ms end to end, so 250 ms is ~1.8× the observed worst case. It
    /// can afford to be tight because overrunning degrades honestly — a head batch with no base answers
    /// `Event.coverUnavailable` and the user gets an instant placement instead of a black screen.
    public static let defaultDeadline: TimeInterval = 0.25

    private let registry: WindowRegistry
    private let capturer: any SurfaceCapturer
    private let scheduler: any DelayScheduler
    private let deadline: TimeInterval

    /// Called as each batch resolves. The daemon logs it; nothing decides on it.
    public var onBatchResolved: (@MainActor (CaptureReport) -> Void)?

    /// This cover's stills. Written before the acks, cleared when a new cover claims the store or the old
    /// one's cross-fade hands its token back.
    private var surfaces: [WindowId: CapturedSurface] = [:]
    private var baseImage: CGImage?

    /// Whether a cover session is open: whether the next batch *grows* a cover (merge, no new base) or
    /// *opens* one (clear the store, take a base).
    private var coverIsOpen = false
    /// Names the current cover session, bumped by every head batch.
    private var coverGeneration = 0

    /// A batch in flight: which windows still owe an ack, and where to send it.
    ///
    /// Keyed by generation because two can be live at once — a retarget arriving before the cover is up
    /// starts a second batch while the first is still out, and superseding the first would ack its
    /// windows with no pixels. Each batch owes its own acks and pays them itself.
    private struct Pending {
        let windows: [WindowId]
        let feedback: EventSink
        let startedAt: Date
        let isHead: Bool
        /// The cover this batch was captured for. A batch that answers after its cover was abandoned
        /// still owes its acks, but its images belong to nothing and must not reach the store.
        let cover: Int
    }
    private var pending: [Int: Pending] = [:]
    /// Bumped by every batch, so the two racers — the capturer answering and the deadline firing — can
    /// each tell whether they are still the live one. The loser must do nothing at all.
    private var generation = 0

    public init(registry: WindowRegistry,
                capturer: any SurfaceCapturer,
                scheduler: any DelayScheduler,
                deadline: TimeInterval = CaptureService.defaultDeadline) {
        self.registry = registry
        self.capturer = capturer
        self.scheduler = scheduler
        self.deadline = deadline
    }

    // MARK: - CaptureStore

    public func surface(for window: WindowId) -> CapturedSurface? { surfaces[window] }

    public var base: CGImage? { baseImage }

    public func closeCover() -> CoverToken {
        coverIsOpen = false
        return CoverToken(coverGeneration)
    }

    public func discard(_ token: CoverToken) {
        // A cross-fade takes 0.22 s and a new transition can open inside it; by then the store may
        // already belong to that transition, and freeing it would blank the cover it is about to raise.
        guard token.generation == coverGeneration else { return }
        clearStore()
    }

    public func capture(_ windows: [WindowId], feedback: EventSink) {
        // A batch with no cover session open is *opening* one: it owns the base and starts the store
        // clean. One with a session open grows a raised cover and merges into what is there.
        let isHead = !coverIsOpen
        if isHead {
            coverGeneration &+= 1
            coverIsOpen = true
            clearStore()
        }

        generation &+= 1
        let mine = generation
        pending[mine] = Pending(windows: windows, feedback: feedback, startedAt: Date(),
                                isHead: isHead, cover: coverGeneration)

        // An id the registry doesn't know has no window number to ask about, but is still owed an ack —
        // dropped from the *request*, kept in the ack list. It reaches the cover as a missing layer,
        // which is truthful for the likely cause: destroyed between the reducer scoping it and here.
        let requests = windows.compactMap { id in
            registry.record(id).map { CaptureRequest(id: id, number: $0.number) }
        }

        capturer.capture(requests, includeBase: isHead) { [weak self] batch in
            self?.resolve(generation: mine, batch: batch)
        }
        scheduler.schedule(after: deadline) { [weak self] in
            self?.resolve(generation: mine, batch: nil)
        }
    }

    // MARK: - Resolution

    /// Finish the batch `generation` names: store whatever arrived, then ack every window it owes.
    /// Idempotent by generation, which is what makes "exactly once" true when the deadline and the
    /// capturer both fire. `batch == nil` is the deadline: ack with whatever the store already holds.
    private func resolve(generation: Int, batch: CaptureBatch?) {
        guard let owed = pending.removeValue(forKey: generation) else { return }

        // Whether this batch's cover still exists: a session can be abandoned, or a whole further
        // transition can start, while a slow batch is out, and its stills would then be somebody else's
        // desktop. The acks are still owed; the images stop here.
        let isCurrent = owed.cover == coverGeneration

        // Order is the contract (rule 3): the last ack below re-enters the pump synchronously and comes
        // back out as `raiseCover`, which reads exactly these two properties. Merged, not replaced — a
        // growing cover keeps the stills the raise was built from.
        if let batch, isCurrent {
            surfaces.merge(batch.surfaces) { _, new in new }
            if let base = batch.base { baseImage = base }
        }

        onBatchResolved?(CaptureReport(
            windows: owed.windows.count,
            missing: owed.windows.filter { surfaces[$0] == nil }.count,
            elapsed: Date().timeIntervalSince(owed.startedAt),
            timedOut: batch == nil,
            isHead: owed.isHead))

        // A head batch with no base has nothing to build a cover from, and the overlay's own fill is
        // black — acking here would black out the display for the whole transition. The core abandons
        // the session before anything has moved, and snaps instead.
        if owed.isHead, isCurrent, baseImage == nil {
            coverIsOpen = false             // no cover will be raised; the next scroll starts fresh
            clearStore()
            owed.feedback(.coverUnavailable)
            return
        }

        for window in owed.windows {
            owed.feedback(.captureReady(window))
        }
    }

    private func clearStore() {
        surfaces.removeAll()
        baseImage = nil
    }
}
