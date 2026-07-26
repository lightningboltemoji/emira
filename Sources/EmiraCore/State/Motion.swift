import Foundation
import EmiraMotion

// The **animation** half of core `State` (IMPLEMENTATION.md §5, `State/Motion.swift`) — the third and
// last piece of `State` alongside `World` (truth) and `Layout` (structure). It holds everything that
// is *in motion or mid-transition*: the one scalar a strip scroll animates, any genuinely-independent
// per-window animators, and the ephemeral transition session (the cover lifecycle, §3). `World` and
// `Layout` describe where things *are* and *belong*; `Motion` describes how they're currently
// *travelling* there.
//
// **The core owns the clock (PRINCIPLES.md §7, IMPLEMENTATION.md §1 invariant 2).** We do not hand
// motion to `CAAnimation`. `Motion` holds each animated quantity as an `Animator` (`{current,
// velocity, target}`) and advances them itself on `Event.tick(dt)` via `advance(by:)`; the shell just
// blits `layer.position` from the emitted `setLayerFrame` intents. This is what makes interruption
// pure arithmetic: retargeting the viewport mid-scroll (`retargetViewport`) carries the live velocity
// through untouched — the thing `CASpringAnimation` cannot do.
//
// **One scalar scrolls the strip.** A strip scroll animates a *single* number — `viewportOffset` —
// and `Layout.targetFrames(scrollOffset:)` derives every window's frame from it, so lockstep motion,
// settle-detection, and retargeting are all trivially one-number operations (§6). Most transitions
// touch only the offset.
//
// **…and one displacement per window rearranges it.** `windowAnimators` is the third quantity and the
// one that is not like the other two: a structural edit (`moveWindow`, `consumeOrExpel`) inserts or
// removes a column, so there is no number the new frames derive from — before and after are two
// different `Layout`s. What animates instead is a **displacement that decays to zero**
// (`RectAnimator`): the layout mutates at once and keeps sole authority over where a window belongs,
// and the animator carries only how far behind that answer the layer currently is. See
// `RectAnimator.swift`'s header for why the permanently-zero target is the design and not a detail.
//
// **…and one scalar per column resizes it.** `columnWidths` is the second animated quantity, added for
// `cycleWidth` (M4 part 3). It is the same idea one axis over: a column's *resolved width* is a number
// every frame derives from, so animating it makes the whole consequence — this column's windows
// growing, every column to the right of it sliding — fall out of the same layout math in lockstep, with
// one settle test and one retarget. It drives the **presentation plane only**; the real windows are
// teleported to their final size behind the cover, because only the owning app can produce resized
// pixels (§4d).
//
// **The transition session is ephemeral (§3).** Steady state has no session (`transition == nil`) and
// produces no ticks. A command (or gesture) that warrants motion opens one; it lives only for the
// duration of the cover and is torn down on cross-fade. `Motion` models the session as *data + total
// mutators* — it is the state, not the state machine. The `Engine` reducer (a later iteration) owns
// the *policy* of when to open/raise/close it, exactly as it owns when to call `World`'s mutators.
// Every mutator here is **total**: a mark for a window not in the session, a raise of an already-raised
// cover, a close of a session that isn't open — all no-op rather than trap (the §1-invariant-3
// discipline the whole core keeps).

/// The presentation-plane binding for one window's reconstruction layer: the core-minted `LayerId`
/// the shell tags the layer with (so subsequent `Effect.setLayerFrame` can name it) paired with the
/// `WindowId` whose captured surface the layer shows. Array order in `Effect.beginTransition` is
/// z-order, bottom→top.
///
/// This is why `LayerId` is its own id kind (Ids.swift) and why `setLayerFrame` is keyed by `LayerId`
/// not `WindowId` (Effect.swift): the presentation plane isn't 1:1 with windows, and this binding is
/// the association the core carries so it can animate the right layer for each window.
public struct LayerBinding: Sendable, Equatable, Codable {
    /// The window whose captured surface this layer reconstructs.
    public let window: WindowId
    /// The core-minted layer id the shell tags the layer with, and that `setLayerFrame` names.
    public let layer: LayerId

    public init(window: WindowId, layer: LayerId) {
        self.window = window
        self.layer = layer
    }
}

