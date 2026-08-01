import Foundation

// Turns the strip/column/park math into concrete per-window target frames: a window gets its tiled
// frame if its column is on screen, or a park slot if its column is scrolled off the viewport.
//
// Structure lives here (which columns, which windows stack in each); monitor- and config-dependent
// metrics arrive per call in `LayoutMetrics` and are never stored. Columns sit in virtual-strip space
// (infinite x, origin 0), pulled into the viewport as `contentArea.minX + (stripX − scrollOffset)`;
// parked windows are already in screen space. Top-left origin throughout (Geometry.swift).

/// What a fullscreen column remembers so the toggle can undo itself: the stack the window was expelled
/// from, and where the viewport was looking. Never a width — the width underneath comes back by being
/// un-shadowed. Each half is optional, and applied only if its column is still on the strip.
public struct Fullscreen: Sendable, Equatable, Codable {
    /// The column a window with stackmates was expelled from, and the row it sat at. `nil` where the
    /// window was already alone in its column: nothing was extracted, so there is nothing to merge into.
    public struct Stack: Sendable, Equatable, Codable {
        public let column: ColumnId
        public let row: Int

        public init(column: ColumnId, row: Int) {
            self.column = column
            self.row = row
        }
    }

    /// The viewport, as a column and that column's distance from the content area's left edge. A column
    /// and a distance rather than an offset: anything changing to the anchor's left leaves both true.
    public struct Anchor: Sendable, Equatable, Codable {
        public let column: ColumnId
        public let dx: Double

        public init(column: ColumnId, dx: Double) {
            self.column = column
            self.dx = dx
        }
    }

    public var stack: Stack?
    public var anchor: Anchor?

    public init(stack: Stack? = nil, anchor: Anchor? = nil) {
        self.stack = stack
        self.anchor = anchor
    }

    /// Fullscreen with nothing to undo — what a new column inherits when a window carries the full width
    /// into an expel or another workspace, where the arrangement it would restore to is not the one it
    /// is going to.
    public static let plain = Fullscreen()
}

/// One column's structure: its stable id, the ordered window stack (top→bottom), and its width
/// intent. Pure data; the geometry is computed by `Layout`.
public struct ColumnLayout: Sendable, Equatable, Codable {
    /// Stable identity across relayouts — the handle animation and consume/expel key on.
    public let id: ColumnId
    /// The window stack, top→bottom. Array order *is* vertical stacking order; never empty.
    public var windowIds: [WindowId]
    /// Index into the width `PresetCycle` (supplied via `LayoutMetrics`). Stored as an index, not a
    /// resolved width, so a ½-width column stays ½ on any display and a drifted index normalizes.
    public var widthPreset: Int
    /// An explicit width from `grow`/`shrink` that supersedes `widthPreset` until the next
    /// `cycleWidth` clears it; `nil` — the ordinary case — means the column is on the preset ladder.
    /// A `PresetSize` rather than points, so `grow 10%` tracks the monitor and `grow 100px` doesn't.
    public var widthOverride: PresetSize?
    /// Full width of the strip's area, plus what it takes to undo — a third layer *above* `widthOverride`
    /// and `widthPreset` rather than a fourth way of writing a width, so the width underneath needs no
    /// saving. Not exclusive: two fullscreen columns is two full-width columns, each undoing on its own.
    public var fullscreen: Fullscreen?

    /// Whether this column resolves to the full content width — all the width stack reads of
    /// `fullscreen`, so remembering how to undo cannot change what a column *is*.
    public var isFullscreen: Bool { fullscreen != nil }

    public init(id: ColumnId, windowIds: [WindowId], widthPreset: Int = 0,
                widthOverride: PresetSize? = nil, fullscreen: Fullscreen? = nil) {
        self.id = id
        self.windowIds = windowIds
        self.widthPreset = widthPreset
        self.widthOverride = widthOverride
        self.fullscreen = fullscreen
    }
}

