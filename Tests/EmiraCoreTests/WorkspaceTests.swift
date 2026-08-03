import Foundation
import Testing
@testable import EmiraCore

/// The workspace address space: a fixed, ordered domain of 36 names, `1`…`9`, `0`, then `a`…`z`.
@Suite struct WorkspaceNameTests {

    /// The key order is the whole of the ordering: the domain is a keyboard's number row followed by its
    /// letters, so `1` is the launch address and `0` is the tenth — where the key actually sits.
    @Test func theDomainIsExactlyThirtySixNamesInKeyOrder() {
        #expect(WorkspaceName.all.count == 36)
        #expect(WorkspaceName.all.map(\.description).joined() == "1234567890abcdefghijklmnopqrstuvwxyz")
        #expect(WorkspaceName.first.description == "1")
        #expect(WorkspaceName.last.description == "z")
        #expect(WorkspaceName("0")!.rank == 9)
    }

    /// Rank order is not alphabetical order, and `0` is the single place they disagree. Every ordered
    /// view in `Workspaces` sorts by the *name* (`Comparable`, i.e. by rank) rather than by its spelling;
    /// one that sorted strings would put `0` at the front, silently.
    @Test func rankOrderIsTheKeyOrderNotTheAlphabeticalOne() {
        let byRank = WorkspaceName.all.sorted()
        let byCharacter = WorkspaceName.all.sorted { $0.description < $1.description }
        #expect(byRank != byCharacter)
        #expect(byRank == WorkspaceName.all)                       // `all` is already in rank order
        // The two agree everywhere `0` is not involved.
        #expect(byRank.filter { $0 != WorkspaceName("0")! }
                == byCharacter.filter { $0 != WorkspaceName("0")! })
        #expect(WorkspaceName("1")! < WorkspaceName("9")!)
        #expect(WorkspaceName("9")! < WorkspaceName("0")!)         // …and this is the disagreement
        #expect(WorkspaceName("0")! < WorkspaceName("a")!)
        #expect(WorkspaceName("a")! < WorkspaceName("z")!)
    }

    @Test func everyNameRoundTripsThroughItsCharacter() {
        for name in WorkspaceName.all {
            #expect(WorkspaceName(name.character) == name)
            #expect(WorkspaceName(rank: name.rank) == name)
        }
    }

    /// Failable and total, so a bad name is a config/CLI diagnostic rather than a trap. Strict about
    /// case on purpose: this type keys a dictionary, and two spellings of one address would let a
    /// decoded document silently lose an entry.
    @Test func anythingOutsideTheDomainIsNilNotATrap() {
        for bad: Character in ["A", "Z", "-", " ", "/", "é", "!"] {
            #expect(WorkspaceName(bad) == nil, "\(bad)")
        }
        #expect(WorkspaceName("") == nil)
        #expect(WorkspaceName("ab") == nil)          // a name is one character, never two
        #expect(WorkspaceName(rank: -1) == nil)
        #expect(WorkspaceName(rank: 36) == nil)
    }

    /// `next`/`previous` step one address and clamp at the ends — no wrap, matching `focus left|right`
    /// at the strip's edges. They follow the *key* order, so the number row runs into `0` first.
    @Test func relativeMotionClampsAtBothEndsRatherThanWrapping() {
        #expect(WorkspaceName("1")!.next == WorkspaceName("2"))
        #expect(WorkspaceName("9")!.next == WorkspaceName("0"))   // the end of the number row
        #expect(WorkspaceName("0")!.next == WorkspaceName("a"))   // then the letters
        #expect(WorkspaceName("a")!.previous == WorkspaceName("0"))
        #expect(WorkspaceName.last.next == nil)                   // clamps, never wraps to "1"
        #expect(WorkspaceName.first.previous == nil)              // …and `prev` at launch is a no-op
    }

    /// Encoded as the one-character string, not the rank, so dumps and replay logs stay legible.
    @Test func namesEncodeAsTheirCharacter() throws {
        let data = try JSONEncoder().encode([WorkspaceName("0")!, WorkspaceName("a")!])
        #expect(String(decoding: data, as: UTF8.self) == #"["0","a"]"#)
        let back = try JSONDecoder().decode([WorkspaceName].self, from: data)
        #expect(back == [WorkspaceName("0")!, WorkspaceName("a")!])
    }

    @Test func decodingANameOutsideTheDomainFails() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WorkspaceName.self, from: Data(#""A""#.utf8))
        }
    }

    /// `CodingKeyRepresentable` is what makes `[WorkspaceName: T]` a JSON *object* keyed by the
    /// character rather than the flat alternating array Swift falls back to for non-string keys. The
    /// state dump is the thing that reads it, so this is pinned as a wire form, not just a round-trip.
    @Test func nameKeyedDictionariesEncodeAsObjects() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode([WorkspaceName("0")!: 1, WorkspaceName("c")!: 2])
        #expect(String(decoding: data, as: UTF8.self) == #"{"0":1,"c":2}"#)
        #expect(try JSONDecoder().decode([WorkspaceName: Int].self, from: data)
                == [WorkspaceName("0")!: 1, WorkspaceName("c")!: 2])
    }
}

