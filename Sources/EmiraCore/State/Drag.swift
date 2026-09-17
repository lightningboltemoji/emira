import Foundation

/// What a mouse button being down means for the frame changes arriving under it.
///
/// **Not `World`'s, for the reason `Pointer` is not either: nothing observes this.** A window's frame
/// is refreshed by observation; *who moved it* is not reported by anything. AX says a window resized,
/// never that a user dragged it, and our own writes provoke the identical notification — so a frame
/// change is evidence only while something says the user's hand was on it.
///
/// The subject is what makes that evidence usable. During a drag the reals are left alone, but a
/// placement pass triggered by anything else still writes the strip, and an app clamping one of those
/// writes reports a frame change with the button still down. Latching the *first* window to move keeps
/// a stackmate's clamp from being read as a second resize.
///
/// A hand draws a size while the button is **down**, so that — and not the wait for the window to go
/// quiet after the release — is the interval a subject may be latched in.
public enum Drag: Sendable, Equatable, Codable {
    /// No button is down, or one came up having moved nothing. Every frame change is somebody else's —
    /// our own write echoing back, an app clamping one, or an app placing itself — and none of it is
    /// intent. The last of those is still answered, once the window stops (`Event.windowSelfPlaced`).
    case idle

    /// A button is down and nothing managed has moved under it yet. Arming costs nothing: a click that
    /// moves no window ends here and goes back to `idle` on the release.
    case armed

    /// A button is down and this window has moved under it, tiled or not — the one window a release may
    /// read an intent from, and the one every veil is lifted for (`State.scrimBindings`).
    case subject(WindowId)

    /// The window in the user's hand, or `nil`.
    public var subject: WindowId? {
        guard case .subject(let id) = self else { return nil }
        return id
    }

    /// Whether a frame change arriving now may latch the subject. False once a subject is
    /// latched — the second window to move under one press is being pushed, not dragged — and false
    /// again the moment the button comes up.
    public var isArmed: Bool { self == .armed }
}
