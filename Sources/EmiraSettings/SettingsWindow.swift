import AppKit
import EmiraConfig
import EmiraCore
import EmiraMotion

// The settings window, which is not a window: a scrim over **every** display, the user's own desktop
// drawn small and floating above it, and the controls floating below that.
//
// One borderless window per screen. Dimming one monitor and leaving the other bright reads as a bug, so
// every display is scrimmed; the monitor and the slab go on the display holding the pointer, and the
// mock is *that* display's geometry.
//
// **A borderless window answers `false` to `canBecomeKey`** and the controls need the keyboard, so the
// content window overrides it. The symptom of forgetting is a control that silently will not take a
// keystroke rather than anything that looks like an error.

@MainActor
public final class SettingsWindow: NSObject, NSWindowDelegate {

    /// Why the window came down. The caller owns the file, so a save is handed back as text rather than
    /// written here — `ConfigDocument`'s no-I/O rule, one level out.
    public enum Outcome: Sendable {
        case dismissed
        /// Save this text — but only if the file still holds `basedOn`. The window never writes, so the
        /// caller owning the path is also the one that can check nobody else got there first.
        case save(rendered: String, basedOn: String)
    }

    private var scrims: [NSWindow] = []
    private var content: NSWindow?
    private var stage: Stage?
    private var clock: PreviewClock?

    private var draft: Draft
    private var take: Take
    private var motion = PreviewMotion()
    /// The camera, travelling on the window's own fixed curve. **Deliberately not in `PreviewMotion`**:
    /// the desktop moves on the user's springs and the furniture moves on ours, and mixing the two is
    /// what would let a sludgy `movement.stiffness` hide behind an equally sludgy lens.
    private var camera: CameraTravel
    private var projection: Projection

    /// Seconds into the take. Advanced by the clock, and held still while a control is being dragged so
    /// the loop is never fighting the hand.
    private var elapsed: Double = 0
    private var isDragging = false
    /// The file's text as of the change the banner is asking about, or `nil` when it is not up.
    private var pendingFile: String?
    private let environment = SettingsEnvironment()
    /// Bumped by every hover, so a dwell that has been superseded knows not to take the stage.
    private var hoverGeneration = 0

    private let onClose: @MainActor (Outcome) -> Void

    /// Open over every attached display, with the content on the one holding the pointer.
    ///
    /// - Parameter text: the config file's text. An absent file is the caller's to turn into the starter
    ///   document, for the reason nothing here does I/O.
    public static func open(text: String,
                            onClose: @escaping @MainActor (Outcome) -> Void) throws -> SettingsWindow {
        let window = try SettingsWindow(text: text, onClose: onClose)
        window.show()
        return window
    }

    private init(text: String, onClose: @escaping @MainActor (Outcome) -> Void) throws {
        self.draft = try Draft(text)
        self.onClose = onClose
        let screen = Self.screenUnderPointer()
        let projection = Projection(screen: screen,
                                    mockWidth: Double(screen.frame.width)
                                        * SettingsStyle.mockWidthFraction)
        self.projection = projection
        self.camera = CameraTravel(projection.displayFrame)
        // The section's set is what the window opens on, which is a static take.
        self.take = Catalog.take(for: .layout)
        super.init()
    }

