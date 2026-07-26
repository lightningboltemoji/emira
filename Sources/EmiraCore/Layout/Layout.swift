import Foundation

// The layout assembler (IMPLEMENTATION.md §5, `Layout/Layout.swift`) — the struct that turns the
// pure strip/column/park math into **concrete per-window target frames**. Where `Strip` (x-axis),
// `Column` (y-axis), and `ParkingLot` (off-viewport slots) are each a piece of geometry, `Layout`
// holds the *structure* — the ordered columns and which windows stack in each — and computes, for a
// given scroll offset and monitor/config metrics, the target `Rect` every managed window should
// occupy: its tiled frame if its column is on-screen, or a park slot if the column has been scrolled
// off the viewport (PRINCIPLES.md §3 — "scrolling the strip is just repositioning windows so a
// different slice enters the viewport"; off-viewport columns park as slivers, §4a/§10).
//
// **Structure vs. metrics — the seam.** `Layout` stores only structure (columns, their window
// stacks, each column's cycled width-preset index) and the column-id allocator. Everything that
// depends on the *monitor* (working area) or *config* (width presets, gaps) is passed in per call as
// `LayoutMetrics`, never stored — because those change independently (display hotplug, config
// reload) and are owned elsewhere (World's monitors, the reducer's Config). So the same structural
// `Layout` re-resolves against a new monitor or new gaps for free, and `Layout` stays a pure record
// of arrangement. This mirrors the "mechanism here, policy/inputs upstream" seam the rest of the
// core keeps.
//
// **Coordinate transform.** Columns are placed in *virtual-strip* space (infinite x, origin 0) by
// `Strip`; a window's on-screen frame is `workingArea.minX + (stripX − scrollOffset)` — the strip
// position pulled into the viewport. `y`/`height` come straight from the working area (columns fill
// its height). Parked windows are already in screen space (they hug the working area's edge). All
// top-left origin (Geometry.swift), same as everything the shell will Y-flip once at its boundary.
//
// Scope of this slice (deferrals, documented so the gaps read as intentional):
//  · **One strip = one workspace on one monitor.** Multiple workspaces (a collection of strips) and
//    per-monitor strips are M6 — a `Layout` here is a single strip. The `LayoutMetrics.workingArea`
//    is the monitor's; a multi-strip container wraps this later.
//  · **Heights are all-auto.** Per-window height *selection* (the persistent `cycleHeight` state) is
//    a later slice; every window currently shares its column's height equally (`Column`'s auto path,
//    already tested). Width-preset cycling *is* modeled (each column carries a `widthPreset` index),
//    since column width is the load-bearing horizontal-strip knob.
//  · **Structural edits are primitives here, policy in the reducer.** Four mutators — `moveColumn`,
//    `moveWindowWithinColumn`, `move(window:toColumn:at:)`, `extract(window:toNewColumnAt:)` — are the
//    complete alphabet the strip's editing commands compose from. They are deliberately *not* the
//    verbs: "alone in its column ⇒ the column moves, stacked ⇒ the window pops out" is a choice,
//    and choices live beside `handleFocus`, which already makes the same distinction. Two rules bind
//    every mutator: each is **atomic over the invariants** (no caller ever observes an empty column or
//    a window in none), and **new `ColumnId`s are minted only in this file** — never by rebuilding
//    through `init(columns:)`, which rewinds the allocator (see its doc).
//  · **A structural edit is animated from the outside, and `Layout` keeps no before-state.** Unlike a
//    scroll (one offset) or a resize (one width per column), an edit that inserts or removes a column
//    shifts the strip *discretely* — before and after are two different `Layout`s, not two values of
//    one, so there is no scalar here to interpolate. The reducer animates it anyway, by asking
//    `naturalFrames` the *same question either side of the mutation* (same offset, same `widths:`
//    override) and putting the difference under a spring as a per-window displacement decaying to
//    zero (`Motion.windowAnimators`, `Engine.finishStructuralEdit`). So this type stays what it was —
//    the authority on where a window belongs *now* — and the animation lives entirely in the lag
//    behind that answer. `naturalFrames`'s `widths:` override now has two callers keeping the same
//    discipline: pass one map, use it for both reads, or the delta stops being purely structural.
//  · **Cross-workspace / cross-monitor moves** (`moveToWorkspace`, `moveToMonitor`) are M6 — they move
//    a window between *strips*, which needs the multi-strip container that doesn't exist yet.

