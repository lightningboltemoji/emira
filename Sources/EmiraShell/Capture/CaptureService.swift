import CoreGraphics
import Foundation
import EmiraCore

// The capture plane: the pixels the cover is built from. ScreenCaptureKit itself is in
// `SCKCapturer.swift`; the policy here is four rules.
//
//  1. Every `capture` answers, exactly once, within a deadline. The core emits `beginTransition` on the
//     *last* `captureReady`, so a still that never arrives is a command that silently does nothing with
//     no cover raised and no hold timer to rescue it. Failure, timeout and unknown-window all answer.
//  2. No ack leaves a head batch before **every** base it needs has landed. A batch delivers its pieces
//     as they land, and an overlay's own fill is black, so a raise with a base missing blacks out that
//     display. One base per covered screen, because a base is a photograph of one screen — while a
//     window still is filmed once however many screens are covered, its own surface being
//     display-independent.
//  3. The store is written before the acks go out: the last `captureReady` re-enters the pump
//     synchronously and comes back out as `raiseCover`, which reads this store.
//  4. Stills live exactly as long as the cover — at capture resolution. A window image at 2× is several
//     megabytes, so what outlives one is the reduced copy `SurfaceCache` keeps, under `.immediate` only.
//
// `CoverMode` is the only policy here the core does not decide, and it changes one thing: whether a
// window whose kept still fits is ready *now*, its own capture following as a `captureRefreshed`, or
// only once that capture lands. The gate the core counts down is identical either way.

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

/// One thing a batch produced, handed over the moment it lands rather than with the rest of its batch.
///
/// Optional by absence in both directions: a window whose still failed simply never appears, and a base
/// that failed never does either. No errors, because there is no decision to make from one.
///
/// The base carries no display id, and does not need one: a `SurfaceCapturer` *is* one display's, so
/// which screen a base is of is a fact about who was asked rather than about the answer.
public enum CapturePiece: Sendable {
    /// The capturer's display *excluding* every requested window — the desktop the layers slide over.
    case base(CGImage)
    case window(WindowId, CapturedSurface)
}

/// The untestable half: ScreenCaptureKit behind one method.
///
/// Implementers must deliver each piece to `piece` as it arrives and call `done` exactly once, on the
/// main actor, however the batch turns out — including when the grant is missing and nothing can be
/// captured at all. Pieces stream because the window server *serializes* screenshots, so a batch's
/// stills arrive about 10 ms apart and a cover gated on the base need not wait for the last.
///
/// `includeBase` is `false` for a batch *growing* an existing cover: a second base taken mid-transition
/// would bake the first batch's windows, by then already teleported, into the desktop behind their own
/// sliding layers.
///
/// **`requests` is both instructions at once**: photograph these windows, and cut them out of the base.
/// The two can be one again now that a cover names its display — a batch goes to exactly one capturer,
/// the one whose screen the cover is over, so the windows it films and the hole its base needs are the
/// same list. (They had to be separate while one session covered every screen and only the first
/// capturer filmed.) A window straddling two displays is the case this does not serve: it is covered on
/// the display its workspace lives on, and its other half is left in the neighbouring desktop.
@MainActor
public protocol SurfaceCapturer: AnyObject {
    func capture(_ requests: [CaptureRequest], includeBase: Bool,
                 piece: @escaping @MainActor (CapturePiece) -> Void,
                 done: @escaping @MainActor () -> Void)
}

/// One window a transition needs pixels for, and the size the core records it at — which is what decides
/// whether a kept still may stand in for it (`Effect.capture`, `SurfaceCache`).
public struct CaptureTarget: Sendable, Equatable {
    public let id: WindowId
    public let size: Size

    public init(id: WindowId, size: Size) {
        self.id = id
        self.size = size
    }
}