    /// The screen the pointer is on — where the user is looking, and the display the mock portrays.
    private static func screenUnderPointer() -> NSScreen {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func show() {
        let host = Self.screenUnderPointer()

        for screen in NSScreen.screens {
            let scrim = makeScrim(on: screen, interactive: screen == host)
            scrims.append(scrim)
            if screen == host { content = scrim }
        }

        buildContent(on: host)
        renderNow(settle: true)

        clock = PreviewClock(screen: host) { [weak self] dt in self?.advance(by: dt) }

        environment.onAppearance = { [weak self] in self?.restyle() }
        environment.onScreens = { [weak self] in self?.rebuildForScreens() }
        environment.onMotionPreference = { [weak self] in self?.renderNow(settle: true) }
        environment.start()

        stage?.move(to: .lifted)
        for scrim in scrims { scrim.orderFrontRegardless() }
        present(.seated, on: scrims)
        NSApp.activate()
        content?.makeKeyAndOrderFront(nil)
    }

    /// Set the composition down on the desktop, or lift it off again — one motion run in either
    /// direction, and `SettingsStyle`'s presentation section is the argument for it.
    ///
    /// **Reduce Motion keeps the dissolve and drops the travel.** A cross-fade is what the preference
    /// asks a zoom to become; removing the transition altogether would make the window arrive by
    /// replacing the desktop in a single frame, which is the thing it is least willing to sit through.
    private func present(_ placement: Stage.Placement, on windows: [NSWindow],
                         then completion: @escaping @MainActor () -> Void = {}) {
        stage?.move(to: placement, over: animates ? SettingsStyle.present : 0)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = SettingsStyle.present
            context.timingFunction = SettingsStyle.presentCurve
            for window in windows { window.animator().alphaValue = placement.alpha }
        }, completionHandler: { MainActor.assumeIsolated(completion) })
    }

    private func makeScrim(on screen: NSScreen, interactive: Bool) -> NSWindow {
        let window: NSWindow
        if interactive {
            let keyable = KeyableWindow(contentRect: screen.frame, styleMask: .borderless,
                                        backing: .buffered, defer: false)
            keyable.onCancel = { [weak self] in self?.dismiss() }
            window = keyable
        } else {
            window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = SettingsStyle.scrimLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.animationBehavior = .none
        window.alphaValue = 0
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: false)

        let backdrop = NSVisualEffectView(frame: CGRect(origin: .zero, size: screen.frame.size))
        backdrop.material = SettingsStyle.backdropMaterial
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]

        // A **double** click on the dim dismisses, and the dim is the view that takes it. An
        // `NSClickGestureRecognizer` on the effect view does *not* receive these — the visual-effect
        // view is not in the routing path a click takes to the dim above it — so the dismissal is an
        // explicit `mouseDown` rather than a recognizer.
        let dim = ScrimView(frame: backdrop.bounds)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(SettingsStyle.dim).cgColor
        dim.autoresizingMask = [.width, .height]
        dim.onDismiss = { [weak self] in self?.dismiss() }
        backdrop.addSubview(dim)

        window.contentView = backdrop
        return window
    }

    private func buildContent(on screen: NSScreen) {
        guard let backdrop = content?.contentView else { return }

        let desktop = DesktopView(projection: projection, backingScale: screen.backingScaleFactor)
        let slab = ControlSlab()
        slab.show(draft)
        slab.onChange = { [weak self] edit in self?.edit(edit) }
        slab.onDragChanged = { [weak self] dragging in self?.isDragging = dragging }
        slab.onSection = { [weak self] section in self?.sectionChanged(to: section) }
        slab.onHover = { [weak self] key in self?.hovered(key) }
        slab.onSave = { [weak self] in self?.commit() }
        slab.onDiscard = { [weak self] in self?.revert() }
        slab.onReload = { [weak self] in self?.acceptFile() }
        slab.onKeepEditing = { [weak self] in self?.dismissBanner() }

        // The stage is the stack; centring it on the display is all that is left.
        let stage = Stage(desktop: desktop, slab: slab)
        let size = screen.frame.size
        stage.setFrameOrigin(CGPoint(x: ((size.width - stage.frame.width) / 2).rounded(),
                                     y: ((size.height - stage.frame.height) / 2).rounded()))

        backdrop.addSubview(stage)
        self.stage = stage
    }

    // Editing

    /// How long the pointer has to rest on a control before what it names takes the stage. Without it,
    /// crossing the panel strobes the mock through every take on the way.
    static let hoverDwell: TimeInterval = 0.25

    /// A tab was picked. The section's set goes up at once — no dwell, since the panel under the
    /// pointer changed wholesale.
    private func sectionChanged(to section: Setting.Section) {
        play(Catalog.take(for: section))
    }

    /// The pointer entered a row, which named the setting or the surface under it. Held for
    /// `hoverDwell` before it counts, and superseded by anything the pointer reaches in the meantime.
    ///
    /// **A row with nothing to show holds the stage.** `Catalog` answering `nil` means "leave whatever
    /// is playing alone" rather than "fall back to the section": crossing `hold-timeout` on the way down
    /// the panel must not tear the mock away from the setting above it, which the user would read as
    /// that setting having no picture either.
    private func hovered(_ key: String) {
        hoverGeneration &+= 1
        let mine = hoverGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDwell) { [weak self] in
            guard let self, hoverGeneration == mine,
                  let take = Catalog.take(for: key, config: draft.config) else { return }
            play(take)
        }
    }

    /// **An edit restarts the take it edited.** A ladder is walked one beat per rung, so committing a
    /// new list must play the new ladder from the top rather than resuming three rungs into a script
    /// that no longer exists.
    private func edit(_ edit: Draft.Edit) {
        draft.apply(edit)
        // No dwell: you touched it, you meant it. And a setting with no picture still holds the stage.
        // Looked up **after** the edit has landed, because the draft is an input to the catalog: a
        // fourth width typed has to walk a four-rung ladder, not the three that were there before.
        if let take = Catalog.take(for: edit.key, config: draft.config) { play(take, restarting: true) }
        // The draft is the authority: every control re-reads it, so a refused edit shows the file's
        // value rather than the one that was typed.
        stage?.slab.show(draft)
        renderNow(settle: false)
    }

    private func revert() {
        draft.discard()
        stage?.slab.show(draft)
        renderNow(settle: false)
    }

    /// Hand the text to whoever owns the file, with the baseline it was built on so a foreign edit
    /// cannot be clobbered.
    private func commit() {
        onClose(.save(rendered: draft.rendered, basedOn: draft.baseline.rendered))
    }

    /// Told by the shell that the file on disk changed.
    ///
    /// **Ours is not a change.** A save writes text the draft already holds as its baseline, and the
    /// watcher cannot tell that write from anyone else's — so the draft's own text is what says whether
    /// this was somebody else.
    public func fileChanged(text: String) {
        guard text != draft.baseline.rendered else { return }
        pendingFile = text
        // With nothing unsaved, re-reading is silent: there is no edit to lose and a banner would be
        // asking permission to do the only sensible thing.
        if draft.isDirty {
            stage?.slab.showBanner(true)
        } else {
            acceptFile()
        }
    }

    /// Take the file as it now stands, dropping whatever was unsaved.
    private func acceptFile() {
        guard let text = pendingFile else { return }
        pendingFile = nil
        stage?.slab.showBanner(false)
        try? draft.reload(text)
        stage?.slab.show(draft)
        renderNow(settle: false)
    }

    private func dismissBanner() {
        pendingFile = nil
        stage?.slab.showBanner(false)
    }

    /// A saved draft is its own baseline, so the write the watcher reports back is recognised as ours.
    public func saved() {
        draft.saved()
        stage?.slab.show(draft)
    }

    /// Put a different take on the mock, from wherever the last one had got to.
    ///
    /// **A retarget, not a cut**: the mock windows travel from the old arrangement to the new one under
    /// the draft's own springs, so every hover is itself a small demonstration of the animation
    /// settings. The same take again is left alone — restarting its loop would be a jump nobody asked
    /// for, and it is what makes crossing between two settings that share a set cost nothing.
    private func play(_ take: Take, restarting: Bool = false) {
        guard take != self.take || restarting else { return }
        self.take = take
        elapsed = 0
        renderNow(settle: false)
    }

    /// Derive the preview and hand it to the layers. `settle` snaps rather than springs — the first
    /// frame, where a preview that sprang into place would be animating the act of opening.
    private func renderNow(settle: Bool) {
        let state = PreviewModel.state(of: take, at: elapsed,
                                       config: draft.config, workingArea: projection.workingArea)
        if settle || !animates {
            motion.snap(to: state)
            camera.snap(to: framing(of: state))
        } else {
            motion.retarget(to: state, springs: PreviewSprings(draft.config),
                            mode: draft.config.transitionMode, head: state.head)
            camera.retarget(to: framing(of: state))
        }
        draw(state)
        syncClock()
    }

    private func advance(by dt: Double) {
        if !isDragging && !take.isStatic { elapsed += dt }
        let state = PreviewModel.state(of: take, at: elapsed,
                                       config: draft.config, workingArea: projection.workingArea)

        // **Retargeted every frame, before advancing.** A beat that fired since the last one changes the
        // arrangement, and without this the panes would cut to it rather than travel. `retarget` is
        // idempotent when nothing moved — every delta is zero and no animator is touched — so the
        // ordinary frame costs a comparison and the beat costs a spring, with no flag between them.
        if animates {
            // **`animation.transition` governs every take, not only its own.** It is what the desktop
            // will do once saved, so a preview that exempted itself would be showing a different
            // machine — the same discipline the springs keep.
            motion.retarget(to: state, springs: PreviewSprings(draft.config),
                            mode: draft.config.transitionMode, head: state.head)
            camera.retarget(to: framing(of: state))
        } else {
            motion.snap(to: state)
            camera.snap(to: framing(of: state))
        }
        motion.advance(by: dt)
        motion.prune()
        camera.advance(by: dt)

        draw(state)
        syncClock()
    }

    /// Where the take wants the camera, resolved against this display. Off the **layout's** frames and
    /// not the animated ones: the lens travels to where the desktop is going, so the two arrive
    /// together rather than the camera chasing the strip.
    private func framing(of state: PreviewState) -> Rect {
        state.camera.frame(of: state, in: projection)
    }

    private func draw(_ state: PreviewState) {
        stage?.desktop.render(scene: state.scene, frames: motion.frames(of: state),
                              targets: state.frames, camera: camera.current,
                              pointer: state.pointer, cursor: state.scene.pointer,
                              showsPointer: state.isPointerShown,
                              animation: draft.config.windowAnimation, raised: state.raised,
                              showsFocus: state.showsFocus,
                              guide: motion.guide(of: state), guideStyle: draft.config.guide.style,
                              mark: state.mark)
    }

    /// **Reduce Motion turns the springs off, not the demonstration.** A take still plays and its beats
    /// still fire; what goes away is the travel between arrangements, so the mock steps rather than
    /// glides. Removing the beats too would leave the behaviour settings with nothing to show at all,
    /// which is a worse answer than showing it without the movement.
    private var animates: Bool { !SettingsEnvironment.prefersReducedMotion }

    /// The appearance changed under an open window.
    private func restyle() {
        stage?.desktop.restyle()
        renderNow(settle: true)
    }

    /// The displays changed. The scrim covers every one of them, so a screen that arrived with no scrim
    /// is a hole in the composition and a screen that left has a window over nothing.
    ///
    /// Rebuilt wholesale rather than reconciled: the draft is the state worth keeping and it lives
    /// outside the views entirely, so tearing the composition down costs nothing but a frame.
    private func rebuildForScreens() {
        guard !scrims.isEmpty else { return }
        for window in scrims { window.orderOut(nil) }
        scrims = []
        content = nil
        stage = nil
        clock?.invalidate()
        clock = nil
        motion = PreviewMotion()

        let host = Self.screenUnderPointer()
        projection = Projection(screen: host,
                                mockWidth: Double(host.frame.width) * SettingsStyle.mockWidthFraction)
        camera = CameraTravel(projection.displayFrame)
        for screen in NSScreen.screens {
            let scrim = makeScrim(on: screen, interactive: screen == host)
            scrims.append(scrim)
            if screen == host { content = scrim }
        }
        buildContent(on: host)
        renderNow(settle: true)
        clock = PreviewClock(screen: host) { [weak self] dt in self?.advance(by: dt) }
        for scrim in scrims {
            scrim.alphaValue = 1
            scrim.orderFrontRegardless()
        }
        content?.makeKeyAndOrderFront(nil)
    }

    /// The link runs only while there is something to draw — a settled preview on a static take costs
    /// nothing at idle, which is most of a settings window's life.
    private func syncClock() {
        if take.isStatic && motion.isSettled() && camera.isSettled() {
            clock?.stop()
        } else {
            clock?.start()
        }
    }

    // Coming down

    @objc private func dismiss() {
        close(.dismissed)
    }

    private func close(_ outcome: Outcome) {
        environment.stop()
        clock?.invalidate()
        clock = nil
        let windows = scrims
        scrims = []
        content = nil
        // The stage is left where it is: its superview is one of `windows`, which the completion holds
        // until it is off the screen, so the composition is still there to be lifted.
        present(.lifted, on: windows) {
            for window in windows { window.orderOut(nil) }
        }
        onClose(outcome)
    }
}

/// The dim over the blur, and the thing a click outside the content lands on.
@MainActor
final class ScrimView: NSView {
    var onDismiss: (@MainActor () -> Void)?

    /// A single click is far too easy to spend by accident on a window that covers every display, and
    /// what it costs is an edit. Two is a thing you meant.
    static let clicksToDismiss = 2

    /// Without this the first click into a window that isn't already active is swallowed to activate
    /// it — so the count would restart, and dismissing would take three.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount >= Self.clicksToDismiss else { return }
        onDismiss?()
    }
}

/// A borderless window that can take the keyboard. Borderless answers `false` by default, and the
/// symptom is a control that silently ignores a keystroke.
///
/// It also owns Escape, for the reason the click on the dim exists: a scrim asks to be dismissed, and
/// `cancelOperation` is the responder chain's name for that.
@MainActor
final class KeyableWindow: NSWindow {
    var onCancel: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
