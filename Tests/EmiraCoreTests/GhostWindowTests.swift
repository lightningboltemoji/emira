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
    /// `half`, but snapping — §4a, the supported configuration on a machine with no Screen Recording
    /// grant. Used where the assertion is about *where the strip lands*, not how it gets there: under
    /// the animated path the resting value is only reached once the spring settles.
    static let halfSnap = Config(widthPresets: PresetCycle([.proportion(0.5)]),
                                 smoothTransitions: false)

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

    /// Drive a state to rest — answer every capture, land every set, tick until settled.
    static func settle(_ start: State, _ effects: [Effect] = []) -> State {
        var s = start
        var queue = effects
        for _ in 0..<4000 {
            var feedback: [Event] = []
            for effect in queue {
                switch effect {
                case .capture(let w): feedback.append(.captureReady(w))
                case .setFrame(let w, _), .park(let w, _): feedback.append(.axLanded(w))
                default: continue
                }
            }
            queue = []
            if feedback.isEmpty {
                guard s.motion.isTransitioning else { return s }
                feedback = [.tick(dt: 1.0 / 120)]
            }
            for event in feedback {
                let (next, out) = Engine.reduce(s, event)
                s = next
                queue += out
            }
        }
        return s
    }

    /// As `EngineTests.run`: an arrival that *opened* a transition is driven to rest, because building
    /// a world is setup rather than the thing under test. One that joined a live transition is not.
    static func run(_ start: State, _ events: [Event]) -> (State, [Effect]) {
        var s = start
        var fx: [Effect] = []
        for e in events {
            let wasIdle = !s.motion.isTransitioning
            let (n, f) = Engine.reduce(s, e)
            s = n
            fx += f
            let isArrival: Bool
            switch e {
            case .windowCreated, .windowDeminimized: isArrival = true
            default: isArrival = false
            }
            if wasIdle, isArrival, s.motion.isTransitioning { s = settle(s, f) }
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
        // §4a's configuration: this is about the placement *diff*, so the sets want to be in the same
        // batch as the event rather than arriving later at a cover's raise.
        var s = Self.booted(Self.halfSnap)
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

    // MARK: Arrival — the strip opens for a new window, and it opens beside the focused one

    @Test func aNewWindowOpensBesideTheFocusedColumnNotAtTheEndOfTheStrip() {
        var s = Self.booted()
        (s, _) = Self.run(s, (1...3).map { .windowCreated(Self.snap($0)) })
        #expect(s.layout.columns.map(\.windowIds) == [[WindowId(1)], [WindowId(2)], [WindowId(3)]],
                "each arrival opened beside the one that had focus, so they chain left to right")

        // Go back to the first column and open another: it lands immediately to its right.
        (s, _) = Self.run(s, [.focusChanged(WindowId(1)), .windowCreated(Self.snap(4))])
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(4)], [WindowId(2)], [WindowId(3)]])
        #expect(s.world.focusedWindow == WindowId(4), "and it takes focus")
    }

    @Test func aNewWindowStillOpensBesideTheFocusedColumnWhenFocusWentNilFirst() {
        // The product's actual event order, which the plain insertion test could not express: an app
        // focuses its brand-new window *before* emira has adopted it, so the observer resolves that
        // element to no id and `focusChanged(nil)` lands first. Anchoring on live focus alone made
        // every ⌘N append at the far end of the strip; `World.lastStripFocus` is what survives it.
        var s = Self.booted()
        (s, _) = Self.run(s, (1...3).map { .windowCreated(Self.snap($0)) })
        (s, _) = Self.run(s, [.focusChanged(WindowId(1))])
        #expect(s.world.lastStripFocus == WindowId(1))

        (s, _) = Self.run(s, [.focusChanged(nil), .windowCreated(Self.snap(4))])
        #expect(s.layout.columns.map(\.windowIds)
                == [[WindowId(1)], [WindowId(4)], [WindowId(2)], [WindowId(3)]],
                "opened beside where the user was working, not at the end")
    }

    @Test func anArrivalAnimatesAndItsFirstFrameIsWhereTheAppOpenedIt() {
        var s = Self.booted()
        (s, _) = Self.run(s, (1...2).map { .windowCreated(Self.snap($0)) })

        // A third window, opened by its app somewhere of the app's choosing.
        let opened = Rect(x: 420, y: 260, width: 700, height: 500)
        var fx: [Effect] = []
        (s, fx) = Engine.reduce(s, .windowCreated(Self.snap(3, frame: opened)))

        #expect(s.motion.isTransitioning, "the strip opens for it under the cover")
        #expect(fx.contains { if case .capture(WindowId(3)) = $0 { return true }; return false },
                "so it needs a still of its own")

        // The seeded displacement is what makes the raise seamless: the newcomer's first animated
        // frame reproduces the frame its layer was captured at, rather than jumping to its column.
        let metrics = s.metrics()!
        let natural = s.layout.naturalFrames(scrollOffset: s.motion.viewportOffset.current,
                                             metrics: metrics)[WindowId(3)]
        #expect(natural != nil)
        let first = natural!.displaced(by: s.motion.displacement(of: WindowId(3)))
        #expect(Self.approx(first, opened), "first frame \(first) should be the opened frame \(opened)")

        // And it settles onto the layout's answer, which is a real column.
        let settled = Self.settle(s, fx)
        #expect(settled.motion.displacement(of: WindowId(3)) == .zero)
        #expect(settled.layout.columnIndex(ofWindow: WindowId(3)) != nil)
    }

    static func approx(_ a: Rect, _ b: Rect, tol: Double = 0.01) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol &&
        abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    // MARK: The viewport never rests looking past the end of the strip

    /// Scroll to the far right, then close columns the viewport is *not* focused on. Focus survives,
    /// so nothing on this path asks to reveal anything — which is exactly how the offset is left
    /// describing a strip that no longer exists.
    private static func strandedViewport(windows: Int, closing: [UInt64],
                                         config: Config = halfSnap) -> State {
        var s = booted(config)
        (s, _) = run(s, (1...UInt64(windows)).map { .windowCreated(snap($0)) })
        (s, _) = run(s, (1..<windows).map { _ in .command(.focus(.right)) })
        (s, _) = run(s, closing.map { .windowDestroyed(WindowId($0)) })
        return s
    }

    @Test func closingColumnsPullsTheViewportBackOntoTheStrip() {
        let s = Self.strandedViewport(windows: 6, closing: [1, 2, 3])
        #expect(s.world.focusedWindow == WindowId(6), "focus survived, so nothing revealed anything")

        let metrics = s.metrics()!
        let maxOffset = s.layout.strip(metrics: metrics)
            .maxOffset(viewportWidth: metrics.workingArea.width)
        #expect(s.motion.viewportOffset.current <= maxOffset + 0.5,
                "rests at \(s.motion.viewportOffset.current), strip allows at most \(maxOffset)")

        // The concrete symptom: with the viewport off the end, columns that would fit on screen are
        // parked at their 1 px slivers beside empty desktop instead.
        let visible = s.layout.visibleWindowIds(scrollOffset: s.motion.viewportOffset.current,
                                                metrics: metrics)
        #expect(visible.count == 2, "both columns the viewport can hold are on screen, not parked")
    }

    @Test func theCollapseIsAnimatedAndAimsAtTheClampedOffset() {
        // The same departure with a cover available: the viewport must still be *heading* inside the
        // strip, and the survivors must be under a transition rather than teleported.
        let s = Self.strandedViewport(windows: 6, closing: [1, 2, 3], config: Self.half)
        #expect(s.motion.isTransitioning, "closing a column opens the signature transition")

        let metrics = s.metrics()!
        let maxOffset = s.layout.strip(metrics: metrics)
            .maxOffset(viewportWidth: metrics.workingArea.width)
        #expect(s.motion.viewportOffset.target <= maxOffset + 0.5,
                "aims inside the strip even though it has not arrived yet")
        #expect(s.motion.viewportOffset.current > s.motion.viewportOffset.target,
                "and it is still travelling — the collapse is motion, not a jump")

        // Every surviving column is lagging behind where the layout now puts it, which is the
        // displacement that *is* the collapse.
        let lagging = s.layout.allWindowIds.filter { s.motion.displacement(of: $0) != .zero }
        #expect(!lagging.isEmpty, "survivors are displaced, decaying to zero")
    }

    @Test func closingTheFocusedWindowFocusesItsNeighbourNotTheFrontOfTheStrip() {
        var s = Self.booted(Self.halfSnap)
        (s, _) = Self.run(s, (1...4).map { .windowCreated(Self.snap($0)) })

        // Focus the third column, then close it: focus takes the column that slid into its place.
        (s, _) = Self.run(s, [.focusChanged(WindowId(3)), .windowDestroyed(WindowId(3))])
        #expect(s.world.focusedWindow == WindowId(4), "the right neighbour, not window 1")

        // Close the last column: there is no right neighbour, so the left one takes over.
        (s, _) = Self.run(s, [.windowDestroyed(WindowId(4))])
        #expect(s.world.focusedWindow == WindowId(2))
    }

    @Test func closingAStackedWindowKeepsFocusInItsOwnColumn() {
        var s = Self.booted(Self.halfSnap)
        (s, _) = Self.run(s, (1...3).map { .windowCreated(Self.snap($0)) })
        // Pull window 2 into window 1's column, so column 0 is a two-window stack.
        (s, _) = Self.run(s, [.focusChanged(WindowId(2)), .command(.consumeOrExpel(.left))])
        #expect(s.layout.columns.first?.windowIds.count == 2)

        (s, _) = Self.run(s, [.focusChanged(WindowId(2)), .windowDestroyed(WindowId(2))])
        #expect(s.world.focusedWindow == WindowId(1), "the surviving stackmate, not another column")
    }

    @Test func aStripThatFitsEntirelyOnScreenRestsAtZero() {
        let s = Self.strandedViewport(windows: 5, closing: [1, 2, 3, 4])
        #expect(s.layout.columns.count == 1)
        #expect(abs(s.motion.viewportOffset.current) <= 0.5,
                "one column is narrower than the viewport, so there is nowhere to be but the start")
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
