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

/// The core's record of a display: identity plus the two geometry facts observation refreshes. Its own
/// type, so World state doesn't depend on the `MonitorInfo` wire shape. Which *workspaces* a display
/// holds is structure and lives in `Monitors`, the same split `World`/`Workspaces` already has.
public struct MonitorState: Sendable, Equatable, Codable {
    public let id: MonitorId
    /// The display's full bounds in top-left virtual-strip coordinates.
    public var frame: Rect
    /// The chrome this display reserves. Per display and live — the Dock moves between them — which is
    /// why it is refreshed here rather than read once into `Config`.
    public var struts: EdgeInsets
    /// Whether macOS calls this the main display. Here rather than in `Monitors` because observation
    /// refreshes it — which is also what lets `setMonitors` read the *previous* main out of `World`
    /// before folding the new report over it, rather than remembering one separately.
    public var isMain: Bool

    public init(id: MonitorId, frame: Rect, struts: EdgeInsets = .zero, isMain: Bool = false) {
        self.id = id
        self.frame = frame
        self.struts = struts
        self.isMain = isMain
    }

    /// Where the strip is laid out on this display: its bounds minus its own chrome.
    public var workingArea: Rect { frame.inset(by: struts) }
}

/// Where a pinned window is held: the display, the edge, and the width stack it walks —
/// `ColumnLayout`'s two lower rungs exactly, minus the fullscreen one, since a pin already fills its
/// own band. `PresetSize` and never points, so a pin at a quarter of one display is a quarter of the
/// next.
public struct PinPlacement: Sendable, Equatable, Codable {
    public var monitor: MonitorId
    public var side: PinSide
    public var widthPreset: Int
    public var widthOverride: PresetSize?

    public init(monitor: MonitorId, side: PinSide, widthPreset: Int = 0,
                widthOverride: PresetSize? = nil) {
        self.monitor = monitor
        self.side = side
        self.widthPreset = widthPreset
        self.widthOverride = widthOverride
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
    /// The windows held at a display's edge — `Command.pin`. Beside `floating` and keyed the same way
    /// because it is the same *kind* of fact: the user's answer about whether a window is on the strip
    /// at all, which is what `participatesInStrip` reads. **At most one window per (display, side)**,
    /// which `setPin` is the only writer of.
    public private(set) var pins: [WindowId: PinPlacement]
    /// The last window focus rested on that belongs to the strip — "where was the user working", against
    /// `focusedWindow`'s "what is focused", which goes `nil` routinely for a moment because an app focuses
    /// a new window *before* we adopt it. A new column opens beside *this*: without it, ⌘N raced that
    /// transient `nil` and appended at the far end of the strip.
    ///
    /// It names a *place* the user can be handed back to, not merely a window that once had focus:
    /// `pruneStripFocus` drops it when its window leaves the strip, `noteStripFocus` moves it on.
    public private(set) var lastStripFocus: WindowId?
    /// The last window focus rested on, **whatever kind of window it was** — the same shelter from that
    /// transient `nil`, one constraint looser, because a float and a full-screen window are both windows
    /// a user works in and neither is ever `lastStripFocus`. What an arrival is measured against.
    public private(set) var lastFocus: WindowId?
    /// When each window last took focus — the whole of what emira knows about **stacking**, and it is
    /// derived rather than read: the window server's own answer costs a `CGWindowListCopyWindowInfo`
    /// that blocks for as long as another app's animation runs. Absent reads as 0, below everything
    /// focused and above nothing, so a desktop nothing has focused knows of no window behind another.
    public private(set) var focusedAt: [WindowId: Int] = [:]
    /// The counter behind `focusedAt`. Monotonic and never reset — it orders the session rather than the
    /// windows in it, so two windows can never share a rank.
    private var focusClock = 0

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
        self.pins = [:]
        self.lastStripFocus = nil
        self.lastFocus = nil
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
        pins[id] = nil
        focusedAt[id] = nil
        pruneStripFocus()
        if lastFocus == id { lastFocus = nil }
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
        let previous = focusedWindow
        focusedWindow = id
        if let id { lastFocus = id }
        if let id, participatesInStrip(id) { lastStripFocus = id }
        // The stacking record, written wherever focus is, and unconditional on kind: a float taking
        // focus is the event that puts it back on top, and it is the one this exists to catch.
        //
        // **Only when focus actually moved.** Re-asserting focus onto the window that already has it
        // raises nothing — it is already in front — so bumping the clock for it would make a fold that
        // changes nothing on the desktop change `World`, and the echo of our own `.focus` is exactly
        // that fold.
        if let id, id != previous, windows[id] != nil {
            focusClock += 1
            focusedAt[id] = focusClock
        }
    }

