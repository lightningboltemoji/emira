import Foundation
import EmiraCore
import EmiraProtocol

// The policy half of the IPC seam, kept out of `SocketServer` (pure transport) and out of
// `emira-daemon/main.swift` (which can't be unit-tested).
//
// Commands are writes: they enter the core as `Event.command(_:)` and are answered `ok` — accepted,
// not completed. `dumpState` is a read, answered here from `Runtime.state` without entering the
// reducer. That's safe because the pump is never re-entrant: a hop from the socket lands strictly
// *between* pumps and can only observe a fully-reduced state.

/// Turns a decoded `Request` into the `Reply` the daemon sends back.
public enum RequestRouter {

    /// Route one request against a live `Runtime`. `@MainActor` because the `Runtime` is; the call
    /// does no I/O and no waiting, so the socket server's hop is brief.
    @MainActor
    public static func reply(to request: Request, from runtime: Runtime) -> Reply {
        switch request.command {
        case .dumpState:
            do {
                return .state(json: try stateJSON(runtime.state))
            } catch {
                return .failed(.internalError("could not render the state dump: \(error)"))
            }

        // Every other verb is a write; the reducer decides what it means.
        default:
            runtime.sink(.command(request.command))
            return .ok
        }
    }

    /// Render the core state as the JSON document `emira debug` prints. Pretty-printing costs the
    /// framing nothing — the reply's encoder escapes the newlines, so it still travels as one line.
    public static func stateJSON(_ state: State) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(state), as: UTF8.self)
    }
}
