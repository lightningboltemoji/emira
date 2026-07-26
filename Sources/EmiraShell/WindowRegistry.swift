import CoreGraphics
import EmiraCore
import Foundation

// **Window identity — the shell's single hardest job, and the one the charter constrains most.**
//
// The core addresses windows by an opaque `WindowId` it never interprets (`Ids.swift`). Something has
// to decide that *this* `AXUIElement` and *that* window on screen are the same window, and to keep
// deciding it correctly for as long as the daemon runs. yabai answers this with the private
// `_AXUIElementGetWindow`, which returns a `CGWindowID` straight out of an AX element. We have
// chartered ourselves out of that (PRINCIPLES.md §10: "no private AX SPI … window identity via
// first-sight binding → public `CGWindowID`"), so we reconstruct the same association from two public
// lists that overlap:
//
//  · **AX** knows the element, the title, the subrole, and the frame — but not the window number.
//  · **`CGWindowListCopyWindowInfo`** knows the window number, the owner pid, and the frame — but
//    hands out no AX element and (without Screen Recording) no title.
//
// **The join is the frame, and it is made exactly once per window.** Two windows of the same app
// occupying the same rectangle to the point is not a thing macOS produces; even emira's own parked
// windows are given *unique* sliver slots specifically so this stays true (PRINCIPLES.md §4a). After
// the join we key on the `CGWindowID` forever — it is stable for the window's whole life, immune to
// the title churn and frame collisions that would break a match made later. That is the whole of §7's
// "bound once, at first sight."
//
// **A match must be unique or it is not a match.** The spikes matched by *nearest* position
// (`spike/strip-scroll.swift:97`) because they only needed *a* window to play with, and nearest always
// answers. Here a wrong answer is permanent — emira would move one window whenever the user asked for
// another, forever — so `WindowIdentity` requires exactly one candidate within tolerance and rejects
// anything else. A rejected window is simply not managed, which is a visible, recoverable failure; a
// mis-bound window is an invisible, permanent one.

// MARK: - The two sides of the join

/// A window as the Accessibility API describes it, with the AX element factored out — the pure value
/// the identity join and the taxonomy work on, and the reason both are testable with no macOS running.
public struct ObservedWindow: Sendable, Equatable {
    /// The owning process. Shell-side only: the core keys apps by `bundleId` (`World.swift`).
    public let pid: pid_t
    /// The owning app's bundle identifier — the core's app-grouping key and what rules match on.
    public let bundleId: String
    /// The title at first sight. Recorded and displayed; never used for identity (§7).
    public let title: String
    /// The tiling role, already classified from the AX role/subrole (`WindowRole.init(axRole:…)`).
    public let role: WindowRole
    /// The frame in core (top-left, global) coordinates. AX reports this space natively — no flip.
    public let frame: Rect
    /// Whether the window is currently in the Dock.
    public let isMinimized: Bool

    public init(pid: pid_t, bundleId: String, title: String, role: WindowRole,
                frame: Rect, isMinimized: Bool) {
        self.pid = pid
        self.bundleId = bundleId
        self.title = title
        self.role = role
        self.frame = frame
        self.isMinimized = isMinimized
    }
}

/// One entry from the public window list — the `CGWindowID` authority side of the join.
public struct WindowListEntry: Sendable, Equatable {
    /// The public, stable window number (`kCGWindowNumber`). The same integer ScreenCaptureKit calls
    /// `SCWindow.windowID`, which is what lets M4's capture reuse these bindings unchanged.
    public let number: CGWindowID
    /// The owning process, used to narrow the join before frames are compared.
    public let pid: pid_t
    /// The window's bounds in core (top-left, global) coordinates — the same space AX reports.
    public let frame: Rect
    /// Whether the window server currently considers this window on screen (`kCGWindowIsOnscreen`).
    ///
    /// The third piece of evidence, and the one that unsticks a real duplicate: an app can carry two
    /// layer-0 entries with byte-identical bounds, of which only one is live. See `WindowIdentity.bind`.
    public let isOnScreen: Bool

