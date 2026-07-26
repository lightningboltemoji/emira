import Testing
@testable import EmiraMotion

/// Fixed-duration easing curves (for fades, not interruptible motion).
@Suite struct EasingTests {
    static let all: [Easing] = [.linear, .easeIn, .easeOut, .easeInOut]

    @Test(arguments: all)
    func mapsEndpoints(_ curve: Easing) {
        #expect(abs(curve(0) - 0) < 1e-9)
        #expect(abs(curve(1) - 1) < 1e-9)
    }

    @Test(arguments: all)
    func clampsOutOfRange(_ curve: Easing) {
        #expect(curve(-1) == curve(0))
        #expect(curve(2) == curve(1))
    }

    @Test func easeInOutIsSymmetricAtMidpoint() {
        #expect(Easing.easeInOut(0.5) == 0.5)
    }

    @Test func monotonicNonDecreasing() {
        for curve in Self.all {
            var previous = curve(0)
            for i in 1...100 {
                let value = curve(Double(i) / 100)
                #expect(value >= previous - 1e-12)
                previous = value
            }
        }
    }
}
