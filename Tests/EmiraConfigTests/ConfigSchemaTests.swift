import Foundation
import Testing
import EmiraCore
@testable import EmiraConfig

// The schema as a table, tested for the two things that being a table is *for*: that the document it
// generates is the file it describes, and that nothing can be added to `Config` without saying how it
// is configured.
//
// `ConfigSyntaxTests` is the behavioural net under all of this and it did not change when the reader
// stopped being straight-line statements. What is here is what only a table can be asked.

@Suite struct ConfigSchemaTests {

    /// The repo root, from this file rather than from a working directory or `$HOME`: the suite has to
    /// stay hermetic, and `swift test` is run from more than one place.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The golden file. Generated means it cannot drift from the reader; golden means it cannot change
    /// without a human reading the diff — and it is the file the README sends people to.
    ///
    /// `make example` regenerates it, by setting `EMIRA_UPDATE_GOLDEN` and running this test as the
    /// generator: the schema reader writes the file it is otherwise checked against, so there is no
    /// second copy of the rendering to keep in step. The diff a human is meant to read is then
    /// `git diff` rather than a failure message.
    ///
    /// Opt-in, and deliberately not something CI sets. A suite that repaired itself on the way past
    /// would answer "do the tests pass?" differently on a second run — and a CI retry would go green
    /// with a modified tree, laundering a stale file into main.
    @Test func theGeneratedDocumentIsTheGoldenFile() throws {
        let file = Self.root.appendingPathComponent("emira.example.toml")
        let updating = ProcessInfo.processInfo.environment["EMIRA_UPDATE_GOLDEN"]
        if let updating, !updating.isEmpty {
            try ConfigSchema.document.write(to: file, atomically: true, encoding: .utf8)
            return
        }
        let golden = try String(contentsOf: file, encoding: .utf8)
        #expect(ConfigSchema.document == golden, """
        emira.example.toml is stale. Run `make example` to regenerate it, and read the diff.
        """)
    }

    /// The document is a config file, not prose about one — including the three hand-written blocks,
    /// whose spellings are checked here rather than by the eye that typed them.
    @Test func theDocumentParses() throws {
        _ = try Config.parse(ConfigSchema.document)
    }

    /// …and it is the *defaults*, so a file that says none of it means exactly what it says. Everything
    /// but the two sections that have no default: no chord is bound and no rule exists until asked.
    @Test func theDocumentSaysNothingButTheDefaults() throws {
        let parsed = try Config.parse(ConfigSchema.document)
        var expected = Config()
        expected.keys = parsed.keys
        expected.windowRules = parsed.windowRules
        #expect(parsed == expected)

        #expect(parsed.keys.count == 4)
        #expect(parsed.windowRules.count == 2)
    }

    /// Every setting reaches the document, so a new entry cannot be added without being documented.
    @Test func everySettingIsWrittenDown() {
        for setting in ConfigSchema.settings {
            #expect(ConfigSchema.document.contains("\(setting.name) = "),
                    "\(setting.key) is missing from the generated document")
            #expect(ConfigSchema.document.contains(setting.help),
                    "\(setting.key)'s help is missing from the generated document")
        }
    }

    // Every field of `Config` has a config story

    /// The stored properties of `Config`, by name, described well enough to compare two of them. The
    /// compiler can't check that a field is reachable from the file, so this does — the same trick
    /// `CommandSyntax.swift` notes for the verb table.
    static func fields(of config: Config) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Mirror(reflecting: config).children.compactMap { child in
            child.label.map { ($0, String(describing: child.value)) }
        })
    }

    /// **Empty, and that is the claim**: every stored property of `Config` is either a schema entry or
    /// one of the three sections the table doesn't describe. A field added here needs a reason in
    /// writing, and the bar is that the file genuinely may not decide it — the struts were the last
    /// entry, and they left `Config` entirely rather than staying as an exemption, because they are per
    /// display and live (`MonitorInfo.struts`).
    static let notKeys: Set<String> = []

    /// A file that disagrees with the default about *everything*: every schema entry, driven off the
    /// table, plus the three bespoke sections by hand. Any field of `Config` still at its default after
    /// reading it is a field with no way to configure it.
    @Test func everyFieldOfConfigIsCoveredClaimedOrExcluded() throws {
        var tables: [(name: String, lines: [String])] = []
        for setting in ConfigSchema.settings {
            let value = Self.disagreeing(with: setting)
            #expect(value.spelled != setting.defaultValue.spelled,
                    "\(setting.key)'s generated value is its default, so it proves nothing")
            if tables.last?.name != setting.table { tables.append((setting.table, [])) }
            tables[tables.endIndex - 1].lines.append("\(setting.name) = \(value.spelled)")
        }
        // The three the table doesn't describe. Spelled out here on purpose: this test is the list of
        // what claims a field, so a section that claims one has to appear in it.
        if let layout = tables.firstIndex(where: { $0.name == "layout" }) {
            tables[layout].lines.append("outer-gap = 7")
        }
        let text = tables.map { "[\($0.name)]\n\($0.lines.joined(separator: "\n"))" }
            .joined(separator: "\n\n")
            + """


        [keys]
        alt-h = "focus left"

        [[window-rules]]
        app-id = "com.example.app"
        float = true

        """

        let config = try Config.parse(text)
        let defaults = Self.fields(of: Config())
        let unchanged = Set(Self.fields(of: config).filter { defaults[$0.key] == $0.value }.keys)

        #expect(unchanged == Self.notKeys, """
        These fields of Config came back at their default from a file that disagrees with every \
        setting the schema knows: \(unchanged.subtracting(Self.notKeys).sorted()). Each needs a schema \
        entry, a named bespoke section, or a line in `notKeys` saying why it isn't a setting.
        """)
    }

    /// A legal value for `setting` that isn't its default, built off the entry's `kind` alone — so a
    /// new setting is exercised by the test above without being named in it.
    static func disagreeing(with setting: Setting) -> TOMLValue {
        switch setting.kind {
        case .toggle:
            return .bool(setting.defaultValue.spelled != "true")
        case .number:
            // One more than the default clears either bound, since the default already does.
            return .number((Double(setting.defaultValue.spelled) ?? 0) + 1)
        case .choice(let words):
            let other = words.first { TOMLValue.string($0).spelled != setting.defaultValue.spelled }
            return .string(other ?? "")
        case .sizeList:
            return .array([.number(0.25)])
        }
    }

    // A value from a word

    /// The round trip that makes `emira config get` and `emira config set` the same vocabulary: what a
    /// setting prints is what it reads. Driven off the table, so a new entry is exercised without being
    /// named — and off `disagreeing`, so it is exercised on a value that isn't the default's spelling.
    @Test func everySettingReadsBackWhateverItPrints() throws {
        for setting in ConfigSchema.settings {
            for value in [setting.defaultValue, Self.disagreeing(with: setting)] {
                let read = try setting.value(from: value.spelled)
                #expect(read.spelled == value.spelled, "\(setting.key) did not read back \(value.spelled)")
            }
            #expect(setting.isDefault(try setting.value(from: setting.defaultValue.spelled)))
        }
    }

    /// A word refused by the *codec*, so the complaint is the file's own sentence rather than a second
    /// one written for the command line. The line is dropped by the caller: there isn't one.
    @Test func aWordThatIsNotTheKindIsRefusedInTheFilesWords() throws {
        func refusal(_ key: String, _ text: String) -> String? {
            guard let setting = ConfigSchema.setting(for: key) else { return "no such setting" }
            do {
                _ = try setting.value(from: text)
                return nil
            } catch let error as ConfigSyntaxError {
                return error.message
            } catch {
                return "\(error)"
            }
        }
        #expect(refusal("layout.column-gap", "eight") == "'layout.column-gap' must be a number, not a string")
        #expect(refusal("layout.column-gap", "-5") == "'layout.column-gap' must be at least 0")
        #expect(refusal("animation.scroll.stiffness", "0")
                == "'animation.scroll.stiffness' must be greater than 0")
        #expect(refusal("layout.center-focused-column", "yes")
                == "'layout.center-focused-column' must be true or false, not a string")
        #expect(refusal("focus.system-events", "adopt")
                == "'focus.system-events' must be \"respect\" or \"on-screen\" or \"ignore\", not \"adopt\"")
        #expect(refusal("layout.width-presets", "") == "'layout.width-presets' must list at least one width")
        #expect(refusal("layout.width-presets", "0.5 wide")
                == "'layout.width-presets' must be a number, not a string")
    }

    /// A shell eats the quotes the file wants and splits a list on its spaces, so a word arrives in
    /// spellings the file would never carry — and every one of them means the same value.
    @Test func aWordIsReadAsATerminalHandsItOver() throws {
        let choice = try #require(ConfigSchema.setting(for: "focus.system-events"))
        for spelling in ["ignore", "\"ignore\"", "'ignore'"] {
            #expect(try choice.value(from: spelling).spelled == "\"ignore\"")
        }
        let list = try #require(ConfigSchema.setting(for: "layout.width-presets"))
        for spelling in ["[0.5, 1]", "0.5, 1", "0.5 1", "0.5,1"] {
            #expect(try list.value(from: spelling).spelled == "[0.5, 1]")
        }
    }

    /// The table is the whole of what a key can name. The three sections it doesn't describe are on the
    /// wrong side of it on purpose: they are edited as blocks, not one value at a time.
    @Test func onlyTheTablesOwnKeysResolve() {
        for setting in ConfigSchema.settings {
            #expect(ConfigSchema.setting(for: setting.key)?.key == setting.key)
        }
        #expect(ConfigSchema.setting(for: "layout.colum-gap") == nil)
        #expect(ConfigSchema.setting(for: "layout") == nil)
        #expect(ConfigSchema.setting(for: "keys.alt-h") == nil)
        #expect(ConfigSchema.setting(for: "window-rules") == nil)
    }

    // The table's own shape

    /// A `Kind` case nothing spells is a shape the table carries for free — the cases are the forms a TOML
    /// value comes in, so *used at all* is the test and a census of the settings is not. The four are
    /// listed by hand, `Kind` having associated values and so no `CaseIterable`: **a fifth case must be
    /// added to the list as well as to the switch, or it goes unchecked.**
    @Test func everyKindCaseServesASetting() {
        var uses: [String: Int] = [:]
        for setting in ConfigSchema.settings {
            let name: String
            switch setting.kind {
            case .toggle:   name = "toggle"
            case .number:   name = "number"
            case .choice:   name = "choice"
            case .sizeList: name = "sizeList"
            }
            uses[name, default: 0] += 1
        }
        for kind in ["toggle", "number", "choice", "sizeList"] {
            #expect(uses[kind, default: 0] > 0, "\(kind) serves no setting — it is a shape nothing spells")
        }
    }

    /// Keys are unique, and each is spelled under a table the reader accepts. A duplicate would make
    /// the second entry dead code: `take` is destructive, so the first one wins and nothing says so.
    @Test func everyKeyIsDistinctAndSitsInADeclaredTable() {
        var seen: Set<String> = []
        for setting in ConfigSchema.settings {
            #expect(seen.insert(setting.key).inserted, "\(setting.key) appears twice in the table")
            #expect(ConfigSchema.tables.contains(setting.table))
        }
    }
}