/// One column's structure: its stable id, the ordered window stack (top→bottom), and the index of
/// its currently-selected width preset (cycled by `cycleWidth`; resolved against the monitor at
/// layout time via the width `PresetCycle`). Pure data; the geometry is computed by `Layout`.
public struct ColumnLayout: Sendable, Equatable, Codable {
    /// Stable identity across relayouts — the handle animation and consume/expel key on. Minted by
    /// the owning `Layout`.
    public let id: ColumnId
    /// The window stack, top→bottom. Array order *is* vertical stacking order. Non-empty for any
    /// column that survives `reconcile` (emptied columns are dropped).
    public var windowIds: [WindowId]
    /// Index into the width `PresetCycle` (supplied via `LayoutMetrics`). Stored as an index, not a
    /// resolved width, so cycling is stable across monitors (a ½-width column stays ½ on any display)
    /// and resolution normalizes any drift (`Presets.swift`).
    public var widthPreset: Int

    public init(id: ColumnId, windowIds: [WindowId], widthPreset: Int = 0) {
        self.id = id
        self.windowIds = windowIds
        self.widthPreset = widthPreset
    }
}

/// The monitor + config inputs a `Layout` resolves against — passed per call, never stored (see the
/// type doc). Everything here is owned elsewhere: `workingArea` derives from World's monitor set
/// (strut-inset by the shell), the presets/gaps from the reducer's `Config`.
public struct LayoutMetrics: Sendable, Equatable {
    /// The monitor's working area — screen-space, top-left, already inset past the menu bar/Dock by
    /// the shell. Columns fill its height; its width is the viewport width; parked slivers hug it.
    public var workingArea: Rect
    /// The width presets a column cycles through (`cycleWidth`). A column's `widthPreset` indexes it.
    public var widthPresets: PresetCycle
    /// Gap between adjacent columns on the strip (inter-column only).
    public var columnGap: Double
    /// Gap between vertically-adjacent windows within a column (inter-window only).
    public var windowGap: Double
    /// What each window last answered when asked to be a size (`World.corrections`) — the facts that
    /// let a column be as wide as the app *actually is* rather than as wide as the preset wished.
    ///
    /// It rides in `metrics` for one reason, and it is the same reason `ScreenGeometry` owns exactly
    /// one Y-flip: **every** geometry entry point on `Layout` already takes `metrics`, so a correction
    /// cannot be forgotten at a call site. It has to reach all of them — a `targetFrames` that widened
    /// a column while `visibleWindowIds`/`sweptWindowIds`/`scrollOffsetToReveal` still used the preset
    /// would accumulate different left edges and place windows at the wrong x. Making that impossible
    /// beats making it someone's job to remember.
    ///
    /// (Contrast `strip(metrics:widths:)`'s separate `widths` parameter, which is deliberately reachable
    /// from one caller: that one is a presentation-plane animation override, not a fact about the strip.)
    public var corrections: [WindowId: SizeCorrection]

    public init(
        workingArea: Rect,
        widthPresets: PresetCycle = .defaultWidths,
        columnGap: Double = 0,
        windowGap: Double = 0,
        corrections: [WindowId: SizeCorrection] = [:]
    ) {
        self.workingArea = workingArea
        self.widthPresets = widthPresets
        self.columnGap = columnGap
        self.windowGap = windowGap
        self.corrections = corrections
    }

    /// These metrics with every correction dropped — the geometry as the presets alone would have it.
    /// This is how "the question" is defined (`Layout.uncorrectedSize`): by running the *same* code
    /// with no answers available, so the question and the corrected answer can never drift apart.
    public var uncorrected: LayoutMetrics {
        var copy = self
        copy.corrections = [:]
        return copy
    }
}

/// What one structural mutation did — enough for the reducer to finish the job without re-deriving
/// it. Returned by every mutator in `Layout`'s structural-mutation section, so a call site reads the
/// same way whichever edit it made.
///
/// Two facts, and each is there because the caller cannot recover it afterwards. `moved` separates
/// "the edit happened" from "the edit was a total no-op" (an edge, an unknown id, a move onto
/// itself) — indistinguishable from the outside once the call has returned. `destroyedColumn` names
/// the column the edit emptied: `Layout` drops it to keep its non-empty invariant, but `Motion` may
/// still hold an in-flight width animator keyed by that `ColumnId`, and nothing else will ever
/// mention it again (`Engine.finishStructuralEdit` retires it).
///
/// Not `Codable`, deliberately: this is a return value, not state, and nothing should dump it.
public struct LayoutEdit: Sendable, Equatable {
    /// Whether the structure actually changed. `false` ⇒ nothing was touched, not even the column-id
    /// allocator.
    public let moved: Bool
    /// The column this edit destroyed (its last window left it), or `nil`. At most one column can be
    /// emptied by a single-window move, so this is one id rather than a list.
    public let destroyedColumn: ColumnId?

