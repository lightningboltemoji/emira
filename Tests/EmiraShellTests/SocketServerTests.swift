import Darwin
import Foundation
import Testing
import EmiraCore
@testable import EmiraProtocol
@testable import EmiraShell

// The IPC seam, end to end over a real unix-domain socket: `SocketClient` dials, `SocketServer`
// accepts, `RequestRouter` answers, a command lands in the pump. Also the path rules — the socket can
// resolve into world-writable `/tmp`, so each is a filesystem-destroying bug if wrong. Every client
// call goes through the `async` helpers below: the suite is `@MainActor` and the server hops to the
// main actor to reply, so a synchronous dial from a test would deadlock on the thread it needs.
@Suite @MainActor struct SocketServerTests {

    /// A unique socket path in the per-user temporary directory (short enough to bind, cleaned up by
    /// each test's `stop()`).
    static func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("emira-test-\(UUID().uuidString.prefix(8)).sock").path
    }

    static func snapshot(_ raw: UInt64) -> WindowSnapshot {
        WindowSnapshot(id: WindowId(raw), bundleId: "com.test.app", title: "w", role: .standard,
                       frame: Rect(x: 0, y: 0, width: 200, height: 200))
    }

    /// A runtime that already knows one display and three tiled windows (window 3 focused). Default
    /// width presets, so all three fit the viewport and a `focus left` snaps — no clock to settle.
    static func bootedRuntime() -> Runtime {
        let runtime = Runtime(executor: MockExecutor(mode: .simulate))
        runtime.dispatch(.screensChanged([MonitorInfo(id: MonitorId(1),
                                                      frame: Rect(x: 0, y: 0, width: 1000, height: 800))]))
        for i in 1...3 { runtime.dispatch(.windowCreated(snapshot(UInt64(i)))) }
        return runtime
    }

    /// A started server routing to `runtime`. Callers `defer { server.stop() }`.
    static func started(at path: String, routing runtime: Runtime) throws -> SocketServer {
        let server = SocketServer(path: path) { RequestRouter.reply(to: $0, from: runtime) }
        try server.start()
        return server
    }

    /// Dial from a background thread and await the answer, so the main actor stays free to run the
    /// server's handler hop.
    static func send(_ request: Request, to path: String) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try SocketClient.send(request, to: path) })
            }
        }
    }

    /// The same, at the byte level — for the requests the typed API can't express.
    static func exchange(_ line: Data, with path: String) async throws -> Reply {
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try SocketClient.exchange(line: line, to: path) })
            }
        }
        return try Wire.decode(Reply.self, from: reply)
    }

    /// Bind a socket and close the descriptor without unlinking — what a crashed daemon leaves
    /// behind: a socket file with nobody answering.
    static func leaveStaleSocket(at path: String) throws {
        let address = try Wire.socketAddress(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(Wire.withSocketAddress(address) { bind(fd, $0, $1) } == 0)
    }

    static func mode(of path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode
    }

    /// A word typed in a terminal becomes an `Event` in the core.
    @Test func aCommandRoundTripsIntoThePump() async throws {
        let path = Self.temporaryPath()
        let runtime = Self.bootedRuntime()
        let server = try Self.started(at: path, routing: runtime)
        defer { server.stop() }
        #expect(runtime.state.world.focusedWindow == WindowId(3))

        let reply = try await Self.send(Request(.focus(.left)), to: path)

        #expect(reply.outcome == .ok)
        #expect(reply.version == Wire.version)
        // The reply is sent from the same main-actor turn that dispatched, so by the time the client
        // sees `ok` the state has already moved.
        #expect(runtime.state.world.focusedWindow == WindowId(2))
    }

    /// `emira debug` must answer with the live state, and it must survive the wire intact.
    @Test func debugAnswersWithTheLiveStateAsJSON() async throws {
        let path = Self.temporaryPath()
        let runtime = Self.bootedRuntime()
        let server = try Self.started(at: path, routing: runtime)
        defer { server.stop() }

        let reply = try await Self.send(Request(.dumpState), to: path)

        guard case .state(let json) = reply.outcome else {
            Issue.record("expected a state dump, got \(reply.outcome)")
            return
        }
        // A pretty-printed dump is full of newlines, and it still arrived as exactly one framed line.
        #expect(json.contains("\n"))
        let decoded = try JSONDecoder().decode(State.self, from: Data(json.utf8))
        #expect(decoded == runtime.state)
        #expect(decoded.world.windows.count == 3)
    }

    /// A verb the reducer hasn't implemented is still accepted: the wire's job is delivery, not
    /// judgement.
    @Test func aDeferredCommandIsStillAccepted() async throws {
        let path = Self.temporaryPath()
        let server = try Self.started(at: path, routing: Self.bootedRuntime())
        defer { server.stop() }

        #expect(try await Self.send(Request(.cycleWidth), to: path).outcome == .ok)
    }

    /// The daemon probes the version before decoding, so a client from another build is told what
    /// happened.
    @Test func aClientFromAnotherBuildIsToldSoNotDecodeFailed() async throws {
        let path = Self.temporaryPath()
        let server = try Self.started(at: path, routing: Self.bootedRuntime())
        defer { server.stop() }

        let reply = try await Self.send(Request(.focus(.left), version: Wire.version + 1), to: path)

        #expect(reply.error?.code == .versionMismatch)
        #expect(reply.error?.message.contains("v\(Wire.version + 1)") == true)
        #expect(reply.version == Wire.version, "the daemon answers at its own version")
    }

    /// Garbage on the socket (a stray `nc`, a half-written line) is *answered*, then hung up on —
    /// never silently dropped, which would leave a client waiting on a reply that never comes.
    @Test func garbageIsAnsweredNotIgnored() async throws {
        let path = Self.temporaryPath()
        let server = try Self.started(at: path, routing: Self.bootedRuntime())
        defer { server.stop() }

        #expect(try await Self.exchange(Data("not json\n".utf8), with: path).error?.code
                == .malformedRequest)
        // Valid JSON with a version, wrong shape: the probe passes, the decode fails.
        #expect(try await Self.exchange(Data(#"{"version":1,"nonsense":true}"#.utf8 + [0x0A]), with: path)
                .error?.code == .malformedRequest)
    }

    /// One connection carries one request (`Wire`). A second line on the same connection is not a
    /// second command — the server stops reading at the first, answers, and closes.
    @Test func aSecondRequestOnTheSameConnectionIsNotExecuted() async throws {
        let path = Self.temporaryPath()
        let runtime = Self.bootedRuntime()
        let server = try Self.started(at: path, routing: runtime)
        defer { server.stop() }

        var both = try Wire.encode(Request(.focus(.left)))
        both.append(try Wire.encode(Request(.focus(.left))))
        #expect(try await Self.exchange(both, with: path).outcome == .ok)

        // One `focus left` from window 3, not two: focus is on 2, not 1.
        #expect(runtime.state.world.focusedWindow == WindowId(2))
    }

    // The socket path (each of these is a destructive bug if it's wrong)

    @Test func theSocketIsCreatedPrivateToThisUser() throws {
        let path = Self.temporaryPath()
        let server = try Self.started(at: path, routing: Self.bootedRuntime())
        defer { server.stop() }

        let mode = try #require(Self.mode(of: path))
        #expect(mode & 0o777 == 0o600, "the socket must not be reachable by other users")
        #expect(mode & S_IFMT == S_IFSOCK)
        #expect(server.isListening)
    }

    @Test func stopUnlinksTheSocketAndStopsListening() throws {
        let path = Self.temporaryPath()
        let server = try Self.started(at: path, routing: Self.bootedRuntime())

        server.stop()

        #expect(Self.mode(of: path) == nil, "the socket file outlived the server")
        #expect(!server.isListening)
        #expect(!SocketClient.isListening(at: path))
        server.stop()                                   // idempotent: a signal handler may double-call
    }

    /// A socket file with nobody behind it is ours to remove: a restart needs no manual cleanup.
    @Test func aStaleSocketIsReplaced() async throws {
        let path = Self.temporaryPath()
        try Self.leaveStaleSocket(at: path)
        #expect(Self.mode(of: path) != nil, "the stale socket should exist before we start")

        let server = try Self.started(at: path, routing: Self.bootedRuntime())
        defer { server.stop() }

        #expect(try await Self.send(Request(.focus(.left)), to: path).outcome == .ok)
    }

    /// …but a socket someone is *answering* on is a running daemon. The second one must exit, not
    /// steal the path — otherwise `emira` reaches whichever process won the race.
    @Test func aLiveDaemonsSocketIsNotStolen() async throws {
        let path = Self.temporaryPath()
        let first = try Self.started(at: path, routing: Self.bootedRuntime())
        defer { first.stop() }

        let second = SocketServer(path: path) { _ in .ok }
        #expect(throws: SocketServerError.alreadyRunning(path)) { try second.start() }

        // The incumbent is untouched and still answering.
        #expect(try await Self.send(Request(.focus(.left)), to: path).outcome == .ok)
        #expect(first.isListening)
    }

    /// The one that must never be got wrong: something at our path that *isn't* a socket is a user's
    /// file. Refuse — and leave it exactly where it is.
    @Test func aRegularFileAtThePathIsRefusedAndSurvives() throws {
        let path = Self.temporaryPath()
        let contents = "someone else's data"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = SocketServer(path: path) { _ in .ok }
        #expect(throws: SocketServerError.pathOccupied(path)) { try server.start() }

        #expect(try String(contentsOfFile: path, encoding: .utf8) == contents)
        #expect(!server.isListening)
    }

    /// A path that can't fit in `sockaddr_un` fails at address construction, not at `bind` — because
    /// `sun_path` truncates *silently*, and a truncated path names a different socket.
    @Test func anUnbindablyLongPathIsRefusedUpFront() {
        let long = "/tmp/" + String(repeating: "d", count: 200) + ".sock"
        let server = SocketServer(path: long) { _ in .ok }
        #expect(throws: WireError.socketPathTooLong(path: long, limit: Wire.maxSocketPathBytes)) {
            try server.start()
        }
    }
}
