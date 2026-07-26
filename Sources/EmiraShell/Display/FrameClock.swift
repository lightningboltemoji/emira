import Foundation
import EmiraCore

// The frame clock — the shell subsystem that turns display refreshes into `Event.tick(dt)`, the one
// event that advances the core's animators (`PRINCIPLES.md` §7: *the core owns the clock; the shell
// is a dumb blitter*).
//
// This file holds only the **protocol**, for two reasons. First, the `Runtime` must be able to gate
// the clock (start it when a transition opens, stop it when the cover comes down — idle produces no
// ticks, IMPLEMENTATION.md §6) without importing AppKit, which keeps the pump and its tests
// framework-free and headless. Second, the real implementation
// (`Display/DisplayLinkDriver.swift`, `NSScreen.displayLink`) needs a live `NSScreen` and a running
// app, so it is the *only* piece of this path that can't be unit-tested — isolating it behind two
// methods keeps that untestable surface as small as it can possibly be.

/// A source of `Event.tick(dt)` at display refresh rate. Implemented for real by
/// `DisplayLinkDriver` (`CADisplayLink` via `NSScreen.displayLink`) and by test doubles that step
/// time by hand.
///
/// **Contract for implementers:**
///
///  · `start` is only called while stopped and `stop` only while started — the `Runtime` tracks the
///    state and never double-calls — but both should still be idempotent (totality, §1 invariant 3).
///  · `dt` is the interval **since the previous delivered tick**, in seconds. On `start`, reset the
///    baseline: the first tick after an idle period must not carry the seconds that elapsed while the
///    clock was stopped, or one frame would teleport every spring to its target.
///  · Deliver ticks through the `sink` and nothing else — the pump is the only writer of core state.
@MainActor
public protocol FrameClock: AnyObject {
    /// Begin delivering ticks to `sink`. Called when a transition session opens.
    func start(sink: EventSink)

    /// Stop delivering ticks. Called when the session closes; the display link should be paused, not
    /// torn down, so the next transition starts without re-acquiring it.
    func stop()
}
