import Foundation
import EmiraConfig
import EmiraCore

// `(Take, t, Config, workingArea) → frames`, and it is one expression: the mock desktop is laid out by
// the code that lays out the real one.
//
// **The layout runs at real scale and only the result is projected.** Everything here is true points
// against the display's own working area; the AppKit half multiplies by `k` on the way to a layer. Run
// the layout against the small rect instead and an 8 pt gap becomes 8 pt of a 900-point screen — four
// times too wide, and every preview a lie about the number beside it.
//
// The scroll offset is a **fold over the beats**, not a function of the final set. `offsetToReveal` is
// relative to where the strip already is, so a take that focuses right twice must reveal from the offset
// the first one left behind — which is exactly what the reducer does, one command at a time.

/// What is moving the desktop, and therefore what animates it.
///
/// **A hand is not a spring.** Direct manipulation tracks linearly because a hand does; the
/// coast after the lift springs because a solver does. Getting this backwards is the single most common
/// way a demo feels fake, so it is a fact about the frame rather than a flag someone has to set.
public enum Travel: Sendable, Equatable {
    /// The ordinary case: the draft's own springs carry whatever moved.
    case springs
    /// Fingers are on it. The view draws exactly what the model says, with nothing in between.
    case hand
    /// The fingers came off. The glide spring is what `animation.glide` names and what this is.
    case glide
}

/// A mock desktop at one instant: the set, where the strip is scrolled to, and where every window is.
public struct PreviewState: Sendable, Equatable {
    /// The set as of this instant — the roles and the focus the view draws.
    public let scene: Scene
    /// The display's working area, in true points. Carried so a camera framing "the middle of the
    /// screen" has a screen to be the middle of without a second parameter following it everywhere.
    public let workingArea: Rect
    /// The strip's scroll offset, in true points.
    public let scrollOffset: Double
    /// Every mock window's frame, in true points on the display's own working area.
    public let frames: [WindowId: Rect]
    /// Where the mock pointer rests, in true points, or `nil` when the set carries none.
    public let pointer: Point?
    /// Whether the pointer is drawn. `mouse.hide` is what takes it away, and a pointer that vanished
    /// without travelling first would be showing the wrong setting.
    public let isPointerShown: Bool
    /// The guides, drawn small on the mock, in drawing order — empty when the set carries none or
    /// none is enabled.
    public let guides: [GuideFrame]
    /// Where the mock is being looked at from. Resolved to a rect against the display by `Camera`,
    /// because only the AppKit half knows the display's shape.
    public let camera: Camera
    /// The mark to draw, in true points, or `nil` — which of the two, and where.
    public let mark: Mark.Drawn?
    /// Whether the focus ring is drawn: whether focus is part of what the setting on screen is about.
    public let showsFocus: Bool
    /// What is moving the desktop this instant, which decides what animates it. A hand tracks 1:1 and
    /// must not ease, a coast after the lift is the glide spring, and everything else is the ordinary
    /// springs.
    public let travel: Travel
    /// A pause owed before anything may move — `animation.cover = exact` paying a capture round trip.
    /// Zero everywhere else, which is most of the window.
    public let head: Double
    /// A window drawn above the strip because a hand is on it. During an edge drag the dragged window
    /// grows **over** its neighbour, which has not moved — so the neighbour painting on top of it would
    /// hide the very edge the hand is carrying.
    public let raised: WindowId?

    public var focus: WindowId { scene.focus }

    /// Where each enabled guide's panel goes, by style — what the movement springs are keyed on.
    public var panels: [GuideStyle: Rect] {
        guides.reduce(into: [:]) { panels, guide in panels[guide.style] = guide.panel }
    }

    /// One style's guide this frame, or `nil` when it is not up. What a camera framing a particular
    /// guide asks.
    public func guide(_ style: GuideStyle) -> GuideFrame? {
        guides.first { $0.style == style }
    }

    /// The focused window's frame — the ring, when there is one to draw.
    public var focusFrame: Rect? { frames[scene.focus] }

    /// The focused window's whole column: the union of its stack's frames. What a camera framing "the
    /// column" is measured against, and it comes off the frames rather than off the layout so a column
    /// mid-resize is the column that is on screen.
    public var focusedColumnFrame: Rect? {
        guard let column = scene.focusedColumn else { return nil }
        return column.windows.compactMap { frames[$0.id] }
            .reduce(Rect?.none) { union, frame in union.map { $0.union(frame) } ?? frame }
    }