/// Names one display's cover's worth of stills, so a cross-fade finishing *after* a newer transition
/// started capturing cannot free the newer one's pixels. A token rather than an `Int` because the only
/// way to hold one is to have been handed it by `closeCover(on:)`.
public struct CoverToken: Sendable, Equatable {
    let monitor: MonitorId
    let generation: Int
    init(_ monitor: MonitorId, _ generation: Int) {
        self.monitor = monitor
        self.generation = generation
    }
}

/// The reconstruction's source of pixels: ask for a batch, read what arrived, drop it when the cover
/// comes down. `CompositingExecutor` drives `capture`/`discard` and `Reconstruction` reads
/// `surface(for:)`/`base`; one object because those writes and reads are ordered against each other
/// (rule 3 above).
@MainActor
public protocol CaptureStore: AnyObject {
    /// Capture these windows for `monitor`'s cover — and, if that display has no cover session open,
    /// the desktop behind them — then ack each through `feedback` as `Event.captureReady`, exactly once
    /// and within a bounded time. A batch that finds that display's session already open is *growing*
    /// its cover and takes no new base.
    ///
    /// Under `CoverMode.immediate` a window a kept still fits is acked at once, its own capture arriving
    /// later as `Event.captureRefreshed` — still one `captureReady` per window.
    func capture(_ targets: [CaptureTarget], on monitor: MonitorId, feedback: EventSink)

    /// This cover's still for `window`, if one arrived. Not keyed by display: a window is filmed once
    /// and one still serves every cover, `SCContentFilter(desktopIndependentWindow:)` being
    /// display-independent already.
    func surface(for window: WindowId) -> CapturedSurface?

    /// This cover's desktop base for one display, if one arrived. Per display, because a base *is* a
    /// photograph of a screen — the one thing in the store that cannot be shared between covers.
    func base(of monitor: MonitorId) -> CGImage?

    /// `monitor`'s cover session is over: the next `capture` for it starts a fresh one and takes a
    /// fresh base. The stills stay alive — on screen for the whole cross-fade — until the token reaches
    /// `discard`.
    func closeCover(on monitor: MonitorId) -> CoverToken

    /// Release the stills the cover `token` names, minus any another live cover is still showing.
    /// Ignored if a newer cover on that display claimed them.
    func discard(_ token: CoverToken)
}

/// What one batch cost and yielded. Reported because the other instrument cannot see it:
/// frames-per-transition is counted from the raise, and everything measured here precedes it.
public struct CaptureReport: Sendable {
    /// How many windows the batch owed an ack for.
    public let windows: Int
    /// How many of them still have no still afterwards — holes in the cover.
    public let missing: Int
    /// How many windows a kept still was *installed* for — cache hits at request time, which is not the
    /// same as how many the cover was actually built from (`standing`).
    public let stoodIn: Int
    /// How many of those still had nothing better to show when the batch stopped owing acks — the layers
    /// the raise paints with kept pixels. Zero against a high `stoodIn` is a cover that came out exact
    /// because every stand-in was overtaken before the gate opened.
    public let standing: Int
    /// Wall-clock from the request to the moment the batch stopped owing acks — **the head latency**,
    /// i.e. what a keypress feels like before anything moves. `nil` if it never stopped owing them.
    public let gate: TimeInterval?
    /// Wall-clock from the request to the base landing, `nil` if it never did. The gate can be no
    /// earlier than this, and under `.immediate` it should be barely later.
    public let base: TimeInterval?
    /// Wall-clock from the request to the resolution: `SCShareableContent` plus the fan-out.
    public let elapsed: TimeInterval
    /// Whether the deadline resolved it rather than the capturer.
    public let timedOut: Bool
    /// The display whose cover this batch was for — two covers are two transitions, and a log line
    /// that cannot say which screen it is about describes neither.
    public let monitor: MonitorId
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
    /// batch costs ~10 ms for `SCShareableContent` plus ~10 ms per capture — linear, because the window
    /// server serializes them — so a four-window batch lands near 60 ms and ~22 windows would reach this
    /// bound. It can afford to be tight because overrunning degrades honestly: a head batch with no base
    /// answers `Event.coverUnavailable` and the user gets an instant placement instead of a black screen.
    public static let defaultDeadline: TimeInterval = 0.25

