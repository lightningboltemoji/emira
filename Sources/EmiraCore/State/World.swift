import Foundation

// The truth-plane half of core `State`: a framework-free mirror of what AX + `NSWorkspace` observations
// report. Deliberately dumb — it enforces one invariant (focus can never reference a destroyed window)
// and one bookkeeping rule (`apps` is reference-counted by window membership); anything with a choice in
// it is policy and lives in the reducer. App identity is the `bundleId`, never a pid (the core never
// sees one), which assumes one running instance per bundle; the shell would disambiguate before here.

/// The core's record of a live window — distinct from `WindowSnapshot`, the boundary DTO the shell hands
/// in at first sight. `id` and `bundleId` are identity and never change; the rest is mutable truth.
public struct WindowState: Sendable, Equatable, Codable {
    public let id: WindowId
    /// The app-grouping key, and the stable key rules match on.
    public let bundleId: String
    /// Mutable (apps rewrite it); never used for identity after binding.
    public var title: String
    /// The window's tiling role. Only `.standard` joins the strip.
    public var role: WindowRole
    /// Last-known truth frame in top-left virtual-strip coordinates (the shell Y-flips at its edge).
    public var frame: Rect
    /// A minimized window *leaves the strip*, like a close.
    public var isMinimized: Bool

    public init(
        id: WindowId, bundleId: String, title: String, role: WindowRole,
        frame: Rect, isMinimized: Bool = false
    ) {
        self.id = id
        self.bundleId = bundleId
        self.title = title
        self.role = role
        self.frame = frame
        self.isMinimized = isMinimized
    }

    /// What the window's *role* says about tiling, before the user gets a say. `World.isFloating`
    /// overrides it and `World.participatesInStrip` combines both with `AppState.isHidden`.
    public var isTileable: Bool { role.tiles && !isMinimized }
}

/// What one window answered the last time the layout asked it to be a particular size.
///
/// There is no public AX attribute for a window's minimum size, so we cannot *know* an app's constraints,
/// only what it did when asked. `wanted` is the *uncorrected* size the layout asked for — the question,
/// not the literal AX request — and keying on the question makes the record self-invalidating: a new
/// preset, edited gaps, or another display change the question, so a stale answer is not consulted — and
/// a learned minimum can't ratchet, as a terminal answering 900 pt with 904 would otherwise floor ⅓.
public struct SizeCorrection: Sendable, Equatable, Codable {
    /// The uncorrected size the layout wanted — the question this is the answer to.
    public var wanted: Size
    /// The size the window actually ended up at.
    public var actual: Size

    public init(wanted: Size, actual: Size) {
        self.wanted = wanted
        self.actual = actual
    }

    /// This answer's width, if it answers `question` — in *either* direction, because a column's width is
    /// strip extent (it sets where the next column begins, what a scroll reveals, what is parked), so an
    /// under-filled slot isn't cosmetic. Direction is `Layout.resolvedWidth`'s job, via one `max`.
    public func width(forQuestion question: Double, tolerance: Double = 0.5) -> Double? {
        guard abs(wanted.width - question) <= tolerance else { return nil }
        return actual.width
    }

    /// This answer's height as a bound on the share its column offers it, if it answers `question` —
    /// in *either* direction, like `width(forQuestion:)` and for the same reason: a slot the window
    /// cannot fill is not cosmetic either. A column's height is the viewport's and fixed, so the two
    /// refusals land differently — too tall overlaps a stackmate, too short leaves a hole under the
    /// window — but both are the layout holding a size the app has already refused, and re-asking is
    /// a resize the app rejects again on every placement.
    ///
    /// Direction is `Column`'s job, via the water-fill: it is what tells a share of 400 offered to a
    /// window that answered 200 (pin it) from the same share offered to one that answered 500 (pin it
    /// too) from either offered to a window that answered nothing (share it).
    public func heightBound(forQuestion question: Double, tolerance: Double = 0.5) -> HeightBound? {
        guard abs(wanted.height - question) <= tolerance else { return nil }
        if actual.height > question + tolerance { return .atLeast(actual.height) }
        if actual.height < question - tolerance { return .atMost(actual.height) }
        return nil
    }
}

/// The core's record of a running app: identity plus the app-level hidden flag, so `Cmd-H` (which hides
/// every window at once) is one shared truth rather than a flag denormalized onto each window.
public struct AppState: Sendable, Equatable, Codable {
    public let bundleId: String
    /// When `true`, all of the app's windows leave the strip.
    public var isHidden: Bool

    public init(bundleId: String, isHidden: Bool = false) {
        self.bundleId = bundleId
        self.isHidden = isHidden
    }
}