    /// The gap **inside** the focused column: the band between the focused window and the one stacked
    /// against it, in true points. What `layout.window-gap` is measured against, and `nil` for a column
    /// of one, which has no seam.
    ///
    /// The seam next to the *focused* window rather than the column's first: a stack three deep has two,
    /// and the one to look at is the one beside the window the ring would be on.
    public var stackSeam: Rect? {
        guard let column = scene.focusedColumn, let window = frames[scene.focus] else { return nil }
        let stack = column.windows.compactMap { frames[$0.id] }.sorted { $0.minY < $1.minY }
        let pairs = Array(zip(stack, stack.dropFirst()))
        guard let (upper, lower) = pairs.first(where: { $0.0 == window || $0.1 == window })
            ?? pairs.first else { return nil }
        return Rect(x: upper.minX, y: upper.maxY,
                    width: upper.width, height: lower.minY - upper.maxY)
    }
}

/// The mock desktop's geometry, derived and never stored.
public enum PreviewModel {

    /// The metrics a draft asks for on a display whose working area is `workingArea`.
    ///
    /// The state-derived half of `LayoutMetrics` is empty and that is honest: a preview has no world to
    /// correct and nothing parked, which is the same reason it may not reach the reducer at all.
    public static func metrics(for config: Config, workingArea: Rect) -> LayoutMetrics {
        LayoutMetrics(config: config, workingArea: workingArea)
    }

