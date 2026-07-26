import CoreGraphics
import Foundation
import EmiraCore

// The capture plane — the third machinery `Effect` spans, and the one that finally puts *pixels* in the
// cover (PRINCIPLES.md §4b step 1, IMPLEMENTATION.md §5 `Capture/CaptureService.swift`). Through M3 this
// was a lie told in one line: `AXExecutor` acked `Effect.capture` on the spot, because the
// reconstruction was built from coloured rectangles and there was no still to wait for. Here it becomes
// real, and with it the whole of §9's Risk B — *fidelity* — moves from the spikes into the product.
//
// **What this file decides** (everything below it is ScreenCaptureKit, `SCKCapturer.swift`):
//
//  1. **Every `capture` answers, exactly once, within a deadline.** This is the load-bearing rule and
//     it exists because of how the core waits: `beginTransition` is emitted on the *last*
//     `captureReady`, and the real windows only teleport behind a raised cover. So a still that never
//     arrives is not a degraded transition — it is a command that **silently does nothing**, with the
//     hold timer unarmed (it starts at the raise) and no cover to time out. That failure mode was
//     invisible while the ack was synchronous, and it is the first thing this file has to make
//     impossible. A capture that fails, times out, or names a window the registry has never heard of
//     still answers; it simply answers with no image.
//  2. **A batch is atomic.** The stills and the base are requested together and acked together, rather
//     than each window acking as it lands. Per-window acks would let the core count *down* to a raise
//     the base isn't ready for — and the base is the layer that makes the cover opaque, so raising
//     without it exposes the real desktop at the exact instant the reals start teleporting, which is
//     the one thing §4b exists to prevent. The core gains nothing from the finer grain either: it acts
//     only on the last ack.
//  3. **The store is written before the acks go out.** The last `captureReady` re-enters the pump
//     *synchronously* and comes straight back out as `beginTransition` → `raiseCover`, which reads
//     this store. Ack first and the cover raises over an empty cache — every layer blank, on the frame
//     where fidelity matters most.
//  4. **Stills live exactly as long as the cover.** A window image at 2× is several megabytes and a
//     scoped strip holds a handful; `discard()` on cross-fade keeps the resting daemon's memory flat
//     (the M3 measurement worth not regressing). It also means a stale still can never be shown: the
//     only images in the store are the ones this transition captured.
//
// **Why the deadline is short.** It is not a safety net that should ever fire — a still takes single-
// digit milliseconds — it is the head of the transition, and the user is already waiting on it. A
// capture slow enough to hit the deadline has already cost more than the artifact of proceeding
// without it. See `CaptureService.deadline`.

/// One window's captured surface, and the frame it was taken from.
///
/// The frame travels *with* the image because it is the only honest source for where the layer starts:
/// the core knows where the window is supposed to be, the capture knows where it actually was when the
/// shutter opened, and a cover raised at the second one is pixel-identical while a cover raised at the
/// first one is merely nearly right. It is core (top-left, global) space — the same space
/// `CGWindowListCopyWindowInfo` bounds are in — so no flip happens here (`ScreenGeometry` does that,
/// once, at the overlay).
public struct CapturedSurface: Sendable {
    /// The window's surface, captured at native backing resolution.
    public let image: CGImage
    /// Where the window was when it was captured, in core coordinates.
    public let frame: Rect

    public init(image: CGImage, frame: Rect) {
        self.image = image
        self.frame = frame
    }
}

/// One window to capture: the core's id, and the public window number the capturer keys on. The
/// translation between them is `WindowRegistry`'s, done once here so nothing below this file knows what
/// a `WindowId` is.
public struct CaptureRequest: Sendable {
    public let id: WindowId
    public let number: CGWindowID

    public init(id: WindowId, number: CGWindowID) {
        self.id = id
        self.number = number
    }
}

/// What one capture batch yielded. Both halves are optional-by-absence: a window whose still failed is
/// simply missing from `surfaces`, and a base that failed is `nil`. Nothing here reports errors,
/// because there is no decision to make from one — the policy above is the same either way.
public struct CaptureBatch: Sendable {
    /// The stills that arrived, keyed by window.
    public let surfaces: [WindowId: CapturedSurface]
    /// The display *excluding* every requested window — the desktop the layers slide over.
    public let base: CGImage?

