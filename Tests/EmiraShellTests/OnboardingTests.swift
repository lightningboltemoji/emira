import CoreGraphics
import Foundation
import Testing
@testable import EmiraShell

// The onboarding gate's policy: which grants are asked for, when boot may proceed, what the window
// says, and where it opens. `OnboardingWindow` itself is AppKit wiring and is exercised by launching
// the app with a grant missing.

@Suite @MainActor struct OnboardingTests {

    static func model(_ rows: [GrantRow]) -> OnboardingModel {
        OnboardingModel(rows: rows)
    }

    // MARK: - What is asked for

    @Test func askingForTheCoverIsWhatMakesScreenRecordingARow() {
        // Demanding a grant for a feature the user turned off is the whole reason it is conditional.
        #expect(!OnboardingModel.live(wantsCover: false).isAskingForCover)
        #expect(OnboardingModel.live(wantsCover: true).isAskingForCover)

        // Accessibility is asked for either way, and first.
        for wantsCover in [true, false] {
            let model = OnboardingModel.live(wantsCover: wantsCover)
            #expect(model.rows.first?.service == .accessibility)
            #expect(model.rows.count == (wantsCover ? 2 : 1))
        }
    }

    // MARK: - When boot may proceed

    @Test func everyRowIsRequired() {
        // Satisfaction is just "all of them" — the optional grant is the one that isn't there.
        #expect(Self.model([.accessibility(.denied), .screenRecording(.granted)]).isSatisfied == false)
        #expect(Self.model([.accessibility(.granted), .screenRecording(.denied)]).isSatisfied == false)
        #expect(Self.model([.accessibility(.granted), .screenRecording(.granted)]).isSatisfied)
        // The waived-cover shape: Accessibility alone is enough.
        #expect(Self.model([.accessibility(.granted)]).isSatisfied)
    }

