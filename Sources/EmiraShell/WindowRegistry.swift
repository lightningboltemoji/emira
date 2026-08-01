import CoreGraphics
import EmiraCore
import Foundation

// Window identity, reconstructed from two public lists rather than the private `_AXUIElementGetWindow`:
// AX knows the element, title, subrole and frame but not the window number; `CGWindowListCopyWindowInfo`
// knows the number, owner pid and frame but hands out no AX element and (without Screen Recording) no
// title. The join is the frame and is made exactly once per window; afterwards we key on the
// `CGWindowID`. Parked windows get unique sliver slots partly to keep frames distinct. A match must be
// unique or it is not a match — a mis-bind is permanent and invisible, where an unmanaged window is
// visible and recoverable.
//
// **A native tab group is one window, and which tab is showing is not identity** (decided 2026-07-27).
// macOS tabs are real `NSWindow`s, but `kAXWindowsAttribute` lists only the *selected* one — so AX
// already answers the question the way emira wants it answered. What it does not do is announce the
// swap: selecting a never-shown tab posts `AXWindowCreated` for a window that already existed, and the
// tab it replaces is never destroyed. Left alone that mints a column per tab and never retires one.
// `succeed(departed:arrived:)` is the second join that closes it — a managed window AX has stopped
// listing, paired with the window standing where it stood — and `rebind` moves the `WindowId` onto the
// new number and element. The core is never told: it holds one window for the group, so the column, its
// width, its workspace and its float state survive every tab switch.

// The two sides of the join

/// A window as the Accessibility API describes it, with the AX element factored out — the pure value the
/// identity join and the taxonomy work on.
public struct ObservedWindow: Sendable, Equatable {
    /// The owning process. Shell-side only: the core keys apps by `bundleId`.
    public let pid: pid_t
    /// The owning app's bundle identifier — the core's app-grouping key and what rules match on.
    public let bundleId: String
    /// The title at first sight. Recorded and displayed; never used for identity.
    public let title: String
    /// The tiling role, already classified from the AX role/subrole.
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
    /// The public, stable window number (`kCGWindowNumber`) — the same integer as `SCWindow.windowID`,
    /// so the capture plane reuses these bindings unchanged.
    public let number: CGWindowID
    /// The owning process, used to narrow the join before frames are compared.
    public let pid: pid_t
    /// The window's bounds in core (top-left, global) coordinates — the same space AX reports.
    public let frame: Rect
    /// Whether the window server considers this window on screen (`kCGWindowIsOnscreen`). A third piece
    /// of evidence: an app can carry two layer-0 entries with byte-identical bounds, only one of them
    /// live.
    public let isOnScreen: Bool

    public init(number: CGWindowID, pid: pid_t, frame: Rect, isOnScreen: Bool = true) {
        self.number = number
        self.pid = pid
        self.frame = frame
        self.isOnScreen = isOnScreen
    }

    /// The current window list, ordinary application windows only.
    ///
    /// `.optionAll` rather than `.optionOnScreenOnly` because a minimized window still needs an identity
    /// and is by definition not on screen; `.excludeDesktopElements` plus `kCGWindowLayer == 0` drops the
    /// desktop, Dock and menu bar, leaving the set AX also describes. Needs no Screen Recording grant —
    /// only `kCGWindowName` is gated, and titles come from AX instead.
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

// The join (pure)

/// The first-sight match between AX-observed windows and public window numbers. Pure and total: two
/// lists of values in, which ones paired up and why the rest didn't out.
public enum WindowIdentity {

    /// A successful pairing. `observed` is an index into the input array, so the caller can carry the
    /// un-`Equatable` AX element alongside without it entering this calculation.
    public struct Match: Sendable, Equatable {
        public let observed: Int
        public let number: CGWindowID

        public init(observed: Int, number: CGWindowID) {
            self.observed = observed
            self.number = number
        }
    }

    /// A window we declined to bind, and why — which the daemon logs, because "emira is not managing
    /// that window" must never be silent.
    public struct Rejection: Sendable, Equatable {
        public let observed: Int
        public let reason: Reason

        public enum Reason: String, Sendable, Equatable {
            /// No window-list entry for this pid sits at this frame — usually the window moved between
            /// the two reads, occasionally the app reports a frame that isn't where it draws.
            case noCandidate
            /// Several entries match equally well; binding to either would be a permanent coin flip.
            case ambiguous
            /// Two AX windows matched the *same* entry uniquely. One is right, nothing here can say
            /// which, so neither binds.
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
    /// - Parameter tolerance: per-edge slack in points. Small on purpose — it absorbs rounding between
    ///   two subsystems describing one rectangle; widen it and adjacent windows match each other.
    ///
    /// Two passes, because uniqueness has two directions: each observed window must see exactly one
    /// candidate, and no two observed windows may land on the same entry (which happens when a window's
    /// own entry is missing from the list and it falls onto its neighbour's).
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
            // Owner and frame are not always enough: Safari in native full screen carries two layer-0
            // entries with byte-identical bounds, only one of them on screen. Consulted only after the
            // first two facts fail to separate candidates, so an unambiguous off-screen match (minimized,
            // or on another Space) still binds.
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