    public init(moved: Bool, destroyedColumn: ColumnId?) {
        self.moved = moved
        self.destroyedColumn = destroyedColumn
    }

    /// The no-op result — the total answer for an unknown id, an edge, or a move onto itself.
    public static let none = LayoutEdit(moved: false, destroyedColumn: nil)
}

/// The arrangement of one strip: its ordered columns and the allocator that mints their ids. Holds
/// structure only; frames are computed on demand from a `scrollOffset` + `LayoutMetrics`. Value type,
/// `Codable` for state dumps / replay (the allocator watermark is part of that state, so ids stay
/// unique across a serialization round-trip).
public struct Layout: Sendable, Equatable, Codable {
    /// The columns, left→right. `private(set)` so the one structural invariant — every column is
    /// non-empty and each window appears in at most one column — is maintained only through the
    /// mutators below.
    public private(set) var columns: [ColumnLayout]
    /// Monotonic `ColumnId` watermark — the next raw id to mint. Part of serialized state so replay
    /// reproduces identical ids (IMPLEMENTATION.md §7). Never rewinds.
    private var nextColumnRaw: UInt64

    /// An empty strip — no columns. Populate via `reconcile`.
    public init() {
        self.columns = []
        self.nextColumnRaw = 1
    }

    /// Construct from an explicit column arrangement (for the reducer building a specific layout, and
    /// for tests). The allocator resumes past the highest id present, so subsequent `reconcile`
    /// mints never collide with the supplied columns.
    ///
    /// **Never rebuild an existing `Layout` through this initializer.** The watermark resumes past the
    /// highest *supplied* id, so it **rewinds** whenever a column has been dropped — and the next mint
    /// then re-issues a `ColumnId` that a `Motion.columnWidths` animator (and the cover's animation
    /// identity) may still be keyed on. The structural mutators below edit `columns` in place for
    /// exactly this reason.
    public init(columns: [ColumnLayout]) {
        self.columns = columns
        self.nextColumnRaw = (columns.map(\.id.raw).max() ?? 0) + 1
    }

    public var isEmpty: Bool { columns.isEmpty }

    private mutating func mintColumnId() -> ColumnId {
        defer { nextColumnRaw += 1 }
        return ColumnId(nextColumnRaw)
    }

    // MARK: - Membership queries

    /// The index of the column containing `id`, or `nil` if the window is on no column (not on this
    /// strip). The strip's columns are the ordered unit reveal/center scroll math keys off.
    public func columnIndex(ofWindow id: WindowId) -> Int? {
        columns.firstIndex { $0.windowIds.contains(id) }
    }

    /// The column with the given id, or `nil`.
    public func columnIndex(withId id: ColumnId) -> Int? {
        columns.firstIndex { $0.id == id }
    }

    /// Every window on the strip, in column-then-stack order — the deterministic flattening of the
    /// structure (distinct from `World.stripWindowIds`, which is id-sorted; this one is *layout*
    /// order, left→right, top→bottom).
    public var allWindowIds: [WindowId] {
        columns.flatMap(\.windowIds)
    }

    // MARK: - Structural mutation

    /// Sync the column structure to the strip's current membership (the World→Layout bridge — the
    /// reducer calls this with `World.stripWindowIds`). Windows no longer present are dropped and any
    /// column they empty is removed; windows newly present are appended as fresh single-window columns
    /// in input order. Existing columns keep their id and their surviving stack order, so animation
    /// identity and the user's arrangement are preserved across enumeration churn. Total — a repeat
    /// call with the same set is a no-op.
    /// - Parameter anchor: the window a newcomer should open **beside** — a new column immediately
    ///   right of the focused one, pushing the rest of the strip along (2026-07-26). `nil`,
    ///   or a window with no column of its own, falls back to appending at the far end.
    ///
    ///   The anchor must be the window focused *before* the newcomer arrived: the reducer gives a new
    ///   window focus on sight, and by the time this runs it has no column to sit beside yet.
    public mutating func reconcile(stripWindowIds ids: [WindowId],
                                   insertingAfter anchor: WindowId? = nil) {
        let target = Set(ids)
        // 1. Drop departed windows; remove any column left empty.
        for i in columns.indices {
            columns[i].windowIds.removeAll { !target.contains($0) }
        }
        columns.removeAll { $0.windowIds.isEmpty }
        // 2. Insert newcomers (present in `ids`, absent from every column) as new single-window
        //    columns, preserving `ids` order, beside the anchor or at the end.
        let present = Set(allWindowIds)
        let newcomers = ids.filter { !present.contains($0) }
        guard !newcomers.isEmpty else { return }
        var at = anchor.flatMap { columnIndex(ofWindow: $0) }.map { $0 + 1 } ?? columns.count
        for id in newcomers {
            columns.insert(ColumnLayout(id: mintColumnId(), windowIds: [id], widthPreset: 0), at: at)
            at += 1
        }
    }

