import Foundation
import Testing
@testable import EmiraCore

// Window rules, in two halves that fail differently: matching (does this rule apply to this window?)
// and arrival (what does the reducer do when one does). The config file's spelling of them is in
// `ConfigSyntaxTests`.

@Suite struct WindowRuleMatchingTests {

    private func name(_ c: Character) -> WorkspaceName { WorkspaceName(c)! }

    /// A window with no anchor — the four metadata matchers never read one.
    private func window(_ bundleId: String, _ title: String = "") -> WindowArrival {
        WindowArrival(bundleId: bundleId, title: title)
    }

    /// Every matcher a rule sets has to agree — the rule is an AND, not a "sounds about right".
    @Test func everySetMatcherMustAgree() {
        let rule = WindowRule(appId: "com.tinyspeck.slackmacgap", title: "Slack", workspace: name("3"))
        #expect(rule.matches(window("com.tinyspeck.slackmacgap", "Slack")))
        #expect(!rule.matches(window("com.tinyspeck.slackmacgap", "Huddle")))
        #expect(!rule.matches(window("com.apple.Safari", "Slack")))
    }

    /// An unset matcher abstains rather than failing, which is what makes a one-line rule the common
    /// case: `app-id` alone is every window of that app.
    @Test func anUnsetMatcherSaysNothing() {
        let rule = WindowRule(appId: "com.apple.Safari", workspace: name("2"))
        #expect(rule.matches(window("com.apple.Safari")))
        #expect(rule.matches(window("com.apple.Safari", "anything at all")))
    }

    /// `title` is exact and `title-regex` is not anchored, so the substring test people actually want
    /// is spelled in the notation everyone already reads that way.
    @Test func theExactMatchersAreExactAndTheRegexesAreNot() {
        let exact = WindowRule(title: "Huddle", workspace: name("4"))
        #expect(exact.matches(window("x", "Huddle")))
        #expect(!exact.matches(window("x", "Huddle — general")))

        let loose = WindowRule(titleRegex: "Huddle", workspace: name("4"))
        #expect(loose.matches(window("x", "Huddle — general")))
        #expect(loose.matches(window("x", "in a Huddle")))

        let anchored = WindowRule(appIdRegex: #"^com\.apple\."#, workspace: name("4"))
        #expect(anchored.matches(window("com.apple.Safari")))
        #expect(!anchored.matches(window("org.com.apple.fake")))
    }

    /// A rule with no matcher is refused by the config reader, so this can only be reached by building
    /// one in code — and the answer there is "matches nothing", never "matches the whole desktop".
    @Test func aRuleThatConstrainsNothingMatchesNothing() {
        let empty = WindowRule(workspace: name("3"))
        #expect(!empty.hasMatcher)
        #expect(!empty.matches(window("com.apple.Safari", "anything")))
    }

    /// Same reasoning one level down: a pattern that will not compile is refused at parse time, and if
    /// one arrives anyway it matches nothing rather than everything.
    @Test func anUncompilablePatternMatchesNothing() {
        let broken = WindowRule(appIdRegex: "com.(apple", workspace: name("3"))
        #expect(!broken.matches(window("com.apple.Safari")))
    }

    /// File order is precedence order, and it applies field by field: a later match overrides an
    /// earlier one, and a matching rule with nothing to say about a field leaves it alone.
    @Test func laterMatchesOverrideEarlierOnesFieldByField() {
        let rules = [
            WindowRule(appIdRegex: "^com\\.apple\\.", workspace: name("2")),
            WindowRule(appId: "com.apple.Safari", workspace: name("5")),
        ]
        #expect(WindowRules.outcome(for: window("com.apple.Safari"), in: rules).workspace == name("5"))
        #expect(WindowRules.outcome(for: window("com.apple.Mail"), in: rules).workspace == name("2"))
        #expect(WindowRules.outcome(for: window("com.tinyspeck.slackmacgap"), in: rules)
                .workspace == nil)
    }