/// The monitor + config inputs a `Layout` resolves against — passed per call, never stored.
public struct LayoutMetrics: Sendable, Equatable {
    /// The monitor's **physical** working area — screen-space, top-left, already inset past the menu
    /// bar/Dock by the shell. The corner a parked nub hugs; the strip itself lives in `contentArea`.
    public var workingArea: Rect
    /// The width presets a column cycles through (`cycleWidth`). A column's `widthPreset` indexes it.
    public var widthPresets: PresetCycle
    /// The height presets a window cycles through inside its column (`cycleHeight`), indexed by
    /// `heightSelections`.
    public var heightPresets: PresetCycle
    /// Which height preset each window is pinned to, where the user has pinned one. Absent — the
    /// ordinary case — means **auto**: share the column's leftover height with the other autos.
    ///
    /// Rides in `metrics` for the same reason `corrections` does: it must reach every geometry query
    /// or they disagree about how tall a window is. Keyed by `WindowId` rather than stored as an array
    /// beside `ColumnLayout.windowIds`, so the four structural editing primitives cannot desync it —
    /// a window carries its height through a move, an extract, a merge and a workspace switch alike.
    public var heightSelections: [WindowId: Int]
    /// Gap between adjacent columns on the strip (inter-column only).
    public var columnGap: Double
    /// Gap between vertically-adjacent windows within a column (inter-window only).
    public var windowGap: Double
    /// The margin held clear at the edges of the working area — the strip's *outer* gaps. Not a strut,
    /// though the arithmetic is identical: a strut is forbidden ground, an outer gap is empty at rest
    /// and *crossed in motion*. The cover clips to the strut-inset region, so folding this into
    /// `Config.struts` would cut every layer off at the margin's inner edge.
    public var outerGaps: EdgeInsets
    /// What each window last answered when asked to be a size (`World.corrections`) — what lets a
    /// column be as wide as the app *actually is*. It rides in `metrics` so a correction cannot be
    /// forgotten at a call site: it must reach every geometry query, or they accumulate different left
    /// edges and place windows at the wrong x.
    public var corrections: [WindowId: SizeCorrection]
    /// The least chrome each window has been observed to accept at a park (`World.parkFloors`) — a
    /// window that will not hide behind a 40 pt nub gets a taller one. Rides here for the same reason
    /// `corrections` does, and for a sharper version of it: a park slot allocated without the floors
    /// would be a slot the app refuses, and the refusal would be re-issued on every placement pass.
    public var parkFloors: [WindowId: Double]

    public init(
        workingArea: Rect,
        widthPresets: PresetCycle = .defaultWidths,
        heightPresets: PresetCycle = .defaultHeights,
        heightSelections: [WindowId: Int] = [:],
        columnGap: Double = 0,
        windowGap: Double = 0,
        outerGaps: EdgeInsets = .zero,
        corrections: [WindowId: SizeCorrection] = [:],
        parkFloors: [WindowId: Double] = [:]
    ) {
        self.workingArea = workingArea
        self.widthPresets = widthPresets
        self.heightPresets = heightPresets
        self.heightSelections = heightSelections
        self.columnGap = columnGap
        self.windowGap = windowGap
        self.outerGaps = outerGaps
        self.corrections = corrections
        self.parkFloors = parkFloors
    }

    // MARK: The two viewports
    //
    // Outer gaps split one number in two. *Where does the strip live?* is `contentArea`, the logical
    // viewport — width proportions, column placement and every scroll target frame against it, and
    // "100%" means this. *What is on screen?* is `workingArea`, the physical extent — the tile-vs-park
    // decision, the capture scope, the edge a sliver parks against. Answering the second with the
    // logical viewport parks any column whose leading edge sits in the outer-gap band.

    /// The **logical** viewport: the working area inset by the outer gaps. Where the strip is laid out.
    public var contentArea: Rect { workingArea.inset(by: outerGaps) }

    /// The **physical** viewport in strip space, for a strip scrolled to `offset`.
    ///
    /// `widenedBy` carries a sweep's travel distance, so the swept query composes with this one rather
    /// than re-deriving the shift; they must agree, or the capture scope and the park set disagree.
    public func physicalViewport(at offset: Double, widenedBy extra: Double = 0)
        -> (width: Double, offset: Double) {
        (workingArea.width + extra, offset - outerGaps.left)
    }

    /// These metrics with every correction dropped — how "the question" a correction answers is
    /// defined: the *same* code with no answers available, so the two cannot drift apart.
    public var uncorrected: LayoutMetrics {
        var copy = self
        copy.corrections = [:]
        return copy
    }
}

/// What one structural mutation did. Returned by every mutator below; neither fact is recoverable
/// once the call has returned.
public struct LayoutEdit: Sendable, Equatable {
    /// Whether the structure actually changed. `false` ⇒ nothing was touched, not even the allocator.
    public let moved: Bool
    /// The column this edit destroyed (its last window left it), or `nil`. `Motion` may still hold an
    /// in-flight width animator keyed by it, and nothing else will ever mention it again.
    public let destroyedColumn: ColumnId?