    /// Set a column's width-preset index (the reducer computes the next index via the width
    /// `PresetCycle` when handling `cycleWidth`, then stores it here). Keyed by `ColumnId` for
    /// stability; no-op if the column is gone. Resolution normalizes any index, so no range check.
    public mutating func setWidthPreset(_ index: Int, ofColumn id: ColumnId) {
        guard let i = columnIndex(withId: id) else { return }
        columns[i].widthPreset = index
    }

    // MARK: - Structural mutation (the strip's editing primitives)
    //
    // The four edits every structural command composes from (`moveWindow`, `consumeOrExpel` — and the
    // workspace/monitor moves when they land). They share three properties, and each is load-bearing:
    //
    //  · **Total.** An unknown id, an out-of-range destination, or a move onto the current position is
    //    a silent no-op returning `.none`, never a trap — the same contract `setWidthPreset` keeps.
    //    Indices *clamp* rather than reject, which is what makes the reducer's "no wrap at the strip's
    //    edge" rule fall out of the arithmetic instead of being enforced twice.
    //  · **Atomic over the invariants.** Every legal edit is exactly one call, because the obvious
    //    decomposition — "remove the window from its column", then "insert a column for it" — passes
    //    through a state with an empty column, and a `private(set)` array cannot protect an invariant
    //    its clients are trusted to restore on the next line.
    //  · **Policy-free.** Which direction is which, and whether a stacked window pops out or its whole
    //    column moves, is the reducer's call (`Engine.handleMoveWindow`). These just move things.

    /// Move the column with `id` to strip index `index`, sliding the columns between them along — the
    /// whole-column reorder behind `move-window left|right` for a window alone in its column.
    ///
    /// Keyed by `ColumnId` rather than by index for the reason `setWidthPreset` is: an index is a fact
    /// about an array the caller may have re-derived, an id is a fact about the column. `index` is the
    /// column's position in the **resulting** array, clamped into `0..<columns.count` — so a
    /// destination past either end is a no-op rather than a trap, which is precisely the strip's
    /// no-wrap rule. Membership is untouched, so nothing can be emptied (`destroyedColumn` is always
    /// `nil`). Total: an unknown id, or a column already at `index`, no-ops.
    @discardableResult
    public mutating func moveColumn(_ id: ColumnId, to index: Int) -> LayoutEdit {
        guard let from = columnIndex(withId: id) else { return .none }
        let to = Swift.min(Swift.max(index, 0), columns.count - 1)
        guard to != from else { return .none }
        let column = columns.remove(at: from)
        columns.insert(column, at: to)
        return LayoutEdit(moved: true, destroyedColumn: nil)
    }

    /// Move `window` to stack index `row` **within its own column** — the reorder behind
    /// `move-window up|down`. `row` clamps into the column's own index range, so the top window moved
    /// up and the bottom window moved down are no-ops, matching the strip's no-wrap rule one axis
    /// over. Column membership never changes, so nothing is destroyed. Total: a window on no column,
    /// or already at `row`, no-ops.
    @discardableResult
    public mutating func moveWindowWithinColumn(_ window: WindowId, to row: Int) -> LayoutEdit {
        guard let i = columnIndex(ofWindow: window),
              let from = columns[i].windowIds.firstIndex(of: window) else { return .none }
        let to = Swift.min(Swift.max(row, 0), columns[i].windowIds.count - 1)
        guard to != from else { return .none }
        columns[i].windowIds.remove(at: from)
        columns[i].windowIds.insert(window, at: to)
        return LayoutEdit(moved: true, destroyedColumn: nil)
    }