    /// The merge is per field, so a broad rule setting one action and a narrow one setting another
    /// compose instead of the second erasing the first — which is the whole reason it is a merge.
    @Test func actionsFromDifferentMatchingRulesCombine() {
        let rules = [
            WindowRule(appIdRegex: "^com\\.apple\\.", width: .proportion(0.5)),
            WindowRule(appId: "com.apple.Safari", workspace: name("5")),
            WindowRule(titleRegex: "^Inspector", float: true),
        ]
        let safari = WindowRules.outcome(for: window("com.apple.Safari", "emira"), in: rules)
        #expect(safari == RuleOutcome(workspace: name("5"), width: .proportion(0.5)))

        // Two rules, two different fields, both applied — the apple-wide width and the title's float.
        let inspector = WindowRules.outcome(for: window("com.apple.Mail", "Inspector"), in: rules)
        #expect(inspector == RuleOutcome(float: true, width: .proportion(0.5)))

        // …and a window matching only the last one carries only its field.
        let other = WindowRules.outcome(for: window("com.test.app", "Inspector"), in: rules)
        #expect(other == RuleOutcome(float: true))
    }

    /// The order is the file's, not the specificity's — putting the broad rule last really does beat
    /// the narrow one above it, which is the price of a rule that is read top to bottom.
    @Test func precedenceIsPositionalAndNotCleverAboutIt() {
        let rules = [
            WindowRule(appId: "com.apple.Safari", workspace: name("5")),
            WindowRule(appIdRegex: "^com\\.apple\\.", workspace: name("2")),
        ]
        #expect(WindowRules.outcome(for: window("com.apple.Safari"), in: rules).workspace == name("2"))
    }
}

// The two relational matchers: predicates over how the arriving window sits against the one it opened
// out of, rather than over anything the window alone could say.

@Suite struct WindowRuleRelativeMatchingTests {

    /// A full-screen editor on a 2560×1440 display — the anchor everything here is measured against.
    private static let editor = WindowArrival.Anchor(
        bundleId: "com.jetbrains.intellij", frame: Rect(x: 0, y: 0, width: 2560, height: 1440))

    /// A window of `size`, opened by `bundleId`, out of `anchor`.
    private func opening(_ width: Double, _ height: Double,
                         by bundleId: String = "com.jetbrains.intellij",
                         from anchor: WindowArrival.Anchor? = editor) -> WindowArrival {
        WindowArrival(bundleId: bundleId, title: "",
                      frame: Rect(x: 0, y: 0, width: width, height: height), from: anchor)
    }

    /// The headline: a go-to-line prompt is a fraction of the window that spawned it in both directions,
    /// and a second project window is not.
    @Test func smallerThanFocusedSeparatesAPromptFromASecondWindow() {
        let rule = WindowRule(smallerThanFocused: 0.2, float: true)
        #expect(rule.matches(opening(400, 120)))            // 0.156 × 0.083
        #expect(!rule.matches(opening(1100, 900)))          // 0.43  × 0.63
    }

    /// **Both** dimensions, not area: a shape the strip can already hold is not a shape a column has to
    /// invent size for, however little of the screen it covers.
    @Test func bothDimensionsAreRequired() {
        let rule = WindowRule(smallerThanFocused: 0.2, float: true)
        #expect(!rule.matches(opening(200, 1400)))          // narrow, but full height
        #expect(!rule.matches(opening(2400, 100)))          // short, but full width
    }

    /// The threshold is read against the anchor and not the screen, which is what makes it mean
    /// "how violently would tiling distort this" rather than "how big is it".
    @Test func theSameWindowMatchesOrNotDependingOnWhatItOpenedBeside() {
        let rule = WindowRule(smallerThanFocused: 0.2, float: true)
        let third = WindowArrival.Anchor(bundleId: "com.jetbrains.intellij",
                                         frame: Rect(x: 0, y: 0, width: 853, height: 1440))
        #expect(rule.matches(opening(400, 120)))
        // 400 of 853 is 0.47 — with that much screen unclaimed, a column beside it costs nothing.
        #expect(!rule.matches(opening(400, 120, from: third)))
    }

    /// A float is not placed and a foreign window is never re-levelled, so a surprise window from a
    /// background app is exactly the one emira must leave on the strip.
    @Test func fromFocusedAppSeparatesTheAppsOwnWindowFromASurprise() {
        let rule = WindowRule(fromFocusedApp: true, float: true)
        #expect(rule.matches(opening(400, 120)))
        #expect(!rule.matches(opening(400, 120, by: "com.apple.Console")))

        // …and `false` is the other half of the tri-state, not a synonym for unset.
        let inverted = WindowRule(fromFocusedApp: false, float: true)
        #expect(!inverted.matches(opening(400, 120)))
        #expect(inverted.matches(opening(400, 120, by: "com.apple.Console")))
    }