/// The core's record of a display: identity + geometry. Struts (menu-bar/notch) are applied by the layout
/// engine, not baked in here. Its own type, so World state doesn't depend on the `MonitorInfo` wire shape.
public struct MonitorState: Sendable, Equatable, Codable {
    public let id: MonitorId
    /// The display's full bounds in top-left virtual-strip coordinates.
    public var frame: Rect

    public init(id: MonitorId, frame: Rect) {
        self.id = id
        self.frame = frame
    }
}

/// The truth-plane state: the live windows, the apps that own them, the displays, and where focus sits.
/// Mutated only through the total methods below — properties are `private(set)` so the two invariants,
/// focus integrity and app ref-counting, hold from outside.
public struct World: Sendable, Equatable, Codable {
    /// Every live window, keyed by id. Dictionary order is nondeterministic — always derive ordered views
    /// (e.g. `stripWindowIds`) by sorting, never by iterating this directly.
    public private(set) var windows: [WindowId: WindowState]
    /// Every app with at least one live window. Reference-counted against `windows`.
    public private(set) var apps: [String: AppState]
    /// The displays, in system enumeration order — which is meaningful, not incidental: `State.metrics()`
    /// lays the strip out against `monitors.first`, so the order decides which display emira manages.
    public private(set) var monitors: [MonitorState]
    /// The currently focused window, or `nil` when focus has left every managed window. Kept
    /// referentially honest: `remove` clears it if the focused window is the one going away.
    public private(set) var focusedWindow: WindowId?
    /// What each window answered the last time we asked it to be a size. A dictionary rather than a field
    /// on `WindowState` because `State.metrics()` hands it to `LayoutMetrics` on every display-link tick.
    public private(set) var corrections: [WindowId: SizeCorrection]
    /// The least chrome each window has been observed to accept at a park, in points — the answer a
    /// window gives by refusing to sit as far off the bottom edge as it was asked to. A side table for
    /// the reason `corrections` is one, and a *scalar* rather than the whole answer because a floor is a
    /// fact about the window (its title bar, its toolbar) rather than about the slot it was asked for:
    /// keyed to one slot it would have to be re-learned every time the ordinal run renumbers.
    public private(set) var parkFloors: [WindowId: Double]
    /// Windows whose recorded frame is a guess we know to be wrong. Placement writes its target into
    /// `windows` *optimistically* (which stops a repeated idle event re-emitting the same set forever) and
    /// a timed-out write usually can't be read back — so without this mark that guess stands as truth and
    /// `Engine.isAlreadyPlaced` skips the window forever. Not a retry: nothing here schedules anything.
    public private(set) var unverified: Set<WindowId>
    /// The windows the last placement pass put **on the glass** — every other window it placed is parked
    /// at its sliver. Recorded by `Engine.writeTruthPlane` rather than derived, because deriving it needs
    /// both a scroll offset and the layout it was measured against, and the two come apart: through a
    /// transition's capture head the strip can be restructured with no real window moving. `isOnScreen`
    /// reads it, which is how `[focus] system-events` judges a report against where the windows *are*.
    public private(set) var placedOnScreen: Set<WindowId>
    /// The user's explicit float/tile answer per window, where they have given one — `Command.float`.
    /// A side table rather than a field on `WindowState` for the same reason `corrections` is one:
    /// `insert` rebuilds the whole record (a re-scan overwrites it), and an answer the user gave should
    /// outlive a re-enumeration. Absent means "follow the role"; see `isFloating`.
    public private(set) var floating: [WindowId: Bool]
    /// The last window focus rested on that belongs to the strip — "where was the user working", against
    /// `focusedWindow`'s "what is focused", which goes `nil` routinely for a moment because an app focuses
    /// a new window *before* we adopt it. A new column opens beside *this*: without it, ⌘N raced that
    /// transient `nil` and appended at the far end of the strip.
    public private(set) var lastStripFocus: WindowId?

    public init() {
        self.windows = [:]
        self.apps = [:]
        self.monitors = []
        self.focusedWindow = nil
        self.corrections = [:]
        self.parkFloors = [:]
        self.unverified = []
        self.placedOnScreen = []
        self.floating = [:]
        self.lastStripFocus = nil
    }

    // Mutators (each folds exactly one truth-plane Event; all are total)

    /// Fold `Event.windowCreated`: record the window and ensure its app exists (a repeat id overwrites).
    /// `isMinimized` is carried through rather than assumed `false` — launch enumeration meets windows
    /// mid-life, and one already in the Dock must land off the strip at once.
    public mutating func insert(_ snapshot: WindowSnapshot) {
        windows[snapshot.id] = WindowState(
            id: snapshot.id, bundleId: snapshot.bundleId, title: snapshot.title,
            role: snapshot.role, frame: snapshot.frame, isMinimized: snapshot.isMinimized)
        if apps[snapshot.bundleId] == nil {
            apps[snapshot.bundleId] = AppState(bundleId: snapshot.bundleId)
        }
    }