/// The multi-strip container. Everything here is provably inert while there is one workspace: park
/// slots colliding, `reconcile` migrating windows between strips, and `ColumnId`s colliding across
/// strips are all silent failures, and this is where they can be proved against.
@Suite struct WorkspacesTests {

    private let w1 = WindowId(1), w2 = WindowId(2), w3 = WindowId(3), w4 = WindowId(4)
    /// The launch address plus two more, in ascending rank order — what every `materialized` /
    /// `placementOrder` assertion below is written against.
    private let a = WorkspaceName.first, b = WorkspaceName("3")!, c = WorkspaceName("z")!

    /// A 900×600 working area, columns ⅓ of it = 300 pt, no gaps — the same fixture `LayoutTests`
    /// uses, so a frame here can be read against the ones asserted there.
    private let metrics = LayoutMetrics(
        workingArea: Rect(x: 0, y: 0, width: 900, height: 600),
        widthPresets: PresetCycle([.proportion(1.0 / 3.0)]),
        columnGap: 0, windowGap: 0)

    /// The two containers as the reducer holds them. `Workspaces` no longer knows which address is on
    /// screen — a *monitor* does — so a test that needs the difference says which one it means, and
    /// this is the one-line way of saying it.
    private struct Desktop {
        var workspaces = Workspaces()
        var shown = WorkspaceName.first

        /// Put `name` on screen: what `Monitors.show` plus the reducer's `materialize` do together.
        mutating func show(_ name: WorkspaceName) {
            shown = name
            workspaces.materialize(name)
        }

        mutating func reconcile(_ ids: [WindowId], insertingAfter anchor: WindowId? = nil) {
            workspaces.reconcile(stripWindowIds: ids, onto: shown, insertingAfter: anchor)
        }

        func targetFrames(_ metrics: LayoutMetrics) -> [WindowId: Rect] {
            workspaces.targetFrames(shown: [shown], scrollOffset: 0, metrics: metrics)
        }

        var strip: Layout {
            get { workspaces[shown] }
            set { workspaces[shown] = newValue }
        }
    }

    @Test func aFreshSetHasExactlyTheLaunchWorkspace() {
        let ws = Workspaces()
        #expect(ws.materialized == [.first])
        #expect(ws.allWindowIds.isEmpty)
    }

    /// An unmaterialized name answers as an empty strip, so nothing anywhere branches on existence.
    @Test func anUnmaterializedNameReadsAsAnEmptyStrip() {
        let ws = Workspaces()
        #expect(ws[c].isEmpty)
        #expect(ws[c].columns.isEmpty)
        #expect(ws.materialized == [.first])   // …and reading it did not materialize it
    }

    /// Materialized on demand and never dropped: no collapsing, as a property.
    @Test func showingMaterializesAndNothingEverUnmaterializes() {
        var d = Desktop()
        d.show(b)
        #expect(d.workspaces.materialized == [a, b])
        d.reconcile([w1])                      // give `b` a window
        d.show(a)
        d.reconcile([])                        // and take it away again
        #expect(d.workspaces[b].isEmpty)
        #expect(d.workspaces.materialized == [a, b])     // emptied, still there
    }

