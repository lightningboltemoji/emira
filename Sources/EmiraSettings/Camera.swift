import EmiraCore
import EmiraMotion

// **Legibility is bought with the camera, never with a lie.** Where something true to scale is too small
// to read — a 2 pt gap, a 20 pt cursor — the mock looks closer at it. Nothing is ever drawn larger than
// it is: what changes is the rect of the display the slab shows, and every dimension inside it scales
// together, so a title bar and a shadow stay a real window's at every framing.
//
// **Life size is the ceiling**, and `maximumScale` is where that rule stops being a resolution and starts
// being arithmetic: a camera may go no closer than one mock point to one real point. A gap is a length the
// user is judging by eye, so at that cap the number in the field is the thing on the screen, exactly.
//
// A camera is **a property of the setting**, not of the section. That is what buys the nicest detail
// there is for nothing: crossing from `column-gap` to `window-gap` pans from a vertical seam to a
// horizontal one, and the pan *is* the difference between the two settings.
//
// Two rules it never breaks. **A shot contains, whole, the object the value is measured against** — both
// windows for a gap, the screen's edges for an outer gap — so the frame only ever *grows* to the
// display's aspect and never crops to it. And it travels on **the window's own fixed curve**, never on
// the user's springs: a sludgy `movement.stiffness` must not be able to hide behind an equally sludgy
// lens.

/// What the mock is looking at. Resolved against the set as it stands, so a camera framing "the focused
/// column" follows focus without anything being recomputed by hand.
public enum Camera: Sendable, Equatable {

    /// The whole display. Most takes rest here, and every take that is about the screen's own edges
    /// stays here — a frame that lost them would lose the setting.
    case wide

    /// The focused column with `slack` of its own width to spare each side, at one whole window's
    /// height. Both of the column's seams are in frame with a window against each of them, which is what
    /// makes a stripe of wallpaper between two columns readable as a number.
    case seams(slack: Double)

    /// The focused column, all of it. A column is full height, so this is very nearly the display —
    /// which is the honest framing for a value measured against the whole column: a height rung, or a
    /// width the artifact of a stretch is read against.
    case stack

    /// The seam **inside** the focused column, at one window's height centred on it: the facing halves
    /// of the two stacked windows, and the gap between them across its whole width.
    ///
    /// **`seams` read the other way round**, and deliberately: the object a gap is measured against is
    /// the two edges it holds apart, not the two windows they belong to — which is already how the shot
    /// between two columns is framed, at one window's height with the neighbours cut off. Both gaps then
    /// rest at the same push-in, and crossing the two rows is one lens turning through a right angle.
    /// A column of one has no seam, and the whole column is the honest answer there.
    case stackSeam

    /// One guide's own panel, and nothing around it — close enough to read a tile or a word.
    /// **Per style**, because a lens that framed "the guide" would push in on the minimap while the user
    /// was editing the names row. `maximumScale` decides how close the shot ends up; a margin here would
    /// be a second framing rule overriding that one.
    case guidePanel(GuideStyle)

    /// One guide **and the two working-area edges it is inset from**, because those two edges are what
    /// its `gap` is measured from and a frame that lost them would lose the setting.
    case guideCorner(GuideStyle)

    /// The rect the frame must contain, in true display points, or `nil` for the whole display.
    func subject(of state: PreviewState) -> Rect? {
        switch self {
        case .wide:
            return nil
        case .seams(let slack):
            guard let column = state.focusedColumnFrame, let window = state.focusFrame else { return nil }
            let margin = column.width * slack
            return Rect(x: column.minX - margin, y: window.minY,
                        width: column.width + margin * 2, height: window.height)
        case .stack:
            return state.focusedColumnFrame
        case .stackSeam:
            guard let column = state.focusedColumnFrame, let seam = state.stackSeam,
                  let window = state.focusFrame else { return state.focusedColumnFrame }
            return Rect(x: column.minX, y: seam.midY - window.height / 2,
                        width: column.width, height: window.height)

        case .guidePanel(let style):
            return state.guide(style)?.panel

        case .guideCorner(let style):
            guard let panel = state.guide(style)?.panel else { return nil }
            let area = state.workingArea
            // The corner the panel is nearest — the two edges the gap is measured from. Stretched to
            // rather than unioned with, because `Rect.union` ignores an empty operand by design.
            let corner = Point(x: panel.midX < area.midX ? area.minX : area.maxX,
                               y: panel.midY < area.midY ? area.minY : area.maxY)
            return Rect(x: min(panel.minX, corner.x), y: min(panel.minY, corner.y),
                        width: abs(max(panel.maxX, corner.x) - min(panel.minX, corner.x)),
                        height: abs(max(panel.maxY, corner.y) - min(panel.minY, corner.y)))
        }
    }

