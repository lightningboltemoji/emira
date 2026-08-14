import Foundation

// The guide's arithmetic, stated once and with no AppKit in it — the renderer is the wiring, this is the
// policy, the same split `MenuBar` keeps between `StatusModel` and `MenuBarItem`.
//
// The whole projection is one dimensionless number, `PreviewGuideSettings.scale`, and one window of
// screen space:
//
//     k          = min(width, 1) / span             (clamped so the ribbon fits one working area)
//     content    = the shown strip's extent, never less than the screen you are on
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
// The input is the one expression the cover uses, unmodified, which is where three things come from at
// no cost: off-screen columns (it is un-parked geometry), workspace switches sliding vertically through
// the panel, and animated resizes and structural edits moving in lockstep with the real ones.
//
// **The layout is column-structured**, and that is what makes a second style cheap: the preview guide
// reads window rects, the names guide reads column rects and stack depths, and the separators fall out
// of the same structure rather than being a second derivation from the same frames.

/// One window's rectangle in the guide: where to draw it, and the two identities the drawing needs —
/// the window (its still, and the layer pool's key) and its app (the icon placeholder).
public struct GuideTile: Equatable, Sendable {
    public let window: WindowId
    public let bundleId: String
    /// Panel-local, in guide points, with the separation inset already applied.
    public let rect: Rect

    public init(window: WindowId, bundleId: String, rect: Rect) {
        self.window = window
        self.bundleId = bundleId
        self.rect = rect
    }
}

/// One column of the shown strip, projected: what divides, and what a names cell stands for.
public struct GuideColumn: Equatable, Sendable {
    public let id: ColumnId
    /// The whole column, panel-local and **unseparated** — the union of its stack. What the separators
    /// are measured between, so a rule lands on the boundary rather than a separation inset in from it.
    public let rect: Rect
    /// Its windows, top to bottom, each with the separation already taken out.
    public let tiles: [GuideTile]
}

/// One frame of the guide: where the panel is, and everything drawn inside it.
public struct GuideLayout: Equatable, Sendable {
    /// The panel itself, in core (top-left, global) screen coordinates.
    public let panel: Rect
    /// The shown strip, in strip order.
    public let columns: [GuideColumn]
    /// Tiles the shown strip does not place: a workspace a screen up or down, which projects outside the
    /// panel and clips — which is what makes a workspace switch slide through it.
    public let passing: [GuideTile]
    /// Every tile the panel draws, sorted by window, so a rebuild of the layer pool is driven by the id
    /// *set* changing and never by dictionary iteration order.
    public let tiles: [GuideTile]
    /// Where the strip divides, panel-local: a line down each boundary between adjacent columns and one
    /// across each boundary between windows stacked in a column. **Degenerate by construction** — a
    /// boundary is a line, so a column's has no width and a stack's no height.
    public let separators: [Rect]
    /// The focused window's rectangle plus the ring's in-flight travel, panel-local — or `nil` when
    /// focus is on nothing the strip places.
    public let ring: Rect?
    /// The live viewport, panel-local: one working area at scale `k`, so it is the panel's full height
    /// and a `span`-th of its width.
    public let viewport: Rect

    /// Derives the tile order and the separators from the columns, so neither can be a second opinion
    /// about the structure they come from.
    public init(panel: Rect, columns: [GuideColumn], passing: [GuideTile] = [],
                ring: Rect? = nil, viewport: Rect) {
        self.panel = panel
        self.columns = columns
        self.passing = passing
        self.tiles = (columns.flatMap(\.tiles) + passing).sorted { $0.window < $1.window }
        self.separators = GuideModel.boundaries(of: columns)
        self.ring = ring
        self.viewport = viewport
    }
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

/// The guide's geometry: what the panel shows, and where it sits.
public enum GuideModel {

    /// Points held clear on each side of a tile, applied **after** projection and so constant whatever
    /// `k` is and whatever the user's gaps are. `column-gap` defaults to 0, which would otherwise draw
    /// the minimap as one undifferentiated bar; the frames themselves are never re-derived with
    /// different gaps, because there is one geometry authority.
    static let separation = 1.5

    /// A frame of the guide over `input`, or `nil` when its numbers are degenerate — a span of zero, or
    /// a display with no working area.
    ///
    /// A display showing an empty workspace projects one screen's worth of nothing and so draws an empty
    /// ribbon, which is the right answer and not a special case: the host is what decides whether a
    /// guide goes up at all.
    public static func layout(_ input: GuideInput, settings: PreviewGuideSettings) -> GuideLayout? {
        guard let projection = projection(settings: settings, working: input.workingArea,
                                          strip: input.strip) else { return nil }

        let columns = input.columns.compactMap { column -> GuideColumn? in
            let stack = column.windows.compactMap { window in
                input.frames[window.id].map { (window, projection.project($0)) }
            }
            guard !stack.isEmpty else { return nil }
            return GuideColumn(id: column.id,
                               rect: stack.reduce(Rect.zero) { $0.union($1.1) },
                               tiles: stack.map {
                                   GuideTile(window: $0.0.id, bundleId: $0.0.bundleId,
                                             rect: separated($0.1))
                               })
        }
        let passing = input.passing.compactMap { window in
            input.frames[window.id].map {
                GuideTile(window: window.id, bundleId: window.bundleId,
                          rect: separated(projection.project($0)))
            }
        }
        let ring = input.focus.flatMap { input.frames[$0] }
            .map { projection.project($0.displaced(by: input.focusDisplacement)) }

        return GuideLayout(panel: projection.panel, columns: columns, passing: passing,
                           ring: ring, viewport: projection.project(input.workingArea))
    }