    /// Move `window` **into** the existing column `target`, at stack index `row` — the merge behind a
    /// *consume*. `row` clamps into `0...` the target's window count, so `0` is the top of the stack
    /// and `count` appends at the bottom. If `window`'s old column is left empty it is removed and its
    /// id reported as `destroyedColumn`.
    ///
    /// Total, and each refusal is deliberate: an unknown window, an unknown target, and a `target`
    /// that **is** the window's own column all no-op. The last one matters — a same-column reposition
    /// is `moveWindowWithinColumn`'s job, and handling it here would have to special-case a removal
    /// that empties the very column it is inserting into.
    ///
    /// Note the window's new width comes from the column it joins; the one it left keeps its own
    /// preset. A consume is a membership change, and there is no meaningful way to merge two widths.
    @discardableResult
    public mutating func move(window: WindowId, toColumn target: ColumnId, at row: Int) -> LayoutEdit {
        guard let from = columnIndex(ofWindow: window),
              let to = columnIndex(withId: target),
              to != from else { return .none }
        let insertion = Swift.min(Swift.max(row, 0), columns[to].windowIds.count)
        // Insert into the destination *first*, then remove from the source. The window is transiently
        // in two columns, which is unobservable from outside a `mutating` call, and it removes the
        // index-shift hazard entirely: dropping the emptied source column shifts every index to its
        // right, so a remove-first order would have to re-find `to` afterwards. Safe **only** because
        // `to != from` is guarded above — otherwise the removal would delete the copy just inserted.
        columns[to].windowIds.insert(window, at: insertion)
        columns[from].windowIds.removeAll { $0 == window }
        guard columns[from].windowIds.isEmpty else {
            return LayoutEdit(moved: true, destroyedColumn: nil)
        }
        let destroyed = columns[from].id
        columns.remove(at: from)
        return LayoutEdit(moved: true, destroyedColumn: destroyed)
    }

    /// Move `window` **out** into a freshly-minted single-window column inserted at strip index
    /// `index` — the split behind an *expel*, and the only way a column is created outside
    /// `reconcile`. `index` clamps into `0...columns.count`, so `0` inserts at the strip's origin and
    /// `columns.count` appends past the right end; both are ordinary positions on an infinite axis
    /// (`Strip.leftEdge(of:)` is defined over exactly that range, for exactly this caller).
    ///
    /// **A window already alone in its column is a no-op**, not a rebuild. The literal reading —
    /// destroy the column, mint a replacement holding the same one window — yields a structurally
    /// identical layout with a *different* `ColumnId`, and that id is the handle `Motion.columnWidths`
    /// and the cover's animation identity key on. That guard is also what guarantees nothing is ever
    /// destroyed here, so `destroyedColumn` is always `nil`.
    ///
    /// The new column **inherits the source's `widthPreset`**: the window is on screen at that width,
    /// and since a structural edit snaps, resetting the preset would be a second unrequested change
    /// arriving in the same instant jump.
    @discardableResult
    public mutating func extract(window: WindowId, toNewColumnAt index: Int) -> LayoutEdit {
        // The guard precedes the mint on purpose: `Layout`'s synthesized `Equatable` covers the
        // private allocator watermark, so a stray mint on the no-op path is a visible state change.
        guard let from = columnIndex(ofWindow: window),
              columns[from].windowIds.count > 1 else { return .none }
        let preset = columns[from].widthPreset
        let to = Swift.min(Swift.max(index, 0), columns.count)
        columns[from].windowIds.removeAll { $0 == window }   // never empties it (count > 1 above)
        columns.insert(ColumnLayout(id: mintColumnId(), windowIds: [window], widthPreset: preset),
                       at: to)
        return LayoutEdit(moved: true, destroyedColumn: nil)
    }

    // MARK: - Geometry

    /// The resolved `Strip` for these columns against `metrics` — each column width taken from its
    /// cycled preset resolved against the working width. The handle for the reducer's scroll math.
    ///
    /// `widths` overrides individual columns with a width in **points**, and exists for exactly one
    /// caller: the presentation plane mid-`cycleWidth`, where `Motion.currentColumnWidths` holds a
    /// column's width part-way between two presets (`Motion`'s `columnWidths`). Everything else — the
    /// truth plane's `targetFrames`, the visibility and sweep queries, the scroll targets — passes
    /// nothing and gets the presets, because those questions are all about where the strip is *going*,
    /// which is a fact about the layout and not about the frame we happen to be on.
    ///
    /// An override for an unknown column is ignored (it fell out of the layout mid-resize) and a column
    /// with no override keeps its preset, so a partial map is meaningful rather than all-or-nothing.
    public func strip(metrics: LayoutMetrics, widths: [ColumnId: Double] = [:]) -> Strip {
        let resolved = columns.map { column in
            widths[column.id] ?? resolvedWidth(of: column, metrics: metrics)
        }
        return Strip(columnWidths: resolved, gap: metrics.columnGap)
    }

