import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The menu bar item's *policy*, which is all of it that has decisions in it: what the button says,
// and how a config diagnostic is rendered into a menu. `MenuBarItem` itself is AppKit wiring — an
// `NSStatusItem`, a menu rebuilt on open, two actions — and is exercised by launching the app, the
// same judgement `DisplayLinkDriver` and `CarbonHotkeyBinder` get.
//
// `Runtime.onStateChanged` is tested here rather than in `RuntimeTests` because the menu bar item is
// the reason it exists and the two rules it has to satisfy are about *this* observer: it sees settled
// states only, and it sees one per drain rather than one per event in a cascade.

@Suite @MainActor struct MenuBarTests {

    // MARK: - The title

    @Test func titleIsTheFocusedWorkspacesAddress() {
        #expect(StatusModel(workspace: .first).title == "1")
        #expect(StatusModel(workspace: WorkspaceName("3")!).title == "3")
        // Rank order is key order, so the tenth address is `0` and the eleventh is `a` — the
        // indicator shows the character, never the rank (`WorkspaceName`).
        #expect(StatusModel(workspace: WorkspaceName(rank: 9)!).title == "0")
        #expect(StatusModel(workspace: .last).title == "z")
    }

    @Test func aBrokenConfigTakesTheTitle() {
        var model = StatusModel(workspace: WorkspaceName("4")!)
        #expect(model.title == "4")

        model.configError = "/tmp/emira.toml:3: unknown setting 'layout.colum-gap'"
        #expect(model.title == "!")
        // The address it displaced is still reachable, because the user still needs to know it.
        #expect(model.tooltip.contains("4"))

        model.configError = nil
        #expect(model.title == "4")
    }

    // MARK: - The diagnostic

    @Test func aHealthyConfigContributesNoMenuLines() {
        #expect(StatusModel(workspace: .first).diagnosticLines().isEmpty)
    }

    @Test func theDiagnosticWrapsWithoutBreakingThePath() {
        let path = "/Users/someone/.config/emira/emira.toml:3"
        let model = StatusModel(workspace: .first,
                                configError: "\(path): unknown setting 'layout.colum-gap'")
        let lines = model.diagnosticLines(width: 40)

        #expect(lines.count > 1)                              // it actually wrapped
        #expect(lines.joined(separator: " ") == model.configError)  // and lost nothing
        // A path longer than the wrap width is left over-long rather than cut: a truncated path
        // can't be pasted into a terminal, which is the only thing the user wants to do with it.
        #expect(lines.contains(path + ":"))
    }

    @Test func wrappingIsGreedyAndDropsNothing() {
        let lines = StatusModel.wrap("aaa bbb ccc ddd", at: 7)
        #expect(lines == ["aaa bbb", "ccc ddd"])
    }

    // MARK: - The seam it hangs off

    @Test func stateChangesAreReportedOncePerDrainNotOncePerEvent() {
        let executor = MockExecutor()
        let runtime = Runtime(state: RuntimeTests.booted(config: RuntimeTests.fullWidth),
                              executor: executor)

        var reports: [WorkspaceName] = []
        runtime.onStateChanged = { reports.append($0.workspaces.focused) }

        // One command that cascades — an arrival places, and under a cover that is capture → raise →
        // teleport → landings, several events deep. The observer must see the settled end of it once.
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
