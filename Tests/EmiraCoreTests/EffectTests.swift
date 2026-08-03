import Foundation
import Testing
@testable import EmiraCore

/// The exhaustive output vocabulary. Golden replays and scenario tests assert against exact `Effect`
/// streams, so the load-bearing properties are `Equatable` and a faithful `Codable` round-trip.
@Suite struct EffectTests {

    /// One value of every case — the exhaustiveness checklist. A new `Effect` case not added here
    /// leaves a coverage gap the next reader can spot.
    static let all: [Effect] = [
        .setFrame(WindowId(1), Rect(x: 10, y: 20, width: 300, height: 200)),
        .park(WindowId(2), Rect(x: -1, y: 500, width: 1, height: 40)),
        .setLayerFrame(LayerId(3), Rect(x: 0, y: 0, width: 800, height: 600)),
        .capture(MonitorId(1), WindowId(4), size: Size(width: 300, height: 200)),
        .beginTransition(MonitorId(1), [LayerBinding(window: WindowId(7), layer: LayerId(8)),
                                        LayerBinding(window: WindowId(9), layer: LayerId(10))]),
        .extendCover(MonitorId(2), [LayerBinding(window: WindowId(11), layer: LayerId(12))]),
        .elevateLayer(LayerId(14)),
        .refreshLayer(LayerId(15)),
        .endTransition(MonitorId(1)),
        .focus(WindowId(5)),
        .raise(WindowId(6)),
        .closeWindow(WindowId(13)),
        .setCursorHidden(true),
        .setCursorHidden(false),
        .warpPointer(into: Rect(x: 100, y: 100, width: 400, height: 300)),
        .exec("osascript -e 'tell application \"Ghostty\" to new window'"),
    ]

    @Test func everyEffectRoundTrips() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for effect in Self.all {
            let decoded = try decoder.decode(Effect.self, from: encoder.encode(effect))
            #expect(decoded == effect, "round-trip changed \(effect)")
        }
    }

    /// `setFrame` and `park` share the `(WindowId, Rect)` shape but are distinct cases — park carries
    /// off-viewport intent. `Equatable` must not conflate them.
    @Test func setFrameAndParkAreDistinctDespiteSamePayload() {
        let r = Rect(x: 0, y: 0, width: 100, height: 100)
        #expect(Effect.setFrame(WindowId(1), r) != Effect.park(WindowId(1), r))
    }

    /// Pin the committed wire shape for one payload case and one bare case. Chosen to carry only an
    /// integer id (which encodes as a bare number) and no `Double`, so the assertion doesn't hinge on
    /// floating-point formatting.
    @Test func effectWireShapeIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let focus = String(decoding: try encoder.encode(Effect.focus(WindowId(5))), as: UTF8.self)
        #expect(focus == #"{"focus":{"_0":5}}"#)

        // Ids encode as bare numbers, so a `beginTransition` payload carries no `Double` and its wire
        // shape is stable to pin (bindings are an ordered array of {layer, window} objects).
        let begin = String(decoding: try encoder.encode(
            Effect.beginTransition(MonitorId(1),
                                   [LayerBinding(window: WindowId(7), layer: LayerId(8))])),
                           as: UTF8.self)
        #expect(begin == #"{"beginTransition":{"_0":1,"_1":[{"layer":8,"window":7}]}}"#)
    }
}
