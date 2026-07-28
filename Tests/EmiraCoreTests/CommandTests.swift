import Foundation
import Testing
@testable import EmiraCore

/// The command vocabulary and its supporting enums. These types cross the socket and land in the
/// replay log, so the load-bearing property is a faithful `Codable` round-trip.
@Suite struct CommandTests {

    // MARK: Direction

    @Test func directionOppositeIsInvolutive() {
        for d in Direction.allCases {
            #expect(d.opposite.opposite == d)          // flipping twice is identity
            #expect(d.opposite != d)
        }
        #expect(Direction.left.opposite == .right)
        #expect(Direction.up.opposite == .down)
    }

    @Test func directionAxisSplitsHorizontalFromVertical() {
        #expect(Direction.left.axis == .horizontal)
        #expect(Direction.right.axis == .horizontal)
        #expect(Direction.up.axis == .vertical)
        #expect(Direction.down.axis == .vertical)
    }

    @Test func directionEncodesAsItsName() throws {
        let data = try JSONEncoder().encode([Direction.left, .up])
        #expect(String(decoding: data, as: UTF8.self) == #"["left","up"]"#)
    }

    // MARK: Toggle

    @Test func toggleResolvesAgainstCurrentState() {
        #expect(Toggle.on.resolved(current: false) == true)
        #expect(Toggle.on.resolved(current: true) == true)
        #expect(Toggle.off.resolved(current: true) == false)
        #expect(Toggle.off.resolved(current: false) == false)
        #expect(Toggle.toggle.resolved(current: true) == false)
        #expect(Toggle.toggle.resolved(current: false) == true)
    }

    // MARK: Codable round-trips — the contract that matters

    /// Every command, including one carrying each supporting-enum shape, survives encode→decode
    /// unchanged — the guarantee the CLI↔daemon wire and the replay log depend on.
    @Test func everyCommandRoundTrips() throws {
        let commands: [Command] = [
            .focus(.left), .focus(.right), .focus(.up), .focus(.down),
            .moveWindow(.left), .moveWindow(.down),
            .moveToWorkspace(.name(WorkspaceName("3")!)), .moveToWorkspace(.next),
            .moveToWorkspace(.previous), .moveToWorkspaceAndFocus(.nextOccupied),
            .cycleWidth, .cycleHeight,
            .grow(.points(100)), .grow(.percent(10)),
            .shrink(.points(12.5)), .shrink(.percent(5)),
            .consumeOrExpel(.left), .consumeOrExpel(.right),
            .fullscreen(.on), .fullscreen(.off), .fullscreen(.toggle),
            .float(.on), .float(.toggle),
            .focusWorkspace(.name(WorkspaceName("a")!)), .focusWorkspace(.next),
            .focusWorkspace(.previousOccupied),
            .closeWindow, .centerColumn, .dumpState,
            .exec("osascript -e 'tell application \"Ghostty\" to new window'"),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for command in commands {
            let decoded = try decoder.decode(Command.self, from: encoder.encode(command))
            #expect(decoded == command, "round-trip changed \(command)")
        }
    }

    @Test func workspaceRefsRoundTrip() throws {
        let workspaceRefs: [WorkspaceRef] = [
            .name(.first), .name(.last), .name(WorkspaceName("7")!),
            .next, .previous, .nextOccupied, .previousOccupied,
        ]
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for r in workspaceRefs {
            #expect(try decoder.decode(WorkspaceRef.self, from: encoder.encode(r)) == r)
        }
    }

    /// Pin the committed wire shape for one payload-carrying case and one bare case, so a change to the
    /// serialized contract is a deliberate, test-visible act.
    @Test func commandWireShapeIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let focus = String(decoding: try encoder.encode(Command.focus(.left)), as: UTF8.self)
        #expect(focus == #"{"focus":{"_0":"left"}}"#)

        let bare = String(decoding: try encoder.encode(Command.closeWindow), as: UTF8.self)
        #expect(bare == #"{"closeWindow":{}}"#)
    }
}
