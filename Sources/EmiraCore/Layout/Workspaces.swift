import Foundation

// The multi-strip container (IMPLEMENTATION.md §5, `Layout/Workspaces.swift`) — the thing
// `Layout.swift`'s header predicted from the beginning: *"one strip = one workspace… a multi-strip
// container wraps this later."* This is later.
//
// **The model, in four sentences.** There are 36 workspaces, named `1`…`9`, `0`, then `a`…`z`
// (`WorkspaceName`), each its own infinite horizontal strip. Exactly one is focused; its strip is what
// the viewport looks at. Everything on every other workspace is **parked** — the same 1 pt corner nubs
// an off-viewport column already uses, which is how emira emulates workspaces without touching native
// Spaces (`PRINCIPLES.md` §3). A window's workspace is *derived*: it is on the strip whose `Layout`
// contains it.
//
// Four properties carry the whole design, and each exists to close a way this could go quietly wrong:
//
//  · **Sparse, and never pruned.** A name materializes when it is first focused or first given a
//    window, and is never dropped again — the "no collapsing" half of the fixed-domain decision, in
//    one sentence. An unmaterialized name answers every query as an empty strip, so nothing anywhere
//    has to branch on whether a workspace "exists".
//  · **Ordered views sort, by `WorkspaceName` and never by its spelling.** `strips` is a dictionary
//    and dictionary order is nondeterministic; this is the same trap `World.windows`' doc names. Every
//    derived view here is ordered by the *name*, whose `Comparable` is the key order `1`…`9`, `0`,
//    `a`…`z` — which is not alphabetical order, and `WorkspaceName`'s header says why, once.
//  · **One `ColumnId` space.** `Workspaces` owns the `ColumnAllocator` and lends it to whichever strip
//    is minting. Per-strip watermarks would make column #1 on workspace `0` and column #1 on
//    workspace `3` the same id, and `Motion.columnWidths` is keyed by a bare `ColumnId`.
//  · **One park-ordinal run.** Park slots are unique *per ordinal*, so the ordinals have to be handed
//    out across the whole set rather than per strip — see `targetFrames`.
//
// **A window's workspace is derived, not stored, and that is deliberate.** The alternative — a
// `[WindowId: WorkspaceName]` assignment map beside the layouts — is a second authority that can
// disagree with the first, and the disagreement is invisible until something places a window twice. A
// window in no strip at all is simply a newcomer, and belongs to the focused workspace.
//
// **The memory landed with the switch that gives it meaning (2026-07-26).** `WorkspaceState` now
// carries a scroll offset and a last-focused window beside the strip. Both are *switching's* state —
// written on the way out, read on the way in, and touched at no other moment — which is why the model
// slice deliberately left them out and why they arrive now, with `focus-workspace`, rather than as
// fields nothing could write. While a workspace is focused the live authorities are
// `Motion.viewportOffset` and `World.focusedWindow`; the record is what makes coming back *coming back*
// rather than starting over. Per-monitor workspace sets are still M6's other half.

/// One materialized workspace: its strip, plus the two things it remembers about having been looked at.
///
/// Not public, and not reachable as a value: `Workspaces` exposes the strip and the two memories as
/// three accessors instead, so no caller can hold a stale copy of a record beside the container that
/// owns it. It is a type rather than three parallel dictionaries for the reason the model rejects an
/// assignment map — three sparse dictionaries keyed by the same name are three things that can
/// disagree about which addresses exist.
struct WorkspaceState: Sendable, Equatable, Codable {
    /// The strip. The only field of the three that means anything while the workspace is focused.
    var layout: Layout

    /// The viewport offset focus was last taken away from this workspace at — the whole of
    /// "per-workspace scroll memory". `0` (the strip's origin) for one never focused.
    ///
    /// Deliberately **stale while this workspace is focused**: `Motion.viewportOffset` is the live
    /// authority there, and mirroring it every frame would be a second one. The switch writes this on
    /// the way out and reads it on the way in; nothing else looks at it.
    var scrollOffset: Double

    /// The window that had focus when this workspace was last left, or `nil`.
    ///
    /// Invariant, maintained by `Workspaces.reconcile`: if set, it names a window **on this strip**. A
    /// remembered window that has since closed, minimized, floated or been moved to another workspace
    /// is cleared rather than left dangling — the alternative is a switch that focuses nothing while
    /// the strip in front of the user is full of windows.
    var lastFocus: WindowId?

