import Foundation

/// A three-finger scroll with the hand still on it.
///
/// **Not `World`'s, and not `Motion`'s, for the reason `Drag` is neither: nothing observes this.** Every
/// field of `World` is refreshed by observation, and a viewport offset is refreshed by the spring that
/// owns it — but "a hand is on the trackpad" is reported by nothing and derivable from nothing. It is a
/// latch, which is what `Pointer`'s own paragraph exists to say a hide is not, so it sits beside `Drag`
/// rather than inside either.
///
/// **There is deliberately no `gliding` case.** The lift hands the offset back to a spring aimed at a
/// target, and from that instant every question about it — does the cover close, is the deadline armed,
/// what does a command interrupting it do — has the same answer it has for a keyboard scroll. A case
/// that changed no answer would be a second authority on "is a transition in flight", which `Motion`
/// already is.
///
/// **One at a time, and one display.** There is one trackpad and the hand is in one place, so this is
/// desktop-wide rather than per monitor; the display is latched at the gesture's start from
/// `State.acting()` — the strip you are working on, not the one the cursor happens to sit over, because
/// the fingers are not on a screen and the focused monitor is the only thing that can answer.
public enum TrackpadScroll: Sendable, Equatable, Codable {
    /// No hand on it. Every viewport offset belongs to its spring.
    case idle
    /// Fingers are down and this display's offset is theirs — written outright by each drained sample,
    /// advanced by no spring and no tick.
    case dragging(MonitorId)

    /// The display the hand has, or `nil`.
    public var monitor: MonitorId? {
        guard case .dragging(let id) = self else { return nil }
        return id
    }

    /// Whether the hand is on `id`'s strip — the question the close gate, the hold deadline and the
    /// frame's blit each ask, all of them about one display rather than about the desktop.
    public func holds(_ id: MonitorId?) -> Bool {
        guard case .dragging(let held) = self, let id else { return false }
        return held == id
    }
}