    /// A column's width in points: its cycled preset, **widened** to the widest size any of its
    /// windows answered when last asked for that preset (`SizeCorrection`).
    ///
    /// Widening only. A window that came back *narrower* than we asked leaves a gap inside its column,
    /// which is cosmetic; one that came back wider would overlap the next column, which breaks the
    /// strip's one promise. So only the second direction moves geometry — the first is handled by not
    /// asking again (`Engine.alreadyAnswered`).
    ///
    /// Capped at the working width. Two stacked windows on *different* quantization grids can chase
    /// each other a few points at a time — A widens the column, B answers wider still — and while that
    /// does terminate (at the grids' common multiple), the cap bounds it absolutely. It costs nothing
    /// real: a column that wide already fills the viewport, and `Strip.offsetToReveal` handles an
    /// over-wide column by showing its left edge.
    public func resolvedWidth(of column: ColumnLayout, metrics: LayoutMetrics) -> Double {
        let preset = metrics.widthPresets.resolved(at: column.widthPreset,
                                                   available: metrics.workingArea.width)
        let floors = column.windowIds.compactMap {
            metrics.corrections[$0]?.widthFloor(forQuestion: preset)
        }
        guard let widest = floors.max() else { return preset }
        return Swift.min(Swift.max(preset, widest), metrics.workingArea.width)
    }

    /// A column's resolved width by id — what `cycleWidth` must animate *to*, so the presentation
    /// plane converges on the same number the truth plane teleported the reals to. `nil` if no such
    /// column is on the strip.
    public func resolvedWidth(ofColumn id: ColumnId, metrics: LayoutMetrics) -> Double? {
        columnIndex(withId: id).map { resolvedWidth(of: columns[$0], metrics: metrics) }
    }

    /// The size the layout would give this window **if no window had ever answered back** — the
    /// *question* a `SizeCorrection` is the answer to (see `SizeCorrection`). `nil` if the window
    /// isn't on the strip.
    ///
    /// Derived by asking the ordinary geometry with `metrics.uncorrected`, so it is the same code path
    /// and cannot drift from the corrected answer. Position is irrelevant here and the scroll offset is
    /// therefore arbitrary — `Column`'s sizes don't depend on x, and neither does the auto height share.
    public func uncorrectedSize(of window: WindowId, metrics: LayoutMetrics) -> Size? {
        naturalFrames(scrollOffset: 0, metrics: metrics.uncorrected)[window]?.size
    }

    /// Per-column window frames in **strip space** (x from the strip, y/height from the working area),
    /// before any viewport pull or parking is applied. The shared basis for `targetFrames` (visible →
    /// pull into the viewport, off-view → park) and `naturalFrames` (always pull into the viewport).
    /// `Column`'s sizes are independent of x, so a strip-space box is valid whether the column ends up
    /// tiled, parked, or slid off-screen — only its *position* is chosen downstream. Indexed by column.
    private func columnStripFrames(_ s: Strip, area: Rect, metrics: LayoutMetrics) -> [[Rect]] {
        columns.enumerated().map { (i, column) in
            let box = Rect(x: s.leftEdge(of: i), y: area.minY,
                           width: s.columnWidths[i], height: area.height)
            // The height each window would get with nobody answering back — the question its own
            // `SizeCorrection` is keyed against. Stable given the column's population and the working
            // area, which is exactly what keeps a floor from re-deriving itself every pass.
            let share = Column(frame: box,
                               windowHeights: Array(repeating: .auto, count: column.windowIds.count),
                               gap: metrics.windowGap).resolvedHeights()
            return Column(
                frame: box,
                windowHeights: Array(repeating: .auto, count: column.windowIds.count),
                gap: metrics.windowGap,
                minHeights: zip(column.windowIds, share).map { id, question in
                    metrics.corrections[id]?.heightFloor(forQuestion: question)
                }
            ).windowFrames()
        }
    }

