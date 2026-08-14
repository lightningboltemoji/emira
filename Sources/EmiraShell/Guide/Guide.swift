import AppKit
import CoreGraphics
import EmiraCore
import EmiraGuide

// The guides' controller: when they go up, how long they stay, and where their pictures come from.
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
//     fade     that guide's own `duration` after its last re-arm
//
// The trigger is a small diffed projection rather than the whole `State`, so an `axLanded` or a title
// change cannot summon a HUD — `MenuBarItem`'s rule about reporting a change in the value rather than
// in the thing carrying it.
//
// `DelayScheduler` has no cancellation, stated at the protocol. The dwell therefore uses the
// generation-token idiom `Overlay.fadeOut` already uses: each re-arm bumps a counter and the scheduled
// closure returns early unless it is still the current one. No new seam, at the price of one inert
// closure per frame of motion.
//
// **The dwell is one guide's.** Each style is armed for its own table's `duration` and leaves on its
// own, because two guides answering *where am I* in two corners are two settings and not one.

/// One display's guide window, as the controller needs it: adopt a renderer, put its panel somewhere,
/// raise it, fade it away. `GuidePanel` is the real one, and it needs a window server; the decisions
/// here do not, so tests use a recording double — `CoverSurface`'s reason exactly.
@MainActor
public protocol GuideSurface: AnyObject {
    /// What a renderer built for this display should rasterize at.
    var backingScale: CGFloat { get }
    /// Whether this guide is up — what the controller asks before spending a frame drawing one.
    func isShown(_ renderer: any GuideRenderer) -> Bool
    func adopt(_ renderer: any GuideRenderer)
    func place(_ renderer: any GuideRenderer, at panel: Rect)
    /// Raise one guide. Instant, which is `GuideFade.up`.
    func show(_ renderer: any GuideRenderer)
    /// Lower one guide over `duration`, zero being a cut. Idempotent: a guide already down stays down.
    func hide(_ renderer: any GuideRenderer, over duration: TimeInterval)
}

/// The guides: transient drawings of one display's strip, above the cover and outliving it. One per
/// display, each drawing the workspace its own monitor is showing — so a second screen showing an
/// empty address draws nothing, and switching *it* is what puts a guide there.
@MainActor
public final class Guide {

    private let panel: any GuideSurface
    /// The display this guide is on, and therefore the workspace it draws.
    private let monitor: MonitorId
    /// One per style, in `GuideStyle.allCases`' own drawing order — the list both hosts build from.
    private let renderers: [any GuideRenderer]
    private let scheduler: any DelayScheduler
    /// Where the pictures come from — the stills a cover left behind, and the app icons behind them.
    private let sources: GuideSources

    private var trigger: GuideTrigger?
    /// Bumped by every re-arm, per style; a scheduled dwell that is no longer current does nothing.
    private var dwells: [GuideStyle: Int] = [:]

    public init(panel: any GuideSurface, monitor: MonitorId, icons: GuideIcons, names: GuideNames,
                scheduler: any DelayScheduler,
                still: @escaping @MainActor (WindowId) -> CGImage? = { _ in nil }) {
        self.panel = panel
        self.monitor = monitor
        self.scheduler = scheduler
        self.sources = GuideSources(still: still, icon: { [icons] in icons.icon(for: $0) },
                                    name: { [names] in names.name(for: $0) })
        self.renderers = GuideStyle.renderers(contentsScale: panel.backingScale)
        for renderer in renderers { panel.adopt(renderer) }
    }

    /// Seed the trigger without showing anything — what the daemon calls once, before wiring
    /// `onStateChanged`, so the boot scan's own arrivals are the first thing the guide reacts to rather
    /// than the fact that it has just been built.
    public func prime(_ state: State) {
        trigger = GuideTrigger(state: state, monitor: monitor)
    }

    /// One drain's worth of state.
    public func stateChanged(_ state: State) {
        let settings = state.config.guide
        let live = settings.enabledStyles
        for renderer in renderers where !live.contains(renderer.style) { lower(renderer, over: 0) }
        guard !live.isEmpty else { return retire() }
        // Nothing to project onto: no display known yet (boot, or a reload racing a display change), or
        // this display gone.
        guard let input = GuideInput(state: state, monitor: monitor) else { return }

        let next = GuideTrigger(state: state, monitor: monitor)
        let moved = next != trigger
        trigger = next

        // The daemon draws at `1`: a guide over the real desktop is the object itself, and the scale is
        // there for the host that draws the same object smaller.
        let palette = GuidePalette.system
        for renderer in renderers where live.contains(renderer.style) {
            // A guide that is down and has nothing raising it costs no frame. It comes back on the next
            // trigger change, which is the only thing that gives a style something new to say.
            guard moved || panel.isShown(renderer) else { continue }
            // Nothing to draw shows nothing, exactly as off does — a style left carrying its last frame
            // would answer *where am I* with the workspace you just left.
            guard let drawing = GuideDrawing.of(renderer.style, input: input, settings: settings,
                                                face: GuideTypeface.face,
                                                name: sources.name) else {
                lower(renderer, over: 0)
                continue
            }
            renderer.draw(drawing, settings: settings, scale: 1, palette: palette, sources: sources)
            panel.place(renderer, at: drawing.panel)
            panel.show(renderer)

            // `needsFrames` is the core's own "something is still moving" — a transition open, or the
            // focus ring still travelling. So a dwell starts when everything stops, not when the key
            // was pressed.
            if moved || state.motion.needsFrames {
                arm(renderer, after: settings.table(of: renderer.style).duration)
            }
        }
    }

    /// Every guide was switched off under us. Down at once — a reload is not a dwell.
    private func retire() {
        trigger = nil
        for renderer in renderers { lower(renderer, over: 0) }
    }

    /// Take one guide down and disown whatever dwell was carrying it.
    private func lower(_ renderer: any GuideRenderer, over duration: TimeInterval) {
        dwells[renderer.style, default: 0] &+= 1
        panel.hide(renderer, over: duration)
    }

    private func arm(_ renderer: any GuideRenderer, after seconds: TimeInterval) {
        let style = renderer.style
        dwells[style, default: 0] &+= 1
        let mine = dwells[style]
        scheduler.schedule(after: seconds) { [weak self] in
            // A later re-arm owns this guide's dwell now.
            guard let self, self.dwells[style] == mine else { return }
            self.panel.hide(renderer, over: GuideFade.down)
        }
    }
}