    /// Name order, which is *key* order — `"0"` comes back after `"9"` and before the letters, not
    /// first, which sorting the spellings would do silently.
    @Test func materializedNamesComeBackInNameOrderNotDictionaryOrder() {
        var ws = Workspaces()
        let zero = WorkspaceName("0")!, g = WorkspaceName("g")!
        for name in [c, b, g, zero] { ws.materialize(name) }
        #expect(ws.materialized == [a, b, zero, g, c])
        #expect(ws.materialized.map(\.description) == ["1", "3", "0", "g", "z"])
    }

    /// Placement order is shown-first, then the rest by name — one rule, used by the z-order walk and
    /// by the park-ordinal run, so the effect order and the nub order cannot disagree.
    @Test func placementOrderPutsTheShownWorkspacesFirst() {
        var ws = Workspaces()
        ws.materialize(b)
        ws.materialize(c)
        #expect(ws.materialized == [a, b, c])
        #expect(ws.placementOrder(shown: [c]) == [c, a, b])
    }

    /// With two displays the order is *both* shown addresses, acting monitor's first, and only then
    /// the parked remainder — the generalization that keeps a visible strip on either screen out of
    /// the high park ordinals.
    @Test func placementOrderKeepsEveryShownWorkspaceAheadOfTheParkedOnes() {
        var ws = Workspaces()
        for name in [b, c] { ws.materialize(name) }
        #expect(ws.placementOrder(shown: [c, a]) == [c, a, b])
    }

    /// **The park run takes the same list the placement walk does**, so an address a second display is
    /// showing keeps its low ordinal on both. Two answers to "what is on screen" would show up only as
    /// a nub that renumbers when the *other* screen switches, which is precisely the silent failure the
    /// single cursor exists to rule out.
    @Test func theParkRunFollowsEveryAddressOnScreenAndNotJustTheTiledOne() {
        var ws = Workspaces()
        var ids = ColumnAllocator()
        for (name, window) in [(a, w1), (b, w2), (c, w3)] {
            var strip = ws[name]
            strip.adopt([window], after: nil, like: nil, columnIds: &ids)
            ws[name] = strip
        }

        // `a` tiles in both; the second display shows `b` in one and `c` in the other.
        let showingB = ws.targetFrames(shown: [a, b], scrollOffset: 0, metrics: metrics)
        let showingC = ws.targetFrames(shown: [a, c], scrollOffset: 0, metrics: metrics)

        #expect(showingB[w1] == showingC[w1])          // the tiled strip is untouched either way
        // Whichever address the second display shows takes the run's first nub, and the parked one
        // takes the next: the two swap exactly, rather than following name order regardless.
        #expect(showingB[w2] == showingC[w3])
        #expect(showingB[w3] == showingC[w2])
        #expect(showingB[w2] != showingB[w3])
    }

    // reconcile — the World→Workspaces bridge

    /// The single-workspace case is byte-for-byte the bare `Layout.reconcile`.
    @Test func withOneWorkspaceReconcileIsExactlyTheSingleStripCall() {
        var d = Desktop()
        d.reconcile([w1, w2, w3])

        var bare = Layout()
        var ids = ColumnAllocator()
        bare.reconcile(stripWindowIds: [w1, w2, w3], columnIds: &ids)

        #expect(d.strip == bare)
        #expect(d.workspaces.allWindowIds == bare.allWindowIds)
        #expect(d.targetFrames(metrics) == bare.targetFrames(scrollOffset: 0, metrics: metrics))
    }

    /// The dangerous one: projected onto the strip in view, the first workspace switch would see every
    /// window on every other workspace as a newcomer and drag the lot onto the one being looked at.
    @Test func newcomersJoinTheShownStripAndOtherWorkspacesAreNotMigrated() {
        var d = Desktop()
        d.reconcile([w1, w2])                  // both land on `1`
        d.show(b)
        d.reconcile([w1, w2, w3])              // w3 is the only newcomer

        #expect(d.workspaces[a].allWindowIds == [w1, w2])   // untouched, still on `1`
        #expect(d.workspaces[b].allWindowIds == [w3])       // the newcomer, alone on the shown strip
        #expect(d.workspaces.workspace(of: w1) == a)
        #expect(d.workspaces.workspace(of: w3) == b)
    }

