import Foundation

// The **truth-plane** half of core `State` (IMPLEMENTATION.md §5, `State/World.swift`): a faithful,
// framework-free mirror of what actually exists on the system as reported by AX + `NSWorkspace`
// observations — monitors, apps, windows, and focus. It is pure data plus **total mutators**; the
// `Engine` reducer (a later iteration) folds truth-plane `Event`s into it, and the layout engine
// reads `stripWindowIds` out of it. `Layout` (where windows sit on the strip) and `Motion`
// (animation state) are the *other* two halves of `State` and land next.
//
// World is deliberately dumb. It records observed reality and enforces exactly **one** invariant —
// focus can never reference a destroyed window — and one bookkeeping rule — the `apps` map is
// reference-counted by window membership (an app exists iff it has ≥1 window). Everything with a
// choice in it — snap-vs-transition, which window to focus after a close, config-driven float
// overrides — is *policy* and lives in the reducer / rules engine, never here. That split is what
// keeps this type trivially testable: fold an event, assert the record.
//
// **App identity in the core is the `bundleId`** (decided this iteration — settling the grouping
// question the deferred Cmd-H `Event` was waiting on). The core never sees a pid (PRINCIPLES.md §7:
// rules match the stable `bundleId`, the pid/`AXUIElement`/`CGWindowID` binding stays shell-side),
// so app grouping keys on `bundleId`, and app-level hide (`Cmd-H`, which hides *all* of an app's
// windows at once) is naturally a single `AppState.isHidden` flag shared by every window of that
// app. This assumes one running instance per bundle for grouping purposes; if a genuine two-instance
// case ever bites, the shell — which owns the pid — disambiguates before the boundary.

/// The core's internal record of a live window — distinct from `WindowSnapshot` (the boundary DTO
/// the shell hands in at first sight). `id` and `bundleId` are identity and never change; the rest
/// is mutable truth updated over the window's lifetime by observation events.
public struct WindowState: Sendable, Equatable, Codable {
    /// The core-minted id (bound to a `CGWindowID` shell-side). Immutable identity.
    public let id: WindowId
    /// The owning app's bundle identifier — the app-grouping key and the stable key rules match on.
    public let bundleId: String
    /// The window's current title. Mutable (apps rewrite it); never used for identity after binding.
    public var title: String
    /// The window's tiling role (§6 taxonomy). Only `.standard` joins the strip.
    public var role: WindowRole
    /// Last-known truth frame in top-left virtual-strip coordinates (the shell Y-flips at its edge).
    /// Updated by `windowFrameChanged` (usually a user drag/resize) and by `axLanded` reconcile.
    public var frame: Rect
    /// Whether the window is minimized. Per the 2026-07-23 decision a minimized window **leaves the
    /// strip** (like a close), so this subtracts from strip participation.
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

    /// Window-**local** tiling truth: this window's own state permits tiling. Combined with the
    /// app-level hidden flag (which lives on `AppState`, not here) at the `World` level to decide
    /// actual strip participation — see `World.participatesInStrip`.
    public var isTileable: Bool { role.tiles && !isMinimized }
}

/// What one window answered the last time the layout asked it to be a particular size.
///
/// **There is no public AX attribute for a window's minimum size** — `NSWindow.minSize` is not
/// exported over the Accessibility API and `kAXMinValueAttribute` belongs to value-taking controls,
/// not windows. So we cannot *know* an app's constraints; we can only know what it did when we asked.
/// That turns out to be enough, and it is strictly more robust than a learned minimum would be:
///
/// > **Ask the question once, then use the answer — and re-ask when the question changes.**
///
/// `wanted` is the **uncorrected** size the layout asked for — the *question*, not the literal AX
/// request (the two differ the moment a correction is in force). Keying on the question is what makes
/// this self-invalidating: cycling a width preset, editing gaps or struts, moving to another display,
/// or joining a column of a different width all change the question, so the stale answer is simply not
/// consulted and the app is asked afresh.
///
/// It is also what stops a naive "learned minimum" from **ratcheting**. A terminal that quantizes to
/// character cells answers a 900 pt question with 904; recorded as a minimum, that 904 would floor the
/// ⅓ preset forever and the column could never be 600 again. Recorded against its question it is inert
/// the moment the question is 600.
public struct SizeCorrection: Sendable, Equatable, Codable {
    /// The uncorrected size the layout wanted — the question this is the answer to.
    public var wanted: Size
    /// The size the window actually ended up at.
    public var actual: Size

    public init(wanted: Size, actual: Size) {
        self.wanted = wanted
        self.actual = actual
    }

