import Foundation

// What a guide is drawn from, with no `State` in it.
//
// The shell builds one from the truth plane and the settings window builds one from a mock desktop, and
// both then run the same layout — which is the whole of why this type exists. `GuideModel.layout` used
// to take a `State`, and `ImportFenceTests` forbids the settings module from naming one, so the preview
// could not have shared the real arithmetic even if it had wanted to.
//
// Everything here is **screen points on one display**, live: the frames are the animated values the
// compositor is drawing this frame, so the guide moves with the desktop rather than a frame behind it.

/// One display's strip, where its windows are right now, and where focus is inside it.
public struct GuideInput: Equatable, Sendable {

    /// One window the guide can draw: the layer pool's key, and the app that stands in for it — an icon
    /// in the preview guide, a name in the names guide.
    public struct Window: Equatable, Sendable {
        public let id: WindowId
        public let bundleId: String

        public init(id: WindowId, bundleId: String) {
            self.id = id
            self.bundleId = bundleId
        }
    }

    /// One column of the shown strip: its identity, and its stack top to bottom.
    public struct Column: Equatable, Sendable {
        public let id: ColumnId
        public let windows: [Window]

        public init(id: ColumnId, windows: [Window]) {
            self.id = id
            self.windows = windows
        }
    }

    /// The display's working area. **Both the ground the panel is anchored inside and the viewport
    /// indicator's own rect** — the strip is laid out in screen space with the scroll already applied,
    /// so the screen you are on is this rect whatever the strip is doing.
    public let workingArea: Rect
    /// The shown strip, in strip order. What divides, what a names cell stands for, and what the
    /// panel's extent is measured from.
    public let columns: [Column]
    /// Windows with a frame that the shown strip does not place — a neighbouring workspace sliding
    /// vertically through the panel during a switch. They draw a tile and divide nothing.
    public let passing: [Window]
    /// Every window's rectangle, screen space and live.
    public let frames: [WindowId: Rect]
    /// The focused window, or `nil` when this display does not hold focus.
    public let focus: WindowId?
    /// The focus ring's in-flight travel, in `Motion`'s own shape: a displacement added to the focused
    /// window's frame, decaying to zero as the ring arrives.
    public let focusDisplacement: Rect

    public init(workingArea: Rect, columns: [Column], passing: [Window] = [],
                frames: [WindowId: Rect], focus: WindowId? = nil,
                focusDisplacement: Rect = .zero) {
        self.workingArea = workingArea
        self.columns = columns
        self.passing = passing
        self.frames = frames
        self.focus = focus
        self.focusDisplacement = focusDisplacement
    }

    /// The shown strip's extent in screen space — the bounding box of what is on it, and empty for a
    /// strip with no windows. What the panel sizes itself against.
    public var strip: Rect {
        columns.lazy.flatMap(\.windows)
            .compactMap { frames[$0.id] }
            .reduce(Rect.zero) { $0.union($1) }
    }
}
