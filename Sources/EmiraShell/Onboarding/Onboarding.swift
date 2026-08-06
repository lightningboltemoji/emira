import CoreGraphics
import Foundation

// The first launch, in one window: every grant emira needs, listed live, each with the button that opens
// its pane. `OnboardingModel` is the policy — which grants are asked for, the copy, when boot may proceed
// — and `OnboardingWindow` the AppKit wiring, the split `StatusModel` keeps.

/// One grant the window asks for: what System Settings calls it, why emira wants it, and where it is
/// switched on.
public struct GrantRow: Equatable, Sendable {

    /// Which grant this is. The window asks for one at a time, and only one of the two can be read by the
    /// process that wants it.
    public enum Service: Hashable, Sendable {
        case accessibility
        case screenRecording
    }

    public let service: Service

    /// As System Settings spells it — the row's label, and the noun the status line waits on.
    public let name: String

    /// Why emira wants this grant, standing alone as the row's caption.
    public let purpose: String

    /// The pane, spelled out for the row's tooltip.
    public let pane: String

    /// The deep link the row's button opens.
    public let url: String

    /// As of the last poll, which is every `OnboardingModel.pollInterval`.
    public var grant: Permissions.Grant

    /// The row's first column. Two states, because "not yet asked" and "refused" are indistinguishable
    /// through the public API.
    public var indicator: String { grant.isGranted ? "✅" : "❌" }

    public static func accessibility(_ grant: Permissions.Grant) -> GrantRow {
        GrantRow(service: .accessibility,
                 name: "Accessibility",
                 purpose: "To move and modify windows",
                 pane: "Privacy & Security › Accessibility",
                 url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                 grant: grant)
    }

    public static func screenRecording(_ grant: Permissions.Grant) -> GrantRow {
        GrantRow(service: .screenRecording,
                 name: "Screen Recording",
                 purpose: "To animate transitions",
                 pane: "Privacy & Security › Screen & System Audio Recording",
                 url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                 grant: grant)
    }

    /// Read this grant again, **monotonically**: `Permissions.screenRecording` answers from a cache this
    /// process cannot clear, so a row the subprocess probe found granted would revert on the next tick.
    /// Onboarding only waits for a grant to arrive; a revocation is the running daemon's problem.
    public func refreshed() -> GrantRow {
        guard !grant.isGranted else { return self }
        var next = self
        switch service {
        case .accessibility:   next.grant = Permissions.accessibility
        case .screenRecording: next.grant = Permissions.screenRecording
        }
        return next
    }

    /// Show this grant's standard system prompt. The return is `.denied` until the user acts, so nothing
    /// reads it — what the prompt buys is emira's row in the pane and macOS's own shortcut there.
    public func request() {
        switch service {
        case .accessibility:   Permissions.requestAccessibility()
        case .screenRecording: Permissions.requestScreenRecording()
        }
    }
}

/// What the onboarding window says, and when boot may proceed.
public struct OnboardingModel: Equatable, Sendable {

    /// How often the grants are re-read. Fast enough that flipping the switch in System Settings and
    /// glancing back at the window reads as instant.
    public static let pollInterval: TimeInterval = 0.3

    /// The grants emira is asking for, in the order it asks. **Every row is required** — a grant the
    /// config waived is not a row at all — so satisfaction is just "all of them".
    public var rows: [GrantRow]

    public init(rows: [GrantRow]) {
        self.rows = rows
    }

    /// The live model. `wantsCover` is `Config.transitionMode.covers` *as the file spells it*: asking for the
    /// cover is what makes Screen Recording required, so a config that turned it off is never asked for
    /// it. The window doesn't advertise that — both grants are billed as required.
    public static func live(wantsCover: Bool) -> OnboardingModel {
        var rows = [GrantRow.accessibility(Permissions.accessibility)]
        if wantsCover { rows.append(.screenRecording(Permissions.screenRecording)) }
        return OnboardingModel(rows: rows)
    }

    /// The same rows, re-read. The *set* never changes while the window is up — the config is not
    /// consulted again — so this is a status refresh and nothing else.
    public func refreshed() -> OnboardingModel {
        var next = self
        next.rows = rows.map { $0.refreshed() }
        return next
    }

    /// Whether boot may proceed.
    public var isSatisfied: Bool { rows.allSatisfy(\.grant.isGranted) }

    /// What is still outstanding, by name — the status line's subject and the daemon's log line.
    public var missing: [String] { rows.filter { !$0.grant.isGranted }.map(\.name) }

    /// Whether Screen Recording is among the rows, i.e. whether the config asked for the cover.
    public var isAskingForCover: Bool { rows.contains { $0.service == .screenRecording } }

    /// The blurb, one string per paragraph, in the inline markdown `OnboardingWindow` renders. A grant
    /// emira isn't asking for gets no paragraph.
    public var paragraphs: [String] {
        var text = ["**Accessibility** permissions are required to move, resize, and focus your"
                    + " windows."]
        if isAskingForCover {
            text.append("**Screen Recording** permissions are required for animations: screenshots"
                        + " stand in for real windows during transitions.")
        }
        return text
    }

    /// The line under the table: what is being waited for, or — once nothing is — what has to happen for
    /// the grants to take effect. A grant given to a *running* emira is only half a grant, so the honest
    /// end of onboarding is a restart, said next to the button that starts it.
    public var status: String {
        isSatisfied
            ? "emira must be restarted. Quit and reopen."
            : "Waiting for \(Self.list(missing))…"
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// Where the onboarding window opens.
public enum OnboardingPlacement {

    /// The inset from the working area's top-right corner, on both axes.
    public static let cornerMargin: CGFloat = 80

    /// The working area's top-right corner, inset by `cornerMargin`. macOS centres its own grant prompt,
    /// so a window in the right-hand column is *beside* it whatever its height; it is also where emira
    /// lives, under the menu bar item this window hands over to. Clamped, since closing is the only way
    /// to decline.
    public static func origin(for size: CGSize, in visible: CGRect) -> CGPoint {
        CGPoint(x: max(visible.maxX - size.width - cornerMargin, visible.minX),
                y: max(visible.maxY - size.height - cornerMargin, visible.minY))
    }
}
