import Foundation
import EmiraMotion

// The animation half of core `State`, alongside `World` (truth) and `Layout` (structure). It holds the
// three animated quantities — each display's viewport offset, each in-flight column's resolved width,
// and each in-flight window's displacement — plus the ephemeral transition sessions (the cover
// lifecycle), one per display.
//
// The core owns the clock: every quantity is an `Animator` (`{current, velocity, target}`) that `Motion`
// advances itself on `Event.tick(dt)`, never a `CAAnimation`. That is what makes interruption pure
// arithmetic — retargeting mid-flight carries the live velocity through untouched.
//
// **What is per display and what is not.** A cover is one screen's, so the viewport it scrolls, the
// session itself and the redirect count that re-arms its deadline are held per `MonitorId`. The
// displacements and column widths are **not**: they are keyed by ids that outlive a workspace and a
// display, and a window changing screens must not lose the animator carrying it. The cost of that
// choice is that "which of these belong to this display" is a question `Motion` cannot answer for
// itself — `State.contents(of:)` supplies it, as `MonitorContents`.

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
    /// Windows this cover draws from **another display's** geometry — ones the edit that opened it
    /// handed across the desktop. Their strips are not this display's, so what it holds cannot say
    /// where they belong, and without naming them a departing window's layer freezes at the frame it
    /// was captured at while the strip it left closes behind it.
    ///
    /// A set, because a held keybind rides several hand-overs on one cover.
    public private(set) var carried: Set<WindowId> = []

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

    mutating func carry(_ id: WindowId) { carried.insert(id) }

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

/// One display's animated state: where its viewport sits, the cover it has in flight, and how many
/// times that cover has been re-aimed. A cover is one screen's, so all three are.
public struct Viewport: Sendable, Equatable, Codable {
    /// The one scalar this display's strip scroll animates — every window frame on it is derived from
    /// `.current`.
    public internal(set) var offset: Animator
    /// The in-flight transition on this display, or `nil` in idle steady state (no cover, no ticks).
    public internal(set) var transition: TransitionSession?
    /// Bumped whenever the reducer *re-aims* something this display's cover is animating; never by
    /// `advance`, so it counts decisions, not frames. It exists for the shell's hold deadline, which
    /// must re-arm on any redirect of a live transition — a resize or structural edit redirects without
    /// moving `offset.target`.
    public internal(set) var retargetGeneration: UInt64

    init(offset: Animator) {
        self.offset = offset
        self.transition = nil
        self.retargetGeneration = 0
    }
}

/// The animated things one display is responsible for: every window on a strip it holds, and every
/// column those windows sit in.
///
/// A parameter rather than something `Motion` reads off itself, because the displacements and widths
/// are deliberately **not** per monitor — they are keyed by ids that outlive a workspace and a display.
/// So which of them a given screen's cover is waiting on is `Workspaces` + `Monitors`' answer, and
/// `State.contents(of:)` is where the two are joined.
public struct MonitorContents: Sendable, Equatable {
    public let windows: Set<WindowId>
    public let columns: Set<ColumnId>

    public init(windows: Set<WindowId> = [], columns: Set<ColumnId> = []) {
        self.windows = windows
        self.columns = columns
    }

    /// Both sets merged — what one `advance` covering several displays is asked to move.
    public func union(_ other: MonitorContents) -> MonitorContents {
        MonitorContents(windows: windows.union(other.windows), columns: columns.union(other.columns))
    }
}

/// The animation state of the whole desktop: one `Viewport` per display, plus the per-column width and
/// per-window displacement animators every display shares. Every mutator is total, and the whole thing
/// round-trips for replay — the `LayerId` watermark included, so ids reproduce exactly.
public struct Motion: Sendable, Equatable, Codable {
    /// Each display's viewport, keyed the way `windowAnimators` is keyed: create-on-write, so a display
    /// nothing has scrolled yet answers as a viewport at rest rather than as an absence.
    private var viewports: [MonitorId: Viewport]
    /// The viewport with no display to hold it. Read and written only while no display is attached,
    /// which is the one condition under which no display can answer — the same rule, and the same
    /// reason, as `Monitors.unattached`. A returning display takes it back (`reconcile`).
    private var detached: Viewport
    /// The spring every viewport is born with — stored because a display that arrives later must open
    /// at the feel the config asks for, not at `Motion`'s default.
    private var scrollSpring: SpringParams
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
    /// outside `isSettled` and never touches a `retargetGeneration`.
    public private(set) var focusRing: RectAnimator?
    /// Monotonic `LayerId` watermark — the next raw id to mint. One watermark for every display, so a
    /// `LayerId` names one layer on one screen and `Effect.setLayerFrame` needs no monitor to route by.
    private var nextLayerRaw: UInt64

