import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The menu bar item's policy: what the button says and how a config diagnostic is rendered into a
// menu. `MenuBarItem` itself is AppKit wiring and is exercised by launching the app.
//
// `Runtime.onStateChanged` is tested here because the menu bar item is why it exists: it sees settled
// states only, and one per drain rather than one per event in a cascade.

@Suite @MainActor struct MenuBarTests {

    @Test func titleIsTheFocusedWorkspacesAddress() {
        #expect(StatusModel(workspace: .first).title == "1")
        #expect(StatusModel(workspace: WorkspaceName("3")!).title == "3")
        // Rank order is key order, so the tenth address is `0` and the eleventh `a` — the indicator
        // shows the character, never the rank.
        #expect(StatusModel(workspace: WorkspaceName(rank: 9)!).title == "0")
        #expect(StatusModel(workspace: .last).title == "z")
    }

    @Test func aBrokenConfigTakesTheTitle() {
        var model = StatusModel(workspace: WorkspaceName("4")!)
        #expect(model.title == "4")

        model.configStatus = .broken("/tmp/emira.toml:3: unknown setting 'layout.colum-gap'")
        #expect(model.title == "!")
        // The address it displaced is still reachable, because the user still needs to know it.
        #expect(model.tooltip.contains("4"))

        model.configStatus = .loaded
        #expect(model.title == "4")
    }

    /// The title is one character, so on several displays it names the one the user is on and the
    /// tooltip carries the rest. One display reads exactly as it always did — the absence of the others
    /// is what keeps the common string unchanged rather than a branch.
    @Test func theTooltipNamesWhatTheOtherDisplaysAreShowing() {
        let alone = StatusModel(workspace: WorkspaceName("4")!)
        #expect(alone.tooltip == "emira — workspace 4")

        let desktop = StatusModel(workspace: WorkspaceName("4")!,
                                  elsewhere: [WorkspaceName("7")!, .last])
        #expect(desktop.title == "4", "the acting display keeps the one character there is")
        #expect(desktop.tooltip == "emira — workspace 4 (also 7, z)")
    }

    /// …and a broken config still displaces the title, with every address kept in the tooltip: which
    /// screen is showing what is not the fact the error replaces.
    @Test func aBrokenConfigKeepsEveryDisplaysAddressInTheTooltip() {
        let model = StatusModel(workspace: WorkspaceName("4")!, elsewhere: [WorkspaceName("7")!],
                                configStatus: .broken("/tmp/emira.toml:3: bad"))
        #expect(model.title == "!")
        #expect(model.tooltip.contains("4"))
        #expect(model.tooltip.contains("7"))
    }

    /// A file that has never parsed takes the title on the same terms — but not the address with it.
    /// Nothing is being managed, so the workspace it would name holds no windows.
    @Test func aConfigThatNeverLoadedTakesTheTitleAndSaysWhy() {
        let model = StatusModel(workspace: WorkspaceName("4")!,
                                configStatus: .neverLoaded("/tmp/emira.toml:3: bad"))
        #expect(model.title == "!")
        #expect(!model.tooltip.contains("4"))
        #expect(model.tooltip.contains("not managing"))
    }

    /// The two failures read differently because they *are* different: one has earlier settings
    /// running and one has none, which is the whole reason emira manages nothing in the second.
    @Test func theTwoFailuresSayDifferentThingsAboutTheSameDiagnostic() {
        let error = "/tmp/emira.toml:3: bad"
        let broken = StatusModel(configStatus: .broken(error)).consequence
        let never = StatusModel(configStatus: .neverLoaded(error)).consequence

        #expect(broken != nil && never != nil)
        #expect(broken != never)
        #expect(StatusModel(configStatus: .loaded).consequence == nil)
        // Same diagnostic either way — only the sentence under it changes.
        #expect(StatusModel(configStatus: .broken(error)).diagnosticLines()
                == StatusModel(configStatus: .neverLoaded(error)).diagnosticLines())
    }

    @Test func aHealthyConfigContributesNoMenuLines() {
        #expect(StatusModel(workspace: .first).diagnosticLines().isEmpty)
    }

    @Test func theDiagnosticWrapsWithoutBreakingThePath() {
        let path = "/Users/someone/.config/emira/emira.toml:3"
        let model = StatusModel(workspace: .first,
                                configStatus: .broken("\(path): unknown setting 'layout.colum-gap'"))
        let lines = model.diagnosticLines(width: 40)

        #expect(lines.count > 1)                                       // it actually wrapped
        #expect(lines.joined(separator: " ") == model.configStatus.error)  // and lost nothing
        // A path longer than the wrap width is left over-long rather than cut: a truncated path
        // can't be pasted into a terminal, which is the only thing the user wants to do with it.
        #expect(lines.contains(path + ":"))
    }

    @Test func wrappingIsGreedyAndDropsNothing() {
        let lines = StatusModel.wrap("aaa bbb ccc ddd", at: 7)
        #expect(lines == ["aaa bbb", "ccc ddd"])
    }

    // The seam it hangs off

    @Test func stateChangesAreReportedOncePerDrainNotOncePerEvent() {
        let executor = MockExecutor()
        let runtime = Runtime(state: RuntimeTests.booted(config: RuntimeTests.fullWidth),
                              executor: executor)

        var reports: [WorkspaceName] = []
        runtime.onStateChanged = { reports.append($0.monitors.shown) }

        // One event that cascades several events deep (capture → raise → teleport → landings). The
        // observer must see the settled end of it, once.
        runtime.dispatch(.windowCreated(RuntimeTests.snapshot(1)))
        #expect(reports.count == 1)

        runtime.dispatch(.command(.focusWorkspace(.name(WorkspaceName("3")!))))
        #expect(reports.count == 2)
        #expect(reports.last == WorkspaceName("3"))
    }

    @Test func theObserverOnlyEverSeesSettledState() {
        let executor = MockExecutor()
        let runtime = Runtime(state: RuntimeTests.booted(config: RuntimeTests.fullWidth, windows: 2),
                              executor: executor)

        // Every report must be a state whose effects are already issued — i.e. never mid-drain.
        // `isPumping` is the bit that says so, and it is false exactly between drains.
        var sawUnsettled = false
        runtime.onStateChanged = { _ in
            if runtime.isPumping { sawUnsettled = true }
        }

        runtime.dispatch(.command(.focus(.right)))
        runtime.dispatch(.command(.focus(.left)))

        #expect(!sawUnsettled)
    }
}
