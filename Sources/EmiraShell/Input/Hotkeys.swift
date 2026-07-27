import Foundation
import EmiraCore

// The hotkey subsystem's policy half — which chords are taken, what happens when the config changes,
// what a press turns into. The framework-bound half is behind `HotkeyBinder` in `CarbonHotkeys.swift`.
// A press enters through the sink as `Event.command`, so this is an event *source*, not an effect,
// and the reducer never reads `Config.keys`.

/// Identifies one live binding. Minted here, handed to the binder, handed back with a press.
public typealias HotkeyId = UInt32

/// The system's hotkey registry, narrowed to the four things we do with it. Implemented for real by
/// `CarbonHotkeyBinder`; tests supply a double.
///
/// Implementers: `bind` returning `false` (another app already holds the chord) is a normal outcome,
/// not an error — the manager reports it and binds the rest. A press is delivered on the main actor
/// with the id that was bound; `unbind` on an unknown id does nothing.
@MainActor
public protocol HotkeyBinder: AnyObject {
    /// Begin delivering presses. Called once, before the first `bind`.
    func start(_ onPress: @escaping @MainActor (HotkeyId) -> Void)

    /// Take `chord` system-wide, under `id`. `false` if the system refused it.
    func bind(_ chord: KeyChord, to id: HotkeyId) -> Bool

    func unbind(_ id: HotkeyId)

    func stop()
}

/// Keeps the system hotkey registry in step with `Config.keys`, turning a press into `Event.command`.
@MainActor
public final class HotkeyManager {

    /// What one `apply` did.
    public struct Outcome: Equatable {
        public var bound: [KeyChord] = []
        /// Refused by the system, almost always because another app holds them.
        public var rejected: [KeyChord] = []
        /// The binding list matched the live one, so nothing was touched.
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

    /// What each live id fires. One-way by design: nothing ever asks "which id holds this chord?".
    private var commands: [HotkeyId: Command] = [:]

    /// The binding list currently registered — the yardstick for "did this reload change anything?".
    private var live: [KeyBinding]?

    /// Minted monotonically and never reused: a press racing an unbind arrives with an id nothing
    /// answers to and is dropped, where a recycled id would fire whatever command inherited it.
    private var nextId: HotkeyId = 1

    private var started = false

    public init(binder: any HotkeyBinder, sink: EventSink) {
        self.binder = binder
        self.sink = sink
    }

    /// Register exactly `bindings`, releasing whatever was registered before. An unchanged list must
    /// stay a no-op: every config reload arrives here, and re-taking a global chord opens a window,
    /// however short, in which the user's keystroke reaches whatever else wants it. A changed list is
    /// released and re-taken wholesale rather than diffed.
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

    /// Release every chord — a registry entry outliving its answerer is a leak nothing else surfaces.
    public func stop() {
        guard started else { return }
        binder.stop()
        started = false
        commands.removeAll()
        live = nil
    }

    private func fire(_ id: HotkeyId) {
        guard let command = commands[id] else { return }   // a race with an unbind; see `nextId`
        sink(.command(command))
    }
}
