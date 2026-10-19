import AVFoundation
import AppKit

/// Seconds on the host clock, which every time in a take is noted in.
func hostNow() -> Double {
    CMClockGetTime(CMClockGetHostTimeClock()).seconds
}

/// Films a display with `screencapture -v`, which keeps windows' drop shadows where ScreenCaptureKit's
/// display capture drops them. Its movie carries no host times, so a take opens with a `Flash`, and
/// `firstFlash` finds where it landed.
@MainActor
final class Recorder {
    let url: URL
    private let process = Process()

    init(display number: Int, to url: URL) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-v", "-D", "\(number)", url.path()]
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// SIGINT, which has it finish the movie.
    func stop() async throws {
        guard process.isRunning else { return }
        process.interrupt()
        for _ in 0..<200 where process.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !process.isRunning, process.terminationStatus == 0 else {
            throw DirectorError("screencapture didn't finish the movie")
        }
    }

    /// Seconds into the movie at which the flash first shows in `patch` (movie pixels from the top
    /// left).
    static func firstFlash(in url: URL, patch: CGRect) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw DirectorError("the movie has no video")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var first: Double?
        while let sample = output.copyNextSampleBuffer() {
            let time = sample.presentationTimeStamp.seconds
            if first == nil { first = time }
            if time - first! > 20 { break }
            guard let pixels = sample.imageBuffer, Flash.isShowing(in: pixels, patch: patch) else { continue }
            reader.cancelReading()
            return time - first!
        }
        throw DirectorError("the take's opening flash isn't in the movie")
    }
}

/// A patch of a colour nothing on the desktop is, shown for a moment in a corner of the take display
/// and noted on the host clock.
@MainActor
enum Flash {
    /// Points along a side.
    static let size = 64.0

    /// Shows it at the bottom left of `screen`; returns the host time it went up.
    static func show(on screen: NSScreen) async -> Double {
        let window = NSWindow(
            contentRect: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: size, height: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.orderFrontRegardless()
        window.display()
        CATransaction.flush()
        let shown = hostNow()
        try? await Task.sleep(for: .milliseconds(400))
        window.orderOut(nil)
        CATransaction.flush()
        return shown
    }

    /// Where the patch is in a frame of the take display, in pixels from the top left.
    static func patch(display: CGSize, scale: Double) -> CGRect {
        CGRect(x: 0, y: (display.height - size) * scale, width: size * scale, height: size * scale)
    }

    static func isShowing(in buffer: CVPixelBuffer, patch: CGRect) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let x = Int(patch.midX), y = Int(patch.midY)
        guard x < CVPixelBufferGetWidth(buffer), y < CVPixelBufferGetHeight(buffer) else { return false }
        let pixel = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
        let (blue, green, red) = (pixel[0], pixel[1], pixel[2])
        return red > 200 && blue > 200 && green < 90
    }
}
