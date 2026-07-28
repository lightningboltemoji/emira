import AppKit

// The demo's caption overlay: a translucent box in the bottom-right corner naming what the
// choreography is doing. One caption per line on stdin — `mono|description`, an empty line to hide,
// EOF to quit — so `demo.sh` drives it by holding a fifo open. Either half may be empty.
//
// Three window settings are load-bearing:
//
//  · `.screenSaver`, not `.floating`. emira's own cover is `.floating` (`Compositor/Overlay.swift`),
//    and a caption drawn *under* it would be baked into the captured base and freeze for the length
//    of every transition — including the caption change that announces the next step.
//  · `.nonactivatingPanel` + `orderFrontRegardless()`. The overlay must never take focus: the
//    choreography's commands all act on the focused window.
//  · `.canJoinAllSpaces` + `.fullScreenAuxiliary`, so the caption survives the Safari full-screen
//    step, which is the one moment the demo leaves the desktop Space.
//
// Borderless with no subrole, so emira's taxonomy reads it as `.other` and floats it rather than
// tiling it (`AX/AXAccess.swift`).

final class CaptionOverlay: NSObject {

    /// Everything below is in points at scale 1 and multiplied by this — the film is downscaled to a
    /// small webp, so the caption has to survive the shrink that the desktop behind it doesn't have
    /// to. `CAPTION_SCALE` in the environment overrides it.
    private static let scale: CGFloat = {
        let environment = ProcessInfo.processInfo.environment["CAPTION_SCALE"]
        return environment.flatMap { Double($0) }.map { CGFloat($0) } ?? 3
    }()

    /// Corner inset from the visible frame. Bottom-**right** is also where parked windows keep their
    /// nubs, which the box covers — the demo is better for not showing them.
    private static let margin: CGFloat = 30 * scale
    private static let padding = NSEdgeInsets(top: 14 * scale, left: 20 * scale,
                                              bottom: 14 * scale, right: 20 * scale)
    private static let maximumTextWidth: CGFloat = 300 * scale
    private static let fade: TimeInterval = 0.14

    private let panel: NSPanel
    private let box = NSView()
    private let mono = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    /// Pinned once: `NSScreen.main` follows the key window, which moves throughout the demo.
    private let screen: NSScreen

    override init() {
        screen = NSScreen.main ?? NSScreen.screens[0]
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0

        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.04, alpha: 0.72).cgColor
        box.layer?.cornerRadius = 14 * Self.scale
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = max(1, Self.scale.rounded())
        box.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        style(mono, font: .monospacedSystemFont(ofSize: 20 * Self.scale, weight: .medium),
              colour: NSColor(white: 1, alpha: 0.98))
        style(detail, font: .systemFont(ofSize: 14 * Self.scale, weight: .regular),
              colour: NSColor(white: 1, alpha: 0.7))

        let stack = NSStackView(views: [mono, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6 * Self.scale
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        let inset = Self.padding
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset.left),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset.right),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: inset.top),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset.bottom),
        ])
        panel.contentView = box
        panel.orderFrontRegardless()
    }

    private func style(_ label: NSTextField, font: NSFont, colour: NSColor) {
        label.font = font
        label.textColor = colour
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = Self.maximumTextWidth
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    // MARK: - The line protocol

    /// `mono|description`. An empty line hides the box; either half may be empty on its own.
    func apply(_ line: String) {
        let halves = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let first = halves.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let second = halves.count > 1 ? halves[1].trimmingCharacters(in: .whitespaces) : ""
        if first.isEmpty && second.isEmpty { hide() } else { show(mono: first, detail: second) }
    }

    /// Out, swap, back in — the box resizes to each caption, so a straight swap would jump.
    private func show(mono text: String, detail description: String) {
        crossfade {
            self.mono.stringValue = text
            self.mono.isHidden = text.isEmpty
            self.detail.stringValue = description
            self.detail.isHidden = description.isEmpty
            self.resize()
        }
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            panel.animator().alphaValue = 0
        }
    }

    private func crossfade(_ swap: @escaping () -> Void) {
        let wasVisible = panel.alphaValue > 0
        let out = wasVisible ? Self.fade : 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = out
            self.panel.animator().alphaValue = 0
        }, completionHandler: {
            swap()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fade
                self.panel.animator().alphaValue = 1
            }
        })
    }

    /// Fit the box to the caption, then pin its bottom-right corner — the corner is what stays put.
    private func resize() {
        box.layoutSubtreeIfNeeded()
        let size = box.fittingSize
        let area = screen.visibleFrame
        let origin = NSPoint(x: area.maxX - Self.margin - size.width,
                             y: area.minY + Self.margin)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

// MARK: - Entry point

let application = NSApplication.shared
application.setActivationPolicy(.accessory)      // no Dock tile, no menu bar, never frontmost

let overlay = CaptionOverlay()

// stdin is a fifo `demo.sh` holds open; EOF means the choreography is done.
Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        DispatchQueue.main.async { overlay.apply(line) }
    }
    DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
}

application.run()