    public init(number: CGWindowID, pid: pid_t, frame: Rect, isOnScreen: Bool = true) {
        self.number = number
        self.pid = pid
        self.frame = frame
        self.isOnScreen = isOnScreen
    }

    /// The current window list, ordinary application windows only.
    ///
    /// `.optionAll` rather than `.optionOnScreenOnly` because a **minimized** window still needs an
    /// identity — it is truth the core records even though it sits off the strip (2026-07-23) — and it
    /// is by definition not on screen. `.excludeDesktopElements` plus the `kCGWindowLayer == 0` filter
    /// drops the desktop picture, the Dock, the menu bar and every other system layer, leaving exactly
    /// the set AX also describes.
    ///
    /// Needs **no** Screen Recording grant: numbers, pids, bounds and layers are unprivileged. Only
    /// `kCGWindowName` is gated, and we never read it — titles come from AX.
    public static func current() -> [WindowListEntry] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return WindowListEntry(
                number: number, pid: pid,
                frame: Rect(x: Double(rect.minX), y: Double(rect.minY),
                            width: Double(rect.width), height: Double(rect.height)),
                isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }
}

// MARK: - The join (pure)

/// The first-sight match between AX-observed windows and public window numbers. Pure and total: it
/// takes two lists of values and returns which ones paired up and why the rest didn't.
public enum WindowIdentity {

    /// A successful pairing. `observed` is an index into the input array rather than the value itself,
    /// so the caller can carry the un-`Equatable` AX element alongside without it entering this
    /// calculation.
    public struct Match: Sendable, Equatable {
        public let observed: Int
        public let number: CGWindowID

        public init(observed: Int, number: CGWindowID) {
            self.observed = observed
            self.number = number
        }
    }

    /// A window we declined to bind, and the reason — which the daemon logs, because "emira is not
    /// managing that window" must never be silent.
    public struct Rejection: Sendable, Equatable {
        public let observed: Int
        public let reason: Reason

        public enum Reason: String, Sendable, Equatable {
            /// No window-list entry for this pid sits at this frame. The window list and the AX read
            /// disagree — normally because the window moved between the two, occasionally because the
            /// app reports a frame that isn't where it draws.
            case noCandidate
            /// Several entries match equally well. Binding to either would be a coin flip, and the
            /// wrong side of that flip is permanent.
            case ambiguous
            /// Two AX windows both matched the *same* entry uniquely. Exactly one of them is right and
            /// nothing here can say which, so neither is bound.
            case contested
        }

        public init(observed: Int, reason: Reason) {
            self.observed = observed
            self.reason = reason
        }
    }

    /// The outcome of one join.
    public struct Binding: Sendable, Equatable {
        /// The pairings, in input order.
        public let matches: [Match]
        /// The windows left unbound, in input order.
        public let rejections: [Rejection]

        public init(matches: [Match], rejections: [Rejection]) {
            self.matches = matches
            self.rejections = rejections
        }
    }