    /// Fold `Event.windowDestroyed`: drop the window, clear focus if it was focused, and garbage-collect
    /// the app record when its last window leaves. A destroy racing a prior removal is normal.
    public mutating func remove(_ id: WindowId) {
        guard let window = windows.removeValue(forKey: id) else { return }
        if focusedWindow == id { focusedWindow = nil }
        corrections[id] = nil
        parkFloors[id] = nil
        unverified.remove(id)
        placedOnScreen.remove(id)
        floating[id] = nil
        if lastStripFocus == id { lastStripFocus = nil }
        if !windows.values.contains(where: { $0.bundleId == window.bundleId }) {
            apps[window.bundleId] = nil
        }
    }

    /// Fold `Event.windowFrameChanged`, and also the optimistic write from `Engine.writeTruthPlane`.
    /// Either way the recorded frame is now the freshest answer we have, so it clears `unverified`.
    public mutating func updateFrame(_ id: WindowId, to frame: Rect) {
        guard windows[id] != nil else { return }
        windows[id]?.frame = frame
        unverified.remove(id)
    }

    /// Record which windows a placement pass just put on the glass. Called by `Engine.writeTruthPlane`
    /// and nowhere else — it is the reducer's only `setFrame`/`park`, and a second place that moved a real
    /// window would make this a lie by omission. `internal`, unlike its neighbours, so that "nowhere else"
    /// is as structural as this can make it: the shell only ever *reads* core state, and every other
    /// mutator here folds an `Event` the shell has to be able to construct. Replaced wholesale, never
    /// merged: a pass places every managed window, so what it does not name it parked.
    mutating func notePlaced(onScreen ids: Set<WindowId>) { placedOnScreen = ids }

    /// Fold `Event.axFailed`: what `windows` holds for this id is a guess we've been told is wrong.
    public mutating func markUnverified(_ id: WindowId) {
        guard windows[id] != nil else { return }
        unverified.insert(id)
    }

    /// Fold `Event.placementCorrected`: record that asking this window for `wanted` produced `actual`.
    /// Last-writer-wins — there is only ever one question in force.
    public mutating func noteCorrection(_ id: WindowId, wanted: Size, actual: Size) {
        guard windows[id] != nil else { return }
        corrections[id] = SizeCorrection(wanted: wanted, actual: actual)
    }

    /// Fold `Event.parkCorrected`: record that this window keeps at least `chrome` points of itself on
    /// screen at a park. Last-writer-wins, like `noteCorrection` — and monotone in practice without
    /// saying so, since a window only ever answers by showing *more* of itself than we asked for.
    public mutating func noteParkFloor(_ id: WindowId, chrome: Double) {
        guard windows[id] != nil else { return }
        parkFloors[id] = chrome
    }

    /// Forget what these windows last answered, so the next placement asks afresh. A resize command is a
    /// cache invalidation — a window's limits usually depend on *what it is currently showing*. Called
    /// only from the explicit resize verbs; a scroll must stay quiet.
    public mutating func forgetCorrections(of ids: [WindowId]) {
        for id in ids { corrections[id] = nil }
    }

    /// Fold `Event.focusChanged`. Stores the argument verbatim — referential validity is the reducer's
    /// contract; World only *enforces* the destroy-clears-focus invariant (see `remove`).
    public mutating func setFocus(_ id: WindowId?) {
        focusedWindow = id
        if let id, participatesInStrip(id) { lastStripFocus = id }
    }

    /// Fold `Event.windowMinimized` / `Event.windowDeminimized`.
    public mutating func setMinimized(_ id: WindowId, _ minimized: Bool) {
        windows[id]?.isMinimized = minimized
    }

    /// Fold an app-level hide/unhide (`Cmd-H`): every window of the app leaves / rejoins the strip at once.
    public mutating func setAppHidden(_ bundleId: String, _ hidden: Bool) {
        apps[bundleId]?.isHidden = hidden
    }

