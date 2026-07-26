import Foundation
import Testing
@testable import EmiraCore

/// The strongly-typed opaque ids that key the World/Layout state and serialize into the wire
/// protocol and replay log.
@Suite struct IdsTests {

    @Test func equalRawMeansEqualId() {
        #expect(WindowId(7) == WindowId(7))
        #expect(WindowId(7) != WindowId(8))
        #expect(WindowId(7).raw == 7)
    }

    @Test func idsSortByRaw() {
        let ids = [WindowId(3), WindowId(1), WindowId(2)]
        #expect(ids.sorted() == [WindowId(1), WindowId(2), WindowId(3)])
    }

    @Test func idsKeyDictionariesByValue() {
        var strip: [ColumnId: Int] = [:]
        strip[ColumnId(1)] = 100
        strip[ColumnId(1)] = 200   // same id overwrites
        strip[ColumnId(2)] = 300
        #expect(strip.count == 2)
        #expect(strip[ColumnId(1)] == 200)
    }

    @Test func descriptionCarriesKindAndRaw() {
        let d = WindowId(42).description
        #expect(d.contains("42"))
        #expect(d.contains("Window"))
    }

    /// Ids encode as the bare number — verify the exact wire form, not just round-trip.
    @Test func idsEncodeAsBareNumbers() throws {
        let data = try JSONEncoder().encode([WindowId(5), WindowId(7)])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json == "[5,7]")
    }

    @Test func idsDecodeFromBareNumbers() throws {
        let decoded = try JSONDecoder().decode([WorkspaceId].self, from: Data("[1,2,3]".utf8))
        #expect(decoded == [WorkspaceId(1), WorkspaceId(2), WorkspaceId(3)])
    }

    /// The point of the phantom tag: different id kinds with the same raw value are distinct types
    /// and live in separate keyspaces. (That `WindowId(1) == ColumnId(1)` doesn't even *compile*
    /// is the real guarantee — this just exercises that they coexist.)
    @Test func distinctKindsAreIndependentKeyspaces() {
        var windows: [WindowId: String] = [WindowId(1): "w"]
        let columns: [ColumnId: String] = [ColumnId(1): "c"]
        #expect(windows[WindowId(1)] == "w")
        #expect(columns[ColumnId(1)] == "c")
        windows[WindowId(1)] = nil
        #expect(columns[ColumnId(1)] == "c")   // untouched
    }
}
