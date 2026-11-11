import CoreGraphics
import EmiraMotion

// The wordmark's loop as numbers: where every window is at an instant. A port of `.github/logo/scene.ts`,
// which stays the design tool and renders the README's copy; `WordmarkSceneTests` holds the two to
// agreement through the golden `bun run ship` writes. Change one and you change both.
//
// Motion is emira's spring in closed form, so any instant is exact and none depends on the frames before it.

enum WordmarkScene {

    enum Letter: CaseIterable, Sendable { case e, m, i, r, a }

    /// The canvas, in points, y down.
    static let size = CGSize(width: 472, height: 136)

    /// One window as drawn: its rect, corners and opacity, and its glyph — the baseline's left end, and
    /// points per x-height.
    struct Window: Equatable, Sendable {
        var letter: Letter
        var rect: CGRect
        var cornerRadius: Double
        var opacity: Double
        var glyphOrigin: CGPoint
        var glyphScale: Double
    }

    /// Every window `t` seconds into the loop, in the order they draw: the focused one last, so a window
    /// moving past its neighbour passes over it.
    static func windows(at t: Double) -> [Window] {
        let t = wrap(t)
        let index = timeline.lastIndex { $0.start <= t } ?? 0
        let step = timeline[index]
        let moving = advance(starts[index], toward: step.target, by: t - step.start)
        let order = Letter.allCases.filter { $0 != step.strip.focus } + [step.strip.focus].compactMap(\.self)
        return order.map { drawn($0, moving[$0]!.at) }
    }

    /// How long the loop runs before it starts again, in seconds.
    static let duration = script.reduce(0) { $0 + $1.hold }

    // MARK: - Look

    private static let xHeight = 40.0             // a letter's x-height at rest
    private static let windowHeight = 104.0
    private static let columnGap = 8.0
    private static let windowGap = 6.0            // between windows stacked in one column
    private static let padX = 16.0                // either side of a letter, at rest
    private static let padY = 14.0
    private static let radius = 9.0
    private static let unfocusedOpacity = 0.32

    // MARK: - The loop

    private enum Command {
        case rest
        case focus(Letter?)
        case resize(Double)
        case move(Int)
        case consume(Int)
        case expel(Int)
    }

    private struct Step {
        var hold: Double
        var command: Command
    }

    /// Each step happens, then `hold` seconds pass before the next. The last leaves the strip as the first
    /// found it, and holds long enough for the spring to land.
    private static let script: [Step] = [
        Step(hold: 1.6, command: .rest),
        Step(hold: 0.75, command: .focus(.e)),
        Step(hold: 0.55, command: .focus(.m)),          // focus right
        Step(hold: 0.75, command: .resize(+40)),        // grow
        Step(hold: 0.6, command: .resize(-40)),         // shrink
        Step(hold: 0.55, command: .focus(.i)),          // focus right
        Step(hold: 0.75, command: .move(+1)),           // move-window right
        Step(hold: 0.6, command: .move(-1)),            // move-window left
        Step(hold: 0.55, command: .focus(.r)),          // focus right
        Step(hold: 1.0, command: .consume(-1)),         // consume-or-expel left
        Step(hold: 0.6, command: .expel(+1)),           // consume-or-expel right
        Step(hold: 0.7, command: .focus(nil)),          // unfocus
    ]

    /// Gentler than emira's default of 800: nobody has learned to read this one yet.
    private static let spring = SpringParams.critical(frequency: 320.0.squareRoot())

    // MARK: - Layout

    private struct Column {
        var width: Double
        var windows: [Letter]
    }

    private struct Strip {
        var columns: [Column]
        var focus: Letter?
    }

    /// Each window's width at rest: its letter plus padding, in whole points so the still is crisp.
    private static let restWidth: [Letter: Double] = Dictionary(uniqueKeysWithValues: Letter.allCases.map {
        ($0, (Glyph.width($0) * xHeight + 2 * padX).rounded())
    })

    /// The `e`'s left edge: where it sits when the word is centred, and where it stays.
    private static let origin = CGPoint(
        x: (size.width - (Letter.allCases.reduce(0) { $0 + restWidth[$1]! } + columnGap * 4)) / 2,
        y: (size.height - windowHeight) / 2)

