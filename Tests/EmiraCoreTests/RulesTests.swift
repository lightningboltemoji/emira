import Foundation
import Testing
@testable import EmiraCore

// Window rules, in two halves that fail differently: matching (does this rule apply to this window?)
// and arrival (what does the reducer do when one does). The config file's spelling of them is in
// `ConfigSyntaxTests`.

@Suite struct WindowRuleMatchingTests {

    private func name(_ c: Character) -> WorkspaceName { WorkspaceName(c)! }

    /// Every matcher a rule sets has to agree — the rule is an AND, not a "sounds about right".
    @Test func everySetMatcherMustAgree() {
        let rule = WindowRule(appId: "com.tinyspeck.slackmacgap", title: "Slack", workspace: name("3"))
        #expect(rule.matches(bundleId: "com.tinyspeck.slackmacgap", title: "Slack"))
        #expect(!rule.matches(bundleId: "com.tinyspeck.slackmacgap", title: "Huddle"))
        #expect(!rule.matches(bundleId: "com.apple.Safari", title: "Slack"))
    }

    /// An unset matcher abstains rather than failing, which is what makes a one-line rule the common
    /// case: `app-id` alone is every window of that app.
    @Test func anUnsetMatcherSaysNothing() {
        let rule = WindowRule(appId: "com.apple.Safari", workspace: name("2"))
        #expect(rule.matches(bundleId: "com.apple.Safari", title: ""))
        #expect(rule.matches(bundleId: "com.apple.Safari", title: "anything at all"))
    }

    /// `title` is exact and `title-regex` is not anchored, so the substring test people actually want
    /// is spelled in the notation everyone already reads that way.
    @Test func theExactMatchersAreExactAndTheRegexesAreNot() {
        let exact = WindowRule(title: "Huddle", workspace: name("4"))
        #expect(exact.matches(bundleId: "x", title: "Huddle"))
        #expect(!exact.matches(bundleId: "x", title: "Huddle — general"))

        let loose = WindowRule(titleRegex: "Huddle", workspace: name("4"))
        #expect(loose.matches(bundleId: "x", title: "Huddle — general"))
        #expect(loose.matches(bundleId: "x", title: "in a Huddle"))

        let anchored = WindowRule(appIdRegex: #"^com\.apple\."#, workspace: name("4"))
        #expect(anchored.matches(bundleId: "com.apple.Safari", title: ""))
        #expect(!anchored.matches(bundleId: "org.com.apple.fake", title: ""))
    }

    /// A rule with no matcher is refused by the config reader, so this can only be reached by building
    /// one in code — and the answer there is "matches nothing", never "matches the whole desktop".
    @Test func aRuleThatConstrainsNothingMatchesNothing() {
        let empty = WindowRule(workspace: name("3"))
        #expect(!empty.hasMatcher)
        #expect(!empty.matches(bundleId: "com.apple.Safari", title: "anything"))
    }

    /// Same reasoning one level down: a pattern that will not compile is refused at parse time, and if
    /// one arrives anyway it matches nothing rather than everything.
    @Test func anUncompilablePatternMatchesNothing() {
        let broken = WindowRule(appIdRegex: "com.(apple", workspace: name("3"))
        #expect(!broken.matches(bundleId: "com.apple.Safari", title: ""))
    }

    /// File order is precedence order, and it applies field by field: a later match overrides an
    /// earlier one, and a matching rule with nothing to say about a field leaves it alone.
    @Test func laterMatchesOverrideEarlierOnesFieldByField() {
        let rules = [
            WindowRule(appIdRegex: "^com\\.apple\\.", workspace: name("2")),
            WindowRule(appId: "com.apple.Safari", workspace: name("5")),
        ]
        #expect(WindowRules.outcome(bundleId: "com.apple.Safari", title: "", in: rules).workspace
                == name("5"))
        #expect(WindowRules.outcome(bundleId: "com.apple.Mail", title: "", in: rules).workspace
                == name("2"))
        #expect(WindowRules.outcome(bundleId: "com.tinyspeck.slackmacgap", title: "", in: rules)
                .workspace == nil)
    }

    /// The order is the file's, not the specificity's — putting the broad rule last really does beat
    /// the narrow one above it, which is the price of a rule that is read top to bottom.
    @Test func precedenceIsPositionalAndNotCleverAboutIt() {
        let rules = [
            WindowRule(appId: "com.apple.Safari", workspace: name("5")),
            WindowRule(appIdRegex: "^com\\.apple\\.", workspace: name("2")),
        ]
        #expect(WindowRules.outcome(bundleId: "com.apple.Safari", title: "", in: rules).workspace
                == name("2"))
    }
}