    // Succession (the tab join)

    /// A managed window AX has stopped listing.
    public struct Departure: Sendable, Equatable {
        public let id: WindowId
        public let pid: pid_t
        /// The last frame the shell recorded for it. For a tab group this is the *group's* frame:
        /// background tabs are never placed on their own, so every member reports where the group sits.
        public let frame: Rect

        public init(id: WindowId, pid: pid_t, frame: Rect) {
            self.id = id
            self.pid = pid
            self.frame = frame
        }
    }

    /// A departure and the window that took its place.
    public struct Succession: Sendable, Equatable {
        public let departed: WindowId
        /// Index into the `arrived` array — the same convention `Match.observed` uses, and for the same
        /// reason: it keeps un-`Equatable` AX elements out of this calculation.
        public let arrived: Int

        public init(departed: WindowId, arrived: Int) {
            self.departed = departed
            self.arrived = arrived
        }
    }

    /// Pair each departed window with the arriving window standing where it stood.
    ///
    /// The signal is the frame, exactly as in `bind`: a tab that becomes selected takes the group's
    /// geometry, so the newcomer is sitting on the departed tab's last known rectangle. That covers all
    /// three ways a tab group changes which window it shows — a switch, a `⌘T`, and closing the selected
    /// tab (where the departed element is already dead and no other evidence survives it).
    ///
    /// Deliberately *only* the frame. "Exactly one window left and one arrived, so they must be the same
    /// one" is tempting and wrong: an app that closes one window while opening another looks identical,
    /// and the cost of believing it is a window inheriting a stranger's column, permanently and
    /// invisibly. Uniqueness is required in both directions for the same reason `bind` requires it.
    ///
    /// - Returns: the pairings, and the departures with no successor — windows that have left the strip
    ///   for good (merged into someone else's tab group, or closed without a destroy notification).
    public static func succeed(departed: [Departure], arrived: [ObservedWindow],
                               tolerance: Double = 2) -> (successions: [Succession],
                                                          orphaned: [WindowId]) {
        var tentative: [Int: Int] = [:]         // departure index → arrival index
        var claimants: [Int: [Int]] = [:]       // arrival index → departure indices
        var orphaned: [WindowId] = []

        for (index, departure) in departed.enumerated() {
            let candidates = arrived.indices.filter {
                arrived[$0].pid == departure.pid
                    && sameFrame(arrived[$0].frame, departure.frame, tolerance: tolerance)
            }
            guard candidates.count == 1 else {
                orphaned.append(departure.id)
                continue
            }
            tentative[index] = candidates[0]
            claimants[candidates[0], default: []].append(index)
        }

        for (_, indices) in claimants where indices.count > 1 {
            for index in indices {
                tentative[index] = nil
                orphaned.append(departed[index].id)
            }
        }

        let successions = tentative
            .map { Succession(departed: departed[$0.key].id, arrived: $0.value) }
            .sorted { $0.departed < $1.departed }
        return (successions, orphaned.sorted())
    }

    /// Whether two rectangles describe the same window, within per-edge slack.
    private static func sameFrame(_ a: Rect, _ b: Rect, tolerance: Double) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

/// Mints `WindowId`s and holds the shell-private binding behind each one: the public window number, the
/// owning process, and the live AX element to write to. The only place a `WindowId` becomes a thing you
/// can act on, which is what keeps `EmiraCore` free of `AXUIElement`, `CGWindowID` and pid.
@MainActor
public final class WindowRegistry {

    /// What the shell knows about one managed window. `element` is deliberately not `public`: outside
    /// this module a `WindowId` is the only handle there is.
    public struct Record: Sendable {
        /// The core-facing opaque id.
        public let id: WindowId
        /// The public window number this id is bound to. Stable for the window's life, and re-pointed
        /// exactly once per tab switch (`rebind`), because a tab group's identity is the group.
        public let number: CGWindowID
        /// The owning process — the AX serial-queue key.
        public let pid: pid_t
        /// The owning app's bundle identifier.
        public let bundleId: String
        /// The AX element to read and write. Refreshed on re-enumeration: elements go stale while the
        /// window number does not, which is why identity keys on the number.
        var element: AXWindow
        /// The last frame the shell saw this window at. Not truth — `World` holds that — but the
        /// evidence `succeed(departed:arrived:)` needs about a window AX has stopped describing.
        var frame: Rect

        init(id: WindowId, number: CGWindowID, pid: pid_t, bundleId: String, element: AXWindow,
             frame: Rect) {
            self.id = id
            self.number = number
            self.pid = pid
            self.bundleId = bundleId
            self.element = element
            self.frame = frame
        }
    }