    /// Move the strip memory without moving focus — what `setFocus` cannot say, for a window that carries
    /// focus *off* the strip and leaves a place behind it. Refuses a window that is not on the strip,
    /// which is `setFocus`'s own guard and the invariant `pruneStripFocus` keeps.
    public mutating func noteStripFocus(_ id: WindowId) {
        guard participatesInStrip(id) else { return }
        lastStripFocus = id
    }

    /// Record that `id`'s app was brought to the front without moving focus — `setFocus`'s stacking half
    /// alone. What a pin's fence writes, and what pays a gated focus out on top of it: both are orderings
    /// the core decides, so neither waits on the arrival of two apps' notifications.
    public mutating func noteActivation(_ id: WindowId) {
        guard windows[id] != nil else { return }
        focusClock += 1
        focusedAt[id] = focusClock
    }

    /// Drop the strip memory when it names a window that is no longer on the strip — the invariant that
    /// separates `lastStripFocus` from `lastFocus`, kept here rather than re-argued at every read. Called
    /// by each of the four mutators that can break it: destroy, float, minimize, `Cmd-H`.
    private mutating func pruneStripFocus() {
        guard let id = lastStripFocus, !participatesInStrip(id) else { return }
        lastStripFocus = nil
    }

    /// Fold `Event.windowMinimized` / `Event.windowDeminimized`.
    public mutating func setMinimized(_ id: WindowId, _ minimized: Bool) {
        windows[id]?.isMinimized = minimized
        pruneStripFocus()
    }

    /// Fold an app-level hide/unhide (`Cmd-H`): every window of the app leaves / rejoins the strip at once.
    public mutating func setAppHidden(_ bundleId: String, _ hidden: Bool) {
        apps[bundleId]?.isHidden = hidden
        pruneStripFocus()
    }

