import Foundation
import Testing
import EmiraCore
@testable import EmiraProtocol

// The published shape, as a consumer outside emira reads it. What a snapshot *says* about a desktop is
// `EmiraShellTests/DesktopSubjectTests`; what is pinned here is the text itself, since that is the
// contract — a bar reads keys, not Swift.

@Suite struct DesktopStatusTests {

    static let window = DesktopStatus.Window(id: WindowId(41), app: "Ghostty",
                                             bundle: "com.mitchellh.ghostty", focused: true)

    static let desktop = DesktopStatus(
        moving: false,
        focus: DesktopStatus.Focus(display: "1", workspace: WorkspaceName("1")!, window: WindowId(41),
                                   app: "Ghostty", bundle: "com.mitchellh.ghostty"),
        displays: [DesktopStatus.Display(
            id: "1", name: "Built-in Retina Display", main: true, focused: true,
            workspace: WorkspaceName("1")!, layout: .strip,
            columns: [DesktopStatus.Column(id: ColumnId(3), focused: true, app: "Ghostty",
                                           windows: [window])],
            pins: [DesktopStatus.Pin(side: .right, window: window)])],
        workspaces: [DesktopStatus.Workspace(name: WorkspaceName("1")!, display: "1", shown: true,
                                             windows: 1)])

    static func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// A merging consumer keeps whatever a line leaves out, so an absent fact is spelled `null` — the
    /// one way a line can take a fact back.
    @Test func anAbsentFactIsNullNotAMissingKey() throws {
        let empty = DesktopStatus(
            moving: true, focus: nil, displays: [],
            workspaces: [DesktopStatus.Workspace(name: .first, display: nil, shown: false, windows: 2)])
        let json = try empty.json()

        #expect(json.contains(#""focus":null"#))
        #expect(json.contains(#""display":null"#))
        let pinned = DesktopStatus.Focus(display: nil, workspace: nil, window: WindowId(1), app: "a",
                                         bundle: "b")
        let focus = try DesktopStatus(moving: false, focus: pinned, displays: [], workspaces: []).json()
        #expect(focus.contains(#""workspace":null"#))
        #expect(focus.contains(#""display":null"#))
    }

    /// The top level and every nested object carry exactly the keys the schema names, spelled as a
    /// consumer's config spells them.
    @Test func theKeysAreTheSchemas() throws {
        let top = try Self.object(try Self.desktop.json())
        #expect(Set(top.keys) == ["version", "moving", "focus", "displays", "workspaces"])
        #expect(top["version"] as? Int == DesktopStatus.currentVersion)

        let focus = try #require(top["focus"] as? [String: Any])
        #expect(Set(focus.keys) == ["display", "workspace", "window", "app", "bundle"])
        #expect(focus["window"] as? Int == 41)
        #expect(focus["workspace"] as? String == "1")

        let display = try #require((top["displays"] as? [[String: Any]])?.first)
        #expect(Set(display.keys)
                == ["id", "name", "main", "focused", "workspace", "layout", "columns", "pins"])
        #expect(display["layout"] as? String == "strip")

        let column = try #require((display["columns"] as? [[String: Any]])?.first)
        #expect(Set(column.keys) == ["id", "focused", "app", "windows"])
        let window = try #require((column["windows"] as? [[String: Any]])?.first)
        #expect(Set(window.keys) == ["id", "app", "bundle", "focused"])

        let pin = try #require((display["pins"] as? [[String: Any]])?.first)
        #expect(pin["side"] as? String == "right")

        let workspace = try #require((top["workspaces"] as? [[String: Any]])?.first)
        #expect(Set(workspace.keys) == ["name", "display", "shown", "windows"])
    }

    /// One line per snapshot: compact, with nothing in it that a line reader would split on.
    @Test func aSnapshotIsOneLine() throws {
        let json = try Self.desktop.json()
        #expect(!json.contains("\n"))
        #expect(try JSONDecoder().decode(DesktopStatus.self, from: Data(json.utf8)) == Self.desktop)
    }

    /// Sorted keys, so two snapshots of the same desktop are the same bytes.
    @Test func theSameDesktopIsTheSameText() throws {
        #expect(try Self.desktop.json() == Self.desktop.json())
        #expect(try Self.desktop.json().hasPrefix(#"{"displays":"#))
    }
}
