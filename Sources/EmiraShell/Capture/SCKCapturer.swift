import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import EmiraCore

// The `SurfaceCapturer` that talks to ScreenCaptureKit.
//
// Two filters, and the difference between them is the whole trick:
//
//  · `SCContentFilter(desktopIndependentWindow:)` captures a window's *own surface*, at full size,
//    on screen or not, occluded or not — which is what makes a parked column, sitting at its 1 px
//    sliver, capturable at all. A screen-region capture could never do this.
//  · `SCContentFilter(display:excludingWindows:)` captures the display *minus* the windows we are about
//    to animate. The base's holes and the cover's stand-ins are one set: a window excluded that nothing
//    draws appears twice, once frozen and once sliding, and a scoped window the content read never
//    named appears once, frozen, while the strip travels around it.
//
// A window still comes back at the resolution its window is drawn at, whatever display filmed it, and holds
// that window and the children inside its frame — never its parent (`surfaceShot`).
//
// The base excludes our own overlay too: it is a real window kept ordered-in at `alpha 0`, and capturing
// the base through it would be a feedback loop. One `processID` comparison closes that.
//
// And it excludes **everything that composites above the cover** — the menu bar, the Dock, a notification
// banner. Those draw over the cover whatever it holds, so a copy of them inside it can only double with
// the live one. Dropping them is what lets the cover be the whole display (`Overlay`) rather than stop at
// the struts, which is what lets a stand-in's shadow reach past the working area the way a real window's
// does. `SCWindow.windowLayer` is the same number as `NSWindow.level`, so `Overlay.level` is the cut.
//
// And it excludes the windows management has just let go of. AX destroys a window's element before the
// window server has finished fading it out, and the close that let it go is very often the edit opening
// this cover — so a base photographed in between would carry the window frozen under the layers
// closing ranks over it. Those numbers arrive as `BaseRequest.departed`: a hole, and nothing to film.
// So do the parked windows a tarp is drawing over (`BaseRequest.concealed`), or a cover would show the
// nubs the desktop around it hides.
//
// **The batch is taken one capture at a time, and that is the fast path.** The window server serializes
// screenshot requests, so overlapping them hides nothing — and worse, inflates each one: ~25 ms taken
// alone against ~41 ms with anything else in flight, which is 1.55–1.90× on the batch and grows under
// CPU load. Two in flight pays that in full, so there is no concurrency width to tune, only overlap to
// avoid. **The scope size is most of the latency** — ~50 ms a window on a 5K display, for a 2500×2750 px
// still, less for a smaller one — so the order a batch is filmed in decides what the gate waits behind.
//
// **A window kept out of capture is not filmed**: ScreenCaptureKit answers for it with a clear image, and a
// clear stand-in is a window gone. The window server says which these are, once per batch, and each is
// drawn as a card instead (`WindowCard`) — on the main actor, where its app's icon and appearance are.
//
// Pieces are handed back as they land rather than as a batch, and in request order — which is the
// caller's policy, not ScreenCaptureKit's enumeration order: a cover gated on the base alone
// (`CoverMode.immediate`) waits for one capture rather than all of them, and the extend gate acks per
// window. The base is captured before any window because it is the gate — no layer can be raised until
// it lands.
//
// **A base cuts every batch asked for in its turn** (`baseCuts`). A scan adopting a desktop is a window
// per event and a batch per window, all before the cover is up, and a base cut only for the first batch
// carries every other window frozen under its own sliding layer.
//
// None of ScreenCaptureKit's descriptor types are `Sendable`, so everything derived from one content
// fetch shares an isolation region. Hence free functions at file scope (isolation propagates into nested
// types) and `nonisolated(unsafe)` on the base filter — narrow and true, since it is built at the send
// site, never stored or mutated. The window filters need none: nothing reaches for them off this task.

/// Captures window surfaces and the desktop beneath them via ScreenCaptureKit.
@MainActor
public final class SCKCapturer: SurfaceCapturer {

    /// The display the base is captured from — the one the overlay covers and the strip is laid out on.
    private let displayId: CGDirectDisplayID
    /// The display's backing scale, so the base is captured at native pixel resolution. A 1× base under a
    /// 2× cover is soft. Window stills need no scale: each comes back at the one its window is drawn at.
    private let scale: CGFloat

