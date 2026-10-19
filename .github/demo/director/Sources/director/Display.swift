import AppKit
import VirtualDisplay

/// The take's display: a virtual one, `size` in points at 2x, which macOS treats as attached for as
/// long as this holds it. A crash takes it with the process, so it can't outlive a take.
@MainActor
final class TakeDisplay {
    let id: CGDirectDisplayID
    let size: CGSize
    private var display: EMVirtualDisplay?

    init(size: CGSize) async throws {
        guard let display = EMVirtualDisplay(
            name: "emira demo", width: UInt32(size.width * 2), height: UInt32(size.height * 2), serial: 0xE31A)
        else { throw DirectorError("macOS refused the take's display (is another take running?)") }
        self.display = display
        self.id = display.displayID
        self.size = size
        try await Self.until("the take's display to attach") { Self.active().contains(display.displayID) }

        // It comes up at 1x; its HiDPI mode is one of those it offers, a moment after it attaches.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        var hiDPI: CGDisplayMode?
        try await Self.until("the take's display to offer \(Int(size.width))×\(Int(size.height)) HiDPI") {
            let modes = (CGDisplayCopyAllDisplayModes(display.displayID, options) as? [CGDisplayMode]) ?? []
            hiDPI = modes.first { $0.width == Int(size.width) && $0.pixelWidth == Int(size.width) * 2 }
            return hiDPI != nil
        }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, id, hiDPI, nil)
        CGCompleteDisplayConfiguration(config, .forAppOnly)
        try await Self.until("the take's display to go HiDPI") {
            CGDisplayCopyDisplayMode(self.id)?.pixelWidth == Int(size.width) * 2 && self.frame.size == size
        }
    }

    /// Global points from the top left.
    var frame: CGRect { CGDisplayBounds(id) }

    /// `screencapture -D`'s number for it: its place among the active displays, from 1.
    var captureNumber: Int? {
        Self.active().firstIndex(of: id).map { $0 + 1 }
    }

    /// Detaches it, and waits for macOS to agree.
    func remove() async {
        guard display != nil else { return }
        display = nil
        try? await Self.until("the take's display to detach") { !Self.active().contains(self.id) }
    }

    private static func active() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private static func until(_ what: String, _ check: () -> Bool) async throws {
        for _ in 0..<100 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DirectorError("gave up waiting for \(what)")
    }
}
