import Foundation

// Which workspaces each display holds, and which of them it is showing. The container beside
// `Workspaces`, joined to it by a `WorkspaceName` exactly as `World` (windows) and `Workspaces`
// (strips) are joined by a `WindowId` — so `Workspaces` never mentions a monitor and stays as pure as
// it is, while the *geometry* of a display stays in `World.monitors`, where observation refreshes it.
//
// Four invariants, in the order they matter:
//
//  1. **A monitor always shows exactly one address, and showing it claims it.** "A monitor with no
//     workspaces" is unrepresentable; the honest state is a monitor showing an *empty* workspace,
//     which every verb already handles.
//  2. **Materialized ⇒ assigned.** Every address with a strip belongs to exactly one record's `owned`,
//     so `monitor(of:)` is total over every address a window can be on. Two mutators keep it: `show`
//     claims what a display shows, `assign` claims what a verb only materializes. `reconcile` repairs
//     what neither saw — a state replayed from a dump, or a display that took its addresses away.
//  3. **`focused` is stored, not derived from `World.focusedWindow`.** A monitor showing an empty
//     workspace has no AX target, and emira's focus must still be able to sit there — which is what
//     makes the next window spawn land on it through the unchanged newcomer rule.
//  4. **A display's assignments outlive the display being gone.** Sleep, lock, clamshell and KVM
//     switches produce transient zero-display states, and dropping the desktop's arrangement on each
//     would scramble it every lid close. With no display attached the whole set is `unattached`.

/// One display's structure. Geometry — the frame and the struts — lives in `World.monitors`; nothing
/// here is refreshed by observation, which is the whole of why the two are separate types.
public struct MonitorRecord: Sendable, Equatable, Codable {
    public let id: MonitorId
    /// The addresses this display holds, in name order. Disjoint across records, and ⊆ materialized
    /// except for `shown`, which a display claims by showing it whether or not it has a strip yet.
    public fileprivate(set) var owned: [WorkspaceName]
    /// The one address on screen here. ∈ `owned` by construction — `show` claims what it shows.
    public fileprivate(set) var shown: WorkspaceName
}

/// The displays as *containers of workspaces*: which addresses each holds, which one it shows, and
/// which display the user is on. A value type, `Codable`, so it dumps and replays with the rest of
/// `State`.
public struct Monitors: Sendable, Equatable, Codable {

    /// The attached displays, in system enumeration order. Empty before the first `screensChanged`
    /// and for as long as no display is attached.
    private var records: [MonitorRecord]

    /// The display the user is on. Names a record whenever one exists; `nil` only with none attached.
    public private(set) var focused: MonitorId?

    /// The set with no display to hold it: every address a departed display owned, and which of them
    /// was last on screen. The launch state, and where a lid close puts the desktop (invariant 4).
    ///
    /// Not a second authority — written and read only while `records` is empty, which is the one
    /// condition under which no record can answer.
    private var unattached: Assignment

    /// A set of addresses and the one of them on screen. The shape a record has, minus its identity,
    /// so "shown ∈ owned" reads the same in both places.
    struct Assignment: Sendable, Equatable, Codable {
        var owned: [WorkspaceName]
        var shown: WorkspaceName
    }

    /// The launch state: no display seen yet, one address shown, nothing else assigned.
    public init(shown: WorkspaceName = .first) {
        self.records = []
        self.focused = nil
        self.unattached = Assignment(owned: [shown], shown: shown)
    }

    // What a monitor holds

    /// Every attached display, in enumeration order.
    public var ids: [MonitorId] { records.map(\.id) }

    /// The record `id` names, or `nil` for a display that is not attached.
    public func record(_ id: MonitorId) -> MonitorRecord? { records.first { $0.id == id } }

    /// The address `id` is showing, or `nil` for a display that is not attached.
    public func shown(on id: MonitorId) -> WorkspaceName? { record(id)?.shown }

    /// The addresses `id` holds, in name order — empty for a display that is not attached.
    public func owned(of id: MonitorId) -> [WorkspaceName] { record(id)?.owned ?? [] }

    /// **The acting monitor's address** — what `State.layout` projects, and what every verb naming no
    /// monitor acts on. Total, including with no display attached, which is what lets the reducer hold
    /// a focused workspace before the first `screensChanged` and through every lid close.
    public var shown: WorkspaceName {
        focused.flatMap { shown(on: $0) } ?? unattached.shown
    }

