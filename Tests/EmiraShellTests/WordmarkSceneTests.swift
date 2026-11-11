import CoreGraphics
import Testing
@testable import EmiraShell

// The onboarding wordmark's loop, as numbers. `scene.ts` is where the loop is designed and the README's
// copy is rendered; `WordmarkGolden.swift` is what it draws, and the port has to draw the same.

@Suite struct WordmarkSceneTests {

    struct Drawn: Sendable {
        let letter: WordmarkScene.Letter
        let values: [Double]

        init(_ letter: WordmarkScene.Letter, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
             _ radius: Double, _ opacity: Double, _ gx: Double, _ gy: Double, _ scale: Double) {
            self.letter = letter
            self.values = [x, y, w, h, radius, opacity, gx, gy, scale]
        }
    }

    struct Instant: Sendable {
        let t: Double
        let windows: [Drawn]
        init(_ t: Double, _ windows: [Drawn]) {
            self.t = t
            self.windows = windows
        }
    }

    static func values(_ window: WordmarkScene.Window) -> [Double] {
        [window.rect.minX, window.rect.minY, window.rect.width, window.rect.height, window.cornerRadius,
         window.opacity, window.glyphOrigin.x, window.glyphOrigin.y, window.glyphScale]
    }

    @Test(arguments: golden)
    func drawsWhatTheSceneDraws(_ instant: Instant) {
        let windows = WordmarkScene.windows(at: instant.t)
        #expect(windows.map(\.letter) == instant.windows.map(\.letter), "draw order at \(instant.t)s")
        for (window, expected) in zip(windows, instant.windows) {
            let drift = zip(Self.values(window), expected.values).map { abs($0 - $1) }.max()!
            #expect(drift < 0.001, "\(window.letter) at \(instant.t)s")
        }
    }

    @Test func theLoopClosesOnItsFirstFrame() {
        let end = WordmarkScene.windows(at: WordmarkScene.duration - 1e-6)
        let start = WordmarkScene.windows(at: 0)
        #expect(end.map(\.letter) == start.map(\.letter))
        let gap = zip(end, start).flatMap { zip(Self.values($0), Self.values($1)).map { abs($0 - $1) } }.max()!
        #expect(gap < 0.05)
    }

    @Test func aSecondLapPlaysTheFirstAgain() {
        let first = WordmarkScene.windows(at: 1.7)
        let second = WordmarkScene.windows(at: WordmarkScene.duration + 1.7)
        #expect(second.map(\.letter) == first.map(\.letter))
        let drift = zip(second, first).flatMap { zip(Self.values($0), Self.values($1)).map { abs($0 - $1) } }.max()!
        #expect(drift < 1e-9)
    }

    @Test func theEAnchorsTheWord() {
        let rest = WordmarkScene.windows(at: 0).first { $0.letter == .e }!.rect
        for frame in 0..<Int(WordmarkScene.duration * 120) {
            let e = WordmarkScene.windows(at: Double(frame) / 120).first { $0.letter == .e }!
            #expect(e.rect == rest, "frame \(frame)")
        }
    }
}