    public init(moved: Bool, destroyedColumn: ColumnId?) {
        self.moved = moved
        self.destroyedColumn = destroyedColumn
    }

    /// The no-op result — the total answer for an unknown id, an edge, or a move onto itself.
    public static let none = LayoutEdit(moved: false, destroyedColumn: nil)
}

/// The monotonic `ColumnId` source — **one watermark for the whole workspace set**, not one per strip.
///
/// A parameter to `Layout`'s two minting mutators rather than a field on it: per-strip watermarks make
/// column #1 on workspace `0` and column #1 on workspace `3` the *same* `ColumnId`, and
/// `Motion.columnWidths` is keyed by a bare `ColumnId`. Part of `Workspaces`' serialized state, so
/// replay reproduces identical ids. Never rewinds.
public struct ColumnAllocator: Sendable, Equatable, Codable {
    /// The next raw id to hand out.
    private var next: UInt64

    /// A fresh allocator, starting at 1.
    public init() {
        self.next = 1
    }

    /// An allocator resuming at `next` (never below 1) — for replay, and for `Workspaces` seeding
    /// itself past an explicitly-supplied arrangement.
    public init(next: UInt64) {
        self.next = Swift.max(next, 1)
    }

    /// Hand out the next id. The only place a `ColumnId` comes into existence.
    public mutating func mint() -> ColumnId {
        defer { next += 1 }
        return ColumnId(next)
    }

    // Encode as the bare number, as `Id` does — a legible dump.
    public init(from decoder: any Decoder) throws {
        next = try decoder.singleValueContainer().decode(UInt64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(next)
    }
}

/// The arrangement of one strip: its ordered columns. Structure only; frames are computed on demand
/// from a `scrollOffset` + `LayoutMetrics`. Value type, `Codable` for state dumps / replay.
///
/// It mints nothing of its own — new `ColumnId`s come from a `ColumnAllocator` the caller passes in —
/// which is what makes its `Equatable` purely *structural*.
public struct Layout: Sendable, Equatable, Codable {
    /// The columns, left→right. `private(set)` so the structural invariant — every column non-empty,
    /// each window in at most one — is maintained only through the mutators below.
    public private(set) var columns: [ColumnLayout]

    /// An empty strip — no columns. Populate via `reconcile`.
    public init() {
        self.columns = []
    }

    /// Construct from an explicit column arrangement. Supplied ids are taken as given; keeping the
    /// allocator past them is the caller's job, which `Workspaces.init(focused:strips:)` does once.
    public init(columns: [ColumnLayout]) {
        self.columns = columns
    }

    public var isEmpty: Bool { columns.isEmpty }

    // MARK: - Membership queries

    /// The index of the column containing `id`, or `nil` if the window is not on this strip.
    public func columnIndex(ofWindow id: WindowId) -> Int? {
        columns.firstIndex { $0.windowIds.contains(id) }
    }

    /// The column with the given id, or `nil`.
    public func columnIndex(withId id: ColumnId) -> Int? {
        columns.firstIndex { $0.id == id }
    }

    /// Every window on the strip in *layout* order — left→right, top→bottom. Distinct from
    /// `World.stripWindowIds`, which is id-sorted.
    public var allWindowIds: [WindowId] {
        columns.flatMap(\.windowIds)
    }

    // MARK: - Structural mutation

    /// Sync the column structure to the strip's current membership: departures are dropped along with
    /// any column they empty, newcomers arrive as fresh single-window columns. Surviving columns keep
    /// their id and stack order, so animation identity and the user's arrangement outlive enumeration
    /// churn. Total. Called by `Workspaces.reconcile`, which composes it from the two halves below.
    ///
    /// - Parameter anchor: the window a newcomer opens **beside**; `nil`, or a window with no column of
    ///   its own, appends at the far end. It must be the window focused *before* the newcomer arrived,
    ///   which by the time this runs has no column to sit beside yet.
    public mutating func reconcile(stripWindowIds ids: [WindowId],
                                   insertingAfter anchor: WindowId? = nil,
                                   columnIds: inout ColumnAllocator) {
        removeWindows(notIn: Set(ids))
        let present = Set(allWindowIds)
        adopt(ids.filter { !present.contains($0) }, after: anchor, columnIds: &columnIds)
    }