    private let registry: WindowRegistry
    /// One capturer per display, keyed by it. **A batch goes to exactly one of them** — the display
    /// whose cover it is for — which is what makes the still's scale the destination overlay's, the one
    /// thing §8 says a cross-display move must get right. A window's own surface is display-independent,
    /// so a window owed by two covers is filmed once per cover and the second film is what carries the
    /// second display's scale.
    private var capturers: [MonitorId: any SurfaceCapturer]
    /// Whether a display this was built for is still attached. **A departed display's capturer can
    /// produce no base at all**, and a head batch owing one abandons that cover — so without this an
    /// unplug would put every transition for the rest of the session on the `snap` path. The shell's
    /// set of capturers is fixed at launch; which of them still name a display is not.
    public var isAttached: @MainActor (MonitorId) -> Bool = { _ in true }
    private let scheduler: any DelayScheduler
    private let deadline: TimeInterval
    /// Where stills go to outlive their cover, and where `.immediate`'s stand-ins come from.
    private let cache: SurfaceCache

    /// When a cover may be raised. Read when a batch is *issued*, so a config reload landing mid-flight
    /// changes the next transition rather than the one in the air — the same rule `Reconstruction`
    /// applies to `WindowAnimation`.
    public var mode: CoverMode

    /// Whether a cover's stills are reduced and kept when it comes down. Two features want them and
    /// neither is the other's: `CoverMode.immediate` raises over them, and a preview guide drawing
    /// `stills` draws its tiles from them. A settable bit rather than a second read of `mode`, so the daemon can name
    /// the union of the two conditions in one place (`applyShellConfig`).
    ///
    /// Costs no captures either way — what it changes is whether a still is reduced on its way to being
    /// freed, or simply freed.
    public var keepsStills: Bool

    /// Called as each batch resolves. The daemon logs it; nothing decides on it.
    public var onBatchResolved: (@MainActor (CaptureReport) -> Void)?

    /// The live covers' stills, keyed by window. Written before the acks, released when the cover that
    /// owns them comes down — or, for a window two covers show, when the last of them does.
    private var surfaces: [WindowId: CapturedSurface] = [:]
    /// Which cover each still belongs to. A window owed by two sessions is filmed for each, so the
    /// answer is a set, and one cover's release must not free pixels the other is still showing.
    private var owners: [WindowId: Set<MonitorId>] = [:]
    /// One base per covered display. Absent means that display's overlay would raise onto its own black
    /// fill, which is why a head batch that ends with one missing abandons that cover instead.
    private var baseImages: [MonitorId: CGImage] = [:]
    /// Which of `surfaces` are a live cover's *own* captures, as against stand-ins it inherited. Only
    /// these are worth keeping: reducing an already-reduced still would degrade it once per transition
    /// it survives, until a window that is never re-filmed fades to nothing.
    private var freshlyCaptured: Set<WindowId> = []

    /// Which displays have a cover session open: whether the next batch for one *grows* its cover
    /// (merge, no new base) or *opens* one (clear its stills, take its base).
    private var openCovers: Set<MonitorId> = []
    /// Names each display's current cover session, bumped by every head batch for it.
    private var coverGeneration: [MonitorId: Int] = [:]

    /// A batch in flight: which windows still owe an ack, and where to send it.
    ///
    /// Keyed by generation because two can be live at once — a retarget arriving before the cover is up
    /// starts a second batch while the first is still out, and superseding the first would ack its
    /// windows with no pixels. Each batch owes its own acks and pays them itself.
    private struct Pending {
        /// Every window this batch owes a `captureReady`, in scope order.
        let windows: [WindowId]
        /// Those a kept still stands in for. They have pixels from the moment the batch is issued, so
        /// their own capture — if it lands at all — is a `captureRefreshed`, never a second ack.
        let stoodIn: Set<WindowId>
        let feedback: EventSink
        let startedAt: Date
        let isHead: Bool
        /// The display this batch's cover is over, and which generation of it. A batch that answers
        /// after its cover was abandoned still owes its acks, but its images belong to nothing and must
        /// not reach the store.
        let monitor: MonitorId
        let cover: Int

