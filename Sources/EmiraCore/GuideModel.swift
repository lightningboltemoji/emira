import Foundation

// The guide's arithmetic, stated once and with no AppKit in it — `GuidePanel` is the wiring, this is
// the policy, the same split `MenuBar` keeps between `StatusModel` and `MenuBarItem`.
//
// The whole projection is one dimensionless number, `GuideSettings.scale`, and one window of screen
// space:
//
//     k          = min(width, 1) / span             (clamped so the ribbon fits one working area)
//     content    = the focused strip's extent, never less than the screen you are on
//     shown      = content, or a `span`-screens-wide window following the viewport inside it
//     panel.size = (k · shown.width, k · working.height)
//     project(r) = panel.origin + (r.origin − shown.origin) · k,  size: r.size · k
//
// **`span` is a ceiling, not a frame.** The guide shows the strip, and only clamps to `span` screens
// once the strip is longer than that — so two screens of windows draw a two-screens-wide ribbon rather
// than a `span`-wide one with the ends empty. The panel therefore *shrinks*, and it is the **viewport
// indicator that travels**: at either end of a long strip the shown window pins to the content's edge
// and the indicator slides to that end, while in the middle it centres and the tiles slide past it
// instead. The two regimes meet continuously — the clamp is a `min`/`max`, not a branch you can see.
//
// The panel's **height is derived, never configured**: the ribbon is exactly as tall as one desktop at
// scale `k`.
//
// The content is the one expression the cover uses, unmodified, which is where three things come from
// at no cost: off-screen columns (it is un-parked geometry), workspace switches sliding vertically
// through the panel (`verticalOffset` is already in there), and animated resizes and structural edits
// moving in lockstep with the real ones.

/// One window's rectangle in the guide: where to draw it, and the two identities the drawing needs —
/// the window (its still, and the layer pool's key) and its app (the icon placeholder).
public struct GuideTile: Equatable, Sendable {
    public let window: WindowId
    public let bundleId: String
    /// Panel-local, in guide points, with the separation inset already applied.
    public let rect: Rect
}

/// One frame of the guide: where the panel is, and everything drawn inside it.
public struct GuideLayout: Equatable, Sendable {
    /// The panel itself, in core (top-left, global) screen coordinates.
    public let panel: Rect
    /// Every window on every materialized workspace. The ones a screen up or down project outside the
    /// panel and clip, which is what makes a workspace switch slide through it.
    public let tiles: [GuideTile]
    /// Where the strip divides, panel-local: a line down each boundary between adjacent columns and one
    /// across each boundary between windows stacked in a column. **Degenerate by construction** — a
    /// boundary is a line, so a column's has no width and a stack's no height — which is what lets the
    /// one projection place them alongside everything else.
    public let separators: [Rect]
    /// The focused window's rectangle plus the ring's in-flight travel, panel-local — or `nil` when
    /// focus is on nothing the strip places.
    public let ring: Rect?
    /// The live viewport, panel-local: one working area at scale `k`, so it is the panel's full height
    /// and a `span`-th of its width.
    public let viewport: Rect
}

/// Four corner radii, in `Rect`'s own top-left orientation: `topLeft` is the corner at `(minX, minY)`.
/// `CALayer.cornerRadius` is one number for all four, and the guide needs four — see `corners(of:in:)`.
public struct Corners: Equatable, Sendable {
    public var topLeft: Double
    public var topRight: Double
    public var bottomRight: Double
    public var bottomLeft: Double

    public init(topLeft: Double, topRight: Double, bottomRight: Double, bottomLeft: Double) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public static func uniform(_ radius: Double) -> Corners {
        Corners(topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius)
    }

    /// The same corners on a rect inset by `d`: concentric, so every radius tightens by exactly the
    /// inset and none goes below zero. A stroke drawn inside a silhouette, or a mask drawn inside a
    /// stroke, is this.
    public func inset(by d: Double) -> Corners {
        Corners(topLeft: max(topLeft - d, 0), topRight: max(topRight - d, 0),
                bottomRight: max(bottomRight - d, 0), bottomLeft: max(bottomLeft - d, 0))
    }
}