    init(layout: Layout = Layout(), scrollOffset: Double = 0, lastFocus: WindowId? = nil) {
        self.layout = layout
        self.scrollOffset = scrollOffset
        self.lastFocus = lastFocus
    }
}

/// The 36-address workspace set: one `Layout` per materialized address, which one is focused, and the
/// `ColumnId` allocator they all mint from.
///
/// Value type, `Equatable`/`Codable` like its parts, so the whole of `State` still dumps to JSON
/// (`emira debug`) and replays deterministically (IMPLEMENTATION.md §7). The allocator watermark is
/// part of that state, so ids stay unique across a serialization round-trip.
public struct Workspaces: Sendable, Equatable, Codable {
    /// The materialized workspaces, keyed by address. Sparse: an absent name is an empty strip with no
    /// memory, and no name is ever removed. Private — every read goes through one of the three
    /// accessors below, which is what makes "absent means empty" true in one place instead of at each
    /// call site.
    ///
    /// Encoded as a JSON object keyed by the character (`WorkspaceName: CodingKeyRepresentable`), so
    /// a state dump reads `"strips": {"1": …}`.
    private var strips: [WorkspaceName: WorkspaceState]

    /// The workspace on screen. Every other strip is parked in its entirety.
    ///
    /// `private(set)` with `focus(_:)` as the only way to move it: focusing is what materializes an
    /// address, and the two must not come apart.
    public private(set) var focused: WorkspaceName

    /// The one `ColumnId` source for every strip (see `ColumnAllocator`). Private, and lent out only
    /// by the two mutators below that mint — which is why they live here rather than being reached
    /// through the `Layout` projection like every other structural edit.
    private var columnIds: ColumnAllocator

    /// A fresh set: `focused` materialized and empty, nothing else. The launch state.
    public init(focused: WorkspaceName = .first) {
        self.strips = [focused: WorkspaceState()]
        self.focused = focused
        self.columnIds = ColumnAllocator()
    }

    /// Construct from explicit strips — for the reducer building a specific state, for replay, and for
    /// tests. `focused` is materialized whether or not `strips` mentions it.
    ///
    /// The allocator resumes past the highest `ColumnId` supplied, which is the rule `Layout`'s own
    /// `init(columns:)` used to carry — now in one place instead of one per strip. The warning that
    /// came with it moves here intact: **never rebuild a live `Workspaces` through this initializer.**
    /// The watermark resumes past the highest *supplied* id, so it rewinds whenever a column has been
    /// dropped, and the next mint re-issues an id a `Motion.columnWidths` animator may still be keyed
    /// on. Everything in the reducer mutates in place for exactly this reason.
    public init(focused: WorkspaceName, strips: [WorkspaceName: Layout]) {
        self.strips = strips.mapValues { WorkspaceState(layout: $0) }
        self.strips[focused] = self.strips[focused] ?? WorkspaceState()
        self.focused = focused
        let highest = strips.values.flatMap { $0.columns.map(\.id.raw) }.max() ?? 0
        self.columnIds = ColumnAllocator(next: highest + 1)
    }

    // MARK: - Access

    /// The strip at `name` — an **empty** strip for an address that has never been materialized, so no
    /// caller branches on existence. Assigning materializes it (and never un-materializes: an assigned
    /// empty strip is a name that now exists and is simply empty).
    public subscript(name: WorkspaceName) -> Layout {
        get { strips[name]?.layout ?? Layout() }
        set { strips[name, default: WorkspaceState()].layout = newValue }
    }

    /// Where `name`'s viewport rested when focus last left it, and where it resumes when focus returns
    /// — the whole of per-workspace scroll memory, which is one stored `Double` because the switch is
    /// the only thing that reads or writes it (`WorkspaceState.scrollOffset`).
    ///
    /// An address never focused answers `0`, the strip's origin, which is also what a fresh workspace
    /// should show. Reading does not materialize; assigning does.
    public subscript(scrollOffsetOf name: WorkspaceName) -> Double {
        get { strips[name]?.scrollOffset ?? 0 }
        set { strips[name, default: WorkspaceState()].scrollOffset = newValue }
    }

    /// Which of `name`'s windows had focus when focus last left it (`WorkspaceState.lastFocus`), or
    /// `nil` — never focused, left with focus off the strip, or the remembered window is gone.
    ///
    /// Two callers, and they are the two ends of the same rule: a switch *into* `name` focuses this
    /// window, and a window moved *to* `name` opens beside it (the rule
    /// `reconcile(stripWindowIds:insertingAfter:)` already applies to a newcomer).
    public subscript(lastFocusOf name: WorkspaceName) -> WindowId? {
        get { strips[name]?.lastFocus }
        set { strips[name, default: WorkspaceState()].lastFocus = newValue }
    }

