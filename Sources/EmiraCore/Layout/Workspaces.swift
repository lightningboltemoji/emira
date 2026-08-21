import Foundation

// The 36 workspaces — named `1`…`9`, `0`, then `a`…`z` (`WorkspaceName`) — each its own infinite
// horizontal strip. A window's workspace is *derived*, never stored: it is on the strip whose `Layout`
// contains it, so there is no assignment map that can disagree with the layouts.
//
// **Which strip is on screen is not a fact this container holds.** A workspace is shown because a
// *monitor* shows it (`Monitors`), so every query that depends on the difference between the strip in
// view and the parked remainder takes the shown address as an argument. That is the whole of what
// keeps `Workspaces` a pure structure joined to the displays by a name, rather than a second opinion
// about which display is looking at what.
//
// The set is sparse and never pruned — a name materializes when first shown or first given a window,
// and an unmaterialized name answers as an empty strip, so nothing branches on whether a workspace
// "exists". Every ordered view sorts by `WorkspaceName`, whose `Comparable` is the key order
// `1`…`9`, `0`, `a`…`z` and *not* alphabetical. One `ColumnAllocator` and one park-ordinal run serve
// the whole set (see `ColumnAllocator`, `targetFrames`).

/// One materialized workspace: its strip, plus the two things it remembers about having been looked at.
/// Not reachable as a value — `Workspaces` exposes the three fields as three accessors, so no caller
/// can hold a stale copy beside the container that owns it.
struct WorkspaceState: Sendable, Equatable, Codable {
    /// The strip. The only field of the three that means anything while the workspace is on screen.
    var layout: Layout

    /// The viewport offset focus was last taken away at — per-workspace scroll memory, `0` for a
    /// workspace never shown. Deliberately **stale while this workspace is on screen**, where
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

/// The 36-address workspace set: one `Layout` per materialized address, plus the `ColumnId` allocator
/// they all mint from. Value type, `Codable` including the allocator watermark, so ids stay unique
/// across a serialization round-trip.
public struct Workspaces: Sendable, Equatable, Codable {
    /// The materialized workspaces, keyed by address. Private, so "absent means empty" is true in one
    /// place rather than at each call site. Encoded as a JSON object keyed by the character, so a state
    /// dump reads `"strips": {"1": …}`.
    private var strips: [WorkspaceName: WorkspaceState]

    /// The one `ColumnId` source for every strip. Private, and lent out only by the two mutators below
    /// that mint — which is why those live here rather than on the `Layout` projection.
    private var columnIds: ColumnAllocator

    /// Which height preset each window is pinned to (`cycleHeight`); absent means auto. Kept for the
    /// whole set rather than per strip, so a window carries its height to another workspace without
    /// `move` having to remember to bring it — the same reason one `ColumnAllocator` serves all 36.
    /// Reconciled against the live strip set, so a closed window's selection does not outlive it.
    public private(set) var heightSelections: [WindowId: Int] = [:]

    /// An explicit height that supersedes `heightSelections` until the next `cycleHeight` clears it —
    /// what a window resized by its own handle is pinned to. The height stack's middle rung, and the
    /// exact counterpart of `ColumnLayout.widthOverride`: it *shadows* the ladder rather than replacing
    /// it, so the selection underneath needs no memory and no restore policy.
    ///
    /// Keyed and reconciled beside `heightSelections` for the same reasons, and against the same set.
    public private(set) var heightOverrides: [WindowId: PresetSize] = [:]

    /// A fresh set: one materialized, empty address, nothing else. The launch state, and the address
    /// `Monitors` starts out showing.
    public init(materializing name: WorkspaceName = .first) {
        self.strips = [name: WorkspaceState()]
        self.columnIds = ColumnAllocator()
    }

    /// Construct from explicit strips, materializing `showing` whether or not `strips` mentions it.
    ///
    /// **Never rebuild a live `Workspaces` through this initializer.** The watermark resumes past the
    /// highest *supplied* id, so it rewinds whenever a column has been dropped and the next mint
    /// re-issues an id a `Motion.columnWidths` animator may still be keyed on.
    public init(showing name: WorkspaceName, strips: [WorkspaceName: Layout]) {
        self.strips = strips.mapValues { WorkspaceState(layout: $0) }
        self.strips[name] = self.strips[name] ?? WorkspaceState()
        let highest = strips.values.flatMap { $0.columns.map(\.id.raw) }.max() ?? 0
        self.columnIds = ColumnAllocator(next: highest + 1)
    }

    /// The strip at `name` — an **empty** strip for an address never materialized, so no caller
    /// branches on existence. Assigning materializes it, and never un-materializes.
    public subscript(name: WorkspaceName) -> Layout {
        get { strips[name]?.layout ?? Layout() }
        set { strips[name, default: WorkspaceState()].layout = newValue }
    }

