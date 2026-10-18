import Foundation

// Peeks: a column the viewport shows that its own display cannot draw.
//
// **macOS draws a window on the display holding the largest share of it, and nowhere else**
// (`Neighbourhood`). A column hanging off an edge is drawn on its own screen, cut at the edge, until most
// of it is past that edge — and if another display sits there, past that point it is drawn whole on the
// neighbour, over that screen's own windows, while its own screen shows a hole where it should be. Nothing
// emira may call clips a foreign window, so the column cannot be put there truthfully at all.
//
// So the placement pass parks it (`Layout.peekingFrames`), and the presentation plane draws the part of it
// this display shows out of its own pixels: the hoist's answer to a different question, a window of ours
// standing in for one we may not place. A peek is a slice of a column the user is not working in, which is
// what makes a picture the right trade here: it takes clicks, and a click is a focus, which reveals the
// column and puts the real window back. What it cannot do is change while it stands, so a peek's content
// is the window as it was last filmed.

/// One peeking column's stand-in: which window, which display shows it, and the frame the window would
/// stand at — most of it past that display's edge, where nothing of it is drawn. Array order is the
/// window id's, since peeks never overlap one another.
public struct PeekBinding: Sendable, Equatable, Codable {
    public let window: WindowId
    /// The display whose viewport shows the column — the one the picture is drawn on and clipped to.
    public let monitor: MonitorId
    /// The window's whole tiled frame, whole points, as the placement pass would have written it.
    public let frame: Rect

    public init(window: WindowId, monitor: MonitorId, frame: Rect) {
        self.window = window
        self.monitor = monitor
        self.frame = frame
    }
}

extension State {

    /// The placement pass's peeks (`World.peeks`), plus one it dropped whose window's write onto the glass
    /// is still out: the picture is behind every window, so the one landing hides it, and taken down first
    /// it leaves a hole for the length of the write. A column scrolled away has nothing landing over it.
    public func peekBindings() -> [PeekBinding] {
        var shown = world.peeks
        for held in peeks where shown[held.window] == nil
            && world.placedOnScreen.contains(held.window) && world.inFlight[held.window] != nil {
            shown[held.window] = held
        }
        return shown.values.sorted { $0.window < $1.window }
    }
}
