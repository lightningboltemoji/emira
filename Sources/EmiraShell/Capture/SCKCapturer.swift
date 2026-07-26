import CoreGraphics
import Foundation
import ScreenCaptureKit
import EmiraCore

// The `SurfaceCapturer` that talks to ScreenCaptureKit — the third and last file in the shell that
// imports a system framework it cannot be tested without (`AXAccess`, `AXObservers`, and this).
// Everything here is harvested from the validated spikes rather than re-derived: the filters, the
// configuration and the native-resolution sizing below are `spike/move-loop.swift` and
// `spike/strip.swift`, which is where they were proved to produce a stand-in the eye cannot catch
// (PRINCIPLES.md §10, checkpoints 1–3a).
//
// **Two filters, and the difference between them is the whole trick.**
//
//  · `SCContentFilter(desktopIndependentWindow:)` captures a window's **own surface**, at full size,
//    whether or not it is on screen or occluded. That is what makes a parked column — a window sitting
//    at its 1 px sliver — capturable at all, and therefore what makes a scroll *in* from off-viewport
//    possible. A screen-region capture could never do this.
//  · `SCContentFilter(display:excludingWindows:)` captures the display **minus** the windows we are
//    about to animate. That is the base: wallpaper, menu bar, and every window that is *not* moving,
//    with window-shaped holes where the moving ones were. Layers go in those holes. Getting this
//    exclusion wrong is not subtle — the excluded window appears twice, once frozen and once sliding.
//
// **We exclude ourselves too.** emira's overlay is a real window on the display, kept ordered-in at
// `alpha 0` so the raise is a pure alpha flip (`Overlay`). An invisible window contributes nothing to a
// composite, so in principle it is harmless; in practice "in principle the compositor ignores it" is a
// bet with no upside, and a base captured through our own cover would be a spectacular, self-inflicted
// feedback loop. One `processID` comparison closes it.
//
// **Concurrency, and the shape Swift 6 forces it into.** The batch fans out — N window stills and the
// base go out together, so it costs the slowest one rather than the sum. Same reasoning as the AX lanes
// (`AXClient`): the work is per-window and independent, and serializing it would turn a handful of
// milliseconds into a visible wait at the head of every transition.
//
// None of ScreenCaptureKit's descriptor types are `Sendable` — not `SCShareableContent`, not `SCWindow`,
// not `SCDisplay`, not `SCContentFilter` — so everything derived from one content fetch shares a single
// isolation region, and a child task may not reach into it. Two consequences, and both are deliberate:
//
//  · **The whole batch is `nonisolated`** (hence these two free functions rather than methods on the
//    `@MainActor` class above; isolation propagates into nested types, so they are at file scope too).
//    A filter built on the main actor could not be handed to a capture running off it — and none of
//    this belongs on the main thread at the head of a transition anyway.
//  · **Each filter crosses as `nonisolated(unsafe)`.** This is the one unsafe assertion in the shell,
//    so it is worth stating exactly what is being asserted: a filter is constructed *at the send site*,
//    is never stored, never mutated and never read again by the sender, and is used by exactly one
//    child task. It is single-ownership transfer — the thing `sending` exists to express — and the
//    compiler simply cannot see it through a type it has no `Sendable` information about. What crosses
//    the boundary alongside it is a `CGWindowID`, a `Rect` and two `Int`s.
//
// The alternative was capturing serially, which needs no assertion and costs N round trips instead of
// one at the head of every scroll — user-visible latency traded for a safety property we already have.

/// Captures window surfaces and the desktop beneath them via ScreenCaptureKit.
@MainActor
public final class SCKCapturer: SurfaceCapturer {

    /// The display the base is captured from — the one the overlay covers and the strip is laid out on.
    /// Per-display capture arrives with per-display covers at M6.
    private let displayId: CGDirectDisplayID
    /// The display's backing scale, so every still is captured at native pixel resolution. Fidelity is
    /// make-or-break (§6): a still captured at 1× and stretched onto a 2× layer is a soft rectangle,
    /// and the cross-fade back to the crisp real window is exactly the "pop" §9's Risk B is about.
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
                surfaces[id] = CapturedSurface(image: shot.image, frame: shot.frame)
            }
            completion(CaptureBatch(surfaces: surfaces, base: shots.base))
        }
    }
}

// MARK: - ScreenCaptureKit
//
// File scope on purpose: nested inside a `@MainActor` type these would inherit its isolation, and a
// main-actor-isolated child-task closure cannot take ownership of the filter it was handed — which is
// the whole arrangement above. Isolation propagates to nested types; it does not propagate here.

/// One window's still and where it was taken from. `frame` is `SCWindow.frame`, which is CG global
/// top-left space — the *same* space `EmiraCore` calls its own, so it crosses into `Rect` with no
/// conversion (`WindowRegistry` reads `kCGWindowBounds` identically). The Y-flip happens once, later,
/// at the overlay.
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
/// isolation region is exactly what Swift 6 rejects — and because "the batch is done when the last
/// piece lands" is one question, not two.
private enum Piece: Sendable {
    case window(Shot)
    case base(CGImage)
}

/// Fetch the shareable content once, then fan the captures out.
///
/// The single `SCShareableContent` read is deliberate: it is a window-server round trip, and one per
/// *window* would put the enumeration cost back at the head of the transition that the fan-out below
/// exists to remove. `onScreenWindowsOnly: true` is safe for a parked column precisely because
/// macOS never lets a window leave the screen entirely (PRINCIPLES.md §10, the Risk A probe) — a
/// parked window keeps its ~1 px sliver and stays in this list.
private func grab(windows: Set<CGWindowID>,
                  display: CGDirectDisplayID,
                  scale: CGFloat,
                  includeBase: Bool) async -> Shots {
    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    } catch {
        // Overwhelmingly: the Screen Recording grant is missing or has lapsed. There is nothing to
        // decide here — `CaptureService` acks either way and the daemon has already told the user at
        // boot — so the honest answer is an empty batch.
        return Shots(windows: [], base: nil)
    }

    let targets = content.windows.filter { windows.contains($0.windowID) }
    let mine = ProcessInfo.processInfo.processIdentifier
    // The base excludes what we are about to animate *and* our own overlay. See the file header.
    let excluded = content.windows.filter {
        windows.contains($0.windowID) || $0.owningApplication?.processID == mine
    }
    // Only the batch that *opens* a cover takes a base. A batch growing one is capturing windows the
    // retarget swept in, and by then the cover's other windows have already teleported to their end
    // frames — a fresh base would carry them, frozen, behind their own sliding layers.
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

/// One `SCScreenshotManager` still at an explicit pixel size.
///
/// `showsCursor = false` because the cursor is not part of any window's identity: captured into a
/// layer it would freeze mid-transition and then jump when the real one reappeared at the
/// cross-fade — two pointers on screen for the length of the scroll.
private func shot(_ filter: SCContentFilter, width: Int, height: Int) async throws -> CGImage {
    let configuration = SCStreamConfiguration()
    configuration.width = width
    configuration.height = height
    configuration.showsCursor = false
    return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                      configuration: configuration)
}