    /// Where `name`'s viewport rested when focus last left it, and where it resumes when focus returns.
    /// An address never shown answers `0`, the strip's origin. Reading does not materialize;
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

    /// Give `name` a strip if it has none. What a monitor showing an address for the first time does,
    /// and deliberately nothing else — storing the outgoing memory and seeding the incoming viewport
    /// read `Motion` and `World`, which a layout container knows nothing about.
    public mutating func materialize(_ name: WorkspaceName) {
        if strips[name] == nil { strips[name] = WorkspaceState() }
    }

    /// The address a `WorkspaceRef` names, from `here` — the address the acting monitor is showing —
    /// **within** the addresses a relative motion may land on. `within` is a set only a caller that
    /// knows about displays can supply (`Monitors.reachable`); an absolute name ignores it entirely,
    /// which is the whole of "absolute refs are global, relative refs are not".
    ///
    /// **Total, clamping rather than wrapping:** `next` at the top of the set, `previous` at the
    /// bottom and an occupied motion with nothing ahead all answer `here`, which the caller turns into
    /// a no-op in one place.
    public func resolve(_ ref: WorkspaceRef, from here: WorkspaceName,
                        within reachable: [WorkspaceName]) -> WorkspaceName {
        switch ref {
        case .name(let name):     return name
        case .next:               return reachable.first { $0 > here } ?? here
        case .previous:           return reachable.last { $0 < here } ?? here
        case .nextOccupied:       return occupied(within: reachable).first { $0 > here } ?? here
        case .previousOccupied:   return occupied(within: reachable).last { $0 < here } ?? here
        }
    }

    /// Every materialized address holding a window, **in name order**. What `next-non-empty` walks and
    /// what a display falling off an address would rather land on (`Monitors.show`).
    ///
    /// **Materialized-and-empty is not occupied** — a workspace you passed through once should not
    /// keep answering `next-non-empty` forever. Only a materialized address can be non-empty, so
    /// scanning `materialized` is complete.
    public var occupied: [WorkspaceName] { materialized.filter { !self[$0].isEmpty } }

    private func occupied(within reachable: [WorkspaceName]) -> [WorkspaceName] {
        let allowed = Set(reachable)
        return occupied.filter(allowed.contains)
    }

    /// Every materialized address, **in name order** — sorted, because `strips` is a dictionary.
    public var materialized: [WorkspaceName] { strips.keys.sorted() }

    /// The materialized addresses in **placement order**: the addresses on screen first, in `shown`'s
    /// own order (acting monitor first), then the rest in name order. Both the order windows are placed
    /// in and the order park ordinals are handed out in, so a visible strip owns the low ordinals and
    /// its nubs never renumber as other addresses fill up.
    public func placementOrder(shown: [WorkspaceName]) -> [WorkspaceName] {
        shown + materialized.filter { !shown.contains($0) }
    }

    /// Every window on every strip — the set `Engine` places and the union `reconcile` maintains, in
    /// name order and then layout order within each strip. **Membership, not stacking:** a caller whose
    /// answer is a z-order asks `windowIds(inPlacementOrder:)` instead, and the two are distinct
    /// questions rather than one query with a spare argument.
    public var allWindowIds: [WindowId] {
        materialized.flatMap { self[$0].allWindowIds }
    }

