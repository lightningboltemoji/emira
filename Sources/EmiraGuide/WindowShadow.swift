import AppKit
import QuartzCore

// The drop shadow is not part of a window's surface, so anything standing in for a window has to cast
// its own — the reconstruction's layers and the settings mock's panes both. One spec, read by both, or
// the mock stops being a picture of the compositor.

/// The shadow macOS casts around a window, as the three numbers `CALayer` takes for one. **There are
/// two**, because macOS draws two — the key window's and every other window's — and they are not a
/// tweak apart: σ 20 against σ 8, so one shadow for both is a halo on whichever it was not chosen for.
public struct WindowShadow: Sendable, Equatable {

    /// Peak alpha, under the silhouette — `CALayer.shadowOpacity`.
    public let opacity: Float
    /// σ of the Gaussian, in points, which is exactly what `CALayer.shadowRadius` is.
    public let radius: Double
    /// How far the silhouette drops before it is blurred, in points. Down is positive; the layer
    /// property is a `y`-up offset and negates it.
    public let drop: Double

    public init(opacity: Float, radius: Double, drop: Double) {
        self.opacity = opacity
        self.radius = radius
        self.drop = drop
    }

    public static let focused = WindowShadow(opacity: 0.71, radius: 20, drop: 17.5)
    public static let unfocused = WindowShadow(opacity: 0.46, radius: 8, drop: 6.5)

    /// The one macOS would draw for a window in this state — the only way either constant is chosen.
    public static func of(focused: Bool) -> WindowShadow { focused ? .focused : .unfocused }

    /// The same shadow at a projection other than the desktop's, for the settings mock: every length
    /// scales, and the opacity — which is not one — does not.
    public func scaled(by k: Double) -> WindowShadow {
        WindowShadow(opacity: opacity, radius: radius * k, drop: drop * k)
    }

    /// Put it on a layer. The silhouette stays the caller's: a layer that paints nothing has no alpha
    /// for Core Animation to derive one from and must state its `shadowPath` itself.
    @MainActor public func apply(to layer: CALayer) {
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = radius
        layer.shadowOffset = CGSize(width: 0, height: -drop)
    }

    /// How far past the silhouette this shadow reaches: three σ, where a Gaussian's tail ends, plus the
    /// drop. What anything that would clip the shadow has to leave room for.
    public var reach: Double { radius * 3 + drop }

    /// The wider of the two reaches — what a pad sized before it knows which shadow it will hold needs.
    public static let maxReach = max(focused.reach, unfocused.reach)
}