    private static func apply(_ command: Command, to strip: Strip) -> Strip {
        var next = strip
        if case .focus(let letter) = command { next.focus = letter }
        guard let focus = next.focus,
              let at = next.columns.firstIndex(where: { $0.windows.contains(focus) }) else { return next }
        switch command {
        case .rest, .focus:
            break
        case .resize(let delta):
            next.columns[at].width += delta
        case .move(let by):
            next.columns.swapAt(at, at + by)
        case .consume(let from):
            next.columns[at + from].windows.append(focus)
            next.columns[at + from].width = max(next.columns[at + from].width, next.columns[at].width)
            next.columns.remove(at: at)
        case .expel(let to):
            next.columns[at].windows.removeAll { $0 == focus }
            next.columns[at].width = next.columns[at].windows.map { restWidth[$0]! }.max()!
            next.columns.insert(Column(width: restWidth[focus]!, windows: [focus]), at: at + (to > 0 ? 1 : 0))
        }
        return next
    }

    /// Every window's rect and opacity: the values the spring animates.
    private struct Pose {
        var x, y, w, h, opacity: Double
        static var components: [WritableKeyPath<Pose, Double>] { [\.x, \.y, \.w, \.h, \.opacity] }
        static let still = Pose(x: 0, y: 0, w: 0, h: 0, opacity: 0)
    }

    private static func place(_ strip: Strip) -> [Letter: Pose] {
        var poses: [Letter: Pose] = [:]
        var x = origin.x
        for column in strip.columns {
            let n = Double(column.windows.count)
            let h = (windowHeight - windowGap * (n - 1)) / n
            for (i, letter) in column.windows.enumerated() {
                let lit = strip.focus == nil || strip.focus == letter
                poses[letter] = Pose(x: x, y: origin.y + Double(i) * (h + windowGap), w: column.width, h: h,
                                     opacity: lit ? 1 : unfocusedOpacity)
            }
            x += column.width + columnGap
        }
        return poses
    }

    // MARK: - Timeline

    private struct Timed {
        var start: Double
        var strip: Strip
        var target: [Letter: Pose]
    }

    private static let timeline: [Timed] = {
        var strip = Strip(columns: Letter.allCases.map { Column(width: restWidth[$0]!, windows: [$0]) },
                          focus: nil)
        var start = 0.0
        return script.map { step in
            strip = apply(step.command, to: strip)
            defer { start += step.hold }
            return Timed(start: start, strip: strip, target: place(strip))
        }
    }()

    private struct Moving {
        var at: Pose
        var velocity: Pose
    }

    /// Each step retargets every value, carrying position *and* velocity across, so a step that lands
    /// before the last has settled bends the motion instead of restarting it.
    private static func advance(_ moving: [Letter: Moving], toward target: [Letter: Pose],
                                by dt: Double) -> [Letter: Moving] {
        var out = moving
        for (letter, var next) in moving {
            for component in Pose.components {
                let step = Spring.step(current: next.at[keyPath: component],
                                       velocity: next.velocity[keyPath: component],
                                       target: target[letter]![keyPath: component],
                                       params: spring, dt: dt)
                next.at[keyPath: component] = step.current
                next.velocity[keyPath: component] = step.velocity
            }
            out[letter] = next
        }
        return out
    }

    /// What each step starts from, carried forward from the one before.
    private static let starts: [[Letter: Moving]] = {
        let rest = timeline[0].target.mapValues { Moving(at: $0, velocity: .still) }
        var starts = [rest]
        for i in timeline.indices.dropFirst() {
            starts.append(advance(starts[i - 1], toward: timeline[i - 1].target,
                                  by: timeline[i].start - timeline[i - 1].start))
        }
        return starts
    }()

    private static func wrap(_ t: Double) -> Double {
        let t = t.truncatingRemainder(dividingBy: duration)
        return t < 0 ? t + duration : t
    }

    // MARK: - Drawing

    private static func drawn(_ letter: Letter, _ pose: Pose) -> Window {
        let scale = letterScale(letter, w: pose.w, h: pose.h)
        return Window(
            letter: letter,
            rect: CGRect(x: pose.x, y: pose.y, width: pose.w, height: pose.h),
            cornerRadius: min(radius, pose.w / 3, pose.h / 3),
            opacity: min(1, max(0, pose.opacity)),
            glyphOrigin: CGPoint(x: pose.x + (pose.w - Glyph.width(letter) * scale) / 2,
                                 y: pose.y + pose.h / 2 + Glyph.anchor * scale),
            glyphScale: scale)
    }

