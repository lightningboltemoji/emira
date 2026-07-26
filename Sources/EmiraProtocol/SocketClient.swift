import Darwin
import Foundation

// The client half of the seam: dial the daemon, write one `Request`, read one `Reply`, hang up
// (IMPLEMENTATION.md §4, §6). `SocketServer` (EmiraShell) is the other half; the two are written
// against the same `Wire` framing and the same version probe, in both directions.
//
// **Why it lives in `EmiraProtocol` and not in the `emira` executable.** The CLI is the one target in
// the graph that cannot be unit-tested (an executable has no importable module), so anything with real
// logic in it is untested by construction. Sockets are exactly where a protocol silently breaks —
// partial writes, a peer that hangs up mid-reply, a timeout that never fires — so the transport
// belongs on the testable side of that line, and `main.swift` gets to be "parse argv, call one
// function, print the answer". It costs the CLI nothing: `EmiraProtocol` was already its dependency,
// and this file imports nothing beyond Foundation.
//
// **Blocking on purpose.** `emira` is a one-shot process with no run loop and nothing else to do while
// it waits — a blocking socket with `SO_RCVTIMEO`/`SO_SNDTIMEO` is both the simplest correct thing and
// the fastest to launch. (The *daemon*'s side is the opposite: it must never block its main thread, so
// `SocketServer` is fully event-driven on a private queue.)

/// What can go wrong dialing the daemon, as distinct from what the daemon *replies* (`ReplyError`).
/// `CustomStringConvertible` because the CLI prints it verbatim to stderr.
public enum SocketClientError: Error, Equatable, CustomStringConvertible {
    /// Nothing is listening at the socket path — almost always "the daemon isn't running". The CLI
    /// maps this, and only this, to exit code 69 (`EX_UNAVAILABLE`).
    case daemonUnreachable(path: String)
    /// The daemon accepted the connection but didn't answer within the timeout.
    case timedOut(seconds: TimeInterval)
    /// The connection closed before a complete reply line arrived (a crashed daemon mid-request).
    case closedWithoutReply
    /// The peer's reply is from another build of the protocol. The mirror of the daemon's
    /// `ReplyError.versionMismatch`, for the case where the *reply* itself is the unreadable message.
    case versionMismatch(daemon: Int, client: Int)
    /// A syscall failed in a way that isn't one of the above.
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

/// The one-shot socket client. Stateless — there is no connection to hold, because there is no
/// session: one request, one reply, then close (`Wire`).
///
/// Not to be confused with `Client` (`Request.swift`), which is *who* is asking; this is *how*.
public enum SocketClient {

    /// Send one request and return the daemon's reply.
    ///
    /// - Parameters:
    ///   - request: the envelope to write.
    ///   - path: where the daemon listens; defaults to the resolved per-user socket.
    ///   - timeout: bound on both the write and the wait for the reply. The daemon answers
    ///     *accepted*, not *completed* (`Reply`), so this is a liveness bound, not a work bound — a
    ///     slow AX teleport can't push us past it.
    public static func send(_ request: Request,
                            to path: String = Wire.socketPath(),
                            timeout: TimeInterval = 5) throws -> Reply {
        try decodeReply(exchange(line: try Wire.encode(request), to: path, timeout: timeout))
    }

    /// The byte-level half of `send`: write one already-framed line, return the first complete line
    /// that comes back. Split out because a *malformed* request is a real case the daemon has to
    /// answer gracefully, and the typed API can't express one — this is what lets a test send the
    /// garbage a stray `nc` (or a peer from another build) would.
    static func exchange(line: Data, to path: String, timeout: TimeInterval = 5) throws -> Data {
        let fd = try connect(to: path, timeout: timeout)
        defer { close(fd) }

        try writeAll(line, to: fd, timeout: timeout)
        // We will never write again on this connection; telling the peer so means a daemon that reads
        // to EOF sees a clean end of request rather than waiting on a client that has nothing to add.
        shutdown(fd, SHUT_WR)

        var buffer = LineBuffer()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if received > 0 {
                // The first complete line is the answer; a well-behaved daemon sends nothing after it.
                if let line = try buffer.append(Data(chunk[0..<received])).first { return line }
                continue
            }
            if received == 0 { throw SocketClientError.closedWithoutReply }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketClientError.timedOut(seconds: timeout) }
            throw SocketClientError.systemCall("read", code: errno)
        }
    }

    /// Whether *something* is accepting connections at `path` — the "is a daemon already running
    /// here?" probe. Used by `SocketServer` to tell a live daemon (refuse to steal its socket) from a
    /// stale socket file left by a crash (unlink and rebind).
    public static func isListening(at path: String) -> Bool {
        guard let fd = try? connect(to: path, timeout: 1) else { return false }
        close(fd)
        return true
    }

    // MARK: - Plumbing

    /// Open a connected socket, or throw the reason we couldn't.
    private static func connect(to path: String, timeout: TimeInterval) throws -> Int32 {
        let address = try Wire.socketAddress(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketClientError.systemCall("socket", code: errno) }

        var succeeded = false
        defer { if !succeeded { close(fd) } }

        // Never let a vanished daemon kill the CLI with SIGPIPE mid-write; a failed write is an error
        // to report, not a signal.
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
            // No socket file at all, or a socket file with nothing behind it: same story for a user.
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

    /// Decode the reply — and, if it doesn't decode, check whether the reason is that it came from
    /// another build. That check is the whole point of the version being a flat top-level `Int`
    /// (`Wire.probeVersion`), and it has to work in *this* direction too: an old CLI meeting a new
    /// daemon is exactly as likely as the reverse.
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