    public init(surfaces: [WindowId: CapturedSurface], base: CGImage?) {
        self.surfaces = surfaces
        self.base = base
    }
}

/// The untestable half: ScreenCaptureKit. Same seam as `WindowSource` and `FrameClock` — the framework
/// call sits behind a protocol so the *policy* above it (batching, the deadline, the ack, the cache
/// lifetime) stays headlessly testable, and the part that needs a window server and a TCC grant is one
/// method wide.
///
/// **Contract for implementers:** `completion` is called **exactly once**, on the main actor, however
/// the batch turns out — including when the grant is missing and nothing can be captured at all.
///
/// `includeBase` is `false` for a batch that is *growing* an existing cover. The base is the display
/// captured excluding the requested windows, so a second one taken mid-transition would bake the
/// *first* batch's windows — by then already teleported to their end frames — into the desktop behind
/// their own sliding layers. One base per cover, taken by the batch that raises it.
@MainActor
public protocol SurfaceCapturer: AnyObject {
    func capture(_ requests: [CaptureRequest], includeBase: Bool,
                 then completion: @escaping @MainActor (CaptureBatch) -> Void)
}

/// Names one cover's worth of stills, so a cross-fade that finishes *after* a newer transition has
/// already started capturing cannot free the newer one's pixels.
///
/// The same generation device `Overlay` uses for its raise/fade pair and `CaptureService` uses for its
/// batches, and for the same reason: on macOS the loser of a race must do **nothing**, not the same
/// thing twice. It is a token rather than a raw `Int` because the only correct value is the one
/// `closeCover()` handed out.
public struct CoverToken: Sendable, Equatable {
    /// Deliberately not `public`: outside the shell the only way to hold a token is to have been given
    /// one by `closeCover()`, which is the whole guarantee.
    let generation: Int
    init(_ generation: Int) { self.generation = generation }
}

/// The reconstruction's source of pixels, as narrowly as the compositor needs it: ask for a batch, read
/// what arrived, drop it when the cover comes down.
///
/// Two collaborators hold one of these and they want different halves — `CompositingExecutor` drives
/// `capture`/`discard`, `Reconstruction` reads `surface(for:)`/`base` — but they are the same object and
/// splitting the protocol in two would only obscure that the writes and the reads are ordered against
/// each other (decision 3 in the file header).
@MainActor
public protocol CaptureStore: AnyObject {
    /// Capture these windows — and, if no cover session is open, the desktop behind them — then ack
    /// **each** window through `feedback` as `Event.captureReady`, exactly once and within a bounded
    /// time. A batch that finds a session already open is *growing* a cover and takes no new base.
    func capture(_ windows: [WindowId], feedback: EventSink)

    /// This cover's still for `window`, if one arrived.
    func surface(for window: WindowId) -> CapturedSurface?

    /// This cover's desktop base, if one arrived.
    var base: CGImage? { get }

    /// The cover session is over (`Effect.endTransition`): the next `capture` starts a fresh one and
    /// takes a fresh base. The stills stay alive — they are on screen for the whole cross-fade — until
    /// the returned token is handed to `discard`.
    func closeCover() -> CoverToken

    /// Release the stills of the cover `token` named — the cross-fade is down and they can never be
    /// shown again. Ignored if a newer cover has since claimed the store.
    func discard(_ token: CoverToken)
}

