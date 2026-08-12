import Carbon.HIToolbox
import EmiraCore

// The system hotkey registry. `RegisterEventHotKey` is still the only public API that *consumes* a
// keystroke without a `CGEventTap` — the chord is claimed at the window server, and a hung emira cannot
// stall the event stream the way a tap can. (Carbon's deprecated *UI* is not this; the hotkey registry
// has no replacement.)
//
// The keycode table this spends is `Key.virtualKeyCode`, in `EmiraCore`: the settings window records
// keystrokes and needs the same map read backwards, and it cannot reach a Carbon-spelled one.
// `HotkeyTests` is what pins it against `kVK_*`, which is the checking the spelling used to do.

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
        // `nil` is a chord this registry cannot express — only fn, and only if something bypassed
        // the router. Refusing beats registering it: see `carbonFlags`.
        guard let modifiers = chord.modifiers.carbonFlags else { return false }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(chord.key.virtualKeyCode), modifiers,
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

extension KeyModifiers {
    /// Our modifier set in the registry's own bit layout, or `nil` for a set the registry cannot
    /// express. Neither side distinguishes left from right.
    ///
    /// **There is no fn bit.** `EventModifiers` is a `UInt16` topping out at `rightControlKey`, and
    /// `RegisterEventHotKey` matches on that width: handed a wider word it registers cleanly, returns
    /// `noErr`, and then answers to the *unmodified* key — `fn-h` would take plain `h` from every app
    /// on the machine. So an fn chord is refused here and routed to the tap by `SplitHotkeyBinder`,
    /// which is what makes this `nil` unreachable in the daemon.
    var carbonFlags: UInt32? {
        guard !contains(.function) else { return nil }
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option)  { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift)   { flags |= UInt32(shiftKey) }
        return flags
    }
}