    /// Departures leave every strip, not just the one being looked at.
    @Test func departuresAreDroppedFromEveryWorkspace() {
        var d = Desktop()
        d.reconcile([w1, w2])
        d.show(b)
        d.reconcile([w1, w2, w3])

        d.reconcile([w2, w3])                  // w1 closed, and it was on the *off-screen* `1`
        #expect(d.workspaces[a].allWindowIds == [w2])
        #expect(d.workspaces[b].allWindowIds == [w3])
        #expect(d.workspaces.workspace(of: w1) == nil)
    }

    @Test func aRepeatedReconcileWithTheSameSetChangesNothing() {
        var d = Desktop()
        d.reconcile([w1, w2])
        d.show(b)
        d.reconcile([w1, w2, w3])
        let settled = d.workspaces
        d.reconcile([w1, w2, w3])
        #expect(d.workspaces == settled)       // no churn, and no id minted (allocator compared)
    }

    @Test func aNewcomerOpensBesideTheAnchorOnTheShownStrip() {
        var d = Desktop()
        d.reconcile([w1, w2])
        d.reconcile([w1, w2, w3], insertingAfter: w1)
        #expect(d.strip.allWindowIds == [w1, w3, w2])
    }

    /// Column #1 on one workspace and column #1 on another must not be the same id: `Motion.columnWidths`
    /// is keyed by a bare `ColumnId`, so a collision would let an in-flight resize on one workspace
    /// re-aim a column on another. One allocator for the whole set makes that unrepresentable.
    @Test func columnIdsAreDisjointAcrossWorkspaces() {
        var d = Desktop()
        d.reconcile([w1, w2])
        d.show(b)
        d.reconcile([w1, w2, w3, w4])

        let all = d.workspaces.materialized.flatMap { d.workspaces[$0].columns.map(\.id) }
        #expect(all.count == 4)
        #expect(Set(all).count == all.count)   // …and every one of them distinct
    }

    /// The same property through the *other* minting mutator, and across a strip that has already had
    /// a column destroyed — the rewind the allocator's watermark exists to prevent.
    @Test func extractMintsIntoTheSameIdSpaceAndNeverReusesADestroyedId() {
        var d = Desktop()
        d.reconcile([w1, w2])
        var strip = d.strip
        strip.move(window: w2, toColumn: strip.columns[0].id, at: 1)   // one column of two windows
        d.strip = strip
        let seen = Set(d.strip.columns.map(\.id))

        d.workspaces.extract(window: w2, toNewColumnAt: 1)             // mints
        let extracted = Set(d.strip.columns.map(\.id)).subtracting(seen)
        #expect(extracted.count == 1)

        d.show(b)
        d.reconcile([w1, w2, w3])                                      // mints again, on another strip
        let everything = d.workspaces.materialized.flatMap { d.workspaces[$0].columns.map(\.id) }
        #expect(Set(everything).count == everything.count)
    }

    @Test func extractIsATotalNoOpForAWindowOnNoWorkspace() {
        var d = Desktop()
        d.reconcile([w1])
        let before = d.workspaces
        #expect(d.workspaces.extract(window: WindowId(999), toNewColumnAt: 0) == .none)
        #expect(d.workspaces == before)        // not even an id consumed
    }

    // Park slots across the whole set