    @Test func missingNamesTheOutstandingGrantsInOrder() {
        #expect(Self.model([.accessibility(.denied), .screenRecording(.denied)]).missing
                == ["Accessibility", "Screen Recording"])
        #expect(Self.model([.accessibility(.granted), .screenRecording(.denied)]).missing
                == ["Screen Recording"])
        #expect(Self.model([.accessibility(.granted), .screenRecording(.granted)]).missing.isEmpty)
    }

    // MARK: - What it says

    @Test func theStatusLineReadsAsASentenceAtEveryCount() {
        #expect(Self.model([.accessibility(.denied), .screenRecording(.denied)]).status
                == "waiting for Accessibility and Screen Recording…")
        #expect(Self.model([.accessibility(.denied)]).status == "waiting for Accessibility…")
    }

    @Test func aSatisfiedModelAsksForTheRestart() {
        // The end of onboarding is a restart, not a launch, and the line has to say so — it is the
        // explanation under the only button left.
        let status = Self.model([.accessibility(.granted), .screenRecording(.granted)]).status
        #expect(status.contains("restarted"))
        #expect(status.contains("quit"))
        #expect(!status.contains("waiting"))
    }

    @Test func listGrowsWithoutLosingItsGrammar() {
        #expect(OnboardingModel.list([]) == "")
        #expect(OnboardingModel.list(["A"]) == "A")
        #expect(OnboardingModel.list(["A", "B"]) == "A and B")
        #expect(OnboardingModel.list(["A", "B", "C"]) == "A, B and C")
    }

    @Test func aParagraphPerGrantAsked() {
        let asking = Self.model([.accessibility(.denied), .screenRecording(.denied)]).paragraphs
        #expect(asking.count == 2)
        #expect(asking[0].contains("**Accessibility**"))
        // Both grants are billed as required; the config waiver is deliberately unadvertised. Asserted on
        // the key as a file spells it, not on the bare word: the paragraph says "during transitions" as
        // prose, and it is naming the setting that would be the leak.
        #expect(asking[1].contains("**Screen Recording**"))
        #expect(!asking.contains { $0.contains("animation.transition") || $0.contains("transition =") })

        // A grant emira isn't asking for gets no paragraph.
        #expect(Self.model([.accessibility(.denied)]).paragraphs.count == 1)
    }

    @Test func theBlurbReadsAsProseAcrossItsSeams() {
        // Asserted whole, like the status line: each paragraph is assembled from fragments to stay
        // inside the column, and a space lost at a seam is a typo in emira's first sentence.
        let asking = Self.model([.accessibility(.denied), .screenRecording(.denied)]).paragraphs
        #expect(asking[0] == "**Accessibility** permissions are required to move, resize, and focus"
                + " your windows.")
        #expect(asking[1] == "**Screen Recording** permissions are required for animations:"
                + " screenshots stand in for real windows during transitions.")
    }

    // MARK: - Reading a grant this process can't read

    @Test func aGrantOnceSeenIsNotUnseen() {
        // The probe writes `.granted` into a row whose in-process read still says otherwise, so a
        // refresh that consulted `Permissions` again would revert it on the very next tick.
        var row = GrantRow.screenRecording(.denied)
        row.grant = .granted
        #expect(row.refreshed().grant == .granted)

        // Whole-model, since that is what the window's tick calls. Deliberately no assertion about a
        // *denied* row surviving a refresh: that reads the real grant, which this process inherits from
        // whatever launched it.
        var model = Self.model([.accessibility(.granted), .screenRecording(.denied)])
        model.rows[1].grant = .granted
        #expect(model.refreshed().isSatisfied)
    }

    @Test func theIndicatorSaysOnlyWhetherTheGrantIsIn() {
        #expect(GrantRow.accessibility(.granted).indicator == "✅")
        #expect(GrantRow.accessibility(.denied).indicator == "❌")
    }

    @Test func everyRowNamesAPaneAndADeepLinkIntoIt() {
        for row in [GrantRow.accessibility(.denied), .screenRecording(.denied)] {
            #expect(row.url.hasPrefix("x-apple.systempreferences:"))
            #expect(row.pane.hasPrefix("Privacy & Security › "))
            #expect(!row.purpose.isEmpty)
        }
    }

    // MARK: - Where it opens

    @Test func theWindowOpensInTheTopRightCorner() {
        // Where emira lives: the menu bar item this window hands over to is in the same corner.
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1130)
        let size = CGSize(width: 468, height: 390)
        let margin = OnboardingPlacement.cornerMargin
        let origin = OnboardingPlacement.origin(for: size, in: visible)

        #expect(origin.x == visible.maxX - size.width - margin)
        #expect(origin.y == visible.maxY - size.height - margin)
        // Inset on both axes rather than flush, and `visibleFrame` has already taken the menu bar off.
        #expect(origin.x + size.width < visible.maxX)
        #expect(origin.y + size.height < visible.maxY)
    }

    @Test func theCornerCannotCollideWithACentredPrompt() {
        // Why a corner and not a lower centre: macOS's grant prompt is centred, so the right-hand column
        // is *beside* it and no prompt height can reach the window.
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1130)
        let origin = OnboardingPlacement.origin(for: CGSize(width: 468, height: 390), in: visible)

        // A generously wide centred prompt, at any height at all.
        let prompt = CGRect(x: visible.midX - 320, y: visible.minY, width: 640, height: visible.height)
        #expect(origin.x > prompt.maxX)
    }

    @Test func placementRespectsWhereTheScreenActuallyIs() {
        // A menu bar, a Dock and a second display to the left all arrive as a non-zero origin.
        let visible = CGRect(x: -2560, y: 300, width: 2560, height: 1600)
        let size = CGSize(width: 468, height: 390)
        let origin = OnboardingPlacement.origin(for: size, in: visible)
        #expect(origin.x == visible.maxX - size.width - OnboardingPlacement.cornerMargin)
        #expect(origin.y == visible.maxY - size.height - OnboardingPlacement.cornerMargin)
    }

    @Test func aWindowTallerThanTheScreenStaysReachable() {
        // Clamped rather than centred: the title bar has to stay on screen, since the close button is
        // the only way to decline.
        let visible = CGRect(x: 0, y: 0, width: 400, height: 300)
        let origin = OnboardingPlacement.origin(for: CGSize(width: 600, height: 500), in: visible)
        #expect(origin == CGPoint(x: visible.minX, y: visible.minY))
    }

    @Test func aScreenTooShortForTheMarginKeepsTheWindowOnIt() {
        // `visibleFrame`'s floor is a Dock, a second display's offset, or both — the margin gives way
        // before the window does.
        let visible = CGRect(x: 0, y: 100, width: 1000, height: 460)
        let size = CGSize(width: 468, height: 420)
        let origin = OnboardingPlacement.origin(for: size, in: visible)
        #expect(origin.y == visible.minY)                       // the 80 pt margin didn't fit; 40 did
        #expect(origin.y + size.height <= visible.maxY)
        #expect(origin.x == visible.maxX - size.width - OnboardingPlacement.cornerMargin)
    }
}