    /// Drop every window not in `keep`, removing any column they empty — the *departure* half of
    /// `reconcile`, and the only half an unfocused workspace ever runs. Total.
    public mutating func removeWindows(notIn keep: Set<WindowId>) {
        for i in columns.indices {
            columns[i].windowIds.removeAll { !keep.contains($0) }
        }
        columns.removeAll { $0.windowIds.isEmpty }
    }

    /// Insert `newcomers` as fresh single-window columns beside `anchor` (or at the far end) — the
    /// *arrival* half of `reconcile`, and the only half that mints. The caller owes the guarantee that
    /// a newcomer is on **no strip at all**.
    ///
    /// - Parameter source: a column whose width intent the new columns take instead of the ladder's
    ///   first rung. `nil` — a genuinely new window — starts on the ladder; non-`nil` for the arrival
    ///   half of a cross-workspace move, where the window is already on screen at that width. A
    ///   fullscreen source lends the *width* but not its undo record, whose columns are on another strip.
    public mutating func adopt(_ newcomers: [WindowId], after anchor: WindowId?,
                               like source: ColumnLayout? = nil,
                               columnIds: inout ColumnAllocator) {
        guard !newcomers.isEmpty else { return }
        var at = anchor.flatMap { columnIndex(ofWindow: $0) }.map { $0 + 1 } ?? columns.count
        for id in newcomers {
            columns.insert(ColumnLayout(id: columnIds.mint(), windowIds: [id],
                                        widthPreset: source?.widthPreset ?? 0,
                                        widthOverride: source?.widthOverride,
                                        fullscreen: source?.isFullscreen == true ? .plain : nil),
                           at: at)
            at += 1
        }
    }

    /// Drop `window` from this strip, removing the column it empties — the *departure* half of a
    /// cross-workspace move. Total.
    ///
    /// **Internal on purpose:** it leaves a window on no strip at all, an invariant `Layout` does not
    /// own and cannot restore. Only `Workspaces.move(window:to:insertingAfter:)` may call it, because
    /// only that call puts the window down again in the same breath.
    @discardableResult
    mutating func remove(window: WindowId) -> LayoutEdit {
        guard let from = columnIndex(ofWindow: window) else { return .none }
        columns[from].windowIds.removeAll { $0 == window }
        guard columns[from].windowIds.isEmpty else {
            return LayoutEdit(moved: true, destroyedColumn: nil)
        }
        let destroyed = columns[from].id
        columns.remove(at: from)
        return LayoutEdit(moved: true, destroyedColumn: destroyed)
    }

    /// Set a column's width-preset index. Keyed by `ColumnId`, total; resolution normalizes any index,
    /// so no range check. Clears both `widthOverride` and `fullscreen` — a cycle resumes the ladder
    /// where it was last left rather than guessing which rung a grown width was nearest.
    public mutating func setWidthPreset(_ index: Int, ofColumn id: ColumnId) {
        guard let i = columnIndex(withId: id) else { return }
        columns[i].widthPreset = index
        columns[i].widthOverride = nil
        columns[i].fullscreen = nil
    }

    /// Pin a column to an explicit width until the next `cycleWidth` — how `grow`/`shrink` record their
    /// answer. Deliberately *not* bounds-checked: clamping is the reducer's, since the bound depends on
    /// the working area and on which direction the user asked to move. Clears `fullscreen`, so a
    /// `shrink` off a fullscreen column lands at 90% rather than moving nothing.
    public mutating func setWidthOverride(_ size: PresetSize, ofColumn id: ColumnId) {
        guard let i = columnIndex(withId: id) else { return }
        columns[i].widthOverride = size
        columns[i].fullscreen = nil
    }

    /// Take a column to the full width of the strip's area, carrying `record` as how to undo it — or give
    /// it back the width it already had (`nil`). This raises or lowers a layer **over** the width intent,
    /// so coming off is exact for a preset rung and a grown override alike.
    public mutating func setFullscreen(_ record: Fullscreen?, ofColumn id: ColumnId) {
        guard let i = columnIndex(withId: id) else { return }
        columns[i].fullscreen = record
    }