    /// The addresses the acting monitor holds — the set a relative workspace ref cycles inside.
    public var owned: [WorkspaceName] {
        focused.map { owned(of: $0) } ?? unattached.owned
    }

    /// Every address currently on a screen, **acting monitor first**, then the rest in enumeration
    /// order. What `Workspaces.placementOrder` puts in front of the parked remainder, so a visible
    /// strip owns the low park ordinals and its nubs never renumber as another address fills up.
    public var shownWorkspaces: [WorkspaceName] {
        guard !records.isEmpty else { return [unattached.shown] }
        let acting = focused.flatMap { shown(on: $0) }
        return (acting.map { [$0] } ?? []) + records.map(\.shown).filter { $0 != acting }
    }

    /// Which display holds `name`, or `nil` — held by no attached display. Total over every address a
    /// window can be on while a display exists (invariant 2).
    public func monitor(of name: WorkspaceName) -> MonitorId? {
        records.first { $0.owned.contains(name) }?.id
    }

    // Mutation

    /// Show `name` on `id`, claiming it from whichever display held it. The one mutator invariant 1
    /// rests on: there is no way to move `shown` without moving `owned` with it.
    ///
    /// Total: an `id` naming no attached display writes the unattached set instead, which is what
    /// keeps a workspace switch working before the first `screensChanged`.
    public mutating func show(_ name: WorkspaceName, on id: MonitorId?) {
        guard let id, let index = records.firstIndex(where: { $0.id == id }) else {
            guard records.isEmpty else { return }
            unattached.shown = name
            unattached.owned = inserting(name, into: unattached.owned)
            return
        }
        claim(name, by: index)
        records[index].shown = name
        repairShown(except: index)
    }

    /// Show `name` on the acting monitor — the whole of what a workspace switch does to this
    /// container, and what `Workspaces.focus(_:)` used to be.
    public mutating func show(_ name: WorkspaceName) { show(name, on: focused) }

    /// Give `name` a home on the acting monitor if no display holds it — **invariant 2 at the one
    /// moment it can break.** `show` claims what a display *shows*; this claims what a verb merely
    /// materializes, and between them every address with a strip has an owner the instant it gets one.
    ///
    /// An address some display already holds keeps it: a workspace lives where it lives, which is what
    /// lets a window sent to one travel to whichever screen that is.
    public mutating func assign(_ name: WorkspaceName) {
        guard monitor(of: name) == nil else { return }
        guard !records.isEmpty else {
            unattached.owned = inserting(name, into: unattached.owned)
            return
        }
        let acting = records.firstIndex { $0.id == focused } ?? 0
        records[acting].owned = inserting(name, into: records[acting].owned)
    }

    /// Move the user to `id`. Ignored for a display that is not attached, so the acting monitor is
    /// always one that exists.
    public mutating func focus(_ id: MonitorId) {
        guard records.contains(where: { $0.id == id }) else { return }
        focused = id
    }

