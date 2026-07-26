import Darwin
import Dispatch
import Foundation
import EmiraCore
import EmiraProtocol

// The daemon's half of the CLI seam (IMPLEMENTATION.md §6 "IPC SocketServer — the CLI/daemon seam and
// the introspection endpoint"): a unix-domain listener that turns each connection into exactly one
// `Request` → one `Reply` → close. `SocketClient` (EmiraProtocol) is the other end; both speak the
// same `Wire` framing and the same version probe.
//
// **Threading: everything here runs on one private serial queue; only the handler hops to main.**
// The `Runtime` and all core state live on the main actor, and a window manager's main thread is the
// one thing that must never stall (`PRINCIPLES.md` §5 "never block our own run loop"). So no socket
// syscall is ever issued from the main thread: `accept`, `read` and `write` all happen on `queue`, and
// the *only* main-actor work is computing the `Reply` from a decoded `Request` — a synchronous read of
// state that a client cannot make slow. A wedged or hostile peer can, at worst, occupy this one queue.
//
// **The path is never trusted, only checked.** `Wire.socketPath()` may resolve into world-writable
// `/tmp` (the fallback), so before binding we require: nothing there (bind), or a *socket* we own with
// nobody answering (a crash leftover — unlink and rebind). Anything else — a regular file, someone
// else's socket, a live daemon — is refused, and refused *without deleting it*. "Choose the path" and
// "trust the path" are different acts.
//
// **One request per connection.** After the first complete line we stop reading and answer; the reply
// means *accepted*, not *completed* (`Reply`), so the CLI is gone long before a command's real work
// (an AX teleport, a 200 ms covered scroll) finishes.

/// Why the daemon couldn't start listening. `CustomStringConvertible` because these are printed at
/// startup, where they are the entire diagnosis.
public enum SocketServerError: Error, Equatable, CustomStringConvertible {
    /// Something that isn't a socket already occupies the path. We refuse rather than delete it.
    case pathOccupied(String)
    /// A socket is there, but it belongs to another user.
    case pathNotOwned(String)
    /// A daemon is already listening there — this one should exit, not steal the socket.
    case alreadyRunning(String)
    /// A syscall failed.
    case systemCall(String, code: Int32)

