import CoreGraphics
import CoreImage
import Foundation
import ScreenCaptureKit
import EmiraCore

// The desktop photograph a scrim is drawn from: one display with **every window** taken out of it.
//
// It is a third filter beside the two in `SCKCapturer`, and the difference from the cover's base is the
// whole of why it is not that. A base excludes only the windows a transition animates, so it carries
// every window that is not moving — which is exactly right for a cover, and exactly wrong here: a scrim
// draws what is *behind* a window, and a photograph holding the other windows would put them back on
// top of the one you are looking through.
//
// **Everything at layer 0 and above goes**, whoever owns it. Our own overlay and guides go with it for
// the reason the base drops them — a photograph taken through them is a feedback loop — and so does the
// chrome above the cover, which a scrim never reaches anyway. What is left is the desktop: the
// wallpaper, the icons, the widgets.
//
// A negative-layer window is the desktop and stays: the wallpaper itself is one.
//
// **`[focus] unfocused-blur` is baked in here.** A blur belongs to the backdrop rather than to the
// window over it, and the backdrop is this photograph — so it is one Gaussian per film, on the capture
// task, rather than a filter the render server re-runs behind a mask that moves on every focus change.
// A radius change is therefore a photograph gone stale, which is `Scrims`' word for it already.

/// Films a display's desktop through ScreenCaptureKit. The `Scrims` plane's source of pixels.
@MainActor
public final class DesktopCapturer: DesktopFilmer {

    /// Each display's backing scale, so the photograph is taken at native resolution — a 1× desktop
    /// stretched over a 2× screen is a soft wallpaper behind a sharp window, which reads as a blur
    /// nobody asked for rather than as transparency.
    private var scales: [MonitorId: CGFloat]

    public init(scales: [MonitorId: CGFloat] = [:]) {
        self.scales = scales
    }

    public func setScales(_ scales: [MonitorId: CGFloat]) {
        self.scales = scales
    }

    public func film(desktopOf monitor: MonitorId, blurredBy radius: Double,
                     then: @escaping @MainActor (CGImage?) -> Void) {
        let display = CGDirectDisplayID(monitor.raw)
        let scale = scales[monitor] ?? 2
        Task {
            // The photograph is taken at native resolution, so the radius crosses into pixels with it.
            let image = await desktop(of: display, scale: scale, sigma: radius * Double(scale))
            await then(image)
        }
    }
}

/// File scope for `SCKCapturer`'s reason: none of ScreenCaptureKit's descriptor types are `Sendable`,
/// and nested inside a `@MainActor` type these would inherit its isolation.
private func desktop(of display: CGDirectDisplayID, scale: CGFloat,
                     sigma: Double) async -> CGImage? {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true),
          let scDisplay = content.displays.first(where: { $0.displayID == display })
    else { return nil }

    // Every window, ours included. See the file header.
    let windows = content.windows.filter { $0.windowLayer >= 0 }
    nonisolated(unsafe) let filter = SCContentFilter(display: scDisplay, excludingWindows: windows)
    let configuration = SCStreamConfiguration()
    configuration.width = Int(Double(scDisplay.width) * scale)
    configuration.height = Int(Double(scDisplay.height) * scale)
    configuration.showsCursor = false
    guard let shot = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                 configuration: configuration)
    else { return nil }
    return frosted(shot, sigma: sigma)
}

/// Shared: a context compiles its kernels, so one per film would pay for them again every time. Working
/// space is linear and wide — a Gaussian is a weighted sum, which is the blur of light only in linear
/// light, and a P3 wallpaper clips in a space that cannot hold it.
private let frostContext = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
])

/// `image` under a Gaussian of `sigma` **pixels** — itself at `0`, and itself again if Core Image
/// declines. Clamped to its own extent first: a blur reads past the edges it is given, and past the
/// screen there is only transparency, which would leave a band down every side of the display unveiled.
func frosted(_ image: CGImage, sigma: Double) -> CGImage? {
    guard sigma > 0 else { return image }
    let source = CIImage(cgImage: image)
    guard let filter = CIFilter(name: "CIGaussianBlur",
                                parameters: [kCIInputImageKey: source.clampedToExtent(),
                                             kCIInputRadiusKey: sigma]),
          let output = filter.outputImage
    else { return image }
    return frostContext.createCGImage(output, from: source.extent, format: .BGRA8,
                                      colorSpace: image.colorSpace)
}
