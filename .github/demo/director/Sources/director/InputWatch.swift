import CoreGraphics
import Foundation

/// Watches for input that isn't the director's: a person touching the mouse or keyboard mid-take
/// spoils it, so the take stops there instead of typing into whatever they moved focus to.
enum InputWatch {
    nonisolated(unsafe) private(set) static var interruption: String?

    /// False if the system won't let the director watch input; takes still work, unguarded.
    @discardableResult
    static func start() -> Bool {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .mouseMoved, .leftMouseDragged, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                callback: { _, type, event, _ in
                    if type.rawValue < CGEventType.tapDisabledByTimeout.rawValue,
                       event.getIntegerValueField(.eventSourceUserData) != inputTag, InputWatch.interruption == nil {
                        InputWatch.interruption = "\(type)"
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: nil)
        else { return false }
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "input watch"
        thread.start()
        return true
    }
}

extension CGEventType: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .keyDown: "a key"
        case .flagsChanged: "a modifier key"
        case .scrollWheel: "a scroll"
        case .leftMouseDown, .rightMouseDown: "a click"
        default: "the pointer moving"
        }
    }
}
