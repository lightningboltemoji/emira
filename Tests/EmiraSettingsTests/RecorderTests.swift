import AppKit
import Testing
import EmiraCore
@testable import EmiraSettings

// The recorder's decision, which is a pure function and is therefore the whole of what a suite can
// reach. What it cannot: whether the monitor is installed at the right moments, and whether a chord it
// recorded actually fires after a save — both want the daemon running.
//
// The one line here worth the file is the fn strip. macOS marks the arrows, the F-keys and
// home/end/page-up/page-down with the fn flag whether or not fn is held, so a recorder that trusted
// `modifierFlags` would compose `fn-left` out of a bare left arrow — and `[keys]` refuses that by name.

@MainActor
@Suite struct RecorderTests {

    static func read(_ key: Key, _ flags: NSEvent.ModifierFlags) -> ChordRecorder.Reading {
        ChordRecorder.read(keyCode: key.virtualKeyCode, flags: flags)
    }

    static func chord(_ key: Key, _ flags: NSEvent.ModifierFlags) throws -> KeyChord {
        guard case .chord(let chord) = read(key, flags) else {
            throw ReadingIsNotAChord(reading: read(key, flags))
        }
        return chord
    }

    struct ReadingIsNotAChord: Error { let reading: ChordRecorder.Reading }

    // The ordinary press

    @Test func aModifiedLetterIsTheChordItLooksLike() throws {
        #expect(try Self.chord(.h, [.option]) == KeyChord([.option], .h))
        #expect(try Self.chord(.h, [.command, .option]) == KeyChord([.command, .option], .h))
        // Spelled the canonical way whichever order the flags arrived in.
        #expect(try Self.chord(.h, [.option, .command]).description == "alt-cmd-h")
    }

    /// An unmodified key is a chord — `f13` alone is a legitimate binding, which is what the empty
    /// modifier set means.
    @Test func anUnmodifiedKeyIsStillAChord() throws {
        #expect(try Self.chord(.f13, []) == KeyChord([], .f13))
    }

    /// Everything AppKit carries that a binding cannot say is dropped: caps lock, the keypad flag,
    /// which side of the keyboard the modifier was on.
    @Test func flagsABindingCannotSayAreDropped() throws {
        #expect(try Self.chord(.h, [.option, .capsLock, .numericPad]) == KeyChord([.option], .h))
    }

    // The fn strip

    /// **The subtlest line in the feature.** Every function-class key, pressed bare, arrives with the
    /// fn flag set — and `fn` on one of them is refused by `KeyChord.parse`, so a recorder that kept it
    /// would hand the file a chord it will not read back.
    @Test func theFunctionFlagIsStrippedFromEveryFunctionClassKey() throws {
        for key in Key.allCases where key.isFunctionClass {
            let chord = try Self.chord(key, [.function])
            #expect(chord == KeyChord([], key), "\(key.rawValue) kept its fn flag")
            // …and the proof it matters: the spelling has to parse back.
            #expect(try KeyChord.parse(chord.description) == chord)
        }
    }

