import Foundation
import Testing
@testable import EmiraCore

/// The exhaustive output vocabulary (IMPLEMENTATION.md §1/§3). Golden `ReplayTests` and scenario
/// tests assert against exact Effect streams, so the load-bearing properties are `Equatable`
/// comparison and a faithful `Codable` round-trip. The pinned wire shapes guard the serialized
/// contract that fixtures depend on.
@Suite struct EffectTests {

    /// One value of **every** case. This list *is* the exhaustiveness checklist — a new `Effect`
    /// case that isn't added here leaves a coverage gap the next reader can spot.
    static let all: [Effect] = [
        .setFrame(WindowId(1), Rect(x: 10, y: 20, width: 300, height: 200)),
        .park(WindowId(2), Rect(x: -1, y: 500, width: 1, height: 40)),
        .setLayerFrame(LayerId(3), Rect(x: 0, y: 0, width: 800, height: 600)),
        .capture(WindowId(4)),
        .beginTransition([LayerBinding(window: WindowId(7), layer: LayerId(8)),
                          LayerBinding(window: WindowId(9), layer: LayerId(10))]),
        .extendCover([LayerBinding(window: WindowId(11), layer: LayerId(12))]),
        .endTransition,
        .focus(WindowId(5)),
        .raise(WindowId(6)),
    ]

    @Test func everyEffectRoundTrips() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for effect in Self.all {
            let decoded = try decoder.decode(Effect.self, from: encoder.encode(effect))
            #expect(decoded == effect, "round-trip changed \(effect)")
        }
    }

    /// `setFrame` and `park` share the `(WindowId, Rect)` shape but are distinct cases — the whole
    /// point (park carries off-viewport intent, §4a). Equatable must not conflate them.
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
            Effect.beginTransition([LayerBinding(window: WindowId(7), layer: LayerId(8))])), as: UTF8.self)
        #expect(begin == #"{"beginTransition":{"_0":[{"layer":8,"window":7}]}}"#)
    }
}
