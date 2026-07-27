import Foundation
import EmiraCore

// The CLI→daemon message: one `Command`, the protocol version, and who is asking. The envelope does
// not translate — the payload is the same `Command` the reducer consumes as `Event.command(_:)`, so
// adding a verb never touches this file.

/// Who sent a request. Metadata only — the daemon never authorizes on it.
public struct Client: Sendable, Equatable, Codable {
    public let pid: Int32

    public init(pid: Int32) {
        self.pid = pid
    }

    public static var current: Client {
        Client(pid: ProcessInfo.processInfo.processIdentifier)
    }
}

/// One command, framed for the socket. The daemon answers with exactly one `Reply`, then closes.
public struct Request: Sendable, Equatable, Codable {
    /// The protocol version the sender speaks. Flat and top-level so `Wire.probeVersion` can read it
    /// out of a line whose envelope it can't otherwise decode.
    public let version: Int
    public let command: Command
    public let client: Client

    /// Defaults describe this process; overridable so a test can forge an old or new client.
    public init(_ command: Command, client: Client = .current, version: Int = Wire.version) {
        self.version = version
        self.command = command
        self.client = client
    }
}
