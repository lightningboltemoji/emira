import Foundation
import EmiraCore

// The hotkey subsystem's **policy** half — which chords are currently taken, what happens when the
// config changes, and what a press turns into. The framework-bound half (the system hotkey registry)
// is behind `HotkeyBinder` in `Input/CarbonHotkeys.swift`, the same split as `FrameClock` /
// `DisplayLinkDriver` and `WindowSource` / `AXWindowSource`.
//
// **A hotkey manager is an event *source*, not an effect.** It sits beside the socket server and the
// AX observers: something outside the core happens, and an `Event.command` goes in through the sink.
// That is why the daemon wires it up directly and why `Config.keys` is a value the reducer never
// reads — the alternative (an `Effect.rebindKeys([KeyBinding])` emitted by the reducer on
// `configChanged`) would send the bindings *through* the core only to hand them straight back out
// unchanged, and would make the keyboard depend on a pump that isn't running yet at boot. What the
// core owns is what a keypress *produces*: a `Command`, identical in every respect to the one the CLI
// sends, which is IMPLEMENTATION.md §2's whole claim.
//
// **Why the system registry and not a global event monitor.** `NSEvent.addGlobalMonitorForEvents` is
// already available to us — the AX grant covers it, and `AXObservers` uses one for mouse-up — but a
// global monitor **cannot consume the event**. `alt-h` would scroll the strip *and* type into the
// focused terminal, which is not a window manager. Consuming needs either the system hotkey registry
// or a `CGEventTap`; the registry is cheaper, needs no extra grant, and cannot wedge the event stream
// if we hang. (IMPLEMENTATION.md §11 open item 1, resolved as recommended.)

/// Identifies one live binding to the system registry. Minted here, handed to the binder, and handed
/// back with a press — the *only* lookup the subsystem performs.
public typealias HotkeyId = UInt32

/// The system's hotkey registry, narrowed to the four things we do with it. Implemented for real by
/// `CarbonHotkeyBinder`; tests supply a double.
///
/// **Contract for implementers:**
///
///  · `bind` returns `false` when the system refuses the chord — normally because another application
///    already holds it. That is a **normal outcome**, not an error: the manager reports it and carries
///    on binding the rest, because one taken chord must not cost the user their other twenty.
///  · A press is delivered on the main actor, with the id that was bound, and nothing else.
///  · `unbind` on an id that was never bound (or already unbound) does nothing — totality, §1
///    invariant 3.
@MainActor
public protocol HotkeyBinder: AnyObject {
    /// Begin delivering presses. Called once, before the first `bind`.
    func start(_ onPress: @escaping @MainActor (HotkeyId) -> Void)

    /// Take `chord` system-wide, under `id`. `false` if the system refused it.
    func bind(_ chord: KeyChord, to id: HotkeyId) -> Bool

    /// Release the chord bound under `id`.
    func unbind(_ id: HotkeyId)

    /// Release everything and stop delivering presses.
    func stop()
}

/// Keeps the system hotkey registry in step with `Config.keys`, and turns a press into
/// `Event.command`.
@MainActor
public final class HotkeyManager {

    /// What one `apply` did — returned rather than reported through a callback because it is a
    /// *result*, and a result is the easier of the two to test and the easier for the daemon to log.
    public struct Outcome: Equatable {
        /// Chords the system gave us, in config order.
        public var bound: [KeyChord] = []
        /// Chords the system refused, almost always because another app holds them.
        public var rejected: [KeyChord] = []
        /// The binding list was identical to the live one, so nothing was touched at all.
        public var isUnchanged = false

        /// One phrase for the daemon's log line.
        public var summary: String {
            if isUnchanged { return "unchanged" }
            var text = bound.isEmpty ? "none bound" : "\(bound.count) bound"
            if !rejected.isEmpty {
                text += ", \(rejected.count) refused (taken by another app): "
                    + rejected.map(\.description).joined(separator: ", ")
            }
            return text
        }
    }

    private let binder: any HotkeyBinder
    private let sink: EventSink

    /// What each live id fires. The only map in the subsystem, and it is one-way by design: nothing
    /// ever asks "which id holds this chord?".
    private var commands: [HotkeyId: Command] = [:]

    /// The binding list currently registered — the yardstick for "did this reload change the
    /// keyboard?". See `apply`.
    private var live: [KeyBinding]?

    /// Ids are minted monotonically and **never reused**. A press that races an unbind (the key was
    /// down as the config was saved) then arrives with an id nothing answers to, and is dropped —
    /// where a recycled id would fire whatever command happened to inherit it.
    private var nextId: HotkeyId = 1

    private var started = false

    public init(binder: any HotkeyBinder, sink: EventSink) {
        self.binder = binder
        self.sink = sink
    }

    /// Register exactly `bindings`, releasing whatever was registered before.
    ///
    /// **An unchanged list is a no-op, and that matters more than it looks.** Every config reload
    /// arrives here, including the ones that only moved `column-gap` — and a chord is a *global*
    /// resource, so re-taking twenty of them because a gap changed is churn against the rest of the
    /// system, with a window (however short) in which the user's keystroke reaches whatever else wants
    /// it. Comparing the parsed value is the same filter `ConfigLoader` applies one level up, for the
    /// same reason: the file changing is a guess, the bindings changing is the fact.
    ///
    /// When the list *has* changed, everything is released and re-taken rather than diffed. A diff
    /// would save a handful of registry calls on a keystroke nobody is making at that instant, in
    /// exchange for the subsystem's one piece of arithmetic; at twenty bindings that is not a trade.
    @discardableResult
    public func apply(_ bindings: [KeyBinding]) -> Outcome {
        if let live, live == bindings { return Outcome(isUnchanged: true) }

        if !started {
            started = true
            binder.start { [weak self] id in self?.fire(id) }
        }

        for id in commands.keys { binder.unbind(id) }
        commands.removeAll()

        var outcome = Outcome()
        for binding in bindings {
            let id = nextId
            nextId += 1
            if binder.bind(binding.chord, to: id) {
                commands[id] = binding.command
                outcome.bound.append(binding.chord)
            } else {
                outcome.rejected.append(binding.chord)
            }
        }
        live = bindings
        return outcome
    }

    /// Release every chord and stop listening. The daemon has no teardown path yet (it exits), but a
    /// registry entry outliving the thing that answers it is the sort of leak that only shows up under
    /// a debugger, so the door exists.
    public func stop() {
        guard started else { return }
        binder.stop()
        started = false
        commands.removeAll()
        live = nil
    }

    /// A press: the one place this subsystem touches the core, and it says exactly what the CLI says.
    private func fire(_ id: HotkeyId) {
        guard let command = commands[id] else { return }   // a race with an unbind; see `nextId`
        sink(.command(command))
    }
}
