import Darwin
import Foundation

// The client half of the seam: dial the daemon, write one `Request`, read one `Reply`, hang up.
// `SocketServer` (EmiraShell) is the other half, speaking the same framing and version probe.
// Blocking on purpose — `emira` is a one-shot process with no run loop and nothing else to do while
// it waits, so a blocking socket with `SO_RCVTIMEO`/`SO_SNDTIMEO` is the simplest correct thing.
// The daemon's side is the opposite and must never block its main thread.

/// What can go wrong dialing the daemon, as distinct from what the daemon *replies* (`ReplyError`).
public enum SocketClientError: Error, Equatable, CustomStringConvertible {
    /// Nothing listening — the CLI maps this, and only this, to exit code 69 (`EX_UNAVAILABLE`).
    case daemonUnreachable(path: String)
    case timedOut(seconds: TimeInterval)
    /// The connection closed before a complete reply line arrived (a daemon that crashed mid-request).
    case closedWithoutReply
    /// The mirror of `ReplyError.versionMismatch`, for when the *reply* is the unreadable message.
    case versionMismatch(daemon: Int, client: Int)
    case systemCall(String, code: Int32)

    public var description: String {
        switch self {
        case .daemonUnreachable(let path):
            return "no daemon is listening at \(path) — is emira-daemon running?"
        case .timedOut(let seconds):
            return "the daemon did not answer within \(Int(seconds))s"
        case .closedWithoutReply:
            return "the daemon closed the connection without answering"
        case .versionMismatch(let daemon, let client):
            return "protocol version mismatch: the daemon speaks v\(daemon), this client speaks "
                 + "v\(client) — install the CLI and the daemon from the same build"
        case .systemCall(let name, let code):
            return "\(name) failed: \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

/// The one-shot socket client. Stateless: one request, one reply, then close. Not `Client`
/// (`Request.swift`), which is *who* is asking; this is *how*.
public enum SocketClient {

    /// Send one request and return the daemon's reply. `timeout` bounds both the write and the wait,
    /// and is a liveness bound, not a work bound: the daemon answers *accepted*, not *completed*.
    public static func send(_ request: Request,
                            to path: String = Wire.socketPath(),
                            timeout: TimeInterval = 5) throws -> Reply {
        try decodeReply(exchange(line: try Wire.encode(request), to: path, timeout: timeout))
    }

    /// The byte-level half of `send`: write one already-framed line, return the first complete line
    /// back. Split out because the typed API can't express a malformed request, which a test must send.
    static func exchange(line: Data, to path: String, timeout: TimeInterval = 5) throws -> Data {
        let fd = try connect(to: path, timeout: timeout)
        defer { close(fd) }

        try writeAll(line, to: fd, timeout: timeout)
        // Half-close so a daemon reading to EOF sees a clean end of request instead of waiting on us.
        shutdown(fd, SHUT_WR)

        var buffer = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if received > 0 {
                // The first complete line is the answer; nothing follows it.
                if let line = try buffer.append(Data(chunk[0..<received])).first { return line }
                continue
            }
            if received == 0 { throw SocketClientError.closedWithoutReply }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketClientError.timedOut(seconds: timeout) }
            throw SocketClientError.systemCall("read", code: errno)
        }
    }

    /// Whether *something* is accepting connections at `path`. `SocketServer` uses it to tell a live
    /// daemon (refuse to steal its socket) from a socket file left by a crash (unlink and rebind).
    public static func isListening(at path: String) -> Bool {
        guard let fd = try? connect(to: path, timeout: 1) else { return false }
        close(fd)
        return true
    }

    // MARK: - Plumbing

    private static func connect(to path: String, timeout: TimeInterval) throws -> Int32 {
        let address = try Wire.socketAddress(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketClientError.systemCall("socket", code: errno) }

        var succeeded = false
        defer { if !succeeded { close(fd) } }

        // A vanished daemon must be a failed write to report, not a SIGPIPE that kills the CLI.
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var bound = timeval(tv_sec: Int(timeout),
                            tv_usec: __darwin_suseconds_t((timeout - Double(Int(timeout))) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &bound, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &bound, socklen_t(MemoryLayout<timeval>.size))

        let result = Wire.withSocketAddress(address) { pointer, length in
            Darwin.connect(fd, pointer, length)
        }
        guard result == 0 else {
            let code = errno
            // No socket file, or a socket file with nothing behind it: same story for a user.
            if code == ENOENT || code == ECONNREFUSED { throw SocketClientError.daemonUnreachable(path: path) }
            throw SocketClientError.systemCall("connect", code: code)
        }
        succeeded = true
        return fd
    }

    /// Write every byte, tolerating the short writes a stream socket is allowed to do.
    private static func writeAll(_ data: Data, to fd: Int32, timeout: TimeInterval) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketClientError.timedOut(seconds: timeout) }
                throw SocketClientError.systemCall("write", code: errno)
            }
        }
    }

    /// Decode the reply — and, if it doesn't decode, check whether it came from another build. An old
    /// CLI meeting a new daemon is as likely as the reverse, so the probe runs in this direction too.
    static func decodeReply(_ line: Data) throws -> Reply {
        do {
            return try Wire.decode(Reply.self, from: line)
        } catch {
            if let peer = Wire.probeVersion(line), peer != Wire.version {
                throw SocketClientError.versionMismatch(daemon: peer, client: Wire.version)
            }
            throw error
        }
    }
}
