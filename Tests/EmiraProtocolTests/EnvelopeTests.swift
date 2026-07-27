import Foundation
import Testing
import EmiraCore
@testable import EmiraProtocol

/// The envelope: every command survives the wire unchanged, the three outcomes round-trip, and a
/// version mismatch produces a readable failure rather than a decode error.
@Suite struct EnvelopeTests {

    /// Round-trips through the real codec, not a bare `JSONEncoder`, so framing is part of the test.
    static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let line = try Wire.encode(value)
        return try Wire.decode(T.self, from: Data(line.dropLast()))
    }

    // MARK: - Request

    @Test func everyCommandSurvivesTheEnvelope() throws {
        for command in CommandSamples.all {
            let request = Request(command, client: Client(pid: 4821))
            let decoded = try Self.roundTrip(request)
            #expect(decoded == request, "round-trip changed \(command)")
            #expect(decoded.command == command)
        }
    }

    @Test func aRequestDefaultsToThisProcessAndThisVersion() {
        let request = Request(.centerColumn)
        #expect(request.version == Wire.version)
        #expect(request.client.pid == ProcessInfo.processInfo.processIdentifier)
    }

    /// The envelope carries the vocabulary verbatim — no translation layer, so a new `Command` case
    /// needs no change here.
    @Test func theWireShapeKeepsVersionFlatAndCommandVerbatim() throws {
        let line = try Wire.encode(Request(.focus(.left), client: Client(pid: 7)))
        let text = String(decoding: line.dropLast(), as: UTF8.self)
        #expect(text == #"{"client":{"pid":7},"command":{"focus":{"_0":"left"}},"version":1}"#)
    }

    // MARK: - Reply

    @Test func allThreeOutcomesRoundTrip() throws {
        let replies: [Reply] = [
            .ok,
            .failed(.versionMismatch(daemon: 1, client: 2)),
            .failed(.malformedRequest("unexpected end of JSON")),
            .failed(.internalError("the executor is gone")),
            .state(json: #"{"windows":[1,2,3]}"#),
        ]
        for reply in replies {
            #expect(try Self.roundTrip(reply) == reply, "round-trip changed \(reply)")
        }
    }

    @Test func onlyAFailureCarriesAnError() {
        #expect(Reply.ok.error == nil)
        #expect(Reply.state(json: "{}").error == nil)
        #expect(Reply.failed(.internalError("boom")).error?.code == .internalError)
    }

    /// The mismatch message has to name both versions, so the user reads "reinstall the matching
    /// build" rather than a decode error.
    @Test func theVersionMismatchMessageNamesBothVersions() {
        let error = ReplyError.versionMismatch(daemon: 1, client: 2)
        #expect(error.code == .versionMismatch)
        #expect(error.message.contains("v1"))
        #expect(error.message.contains("v2"))
        #expect("\(error)" == error.message)      // printable straight to stderr
    }

    /// The daemon probes the version before decoding, so a request it can't decode still yields a
    /// sentence naming both versions.
    @Test func aFutureClientGetsAMismatchNotADecodeError() throws {
        let futureLine = Data(#"{"client":{"pid":9},"verb":"focus left","version":2}"#.utf8)

        let reply: Reply
        if let claimed = Wire.probeVersion(futureLine), claimed != Wire.version {
            reply = .failed(.versionMismatch(daemon: Wire.version, client: claimed))
        } else {
            reply = (try? Wire.decode(Request.self, from: futureLine)).map { _ in Reply.ok }
                 ?? .failed(.malformedRequest("undecodable"))
        }

        #expect(reply.error?.code == .versionMismatch)
        #expect(try Self.roundTrip(reply) == reply)
    }

    @Test func anErrorCodeIsAStableString() throws {
        for code in ReplyError.Code.allCases {
            let encoded = String(decoding: try JSONEncoder().encode(code), as: UTF8.self)
            #expect(encoded == "\"\(code.rawValue)\"")
        }
    }
}

/// One of every `Command` case, restated here because this target can't see into `EmiraCoreTests`.
enum CommandSamples {
    static let all: [Command] = [
        .focus(.left), .focus(.down),
        .moveWindow(.right), .moveWindow(.up),
        .moveToWorkspace(.name(WorkspaceName("3")!)), .moveToWorkspace(.next),
        .moveToWorkspace(.previous), .moveToWorkspace(.nextOccupied),
        .moveToWorkspaceAndFocus(.name(WorkspaceName("a")!)),
        .moveToWorkspaceAndFocus(.previousOccupied),
        .moveToMonitor(.direction(.left)), .moveToMonitor(.index(2)), .moveToMonitor(.next),
        .moveToMonitor(.previous),
        .cycleWidth, .cycleHeight,
        .consumeOrExpel(.right),
        .fullscreen(.on), .fullscreen(.off), .fullscreen(.toggle),
        .float(.on), .float(.toggle),
        .focusWorkspace(.name(.first)), .focusWorkspace(.next), .focusWorkspace(.previous),
        .focusWorkspace(.nextOccupied), .focusWorkspace(.previousOccupied),
        .closeWindow, .centerColumn, .reloadConfig, .dumpState,
    ]
}
