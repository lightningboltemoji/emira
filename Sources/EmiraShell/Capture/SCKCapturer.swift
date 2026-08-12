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
//    to animate. Get the exclusion wrong and the window appears twice, once frozen and once sliding.
//
// The base excludes our own overlay too: it is a real window kept ordered-in at `alpha 0`, and capturing
// the base through it would be a feedback loop. One `processID` comparison closes that.
//
// **The batch is taken one capture at a time, and that is the fast path.** The window server serializes
// screenshot requests, so overlapping them hides nothing — and worse, inflates each one: ~25 ms taken
// alone against ~41 ms with anything else in flight, which is 1.55–1.90× on the batch and grows under
// CPU load. Two in flight pays that in full, so there is no concurrency width to tune, only overlap to
// avoid. Pixel dimensions do not enter into it, a 500×400 window costing what an 1100×800 one does, so
// **the scope size alone is the latency** at ~25 ms a window.
//
// Pieces are handed back as they land rather than as a batch, and in scope order: a cover gated on the
// base alone (`CoverMode.immediate`) waits for one capture rather than all of them, and the extend gate
// acks per window. The base is captured before any window because it is the gate — no layer can be
// raised until it lands.
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
    /// The display's backing scale, so every still is captured at native pixel resolution. A 1× still
    /// stretched onto a 2× layer is soft, and the cross-fade back to the real window is a visible pop.
    private let scale: CGFloat

    public init(displayId: CGDirectDisplayID, scale: CGFloat) {
        self.displayId = displayId
        self.scale = scale
    }

    public func capture(_ requests: [CaptureRequest], includeBase: Bool,
                        piece: @escaping @MainActor (CapturePiece) -> Void,
                        done: @escaping @MainActor () -> Void) {
        let numbers = Dictionary(requests.map { ($0.number, $0.id) }, uniquingKeysWith: { first, _ in first })
        let displayId = self.displayId
        let scale = self.scale

        Task {
            await grab(windows: Set(numbers.keys), display: displayId, scale: scale,
                       includeBase: includeBase) { shot in
                switch shot {
                case .base(let image):
                    await piece(.base(image))
                case .window(let window):
                    guard let id = numbers[window.number] else { return }
                    // Measured here, once per still, where the scale it was taken at is known for certain.
                    await piece(.window(id, CapturedSurface(
                        image: window.image, frame: window.frame,
                        cornerRadius: CapturedSurface.measuredCornerRadius(of: window.image,
                                                                           scale: scale))))
                }
            }
            done()
        }
    }
}

//
// File scope on purpose: nested inside a `@MainActor` type these would inherit its isolation, and a
// main-actor-isolated child-task closure cannot take ownership of the filter it was handed.

/// One window's still and where it was taken from. `frame` is `SCWindow.frame`: CG global top-left
/// space, the same space `EmiraCore` uses, so no conversion. The Y-flip happens later, at the overlay.
private struct Shot: Sendable {
    let number: CGWindowID
    let image: CGImage
    let frame: Rect
}

/// One thing the batch produced, handed to `deliver` the moment it lands rather than with the rest.
private enum Piece: Sendable {
    case window(Shot)
    case base(CGImage)
}

/// Fetch the shareable content once, then fan the captures out, handing each back as it lands.
///
/// One `SCShareableContent` read, because it is a window-server round trip and one per window would put
/// the enumeration cost back at the head of the transition. `onScreenWindowsOnly: true` is safe for a
/// parked column because macOS never lets a window leave the screen entirely — it keeps its ~1 px sliver
/// and stays in this list.
///
/// `windows` is both lists at once: what to photograph, and what the base has to have a hole where. A
/// cover belongs to one display, so the windows it shows and the windows its own base must not contain
/// are the same set.
private func grab(windows: Set<CGWindowID>,
                  display: CGDirectDisplayID,
                  scale: CGFloat,
                  includeBase: Bool,
                  deliver: @Sendable (Piece) async -> Void) async {
    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    } catch {
        // Overwhelmingly: the Screen Recording grant is missing or has lapsed. `CaptureService` acks
        // either way, so delivering nothing at all is a complete answer.
        return
    }

    let targets = content.windows.filter { windows.contains($0.windowID) }
    let mine = ProcessInfo.processInfo.processIdentifier
    // The base excludes what we are about to animate *and* our own overlay. See the file header.
    let excluded = content.windows.filter {
        windows.contains($0.windowID) || $0.owningApplication?.processID == mine
    }
    // Only the batch that *opens* a cover takes a base: by the time one grows, the cover's other windows
    // have teleported to their end frames, and a fresh base would carry them frozen behind their own
    // sliding layers.
    let scDisplay = includeBase ? content.displays.first { $0.displayID == display } : nil

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

    // One at a time, in scope order. See the file header: overlapping these is measurably slower.
    for window in targets {
        let frame = window.frame
        guard frame.width >= 1, frame.height >= 1 else { continue }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let size = (width: Int(frame.width * scale), height: Int(frame.height * scale))
        // A capture that failed is simply not delivered; the batch carries on without it.
        guard let image = try? await shot(filter, width: size.width, height: size.height) else {
            continue
        }
        let rect = Rect(x: Double(frame.minX), y: Double(frame.minY),
                        width: Double(frame.width), height: Double(frame.height))
        await deliver(.window(Shot(number: window.windowID, image: image, frame: rect)))
    }
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