    /// Fold `Event.screensChanged`. Order follows `infos` (authoritative); persisting ids carry their
    /// record forward with the geometry refreshed, so per-monitor truth survives a re-enumeration.
    public mutating func setMonitors(_ infos: [MonitorInfo]) {
        let existing = Dictionary(monitors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        monitors = infos.map { info in
            var record = existing[info.id] ?? MonitorState(id: info.id, frame: info.frame)
            record.frame = info.frame
            record.struts = info.struts
            record.isMain = info.isMain
            return record
        }
    }

    /// The display macOS calls **main** — the one with the menu bar — or `nil` with none attached.
    /// Read *before* `setMonitors` folds a new report to learn which display held the role last, which
    /// is the whole of how a main change is detected.
    public var mainMonitor: MonitorId? { monitors.first(where: \.isMain)?.id }

    /// The display `id` names, or `nil` — what `State.metrics(of:)` asks before it can lay anything out.
    public func monitor(_ id: MonitorId) -> MonitorState? {
        monitors.first { $0.id == id }
    }

    /// The display `point` is on, or `nil` — off every screen, or none attached. Asked of the **full**
    /// frame rather than the working area, since a pointer in the menu bar is still on that display.
    ///
    /// Its one caller is the hover filter, which needs to know whether the screen under the hand is the
    /// one with a cover over it: a question about where the pointer *is*, which no window it happens to
    /// be over can answer.
    public func monitor(at point: Point) -> MonitorId? {
        monitors.first { $0.frame.contains(point) }?.id
    }

    // Derived views (deterministically ordered; consumed by the layout engine and CLI dumps)

    /// Whether a window is currently on the tiled strip: it exists, its own state permits tiling, and its
    /// app is not `Cmd-H` hidden. Config-driven float overrides subtract from this elsewhere.
    public func participatesInStrip(_ id: WindowId) -> Bool {
        guard let window = windows[id], !window.isMinimized, !isFloating(id),
              !isPinned(id) else { return false }
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

    /// Whether *somebody asked* for this window to float, as against macOS's opinion of it — the same
    /// tri-state `isFloating` collapses, read without collapsing it. An explicit `true` is only ever
    /// written by `Command.float` or a rule's `float = true`; `nil` under a non-tiling role is the
    /// taxonomy speaking. What hoisting reads, because a picture over a background app's tool palettes
    /// is not floating them, it is putting them in the way.
    public func isFloatedByChoice(_ id: WindowId) -> Bool {
        windows[id] != nil && floating[id] == true
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
        // The two are exclusive, and the exclusion is stated here rather than argued at each verb:
        // both mean *off the strip*, and two records of that would be two authorities on membership.
        if isFloating { pins[id] = nil }
        pruneStripFocus()
    }

    // Pinning (a window the display holds, on no strip at all)

    /// Whether this window is held at a display's edge. The hot read — `participatesInStrip` asks it
    /// once per window per placement pass — which is why the table is keyed by window and not by side.
    public func isPinned(_ id: WindowId) -> Bool { pins[id] != nil }

    /// The window `monitor` holds on `side`, or `nil`. Determinate despite the dictionary's own lack of
    /// order: at most one entry can match, which `setPin` maintains by evicting.
    public func pinned(on monitor: MonitorId, _ side: PinSide) -> WindowId? {
        pins.first { $0.value.monitor == monitor && $0.value.side == side }?.key
    }

    /// What `monitor` holds pinned, by side — the shape `LayoutMetrics` takes, carrying the width stack
    /// rather than a resolved width, because resolving one needs an extent this container has no idea
    /// about.
    public func pinBands(on monitor: MonitorId) -> [PinSide: PinBand] {
        var bands: [PinSide: PinBand] = [:]
        for (id, pin) in pins where pin.monitor == monitor {
            bands[pin.side] = PinBand(window: id, widthPreset: pin.widthPreset,
                                      widthOverride: pin.widthOverride)
        }
        return bands
    }

    /// Fold `Command.pin`: hold `id` at `side` of `monitor`, evicting whatever held that side and
    /// clearing any float — **the one writer**, which is what makes both exclusions hold from outside.
    public mutating func setPin(_ id: WindowId, on monitor: MonitorId, side: PinSide,
                                widthPreset: Int = 0, widthOverride: PresetSize? = nil) {
        guard windows[id] != nil else { return }
        if let held = pinned(on: monitor, side), held != id { pins[held] = nil }
        floating[id] = nil
        pins[id] = PinPlacement(monitor: monitor, side: side, widthPreset: widthPreset,
                                widthOverride: widthOverride)
        pruneStripFocus()
    }

    /// Fold `pin off`: the window rejoins the strip. Total.
    public mutating func clearPin(_ id: WindowId) { pins[id] = nil }

    /// Re-record a pin's width intent — `grow`/`shrink` write the override, `cycle-width` the index and
    /// a cleared override, exactly as they do one container over on a column.
    public mutating func setPinWidth(_ id: WindowId, preset: Int, override: PresetSize?) {
        guard pins[id] != nil else { return }
        pins[id]?.widthPreset = preset
        pins[id]?.widthOverride = override
    }

    /// Re-home the pins of displays that are no longer attached onto `monitor`, evicting a side it
    /// already holds. Called by `State.setMonitors`, which is the only thing that knows what survived.
    ///
    /// With nothing attached there is nowhere to go and the records simply wait: no display means no
    /// metrics, so nothing is placed at all until one arrives and this runs again.
    public mutating func rehomePins(attached: Set<MonitorId>, onto monitor: MonitorId?) {
        let stranded = pins.filter { !attached.contains($0.value.monitor) }
        guard let monitor, !stranded.isEmpty else { return }
        for (id, pin) in stranded.sorted(by: { $0.key < $1.key }) {
            setPin(id, on: monitor, side: pin.side, widthPreset: pin.widthPreset,
                   widthOverride: pin.widthOverride)
        }
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
