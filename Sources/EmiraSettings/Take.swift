import EmiraCore

// What one setting shows: a `Scene` — the set — plus a script of timed beats over it, looping.
//
// **The script is empty for most settings, and that is the point of splitting the two.** A setting that
// *is* geometry needs no script: `PreviewModel` re-derives frames from the draft on every change, so a
// gap opens under the hand with nothing playing. A script is for settings that are behaviour rather than
// geometry — `focus right` has to happen for `focus.system-events` to mean anything, and a spring with
// nothing to animate shows nothing.
//
// A take is pure and total in `t`: playing to a time gives a `Scene`, and the same time always gives the
// same one. That is what makes the animation testable without a clock and without a window.

/// One scripted action on the mock desktop.
public enum Beat: Sendable, Equatable {
    /// Move focus one column left or right, stopping at the ends.
    case focusLeft, focusRight
    /// Step the focused column to the next width preset. The index runs on unbounded and `PresetCycle`
    /// wraps it at resolution, which is what `cycleWidth` itself does.
    case cycleWidth
    /// Put focus on a particular window — how a take returns to where it started.
    case focus(WindowId)
    /// Put a column back on a particular width preset.
    case widthPreset(Int, column: ColumnId)
    /// Put a column on an explicit width off the ladder, or back on its rung (`nil`) — where a `grow`
    /// and a hand resize leave one. **How a take that starts from an explicit width returns to it**,
    /// which `widthPreset` cannot do: a rung is the draft's number and this one is the take's.
    case widthOverride(PresetSize?, column: ColumnId)
    /// Pin one window to a height rung, or to **auto** (`nil`) — the rung the field cannot spell, where
    /// the stack shares the column evenly. Spelled as a rung rather than as a step because the ladder's
    /// length is the draft's, and the take that walks it is built with the draft in hand.
    case heightPreset(Int?, window: WindowId)
    /// Look somewhere else. The camera is furniture, so this travels on the window's own curve while
    /// the desktop underneath keeps travelling on the user's springs.
    case camera(Camera)
    /// Send the pointer somewhere over `over` seconds, focus untouched.
    ///
    /// **A hand is not a spring**, so this travels at its own pace on its own arc rather than
    /// being sprung at a target: the model owns the whole path, which is also what lets focus be read
    /// off where the cursor *is* this frame.
    case pointer(PointerAt, over: Double)
    /// The same travel, with focus answering it — **the pointer as the actor**. Focus lands on whatever
    /// window the cursor is inside, frame by frame, so the ring transfers on the seam crossing itself
    /// rather than on the beat that started the move.
    case hover(PointerAt, over: Double)
    /// Take the cursor's shape — a handle announcing itself.
    case cursor(MockPointer.Shape)
    /// Hold the button down, or let it go.
    case press(Bool)
    /// Ask for the cursor to be taken away, or given back. **Asking is not doing** — `mouse.hide` is
    /// what decides, so the same script plays under both rungs and only one of them loses the pointer.
    case hidePointer(Bool)
    /// Put the input badge up, or take it down. What supplies a cause the desktop cannot show.
    case cue(Cue?)
    /// **Something emira did not cause asks for this window.** Whether it lands is
    /// `focus.system-events`' to decide, and the badge answers taken or declined accordingly — which is
    /// the only way a rung that does nothing reads as a refusal rather than as a broken loop.
    case systemFocus(WindowId)
    /// Three fingers drag the strip `screens` working-widths, over `over` seconds. **Direct
    /// manipulation**: the strip tracks the hand 1:1 and does not ease, which is the single most common
    /// way a demo feels fake. `mouse.trackpad-scroll` decides whether it is listened for at
    /// all; `-direction` decides the sign.
    case scrub(screens: Double, over: Double)
    /// The fingers come off. The strip carries a little further and comes to rest — flush against a
    /// column edge under `magnet`, wherever the momentum ran out under `free`.
    case lift
    /// Ask for the flush tick on one viewport edge, or take it away. Granted only where a column edge
    /// really has landed there, so the mark is a fact rather than an annotation.
    case flushMark(Mark.Edge?)
    /// Grow the focused column by a continuous delta — a `SizeDelta`, not a rung, because that is what
    /// `layout.resize-detent` is a setting about.
    case grow(SizeDelta)
    /// **A hand on the focused column's own trailing edge**, carrying it `by` over `over`
    /// seconds. A `SizeDelta` rather than points, for `grow`'s reason: a hand crossing a third of the
    /// screen is a third of *any* screen, where 90 pt is a gesture that shrinks as the display grows.
    /// The cursor tracks it 1:1 and **the neighbours do not move**: the reducer adopts on
    /// release, because the truth plane is the app's main thread and a strip re-tiling under every
    /// intermediate frame would trade writes with the hand. That is not a simplification.
    case dragEdge(by: SizeDelta, over: Double)
    /// Let go. `layout.interactive-resize` decides what the last 500 ms are: the layout taking the size
    /// as its own intent, or emira taking the width back.
    case release
    /// Move a column along the strip — a `move-window`, the one motion that is pure translation and
    /// therefore the only one in which the movement spring is the only spring in the shot.
    case moveColumn(ColumnId, to: Int)
    /// A pause with a cause: `animation.cover = exact` waits for a capture round trip before it can
    /// raise anything, and the wait is one of the two things that setting is a trade between.
    case coverHead
}

