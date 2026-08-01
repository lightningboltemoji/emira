import Foundation
import EmiraMotion

// The animation half of core `State`, alongside `World` (truth) and `Layout` (structure). It holds the
// three animated quantities — the strip's `viewportOffset`, each in-flight column's resolved width, and
// each in-flight window's displacement — plus the ephemeral transition session (the cover lifecycle).
//
// The core owns the clock: every quantity is an `Animator` (`{current, velocity, target}`) that `Motion`
// advances itself on `Event.tick(dt)`, never a `CAAnimation`. That is what makes interruption pure
// arithmetic — retargeting mid-flight carries the live velocity through untouched.

/// One window's reconstruction layer: the core-minted `LayerId` the shell tags it with (so
/// `Effect.setLayerFrame` can name it) and the `WindowId` whose captured surface it shows. Array order in
/// `Effect.beginTransition` is z-order, bottom→top.
public struct LayerBinding: Sendable, Equatable, Codable {
    public let window: WindowId
    public let layer: LayerId

    public init(window: WindowId, layer: LayerId) {
        self.window = window
        self.layer = layer
    }
}

/// Where the authority over the real windows sits right now — `TransitionSession.Phase` extended with the
/// case a session cannot represent, its own absence. The reducer routes every re-place on this.
public enum MotionPhase: Sendable, Equatable {
    /// No session, so a placement pass owns the reals and writes them at `viewportOffset.current`.
    case idle
    /// A session is open and no cover has been built. No real window has moved, and none may: nothing is
    /// over the desktop to hide a write.
    case capturing
    /// The cover has been handed to the shell and is on its way to the glass. Still nothing may move —
    /// a committed cover is not a visible one (see `confirmCover`).
    case raising
    /// The cover is up *on screen*, so `teleportBehindCover` owns the reals and writes them at the
    /// scroll's end; `viewportOffset.current` is the spring's, feeding the layers.
    case covered
}

/// The ephemeral cover lifecycle for one transition. Data + narrow mutators (all total); the reducer
/// drives the phase progression `.capturing` (captures requested, no cover built, so no real window has
/// moved) → `.raising` (cover built and handed over, still nothing moved) → `.covered` (cover on the
/// glass, reals teleported behind it, layers sliding each tick until the animators settle *and* the
/// scoped `axLanded`s arrive). The scoped set `windows` is the union of "start *or* end frame intersects
/// the viewport": exactly the windows that must be captured and whose AX landing gates the close.
/// Park→park moves never come into view, so they are out of scope and block nothing.
public struct TransitionSession: Sendable, Equatable, Codable {
    /// Which lifecycle phase the session is in; advances `.capturing → .raising` at `raiseCover` and
    /// `.raising → .covered` at `confirmCover`, each once.
    public enum Phase: Sendable, Equatable, Codable {
        case capturing
        case raising
        case covered
    }

    public private(set) var phase: Phase
    /// The scoped window set, in z-order (bottom→top) — both the capture set and the `axLanded` wait set.
    /// Grows, never shrinks: a retarget can sweep in windows the session wasn't scoped for (which would
    /// otherwise be holes in the cover), and removing one abandons a layer and a teleport mid-flight.
    public private(set) var windows: [WindowId]
    /// Scoped windows whose still hasn't landed yet. Empty ⇒ ready to raise the cover.
    public private(set) var pendingCaptures: Set<WindowId>
    /// Scoped windows whose real AX set hasn't landed yet. Empty (with the animators settled) ⇒ ready to
    /// cross-fade out.
    public private(set) var awaitingLanding: Set<WindowId>
    /// The `WindowId → LayerId` association, minted at `raiseCover`. Empty while `.capturing`.
    public private(set) var layerIds: [WindowId: LayerId]
    /// The window drawn on top for the whole transition — the one a structural edit is moving, which is
    /// what makes a swap read as a swap when two columns pass through each other. `nil` for a scroll or
    /// resize. Re-applied after every `extendCover`, since additions land on top.
    public private(set) var elevated: WindowId?