    /// This answer's width, if it answers `question` — **in either direction** (corrected 2026-07-26).
    ///
    /// This was `widthFloor`, and it consulted the answer only when it was *larger*, on the grounds
    /// that an over-filled slot is an overlap (the one invariant the strip promises) while an
    /// under-filled one is "a gap, which is cosmetic". The second half was wrong, and the product said
    /// so within the hour: a column's width **is strip extent** — it sets where every column right of it
    /// begins, what a scroll reveals, what is tiled versus parked, and what the sweep captures. A
    /// 1800 pt column holding a 723 pt window is 1077 pt of desktop the whole layout treats as content,
    /// and it is permanent, because the intent that produced it is stored.
    ///
    /// So an answer is an answer. The *direction* still matters, but it belongs where the column is
    /// assembled rather than here: `Layout.resolvedWidth` takes the **widest** width its windows can
    /// actually achieve, which absorbs a refusal-to-shrink (that window needs the room) and a
    /// refusal-to-grow (nobody can use the room) with one `max` instead of two rules.
    public func width(forQuestion question: Double, tolerance: Double = 0.5) -> Double? {
        guard abs(wanted.width - question) <= tolerance else { return nil }
        return actual.width
    }

    /// This answer's height, if it answers `question` and is **taller** — the case a stacked column
    /// reaches when its share drops below what an app accepts, feeding `Column`'s height water-fill.
    ///
    /// Still one-directional, where `width(forQuestion:)` above stopped being so, and the asymmetry is
    /// real rather than an oversight. A column's *width* is strip extent, so an intent no window can
    /// fill is phantom desktop; a column's *height* is the viewport's, fixed, and a window that refuses
    /// to be as tall as its share leaves space with nowhere to go but a gap inside the column — which
    /// is the genuinely cosmetic case the width rule was wrongly assumed to be. A shorter answer will
    /// therefore still be re-asked on a placement whose position changed; that is the vertical shadow
    /// of the bug fixed above, unobserved in the product (no app has yet refused a height) and left
    /// unbuilt rather than guessed at.
    public func heightFloor(forQuestion question: Double, tolerance: Double = 0.5) -> Double? {
        guard abs(wanted.height - question) <= tolerance, actual.height > question + tolerance
        else { return nil }
        return actual.height
    }
}

/// The core's record of a running app. Currently just identity plus the app-level hidden flag; it
/// exists so `Cmd-H` (which hides every window of an app at once) is one shared piece of truth rather
/// than a flag denormalized onto each window. Reference-counted by `World`: created when an app's
/// first window appears, dropped when its last window is destroyed.
public struct AppState: Sendable, Equatable, Codable {
    /// The app's bundle identifier — the grouping key. Immutable identity.
    public let bundleId: String
    /// Whether the app is `Cmd-H` hidden. When `true`, all of its windows leave the strip (§6).
    public var isHidden: Bool

    public init(bundleId: String, isHidden: Bool = false) {
        self.bundleId = bundleId
        self.isHidden = isHidden
    }
}

/// The core's record of a display. Currently identity + geometry; struts (menu-bar/notch) are applied
/// by the layout engine, not baked in here, and per-monitor workspace pointers are a `Layout` concern
/// (next iteration), so this stays minimal. It's the core's own type rather than the `MonitorInfo`
/// boundary DTO so World state doesn't structurally depend on the wire shape.
public struct MonitorState: Sendable, Equatable, Codable {
    /// The shell-minted display id. Immutable identity within a hardware set.
    public let id: MonitorId
    /// The display's full bounds in top-left virtual-strip coordinates.
    public var frame: Rect

    public init(id: MonitorId, frame: Rect) {
        self.id = id
        self.frame = frame
    }
}