/// The ephemeral cover lifecycle for one transition (IMPLEMENTATION.md §3). Data + narrow mutators;
/// the reducer drives phase progression. Two phases, in order:
///
///  1. **`.capturing`** — the reducer has emitted `Effect.capture` for every scoped window and is
///     waiting on `Event.captureReady`. The cover is *not* yet raised, so no real window has moved.
///  2. **`.covered`** — every capture is in, the cover is up (`Effect.beginTransition(bindings)`), the
///     real windows have teleported to their final AX targets behind it, and each `tick` slides the
///     layers. We wait for the animators to settle **and** the scoped `axLanded`s to arrive.
///
/// The scoped window set (`windows`) is the union of "start *or* end frame intersects the viewport"
/// (§3): those are exactly the windows that must be captured (they're visible at some point during the
/// motion) *and* the windows whose AX landing gates the close (a failed park would otherwise squat in
/// view). Park→park moves are never in view, so they're outside the scope and don't block anything.
public struct TransitionSession: Sendable, Equatable, Codable {
    /// Which lifecycle phase the session is in.
    public enum Phase: Sendable, Equatable, Codable {
        /// Captures requested, cover not yet raised (no real window has moved).
        case capturing
        /// Cover raised, real windows teleporting behind it, layers animating.
        case covered
    }

    /// The current phase. Advances `.capturing → .covered` exactly once, at `raiseCover`.
    public private(set) var phase: Phase
    /// The scoped window set, in z-order (bottom→top). Defines both the capture set and the
    /// `axLanded` wait set.
    ///
    /// **It grows; it never shrinks (2026-07-25, M4 part 2).** A retarget aims the scroll somewhere
    /// the session was not scoped for, and the windows that new destination sweeps have no captured
    /// surface — so they slide into the viewport as holes in the cover. `extend` widens the scope to
    /// cover them. Nothing is ever removed: a window the *old* destination swept is mid-flight on the
    /// presentation plane and mid-teleport on the truth plane, and dropping it would abandon both.
    public private(set) var windows: [WindowId]
    /// Scoped windows whose still hasn't landed yet (`Effect.capture` outstanding). Shrinks as
    /// `Event.captureReady` arrives; empty ⇒ ready to raise the cover.
    public private(set) var pendingCaptures: Set<WindowId>
    /// Scoped windows whose real AX set hasn't landed yet. Shrinks as `Event.axLanded` arrives; empty
    /// (with the animators settled) ⇒ ready to cross-fade out.
    public private(set) var awaitingLanding: Set<WindowId>
    /// The `WindowId → LayerId` association, minted at `raiseCover`. Empty while `.capturing`.
    public private(set) var layerIds: [WindowId: LayerId]
    /// The window this transition draws **on top of** everything else in the cover — the one a
    /// structural edit is moving. `nil` for a scroll or a resize, where strip windows never overlap
    /// and z-order is therefore arbitrary.
    ///
    /// This is what makes a swap read as a swap: two columns trading places pass *through* each
    /// other on the presentation plane, and without an opinion the one drawn on top is whichever
    /// happened to be created last. The reducer turns this into `Effect.elevateLayer` at the raise,
    /// after every `extendCover` (additions land on top, so the mover must be re-raised), and on a
    /// second edit under an already-raised cover.
    public private(set) var elevated: WindowId?
    /// Whether the hold-timeout (§3) fired before a clean settle. Records *why* the session closed so
    /// the reducer keeps retrying any AX set that never landed. A frozen cover is worse than a hung app.
    public private(set) var didTimeout: Bool

    /// Open a fresh session in `.capturing` over the given scoped, ordered window set.
    init(windows: [WindowId], elevated: WindowId? = nil) {
        self.phase = .capturing
        self.windows = windows
        self.pendingCaptures = Set(windows)
        self.awaitingLanding = Set(windows)
        self.layerIds = [:]
        self.elevated = elevated
        self.didTimeout = false
    }

    /// A scoped window's still landed. Total — an unknown id (or a repeat) no-ops.
    mutating func markCaptured(_ id: WindowId) { pendingCaptures.remove(id) }

    /// Draw `id` on top for the rest of this transition — a structural edit arriving under an
    /// already-open session names its own mover. Total; the last edit wins, which is the right
    /// reading (the window the user just moved is the one they are watching).
    mutating func elevate(_ id: WindowId) { elevated = id }

