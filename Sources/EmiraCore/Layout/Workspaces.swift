import Foundation

// The 36 workspaces — named `1`…`9`, `0`, then `a`…`z` (`WorkspaceName`) — each its own infinite
// horizontal strip. Exactly one is focused and its strip is what the viewport looks at; everything on
// every other workspace is **parked**. A window's workspace is *derived*, never stored: it is on the
// strip whose `Layout` contains it, so there is no assignment map that can disagree with the layouts.
//
// The set is sparse and never pruned — a name materializes when first focused or first given a window,
// and an unmaterialized name answers as an empty strip, so nothing branches on whether a workspace
// "exists". Every ordered view sorts by `WorkspaceName`, whose `Comparable` is the key order
// `1`…`9`, `0`, `a`…`z` and *not* alphabetical. One `ColumnAllocator` and one park-ordinal run serve
// the whole set (see `ColumnAllocator`, `targetFrames`).

/// One materialized workspace: its strip, plus the two things it remembers about having been looked at.
/// Not reachable as a value — `Workspaces` exposes the three fields as three accessors, so no caller
/// can hold a stale copy beside the container that owns it.
struct WorkspaceState: Sendable, Equatable, Codable {
    /// The strip. The only field of the three that means anything while the workspace is focused.
    var layout: Layout

    /// The viewport offset focus was last taken away at — per-workspace scroll memory, `0` for a
    /// workspace never focused. Deliberately **stale while this workspace is focused**, where
    /// `Motion.viewportOffset` is the live authority; the switch writes it out and reads it back in.
    var scrollOffset: Double

    /// The window that had focus when this workspace was last left, or `nil`.
    ///
    /// Invariant, maintained by `Workspaces.reconcile`: if set, it names a window **on this strip**. A
    /// remembered window that has closed, minimized, floated or moved elsewhere is cleared rather than
    /// left dangling, or a switch would focus nothing while the strip is full of windows.
    var lastFocus: WindowId?

    init(layout: Layout = Layout(), scrollOffset: Double = 0, lastFocus: WindowId? = nil) {
        self.layout = layout
        self.scrollOffset = scrollOffset
        self.lastFocus = lastFocus
    }
}

/// The 36-address workspace set: one `Layout` per materialized address, which one is focused, and the
/// `ColumnId` allocator they all mint from. Value type, `Codable` including the allocator watermark,
/// so ids stay unique across a serialization round-trip.
public struct Workspaces: Sendable, Equatable, Codable {
    /// The materialized workspaces, keyed by address. Private, so "absent means empty" is true in one
    /// place rather than at each call site. Encoded as a JSON object keyed by the character, so a state
    /// dump reads `"strips": {"1": …}`.
    private var strips: [WorkspaceName: WorkspaceState]

    /// The workspace on screen. Every other strip is parked in its entirety. `private(set)` with
    /// `focus(_:)` as the only way to move it, since focusing is what materializes an address.
    public private(set) var focused: WorkspaceName

    /// The one `ColumnId` source for every strip. Private, and lent out only by the two mutators below
    /// that mint — which is why those live here rather than on the `Layout` projection.
    private var columnIds: ColumnAllocator

    /// A fresh set: `focused` materialized and empty, nothing else. The launch state.
    public init(focused: WorkspaceName = .first) {
        self.strips = [focused: WorkspaceState()]
        self.focused = focused
        self.columnIds = ColumnAllocator()
    }

    /// Construct from explicit strips, materializing `focused` whether or not `strips` mentions it.
    ///
    /// **Never rebuild a live `Workspaces` through this initializer.** The watermark resumes past the
    /// highest *supplied* id, so it rewinds whenever a column has been dropped and the next mint
    /// re-issues an id a `Motion.columnWidths` animator may still be keyed on.
    public init(focused: WorkspaceName, strips: [WorkspaceName: Layout]) {
        self.strips = strips.mapValues { WorkspaceState(layout: $0) }
        self.strips[focused] = self.strips[focused] ?? WorkspaceState()
        self.focused = focused
        let highest = strips.values.flatMap { $0.columns.map(\.id.raw) }.max() ?? 0
        self.columnIds = ColumnAllocator(next: highest + 1)
    }

    // MARK: - Access

    /// The strip at `name` — an **empty** strip for an address never materialized, so no caller
    /// branches on existence. Assigning materializes it, and never un-materializes.
    public subscript(name: WorkspaceName) -> Layout {
        get { strips[name]?.layout ?? Layout() }
        set { strips[name, default: WorkspaceState()].layout = newValue }
    }