    /// The focused workspace's strip — the one the viewport looks at, and what `State.layout` projects.
    public var focusedStrip: Layout {
        get { self[focused] }
        set { self[focused] = newValue }
    }

    /// Move focus to `name`, materializing it if this is its first sight.
    ///
    /// **Deliberately just this.** Storing the outgoing workspace's memory and seeding the viewport
    /// from the incoming one's are the reducer's, not this type's: they read `Motion` and `World`,
    /// which a layout container knows nothing about (`Engine.switchWorkspace`). What is atomic *here*
    /// is the one thing that must be — `focused` never names an address that does not exist.
    public mutating func focus(_ name: WorkspaceName) {
        if strips[name] == nil { strips[name] = WorkspaceState() }
        focused = name
    }

    /// The address a `WorkspaceRef` names, against the focused workspace and — for the two occupied
    /// motions — against which strips actually hold a window.
    ///
    /// **Total, and clamping rather than wrapping.** Every ref resolves to a real address: `next` at
    /// `"z"`, `previous` at `"0"`, and an occupied motion with nothing in that direction all answer the
    /// *focused* workspace, i.e. answer "nowhere to go". The caller turns resolving-to-where-we-already-
    /// are into a silent no-op in one place, which is why nothing here returns `nil` for it to
    /// re-interpret. No wrap is the same rule `focus left|right` keeps at the strip's edges.
    ///
    /// It lives here rather than in the reducer because it is a question about the *ordering* of this
    /// container and about what is in it — both facts this type already owns.
    public func resolve(_ ref: WorkspaceRef) -> WorkspaceName {
        switch ref {
        case .name(let name):     return name
        case .next:               return focused.next ?? focused
        case .previous:           return focused.previous ?? focused
        case .nextOccupied:       return occupied(after: focused) ?? focused
        case .previousOccupied:   return occupied(before: focused) ?? focused
        }
    }

    /// The first address after `name` holding a window, or `nil`. **Materialized-and-empty is not
    /// occupied**: the two relative motions differ over what is *there*, not over what has been
    /// visited, and a workspace you passed through once should not keep answering `next-non-empty`
    /// forever. Only a materialized address can be non-empty, so scanning `materialized` (which is
    /// sorted) is complete as well as ordered.
    private func occupied(after name: WorkspaceName) -> WorkspaceName? {
        materialized.first { $0 > name && !self[$0].isEmpty }
    }

    /// The mirror of `occupied(after:)`, taking the *last* candidate below `name` because
    /// `materialized` runs upward.
    private func occupied(before name: WorkspaceName) -> WorkspaceName? {
        materialized.last { $0 < name && !self[$0].isEmpty }
    }

    /// Every materialized address, **in name order** — the workspace set as it stands. Sorted, because
    /// `strips` is a dictionary (see the type header).
    public var materialized: [WorkspaceName] { strips.keys.sorted() }

    /// The materialized addresses in **placement order**: the focused workspace first, then the rest in
    /// name order.
    ///
    /// One rule, used twice, which is why it is named. It is the order windows are placed in
    /// (`allWindowIds` → `Engine.emitPlacements`, whose effect order it fixes) *and* the order park
    /// ordinals are handed out in (`targetFrames`). Focused-first means the workspace the user is
    /// looking at owns the low ordinals and its nubs do not renumber as other addresses fill up.
    public var placementOrder: [WorkspaceName] {
        [focused] + materialized.filter { $0 != focused }
    }

    /// Every window on every strip, in placement order (see above) — within each strip, layout order
    /// (left→right, top→bottom). The set `Engine` places, and the union `reconcile` maintains.
    public var allWindowIds: [WindowId] {
        placementOrder.flatMap { self[$0].allWindowIds }
    }

    /// The workspace whose strip holds `id`, or `nil` if it is on none (a newcomer, a float, or a
    /// window that has left). The derived answer to "which workspace is this window on" — there is no
    /// stored one, on purpose (see the type header).
    public func workspace(of id: WindowId) -> WorkspaceName? {
        materialized.first { self[$0].columnIndex(ofWindow: id) != nil }
    }

