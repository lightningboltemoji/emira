import Foundation
import Testing
import EmiraMotion
@testable import EmiraCore

// TEMPORARY repro harness — delete.
@Suite struct ScrollRepro {

    static let display = Rect(x: 0, y: 0, width: 1800, height: 1169)
    // Five ⅔-width columns (1200 pt) with the user's 8 pt gap → strip 6032 pt ≈ 3.35 monitors.
    static let cfg = Config(widthPresets: PresetCycle([.proportion(2.0 / 3.0)]),
                            columnGap: 8, windowGap: 8,
                            struts: EdgeInsets(top: 39, left: 0, bottom: 0, right: 0))

    static func snap(_ raw: UInt64) -> WindowSnapshot {
        WindowSnapshot(id: WindowId(raw), bundleId: "com.test.app\(raw)", title: "w\(raw)",
                       role: .standard, frame: Rect(x: 0, y: 0, width: 200, height: 200))
    }

    /// Drive a command all the way through the animated lifecycle: captures land, cover raises,
    /// reals teleport, ticks until settled, AX lands, cross-fade.
    static func drive(_ s: inout State, _ command: Command) {
        var fx: [Effect]
        (s, fx) = Engine.reduce(s, .command(command))
        var guardrail = 0
        while s.motion.isTransitioning && guardrail < 2000 {
            guardrail += 1
            var next: [Effect] = []
            for e in fx {
                switch e {
                case .capture(let w):
                    var out: [Effect]; (s, out) = Engine.reduce(s, .captureReady(w)); next += out
                case .setFrame(let w, _), .park(let w, _):
                    var out: [Effect]; (s, out) = Engine.reduce(s, .axLanded(w)); next += out
                default: break
                }
            }
            if next.isEmpty && s.motion.isTransitioning {
                (s, next) = Engine.reduce(s, .tick(dt: 1.0 / 120.0))
            }
            fx = next
        }
    }

    @Test func repro() {
        var s = State(config: Self.cfg)
        (s, _) = Engine.reduce(s, .screensChanged([MonitorInfo(id: MonitorId(1), frame: Self.display)]))
        for i in 1...5 { (s, _) = Engine.reduce(s, .windowCreated(Self.snap(UInt64(i)))) }

        func report(_ label: String) {
            let off = s.motion.viewportOffset.current
            var line = "\(label) focus=\(s.world.focusedWindow.map { "\($0.raw)" } ?? "-") off=\(String(format: "%.0f", off))  "
            for id in s.layout.allWindowIds {
                let f = s.world.windows[id]!.frame        // the TRUTH plane: where the real window is
                line += "[\(id.raw): \(String(format: "%.0f", f.minX))…\(String(format: "%.0f", f.maxX))] "
            }
            print(line)
        }

        report("boot    ")
        for _ in 0..<6 { Self.drive(&s, .focus(.left)) }
        report("far-left")
        for i in 1...4 { Self.drive(&s, .focus(.right)); report("right \(i) ") }
        for i in 1...4 { Self.drive(&s, .focus(.left));  report("left  \(i) ") }
    }
}