/// What a *change* in the guide's subject looks like — a small diffed projection of `State` rather than
/// the whole of it, so an `axLanded` or a title change cannot summon a HUD. `MenuBarItem`'s rule:
/// report a change in the value, not in the thing carrying it.
public struct GuideTrigger: Equatable, Sendable {
    /// One column's identity and its stack, which together say "the strip was rearranged".
    public struct Column: Equatable, Sendable {
        public let id: ColumnId
        public let windows: [WindowId]
    }

    public let focused: WindowId?
    public let workspace: WorkspaceName
    public let columns: [Column]
    /// Where the scroll is *aimed*, not where it is — a target moves once per command, a current value
    /// moves 120 times a second.
    public let offset: Double
}

/// The guide's geometry: what the panel shows, and where it sits.
public enum GuideModel {

    /// Points held clear on each side of a tile, applied **after** projection and so constant whatever
    /// `k` is and whatever the user's gaps are. `column-gap` defaults to 0, which would otherwise draw
    /// the minimap as one undifferentiated bar; the frames themselves are never re-derived with
    /// different gaps, because there is one geometry authority.
    static let separation = 1.5

    /// A frame of `monitor`'s guide, or `nil` when there is nothing to draw — the guide is off, the
    /// display is not attached, or the strip it is showing is empty.
    ///
    /// **Everything is asked of `monitor`**: its metrics, the address it is showing, and that strip's
    /// extent. A display showing an empty workspace projects nothing and so draws no guide, which is
    /// the right answer and not a special case.
    public static func layout(for state: State, on monitor: MonitorId) -> GuideLayout? {
        let settings = state.config.guide
        guard settings.style != .off, let metrics = state.metrics(of: monitor),
              let shown = state.monitors.shown(on: monitor) else { return nil }

        let frames = state.workspaces.naturalFrames(shown: shown, among: state.monitors.owned(of: monitor),
                                                    scrollOffset: state.motion.offset(of: monitor).current,
                                                    metrics: metrics,
                                                    widths: state.motion.currentColumnWidths)
        // The **shown** strip's extent, not every workspace's: a long strip on a workspace you cannot
        // see would otherwise size the guide for one you can. During a switch this is already the strip
        // being switched *to*, which is the one the guide should be sizing itself for.
        let strip = state.workspaces[shown].columns.flatMap(\.windowIds)
            .compactMap { frames[$0] }
            .reduce(Rect.zero) { $0.union($1) }
        guard let projection = projection(settings: settings, working: metrics.workingArea,
                                          strip: strip) else { return nil }

        // **This display's workspaces only**, which `naturalFrames` is already asked for: the neighbours
        // that slide through the panel during a switch are the ones *this* monitor holds, and another
        // display's strips have nothing to do with this panel.
        let mine = windows(of: state, on: monitor)
        // Sorted, so a rebuild of the layer pool is driven by the id *set* changing and never by
        // dictionary iteration order.
        let tiles = frames.keys.sorted().compactMap { id -> GuideTile? in
            guard let window = state.world.windows[id] else { return nil }
            guard let frame = frames[id] else { return nil }
            return GuideTile(window: id, bundleId: window.bundleId,
                             rect: separated(projection.project(frame)))
        }

        let ring = focusedWindow(of: state, among: mine)
            .flatMap { frames[$0] }
            .map { projection.project($0.displaced(by: state.motion.focusRingDisplacement)) }

        return GuideLayout(panel: projection.panel, tiles: tiles,
                           separators: boundaries(of: state.workspaces[shown].columns, frames: frames)
                               .map(projection.project),
                           ring: ring, viewport: projection.project(metrics.workingArea))
    }

    /// What `monitor`'s guide is *about* right now, or `nil` when it is off or the display has left.
    ///
    /// Every field is this display's, `focused` included: there is one focused window on the desktop,
    /// and a display that does not hold it must not summon a HUD because focus moved on another screen.
    public static func trigger(for state: State, on monitor: MonitorId) -> GuideTrigger? {
        guard state.config.guide.style != .off,
              let shown = state.monitors.shown(on: monitor) else { return nil }
        return GuideTrigger(
            focused: focusedWindow(of: state, among: windows(of: state, on: monitor)),
            workspace: shown,
            columns: state.workspaces[shown].columns.map { .init(id: $0.id, windows: $0.windowIds) },
            offset: state.motion.offset(of: monitor).target)
    }

    /// Every window on a strip `monitor` holds — the set both the tiles and the ring are drawn from.
    private static func windows(of state: State, on monitor: MonitorId) -> Set<WindowId> {
        Set(state.monitors.owned(of: monitor).flatMap { state.workspaces[$0].allWindowIds })
    }