    /// **The payoff:** the target frame for every managed window at the given `scrollOffset`. A window
    /// whose column overlaps the viewport gets its tiled frame (strip position pulled into the
    /// viewport); a window whose column is scrolled off gets a park slot (a sliver hugging the working
    /// area's left edge, §4a/§10). The union is exhaustive over the strip's windows — one `Rect` each,
    /// which is exactly what the shell sets via AX (tiled) or parks (off-viewport). This is the
    /// **truth-plane** placement: where the *real* window sits at rest.
    ///
    /// Parked windows are assigned ordinals in column-then-stack order over the *currently* off-view
    /// set, so `ParkingLot`'s per-ordinal uniqueness guarantees no two parked windows collide
    /// (identity-rebind safety, §7). A parked window keeps its tiled *size* (parking repositions,
    /// never resizes) — the size comes from the same `Column` distribution it would have on-screen.
    public func targetFrames(scrollOffset: Double, metrics: LayoutMetrics) -> [WindowId: Rect] {
        let area = metrics.workingArea
        let s = strip(metrics: metrics)
        let visible = Set(s.visibleColumnIndices(viewportWidth: area.width, offset: scrollOffset))
        let lot = ParkingLot(frame: area)
        let dx = area.minX - scrollOffset      // strip x → screen x for on-viewport columns
        let stripFrames = columnStripFrames(s, area: area, metrics: metrics)

        var frames: [WindowId: Rect] = [:]
        var parkOrdinal = 0
        for (i, column) in columns.enumerated() {
            if visible.contains(i) {
                for (w, f) in zip(column.windowIds, stripFrames[i]) {
                    frames[w] = f.offsetBy(dx: dx, dy: 0)
                }
            } else {
                for (w, f) in zip(column.windowIds, stripFrames[i]) {
                    frames[w] = lot.slot(ordinal: parkOrdinal, size: f.size)
                    parkOrdinal += 1
                }
            }
        }
        return frames
    }

    /// The **presentation-plane** counterpart to `targetFrames`: the natural on-screen frame for every
    /// window at `scrollOffset`, with **no parking** — every column's strip position simply pulled into
    /// the viewport (`workingArea.minX + (stripX − scrollOffset)`), so an off-viewport column's frame
    /// slides *off the screen edge* rather than jumping to its park sliver. This is what the
    /// reconstruction layers animate to (§4b): during a scroll a departing window's layer glides smoothly
    /// off-screen while the hidden *real* window teleports to its corner sliver (`targetFrames`). The two
    /// agree exactly for on-viewport windows (natural == tiled there), so the cross-fade at settle lands
    /// pixel-on-pixel for everything still on screen.
    ///
    /// `widths` carries the in-flight column widths of a `cycleWidth` transition (see `strip(metrics:
    /// widths:)`). Passing them here and nowhere else is the whole of the resize animation: the resizing
    /// column's layers grow with it, and *every column to its right slides* because their strip positions
    /// are accumulated from the same widths — lockstep for free, from geometry that already existed. When
    /// the animators settle the override equals the preset, so this converges onto `targetFrames` and the
    /// cross-fade lands pixel-on-pixel exactly as a scroll's does.
    public func naturalFrames(scrollOffset: Double, metrics: LayoutMetrics,
                              widths: [ColumnId: Double] = [:]) -> [WindowId: Rect] {
        let area = metrics.workingArea
        let s = strip(metrics: metrics, widths: widths)
        let dx = area.minX - scrollOffset
        let stripFrames = columnStripFrames(s, area: area, metrics: metrics)

        var frames: [WindowId: Rect] = [:]
        for (i, column) in columns.enumerated() {
            for (w, f) in zip(column.windowIds, stripFrames[i]) {
                frames[w] = f.offsetBy(dx: dx, dy: 0)
            }
        }
        return frames
    }

    /// The windows whose columns overlap the viewport at `scrollOffset` — the on-screen set, in
    /// layout order. What the reducer places (`targetFrames` parks the complement) and what a
    /// still-frame question — "what is on screen right now" — is answered with.
    public func visibleWindowIds(scrollOffset: Double, metrics: LayoutMetrics) -> [WindowId] {
        windowIds(inColumns: strip(metrics: metrics)
            .visibleColumnIndices(viewportWidth: metrics.workingArea.width, offset: scrollOffset))
    }