    /// Widen the scope to include `newcomers`, returning the ones actually added (a window already in
    /// scope is silently skipped, so this is idempotent). Each addition owes a capture, whichever
    /// phase we are in: before the raise it simply joins the batch the cover is waiting on; after it,
    /// its still is what `extendCover` turns into a new layer. Total.
    ///
    /// Additions land at the **end** of `windows`, i.e. on top in z-order rather than in strip order.
    /// Strip windows never overlap, so the only thing this can affect is where a synthesized shadow
    /// falls across a column gap — a cosmetic ordering, traded for not having to re-derive an order
    /// for windows that have already left the layout the old one came from.
    mutating func extend(with newcomers: [WindowId]) -> [WindowId] {
        let known = Set(windows)
        let added = newcomers.filter { !known.contains($0) }
        guard !added.isEmpty else { return [] }
        windows.append(contentsOf: added)
        pendingCaptures.formUnion(added)
        return added
    }

    /// Scoped windows that have a still and no layer yet — what a raised cover still owes and can
    /// actually pay. Empty in steady session state; non-empty only between a `captureReady` and the
    /// cover growing to match.
    ///
    /// **Pending captures are excluded, and that is load-bearing (2026-07-26).** `extendCover` mints a
    /// layer id for everything this returns and the shell binds it *once*, skipping any window it has
    /// no still for — so naming a window whose capture is still in flight spends its only chance at a
    /// layer and leaves it a hole for the rest of the transition. Through iteration 25 the guard
    /// against that lived in the *gate* instead (`Motion.isReadyToExtend` demanded `captureComplete`,
    /// i.e. every outstanding capture in the whole session), which is correct for one extension and
    /// **starves** under a stream of them: each new command adds a capture before the previous one
    /// lands, `captureComplete` is never true again, and the cover stops growing entirely — a scoped
    /// window then rides the whole transition with no layer, showing a full column of wallpaper.
    /// Measured on a spammed `move-window`: 600 pt, versus 130 pt for the plain late-extension hole.
    ///
    /// Asking the question per window instead makes the gate incapable of starving — a still binds the
    /// moment it lands, whatever else is outstanding — and is strictly lower latency besides. The
    /// *raise* keeps its all-or-nothing gate (`isReadyToRaise`), because that one is about the base:
    /// a cover raised without it is not a cover.
    var unboundWindows: [WindowId] {
        windows.filter { layerIds[$0] == nil && !pendingCaptures.contains($0) }
    }

    /// Install layer ids minted for windows that joined after the raise. Total — no-op before it.
    mutating func bindLayers(_ ids: [WindowId: LayerId]) {
        guard phase == .covered else { return }
        layerIds.merge(ids) { _, new in new }
    }

    /// A scoped window's real AX set landed. Total — an unknown id (or a repeat) no-ops.
    mutating func markLanded(_ id: WindowId) { awaitingLanding.remove(id) }

    /// Add `moved` — the scoped windows a (re-)teleport actually moved — to the landing wait.
    ///
    /// The session is born awaiting the whole scope; the first teleport narrows that to the windows
    /// that needed an AX set (a scoped window already at its target emits no `setFrame`, so no
    /// `axLanded` will arrive for it), and an interrupt re-teleport adds whatever it moved again.
    ///
    /// **It grows and never shrinks** (corrected 2026-07-26). Replacing the set outright was right for
    /// the windows being re-teleported and wrong for everyone else: a re-teleport that moves *nothing*
    /// — routine now that every redirect goes through `driveTransition` — would clear the wait for
    /// windows whose sets are still in flight from the previous batch, and the cover could cross-fade
    /// onto reals that have not arrived. Growing cannot hang the close instead, because a set already
    /// issued always answers (`axLanded` or `axFailed`), and `holdTimeout` bounds the wait regardless.
    /// The first narrowing still happens: the *initial* teleport is what replaces the scope-wide wait.
    mutating func armLandings<S: Sequence>(_ moved: S) where S.Element == WindowId {
        awaitingLanding.formUnion(moved)
    }

    /// Narrow the landing wait to exactly `moved` — the initial teleport's form of `armLandings`,
    /// where nothing is in flight yet and the scope-wide wait the session was born with is replaced by
    /// the windows that genuinely needed a set.
    mutating func setLandings<S: Sequence>(_ moved: S) where S.Element == WindowId {
        awaitingLanding = Set(moved)
    }

    /// The hold-timeout fired: mark it so the reducer reconciles the still-unlanded set on close.
    mutating func markTimedOut() { didTimeout = true }