    public var description: String {
        switch self {
        case .pathOccupied(let path):
            return "\(path) exists and is not a socket — refusing to remove it; "
                 + "set \(Wire.socketEnvironmentKey) to choose another path"
        case .pathNotOwned(let path):
            return "the socket at \(path) belongs to another user"
        case .alreadyRunning(let path):
            return "another emira-daemon is already listening at \(path)"
        case .systemCall(let name, let code):
            return "\(name) failed: \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

/// The unix-domain socket server the CLI dials.
///
/// ```swift
/// let server = SocketServer(path: Wire.socketPath()) { RequestRouter.reply(to: $0, from: runtime) }
/// try server.start()
/// ```
///
/// `@unchecked Sendable` with a stated invariant: **every stored property is read and written only on
/// `queue`.** `start`/`stop` bounce onto it synchronously; every source handler and continuation runs
/// on it. Nothing here is touched from the main actor except through that hop.
public final class SocketServer: @unchecked Sendable {

    /// Turn one decoded request into the reply to send. `@MainActor` because that's where the
    /// `Runtime` lives — the server hops for exactly the duration of this call and no longer.
    public typealias Handler = @MainActor @Sendable (Request) -> Reply

    /// Where we listen.
    public let path: String

    /// How long a connection may stay open without producing a complete request, or without its reply
    /// draining, before we hang up. Bounds the file descriptors a stuck client can tie up.
    public let idleTimeout: TimeInterval

    private let handler: Handler
    private let queue = DispatchQueue(label: "emira.ipc")

    // MARK: State confined to `queue`

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Open connections, keyed by a monotonic id rather than by file descriptor: descriptors are
    /// recycled the instant they close, so an id is the only handle that can't come to mean a
    /// *different* connection while a reply is in flight on the main actor.
    private var connections: [UInt64: Connection] = [:]
    private var nextConnectionId: UInt64 = 1

    public init(path: String, idleTimeout: TimeInterval = 5, handler: @escaping Handler) {
        self.path = path
        self.idleTimeout = idleTimeout
        self.handler = handler
    }

    deinit { stop() }

    // MARK: - Lifecycle

    /// Bind, listen, and begin accepting. Throws if the path can't be safely claimed.
    public func start() throws {
        try queue.sync { try startOnQueue() }
    }

    /// Stop listening, hang up every open connection, and remove the socket file. Idempotent — safe to
    /// call from a signal handler, from `deinit`, or twice.
    public func stop() {
        queue.sync { stopOnQueue() }
    }

    /// Whether the listener is up. (Test affordance and a menu-bar status source later.)
    public var isListening: Bool { queue.sync { listener >= 0 } }

    private func startOnQueue() throws {
        guard listener < 0 else { return }
        try Self.claimPath(path)

        let address = try Wire.socketAddress(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketServerError.systemCall("socket", code: errno) }
        var bound = false
        defer { if !bound { close(fd) } }

        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)          // never leak the listener into a child process
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)          // so the accept loop can drain to EAGAIN

        // The socket file inherits the process umask, so clamp it for the duration of the bind; the
        // explicit chmod afterwards covers a umask a host process might have set even tighter/looser.
        let previousMask = umask(0o177)
        let result = Wire.withSocketAddress(address) { pointer, length in
            Darwin.bind(fd, pointer, length)
        }
        let bindErrno = errno
        umask(previousMask)
        guard result == 0 else { throw SocketServerError.systemCall("bind", code: bindErrno) }
        guard chmod(path, 0o600) == 0 else { throw SocketServerError.systemCall("chmod", code: errno) }
        guard Darwin.listen(fd, 16) == 0 else { throw SocketServerError.systemCall("listen", code: errno) }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }       // the one owner of the listener's close
        source.resume()

        listener = fd
        acceptSource = source
        bound = true
    }

    private func stopOnQueue() {
        guard listener >= 0 else { return }
        for id in connections.keys { closeConnection(id) }
        acceptSource?.cancel()                      // its cancel handler closes the fd
        acceptSource = nil
        listener = -1
        unlink(path)
    }

