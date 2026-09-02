import CoreGraphics
import Foundation
import EmiraCore

// *Is this window still buried?* — asked of the window server, because nothing else can answer it.
//
// A hoist comes down when `Event.focusChanged` says the float is in front, and that report is an **AX
// notification**: it says the app told us its focus moved, not that the raise has reached the glass. The
// two are far enough apart to see, so releasing on the report alone cuts the picture away over a window
// that is still behind — the flash `HoistPanels` fences against.
//
// The read is the same family as `Overlay.confirmPublished` and is off the main thread for its reason:
// what is being waited out is another app's activation, and its length is not ours to block for.
// Unreadable is not "still covered" — the answer is gone rather than negative, and holding a picture up
// forever on a failed read is worse than the frame it would save.

/// Whether the window server shows a foreign window over one of ours.
@MainActor
public protocol StackProbe: AnyObject {
    /// Answer whether anything but our own windows sits above `window` and overlaps `frame`, exactly
    /// once. `false` for a window the registry no longer knows, and for a read that failed.
    func isCovered(_ window: WindowId, within frame: Rect,
                   then: @escaping @MainActor (Bool) -> Void)
}

/// The real one: `CGWindowListCopyWindowInfo`, off the main thread.
@MainActor
public final class CGStackProbe: StackProbe {

    private let registry: WindowRegistry
    /// Serial, and its own: the call can block for as long as another app's animation runs, and two
    /// answers about one desktop have no reason to overlap.
    private let inspector = DispatchQueue(label: "xyz.emira.hoist.stack", qos: .userInitiated)

    public init(registry: WindowRegistry) {
        self.registry = registry
    }

    public func isCovered(_ window: WindowId, within frame: Rect,
                          then: @escaping @MainActor (Bool) -> Void) {
        guard let number = registry.record(window)?.number else { return then(false) }
        let mine = ProcessInfo.processInfo.processIdentifier
        inspector.async {
            let covered = Self.isCovered(number, within: frame, ignoring: mine)
            Task { @MainActor in then(covered) }
        }
    }

    /// The pure read. `optionOnScreenAboveWindow` is the whole question — everything the window server
    /// is drawing in front of this one — narrowed to ordinary windows (`kCGWindowLayer == 0`, which
    /// drops the Dock and the menu bar) and to windows that are not ours, since the hoist's own panel,
    /// the cover and the guides are all above it by construction.
    nonisolated static func isCovered(_ number: CGWindowID, within frame: Rect,
                                      ignoring mine: pid_t) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenAboveWindow, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, number) as? [[String: Any]] else {
            return false
        }
        return raw.contains { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  info[kCGWindowOwnerPID as String] as? pid_t != mine,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return false }
            return Rect(x: Double(rect.minX), y: Double(rect.minY),
                        width: Double(rect.width), height: Double(rect.height)).intersects(frame)
        }
    }
}
