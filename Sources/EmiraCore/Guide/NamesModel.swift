import Foundation

// The names guide: one cell per column on the shown strip, in strip order, inside a bounding rounded
// rect. Each cell is the app name of the column's **largest** window, and a column holding more than one
// window carries a superscript count — `ghostty²` is ghostty and one other. The focused column's cell
// sits on a filled rounded rect, which is the whole of *where am I*.
//
// **Every length is derived from `font-size`**, so one number sizes the guide: the padding, the row's
// height and the ribbon's own inset are all fractions of the type size, and a user who wants a bigger
// guide asks for bigger type.
//
// **The cells tile the row, so the gutter between two words is shared.** A cell is its word plus half a
// gutter on each side and neighbours abut, which is what puts the focus fill's edge exactly halfway
// between the two words it comes between. A gap *on top of* each cell's padding is the other way to
// space a row, and it spends three quantities on the one distance: the fill then stops short of a strip
// of ribbon belonging to neither neighbour, and crossing the row the focus reads as jumping over gaps
// rather than moving from one word to the next.
//
// **A word's width is measured, not counted.** `GuideFace` is the one question a pure model cannot
// answer for itself, asked of whoever holds the font — which is both hosts, so the packing stays here
// and stays one expression. Counting characters is the same arithmetic only for a face whose every
// glyph advances the same, and the names on a real desktop are localized: `カレンダー` sets half
// again as wide as five Latin letters, and an emoji or a combining mark is not a character at all.
//
// **The row is bounded by `width`**, a fraction of the working area like the minimap's own. Past it the
// cells share what there is — each takes what it asks for while there is enough to go round, and what
// is left is split evenly between those that asked for more — so a long strip crowds every word equally
// rather than pushing its leading columns off the display. Below the point where a cell has stopped
// being a word, `max-columns`' own elision takes over.
//
// **No viewport indicator.** The focus fill answers *where am I* on its own, and a viewport rect over a
// text row would be measuring something the row does not represent.

/// How wide a word is and how tall a line of them: the two questions a pure model cannot answer, asked
/// of whoever holds the font. `EmiraGuide` has the one implementation, and a test's is a stub.
public struct GuideFace: Sendable {
    /// `text` set at `size`, in points. **Rounded up** by the implementation, since a cell a fraction
    /// short of the word in it truncates that word.
    public let width: @Sendable (_ text: String, _ size: Double) -> Double
    /// The line box `size` sets on, in points.
    public let lineHeight: @Sendable (_ size: Double) -> Double

    public init(width: @escaping @Sendable (_ text: String, _ size: Double) -> Double,
                lineHeight: @escaping @Sendable (_ size: Double) -> Double) {
        self.width = width
        self.lineHeight = lineHeight
    }
}

/// One frame of the names guide: the cells, where they go, and how much of the strip is off the ends.
public struct NamesModel: Equatable, Sendable {

    /// One column, as a word.
    public struct Cell: Equatable, Sendable {
        /// The word — already lowercased if the setting asks. Truncated by the renderer where
        /// `labelRect` is narrower than the word, which is why the count is not part of it.
        public let label: String
        /// The superscript count, or empty below two. Its own run, so a crowded row loses letters off
        /// the end of a name rather than losing the mark that says the column holds more than one.
        public let count: String
        /// Windows in the column. `0` marks the elision cell, which stands for columns rather than
        /// being one.
        public let depth: Int
        public let isFocused: Bool
        /// The cell's rectangle, panel-local, in guide points — the whole of it, which is what the
        /// focus fill is drawn at.
        public let rect: Rect
        /// Where the word is set inside `rect`, and where the count is set after it. Both are one line
        /// box tall, so a renderer places them and measures nothing.
        public let labelRect: Rect
        public let countRect: Rect
    }

    /// Every cell the guide draws, left to right — the elision cells included, so the renderer has one
    /// kind of thing to place.
    public let cells: [Cell]
    /// Columns dropped off each end, by `max-columns` or by the row running out of width.
    public let elidedLeading: Int
    public let elidedTrailing: Int
    /// The panel, in core (top-left, global) screen coordinates.
    public let panel: Rect
    /// The type the cells were packed for. Carried rather than looked up again, so the face a renderer
    /// sets the row in cannot be a different size from the one the row was measured at.
    public let metrics: Metrics