    /// Decide whether we may bind at `path`, and clear a stale socket if that's what's there.
    ///
    /// The three refusals are deliberate and each guards a different mistake: deleting a *user's* file
    /// because it happened to sit at our path; deleting *another account's* socket; and a second daemon
    /// silently stealing the first one's socket, after which the CLI would reach whichever won the
    /// race. Only the fourth case — our own socket, nobody answering — is a leftover we may remove.
    private static func claimPath(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }              // nothing there: clean slate
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw SocketServerError.pathOccupied(path) }
        guard info.st_uid == getuid() else { throw SocketServerError.pathNotOwned(path) }
        guard !SocketClient.isListening(at: path) else { throw SocketServerError.alreadyRunning(path) }
        guard unlink(path) == 0 else { throw SocketServerError.systemCall("unlink", code: errno) }
    }

    // MARK: - Accepting

    private func acceptPending() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR { continue }
                return                                              // EAGAIN: drained
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var enabled: Int32 = 1
            // A CLI that dies mid-reply must not take the daemon with it: a failed write, not SIGPIPE.
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            beginConnection(fd: fd)
        }
    }

    private func beginConnection(fd: Int32) {
        let id = nextConnectionId
        nextConnectionId += 1
        let connection = Connection(id: id, fd: fd, maxLineBytes: Wire.maxLineBytes)
        connections[id] = connection

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.receive(id) }
        source.setCancelHandler { close(fd) }
        connection.source = source
        source.resume()

        // A peer that connects and then says nothing (or never drains its reply) gets hung up on
        // rather than holding a descriptor forever.
        queue.asyncAfter(deadline: .now() + idleTimeout) { [weak self] in self?.closeConnection(id) }
    }

    // MARK: - One request, one reply

    private func receive(_ id: UInt64) {
        guard let connection = connections[id], !connection.isAnswering else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = chunk.withUnsafeMutableBytes { read(connection.fd, $0.baseAddress, $0.count) }
            if received > 0 {
                let lines: [Data]
                do {
                    lines = try connection.buffer.append(Data(chunk[0..<received]))
                } catch {
                    answer(.failed(.malformedRequest("\(error)")), on: connection)
                    return
                }
                if let line = lines.first { handle(line, on: connection); return }
                continue                                            // partial line: keep reading
            }
            if received == 0 { closeConnection(id); return }         // peer hung up before a request
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }    // wait for the next readable event
            closeConnection(id)
            return
        }
    }

    /// Probe the version *before* decoding, so a peer from another build gets a sentence rather than a
    /// `DecodingError` about a key nobody recognizes — the graceful mismatch of IMPLEMENTATION.md §6.
    private func handle(_ line: Data, on connection: Connection) {
        guard let peer = Wire.probeVersion(line) else {
            answer(.failed(.malformedRequest("not a JSON object with a version field")), on: connection)
            return
        }
        guard peer == Wire.version else {
            answer(.failed(.versionMismatch(daemon: Wire.version, client: peer)), on: connection)
            return
        }
        let request: Request
        do {
            request = try Wire.decode(Request.self, from: line)
        } catch {
            answer(.failed(.malformedRequest("\(error)")), on: connection)
            return
        }

        connection.isAnswering = true
        let id = connection.id
        let handler = self.handler
        // The one hop to the main actor: compute the reply where the Runtime lives, then come back
        // here to write it. Capturing the id (not the connection) keeps this closure `Sendable` and
        // makes a connection that closed during the hop a lookup miss instead of a write to a reused
        // descriptor.
        DispatchQueue.main.async { [weak self] in
            let reply = MainActor.assumeIsolated { handler(request) }
            guard let self else { return }
            self.queue.async {
                guard let connection = self.connections[id] else { return }
                self.answer(reply, on: connection)
            }
        }
    }

    /// Write the reply and hang up. Failure to write is not an error worth reporting anywhere — the
    /// peer is gone, and there is no one left to tell.
    private func answer(_ reply: Reply, on connection: Connection) {
        connection.isAnswering = true
        if let line = try? Wire.encode(reply) {
            _ = sendAll(line, to: connection.fd, deadline: Date().addingTimeInterval(idleTimeout))
        }
        closeConnection(connection.id)
    }

    /// Write every byte, waiting for writability when the socket buffer fills (a state dump is far
    /// larger than the default send buffer, so partial writes are the norm, not an edge case).
    /// Bounded by `deadline`: a peer that stops reading costs us that long on this queue, never more.
    private func sendAll(_ data: Data, to fd: Int32, deadline: Date) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written; continue }
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&descriptor, 1, Int32(remaining * 1000)) > 0 else { return false }
            }
            return true
        }
    }

    private func closeConnection(_ id: UInt64) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source?.cancel()                 // its cancel handler closes the fd, exactly once
        connection.source = nil
    }
}

/// One accepted connection: a descriptor, its read source, and the bytes seen so far. Confined to the
/// server's queue like everything else, so it needs no synchronization of its own.
private final class Connection {
    let id: UInt64
    let fd: Int32
    var buffer: LineBuffer
    var source: DispatchSourceRead?
    /// Set once the request has been taken; further reads on this connection are ignored (one request
    /// per connection) and a second answer can't be written.
    var isAnswering = false

    init(id: UInt64, fd: Int32, maxLineBytes: Int) {
        self.id = id
        self.fd = fd
        self.buffer = LineBuffer(maxLineBytes: maxLineBytes)
    }
}