        /// Windows still owing their one `captureReady`.
        var owed: Set<WindowId>
        /// Windows that have pixels but may not say so yet — rule 2. Ordered, so the acks a release
        /// flushes go out in the order the pixels arrived.
        var held: [WindowId] = []
        /// The displays this batch still owes a base. Empty ⇒ a raise built on it would have a desktop
        /// under it on every covered screen. A batch that takes no base is growing a cover already
        /// standing on one, so it starts satisfied.
        var basesOwed: Set<MonitorId>
        /// Capturers that have yet to report themselves finished. The batch resolves when the last one
        /// does, or when the deadline fires — whichever comes first.
        var repliesOwed: Int

        /// When the *last* base arrived, and when the last ack went out — the two numbers that say
        /// whether `.immediate` did anything. Both relative to `startedAt`, both recorded once.
        var baseAt: TimeInterval?
        var gateAt: TimeInterval?
        /// Stand-ins whose own capture had not yet overtaken them at `gateAt`.
        var standingAtGate = 0
    }
    private var pending: [Int: Pending] = [:]
    /// Bumped by every batch, so the two racers — the capturer answering and the deadline firing — can
    /// each tell whether they are still the live one. The loser must do nothing at all.
    private var generation = 0

    public init(registry: WindowRegistry,
                capturers: [(monitor: MonitorId, capturer: any SurfaceCapturer)],
                scheduler: any DelayScheduler,
                cache: SurfaceCache = SurfaceCache(),
                mode: CoverMode = .exact,
                keepsStills: Bool = false,
                deadline: TimeInterval = CaptureService.defaultDeadline) {
        self.registry = registry
        self.capturers = Dictionary(capturers.map { ($0.monitor, $0.capturer) },
                                    uniquingKeysWith: { first, _ in first })
        self.scheduler = scheduler
        self.cache = cache
        self.mode = mode
        self.keepsStills = keepsStills
        self.deadline = deadline
    }

    /// One display's worth — the ordinary case, and what every test that is not about the routing wants.
    public convenience init(registry: WindowRegistry,
                            monitor: MonitorId = MonitorId(1),
                            capturer: any SurfaceCapturer,
                            scheduler: any DelayScheduler,
                            cache: SurfaceCache = SurfaceCache(),
                            mode: CoverMode = .exact,
                            keepsStills: Bool = false,
                            deadline: TimeInterval = CaptureService.defaultDeadline) {
        self.init(registry: registry, capturers: [(monitor, capturer)], scheduler: scheduler,
                  cache: cache, mode: mode, keepsStills: keepsStills, deadline: deadline)
    }

    /// Replace the capturers — hot-plug, and a display whose backing scale changed under it. A
    /// departing display's cover session is over, so its stills and its base go with it; the store is
    /// the only thing here keyed by display, and leaving a base behind would let the next cover on a
    /// re-plugged id raise onto a photograph of the desktop as it was two configurations ago.
    ///
    /// A batch still in flight for a retired display keeps owing its acks and pays them from `finish`
    /// (rule 1) — its images simply never reach the store, which is what `isCurrent` already decides.
    public func setCapturers(_ capturers: [(monitor: MonitorId, capturer: any SurfaceCapturer)]) {
        self.capturers = Dictionary(capturers.map { ($0.monitor, $0.capturer) },
                                    uniquingKeysWith: { first, _ in first })
        let live = Set(self.capturers.keys)
        for monitor in openCovers.subtracting(live) {
            openCovers.remove(monitor)
            coverGeneration[monitor, default: 0] &+= 1   // pixels still in flight belong to nothing
            clearStore(of: monitor)
        }
    }

