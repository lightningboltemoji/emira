import EmiraCore
import Foundation

// The only exit from a hidden pointer, and the reason hiding it is safe at all: emira hides only while
// it can see the motion that brings the cursor back. Refusing a state we have no exit from is better
// than any timeout, which would also unhide on somebody who is merely reading.
//
// *Which* motion counts is a threshold, and the threshold is the whole of this type. A mouse on a desk
// jitters and a resting trackpad finger jitters more, so unhiding on a single sample would make the
// feature look broken.
//
// The other half of the plane's read direction (`PointerFocus` is the first), and a sibling of it rather
// than a corner of `WorldWatcher`: both turn raw samples into at most one `Event`, both are armed by the
// pointer's own state, and neither is a fact about the desktop. The watcher keeps the fan-out alone.

/// Turns pointer samples into `Event.pointerWoke`, one per hide.
@MainActor
public final class PointerWake {

    /// How far the pointer must travel from where a hide left it, in points, before it counts as the
    /// user moving the mouse. Measured from the anchor rather than summed along the path: jitter in
    /// place would sum to a wake given enough seconds, and a deliberate drag crosses this in a few samples.
    public static let distance: Double = 4

    private let sink: EventSink

    /// Where the pointer was when it was hidden, once a sample has said — `nil` while nothing is
    /// hidden, and while a hide is waiting for its first sample to anchor on.
    private var anchor: Point?

    /// Whether a hidden pointer is waiting for the motion that ends it. Distinct from `anchor` being
    /// set, which is the second half of the same arming.
    private var isArmed = false

    public init(sink: EventSink) {
        self.sink = sink
    }

    /// Start — or stop — watching. Driven by the pointer plane's own hide, so the anchor is taken at
    /// the moment the cursor goes.
    public func setArmed(_ armed: Bool) {
        isArmed = armed
        reanchor()
    }

    /// Forget the anchor without changing whether we are watching. Driven by the plane's own warp, which
    /// posts no event, so without this the next jitter measures hundreds of points and unhides at once.
    /// Deliberately not "arm again": a warp with nothing hidden must not start the watching.
    public func reanchor() {
        anchor = nil
    }

    /// Fold one raw pointer sample. Reported once, then disarmed: a stream of `pointerWoke` would put a
    /// mouse drag through the pump at the refresh rate, into the inbound log, which *is* the replay log.
    /// The first sample after arming is the anchor — a hide takes the cursor wherever it stands.
    public func pointerMoved(to point: Point) {
        guard isArmed else { return }
        guard let anchor else {
            self.anchor = point
            return
        }
        guard point.distance(to: anchor) > Self.distance else { return }
        setArmed(false)
        sink(.pointerWoke)
    }
}