/// The reducer's half: where an assigned window lands, and what happens to focus.
@Suite struct WindowRuleArrivalTests {

    private func name(_ c: Character) -> WorkspaceName { WorkspaceName(c)! }

    /// Slack goes to `"3"`; everything else is left alone.
    private static func config(_ rules: [WindowRule]) -> Config {
        Config(widthPresets: PresetCycle([.proportion(0.5)]), smoothTransitions: false,
               windowRules: rules)
    }

    private static let slackToThree = config([
        WindowRule(appId: "com.tinyspeck.slackmacgap", workspace: WorkspaceName("3")!)
    ])

    private func arrival(_ raw: UInt64, bundle: String, alreadyOpen: Bool = false) -> Event {
        .windowCreated(EngineTests.snapshot(raw, bundle: bundle, wasAlreadyOpen: alreadyOpen))
    }

    /// The headline: a matching window starts on the workspace the rule names, without the user having
    /// gone there.
    @Test func aMatchingWindowStartsOnTheWorkspaceItsRuleNames() {
        let s = EngineTests.booted(config: Self.slackToThree)
        let (after, _) = EngineTests.run(s, [arrival(1, bundle: "com.tinyspeck.slackmacgap")])

        #expect(after.workspaces.workspace(of: WindowId(1)) == name("3"))
        #expect(after.workspaces[.first].isEmpty)
    }

    /// …and a window no rule matches is untouched by the feature — the ordinary arrival, on the strip
    /// in view.
    @Test func anUnmatchedWindowStillJoinsTheFocusedStrip() {
        let s = EngineTests.booted(config: Self.slackToThree)
        let (after, _) = EngineTests.run(s, [arrival(1, bundle: "com.apple.Safari")])

        #expect(after.workspaces.workspace(of: WindowId(1)) == .first)
        #expect(after.workspaces.focused == .first)
    }

    /// A rule naming the workspace you are already on is the ordinary arrival too, not a move to
    /// where the window already is.
    @Test func aRuleNamingTheFocusedWorkspaceChangesNothing() {
        let config = Self.config([WindowRule(appId: "com.test.app", workspace: .first)])
        let s = EngineTests.booted(config: config)
        let (after, _) = EngineTests.run(s, [arrival(1, bundle: "com.test.app")])

        #expect(after.workspaces.workspace(of: WindowId(1)) == .first)
        #expect(after.world.focusedWindow == WindowId(1))
    }

    /// A window opened *now* is one the user opened, so the workspace follows it — the same thing a
    /// Dock click on an app living elsewhere already does.
    @Test func aLiveArrivalTakesTheUserWithIt() {
        let s = EngineTests.booted(config: Self.slackToThree)
        let (after, fx) = EngineTests.run(s, [arrival(1, bundle: "com.tinyspeck.slackmacgap")])

        #expect(after.workspaces.focused == name("3"))
        #expect(after.world.focusedWindow == WindowId(1))
        #expect(fx.contains(.focus(WindowId(1))))
    }

    /// The launch scan is emira sorting a desktop nobody just asked it to sort, so it stays put — the
    /// alternative walks the user through every address they own before their first keystroke.
    @Test func theBootScanSortsTheDesktopWithoutMovingTheUser() {
        let s = EngineTests.booted(config: Self.slackToThree)
        let (after, fx) = EngineTests.run(
            s, [arrival(1, bundle: "com.tinyspeck.slackmacgap", alreadyOpen: true)])

        #expect(after.workspaces.workspace(of: WindowId(1)) == name("3"))
        #expect(after.workspaces.focused == .first)         // still home
        #expect(after.world.focusedWindow == nil)           // and focus was never claimed
        #expect(!fx.contains(.focus(WindowId(1))))
    }

