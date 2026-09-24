import Darwin
import Foundation
import Testing
import EmiraCore
@testable import EmiraProtocol
@testable import EmiraShell

// `watch` over a real unix-domain socket: the connection that stays open. What a line says is
// `DesktopPublisherTests`; what is asserted here is the carrying — the first line at once, the next on
// a change, the newest rather than every one to a slow reader, and a watcher leaving noticed however it
// leaves. `@MainActor` for `SocketServerTests`' reason: every read is off-actor so the hop can land.

/// A watcher at the byte level. It reads only when asked, which is what a slow reader, a half-close
/// and a hang-up need and the CLI's client cannot be made to do.
final class RawWatcher: @unchecked Sendable {
    let fd: Int32
    private var buffer = LineBuffer(maxLineBytes: 1 << 24)
    private var lines: [Data] = []

    init(path: String, request: Request = Request(.watch)) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        // A line that never comes fails the test rather than hanging it.
        var bound = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &bound, socklen_t(MemoryLayout<timeval>.size))
        let address = try Wire.socketAddress(for: path)
        guard Wire.withSocketAddress(address, { connect(fd, $0, $1) }) == 0 else {
            throw SocketClientError.daemonUnreachable(path: path)
        }
        let line = try Wire.encode(request)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// The next reply, read on a background thread so the main actor stays free for the server's hop.
    func next() async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try self.nextNow() })
            }
        }
    }

    private func nextNow() throws -> Reply {
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while lines.isEmpty {
            let received = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard received > 0 else { throw SocketClientError.closedWithoutReply }
            lines += try buffer.append(Data(chunk[0..<received]))
        }
        return try Wire.decode(Reply.self, from: lines.removeFirst())
    }

    func close() { Darwin.close(fd) }
}

/// Lines a background client collects, read from the test.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var count: Int { lock.withLock { lines.count } }
    var all: [String] { lock.withLock { lines } }
}

@Suite @MainActor struct WatchStreamTests {

    static func desktop(_ reply: Reply) throws -> DesktopStatus {
        guard case .desktop(let json) = reply.outcome else {
            throw WireError.malformedMessage("expected a desktop, got \(reply.outcome)")
        }
        return try JSONDecoder().decode(DesktopStatus.self, from: Data(json.utf8))
    }

