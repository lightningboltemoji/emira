import Carbon.HIToolbox
import EmiraCore

// The system hotkey registry, and the table mapping our key names onto its virtual key codes.
// `RegisterEventHotKey` is still the only public API that *consumes* a keystroke without a
// `CGEventTap` — the chord is claimed at the window server, and a hung emira cannot stall the event
// stream the way a tap can. (Carbon's deprecated *UI* is not this; the hotkey registry has no
// replacement.) The keycode table is a physical map: `kVK_ANSI_H` is the key where H sits on US
// layout, whatever it types elsewhere.

/// Ours, in the registry's four-character-code namespace: `'emir'`. File-scope rather than a static
/// member because the C event handler below is not on the main actor and cannot touch one.
private let hotkeySignature: OSType = 0x656D_6972

/// One application-wide Carbon event handler plus one registry entry per live binding.
@MainActor
public final class CarbonHotkeyBinder: HotkeyBinder {

    private var handler: EventHandlerRef?
    private var refs: [HotkeyId: EventHotKeyRef] = [:]
    private var onPress: (@MainActor (HotkeyId) -> Void)?

    public init() {}

    public func start(_ onPress: @escaping @MainActor (HotkeyId) -> Void) {
        self.onPress = onPress
        guard handler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // One handler for every hotkey; the press carries the id back. The callback is a C function
        // pointer, so `self` travels unretained as the user-data pointer — the binder outlives it.
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                // `eventNotHandledErr` lets somebody else's hotkey carry on to whoever registered it.
                guard status == noErr, pressed.signature == hotkeySignature else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon delivers on the main run loop, which *is* the main actor's executor.
                let binder = Unmanaged<CarbonHotkeyBinder>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { binder.deliver(pressed.id) }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    public func bind(_ chord: KeyChord, to id: HotkeyId) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(chord.key.virtualKeyCode), chord.modifiers.carbonFlags,
            EventHotKeyID(signature: hotkeySignature, id: id),
            GetApplicationEventTarget(), 0, &ref)
        // The usual refusal is `eventHotKeyExistsErr` — another app holds the chord. Not an error.
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    public func unbind(_ id: HotkeyId) {
        guard let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }

    public func stop() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        onPress = nil
    }

    private func deliver(_ id: HotkeyId) {
        onPress?(id)
    }
}

// MARK: - The two translations

extension KeyModifiers {
    /// Our modifier set in the registry's own bit layout. Neither side distinguishes left from right.
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option)  { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift)   { flags |= UInt32(shiftKey) }
        return flags
    }
}

extension Key {
    /// The virtual key code for this key's physical position. Spelled `kVK_*` rather than hex so the
    /// table is checkable against Apple's header — a silent transposition (two keys, one code) is the
    /// failure mode, and nothing at the call site would catch it.
    var virtualKeyCode: Int {
        switch self {
        case .a: return kVK_ANSI_A
        case .b: return kVK_ANSI_B
        case .c: return kVK_ANSI_C
        case .d: return kVK_ANSI_D
        case .e: return kVK_ANSI_E
        case .f: return kVK_ANSI_F
        case .g: return kVK_ANSI_G
        case .h: return kVK_ANSI_H
        case .i: return kVK_ANSI_I
        case .j: return kVK_ANSI_J
        case .k: return kVK_ANSI_K
        case .l: return kVK_ANSI_L
        case .m: return kVK_ANSI_M
        case .n: return kVK_ANSI_N
        case .o: return kVK_ANSI_O
        case .p: return kVK_ANSI_P
        case .q: return kVK_ANSI_Q
        case .r: return kVK_ANSI_R
        case .s: return kVK_ANSI_S
        case .t: return kVK_ANSI_T
        case .u: return kVK_ANSI_U
        case .v: return kVK_ANSI_V
        case .w: return kVK_ANSI_W
        case .x: return kVK_ANSI_X
        case .y: return kVK_ANSI_Y
        case .z: return kVK_ANSI_Z

        case .digit0: return kVK_ANSI_0
        case .digit1: return kVK_ANSI_1
        case .digit2: return kVK_ANSI_2
        case .digit3: return kVK_ANSI_3
        case .digit4: return kVK_ANSI_4
        case .digit5: return kVK_ANSI_5
        case .digit6: return kVK_ANSI_6
        case .digit7: return kVK_ANSI_7
        case .digit8: return kVK_ANSI_8
        case .digit9: return kVK_ANSI_9

        case .f1:  return kVK_F1
        case .f2:  return kVK_F2
        case .f3:  return kVK_F3
        case .f4:  return kVK_F4
        case .f5:  return kVK_F5
        case .f6:  return kVK_F6
        case .f7:  return kVK_F7
        case .f8:  return kVK_F8
        case .f9:  return kVK_F9
        case .f10: return kVK_F10
        case .f11: return kVK_F11
        case .f12: return kVK_F12
        case .f13: return kVK_F13
        case .f14: return kVK_F14
        case .f15: return kVK_F15
        case .f16: return kVK_F16
        case .f17: return kVK_F17
        case .f18: return kVK_F18
        case .f19: return kVK_F19
        case .f20: return kVK_F20

        case .left:  return kVK_LeftArrow
        case .right: return kVK_RightArrow
        case .up:    return kVK_UpArrow
        case .down:  return kVK_DownArrow

        case .enter:  return kVK_Return
        case .tab:    return kVK_Tab
        case .space:  return kVK_Space
        case .escape: return kVK_Escape
        // The key a Mac keyboard *labels* "delete" is `kVK_Delete`, and ⌦ is `kVK_ForwardDelete`;
        // `KeyChord.swift` names them `backspace` and `delete`. The two conventions meet here.
        case .backspace: return kVK_Delete
        case .delete:    return kVK_ForwardDelete

        case .home:     return kVK_Home
        case .end:      return kVK_End
        case .pageup:   return kVK_PageUp
        case .pagedown: return kVK_PageDown

        case .minus:        return kVK_ANSI_Minus
        case .equal:        return kVK_ANSI_Equal
        case .leftbracket:  return kVK_ANSI_LeftBracket
        case .rightbracket: return kVK_ANSI_RightBracket
        case .backslash:    return kVK_ANSI_Backslash
        case .semicolon:    return kVK_ANSI_Semicolon
        case .quote:        return kVK_ANSI_Quote
        case .comma:        return kVK_ANSI_Comma
        case .period:       return kVK_ANSI_Period
        case .slash:        return kVK_ANSI_Slash
        case .backtick:     return kVK_ANSI_Grave
        }
    }
}
