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

    @Test func aFreshSetHasExactlyTheFocusedWorkspace() {
        let ws = Workspaces()
        #expect(ws.focused == .first)
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
    @Test func focusingMaterializesAndNothingEverUnmaterializes() {
        var ws = Workspaces()
        ws.focus(b)
        #expect(ws.focused == b)
        #expect(ws.materialized == [a, b])
        ws.reconcile(stripWindowIds: [w1])     // give `b` a window
        ws.focus(a)
        ws.reconcile(stripWindowIds: [])       // and take it away again
        #expect(ws[b].isEmpty)
        #expect(ws.materialized == [a, b])     // emptied, still there
    }

    /// Name order, which is *key* order — `"0"` comes back after `"9"` and before the letters, not
    /// first, which sorting the spellings would do silently.
    @Test func materializedNamesComeBackInNameOrderNotDictionaryOrder() {
        var ws = Workspaces()
        let zero = WorkspaceName("0")!, g = WorkspaceName("g")!
        for name in [c, b, g, zero] { ws.focus(name) }
        #expect(ws.materialized == [a, b, zero, g, c])
        #expect(ws.materialized.map(\.description) == ["1", "3", "0", "g", "z"])
    }

    /// Placement order is focused-first, then the rest by name — one rule, used by `allWindowIds` and
    /// by the park-ordinal run, so the effect order and the nub order cannot disagree.
    @Test func placementOrderPutsTheFocusedWorkspaceFirst() {
        var ws = Workspaces()
        ws.focus(b)
        ws.focus(c)
        #expect(ws.materialized == [a, b, c])
        #expect(ws.placementOrder == [c, a, b])
    }

    // reconcile — the World→Workspaces bridge

    /// The single-workspace case is byte-for-byte the bare `Layout.reconcile`.
    @Test func withOneWorkspaceReconcileIsExactlyTheSingleStripCall() {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1, w2, w3])

        var bare = Layout()
        var ids = ColumnAllocator()
        bare.reconcile(stripWindowIds: [w1, w2, w3], columnIds: &ids)

        #expect(ws.focusedStrip == bare)
        #expect(ws.allWindowIds == bare.allWindowIds)
        #expect(ws.targetFrames(scrollOffset: 0, metrics: metrics)
                == bare.targetFrames(scrollOffset: 0, metrics: metrics))
    }

    /// The dangerous one: projected onto the focused strip, the first workspace switch would see every
    /// window on every other workspace as a newcomer and drag the lot onto the focused one.
    @Test func newcomersJoinTheFocusedStripAndOtherWorkspacesAreNotMigrated() {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1, w2])       // both land on `0`
        ws.focus(b)
        ws.reconcile(stripWindowIds: [w1, w2, w3])   // w3 is the only newcomer

        #expect(ws[a].allWindowIds == [w1, w2])      // untouched, still on `0`
        #expect(ws[b].allWindowIds == [w3])          // the newcomer, alone on the focused strip
        #expect(ws.workspace(of: w1) == a)
        #expect(ws.workspace(of: w3) == b)
    }

    /// Departures leave every strip, not just the one being looked at.
    @Test func departuresAreDroppedFromEveryWorkspace() {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1, w2])
        ws.focus(b)
        ws.reconcile(stripWindowIds: [w1, w2, w3])

        ws.reconcile(stripWindowIds: [w2, w3])       // w1 closed, and it was on the *unfocused* `0`
        #expect(ws[a].allWindowIds == [w2])
        #expect(ws[b].allWindowIds == [w3])
        #expect(ws.workspace(of: w1) == nil)
    }

    @Test func aRepeatedReconcileWithTheSameSetChangesNothing() {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1, w2])
        ws.focus(b)
        ws.reconcile(stripWindowIds: [w1, w2, w3])
        let settled = ws
        ws.reconcile(stripWindowIds: [w1, w2, w3])
        #expect(ws == settled)                       // no churn, and no id minted (allocator compared)
    }

    @Test func aNewcomerOpensBesideTheAnchorOnTheFocusedStrip() {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1, w2])
        ws.reconcile(stripWindowIds: [w1, w2, w3], insertingAfter: w1)
        #expect(ws.focusedStrip.allWindowIds == [w1, w3, w2])
    }

    /// Column #1 on one workspace and column #1 on another must not be the same id: `Motion.columnWidths`
    /// is keyed by a bare `ColumnId`, so a collision would let an in-flight resize on one workspace
    /// re-aim a column on another. One allocator for the whole set makes that unrepresentable.
    @Test func columnIdsAreDisjointAcrossWorkspaces() {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1, w2])
        ws.focus(b)
        ws.reconcile(stripWindowIds: [w1, w2, w3, w4])

        let all = ws.materialized.flatMap { ws[$0].columns.map(\.id) }
        #expect(all.count == 4)
        #expect(Set(all).count == all.count)         // …and every one of them distinct
    }

    /// The same property through the *other* minting mutator, and across a strip that has already had
    /// a column destroyed — the rewind the allocator's watermark exists to prevent.
    @Test func extractMintsIntoTheSameIdSpaceAndNeverReusesADestroyedId() {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1, w2])
        var strip = ws.focusedStrip
        strip.move(window: w2, toColumn: strip.columns[0].id, at: 1)   // one column of two windows
        ws.focusedStrip = strip
        let seen = Set(ws.focusedStrip.columns.map(\.id))

        ws.extract(window: w2, toNewColumnAt: 1)                       // mints
        let extracted = Set(ws.focusedStrip.columns.map(\.id)).subtracting(seen)
        #expect(extracted.count == 1)

        ws.focus(b)
        ws.reconcile(stripWindowIds: [w1, w2, w3])                     // mints again, on another strip
        let everything = ws.materialized.flatMap { ws[$0].columns.map(\.id) }
        #expect(Set(everything).count == everything.count)
    }

    @Test func extractIsATotalNoOpForAWindowOnNoWorkspace() {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1])
        let before = ws
        #expect(ws.extract(window: WindowId(999), toNewColumnAt: 0) == .none)
        #expect(ws == before)                        // not even an id consumed
    }

    // Park slots across the whole set

    /// Every window on every unfocused workspace is parked, so the ordinals have to be one run across the
    /// set. Two windows sharing a park frame breaks the ±2 pt first-sight identity join *and* the
    /// no-overlap invariant — both silently, one permanently.
    @Test func parkSlotsAreUniqueAcrossEveryWorkspaceWithinTheBindingTolerance() {
        var ws = Workspaces()
        // Four columns on `0` (the last is off-viewport at a 900 pt viewport), then four more each on
        // two other workspaces — every one of the latter parked.
        ws.reconcile(stripWindowIds: [w1, w2, w3, w4])
        ws.focus(b)
        ws.reconcile(stripWindowIds: [w1, w2, w3, w4] + (10..<14).map(WindowId.init))
        ws.focus(c)
        ws.reconcile(stripWindowIds: [w1, w2, w3, w4] + (10..<14).map(WindowId.init)
                     + (20..<24).map(WindowId.init))
        ws.focus(a)

        let frames = ws.targetFrames(scrollOffset: 0, metrics: metrics)
        #expect(frames.count == 12)

        // Parked windows only: the tiled ones legitimately sit side by side.
        let visible = Set(ws.focusedStrip.visibleWindowIds(scrollOffset: 0, metrics: metrics))
        let parked = ws.allWindowIds.filter { !visible.contains($0) }.compactMap { frames[$0] }
        #expect(parked.count == 9)                   // 12 total − 3 tiled columns on `0`
        for i in parked.indices {
            for j in (i + 1)..<parked.count {
                let (x, y) = (parked[i], parked[j])
                let ambiguous = abs(x.minX - y.minX) <= 2 && abs(x.minY - y.minY) <= 2
                    && abs(x.width - y.width) <= 2 && abs(x.height - y.height) <= 2
                #expect(!ambiguous, "park slots \(i) and \(j) are indistinguishable at rebind")
            }
        }
    }

    /// A parked window keeps the size it *would* have if its workspace were focused — parking
    /// repositions and never resizes, so switching changes a window's address and not its shape.
    @Test func aParkedWorkspaceKeepsItsOwnGeometryForSizes() {
        var ws = Workspaces()
        ws.focus(b)
        ws.reconcile(stripWindowIds: [w1, w2])
        ws.focus(a)                                  // `3` is now entirely parked

        let parked = ws.targetFrames(scrollOffset: 0, metrics: metrics)
        // ⅓ of 900 wide, full content height — exactly what it would be tiled.
        #expect(parked[w1]?.size == Size(width: 300, height: 600))
        #expect(parked[w2]?.size == Size(width: 300, height: 600))
    }

    /// The focused workspace owns the low ordinals, so its nubs do not renumber as other addresses
    /// fill up — that is what `placementOrder` being focused-first buys.
    @Test func theFocusedWorkspacesParksKeepTheirOrdinalsAsOthersFillUp() {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1, w2, w3, w4])   // w4's column is off-viewport → parked
        let alone = ws.targetFrames(scrollOffset: 0, metrics: metrics)[w4]

        ws.focus(b)
        ws.reconcile(stripWindowIds: [w1, w2, w3, w4, WindowId(10), WindowId(11)])
        ws.focus(a)
        #expect(ws.targetFrames(scrollOffset: 0, metrics: metrics)[w4] == alone)
    }

    @Test func theContainerRoundTripsThroughCodable() throws {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1, w2])
        ws.focus(b)
        ws.reconcile(stripWindowIds: [w1, w2, w3])

        let data = try JSONEncoder().encode(ws)
        let back = try JSONDecoder().decode(Workspaces.self, from: data)
        #expect(back == ws)
        #expect(back.focused == b)
        #expect(back[a].allWindowIds == [w1, w2])
    }

    /// The allocator watermark is serialized state, and the only way to observe it is to mint. Mutate
    /// first so it has advanced past `max(id)`, then check the original and the decoded copy hand out the
    /// *same* next id — a round-trip that dropped it would silently re-issue one.
    @Test func aRoundTrippedSetMintsTheSameNextColumnId() throws {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1, w2, w3])       // mints 1, 2, 3
        var back = try JSONDecoder().decode(Workspaces.self, from: try JSONEncoder().encode(ws))
        #expect(back == ws)

        let churn = [w1, w2, w3, w4]
        ws.reconcile(stripWindowIds: churn)
        back.reconcile(stripWindowIds: churn)
        #expect(back.focusedStrip.columns.last?.id == ws.focusedStrip.columns.last?.id)
        #expect(back.focusedStrip.columns.last?.id == ColumnId(4))
    }

    /// The dump is something a human reads (`emira debug`), so the shape is pinned, not just the
    /// round-trip: strips keyed by their character, `focused` as a character, the watermark bare.
    @Test func theEncodedShapeIsLegible() throws {
        var ws = Workspaces()
        ws.reconcile(stripWindowIds: [w1])
        ws[scrollOffsetOf: a] = 1200
        ws[lastFocusOf: a] = w1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(ws), as: UTF8.self)
        #expect(json.contains(#""focused":"1""#), "\(json)")
        #expect(json.contains(#""strips":{"1":"#), "\(json)")
        #expect(json.contains(#""columnIds":2"#), "\(json)")       // one column minted ⇒ next is 2
        // The memory rides in each strip's record, in the same dump — a switch that comes back to the
        // wrong place is diagnosable from `emira debug` alone.
        #expect(json.contains(#""scrollOffset":1200"#), "\(json)")
        #expect(json.contains(#""lastFocus":1"#), "\(json)")
    }
}

