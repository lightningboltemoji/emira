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
// Concurrency: the batch fans out, but the window server *serializes* screenshot requests — a batch
// costs roughly 10 ms per capture however it is shaped, and the requested pixel dimensions do not enter
// into it. The group buys partial overlap, not parallelism, so scope size is the latency. None of
// ScreenCaptureKit's descriptor types are `Sendable`, so everything derived from one content fetch
// shares an isolation region a child task may not reach into. Hence free functions at file scope
// (isolation propagates into nested types) and `nonisolated(unsafe)` on each filter — narrow and true,
// since a filter is built at the send site, never stored or mutated, and used by exactly one child task.

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
                        then completion: @escaping @MainActor (CaptureBatch) -> Void) {
        let numbers = Dictionary(requests.map { ($0.number, $0.id) }, uniquingKeysWith: { first, _ in first })
        let displayId = self.displayId
        let scale = self.scale

        Task {
            let shots = await grab(windows: Set(numbers.keys), display: displayId, scale: scale,
                                   includeBase: includeBase)
            var surfaces: [WindowId: CapturedSurface] = [:]
            for shot in shots.windows {
                guard let id = numbers[shot.number] else { continue }
                // Measured here, once per still, where the scale it was taken at is known for certain.
                surfaces[id] = CapturedSurface(
                    image: shot.image, frame: shot.frame,
                    cornerRadius: CapturedSurface.measuredCornerRadius(of: shot.image, scale: scale))
            }
            completion(CaptureBatch(surfaces: surfaces, base: shots.base))
        }
    }
}

// MARK: - ScreenCaptureKit
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

private struct Shots: Sendable {
    let windows: [Shot]
    let base: CGImage?
}

/// What one child task of the batch came back with. The base and the window stills go through the
/// *same* task group rather than a group plus an `async let`, because two concurrent readers of one
/// isolation region is exactly what Swift 6 rejects.
private enum Piece: Sendable {
    case window(Shot)
    case base(CGImage)
}

/// Fetch the shareable content once, then fan the captures out.
///
/// One `SCShareableContent` read, because it is a window-server round trip and one per window would put
/// the enumeration cost back at the head of the transition. `onScreenWindowsOnly: true` is safe for a
/// parked column because macOS never lets a window leave the screen entirely — it keeps its ~1 px sliver
/// and stays in this list.
private func grab(windows: Set<CGWindowID>,
                  display: CGDirectDisplayID,
                  scale: CGFloat,
                  includeBase: Bool) async -> Shots {
    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    } catch {
        // Overwhelmingly: the Screen Recording grant is missing or has lapsed. `CaptureService` acks
        // either way, so an empty batch is a complete answer.
        return Shots(windows: [], base: nil)
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

    return await withTaskGroup(of: Piece?.self) { group in
        for window in targets {
            let frame = window.frame
            guard frame.width >= 1, frame.height >= 1 else { continue }
            nonisolated(unsafe) let filter = SCContentFilter(desktopIndependentWindow: window)
            let number = window.windowID
            let rect = Rect(x: Double(frame.minX), y: Double(frame.minY),
                            width: Double(frame.width), height: Double(frame.height))
            let size = (width: Int(frame.width * scale), height: Int(frame.height * scale))
            group.addTask {
                guard let image = try? await shot(filter, width: size.width, height: size.height)
                else { return nil }
                return .window(Shot(number: number, image: image, frame: rect))
            }
        }

        if let scDisplay {
            nonisolated(unsafe) let filter = SCContentFilter(display: scDisplay,
                                                             excludingWindows: excluded)
            let size = (width: Int(Double(scDisplay.width) * scale),
                        height: Int(Double(scDisplay.height) * scale))
            group.addTask {
                guard let image = try? await shot(filter, width: size.width, height: size.height)
                else { return nil }
                return .base(image)
            }
        }

        var stills: [Shot] = []
        var base: CGImage?
        for await piece in group {
            switch piece {
            case .window(let shot): stills.append(shot)
            case .base(let image):  base = image
            case nil:               break        // this piece failed; the batch carries on without it
            }
        }
        return Shots(windows: stills, base: base)
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
