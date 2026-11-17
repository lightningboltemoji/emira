import Testing
import EmiraCore
@testable import EmiraConfig

// The in-memory layer over the config file. What it has to get right is small and all of it is here:
// it reads values exactly as `config set` does, a toggle is keyed on the value as well as the key, and
// it lands on top of the file the way the same line written into the file would.

@Suite struct ConfigOverridesTests {

    private static let opacity = "focus.unfocused-opacity"

    private static func file(_ text: String) throws -> Config { try Config.parse(text) }

    @Test func aSetLaysTheValueOverTheFile() throws {
        var overrides = ConfigOverrides()
        #expect(try overrides.apply(.set(key: Self.opacity, value: "1")))
        let file = try Self.file("[focus]\nunfocused-opacity = 0.5\nunfocused-blur = 8")
        let live = overrides.applied(to: file)
        #expect(live.unfocusedOpacity == 1)
        #expect(live.unfocusedBlur == 8)             // a key nobody overrode is the file's
        #expect(overrides.lines == ["focus.unfocused-opacity = 1"])
    }

    /// The binding this exists for: one press lays it, the next lifts it, and the file's value is never
    /// written anywhere but the file.
    @Test func aToggleLiftsTheOverrideItLaid() throws {
        var overrides = ConfigOverrides()
        let toggle = OverrideIntent.toggle(key: Self.opacity, value: "1")
        #expect(try overrides.apply(toggle))
        #expect(overrides.lines == ["focus.unfocused-opacity = 1"])
        #expect(try overrides.apply(toggle))
        #expect(overrides.isEmpty)
    }

    /// Keyed on the value, so two bindings on one setting each flip between theirs and the file's — and
    /// on the value as the schema reads it, so `1` and `1.0` are the same press.
    @Test func aToggleAtAnotherValueReplacesRatherThanLifts() throws {
        var overrides = ConfigOverrides()
        try overrides.apply(.set(key: Self.opacity, value: "0.8"))
        #expect(try overrides.apply(.toggle(key: Self.opacity, value: "1")))
        #expect(overrides.lines == ["focus.unfocused-opacity = 1"])
        #expect(try overrides.apply(.toggle(key: Self.opacity, value: "1.0")))
        #expect(overrides.isEmpty)
    }

    @Test func aSetThatChangesNothingSaysSo() throws {
        var overrides = ConfigOverrides()
        try overrides.apply(.set(key: Self.opacity, value: "1"))
        #expect(try !overrides.apply(.set(key: Self.opacity, value: "1")))
        #expect(try !overrides.apply(.reset(key: "focus.unfocused-blur")))
        var empty = ConfigOverrides()
        #expect(try !empty.apply(.reset(key: nil)))
    }

    /// A replaced entry keeps its place, so the menu's list does not reshuffle under a second press.
    @Test func entriesKeepTheOrderTheyWereLaidIn() throws {
        var overrides = ConfigOverrides()
        try overrides.apply(.set(key: Self.opacity, value: "1"))
        try overrides.apply(.set(key: "layout.column-gap", value: "0"))
        try overrides.apply(.set(key: Self.opacity, value: "0.9"))
        #expect(overrides.lines == ["focus.unfocused-opacity = 0.9", "layout.column-gap = 0"])
        try overrides.apply(.reset(key: Self.opacity))
        #expect(overrides.lines == ["layout.column-gap = 0"])
        try overrides.apply(.reset(key: nil))
        #expect(overrides.isEmpty)
    }

    /// The same words `config set` refuses with, and nothing laid on the way to the refusal.
    @Test func whatTheSchemaRefusesIsRefusedInItsWords() throws {
        var overrides = ConfigOverrides()
        let unknown = try #require(throws: ConfigSyntaxError.self) {
            try overrides.apply(.toggle(key: "focus.unfocused-opacty", value: "1"))
        }
        #expect(unknown.message == "unknown setting 'focus.unfocused-opacty'")
        let bad = try #require(throws: ConfigSyntaxError.self) {
            try overrides.apply(.set(key: Self.opacity, value: "-1"))
        }
        #expect(bad.message == "'focus.unfocused-opacity' must be at least 0")
        #expect(throws: ConfigSyntaxError.self) { try overrides.apply(.reset(key: "focus.nope")) }
        #expect(overrides.isEmpty)

        #expect(throws: Never.self) { try ConfigOverrides.check(.reset(key: nil)) }
        #expect(throws: ConfigSyntaxError.self) {
            try ConfigOverrides.check(.set(key: "mouse.trackpad-scroll", value: "sideways"))
        }
    }

    /// **An override lands where the same line in the file would.** Every kind the schema has, including
    /// a spring coordinate — the one setter that reads the config it writes into.
    @Test func anOverrideIsTheFileWithThatLineWritten() throws {
        let base = """
        [layout]
        column-gap = 20

        [animation.scroll]
        damping-ratio = 0.5
        """
        var overrides = ConfigOverrides()
        try overrides.apply(.set(key: "layout.column-gap", value: "4"))
        try overrides.apply(.set(key: "layout.width-presets", value: "0.5 1"))
        try overrides.apply(.set(key: "layout.center-focused-column", value: "true"))
        try overrides.apply(.set(key: "animation.window", value: "crop"))
        try overrides.apply(.set(key: "animation.scroll.stiffness", value: "400"))

        let written = try Self.file("""
        [layout]
        column-gap = 4
        width-presets = [0.5, 1]
        center-focused-column = true

        [animation]
        window = "crop"

        [animation.scroll]
        stiffness = 400
        damping-ratio = 0.5
        """)
        #expect(overrides.applied(to: try Self.file(base)) == written)
    }
}