    /// The names guide over `input`, or `nil` when its numbers are degenerate or there is no strip to
    /// name. `face` measures a word and `name` resolves an app to one — both the caller's, because only
    /// a host holds a font, and both asked here so the panel is answered before anything is drawn.
    public static func model(_ input: GuideInput, settings: NamesGuideSettings, face: GuideFace,
                             name: (String) -> String) -> NamesModel? {
        let size = settings.fontSize
        guard size > 0, !input.workingArea.isEmpty else { return nil }
        let columns = input.columns.filter { column in
            column.windows.contains { input.frames[$0.id] != nil }
        }
        guard !columns.isEmpty else { return nil }

        let metrics = Metrics(fontSize: size, lineHeight: face.lineHeight(size))
        // The row's ceiling: a fraction of the working area, and never past the gap it is held off the
        // edge by. What the cells divide is that less the ribbon's own inset.
        let free = input.workingArea.inset(by: EdgeInsets(uniform: settings.gap))
        let room = min(min(settings.width, 1) * input.workingArea.width, free.width)
            - metrics.padding * 2
        guard room > 0 else { return nil }

        // What the user asked to see, at the width the words want. The floor is a **crowding** rule and
        // nothing else, so a row that fits is never cut for it — only one being squeezed past reading.
        var cut = elided(columns, focus: input.focus, limit: settings.maxColumns)
        var words = labels(of: cut, input: input, settings: settings, name: name)
        var wanted = words.map { metrics.cellWidth(of: $0, face: face) }
        if wanted.reduce(0, +) > room {
            cut = fitting(columns, focus: input.focus, limit: settings.maxColumns,
                          capacity: Int(room / metrics.minimumCell))
            words = labels(of: cut, input: input, settings: settings, name: name)
            wanted = words.map { metrics.cellWidth(of: $0, face: face) }
        }
        let (leading, trailing) = (cut.leading, cut.trailing)
        let granted = share(wanted, within: room)

        let row = granted.reduce(0, +)
        let panel = GuideModel.place(size: Size(width: row + metrics.padding * 2,
                                                height: metrics.cellHeight + metrics.padding * 2),
                                     within: input.workingArea, position: settings.position,
                                     gap: settings.gap)

        var x = metrics.padding
        var cells: [Cell] = []
        for (word, width) in zip(words, granted) {
            cells.append(word.cell(in: Rect(x: x, y: metrics.padding,
                                            width: width, height: metrics.cellHeight),
                                   metrics: metrics, face: face))
            x += width
        }
        return NamesModel(cells: cells, elidedLeading: leading, elidedTrailing: trailing,
                          panel: panel, metrics: metrics)
    }

    /// What stands in for the columns that did not fit.
    public static let ellipsis = "…"

    // What a cell says

    /// One cell's words before they have a rectangle: what is set, and what the cell stands for.
    struct Word {
        let label: String
        let count: String
        let depth: Int
        let isFocused: Bool
    }

    /// The row's words, the elision marks at either end included — a mark reads as a cell at whichever
    /// end lost columns, so what is off the guide is stated rather than silently absent.
    static func labels(of cut: (shown: [GuideInput.Column], leading: Int, trailing: Int),
                       input: GuideInput, settings: NamesGuideSettings,
                       name: (String) -> String) -> [Word] {
        var words = cut.shown.map { column -> Word in
            let word = name(largest(of: column, in: input.frames))
            let depth = column.windows.count
            return Word(label: settings.lowercase ? word.lowercased() : word,
                        count: superscript(depth), depth: depth,
                        isFocused: input.focus.map { focus in
                            column.windows.contains { $0.id == focus }
                        } ?? false)
        }
        let mark = Word(label: ellipsis, count: "", depth: 0, isFocused: false)
        if cut.trailing > 0 { words.append(mark) }
        if cut.leading > 0 { words.insert(mark, at: 0) }
        return words
    }

    /// The columns that fit: at most `limit` of them, and at most `capacity` cells once the elision
    /// marks are counted. Settles in at most three turns, since a cut adds at most two marks.
    static func fitting(_ columns: [GuideInput.Column], focus: WindowId?, limit: Int,
                        capacity: Int) -> (shown: [GuideInput.Column], leading: Int, trailing: Int) {
        let wanted = limit > 0 ? min(limit, columns.count) : columns.count
        var count = min(wanted, max(capacity, 1))
        while count > 1 {
            let cut = elided(columns, focus: focus, limit: count)
            let marks = (cut.leading > 0 ? 1 : 0) + (cut.trailing > 0 ? 1 : 0)
            if count + marks <= capacity { return cut }
            count -= 1
        }
        return elided(columns, focus: focus, limit: 1)
    }

    /// The `limit` columns nearest focus, and how many that left off each end. **The window follows
    /// focus**, so what goes is the end away from it — the preview guide's shown-window rule, counted
    /// in columns. `0` is the whole strip.
    static func elided(_ columns: [GuideInput.Column], focus: WindowId?,
                       limit: Int) -> (shown: [GuideInput.Column], leading: Int, trailing: Int) {
        guard limit > 0, columns.count > limit else { return (columns, 0, 0) }
        let focused = focus.flatMap { id in
            columns.firstIndex { $0.windows.contains { $0.id == id } }
        } ?? 0
        let start = min(max(focused - limit / 2, 0), columns.count - limit)
        return (Array(columns[start..<(start + limit)]), start, columns.count - limit - start)
    }