/// The truth-plane state: the live windows, the apps that own them, the displays, and where focus
/// sits. Mutated only through the total methods below (stored properties are `private(set)` so the
/// two invariants — focus integrity and app ref-counting — can't be broken from outside).
public struct World: Sendable, Equatable, Codable {
    /// Every live window, keyed by id. Dictionary order is nondeterministic — always derive ordered
    /// views (e.g. `stripWindowIds`) by sorting, never by iterating this directly.
    public private(set) var windows: [WindowId: WindowState]
    /// Every app with at least one live window, keyed by `bundleId`. Reference-counted against
    /// `windows`: an entry appears with an app's first window and vanishes with its last.
    public private(set) var apps: [String: AppState]
    /// The displays, in enumeration order (so `MonitorRef.index`/`.next` resolve consistently —
    /// PRINCIPLES/§ IMPLEMENTATION). Reconciled wholesale by `setMonitors`.
    public private(set) var monitors: [MonitorState]
    /// The currently focused window, or `nil` when focus has left every managed window (Cmd-Tab to an
    /// unmanaged app, all windows closed). Kept referentially honest: `remove` clears it if the
    /// focused window is the one going away.
    public private(set) var focusedWindow: WindowId?
    /// What each window answered the last time we asked it to be a size (`SizeCorrection`) — the
    /// record that lets the layout stop asking apps for sizes they refuse.
    ///
    /// A dictionary here rather than a field on `WindowState` for one reason: `State.metrics()` hands
    /// this straight to `LayoutMetrics`, and `metrics()` is called from `emitLayerFrames` on **every
    /// display-link tick**. Deriving a map from `windows` 120 times a second to answer a question about
    /// a handful of stubborn apps is not a trade worth making. Keyed by the same id as `windows` and
    /// garbage-collected by the same `remove`, so the two cannot drift.
    public private(set) var corrections: [WindowId: SizeCorrection]
    /// Windows whose recorded frame is a guess we know to be wrong.
    ///
    /// Placement records its target into `windows` **optimistically** — we asked, it will land, and a
    /// failure comes back as `Event.axFailed` — which is what stops a repeated idle event from
    /// re-emitting the same set forever. But `axFailed` is precisely the case where it did *not* land,
    /// and the executor can only correct the frame when it could still *read* it back
    /// (`AXExecutor.report`); a write that timed out usually cannot be read either, so nothing arrives
    /// and the optimistic value stands as truth. The window then sits wherever the app left it while
    /// `Engine.isAlreadyPlaced` skips it on every future placement — a column-shaped hole on the strip
    /// with a real window loose behind it, for as long as its target doesn't happen to change.
    ///
    /// So `axFailed` records the one thing we do know: **that we don't know**. Membership makes
    /// `isAlreadyPlaced` answer `false`, so the next placement re-issues the set; issuing it clears the
    /// mark (`updateFrame`). It is deliberately *not* a retry — nothing here schedules anything, so a
    /// genuinely hung app costs one extra set per real event rather than a busy loop (2026-07-26).
    public private(set) var unverified: Set<WindowId>
    /// The last window focus rested on that belongs to the strip.
    ///
    /// `focusedWindow` is the honest answer to "what is focused", including `nil` and including windows
    /// with no column — and it goes `nil` routinely for a moment, because an app focuses a brand-new
    /// window *before* we have adopted it, so the observer resolves that element to nothing. This is
    /// the answer to a different question — "where was the user working" — which is what a new column
    /// opens beside (`Layout.reconcile(stripWindowIds:insertingAfter:)`). Without it, every ⌘N raced
    /// that transient `nil` and appended at the far end of the strip (2026-07-26).
    public private(set) var lastStripFocus: WindowId?

    /// An empty world — the launch state before any window is enumerated. Populate via the mutators.
    public init() {
        self.windows = [:]
        self.apps = [:]
        self.monitors = []
        self.focusedWindow = nil
        self.corrections = [:]
        self.unverified = []
        self.lastStripFocus = nil
    }

    // MARK: - Mutators (each folds exactly one truth-plane Event; all are total)

    /// Fold `Event.windowCreated`: record the window and ensure its app exists. Create-only in
    /// practice (the shell mints a fresh `WindowId` per window); a repeat id overwrites, last-writer-
    /// wins. An unseen `bundleId` mints a fresh, unhidden `AppState`.
    ///
    /// The snapshot's `isMinimized` is carried through rather than assumed `false`: launch enumeration
    /// meets windows mid-life, and one already in the Dock must land off the strip immediately, not
    /// after a correcting event that may never come.
    public mutating func insert(_ snapshot: WindowSnapshot) {
        windows[snapshot.id] = WindowState(
            id: snapshot.id, bundleId: snapshot.bundleId, title: snapshot.title,
            role: snapshot.role, frame: snapshot.frame, isMinimized: snapshot.isMinimized)
        if apps[snapshot.bundleId] == nil {
            apps[snapshot.bundleId] = AppState(bundleId: snapshot.bundleId)
        }
    }

    /// Fold `Event.windowDestroyed`: drop the window, clear focus if it was focused, and garbage-
    /// collect the app record when its last window leaves. No-op on an unknown id (a destroy racing a
    /// prior removal is normal, not an error — the core stays total).
    public mutating func remove(_ id: WindowId) {
        guard let window = windows.removeValue(forKey: id) else { return }
        if focusedWindow == id { focusedWindow = nil }
        corrections[id] = nil
        unverified.remove(id)
        if lastStripFocus == id { lastStripFocus = nil }
        if !windows.values.contains(where: { $0.bundleId == window.bundleId }) {
            apps[window.bundleId] = nil
        }
    }

