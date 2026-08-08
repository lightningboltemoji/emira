import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The hotkey subsystem's policy — everything above the system registry, which is `HotkeyBinder`, four
// methods wide, with `CarbonHotkeyBinder` untestable by construction. What is tested: what a config
// reload does to the live bindings, what happens when the system refuses a chord, and what a press
// turns into — plus the Carbon keycode table, whose failure mode no call site could catch.

@Suite @MainActor struct HotkeyTests {

    /// A `HotkeyBinder` that records what was asked of it and can be told to refuse chords, the way a
    /// real registry refuses one another app already holds.
    final class FakeBinder: HotkeyBinder {
        /// Chords this binder pretends are taken by somebody else.
        var refuses: Set<KeyChord> = []
        private(set) var live: [HotkeyId: KeyChord] = [:]
        /// What this binder currently holds, for the routing tests — which care which registry took a
        /// chord, not what id it was given.
        var liveChords: [KeyChord] { Array(live.values) }
        /// Every id the manager *offered*, whether or not the bind succeeded — so a test can press an
        /// id the registry never actually gave back.
        private(set) var offered: [KeyChord: HotkeyId] = [:]
        /// Every call, in order — the subject of the "released before re-taken" test.
        private(set) var calls: [String] = []
        private(set) var isStarted = false
        private var onPress: (@MainActor (HotkeyId) -> Void)?

        func start(_ onPress: @escaping @MainActor (HotkeyId) -> Void) {
            isStarted = true
            self.onPress = onPress
            calls.append("start")
        }

        func bind(_ chord: KeyChord, to id: HotkeyId) -> Bool {
            calls.append("bind \(chord) #\(id)")
            offered[chord] = id
            guard !refuses.contains(chord) else { return false }
            live[id] = chord
            return true
        }

        func unbind(_ id: HotkeyId) {
            calls.append("unbind #\(id)")
            live.removeValue(forKey: id)
        }

        func stop() {
            calls.append("stop")
            isStarted = false
            live.removeAll()
            onPress = nil
        }

        /// Model a keypress on a chord the binder currently holds.
        func press(_ chord: KeyChord) {
            guard let id = live.first(where: { $0.value == chord })?.key else { return }
            onPress?(id)
        }

        /// Model a press arriving by id alone — an id nothing holds any more (the key was down as the
        /// config was saved), or one the manager offered for a chord we refused.
        func press(id: HotkeyId) { onPress?(id) }
    }

    /// A manager over a fake binder, plus the events it produced.
    static func manager(_ binder: FakeBinder) -> (HotkeyManager, Recorder) {
        let recorder = Recorder()
        let manager = HotkeyManager(binder: binder, sink: EventSink { event in recorder.record(event) })
        return (manager, recorder)
    }

    final class Recorder: @unchecked Sendable {
        private(set) var events: [Event] = []
        func record(_ event: Event) { events.append(event) }
        var commands: [Command] {
            events.compactMap { if case .command(let c) = $0 { return c } else { return nil } }
        }
    }

    static let focusLeft = KeyBinding(KeyChord([.option], .h), .focus(.left))
    static let focusRight = KeyBinding(KeyChord([.option], .l), .focus(.right))
    static let cycleWidth = KeyBinding(KeyChord([.option], .r), .cycleWidth)

    // A press is a command

    /// A keypress produces the same `Event.command` the socket does, with no translation anywhere.
    @Test func aPressBecomesTheCommandItIsBoundTo() {
        let binder = FakeBinder()
        let (manager, recorder) = Self.manager(binder)
        manager.apply([Self.focusLeft, Self.cycleWidth])

        binder.press(Self.focusLeft.chord)
        binder.press(Self.cycleWidth.chord)
        #expect(recorder.commands == [.focus(.left), .cycleWidth])
    }

    @Test func anUnboundChordProducesNothing() {
        let binder = FakeBinder()
        let (manager, recorder) = Self.manager(binder)
        manager.apply([Self.focusLeft])

        binder.press(Self.focusRight.chord)
        #expect(recorder.events.isEmpty)
    }