    public init(viewportOffset: Double = 0, params: SpringParams = .smooth) {
        self.viewports = [:]
        self.detached = Viewport(offset: Animator(value: viewportOffset, params: params))
        self.scrollSpring = params
        self.windowAnimators = [:]
        self.columnWidths = [:]
        self.focusRing = nil
        self.nextLayerRaw = 1
    }

    // Which display's viewport
    //
    // Every query and every mutator names one, and `nil` names the detached slot — so a workspace
    // switch works before the first `screensChanged` exactly as it works after one.

    /// `id`'s viewport: the detached one for a desktop with no display attached, a viewport at rest for
    /// a display nothing has scrolled yet. Total, and reading never materializes.
    public func viewport(of id: MonitorId?) -> Viewport {
        guard let id else { return detached }
        return viewports[id] ?? Viewport(offset: Animator(value: 0, params: scrollSpring))
    }

    /// Where `id`'s scroll is — the number every frame on that display derives from.
    public func offset(of id: MonitorId?) -> Animator { viewport(of: id).offset }

    /// The in-flight transition on `id`, or `nil`.
    public func transition(of id: MonitorId?) -> TransitionSession? { viewport(of: id).transition }

    /// Every display with a session open, in id order — the loop each per-display report and gate runs.
    /// Sorted rather than dictionary order, so an effect stream is the same on every run.
    public var transitioningMonitors: [MonitorId] {
        viewports.filter { $0.value.transition != nil }.keys.sorted()
    }

    /// Every display whose cover is up on the glass, in id order.
    public var coveredMonitors: [MonitorId] {
        transitioningMonitors.filter { isCovered(on: $0) }
    }

    /// Read, mutate, write back — create-on-write, so a display's first scroll gives it a viewport.
    private mutating func withViewport(_ id: MonitorId?, _ body: (inout Viewport) -> Void) {
        guard let id else { return body(&detached) }
        var viewport = viewports[id] ?? Viewport(offset: Animator(value: 0, params: scrollSpring))
        body(&viewport)
        viewports[id] = viewport
    }

    /// Sync to the hardware, the mirror of `Monitors.reconcile` and settled by the same rule: a
    /// display's *structure* survives it leaving, its *motion* does not. A viewport is where one
    /// screen's scroll happens to be, and the memory that outlives a display is the per-workspace
    /// offset `Workspaces` holds.
    ///
    /// The detached slot moves whole onto the first display to arrive and back off the last to leave,
    /// so a lid close and its reopening are one continuous scroll.
    ///
    /// - Returns: the displays whose session went with them, which the caller owes an `endTransition`
    ///   — a cover on a screen that is gone still has an overlay to take down.
    @discardableResult
    public mutating func reconcile(_ ids: [MonitorId]) -> [MonitorId] {
        guard !ids.isEmpty else {
            // The last display left. What the user was scrolled to is what a returning one resumes at.
            if let survivor = viewports.keys.sorted().first { detached = viewports[survivor]! }
            let abandoned = transitioningMonitors
            detached.transition = nil
            viewports.removeAll()
            return abandoned
        }
        let wasDetached = viewports.isEmpty
        let abandoned = transitioningMonitors.filter { !ids.contains($0) }
        viewports = viewports.filter { ids.contains($0.key) }
        if wasDetached {
            viewports[ids[0]] = detached
            detached.transition = nil
        }
        return abandoned
    }

    // The clock (Event.tick)

    /// Advance the quantities the covers on `monitors` are animating: those viewports, plus the
    /// displacements and widths of the things `contents` says are on those screens.
    ///
    /// Scoped rather than global, and that is load-bearing: a structural edit seeds a displacement the
    /// instant its command lands, and that seed is what the cover raises onto. Advancing it under
    /// *another* display's tick would decay it away during this display's capture head, so the edit
    /// would raise onto geometry it had already finished travelling to.
    public mutating func advance(by dt: Double, on monitors: [MonitorId],
                                 holding contents: MonitorContents) {
        for id in monitors { withViewport(id) { $0.offset.advance(by: dt) } }
        for id in contents.windows { windowAnimators[id]?.advance(by: dt) }
        for id in contents.columns { columnWidths[id]?.advance(by: dt) }
    }