    /// How close this camera may ever go, as a **scale**: `1` is life size, one mock point drawn for one
    /// real point.
    ///
    /// **Life size is the ceiling, and that is "nothing is drawn larger than it is" as arithmetic rather
    /// than as a resolution.** A setting whose value is a length in points is one the user is judging by
    /// eye — that is the entire job of the preview — and a lens 4% closer than life is a ruler that lies
    /// by 4%. At the cap a 40 pt gap is drawn at 40 points, and the number in the field is the thing on
    /// the screen.
    var maximumScale: Double {
        switch self {
        case .guidePanel(.preview):
            // **The one framing allowed closer than life, and it is allowed because nothing read at it
            // is a length.** `content` is what a tile draws and `span` is how many there are; a tile at
            // life size is a few points across and neither choice is legible. `gap` *is* points, and it
            // is framed by `guideCorner`, which keeps the cap.
            return Self.readable
        case .guidePanel(.names):
            // …and the names guide is the reason that clause is not a licence. Everything read on it is
            // **type**, and type is a length: at the cap `font-size = 12` draws twelve points.
            return 1
        case .wide, .seams, .stack, .stackSeam, .guideCorner:
            return 1
        }
    }

    /// How far past life size the guide's own panel may be magnified. Enough to tell an icon from a
    /// still and eight tiles from three, and no more — past this the mock stops being a desktop and
    /// starts being a diagram.
    static let readable: Double = 1.6

    /// The frame this camera asks for, given the set as it stands and the scale the slab draws at.
    public func frame(of state: PreviewState, in projection: Projection) -> Rect {
        Self.frame(containing: subject(of: state), display: projection.displayFrame,
                   lifeSize: projection.lifeSizeWidth, maximumScale: maximumScale)
    }

    /// The nearest thing to `subject` that is the display's own shape, inside the display, and no closer
    /// than `maximumScale` — `lifeSize` being the frame width at which one mock point is one real point.
    ///
    /// **It grows and never crops.** The subject is what the value on screen is measured against, so a
    /// frame that trimmed it to an aspect ratio would be answering a different question — and it is why
    /// a full-height subject lands on very nearly the whole display rather than on a tall slot. The
    /// ceiling only ever widens the frame further, so it can never cost the subject either.
    static func frame(containing wanted: Rect?, display: Rect,
                      lifeSize: Double, maximumScale: Double = 1) -> Rect {
        guard let wanted, !display.size.isEmpty else { return display }
        // Only what is on the display can be framed, and a subject running off the edge is ordinary:
        // `seams` adds slack past the last column, and a set deliberately parks one half off the right.
        // Clipping first is also what keeps the frame centred on the part there is to look at.
        guard let subject = wanted.intersection(display), !subject.size.isEmpty else { return display }
        let aspect = display.width / display.height

        var width = max(subject.width, subject.height * aspect)
        width = max(width, lifeSize / max(maximumScale, 1e-9))
        width = min(width, display.width)
        let height = min(width / aspect, display.height)
        // The height clamp can only have shortened the frame, which would crop; widening back keeps the
        // shape and the containment together.
        let fitted = Size(width: max(width, height * aspect), height: height)

        // Centred on the subject, then slid back inside the display — a frame half off the panel would
        // show the bezel from the inside.
        let x = min(max(subject.midX - fitted.width / 2, display.minX), display.maxX - fitted.width)
        let y = min(max(subject.midY - fitted.height / 2, display.minY), display.maxY - fitted.height)
        return Rect(x: x, y: y, width: fitted.width, height: fitted.height)
    }
}

/// What the mock draws where the geometry alone would show nothing.
///
/// **The only non-geometric mark in the window**, and it earns its place on empty ground: at
/// `outer-gap = 0` there is literally nothing to see, so a row of four numbers has to say which edge it
/// is talking about before anything has been typed.
public enum Mark: Sendable, Equatable {
    /// One outer gap, as the band of desktop it holds open.
    case outerGap(Edge)

    public enum Edge: String, Sendable, Equatable, CaseIterable {
        case top, left, bottom, right
    }