    public func surface(for window: WindowId) -> CapturedSurface? { surfaces[window] }

    public func base(of monitor: MonitorId) -> CGImage? { baseImages[monitor] }

    public func closeCover(on monitor: MonitorId) -> CoverToken {
        openCovers.remove(monitor)
        return CoverToken(monitor, coverGeneration[monitor] ?? 0)
    }

    public func discard(_ token: CoverToken) {
        // A cross-fade takes 0.22 s and a new transition can open inside it; by then that display's
        // stills may already belong to the new one, and freeing them would blank the cover it is about
        // to raise.
        guard token.generation == coverGeneration[token.monitor] ?? 0 else { return }
        clearStore(of: token.monitor)
    }

    public func capture(_ targets: [CaptureTarget], on monitor: MonitorId, feedback: EventSink) {
        // A batch for a display with no cover session open is *opening* one: it owns that display's
        // base and starts its stills clean. One with a session open grows a raised cover and merges
        // into what is there.
        let isHead = !openCovers.contains(monitor)
        if isHead {
            coverGeneration[monitor, default: 0] &+= 1
            openCovers.insert(monitor)
            clearStore(of: monitor)
        }

        // Which windows a kept still can already answer for. Written into the store *before* any ack
        // goes out (rule 3) — and before the batch is even on the wire, since a synchronous capturer
        // could otherwise land a fresh still on top of a stand-in that had not been installed yet.
        var stoodIn: Set<WindowId> = []
        if mode == .immediate {
            for target in targets {
                guard let kept = cache.surface(for: target.id, at: target.size) else { continue }
                install(kept, for: target.id, on: monitor, fresh: false)
                stoodIn.insert(target.id)
            }
        }

        generation &+= 1
        let mine = generation
        let windows = targets.map(\.id)
        // Exactly one capturer: the display this cover is over, if it is still there to answer.
        let asked = isAttached(monitor) ? capturers[monitor] : nil
        pending[mine] = Pending(windows: windows, stoodIn: stoodIn, feedback: feedback,
                                startedAt: Date(), isHead: isHead, monitor: monitor,
                                cover: coverGeneration[monitor] ?? 0,
                                owed: Set(windows),
                                // Owed whether or not anyone was asked: a head batch with no capturer
                                // to answer it has no base, and a cover with no base is not a cover.
                                basesOwed: isHead ? [monitor] : [],
                                repliesOwed: asked == nil ? 0 : 1)

        // An id the registry doesn't know has no window number to ask about, but is still owed an ack —
        // dropped from the *request*, kept in the ack list. It reaches the cover as a missing layer,
        // which is truthful for the likely cause: destroyed between the reducer scoping it and here.
        // A stood-in window is still filmed: the stand-in buys the raise, not the transition.
        let requests = targets.compactMap { target in
            registry.record(target.id).map { CaptureRequest(id: target.id, number: $0.number) }
        }

        // The stand-ins have pixels already, so they are ready as soon as anything is — `ready` still
        // routes them through rule 2's hold, which is the whole of what `.immediate` waits for. Before
        // the batch goes on the wire, so that a capturer answering synchronously cannot deliver a
        // window's own still before the stand-in it replaces has been declared.
        for id in stoodIn { ready(generation: mine, id) }

        // One capturer, filming what its own base has to have a hole where: with a cover per display
        // those are the same list, so a second screen costs a transition nothing unless it is also
        // being covered.
        if let asked {
            asked.capture(requests, includeBase: isHead,
                          piece: { [weak self] piece in
                              self?.receive(generation: mine, from: monitor, piece: piece)
                          },
                          done: { [weak self] in self?.replied(generation: mine) })
        } else {
            // Nobody to ask — the display has left — is a batch that owes acks and can never be
            // answered by anyone, so it is resolved here rather than left to the deadline.
            finish(generation: mine, timedOut: false)
        }
        scheduler.schedule(after: deadline) { [weak self] in
            self?.finish(generation: mine, timedOut: true)
        }
    }

