import AppKit
import QuartzCore
import EmiraCore

// One peek's substrate: a borderless, non-activating panel over the part of a peeking column its display shows,
// holding that part of the window's photograph. `HoistPanel`'s sibling, keeping its idioms —
// `animationBehavior = .none`, ordered in at birth and shown by an alpha flip, `isReleasedWhenClosed =
// false`, and a window per peek because only a window's frame routes clicks.
//
// **It is cut to the display, because it is drawn by the same rule it exists to get around.** A window of
// ours standing at the column's whole frame would be drawn whole on the neighbour too. So the panel is the
// slice the display shows, and its layer shows the matching part of the photograph.
//
// **It stands where the column would, among the windows rather than over them.** A hoist is above
// everything because a buried float is the thing it corrects; a peek is a tiled window, and whatever
// stacks over a tiled window — a float, a dialog — stacks over this. So it is a normal-level window at
// the back of its level: no tiled window overlaps it, and everything that may is in front. The scrim
// reads it as the window it stands for (`PeekPanels.standIn`), so it carries the column's veil too.

/// One peek: a click target the size of what the display shows of the column, showing that part of it.
@MainActor
public final class PeekPanel: PeekSurface {

    /// The window this panel stands for — what a click reports.
    public let window: WindowId

    private let geometry: ScreenGeometry
    private let panel: NSWindow
    private let host: CALayer
    private let onClick: @MainActor (WindowId) -> Void

    /// Whether a photograph has arrived. A panel with none shows nothing and takes no clicks: an empty
    /// window is a hole in the desktop.
    private var hasImage = false

    /// The part of the column on the glass, and the column's whole frame — what places the photograph.
    public private(set) var slice: Rect = .zero
    private var whole: Rect = .zero

    /// The window server's number for the panel — what a reading of the desktop names it by.
    public var number: CGWindowID { CGWindowID(panel.windowNumber) }

    /// Whether the picture is on the glass.
    public var isShowing: Bool { hasImage }

    public init(window: WindowId, scale: CGFloat, geometry: ScreenGeometry,
                onClick: @escaping @MainActor (WindowId) -> Void) {
        self.window = window
        self.geometry = geometry
        self.onClick = onClick

        panel = clickablePanel(.zero)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // macOS's own, cast from the photograph's alpha: the window's rounded corners are in the pixels.
        panel.hasShadow = true
        panel.level = .normal
        // Neither `.canJoinAllSpaces` nor `.fullScreenAuxiliary`, for `HoistPanel`'s reason.
        panel.collectionBehavior = [.stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true

        let view = PeekClickView(frame: .zero)
        view.wantsLayer = true
        host = view.layer ?? CALayer()
        host.contentsScale = scale
        host.contentsGravity = .resize
        host.masksToBounds = true

        view.onClick = { [weak self] in
            guard let self, self.hasImage else { return }
            self.onClick(self.window)
        }
        panel.contentView = view
        // Behind every window of its level, and left there: nothing of ours ever raises it.
        panel.orderBack(nil)
    }

    /// Stand over `slice`, the part of `frame` its display shows. The photograph is laid at `frame` and
    /// cut by the panel's bounds, so the part on the glass is the part of the window that would be.
    public func place(slice: Rect, of frame: Rect) {
        guard slice != self.slice || frame != whole else { return }
        self.slice = slice
        whole = frame
        let cocoa = geometry.cocoa(slice)
        panel.setFrame(cocoa, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = CGRect(origin: .zero, size: cocoa.size)
        host.contentsRect = Self.contentsRect(of: slice, in: frame)
        CATransaction.commit()
        panel.invalidateShadow()
    }

    /// Load the pixels, and show them if they are the first.
    public func setImage(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.contents = image
        CATransaction.commit()
        panel.invalidateShadow()
        guard !hasImage else { return }
        hasImage = true
        panel.ignoresMouseEvents = false
        setAlpha(1)
    }

    /// Take it off the screen for good — the column has come back on the glass or left the viewport, a
    /// display changed under it, or the daemon is quitting.
    public func retire() {
        hasImage = false
        panel.ignoresMouseEvents = true
        setAlpha(0)
        panel.orderOut(nil)
    }

    /// The part of the photograph a slice shows, in the unit square — measured from the bottom-left, as
    /// a non-flipped layer measures it, so the core's top-left `y` comes in from the frame's bottom edge.
    static func contentsRect(of slice: Rect, in frame: Rect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: (slice.minX - frame.minX) / frame.width,
                      y: (frame.maxY - slice.maxY) / frame.height,
                      width: slice.width / frame.width,
                      height: slice.height / frame.height)
    }

    /// `HoistPanel.setAlpha`'s write, for its reason.
    private func setAlpha(_ alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = alpha
        }
    }
}

/// The panel's content view: pixels and one gesture, on the press for `HoistPanel`'s reason.
private final class PeekClickView: NSView {
    var onClick: (@MainActor () -> Void)?

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { onClick?() }
    }
}
