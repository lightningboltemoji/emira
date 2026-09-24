import Foundation

// Display rules: where one display is laid out differently from `[layout]`. A `[[display]]` block names
// a display by what macOS calls it and overrides some of `[layout]` there; every other display, and
// every key the block leaves alone, is `[layout]`'s.
//
// **What a display may override is what is resolved against its working area** — the file's inputs to
// `LayoutMetrics`, of which the gaps are the three here. The layout kind is a workspace's and never a
// display's (PRINCIPLES §1), and `resize-detent` and `interactive-resize` are about the hand rather than
// the screen.
//
// **A standing rule, where a window rule is a seed.** It is consulted every time a display is laid out,
// which is safe because a gap is not a fact about any window: nothing a verb owns is being decided, so
// there is no second authority to fall out of step with.

/// One `[[display]]` block: which display it names, and what it sets there. Every matcher that is set
/// must match, as a window rule's must; one with no matcher, or setting nothing, is refused at parse time.
public struct DisplayRule: Sendable, Equatable, Codable {
    /// What macOS calls the display, matched exactly — the name `emira watch` prints.
    public var name: String?
    /// That name, matched against a regular expression. Unanchored, as a window rule's patterns are.
    public var nameRegex: String?

    /// `column-gap` on this display.
    public var columnGap: Double?
    /// `window-gap` on this display.
    public var windowGap: Double?
    /// The edges of `outer-gap` this display sets; the rest stay `[layout]`'s.
    public var outerGaps: EdgeInsetsPatch

    public init(name: String? = nil, nameRegex: String? = nil,
                columnGap: Double? = nil, windowGap: Double? = nil,
                outerGaps: EdgeInsetsPatch = EdgeInsetsPatch()) {
        self.name = name
        self.nameRegex = nameRegex
        self.columnGap = columnGap
        self.windowGap = windowGap
        self.outerGaps = outerGaps
    }

    /// Whether this rule names any display at all. One that doesn't would apply to every display, which
    /// is what `[layout]` already is.
    public var hasMatcher: Bool { name != nil || nameRegex != nil }

    /// Whether this rule changes anything on the displays it names.
    public var hasOverride: Bool { columnGap != nil || windowGap != nil || !outerGaps.isEmpty }

    /// Whether this rule applies to the display called `display`.
    public func matches(_ display: String) -> Bool {
        if let name, name != display { return false }
        if let nameRegex, !WindowRule.matches(pattern: nameRegex, display) { return false }
        return hasMatcher
    }

    /// `config` with every value this rule sets written over it.
    public func apply(to config: inout Config) {
        if let columnGap { config.columnGap = columnGap }
        if let windowGap { config.windowGap = windowGap }
        config.outerGaps = outerGaps.applied(to: config.outerGaps)
    }
}

extension Config {
    /// The config as the display called `name` sees it: every `[[display]]` block naming it, applied
    /// over `[layout]` in file order — so a later block wins field by field, as a later window rule does.
    public func on(display name: String) -> Config {
        displays.reduce(into: self) { config, rule in
            if rule.matches(name) { rule.apply(to: &config) }
        }
    }
}