    /// One batch as it was asked for, waiting for the end of the turn.
    private struct Order {
        let requests: [CaptureRequest]
        let base: BaseRequest?
        let piece: @MainActor (CapturePiece) -> Void
        let done: @MainActor () -> Void
    }

    /// The batches asked for this turn. Non-empty exactly while a flush is scheduled.
    private var queued: [Order] = []

    /// Windows whose children were once what kept a still from being their frame (`SurfaceStill.needsAlone`),
    /// filmed alone from then on, so the retake is paid once rather than in every cover. Never pruned: a
    /// number reused by another window costs that window its sheets, never a wrong still.
    private var alone: Set<CGWindowID> = []

    public init(displayId: CGDirectDisplayID, scale: CGFloat) {
        self.displayId = displayId
        self.scale = scale
    }

    public func capture(_ requests: [CaptureRequest], base: BaseRequest?,
                        piece: @escaping @MainActor (CapturePiece) -> Void,
                        done: @escaping @MainActor () -> Void) {
        // A grab is a task, which starts once this turn is over — so letting the rest of the turn's batches
        // say what the base has to cut costs nothing.
        if queued.isEmpty { Task { self.flush() } }
        queued.append(Order(requests: requests, base: base, piece: piece, done: done))
    }

    private func flush() {
        let orders = queued
        queued = []
        let cuts = baseCuts(orders.map { ($0.requests.map(\.number), $0.base != nil) })
        for (order, cut) in zip(orders, cuts) { run(order, cutting: cut) }
    }

    /// One batch's grab, in flight beside any other batch's. Only the base's holes are pooled across the
    /// turn.
    private func run(_ order: Order, cutting cut: Set<CGWindowID>) {
        let numbers = Dictionary(order.requests.map { ($0.number, $0.id) },
                                 uniquingKeysWith: { first, _ in first })
        let displayId = self.displayId
        let scale = self.scale
        let alone = self.alone
        let piece = order.piece

        var seen = Set<CGWindowID>()
        let ordered = order.requests.map(\.number).filter { seen.insert($0).inserted }

        Task {
            await grab(windows: ordered, cutting: cut, display: displayId, scale: scale,
                       alone: alone, base: order.base) { shot in
                switch shot {
                case .base(let image):
                    await piece(.base(image))
                case .window(let window):
                    let still = window.still
                    if still.needsAlone { await self.filmAlone(window.number) }
                    guard let id = numbers[window.number] else { return }
                    await piece(.window(id, CapturedSurface(
                        image: still.image, frame: window.frame, corner: still.corner,
                        isWhole: CapturedSurface.measuredWhole(of: still.image))))
                case .refused(let refusal):
                    guard let id = numbers[refusal.number],
                          let card = await self.card(for: refusal) else { return }
                    await piece(.window(id, card))
                }
            }
            order.done()
        }
    }

    private func filmAlone(_ number: CGWindowID) { alone.insert(number) }

    /// The card a window kept out of capture stands in as. No corner reading: none was taken.
    private func card(for refusal: Refusal) -> CapturedSurface? {
        let app = refusal.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        return WindowCard.image(size: refusal.frame.size, scale: refusal.scale, title: refusal.title, app: app)
            .map { CapturedSurface(image: $0, frame: refusal.frame) }
    }
}

/// What each base asked for in one turn must cut. A batch opening a cover is grown by every batch after
/// it until the next one opens another, all before it is raised — so its base cuts their windows as well
/// as its own. Empty for a batch that takes no base.
func baseCuts(_ batches: [(numbers: [CGWindowID], opensCover: Bool)]) -> [Set<CGWindowID>] {
    var cuts = Array(repeating: Set<CGWindowID>(), count: batches.count)
    var opening: Int?
    for (index, batch) in batches.enumerated() {
        if batch.opensCover { opening = index }
        if let opening { cuts[opening].formUnion(batch.numbers) }
    }
    return cuts
}

//
// File scope on purpose: nested inside a `@MainActor` type these would inherit its isolation, and a
// main-actor-isolated child-task closure cannot take ownership of the filter it was handed.

/// One window's still and where it was taken from. `frame` is `SCWindow.frame`: CG global top-left
/// space, the same space `EmiraCore` uses, so no conversion. The Y-flip happens later, at the overlay.
private struct Shot: Sendable {
    let number: CGWindowID
    let still: SurfaceStill
    let frame: Rect
}