    /// One capturer has nothing further to deliver. The batch resolves when the last of them says so.
    private func replied(generation: Int) {
        guard var batch = pending[generation] else { return }
        batch.repliesOwed -= 1
        pending[generation] = batch
        guard batch.repliesOwed <= 0 else { return }
        finish(generation: generation, timedOut: false)
    }

    /// Take one piece of the batch `generation` names, from `monitor`'s capturer: store it, then say so.
    private func receive(generation: Int, from monitor: MonitorId, piece: CapturePiece) {
        guard let batch = pending[generation] else { return }   // already finished; nothing owes an ack

        // Whether this batch's cover still exists: a session can be abandoned, or a whole further
        // transition can start, while a slow batch is out, and its pixels would then be somebody else's
        // desktop. The acks are still owed; the images stop here.
        let isCurrent = batch.cover == coverGeneration[batch.monitor] ?? 0

        switch piece {
        case .base(let image):
            // Order is the contract (rule 3): releasing the hold below can ack the last window the core
            // is waiting on, which re-enters the pump synchronously and comes back out as `raiseCover`.
            if isCurrent { baseImages[monitor] = image }
            pending[generation]?.basesOwed.remove(monitor)
            // The base is the one the gate waits on, so the time is recorded when the set empties.
            if pending[generation]?.basesOwed.isEmpty == true {
                pending[generation]?.baseAt = Date().timeIntervalSince(batch.startedAt)
            }
            release(generation: generation)

        case .window(let id, let surface):
            if isCurrent { install(surface, for: id, on: batch.monitor, fresh: true) }
            guard batch.stoodIn.contains(id) else { return ready(generation: generation, id) }
            // A stand-in has spent its `captureReady`, so this asks for a repaint instead, which settles
            // no gate. Only once that ack has gone out — before it there is no layer, and the raise finds
            // these pixels in the store anyway — and only if they reached the store at all.
            guard isCurrent, pending[generation]?.owed.contains(id) == false else { return }
            batch.feedback(.captureRefreshed(id))
        }
    }

    /// This window has pixels: ack it, or hold the ack until the base lands (rule 2).
    ///
    /// Holding does not clear `owed` — `finish` pays from that set when a base never lands — so the hold
    /// list is what dedupes a piece delivered twice.
    private func ready(generation: Int, _ id: WindowId) {
        guard var batch = pending[generation], batch.owed.contains(id) else { return }
        guard batch.basesOwed.isEmpty else {
            if !batch.held.contains(id) { batch.held.append(id) }
            pending[generation] = batch
            return
        }
        batch.owed.remove(id)
        pending[generation] = batch
        noteGate(generation)
        batch.feedback(.captureReady(id))
    }

    /// Every base has landed: everything held on them may speak.
    private func release(generation: Int) {
        guard var batch = pending[generation], batch.basesOwed.isEmpty else { return }
        let held = batch.held
        batch.held.removeAll()
        batch.owed.subtract(held)
        pending[generation] = batch
        noteGate(generation)
        for id in held { batch.feedback(.captureReady(id)) }
    }

    /// The batch owes nothing further: record when, and how many stand-ins the cover will be built from.
    ///
    /// Measured before the acks go out: the last of them re-enters the pump synchronously and comes back
    /// out as the raise, so measuring after would time the raise itself.
    private func noteGate(_ generation: Int) {
        guard var batch = pending[generation], batch.gateAt == nil, batch.owed.isEmpty else { return }
        batch.gateAt = Date().timeIntervalSince(batch.startedAt)
        batch.standingAtGate = batch.stoodIn.subtracting(freshlyCaptured).count
        pending[generation] = batch
    }