/// `State.layout` as a projection of `State.workspaces` — single storage, not a second authority.
@Suite struct StateProjectionTests {

    private let w1 = WindowId(1), w2 = WindowId(2)

    @Test func readingLayoutIsReadingTheFocusedStrip() {
        var s = State()
        s.workspaces.reconcile(stripWindowIds: [w1, w2])
        #expect(s.layout == s.workspaces.focusedStrip)
        #expect(s.layout.allWindowIds == [w1, w2])
    }

    /// Writing through the projection writes the focused strip and nothing else — what makes every
    /// `s.layout.moveColumn(…)`-style mutation keep working.
    @Test func writingLayoutWritesTheFocusedStripAndOnlyThat() {
        var s = State()
        s.workspaces.reconcile(stripWindowIds: [w1, w2])
        s.workspaces.focus(WorkspaceName("3")!)
        s.workspaces.reconcile(stripWindowIds: [w1, w2])   // both still on the launch workspace

        s.layout = Layout(columns: [ColumnLayout(id: ColumnId(99), windowIds: [WindowId(9)])])
        #expect(s.workspaces[WorkspaceName("3")!].columns.map(\.id) == [ColumnId(99)])
        #expect(s.workspaces[.first].allWindowIds == [w1, w2])   // untouched
    }