    /// Where `name`'s viewport rested when focus last left it, and where it resumes when focus returns.
    /// An address never focused answers `0`, the strip's origin. Reading does not materialize;
    /// assigning does.
    public subscript(scrollOffsetOf name: WorkspaceName) -> Double {
        get { strips[name]?.scrollOffset ?? 0 }
        set { strips[name, default: WorkspaceState()].scrollOffset = newValue }
    }

    /// Which of `name`'s windows had focus when focus last left it, or `nil` — never focused, left with
    /// focus off the strip, or the remembered window is gone. Two callers, the two ends of one rule: a
    /// switch *into* `name` focuses this window, and a window moved *to* `name` opens beside it.
    public subscript(lastFocusOf name: WorkspaceName) -> WindowId? {
        get { strips[name]?.lastFocus }
        set { strips[name, default: WorkspaceState()].lastFocus = newValue }
    }

    /// The focused workspace's strip — the one the viewport looks at, and what `State.layout` projects.
    public var focusedStrip: Layout {
        get { self[focused] }
        set { self[focused] = newValue }
    }

    /// Move focus to `name`, materializing it if this is its first sight — and deliberately nothing
    /// else: storing the outgoing memory and seeding the incoming viewport read `Motion` and `World`,
    /// which a layout container knows nothing about. What is atomic here is the one thing that must be:
    /// `focused` never names an address that does not exist.
    public mutating func focus(_ name: WorkspaceName) {
        if strips[name] == nil { strips[name] = WorkspaceState() }
        focused = name
    }

    /// The address a `WorkspaceRef` names, against the focused workspace and — for the two occupied
    /// motions — against which strips actually hold a window. **Total, clamping rather than wrapping:**
    /// `next` at `"z"`, `previous` at `"0"` and an occupied motion with nothing ahead all answer the
    /// *focused* workspace, which the caller turns into a no-op in one place.
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
    /// occupied** — a workspace you passed through once should not keep answering `next-non-empty`
    /// forever. Only a materialized address can be non-empty, so scanning `materialized` is complete.
    private func occupied(after name: WorkspaceName) -> WorkspaceName? {
        materialized.first { $0 > name && !self[$0].isEmpty }
    }

    /// The mirror of `occupied(after:)`, taking the *last* candidate below `name` because
    /// `materialized` runs upward.
    private func occupied(before name: WorkspaceName) -> WorkspaceName? {
        materialized.last { $0 < name && !self[$0].isEmpty }
    }

    /// Every materialized address, **in name order** — sorted, because `strips` is a dictionary.
    public var materialized: [WorkspaceName] { strips.keys.sorted() }

    /// The materialized addresses in **placement order**: focused first, then the rest in name order.
    /// Both the order windows are placed in and the order park ordinals are handed out in, so the
    /// focused workspace owns the low ordinals and its nubs never renumber as other addresses fill up.
    public var placementOrder: [WorkspaceName] {
        [focused] + materialized.filter { $0 != focused }
    }

    /// Every window on every strip, in placement order and then layout order within each strip. The set
    /// `Engine` places, and the union `reconcile` maintains.
    public var allWindowIds: [WindowId] {
        placementOrder.flatMap { self[$0].allWindowIds }
    }

    /// The workspace whose strip holds `id`, or `nil` if it is on none (a newcomer, a float, or a
    /// window that has left). Derived, since there is no stored assignment.
    public func workspace(of id: WindowId) -> WorkspaceName? {
        materialized.first { self[$0].columnIndex(ofWindow: id) != nil }
    }

    /// The workspace and column holding `id`, or `nil` — what a question about a window's *column*
    /// needs when the window is not necessarily on the focused strip.
    public func column(containing id: WindowId) -> (workspace: WorkspaceName, column: ColumnLayout)? {
        for name in materialized {
            let strip = self[name]
            if let i = strip.columnIndex(ofWindow: id) { return (name, strip.columns[i]) }
        }
        return nil
    }

    // MARK: - Structural mutation (the two edits that mint)
    //
    // Only `reconcile` and `extract` create columns, so only they need the allocator — and because they
    // need it, they live here rather than being reached through `State.layout`. Every other structural
    // edit is a fact about one strip and goes through the projection unchanged.

    /// Sync every strip to the system's current strip membership. The asymmetry *is* the model:
    /// **departures leave every strip**, while **newcomers join the focused strip only**, beside
    /// `anchor`. Projected onto the focused strip instead, the first workspace switch would treat every
    /// window on every other workspace as a newcomer and suck the lot onto the focused one.
    ///
    /// Also clears a remembered focus no longer on its own strip, making that an invariant of the
    /// container rather than a check somebody has to remember at the switch.
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
        // so it sees them as neither members nor newcomers — what keeps step 2 from undoing step 1.
        var strip = focusedStrip
        strip.reconcile(stripWindowIds: ids.filter { !elsewhere.contains($0) },
                        insertingAfter: anchor, columnIds: &columnIds)
        self[focused] = strip