    /// Close the batch `generation` names and pay whatever it still owes. Idempotent by generation,
    /// which is what makes "exactly once" true when the deadline and the capturer both fire.
    private func finish(generation: Int, timedOut: Bool) {
        guard let batch = pending.removeValue(forKey: generation) else { return }
        let isCurrent = batch.cover == coverGeneration[batch.monitor] ?? 0

        onBatchResolved?(CaptureReport(
            windows: batch.windows.count,
            missing: batch.windows.filter { surfaces[$0] == nil }.count,
            stoodIn: batch.stoodIn.count,
            standing: batch.standingAtGate,
            gate: batch.gateAt,
            base: batch.baseAt,
            elapsed: Date().timeIntervalSince(batch.startedAt),
            timedOut: timedOut,
            monitor: batch.monitor,
            isHead: batch.isHead))

        // A head batch with no base has nothing to build that display's cover from, and an overlay's own
        // fill is black — acking here would black out that screen for the whole transition. The core
        // abandons that session before anything has moved there, and snaps instead. The held acks die
        // with it, and the other display's cover is untouched.
        if batch.isHead, isCurrent, !batch.basesOwed.isEmpty {
            openCovers.remove(batch.monitor)    // no cover raised there; the next scroll starts fresh
            clearStore(of: batch.monitor)
            batch.feedback(.coverUnavailable(batch.monitor))
            return
        }

        // Whatever never arrived is acked anyway, in scope order — rule 1. Held acks are among them: the
        // base has landed by now, or this is not a head batch and never waited on one.
        for window in batch.windows where batch.owed.contains(window) {
            batch.feedback(.captureReady(window))
        }
    }

    /// Write one still into the store and record which cover it belongs to. A window two covers show is
    /// owned by both, so neither release alone can free it.
    private func install(_ surface: CapturedSurface, for id: WindowId, on monitor: MonitorId,
                         fresh: Bool) {
        surfaces[id] = surface
        owners[id, default: []].insert(monitor)
        if fresh { freshlyCaptured.insert(id) }
    }

    /// Drop one display's cover's pixels — and, on the way out, hand its own captures to the cache. The
    /// single point every still passes through on its way to being freed, which is why the hand-off is
    /// here and not in `discard`: a cover can also lose its stills to the *next* transition on that
    /// display claiming them.
    ///
    /// **A still another live cover is showing stays**, which is what keeps two displays independent:
    /// one screen's transition ending must not blank a layer on the other.
    private func clearStore(of monitor: MonitorId) {
        var released: [WindowId: CapturedSurface] = [:]
        for (id, holders) in owners where holders.contains(monitor) {
            var holders = holders
            holders.remove(monitor)
            guard holders.isEmpty else { owners[id] = holders; continue }
            owners[id] = nil
            if let surface = surfaces.removeValue(forKey: id) {
                if freshlyCaptured.remove(id) != nil { released[id] = surface }
            }
        }
        keep(released)
        baseImages[monitor] = nil
    }

    /// Drop every kept still — the desktop they were filmed on is gone. `SurfaceCache`'s rule 2 holds
    /// only while the geometry a size was computed against does, and a display change moves every working
    /// area at once. Live covers' stills stay: `Event.screensChanged` takes those transitions down itself.
    public func forgetKeptStills() {
        cache.removeAll()
    }

    /// Reduce these captures and keep them for a later `.immediate` cover to stand in with.
    ///
    /// Detached: the reduction is Core Graphics work proportional to the scope, and a cover comes down
    /// during the next transition's animation whenever a key is held.
    private func keep(_ captures: [WindowId: CapturedSurface]) {
        guard keepsStills, !captures.isEmpty else { return }
        let cache = self.cache
        Task.detached(priority: .utility) {
            let reduced = captures.compactMapValues { SurfaceCache.reduced($0) }
            guard !reduced.isEmpty else { return }
            await MainActor.run { cache.keep(reduced) }
        }
    }
}
