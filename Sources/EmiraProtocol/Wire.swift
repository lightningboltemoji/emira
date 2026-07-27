import Foundation

// Where the daemon's socket lives, how bytes are framed, and what version the two ends agree they're
// speaking. One connection carries one `Request` and one `Reply`, then closes. Framing is JSON-lines
// — one UTF-8 JSON object, one `\n`, unambiguous because a non-pretty `JSONEncoder` never emits a raw
// newline. `version` is probed out of a line *before* the envelope is decoded, so a peer from another
// build gets a version message instead of a decode failure; hence a flat top-level `Int`, forever.

/// The protocol's constants and codec.
public enum Wire {

    // MARK: - Version

    /// Bump whenever `Request`/`Reply` change shape in a way an older peer can't read.
    public static let version = 1

    // MARK: - Socket location

    /// Overrides the socket path — the escape hatch for tests and for two daemons side by side.
    public static let socketEnvironmentKey = "EMIRA_SOCKET"

    public static let socketName = "emira.sock"

    /// `sockaddr_un.sun_path` is 104 bytes including the NUL, so a longer path cannot be bound.
    /// Enforced when *choosing* the path so the failure never reaches `bind`.
    public static let maxSocketPathBytes = 103

    /// Where the daemon listens and the CLI dials: the `EMIRA_SOCKET` override, then `$TMPDIR` (on
    /// macOS the per-user `0700` `/var/folders/…/T/`), then `/tmp/emira-<user>.sock`.
    ///
    /// - Note: that last fallback is world-writable, so the *server* must still create the socket
    ///   `0600` and refuse a path it doesn't own. Choosing a path is not trusting it.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  user: String = NSUserName()) -> String {
        if let override = environment[socketEnvironmentKey], !override.isEmpty { return override }
        if let temporary = environment["TMPDIR"], !temporary.isEmpty {
            let path = URL(fileURLWithPath: temporary, isDirectory: true)
                .appendingPathComponent(socketName).path
            if path.utf8.count <= maxSocketPathBytes { return path }
        }
        return "/tmp/emira-\(user).sock"
    }

    // MARK: - Codec

    /// Ceiling on one framed message, so a wedged or hostile peer can't grow the read buffer forever.
    public static let maxLineBytes = 1 << 20

    /// Encode a message as one framed line: compact JSON plus a trailing `\n`. `sortedKeys` keeps the
    /// bytes deterministic for golden tests; `withoutEscapingSlashes` keeps dumped paths readable.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw WireError.encodingFailed("could not encode \(T.self): \(error)")
        }
        data.append(0x0A)                                   // the frame terminator
        return data
    }

    /// Decode one framed line (the terminating `\n` already stripped by `LineBuffer`).
    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: line)
        } catch {
            throw WireError.malformedMessage("could not decode \(T.self): \(error)")
        }
    }

    /// Read *only* the `version` field out of a framed line, whatever else the envelope looks like.
    /// `nil` means the line isn't even a JSON object with a version, i.e. genuinely malformed.
    public static func probeVersion(_ line: Data) -> Int? {
        (try? JSONDecoder().decode(VersionProbe.self, from: line))?.version
    }

    /// The minimal shape every message on this wire shares, forever.
    private struct VersionProbe: Decodable {
        let version: Int
    }

    // MARK: - Addressing

    /// Build the `sockaddr_un` for a path. `sun_path` truncates silently, so an over-long path must
    /// fail loudly here rather than bind or connect to a different socket than the one named.
    public static func socketAddress(for path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxSocketPathBytes else {
            throw WireError.socketPathTooLong(path: path, limit: maxSocketPathBytes)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        // `sockaddr_un()` zero-fills, so copying the prefix leaves the remainder NUL-terminated.
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// The address as the `sockaddr` pointer + length pair the BSD socket calls want.
    public static func withSocketAddress<Result>(
        _ address: sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) -> Result {
        withUnsafePointer(to: address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                body(pointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

/// Framing/codec failures, as opposed to command-layer ones (`Reply.failed` carries those).
public enum WireError: Error, Equatable, CustomStringConvertible {
    case lineTooLong(limit: Int)
    case malformedMessage(String)
    case encodingFailed(String)
    /// The socket path doesn't fit in `sockaddr_un.sun_path` (which would silently truncate it).
    case socketPathTooLong(path: String, limit: Int)

    public var description: String {
        switch self {
        case .lineTooLong(let limit):  return "message exceeded \(limit) bytes without a newline"
        case .malformedMessage(let detail): return "malformed message: \(detail)"
        case .encodingFailed(let detail):   return "could not encode message: \(detail)"
        case .socketPathTooLong(let path, let limit):
            return "socket path is \(path.utf8.count) bytes, over the \(limit)-byte limit: \(path)"
        }
    }
}

/// The reader half of the framing: socket chunks in, complete lines out. A stream socket gives no
/// message boundaries — one `read` can return half a request, three requests, or one and a half.
/// Empty lines and a trailing `\r` are tolerated, not reported as malformed.
public struct LineBuffer {

    /// Exceeding it throws and clears the buffer.
    public let maxLineBytes: Int

    private var pending = Data()

    public init(maxLineBytes: Int = Wire.maxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    public var pendingByteCount: Int { pending.count }

    /// Feed a chunk from the socket; get back every complete line it finished, in order. Throws
    /// `lineTooLong` if the *incomplete* remainder outgrows `maxLineBytes`, clearing the buffer first
    /// so a connection kept open resynchronizes at the next newline.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        pending.append(chunk)

        var lines: [Data] = []
        var cursor = pending.startIndex
        while let newline = pending[cursor...].firstIndex(of: 0x0A) {
            var line = pending[cursor..<newline]
            if line.last == 0x0D { line = line.dropLast() }         // tolerate CRLF
            if !line.isEmpty { lines.append(Data(line)) }
            cursor = pending.index(after: newline)
        }
        if cursor != pending.startIndex { pending = Data(pending[cursor...]) }

        if pending.count > maxLineBytes {
            pending.removeAll(keepingCapacity: false)
            throw WireError.lineTooLong(limit: maxLineBytes)
        }
        return lines
    }
}