        // Asked of the strip rather than of `keep`, so one rule covers both ways a memory goes stale:
        // the window left the strip set entirely, or it is still open on a *different* address.
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
    /// single-window column beside `anchor` (or appended). Total: a window on no strip, or one already
    /// on `destination`, no-ops. A window with stackmates leaves them behind, taking its width intent.
    ///
    /// **One call, and that is the point.** The obvious decomposition passes through a state with a
    /// window on *no* strip, which `Workspaces` cannot represent honestly — `workspace(of:)` answers
    /// `nil`, `allWindowIds` omits it, and a placement pass landing in between leaves a real window
    /// wherever it happened to be. That is why `Layout.remove(window:)` is internal.
    ///
    /// - Returns: the edit **as it landed on the source strip**, so `destroyedColumn` names a column
    ///   the departure emptied. The arrival destroys nothing by construction.
    @discardableResult
    public mutating func move(window: WindowId, to destination: WorkspaceName,
                              insertingAfter anchor: WindowId?) -> LayoutEdit {
        guard let source = workspace(of: window), source != destination else { return .none }

        var from = self[source]
        // Read before the removal: the arrival inherits this column's width intent, and after the
        // removal the column may not exist at all.
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

    /// The truth-plane target frame for **every** window on **every** workspace at `scrollOffset`. The
    /// focused strip tiles its on-viewport columns and parks the rest; every other workspace parks in
    /// full, at the size it would have if it were focused.
    ///
    /// The ordinals form **one run** across the whole set, in `placementOrder`, so no two parked windows
    /// anywhere share a nub — a shared park frame would silently break both the ±2 pt first-sight
    /// identity join a daemon restart depends on and the no-overlap invariant.
    public func targetFrames(scrollOffset: Double, metrics: LayoutMetrics) -> [WindowId: Rect] {
        var frames = focusedStrip.targetFrames(scrollOffset: scrollOffset, metrics: metrics)
        var ordinal = focusedStrip.parkedWindowIds(scrollOffset: scrollOffset, metrics: metrics).count
        for name in placementOrder.dropFirst() {
            let strip = self[name]
            // Disjoint by construction — a window is on exactly one strip — so the merge rule is
            // unreachable, not a policy.
            frames.merge(strip.parkedFrames(metrics: metrics, parkingFrom: ordinal)) { existing, _ in existing }
            ordinal += strip.allWindowIds.count
        }
        return frames
    }

    /// Where `name`'s strip is drawn **relative to the focused one** on the presentation plane: nothing
    /// for the focused workspace, one screen *down* for an address sorting after it, one screen *up*
    /// for one sorting before. **Presentation plane only** — on the truth plane an off-workspace window
    /// is simply parked.
    ///
    /// **A sign, not a distance**, so a switch from `1` to `z` animates the same one screen `1` → `2`
    /// does. And the **physical** extent, not the content area, or a neighbour's edge rests inside the
    /// outer-gap margin instead of clearing the screen. Both strips must move by the *same* number to
    /// stay one screen apart, so a content-dependent travel is not an option.
    public func verticalOffset(of name: WorkspaceName, metrics: LayoutMetrics) -> Double {
        guard name != focused else { return 0 }
        return name > focused ? metrics.workingArea.height : -metrics.workingArea.height
    }

    /// The **presentation-plane** frame for every window on every workspace — `Layout.naturalFrames`
    /// across the set, each unfocused strip pushed one screen off by `verticalOffset(of:metrics:)`.
    ///
    /// **Each unfocused strip resolves at its own stored `scrollOffset`, not at the live animator.**
    /// The parameter is the *focused* workspace's; applying it to a strip that is leaving would slide
    /// that strip sideways as it goes instead of straight up or down. `widths` does reach every strip,
    /// since `ColumnId`s are one space across the set and a resize should keep animating as it leaves.
    public func naturalFrames(scrollOffset: Double, metrics: LayoutMetrics,
                              widths: [ColumnId: Double] = [:]) -> [WindowId: Rect] {
        var frames = focusedStrip.naturalFrames(scrollOffset: scrollOffset, metrics: metrics,
                                                widths: widths)
        for name in materialized where name != focused {
            let dy = verticalOffset(of: name, metrics: metrics)
            for (id, frame) in self[name].naturalFrames(scrollOffset: self[scrollOffsetOf: name],
                                                        metrics: metrics, widths: widths) {
                frames[id] = frame.offsetBy(dx: 0, dy: dy)
            }
        }
        return frames
    }

    /// The size the layout would give each window **if nobody had answered back**, for every window on
    /// every strip. Asking only the focused strip would leave every parked window elsewhere unable to
    /// match its own recorded answer, and so re-placed on every event forever.
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
