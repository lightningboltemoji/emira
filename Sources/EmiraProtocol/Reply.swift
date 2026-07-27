import Foundation

// The daemon→CLI message: exactly one per `Request`, then the connection closes. "Accepted", not
// "completed" — a command's real work finishes long after the CLI has exited.

/// Why a request wasn't accepted. `CustomStringConvertible` because the message is what the user reads.
public struct ReplyError: Sendable, Equatable, Codable, Error, CustomStringConvertible {

    /// The machine-readable kind, so a script can branch without matching on prose. `String` raw
    /// values keep the wire readable and make an unknown future code fail decoding loudly.
    public enum Code: String, Sendable, Codable, CaseIterable, Equatable {
        case versionMismatch
        case malformedRequest
        case internalError
    }

    public let code: Code
    /// A complete sentence — the CLI prints it verbatim after `emira: `.
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }

    // MARK: Canonical errors (the wording lives here, once)

    /// The one part of this protocol whose shape must never change — a peer of *any* version has to
    /// be able to read it.
    public static func versionMismatch(daemon: Int, client: Int) -> ReplyError {
        ReplyError(code: .versionMismatch,
                   message: "protocol version mismatch: the daemon speaks v\(daemon), this client "
                          + "speaks v\(client) — install the CLI and the daemon from the same build")
    }

    public static func malformedRequest(_ detail: String) -> ReplyError {
        ReplyError(code: .malformedRequest, message: "malformed request: \(detail)")
    }

    public static func internalError(_ detail: String) -> ReplyError {
        ReplyError(code: .internalError, message: "internal error: \(detail)")
    }
}

/// The daemon's answer to one request. A struct rather than a bare enum so the reply carries the same
/// flat top-level `version` a request does, and `Wire.probeVersion` works in both directions.
public struct Reply: Sendable, Equatable, Codable {

    public enum Outcome: Sendable, Equatable, Codable {
        case ok
        case failed(ReplyError)
        /// The answer to `dumpState`. An opaque string, not a decoded `State`, so a CLI one release
        /// behind still prints a newer daemon's state instead of failing on an unknown field.
        case state(json: String)
    }

    public let version: Int
    public let outcome: Outcome

    public init(_ outcome: Outcome, version: Int = Wire.version) {
        self.version = version
        self.outcome = outcome
    }

    public static var ok: Reply { Reply(.ok) }

    public static func failed(_ error: ReplyError) -> Reply { Reply(.failed(error)) }

    public static func state(json: String) -> Reply { Reply(.state(json: json)) }

    /// The error, if this reply is a failure.
    public var error: ReplyError? {
        if case .failed(let error) = outcome { return error }
        return nil
    }
}