    /// Sync to the hardware and to the workspace set — the mirror of `Workspaces.reconcile`, and total
    /// in the same three ways: **adopt orphans, drop the departed, repair `shown`.**
    ///
    /// - An arriving display owns nothing, so it shows the first address nobody holds. The *first*
    ///   display to arrive is the exception that makes a one-display boot come out unchanged: it
    ///   adopts the unattached set whole, launch address included.
    /// - A departing display's addresses go to the first survivor, or — when it was the last one — to
    ///   `unattached`, which is invariant 4 and what makes a lid close survivable.
    /// - An address materialized by a verb that never touched this container is claimed by the acting
    ///   monitor, which is invariant 2 repaired rather than asserted.
    public mutating func reconcile(materialized: [WorkspaceName], infos: [MonitorInfo]) {
        let arriving = infos.map(\.id)
        let known = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Both read before `records` is rebuilt: a departed record is about to stop existing, and what
        // it held has to be re-homed rather than dropped.
        let orphaned = records.filter { !arriving.contains($0.id) }.flatMap(\.owned)
        let wasDetached = records.isEmpty

        guard !arriving.isEmpty else {
            // The last display left. What the user was looking at is what a returning display shows.
            unattached = Assignment(
                owned: (orphaned + unattached.owned + materialized).sorted().deduplicated(),
                shown: focused.flatMap { known[$0] }?.shown ?? unattached.shown)
            records = []
            focused = nil
            return
        }

        records = arriving.map { known[$0] ?? MonitorRecord(id: $0, owned: [], shown: .first) }
        // The acting monitor always names one that exists: a display that left hands focus to the
        // first survivor, which is also where its workspaces go.
        if focused.map(arriving.contains) != true { focused = records[0].id }

        // A desktop assembled with no display to hold it lands **whole** on the first one to arrive —
        // its addresses *and* the one that was on screen. This is both the boot path (`Workspaces` has
        // materialized the launch address and nothing has been able to claim it yet) and the far side
        // of a lid close.
        if wasDetached {
            records[0].owned = unattached.owned
            records[0].shown = unattached.shown
        }
        unattached.owned = []

        // A departing display's addresses go to the first survivor rather than being dropped.
        for name in orphaned where monitor(of: name) == nil {
            records[0].owned = inserting(name, into: records[0].owned)
        }

        // Invariant 2: an address with a strip and no owner belongs to the monitor whose verb made it.
        let acting = records.firstIndex { $0.id == focused } ?? 0
        for name in materialized.sorted() where monitor(of: name) == nil {
            records[acting].owned = inserting(name, into: records[acting].owned)
        }

        repairShown(except: nil)

        // Drop assignments for addresses that no longer have a strip — never the shown one, which a
        // display holds by showing it whether or not anything has materialized it yet.
        let live = Set(materialized)
        for index in records.indices {
            let shown = records[index].shown
            records[index].owned.removeAll { !live.contains($0) && $0 != shown }
        }
    }

    /// Invariant 1, kept through the two mutators that can break it: a display showing an address it
    /// does not hold takes one it can — its own first, then `takeable()` for a display that holds
    /// nothing at all (an arrival, or the loser of a `show`).
    ///
    /// Cannot cascade: the address taken is this display's, nobody's, or one another display owns but
    /// is not *looking at*, so the claim never dispossesses a display of what is on its screen.
    /// `except` is the display that just claimed, which must not be walked back.
    private mutating func repairShown(except index: Int?) {
        for other in records.indices where other != index {
            guard !records[other].owned.contains(records[other].shown) else { continue }
            // Every address on a screen means there is nothing to take — 37 displays, so unreachable,
            // but answered rather than trapped: the display keeps showing what it was showing.
            guard let name = records[other].owned.first ?? takeable() else { continue }
            claim(name, by: other)
            records[other].shown = name
        }
    }

    /// Take `name` away from every other holder and give it to `index`, in name order.
    private mutating func claim(_ name: WorkspaceName, by index: Int) {
        for other in records.indices where other != index {
            records[other].owned.removeAll { $0 == name }
        }
        unattached.owned.removeAll { $0 == name }
        records[index].owned = inserting(name, into: records[index].owned)
    }

    /// The lowest address a display with none of its own may take: one nobody holds, failing that one
    /// another display holds but is not showing.
    ///
    /// The second rung is what keeps invariant 1 total. `show` claims and never releases, so the acting
    /// monitor accumulates every address it has ever shown, and **two** displays with enough switching
    /// between them exhaust the unassigned set long before the 36 addresses run out. Taking an address
    /// its owner is not looking at costs that owner nothing it can see, and leaves it showing one it
    /// still holds, so no repair follows.
    ///
    /// `nil` only when all 36 are *on screen*, which does need 37 displays.
    private func takeable() -> WorkspaceName? {
        if let free = WorkspaceName.all.first(where: { monitor(of: $0) == nil }) { return free }
        let onScreen = Set(records.map(\.shown))
        return WorkspaceName.all.first { !onScreen.contains($0) }
    }

    /// `names` with `name` in it, in name order and once.
    private func inserting(_ name: WorkspaceName, into names: [WorkspaceName]) -> [WorkspaceName] {
        guard !names.contains(name) else { return names }
        var names = names
        names.insert(name, at: names.firstIndex { $0 > name } ?? names.endIndex)
        return names
    }
}

private extension Array where Element: Equatable {
    /// First occurrence wins. Small by construction (≤ 36 addresses), so the quadratic scan is the
    /// cheaper of the two.
    func deduplicated() -> [Element] {
        reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}