    init(windows: [WindowId], elevated: WindowId? = nil) {
        self.phase = .capturing
        self.windows = windows
        self.pendingCaptures = Set(windows)
        self.awaitingLanding = Set(windows)
        self.layerIds = [:]
        self.elevated = elevated
    }

    mutating func markCaptured(_ id: WindowId) { pendingCaptures.remove(id) }

    mutating func elevate(_ id: WindowId) { elevated = id }

    /// Widen the scope, returning the ids actually added (already-scoped windows are skipped, so this is
    /// idempotent); each addition owes a capture in either phase. Additions land at the *end*, i.e. on
    /// top in z-order rather than in strip order.
    mutating func extend(with newcomers: [WindowId]) -> [WindowId] {
        let known = Set(windows)
        let added = newcomers.filter { !known.contains($0) }
        guard !added.isEmpty else { return [] }
        windows.append(contentsOf: added)
        pendingCaptures.formUnion(added)
        return added
    }

    /// Scoped windows that have a still and no layer yet — what a raised cover still owes and can pay.
    /// Excluding pending captures is load-bearing: the shell binds each minted layer id *once*, skipping
    /// any window it has no still for, so naming one whose capture is in flight spends its only chance at
    /// a layer. Asking per window also cannot starve, where a session-wide `captureComplete` gate does.
    var unboundWindows: [WindowId] {
        windows.filter { layerIds[$0] == nil && !pendingCaptures.contains($0) }
    }

    mutating func bindLayers(_ ids: [WindowId: LayerId]) {
        guard hasLayers else { return }
        layerIds.merge(ids) { _, new in new }
    }

    mutating func markLanded(_ id: WindowId) { awaitingLanding.remove(id) }

    /// Add the scoped windows a re-teleport actually moved to the landing wait. Grows, never shrinks: a
    /// re-teleport that moves nothing must not clear the wait for sets still in flight, or the cover
    /// cross-fades onto reals that have not arrived. It cannot hang the close — `holdTimeout` bounds it.
    mutating func armLandings<S: Sequence>(_ moved: S) where S.Element == WindowId {
        awaitingLanding.formUnion(moved)
    }

    /// The initial teleport's form of `armLandings`: nothing is in flight yet, so the scope-wide wait the
    /// session was born with is replaced by the windows that genuinely needed a set.
    mutating func setLandings<S: Sequence>(_ moved: S) where S.Element == WindowId {
        awaitingLanding = Set(moved)
    }

    mutating func raiseCover(layerIds: [WindowId: LayerId]) {
        guard phase == .capturing else { return }
        self.layerIds = layerIds
        self.phase = .raising
    }

    mutating func confirmCover() {
        guard phase == .raising else { return }
        phase = .covered
    }

    /// Every capture is in — the gate for raising the cover.
    public var captureComplete: Bool { pendingCaptures.isEmpty }
    /// Every scoped AX set landed — the settle-gated gate for closing the transition.
    public var landingComplete: Bool { awaitingLanding.isEmpty }
    /// Whether the layer tree exists — the presentation plane's half of the phase, and the one gate the
    /// cover's *growth* reads. Spelled as the phases that have a tree rather than as "not `.capturing`",
    /// so a phase added later has to say for itself which side it is on.
    public var hasLayers: Bool { phase == .raising || phase == .covered }

    /// The ordered bindings the cover is built from. Empty until `raiseCover`; z-order follows `windows`.
    public var bindings: [LayerBinding] {
        windows.compactMap { w in layerIds[w].map { LayerBinding(window: w, layer: $0) } }
    }

    public func layerId(for id: WindowId) -> LayerId? { layerIds[id] }

    /// The layer to draw on top, or `nil` — nothing elevated, or an elevated window with no layer.
    public var elevatedLayer: LayerId? { elevated.flatMap { layerIds[$0] } }
}