    /// How close (in points) an animator must be to its target, and how slow it must be moving, to count as
    /// arrived. `EmiraMotion`'s `1e-3` defaults are unit-agnostic; everything here carries points, so the
    /// criterion is physical — and a spring's tail decays exponentially, so a tighter bound buys hundreds
    /// of ms of frozen cover after the motion is visually over. 30 pt/s is half a point per 60 Hz frame.
    static let settleEpsilon = 0.5
    static let settleVelocityEpsilon = 30.0

    private static func arrived(_ animator: Animator) -> Bool {
        animator.isSettled(epsilon: settleEpsilon, velocityEpsilon: settleVelocityEpsilon)
    }

    private static func arrived(_ animator: RectAnimator) -> Bool {
        animator.isSettled(epsilon: settleEpsilon, velocityEpsilon: settleVelocityEpsilon)
    }

    /// Whether everything `id`'s cover is waiting on has arrived and stopped — half of that cover's
    /// close test (`landingComplete` is the other half). A width still growing holds a cover up exactly
    /// as a scroll still travelling does, but only the cover over the screen it is growing on: two
    /// displays are two presentation planes, and one settling is not the other's business.
    public func isSettled(on id: MonitorId, holding contents: MonitorContents) -> Bool {
        Self.arrived(offset(of: id))
            && contents.windows.allSatisfy { windowAnimators[$0].map(Self.arrived) ?? true }
            && contents.columns.allSatisfy { columnWidths[$0].map(Self.arrived) ?? true }
    }

    /// Whether *nothing* anywhere is still travelling — the frame clock's question, which is one clock
    /// for every display (D9) and so asks across all of them.
    public var isSettled: Bool {
        viewports.values.allSatisfy { Self.arrived($0.offset) }
            && windowAnimators.values.allSatisfy(Self.arrived)
            && columnWidths.values.allSatisfy(Self.arrived)
    }

    /// Whether the frame clock should run: a transition anywhere to animate, or a focus ring still
    /// travelling with no cover up. Not `isSettled`, which answers the different question
    /// `isReadyToClose` asks — a ring is a guide decoration and must never hold a cover in the air.
    public var needsFrames: Bool { isTransitioning || !isFocusRingSettled }

    /// Aim `id`'s scroll at a new offset without disturbing position or velocity — the interrupt path.
    public mutating func retargetViewport(to offset: Double, on id: MonitorId?) {
        let spring = scrollSpring
        withViewport(id) {
            $0.retargetGeneration &+= 1
            $0.offset.params = spring          // see `glideViewport`: the last aim names the spring
            $0.offset.retarget(to: offset)
        }
    }

    /// Jump `id`'s scroll instantly to `offset`, killing motion — the no-animation reveal, and what
    /// `snap` mode does with every aim it is given.
    public mutating func snapViewport(to offset: Double, on id: MonitorId?) {
        let spring = scrollSpring
        withViewport(id) {
            $0.retargetGeneration &+= 1
            $0.offset.params = spring
            $0.offset.snap(to: offset)
        }
    }

    /// Put `id`'s scroll exactly where the hand has taken it. Not `snapViewport`: this deliberately
    /// does **not** bump `retargetGeneration`. A drag re-aims nothing — the destination is not
    /// changing, the hand is — and bumping it would re-arm the shell's hold deadline 120 times a second.
    ///
    /// Writes `current` **and** `target` together, so `advance(by:)` on the next tick is a no-op and
    /// `Motion.advance` needs no special case for a driven viewport. That is the whole trick: **a
    /// dragged offset is an offset that has already arrived**, every frame.
    public mutating func driveViewport(to offset: Double, on id: MonitorId?) {
        withViewport(id) { $0.offset.snap(to: offset) }
    }