    /// A tile with its separation taken out of it. Never more than a quarter of an extent, so a tile at
    /// a high `span` thins rather than inverting.
    static func separated(_ rect: Rect) -> Rect {
        rect.insetBy(dx: min(separation, rect.width / 4), dy: min(separation, rect.height / 4))
    }

    // Where the strip divides

    /// The boundaries between adjacent tiles, panel-local: a line down the middle of every gap between
    /// columns, and one across every gap between windows stacked in a column.
    ///
    /// A separator is the **boundary** rather than either edge of it, so `column-gap = 0` puts it on the
    /// shared edge and a wide gap centres it in the space. Each spans the whole of what it divides — a
    /// column boundary runs the full height of the two columns it parts, a stack boundary the full width
    /// of its column — which is what makes the set read as a grid rather than as a row of ticks.
    ///
    /// Measured between the columns' **unseparated** rects, which is why a `GuideColumn` carries one:
    /// derived from the tiles it would be a boundary between two insets rather than between two windows.
    static func boundaries(of columns: [GuideColumn]) -> [Rect] {
        var lines: [Rect] = []
        for column in columns {
            // `tiles` is the stack top→bottom, so consecutive pairs are exactly the boundaries — and
            // the midpoint of the band actually left empty, which is the gap's own for any tile tall
            // enough for the separation to be the full 1.5 at both ends.
            for (upper, lower) in zip(column.tiles, column.tiles.dropFirst()) {
                lines.append(Rect(x: column.rect.minX, y: (upper.rect.maxY + lower.rect.minY) / 2,
                                  width: column.rect.width, height: 0))
            }
        }
        for (left, right) in zip(columns, columns.dropFirst()) {
            let top = min(left.rect.minY, right.rect.minY)
            lines.append(Rect(x: (left.rect.maxX + right.rect.minX) / 2, y: top, width: 0,
                              height: max(left.rect.maxY, right.rect.maxY) - top))
        }
        return lines
    }

    //
    // Paint-time, like the separation: it changes no frame, and it is here rather than in the renderer
    // because it is arithmetic and the renderer is wiring. The radii themselves are cosmetics and stay
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

    /// Where a panel of `size` sits in `area`: the nine-anchor arithmetic, one gap, and nothing else.
    ///
    /// The gap is measured from the area's edges and is the first thing to give: a panel with no room
    /// for one is clamped back inside the area rather than pushed off the display. Shared, because every
    /// guide answers the same question about where it goes and only differs in how it got its size.
    public static func place(size: Size, within area: Rect, position: GuidePosition,
                             gap: Double) -> Rect {
        let free = area.inset(by: EdgeInsets(uniform: gap))
        let (fx, fy) = position.fractions
        let x = min(max(free.minX + max(free.width - size.width, 0) * fx, area.minX),
                    area.maxX - size.width)
        let y = min(max(free.minY + max(free.height - size.height, 0) * fy, area.minY),
                    area.maxY - size.height)
        return Rect(origin: Point(x: x, y: y), size: size)
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
    /// `strip` is the shown strip's bounding box in screen space — empty for a strip with no windows,
    /// which is why it defaults to nothing rather than being demanded.
    public static func projection(settings: PreviewGuideSettings, working: Rect,
                                  strip: Rect = .zero) -> Projection? {
        let k = settings.scale
        guard k > 0, !working.isEmpty else { return nil }

        let shown = shownWindow(settings: settings, working: working, strip: strip)
        let size = Size(width: k * shown.width, height: k * working.height)
        return Projection(panel: place(size: size, within: working, position: settings.position,
                                       gap: settings.gap),
                          scale: k, origin: Point(x: shown.minX, y: working.minY))
    }

    /// The horizontal window of screen space the guide draws, given what is actually on the strip.
    ///
    /// Two rules, and the second only applies once the first has run out of room. The window is the
    /// strip's own extent **unioned with the viewport**, so the guide is as long as there is something
    /// to show and never so short that the screen you are on won't fit in it — an indicator wider than
    /// the panel containing it is not an indicator. If that exceeds `span` screens the window becomes
    /// exactly `span` screens, positioned to centre the viewport and **clamped inside the content**, so
    /// the ends of a long strip pin the window and let the indicator travel to them instead.
    static func shownWindow(settings: PreviewGuideSettings, working: Rect, strip: Rect) -> (minX: Double,
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