/// What a setting demonstrates: a set, where it is looked at from, and optionally a script over it.
public struct Take: Sendable, Equatable {
    /// The arrangement the take starts from, and returns to at the end of every loop.
    public let scene: Scene
    /// Where the camera rests. **A property of the setting rather than of the section** — which is what
    /// makes crossing from one row to the next a pan, and the pan the difference between the two.
    public let camera: Camera
    /// A mark the mock draws to make an otherwise invisible value legible, or `nil` — which is
    /// almost always, because geometry is its own picture.
    public let mark: Mark?
    /// Whether the focus ring is drawn. **It is a claim that focus is part of what this setting is
    /// about**, and six settings on the Layout tab are pure geometry: a gap is the same number whichever
    /// window is focused, so a blue border on one of them is the preview inventing a subject for the eye
    /// to follow. Everywhere else something is visibly acting on a window, and the ring names it.
    public let showsFocus: Bool
    /// The script, as `(time, beat)` pairs in seconds from the start of a loop. Empty for a setting that
    /// is demonstrated by its geometry alone.
    public let beats: [(at: Double, beat: Beat)]
    /// How long one loop runs before starting over. Ignored when `beats` is empty.
    public let period: Double

    public init(scene: Scene, camera: Camera = .wide, mark: Mark? = nil, showsFocus: Bool = true,
                beats: [(at: Double, beat: Beat)] = [], period: Double = 0) {
        self.scene = scene
        self.camera = camera
        self.mark = mark
        self.showsFocus = showsFocus
        self.beats = beats
        self.period = period
    }

    /// The same take framed somewhere else — how a section's set is shared by settings that look at
    /// different parts of it.
    public func looking(_ camera: Camera, marking mark: Mark? = nil) -> Take {
        Take(scene: scene, camera: camera, mark: mark ?? self.mark, showsFocus: showsFocus,
             beats: beats, period: period)
    }

    /// The same script with every beat respaced to `interval`, and a beat of rest on the end.
    ///
    /// **The period is derived from the spring being edited.** A spring dial's take has to show one
    /// complete motion and then stop, whatever the slider says: a slack spring interrupted by the next
    /// beat never arrives, and a stiff one leaves the desktop still for most of the loop. Beats that
    /// share a time stay together, because two things scripted for the same instant are one event.
    public func paced(by interval: Double) -> Take {
        let times = Array(Set(beats.map(\.at))).sorted()
        let slot = Dictionary(uniqueKeysWithValues: times.enumerated().map { ($1, Double($0 + 1) * interval) })
        return Take(scene: scene, camera: camera, mark: mark, showsFocus: showsFocus,
                    beats: beats.map { (slot[$0.at] ?? $0.at, $0.beat) },
                    period: Double(times.count + 1) * interval)
    }

    /// Where the camera stands `t` seconds in: the resting frame, then every camera beat up to `t`.
    public func camera(at t: Double) -> Camera {
        guard !isStatic else { return camera }
        return beats(upTo: t).reduce(camera) { standing, beat in
            if case .camera(let next) = beat.beat { return next }
            return standing
        }
    }

    /// Whether anything happens over time. A static take needs no clock, which is what lets an idle
    /// settings window run no display link.
    public var isStatic: Bool { beats.isEmpty || period <= 0 }

    /// The set as it stands `t` seconds into the take, every beat up to `t` applied in order.
    ///
    /// Total and pure: `t` is wrapped into one loop, so a take played for an hour and a take played for
    /// a second differ only in where in the loop they are. A static take is its own scene at every `t`.
    public func scene(at t: Double) -> Scene {
        guard !isStatic else { return scene }
        return beats(upTo: t).reduce(scene) { $1.beat.applied(to: $0) }
    }

