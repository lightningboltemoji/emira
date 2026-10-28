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
    /// Answer whether anything but our own windows sits above `window` and overlaps `frame` — or is one
    /// of `others`, wherever it stands — exactly once. `false` for a window the registry no longer
    /// knows, and for a read that failed.
    func isCovered(_ window: WindowId, within frame: Rect, orBy others: Set<WindowId>,
                   then: @escaping @MainActor (Bool) -> Void)

    /// The managed windows drawn over each of `windows` where they overlap it, front first — one reading
    /// for all of them. A window the reading does not show is left out; `nil` for a read that failed.
    func windowsOver(_ windows: Set<WindowId>,
                     then: @escaping @MainActor ([WindowId: [WindowId]]?) -> Void)
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

    public func isCovered(_ window: WindowId, within frame: Rect, orBy others: Set<WindowId>,
                          then: @escaping @MainActor (Bool) -> Void) {
        guard let number = registry.record(window)?.number else { return then(false) }
        // A window the registry has lost cannot be above anything any more, so it drops out here.
        let named = Set(others.compactMap { registry.record($0)?.number })
        let mine = ProcessInfo.processInfo.processIdentifier
        inspector.async {
            let covered = Self.isCovered(number, within: frame, orBy: named, ignoring: mine)
            Task { @MainActor in then(covered) }
        }
    }

    public func windowsOver(_ windows: Set<WindowId>,
                            then: @escaping @MainActor ([WindowId: [WindowId]]?) -> Void) {
        let numbers = Dictionary(windows.compactMap { id in registry.record(id).map { ($0.number, id) } },
                                 uniquingKeysWith: { first, _ in first })
        guard !numbers.isEmpty else { return then([:]) }
        let targets = Set(numbers.keys)
        let mine = ProcessInfo.processInfo.processIdentifier
        let registry = registry
        inspector.async {
            let read = Self.onScreen(ignoring: mine).map { Self.over(targets, in: $0) }
            Task { @MainActor in
                guard let read else { return then(nil) }
                // Named on the main actor, where the registry is: a window it does not manage is nothing
                // the core can rank, so it drops out here.
                then(Dictionary(uniqueKeysWithValues: read.compactMap { number, over in
                    numbers[number].map { ($0, over.compactMap { registry.id(forNumber: $0) }) }
                }))
            }
        }
    }

    /// Every window on the glass but ours, front first — the order `optionAll` does not keep.
    nonisolated static func onScreen(ignoring mine: pid_t) -> [WindowListEntry]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return raw.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != mine,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return WindowListEntry(number: number, pid: pid,
                                   frame: Rect(x: Double(rect.minX), y: Double(rect.minY),
                                               width: Double(rect.width), height: Double(rect.height)),
                                   alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    /// For each of `targets` on the glass, the drawn windows in front of it that overlap it, front first.
    /// `list` is front first, which is what makes "in front" an index comparison.
    nonisolated static func over(_ targets: Set<CGWindowID>,
                                 in list: [WindowListEntry]) -> [CGWindowID: [CGWindowID]] {
        var over: [CGWindowID: [CGWindowID]] = [:]
        var above: [WindowListEntry] = []
        for entry in list where entry.isDrawn {
            if targets.contains(entry.number) {
                over[entry.number] = above.filter { $0.frame.intersects(entry.frame) }.map(\.number)
            }
            above.append(entry)
        }
        return over
    }

    /// The pure read. `optionOnScreenAboveWindow` is the whole question — everything the window server
    /// is drawing in front of this one — narrowed to ordinary windows (`kCGWindowLayer == 0`, which
    /// drops the Dock and the menu bar) and to windows that are not ours, since the hoist's own panel,
    /// the cover and the guides are all above it by construction.
    nonisolated static func isCovered(_ number: CGWindowID, within frame: Rect,
                                      orBy named: Set<CGWindowID>, ignoring mine: pid_t) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenAboveWindow, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, number) as? [[String: Any]] else {
            return false
        }
        return raw.contains { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  info[kCGWindowOwnerPID as String] as? pid_t != mine
            else { return false }
            if let above = info[kCGWindowNumber as String] as? CGWindowID, named.contains(above) {
                return true
            }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return false }
            return Rect(x: Double(rect.minX), y: Double(rect.minY),
                        width: Double(rect.width), height: Double(rect.height)).intersects(frame)
        }
    }
}