    /// The workspace and column holding `id`, or `nil`. What a query about a window's *column* needs
    /// when the window is not necessarily on the focused strip.
    public func column(containing id: WindowId) -> (workspace: WorkspaceName, column: ColumnLayout)? {
        for name in materialized {
            let strip = self[name]
            if let i = strip.columnIndex(ofWindow: id) { return (name, strip.columns[i]) }
        }
        return nil
    }

    // MARK: - Structural mutation (the two edits that mint)
    //
    // Only `reconcile` and `extract` create columns, so only they need the allocator — and because
    // they need it, they live here rather than being reached through `State.layout`. Every other
    // structural edit (`moveColumn`, `move(window:toColumn:at:)`, `moveWindowWithinColumn`, the three
    // width setters) is a fact about one strip and goes through the projection unchanged.

    /// Sync every strip to the system's current strip membership — the World→Workspaces bridge, and
    /// the query in this slice with the most room to go quietly wrong.
    ///
    /// Two halves, and the asymmetry *is* the model:
    ///
    ///  1. **Departures leave every strip.** A window that closed, minimized or stopped tiling is gone
    ///     from wherever it was, not just from the workspace being looked at.
    ///  2. **Newcomers join the focused strip only.** A window on no strip at all is a newcomer, and it
    ///     opens beside `anchor` on the workspace the user is on.
    ///
    /// Left projected onto the focused strip — i.e. left as the single-strip `Layout.reconcile` this
    /// replaced — the very first workspace switch would treat every window on every *other* workspace
    /// as a newcomer and suck the lot onto the focused one, in one silent pass, with the user's whole
    /// desktop as the result. That is why this belongs to the slice where there is only one workspace
    /// to prove it against: with a single materialized address, `elsewhere` is empty and this is
    /// byte-for-byte the call it replaced.
    ///
    /// It also **clears a remembered focus that is no longer on its own strip** — the third half, added
    /// with switching (2026-07-26). A window closes, minimizes or is moved to another workspace, and
    /// the address it was last focused on is still naming it; a switch there would then focus nothing
    /// while the user looks at a strip full of windows. Enforcing it here rather than at the switch is
    /// what makes it an invariant of the container (`WorkspaceState.lastFocus`) instead of a check
    /// somebody has to remember, and membership is exactly the fact this function is already about.
    ///
    /// - Parameter anchor: the window a newcomer opens beside (`Layout.reconcile`'s rule, unchanged).
    public mutating func reconcile(stripWindowIds ids: [WindowId], insertingAfter anchor: WindowId? = nil) {
        let keep = Set(ids)
        var elsewhere: Set<WindowId> = []
        for name in materialized where name != focused {
            var strip = self[name]
            strip.removeWindows(notIn: keep)
            self[name] = strip
            elsewhere.formUnion(strip.allWindowIds)
        }
        // Windows living on another workspace are subtracted before the focused strip is reconciled,
        // so it sees them as neither members nor newcomers — the one line that keeps step 2 from
        // undoing step 1.
        var strip = focusedStrip
        strip.reconcile(stripWindowIds: ids.filter { !elsewhere.contains($0) },
                        insertingAfter: anchor, columnIds: &columnIds)
        self[focused] = strip

        // Asked of the strip rather than of `keep`, so it covers both ways a memory goes stale in one
        // rule: the window left the strip set entirely, or it is still open on a *different* address.
        for name in materialized {
            guard let remembered = strips[name]?.lastFocus,
                  self[name].columnIndex(ofWindow: remembered) == nil else { continue }
            strips[name]?.lastFocus = nil
        }
    }

    /// Move `window` out into a freshly-minted single-window column on **its own** workspace
    /// (`Layout.extract`). Total: a window on no strip no-ops.
    @discardableResult
    public mutating func extract(window: WindowId, toNewColumnAt index: Int) -> LayoutEdit {
        guard let name = workspace(of: window) else { return .none }
        var strip = self[name]
        let edit = strip.extract(window: window, toNewColumnAt: index, columnIds: &columnIds)
        self[name] = strip
        return edit
    }

