import CoreGraphics
import Foundation

/// A key with modifiers, as a tape writes it: `fn+shift+leftbracket`, `cmd+n`, `return`. Keys are
/// named as emira's config names them.
struct KeyCombo: CustomStringConvertible {
    var key: CGKeyCode
    var flags: CGEventFlags
    var text: String?
    var description: String
    /// Its parts, as emira's config spells a chord between its dashes.
    var parts: Set<String> { Set(description.split(separator: "+").map(String.init)) }

    init(parsing word: String, line: Int) throws {
        var parts = word.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.popLast() else { throw TapeError(line: line, message: "empty key") }
        flags = []
        for part in parts {
            guard let modifier = Keyboard.modifiers[part] else {
                throw TapeError(line: line, message: "unknown modifier \(part)")
            }
            flags.insert(modifier.flag)
        }
        if let named = Keyboard.named[last] {
            key = named
        } else if last.count == 1, let (code, shift) = Keyboard.code(for: last.first!) {
            key = code
            // AppKit's menus don't match a shortcut whose event carries its own text (⌘N for New
            // Window), so only plain keys get it.
            text = flags.isEmpty ? last : nil
            if shift { flags.insert(.maskShift) }
        } else {
            throw TapeError(line: line, message: "unknown key \(last)")
        }
        description = word.lowercased()
    }
}

/// US ANSI virtual key codes, which is what the events claim to come from.
enum Keyboard {
    static let modifiers: [String: (code: CGKeyCode, flag: CGEventFlags)] = [
        "cmd": (55, .maskCommand), "shift": (56, .maskShift),
        "alt": (58, .maskAlternate), "option": (58, .maskAlternate),
        "ctrl": (59, .maskControl), "control": (59, .maskControl),
        "fn": (63, .maskSecondaryFn), "globe": (63, .maskSecondaryFn),
    ]
    /// Pressed in this order and released in reverse, as hands do.
    static let modifierOrder: [(code: CGKeyCode, flag: CGEventFlags)] = [
        (63, .maskSecondaryFn), (59, .maskControl), (58, .maskAlternate), (56, .maskShift), (55, .maskCommand),
    ]

    static let named: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "minus": 27, "equal": 24, "leftbracket": 33, "rightbracket": 30, "semicolon": 41, "quote": 39,
        "comma": 43, "period": 47, "slash": 44, "backslash": 42, "grave": 50,
    ]

    /// What each key code types, by code (NUL for keys that type nothing).
    private static let plain = Array("asdfhgzxcv\u{0}bqweryt123465=97-80]ou[ip\u{0}lj'k;\\,/nm.\u{0}\u{0}`")
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// The key that types `c`, and whether it takes Shift.
    static func code(for c: Character) -> (CGKeyCode, Bool)? {
        if c == " " { return (49, false) }
        if let base = shifted[c], let index = plain.firstIndex(of: base) { return (CGKeyCode(index), true) }
        if c.isUppercase, let index = plain.firstIndex(of: Character(c.lowercased())) {
            return (CGKeyCode(index), true)
        }
        if let index = plain.firstIndex(of: c), c != "\u{0}" { return (CGKeyCode(index), false) }
        return nil
    }
}

/// A deterministic random source, so a tape plays the same way every time.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Marks every event the director posts, which is how `InputWatch` tells them from a person's.
let inputTag: Int64 = 0xE31_4A

/// Real input, posted where the hardware's goes, so neither emira nor the app can tell it apart from
/// a person's.
@MainActor
final class Input {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var random: SeededRandom
    private var pressedModifiers: [(code: CGKeyCode, flag: CGEventFlags)] = []

    init(seed: UInt64) {
        random = SeededRandom(seed: seed)
    }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: inputTag)
        event.post(tap: .cghidEventTap)
    }

    private func jitter(_ base: Double, by amount: Double) -> Duration {
        let ms = base * (1 + Double.random(in: -amount...amount, using: &random))
        return .microseconds(Int(ms * 1000))
    }

    private func keyEvent(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, text: String? = nil) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        if let text {
            let units = Array(text.utf16)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        post(event)
    }

    private func pressModifiers(_ flags: CGEventFlags) async {
        var held: CGEventFlags = []
        for modifier in Keyboard.modifierOrder where flags.contains(modifier.flag) {
            held.insert(modifier.flag)
            // A modifier's own event is flagsChanged, not keyDown, as the hardware's is.
            let event = CGEvent(keyboardEventSource: source, virtualKey: modifier.code, keyDown: true)
            event?.type = .flagsChanged
            event?.flags = held
            post(event)
            pressedModifiers.append(modifier)
            try? await Task.sleep(for: jitter(28, by: 0.3))
        }
    }

    func releaseModifiers() async {
        var held = pressedModifiers.reduce(into: CGEventFlags()) { $0.insert($1.flag) }
        while let modifier = pressedModifiers.popLast() {
            held.remove(modifier.flag)
            let event = CGEvent(keyboardEventSource: source, virtualKey: modifier.code, keyDown: false)
            event?.type = .flagsChanged
            event?.flags = held
            post(event)
            try? await Task.sleep(for: jitter(24, by: 0.3))
        }
    }

    /// Presses and lets go of `combo`.
    func press(_ combo: KeyCombo) async {
        await pressModifiers(combo.flags)
        keyEvent(combo.key, down: true, flags: combo.flags, text: combo.text)
        try? await Task.sleep(for: jitter(70, by: 0.3))
        keyEvent(combo.key, down: false, flags: combo.flags, text: combo.text)
        try? await Task.sleep(for: jitter(30, by: 0.3))
        await releaseModifiers()
    }

    /// Puts the pointer at `point`, in global points, at once.
    func warp(to point: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
    }
}