    /// The two AND together, and each ANDs with the metadata matchers above them — a rule can be as
    /// narrow as one app's small windows.
    @Test func theRelationalMatchersAndWithEachOtherAndWithTheOthers() {
        let both = WindowRule(smallerThanFocused: 0.2, fromFocusedApp: true, float: true)
        #expect(both.matches(opening(400, 120)))
        #expect(!both.matches(opening(1100, 900)))                          // right app, too big
        #expect(!both.matches(opening(400, 120, by: "com.apple.Console")))  // small enough, wrong app

        let scoped = WindowRule(appId: "com.jetbrains.intellij", smallerThanFocused: 0.2, float: true)
        #expect(scoped.matches(opening(400, 120)))
        #expect(!scoped.matches(opening(400, 120, by: "com.apple.Console",
                                        from: WindowArrival.Anchor(bundleId: "com.apple.Console",
                                                                     frame: Self.editor.frame))))

        let titled = WindowRule(titleRegex: "Preferences", smallerThanFocused: 0.2, float: true)
        var prompt = opening(400, 120)
        #expect(!titled.matches(prompt))
        prompt.title = "Preferences"
        #expect(titled.matches(prompt))
    }

    /// With nothing to compare against — the first window on an empty workspace, or a window the launch
    /// scan adopted — a relational matcher fails rather than guessing at a scale.
    @Test func noAnchorMatchesNothing() {
        let smaller = WindowRule(smallerThanFocused: 0.2, float: true)
        let app = WindowRule(fromFocusedApp: true, float: true)
        #expect(!smaller.matches(opening(400, 120, from: nil)))
        #expect(!app.matches(opening(400, 120, from: nil)))

        // …and it fails the whole rule, not just its own clause.
        let scoped = WindowRule(appId: "com.jetbrains.intellij", smallerThanFocused: 0.2, float: true)
        #expect(!scoped.matches(opening(400, 120, from: nil)))
    }

    /// A rule carrying only these is a rule about a narrow slice of the desktop, so it is legal — the
    /// parse-time refusal is for a rule that constrains nothing at all.
    @Test func aRuleCarryingOnlyTheseHasAMatcher() {
        #expect(WindowRule(smallerThanFocused: 0.2, float: true).hasMatcher)
        #expect(WindowRule(fromFocusedApp: true, float: true).hasMatcher)
        #expect(!WindowRule(float: true).hasMatcher)
    }
}

/// The reducer's half: where an assigned window lands, and what happens to focus.
@Suite struct WindowRuleArrivalTests {

    private func name(_ c: Character) -> WorkspaceName { WorkspaceName(c)! }

    /// Slack goes to `"3"`; everything else is left alone.
    private static func config(_ rules: [WindowRule]) -> Config {
        Config(widthPresets: PresetCycle([.proportion(0.5)]), transitionMode: .off,
               windowRules: rules)
    }

    private static let slackToThree = config([
        WindowRule(appId: "com.tinyspeck.slackmacgap", workspace: WorkspaceName("3")!)
    ])

    private func arrival(_ raw: UInt64, bundle: String, alreadyOpen: Bool = false) -> Event {
        .windowCreated(EngineFix.snapshot(raw, bundle: bundle, wasAlreadyOpen: alreadyOpen))
    }

    /// The headline: a matching window starts on the workspace the rule names, without the user having
    /// gone there.
    @Test func aMatchingWindowStartsOnTheWorkspaceItsRuleNames() {
        let s = EngineFix.booted(config: Self.slackToThree)
        let (after, _) = EngineFix.run(s, [arrival(1, bundle: "com.tinyspeck.slackmacgap")])

        #expect(after.workspaces.workspace(of: WindowId(1)) == name("3"))
        #expect(after.workspaces[.first].isEmpty)
    }

    /// …and a window no rule matches is untouched by the feature — the ordinary arrival, on the strip
    /// in view.
    @Test func anUnmatchedWindowStillJoinsTheFocusedStrip() {
        let s = EngineFix.booted(config: Self.slackToThree)
        let (after, _) = EngineFix.run(s, [arrival(1, bundle: "com.apple.Safari")])

        #expect(after.workspaces.workspace(of: WindowId(1)) == .first)
        #expect(after.monitors.shown == .first)
    }

