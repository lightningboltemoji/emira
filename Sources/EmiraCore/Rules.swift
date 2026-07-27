import Foundation

// Window rules: pure predicates over a window's metadata, deciding what happens to it *when emira first
// meets it*. Today there is one decision — which workspace it arrives on — and the shape below is built
// so the rest (float, an initial width) are fields rather than a redesign.
//
// **A rule fires once, at first sight, and is never consulted again.** That is what makes an assignment
// a starting position rather than a leash: a window sent to `3` on arrival can be moved anywhere
// afterwards and nothing drags it back. It also spares us the question a standing constraint would
// raise — a window's workspace is *derived* from the strip holding it (`Workspaces`), so a rule that
// kept applying would be a second authority on a fact that already has one.
//
// **Titles are matched as they read at first sight**, which is a real limitation rather than an
// implementation gap. Plenty of apps — Electron ones especially — create a window and set its title a
// moment later, so a title matcher can be looking at `""` or at a generic app name. `app-id` matching
// has no such weakness; prefer it, and reach for a title only to split one app's windows apart.

/// One rule from the config file: the conditions a window must meet, and what to do about it.
///
/// Every matcher that is set must match (they are AND'd); matchers that are `nil` say nothing. A rule
/// with no matcher at all would match every window on the desktop and is refused at parse time, as is
/// one that matches without doing anything.
public struct WindowRule: Sendable, Equatable, Codable {

    // MARK: Matchers

    /// The window's app, by bundle identifier, matched exactly — the stable key, unlike a title.
    public var appId: String?
    /// The window's bundle identifier, matched against a regular expression. Unanchored, so
    /// `'^com\.apple\.'` is a prefix test and `'apple'` a substring one.
    public var appIdRegex: String?
    /// The window's title at first sight, matched exactly. Exact and not substring on purpose: one
    /// silent semantic across the four matchers is worth more than the convenience, and `titleRegex`
    /// spells a substring test in a notation nobody has to be told about.
    public var title: String?
    /// The window's title at first sight, matched against a regular expression.
    public var titleRegex: String?

    // MARK: Actions

    /// The workspace this window arrives on, instead of the focused one.
    public var workspace: WorkspaceName?

    public init(appId: String? = nil, appIdRegex: String? = nil,
                title: String? = nil, titleRegex: String? = nil,
                workspace: WorkspaceName? = nil) {
        self.appId = appId
        self.appIdRegex = appIdRegex
        self.title = title
        self.titleRegex = titleRegex
        self.workspace = workspace
    }

    /// Whether this rule constrains anything at all. A rule that doesn't is a config error, not a
    /// match-everything wildcard — nobody writes one on purpose, and the failure is silent and total.
    public var hasMatcher: Bool {
        appId != nil || appIdRegex != nil || title != nil || titleRegex != nil
    }

    /// Whether this rule does anything at all — the same promise `Command` makes (`IMPLEMENTATION.md`
    /// §2): a rule you can write is a rule that has an effect.
    public var hasAction: Bool { workspace != nil }

    /// Whether this rule applies to a window with this bundle id and title. Every set matcher must
    /// agree; an unset one abstains.
    public func matches(bundleId: String, title windowTitle: String) -> Bool {
        if let appId, appId != bundleId { return false }
        if let title, title != windowTitle { return false }
        if let appIdRegex, !Self.matches(pattern: appIdRegex, bundleId) { return false }
        if let titleRegex, !Self.matches(pattern: titleRegex, windowTitle) { return false }
        return hasMatcher
    }

    /// Whether `pattern` occurs anywhere in `text`. A pattern that will not compile matches **nothing**
    /// — the config reader has already refused the file it came from, so the only way to be here with a
    /// bad pattern is a `Config` built in code, and a rule that silently matched everything would be
    /// the worse of the two ways to be wrong.
    static func matches(pattern: String, _ text: String) -> Bool {
        guard let regex = try? Regex(pattern) else { return false }
        return text.contains(regex)
    }
}

/// What a set of rules decided about one window — the fields the matching rules agreed on, merged.
/// A struct rather than a bare `WorkspaceName?` because the merge below is the *only* place precedence
/// is expressed, and every action added later is one field here and one line there.
public struct RuleOutcome: Sendable, Equatable {
    /// The workspace to place the window on, or `nil` for the focused one.
    public var workspace: WorkspaceName?

    public init(workspace: WorkspaceName? = nil) {
        self.workspace = workspace
    }
}

public enum WindowRules {

    /// Apply `rules` to a window, in file order, **later matches overriding earlier ones field by
    /// field**. So a broad rule can set a default that a narrower one below it refines, and the two
    /// never have to agree about everything to coexist. A rule that matches but leaves a field unset
    /// does not clear what an earlier one decided — it simply had no opinion.
    public static func outcome(bundleId: String, title: String,
                               in rules: [WindowRule]) -> RuleOutcome {
        var outcome = RuleOutcome()
        for rule in rules where rule.matches(bundleId: bundleId, title: title) {
            if let workspace = rule.workspace { outcome.workspace = workspace }
        }
        return outcome
    }
}
