import AppKit
import EmiraCore

// Turning a press into a chord.
//
// **A local `NSEvent` monitor, installed only while listening** — the discipline `applyShellConfig`
// keeps for the pointer monitor and the gesture tap, and for the same reason: a recorder that outlived
// the recording would be eating keystrokes the panel never asked for. It crosses no new boundary; a
// local monitor sees what is already routed to this app, including the fn chords the Carbon registry
// cannot express.
//
// It runs *before* the event is dispatched, which is the whole of why it can be the control: `⏎` and
// `⎋` are both bindable keys in the vocabulary and both are already owned by the panel
// (`save.keyEquivalent`, `ScrimWindow.cancelOperation`). Returning `nil` takes the press from them, so
// escape **records** escape — and cancelling a recording is a second click on the bubble, or a click
// somewhere else.
//
// **What it cannot see is what the window server ate first.** `⌘Space`, `⌃↑`, `⌘⇥` and `⌘⇧4` never
// reach a local monitor at all, so the honest tell is their shape: modifiers held and let go with no
// key in between. That is `.systemHeld`, and it is the only thing v1 says about a chord that will never
// fire (see the change's Observations).

/// A keystroke recorder for one chord.
@MainActor
final class ChordRecorder {

    /// What one keyboard event amounted to.
    enum Reading: Equatable {
        /// A chord the vocabulary can name and the file can carry.
        case chord(KeyChord)
        /// A key emira has no name for — a media key, the keypad, `fn` itself. **Refused by name**
        /// rather than dropped: a recorder that ignored a press looks broken, and the user pressed
        /// something.
        case unnameable(keyCode: UInt16)
        /// Modifiers pressed and released with nothing between them, which is what a chord the window
        /// server owns looks like from in here.
        case systemHeld(KeyModifiers)

        /// What to say when this is not a chord, or `nil` when it is.
        var refusal: String? {
            switch self {
            case .chord:
                return nil
            case .unnameable:
                return "emira has no name for that key."
            // **A possibility, not a verdict.** From in here a chord the window server ate and a hand
            // that let go without pressing anything are the same two events in the same order, so a
            // sentence that named the first as fact would be wrong every time it was the second.
            case .systemHeld:
                return "Nothing arrived — macOS may already own that combination."
            }
        }
    }

    /// The reading of a press, **with no event in it** — so every branch is testable without an event
    /// to synthesize, the split `ScrollFade` already keeps between the arithmetic and the layer code.
    ///
    /// **The fn flag is stripped from a function-class key**, and this is the subtlest line in the
    /// feature: macOS marks the arrows, the F-keys and home/end/page-up/page-down with the fn flag
    /// whether or not fn is held. A recorder reading `modifierFlags` naively turns a bare `←` into
    /// `fn-left`, which `KeyChordSyntaxError.functionCannotQualify` exists to refuse — so the file would
    /// reject a chord the user pressed correctly.
    static func read(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Reading {
        guard let key = Key(virtualKeyCode: keyCode) else { return .unnameable(keyCode: keyCode) }
        var modifiers = self.modifiers(flags)
        if key.isFunctionClass { modifiers.remove(.function) }
        return .chord(KeyChord(modifiers, key))
    }

    /// The five modifiers emira names, out of AppKit's word. Everything else it carries — caps lock, the
    /// numeric keypad, which side the key was on — is not something a binding can say.
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.command)  { modifiers.insert(.command) }
        if flags.contains(.option)   { modifiers.insert(.option) }
        if flags.contains(.control)  { modifiers.insert(.control) }
        if flags.contains(.shift)    { modifiers.insert(.shift) }
        if flags.contains(.function) { modifiers.insert(.function) }
        return modifiers
    }

    /// Whether a monitor is installed — what makes `start` idempotent and `stop` safe to call twice.
    private(set) var isListening = false
    private var monitor: Any?
    /// The modifiers seen down since the last time they were all up. Compared against `tookKey` to spot
    /// a combination that came and went with no press in it.
    private var held: KeyModifiers = []
    /// Whether a key arrived while those modifiers were down.
    private var tookKey = false

    /// Start listening. `onReading` gets every press until `stop()`, including the refusals — a recorder
    /// that answered only the presses it liked would look broken on the ones it didn't.
    func start(_ onReading: @escaping @MainActor (Reading) -> Void) {
        guard !isListening else { return }
        isListening = true
        held = []
        tookKey = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self else { return event }
            return self.take(event, reporting: onReading)
        }
    }

    /// Stop listening and take the monitor back out. Idempotent.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isListening = false
        held = []
        tookKey = false
    }

    /// Isolated, because taking the monitor out is main-actor work and a recorder released while it is
    /// still listening would otherwise leave one installed for the life of the process.
    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// A press arrived: what it amounts to. Separate from the monitor so every branch can be reached
    /// without an event to synthesize.
    func keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Reading {
        tookKey = true
        return Self.read(keyCode: keyCode, flags: flags)
    }

    /// The modifiers the window server builds its own chords with. A bare `⌥` or `⇧` pressed and let go
    /// is somebody hesitating over the keyboard — the commonest thing to do while deciding what to bind
    /// — and every combination macOS keeps carries one of these two.
    static let reserved: KeyModifiers = [.command, .control]

    /// The modifiers moved. `.systemHeld` when a combination macOS could plausibly own came and went
    /// with no key in it, and `nil` otherwise — most flag changes are somebody halfway through a chord.
    ///
    /// The modifiers are **accumulated** rather than read off the last word: letting go of `⌘⇧` sends
    /// `⇧` and then nothing, so the last non-empty word is not the combination that was built.
    func flagsChanged(_ flags: NSEvent.ModifierFlags) -> Reading? {
        let now = Self.modifiers(flags)
        guard now.isEmpty else {
            held.formUnion(now)
            return nil
        }
        defer {
            held = []
            tookKey = false
        }
        guard !tookKey, !held.isDisjoint(with: Self.reserved) else { return nil }
        return .systemHeld(held)
    }

    /// One event, and what to hand back to AppKit. `nil` swallows it.
    private func take(_ event: NSEvent, reporting onReading: @MainActor (Reading) -> Void) -> NSEvent? {
        switch event.type {
        case .keyDown:
            onReading(keyDown(keyCode: event.keyCode, flags: event.modifierFlags))
            // Swallowed, which is what lets the bubble take `⏎` and `⎋` from the buttons that own them.
            return nil
        case .flagsChanged:
            // Passed through: what the recorder claims is the press, and AppKit tracks the modifier
            // state off these.
            if let reading = flagsChanged(event.modifierFlags) { onReading(reading) }
            return event
        default:
            return event
        }
    }
}