    /// Every window on every off-screen workspace is parked, so the ordinals have to be one run across
    /// the set. Two windows sharing a park frame breaks the ±2 pt first-sight identity join *and* the
    /// no-overlap invariant — both silently, one permanently.
    @Test func parkSlotsAreUniqueAcrossEveryWorkspaceWithinTheBindingTolerance() {
        var d = Desktop()
        // Four columns on `1` (the last is off-viewport at a 900 pt viewport), then four more each on
        // two other workspaces — every one of the latter parked.
        d.reconcile([w1, w2, w3, w4])
        d.show(b)
        d.reconcile([w1, w2, w3, w4] + (10..<14).map(WindowId.init))
        d.show(c)
        d.reconcile([w1, w2, w3, w4] + (10..<14).map(WindowId.init) + (20..<24).map(WindowId.init))
        d.show(a)

        let frames = d.targetFrames(metrics)
        #expect(frames.count == 12)

        // Parked windows only: the tiled ones legitimately sit side by side.
        let visible = Set(d.strip.visibleWindowIds(scrollOffset: 0, metrics: metrics))
        let parked = d.workspaces.allWindowIds.filter { !visible.contains($0) }.compactMap { frames[$0] }
        #expect(parked.count == 9)             // 12 total − 3 tiled columns on `1`
        for i in parked.indices {
            for j in (i + 1)..<parked.count {
                let (x, y) = (parked[i], parked[j])
                let ambiguous = abs(x.minX - y.minX) <= 2 && abs(x.minY - y.minY) <= 2
                    && abs(x.width - y.width) <= 2 && abs(x.height - y.height) <= 2
                #expect(!ambiguous, "park slots \(i) and \(j) are indistinguishable at rebind")
            }
        }
    }

    /// A parked window keeps the size it *would* have if its workspace were on screen — parking
    /// repositions and never resizes, so switching changes a window's address and not its shape.
    @Test func aParkedWorkspaceKeepsItsOwnGeometryForSizes() {
        var d = Desktop()
        d.show(b)
        d.reconcile([w1, w2])
        d.show(a)                              // `3` is now entirely parked

        let parked = d.targetFrames(metrics)
        // ⅓ of 900 wide, full content height — exactly what it would be tiled.
        #expect(parked[w1]?.size == Size(width: 300, height: 600))
        #expect(parked[w2]?.size == Size(width: 300, height: 600))
    }

    /// The workspace on screen owns the low ordinals, so its nubs do not renumber as other addresses
    /// fill up — that is what `placementOrder(shown:)` being shown-first buys.
    @Test func theShownWorkspacesParksKeepTheirOrdinalsAsOthersFillUp() {
        var d = Desktop()
        d.reconcile([w1, w2, w3, w4])          // w4's column is off-viewport → parked
        let alone = d.targetFrames(metrics)[w4]

        d.show(b)
        d.reconcile([w1, w2, w3, w4, WindowId(10), WindowId(11)])
        d.show(a)
        #expect(d.targetFrames(metrics)[w4] == alone)
    }

    @Test func theContainerRoundTripsThroughCodable() throws {
        var d = Desktop()
        d.reconcile([w1, w2])
        d.show(b)
        d.reconcile([w1, w2, w3])

        let data = try JSONEncoder().encode(d.workspaces)
        let back = try JSONDecoder().decode(Workspaces.self, from: data)
        #expect(back == d.workspaces)
        #expect(back.materialized == [a, b])
        #expect(back[a].allWindowIds == [w1, w2])
    }

    /// The allocator watermark is serialized state, and the only way to observe it is to mint. Mutate
    /// first so it has advanced past `max(id)`, then check the original and the decoded copy hand out the
    /// *same* next id — a round-trip that dropped it would silently re-issue one.
    @Test func aRoundTrippedSetMintsTheSameNextColumnId() throws {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1, w2, w3], onto: a)   // mints 1, 2, 3
        var back = try JSONDecoder().decode(Workspaces.self, from: try JSONEncoder().encode(ws))
        #expect(back == ws)

        let churn = [w1, w2, w3, w4]
        ws.reconcile(stripWindowIds: churn, onto: a)
        back.reconcile(stripWindowIds: churn, onto: a)
        #expect(back[a].columns.last?.id == ws[a].columns.last?.id)
        #expect(back[a].columns.last?.id == ColumnId(4))
    }

    /// The dump is something a human reads (`emira debug`), so the shape is pinned, not just the
    /// round-trip: strips keyed by their character, the watermark bare. **No `focused` here** — which
    /// address is on screen is `Monitors`'s to say, and a second copy in this dump would be a second
    /// authority a reader could catch disagreeing.
    @Test func theEncodedShapeIsLegible() throws {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1], onto: a)
        ws[scrollOffsetOf: a] = 1200
        ws[lastFocusOf: a] = w1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(ws), as: UTF8.self)
        #expect(!json.contains(#""focused""#), "\(json)")
        #expect(json.contains(#""strips":{"1":"#), "\(json)")
        #expect(json.contains(#""columnIds":2"#), "\(json)")       // one column minted ⇒ next is 2
        // The memory rides in each strip's record, in the same dump — a switch that comes back to the
        // wrong place is diagnosable from `emira debug` alone.
        #expect(json.contains(#""scrollOffset":1200"#), "\(json)")
        #expect(json.contains(#""lastFocus":1"#), "\(json)")
    }
}