    /// The windows the viewport touches at **any** offset between `from` and `to` — the *swept*
    /// union, in layout order. This is the transition scope (IMPLEMENTATION.md §3): exactly the
    /// windows that must be captured (each is on screen at some point during the motion) and whose AX
    /// landing gates the cross-fade.
    ///
    /// **Why swept and not "start ∪ end" (corrected 2026-07-25).** §3 originally read "every window
    /// whose start *or* end frame intersects the viewport", and that is right only when the two
    /// viewports overlap — a one-column `focus`. Scroll further (a centered jump, or two commands
    /// chained) and the columns *between* the endpoints pass straight across the screen with no layer
    /// to draw them: the cover shows the base — wallpaper — sliding where a window should be. Sweeping
    /// the interval is the fix, and it costs nothing, because a viewport of width `w` travelling from
    /// `a` to `b` covers exactly `[min(a,b), max(a,b) + w]` — which *is* one viewport of width
    /// `w + |b − a|` parked at `min(a,b)`. So the sweep is the query `visibleWindowIds` already
    /// answers, asked of a wider window; there is no new geometry and no interval arithmetic to get
    /// wrong.
    ///
    /// **Plus a shoulder on each end (2026-07-26).** The scope is the swept run *flanked* by the column
    /// just outside either end, which are the columns one further command can pull into view. They are
    /// captured for a motion that will not show them, and the reason is **latency, not geometry**: a
    /// retarget widens the scope correctly (`Motion.extendTransition`) but its stills take a capture
    /// round trip to arrive, and with minimal-reveal scrolling the newcomer's leading edge sits one
    /// `columnGap` past the destination the session was already aiming at — so the layers cross into it
    /// almost immediately and the cover shows wallpaper there until `extendCover` lands. Measured at
    /// 130–140 pt of hole on a spammed `focus`, and *only* when interrupted, since an uninterrupted
    /// transition raises no cover until every still is in.
    ///
    /// A shoulder is what makes the pixels already be there. It is nearly free where it is paid — the
    /// head batch is a fan-out whose critical path is the full-display base capture, so one or two more
    /// window stills alongside it cost almost nothing, while an extension costs a *serial* round trip
    /// that lands mid-motion. And it stays correct under repeated interrupts: each retarget captures
    /// the *next* shoulder while the spring, always lagging behind a spammed target, has not yet
    /// reached the one before it.
    ///
    /// This is deliberately not `visibleWindowIds`' business. That query means "what is on screen", and
    /// the reducer parks its complement — a shouldered answer there would place two parked columns on
    /// the strip.
    public func sweptWindowIds(from: Double, to: Double, metrics: LayoutMetrics) -> [WindowId] {
        let strip = strip(metrics: metrics)
        let swept = strip.visibleColumnIndices(
            viewportWidth: metrics.workingArea.width + abs(to - from),
            offset: Swift.min(from, to))
        return windowIds(inColumns: strip.shoulderedColumnIndices(swept))
    }

    /// The windows stacked in the given column indices, flattened in layout order (left→right,
    /// top→bottom) — which is also the cover's z-order, bottom→top.
    private func windowIds(inColumns indices: [Int]) -> [WindowId] {
        let wanted = Set(indices)
        return columns.enumerated()
            .filter { wanted.contains($0.offset) }
            .flatMap { $0.element.windowIds }
    }

    // MARK: - Scroll targets (thin delegations to `Strip`, keyed by window)

    /// The minimal scroll offset that reveals the window's column, from the current `offset` — the
    /// keep-it-on-screen behavior (`Strip.offsetToReveal`). `nil` if the window isn't on the strip.
    public func scrollOffsetToReveal(window id: WindowId, from offset: Double, metrics: LayoutMetrics) -> Double? {
        guard let i = columnIndex(ofWindow: id) else { return nil }
        return strip(metrics: metrics).offsetToReveal(i, viewportWidth: metrics.workingArea.width, from: offset)
    }

    /// `offset` brought inside the strip's scrollable range (`Strip.clampOffset`) — the offsets from
    /// which the viewport isn't looking past either end.
    ///
    /// Deliberately **not** applied to `scrollOffsetToCenter`: centering is an explicit instruction to
    /// put a column in the middle, and at the strip's ends honouring it *means* showing space beyond
    /// the last column (an always-center policy does exactly that). The reducer
    /// applies this on the non-centering path only.
    public func clampScrollOffset(_ offset: Double, metrics: LayoutMetrics) -> Double {
        strip(metrics: metrics).clampOffset(offset, viewportWidth: metrics.workingArea.width)
    }

    /// The scroll offset that centers the window's column (`Strip.offsetToCenter`). `nil` if the
    /// window isn't on the strip. The reducer picks reveal vs. center per `centerFocusedColumn`.
    public func scrollOffsetToCenter(window id: WindowId, metrics: LayoutMetrics) -> Double? {
        guard let i = columnIndex(ofWindow: id) else { return nil }
        return strip(metrics: metrics).offsetToCenter(i, viewportWidth: metrics.workingArea.width)
    }
}