/// The animation state of one strip: the viewport-offset scroll animator, the per-column width and
/// per-window displacement animators, and the optional transition session. Every mutator is total, and
/// the whole thing round-trips for replay — the `LayerId` watermark included, so ids reproduce exactly.
public struct Motion: Sendable, Equatable, Codable {
    /// The one scalar a strip scroll animates — every window frame is derived from `.current`.
    public private(set) var viewportOffset: Animator
    /// Each window's in-flight *displacement* from where `Layout` says it now belongs, decaying to zero —
    /// the quantity structural edits animate (see `RectAnimator.swift`). Presentation plane only: a
    /// foreign window can't be moved at refresh rate, so the reals teleport behind the cover.
    public private(set) var windowAnimators: [WindowId: RectAnimator]
    /// Each in-flight column's *resolved width in points*, travelling between two presets. Animating the
    /// width, not four rects per window, is what keeps every column to its right sliding in lockstep by
    /// derivation. Presentation plane only: only the owning app can make resized pixels.
    public private(set) var columnWidths: [ColumnId: Animator]
    /// The guide's focus ring, as a displacement from the focused window's frame, decaying to zero. The
    /// fourth animated quantity, and the only one nothing else derives from — so it is deliberately
    /// outside `isSettled` and never touches `retargetGeneration`.
    public private(set) var focusRing: RectAnimator?
    /// The in-flight transition, or `nil` in idle steady state (no cover, no ticks).
    public private(set) var transition: TransitionSession?
    /// Monotonic `LayerId` watermark — the next raw id to mint. Never rewinds.
    private var nextLayerRaw: UInt64
    /// Bumped whenever the reducer *re-aims* an animated quantity; never by `advance`, so it counts
    /// decisions, not frames. It exists for the shell's hold deadline, which must re-arm on any redirect
    /// of a live transition — a resize or structural edit redirects without moving `viewportOffset.target`.
    public private(set) var retargetGeneration: UInt64

    public init(viewportOffset: Double = 0, params: SpringParams = .smooth) {
        self.viewportOffset = Animator(value: viewportOffset, params: params)
        self.windowAnimators = [:]
        self.columnWidths = [:]
        self.focusRing = nil
        self.transition = nil
        self.nextLayerRaw = 1
        self.retargetGeneration = 0
    }

    // MARK: - The clock (Event.tick)

    /// Advance every animator by `dt` seconds, off `Event.tick(dt)` — emitted only under a transition.
    public mutating func advance(by dt: Double) {
        viewportOffset.advance(by: dt)
        // Rebuild the dicts rather than mutate one mid-iteration.
        windowAnimators = windowAnimators.mapValues(Self.advanced(by: dt))
        columnWidths = columnWidths.mapValues(Self.advanced(by: dt))
    }

    /// `advance(by:)` as a value transform, so the animator dictionaries advance by `mapValues`.
    private static func advanced(by dt: Double) -> (Animator) -> Animator {
        { a in
            var m = a
            m.advance(by: dt)
            return m
        }
    }

    private static func advanced(by dt: Double) -> (RectAnimator) -> RectAnimator {
        { a in
            var m = a
            m.advance(by: dt)
            return m
        }
    }

    /// How close (in points) an animator must be to its target, and how slow it must be moving, to count as
    /// arrived. `EmiraMotion`'s `1e-3` defaults are unit-agnostic; everything here carries points, so the
    /// criterion is physical — and a spring's tail decays exponentially, so a tighter bound buys hundreds
    /// of ms of frozen cover after the motion is visually over. 30 pt/s is half a point per 60 Hz frame.
    static let settleEpsilon = 0.5
    static let settleVelocityEpsilon = 30.0

    /// Whether all motion has arrived and stopped — half the transition-close test (`landingComplete` is
    /// the other half). A width still growing holds the cover up exactly as a scroll still travelling does.
    public var isSettled: Bool {
        func arrived(_ animator: Animator) -> Bool {
            animator.isSettled(epsilon: Self.settleEpsilon, velocityEpsilon: Self.settleVelocityEpsilon)
        }
        func arrived(_ animator: RectAnimator) -> Bool {
            animator.isSettled(epsilon: Self.settleEpsilon, velocityEpsilon: Self.settleVelocityEpsilon)
        }
        return arrived(viewportOffset)
            && windowAnimators.values.allSatisfy(arrived)
            && columnWidths.values.allSatisfy(arrived)
    }