    /// Hand `id`'s scroll back to a spring at the lift: aimed at `offset`, seeded with the hand's
    /// velocity, under `params`. The one place `Animator.velocity` is written from outside.
    ///
    /// `params` rather than one stored glide spring, because the two rest points want different feels:
    /// `free` coasts under the spring its projection was measured with, while `magnet`'s destination is
    /// a column exactly as `focus left`'s is and should arrive with the feel every other column arrival
    /// has. **Which spring a viewport is under is then derived from the last aim rather than stored** —
    /// `retargetViewport` and `snapViewport` put it back on the scroll spring before aiming, so a glide
    /// cannot outlive the gesture that asked for it.
    public mutating func glideViewport(to offset: Double, velocity: Double,
                                       under params: SpringParams, on id: MonitorId?) {
        withViewport(id) {
            $0.retargetGeneration &+= 1        // the lift *is* a re-aim: the destination is changing
            $0.offset.params = params
            $0.offset.retarget(to: offset)
            $0.offset.launch(velocity)
        }
    }

    /// How many times `id`'s cover has been re-aimed — what the shell's hold deadline re-arms on.
    public func retargetGeneration(of id: MonitorId?) -> UInt64 { viewport(of: id).retargetGeneration }

    /// Re-tune every scroll spring, leaving position and velocity alone — a config reload landing
    /// mid-scroll changes the *shape* of the remaining motion, not where it is. Stored too, so a
    /// display that arrives afterwards opens at the feel that is now configured.
    public mutating func setScrollSpring(_ params: SpringParams) {
        scrollSpring = params
        detached.offset.params = params
        for id in viewports.keys { viewports[id]?.offset.params = params }
    }

    // Per-window displacements (the structural edit, in flight)