    // MARK: - Structural mutation (the strip's editing primitives)
    //
    // The four edits every structural command composes from. All **total** — an unknown id or an
    // out-of-range destination is a silent no-op, and indices *clamp*, which is where the reducer's
    // no-wrap-at-the-edge rule comes from. All **atomic over the invariants**: one call each, because
    // the obvious decomposition (remove the window, then insert a column for it) passes through a state
    // with an empty column and no caller may observe one. All **policy-free** — whether a stacked
    // window pops out or its whole column moves is the reducer's.

    /// Move the column with `id` to strip index `index`, sliding the columns between them along — the
    /// whole-column reorder behind `move-window left|right` for a window alone in its column.
    ///
    /// `index` is the column's position in the **resulting** array, clamped into `0..<columns.count`.
    /// Membership is untouched, so `destroyedColumn` is always `nil`.
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
    /// up and the bottom window moved down are no-ops. Membership never changes, so nothing is
    /// destroyed.
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
    /// *consume*. `row` clamps into `0...` the target's window count; an emptied source column is
    /// removed and reported as `destroyedColumn`. The window's new width comes from the column it joins.
    ///
    /// A `target` that **is** the window's own column no-ops: that is `moveWindowWithinColumn`'s job,
    /// and handling it here would mean a removal that empties the very column it is inserting into.
    @discardableResult
    public mutating func move(window: WindowId, toColumn target: ColumnId, at row: Int) -> LayoutEdit {
        guard let from = columnIndex(ofWindow: window),
              let to = columnIndex(withId: target),
              to != from else { return .none }
        let insertion = Swift.min(Swift.max(row, 0), columns[to].windowIds.count)
        // Insert into the destination *first*: dropping the emptied source column shifts every index
        // to its right, so a remove-first order would have to re-find `to` afterwards. Safe **only**
        // because `to != from` is guarded above — otherwise the removal deletes the copy just inserted.
        columns[to].windowIds.insert(window, at: insertion)
        columns[from].windowIds.removeAll { $0 == window }
        guard columns[from].windowIds.isEmpty else {
            return LayoutEdit(moved: true, destroyedColumn: nil)
        }
        let destroyed = columns[from].id
        columns.remove(at: from)
        return LayoutEdit(moved: true, destroyedColumn: destroyed)
    }

    /// Move `window` **out** into a freshly-minted single-window column at strip index `index` — the
    /// split behind an *expel*, and the only way a column is created outside `reconcile`. `index`
    /// clamps into `0...columns.count`. The new column inherits all three of the source's width intents
    /// (`widthPreset`, `widthOverride`, and fullscreen), or an expel would snap a grown or fullscreen
    /// column back to its ladder rung. The fullscreen *width* only: an undo record names one origin
    /// column, which two columns cannot share.
    ///
    /// **A window already alone in its column is a no-op**, not a rebuild: a replacement column would
    /// carry a *different* `ColumnId`, which `Motion.columnWidths` and the cover's animation identity
    /// key on. That guard is also why `destroyedColumn` is always `nil` here.
    @discardableResult
    public mutating func extract(window: WindowId, toNewColumnAt index: Int,
                                 columnIds: inout ColumnAllocator) -> LayoutEdit {
        // The guard precedes the mint on purpose: a no-op must not consume an id.
        guard let from = columnIndex(ofWindow: window),
              columns[from].windowIds.count > 1 else { return .none }
        let source = columns[from]
        let to = Swift.min(Swift.max(index, 0), columns.count)
        columns[from].windowIds.removeAll { $0 == window }   // never empties it (count > 1 above)
        columns.insert(ColumnLayout(id: columnIds.mint(), windowIds: [window],
                                    widthPreset: source.widthPreset,
                                    widthOverride: source.widthOverride,
                                    fullscreen: source.isFullscreen ? .plain : nil),
                       at: to)
        return LayoutEdit(moved: true, destroyedColumn: nil)
    }

    // MARK: - Geometry

    /// The resolved `Strip` for these columns against `metrics` — the handle for the reducer's scroll math.
    ///
    /// `widths` overrides individual columns with a width in **points**, for one caller only: the
    /// presentation plane mid-`cycleWidth`, where a column sits part-way between two presets.
    /// Everything else gets the presets, because those questions are about where the strip is *going*.
    /// A partial map is meaningful — an unknown column's override is ignored, and a column without one
    /// keeps its preset.
    public func strip(metrics: LayoutMetrics, widths: [ColumnId: Double] = [:]) -> Strip {
        let resolved = columns.map { column in
            widths[column.id] ?? resolvedWidth(of: column, metrics: metrics)
        }
        return Strip(columnWidths: resolved, gap: metrics.columnGap)
    }