    /// The single-strip `State` initializer means what it always meant: this layout, on the focused
    /// workspace, with nothing else materialized.
    @Test func theSingleStripInitializerSeedsTheFocusedWorkspace() {
        let layout = Layout(columns: [ColumnLayout(id: ColumnId(7), windowIds: [w1])])
        let s = State(world: World(), layout: layout, motion: Motion(), config: Config())
        #expect(s.workspaces.focused == .first)
        #expect(s.workspaces.materialized == [.first])
        #expect(s.layout == layout)
    }

    /// …and it seeds the allocator past the ids it was handed, so the next mint cannot collide.
    @Test func theSingleStripInitializerResumesTheAllocatorPastTheSuppliedIds() {
        let layout = Layout(columns: [ColumnLayout(id: ColumnId(7), windowIds: [w1])])
        var s = State(world: World(), layout: layout, motion: Motion(), config: Config())
        s.workspaces.reconcile(stripWindowIds: [w1, w2])
        #expect(s.layout.columns.map(\.id) == [ColumnId(7), ColumnId(8)])
    }

    @Test func stateRoundTripsWithItsWorkspaceSet() throws {
        var s = State()
        s.workspaces.reconcile(stripWindowIds: [w1, w2])
        s.workspaces.focus(WorkspaceName("a")!)
        let back = try JSONDecoder().decode(State.self, from: try JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.workspaces.focused == WorkspaceName("a")!)
    }
}
