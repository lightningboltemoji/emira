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
}

/// What a setting demonstrates: a set, and optionally a script over it.
public struct Take: Sendable, Equatable {
    /// The arrangement the take starts from, and returns to at the end of every loop.
    public let scene: Scene
    /// The script, as `(time, beat)` pairs in seconds from the start of a loop. Empty for a setting that
    /// is demonstrated by its geometry alone.
    public let beats: [(at: Double, beat: Beat)]
    /// How long one loop runs before starting over. Ignored when `beats` is empty.
    public let period: Double

    public init(scene: Scene, beats: [(at: Double, beat: Beat)] = [], period: Double = 0) {
        self.scene = scene
        self.beats = beats
        self.period = period
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
        let phase = t.truncatingRemainder(dividingBy: period)
        let wrapped = phase < 0 ? phase + period : phase
        return beats.filter { $0.at <= wrapped }
            .reduce(scene) { $1.beat.applied(to: $0) }
    }

    public static func == (lhs: Take, rhs: Take) -> Bool {
        lhs.scene == rhs.scene && lhs.period == rhs.period
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