    /// The app the column is named after: its **largest** window, by area. A column stacked three deep
    /// has one name, and the window that earns it is the one taking most of the column — arithmetic over
    /// the frames, which is why it lives here rather than in the renderer.
    static func largest(of column: GuideInput.Column, in frames: [WindowId: Rect]) -> String {
        let placed = column.windows.compactMap { window in
            frames[window.id].map { (window, $0.area) }
        }
        return placed.max { $0.1 < $1.1 }?.0.bundleId ?? column.windows.first?.bundleId ?? ""
    }

    // What each cell gets of the row

    /// `wanted` widths cut to fit `room`: each takes what it asked for while there is enough to go
    /// round, and what is left splits evenly between those that asked for more. **Max-min fair in one
    /// pass** — narrowest first, the first cell over its share settles every cell after it.
    static func share(_ wanted: [Double], within room: Double) -> [Double] {
        guard wanted.reduce(0, +) > room else { return wanted }
        var granted = wanted
        var left = room
        let narrowest = wanted.indices.sorted { wanted[$0] < wanted[$1] }
        for (rank, index) in narrowest.enumerated() {
            let equal = left / Double(narrowest.count - rank)
            guard wanted[index] > equal else {
                granted[index] = wanted[index]
                left -= wanted[index]
                continue
            }
            for crowded in narrowest[rank...] { granted[crowded] = equal }
            break
        }
        return granted
    }

    /// The type the row is set in, and every length derived from its size.
    ///
    /// One number sizes the guide: at `font-size = 12` a cell is 7.2 pt of padding either side of the
    /// text and 3.6 pt above and below it, so two words stand 14.4 pt apart, with 6 pt of ribbon around
    /// the row.
    public struct Metrics: Equatable, Sendable {
        public let fontSize: Double
        /// The line box the face sets this size on — measured, since it is a property of the type
        /// rather than of the setting.
        public let lineHeight: Double

        public init(fontSize: Double, lineHeight: Double) {
            self.fontSize = fontSize
            self.lineHeight = lineHeight
        }

        /// **Half the gutter**, since the cell on the other side of it carries the other half. The two
        /// words a gutter separates therefore stand `hPad * 2` apart, and the cells between them abut.
        public var hPad: Double { 0.6 * fontSize }
        public var vPad: Double { 0.3 * fontSize }
        /// The ribbon's own inset around the row. With the end cell's own half-gutter it comes to 1.1
        /// times the type size against the interior's 1.2, so the row reads as evenly spaced right
        /// through to its ends — and the focus fill never sits flush against the ribbon's edge.
        public var padding: Double { 0.5 * fontSize }

        public var cellHeight: Double { lineHeight + vPad * 2 }

        /// Where a word stops being one. Under about six characters a name is not recognisable and the
        /// row has stopped naming anything — at which point dropping a column says more than crowding
        /// every one of them past reading, and the count at the end says how many went.
        public var minimumText: Double { 4 * fontSize }
        public var minimumCell: Double { minimumText + hPad * 2 }

        /// A cell wide enough for a word and its count, padded.
        func cellWidth(of word: Word, face: GuideFace) -> Double {
            face.width(word.label, fontSize) + face.width(word.count, fontSize) + hPad * 2
        }
    }

    /// A count as superscript digits, or nothing at all below two — a column of one is the ordinary
    /// case, and a `¹` on every cell would be noise on every cell.
    public static func superscript(_ depth: Int) -> String {
        guard depth > 1 else { return "" }
        let digits = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")
        return String(depth).compactMap { $0.wholeNumberValue.map { digits[$0] } }
            .map(String.init).joined()
    }
}

extension NamesModel.Word {
    /// This word in `rect`: the two runs side by side, centred in what the gutters leave while both fit
    /// and hard against the ends once they do not. **The count keeps its width whatever happens**, so a
    /// crowded cell gives up letters of the name and still says how deep the column is.
    func cell(in rect: Rect, metrics: NamesModel.Metrics, face: GuideFace) -> NamesModel.Cell {
        let box = Rect(x: rect.minX + metrics.hPad, y: rect.minY + metrics.vPad,
                       width: max(rect.width - metrics.hPad * 2, 0), height: metrics.lineHeight)
        let counted = min(face.width(count, metrics.fontSize), box.width)
        let asked = face.width(label, metrics.fontSize)
        let written = min(asked, box.width - counted)
        // Centred as one run while both fit; hard against the ends once they do not, which is where the
        // name gives up letters and the count does not.
        let x = box.minX + max(box.width - (written + counted), 0) / 2
        return NamesModel.Cell(
            label: label, count: count, depth: depth, isFocused: isFocused, rect: rect,
            labelRect: Rect(x: x, y: box.minY, width: max(written, 0), height: box.height),
            countRect: Rect(x: x + max(written, 0), y: box.minY, width: counted, height: box.height))
    }
}
