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

    /// What each departed display held, kept against the id it will come back as — invariant 4's
    /// other half. A survivor owns those addresses meanwhile, so this is a **memory and never an
    /// authority**: `monitor(of:)` still answers from `records` alone, and an entry is consumed the
    /// moment its display returns.
    ///
    /// Distinct from `unattached`, which answers "what is the desktop showing" while there is no
    /// display at all. That one has to be total; this one only has to be right.
    private var detached: [MonitorId: Assignment] = [:]

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

    /// Where a **relative** workspace ref may land from the acting monitor: the addresses it holds,
    /// plus every address no display holds at all. The monitor is the container, so `next` and its kin
    /// stay inside it (D1) — and on one display "held here or held by nobody" is all 36 addresses, so
    /// single-display behaviour is unchanged to the letter.
    public var reachable: [WorkspaceName] {
        let mine = Set(owned)
        return WorkspaceName.all.filter { mine.contains($0) || monitor(of: $0) == nil }
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
    /// rests on: there is no way to move `shown` without moving `owned` with it. Also the whole of
    /// what `move-workspace-to-monitor` does here — handing an address to another display *is* that
    /// display showing it, and the dispossessed one falling back.
    ///
    /// `occupied` is which addresses hold a window, which only `Workspaces` can answer: it decides
    /// what the loser of the claim falls back to (see `fallback`), and nothing else.
    ///
    /// Total: an `id` naming no attached display writes the unattached set instead, which is what
    /// keeps a workspace switch working before the first `screensChanged`.
    public mutating func show(_ name: WorkspaceName, on id: MonitorId?,
                              occupied: [WorkspaceName] = []) {
        guard let id, let index = records.firstIndex(where: { $0.id == id }) else {
            guard records.isEmpty else { return }
            unattached.shown = name
            unattached.owned = inserting(name, into: unattached.owned)
            return
        }
        claim(name, by: index)
        records[index].shown = name
        repairShown(except: index, occupied: Set(occupied))
    }

    /// Hand `name` to `id` and `id`'s address to `donor`, in one step — two displays **trading** rather
    /// than one dispossessing the other, which is what the main display moving does here. Not two
    /// `show`s: those strand `donor` between them, and the fallback repairing it claims a *third*
    /// address. Silent unless both are attached and the address is moving.
    public mutating func exchange(_ name: WorkspaceName, to id: MonitorId, with donor: MonitorId) {
        guard id != donor,
              let index = records.firstIndex(where: { $0.id == id }),
              let other = records.firstIndex(where: { $0.id == donor }),
              records[index].shown != name else { return }
        let vacated = records[index].shown
        claim(name, by: index)
        records[index].shown = name
        claim(vacated, by: other)
        records[other].shown = vacated
    }

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
    ///   `unattached`, which is invariant 4 and what makes a lid close survivable. They are remembered
    ///   in `detached` either way, and **a display that comes back takes them back**: sleep, lock,
    ///   clamshell and KVM switches all return the same `CGDirectDisplayID`, and a desktop that
    ///   re-scrambles on each is one the user rebuilds every lid close.
    /// - An address materialized by a verb that never touched this container is claimed by the acting
    ///   monitor, which is invariant 2 repaired rather than asserted.
    public mutating func reconcile(materialized: [WorkspaceName], occupied: [WorkspaceName] = [],
                                   infos: [MonitorInfo]) {
        let arriving = infos.map(\.id)
        let known = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Both read before `records` is rebuilt: a departed record is about to stop existing, and what
        // it held has to be re-homed rather than dropped.
        let orphaned = records.filter { !arriving.contains($0.id) }.flatMap(\.owned)
        let wasDetached = records.isEmpty

        // Remembered before the departure is folded away, and against the id rather than the record:
        // what comes back is an id, and this is the only thing that can tell it what it used to hold.
        for record in records where !arriving.contains(record.id) {
            detached[record.id] = Assignment(owned: record.owned, shown: record.shown)
        }

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

        // A display that has been here before takes its own addresses back, off whichever survivor
        // adopted them (D12). Unconditional, and deliberately: a claim is what `show` does too, and
        // any display it dispossesses falls back through `repairShown` below exactly as it would
        // there. `shown` is set rather than checked for the same reason.
        //
        // The exception is the display that just adopted the detached desktop, which keeps
        // `unattached.shown`: **what the user was looking at outranks what this screen was showing.**
        // Every display departing into a zero-display state leaves a memory behind, so without this the
        // reclaim always overrides the adoption and `unattached.shown` never survives the lid close it
        // exists for. A display whose address that really was reclaims it from here in this same loop.
        for index in records.indices {
            guard let memory = detached.removeValue(forKey: records[index].id) else { continue }
            for name in memory.owned { claim(name, by: index) }
            guard !(wasDetached && index == 0) else { continue }
            records[index].shown = memory.shown
        }

        // A departing display's addresses go to the first survivor rather than being dropped.
        for name in orphaned where monitor(of: name) == nil {
            records[0].owned = inserting(name, into: records[0].owned)
        }

        // Invariant 2: an address with a strip and no owner belongs to the monitor whose verb made it.
        let acting = records.firstIndex { $0.id == focused } ?? 0
        for name in materialized.sorted() where monitor(of: name) == nil {
            records[acting].owned = inserting(name, into: records[acting].owned)
        }

        repairShown(except: nil, occupied: Set(occupied))

        // Drop assignments for addresses that no longer have a strip — never the shown one, which a
        // display holds by showing it whether or not anything has materialized it yet.
        let live = Set(materialized)
        for index in records.indices {
            let shown = records[index].shown
            records[index].owned.removeAll { !live.contains($0) && $0 != shown }
        }
    }

    /// Invariant 1, kept through the two mutators that can break it: a display showing an address it
    /// does not hold takes one it can (`fallback`).
    ///
    /// Cannot cascade: the address taken is this display's, nobody's, or one another display owns but
    /// is not *looking at*, so the claim never dispossesses a display of what is on its screen.
    /// `except` is the display that just claimed, which must not be walked back.
    private mutating func repairShown(except index: Int?, occupied: Set<WorkspaceName>) {
        for other in records.indices where other != index {
            guard !records[other].owned.contains(records[other].shown) else { continue }
            guard let name = fallback(for: other, occupied: occupied) else { continue }
            claim(name, by: other)
            records[other].shown = name
        }
    }

    /// What a display falls back to when the address it was showing is claimed away — three rungs,
    /// nearest first:
    ///
    ///  1. the **occupied** addresses it still holds. A display losing its screen should land on
    ///     windows it already has rather than on an empty address it merely passed through.
    ///  2. anything it holds, or that nobody holds. Claiming an unassigned address costs nothing.
    ///  3. an address another display holds but is **not showing** — the rung that makes invariant 1
    ///     total, since `show` claims and never releases, so two displays exhaust the unassigned set
    ///     long before the 36 addresses run out. Taking what nobody is looking at costs its owner
    ///     nothing it can see, so no repair cascades from it.
    ///
    /// "Nearest" is `WorkspaceName` distance from the address being left, **forward winning ties** —
    /// `next`'s own bias, so a display losing `2` lands on `3` rather than on `1`.
    ///
    /// `nil` only when all 36 addresses are on a screen at once, which needs 37 displays: answered
    /// rather than trapped, and the display keeps showing what it was showing.
    private func fallback(for index: Int, occupied: Set<WorkspaceName>) -> WorkspaceName? {
        let from = records[index].shown
        let mine = records[index].owned
        let onScreen = Set(records.map(\.shown))
        let rungs = [
            mine.filter(occupied.contains),
            mine + WorkspaceName.all.filter { monitor(of: $0) == nil },
            WorkspaceName.all.filter { !onScreen.contains($0) },
        ]
        return rungs.lazy.compactMap { nearest(to: from, among: $0) }.first
    }

    /// The address in `names` closest to `origin` in rank, forward winning ties.
    private func nearest(to origin: WorkspaceName, among names: [WorkspaceName]) -> WorkspaceName? {
        names.min { (distance($0, origin)) < (distance($1, origin)) }
    }

    /// Rank distance, with the tie-break folded in: a lower second component wins, and forward
    /// carries `0` where backward carries `1`.
    private func distance(_ name: WorkspaceName, _ origin: WorkspaceName) -> (Int, Int) {
        (abs(name.rank - origin.rank), name.rank < origin.rank ? 1 : 0)
    }

    /// Take `name` away from every other holder and give it to `index`, in name order.
    private mutating func claim(_ name: WorkspaceName, by index: Int) {
        for other in records.indices where other != index {
            records[other].owned.removeAll { $0 == name }
        }
        unattached.owned.removeAll { $0 == name }
        records[index].owned = inserting(name, into: records[index].owned)
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
