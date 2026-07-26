import Foundation

// The wire: where the daemon's socket lives, how bytes are framed, and what version the two ends
// agree they're speaking (IMPLEMENTATION.md §6 "the CLI/daemon seam … predictable per-user socket
// path with `0600` perms; the wire protocol is versioned from message one").
//
// **The shape, decided here.** One connection carries **one `Request` and one `Reply`**, then closes.
// `emira` is a one-shot process — parse argv, dial, write a line, print the answer, exit — so there is
// no need for request ids, multiplexing, or a session. (A future long-lived subscriber — an event
// stream for a status bar — would add an id field to the envelope; the version probe below is exactly
// what makes that a graceful change rather than a breaking one.)
//
// **Framing is JSON-lines**: one UTF-8 JSON object, one `\n`. It debugs with `nc`, needs no length
// prefix, and cannot ambiguously frame, because a non-pretty `JSONEncoder` never emits a raw newline
// — string contents are escaped as `\n` (`LineBuffer` is the reader half, and the property is
// pinned by a test).
//
// **Versioning is a probe, not a decode.** The daemon reads the version out of the line *before*
// decoding the envelope, so a client from a future (or ancient) build gets "daemon speaks v1, you
// speak v2" instead of a bewildering decode failure — the graceful mismatch §6 asks for. That is the
// entire reason `version` is a flat `Int` at the top level of every message and always will be.

/// Namespace for the protocol's constants and codec. Everything is `static` — there's no wire object
/// to own, just an agreed encoding.
public enum Wire {

    // MARK: - Version

    /// The protocol version this build speaks. Bump it whenever `Request`/`Reply` change shape in a
    /// way an older peer can't read; the mismatch is then reported, not crashed on.
    public static let version = 1

    // MARK: - Socket location

    /// Environment variable that overrides the socket path — the escape hatch for tests (each gets
    /// its own socket in a temp directory) and for running two daemons side by side.
    public static let socketEnvironmentKey = "EMIRA_SOCKET"

    /// Basename of the per-user socket.
    public static let socketName = "emira.sock"

    /// `sockaddr_un.sun_path` is 104 bytes including the NUL terminator, so a path longer than this
    /// simply cannot be bound. Enforced when *choosing* the path so the failure never reaches `bind`.
    public static let maxSocketPathBytes = 103

    /// Where the daemon listens and the CLI dials.
    ///
    /// Preference order: the `EMIRA_SOCKET` override, then `$TMPDIR` (on macOS that's the per-user,
    /// `0700`, reboot-cleaned `/var/folders/…/T/` — private by construction and short enough to bind),
    /// then a `/tmp/emira-<user>.sock` fallback.
    ///
    /// - Note: the fallback lives in a world-writable directory, so the *server* must still create the
    ///   socket `0600` and refuse a path it doesn't own — see `SocketServer` (next slice). Choosing the
    ///   path is not the same as trusting it.
    ///
    /// - Parameters:
    ///   - environment: injectable for tests; defaults to the real process environment.
    ///   - user: injectable for tests; defaults to the login name.
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

    /// Ceiling on one framed message, so a wedged or hostile peer can't grow the read buffer without
    /// bound. Generous next to a `Request` (a couple of hundred bytes) and to a `Reply.state` dump.
    public static let maxLineBytes = 1 << 20

    /// Encode a message as one framed line: compact JSON plus a trailing `\n`.
    ///
    /// `sortedKeys` makes the bytes deterministic (golden tests can compare the whole line);
    /// `withoutEscapingSlashes` keeps paths in a state dump readable when a human runs `nc`.
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

    /// Read *only* the `version` field out of a framed line, without decoding the rest.
    ///
    /// This is what makes a version mismatch diagnosable: whatever else the peer's envelope looks
    /// like, if it carries a top-level integer `version` we can say which protocol it speaks. `nil`
    /// means the line isn't even a JSON object with a version — i.e. genuinely malformed.
    public static func probeVersion(_ line: Data) -> Int? {
        (try? JSONDecoder().decode(VersionProbe.self, from: line))?.version
    }

    /// The minimal shape every message on this wire shares, forever.
    private struct VersionProbe: Decodable {
        let version: Int
    }

    // MARK: - Addressing

    /// Build the `sockaddr_un` for a path, for either end of the seam (`SocketServer.bind`,
    /// `SocketClient.connect`).
    ///
    /// It lives here, once, because this is where the 103-byte limit is *known*: `sun_path` silently
    /// truncates, so a path that doesn't fit must fail loudly at address-construction time rather than
    /// bind or connect to a different socket than the one named.
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

    /// Call `body` with the address as the `sockaddr` pointer + length pair the BSD socket calls want.
    /// Both `bind` and `connect` need this dance; neither should have to write it.
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

/// What can go wrong at the framing/codec layer, as opposed to at the command layer (`Reply.failed`
/// carries those). `CustomStringConvertible` because these reach the user through the CLI's stderr.
public enum WireError: Error, Equatable, CustomStringConvertible {
    /// A peer sent more than `limit` bytes with no newline; the buffer was dropped.
    case lineTooLong(limit: Int)
    /// A line arrived but isn't a valid message of the expected type.
    case malformedMessage(String)
    /// A value couldn't be encoded — a programming error, surfaced rather than trapped.
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

/// The reader half of the framing: bytes in (in whatever chunks the socket hands over), complete
/// lines out.
///
/// A stream socket gives no message boundaries at all — one `read` can return half a request, or
/// three requests, or a request and half of the next. This is the (pure, testable) piece that turns
/// that into messages, so `SocketServer` can be a thin loop around it.
///
/// Empty lines are skipped rather than reported as malformed: a blank line is a harmless keepalive
/// or a stray newline from a human with `nc`, not a protocol violation. A lone `\r` before the
/// newline is stripped for the same reason.
public struct LineBuffer {

    /// Ceiling on a single line; exceeding it throws and clears the buffer.
    public let maxLineBytes: Int

    /// Bytes received since the last complete line.
    private var pending = Data()

    public init(maxLineBytes: Int = Wire.maxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    /// How many bytes are buffered mid-line — for tests and for a "peer is dribbling" log.
    public var pendingByteCount: Int { pending.count }

    /// Feed a chunk from the socket; get back every complete line it finished, in order.
    ///
    /// - Throws: `WireError.lineTooLong` if the *incomplete* remainder outgrows `maxLineBytes`. The
    ///   buffer is cleared first, so a caller that keeps the connection open resynchronizes at the
    ///   next newline instead of throwing forever.
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
        // One copy per call, not one per line.
        if cursor != pending.startIndex { pending = Data(pending[cursor...]) }

        if pending.count > maxLineBytes {
            pending.removeAll(keepingCapacity: false)
            throw WireError.lineTooLong(limit: maxLineBytes)
        }
        return lines
    }
}
