import ApplicationServices
import CoreGraphics
import Foundation

// The TCC grants emira needs, checked in one place. Neither needs SIP off.
//
// A precondition, not a detail: with Accessibility denied `AXUIElementCopyAttributeValue` does not fail
// loudly — it returns `.apiDisabled`/`.cannotComplete` for every app and enumeration comes back with
// zero windows and no error, so a window manager silently manages nothing.
//
// Screen Recording is only needed for the cover's pixels; `CGWindowListCopyWindowInfo`'s numbers, pids
// and bounds are unprivileged (only `kCGWindowName` is gated, and titles come from AX). Denied mid-
// session, `Config.smoothTransitions` goes false and scrolls snap rather than killing the daemon and
// stranding every parked window at its sliver. `emira-daemon` still requires both grants to *start* —
// which answer is fatal is its policy, not this file's.

/// The system permissions emira depends on, and the checks for them.
public enum Permissions {

    /// Whether a TCC grant is in place. Two-valued because "not yet granted" and "refused" are
    /// indistinguishable through the public API.
    public enum Grant: Sendable, Equatable {
        /// The grant is in place; AX calls against other processes will be answered.
        case granted
        /// Not granted. Every AX read returns nothing — treat as fatal for the truth plane.
        case denied

        /// Whether work depending on this grant can proceed.
        public var isGranted: Bool { self == .granted }
    }

    /// Whether this process currently holds the Accessibility grant. Computed, never cached: the answer
    /// changes *while the process runs* when the user flips the switch in System Settings.
    public static var accessibility: Grant {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// The option key that turns `AXIsProcessTrustedWithOptions` from a query into a prompt. Spelled out
    /// because the SDK exports `kAXTrustedCheckOptionPrompt` as a mutable C global, which Swift 6 refuses
    /// to read across concurrency domains.
    private static let promptOption = "AXTrustedCheckOptionPrompt"

    /// Check the Accessibility grant, showing the standard "…would like to control this computer" prompt
    /// if it is missing.
    ///
    /// Returns the grant as it stands *now*, which after a prompt is virtually always `.denied` — the
    /// sheet is asynchronous and the user has to visit System Settings. macOS 26 needs no relaunch after
    /// the toggle, so a daemon that exits here is restartable by hand.
    @discardableResult
    public static func requestAccessibility() -> Grant {
        AXIsProcessTrustedWithOptions([promptOption: true] as CFDictionary) ? .granted : .denied
    }

    /// Whether this process currently holds the Screen Recording grant — what `CaptureService` needs to
    /// build a cover out of real pixels.
    ///
    /// Computed, never cached: macOS periodically re-prompts users to keep allowing screen capture, so
    /// this can flip to `.denied` in a running daemon with no user action at all, and a cached `true`
    /// means transitions that cover the screen with nothing. `CGPreflightScreenCaptureAccess` asks
    /// without prompting.
    public static var screenRecording: Grant {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Check the Screen Recording grant, prompting if it is missing. As with `requestAccessibility`, the
    /// honest return immediately after a prompt is `.denied`.
    @discardableResult
    public static func requestScreenRecording() -> Grant {
        CGRequestScreenCaptureAccess() ? .granted : .denied
    }
}
