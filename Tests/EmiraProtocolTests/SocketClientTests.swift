import Foundation
import Testing
import EmiraCore
@testable import EmiraProtocol

/// The client half of the transport (`SocketClient.swift`), tested where no daemon is involved: what
/// happens when there *isn't* one, and what happens when the answer comes back from another build.
/// The happy path needs a server, so it lives in `EmiraShellTests/SocketServerTests`.
@Suite struct SocketClientTests {

    static func nonexistentPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("emira-absent-\(UUID().uuidString.prefix(8)).sock").path
    }

    /// The overwhelmingly common failure — "you didn't start the daemon" — must arrive as that
    /// sentence, and as the one error the CLI maps to `EX_UNAVAILABLE` (69) rather than a generic
    /// failure. It's the difference between a script retrying and a script giving up.
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

    /// The mismatch story has to work in *this* direction too: an old CLI meeting a newer daemon is
    /// exactly as likely as the reverse, and it's the direction where the *reply* is the message
    /// nobody can read. Without the probe this would surface as a `DecodingError` about a missing key.
    @Test func aReplyFromAnotherBuildIsAMismatchNotADecodeError() {
        let future = Data(#"{"version":99,"result":"accepted"}"#.utf8)
        #expect(throws: SocketClientError.versionMismatch(daemon: 99, client: Wire.version)) {
            try SocketClient.decodeReply(future)
        }
    }

    /// …but an unreadable reply at *our* version is a malformed message, not a version story — don't
    /// blame the build for a bug.
    @Test func anUndecodableReplyAtOurVersionStaysMalformed() {
        let broken = Data(#"{"version":1,"result":"accepted"}"#.utf8)
        #expect(throws: WireError.self) { try SocketClient.decodeReply(broken) }
    }
}
