import CoreGraphics
import Foundation
import EmiraCore

// The second hotkey registry, for the one modifier the first cannot express. `CarbonHotkeys.swift`
// documents why Carbon is the default and this is not: a consuming tap sits in the event stream, and
// a tap that does not answer stalls every keystroke on the machine. That objection is about *where
// the callback runs*, and it is answerable — so this file's whole design is the answer.
//
// **The tap runs on its own thread, and never waits for the main actor.** Matching reads an immutable
// snapshot under a lock held for a dictionary lookup; the hop to the main actor is `async` and happens
// *after* the decision to consume. So a main actor blocked on AX — the one thing in emira that
// genuinely blocks — cannot delay a keystroke: the tap has already passed it on. This is strictly
// stronger than the property Carbon gives, which is that emira is not in the path at all.
//
// **It exists only if a config binds an fn chord.** Nothing is created until the first `bind`, so a
// user who never writes `fn-` never has a keyboard tap in their session, and never meets whatever
// prompt macOS attaches to one.

/// One chord in the form the callback compares against: a key position and the modifier bits that
/// must be exactly present. Built once per binding, never per event.
private struct Match: Hashable {
    let keyCode: Int64
    let flags: UInt64
}

/// The modifier bits a chord is matched on. Everything else macOS sets — `maskNonCoalesced` on every
/// event, caps lock, the numeric-pad bit the arrows carry — is masked out before comparing, because a
/// chord says nothing about them and an exact compare would never match.
private let matchedFlags: CGEventFlags = [
    .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn,
]

/// Everything the tap thread and the main actor both touch: the bindings, the keys we have swallowed
/// the press of, the tap and its run loop, and the way back to the main actor. Reachable from the tap
/// thread, so every member is behind the lock; `@unchecked Sendable` is the honest label for that.
private final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var bindings: [Match: HotkeyId] = [:]
    private var held: Set<Int64> = []
    private var deliver: (@Sendable (HotkeyId) -> Void)?
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var isStopping = false

    func setDeliver(_ deliver: (@Sendable (HotkeyId) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.deliver = deliver
    }

    func setTap(_ tap: CFMachPort?) {
        lock.lock(); defer { lock.unlock() }
        self.tap = tap
    }

    func currentTap() -> CFMachPort? {
        lock.lock(); defer { lock.unlock() }
        return tap
    }

    func insert(_ match: Match, _ id: HotkeyId) {
        lock.lock(); defer { lock.unlock() }
        bindings[match] = id
    }

    func remove(_ id: HotkeyId) {
        lock.lock(); defer { lock.unlock() }
        bindings = bindings.filter { $0.value != id }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        bindings.removeAll()
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return bindings.isEmpty
    }

    /// The whole of the tap thread's work: one lookup. Returns the id to fire, or `nil` to pass the
    /// event on untouched.
    func id(for match: Match) -> HotkeyId? {
        lock.lock(); defer { lock.unlock() }
        return bindings[match]
    }

    /// Remember that a key's press was swallowed, so its release can be swallowed to match.
    func hold(_ keyCode: Int64) {
        lock.lock(); defer { lock.unlock() }
        held.insert(keyCode)
    }

    /// `true` if this key's press was swallowed, and clears the record. Keyed on the key alone: a
    /// keyboard has one `h` and it is either down or not.
    func releaseHeld(_ keyCode: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return held.remove(keyCode) != nil
    }

    /// Forget every held key — for when the releases themselves may have been missed.
    func releaseAllHeld() {
        lock.lock(); defer { lock.unlock() }
        held.removeAll()
    }

    /// Take the run loop the tap thread has just made its own. `false` if `stop()` already happened,
    /// in which case the thread must leave rather than enter a loop nothing will stop.
    func adoptRunLoop(_ runLoop: CFRunLoop) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isStopping else { return false }
        self.runLoop = runLoop
        return true
    }

    /// End the tap thread's run loop, from the main actor. Both orders are safe because both sides
    /// take the lock: either the thread has published its run loop and this stops it, or it has not
    /// and `adoptRunLoop` sends it home instead.
    func stopRunLoop() {
        lock.lock()
        isStopping = true
        let runLoop = self.runLoop
        self.runLoop = nil
        lock.unlock()
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    /// Re-arm after a `stop()`, so a later `bind` can install a tap again.
    func beginRun() {
        lock.lock(); defer { lock.unlock() }
        isStopping = false
    }

    /// Off the tap thread and onto the main actor, without waiting for it.
    ///
    /// **The hop is made here, before the stored closure is entered.** That closure is formed on the
    /// main actor and carries its isolation with it, so calling it from this thread is not a race the
    /// compiler let through — it is a runtime isolation check, and it traps. Hopping first is also the
    /// arrangement that keeps the promise at the top of this file: `async`, so the tap thread returns
    /// to the event stream without waiting for whatever the main actor is doing.
    func fire(_ id: HotkeyId) {
        lock.lock()
        let deliver = self.deliver
        lock.unlock()
        guard let deliver else { return }
        DispatchQueue.main.async { deliver(id) }
    }
}

