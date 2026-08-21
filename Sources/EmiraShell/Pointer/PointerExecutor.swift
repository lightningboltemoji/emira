import CoreGraphics
import EmiraCore
import Foundation

// The pointer plane's `Executor` — the smallest of the five.
//
// `Effect.setCursorHidden(true)` is a standing *assertion*, not an edge: an application coming to the
// front discards a hide made from the background, so the core re-issues it on every `Event.appActivated`
// and every one of them is executed. A show pays out the whole depth of them.
//
// That bookkeeping sits above the `CursorSurface` seam, so the arithmetic that has to be right is
// headless and `SystemCursor` stays two calls — the shape `CompositingExecutor`→`CoverSurface` and
// `AXExecutor`→`WindowWriter` have, for the same reason.

/// The pointer plane's mechanism: make the cursor invisible, bring it back, and move it. `SystemCursor`
/// is the real one; tests use a recording double.
@MainActor
public protocol CursorSurface: AnyObject {
    /// Whether this surface can hide the cursor at all. Read once, by `applyEnvironment`, and never
    /// consulted per-effect: a surface that cannot hide is one the reducer is never allowed to ask.
    var canHideCursor: Bool { get }

    /// Hide the pointer on every display — one call, one increment of the window server's count. The
    /// balancing is the executor's, so the mechanism stays two dumb calls.
    func hideCursor()

    /// Show it again, once.
    func showCursor()

    /// Where the pointer is, in top-left global coordinates — the core's own space.
    var location: Point { get }

    /// Put the pointer at `point`, in the same space. Posts no event.
    func warp(to point: Point)
}

/// Executes `Effect.setCursorHidden` against the real cursor.
@MainActor
public final class PointerExecutor: Executor {

    private let surface: any CursorSurface

    /// How many hides we have issued and not yet paid for. Ours, not the window server's, which resets
    /// its count on an activation without telling us — so this is an upper bound, and the safe side:
    /// the count floors at zero, and a hide left unpaid is a desktop with no cursor.
    private var hideDepth = 0

    /// Whether the cursor is hidden *by us*. **Derived, not stored:** it is exactly "a hide is
    /// outstanding", and a second field agreeing with the depth by convention is one authority too many.
    public var isCursorHidden: Bool { hideDepth > 0 }

    /// Called whenever that changes, so the watcher can arm (or stop watching for) the motion that ends
    /// a hide. Wired in the daemon, the shape `capture.onBatchResolved` and `executor.onCoverDismissed`
    /// have.
    public var onCursorHidden: (@MainActor (Bool) -> Void)?

    /// Whether a pointer already inside the rect is centred anyway — `[mouse] follows-focus`'s upper two
    /// rungs. Here rather than on the effect, for the reason `windowAnimation` is: the core emits the
    /// identical stream under every rung. Set at boot and on every reload (`applyShellConfig`).
    public var recentres = false

    /// Called with where the pointer was put, after a warp actually moved it. A warp posts no event, so
    /// this is the only way the sample readers hear about a move nobody made — and both are measuring
    /// against a place the cursor no longer is.
    public var onWarp: (@MainActor (Point) -> Void)?

    public init(surface: any CursorSurface) {
        self.surface = surface
    }

    /// Whether hiding is reachable on this machine. Read at boot and on every config reload.
    public var canHideCursor: Bool { surface.canHideCursor }

    public func execute(_ effects: [Effect], feedback: EventSink) {
        for effect in effects {
            switch effect {
            case .setCursorHidden(let hidden):
                setCursorHidden(hidden)

            case .warpPointer(let rect):
                warp(into: rect)

            // The other planes, routed by `CompositingExecutor` before they reach here. Exhaustive so a
            // new `Effect` case must be assigned a home rather than falling through.
            case .setFrame, .park, .capture, .beginTransition, .extendCover, .elevateLayer,
                 .setLayerFrame, .hideLayer, .refreshLayer, .endTransition, .focus, .raise,
                 .closeWindow, .exec:
                break
            }
        }
    }

    /// Show the cursor if we are hiding it, from outside the effect stream. The shutdown path: quitting
    /// with a hidden pointer would leave the desktop without one, and a `Teardown` cascade emits only
    /// `setFrame`/`raise`/`focus` and takes the truth executor, so this is not on it.
    public func restoreCursor() {
        setCursorHidden(false)
    }

    /// The half of `Effect.warpPointer` that needs the cursor's position, which is why it is here:
    /// the pointer moves without anyone asking, so a `State` holding it would be wrong between reads.
    /// Under `recentres` the position is not consulted at all and every focus change centres it.
    private func warp(into rect: Rect) {
        guard recentres || !rect.contains(surface.location) else { return }
        surface.warp(to: rect.center)
        onWarp?(rect.center)
    }

    /// Make the cursor's visibility what the core asked for. A hide is executed **every time it is
    /// asserted**, since a re-assertion is the only answer to an activation having discarded the last
    /// one; the *notification* stays an edge, because arming the wake watcher again would re-anchor it.
    private func setCursorHidden(_ hidden: Bool) {
        let wasHidden = isCursorHidden
        if hidden {
            surface.hideCursor()
            hideDepth += 1
        } else {
            // A show with nothing outstanding does not reach the cursor: the count is shared with every
            // other process on this connection's display, and paying out a hide we did not make is the
            // one failure here that outlives the process.
            guard wasHidden else { return }
            for _ in 0..<hideDepth { surface.showCursor() }
            hideDepth = 0
        }
        guard hidden != wasHidden else { return }
        onCursorHidden?(hidden)
    }
}

/// The real cursor. Two public Core Graphics calls, over a connection `CursorConnection` has marked.
@MainActor
public final class SystemCursor: CursorSurface {

    public init() {}

    public var canHideCursor: Bool { CursorConnection.isAvailable }

    /// One call, not one per display: the `display` argument is ignored and the count it increments
    /// belongs to the connection, so hiding per screen would take as many shows to undo. **Passing over
    /// the Dock brings the cursor back** — a permanent limit of this route, which `[mouse] hide` names.
    public func hideCursor() {
        guard CursorConnection.markConnection() else { return }
        CGDisplayHideCursor(CGMainDisplayID())
    }

    public func showCursor() {
        CGDisplayShowCursor(CGMainDisplayID())
    }

    /// **The one boundary in the shell that does not Y-flip.** `CGEvent` locations and
    /// `CGWarpMouseCursorPosition` both speak top-left global coordinates, which is the core's own
    /// space; every other seam here converts to Cocoa's bottom-left.
    public var location: Point {
        guard let event = CGEvent(source: nil) else { return .zero }
        return Point(x: Double(event.location.x), y: Double(event.location.y))
    }

    /// Warping succeeds from a background process and posts no event of any kind. The re-association is
    /// not optional: a warp starts a short suppression interval during which the window server ignores
    /// real mouse deltas, so without it the user's next movement is swallowed.
    public func warp(to point: Point) {
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