    /// Whether the frame clock should run: a transition to animate, or a focus ring still travelling
    /// with no cover up. Not `isSettled`, which answers the different question `isReadyToClose` asks —
    /// a ring is a guide decoration and must never hold a cover in the air.
    public var needsFrames: Bool { isTransitioning || !isFocusRingSettled }

    // MARK: - Viewport scroll

    /// Aim the scroll at a new offset without disturbing position or velocity — the interrupt path.
    public mutating func retargetViewport(to offset: Double) {
        retargetGeneration &+= 1
        viewportOffset.retarget(to: offset)
    }

    /// Jump the scroll instantly to `offset`, killing motion — the no-animation reveal, and what `snap`
    /// mode does with every aim it is given.
    public mutating func snapViewport(to offset: Double) {
        retargetGeneration &+= 1
        viewportOffset.snap(to: offset)
    }

    /// Re-tune the scroll spring, leaving position and velocity alone — a config reload landing mid-scroll
    /// changes the *shape* of the remaining motion, not where it is.
    public mutating func setScrollSpring(_ params: SpringParams) { viewportOffset.params = params }

    // MARK: - Per-window displacements (the structural edit, in flight)

    /// Displace `id`'s presented rect by `delta` and let it decay back to zero — or add to an in-flight
    /// displacement, keeping its velocity. Create-or-accumulate because a structural edit is a keybind:
    /// the second press lands mid-flight, and rebuilding would teleport the layer back to the start.
    public mutating func displaceWindow(_ id: WindowId, by delta: Rect,
                                        params: SpringParams = .smooth) {
        retargetGeneration &+= 1
        if windowAnimators[id] != nil {
            windowAnimators[id]?.nudge(by: delta)
        } else {
            windowAnimators[id] = RectAnimator(displacement: delta, params: params)
        }
    }

    /// `id`'s displacement at this instant, or `.zero`, so the per-frame emission can add it blindly.
    public func displacement(of id: WindowId) -> Rect { windowAnimators[id]?.current ?? .zero }

    /// Drop `id`'s displacement — the window has left the strip, so the layout has no opinion about where
    /// it belongs. Hygiene: an orphan settles harmlessly, but `isSettled` is the transition's close gate.
    public mutating func removeWindowAnimator(_ id: WindowId) { windowAnimators[id] = nil }

    /// The displacement animator carrying `id`, or `nil` if it isn't rearranging.
    public func windowAnimator(_ id: WindowId) -> RectAnimator? { windowAnimators[id] }

    // MARK: - Column widths (the strip's own geometry, in flight)

    /// Put column `id`'s resolved width in motion from `from` to `to` — or, if it is *already* in motion,
    /// re-aim it, keeping position and velocity. That second branch is the point: restarting the animator
    /// at the new preset's *old* value would teleport the column back to where the previous press started.
    public mutating func animateColumnWidth(_ id: ColumnId, from: Double, to: Double,
                                            params: SpringParams = .smooth) {
        retargetGeneration &+= 1
        if columnWidths[id] != nil {
            columnWidths[id]?.retarget(to: to)
        } else {
            var animator = Animator(value: from, params: params)
            animator.retarget(to: to)
            columnWidths[id] = animator
        }
    }

    /// Every in-flight column width now, as the override `Layout.naturalFrames` resolves the strip
    /// against. Empty ⇒ the layout's own preset widths, i.e. every transition that isn't a resize.
    public var currentColumnWidths: [ColumnId: Double] {
        columnWidths.mapValues(\.current)
    }

    /// The width animator for `id`, or `nil` if the column isn't resizing.
    public func columnWidth(_ id: ColumnId) -> Animator? { columnWidths[id] }

    /// Drop column `id`'s in-flight width animator — the column no longer exists (a *consume* merged it
    /// away mid-resize) and nothing will mention that `ColumnId` again, which is why
    /// `LayoutEdit.destroyedColumn` is reported at all. Same hygiene as `removeWindowAnimator`.
    public mutating func removeColumnWidthAnimator(_ id: ColumnId) { columnWidths[id] = nil }