    /// Displace `id`'s presented rect by `delta` and let it decay back to zero — or add to an in-flight
    /// displacement, keeping its velocity. Create-or-accumulate because a structural edit is a keybind:
    /// the second press lands mid-flight, and rebuilding would teleport the layer back to the start.
    public mutating func displaceWindow(_ id: WindowId, by delta: Rect,
                                        params: SpringParams = .smooth, on monitor: MonitorId?) {
        withViewport(monitor) { $0.retargetGeneration &+= 1 }
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

    // Column widths (the strip's own geometry, in flight)

    /// Put column `id`'s resolved width in motion from `from` to `to` — or, if it is *already* in motion,
    /// re-aim it, keeping position and velocity. That second branch is the point: restarting the animator
    /// at the new preset's *old* value would teleport the column back to where the previous press started.
    public mutating func animateColumnWidth(_ id: ColumnId, from: Double, to: Double,
                                            params: SpringParams = .smooth, on monitor: MonitorId?) {
        withViewport(monitor) { $0.retargetGeneration &+= 1 }
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

    // The focus ring (the guide's travel, in flight)
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

    // Transition sessions (the ephemeral cover lifecycle, one per display)
    //
    // One session per monitor, each with its own cover, its own raise gate and its own hold deadline.
    // The alternative — one session spanning displays — couples the screens: a scroll on A joins B's
    // open session, so B's cover cannot come down until A settles, and a hung app on A holds B's cover
    // for the full timeout.
    //
    // Two feedback events stay **untagged**, because both are facts about a window rather than about a
    // screen: `captureReady` and `axLanded` are marked in *every* session that is waiting on them, so a
    // window owed by two covers settles both.

    /// Which of the four `id`'s truth plane is in. Every question about where that display's real
    /// windows are — and therefore which writer owns them — resolves here.
    public func phase(of id: MonitorId?) -> MotionPhase {
        switch transition(of: id)?.phase {
        case .none:       return .idle
        case .capturing:  return .capturing
        case .raising:    return .raising
        case .covered:    return .covered
        }
    }

    /// Whether `id` has a session open (cover in flight). `false` ⇒ idle steady state on that screen.
    public func isTransitioning(on id: MonitorId?) -> Bool { phase(of: id) != .idle }

    /// Whether **any** display has a session open — what the frame clock and the pointer's owed warp
    /// ask, neither of them being about a particular screen.
    public var isTransitioning: Bool {
        detached.transition != nil || viewports.values.contains { $0.transition != nil }
    }

    /// Whether `id`'s cover is up **on screen**. The reducer gates that display's per-frame layer
    /// animation and every teleport of its windows on this: a cover that has been built but not yet
    /// presented hides nothing, so a window moved under it moves in the open.
    public func isCovered(on id: MonitorId?) -> Bool { phase(of: id) == .covered }

    /// Whether `id`'s cover layers exist — `.raising` or `.covered`. What the *presentation* plane asks,
    /// as against `isCovered`'s question about the truth plane: a newcomer swept in during the raise owes
    /// its layer either way, and there is no later event that would come back for it.
    public func hasLayers(on id: MonitorId?) -> Bool { transition(of: id)?.hasLayers ?? false }

    /// Open a transition on `id` over the scoped, ordered window set. One session per display at a time
    /// — an interrupt retargets the open one rather than opening a second. `elevated` names the window
    /// to draw on top.
    public mutating func openTransition(scope windows: [WindowId], elevated: WindowId? = nil,
                                        on id: MonitorId?) {
        withViewport(id) {
            guard $0.transition == nil else { return }
            $0.transition = TransitionSession(windows: windows, elevated: elevated)
        }
    }

    /// A scoped window's capture landed (`Event.captureReady`) — in every session waiting for it, since
    /// one still serves however many covers show that window.
    public mutating func markCaptured(_ id: WindowId) {
        detached.transition?.markCaptured(id)
        for monitor in viewports.keys { viewports[monitor]?.transition?.markCaptured(id) }
    }

    /// Name (or rename) the window `id`'s transition draws on top.
    public mutating func elevate(_ window: WindowId, on id: MonitorId?) {
        withViewport(id) { $0.transition?.elevate(window) }
    }

    /// Name a window `id`'s cover draws from **another display's** geometry — one handed across the
    /// desktop by the edit that opened the session. Total, so call sites append it unconditionally.
    public mutating func carry(_ window: WindowId, on id: MonitorId?) {
        withViewport(id) { $0.transition?.carry(window) }
    }

    /// The layer `id`'s cover draws on top, or `nil` — no session, nothing elevated, or no cover yet.
    public func elevatedLayer(on id: MonitorId?) -> LayerId? { transition(of: id)?.elevatedLayer }

    /// Widen `id`'s open session, returning those actually added — each of which owes an
    /// `Effect.capture`. Called when a retarget aims that scroll past what the session was scoped for.
    public mutating func extendTransition(scope newcomers: [WindowId], on id: MonitorId?) -> [WindowId] {
        var added: [WindowId] = []
        withViewport(id) {
            guard var t = $0.transition else { return }
            added = t.extend(with: newcomers)
            $0.transition = t
        }
        return added
    }

    /// Mint a `LayerId` for every window `id`'s raised cover still lacks one for, and return the new
    /// bindings for `Effect.extendCover`.
    public mutating func extendCover(on id: MonitorId?) -> [LayerBinding] {
        guard var t = transition(of: id), t.hasLayers else { return [] }
        let unbound = t.unboundWindows
        guard !unbound.isEmpty else { return [] }
        var ids: [WindowId: LayerId] = [:]
        for w in unbound { ids[w] = mintLayerId() }
        t.bindLayers(ids)
        withViewport(id) { $0.transition = t }
        return unbound.compactMap { w in ids[w].map { LayerBinding(window: w, layer: $0) } }
    }

    /// Abandon `id`'s session *before* its cover was ever raised — the answer to
    /// `Event.coverUnavailable` (no pixels ⇒ no cover). Refuses once the cover is up: that must be taken
    /// down by a cross-fade.
    ///
    /// Internal for `closeTransition`'s reason: `State.abortTransition` is the way in.
    mutating func abortTransition(on id: MonitorId?) {
        guard transition(of: id)?.phase == .capturing else { return }
        closeTransition(on: id)
    }

    /// Raise `id`'s cover: mint a `LayerId` per scoped window (in z-order) and advance to `.raising`.
    /// Called once `isReadyToRaise`, followed by `Effect.beginTransition` and the cover's first blits.
    public mutating func raiseCover(on id: MonitorId?) {
        guard var t = transition(of: id), t.phase == .capturing else { return }
        var ids: [WindowId: LayerId] = [:]
        for w in t.windows { ids[w] = mintLayerId() }
        t.raiseCover(layerIds: ids)
        withViewport(id) { $0.transition = t }
    }

    /// The cover the shell was handed is now on `id`'s glass (`Event.coverOnScreen`): advance to
    /// `.covered`, which is what entitles the reducer to teleport that display's reals. Total, so a
    /// report arriving for a cover already taken down — or replaced by a newer one — is a no-op.
    public mutating func confirmCover(on id: MonitorId?) {
        withViewport(id) { $0.transition?.confirmCover() }
    }

    /// A scoped window's real AX set landed (`Event.axLanded`) — in every session waiting on it, for the
    /// reason `markCaptured` is untagged: the window landed, which is true wherever it is being watched.
    public mutating func markLanded(_ id: WindowId) {
        detached.transition?.markLanded(id)
        for monitor in viewports.keys { viewports[monitor]?.transition?.markLanded(id) }
    }

    /// Arm `id`'s landing wait with the scoped windows a (re-)teleport actually moved. `replacing` marks
    /// the *initial* teleport, which narrows the scope-wide wait; later ones only add, so a redirect that
    /// moves nothing cannot free sets still in flight.
    public mutating func armLandings<S: Sequence>(_ moved: S, replacing: Bool = false,
                                                  on id: MonitorId?) where S.Element == WindowId {
        withViewport(id) {
            if replacing { $0.transition?.setLandings(moved) } else { $0.transition?.armLandings(moved) }
        }
    }

    /// Tear `id`'s session down and snap its viewport to its target, so resting state matches the
    /// revealed truth. Widths and displacements are *dropped*, not snapped: their resting values are
    /// what `Layout` already derives, so keeping either is a staler authority. The focus ring is
    /// neither — it belongs to the guide, which outlives the cover.
    ///
    /// **The drops wait for the last cover down**, because the two dictionaries are the whole desktop's:
    /// clearing them while another display is mid-transition would cut that display's layers to their
    /// derived positions in one frame. What is left behind meanwhile is a settled animator — resolving
    /// to the number `Layout` derives anyway — or, after a `holdTimeout`, one that resumes decaying the
    /// next time its own display is covered.
    ///
    /// **Internal, so `State.closeTransition` is the only way in.** The trackpad latch rides on a
    /// session and has to die with it, and a container that cannot know about the latch must not be the
    /// route that strands one — `Workspaces.move`'s argument exactly.
    mutating func closeTransition(on id: MonitorId?) {
        guard transition(of: id) != nil else { return }
        withViewport(id) {
            $0.offset.snap(to: $0.offset.target)
            $0.transition = nil
        }
        guard !isTransitioning else { return }
        windowAnimators.removeAll()
        columnWidths.removeAll()
    }

    // Readiness queries (policy gates the reducer reads)

    public func isReadyToRaise(on id: MonitorId?) -> Bool {
        guard let t = transition(of: id) else { return false }
        return t.phase == .capturing && t.captureComplete
    }

    /// Ready to *grow* `id`'s cover: built, with a scoped window whose still has landed but has no
    /// layer. Deliberately not gated on `captureComplete` — see `TransitionSession.unboundWindows` — nor
    /// on the cover being on screen, since a layer is owed from the moment the layer tree exists.
    public func isReadyToExtend(on id: MonitorId?) -> Bool {
        guard let t = transition(of: id) else { return false }
        return t.hasLayers && !t.unboundWindows.isEmpty
    }

    /// Whether `id`'s cover may cross-fade out.
    ///
    /// **A cover a hand is still on never closes**, whatever its animators say. A driven viewport is
    /// settled by construction (`driveViewport` writes `current` and `target` together) and the lift's
    /// teleport completes the landing, so without the latch the cover would cross-fade the instant the
    /// fingers paused — a paused finger is a settled offset, and settled is exactly the wrong reading
    /// of it. The latch is not `Motion`'s, so this is one more question `Motion` cannot answer for
    /// itself: it takes it alongside `MonitorContents`, which is already here for the same reason.
    public func isReadyToClose(on id: MonitorId, holding contents: MonitorContents,
                               hand: TrackpadScroll) -> Bool {
        guard let t = transition(of: id), !hand.holds(id) else { return false }
        return t.phase == .covered && t.landingComplete && isSettled(on: id, holding: contents)
    }

    /// Every layer animating `id`'s surface — what the per-frame `setLayerFrame` emission names, and
    /// what a content refresh repaints. A list because a window in two sessions has a layer in each,
    /// and both are showing the still that just landed.
    public func layerIds(for id: WindowId) -> [LayerId] {
        transitioningMonitors.compactMap { transition(of: $0)?.layerId(for: id) }
    }

    private mutating func mintLayerId() -> LayerId {
        defer { nextLayerRaw += 1 }
        return LayerId(nextLayerRaw)
    }
}