    /// The focused window if this display holds it, else `nil`. The ring is single because focus is;
    /// only the monitor holding it draws one.
    private static func focusedWindow(of state: State, among mine: Set<WindowId>) -> WindowId? {
        state.world.focusedWindow.flatMap { mine.contains($0) ? $0 : nil }
    }

    /// A tile with its separation taken out of it. Never more than a quarter of an extent, so a tile at
    /// a high `span` thins rather than inverting.
    static func separated(_ rect: Rect) -> Rect {
        rect.insetBy(dx: min(separation, rect.width / 4), dy: min(separation, rect.height / 4))
    }

    // Where the strip divides

    /// The boundaries between adjacent tiles, in screen space, to be projected with everything else: a
    /// line down the middle of every gap between columns, and one across every gap between windows
    /// stacked in a column.
    ///
    /// A separator is the **boundary** rather than either edge of it, so `column-gap = 0` puts it on the
    /// shared edge and a wide gap centres it in the space. Each spans the whole of what it divides — a
    /// column boundary runs the full height of the two columns it parts, a stack boundary the full width
    /// of its column — which is what makes the set read as a grid rather than as a row of ticks. They
    /// come from the *focused* strip's columns, like the extent does, and from the same `frames`, so a
    /// workspace sliding in brings its own with it.
    static func boundaries(of columns: [ColumnLayout], frames: [WindowId: Rect]) -> [Rect] {
        var lines: [Rect] = []
        var extents: [Rect] = []
        for column in columns {
            // `windowIds` is the stack top→bottom, so consecutive pairs are exactly the boundaries.
            let stack = column.windowIds.compactMap { frames[$0] }
            let extent = stack.reduce(Rect.zero) { $0.union($1) }
            guard !extent.isEmpty else { continue }
            extents.append(extent)
            for (upper, lower) in zip(stack, stack.dropFirst()) {
                lines.append(Rect(x: extent.minX, y: (upper.maxY + lower.minY) / 2,
                                  width: extent.width, height: 0))
            }
        }
        for (left, right) in zip(extents, extents.dropFirst()) {
            let top = min(left.minY, right.minY)
            lines.append(Rect(x: (left.maxX + right.minX) / 2, y: top, width: 0,
                              height: max(left.maxY, right.maxY) - top))
        }
        return lines
    }

    //
    // Paint-time, like the separation: it changes no frame, and it is here rather than in `GuidePanel`
    // because it is arithmetic and the panel is wiring. The radii themselves are cosmetics and stay
    // with the rest of the look, which is why both of these take them rather than knowing them.

    /// A rect's corners: its own `radius` everywhere, except where one approaches a corner of
    /// `container`, where it takes the radius **concentric** with that corner instead.
    ///
    /// A corner `d` points inside the container's is drawn at `outer − d` — the one curve that holds a
    /// constant gap from it — decaying back to the rect's own radius at `d = outer − radius`. So a tile
    /// pushed into the end of the ribbon rounds to the ribbon, and gives that curve up continuously as
    /// it scrolls away from it. `d` is the *larger* of the two offsets, so a tile flush against one edge
    /// but well along it is not in the corner. Each radius is capped at half the short side, below which
    /// a rounded rect stops being one.
    public static func corners(of rect: Rect, in container: Rect, radius: Double,
                               outer: Double) -> Corners {
        // Clamped at zero: a tile hanging off the ribbon has its corner outside the clip, where the
        // ribbon's own curve is already what the eye sees.
        let left = max(rect.minX - container.minX, 0)
        let right = max(container.maxX - rect.maxX, 0)
        let top = max(rect.minY - container.minY, 0)
        let bottom = max(container.maxY - rect.maxY, 0)
        let cap = min(rect.width, rect.height) / 2
        func corner(_ a: Double, _ b: Double) -> Double {
            min(max(radius, outer - max(a, b)), cap)
        }
        return Corners(topLeft: corner(left, top), topRight: corner(right, top),
                       bottomRight: corner(right, bottom), bottomLeft: corner(left, bottom))
    }

    /// The padding rule's three numbers: what a placeholder icon takes of its tile's short side when the
    /// tile has room for it, what it takes when the tile is crunched, and the squareness at which the
    /// padding has fully given way.
    static let icon = (roomy: 0.6, crunched: 0.85, crunch: 0.5)