    /// Raise the cover: install the minted layer ids (one per scoped window) and advance to
    /// `.covered`. Total — a no-op if already covered (idempotent under a duplicated raise).
    mutating func raiseCover(layerIds: [WindowId: LayerId]) {
        guard phase == .capturing else { return }
        self.layerIds = layerIds
        self.phase = .covered
    }

    /// Every capture is in — the gate for raising the cover (`beginTransition`).
    public var captureComplete: Bool { pendingCaptures.isEmpty }
    /// Every scoped AX set landed — the (settle-gated) gate for closing the transition.
    public var landingComplete: Bool { awaitingLanding.isEmpty }

    /// The ordered layer bindings the cover is built from — the parameterization of
    /// `Effect.beginTransition`. Empty until `raiseCover`; z-order follows `windows` (bottom→top).
    public var bindings: [LayerBinding] {
        windows.compactMap { w in layerIds[w].map { LayerBinding(window: w, layer: $0) } }
    }

    /// The layer animating `id`'s surface this transition, or `nil` (not scoped, or not yet raised).
    /// The per-frame `setLayerFrame` emission looks this up to name the layer.
    public func layerId(for id: WindowId) -> LayerId? { layerIds[id] }

    /// The layer that should be drawn on top, or `nil` — no elevated window, or one with no layer
    /// (it wasn't in scope, or the cover isn't up yet). What `Effect.elevateLayer` names.
    public var elevatedLayer: LayerId? { elevated.flatMap { layerIds[$0] } }
}

/// The animation state of one strip: the viewport-offset scroll animator, the reserved per-window
/// independent animators, and the optional transition session. A value type — `Equatable`/`Codable`
/// like `World`/`Layout`, so the whole of `State` dumps to JSON (`emira debug`) and round-trips for
/// replay (§7); the `LayerId` allocator watermark is part of that state so replay reproduces identical
/// ids.
public struct Motion: Sendable, Equatable, Codable {
    /// The one scalar a strip scroll animates. `Layout.targetFrames(scrollOffset:)` derives every
    /// window frame from `viewportOffset.current`; the reducer retargets it to scroll (velocity
    /// carried) and snaps it for the no-animation reveal of an externally-focused window (§4a).
    public private(set) var viewportOffset: Animator
    /// The genuinely-independent per-window channel, and the one the structural edits animate: each
    /// window's in-flight **displacement** from where `Layout` says it now belongs, decaying to zero.
    /// Empty for an ordinary scroll or resize, and empty again the moment a transition closes.
    ///
    /// **A displacement, never a position — and that distinction is the whole design.**
    /// `viewportOffset` and `columnWidths` animate numbers every frame *derives from*, so their
    /// consequences fall out in lockstep. A structural edit has no such number: it inserts or removes
    /// a column, so before and after are two different `Layout`s. Interpolating between them would
    /// make lockstep something to be maintained. Animating the *lag* instead keeps the destination
    /// derived — only how far behind it a layer currently is, is per-window, and lag genuinely is
    /// per-window. It also makes three properties free: the first frame reproduces the old layout
    /// exactly (no pop at the raise), a settled animator is indistinguishable from no animator (so
    /// `closeTransition` may drop them, as it does the widths), and a second edit mid-flight is a
    /// `nudge` — position continuous to the point, velocity carried. See `RectAnimator.swift`.
    ///
    /// **The presentation plane only**, like `columnWidths`: the reals are teleported to their final
    /// frames behind the cover, because a foreign window cannot be moved at refresh rate (§4b).
    public private(set) var windowAnimators: [WindowId: RectAnimator]
    /// The **second** animated quantity of the strip, and the one that makes `cycleWidth` possible: a
    /// column's *resolved width in points*, in flight between two presets. Empty for an ordinary
    /// scroll, and empty again the moment a transition closes.
    ///
    /// **Why this rather than per-window frame animators.** A width change is not independent motion of
    /// the windows in one column — it is a change to the strip's own geometry, and *every* column to the
    /// right of it moves as a consequence. Animating the width means the consequence is *derived*
    /// (`Layout.naturalFrames(…, widths:)` re-runs the same placement math it always did against a
    /// different width), so the neighbours slide in lockstep by construction, exactly as they do for the
    /// viewport offset. Animating four rects per window instead would make lockstep something to be kept
    /// rather than something that cannot break, and settle-detection N tests instead of one.
    ///
    /// **The presentation plane only.** The truth plane teleports the reals to their *final* frames
    /// behind the cover, as it always has — a foreign window cannot be resized at refresh rate (§4d;
    /// only the owning app makes those pixels). These animators drive the layers, i.e. a *scaled still*
    /// of the old content: §4d's "cross-fade a scaled screenshot over it until the app redraws", which
    /// is what the cover already does for every other transition.
    public private(set) var columnWidths: [ColumnId: Animator]
    /// The in-flight transition, or `nil` in idle steady state (no cover, no ticks).
    public private(set) var transition: TransitionSession?
    /// Monotonic `LayerId` watermark — the next raw id to mint. Part of serialized state so replay
    /// reproduces identical layer ids; never rewinds (a fresh transition mints fresh ids).
    private var nextLayerRaw: UInt64
    /// Bumped every time the reducer **re-aims** an animated quantity — the viewport (retarget or
    /// snap), a column width, a window displacement. Never bumped by `advance`: this counts
    /// decisions, not frames.
    ///
    /// It exists for the shell's hold deadline. `Runtime.syncHold` used to re-arm on a change to
    /// `viewportOffset.target`, which was right while every transition was a scroll and silently
    /// wrong the moment one wasn't: a resize or a structural edit can redirect a live transition
    /// without moving the offset by a point, and the deadline would go on bounding a wait the user
    /// had already left — cutting the *second* press of a keybind short. What makes a deadline safe
    /// is unchanged, because a genuinely stuck transition receives no commands: this number stops
    /// moving and the timeout fires.
    public private(set) var retargetGeneration: UInt64