    /// The id counter. Monotonic and never reused — a recycled id would let a stale `Effect` land on a
    /// different window than the reducer meant.
    private var nextRaw: UInt64 = 1
    /// The permanent binding, window number → id. The map that makes re-enumeration idempotent.
    private var idByNumber: [CGWindowID: WindowId] = [:]
    /// The observers' lookup, AX element → id: a notification arrives carrying an element and nothing
    /// else. Not a second identity — derived state, written and cleared in lock-step with `records`.
    private var idByElement: [AXWindow: WindowId] = [:]
    /// Everything known about each managed window.
    private var records: [WindowId: Record] = [:]

    public init() {}

    /// Take a bound window into management and return the `WindowSnapshot` the core is told about, or
    /// `nil` if the bind contradicts one we already hold.
    ///
    /// Idempotent by window number: a re-enumeration reuses the id and refreshes the AX element, so the
    /// resulting `windowCreated` events are last-writer-wins updates and nothing on the strip duplicates.
    ///
    /// A contradiction is refused, not resolved. An element already bound to a *different* number means
    /// the join matched a stale AX frame onto a newer window's list entry; minting anyway would strand a
    /// column with no window behind it and redirect the old window's notifications to the wrong id.
    @discardableResult
    public func adopt(_ observed: ObservedWindow, element: AXWindow,
                      number: CGWindowID) -> WindowSnapshot? {
        if let existing = idByElement[element], records[existing]?.number != number { return nil }
        let id: WindowId
        if let existing = idByNumber[number] {
            id = existing
        } else {
            id = WindowId(nextRaw)
            nextRaw += 1
            idByNumber[number] = id
        }
        // A re-scan's fresh element normally compares equal to the old one, so this is a no-op — but an
        // app handing back an unequal element would leave a stale key pointing at a live id, resolving
        // every notification about the window to the wrong one.
        if let previous = records[id]?.element, previous != element { idByElement[previous] = nil }
        idByElement[element] = id
        records[id] = Record(id: id, number: number, pid: observed.pid,
                             bundleId: observed.bundleId, element: element, frame: observed.frame)
        return WindowSnapshot(
            id: id, bundleId: observed.bundleId, title: observed.title,
            role: observed.role, frame: observed.frame, isMinimized: observed.isMinimized)
    }

    /// Move an existing id onto the window that succeeded it — the tab group selecting a different tab.
    ///
    /// The *only* thing in emira that re-points a binding, and the reason `Record.number` is no longer
    /// "for life": a tab group's members are interchangeable stand-ins for one thing on the strip, so
    /// keeping the id is what makes a tab switch invisible to the core. Everything derived from the old
    /// window goes with it — the number the capture plane films, and the element the write path sets
    /// frames on, which matters more than it looks: a *background* tab accepts geometry writes and
    /// applies them to itself alone, so a stale element is placement landing on an invisible window.
    ///
    /// Refused, like `adopt`, when the new number already belongs to someone else — that would strand
    /// two ids on one window.
    @discardableResult
    public func rebind(_ id: WindowId, to number: CGWindowID, observed: ObservedWindow,
                       element: AXWindow) -> Bool {
        guard let old = records[id] else { return false }
        if let holder = idByNumber[number], holder != id { return false }
        if let holder = idByElement[element], holder != id { return false }

        idByNumber[old.number] = nil
        idByElement[old.element] = nil
        idByNumber[number] = id
        idByElement[element] = id
        records[id] = Record(id: id, number: number, pid: observed.pid,
                             bundleId: observed.bundleId, element: element, frame: observed.frame)
        return true
    }

    /// The record behind an id, or `nil` if it is unknown or has been forgotten.
    public func record(_ id: WindowId) -> Record? { records[id] }

    /// Every managed window belonging to one of `pids`, in id order.
    public func records(ofApps pids: Set<pid_t>) -> [Record] {
        records.values.filter { pids.contains($0.pid) }.sorted { $0.id < $1.id }
    }

    /// Record where a window has got to, so a later succession has something to match against. Cheap
    /// and lossy on purpose: this is corroboration for the tab join, never a second copy of `World`.
    public func noteFrame(_ id: WindowId, _ frame: Rect) {
        records[id]?.frame = frame
    }

    /// The AX element to act on for an id. `AXExecutor` goes through `record(_:)` instead (it needs the
    /// pid too, to pick the lane); this is the direct form for callers that already know the app.
    public func element(for id: WindowId) -> AXWindow? { records[id]?.element }

    /// The id bound to a window number, if we have seen it.
    public func id(forNumber number: CGWindowID) -> WindowId? { idByNumber[number] }

    /// The id behind an AX element — how an observer callback becomes an `Event`. `nil` means "not a
    /// window emira manages", a normal answer rather than an error.
    func id(for element: AXWindow) -> WindowId? { idByElement[element] }

    /// Drop one window (it closed).
    ///
    /// The number → id entry goes too: the window server *does* reuse a `CGWindowID` after a window is
    /// destroyed, so a stale mapping would eventually hand a dead window's id to a live one.
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
