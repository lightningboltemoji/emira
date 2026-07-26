import Foundation

// The daemon→CLI message: exactly one per `Request`, then the connection closes (`Wire`).
//
// Three outcomes and no more: the command was accepted, it wasn't, or it was `dumpState` and here is
// the state. Note "accepted", not "completed" — a command enters the core as `Event.command(_:)` and
// its real work (an AX teleport, a 200 ms scroll under a cover) finishes long after the CLI has
// exited. `emira` is a remote control, not an RPC that waits for the window to land; anything else
// would make the CLI's latency hostage to a busy app's main thread (PRINCIPLES.md §5).

/// Why a request wasn't accepted. `Error` so the CLI can `throw` it into its one error path;
/// `CustomStringConvertible` because the message is what the user reads.
public struct ReplyError: Sendable, Equatable, Codable, Error, CustomStringConvertible {

    /// The machine-readable kind, so a script can branch without matching on prose. A `String` raw
    /// value keeps the wire readable and lets an unknown future code fail decoding loudly rather than
    /// silently aliasing onto case 0.
    public enum Code: String, Sendable, Codable, CaseIterable, Equatable {
        /// The two ends speak different protocol versions.
        case versionMismatch
        /// The line wasn't a decodable `Request`.
        case malformedRequest
        /// The daemon hit an internal failure handling the request.
        case internalError
    }

    public let code: Code
    /// A complete, printable sentence — the CLI prints this verbatim after `emira: `.
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }

    // MARK: Canonical errors (the wording lives here, once)

    /// The graceful mismatch of IMPLEMENTATION.md §6. Its shape is the one part of this protocol that
    /// must never change: it's the message a peer of *any* version has to be able to read.
    public static func versionMismatch(daemon: Int, client: Int) -> ReplyError {
        ReplyError(code: .versionMismatch,
                   message: "protocol version mismatch: the daemon speaks v\(daemon), this client "
                          + "speaks v\(client) — install the CLI and the daemon from the same build")
    }

    /// The line didn't decode as a `Request`.
    public static func malformedRequest(_ detail: String) -> ReplyError {
        ReplyError(code: .malformedRequest, message: "malformed request: \(detail)")
    }

    /// Something failed inside the daemon while handling an otherwise valid request.
    public static func internalError(_ detail: String) -> ReplyError {
        ReplyError(code: .internalError, message: "internal error: \(detail)")
    }
}

/// The daemon's answer to one request.
///
/// A struct wrapping the outcome, rather than a bare enum, so the reply carries the same flat
/// top-level `version` a request does — which means `Wire.probeVersion` works in *both* directions
/// and a future reply shape is diagnosable by an old CLI instead of merely undecodable.
public struct Reply: Sendable, Equatable, Codable {

    /// What happened.
    public enum Outcome: Sendable, Equatable, Codable {
        /// The command was accepted into the core's event queue.
        case ok
        /// It wasn't. See the error.
        case failed(ReplyError)
        /// The answer to `dumpState`: the daemon's live `State`, already rendered as a JSON document.
        ///
        /// Deliberately an opaque **string**, not a decoded `State`: the CLI's job is to print it
        /// (`emira debug`), and a string means a CLI one release behind still prints a newer daemon's
        /// state perfectly instead of failing to decode a field it has never heard of. The daemon owns
        /// the rendering; the wire just carries it.
        case state(json: String)
    }

    /// The protocol version the daemon speaks (see `Request.version`).
    public let version: Int
    /// The outcome itself.
    public let outcome: Outcome

    public init(_ outcome: Outcome, version: Int = Wire.version) {
        self.version = version
        self.outcome = outcome
    }

    /// The command was accepted.
    public static var ok: Reply { Reply(.ok) }

    /// The command was rejected, for this reason.
    public static func failed(_ error: ReplyError) -> Reply { Reply(.failed(error)) }

    /// The state dump, as a JSON document.
    public static func state(json: String) -> Reply { Reply(.state(json: json)) }

    /// The error, if this reply is a failure — the CLI's whole branch.
    public var error: ReplyError? {
        if case .failed(let error) = outcome { return error }
        return nil
    }
}