    /// The beats that have fired by `t`, in order, with `t` wrapped into one loop.
    public func beats(upTo t: Double) -> [(at: Double, beat: Beat)] {
        guard !isStatic else { return [] }
        let phase = t.truncatingRemainder(dividingBy: period)
        let wrapped = phase < 0 ? phase + period : phase
        return beats.filter { $0.at <= wrapped }
    }

    public static func == (lhs: Take, rhs: Take) -> Bool {
        lhs.scene == rhs.scene && lhs.camera == rhs.camera && lhs.mark == rhs.mark
            && lhs.showsFocus == rhs.showsFocus && lhs.period == rhs.period
            && lhs.beats.count == rhs.beats.count
            && zip(lhs.beats, rhs.beats).allSatisfy { $0.at == $1.at && $0.beat == $1.beat }
    }
}

extension Beat {
    /// This beat's effect on a set. Every case is total — focusing past the end of the strip stays where
    /// it is, which is what the real `focus right` does at the last column.
    func applied(to scene: Scene) -> Scene {
        switch self {
        case .focusLeft:
            return scene.focusing(neighbour(of: scene, by: -1))
        case .focusRight:
            return scene.focusing(neighbour(of: scene, by: +1))
        case .focus(let id):
            return scene.focusing(id)
        case .cycleWidth:
            guard let column = scene.focusedColumn else { return scene }
            return scene.setting(widthPreset: column.widthPreset + 1, ofColumn: column.id)
        case .widthPreset(let preset, let column):
            return scene.setting(widthPreset: preset, ofColumn: column)
        case .widthOverride(let width, let column):
            return scene.setting(widthOverride: width, ofColumn: column)
        case .heightPreset(let preset, let window):
            return scene.setting(heightPreset: preset, ofWindow: window)
        case .pointer(let at, _), .hover(let at, _):
            return scene.moving { $0.at = at }
        case .cursor(let shape):
            return scene.moving { $0.shape = shape }
        case .press(let down):
            return scene.moving { $0.isPressed = down }
        case .hidePointer(let hidden):
            return scene.moving { $0.isHidden = hidden }
        case .cue(let cue):
            return scene.showing(cue: cue)
        case .flushMark(let showing):
            return scene.showing(flush: showing)
        case .moveColumn(let id, let index):
            return scene.moving(column: id, to: index)
        case .systemFocus, .scrub, .lift, .grow, .dragEdge, .release, .coverHead:
            // Every one of these is a question about the draft — whether the event is honoured, which
            // way it carries, where it comes to rest, where it catches — so `PreviewModel` answers it.
            return scene
        case .camera:
            // The camera is not on the set. `Take.camera(at:)` is the fold that reads these.
            return scene
        }
    }

    /// The hand's travel this beat starts, or `nil` for a beat that is not one.
    var travel: Double? {
        switch self {
        case .pointer(_, let over), .hover(_, let over): return over
        default: return nil
        }
    }

    /// Whether focus is to answer the cursor while this beat's travel is the most recent one — which is
    /// what makes a focus change *the hand's*, and `mouse.follows-focus` has a rung about exactly that.
    var isHover: Bool {
        if case .hover = self { return true }
        return false
    }

    /// Whether this beat moves focus by itself — a command, which is the other kind of focus change.
    var isCommandedFocus: Bool {
        switch self {
        case .focus, .focusLeft, .focusRight: return true
        default: return false
        }
    }

    /// Whether this beat rearranges the desktop — **which is what raises the guide**, exactly as the
    /// daemon raises one. The guide's whole life cycle is then on screen every few seconds, and the
    /// cause-and-effect of picking a style and watching one start arriving is the best thing in the
    /// section.
    var movesTheDesktop: Bool {
        switch self {
        case .focus, .focusLeft, .focusRight, .cycleWidth, .widthPreset, .widthOverride, .heightPreset,
             .moveColumn, .grow, .scrub, .systemFocus, .dragEdge:
            return true
        default:
            return false
        }
    }

    /// The window focus lands on `step` columns away — the first window of that column, which is where
    /// a column-wise focus change puts it. Clamped at both ends.
    private func neighbour(of scene: Scene, by step: Int) -> WindowId {
        guard let index = scene.columnIndex(ofWindow: scene.focus) else { return scene.focus }
        let next = min(max(index + step, 0), scene.columns.count - 1)
        return scene.columns[next].windows.first?.id ?? scene.focus
    }
}
