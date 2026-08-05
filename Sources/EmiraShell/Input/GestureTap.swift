import AppKit
import CoreGraphics
import EmiraCore

// The trackpad's framework-bound half, mirroring `CarbonHotkeys.swift`: a `CGEventTap` on the gesture
// event type, bridged to `NSEvent` for the touches only `NSEvent` can read. No policy — what comes out
// is a contact set and a timestamp, and everything decided about it lives next door in `Gestures.swift`.
//
// **The tap is a requirement, not a preference.** `NSEvent.addGlobalMonitorForEvents` sees no gesture or
// touch event at all, ever — `NSTouch` data is delivered only into the frontmost app's own view
// hierarchy — so there is no tuning that would make a global monitor answer.
//
// `listenOnly`, and that is load-bearing: a non-consuming tap cannot stall the event stream if emira
// hangs, which is the risk `CarbonHotkeys.swift` documents choosing Carbon to avoid. The cost is that
// macOS keeps its own three-finger gestures, and a user who wants emira's turns the system's off in
// System Settings → Trackpad. No new permission — Accessibility already covers this, and boot demands it.

/// `NSEventTypeGesture`, and **only** it. The sibling gesture types interleave into a three-finger
/// episode — a vertical swipe carries a little pinch, arriving as `magnify` (30) — and
/// `NSEvent(cgEvent:)` cannot bridge those: it logs `unrecognized type` and yields an event carrying no
/// touches, which reads as "the fingers left" and tears the episode down mid-swipe. The mask narrows it
/// and the callback checks the type again anyway.
///
/// File-scope rather than a static member for `hotkeySignature`'s reason: the C callback below cannot
/// form a function pointer from a closure naming `Self`.
private let gestureEventType: UInt32 = 29

/// One frame of contacts on the pad.
///
/// Positions are normalized pad units with `y` increasing toward the **top** of the pad — the opposite
/// way round from the core's top-left global space. Nothing here flips it: emira keeps the horizontal
/// axis alone, which runs the same way in both spaces, and the vertical term is only ever read as a
/// magnitude (`Gestures`' dominance test). A feature that took a *sign* off `y` would owe the flip.
public struct TouchSample: Sendable, Equatable {
    /// Every finger currently on the pad, in whatever order the frame reported them.
    public let contacts: [Point]
    /// When the tap saw it, on the machine's monotonic clock (seconds).
    public let time: Double

    public init(contacts: [Point], time: Double) {
        self.contacts = contacts
        self.time = time
    }

    /// The mean contact — the one point a swipe is measured on. `nil` for an empty frame.
    public var centre: Point? {
        guard !contacts.isEmpty else { return nil }
        let sum = contacts.reduce(Point(x: 0, y: 0)) { Point(x: $0.x + $1.x, y: $0.y + $1.y) }
        return Point(x: sum.x / Double(contacts.count), y: sum.y / Double(contacts.count))
    }
}

/// The system's touch stream, narrowed to the two things we do with it. Implemented for real by
/// `CGGestureTap`; tests supply a double and drive `Gestures` from an array of samples.
///
/// Implementers: `install` returning `false` is a normal outcome (nothing to listen with), not an
/// error. Samples are delivered on the main actor, and `remove` is idempotent.
@MainActor
public protocol GestureTapper: AnyObject {
    /// Begin delivering contact frames. `false` if the system would not give us a tap at all.
    func install(_ onSample: @escaping @MainActor (TouchSample) -> Void) -> Bool

    func remove()
}

/// A session-level `CGEventTap` on `NSEventTypeGesture`, bridged through `NSEvent.allTouches()`.
@MainActor
public final class CGGestureTap: GestureTapper {

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var onSample: (@MainActor (TouchSample) -> Void)?

    public init() {}

    public func install(_ onSample: @escaping @MainActor (TouchSample) -> Void) -> Bool {
        self.onSample = onSample
        guard tap == nil else { return true }

        let mask: CGEventMask = (1 as CGEventMask) << CGEventMask(gestureEventType)
        // The callback is a C function pointer and captures nothing, so `self` travels through
        // `userInfo` unretained — `axObserverCallback`'s pattern, unretained for its reason: this
        // object owns the tap, and retaining it here would be a cycle.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<CGGestureTap>.fromOpaque(context).takeUnretainedValue()
                // A tap the window server disables is reported *to the callback*, not through any
                // other channel, and re-enabling is the only way it ever fires again.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { tap.reenable() }
                    return Unmanaged.passUnretained(event)
                }
                // `allTouches()` raises on a non-touch event and AppKit swallows the exception
                // mid-dispatch — the handler simply stops half-run, with no crash and no log. So the
                // type is the guard, rather than a `nil` or an empty set anyone could trust.
                guard type.rawValue == gestureEventType,
                      let bridged = NSEvent(cgEvent: event) else {
                    return Unmanaged.passUnretained(event)
                }
                MainActor.assumeIsolated { tap.deliver(bridged) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            self.onSample = nil
            return false
        }

        self.tap = tap
        // The **main** run loop, so delivery lands on the main actor like every other source here.
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func remove() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.source = nil
        self.tap = nil
        onSample = nil
    }

    /// Take the tap back up after the window server disabled it, and report the pad as empty — the
    /// samples that would have closed an open episode are exactly the ones that were dropped, so the
    /// recognizer must be told the fingers are gone rather than left holding a live gesture.
    private func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        onSample?(TouchSample(contacts: [], time: CACurrentMediaTime()))
    }

    private func deliver(_ event: NSEvent) {
        // Ended and cancelled contacts are fingers that have left; the pad reports them one frame more.
        let touching = event.allTouches().filter { $0.phase != .ended && $0.phase != .cancelled }
        onSample?(TouchSample(
            contacts: touching.map { Point(x: Double($0.normalizedPosition.x),
                                           y: Double($0.normalizedPosition.y)) },
            time: CACurrentMediaTime()))
    }
}