    /// Fold `Event.windowFrameChanged`: update the last-known truth frame. No-op on an unknown id.
    ///
    /// Also the optimistic write from `Engine.emitPlacements`. Either way the recorded frame is now
    /// the freshest answer we have, so it clears any `unverified` mark: an observation is the truth,
    /// and a re-issued set is the question being asked again.
    public mutating func updateFrame(_ id: WindowId, to frame: Rect) {
        guard windows[id] != nil else { return }
        windows[id]?.frame = frame
        unverified.remove(id)
    }

    /// Fold `Event.axFailed`: the app refused or never answered the write, so what `windows` holds for
    /// this id is a guess we have been told is wrong. See `unverified`.
    public mutating func markUnverified(_ id: WindowId) {
        guard windows[id] != nil else { return }
        unverified.insert(id)
    }

    /// Fold `Event.placementCorrected`: record that asking this window for `wanted` produced `actual`.
    /// Last-writer-wins — one answer per window, because there is only ever one question in force.
    /// No-op on an unknown id, so a correction can never outlive the window it describes.
    public mutating func noteCorrection(_ id: WindowId, wanted: Size, actual: Size) {
        guard windows[id] != nil else { return }
        corrections[id] = SizeCorrection(wanted: wanted, actual: actual)
    }

    /// Fold `Event.focusChanged`: record where focus landed (or `nil` if it left every managed
    /// window). Stores the argument verbatim — referential validity is the reducer's contract; World
    /// only *enforces* the destroy-clears-focus invariant (see `remove`).
    public mutating func setFocus(_ id: WindowId?) {
        focusedWindow = id
        if let id, participatesInStrip(id) { lastStripFocus = id }
    }

    /// Fold `Event.windowMinimized` / `Event.windowDeminimized`: toggle the minimized flag (which
    /// gates strip participation). No-op on an unknown id.
    public mutating func setMinimized(_ id: WindowId, _ minimized: Bool) {
        windows[id]?.isMinimized = minimized
    }

    /// Fold an app-level hide/unhide (`Cmd-H`; the `Event` case lands with app modeling). Flips the
    /// shared flag so every window of the app leaves / rejoins the strip at once. No-op if no such app
    /// is present.
    public mutating func setAppHidden(_ bundleId: String, _ hidden: Bool) {
        apps[bundleId]?.isHidden = hidden
    }

    /// Fold `Event.screensChanged`: reconcile the display set against the new enumeration. Order
    /// follows `infos` (authoritative); persisting ids carry their existing record forward (so future
    /// per-monitor truth survives a re-enumeration) with the frame refreshed; vanished ids drop.
    public mutating func setMonitors(_ infos: [MonitorInfo]) {
        let existing = Dictionary(monitors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        monitors = infos.map { info in
            var record = existing[info.id] ?? MonitorState(id: info.id, frame: info.frame)
            record.frame = info.frame
            return record
        }
    }

    // MARK: - Derived views (deterministically ordered; consumed by the layout engine and CLI dumps)

    /// Whether a window is currently on the tiled strip: it exists, its own state permits tiling
    /// (`.standard` role, not minimized), and its app is not `Cmd-H` hidden. This is the §6 default
    /// taxonomy as one predicate; config-driven float overrides (M3 rules) will later subtract from
    /// it, but they aren't truth and don't live here.
    public func participatesInStrip(_ id: WindowId) -> Bool {
        guard let window = windows[id], window.isTileable else { return false }
        return !(apps[window.bundleId]?.isHidden ?? false)
    }

    /// The windows currently on the strip, sorted by id for deterministic layout and replay. This is
    /// the set the layout engine arranges into columns.
    public var stripWindowIds: [WindowId] {
        windows.keys.filter(participatesInStrip).sorted()
    }

    /// The ids of every live window owned by `bundleId`, sorted. The grouping app-level operations
    /// (`Cmd-H`, focus-next-in-app) read.
    public func windowIds(inApp bundleId: String) -> [WindowId] {
        windows.values.filter { $0.bundleId == bundleId }.map(\.id).sorted()
    }

    /// The display at an enumeration index (for `MonitorRef.index`), bounds-checked to `nil`.
    public func monitor(atIndex index: Int) -> MonitorState? {
        monitors.indices.contains(index) ? monitors[index] : nil
    }

    /// The focused window's full record, if focus is on a live window.
    public var focusedWindowState: WindowState? {
        focusedWindow.flatMap { windows[$0] }
    }
}
