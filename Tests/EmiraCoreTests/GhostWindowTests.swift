import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// The reducer half of the "ghost window" report (2026-07-26): three ways a window ended up on the
// strip without its real counterpart following, or off the strip with focus stuck on it. Each of these
// asserted the *broken* behaviour first, and each failed the moment its fix landed.

@Suite struct GhostWindowTests {

    static let display = Rect(x: 0, y: 0, width: 1000, height: 800)
    static let half = Config(widthPresets: PresetCycle([.proportion(0.5)]))
    static let full = Config(widthPresets: PresetCycle([.proportion(1.0)]))

    static func booted(_ config: Config = half) -> State {
        let (s, _) = Engine.reduce(State(config: config),
                                   .screensChanged([MonitorInfo(id: MonitorId(1), frame: display)]))
        return s
    }

    static func snap(_ raw: UInt64, role: WindowRole = .standard,
                     frame: Rect = Rect(x: 300, y: 300, width: 200, height: 200)) -> WindowSnapshot {
        WindowSnapshot(id: WindowId(raw), bundleId: "com.mitchellh.ghostty", title: "w\(raw)",
                       role: role, frame: frame)
    }

    static func run(_ start: State, _ events: [Event]) -> (State, [Effect]) {
        var s = start
        var fx: [Effect] = []
        for e in events {
            let (n, f) = Engine.reduce(s, e)
            s = n
            fx += f
        }
        return (s, fx)
    }

    static func placement(of id: WindowId, in fx: [Effect]) -> Rect? {
        for e in fx {
            switch e {
            case .setFrame(let w, let r) where w == id: return r
            case .park(let w, let r) where w == id: return r
            default: continue
            }
        }
        return nil
    }

    // MARK: Focus resting off the strip is an entry condition, not a dead end

    @Test func focusOnANonStripWindowStillLetsFocusReEnterTheStrip() {
        var s = Self.booted()
        (s, _) = Self.run(s, [.windowCreated(Self.snap(1)),
                              .windowCreated(Self.snap(2)),
                              .windowCreated(Self.snap(3))])
        #expect(s.layout.columns.count == 3)

        // A window with a non-standard role — a dialog, or one whose AX subrole read came back
        // unreadable. It is recorded in World and correctly gets no column...
        (s, _) = Self.run(s, [.windowCreated(Self.snap(9, role: .other))])
        #expect(s.layout.columns.count == 3)

        // ...but it can still take focus: activating an app surfaces whichever window is AXMain.
        (s, _) = Self.run(s, [.focusChanged(WindowId(9))])
        #expect(s.world.focusedWindow == WindowId(9))

        // `right` re-enters at the left edge, `left` at the right edge — and both actually move.
        let (rightward, rightFx) = Engine.reduce(s, .command(.focus(.right)))
        #expect(rightward.world.focusedWindow == rightward.layout.columns.first?.windowIds.first)
        #expect(rightFx.contains { if case .focus = $0 { return true }; return false })

        let (leftward, _) = Engine.reduce(s, .command(.focus(.left)))
        #expect(leftward.world.focusedWindow == leftward.layout.columns.last?.windowIds.first)

        // And from there navigation works normally: stepping right reaches the far column.
        var walk = rightward
        (walk, _) = Self.run(walk, [.command(.focus(.right)), .command(.focus(.right))])
        #expect(walk.world.focusedWindow == walk.layout.columns.last?.windowIds.first,
                "the far-right column is reachable again")
    }

    // MARK: A refused write invalidates the optimistic frame it was supposed to confirm

    @Test func aFailedPlacementIsReIssuedRatherThanSkippedForever() {
        var s = Self.booted()
        let natural = Rect(x: 300, y: 300, width: 200, height: 200)
        var fx: [Effect] = []
        (s, fx) = Self.run(s, [.windowCreated(Self.snap(1, frame: natural)),
                               .windowCreated(Self.snap(2, frame: natural))])
        let target = Self.placement(of: WindowId(2), in: fx)
        #expect(target != nil, "first placement is emitted")

        // The app refused the write and could not be read back either, so the only thing that arrives
        // is `axFailed` — no corrected frame. The core records that it does not know where the window is.
        (s, _) = Self.run(s, [.axFailed(WindowId(2))])
        #expect(s.world.unverified.contains(WindowId(2)))

        // The next real event re-issues the set instead of trusting the guess.
        var retried: [Effect] = []
        (s, retried) = Engine.reduce(s, .dragEnded)
        #expect(Self.placement(of: WindowId(2), in: retried) == target, "re-aimed at the same target")
        #expect(!s.world.unverified.contains(WindowId(2)), "asking again clears the mark")

        // And a window that never failed is still diffed away — this did not turn placement into a
        // broadcast.
        #expect(Self.placement(of: WindowId(1), in: retried) == nil)
    }

    // MARK: A window adopted mid-transition is placed and covered, not dropped

    @Test func aWindowAdoptedDuringATransitionIsPlacedAndCaptured() {
        var s = Self.booted(Self.full)   // full-width columns ⇒ focus across columns really scrolls
        (s, _) = Self.run(s, [.windowCreated(Self.snap(1)), .windowCreated(Self.snap(2))])

        var fx: [Effect] = []
        (s, fx) = Engine.reduce(s, .command(.focus(.left)))
        #expect(s.motion.isTransitioning, "a scroll transition is open")

        // Raise the cover so the session is past `.capturing` — the state a real ⌘N lands in.
        for id in fx.compactMap({ if case .capture(let w) = $0 { return w }; return nil }) {
            (s, _) = Engine.reduce(s, .captureReady(id))
        }
        #expect(s.motion.isCovered)

        // A new window is adopted while it runs.
        (s, fx) = Engine.reduce(s, .windowCreated(Self.snap(3)))
        #expect(s.layout.columns.count == 3, "it joined the strip")
        #expect(Self.placement(of: WindowId(3), in: fx) != nil,
                "and the real window was told where to go")
        #expect(fx.contains { if case .capture(WindowId(3)) = $0 { return true }; return false },
                "and it is in the transition's scope, so the cover gets a layer for it")
    }
}
