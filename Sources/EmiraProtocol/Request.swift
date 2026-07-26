import Foundation
import EmiraCore

// The CLI→daemon message. One `Command` (EmiraCore §2 — the *one* vocabulary), the protocol version,
// and a little about who is asking.
//
// Note what the envelope deliberately does *not* do: translate. The payload is the same `Command`
// value the reducer consumes as `Event.command(_:)`, the same one a hotkey builds, the same one a
// config binding parses. `EmiraProtocol` only *wraps* it for the wire (IMPLEMENTATION.md §2), so
// adding a verb never touches this file.

/// Who sent a request. Metadata only — the daemon never authorizes on it, it just makes the log
/// ("command from pid 4821") answerable and gives the envelope somewhere to grow.
public struct Client: Sendable, Equatable, Codable {
    /// The sending process's pid.
    public let pid: Int32

    public init(pid: Int32) {
        self.pid = pid
    }

    /// This process.
    public static var current: Client {
        Client(pid: ProcessInfo.processInfo.processIdentifier)
    }
}

/// One command, framed for the socket. The daemon answers every request with exactly one `Reply` and
/// closes the connection (`Wire`).
public struct Request: Sendable, Equatable, Codable {
    /// The protocol version the sender speaks. Top-level and flat, so `Wire.probeVersion` can read it
    /// out of a line whose envelope it can't otherwise decode — that's how a mismatch stays a clear
    /// message instead of a decode error.
    public let version: Int
    /// What to do.
    public let command: Command
    /// Who asked.
    public let client: Client

    /// Build a request from this process, at this build's protocol version — the CLI's one-liner.
    /// The defaults are overridable so a test can forge an old/new client.
    public init(_ command: Command, client: Client = .current, version: Int = Wire.version) {
        self.version = version
        self.command = command
        self.client = client
    }
}