    /// Wait for something the server does on its own queue, giving the main actor back meanwhile.
    static func eventually(within seconds: TimeInterval = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// The first line is the desktop as it stands, the next arrives when it changes — and the ordinary
    /// requests on other connections are answered and closed exactly as before.
    @Test func aWatchIsAnsweredAtOnceAndAgainOnAChange() async throws {
        let path = SocketServerTests.temporaryPath()
        let runtime = SocketServerTests.bootedRuntime()
        let server = try SocketServerTests.started(at: path, routing: runtime)
        defer { server.stop() }
        let watcher = try RawWatcher(path: path)
        defer { watcher.close() }

        let first = try await watcher.next()
        #expect(first.version == Wire.version)
        #expect(try Self.desktop(first).focus?.window == WindowId(3))
        #expect(try Self.desktop(first).displays.first?.columns.count == 3)

        #expect(try await SocketServerTests.send(Request(.focus(.left)), to: path).outcome == .ok)
        #expect(try Self.desktop(try await watcher.next()).focus?.window == WindowId(2))

        guard case .state = try await SocketServerTests.send(Request(.dumpState), to: path).outcome else {
            Issue.record("debug should still be answered while someone watches")
            return
        }
    }

    /// Every line is a whole snapshot, so a watcher that stops reading is owed only the newest: the
    /// ones in between are dropped at the server, and the one it gets is never torn.
    @Test func aSlowWatcherIsSentTheNewestLineNotEveryLine() async throws {
        let path = SocketServerTests.temporaryPath()
        let server = try SocketServerTests.started(at: path, routing: SocketServerTests.bootedRuntime())
        defer { server.stop() }
        let watcher = try RawWatcher(path: path)
        defer { watcher.close() }
        _ = try await watcher.next()

        // Far more than a socket buffer holds, sent while nobody reads.
        let sent = 40
        let padding = String(repeating: "x", count: 100_000)
        for index in 0..<sent { server.broadcast(.desktop(json: "\(index)|\(padding)")) }
        try await Task.sleep(for: .milliseconds(300))

        var received: [String] = []
        while received.last?.hasPrefix("\(sent - 1)|") != true {
            guard case .desktop(let json) = try await watcher.next().outcome else { break }
            received.append(json)
        }
        #expect(received.count < sent / 2, "the lines in between should have been dropped")
        #expect(received.last?.hasPrefix("\(sent - 1)|") == true)
    }

    /// The idle deadline is for a peer that never speaks or never reads, and a watcher is neither — it
    /// is quiet for exactly as long as the desktop is.
    @Test func aWatcherOutlivesTheIdleDeadline() async throws {
        let path = SocketServerTests.temporaryPath()
        let server = try SocketServerTests.started(at: path, routing: SocketServerTests.bootedRuntime(),
                                                   idleTimeout: 0.3)
        defer { server.stop() }
        let watcher = try RawWatcher(path: path)
        defer { watcher.close() }
        _ = try await watcher.next()

        try await Task.sleep(for: .milliseconds(800))
        server.broadcast(.desktop(json: "{}"))
        #expect(try await watcher.next().outcome == .desktop(json: "{}"))
    }

    /// Gone is noticed when it happens rather than at the next change, so nothing is built for a
    /// watcher that has left.
    @Test func aWatcherThatHangsUpIsForgotten() async throws {
        let path = SocketServerTests.temporaryPath()
        let server = try SocketServerTests.started(at: path, routing: SocketServerTests.bootedRuntime())
        defer { server.stop() }
        let watcher = try RawWatcher(path: path)
        _ = try await watcher.next()
        #expect(server.isWatched)

        watcher.close()
        #expect(try await Self.eventually { !server.isWatched })
    }

    /// Closing only the write half is a peer with nothing more to say, not a peer that has gone — the
    /// way `nc` ends a request — and it goes on being sent the desktop.
    @Test func aWatcherThatOnlyStopsTalkingIsStillSent() async throws {
        let path = SocketServerTests.temporaryPath()
        let server = try SocketServerTests.started(at: path, routing: SocketServerTests.bootedRuntime())
        defer { server.stop() }
        let watcher = try RawWatcher(path: path)
        defer { watcher.close() }
        _ = try await watcher.next()

        shutdown(watcher.fd, SHUT_WR)
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.isWatched)
        server.broadcast(.desktop(json: "{}"))
        #expect(try await watcher.next().outcome == .desktop(json: "{}"))
    }

    /// A `watch` from another build is refused like any request, before it counts as a watcher.
    @Test func aWatchFromAnotherBuildIsRefusedLikeAnyRequest() async throws {
        let path = SocketServerTests.temporaryPath()
        let server = try SocketServerTests.started(at: path, routing: SocketServerTests.bootedRuntime())
        defer { server.stop() }

        let reply = try await SocketServerTests.send(Request(.watch, version: Wire.version + 1), to: path)
        #expect(reply.error?.code == .versionMismatch)
        #expect(!server.isWatched)
    }

    /// The CLI's own client: every snapshot's JSON, as it comes, until the daemon goes — which it hears
    /// as the stream ending, the one way `emira watch` exits.
    @Test func theClientStreamsUntilTheDaemonGoes() async throws {
        let path = SocketServerTests.temporaryPath()
        let runtime = SocketServerTests.bootedRuntime()
        let server = try SocketServerTests.started(at: path, routing: runtime)
        let lines = Collected()
        let ended = Task.detached { () -> (any Error)? in
            do {
                try SocketClient.watch(to: path, timeout: SocketServerTests.timeout) { lines.append($0) }
            } catch {
                return error
            }
        }

        #expect(try await Self.eventually { lines.count == 1 })
        #expect(try await SocketServerTests.send(Request(.focus(.left)), to: path).outcome == .ok)
        #expect(try await Self.eventually { lines.count == 2 })
        server.stop()

        #expect(await ended.value as? SocketClientError == .streamEnded)
        let focus = try lines.all.map {
            try JSONDecoder().decode(DesktopStatus.self, from: Data($0.utf8)).focus?.window
        }
        #expect(focus == [WindowId(3), WindowId(2)])
    }
}
