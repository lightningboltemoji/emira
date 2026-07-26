import Foundation
import Testing
import EmiraCore
@testable import EmiraProtocol

/// The framing and codec (`Wire.swift`). A stream socket has no message boundaries, so everything
/// here is about the one guarantee that makes JSON-lines safe: **exactly one message per line, and a
/// newline never appears inside one**. Plus the socket-path policy and the version probe, which is
/// what turns a peer-from-another-build into a sentence instead of a decode error.
@Suite struct WireTests {

    // MARK: - Framing

    @Test func encodingProducesOneNewlineTerminatedLine() throws {
        let line = try Wire.encode(Request(.focus(.left), client: Client(pid: 42)))
        #expect(line.last == 0x0A)
        #expect(line.dropLast().firstIndex(of: 0x0A) == nil, "a newline inside the frame")
    }

    /// The property the whole framing rests on: a payload full of newlines still encodes to *one*
    /// line, because JSON escapes them. A state dump is exactly such a payload.
    @Test func newlinesInAPayloadAreEscapedNotEmitted() throws {
        let pretty = "{\n  \"windows\": [\n    1,\n    2\n  ]\n}"
        let line = try Wire.encode(Reply.state(json: pretty))
        #expect(line.dropLast().firstIndex(of: 0x0A) == nil)

        var buffer = LineBuffer()
        let lines = try buffer.append(line)
        #expect(lines.count == 1)
        let decoded = try Wire.decode(Reply.self, from: lines[0])
        #expect(decoded.outcome == .state(json: pretty))
    }

    @Test func decodingGarbageThrowsMalformed() {
        #expect(throws: WireError.self) {
            try Wire.decode(Request.self, from: Data("not json".utf8))
        }
        // Valid JSON, wrong shape.
        #expect(throws: WireError.self) {
            try Wire.decode(Request.self, from: Data(#"{"version":1}"#.utf8))
        }
    }

    // MARK: - Version probe

    @Test func probeReadsTheVersionOfAMessageItCannotDecode() throws {
        // A hypothetical v2 envelope: the command payload has moved, so `Request` can't decode it —
        // but the version is still legible, which is the whole point.
        let future = Data(#"{"client":{"pid":7},"verb":"focus left","version":2}"#.utf8)
        #expect(Wire.probeVersion(future) == 2)
        #expect(throws: WireError.self) { try Wire.decode(Request.self, from: future) }
    }

    @Test func probeReturnsNilForSomethingThatIsNotAMessage() {
        #expect(Wire.probeVersion(Data("not json".utf8)) == nil)
        #expect(Wire.probeVersion(Data(#"{"command":{"closeWindow":{}}}"#.utf8)) == nil)
        #expect(Wire.probeVersion(Data()) == nil)
    }

    @Test func bothDirectionsCarryTheVersion() throws {
        #expect(Wire.probeVersion(try Wire.encode(Request(.closeWindow))) == Wire.version)
        #expect(Wire.probeVersion(try Wire.encode(Reply.ok)) == Wire.version)
    }

    // MARK: - LineBuffer

    @Test func oneChunkCanHoldSeveralLines() throws {
        var buffer = LineBuffer()
        let lines = try buffer.append(Data("a\nbb\nccc\n".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["a", "bb", "ccc"])
        #expect(buffer.pendingByteCount == 0)
    }

    /// The case a stream socket actually produces: a message split across reads, and the start of the
    /// next one trailing along behind it.
    @Test func aLineSplitAcrossChunksIsReassembled() throws {
        var buffer = LineBuffer()
        #expect(try buffer.append(Data(#"{"version":1,"#.utf8)).isEmpty)
        #expect(buffer.pendingByteCount > 0)

        let lines = try buffer.append(Data("\"rest\":true}\n{\"next\"".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"version":1,"rest":true}"#])
        #expect(buffer.pendingByteCount == 7, "the start of the next message stays buffered")
    }

    @Test func blankLinesAndCarriageReturnsAreTolerated() throws {
        var buffer = LineBuffer()
        let lines = try buffer.append(Data("\n\r\nhello\r\n\nworld\n".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["hello", "world"])
    }

    /// A peer that never sends a newline must not be able to grow our buffer without bound — and the
    /// connection resynchronizes at the next newline rather than throwing forever.
    @Test func anOverlongLineThrowsAndClearsTheBuffer() throws {
        var buffer = LineBuffer(maxLineBytes: 16)
        #expect(try buffer.append(Data(repeating: 0x41, count: 16)).isEmpty)  // exactly at the limit

        #expect(throws: WireError.lineTooLong(limit: 16)) {
            try buffer.append(Data(repeating: 0x41, count: 1))
        }
        #expect(buffer.pendingByteCount == 0)

        let lines = try buffer.append(Data("ok\n".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["ok"])
    }

    @Test func aFullRoundTripSurvivesTheBuffer() throws {
        let sent = [Request(.focus(.right)), Request(.moveToWorkspace(.index(2))), Request(.dumpState)]
        var stream = Data()
        for request in sent { stream.append(try Wire.encode(request)) }

        var buffer = LineBuffer()
        // Deliver the whole stream one byte at a time — the worst framing a socket can hand us.
        var received: [Request] = []
        for byte in stream {
            for line in try buffer.append(Data([byte])) {
                received.append(try Wire.decode(Request.self, from: line))
            }
        }
        #expect(received == sent)
    }

    // MARK: - Socket path

    @Test func theEnvironmentOverrideWins() {
        let path = Wire.socketPath(environment: [Wire.socketEnvironmentKey: "/tmp/custom.sock",
                                                 "TMPDIR": "/var/folders/xx/T/"], user: "tanner")
        #expect(path == "/tmp/custom.sock")
    }

    @Test func theDefaultLivesInThePerUserTemporaryDirectory() {
        let path = Wire.socketPath(environment: ["TMPDIR": "/var/folders/xx/T/"], user: "tanner")
        #expect(path == "/var/folders/xx/T/\(Wire.socketName)")
        #expect(path.utf8.count <= Wire.maxSocketPathBytes)
    }

    /// `sun_path` is 104 bytes, so an absurd `TMPDIR` has to fall back rather than produce a path
    /// `bind` would truncate. (The real default is ~50 bytes; this is the guard, not the norm.)
    @Test func anUnbindablyLongTemporaryDirectoryFallsBack() {
        let long = "/var/folders/" + String(repeating: "d", count: 120) + "/T/"
        #expect(Wire.socketPath(environment: ["TMPDIR": long], user: "tanner")
                == "/tmp/emira-tanner.sock")
        #expect(Wire.socketPath(environment: [:], user: "tanner") == "/tmp/emira-tanner.sock")
        #expect(Wire.socketPath(environment: [Wire.socketEnvironmentKey: ""], user: "tanner")
                == "/tmp/emira-tanner.sock")
    }

    @Test func theRealDefaultPathIsBindable() {
        #expect(Wire.socketPath().utf8.count <= Wire.maxSocketPathBytes)
        #expect(Wire.socketPath().hasSuffix(".sock"))
    }
}
