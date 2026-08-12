import Foundation
import Testing

// The fence around `EmiraSettings`, which the module graph cannot draw for us: `EmiraConfig` depends on
// `EmiraCore`, so the reducer is one `import` away however the targets are arranged. The compiler can't
// check that a name is *absent*, so this does — the same trick `ConfigSchemaTests` uses to check that
// every field of `Config` is reachable from the file.

@Suite struct ImportFenceTests {

    /// The repo root, from this file rather than from a working directory: the suite has to stay
    /// hermetic, and `swift test` is run from more than one place.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The five names the settings window may not reach for. `Layout`, `Strip` and `LayoutMetrics` are
    /// deliberately absent: geometry is exactly what this module is allowed to share.
    ///
    /// **`Vocabulary` and `Verb` are absent too, and that is not an oversight.** The five here are the
    /// reducer — its state, its input, its output, and the machine between them. The vocabulary is the
    /// spellings, and offering a word is not consuming one: the keys editor composes `focus left` as
    /// text and the *schema* is where that becomes a `Command`, in another module. What would breach the
    /// fence is calling `Command.parse` to check it, which is why the panel never does — the draft is
    /// the authority on what is legal and this module is only the authority on what is offerable.
    static let forbidden = ["Engine", "State", "Event", "Effect", "Command"]

    @Test func settingsNeverNamesTheReducer() throws {
        let sources = Self.root.appending(path: "Sources/EmiraSettings")
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty, "no sources found under \(sources.path) — the fence is checking nothing")

        for file in files {
            let text = try String(contentsOf: sources.appending(path: file), encoding: .utf8)
            let code = Self.stripped(text)
            for name in Self.forbidden {
                #expect(code.range(of: "\\b\(name)\\b", options: .regularExpression) == nil, """
                EmiraSettings/\(file) names `\(name)`. This module sees the config and the geometry and \
                nothing else — see the boundary rule in EmiraSettings.swift.
                """)
            }
        }
    }

    /// `text` with its comments and string literals removed, so the fence reads code alone. The module
    /// header states the rule by naming all five, and a test that failed on the sentence explaining
    /// itself would be one nobody could write the explanation for.
    static func stripped(_ text: String) -> String {
        var code = text
        for pattern in [#"/\*[\s\S]*?\*/"#, #"//[^\n]*"#, #""(?:[^"\\\n]|\\.)*""#] {
            code = code.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return code
    }
}