    @Test func applyingBindingsTakesThemAll() {
        let binder = FakeBinder()
        let (manager, _) = Self.manager(binder)
        let outcome = manager.apply([Self.focusLeft, Self.focusRight])

        #expect(binder.isStarted)
        #expect(outcome.bound == [Self.focusLeft.chord, Self.focusRight.chord])
        #expect(outcome.rejected.isEmpty)
        #expect(outcome.summary == "2 bound")
        #expect(Set(binder.live.values) == [Self.focusLeft.chord, Self.focusRight.chord])
    }

    /// A refused chord is a normal outcome, not a failure: the other bindings still land.
    @Test func aRefusedChordCostsOnlyItself() {
        let binder = FakeBinder()
        binder.refuses = [Self.focusRight.chord]
        let (manager, _) = Self.manager(binder)
        let outcome = manager.apply([Self.focusLeft, Self.focusRight, Self.cycleWidth])

        #expect(outcome.bound == [Self.focusLeft.chord, Self.cycleWidth.chord])
        #expect(outcome.rejected == [Self.focusRight.chord])
        #expect(outcome.summary
            == "2 bound, 1 refused (taken by another app, or the AX grant revoked): alt-l")
        // And a press on a bound chord still works — the refusal didn't derail the rest.
        binder.press(Self.cycleWidth.chord)
    }

    /// Only a chord the system gave us can fire: a refusal must leave the command map alone, not
    /// merely leave the chord unregistered.
    @Test func aRefusedChordLeavesNoCommandBehind() {
        let binder = FakeBinder()
        binder.refuses = [Self.focusLeft.chord]
        let (manager, recorder) = Self.manager(binder)
        manager.apply([Self.focusLeft])

        binder.press(Self.focusLeft.chord)
        #expect(recorder.events.isEmpty)
        guard let offered = binder.offered[Self.focusLeft.chord] else {
            Issue.record("the manager never offered an id for the refused chord")
            return
        }
        binder.press(id: offered)
        #expect(recorder.events.isEmpty)
    }

    /// Every config change reaches `apply`, including ones that only moved `column-gap`. A chord is a
    /// global resource, so re-taking twenty of them leaves a window where the keystroke reaches
    /// somebody else.
    @Test func anUnchangedBindingListIsANoOp() {
        let binder = FakeBinder()
        let (manager, _) = Self.manager(binder)
        manager.apply([Self.focusLeft, Self.focusRight])
        let before = binder.calls

        let outcome = manager.apply([Self.focusLeft, Self.focusRight])
        #expect(outcome.isUnchanged)
        #expect(outcome.summary == "unchanged")
        #expect(binder.calls == before)          // nothing was touched at all
    }

    /// …and the filter is on the bindings, not on identity: a list that *reordered* is a change,
    /// because the daemon reports bindings in file order.
    @Test func aChangedBindingListIsReapplied() {
        let binder = FakeBinder()
        let (manager, recorder) = Self.manager(binder)
        manager.apply([Self.focusLeft])
        let outcome = manager.apply([Self.focusRight])

        #expect(!outcome.isUnchanged)
        #expect(outcome.bound == [Self.focusRight.chord])
        #expect(Set(binder.live.values) == [Self.focusRight.chord])
        // The old chord is gone from the system, not merely shadowed.
        binder.press(Self.focusLeft.chord)
        #expect(recorder.events.isEmpty)
    }

    @Test func rebindingReleasesBeforeItRetakes() {
        let binder = FakeBinder()
        let (manager, _) = Self.manager(binder)
        manager.apply([Self.focusLeft])
        manager.apply([Self.focusLeft, Self.focusRight])

        let unbind = binder.calls.firstIndex(of: "unbind #1")
        let rebind = binder.calls.firstIndex(of: "bind alt-h #2")
        #expect(unbind != nil && rebind != nil)
        #expect(unbind! < rebind!)
    }

    /// A rebind rebuilds the command map rather than adding to it — otherwise a removed binding would
    /// keep firing under its old id if the registry ever handed one back.
    @Test func aRemovedBindingLeavesNothingBehind() {
        let binder = FakeBinder()
        let (manager, recorder) = Self.manager(binder)
        manager.apply([Self.focusLeft, Self.focusRight])
        manager.apply([Self.focusLeft])

        #expect(binder.live.count == 1)
        binder.press(Self.focusLeft.chord)
        #expect(recorder.commands == [.focus(.left)])
    }

    @Test func anEmptyBindingListBindsNothingAndSaysSo() {
        let binder = FakeBinder()
        let (manager, _) = Self.manager(binder)
        let outcome = manager.apply([])

        #expect(outcome.bound.isEmpty)
        #expect(outcome.summary == "none bound")
        #expect(binder.live.isEmpty)
    }

    /// Ids are minted monotonically and never reused, so a press that raced an unbind — the key was
    /// down as the file was saved — finds nothing rather than firing whatever inherited the id.
    @Test func aPressThatRacedAnUnbindIsDropped() {
        let binder = FakeBinder()
        let (manager, recorder) = Self.manager(binder)
        manager.apply([Self.focusLeft])
        manager.apply([Self.focusRight])

        binder.press(id: 1)
        #expect(recorder.events.isEmpty)
        #expect(!binder.calls.contains("bind alt-l #1"))    // #1 was retired, not recycled
    }

    @Test func stoppingReleasesEverything() {
        let binder = FakeBinder()
        let (manager, _) = Self.manager(binder)
        manager.apply([Self.focusLeft])
        manager.stop()

        #expect(!binder.isStarted)
        #expect(binder.live.isEmpty)
    }

    // The Carbon half's one testable claim

    /// The keycode table's failure mode is a transposition: two key names sharing one code means one
    /// silently binds the wrong physical key, undetectable at the call site. Injectivity catches it.
    @Test func theKeycodeTableIsInjective() {
        var codes: [Int: Key] = [:]
        for key in Key.allCases {
            let code = key.virtualKeyCode
            #expect(codes[code] == nil, "\(key.rawValue) and \(codes[code]?.rawValue ?? "") share \(code)")
            codes[code] = key
        }
        #expect(codes.count == Key.allCases.count)
    }

    /// A spot-check against Apple's own numbers, so the table is anchored to something outside itself.
    @Test func theKeycodesAreThePhysicalOnes() {
        #expect(Key.a.virtualKeyCode == 0x00)
        #expect(Key.h.virtualKeyCode == 0x04)
        #expect(Key.space.virtualKeyCode == 0x31)
        #expect(Key.enter.virtualKeyCode == 0x24)
        #expect(Key.left.virtualKeyCode == 0x7B)
        // The two delete keys, which are named the other way round from Apple's constants on purpose.
        #expect(Key.backspace.virtualKeyCode == 0x33)
        #expect(Key.delete.virtualKeyCode == 0x75)
    }

    @Test func theModifierFlagsAreCarbonsOwn() {
        #expect(KeyModifiers([]).carbonFlags == 0)
        #expect(KeyModifiers([.command]).carbonFlags == 0x0100)
        #expect(KeyModifiers([.shift]).carbonFlags == 0x0200)
        #expect(KeyModifiers([.option]).carbonFlags == 0x0800)
        #expect(KeyModifiers([.control]).carbonFlags == 0x1000)
        #expect(KeyModifiers([.command, .option]).carbonFlags == 0x0900)
    }

    /// The bit that isn't there. `RegisterEventHotKey` takes a `UInt32` but matches on `EventModifiers`
    /// width, so an invented fn bit registers with `noErr` and then answers to the *bare* key — `fn-h`
    /// taking plain `h` from every app on the machine. `nil` is what stops that reaching the registry,
    /// and this is the test that keeps it `nil`.
    @Test func carbonCannotExpressFunction() {
        #expect(KeyModifiers([.function]).carbonFlags == nil)
        #expect(KeyModifiers([.function, .command]).carbonFlags == nil)
        #expect(KeyModifiers([.command]).carbonFlags != nil)
    }

    /// The tap's layout is `CGEventFlags`, which does have a bit for every modifier — that difference
    /// is the reason there are two registries at all.
    @Test func theTapFlagsAreCoreGraphicsOwn() {
        #expect(KeyModifiers([.function]).tapFlags == .maskSecondaryFn)
        #expect(KeyModifiers([.command]).tapFlags == .maskCommand)
        #expect(KeyModifiers([.function, .shift]).tapFlags == [.maskSecondaryFn, .maskShift])
        #expect(KeyModifiers([]).tapFlags == [])
    }

    // MARK: - Routing

    /// Each chord reaches exactly one registry, and the one that can express it.
    @Test func fnChordsGoToTheTapAndNothingElseDoes() {
        let carbon = FakeBinder()
        let tap = FakeBinder()
        let split = SplitHotkeyBinder(carbon: carbon, function: tap)
        split.start { _ in }

        #expect(split.bind(KeyChord([.function], .h), to: 1))
        #expect(split.bind(KeyChord([.option], .h), to: 2))
        #expect(split.bind(KeyChord([.function, .shift], .j), to: 3))
        #expect(split.bind(KeyChord([], .f13), to: 4))

        #expect(Set(tap.liveChords) == [KeyChord([.function], .h), KeyChord([.function, .shift], .j)])
        #expect(Set(carbon.liveChords) == [KeyChord([.option], .h), KeyChord([], .f13)])
        // Both are started, because an id names a binding rather than a registry.
        #expect(carbon.isStarted && tap.isStarted)
    }

    /// `unbind` arrives with an id and nothing else, so the router has to remember who took it —
    /// asking the wrong registry is silent, and leaves the chord held with nobody answering.
    @Test func unbindReachesTheRegistryThatTookTheChord() {
        let carbon = FakeBinder()
        let tap = FakeBinder()
        let split = SplitHotkeyBinder(carbon: carbon, function: tap)
        split.start { _ in }
        _ = split.bind(KeyChord([.function], .h), to: 7)
        _ = split.bind(KeyChord([.option], .h), to: 8)

        split.unbind(7)
        #expect(tap.liveChords.isEmpty)
        #expect(carbon.liveChords == [KeyChord([.option], .h)])

        split.unbind(8)
        #expect(carbon.liveChords.isEmpty)
    }

    /// A refusal from either side is still a refusal, and must not be recorded as bound — a config
    /// reload would then unbind an id its registry never took.
    @Test func aRefusedChordIsNotRecorded() {
        let carbon = FakeBinder()
        let tap = FakeBinder()
        tap.refuses = [KeyChord([.function], .h)]
        let split = SplitHotkeyBinder(carbon: carbon, function: tap)
        split.start { _ in }

        #expect(!split.bind(KeyChord([.function], .h), to: 1))
        split.unbind(1)          // must not be routed anywhere; nothing to assert but the absence
        #expect(tap.calls.filter { $0.hasPrefix("unbind") }.isEmpty)
    }

    @Test func stoppingStopsBoth() {
        let carbon = FakeBinder()
        let tap = FakeBinder()
        let split = SplitHotkeyBinder(carbon: carbon, function: tap)
        split.start { _ in }
        split.stop()
        #expect(!carbon.isStarted && !tap.isStarted)
    }

    /// A press through either registry is the same press: the manager holds the commands, and the id
    /// it minted is what comes back.
    @Test func aPressThroughTheTapFiresItsCommand() {
        let carbon = FakeBinder()
        let tap = FakeBinder()
        var fired: [Command] = []
        let manager = HotkeyManager(binder: SplitHotkeyBinder(carbon: carbon, function: tap),
                                    sink: EventSink { if case .command(let c) = $0 { fired.append(c) } })
        manager.apply([KeyBinding(KeyChord([.function], .h), .focus(.left)),
                       KeyBinding(KeyChord([.option], .h), .focus(.right))])

        tap.press(KeyChord([.function], .h))
        #expect(fired == [.focus(.left)])
        carbon.press(KeyChord([.option], .h))
        #expect(fired == [.focus(.left), .focus(.right)])
    }
}