    /// Move `window` off whichever strip holds it and onto `destination`, as a freshly-minted
    /// single-window column beside `anchor` (or appended) — the cross-strip primitive behind
    /// `move-to-workspace`.
    ///
    /// **One call, and that is the point.** The obvious decomposition — "take it off there, put it on
    /// here" — passes through a state with a window on *no* strip, which `Workspaces` cannot represent
    /// honestly: `workspace(of:)` would answer `nil`, `allWindowIds` would omit it, and a placement
    /// pass landing in between would leave a real window wherever it happened to be. It is the same
    /// argument `Layout`'s four editing primitives make about an empty column, one level up, over the
    /// invariant one level up. `Layout.remove(window:)` is internal for exactly this reason: it is the
    /// half that breaks the invariant, and this is the only place allowed to hold it.
    ///
    /// **A window, not its column.** A window with stackmates leaves them behind, exactly as
    /// `move-window left|right` pops it out of their column — the vocabulary says *window*, and this
    /// does what it says. Its width intent travels with it (`Layout.adopt(_:after:like:columnIds:)`),
    /// which is `extract`'s rule for the same reason: the size is one the user asked for out loud.
    ///
    /// Total, with two deliberate refusals: a window on no strip at all, and a window already on
    /// `destination`, both no-op with `.none` — the second matching `move(window:toColumn:at:)`'s
    /// refusal to "move" a window into the column it is already in.
    ///
    /// - Returns: the edit **as it landed on the source strip**, so `destroyedColumn` names a column
    ///   the departure emptied and the caller can retire its width animator. The arrival destroys
    ///   nothing by construction.
    @discardableResult
    public mutating func move(window: WindowId, to destination: WorkspaceName,
                              insertingAfter anchor: WindowId?) -> LayoutEdit {
        guard let source = workspace(of: window), source != destination else { return .none }

        var from = self[source]
        // Read before the removal: the column's width intent is what the arrival inherits, and after
        // the removal the column may not exist at all.
        let intent = from.columnIndex(ofWindow: window).map { from.columns[$0] }
        let edit = from.remove(window: window)
        guard edit.moved else { return .none }
        self[source] = from
        if strips[source]?.lastFocus == window { strips[source]?.lastFocus = nil }

        var to = self[destination]
        to.adopt([window], after: anchor, like: intent, columnIds: &columnIds)
        self[destination] = to          // materializes `destination` if this is its first window
        return edit
    }

    // MARK: - Geometry across the whole set

    /// The target frame for **every** window on **every** workspace at `scrollOffset` — the truth-plane
    /// placement, and the reason park ordinals had to move up here.
    ///
    /// The focused strip answers as it always did: its on-viewport columns tile, its off-viewport ones
    /// park. Every other workspace parks in full, at the size it would have if it were focused. The
    /// ordinals form **one run** across the whole set, in `placementOrder`, so no two parked windows
    /// anywhere share a nub.
    ///
    /// That uniqueness is load-bearing twice over, which is why it is not left to per-strip counters: a
    /// shared park frame breaks the ±2 pt first-sight identity join a daemon restart depends on
    /// (`PRINCIPLES.md` §7) *and* the no-overlap invariant the strip promises. Both failures are
    /// silent, and one of them is permanent.
    ///
    /// `ParkingLot.slot` is total and unique for any ordinal — past one lane's worth of rows it wraps
    /// a sliver further on screen — so a populated 36-workspace set is bounded, not merely unlikely to
    /// overflow.
    public func targetFrames(scrollOffset: Double, metrics: LayoutMetrics) -> [WindowId: Rect] {
        var frames = focusedStrip.targetFrames(scrollOffset: scrollOffset, metrics: metrics)
        var ordinal = focusedStrip.parkedWindowIds(scrollOffset: scrollOffset, metrics: metrics).count
        for name in placementOrder.dropFirst() {
            let strip = self[name]
            // Disjoint by construction — a window is on exactly one strip — so the merge rule is
            // unreachable rather than a policy.
            frames.merge(strip.parkedFrames(metrics: metrics, parkingFrom: ordinal)) { existing, _ in existing }
            ordinal += strip.allWindowIds.count
        }
        return frames
    }

    /// The size the layout would give each window **if nobody had answered back** — the *question* a
    /// `SizeCorrection` answers (`Layout.uncorrectedSize`), for every window on every strip.
    ///
    /// `Engine`'s placement diff needs one of these per window it considers, and it considers all of
    /// them; asking only the focused strip would leave every parked window on another workspace
    /// unable to match its own recorded answer, and so re-placed on every event forever.
    public func uncorrectedSizes(metrics: LayoutMetrics) -> [WindowId: Size] {
        var sizes: [WindowId: Size] = [:]
        for name in materialized {
            for (id, frame) in self[name].naturalFrames(scrollOffset: 0, metrics: metrics.uncorrected) {
                sizes[id] = frame.size
            }
        }
        return sizes
    }
}