    // MARK: - The focus ring (the guide's travel, in flight)
    //
    // Structurally `windowAnimators`, and for the identical reason: focus moves between two *different*
    // windows, so there is no shared number to interpolate and the destination must stay derived. Three
    // things keep it out of everything else's way — it is not in `isSettled` (the transition's close
    // gate), it never bumps `retargetGeneration` (the shell's hold deadline), and `closeTransition`
    // leaves it alone, because it outlives the cover by design.

    /// Displace the ring by `delta` and let it decay back to the focused window's own frame — or add to
    /// an in-flight displacement, keeping its velocity, since a refocus lands mid-flight routinely.
    public mutating func nudgeFocusRing(by delta: Rect, params: SpringParams) {
        if focusRing != nil {
            focusRing?.nudge(by: delta)
        } else {
            focusRing = RectAnimator(displacement: delta, params: params)
        }
    }

    /// Advance the ring alone, off `Event.tick`. Separate from `advance(by:)`, which must not move the
    /// strip during a transition's capture head — where the ring is nonetheless travelling.
    public mutating func advanceFocusRing(by dt: Double) { focusRing?.advance(by: dt) }

    /// Drop the ring: the guide is off, or focus has left the strip and there is nothing to ring.
    public mutating func clearFocusRing() { focusRing = nil }

    /// The ring's offset from the focused window's frame at this instant, or `.zero` — so the guide can
    /// add it blindly.
    public var focusRingDisplacement: Rect { focusRing?.current ?? .zero }

    /// Whether the ring has arrived and stopped. Deliberately *not* part of `isSettled`.
    var isFocusRingSettled: Bool {
        focusRing?.isSettled(epsilon: Self.settleEpsilon,
                             velocityEpsilon: Self.settleVelocityEpsilon) ?? true
    }

    // MARK: - Transition session (the ephemeral cover lifecycle)

    /// Which of the three the truth plane is in. Every question about where the real windows are — and
    /// therefore which writer owns them — resolves here.
    public var phase: MotionPhase {
        switch transition?.phase {
        case .none:       return .idle
        case .capturing:  return .capturing
        case .raising:    return .raising
        case .covered:    return .covered
        }
    }

    /// Whether a transition session is open (cover in flight). `false` ⇒ idle steady state.
    public var isTransitioning: Bool { phase != .idle }

    /// Whether the cover is up **on screen**. The reducer gates the per-frame layer animation and every
    /// teleport on this: a cover that has been built but not yet presented hides nothing, so a window
    /// moved under it moves in the open.
    public var isCovered: Bool { phase == .covered }

    /// Whether the cover's layers exist — `.raising` or `.covered`. What the *presentation* plane asks,
    /// as against `isCovered`'s question about the truth plane: a newcomer swept in during the raise owes
    /// its layer either way, and there is no later event that would come back for it.
    public var hasLayers: Bool { transition?.hasLayers ?? false }

    /// Open a transition over the scoped, ordered window set. One session at a time — an interrupt
    /// retargets the open one rather than opening a second. `elevated` names the window to draw on top.
    public mutating func openTransition(scope windows: [WindowId], elevated: WindowId? = nil) {
        guard transition == nil else { return }
        transition = TransitionSession(windows: windows, elevated: elevated)
    }

    /// A scoped window's capture landed (`Event.captureReady`).
    public mutating func markCaptured(_ id: WindowId) { transition?.markCaptured(id) }

    /// Name (or rename) the window this transition draws on top.
    public mutating func elevate(_ id: WindowId) { transition?.elevate(id) }

    /// The layer to draw on top, or `nil` — no session, nothing elevated, or the cover isn't up yet.
    public var elevatedLayer: LayerId? { transition?.elevatedLayer }

    /// Widen the open session's scope, returning those actually added — each of which owes an
    /// `Effect.capture`. Called when a retarget aims the scroll past what the session was scoped for.
    public mutating func extendTransition(scope newcomers: [WindowId]) -> [WindowId] {
        guard var t = transition else { return [] }
        let added = t.extend(with: newcomers)
        transition = t
        return added
    }

