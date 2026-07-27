import Foundation
import Testing
import EmiraCore
@testable import EmiraProtocol

/// The client half of the transport where no daemon is involved: no listener, or a reply from
/// another build. The happy path needs a server, so it lives in `EmiraShellTests/SocketServerTests`.
@Suite struct SocketClientTests {

    static func nonexistentPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("emira-absent-\(UUID().uuidString.prefix(8)).sock").path
    }

    /// "You didn't start the daemon" must arrive as that sentence, and as the one error the CLI maps
    /// to `EX_UNAVAILABLE` (69) — a script retries on it rather than giving up.
    @Test func dialingWhereNoDaemonListensIsUnreachable() {
        let path = Self.nonexistentPath()
        #expect(throws: SocketClientError.daemonUnreachable(path: path)) {
            try SocketClient.send(Request(.focus(.left)), to: path)
        }
        #expect(!SocketClient.isListening(at: path))
    }

    @Test func anUnbindablyLongPathFailsBeforeAnySyscall() {
        let long = "/tmp/" + String(repeating: "d", count: 200) + ".sock"
        #expect(throws: WireError.socketPathTooLong(path: long, limit: Wire.maxSocketPathBytes)) {
            try SocketClient.send(Request(.dumpState), to: long)
        }
    }

    /// The other direction: an old CLI meeting a newer daemon, where the unreadable message is the
    /// reply. Without the probe this surfaces as a `DecodingError` about a missing key.
    @Test func aReplyFromAnotherBuildIsAMismatchNotADecodeError() {
        let future = Data(#"{"version":99,"result":"accepted"}"#.utf8)
        #expect(throws: SocketClientError.versionMismatch(daemon: 99, client: Wire.version)) {
            try SocketClient.decodeReply(future)
        }
    }

    /// An unreadable reply at our own version is malformed, not a version mismatch.
    @Test func anUndecodableReplyAtOurVersionStaysMalformed() {
        let broken = Data(#"{"version":1,"result":"accepted"}"#.utf8)
        #expect(throws: WireError.self) { try SocketClient.decodeReply(broken) }
    }
}