    /// The mock desktop `t` seconds into `take`, under `config`.
    public static func state(of take: Take, at t: Double,
                             config: Config, workingArea: Rect) -> PreviewState {
        let metrics = metrics(for: config, workingArea: workingArea)
        var scene = take.scene
        var offset = framedOffset(scene, config: config, metrics: metrics, from: 0)
        // Whether the *hand* is what last moved focus. `mouse.follows-focus` has a rung about exactly
        // that — `except-hover` is `force` with this one source removed — so it is folded alongside the
        // set rather than guessed at the end.
        var focusIsTheHands = false
        // The travel in flight: where the cursor set off from, when, and how long it takes. Only a
        // `hover` leaves focus answering it, and only until the next commanded focus change.
        var hand: Hand?
        var hoverIsLive = false
        // The strip under the fingers. While one is live the offset is the hand's and **focus framing
        // is off** — a reveal dragging the strip back to the focused column would be the machine
        // fighting the user, which is the one thing direct manipulation must never do.
        var scrub: Scrub?
        // A hand on a window's own edge. Live, it overrides one column's width without touching the
        // layout — which is what keeps the neighbours where they are.
        var drag: Drag?
        // Where the pointer has been **put**, and stays until the script moves it again: by a warp, or
        // by a hand letting go of an edge. Under `interactive-resize = off` the width is taken back and
        // the window springs to the one the ladder says, and a cursor still pinned to its edge would be
        // dragged home with it — a hand teleporting rather than a layout changing its mind.
        var parked: Point?
        var travel = Travel.springs
        var head: Double = 0
        // When the desktop last moved. **The guide is raised by motion and lowered by `duration`**, as
        // the daemon does it, so the whole life cycle is on screen every few seconds and `off` really
        // does mean nothing appears.
        var raisedAt: Double?
        let phase = take.isStatic ? 0 : wrapped(t, into: take.period)

        // **Focus answering the hand, at whatever instant is being folded.** A nested function because it
        // closes over the fold's own running state, and a second copy of that thread is exactly the bug
        // it exists to prevent. Run at every beat as well as at the end, because the fold is what later
        // beats see: a command back to the window a hover already left is a focus change, and one the
        // fold cannot see is a pointer that is never sent after it.
        func answerHover(at instant: Double) {
            guard hoverIsLive, scene.pointerFocus.answers(config) else { return }
            guard let under = window(under: handPoint(of: scene, offset: offset, metrics: metrics,
                                                      hand: hand, phase: instant),
                                     of: scene, offset: offset, metrics: metrics),
                  under != scene.focus else { return }
            scene = scene.focusing(under)
            focusIsTheHands = true
            offset = framedOffset(scene, config: config, metrics: metrics, from: offset)
            parked = warp(after: scene, config: config, offset: offset, metrics: metrics,
                          from: handPoint(of: scene, offset: offset, metrics: metrics,
                                          hand: hand, phase: instant),
                          pointerCaused: true) ?? parked
        }

        for (at, beat) in take.beats(upTo: t) {
            answerHover(at: at)
            let focused = scene.focus
            if let over = beat.travel {
                hand = Hand(from: parked
                                ?? handPoint(of: scene, offset: offset, metrics: metrics,
                                             hand: hand, phase: at),
                            at: at, over: over)
                parked = nil
                hoverIsLive = beat.isHover
            } else if beat.isCommandedFocus {
                hoverIsLive = false
                focusIsTheHands = false
            }
            if beat.movesTheDesktop { raisedAt = at }
            scene = beat.applied(to: scene)
            switch beat {
            case .systemFocus(let id):
                let admitted = admits(id, of: scene, config: config, offset: offset, metrics: metrics)
                scene = scene.answering(admitted ? .taken : .declined)
                if admitted {
                    scene = scene.focusing(id)
                    hoverIsLive = false
                    focusIsTheHands = false
                }

            case .scrub(let screens, let over):
                // **`off` is a refusal, not an absence.** The tap is never installed, so the strip
                // never moves — and the badge dimming is what makes that read as a refusal.
                guard config.trackpadScroll.isLive else {
                    scene = scene.answering(.declined)
                    break
                }
                let reach = screens * metrics.contentArea.width
                    * config.trackpadScrollDirection.sign
                scrub = Scrub(from: offset, to: offset + reach, at: at, over: over)

            case .lift:
                guard let live = scrub else { break }
                offset = restingOffset(after: live, of: scene, config: config, metrics: metrics)
                scrub = nil
                travel = .glide

            case .grow(let delta):
                scene = grown(scene, by: delta, config: config, metrics: metrics, offset: offset)

            case .dragEdge(let by, let over):
                guard let column = scene.focusedColumn,
                      let width = scene.layout.resolvedWidth(ofColumn: column.id, metrics: metrics)
                else { break }
                drag = Drag(column: column.id, from: width,
                            by: by.resolved(available: metrics.contentArea.width),
                            at: at, over: over)

            case .coverHead:
                head = config.coverMode == .exact ? coverHead : 0

            case .release:
                guard let live = drag else { break }
                // Read before the adoption, so both rungs leave the hand at the same point: it is where
                // the *hand* got to, which the layout's answer cannot change.
                parked = releasePoint(of: live, scene: scene, offset: offset, metrics: metrics)
                // **The last 500 ms are the setting.** On, the layout takes the dragged size as its own
                // intent and the strip reflows under it; off, the width is simply not adopted and the
                // window springs back to the one the ladder says — emira taking it back, not a glitch.
                if config.interactiveResize {
                    let width = live.width(at: min(phase, live.at + live.over))
                    scene = scene.setting(widthOverride: metrics.widthExtent.proportion(of: width),
                                          ofColumn: live.column)
                }
                drag = nil

            default:
                break
            }
            // A hand on the strip owns the offset outright.
            if scrub == nil, travel != .glide {
                offset = framedOffset(scene, config: config, metrics: metrics, from: offset)
            }
            // **A warp is an event.** The pointer is sent when focus *moves*, exactly as the reducer
            // sends it — once, to the window that just took it — and then it stays there.
            if scene.focus != focused {
                parked = warp(after: scene, config: config, offset: offset, metrics: metrics,
                              from: parked ?? handPoint(of: scene, offset: offset, metrics: metrics,
                                                        hand: hand, phase: at),
                              pointerCaused: focusIsTheHands) ?? parked
            }
        }

        if let scrub {
            let progress = min(max((phase - scrub.at) / max(scrub.over, 1e-9), 0), 1)
            offset = scrub.from + (scrub.to - scrub.from) * progress
            travel = .hand
        }

        // **The cursor decides where focus is, not the other way round** — which is what makes the ring
        // transfer land on the seam crossing itself rather than on the beat that started the move. Read
        // off the *hand's* position rather than the drawn one, or `force` recentring the cursor would
        // then be what decided which window it had crossed into.
        answerHover(at: phase)

        // **Only now**, because a height rung is the one thing on a set that no scroll target reads: a
        // column is as wide as its presets say whatever its stack is doing, so the offsets above are
        // exact and the heights are applied once, to the frames.
        var frames = layoutFrames(of: scene, offset: offset, metrics: metrics)
        if let drag {
            frames = dragged(frames, by: drag, of: scene, phase: phase)
            travel = .hand
        }

        return PreviewState(scene: scene, workingArea: workingArea,
                            scrollOffset: offset, frames: frames,
                            pointer: drag.map { $0.cursor(of: scene, frames: frames, phase: phase) }
                                ?? parked
                                ?? handPoint(of: scene, offset: offset, metrics: metrics,
                                             hand: hand, phase: phase),
                            // **A cursor never drawn is not a cursor being hidden.** The script asks;
                            // `mouse.hide` decides; a set with no pointer at all has neither.
                            isPointerShown: scene.pointer.map {
                                !($0.isHidden && config.hidesCursor)
                            } ?? false,
                            guides: GuideFrame.all(showing: raised(scene, raisedAt: raisedAt,
                                                                   phase: phase, config: config,
                                                                   isStatic: take.isStatic),
                                                   config: config, scene: scene,
                                                   workingArea: workingArea, frames: frames),
                            camera: take.camera(at: t),
                            mark: mark(of: take, scene: scene, config: config, metrics: metrics,
                                       offset: offset),
                            showsFocus: take.showsFocus,
                            travel: travel, head: head,
                            raised: drag.flatMap { live in
                                scene.columns.first { $0.id == live.column }?.windows.first?.id
                            })
    }

