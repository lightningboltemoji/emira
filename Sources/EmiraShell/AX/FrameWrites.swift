import EmiraCore
import Foundation

// Our own frame writes come back to us as move reports: an app posts `AXWindowMoved`/`AXWindowResized`
// while it applies a set, and the observer delivers them while that set's lane job is still running. The
// executor's read-back already answers them, so a report for a window whose write is still out is dropped.
// One arriving after the landing is read as ever — that is an app moving itself afterwards.

/// The windows the truth plane is writing a frame to. Marked by `AXExecutor` as an app's group goes out on
/// its lane and cleared when the landings come back; read by `WorldWatcher` before it reads a move, and by
/// `Scrims` for how long to keep reading the window server. One per daemon, shared like `FocusIntent`.
@MainActor
public final class FrameWrites {

    /// Writes out per window. A count, because a second batch can name a window before the first lands.
    private var inFlight: [WindowId: Int] = [:]

    /// Told as each group goes out: what it moves reaches the window server at some moment of its app's
    /// choosing, and a plane masked against that server has to be reading when it does.
    public var onBegin: (@MainActor () -> Void)?

    public init() {}

    public func begin(_ ids: [WindowId]) {
        for id in ids { inFlight[id, default: 0] += 1 }
        onBegin?()
    }

    public func end(_ ids: [WindowId]) {
        for id in ids {
            guard let count = inFlight[id] else { continue }
            inFlight[id] = count > 1 ? count - 1 : nil
        }
    }

    /// Whether a write to `id` has yet to come back — so a move reported now is that write's own echo.
    public func isWriting(_ id: WindowId) -> Bool { inFlight[id] != nil }

    /// Whether any write has yet to come back.
    public var isActive: Bool { !inFlight.isEmpty }
}