    /// The mark this frame, in true points — which of the two, and where. The two are drawn
    /// differently and the view is what knows how, so the fact and its ink stay apart.
    public enum Drawn: Sendable, Equatable {
        /// **The gutter itself**, filled: from the working area's own edge to where content starts, the
        /// whole length of that side. The band *is* the number, so it needs no legend — and at `0` it is
        /// a hairline, because the gutter is, which is what makes the row legible before anything has
        /// been typed.
        case gutter(Rect)
        /// A short accent stroke on the viewport edge a column edge has just landed on.
        case flush(Rect)

        public var rect: Rect {
            switch self {
            case .gutter(let rect), .flush(let rect): return rect
            }
        }
    }

    /// **The flush tick**: a short accent stroke on the viewport edge a column edge has just landed on.
    /// Short rather than full height, because it is a tick — the claim is about one coincidence and not
    /// about the whole seam.
    static func flushTick(on edge: Edge, contentArea: Rect) -> Rect {
        Rect(x: edge == .right ? contentArea.maxX : contentArea.minX,
             y: contentArea.maxY - tickLength, width: 0, height: tickLength)
    }

    /// How long a tick is, in true points.
    static let tickLength: Double = 56

    /// The band this gap holds open, in true points — zero-thickness at `0`, which the view gives a
    /// point to.
    ///
    /// **The whole length of its own side**, not the content's: an outer gap is measured from the
    /// screen's edge, so the margin it opens runs corner to corner. The four bands overlap at the
    /// corners and never appear together, because the row is four controls and only the one under the
    /// hand is marked.
    func band(workingArea: Rect, gaps: EdgeInsets) -> Rect {
        let area = workingArea
        switch self {
        case .outerGap(.top):
            return Rect(x: area.minX, y: area.minY, width: area.width, height: gaps.top)
        case .outerGap(.bottom):
            return Rect(x: area.minX, y: area.maxY - gaps.bottom, width: area.width,
                        height: gaps.bottom)
        case .outerGap(.left):
            return Rect(x: area.minX, y: area.minY, width: gaps.left, height: area.height)
        case .outerGap(.right):
            return Rect(x: area.maxX - gaps.right, y: area.minY, width: gaps.right,
                        height: area.height)
        }
    }
}

/// The camera as it is right now: four scalars travelling to the frame the take asks for.
///
/// A *position* animator rather than `RectAnimator`'s displacement, because a camera has somewhere it is
/// rather than a distance it is behind — and because retargeting mid-pan must keep the speed, which is
/// what makes crossing three rows in a second read as one move of the lens.
struct CameraTravel: Sendable, Equatable {

    /// **Critically damped, and settled in the 380 ms the house style names.** Remaining distance is
    /// `D(1 + ωt)e^(−ωt)`, so a settle is `u/ω` where `(1 + u)e^(−u) = ε/D`; at half a point over a
    /// 900 pt pan, `u ≈ 9` and `ω = 9/0.38 ≈ 23.7`, which is `k ≈ 560`.
    static let curve = SpringParams(stiffness: 560, dampingRatio: 1)

    private var x: Animator
    private var y: Animator
    private var width: Animator
    private var height: Animator

    init(_ frame: Rect) {
        x = Animator(value: frame.minX, params: Self.curve)
        y = Animator(value: frame.minY, params: Self.curve)
        width = Animator(value: frame.width, params: Self.curve)
        height = Animator(value: frame.height, params: Self.curve)
    }

    var current: Rect {
        Rect(x: x.current, y: y.current, width: width.current, height: height.current)
    }

    mutating func retarget(to frame: Rect) {
        x.retarget(to: frame.minX)
        y.retarget(to: frame.minY)
        width.retarget(to: frame.width)
        height.retarget(to: frame.height)
    }

    mutating func snap(to frame: Rect) {
        x.snap(to: frame.minX)
        y.snap(to: frame.minY)
        width.snap(to: frame.width)
        height.snap(to: frame.height)
    }

    mutating func advance(by dt: Double) {
        x.advance(by: dt)
        y.advance(by: dt)
        width.advance(by: dt)
        height.advance(by: dt)
    }

    /// Half a point, as the desktop's own animators use — the camera is in true points like everything
    /// else, and an unsettled one is a reason to keep the display link running.
    func isSettled(epsilon: Double = 0.5, velocityEpsilon: Double = 0.5) -> Bool {
        x.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon)
            && y.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon)
            && width.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon)
            && height.isSettled(epsilon: epsilon, velocityEpsilon: velocityEpsilon)
    }
}
