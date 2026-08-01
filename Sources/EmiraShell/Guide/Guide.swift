import AppKit
import CoreGraphics
import EmiraCore

// The guide's controller: when it goes up, how long it stays, and what each tile is made of.
//
// Driven by `Runtime.onStateChanged`, which fires once per *drain* — after the effects are issued and
// the clock is synced — so it reads a settled state and never one the user did not see. During a
// transition, and while the focus ring travels, that is once per tick: a free frame clock, with no
// timer of the guide's own.
//
//     trigger  = { focused window, workspace, ordered column ids + their window ids, scroll target }
//     show     when the trigger changes
//     re-arm   when the trigger changes, or anything is still moving
//     blit     whenever visible
//     fade     `duration` after the last re-arm
//
// The trigger is a small diffed projection rather than the whole `State`, so an `axLanded` or a title
// change cannot summon a HUD — `MenuBarItem`'s rule about reporting a change in the value rather than
// in the thing carrying it.
//
// `DelayScheduler` has no cancellation, stated at the protocol. The dwell therefore uses the
// generation-token idiom `Overlay.fadeOut` already uses: each re-arm bumps a counter and the scheduled
// closure returns early unless it is still the current one. No new seam, at the price of one inert
// closure per frame of motion.

/// The guide: a transient minimap of the focused strip, above the cover and outliving it.
@MainActor
public final class Guide {

    /// How long the guide takes to fade once its dwell expires. Not configurable, and longer than a
    /// cover's exit for the opposite reason: nothing is hidden behind the guide, so the fade is the
    /// whole of the effect rather than a seam over a change.
    private static let fade: TimeInterval = 0.35

    private let panel: GuidePanel
    private let icons: GuideIcons
    private let scheduler: any DelayScheduler
    /// Where a `preview` tile's pixels come from — the stills a cover left behind. Returns `nil` for a
    /// window nothing has filmed, which falls back to the icon placeholder, per tile.
    private let still: @MainActor (WindowId) -> CGImage?

    private var trigger: GuideTrigger?
    /// Bumped by every re-arm; a scheduled dwell that is no longer current does nothing.
    private var dwell = 0

    public init(panel: GuidePanel, icons: GuideIcons, scheduler: any DelayScheduler,
                still: @escaping @MainActor (WindowId) -> CGImage? = { _ in nil }) {
        self.panel = panel
        self.icons = icons
        self.scheduler = scheduler
        self.still = still
    }

    /// Seed the trigger without showing anything — what the daemon calls once, before wiring
    /// `onStateChanged`, so the boot scan's own arrivals are the first thing the guide reacts to rather
    /// than the fact that it has just been built.
    public func prime(_ state: State) {
        trigger = GuideModel.trigger(for: state)
    }

    /// One drain's worth of state.
    public func stateChanged(_ state: State) {
        let style = state.config.guide.style
        guard style != .off else { return retire() }
        // No display known yet (boot, or a reload racing a display change): nothing to project onto,
        // and nothing to say about it either.
        guard let layout = GuideModel.layout(for: state) else { return }

        let next = GuideModel.trigger(for: state)
        let moved = next != trigger
        trigger = next
        if moved { panel.show() }
        guard panel.isShown else { return }

        panel.render(layout) { [icons, still] tile in
            if style == .preview, let image = still(tile.window) { return .preview(image) }
            if let icon = icons.icon(for: tile.bundleId) { return .placeholder(icon) }
            return .blank
        }

        // `needsFrames` is the core's own "something is still moving" — a transition open, or the focus
        // ring still travelling. So the dwell starts when everything stops, not when the key was pressed.
        if moved || state.motion.needsFrames { arm(after: state.config.guide.duration) }
    }

    /// The guide was switched off under us. Down at once — a reload is not a dwell.
    private func retire() {
        trigger = nil
        dwell &+= 1
        panel.hide(over: 0)
    }

    private func arm(after seconds: TimeInterval) {
        dwell &+= 1
        let mine = dwell
        scheduler.schedule(after: seconds) { [weak self] in
            guard let self, self.dwell == mine else { return }   // a later re-arm owns the dwell now
            self.panel.hide(over: Self.fade)
        }
    }
}