    /// A letter's size in a window: its rest size, or smaller when the window can't hold that. Padding
    /// gives way first, so a letter shrinks only once the margin is spent.
    private static func letterScale(_ letter: Letter, w: Double, h: Double) -> Double {
        let padX = min(padX, w * 0.18)
        let padY = min(padY, h * 0.12)
        let reach = max(Glyph.top - Glyph.anchor, Glyph.anchor)
        return max(0, min(xHeight, (w - 2 * padX) / Glyph.width(letter), (h / 2 - padY) / reach))
    }
}

// MARK: - Glyphs

extension WordmarkScene {

    /// A letter as ink, in x-height units with y up from the baseline. Monoline: one pen, round at its ends
    /// and its joins, and the `i`'s dot the one thing above the x-height.
    enum Glyph {

        static let stroke = 0.19                          // the pen, in x-heights
        /// The glyph-space height placed at a window's vertical centre — between the x-height's middle
        /// and the box's, so the dot doesn't drag every letter down.
        static let anchor = 0.62
        static let top = dotY + dotRadius

        private static let dotY = 1.32
        private static let dotRadius = 0.125
        private static let bowl = (1 - stroke) / 2        // the e's and the a's radius
        private static let arch = 0.3                     // the m's
        private static let shoulder = 0.38                // the r's
        private static let shoulderEnd = 55 * Double.pi / 180
        private static let cap = 1 - stroke / 2           // the x-height, on the centreline
        private static let base = stroke / 2

        /// The inked width, pen included.
        static func width(_ letter: Letter) -> Double {
            switch letter {
            case .e, .a: 2 * bowl + stroke
            case .m: 4 * arch + stroke
            case .i: stroke
            case .r: stroke / 2 + shoulder + shoulder * cos(shoulderEnd) + stroke / 2
            }
        }

        /// The pen's path, to be stroked `stroke` wide with round caps and joins. Stroked where it is drawn:
        /// `copy(strokingWithWidth:)` bevels the `e`'s join, where a stroke rounds it.
        static func centreline(_ letter: Letter) -> CGPath {
            let x0 = stroke / 2
            let strokes: [CGPath]
            switch letter {
            case .e:
                // The bar, then round from its right end over the top and out at the lower right.
                let cx = x0 + bowl
                strokes = [arc(from: CGPoint(x: cx - bowl, y: 0.5), center: CGPoint(x: cx, y: 0.5), radius: bowl,
                               start: 0, end: 318 * .pi / 180, clockwise: false)]
            case .m:
                strokes = [stem(x: x0)] + [x0, x0 + 2 * arch].map { x in
                    let path = arc(center: CGPoint(x: x + arch, y: cap - arch), radius: arch,
                                   start: .pi, end: 0, clockwise: true)
                    path.addLine(to: CGPoint(x: x + 2 * arch, y: base))
                    return path
                }
            case .i:
                strokes = [stem(x: x0)]
            case .r:
                strokes = [stem(x: x0),
                           arc(center: CGPoint(x: x0 + shoulder, y: cap - shoulder), radius: shoulder,
                               start: .pi, end: shoulderEnd, clockwise: true)]
            case .a:
                let cx = x0 + bowl
                strokes = [arc(center: CGPoint(x: cx, y: 0.5), radius: bowl, start: 0, end: 2 * .pi,
                               clockwise: false),
                           stem(x: cx + bowl)]
            }
            let path = CGMutablePath()
            for stroke in strokes { path.addPath(stroke) }
            return path
        }

        /// What is filled rather than stroked: the `i`'s dot.
        static func dot(_ letter: Letter) -> CGPath? {
            guard letter == .i else { return nil }
            return CGPath(ellipseIn: CGRect(x: stroke / 2 - dotRadius, y: dotY - dotRadius,
                                            width: 2 * dotRadius, height: 2 * dotRadius), transform: nil)
        }

        /// A stem, from the baseline to the x-height.
        private static func stem(x: Double) -> CGPath {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: base))
            path.addLine(to: CGPoint(x: x, y: cap))
            return path
        }

        /// An arc as a path of its own, led in by a line from `from` if given — never from the arc's own
        /// start, which `addArc` would join with an empty line.
        private static func arc(from: CGPoint? = nil, center: CGPoint, radius: Double, start: Double,
                                end: Double, clockwise: Bool) -> CGMutablePath {
            let path = CGMutablePath()
            if let from { path.move(to: from) }
            path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: clockwise)
            return path
        }
    }
}