    /// An idle Motion: the viewport at `viewportOffset`, no independent motion, no transition.
    public init(viewportOffset: Double = 0, params: SpringParams = .smooth) {
        self.viewportOffset = Animator(value: viewportOffset, params: params)
        self.windowAnimators = [:]
        self.columnWidths = [:]
        self.transition = nil
        self.nextLayerRaw = 1
        self.retargetGeneration = 0
    }

    // MARK: - The clock (Event.tick)

    /// Advance every animator — the viewport offset and each independent per-window animator — by `dt`
    /// seconds. The reducer calls this on `Event.tick(dt)` (emitted only while a transition is open).
    public mutating func advance(by dt: Double) {
        viewportOffset.advance(by: dt)
        // Snapshot-free advance: rebuild the dicts so we never mutate one mid-iteration.
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

    /// The `RectAnimator` overload of the same transform.
    private static func advanced(by dt: Double) -> (RectAnimator) -> RectAnimator {
        { a in
            var m = a
            m.advance(by: dt)
            return m
        }
    }

    /// How close to its target a **point-valued** animator must be to count as arrived, and how slow
    /// it must be moving.
    ///
    /// `EmiraMotion`'s own defaults are deliberately unit-agnostic (`1e-3`) — it is a scalar solver
    /// and has no idea what its numbers mean. Here we do: every animator in `Motion` carries *points*
    /// on the strip, so the criterion can be a physical one.
    ///
    /// This is not a micro-optimization; it is the difference between a transition that ends when it
    /// looks ended and one that holds a **frozen cover** for half a second afterwards. A spring's tail
    /// decays exponentially, so on a 900-point scroll the last thousandth of a point costs about as
    /// long as the first 900: `1e-3` doesn't settle until ~1.25 s, while the motion is visually over
    /// around 0.6 s. Nothing animates in that gap — the user is looking at a still picture of their
    /// desktop they cannot interact with, which is exactly the failure §3 calls "worse than a visibly
    /// hung app". These thresholds close it at ~0.63 s, when the spring genuinely arrives.
    ///
    /// **Position is the real criterion; velocity only rejects a fly-through.** `closeTransition`
    /// snaps the offset to its exact target, so closing within half a point means the cross-fade
    /// absorbs a sub-pixel correction — invisible at any backing scale, and the same tolerance
    /// `Engine` uses for "this window is already there". The velocity bound exists solely so an
    /// *underdamped* spring can't be declared settled while streaking through its target at speed;
    /// 30 pt/s is half a point per 60 Hz frame, i.e. the next frame would be indistinguishable from
    /// this one. Set it much tighter (1 pt/s) and it, not the position, becomes the gate — costing
    /// another ~150 ms of frozen cover for motion that has already stopped.
    static let settleEpsilon = 0.5
    static let settleVelocityEpsilon = 30.0

    /// Whether all motion has arrived and stopped — the viewport offset, every independent window
    /// animator, and every in-flight column width. Half of the transition-close test (the other half is
    /// `landingComplete`). A width still growing holds the cover up exactly as a scroll still travelling
    /// does: both are motion the user is watching on the presentation plane.
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

    // MARK: - Viewport scroll

    /// Aim the scroll at a new offset **without disturbing position or velocity** — the interrupt path
    /// (retarget mid-scroll is pure arithmetic, PRINCIPLES.md §7).
    public mutating func retargetViewport(to offset: Double) {
        retargetGeneration &+= 1
        viewportOffset.retarget(to: offset)
    }

    /// Jump the scroll instantly to `offset`, killing motion — the no-animation reveal of an
    /// externally-focused window (§4a: we made no motion, so we owe no animation).
    public mutating func snapViewport(to offset: Double) {
        retargetGeneration &+= 1
        viewportOffset.snap(to: offset)
    }

    /// Re-tune the scroll spring without disturbing where the viewport is or how fast it's moving —
    /// the config-reload path (`Engine.configChanged`).
    ///
    /// Position and velocity are deliberately untouched: the spring is seeded once at construction, so
    /// this is the only way a saved config reaches a running daemon's feel, and a reload that happened
    /// to land mid-scroll should change the *shape* of the remaining motion, not teleport it. A spring
    /// integrator handles a mid-flight constant change the same way it handles a retarget — it reads
    /// the new constants on the next `advance`.
    public mutating func setScrollSpring(_ params: SpringParams) { viewportOffset.params = params }

    // MARK: - Per-window displacements (the structural edit, in flight)

    /// Displace `id`'s presented rect by `delta` and let it decay back to zero — **or add to an
    /// in-flight displacement**, keeping its velocity.
    ///
    /// The create-or-accumulate shape is `animateColumnWidth`'s, and it is there for the same reason:
    /// a structural edit is a keybind, so the second press lands while the first is still travelling.
    /// Rebuilding would teleport the layer back to where the first press started; `nudge`ing makes a
    /// double-press one continuous motion — and exactly continuous, because the caller's `delta` is
    /// the difference between the two layouts, so `natural₂ + d₂ == natural₁ + d₁` is where the layer
    /// already was.
    public mutating func displaceWindow(_ id: WindowId, by delta: Rect,
                                        params: SpringParams = .smooth) {
        retargetGeneration &+= 1
        if windowAnimators[id] != nil {
            windowAnimators[id]?.nudge(by: delta)
        } else {
            windowAnimators[id] = RectAnimator(displacement: delta, params: params)
        }
    }

    /// `id`'s displacement at this instant, or `.zero`. Total by design, so the per-frame emission
    /// adds it unconditionally rather than branching on whether a window happens to be rearranging.
    public func displacement(of id: WindowId) -> Rect { windowAnimators[id]?.current ?? .zero }

    /// Drop `id`'s displacement — the window has left the strip (closed, minimized) so the layout has
    /// no opinion about where it belongs any more. Total — no-op if absent.
    ///
    /// Same hygiene argument as `removeColumnWidthAnimator`: an orphan settles harmlessly on its own,
    /// but `isSettled` is the transition's close gate and a gate held by a quantity with no meaning is
    /// cheap now and archaeology later.
    public mutating func removeWindowAnimator(_ id: WindowId) { windowAnimators[id] = nil }

    /// The displacement animator carrying `id`, or `nil` if it isn't rearranging.
    public func windowAnimator(_ id: WindowId) -> RectAnimator? { windowAnimators[id] }

    // MARK: - Column widths (the strip's own geometry, in flight)

    /// Put column `id`'s resolved width in motion from `from` to `to` — or, if it is *already* in
    /// motion, simply re-aim it (`retarget`), keeping its position and velocity.
    ///
    /// That second branch is the whole reason this isn't a plain assignment. Cycling a width is a
    /// keybind, so the second press lands while the first is still travelling; restarting the animator
    /// at the new preset's *old* value would teleport the column back to where the press before it
    /// started. Retargeting instead makes a double-press one continuous motion through two presets —
    /// the same arithmetic-not-teardown property the viewport interrupt has (PRINCIPLES.md §7), applied
    /// to the other animated quantity.
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

    /// Every in-flight column width at this instant, as the override
    /// `Layout.naturalFrames(_:metrics:widths:)` resolves the strip against. Empty ⇒ the layout's own
    /// preset widths, which is every transition that isn't a resize.
    public var currentColumnWidths: [ColumnId: Double] {
        columnWidths.mapValues(\.current)
    }

    /// The width animator for `id`, or `nil` if the column isn't resizing.
    public func columnWidth(_ id: ColumnId) -> Animator? { columnWidths[id] }

    /// Drop column `id`'s in-flight width animator — the column no longer exists (a *consume* merged
    /// it away mid-resize). The symmetric partner of `removeWindowAnimator`, and the reason
    /// `LayoutEdit.destroyedColumn` is reported at all: once `Layout` has dropped the column, nothing
    /// else will ever mention that `ColumnId` again. Total — no-op if absent.
    ///
    /// Hygiene rather than a wedge. An orphaned animator keeps advancing on every tick and settles on
    /// its own schedule, so the worst it costs is holding a cover up for the remainder of a motion
    /// nobody can see, and `Layout.strip(metrics:widths:)` already ignores an override for a column it
    /// doesn't have — the geometry was never at risk. But `isSettled` is the transition's close gate,
    /// and a gate held by a quantity that no longer has a meaning is cheap now and archaeology later.
    public mutating func removeColumnWidthAnimator(_ id: ColumnId) { columnWidths[id] = nil }

    // MARK: - Transition session (the ephemeral cover lifecycle, §3)

    /// Whether a transition session is open (cover in flight). `false` ⇒ idle steady state.
    public var isTransitioning: Bool { transition != nil }

    /// Whether the cover is *raised* (phase `.covered`) — the layer-animating phase, distinct from the
    /// brief pre-cover `.capturing` before every still is in. `false` when idle. The reducer gates the
    /// per-frame layer animation (`tick`) and the interrupt re-teleport on this: no cover ⇒ nothing to
    /// blit and no real window has moved yet.
    public var isCovered: Bool { transition?.phase == .covered }

    /// Open a transition over the scoped, ordered window set (union of "start or end frame intersects
    /// the viewport", §3) — enters `.capturing`. Total — no-op if a session is already open (one at a
    /// time; an interrupt retargets the open session, it doesn't open a second).
    /// `elevated` names the window to draw on top for the whole transition — a structural edit's
    /// mover. `nil` (the default) for a scroll or a resize, where strip windows never overlap.
    public mutating func openTransition(scope windows: [WindowId], elevated: WindowId? = nil) {
        guard transition == nil else { return }
        transition = TransitionSession(windows: windows, elevated: elevated)
    }

    /// A scoped window's capture landed (`Event.captureReady`). Total — no-op with no session.
    public mutating func markCaptured(_ id: WindowId) { transition?.markCaptured(id) }

    /// Name (or rename) the window this transition draws on top — a structural edit landing under an
    /// already-open session. Total — no-op with no session.
    public mutating func elevate(_ id: WindowId) { transition?.elevate(id) }

    /// The layer to draw on top, or `nil` — no session, nothing elevated, or the cover isn't up yet.
    /// What the reducer turns into `Effect.elevateLayer`.
    public var elevatedLayer: LayerId? { transition?.elevatedLayer }

    /// Widen the open session's scope to `newcomers`, returning those actually added — each of which
    /// owes an `Effect.capture` (see `TransitionSession.extend`). The reducer calls this when a
    /// retarget aims the scroll past what the session was scoped for. Total — no-op with no session.
    public mutating func extendTransition(scope newcomers: [WindowId]) -> [WindowId] {
        guard var t = transition else { return [] }
        let added = t.extend(with: newcomers)
        transition = t
        return added
    }

    /// Grow a **raised** cover: mint a `LayerId` for every scoped window that still lacks one and
    /// return the new bindings for `Effect.extendCover`. Empty unless the cover is up and there is
    /// something unbound. Total.
    public mutating func extendCover() -> [LayerBinding] {
        guard var t = transition, t.phase == .covered else { return [] }
        let unbound = t.unboundWindows
        guard !unbound.isEmpty else { return [] }
        var ids: [WindowId: LayerId] = [:]
        for w in unbound { ids[w] = mintLayerId() }
        t.bindLayers(ids)
        transition = t
        return unbound.compactMap { w in ids[w].map { LayerBinding(window: w, layer: $0) } }
    }

    /// Abandon a session **before** its cover was ever raised — the answer to `Event.coverUnavailable`
    /// (no pixels ⇒ no cover). Distinct from `closeTransition` only in refusing to fire once the cover
    /// is up: a raised cover must be taken down by `endTransition`'s cross-fade, never dropped.
    public mutating func abortTransition() {
        guard let t = transition, t.phase == .capturing else { return }
        closeTransition()
    }

    /// Raise the cover: mint a `LayerId` per scoped window (in z-order) and advance the session to
    /// `.covered`. The reducer calls this once `isReadyToRaise`, then emits
    /// `Effect.beginTransition(transition!.bindings)` and the teleports. Total — no-op unless a session
    /// is mid-`.capturing`.
    public mutating func raiseCover() {
        guard var t = transition, t.phase == .capturing else { return }
        var ids: [WindowId: LayerId] = [:]
        for w in t.windows { ids[w] = mintLayerId() }
        t.raiseCover(layerIds: ids)
        transition = t
    }

    /// A scoped window's real AX set landed (`Event.axLanded`). Total — no-op with no session.
    public mutating func markLanded(_ id: WindowId) { transition?.markLanded(id) }

    /// Arm the landing wait with `moved` — the scoped windows a (re-)teleport actually moved (see
    /// `TransitionSession.armLandings`). The reducer calls this right after teleporting the reals
    /// behind the cover. The **initial** teleport replaces the scope-wide wait the session was born
    /// with; every re-teleport after it only ever adds, so a redirect that moves nothing cannot free
    /// sets that are still in flight. Total — no-op with no session.
    public mutating func armLandings<S: Sequence>(_ moved: S, replacing: Bool = false) where S.Element == WindowId {
        if replacing { transition?.setLandings(moved) } else { transition?.armLandings(moved) }
    }

    /// The hold-timeout fired (`Event.holdTimeout`) — record it before closing so the reducer keeps
    /// reconciling the still-unlanded set. Total — no-op with no session.
    public mutating func markTimedOut() { transition?.markTimedOut() }

    /// Close the transition (`Effect.endTransition` cross-faded out, or a hold-timeout forced it):
    /// tear down the session, drop all independent animators, and snap the viewport to its target so
    /// resting state matches the revealed truth (the real windows sit at the final framing, §4b). Total
    /// — no-op with no session.
    ///
    /// The column-width animators are *dropped*, not snapped, and the two are the same thing: with the
    /// override gone the presentation plane resolves widths straight from the column's stored preset —
    /// which is where the animator was heading and where the real window has been sitting since the
    /// teleport. An animator kept past the cross-fade would be a second, staler authority on a number
    /// `Layout` already owns.
    ///
    /// The **displacements** are dropped for the same reason, and the argument is even shorter there:
    /// a displacement's target is permanently zero, so dropping a settled one is *literally* a no-op
    /// on the emitted frame. That is the property the whole model was chosen for — see
    /// `windowAnimators` above.
    public mutating func closeTransition() {
        guard transition != nil else { return }
        viewportOffset.snap(to: viewportOffset.target)
        windowAnimators.removeAll()
        columnWidths.removeAll()
        transition = nil
    }

    // MARK: - Readiness queries (policy gates the reducer reads)

    /// Ready to raise the cover: mid-`.capturing` with every capture in. The reducer's cue to
    /// `raiseCover()` + emit `beginTransition`.
    public var isReadyToRaise: Bool {
        guard let t = transition else { return false }
        return t.phase == .capturing && t.captureComplete
    }

    /// Ready to *grow* the cover: raised, and at least one scoped window whose still has landed is
    /// still without a layer. The reducer's cue to `extendCover()` + emit `Effect.extendCover`.
    ///
    /// Deliberately **not** gated on `captureComplete` — see `TransitionSession.unboundWindows`. A
    /// session-wide gate here starves under a stream of interrupts, because each command adds a
    /// capture before the last one lands and the cover simply stops growing.
    public var isReadyToExtend: Bool {
        guard let t = transition else { return false }
        return t.phase == .covered && !t.unboundWindows.isEmpty
    }

    /// Ready to cross-fade out: `.covered`, every scoped AX set landed, and all animators settled. The
    /// reducer's cue to emit `endTransition` + `closeTransition()`.
    public var isReadyToClose: Bool {
        guard let t = transition else { return false }
        return t.phase == .covered && t.landingComplete && isSettled
    }

    /// The layer animating `id`'s surface in the current transition, or `nil`. The per-frame
    /// `setLayerFrame` emission names the layer through this.
    public func layerId(for id: WindowId) -> LayerId? { transition?.layerId(for: id) }

    private mutating func mintLayerId() -> LayerId {
        defer { nextLayerRaw += 1 }
        return LayerId(nextLayerRaw)
    }
}
