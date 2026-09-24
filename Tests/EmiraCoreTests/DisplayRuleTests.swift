import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

/// `[[display]]` blocks: which display one names, what it leaves `[layout]`'s, and that the reducer lays
/// each display out against its own.
@Suite struct DisplayRuleTests {

    static let builtIn = "Built-in Retina Display"
    static let external = "DELL U3223QE"

    // Matching

    @Test func aNameMatchesExactly() {
        let rule = DisplayRule(name: Self.builtIn, columnGap: 4)
        #expect(rule.matches(Self.builtIn))
        #expect(!rule.matches("Built-in"))
        #expect(!rule.matches(Self.external))
    }

    @Test func aPatternMatchesAnywhereInTheName() {
        let rule = DisplayRule(nameRegex: "Built-in", columnGap: 4)
        #expect(rule.matches(Self.builtIn))
        #expect(rule.matches("Built-in Liquid Retina XDR Display"))
        #expect(!rule.matches(Self.external))
    }

    @Test func everyMatcherSetMustAgree() {
        let rule = DisplayRule(name: Self.external, nameRegex: "^LG", columnGap: 4)
        #expect(!rule.matches(Self.external))
    }

    /// A rule naming nothing would be `[layout]` a second time; the reader refuses one, and one built
    /// in code matches nothing rather than everything.
    @Test func aRuleWithNoMatcherMatchesNothing() {
        #expect(!DisplayRule(columnGap: 4).matches(Self.builtIn))
    }

    // What a display sees

    static let base = Config(columnGap: 16, windowGap: 12, outerGaps: EdgeInsets(uniform: 20))

    @Test func aDisplayNoBlockNamesSeesLayoutAsWritten() {
        var config = Self.base
        config.displays = [DisplayRule(name: Self.builtIn, columnGap: 4)]
        #expect(config.on(display: Self.external) == config)
    }

    @Test func aBlockOverridesOnlyWhatItWrites() {
        var config = Self.base
        config.displays = [DisplayRule(name: Self.builtIn, columnGap: 4,
                                       outerGaps: EdgeInsetsPatch(top: 0))]
        let seen = config.on(display: Self.builtIn)
        #expect(seen.columnGap == 4)
        #expect(seen.windowGap == 12)
        #expect(seen.outerGaps == EdgeInsets(top: 0, left: 20, bottom: 20, right: 20))
    }

    /// Two blocks naming one display apply in file order, the later winning key by key — and an edge
    /// of `outer-gap` is a key of its own, so one block's top and another's left both stand.
    @Test func aLaterBlockWinsKeyByKey() {
        var config = Self.base
        config.displays = [
            DisplayRule(nameRegex: "Built-in", columnGap: 4, windowGap: 4,
                        outerGaps: EdgeInsetsPatch(top: 2)),
            DisplayRule(name: Self.builtIn, columnGap: 8, outerGaps: EdgeInsetsPatch(left: 6)),
        ]
        let seen = config.on(display: Self.builtIn)
        #expect(seen.columnGap == 8)
        #expect(seen.windowGap == 4)
        #expect(seen.outerGaps == EdgeInsets(top: 2, left: 6, bottom: 20, right: 20))
    }

    // The reducer

    /// The laptop on the left, a monitor to its right, and `[layout]` asking for a 50 pt margin that
    /// only the laptop overrides.
    static func desktop(_ config: Config) -> State {
        let (s, _) = Engine.reduce(State(config: config), .screensChanged([
            MonitorInfo(id: MonitorId(1), frame: Rect(x: 0, y: 0, width: 1000, height: 800),
                        isMain: true, name: builtIn),
            MonitorInfo(id: MonitorId(2), frame: Rect(x: 1000, y: 0, width: 1000, height: 800),
                        name: external),
        ]))
        return s
    }

    static let margined: Config = {
        var config = Config(columnGap: 30, outerGaps: EdgeInsets(uniform: 50), transitionMode: .off)
        config.displays = [DisplayRule(name: builtIn, columnGap: 6, outerGaps: EdgeInsetsPatch(
            top: 10, left: 10, bottom: 10, right: 10))]
        return config
    }()

    @Test func eachDisplayIsLaidOutAgainstItsOwnGaps() throws {
        let s = Self.desktop(Self.margined)
        let laptop = try #require(s.metrics(of: MonitorId(1)))
        let monitor = try #require(s.metrics(of: MonitorId(2)))
        #expect(laptop.columnGap == 6)
        #expect(laptop.outerGaps == EdgeInsets(uniform: 10))
        #expect(monitor.columnGap == 30)
        #expect(monitor.outerGaps == EdgeInsets(uniform: 50))
    }

    /// A reload is where a user meets this: the block is written, the file saved, and the window on the
    /// display it names moves to its new margin without anything else having to happen.
    @Test func aReloadMovesTheDisplayABlockNames() throws {
        var config = Self.margined
        config.displays = []
        var s = Self.desktop(config)
        let (placed, fx) = Engine.reduce(s, .windowCreated(EngineFix.snapshot(1)))
        s = EngineFix.settle(placed, fx)

        let (_, effects) = Engine.reduce(s, .configChanged(Self.margined))
        let frame = effects.compactMap { effect -> Rect? in
            guard case .setFrame(WindowId(1), let rect) = effect else { return nil }
            return rect
        }.last
        // Alone on the strip, so the whole content area: the laptop's 10 pt margin, not the file's 50.
        #expect(frame == Rect(x: 10, y: 10, width: 980, height: 780))
    }
}