    /// A rule naming the workspace you are already on is the ordinary arrival too, not a move to
    /// where the window already is.
    @Test func aRuleNamingTheFocusedWorkspaceChangesNothing() {
        let config = Self.config([WindowRule(appId: "com.test.app", workspace: .first)])
        let s = EngineFix.booted(config: config)
        let (after, _) = EngineFix.run(s, [arrival(1, bundle: "com.test.app")])

        #expect(after.workspaces.workspace(of: WindowId(1)) == .first)
        #expect(after.world.focusedWindow == WindowId(1))
    }

    /// A window opened *now* is one the user opened, so the workspace follows it — the same thing a
    /// Dock click on an app living elsewhere already does.
    @Test func aLiveArrivalTakesTheUserWithIt() {
        let s = EngineFix.booted(config: Self.slackToThree)
        let (after, fx) = EngineFix.run(s, [arrival(1, bundle: "com.tinyspeck.slackmacgap")])

        #expect(after.monitors.shown == name("3"))
        #expect(after.world.focusedWindow == WindowId(1))
        #expect(fx.contains(.focus(WindowId(1))))
    }

    /// The launch scan is emira sorting a desktop nobody just asked it to sort, so it stays put — the
    /// alternative walks the user through every address they own before their first keystroke.
    @Test func theBootScanSortsTheDesktopWithoutMovingTheUser() {
        let s = EngineFix.booted(config: Self.slackToThree)
        let (after, fx) = EngineFix.run(
            s, [arrival(1, bundle: "com.tinyspeck.slackmacgap", alreadyOpen: true)])

        #expect(after.workspaces.workspace(of: WindowId(1)) == name("3"))
        #expect(after.monitors.shown == .first)         // still home
        #expect(after.world.focusedWindow == nil)           // and focus was never claimed
        #expect(!fx.contains(.focus(WindowId(1))))
    }

    /// An assigned window is on a parked strip, so it is parked — placed, not merely recorded. Two
    /// adopted at boot get *distinct* nubs, which is the invariant the whole park model rests on.
    @Test func anAssignedWindowIsParkedAtItsOwnNub() {
        let s = EngineFix.booted(config: Self.slackToThree)
        let (after, _) = EngineFix.run(s, [
            arrival(1, bundle: "com.tinyspeck.slackmacgap", alreadyOpen: true),
            arrival(2, bundle: "com.tinyspeck.slackmacgap", alreadyOpen: true),
        ])

        let frames = after.workspaces.targetFrames(after.placements())
        #expect(frames[WindowId(1)] != nil)
        #expect(frames[WindowId(1)] != frames[WindowId(2)])
    }