/// The tap callback, and it is **at file scope for a reason that costs a crash to learn**: a closure
/// written inside a `@MainActor` type inherits that isolation, and the compiler emits a
/// `swift_task_isCurrentExecutor` check at its first instruction. On the main run loop that check
/// merely passes — which is why `GestureTap.swift` may write its callback inline — but this one runs
/// on the tap's own thread, where it traps on the first key event. A file-scope function has no
/// enclosing isolation to inherit, so it is the fix and not a style preference.
private func functionKeyTapCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
    _ context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let context else { return Unmanaged.passUnretained(event) }
    let registry = Unmanaged<Registry>.fromOpaque(context).takeUnretainedValue()

    // A tap the window server disables is reported only here, and re-enabling is the only way it ever
    // fires again. The releases that would have cleared `held` were dropped with it, so a key left in
    // there would swallow the release of a later press. `GestureTap.swift` resets for that reason too.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        registry.releaseAllHeld()
        if let tap = registry.currentTap() { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    // A release belongs to whoever took the press, whatever the modifiers say by now — `fn` is
    // usually let go first, so re-matching the chord here would miss and hand the focused app a
    // key-up it never saw the key-down for.
    if type == .keyUp, registry.releaseHeld(keyCode) { return nil }

    let match = Match(keyCode: keyCode, flags: event.flags.intersection(matchedFlags).rawValue)
    guard let id = registry.id(for: match) else {
        return Unmanaged.passUnretained(event)   // not ours: untouched, always
    }

    // Swallowed whichever half it is, so a bound chord never reaches the focused app — including the
    // auto-repeats, which would otherwise type into it while the key is held. Only the first press is
    // an intent, so only that one fires.
    if type == .keyDown {
        registry.hold(keyCode)
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { registry.fire(id) }
    }
    return nil
}

/// A consuming `CGEventTap` on the keyboard, holding only the chords Carbon cannot take.
@MainActor
public final class FunctionKeyTap: HotkeyBinder {

    private let registry = Registry()
    private var thread: Thread?
    /// Set once the system has refused us a tap, so every later `bind` reports the same refusal
    /// rather than asking again per chord and drawing one prompt per binding.
    private var isRefused = false

    public init() {}

    public func start(_ onPress: @escaping @MainActor (HotkeyId) -> Void) {
        // What to do *once on the main actor* — `Registry.fire` owns getting there, because only it
        // knows which thread it is leaving. `self` is `@MainActor`, hence `Sendable`.
        registry.setDeliver { [weak self] id in
            MainActor.assumeIsolated {
                guard self != nil else { return }   // stopped between the press and the hop
                onPress(id)
            }
        }
    }

    public func bind(_ chord: KeyChord, to id: HotkeyId) -> Bool {
        // Carbon takes everything else, and takes it better — see `CarbonHotkeys.swift`.
        guard chord.modifiers.contains(.function) else { return false }
        guard install() else { return false }
        registry.insert(Match(keyCode: Int64(chord.key.virtualKeyCode),
                              flags: chord.modifiers.tapFlags.rawValue), id)
        return true
    }

    public func unbind(_ id: HotkeyId) {
        registry.remove(id)
    }

    public func stop() {
        registry.removeAll()
        registry.releaseAllHeld()
        registry.setDeliver(nil)
        if let tap = registry.currentTap() {
            // Disabled before the run loop is ended, so that between the two the tap is already
            // passing keystrokes through untouched.
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        registry.setTap(nil)
        registry.stopRunLoop()
        thread = nil
        isRefused = false
    }

    /// Create the tap and its thread, once, on the first fn chord. `false` if macOS would not give us
    /// a consuming keyboard tap — which is what a missing Accessibility grant looks like from here.
    private func install() -> Bool {
        if registry.currentTap() != nil { return true }
        if isRefused { return false }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        // `defaultTap`, not `listenOnly` — consuming the keystroke is the entire point, and the
        // difference from `GestureTap.swift` is deliberate. The callback is a C function pointer, so
        // the registry travels through `userInfo` unretained; this object owns it and outlives the tap.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: functionKeyTapCallback,
            userInfo: Unmanaged.passUnretained(registry).toOpaque())
        else {
            isRefused = true
            return false
        }

        registry.setTap(tap)
        registry.beginRun()

        // Its own thread, and that is the load-bearing line of this file. On the main run loop this
        // tap would be exactly the hazard `CarbonHotkeys.swift` refuses to take on. The source is made
        // *here*, on the thread that will run it, so nothing about the tap crosses a thread boundary
        // except through the registry — and the tap is enabled only once it has a run loop to report
        // to, since events arriving before that would sit in the port unanswered.
        //
        // The loop is run, not polled: a daemon thread waking on a timer to ask whether it should
        // still be running costs that wake for the life of the session and buys nothing `stopRunLoop`
        // does not do at once.
        let thread = Thread { [registry] in
            guard let tap = registry.currentTap() else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            guard registry.adoptRunLoop(CFRunLoopGetCurrent()) else {
                CFRunLoopSourceInvalidate(source)
                return
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            CFRunLoopSourceInvalidate(source)
        }
        thread.name = "com.emira.fn-tap"
        thread.qualityOfService = .userInteractive   // it is in the path of every keystroke
        thread.start()
        self.thread = thread
        return true
    }
}

extension KeyModifiers {
    /// Our modifier set in `CGEventFlags`' bit layout — the one the tap compares against. Every
    /// modifier has a bit here, fn included, which is the whole reason this path exists.
    var tapFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command)  { flags.insert(.maskCommand) }
        if contains(.option)   { flags.insert(.maskAlternate) }
        if contains(.control)  { flags.insert(.maskControl) }
        if contains(.shift)    { flags.insert(.maskShift) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}