    /// The strip is only ever the fn bit — the real modifiers held alongside it survive.
    @Test func strippingFnKeepsTheModifiersHeldWithIt() throws {
        #expect(try Self.chord(.left, [.function, .option, .shift])
                == KeyChord([.option, .shift], .left))
    }

    /// …and on a key that is *not* function-class, fn is a modifier like any other. `fn-h` is a legal
    /// binding and the whole reason `SplitHotkeyBinder` exists.
    @Test func fnSurvivesOnAKeyThatIsNotFunctionClass() throws {
        #expect(try Self.chord(.h, [.function]) == KeyChord([.function], .h))
        #expect(try Self.chord(.space, [.function]) == KeyChord([.function], .space))
    }

    // The two refusals

    /// A key with no name is refused rather than dropped: the user pressed something, and a recorder
    /// that sat there looks broken.
    @Test func aKeyWithNoNameIsRefusedRatherThanIgnored() {
        // The keypad, a media key, and the fn key itself — none of which `Key` enumerates.
        for code: UInt16 in [0x52, 0x48, 0x3F, 0x39] {
            let reading = ChordRecorder.read(keyCode: code, flags: [])
            #expect(reading == .unnameable(keyCode: code), "\(code) read as \(reading)")
            #expect(reading.refusal != nil)
        }
    }

    /// Every keycode the vocabulary *does* name reads back as itself — the reverse table, exercised
    /// through the thing that spends it. Option rather than nothing, so the chord is a chord.
    @Test func everyNamedKeycodeReadsBackAsItsKey() throws {
        for key in Key.allCases {
            #expect(try Self.chord(key, [.option]) == KeyChord([.option], key))
        }
    }

    // The tell for a chord that will never fire

    /// `⌘Space`, `⌃↑`, `⌘⇥` and `⌘⇧4` never reach a local monitor — the window server takes them first.
    /// What *does* reach it is their shape: modifiers down, modifiers up, no key in between.
    @Test func modifiersHeldAndReleasedWithNoKeyAreTheSystemsOwn() {
        let recorder = ChordRecorder()
        #expect(recorder.flagsChanged([.command]) == nil)
        let reading = recorder.flagsChanged([])

        #expect(reading == .systemHeld([.command]))
        // **Offered as a possibility, not asserted as a fact.** The same two events in the same order
        // are also what a hand that let go without pressing anything looks like, and there is nothing
        // in here that can tell them apart — so the sentence must not claim to.
        #expect(reading?.refusal == "Nothing arrived — macOS may already own that combination.")
    }

    /// …and a bare `⌥` or `⇧` let go says **nothing**. Deciding what to bind means resting a hand on the
    /// keyboard, and every combination the window server keeps carries `⌘` or `⌃` — so answering a
    /// hesitation with a diagnostic is answering a question nobody asked.
    @Test func aLoneOptionOrShiftIsAHesitationRatherThanATell() {
        let recorder = ChordRecorder()
        #expect(recorder.flagsChanged([.option]) == nil)
        #expect(recorder.flagsChanged([]) == nil, "an option tap was read as a chord macOS ate")

        #expect(recorder.flagsChanged([.shift]) == nil)
        #expect(recorder.flagsChanged([]) == nil, "a shift tap was read as a chord macOS ate")

        // The reserved pair still tells, held with anything else or alone.
        #expect(recorder.flagsChanged([.option, .command]) == nil)
        #expect(recorder.flagsChanged([]) == .systemHeld([.option, .command]))
    }

    /// A press between them is an ordinary chord, and the tell must not fire after it.
    @Test func aKeyBetweenTheModifiersIsAnOrdinaryChord() {
        let recorder = ChordRecorder()
        #expect(recorder.flagsChanged([.option]) == nil)
        #expect(recorder.keyDown(keyCode: Key.h.virtualKeyCode, flags: [.option])
                == .chord(KeyChord([.option], .h)))
        // …and letting go afterwards is not a second, contradictory answer.
        #expect(recorder.flagsChanged([]) == nil)
    }

    /// The modifiers are accumulated, so `⌘` then `⌘⇧` then nothing reports both — the combination the
    /// user was building, not the last flag word before they let go.
    @Test func theTellNamesEveryModifierThatWasHeld() {
        let recorder = ChordRecorder()
        #expect(recorder.flagsChanged([.command]) == nil)
        #expect(recorder.flagsChanged([.command, .shift]) == nil)
        #expect(recorder.flagsChanged([.command]) == nil)
        #expect(recorder.flagsChanged([]) == .systemHeld([.command, .shift]))
    }

    /// …and the tell does not repeat itself: the next rest is a fresh combination, not the last one
    /// again.
    @Test func theTellFiresOncePerCombination() {
        let recorder = ChordRecorder()
        _ = recorder.flagsChanged([.command])
        #expect(recorder.flagsChanged([]) == .systemHeld([.command]))
        #expect(recorder.flagsChanged([]) == nil)
    }

    // The monitor's lifetime

    @Test func startAndStopAreIdempotent() {
        let recorder = ChordRecorder()
        #expect(!recorder.isListening)
        recorder.start { _ in }
        recorder.start { _ in }
        #expect(recorder.isListening)
        recorder.stop()
        recorder.stop()
        #expect(!recorder.isListening)
    }
}