    /// Pair each observed window with the one window-list entry that has the same owner and frame.
    ///
    /// - Parameter tolerance: per-edge slack, in points, when comparing frames. Small on purpose: this
    ///   absorbs rounding between two subsystems describing the same rectangle, and nothing more. Widen
    ///   it and adjacent windows start matching each other's entries.
    ///
    /// Two passes, because uniqueness has two directions and only checking one of them leaves the
    /// interesting bug. First: each observed window must see exactly one candidate. Second: no two
    /// observed windows may have landed on the same entry — which *can* happen when one window's own
    /// entry is missing from the list (it closed mid-scan, say) and it falls onto its neighbour's.
    public static func bind(_ observed: [ObservedWindow], to entries: [WindowListEntry],
                            tolerance: Double = 2) -> Binding {
        var byPid: [pid_t: [WindowListEntry]] = [:]
        for entry in entries { byPid[entry.pid, default: []].append(entry) }

        var tentative: [Int: CGWindowID] = [:]
        var rejections: [Rejection] = []
        var claimants: [CGWindowID: [Int]] = [:]

        for (index, window) in observed.enumerated() {
            var candidates = (byPid[window.pid] ?? []).filter {
                sameFrame($0.frame, window.frame, tolerance: tolerance)
            }
            // Owner and frame are not always enough, in the wild. Safari (in native full screen)
            // carries **two** layer-0 window-list entries with byte-identical bounds, only one of
            // which the window server considers on screen — found the first time this ran against a
            // real desktop, where it made the only real window unbindable.
            //
            // Narrowing on `isOnScreen` is not a tie-break dressed up as evidence: an entry the window
            // server says is not on screen cannot be the window AX just described as visible. It is a
            // *third* fact, and it is only consulted when the first two have already failed to
            // separate the candidates — so an unambiguous off-screen match (a minimized window, or one
            // on another Space) still binds exactly as before.
            if candidates.count > 1 {
                let live = candidates.filter(\.isOnScreen)
                if live.count == 1 { candidates = live }
            }
            switch candidates.count {
            case 1:
                tentative[index] = candidates[0].number
                claimants[candidates[0].number, default: []].append(index)
            case 0:
                rejections.append(Rejection(observed: index, reason: .noCandidate))
            default:
                rejections.append(Rejection(observed: index, reason: .ambiguous))
            }
        }

        for indices in claimants.values where indices.count > 1 {
            for index in indices {
                tentative[index] = nil
                rejections.append(Rejection(observed: index, reason: .contested))
            }
        }

        let matches = tentative
            .map { Match(observed: $0.key, number: $0.value) }
            .sorted { $0.observed < $1.observed }
        return Binding(matches: matches, rejections: rejections.sorted { $0.observed < $1.observed })
    }

    /// Whether two rectangles describe the same window, within per-edge slack.
    private static func sameFrame(_ a: Rect, _ b: Rect, tolerance: Double) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

// MARK: - The registry

/// Mints `WindowId`s and holds the shell-private binding behind each one: the public window number, the
/// owning process, and the live AX element to write to.
///
/// It is the *only* place in emira where a `WindowId` becomes a thing you can act on, which is what
/// keeps `EmiraCore` free of `AXUIElement`, `CGWindowID` and pid (IMPLEMENTATION.md §7).
///
/// `@MainActor` like everything else holding mutable state: it is written during enumeration and by the
/// observers, and read by the AX executor — all on the pump's thread (PRINCIPLES.md §7).
@MainActor
public final class WindowRegistry {

    /// What the shell knows about one managed window. `element` is deliberately not `public`: outside
    /// this module a `WindowId` is the only handle there is.
    public struct Record: Sendable {
        /// The core-facing opaque id.
        public let id: WindowId
        /// The public window number this id is bound to, for life.
        public let number: CGWindowID
        /// The owning process — the AX serial-queue key (`AXClient`).
        public let pid: pid_t
        /// The owning app's bundle identifier.
        public let bundleId: String
        /// The AX element to read and write. Refreshed on re-enumeration: elements can go stale while
        /// the window number does not, which is precisely why identity keys on the number.
        var element: AXWindow

        init(id: WindowId, number: CGWindowID, pid: pid_t, bundleId: String, element: AXWindow) {
            self.id = id
            self.number = number
            self.pid = pid
            self.bundleId = bundleId
            self.element = element
        }
    }