    /// Which guides are up: a set that carries one, something having moved, and that guide's own
    /// `duration` not yet run out since it did — **each on its own clock, as the daemon arms them**. A
    /// **static** take keeps them up for as long as the pointer is on the row, having nothing to fade.
    private static func raised(_ scene: Scene, raisedAt: Double?, phase: Double,
                               config: Config, isStatic: Bool) -> [GuideStyle] {
        guard scene.hasGuide else { return [] }
        guard let raisedAt else { return isStatic ? config.guide.enabledStyles : [] }
        return config.guide.enabledStyles.filter {
            phase - raisedAt <= config.guide.table(of: $0).duration
        }
    }

    /// The pause `exact` pays: one capture round trip, long enough to be a wait rather than a stutter.
    /// **The pause is one cost and the softness is the other** — neither is annotated, and both are the
    /// thing itself.
    public static let coverHead: Double = 0.35

    /// A hand on a window's trailing edge: which column, the width it started at, how far it carries,
    /// and the window of time it takes.
    private struct Drag {
        let column: ColumnId
        let from: Double
        let by: Double
        let at: Double
        let over: Double

        /// The dragged width at `phase`. **1:1 with the hand** — a resize handle that eased would be a
        /// window resizing itself rather than a hand resizing it.
        func width(at phase: Double) -> Double {
            let progress = min(max((phase - at) / max(over, 1e-9), 0), 1)
            return max(from + by * progress, 1)
        }

        /// Where the cursor is: on the edge it is carrying, at the height it grabbed it.
        func cursor(of scene: Scene, frames: [WindowId: Rect], phase: Double) -> Point? {
            guard let column = scene.columns.first(where: { $0.id == self.column }),
                  let window = column.windows.first, let frame = frames[window.id] else { return nil }
            return Point(x: frame.maxX, y: frame.minY + frame.height * dragGrip)
        }
    }

    /// How far down the edge a hand takes hold, as a fraction of the window's height.
    ///
    /// **Public because a take has to aim at it.** The hand arrives under its own script and the drag
    /// takes the cursor over on the press; land the two a few points apart and the cursor jumps sideways
    /// at the moment the button goes down, which reads as the demo skipping a frame.
    public static let dragGrip: Double = 0.45

    /// Where the hand is at the end of a drag, in true points — the edge it carried, at the height it
    /// grabbed. Read off the layout the drag was made against rather than the frames it produced, so
    /// the answer is the same whether or not the width is about to be adopted.
    private static func releasePoint(of drag: Drag, scene: Scene, offset: Double,
                                     metrics: LayoutMetrics) -> Point? {
        let frames = layoutFrames(of: scene, offset: offset, metrics: metrics)
        guard let column = scene.columns.first(where: { $0.id == drag.column }),
              let window = column.windows.first, let frame = frames[window.id] else { return nil }
        return Point(x: frame.minX + drag.width(at: drag.at + drag.over),
                     y: frame.minY + frame.height * dragGrip)
    }