    /// Every window on every strip, back-to-front: `placementOrder(shown:)`, then layout order inside
    /// each strip. What a cover's layer bindings and the quit cascade stack in — the strips on screen
    /// at the bottom, the parked remainder above them in name order.
    public func windowIds(inPlacementOrder shown: [WorkspaceName]) -> [WindowId] {
        placementOrder(shown: shown).flatMap { self[$0].allWindowIds }
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

    // Structural mutation (the two edits that mint)
    //
    // Only `reconcile` and `extract` create columns, so only they need the allocator — and because they
    // need it, they live here rather than being reached through `State.layout`. Every other structural
    // edit is a fact about one strip and goes through the projection unchanged.

    /// Sync every strip to the system's current strip membership. The asymmetry *is* the model:
    /// **departures leave every strip**, while **newcomers join one strip only** — `home`, the address
    /// the acting monitor is showing — beside `anchor`. Projected onto every strip instead, the first
    /// workspace switch would treat every window on every other workspace as a newcomer and suck the
    /// lot onto the one in view.
    ///
    /// Also clears a remembered focus no longer on its own strip, making that an invariant of the
    /// container rather than a check somebody has to remember at the switch.
    public mutating func reconcile(stripWindowIds ids: [WindowId], onto home: WorkspaceName,
                                   insertingAfter anchor: WindowId? = nil) {
        materialize(home)
        let keep = Set(ids)
        var elsewhere: Set<WindowId> = []
        for name in materialized where name != home {
            var strip = self[name]
            strip.removeWindows(notIn: keep)
            self[name] = strip
            elsewhere.formUnion(strip.allWindowIds)
        }
        // Windows living on another workspace are subtracted before the home strip is reconciled, so
        // it sees them as neither members nor newcomers — what keeps step 2 from undoing step 1.
        var strip = self[home]
        strip.reconcile(stripWindowIds: ids.filter { !elsewhere.contains($0) },
                        insertingAfter: anchor, columnIds: &columnIds)
        self[home] = strip

        // Asked of the strip rather than of `keep`, so one rule covers both ways a memory goes stale:
        // the window left the strip set entirely, or it is still open on a *different* address.
        for name in materialized {
            guard let remembered = strips[name]?.lastFocus,
                  self[name].columnIndex(ofWindow: remembered) == nil else { continue }
            strips[name]?.lastFocus = nil
        }

        // A height pinned to a window that has left every strip — closed, minimized, floated — goes
        // with it. Asked of `keep` rather than of the strips, so a window in flight between two of
        // them keeps its height.
        heightSelections = heightSelections.filter { keep.contains($0.key) }
        heightOverrides = heightOverrides.filter { keep.contains($0.key) }
    }

    /// Step `window` to the next height preset, wrapping through **auto**: absent → 0 → … → last →
    /// absent. Auto is a rung of the ladder rather than a state you can only leave, so one verb reaches
    /// every selection *and* gets back home — the alternative is a second verb whose only job is
    /// "un-pin". Total: an empty cycle, or an index drifted past a shortened one, resolves to auto.
    ///
    /// Clears any explicit override, exactly as `Layout.setWidthPreset` clears `widthOverride`: a cycle
    /// resumes the ladder where it was last left rather than guessing which rung a dragged height was
    /// nearest.
    public mutating func cycleHeight(of window: WindowId, through cycle: PresetCycle) {
        heightOverrides[window] = nil
        guard cycle.count > 0, let current = heightSelections[window] else {
            heightSelections[window] = cycle.count > 0 ? 0 : nil
            return
        }
        let next = current + 1
        heightSelections[window] = next < cycle.count ? next : nil
    }

    /// Pin `window` to an explicit height until the next `cycleHeight` — how a resize by the window's
    /// own handle records its answer, and the height counterpart of `Layout.setWidthOverride`.
    /// Deliberately **not** bounds-checked, for the same reason that one isn't: the bound depends on
    /// the column's height and on what its other windows have already been promised, neither of which
    /// is this container's to know.
    public mutating func setHeightOverride(_ size: PresetSize, of window: WindowId) {
        heightOverrides[window] = size
    }

    /// Send `window` back to sharing its column's leftover height — both rungs of its height intent
    /// dropped at once. What the neighbour on a dragged divider takes, so the water-fill has somebody
    /// to hand the difference to; total, and a no-op for a window already auto.
    public mutating func clearHeightIntent(of window: WindowId) {
        heightOverrides[window] = nil
        heightSelections[window] = nil
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
    /// **Internal, so that `State.move(window:to:insertingAfter:)` is the only way in.** Landing a
    /// window on `destination` materializes it, and an address with a strip belongs to a display — a
    /// fact this container is deliberately unable to record, which makes calling this alone a way to
    /// break invariant 2 rather than a shortcut. The same reason `Layout.remove(window:)` is internal.
    ///
    /// - Returns: the edit **as it landed on the source strip**, so `destroyedColumn` names a column
    ///   the departure emptied. The arrival destroys nothing by construction.
    @discardableResult
    mutating func move(window: WindowId, to destination: WorkspaceName,
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

    // Geometry across the whole set

    /// The truth-plane target frame for **every** window on **every** workspace, one strip per
    /// `StripPlacement` in the order given: an address on screen tiles at its own display's offset and
    /// metrics, everything else parks in full against the metrics of the display that holds it.
    ///
    /// **The supply is per display and the run is not.** The ordinals form **one run** across the whole
    /// set, in the order handed in, so no two parked windows anywhere share a nub — every display's
    /// metrics carry the *same* lot (`ParkingLot.init(among:)`), so a cursor per strip would hand two
    /// windows one slot outright, breaking both the ±2 pt first-sight identity join a daemon restart
    /// depends on and the no-overlap invariant. One cursor makes uniqueness unconditional; the cost is
    /// that a later strip's nubs start in a higher lane.
    ///
    /// The cursor is carried *through* each strip rather than advanced by counting windows out here: a
    /// window with a park floor takes the first slot tall enough for it and leaves the skipped ones
    /// unused, so how far a strip advanced the run is something only the run knows.
    public func targetFrames(_ placements: [StripPlacement]) -> [WindowId: Rect] {
        var cursor = 0
        var frames: [WindowId: Rect] = [:]
        for placement in placements {
            let strip = self[placement.name]
            // Disjoint by construction — a window is on exactly one strip — so the merge rule is
            // unreachable, not a policy.
            let theirs = placement.scrollOffset.map {
                strip.targetFrames(scrollOffset: $0, metrics: placement.metrics, parkingFrom: &cursor)
            } ?? strip.parkedFrames(metrics: placement.metrics, parkingFrom: &cursor)
            frames.merge(theirs) { existing, _ in existing }
        }
        return frames
    }

    /// Where `name`'s strip is drawn **relative to `shown`**, the address on screen, on the presentation
    /// plane: nothing for `shown` itself, one screen *down* for an address sorting after it, one screen
    /// *up* for one sorting before. **Presentation plane only** — on the truth plane an off-workspace
    /// window is simply parked.
    ///
    /// **A sign, not a distance**, so a switch from `1` to `z` animates the same one screen `1` → `2`
    /// does. And the **physical** extent, not the content area, or a neighbour's edge rests inside the
    /// outer-gap margin instead of clearing the screen. Both strips must move by the *same* number to
    /// stay one screen apart, so a content-dependent travel is not an option.
    public func verticalOffset(of name: WorkspaceName, from shown: WorkspaceName,
                               metrics: LayoutMetrics) -> Double {
        guard name != shown else { return 0 }
        return name > shown ? metrics.workingArea.height : -metrics.workingArea.height
    }

    /// The **presentation-plane** frame for every window on the strips one display holds —
    /// `Layout.naturalFrames` across `owned`, each off-screen strip pushed one screen off by
    /// `verticalOffset(of:from:metrics:)`.
    ///
    /// **Restricted to `owned`, because this answers for one display's cover.** A strip another screen
    /// holds is drawn by that screen's cover, at its metrics and its offset; laid out here it would put
    /// a second copy of itself a screen above or below this display's viewport.
    ///
    /// **Each off-screen strip resolves at its own stored `scrollOffset`, not at the live animator.**
    /// The parameter is `shown`'s; applying it to a strip that is leaving would slide that strip
    /// sideways as it goes instead of straight up or down. `widths` does reach every strip, since
    /// `ColumnId`s are one space across the set and a resize should keep animating as it leaves.
    public func naturalFrames(shown: WorkspaceName, among owned: [WorkspaceName], scrollOffset: Double,
                              metrics: LayoutMetrics,
                              widths: [ColumnId: Double] = [:]) -> [WindowId: Rect] {
        var frames = self[shown].naturalFrames(scrollOffset: scrollOffset, metrics: metrics,
                                               widths: widths)
        for name in owned where name != shown {
            let dy = verticalOffset(of: name, from: shown, metrics: metrics)
            for (id, frame) in self[name].naturalFrames(scrollOffset: self[scrollOffsetOf: name],
                                                        metrics: metrics, widths: widths) {
                frames[id] = frame.offsetBy(dx: 0, dy: dy)
            }
        }
        return frames
    }

    /// The size the layout would give each window **if nobody had answered back**, for every window on
    /// every strip, each against the metrics of the display that holds it. Asking only the strip on
    /// screen would leave every parked window elsewhere unable to match its own recorded answer, and so
    /// re-placed on every event forever.
    public func uncorrectedSizes(_ placements: [StripPlacement]) -> [WindowId: Size] {
        var sizes: [WindowId: Size] = [:]
        for placement in placements {
            for (id, frame) in self[placement.name].naturalFrames(scrollOffset: 0,
                                                                  metrics: placement.metrics.uncorrected) {
                sizes[id] = frame.size
            }
        }
        return sizes
    }
}

/// One address's place in a placement pass: the geometry it is laid out against, and — for an address
/// on screen — the offset its display's viewport is at. `nil` parks the strip in full.
///
/// The supply that lets `Workspaces` stay a pure structure while the desktop has several displays: it
/// carries the answers `Monitors` and `Motion` hold (whose display, at what offset) without this
/// container having to know either of them exists. Built by `State.placements()`, which is the join.
public struct StripPlacement: Sendable, Equatable {
    public let name: WorkspaceName
    public let metrics: LayoutMetrics
    public let scrollOffset: Double?

    public init(name: WorkspaceName, metrics: LayoutMetrics, scrollOffset: Double?) {
        self.name = name
        self.metrics = metrics
        self.scrollOffset = scrollOffset
    }
}