    /// The rule fires at first sight and never again: a window moved off its assigned workspace by
    /// hand stays where it was put, and being minimized and restored does not re-post it either.
    @Test func theRuleIsNeverConsultedTwice() {
        let s = EngineFix.booted(config: Self.slackToThree)
        var (after, _) = EngineFix.run(s, [arrival(1, bundle: "com.tinyspeck.slackmacgap")])
        #expect(after.monitors.shown == name("3"))

        // Moved by hand to "7" — the freedom the whole design is for.
        (after, _) = EngineFix.run(after, [.command(.moveToWorkspace(.name(name("7"))))])
        #expect(after.workspaces.workspace(of: WindowId(1)) == name("7"))

        // Minimized and restored, from a different workspace: it lands where the user is.
        (after, _) = EngineFix.run(after, [
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
        let s = EngineFix.booted(config: config)
        let (after, _) = EngineFix.run(
            s, [.windowCreated(EngineFix.snapshot(1, bundle: "com.test.app", role: .dialog))])

        #expect(after.workspaces.workspace(of: WindowId(1)) == nil)
        #expect(after.monitors.shown == .first)
    }

    /// A boot-adopted window keeps the width it already had (`PRINCIPLES.md` §4) even though it is
    /// assigned elsewhere — the intent is read on the focused strip and carried across by the move.
    @Test func anAssignedBootWindowKeepsTheWidthItArrivedWith() {
        let s = EngineFix.booted(config: Self.slackToThree)
        let wide = WindowSnapshot(id: WindowId(1), bundleId: "com.tinyspeck.slackmacgap",
                                  title: "Slack", role: .standard,
                                  frame: Rect(x: 0, y: 0, width: 750, height: 400),
                                  wasAlreadyOpen: true)
        let (after, _) = EngineFix.run(s, [.windowCreated(wide)])

        let strip = after.workspaces[name("3")]
        #expect(strip.columns.count == 1)
        // 750 of a 1000-pt content area, not the ½ preset the ladder would have given it.
        #expect(strip.columns[0].widthOverride == .proportion(0.75))
    }

    /// `float = true` takes a window off the strip that would otherwise have tiled — the rule's answer
    /// outranks the role, which is the same direction `Command.float` runs.
    @Test func floatTrueKeepsAStandardWindowOffTheStrip() {
        let config = Self.config([WindowRule(appId: "com.test.app", float: true)])
        let s = EngineFix.booted(config: config)
        let (after, fx) = EngineFix.run(s, [arrival(1, bundle: "com.test.app")])

        #expect(after.world.isFloating(WindowId(1)))
        #expect(!after.world.participatesInStrip(WindowId(1)))
        #expect(after.workspaces.workspace(of: WindowId(1)) == nil)
        #expect(fx.isEmpty)                                 // the app's to position, so we say nothing
    }

    /// …and `float = false` tiles a window macOS classed a dialog, which is the direction that needs a
    /// tri-state: a mis-classified window would otherwise be stuck floating forever.
    @Test func floatFalseTilesAWindowTheRoleWouldHaveFloated() {
        let config = Self.config([WindowRule(appId: "com.test.app", float: false)])
        let s = EngineFix.booted(config: config)
        let (after, _) = EngineFix.run(
            s, [.windowCreated(EngineFix.snapshot(1, bundle: "com.test.app", role: .dialog))])

        #expect(!after.world.isFloating(WindowId(1)))
        #expect(after.workspaces.workspace(of: WindowId(1)) == .first)
    }

    /// The rule seeds the same tri-state the verb toggles, so `float` still works afterwards — a seed,
    /// not a mode.
    @Test func aFloatedWindowCanStillBeTiledByHand() {
        let config = Self.config([WindowRule(appId: "com.test.app", float: true)])
        let s = EngineFix.booted(config: config)
        var (after, _) = EngineFix.run(s, [arrival(1, bundle: "com.test.app")])
        #expect(after.workspaces.workspace(of: WindowId(1)) == nil)

        after.world.setFocus(WindowId(1))
        (after, _) = EngineFix.run(after, [.command(.float(.off))])
        #expect(after.workspaces.workspace(of: WindowId(1)) == .first)
    }

    /// `width` is on `width-presets`' scale, so `0.5` is half the content area — 500 pt of the 1000-pt
    /// display these tests lay out against, rather than the ½ preset by coincidence.
    @Test func widthSeedsTheColumnItOpens() {
        let config = Self.config([WindowRule(appId: "com.test.app", width: .proportion(0.75))])
        let s = EngineFix.booted(config: config)
        let (after, _) = EngineFix.run(s, [arrival(1, bundle: "com.test.app")])

        let column = after.workspaces[.first].columns[0]
        #expect(column.widthOverride == .proportion(0.75))
        #expect(after.workspaces[.first].resolvedWidth(of: column, metrics: after.metrics()!) == 750)
    }

    /// A value over 1 is points, not a fraction — the same reading `width-presets` gives it, shared
    /// rather than restated so the two spellings of a width cannot drift apart.
    @Test func aWidthOverOneIsPoints() {
        let config = Self.config([WindowRule(appId: "com.test.app", width: .fixed(420))])
        let s = EngineFix.booted(config: config)
        let (after, _) = EngineFix.run(s, [arrival(1, bundle: "com.test.app")])

        let strip = after.workspaces[.first]
        #expect(strip.resolvedWidth(of: strip.columns[0], metrics: after.metrics()!) == 420)
    }

    /// It is a `widthOverride`, so the first `cycle-width` clears it and the column rejoins the ladder
    /// — the rule decides where a window *starts*, here as with the workspace.
    @Test func cycleWidthClearsTheSeededWidth() {
        let config = Self.config([WindowRule(appId: "com.test.app", width: .proportion(0.75))])
        let s = EngineFix.booted(config: config)
        var (after, _) = EngineFix.run(s, [arrival(1, bundle: "com.test.app")])

        (after, _) = EngineFix.run(after, [.command(.cycleWidth)])
        #expect(after.workspaces[.first].columns[0].widthOverride == nil)
    }

    /// The two width sources meet on a boot adoption, and the explicit one wins: a rule is what the
    /// user asked for, while the adopted width is an inference from what happened to be on screen.
    @Test func aRuleWidthOutranksTheWidthABootWindowArrivedWith() {
        let config = Self.config([WindowRule(appId: "com.test.app", width: .proportion(0.25))])
        let s = EngineFix.booted(config: config)
        let wide = WindowSnapshot(id: WindowId(1), bundleId: "com.test.app", title: "w",
                                  role: .standard, frame: Rect(x: 0, y: 0, width: 900, height: 400),
                                  wasAlreadyOpen: true)
        let (after, _) = EngineFix.run(s, [.windowCreated(wide)])

        #expect(after.workspaces[.first].columns[0].widthOverride == .proportion(0.25))
    }

    /// Both actions on one window, on a workspace that is not the focused one — the width has to
    /// survive the move that takes it there, which is `move`'s job and not a special case here.
    @Test func aWidthRidesAcrossToTheWorkspaceItWasAssigned() {
        let config = Self.config([WindowRule(appId: "com.test.app", workspace: name("4"),
                                             width: .proportion(0.25))])
        let s = EngineFix.booted(config: config)
        let (after, _) = EngineFix.run(s, [arrival(1, bundle: "com.test.app", alreadyOpen: true)])

        #expect(after.workspaces.workspace(of: WindowId(1)) == name("4"))
        #expect(after.workspaces[name("4")].columns[0].widthOverride == .proportion(0.25))
    }

    /// Two windows for the same address stack up as two columns on it, in arrival order, rather than
    /// the second replacing or merging with the first.
    @Test func severalAssignedWindowsBuildTheStripTheyLandOn() {
        let s = EngineFix.booted(config: Self.slackToThree)
        let (after, _) = EngineFix.run(s, [
            arrival(1, bundle: "com.tinyspeck.slackmacgap", alreadyOpen: true),
            arrival(2, bundle: "com.tinyspeck.slackmacgap", alreadyOpen: true),
        ])

        #expect(after.workspaces[name("3")].allWindowIds == [WindowId(1), WindowId(2)])
        #expect(after.workspaces[name("3")].columns.count == 2)
    }
}

/// The relational matchers through the reducer: what the anchor actually is at the moment a window
/// arrives, and what floating one costs the window that spawned it.
@Suite struct WindowRuleAnchorArrivalTests {

    /// One full-width preset, so the editor below fills the 1000×800 display it opened on.
    private static func config(_ rules: [WindowRule]) -> Config {
        Config(widthPresets: PresetCycle([.proportion(1.0)]), transitionMode: .off, windowRules: rules)
    }

    private static let floatSmallOnes = config([
        WindowRule(smallerThanFocused: 0.2, fromFocusedApp: true, float: true)
    ])

    /// The window that was already there, filling the screen.
    private func editor(_ raw: UInt64, alreadyOpen: Bool = false) -> Event {
        .windowCreated(EngineFix.snapshot(raw, bundle: "com.jetbrains.intellij",
                                          frame: EngineFix.displayFrame, wasAlreadyOpen: alreadyOpen))
    }

    /// A window opening at `size`, from `bundle` — the thing the rule is deciding about.
    private func opens(_ raw: UInt64, _ width: Double, _ height: Double,
                       bundle: String = "com.jetbrains.intellij", alreadyOpen: Bool = false) -> Event {
        .windowCreated(EngineFix.snapshot(raw, bundle: bundle,
                                          frame: Rect(x: 400, y: 300, width: width, height: height),
                                          wasAlreadyOpen: alreadyOpen))
    }

    /// The headline: the prompt floats, and the window that spawned it keeps its column and its width
    /// rather than being pushed aside to make room for one.
    @Test func aPromptFloatsAndCostsTheWindowThatSpawnedItNothing() {
        let s = EngineFix.booted(config: Self.floatSmallOnes)
        var (after, _) = EngineFix.run(s, [editor(1)])
        let before = EngineFix.width(after)
        (after, _) = EngineFix.run(after, [opens(2, 150, 100)])

        #expect(after.world.isFloating(WindowId(2)))
        #expect(!after.world.participatesInStrip(WindowId(2)))
        #expect(after.workspaces.workspace(of: WindowId(2)) == nil)

        #expect(after.workspaces[.first].allWindowIds == [WindowId(1)])
        #expect(after.workspaces[.first].columns.count == 1)
        #expect(EngineFix.width(after) == before)
    }

    /// …and the window the same rule must not touch: a second project window is barely distorted by a
    /// column, so it takes one.
    @Test func aSecondProjectWindowStillTiles() {
        let s = EngineFix.booted(config: Self.floatSmallOnes)
        var (after, _) = EngineFix.run(s, [editor(1)])
        (after, _) = EngineFix.run(after, [opens(2, 600, 700)])

        #expect(!after.world.isFloating(WindowId(2)))
        #expect(after.workspaces[.first].columns.count == 2)
    }

    /// A surprise window from a background app is the one emira must leave on the strip: a float is not
    /// placed, and a foreign window is never re-levelled, so floating one can strand it behind a tile.
    @Test func aSmallWindowFromABackgroundAppStillTiles() {
        let s = EngineFix.booted(config: Self.floatSmallOnes)
        var (after, _) = EngineFix.run(s, [editor(1)])
        (after, _) = EngineFix.run(after, [opens(2, 150, 100, bundle: "com.apple.Console")])

        #expect(!after.world.isFloating(WindowId(2)))
        #expect(after.workspaces[.first].columns.count == 2)
    }

    /// A window the user floated is still the window they are working in. It has no column — nothing
    /// opens beside it — and it is still the thing a prompt from its app opened out of.
    @Test func aFloatedWindowIsStillAnAnchor() {
        let s = EngineFix.booted(config: Self.floatSmallOnes)
        var (after, _) = EngineFix.run(s, [editor(1)])
        (after, _) = EngineFix.run(after, [.command(.float(.on))])
        #expect(after.world.isFloating(WindowId(1)))
        #expect(after.workspaces[.first].columns.isEmpty)

        (after, _) = EngineFix.run(after, [opens(2, 150, 100)])
        #expect(after.world.isFloating(WindowId(2)))
    }

    /// Live focus reads `nil` at exactly the moment a window arrives — an app focuses its new window
    /// before emira has adopted it — so what the rules read is the *last* window focus rested on, and
    /// `lastStripFocus` is not that: floating w1 emptied the strip, so there is no place left for it to
    /// name and it holds nothing at all. `lastFocus` is what still remembers the window.
    @Test func theAnchorSurvivesTheFocusRace() {
        let s = EngineFix.booted(config: Self.floatSmallOnes)
        var (after, _) = EngineFix.run(s, [editor(1)])
        (after, _) = EngineFix.run(after, [.command(.float(.on)),
                                           .focusChanged(nil, origin: .system)])
        #expect(after.world.focusedWindow == nil)
        #expect(after.world.lastStripFocus == nil)
        #expect(after.world.lastFocus == WindowId(1))

        (after, _) = EngineFix.run(after, [opens(2, 150, 100)])
        #expect(after.world.isFloating(WindowId(2)))
    }

    /// Native full screen is the same shape of window: `WindowRole` classes it `.other`, so it is on no
    /// strip and in no column, and a prompt beside it is measured against the screen it fills.
    @Test func aFullScreenWindowIsStillAnAnchor() {
        var s = EngineFix.booted(config: Self.floatSmallOnes)
        (s, _) = EngineFix.run(s, [.windowCreated(
            EngineFix.snapshot(1, bundle: "com.jetbrains.intellij", role: .other,
                               frame: EngineFix.displayFrame))])
        s.world.setFocus(WindowId(1))
        #expect(s.workspaces[.first].columns.isEmpty)

        let (after, _) = EngineFix.run(s, [opens(2, 150, 100)])
        #expect(after.world.isFloating(WindowId(2)))
    }

    /// The anchor is read from live truth, so a window resized since it arrived is measured at the size
    /// it is now — the ratio is about the desktop in front of the user, not about first sight.
    @Test func theAnchorIsMeasuredAtItsCurrentSize() {
        let s = EngineFix.booted(config: Self.floatSmallOnes)
        var (after, _) = EngineFix.run(s, [editor(1)])
        // Shrunk to a quarter of the screen: 150×100 is no longer small against it.
        (after, _) = EngineFix.run(
            after, [.windowFrameChanged(WindowId(1), Rect(x: 0, y: 0, width: 500, height: 400))])
        (after, _) = EngineFix.run(after, [opens(2, 150, 100)])

        #expect(!after.world.isFloating(WindowId(2)))
    }

    /// At boot there is no app that "already had focus" — `lastStripFocus` is whichever window the scan
    /// reached first — so both matchers abstain rather than comparing against noise.
    @Test func theLaunchScanNeverFloatsOnTheseMatchers() {
        let s = EngineFix.booted(config: Self.floatSmallOnes)
        let (after, _) = EngineFix.run(s, [editor(1, alreadyOpen: true),
                                           opens(2, 150, 100, alreadyOpen: true)])

        #expect(!after.world.isFloating(WindowId(2)))
        #expect(after.workspaces[.first].allWindowIds == [WindowId(1), WindowId(2)])
    }

    /// The first window on an empty workspace has nothing to be smaller than, so it tiles however small
    /// it opened — the alternative is a desktop whose first window is unreachable.
    @Test func theFirstWindowOnAWorkspaceHasNoAnchorAndTiles() {
        let s = EngineFix.booted(config: Self.floatSmallOnes)
        let (after, _) = EngineFix.run(s, [opens(1, 150, 100)])

        #expect(!after.world.isFloating(WindowId(1)))
        #expect(after.workspaces.workspace(of: WindowId(1)) == .first)
    }

    /// …and that holds for a workspace *switched to*, not just the first one of a session. `lastFocus`
    /// outlives the switch — nothing clears it, which is the whole point of it — so the constraint that
    /// makes this window anchorless is that the editor is parked, not that focus moved off it.
    @Test func theFirstWindowOnAWorkspaceSwitchedToHasNoAnchorEither() {
        let s = EngineFix.booted(config: Self.floatSmallOnes)
        var (after, _) = EngineFix.run(s, [editor(1)])
        (after, _) = EngineFix.run(after, [.command(.focusWorkspace(.name(WorkspaceName("5")!)))])
        #expect(after.world.lastFocus == WindowId(1))
        #expect(!after.world.isOnScreen(WindowId(1)))

        (after, _) = EngineFix.run(after, [opens(2, 150, 100)])
        #expect(!after.world.isFloating(WindowId(2)))
    }

    /// A window in the Dock is a scale nobody can see. `lastFocus` still names it — minimizing the
    /// focused window clears focus and nothing else — so this is the case that proves the anchor is
    /// gated on being *on screen* rather than merely on still existing.
    @Test func aMinimizedAnchorIsNoAnchor() {
        let s = EngineFix.booted(config: Self.floatSmallOnes)
        var (after, _) = EngineFix.run(s, [editor(1)])
        (after, _) = EngineFix.run(after, [.windowMinimized(WindowId(1))])
        #expect(after.world.lastFocus == WindowId(1))

        (after, _) = EngineFix.run(after, [opens(2, 150, 100)])
        #expect(!after.world.isFloating(WindowId(2)))
    }

    /// `Cmd-H` is the same fact one level up: the app's windows are nowhere on the screen, so its last
    /// focused window is no more a scale than a minimized one is.
    @Test func aHiddenAppsWindowIsNoAnchor() {
        let s = EngineFix.booted(config: Self.floatSmallOnes)
        var (after, _) = EngineFix.run(s, [editor(1)])
        after.world.setAppHidden("com.jetbrains.intellij", true)
        #expect(after.world.lastFocus == WindowId(1))

        (after, _) = EngineFix.run(after, [opens(2, 150, 100)])
        #expect(!after.world.isFloating(WindowId(2)))
    }

    /// The float is a seed and not a leash: the first `emira float` hands the window back to the strip,
    /// and nothing re-floats it.
    @Test func aFloatedPromptIsTiledByHand() {
        let s = EngineFix.booted(config: Self.floatSmallOnes)
        var (after, _) = EngineFix.run(s, [editor(1)])
        (after, _) = EngineFix.run(after, [opens(2, 150, 100)])
        #expect(after.workspaces.workspace(of: WindowId(2)) == nil)

        after.world.setFocus(WindowId(2))
        (after, _) = EngineFix.run(after, [.command(.float(.off))])

        #expect(!after.world.isFloating(WindowId(2)))
        #expect(after.workspaces[.first].allWindowIds == [WindowId(1), WindowId(2)])
    }
}