    /// `frames` with the dragged column's windows carrying the hand's width — and **nothing else moved**.
    ///
    /// The layout is deliberately untouched: adoption is on release, so the neighbours holding still is
    /// the truth of the mechanism rather than a corner cut in the preview.
    private static func dragged(_ frames: [WindowId: Rect], by drag: Drag, of scene: Scene,
                                phase: Double) -> [WindowId: Rect] {
        guard let column = scene.columns.first(where: { $0.id == drag.column }) else { return frames }
        let width = drag.width(at: phase)
        var moved = frames
        for window in column.windows {
            guard let frame = frames[window.id] else { continue }
            moved[window.id] = Rect(x: frame.minX, y: frame.minY,
                                    width: width, height: frame.height)
        }
        return moved
    }

    /// The strip under the fingers: where it started, where it is heading, and the window of time.
    private struct Scrub {
        let from: Double
        let to: Double
        let at: Double
        let over: Double
    }

    /// Where the strip comes to rest when the fingers leave it.
    ///
    /// **The whole difference between the two live rungs is this line.** Both track the fingers
    /// identically; `magnet` projects the momentum onto the nearest offset where a column edge lies
    /// flush with a viewport edge, `free` simply lets it run out. Through `Layout.magnetScrollOffset`,
    /// so a preview of the setting and the reducer obeying it are one expression.
    private static func restingOffset(after scrub: Scrub, of scene: Scene, config: Config,
                                      metrics: LayoutMetrics) -> Double {
        let coasted = scrub.to + coast * metrics.contentArea.width
            * config.trackpadScrollDirection.sign
        let clamped = scene.layout.clampScrollOffset(coasted, metrics: metrics)
        guard config.trackpadScroll == .magnet else { return clamped }
        return scene.layout.magnetScrollOffset(nearest: clamped, metrics: metrics,
                                               centered: config.centerFocusedColumn)
    }

    /// How far the strip carries after the lift, in screens. Chosen so a `free` rest lands plainly
    /// *between* two column edges — the point of the rung is that it does not tidy up.
    private static let coast: Double = 0.18

    /// The focused column grown by `delta`, with the detent applied where the setting asks for it.
    ///
    /// **The reducer's own arithmetic**: `Strip.resizeDetent` is where a notch lives, and a detent only
    /// ever shortens a delta — it catches, it never pulls.
    private static func grown(_ scene: Scene, by delta: SizeDelta, config: Config,
                              metrics: LayoutMetrics, offset: Double) -> Scene {
        guard let column = scene.focusedColumn else { return scene }
        let layout = scene.layout
        let available = metrics.contentArea.width
        let from = layout.resolvedWidth(ofColumn: column.id, metrics: metrics) ?? 0
        var travel = delta.resolved(available: available)
        if config.resizeDetent, let index = layout.columnIndex(withId: column.id),
           let notch = layout.strip(metrics: metrics)
               .resizeDetent(ofColumn: index, growing: travel > 0, viewportWidth: available,
                             offset: offset, centered: config.centerFocusedColumn) {
            travel = min(travel, notch)
        }
        let width = min(max(from + travel, 1), available)
        return scene.setting(widthOverride: metrics.widthExtent.proportion(of: width),
                             ofColumn: column.id)
    }

    /// The mark to draw, if any: the flush tick where the script asked for one **and the geometry
    /// bears it out**, otherwise the take's own standing mark.
    private static func mark(of take: Take, scene: Scene, config: Config, metrics: LayoutMetrics,
                             offset: Double) -> Mark.Drawn? {
        if let edge = scene.asksFlush,
           isFlush(on: edge, of: scene, offset: offset, metrics: metrics) {
            return .flush(Mark.flushTick(on: edge, contentArea: metrics.contentArea))
        }
        return take.mark
            .map { .gutter($0.band(workingArea: metrics.workingArea, gaps: config.outerGaps)) }
    }