/// What one batch cost and yielded — the capture plane's permanent read-out.
///
/// It exists because the *other* instrument cannot see this. Frames-per-transition
/// (`CompositingExecutor.onCoverDismissed`) is counted from the **raise**, and everything measured
/// here happens before it: a scroll that reads as 605 ms to that counter was ~715 ms to the user
/// (`PRINCIPLES.md` §10, M4 part 1, measured with a throwaway probe). A latency nobody can see is a
/// latency nobody tunes, so this one is reported for good.
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
    /// 250 ms, and the number is a *user-latency* budget rather than a safety margin: this wait sits at
    /// the head of the transition, before anything has moved or even been covered, so every millisecond
    /// of it is a millisecond the user's keypress appears to have done nothing.
    ///
    /// **Chosen against evidence as of M4 part 2.** In the product a four-window batch measures
    /// 104–140 ms end to end (~30 ms of `SCShareableContent` plus the concurrent stills), so 250 ms is
    /// about 1.8× the observed worst case — tight, deliberately. It can afford to be tight now that
    /// overrunning it degrades honestly: a head batch that resolves with no base answers
    /// `Event.coverUnavailable`, and the user gets an instant, correct placement (§4a) instead of
    /// another quarter-second of nothing followed by an animation. Before that, the same overrun
    /// raised an empty cover — a black screen.
    public static let defaultDeadline: TimeInterval = 0.25

    private let registry: WindowRegistry
    private let capturer: any SurfaceCapturer
    private let scheduler: any DelayScheduler
    private let deadline: TimeInterval

    /// Called as each batch resolves. The daemon logs it; nothing decides on it.
    public var onBatchResolved: (@MainActor (CaptureReport) -> Void)?

    /// This cover's stills. Written before the acks, cleared when a new cover claims the store or when
    /// the old one's cross-fade hands its token back.
    private var surfaces: [WindowId: CapturedSurface] = [:]
    private var baseImage: CGImage?

    /// Whether a cover session is open — i.e. whether the next batch is *growing* a cover (merge into
    /// the store, no new base) or *opening* one (clear the store, take a base). Closed by
    /// `closeCover()` at `endTransition`, and by a `coverUnavailable` that means no cover will exist.
    private var coverIsOpen = false
    /// Names the current cover session. Bumped by every head batch, so a cross-fade completing after a
    /// newer transition has already captured cannot free the newer stills.
    private var coverGeneration = 0

    /// A batch in flight: which windows still owe an ack, and where to send it.
    ///
    /// Keyed by generation rather than held one-at-a-time, because **two can be live at once**: a
    /// retarget that arrives before the cover is up adds windows to the scope and starts a second batch
    /// while the first is still out. Superseding the first (what this did through M4 part 1) would ack
    /// its windows with no pixels and raise the cover over the newcomers alone. Each batch owes its own
    /// acks and pays them itself.
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
    /// Bumped by every batch, so the two racers for one — the capturer answering and the deadline
    /// firing — can each tell whether they are still the live one. The same device `Overlay` uses for
    /// the cross-fade, and for the same reason: the loser must do nothing at all, not "the same thing
    /// twice".
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
        // A cross-fade takes 0.22 s and a new transition can open inside it; by the time this fires the
        // store may already belong to that transition. Freeing it then would blank the cover it is
        // about to raise — which is why the token exists and why this is a guard, not an assert.
        guard token.generation == coverGeneration else { return }
        clearStore()
    }

    public func capture(_ windows: [WindowId], feedback: EventSink) {
        // A batch with no cover session open is *opening* one: it owns the base, and the store is its
        // to start clean. One with a session open is growing a raised (or about-to-be-raised) cover and
        // merges into what is already there.
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

        // An id the registry doesn't know cannot be captured (there is no window number to ask about),
        // but it is still owed an ack — so it is dropped from the *request* and kept in the batch's
        // ack list. It reaches the cover as a missing layer, which for the overwhelmingly likely cause
        // — the window was destroyed between the reducer scoping it and this call — is the truthful
        // picture.
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
    ///
    /// Idempotent by generation, which is what makes "exactly once" true in the face of the deadline and
    /// the capturer both firing. `batch == nil` is the deadline: ack with whatever the store already
    /// holds — for a head batch, nothing.
    private func resolve(generation: Int, batch: CaptureBatch?) {
        guard let owed = pending.removeValue(forKey: generation) else { return }

        // Whether this batch's cover still exists. It may not: an abandoned session (`coverUnavailable`)
        // or a whole further transition can happen while a slow batch is out, and its stills would then
        // be somebody else's desktop. The acks are still owed — they reduce to no-ops in a core that has
        // moved on — but the images stop here.
        let isCurrent = owed.cover == coverGeneration

        // Order is the contract (decision 3): the last ack below re-enters the pump synchronously and
        // comes back out as `raiseCover` (or `extendCover`), which reads exactly these two properties.
        // Merged, not replaced — a growing cover keeps the stills the raise was built from.
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

        // A head batch with no base has nothing to build a cover out of, and the overlay's own fill is
        // black — so acking here would black out the display for the length of the transition. Say so
        // instead: the core abandons the session before anything has moved and snaps (§4a).
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