    /// Mint a `LayerId` for every scoped window a raised cover still lacks one for, and return the new
    /// bindings for `Effect.extendCover`.
    public mutating func extendCover() -> [LayerBinding] {
        guard var t = transition, t.hasLayers else { return [] }
        let unbound = t.unboundWindows
        guard !unbound.isEmpty else { return [] }
        var ids: [WindowId: LayerId] = [:]
        for w in unbound { ids[w] = mintLayerId() }
        t.bindLayers(ids)
        transition = t
        return unbound.compactMap { w in ids[w].map { LayerBinding(window: w, layer: $0) } }
    }

    /// Abandon a session *before* its cover was ever raised — the answer to `Event.coverUnavailable` (no
    /// pixels ⇒ no cover). Refuses once the cover is up: that must be taken down by a cross-fade.
    public mutating func abortTransition() {
        guard let t = transition, t.phase == .capturing else { return }
        closeTransition()
    }

    /// Raise the cover: mint a `LayerId` per scoped window (in z-order) and advance to `.raising`. Called
    /// once `isReadyToRaise`, followed by `Effect.beginTransition(bindings)` and the cover's first blits.
    public mutating func raiseCover() {
        guard var t = transition, t.phase == .capturing else { return }
        var ids: [WindowId: LayerId] = [:]
        for w in t.windows { ids[w] = mintLayerId() }
        t.raiseCover(layerIds: ids)
        transition = t
    }

    /// The cover the shell was handed is now on the glass (`Event.coverOnScreen`): advance to `.covered`,
    /// which is what entitles the reducer to teleport the reals. Total, so a report arriving for a cover
    /// that has already been taken down — or replaced by a newer one — is the no-op it should be.
    public mutating func confirmCover() { transition?.confirmCover() }

    /// A scoped window's real AX set landed (`Event.axLanded`).
    public mutating func markLanded(_ id: WindowId) { transition?.markLanded(id) }

    /// Arm the landing wait with the scoped windows a (re-)teleport actually moved. `replacing` marks the
    /// *initial* teleport, which narrows the scope-wide wait; later ones only add, so a redirect that
    /// moves nothing cannot free sets still in flight.
    public mutating func armLandings<S: Sequence>(_ moved: S, replacing: Bool = false) where S.Element == WindowId {
        if replacing { transition?.setLandings(moved) } else { transition?.armLandings(moved) }
    }

    /// Tear down the session, drop all independent animators, and snap the viewport to its target so
    /// resting state matches the revealed truth. Widths and displacements are *dropped*, not snapped:
    /// their resting values are what `Layout` already derives, so keeping either is a staler authority.
    /// The focus ring is neither — it belongs to the guide, which outlives the cover.
    public mutating func closeTransition() {
        guard transition != nil else { return }
        viewportOffset.snap(to: viewportOffset.target)
        windowAnimators.removeAll()
        columnWidths.removeAll()
        transition = nil
    }

    // MARK: - Readiness queries (policy gates the reducer reads)

    public var isReadyToRaise: Bool {
        guard let t = transition else { return false }
        return t.phase == .capturing && t.captureComplete
    }

    /// Ready to *grow* the cover: built, with a scoped window whose still has landed but has no layer.
    /// Deliberately not gated on `captureComplete` — see `TransitionSession.unboundWindows` — nor on the
    /// cover being on screen, since a layer is owed from the moment the layer tree exists.
    public var isReadyToExtend: Bool {
        guard let t = transition else { return false }
        return t.hasLayers && !t.unboundWindows.isEmpty
    }

    public var isReadyToClose: Bool {
        guard let t = transition else { return false }
        return t.phase == .covered && t.landingComplete && isSettled
    }

    /// The layer animating `id`'s surface, or `nil` — what the per-frame `setLayerFrame` emission names.
    public func layerId(for id: WindowId) -> LayerId? { transition?.layerId(for: id) }

    private mutating func mintLayerId() -> LayerId {
        defer { nextLayerRaw += 1 }
        return LayerId(nextLayerRaw)
    }
}