    /// A column's width in points, and the only place widths resolve — the three intents as a stack
    /// (fullscreen shadows `widthOverride`, which shadows the ladder), reconciled against what the
    /// column's windows said they could actually be:
    ///
    /// > A column is as wide as the widest width its windows can actually achieve for the width it was
    /// > asked. A window that has answered contributes its answer; one that has not contributes the
    /// > intent, because an unasked window may well fill it.
    ///
    /// One `max` covers both directions: a window refusing to *shrink* needs the room or it overlaps
    /// its neighbour, while a column whose windows all refuse to *grow* holds room nobody can use.
    /// Capped at the content width once an answer is in play, which bounds two stacked windows on
    /// different quantization grids from chasing each other upward.
    ///
    /// Content, not working: a proportion is a share of the *logical* viewport, so "100%" leaves the
    /// outer gaps showing, and `fullscreen` means exactly this 100%.
    public func resolvedWidth(of column: ColumnLayout, metrics: LayoutMetrics) -> Double {
        let intent = uncorrectedWidth(of: column, metrics: metrics)
        var answered = false
        let achievable = column.windowIds.map { id -> Double in
            guard let answer = metrics.corrections[id]?.width(forQuestion: intent) else { return intent }
            answered = true
            return answer
        }
        // Nothing asked yet ⇒ the intent stands, uncapped, so `width-presets = [1.5]` is honored.
        guard answered, let widest = achievable.max() else { return intent }
        return Swift.min(widest, metrics.contentArea.width)
    }

    /// The width this column asks for before any window has answered back — the resolution stack with
    /// no `SizeCorrection` consulted. This *is* the question a correction answers, and an answer
    /// matched against a question nobody asked is the one way this machinery goes wrong.
    private func uncorrectedWidth(of column: ColumnLayout, metrics: LayoutMetrics) -> Double {
        (column.isFullscreen ? .proportion(1.0)
            : column.widthOverride
            ?? metrics.widthPresets.size(at: column.widthPreset))
            .resolved(available: metrics.contentArea.width)
    }

    /// A column's resolved width by id — what `cycleWidth` animates *to*, so the presentation plane
    /// converges on the number the truth plane teleported the reals to. `nil` if the column is gone.
    public func resolvedWidth(ofColumn id: ColumnId, metrics: LayoutMetrics) -> Double? {
        columnIndex(withId: id).map { resolvedWidth(of: columns[$0], metrics: metrics) }
    }

    /// The size the layout would give this window **if no window had ever answered back** — the
    /// *question* a `SizeCorrection` answers, run through the ordinary geometry with
    /// `metrics.uncorrected` so it cannot drift from it. The scroll offset is arbitrary.
    public func uncorrectedSize(of window: WindowId, metrics: LayoutMetrics) -> Size? {
        naturalFrames(scrollOffset: 0, metrics: metrics.uncorrected)[window]?.size
    }

    /// Per-column window frames in **strip space** (x from the strip, y/height from the *content*
    /// area), before any viewport pull or parking — the shared basis for `targetFrames` and
    /// `naturalFrames`. Sizes are independent of x, so only *position* is chosen downstream. `area`
    /// being the content area is how the top and bottom outer gaps enter the layout.
    private func columnStripFrames(_ s: Strip, area: Rect, metrics: LayoutMetrics) -> [[Rect]] {
        columns.enumerated().map { (i, column) in
            let box = Rect(x: s.leftEdge(of: i), y: area.minY,
                           width: s.columnWidths[i], height: area.height)
            // Each window's height intent: the preset it is pinned to (`cycleHeight`), else auto.
            let intents = column.windowIds.map { id in
                metrics.heightSelections[id].map { WindowHeight.preset(metrics.heightPresets.size(at: $0)) }
                    ?? .auto
            }
            // The height each window would get with nobody answering back — the question its own
            // `SizeCorrection` is keyed against, which keeps a bound from re-deriving itself each pass.
            // Resolved against the *same* intents: the question has to be the height actually offered,
            // or a pinned window's answer would be matched against the share it never got.
            let share = Column(frame: box, windowHeights: intents,
                               gap: metrics.windowGap).resolvedHeights()
            return Column(
                frame: box,
                windowHeights: intents,
                gap: metrics.windowGap,
                heightBounds: zip(column.windowIds, share).map { id, question in
                    metrics.corrections[id]?.heightBound(forQuestion: question)
                }
            ).windowFrames()
        }
    }