    /// An assigned window is on a parked strip, so it is parked — placed, not merely recorded. Two
    /// adopted at boot get *distinct* nubs, which is the invariant the whole park model rests on.
    @Test func anAssignedWindowIsParkedAtItsOwnNub() {
        let s = EngineTests.booted(config: Self.slackToThree)
        let (after, _) = EngineTests.run(s, [
            arrival(1, bundle: "com.tinyspeck.slackmacgap", alreadyOpen: true),
            arrival(2, bundle: "com.tinyspeck.slackmacgap", alreadyOpen: true),
        ])

        let frames = after.workspaces.targetFrames(
            scrollOffset: after.motion.viewportOffset.current, metrics: after.metrics()!)
        #expect(frames[WindowId(1)] != nil)
        #expect(frames[WindowId(1)] != frames[WindowId(2)])
    }

    /// The rule fires at first sight and never again: a window moved off its assigned workspace by
    /// hand stays where it was put, and being minimized and restored does not re-post it either.
    @Test func theRuleIsNeverConsultedTwice() {
        let s = EngineTests.booted(config: Self.slackToThree)
        var (after, _) = EngineTests.run(s, [arrival(1, bundle: "com.tinyspeck.slackmacgap")])
        #expect(after.workspaces.focused == name("3"))

        // Moved by hand to "7" — the freedom the whole design is for.
        (after, _) = EngineTests.run(after, [.command(.moveToWorkspace(.name(name("7"))))])
        #expect(after.workspaces.workspace(of: WindowId(1)) == name("7"))

        // Minimized and restored, from a different workspace: it lands where the user is.
        (after, _) = EngineTests.run(after, [
            .windowMinimized(WindowId(1)),
            .command(.focusWorkspace(.name(name("9")))),
            .windowDeminimized(WindowId(1)),
        ])
        #expect(after.workspaces.workspace(of: WindowId(1)) == name("9"))
    }

    /// A rule can only place a window that joins a strip at all; a dialog is still the app's to
    /// position, and a rule naming one says nothing about where it goes.
    @Test func aRuleCannotPlaceAWindowThatDoesNotTile() {
        let config = Self.config([WindowRule(appId: "com.test.app", workspace: name("3"))])
        let s = EngineTests.booted(config: config)
        let (after, _) = EngineTests.run(
            s, [.windowCreated(EngineTests.snapshot(1, bundle: "com.test.app", role: .dialog))])

        #expect(after.workspaces.workspace(of: WindowId(1)) == nil)
        #expect(after.workspaces.focused == .first)
    }

    /// A boot-adopted window keeps the width it already had (`PRINCIPLES.md` §4a) even though it is
    /// assigned elsewhere — the intent is read on the focused strip and carried across by the move.
    @Test func anAssignedBootWindowKeepsTheWidthItArrivedWith() {
        let s = EngineTests.booted(config: Self.slackToThree)
        let wide = WindowSnapshot(id: WindowId(1), bundleId: "com.tinyspeck.slackmacgap",
                                  title: "Slack", role: .standard,
                                  frame: Rect(x: 0, y: 0, width: 750, height: 400),
                                  wasAlreadyOpen: true)
        let (after, _) = EngineTests.run(s, [.windowCreated(wide)])

        let strip = after.workspaces[name("3")]
        #expect(strip.columns.count == 1)
        // 750 of a 1000-pt content area, not the ½ preset the ladder would have given it.
        #expect(strip.columns[0].widthOverride == .proportion(0.75))
    }

    /// Two windows for the same address stack up as two columns on it, in arrival order, rather than
    /// the second replacing or merging with the first.
    @Test func severalAssignedWindowsBuildTheStripTheyLandOn() {
        let s = EngineTests.booted(config: Self.slackToThree)
        let (after, _) = EngineTests.run(s, [
            arrival(1, bundle: "com.tinyspeck.slackmacgap", alreadyOpen: true),
            arrival(2, bundle: "com.tinyspeck.slackmacgap", alreadyOpen: true),
        ])

        #expect(after.workspaces[name("3")].allWindowIds == [WindowId(1), WindowId(2)])
        #expect(after.workspaces[name("3")].columns.count == 2)
    }
}