/// A window the window server keeps out of capture, and what its card needs: where, how dense, and whose.
private struct Refusal: Sendable {
    let number: CGWindowID
    let frame: Rect
    let scale: Double
    let title: String
    let pid: pid_t?
}

/// One thing the batch produced, handed to `deliver` the moment it lands rather than with the rest.
private enum Piece: Sendable {
    case window(Shot)
    case refused(Refusal)
    case base(CGImage)
}

/// Fetch the shareable content once, then fan the captures out, handing each back as it lands.
///
/// One `SCShareableContent` read, because it is a window-server round trip and one per window would put
/// the enumeration cost back at the head of the transition.
///
/// `windows` is both lists at once — what to photograph, in that order, and what the base has to have a
/// hole where, a cover belonging to one display — plus `base.departed` and `cut` (`baseCuts`), which are
/// holes and nothing more.
///
/// **The read is `onScreenWindowsOnly` until it comes up short.** A scoped window the read does not
/// carry is neither photographed nor cut out of the base, and stands frozen in it for the whole cover;
/// the long read costs ~10 ms, so it is asked for only when the short one is missing one of `windows`.
private func grab(windows: [CGWindowID],
                  cutting cut: Set<CGWindowID>,
                  display: CGDirectDisplayID,
                  scale: CGFloat,
                  alone: Set<CGWindowID>,
                  base: BaseRequest?,
                  deliver: @Sendable (Piece) async -> Void) async {
    let wanted = Set(windows)
    var content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        if !wanted.isSubset(of: Set(content.windows.map(\.windowID))) {
            content = try await SCShareableContent.excludingDesktopWindows(true,
                                                                           onScreenWindowsOnly: false)
        }
    } catch {
        // Overwhelmingly: the Screen Recording grant is missing or has lapsed. `CaptureService` acks
        // either way, so delivering nothing at all is a complete answer.
        return
    }

    let byNumber = Dictionary(content.windows.map { ($0.windowID, $0) },
                              uniquingKeysWith: { first, _ in first })
    let targets = windows.compactMap { byNumber[$0] }
    let mine = ProcessInfo.processInfo.processIdentifier
    let departed = (base?.departed ?? []).union(base?.concealed ?? [])
    // The base excludes what we are about to animate, what is still fading out, our own overlay, *and*
    // everything that composites above the cover. See the file header.
    let chrome = Overlay.level.rawValue
    let excluded = content.windows.filter {
        wanted.contains($0.windowID) || cut.contains($0.windowID) || departed.contains($0.windowID)
            || $0.owningApplication?.processID == mine
            || $0.windowLayer > chrome
    }
    // Only the batch that *opens* a cover takes a base: by the time one grows, the cover's other windows
    // have teleported to their end frames, and a fresh base would carry them frozen behind their own
    // sliding layers.
    let scDisplay = base != nil ? content.displays.first { $0.displayID == display } : nil

    // Before the group, not first in it: this is the gate, and it is the one piece whose arrival time
    // we are unwilling to leave to the scheduler. See the file header.
    if let scDisplay {
        nonisolated(unsafe) let filter = SCContentFilter(display: scDisplay,
                                                         excludingWindows: excluded)
        let size = (width: Int(Double(scDisplay.width) * scale),
                    height: Int(Double(scDisplay.height) * scale))
        if let image = try? await shot(filter, width: size.width, height: size.height) {
            await deliver(.base(image))
        }
    }

    // One at a time, in the order asked. See the file header: overlapping these is measurably slower.
    let refusing = refusingCapture(targets.map(\.windowID))
    for window in targets {
        let frame = window.frame
        guard frame.width >= 1, frame.height >= 1 else { continue }
        if refusing.contains(window.windowID) {
            let scale = Double(SCContentFilter(desktopIndependentWindow: window).pointPixelScale)
            await deliver(.refused(Refusal(
                number: window.windowID,
                frame: Rect(x: Double(frame.minX), y: Double(frame.minY),
                            width: Double(frame.width), height: Double(frame.height)),
                scale: scale, title: window.title ?? "", pid: window.owningApplication?.processID)))
            continue
        }
        // A capture that failed is simply not delivered; the batch carries on without it.
        guard let still = await surfaceShot(of: window,
                                            carryingChildren: !alone.contains(window.windowID)) else {
            continue
        }
        let rect = Rect(x: Double(frame.minX), y: Double(frame.minY),
                        width: Double(frame.width), height: Double(frame.height))
        await deliver(.window(Shot(number: window.windowID, still: still, frame: rect)))
    }
}