/// `State.layout` as a projection of `State.workspaces` at `State.monitors.shown` — single storage,
/// not a second authority, now across two containers rather than one.
@Suite struct StateProjectionTests {

    private let w1 = WindowId(1), w2 = WindowId(2)

    @Test func readingLayoutIsReadingTheShownStrip() {
        var s = State()
        s.workspaces.reconcile(stripWindowIds: [w1, w2], onto: s.monitors.shown)
        #expect(s.layout == s.workspaces[s.monitors.shown])
        #expect(s.layout.allWindowIds == [w1, w2])
    }

    /// Writing through the projection writes the shown strip and nothing else — what makes every
    /// `s.layout.moveColumn(…)`-style mutation keep working.
    @Test func writingLayoutWritesTheShownStripAndOnlyThat() {
        var s = State()
        s.workspaces.reconcile(stripWindowIds: [w1, w2], onto: s.monitors.shown)
        s.show(WorkspaceName("3")!)
        s.workspaces.reconcile(stripWindowIds: [w1, w2], onto: s.monitors.shown)   // both still on `1`

        s.layout = Layout(columns: [ColumnLayout(id: ColumnId(99), windowIds: [WindowId(9)])])
        #expect(s.workspaces[WorkspaceName("3")!].columns.map(\.id) == [ColumnId(99)])
        #expect(s.workspaces[.first].allWindowIds == [w1, w2])   // untouched
    }

    /// The single-strip `State` initializer means what it always meant: this layout, on the address the
    /// launch monitor shows, with nothing else materialized.
    @Test func theSingleStripInitializerSeedsTheShownWorkspace() {
        let layout = Layout(columns: [ColumnLayout(id: ColumnId(7), windowIds: [w1])])
        let s = State(world: World(), layout: layout, motion: Motion(), config: Config())
        #expect(s.monitors.shown == .first)
        #expect(s.workspaces.materialized == [.first])
        #expect(s.layout == layout)
    }

    /// …and it seeds the allocator past the ids it was handed, so the next mint cannot collide.
    @Test func theSingleStripInitializerResumesTheAllocatorPastTheSuppliedIds() {
        let layout = Layout(columns: [ColumnLayout(id: ColumnId(7), windowIds: [w1])])
        var s = State(world: World(), layout: layout, motion: Motion(), config: Config())
        s.workspaces.reconcile(stripWindowIds: [w1, w2], onto: s.monitors.shown)
        #expect(s.layout.columns.map(\.id) == [ColumnId(7), ColumnId(8)])
    }

    @Test func stateRoundTripsWithItsWorkspaceSet() throws {
        var s = State()
        s.workspaces.reconcile(stripWindowIds: [w1, w2], onto: s.monitors.shown)
        s.show(WorkspaceName("a")!)
        let back = try JSONDecoder().decode(State.self, from: try JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.monitors.shown == WorkspaceName("a")!)
    }

    /// Before the first `screensChanged` there is no display to hold the address, and the projection
    /// must still answer — every verb reads `State.layout`, and a `nil` here would be a crash at boot
    /// rather than the no-op `metrics()` already gives.
    @Test func theProjectionAnswersBeforeAnyDisplayIsKnown() {
        var s = State()
        #expect(s.monitors.focused == nil)
        #expect(s.metrics() == nil)
        #expect(s.monitors.shown == .first)
        s.show(WorkspaceName("c")!)
        #expect(s.monitors.shown == WorkspaceName("c")!)
        #expect(s.layout.isEmpty)
    }
}