    /// Whether a column edge lies on the viewport's `edge` — which is what the tick claims, so it is
    /// asked rather than assumed.
    ///
    /// **The edge is the one the motion was heading toward.** A magnet settles a column's near edge on
    /// the viewport's leading edge; a detent stops a grow where the strip's far end meets its trailing
    /// one. Asking about "any coincidence" would answer yes at rest, where the first column's left edge
    /// sits on the viewport's left edge and nothing has happened at all.
    private static func isFlush(on edge: Mark.Edge, of scene: Scene, offset: Double,
                                metrics: LayoutMetrics) -> Bool {
        let area = metrics.contentArea
        let strip = scene.layout.strip(metrics: metrics)
        let against = edge == .right ? area.maxX : area.minX
        for i in 0..<strip.count {
            let left = area.minX + strip.leftEdge(of: i) - offset
            for candidate in [left, left + strip.columnWidths[i]] where abs(candidate - against) < 0.5 {
                // The strip's own start against the viewport's start is the resting arrangement rather
                // than an arrival, and it is true before anything has moved.
                if edge == .left, i == 0, candidate == left, offset == 0 { continue }
                return true
            }
        }
        return false
    }

    /// The set at rest, with no take playing — a static take's one and only state.
    public static func state(of scene: Scene, config: Config, workingArea: Rect) -> PreviewState {
        state(of: Take(scene: scene), at: 0, config: config, workingArea: workingArea)
    }

    /// A travel in flight: where the hand set off from — in screen points, since a hand does not move
    /// with the strip — and the window of time it takes.
    private struct Hand {
        let from: Point?
        let at: Double
        let over: Double
    }

    /// Where the **hand** has got to this instant — the script alone, with `follows-focus` ignored.
    ///
    /// A travel that has run out lands on its destination exactly, so nothing downstream has to decide
    /// when it is over.
    private static func handPoint(of scene: Scene, offset: Double, metrics: LayoutMetrics,
                                  hand: Hand?, phase: Double) -> Point? {
        let frames = layoutFrames(of: scene, offset: offset, metrics: metrics)
        guard let to = scene.pointer?.at.point(frames: frames, workingArea: metrics.workingArea) else {
            return nil
        }
        guard let hand, let from = hand.from, hand.over > 0 else { return to }
        let progress = min(max((phase - hand.at) / hand.over, 0), 1)
        guard progress < 1 else { return to }
        return arc(from: from, to: to, progress: reach(progress))
    }

    /// A hand's own velocity profile: **minimum jerk**, the trajectory a person reaching for something
    /// traces, whose closed form `10p³ − 15p⁴ + 6p⁵` has zero velocity *and* zero acceleration at both
    /// ends. At a constant speed a cursor sets off and stops dead inside one frame, and what that reads
    /// as is a teleport followed by a slide.
    ///
    /// **"A hand is not a spring" is about the hand as an *input*** — `scrub` and `dragEdge` track it
    /// 1:1 with nothing in between, and must. A hand being animated is the opposite case.
    static func reach(_ progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return p * p * p * (10 + p * (-15 + 6 * p))
    }

    /// Where a focus change sends the pointer, or `nil` for one that sends it nowhere.
    ///
    /// **The two reducer predicates and nothing else.** `warps(pointerCaused:)` says whether a focus
    /// change owes the pointer a visit at all, which is how `except-hover` differs from `force`;
    /// `recentres` says whether one already inside the window is moved anyway, which is how `lazy`
    /// differs from both. **A warp is a jump**, not a travel — the real one is a single `warpPointer`.
    ///
    /// **And an event, not an invariant**: asked only where focus has just moved. Asked every frame it
    /// becomes "the cursor is always in the middle of the focused window", which pins the hand through
    /// every take that carries one.
    private static func warp(after scene: Scene, config: Config, offset: Double,
                             metrics: LayoutMetrics, from: Point?, pointerCaused: Bool) -> Point? {
        let mode = config.mouseFollowsFocus
        guard mode.warps(pointerCaused: pointerCaused) else { return nil }
        // Clamped into the working area, as the reducer clamps it: a column only half revealed at the
        // viewport's edge takes the pointer to the part of itself the user can actually see.
        let frames = layoutFrames(of: scene, offset: offset, metrics: metrics)
        guard let focused = frames[scene.focus]?.intersection(metrics.workingArea) else { return nil }
        guard let from else { return focused.center }
        guard mode.recentres || !focused.contains(from) else { return nil }
        return focused.center
    }

