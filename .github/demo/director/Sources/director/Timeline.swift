import CoreGraphics
import Foundation

/// What happened in a take, and when, for the studio: the camera keys off its markers and steps, and
/// draws keys from it. Times are seconds into the movie; places are take display points, from the top
/// left.
struct Timeline: Encodable {
    struct Rect: Encodable {
        var x, y, width, height: Double
    }

    struct Size: Encodable {
        var width, height: Double
    }

    struct Marker: Encodable {
        var name: String
        var time: Double
        var rect: Rect
    }

    struct StepTime: Encodable {
        var line: Int
        var command: String
        var start: Double
        var end: Double
    }

    struct KeyPress: Encodable {
        var time: Double
        var keys: String
        /// The emira command the chord is bound to in the take's config, if any.
        var action: String?
    }

    var version = 1
    var tape: String
    var video = "take.mov"
    var display: Size
    /// Movie pixels to a point.
    var scale = 2.0
    /// Seconds into the movie at which the tape's first step starts.
    var start: Double
    var duration: Double
    var markers: [Marker] = []
    var steps: [StepTime] = []
    var keys: [KeyPress] = []

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }
}

extension Timeline.Rect {
    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}
