import Foundation

// The exhaustive *output* vocabulary — the only things the pure core can ask the shell to do
// (IMPLEMENTATION.md §1 diagram, §3). The reducer is `reduce(State, Event) -> (State, [Effect])`:
// it never touches AppKit / AX / Core Animation / ScreenCaptureKit itself — it emits `Effect`s,
// and `EmiraShell`'s Executor interprets them against the real system (with a `MockExecutor` that
// just records them for the scenario/replay tests, §8).
//
// Two properties earn their keep:
//
//  · **`Equatable`** — golden `ReplayTests` assert an exact Effect stream ("event log → asserted
//    final state / Effect stream", §8); scenario tests assert "a `setFrame` was emitted for both
//    windows". You can only assert against a value you can compare.
//  · **`Codable`** — so those golden Effect streams (and an `emira debug` dump) can be serialized
//    and diffed. Per §7 the core's vocabulary is **ids, never pixels**: `capture(win)` names a
//    window, and the *shell* owns the image cache keyed by that `WindowId`. Nothing here carries a
//    `CGImage`/`IOSurface`, which is exactly what keeps `EmiraCore` Foundation-only and the replay
//    logs small.
//
// Every effect the shell runs may feed a result back as an `Event` (`axLanded`, `axFailed`,
// `captureReady`, `crossfadeDone`) — §1 invariant 3. The two planes are visible in the case names:
// the **truth plane** (AX geometry) and the **presentation plane** (our own Core Animation layers).

/// A single instruction from the core to the shell. Grouped by the subsystem that executes it; see
/// the per-case docs for which plane it drives and whether it acks with a feedback `Event`.
public enum Effect: Sendable, Equatable, Codable {

    // MARK: Truth plane — Accessibility API (`AXUIElementSetAttributeValue`)
    //
    // Executed off the main thread on a serial per-app queue with a short messaging timeout
    // (PRINCIPLES.md §5). Each answers back with `Event.axLanded(win)` once the real window
    // arrives, or `Event.axFailed(win)` when the app refuses or times out — so a hung app is a normal
    // transition, not a stall.
    //
    // **Clarified 2026-07-25 (M3 part 2a):** an app that *accepts* the set and then puts the window
    // somewhere else — clamping to a minimum size, quantizing to character cells — is **not** a
    // failure. That is `Event.windowFrameChanged(win, actual)`, the same event a user's drag produces,
    // followed by a normal `axLanded`. The two facts are independent (was the write taken; where is the
    // window), and only the first is a verdict: collapsing them would report a terminal as failing on
    // every placement it ever gets.

    /// Teleport a real window to `rect` on the virtual strip (the shell Y-flips at its boundary).
    /// The everyday placement primitive: new window, close-retile, focus scroll, width cycle.
    case setFrame(WindowId, Rect)

    /// Park a window off-viewport at a deterministic sliver `slot` (PRINCIPLES.md §4a). Geometrically
    /// this is a `setFrame` to a computed slot, but it's a **distinct** effect because the shell
    /// treats it differently: capture *before* parking (occlusion can staleness a parked surface,
    /// §6), and the `axLanded` scoping (§3) skips a park→park move because it's never in view.
    case park(WindowId, Rect)

    // MARK: Presentation plane — Core Animation (our own overlay layers)
    //
    // Blitted on the main thread inside a `CATransaction` with actions disabled. There is no ack:
    // these are per-frame writes driven by `Event.tick(dt)` while a transition session is open, and
    // the core (which owns the clock) knows what it drew.

    /// Set a reconstruction layer's frame this frame — the core advanced its animators on the tick
    /// and is telling the shell where the stand-in now sits. Keyed by `LayerId` (presentation
    /// plane), not `WindowId`: a window may back several layers (its surface, a synthesized shadow,
    /// a scaled resize screenshot), and the wallpaper layer backs no window at all.
    case setLayerFrame(LayerId, Rect)

    // MARK: Capture — ScreenCaptureKit
    //
    /// Grab a still of `win`'s surface (SCK captures it even when occluded). Answered by
    /// `Event.captureReady(win)`; the still lands in the shell's `WindowId`-keyed image cache, never
    /// in the core. Gating a transition on `captureReady` for every included window is what makes the
    /// raised cover opaque before any real window teleports behind it (no exposure).
    case capture(WindowId)

