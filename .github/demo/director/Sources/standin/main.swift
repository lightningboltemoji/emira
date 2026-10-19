import AppKit

// standin NAME RRGGBB
//
// A stand-in for an app in a take: one window, that colour all over, with no title bar and Fiber's
// traffic lights. The director starts one for each `Open` step and quits them when the take ends.

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, let color = NSColor(hex: arguments[1]) else {
    print("usage: standin NAME RRGGBB")
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let standIn = StandIn(name: arguments[0], color: color)
app.delegate = standIn
app.run()

final class StandIn: NSObject, NSApplicationDelegate {
    private let window: StandInWindow

    init(name: String, color: NSColor) {
        window = StandInWindow(title: name, color: color)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

final class StandInWindow: NSWindow {
    init(title: String, color: NSColor) {
        // As big as the biggest display, so the first still emira animates it from is trimmed to its tile
        // and never falls short of it.
        let size = NSScreen.screens.reduce(NSSize.zero) {
            NSSize(width: max($0.width, $1.frame.width), height: max($0.height, $1.frame.height))
        }
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // Kept for AX and emira's state, never drawn.
        self.title = title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = color
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        TrafficLights.addCapsule(to: self)
    }

    // NSWindow's private factory for its frame view, which lays out the traffic lights.
    @objc(frameViewClassForStyleMask:)
    class func frameViewClass(forStyleMask styleMask: UInt) -> AnyClass {
        let selector = #selector(frameViewClass(forStyleMask:))
        typealias Factory = @convention(c) (AnyClass, Selector, UInt) -> AnyClass
        guard let method = class_getClassMethod(NSWindow.self, selector) else { return NSView.self }
        let base: AnyClass = unsafeBitCast(method_getImplementation(method), to: Factory.self)(self, selector, styleMask)
        return TrafficLights.frameViewClass(base: base)
    }
}

extension NSColor {
    /// `RRGGBB`, in sRGB.
    convenience init?(hex: String) {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
