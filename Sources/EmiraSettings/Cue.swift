import EmiraCore

// **Motion has a cause on screen.** Nothing on the mock moves because a timer fired: a window
// moves because focus moved, and focus moved because a key was pressed or a pointer crossed a seam.
// Where the cause is off-screen — a chord, a swipe — this is what supplies it.
//
// Four settings are about *where an event came from*, and the desktop cannot show that on its own.
// `focus.system-events` is meaningless without `⌘⇥`, and `trackpad-scroll-direction` is **entirely** the
// relation between the direction of the fingers and the direction of the strip.
//
// **It names the cause, never narrates the effect**, and it is up only for a beat whose cause is
// off-screen. A cause emira itself acted on is spelled as the **command** — `focus right`, the exact
// text a `[keys]` binding takes — because the verb is what the beat is about and a chord is a fact about
// one user's keyboard. A cause emira did not act on has no command to name, so it keeps the chord.
//
// And it has two states, because a refusal has to read as a refusal rather than as a broken animation.

/// The badge at the low centre of the mock: what the user did, and whether it was honoured.
public struct Cue: Sendable, Equatable {

    /// What the input was.
    public enum Glyph: Sendable, Equatable {
        /// An emira command, spelled the way the config file spells one — `focus right`.
        ///
        /// **The verb, not the chord**, because a binding is one user's. Text rather than a `Command`
        /// because the fence keeps that name out of this module; `CueTests` parses every one back.
        case command(String)
        /// A chord, spelled the way a keycap spells one — `⌘⇥`.
        ///
        /// For a cause **emira did not act on**, which therefore has no command to name — the whole of
        /// what `focus.system-events` is about.
        case keys(String)
        /// Three contacts on a trackpad, and which way the fingers went.
        ///
        /// **The arrow never flips.** What flips is the strip: you cannot change which way you swiped,
        /// only what it does, so fixing the hand and flipping the world is the right way round.
        case swipe(Direction)
    }

    public enum Direction: Sendable, Equatable { case left, right }

    /// Whether the desktop did what was asked.
    public enum Answer: Sendable, Equatable {
        case taken
        /// Dimmed, and the reason the cue exists at all for a rung that does nothing: a desktop that
        /// simply fails to move is indistinguishable from a preview that is broken.
        case declined
    }

    public var glyph: Glyph
    public var answer: Answer

    public init(_ glyph: Glyph, answer: Answer = .taken) {
        self.glyph = glyph
        self.answer = answer
    }

    /// An input, taken. What a beat scripts before the model has decided whether it lands.
    public static func command(_ spelling: String) -> Cue { Cue(.command(spelling)) }
    public static func keys(_ spelling: String) -> Cue { Cue(.keys(spelling)) }
    public static func swipe(_ direction: Direction) -> Cue { Cue(.swipe(direction)) }
}

/// A window emira does not place: over the strip, off the ladder, wherever its app put it.
///
/// The set for `focus.system-events` needs one, because the `ignore` rung's whole content is "focus onto
/// a window emira does not place is still honoured" — and a set without a float cannot say so.
public struct MockFloat: Sendable, Equatable {
    public let window: MockWindow
    /// Its frame as fractions of the working area, so a scripted float lands in the same place on any
    /// display.
    public let at: Rect

    public init(window: MockWindow, at: Rect) {
        self.window = window
        self.at = at
    }

    /// Where it is, in true points.
    public func frame(in workingArea: Rect) -> Rect {
        Rect(x: workingArea.minX + workingArea.width * at.minX,
             y: workingArea.minY + workingArea.height * at.minY,
             width: workingArea.width * at.width,
             height: workingArea.height * at.height)
    }
}