    /// Fold `Event.screensChanged`. Order follows `infos` (authoritative); persisting ids carry their
    /// record forward with the frame refreshed, so per-monitor truth survives a re-enumeration.
    public mutating func setMonitors(_ infos: [MonitorInfo]) {
        let existing = Dictionary(monitors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        monitors = infos.map { info in
            var record = existing[info.id] ?? MonitorState(id: info.id, frame: info.frame)
            record.frame = info.frame
            return record
        }
    }

    // Derived views (deterministically ordered; consumed by the layout engine and CLI dumps)

    /// Whether a window is currently on the tiled strip: it exists, its own state permits tiling, and its
    /// app is not `Cmd-H` hidden. Config-driven float overrides subtract from this elsewhere.
    public func participatesInStrip(_ id: WindowId) -> Bool {
        guard let window = windows[id], !window.isMinimized, !isFloating(id) else { return false }
        return !isAppHidden(of: id)
    }

    /// Whether `Cmd-H` has hidden the app owning `id` — the one reason a window is nowhere on the screen
    /// that is a fact about its app rather than about itself. The reader matching `setAppHidden`, so the
    /// flag is consulted in one spelling by both the strip test and the on-screen one.
    public func isAppHidden(of id: WindowId) -> Bool {
        guard let window = windows[id] else { return false }
        return apps[window.bundleId]?.isHidden ?? false
    }

    /// Whether this window floats: the user's explicit answer where they have given one, else what the
    /// role says. Distinct from "off the strip" — minimizing and `Cmd-H` also take a window off, and
    /// neither of them is a float.
    public func isFloating(_ id: WindowId) -> Bool {
        guard let window = windows[id] else { return false }
        return floating[id] ?? !window.role.tiles
    }

    /// Whether the user can see `id` right now. Not the same question as `participatesInStrip`, and the
    /// difference is the whole of this function: **off the strip and off the screen are different sets.**
    /// A float is off the strip and plainly visible; a minimized window is off the strip and in the Dock.
    ///
    /// For a window emira *does* place the answer is the `.setFrame`-vs-`.park` switch, and the last
    /// placement pass already made it: `placedOnScreen` is that decision, kept. Asking it rather than
    /// re-deriving it is what keeps the question "where is this window" from being answered with where
    /// it is *going* — the viewport describes the destination for the whole of a reveal — or with where
    /// it would be under a strip that has been restructured since it was last placed. Membership
    /// subsumes the workspace test too: a pass parks everything off the focused strip.
    public func isOnScreen(_ id: WindowId) -> Bool {
        guard let window = windows[id] else { return false }
        // Nowhere on the screen for a reason that has nothing to do with the strip.
        guard !window.isMinimized, !isAppHidden(of: id) else { return false }
        // A window emira does not place is wherever its app put it, which is in view.
        guard participatesInStrip(id) else { return true }
        return placedOnScreen.contains(id)
    }

    /// The window under `point`, in top-left global coordinates — the hit test behind
    /// `[focus] follows-mouse`.
    ///
    /// Here because every term of it is `World`'s, and public because the *shell* asks it: raw samples
    /// must not reach the pump (see `Event.pointerEntered`), so the crossing is detected outside.
    /// Restricted to `isOnScreen`, which excludes parked nubs **for free** — a nub sits under a hot
    /// corner, where a stray sweep would otherwise switch workspaces.
    ///
    /// **Floats and dialogs before tiled windows**, since emira declines an opinion about where a float
    /// sits. That is as far as `World` sees: it knows frames, not stacking, so an *unmanaged* window over
    /// a tiled one still resolves to the tiled one.
    ///
    /// One pass and no intermediate arrays — this runs at the refresh rate for as long as the setting is
    /// on. Ties break on the lowest id, a dictionary's order being no order, and only floats can tie.
    public func window(at point: Point) -> WindowId? {
        var float: WindowId?
        var tiled: WindowId?
        for window in windows.values where window.frame.contains(point) && isOnScreen(window.id) {
            let id = window.id
            if isFloating(id) {
                float = float.map { min($0, id) } ?? id
            } else {
                tiled = tiled.map { min($0, id) } ?? id
            }
        }
        return float ?? tiled
    }

    /// Fold `Command.float`. Stored **explicitly**, even when it agrees with the role, because a
    /// subrole describes a window's *presentation* and can change under us — a natively full-screen
    /// Safari window reports `AXDialog` (§10) — and the user's answer must outrank a role that moves.
    public mutating func setFloating(_ id: WindowId, _ isFloating: Bool) {
        guard windows[id] != nil else { return }
        floating[id] = isFloating
    }

    /// The windows currently on the strip, sorted by id for deterministic layout and replay.
    public var stripWindowIds: [WindowId] {
        windows.keys.filter(participatesInStrip).sorted()
    }

    /// The ids of every live window owned by `bundleId`, sorted — what app-level operations read.
    public func windowIds(inApp bundleId: String) -> [WindowId] {
        windows.values.filter { $0.bundleId == bundleId }.map(\.id).sorted()
    }

    public var focusedWindowState: WindowState? {
        focusedWindow.flatMap { windows[$0] }
    }
}
