import Testing
import EmiraCore
@testable import EmiraConfig

// The schema driving a text surface — the thing `emira config explain` prints. What is asserted here is
// that every word of it comes off the table: a setting the schema gains is explained without anyone
// writing a sentence about it, and a setting it loses cannot be explained at all.

@Suite struct ConfigExplainTests {

    // One setting

    @Test func aSettingExplainsItselfFromTheTable() throws {
        let setting = try #require(ConfigSchema.setting(for: "layout.column-gap"))
        var config = Config()
        config.columnGap = 12

        #expect(setting.explanation(in: config) == """
        layout.column-gap — Column gap
          Points between adjacent columns on the strip.
          In points, must be at least 0.

          default  0
          current  12
        """)
    }

    /// A toggle has no legend — `true` or `false` is the whole of what it may be, and saying so is a
    /// line that reads like documentation and carries nothing.
    @Test func aToggleIsExplainedWithoutOne() throws {
        let setting = try #require(ConfigSchema.setting(for: "layout.center-focused-column"))
        #expect(setting.explanation(in: Config()) == """
        layout.center-focused-column — Center the focused column
          Center a focused column rather than scrolling the least that reveals it.

          default  false
          current  false
        """)
    }

    /// Every entry explains itself in the schema's own words, so a new setting needs no prose here and
    /// a stale sentence has nowhere to hide.
    @Test func everySettingSaysWhatItIsAndWhatItIsNow() {
        var config = Config()
        config.columnGap = 12
        for setting in ConfigSchema.settings {
            let explanation = setting.explanation(in: config)
            #expect(explanation.hasPrefix("\(setting.key) — \(setting.label)\n"))
            #expect(explanation.contains(setting.help))
            #expect(explanation.contains("default  \(setting.defaultValue.spelled)"))
            #expect(explanation.contains("current  \(setting.value(in: config).spelled)"))
            if let legend = setting.kind.legend { #expect(explanation.contains(legend)) }
        }
    }

    /// The listing is the file's shape: every key under the `[table]` it is written in, in schema order.
    @Test func theSummaryIsEverySettingGroupedTheWayTheFileGroupsThem() {
        let summary = ConfigSchema.summary(of: Config())
        let lines = summary.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for setting in ConfigSchema.settings {
            #expect(lines.contains { $0.hasPrefix("  \(setting.name) ")
                                  && $0.hasSuffix(" \(setting.defaultValue.spelled)") },
                    "\(setting.key) is missing from the listing")
        }
        // A header per distinct table, and nothing else at the left margin.
        let headers = lines.filter { $0.hasPrefix("[") }
        #expect(headers == ConfigSchema.settings.map { "[\($0.table)]" }.reduced())
        #expect(lines.allSatisfy { $0.isEmpty || $0.hasPrefix("[") || $0.hasPrefix("  ") })
    }

    /// It shows what the file says now, not what the schema says by default — the whole reason it reads
    /// the config at all.
    @Test func theSummaryShowsTheRunningValue() throws {
        var config = Config()
        config.systemFocusEvents = .ignore
        let summary = ConfigSchema.summary(of: config)
        #expect(summary.contains("system-events") && summary.contains("\"ignore\""))
        #expect(!ConfigSchema.summary(of: Config()).contains("\"ignore\""))
    }
}

extension Array where Element: Equatable {
    /// Runs of the same element collapsed to one, the way a header is printed once for the keys under it.
    fileprivate func reduced() -> [Element] {
        reduce(into: []) { unique, element in
            if unique.last != element { unique.append(element) }
        }
    }
}
