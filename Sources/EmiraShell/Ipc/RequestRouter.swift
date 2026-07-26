import Foundation
import EmiraCore
import EmiraProtocol

// What the daemon *does* with a request once the socket has delivered it — the policy half of the IPC
// seam, kept out of `SocketServer` (which is pure transport) and out of `emira-daemon/main.swift`
// (which is the one target that can't be unit-tested). The daemon's wiring is therefore one line:
//
//     SocketServer(path: Wire.socketPath()) { RequestRouter.reply(to: $0, from: runtime) }
//
// **Two kinds of request, and the split is the interesting decision.**
//
//  · **Commands are writes.** They enter the core the same way a hotkey or a config binding will —
//    `Event.command(_:)` through the sink — and are answered `ok`, meaning *accepted*, not *completed*
//    (`Reply`). A command's real work outlives the CLI process by far.
//  · **`dumpState` is a read**, and is answered here, out of band, from `Runtime.state` — it never
//    enters the reducer. (Decided 2026-07-24; iteration 12 had guessed it would need its own
//    `Effect`/`Reply` pair.) Two reasons it can't and shouldn't:
//    **(1)** `Effect` is `Codable` — deliberately, so golden effect streams and replay logs serialize
//    (`IMPLEMENTATION.md` §7 "no pixels in the core's vocabulary: ids, never image payloads"). A
//    state-dump effect would have to carry a *reply channel* — a live socket handle — which is neither
//    a value nor serializable. The one rule would have to bend for the one command that gains nothing
//    from it. **(2)** There is nothing to compute: the answer *is* `State`, which the reducer would
//    hand straight back. And it is safe to read here precisely because of §1 invariant 4 — the pump is
//    never re-entrant, so a main-actor hop from the socket lands strictly *between* pumps and can only
//    ever observe a fully-reduced state, never a half-issued one.

/// Turns a decoded `Request` into the `Reply` the daemon sends back.
public enum RequestRouter {

    /// Route one request against a live `Runtime`.
    ///
    /// `@MainActor` because the `Runtime` is: the socket server hops here for exactly the duration of
    /// this call, which does no I/O and no waiting.
    @MainActor
    public static func reply(to request: Request, from runtime: Runtime) -> Reply {
        switch request.command {
        case .dumpState:
            do {
                return .state(json: try stateJSON(runtime.state))
            } catch {
                return .failed(.internalError("could not render the state dump: \(error)"))
            }

        // Every other verb is a write. The reducer decides what it means — including "nothing yet"
        // for the verbs still deferred in `Engine.reduceCommand`; the wire's job is only to deliver
        // it, so a verb that grows behavior later needs no change here.
        default:
            runtime.sink(.command(request.command))
            return .ok
        }
    }

    /// Render the core state as the JSON document `emira debug` prints.
    ///
    /// Pretty-printed because a human reads it, and that costs the framing nothing: the reply's own
    /// encoder escapes the newlines, so a multi-line dump still travels as exactly one JSON line
    /// (`WireTests.newlinesInAPayloadAreEscapedNotEmitted` pins that property). Sorted keys so two
    /// dumps of the same state diff cleanly.
    public static func stateJSON(_ state: State) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(state), as: UTF8.self)
    }
}