    // MARK: Transition lifecycle — the layered reconstruction (Compositor)
    //
    // The clean policy/mechanism seam (§3): the core decides *whether* a command warrants a
    // transition and *when* it's done; the shell owns the cover/capture/cross-fade mechanics.

    /// Open a transition session: build the layered reconstruction and raise it (the §1-diagram
    /// "raiseCover"). Real windows may then teleport behind it with zero exposure. Carries the ordered
    /// `LayerBinding`s (`Motion.swift`) that compose the cover — one per scoped window, z-order
    /// bottom→top — telling the shell which `LayerId` to tag each window's layer with so subsequent
    /// `setLayerFrame`s can name it. The shell already knows each layer's initial frame from the
    /// window's capture, so only the id association travels here.
    case beginTransition([LayerBinding])

    /// Add layers to an **already-raised** cover, carrying the bindings for windows that entered the
    /// transition's scope after it opened (z-order: on top of what is already there).
    ///
    /// A cover that can only be built once is a cover that can only be right once. The session's scope
    /// is fixed at `beginTransition`, but an interrupting command *retargets* the scroll — and a new
    /// destination sweeps windows the original scope never named. Before this effect existed they slid
    /// into the viewport with no layer at all, and what showed through was the base: wallpaper, where a
    /// window should be (`PRINCIPLES.md` §10, 2026-07-25 — the finding of M4 part 1).
    ///
    /// Emitted on the `captureReady` that completes an extension's stills, *immediately followed by a
    /// `setLayerFrame` for every binding* — so a newcomer's layer is created and placed inside one
    /// frame rather than showing for a refresh at wherever its capture was taken.
    case extendCover([LayerBinding])

    /// Move one layer to the **top** of the cover's z-order, for the rest of the transition.
    ///
    /// Every other transition can ignore z-order, because strip windows never overlap — the cover's
    /// stacking is whatever `beginTransition`'s binding order produced and nothing ever crosses
    /// anything. A **structural edit** breaks that premise on purpose: two columns trading places
    /// pass straight through each other on the presentation plane, and at the midpoint one is
    /// entirely hidden by the other. Which one is on top is the difference between "the window I
    /// moved slid over there" and an unreadable smear, so the core has to have an opinion, and there
    /// is no way to derive it from the layout — it is a fact about the *command*, not the strip.
    ///
    /// Emitted at the raise (right after `beginTransition`), again after every `extendCover` — a
    /// newcomer's layer is appended on top, which would bury the mover — and on a second structural
    /// edit under an already-raised cover, which renames the elevated window. All three land inside
    /// one contiguous presentation run, i.e. one `CATransaction`. No ack.
    case elevateLayer(LayerId)

    /// Close the transition session: cross-fade the reconstruction back to the real desktop and drop
    /// the cover (the §1-diagram "crossFade"). Emitted once the animators settle **and** the scoped
    /// `axLanded`s arrive, or when `Event.holdTimeout` bounds the wait (§3). Acks with
    /// `Event.crossfadeDone`.
    case endTransition

    // MARK: Configuration — the filesystem

    /// Re-read the config file from disk. Answered by `Event.configChanged(Config)` when it parses,
    /// and by a logged diagnostic when it doesn't — a failed reload leaves the running config exactly
    /// as it was.
    ///
    /// **Why this is an `Effect` and not a router special-case, which is what `dumpState` gets.** The
    /// two look alike — both are "commands the reducer has no state to change for" — and they part
    /// company on a single question: does the answer need a live reply channel? `dumpState` does (a
    /// socket to print the JSON down), and `Effect` is a `Codable` value by contract, so it is
    /// answered out of band by the shell (`Ipc/RequestRouter.swift`, 2026-07-24). A reload needs no
    /// channel at all — it names a file, and the outcome comes back as an event like every other
    /// effect's. Making it an effect is what lets it work from **every** surface: `emira
    /// reload-config` reaches the router, but a keybinding (M5 part 2) never does, and intercepting
    /// the command in two places would fork one verb into two implementations.
    case reloadConfig

    // MARK: Focus & stacking — AX + `NSRunningApplication`

    /// Give a real window keyboard focus (raise + make key via AX / app activation).
    case focus(WindowId)

    /// Raise a real window in the z-order without necessarily focusing it (stacking within a column).
    case raise(WindowId)
}
