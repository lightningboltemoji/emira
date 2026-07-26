import ApplicationServices
import CoreGraphics
import Foundation

// The TCC grants emira needs, checked in one place (IMPLEMENTATION.md §5, `Permissions.swift`).
// Nothing here needs SIP off — both are ordinary user grants (PRINCIPLES.md §2, §6).
//
// **Why this is its own file even though it is four lines of API.** The grant is not a detail, it is a
// *precondition*: with Accessibility denied, `AXUIElementCopyAttributeValue` does not fail loudly — it
// returns `.apiDisabled`/`.cannotComplete` for every app, and enumeration comes back with **zero
// windows and no error**. A window manager that silently manages nothing is the worst possible failure
// mode, so the daemon checks *first* and says so. Keeping the check here rather than in
// `AXEnumerator` also means the M5 onboarding flow has one thing to call, and the enumerator stays a
// pure "ask AX, bind, report" pipeline with no policy in it.
//
// **Two grants, and only one of them is fatal.** Identity binding uses `CGWindowListCopyWindowInfo`
// (`WindowRegistry`), whose window *numbers*, owner pids and bounds are unprivileged; only
// `kCGWindowName` needs Screen Recording, and we take titles from AX instead. So the truth plane costs
// exactly one permission (M3's finding), and the second arrives with the feature that needs it —
// `CaptureService`, at M4. The asymmetry runs all the way through:
//
//  · **Accessibility denied ⇒ emira cannot work.** Nothing enumerates, nothing moves.
//  · **Screen Recording denied ⇒ emira works, without the cover.** The cover is made of captured
//    pixels; with no pixels the honest thing is not to raise one, so `Config.smoothTransitions` goes
//    false and every scroll snaps — PRINCIPLES.md §4a, which is the behaviour §4b is a *layer* on top
//    of, not a replacement for. The daemon says so at boot and keeps running.
//
// The prompts themselves are M5's onboarding; what lives here is the question and its two answers.

/// The system permissions emira depends on, and the checks for them.
public enum Permissions {

    /// Whether a TCC grant is in place. Deliberately two-valued: "not yet granted" and "refused" are
    /// indistinguishable through the public API (both are simply *not trusted*), and pretending
    /// otherwise would invent a state we cannot observe.
    public enum Grant: Sendable, Equatable {
        /// The grant is in place; AX calls against other processes will be answered.
        case granted
        /// Not granted. Every AX read returns nothing — treat as fatal for the truth plane.
        case denied

        /// Whether work depending on this grant can proceed.
        public var isGranted: Bool { self == .granted }
    }

    /// Whether this process currently holds the Accessibility grant.
    ///
    /// Cheap and re-readable: the answer changes *while the process runs* when the user flips the
    /// switch in System Settings, so this is a computed property, never a cached one.
    public static var accessibility: Grant {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Check the Accessibility grant, and if it is missing, ask the system to show the standard
    /// "…would like to control this computer" prompt.
    ///
    /// Returns the grant as it stands *now*, which — when the prompt was shown — is virtually always
    /// `.denied`: the sheet is asynchronous and the user has to visit System Settings, so the honest
    /// answer is "not yet". macOS 26 no longer requires a relaunch after the toggle, so a daemon that
    /// exits here is restartable by hand; the M5 onboarding flow polls `accessibility` instead of
    /// exiting.
    /// The option key that turns `AXIsProcessTrustedWithOptions` from a query into a prompt.
    ///
    /// Spelled out rather than using `kAXTrustedCheckOptionPrompt`: the SDK exports that constant as a
    /// mutable C global, which Swift 6 correctly refuses to let us read across concurrency domains. The
    /// literal is the same string and is the one thing about it that is guaranteed not to change.
    private static let promptOption = "AXTrustedCheckOptionPrompt"

    @discardableResult
    public static func requestAccessibility() -> Grant {
        AXIsProcessTrustedWithOptions([promptOption: true] as CFDictionary) ? .granted : .denied
    }

    /// Whether this process currently holds the Screen Recording grant — what `CaptureService` needs to
    /// build a cover out of real pixels.
    ///
    /// Computed, never cached, and for a sharper reason than Accessibility's: macOS **periodically
    /// re-prompts** users to keep allowing screen capture (PRINCIPLES.md §6), so this answer can go from
    /// `.granted` to `.denied` in a running daemon with no action by the user at all. A cached `true`
    /// would mean transitions that quietly cover the screen with nothing.
    ///
    /// `CGPreflightScreenCaptureAccess` asks *without* prompting, which is what a boot-time capability
    /// check wants: a window manager should not throw a permission sheet at someone who is trying to
    /// log in.
    public static var screenRecording: Grant {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Check the Screen Recording grant, prompting if it is missing.
    ///
    /// Like `requestAccessibility`, the honest return immediately after a prompt is `.denied` — the
    /// sheet is asynchronous and the grant needs a trip to System Settings.
    @discardableResult
    public static func requestScreenRecording() -> Grant {
        CGRequestScreenCaptureAccess() ? .granted : .denied
    }
}
