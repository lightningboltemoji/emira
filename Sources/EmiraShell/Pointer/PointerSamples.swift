import EmiraCore
import Foundation

/// The pointer plane's read direction, in the order it has to run.
///
/// `PointerFocus` and `PointerWake` are otherwise independent, and `WorldWatcher` hands them the same
/// samples. What is *not* independent is which goes first, so it lives here rather than in a wiring
/// line: three lines that hold one rule beside the two types it constrains.
@MainActor
public final class PointerSamples {

    private let focus: PointerFocus
    private let wake: PointerWake

    public init(focus: PointerFocus, wake: PointerWake) {
        self.focus = focus
        self.wake = wake
    }

    /// Fold one raw sample. **Focus before wake:** a hidden pointer may be sitting over a window nobody
    /// chose, so the motion that ends a hide must only *wake* — and what tells `PointerFocus` that this
    /// is that sample is `State.pointer.isCursorHidden`, which the wake is about to clear.
    public func pointerMoved(to point: Point) {
        focus.pointerMoved(to: point)
        wake.pointerMoved(to: point)
    }

    /// Fold a move the user did not make — `Effect.warpPointer`, which posts no event, so no sample will
    /// ever report it and both readers now hold a record of a place the cursor has left. No order to
    /// keep here; it sits beside `pointerMoved` because "the cursor moved" has exactly two sources.
    public func pointerWarped(to point: Point) {
        focus.pointerWarped(to: point)
        wake.reanchor()
    }
}
