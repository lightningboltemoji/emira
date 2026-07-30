import AppKit
import Foundation

// The onboarding window itself: the wordmark, the blurb, one row per grant, and a heartbeat that notices
// the switch being flipped.
//
// `gate` **holds boot** in a modal session, which is what keeps the daemon's boot straight-line —
// everything below the permissions check assumes the grants are in, and a modal loop is the one way to
// wait before `NSApplication.run()` has started. It ends by asking for a restart rather than carrying on,
// because a grant given to a running emira is only half a grant: this process cannot read the Screen
// Recording answer it was just handed, its capture client is stale the same way, and its menu bar item
// does not appear.

@MainActor
public final class OnboardingWindow: NSObject, NSWindowDelegate {

    /// Why the window came down.
    public enum Outcome: Equatable, Sendable {
        /// Nothing was missing — the window never opened and boot continues in this process.
        case granted
        /// The window was shown, so emira has to be launched again. `missing` is what was still
        /// outstanding when it closed: empty when everything was granted, otherwise what the user gave up
        /// on. Either way the daemon's move is to exit.
        case restart(missing: [String])
    }

    /// Ask for every missing grant, then hold boot until the user quits. Returns `.granted` immediately
    /// when there was nothing to ask for. `screens.first`, not `NSScreen.main`, for the reason the
    /// compositor picks the same display: it is the one the strip and the menu bar item are on.
    @discardableResult
    public static func gate(_ model: OnboardingModel,
                            screen: NSScreen? = NSScreen.screens.first) -> Outcome {
        guard !model.isSatisfied else { return .granted }
        // Held in a local for the duration: `NSWindow.delegate` is weak, and so is the heartbeat's
        // capture of it.
        let gate = OnboardingWindow(model: model, screen: screen)
        return gate.run()
    }

    /// The text column's width. The window is not resizable, so this is also what the labels wrap at.
    private static let columnWidth: CGFloat = 420

    private let window: NSWindow
    private let screen: NSScreen?
    private let heartbeat: any Heartbeat = DispatchHeartbeat()
    private let delay: any DelayScheduler = DispatchScheduler()

    private var model: OnboardingModel
    private var hasStopped = false

    /// At most one subprocess probe in flight; the answer is the only thing that starts the next.
    private var isProbing = false

    /// Which grants have had their system prompt shown, so no row is ever asked about twice.
    private var prompted: Set<GrantRow.Service> = []

    /// One per row, rebuilt never: the set of rows is fixed for the window's life, so a poll only changes
    /// what these say.
    private var indicators: [NSTextField] = []
    private var buttons: [NSButton] = []
    private let statusLabel = NSTextField(labelWithString: "")

    /// Hidden until every grant is in. It is the only way out that leaves emira ready to be launched, so
    /// it appears exactly when it becomes the thing to do — and looks like it (`PulseButton`).
    private lazy var quitButton = PulseButton(title: "quit emira", target: self, action: #selector(quit))

    private init(model: OnboardingModel, screen: NSScreen?) {
        self.model = model
        self.screen = screen
        self.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                               styleMask: [.titled, .closable, .fullSizeContentView],
                               backing: .buffered,
                               defer: false)
        super.init()
        build()
    }

    // MARK: - Running

    private func run() -> Outcome {
        render()
        place()

        // On screen *before* the modal session, which is the whole of the placement working:
        // `runModal(for:)` centres a window it has to show itself, silently discarding the frame above.
        window.orderFrontRegardless()

        // The system's own prompt, once ours is up: the first drain is the earliest moment the user can
        // already see what the prompt is for.
        delay.schedule(after: 0) { [weak self] in self?.ask() }
        heartbeat.start(every: OnboardingModel.pollInterval) { [weak self] in self?.poll() }
        NSApp.activate()
        NSApp.runModal(for: window)
        heartbeat.stop()
        window.orderOut(nil)
        // Whatever ended the session, the daemon's move is the same and what is outstanding is all it
        // needs to know.
        return .restart(missing: model.missing)
    }

    /// Size the window to its content and put it back in the corner. Called again when the quit button
    /// appears: `setContentSize` alone grows the window upward, out of its inset and under the menu bar.
    private func place(animated: Bool = false) {
        window.setContentSize(window.contentView?.fittingSize ?? .zero)
        guard let visible = screen?.visibleFrame else { return window.center() }
        var frame = window.frame
        frame.origin = OnboardingPlacement.origin(for: frame.size, in: visible)
        window.setFrame(frame, display: true, animate: animated)
    }

    /// Show the standard system prompt for the **first** outstanding grant, and only that one: both fired
    /// together produce one prompt, macOS putting up the Accessibility sheet and dropping the other. The
    /// row being asked about is always the top ❌, and a grant landing earns the next one its prompt.
    private func ask() {
        guard let row = model.rows.first(where: { !$0.grant.isGranted }),
              prompted.insert(row.service).inserted else { return }
        row.request()
    }

    /// Re-read the grants, and ask a fresh process about the one this one can't read.
    private func poll() {
        probe()
        update(model.refreshed())
    }

    /// Ask a subprocess whether Screen Recording has landed — but only once it is the row being asked
    /// about, since a spawn every 300 ms through an Accessibility wait is a process per tick for nothing.
    /// A probe outlives its tick, so only its answer starts the next one.
    private func probe() {
        guard !isProbing,
              let index = model.rows.firstIndex(where: { !$0.grant.isGranted }),
              model.rows[index].service == .screenRecording else { return }
        isProbing = true
        Permissions.probeScreenRecording { [weak self] grant in
            guard let self else { return }
            isProbing = false
            guard grant.isGranted else { return }
            var next = model
            next.rows[index].grant = .granted
            update(next)
        }
    }