    /// Where a placeholder icon sits inside a tile of `size`: a centred square, padded by how much room
    /// the tile has for it.
    ///
    /// An icon is square and a tile is not, so fitting it by aspect alone hands it the tile's whole short
    /// side — in a tile anywhere near square that is an icon at full height, which reads as a button
    /// rather than as a hint of what the window is. The padding therefore tracks the tile's *squareness*:
    /// a square tile gives the icon three fifths of its side, and one at 2:1 or thinner gives it 85%,
    /// because by then the short side is short enough that padding costs more than it buys. Between the
    /// two it is linear, and it is the same rule whether the tile is thin (a narrow column) or flat (a
    /// window stacked in one): what is being crunched is the aspect, not an axis.
    public static func placeholder(in size: Size) -> Rect {
        guard !size.isEmpty else { return .zero }
        let short = min(size.width, size.height)
        let squareness = short / max(size.width, size.height)
        let room = min(max((squareness - icon.crunch) / (1 - icon.crunch), 0), 1)
        let side = short * (icon.crunched + (icon.roomy - icon.crunched) * room)
        return Rect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                    width: side, height: side)
    }

    /// Where the panel sits and how screen geometry maps into it. Pure, and the whole of the placement
    /// policy: nine anchors, one gap, one scale.
    public struct Projection: Equatable, Sendable {
        /// The panel in core (top-left, global) screen coordinates.
        public let panel: Rect
        /// Guide points per screen point.
        public let scale: Double
        /// The screen-space point the panel's top-left corner shows.
        public let origin: Point

        /// A screen-space rect in panel-local guide points.
        public func project(_ rect: Rect) -> Rect {
            Rect(x: (rect.minX - origin.x) * scale, y: (rect.minY - origin.y) * scale,
                 width: rect.width * scale, height: rect.height * scale)
        }
    }

    /// The panel's size and placement, or `nil` for a degenerate scale or an empty display.
    ///
    /// `strip` is the focused strip's bounding box in screen space — empty for a strip with no windows,
    /// which is why it defaults to nothing rather than being demanded.
    ///
    /// The gap is measured from the working area's edges and is the first thing to give: a panel with
    /// no room for one is clamped back inside the working area rather than pushed off the display.
    public static func projection(settings: GuideSettings, working: Rect,
                                  strip: Rect = .zero) -> Projection? {
        let k = settings.scale
        guard k > 0, !working.isEmpty else { return nil }

        let shown = shownWindow(settings: settings, working: working, strip: strip)
        let size = Size(width: k * shown.width, height: k * working.height)
        let free = working.inset(by: EdgeInsets(uniform: settings.gap))
        let (fx, fy) = settings.position.fractions
        let x = min(max(free.minX + max(free.width - size.width, 0) * fx, working.minX),
                    working.maxX - size.width)
        let y = min(max(free.minY + max(free.height - size.height, 0) * fy, working.minY),
                    working.maxY - size.height)

        return Projection(panel: Rect(origin: Point(x: x, y: y), size: size), scale: k,
                          origin: Point(x: shown.minX, y: working.minY))
    }

    /// The horizontal window of screen space the guide draws, given what is actually on the strip.
    ///
    /// Two rules, and the second only applies once the first has run out of room. The window is the
    /// strip's own extent **unioned with the viewport**, so the guide is as long as there is something
    /// to show and never so short that the screen you are on won't fit in it — an indicator wider than
    /// the panel containing it is not an indicator. If that exceeds `span` screens the window becomes
    /// exactly `span` screens, positioned to centre the viewport and **clamped inside the content**, so
    /// the ends of a long strip pin the window and let the indicator travel to them instead.
    static func shownWindow(settings: GuideSettings, working: Rect, strip: Rect) -> (minX: Double,
                                                                                      width: Double) {
        let minX = strip.isEmpty ? working.minX : Swift.min(strip.minX, working.minX)
        let maxX = strip.isEmpty ? working.maxX : Swift.max(strip.maxX, working.maxX)
        let limit = settings.span * working.width
        guard maxX - minX > limit else { return (minX, maxX - minX) }
        // `min` after `max`, so a content range barely over the limit still lands inside it.
        let following = Swift.min(Swift.max(working.midX - limit / 2, minX), maxX - limit)
        return (following, limit)
    }
}