    /// A straight travel bowed a little. A hand does not move in a line, and the bow is what separates
    /// a cursor being carried by a person from one being tweened by a timer.
    ///
    /// Handed the **eased** progress, so the bow rides the same clock as the travel and the pace along
    /// the path is the only thing `reach` decides.
    private static func arc(from: Point, to: Point, progress p: Double) -> Point {
        let dx = to.x - from.x, dy = to.y - from.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let straight = Point(x: from.x + dx * p, y: from.y + dy * p)
        guard distance > 1 else { return straight }
        // Perpendicular, and the sign that bows *upwards* for a rightward move — the way a hand swings.
        let bow = sin(p * Double.pi) * min(distance * bowFraction, maximumBow)
        return Point(x: straight.x + (dy / distance) * bow, y: straight.y - (dx / distance) * bow)
    }

    /// How far off the straight line the middle of a travel bows, as a fraction of its length.
    private static let bowFraction: Double = 0.10

    /// And the most it ever bows, in true points. **The swing is the wrist's, not the distance's** — a
    /// hand crossing a whole screen does not arc a tenth of one — and without a bound a travel that is
    /// meant to read as a straight line back along a window's edge leaves it by fifty points.
    private static let maximumBow: Double = 18

    /// The window the cursor is inside, or `nil` for open desktop — where focus stays where it was.
    private static func window(under cursor: Point?, of scene: Scene, offset: Double,
                               metrics: LayoutMetrics) -> WindowId? {
        guard let cursor else { return nil }
        let frames = layoutFrames(of: scene, offset: offset, metrics: metrics)
        // Layout order, so a stack is read top to bottom exactly as `World.window(at:)` reads one.
        return scene.windows.first { frames[$0.id]?.contains(cursor) == true }?.id
    }

    /// Every window's frame: the strip's, laid out by the code that lays out the real one, plus the
    /// floats, which are wherever their app put them and take no part in it.
    private static func layoutFrames(of scene: Scene, offset: Double,
                                     metrics: LayoutMetrics) -> [WindowId: Rect] {
        var placed = metrics
        placed.heightSelections = scene.heightSelections
        return scene.layout.naturalFrames(scrollOffset: offset, metrics: placed)
            .merging(scene.floatFrames(workingArea: metrics.workingArea)) { _, float in float }
    }

    /// Whether the policy lets a focus emira did not cause land on `id`.
    ///
    /// **The reducer's own ladder, and it is monotone by construction**: `ignore` is `onScreen` minus
    /// the windows emira places, and `respect` admits without asking. Derived from the geometry rather
    /// than from a flag on the beat, so a set that moved its float off the screen would change what the
    /// rungs answer — as it should.
    private static func admits(_ id: WindowId, of scene: Scene, config: Config,
                               offset: Double, metrics: LayoutMetrics) -> Bool {
        switch config.systemFocusEvents {
        case .respect:
            return true
        case .onScreen:
            return isOnScreen(id, of: scene, offset: offset, metrics: metrics)
        case .ignore:
            return isOnScreen(id, of: scene, offset: offset, metrics: metrics) && scene.isFloat(id)
        }
    }

    private static func isOnScreen(_ id: WindowId, of scene: Scene, offset: Double,
                                   metrics: LayoutMetrics) -> Bool {
        guard let frame = layoutFrames(of: scene, offset: offset, metrics: metrics)[id] else {
            return false
        }
        return frame.intersection(metrics.workingArea) != nil
    }

    /// `t` brought into one loop.
    private static func wrapped(_ t: Double, into period: Double) -> Double {
        guard period > 0 else { return 0 }
        let phase = t.truncatingRemainder(dividingBy: period)
        return phase < 0 ? phase + period : phase
    }

    /// Where the strip comes to rest with `scene`'s focused column framed, coming from `offset`.
    ///
    /// `Layout.scrollOffsetToFrame` is the reducer's own choice between centring and the minimal reveal,
    /// so `layout.center-focused-column` previews itself rather than being modelled a second time here.
    private static func framedOffset(_ scene: Scene, config: Config,
                                     metrics: LayoutMetrics, from offset: Double) -> Double {
        scene.layout.scrollOffsetToFrame(window: scene.focus, from: offset,
                                         metrics: metrics,
                                         center: config.centerFocusedColumn) ?? offset
    }
}