    /// The **truth-plane** placement: where the *real* window sits at rest, for every window at
    /// `scrollOffset`. On-viewport columns tile, off-viewport ones park; a parked window keeps its
    /// tiled *size*, since parking repositions and never resizes. Exhaustive over the strip.
    ///
    /// **The ordinal run is an input *and* an output, because uniqueness is a property of the whole
    /// workspace set.** Every window on every unfocused workspace is parked too, so a range local to one
    /// strip would hand two windows the same nub, silently breaking both the ±2 pt first-sight identity
    /// join and the no-overlap invariant. The cursor comes back rather than being counted from the
    /// outside because a window with a park floor skips the ordinals whose nubs are too short for it.
    public func targetFrames(scrollOffset: Double, metrics: LayoutMetrics,
                             parkingFrom cursor: inout Int) -> [WindowId: Rect] {
        let area = metrics.contentArea
        let s = strip(metrics: metrics)
        // Physical: a column with pixels anywhere on the display is tiled, including one bleeding into
        // the outer-gap margin.
        let view = metrics.physicalViewport(at: scrollOffset)
        let visible = Set(s.visibleColumnIndices(viewportWidth: view.width, offset: view.offset))
        // Also physical — a park slot inset by the outer gap would poke a window a margin's width in.
        let lot = ParkingLot(frame: metrics.workingArea)
        let dx = area.minX - scrollOffset      // strip x → screen x for on-viewport columns
        let stripFrames = columnStripFrames(s, area: area, metrics: metrics)

        var frames: [WindowId: Rect] = [:]
        for (i, column) in columns.enumerated() {
            if visible.contains(i) {
                for (w, f) in zip(column.windowIds, stripFrames[i]) {
                    frames[w] = f.offsetBy(dx: dx, dy: 0)
                }
            } else {
                for (w, f) in zip(column.windowIds, stripFrames[i]) {
                    frames[w] = Self.park(w, size: f.size, in: lot, at: &cursor, metrics: metrics)
                }
            }
        }
        return frames
    }

    /// `targetFrames` for a strip standing on its own — the whole-set run starts and ends here.
    public func targetFrames(scrollOffset: Double, metrics: LayoutMetrics) -> [WindowId: Rect] {
        var cursor = 0
        return targetFrames(scrollOffset: scrollOffset, metrics: metrics, parkingFrom: &cursor)
    }

    /// **Every** window on this strip parked, continuing the run at `cursor` — what an *unfocused*
    /// workspace is. Sizes come from this strip's own geometry, so a window that switches workspaces
    /// changes address, not shape.
    public func parkedFrames(metrics: LayoutMetrics, parkingFrom cursor: inout Int) -> [WindowId: Rect] {
        let s = strip(metrics: metrics)
        let lot = ParkingLot(frame: metrics.workingArea)
        let stripFrames = columnStripFrames(s, area: metrics.contentArea, metrics: metrics)

        var frames: [WindowId: Rect] = [:]
        for (i, column) in columns.enumerated() {
            for (w, f) in zip(column.windowIds, stripFrames[i]) {
                frames[w] = Self.park(w, size: f.size, in: lot, at: &cursor, metrics: metrics)
            }
        }
        return frames
    }

    /// One window's park slot, and the cursor moved past it — the step both park runs take. A window
    /// that has refused a short nub (`LayoutMetrics.parkFloors`) is given the first slot at or after the
    /// cursor that clears its floor; the ones behind it in the run follow from there, which is what keeps
    /// the nubs distinct when an app's answer skips ordinals.
    private static func park(_ id: WindowId, size: Size, in lot: ParkingLot,
                             at cursor: inout Int, metrics: LayoutMetrics) -> Rect {
        let ordinal = lot.ordinal(atLeast: cursor, clearing: metrics.parkFloors[id] ?? 0)
        cursor = ordinal + 1
        return lot.slot(ordinal: ordinal, size: size)
    }