    /// Take a new model: render what changed, and stop watching once nothing is outstanding. The one tail
    /// both the heartbeat and the probe come back through.
    private func update(_ next: OnboardingModel) {
        guard next != model else { return }
        model = next
        render()
        guard model.isSatisfied else { return ask() }
        // The window stays up, now asking for the restart that makes the grants real — `render` has put
        // the button there, and the window has to grow to fit it.
        heartbeat.stop()
        place(animated: true)
    }

    /// The close box, which from here says the same thing as the button: emira has to be launched again,
    /// and this process is in the way.
    public func windowWillClose(_ notification: Notification) {
        stop()
    }

    @objc private func quit() {
        stop()
    }

    /// The one way out of the modal session, and it must happen exactly once: a `stopModal` arriving after
    /// the session has ended is remembered and closes the *next* one.
    private func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        NSApp.stopModal()
    }

    // MARK: - The view

    private func build() {
        window.title = "emira"
        // The wordmark is the window's heading, so the title bar carries nothing but the close button.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Above System Settings: the point of a live table is watching the row turn ✅ from the pane the
        // user is standing in.
        window.level = .floating
        window.delegate = self

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 14
        // The top inset clears the transparent title bar the content extends under.
        content.edgeInsets = NSEdgeInsets(top: 26, left: 24, bottom: 22, right: 24)

        if let wordmark = Wordmark() {
            content.addArrangedSubview(wordmark)
            content.setCustomSpacing(18, after: wordmark)
        }

        for paragraph in model.paragraphs {
            content.addArrangedSubview(Self.label(paragraph))
        }

        let grants = table()
        content.addArrangedSubview(grants)
        content.setCustomSpacing(16, after: grants)

        // The default button, because by the time it appears it is the only thing left to do.
        quitButton.keyEquivalent = "\r"
        quitButton.isHidden = true
        content.addArrangedSubview(quitButton)
        content.setCustomSpacing(14, after: quitButton)

        // Directly under the button and at the size of the paragraphs above, because it is the same kind
        // of sentence: the reason for the button, not a status.
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = Self.columnWidth
        Self.constrainToColumn(statusLabel)
        content.addArrangedSubview(statusLabel)

        window.contentView = content
    }

    /// The grants, one row each: status, name and purpose, and the button that opens its pane.
    private func table() -> NSView {
        var cells: [[NSView]] = []
        for (index, row) in model.rows.enumerated() {
            let indicator = NSTextField(labelWithString: row.indicator)
            indicator.font = .systemFont(ofSize: 15)
            indicators.append(indicator)

            let name = NSTextField(labelWithString: row.name)
            name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            let purpose = NSTextField(labelWithString: row.purpose)
            purpose.font = .preferredFont(forTextStyle: .footnote)
            purpose.textColor = .secondaryLabelColor
            let described = NSStackView(views: [name, purpose])
            described.orientation = .vertical
            described.alignment = .leading
            described.spacing = 1

            let button = NSButton(title: "open settings", target: self, action: #selector(openSettings))
            button.bezelStyle = .rounded
            button.tag = index
            button.toolTip = "System Settings › \(row.pane)"
            buttons.append(button)

            cells.append([indicator, described, button])
        }

        let grid = NSGridView(views: cells)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.rowAlignment = .none
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 2).xPlacement = .trailing
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }
        // A fixed indicator column: ✅ and ❌ are not the same width, and the rest of the row must not
        // move when one flips.
        grid.column(at: 0).width = 22

        // A plain container inside the box, pinned: `NSBox` handles the appearance-aware fill and border,
        // explicit constraints handle the size.
        let inner = NSView()
        inner.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -14),
            grid.topAnchor.constraint(equalTo: inner.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: inner.bottomAnchor, constant: -12),
        ])

        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 10
        box.contentViewMargins = .zero
        box.contentView = inner
        Self.constrainToColumn(box)
        return box
    }

    private func render() {
        for (index, row) in model.rows.enumerated() {
            indicators[index].stringValue = row.indicator
            // Nothing left to do in a pane whose switch is already on.
            buttons[index].isEnabled = !row.grant.isGranted
        }
        statusLabel.stringValue = model.status
        quitButton.isHidden = !model.isSatisfied
        if model.isSatisfied { window.makeFirstResponder(quitButton) }
    }

    @objc private func openSettings(_ sender: NSButton) {
        guard model.rows.indices.contains(sender.tag),
              let url = URL(string: model.rows[sender.tag].url) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Text

    /// A wrapping label. `NSTextField` rather than `NSTextView`: nothing here scrolls or is edited, and a
    /// label sizes itself from the width it is given.
    private static func label(_ markup: String) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: attributed(markup))
        field.isSelectable = true
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = columnWidth
        constrainToColumn(field)
        return field
    }

    private static func constrainToColumn(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
    }

    /// The blurb's inline markdown, as fonts. Foundation does the parsing; the fonts have to be ours,
    /// because `NSAttributedString(AttributedString)` carries the presentation intents across and no
    /// `.font` attribute at all — which an `NSTextField` draws as plain text.
    private static func attributed(_ markup: String) -> NSAttributedString {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let plain: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor]
        guard let parsed = try? AttributedString(
                markdown: markup,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: markup, attributes: plain)
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attributes = plain
            if intent.contains(.code) {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: body.pointSize - 1,
                                                                weight: .regular)
            } else if intent.contains(.stronglyEmphasized) {
                attributes[.font] = NSFont.boldSystemFont(ofSize: body.pointSize)
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters),
                                             attributes: attributes))
        }
        return result
    }
}