    /// The id counter. Monotonic and never reused — a recycled id would let a stale `Effect` land on a
    /// different window than the one the reducer meant.
    private var nextRaw: UInt64 = 1
    /// The permanent binding, window number → id. The map that makes re-enumeration idempotent.
    private var idByNumber: [CGWindowID: WindowId] = [:]
    /// The *observers'* lookup, AX element → id. Not a second identity — identity is the window number
    /// and only the window number (§7). This is the reverse of `Record.element`, kept because an AX
    /// notification arrives carrying an element and nothing else, and turning that back into a
    /// `WindowId` is the alternative to the private `_AXUIElementGetWindow` we have chartered ourselves
    /// out of. It is derived state: written and cleared in lock-step with `records`.
    private var idByElement: [AXWindow: WindowId] = [:]
    /// Everything known about each managed window.
    private var records: [WindowId: Record] = [:]

    public init() {}

    /// Take a bound window into management and return the `WindowSnapshot` the core is told about.
    ///
    /// **Idempotent by window number.** A second enumeration of a window we already know reuses its id
    /// and refreshes its AX element rather than minting a new one — so a re-scan produces
    /// `windowCreated` events the reducer already treats as last-writer-wins updates (`World.insert`),
    /// and nothing on the strip duplicates.
    @discardableResult
    public func adopt(_ observed: ObservedWindow, element: AXWindow, number: CGWindowID) -> WindowSnapshot {
        let id: WindowId
        if let existing = idByNumber[number] {
            id = existing
        } else {
            id = WindowId(nextRaw)
            nextRaw += 1
            idByNumber[number] = id
        }
        // A re-scan hands back a *fresh* element for a window we already know. It compares equal to the
        // old one (`AXWindow: Hashable`), so this is normally a no-op — but an app that hands out an
        // element which no longer compares equal would otherwise leave a stale key pointing at a live
        // id, and every notification about the window would resolve to the wrong one. Cheap to be exact.
        if let previous = records[id]?.element, previous != element { idByElement[previous] = nil }
        idByElement[element] = id
        records[id] = Record(id: id, number: number, pid: observed.pid,
                             bundleId: observed.bundleId, element: element)
        return WindowSnapshot(
            id: id, bundleId: observed.bundleId, title: observed.title,
            role: observed.role, frame: observed.frame, isMinimized: observed.isMinimized)
    }

    /// The record behind an id, or `nil` if it is unknown or has been forgotten.
    public func record(_ id: WindowId) -> Record? { records[id] }

    /// The AX element to act on for an id. `AXExecutor` reaches it through `record(_:)` (it needs the
    /// pid too, to pick the lane); this is the direct form for callers that already know the app.
    public func element(for id: WindowId) -> AXWindow? { records[id]?.element }

    /// The id bound to a window number, if we have seen it.
    public func id(forNumber number: CGWindowID) -> WindowId? { idByNumber[number] }

    /// The id behind an AX element — how an observer callback becomes an `Event`.
    ///
    /// `nil` means "not a window emira manages", which is a complete and normal answer: the user has
    /// windows we declined to bind, windows we classified as floating furniture, and windows belonging
    /// to apps we never scanned. An observation about one of those is not an error, it is silence.
    func id(for element: AXWindow) -> WindowId? { idByElement[element] }

    /// Drop one window (it closed).
    ///
    /// The number → id entry goes too. A `CGWindowID` *is* reused by the window server after a window
    /// is destroyed, so keeping the mapping would eventually hand a dead window's id to a live one —
    /// the one way this scheme could mis-bind, closed by forgetting promptly.
    public func forget(_ id: WindowId) {
        guard let record = records.removeValue(forKey: id) else { return }
        idByNumber[record.number] = nil
        idByElement[record.element] = nil
    }

    /// Drop every window of a process (the app quit) and return the ids, which the caller turns into
    /// `Event.windowDestroyed`s.
    @discardableResult
    public func forget(app pid: pid_t) -> [WindowId] {
        let doomed = records.values.filter { $0.pid == pid }.map(\.id).sorted()
        for id in doomed { forget(id) }
        return doomed
    }

    /// Every managed id, sorted — deterministic order for debug dumps and tests.
    public var ids: [WindowId] { records.keys.sorted() }

    /// How many windows are under management.
    public var count: Int { records.count }
}