/// One window's own surface at the resolution it is drawn at, as `keptStill` chooses it. `carryingChildren`
/// keeps a sheet in its stand-in, and retakes alone a still holding the family ScreenCaptureKit films with a
/// window.
func surfaceShot(of window: SCWindow, carryingChildren: Bool = true) async -> SurfaceStill? {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    return await keptStill(of: window.frame, at: Double(filter.pointPixelScale),
                           carryingChildren: carryingChildren) { withChildren in
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        configuration.includeChildWindows = withChildren
        return try? await SCScreenshotManager.captureScreenshot(contentFilter: filter,
                                                               configuration: configuration).sdrImage
    }
}

/// A window's still, and what it says about the window.
struct SurfaceStill: Sendable {
    let image: CGImage
    /// Pixels per point in `image`, or `nil` for a still that is not its window's frame at that scale.
    let scale: Double?
    /// Whether `image` is the frame to the pixel (`isExactly`) — the size a window at rest is drawn at.
    let isExact: Bool
    /// This still's reading of its window's corner, at rest only at its frame to the pixel as well as inside
    /// no border. A window the server animates open is drawn larger than its lagging frame, inside a clear
    /// pixel, or both.
    let corner: CornerReading?
    /// Filmed with its children the window held more than its frame, and alone it did not.
    let needsAlone: Bool
}

/// The still to keep of a window at `frame`, drawn at `scale`, from `take` filming it with its children or
/// without. A still that is not the frame is retaken alone, and kept only if that one is — anything else
/// wrong with it (a frame read before a resize, a window still opening) is no reason to drop its sheets.
func keptStill(of frame: CGRect, at scale: Double, carryingChildren: Bool,
               take: (_ withChildren: Bool) async -> CGImage?) async -> SurfaceStill? {
    func still(_ image: CGImage, needsAlone: Bool) -> SurfaceStill {
        let pixels = CGSize(width: image.width, height: image.height)
        let fits = isSurface(pixels, of: frame, at: scale), isExact = isExactly(pixels, of: frame, at: scale)
        // Measured here, once per still, where the scale it was taken at is known for certain.
        let read = fits ? CapturedSurface.measuredCorner(of: image, scale: CGFloat(scale)) : nil
        let corner = read.map { CornerReading(radius: $0.radius, isAtRest: isExact && $0.isAtRest) }
        return SurfaceStill(image: image, scale: fits ? scale : nil, isExact: isExact, corner: corner,
                            needsAlone: needsAlone)
    }
    guard let first = await take(carryingChildren) else { return nil }
    let kept = still(first, needsAlone: false)
    guard carryingChildren, kept.scale == nil, let alone = await take(false) else { return kept }
    let retake = still(alone, needsAlone: true)
    return retake.scale != nil ? retake : kept
}

/// Whether `pixels` draw `frame` at `scale`, each axis within `surfaceSlack` — which an opening window's
/// lagging frame stays inside, and a still holding other windows with this one does not.
func isSurface(_ pixels: CGSize, of frame: CGRect, at scale: Double) -> Bool {
    guard scale > 0, frame.width >= 1, frame.height >= 1 else { return false }
    let want = CGSize(width: frame.width * scale, height: frame.height * scale)
    return abs(pixels.width - want.width) <= want.width * surfaceSlack
        && abs(pixels.height - want.height) <= want.height * surfaceSlack
}

/// How far a still may stand from its window's frame and still be that window, per axis.
let surfaceSlack = 0.02

/// Whether `pixels` draw `frame` at `scale` to the pixel on each axis, a fractional frame rounding either way.
func isExactly(_ pixels: CGSize, of frame: CGRect, at scale: Double) -> Bool {
    abs(pixels.width - frame.width * scale) <= 1 && abs(pixels.height - frame.height * scale) <= 1
}

/// One `SCScreenshotManager` still at an explicit pixel size. `showsCursor = false` — a captured cursor
/// would freeze mid-transition and put two pointers on screen for the length of the scroll.
private func shot(_ filter: SCContentFilter, width: Int, height: Int) async throws -> CGImage {
    let configuration = SCStreamConfiguration()
    configuration.width = width
    configuration.height = height
    configuration.showsCursor = false
    return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                      configuration: configuration)
}