    /// The **presentation-plane** counterpart to `targetFrames`: the same frames with **no parking**, so
    /// an off-viewport column slides off the screen edge instead of jumping to its sliver. This is what
    /// the reconstruction layers animate to while the hidden real window teleports; the two agree
    /// exactly for on-viewport windows, so the cross-fade at settle lands pixel-on-pixel.
    ///
    /// `widths` carries a `cycleWidth`'s in-flight column widths. Passing them here and nowhere else is
    /// the whole of the resize animation: the resizing column's layers grow with it and every column to
    /// its right slides, because their strip positions accumulate from the same widths.
    public func naturalFrames(scrollOffset: Double, metrics: LayoutMetrics,
                              widths: [ColumnId: Double] = [:]) -> [WindowId: Rect] {
        let area = metrics.contentArea
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

    /// The windows whose columns overlap the viewport at `scrollOffset`, in layout order — the reducer's
    /// `.setFrame` vs `.park` switch. Against the **physical** viewport, so a column bleeding into the
    /// outer-gap margin counts as on screen.
    public func visibleWindowIds(scrollOffset: Double, metrics: LayoutMetrics) -> [WindowId] {
        let view = metrics.physicalViewport(at: scrollOffset)
        return windowIds(inColumns: strip(metrics: metrics)
            .visibleColumnIndices(viewportWidth: view.width, offset: view.offset))
    }

    /// The windows the viewport touches at **any** offset between `from` and `to`, plus a shoulder
    /// column just outside either end — the transition scope: what must be captured, and whose AX
    /// landing gates the cross-fade.
    ///
    /// Swept rather than "start ∪ end", or columns *between* the endpoints cross the screen with no
    /// layer to draw them. It needs no new geometry: a viewport of width `w` travelling `a`→`b` covers
    /// `[min(a,b), max(a,b) + w]`, which *is* one viewport of width `w + |b − a|` at `min(a,b)`.
    ///
    /// The shoulders are captured for a motion that will not show them, for **latency, not geometry**:
    /// a retarget widens the scope correctly but its stills take a capture round trip, and the layers
    /// cross into the newcomer before they land. Deliberately not `visibleWindowIds`' business, whose
    /// complement the reducer parks — a shouldered answer there would place two parked columns.
    public func sweptWindowIds(from: Double, to: Double, metrics: LayoutMetrics) -> [WindowId] {
        let strip = strip(metrics: metrics)
        // The *same* physical viewport `visibleWindowIds` uses, which is why both go through
        // `physicalViewport`. A scope narrower than the park set is a window on screen with no layer.
        let view = metrics.physicalViewport(at: Swift.min(from, to), widenedBy: abs(to - from))
        let swept = strip.visibleColumnIndices(viewportWidth: view.width, offset: view.offset)
        return windowIds(inColumns: strip.shoulderedColumnIndices(swept))
    }

    /// The windows in the given column indices, flattened in layout order — also the cover's z-order,
    /// bottom→top.
    private func windowIds(inColumns indices: [Int]) -> [WindowId] {
        let wanted = Set(indices)
        return columns.enumerated()
            .filter { wanted.contains($0.offset) }
            .flatMap { $0.element.windowIds }
    }

    // MARK: - Scroll targets (thin delegations to `Strip`, keyed by window)
    //
    // All three frame against the **logical** viewport (`contentArea.width`) — the opposite choice from
    // the visibility queries above, because "reveal this column" means put it inside the margin rather
    // than flush against the screen edge.

    /// The minimal scroll offset that reveals the window's column, from the current `offset`.
    /// `nil` if the window isn't on the strip.
    public func scrollOffsetToReveal(window id: WindowId, from offset: Double, metrics: LayoutMetrics) -> Double? {
        guard let i = columnIndex(ofWindow: id) else { return nil }
        return strip(metrics: metrics).offsetToReveal(i, viewportWidth: metrics.contentArea.width, from: offset)
    }

    /// `offset` brought inside the strip's scrollable range. Deliberately **not** applied to
    /// `scrollOffsetToCenter`: centering is an instruction to put a column in the middle, and at the
    /// strip's ends honouring it *means* showing space past the last column. The reducer applies this
    /// on the non-centering path only.
    public func clampScrollOffset(_ offset: Double, metrics: LayoutMetrics) -> Double {
        strip(metrics: metrics).clampOffset(offset, viewportWidth: metrics.contentArea.width)
    }

    /// The scroll offset that centers the window's column. `nil` if the window isn't on the strip.
    /// The reducer picks reveal vs. center from config.
    public func scrollOffsetToCenter(window id: WindowId, metrics: LayoutMetrics) -> Double? {
        guard let i = columnIndex(ofWindow: id) else { return nil }
        return strip(metrics: metrics).offsetToCenter(i, viewportWidth: metrics.contentArea.width)
    }
}
