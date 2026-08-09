import AppKit
import Testing
@testable import EmiraSettings

// `PRINCIPLES.md` §4's absolute, at the two doors it is spent on: a scrim covers every display, so a
// dismissal that quietly does nothing is not a lost click but a desktop nobody can reach.
//
// What is checked is the *last* line of it — Escape and the double click with no controller to ask.
// `SettingsWindow.presented` makes that unreachable; this is the answer if it ever is.

@Suite(.serialized) @MainActor struct DismissalTests {

    /// A scrim on the screen but not on the eye — `isVisible` is about being ordered in, so a zero alpha
    /// leaves the property under test true and the test invisible to whoever is running it.
    static func scrim(controller: (@MainActor () -> Bool)? = nil) -> (ScrimWindow, ScrimView) {
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let window = ScrimWindow(contentRect: frame, styleMask: .borderless,
                                 backing: .buffered, defer: false)
        window.alphaValue = 0
        window.onCancel = controller
        let dim = ScrimView(frame: frame)
        dim.onDismiss = controller
        window.contentView = dim
        window.orderFront(nil)
        return (window, dim)
    }

    static func press(_ clicks: Int) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 20, y: 20), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    // The dim

    @Test func aSingleClickOnTheDimIsNotADismissal() {
        var asked = 0
        let (window, dim) = Self.scrim { asked += 1; return true }
        defer { window.orderOut(nil) }

        dim.mouseDown(with: Self.press(1))
        #expect(asked == 0)
        dim.mouseDown(with: Self.press(2))
        #expect(asked == 1)
    }

    /// Every press past the second is another dismissal — a quadruple click is three of them — which is
    /// why `SettingsWindow` guards `close()` rather than assuming it is asked once.
    @Test func everyPressPastTheSecondAsksAgain() {
        var asked = 0
        let (window, dim) = Self.scrim { asked += 1; return true }
        defer { window.orderOut(nil) }

        for clicks in 2...4 { dim.mouseDown(with: Self.press(clicks)) }
        #expect(asked == 3)
    }

    @Test func aControllerThatAnswersKeepsTheWindowOnScreen() {
        // The teardown is the controller's: it has a lift to animate and a caller to tell, so a scrim
        // that ordered itself out here would cut both.
        let (window, dim) = Self.scrim { true }
        defer { window.orderOut(nil) }

        dim.mouseDown(with: Self.press(2))
        #expect(window.isVisible)
    }

    @Test func aDimWithNobodyToAskTakesTheScrimsDown() {
        let (window, dim) = Self.scrim(controller: nil)
        defer { window.orderOut(nil) }

        dim.mouseDown(with: Self.press(2))
        #expect(!window.isVisible)
    }

    // Escape

    @Test func escapeWithNobodyToAskTakesTheScrimsDown() {
        let (window, _) = Self.scrim(controller: nil)
        defer { window.orderOut(nil) }

        window.cancelOperation(nil)
        #expect(!window.isVisible)
    }

    @Test func escapeReachesTheControllerWhenThereIsOne() {
        var asked = 0
        let (window, _) = Self.scrim { asked += 1; return true }
        defer { window.orderOut(nil) }

        window.cancelOperation(nil)
        #expect(asked == 1)
        #expect(window.isVisible)
    }

    // The sweep

    /// The scrims are one thing to the user. Clearing the display they happened to press on and leaving
    /// the others dim is a half-answer to "get this off my screen", and on the display that keeps its
    /// scrim there is nothing left to press.
    @Test func anOrphanedDismissalClearsEveryDisplay() {
        let (host, dim) = Self.scrim(controller: nil)
        let (second, _) = Self.scrim(controller: nil)
        defer { for window in [host, second] { window.orderOut(nil) } }

        #expect(second.isVisible)
        dim.mouseDown(with: Self.press(2))
        #expect(!host.isVisible)
        #expect(!second.isVisible)
    }

    // Only the host takes the keyboard

    @Test func onlyTheDisplayWithTheControlsTakesTheKeyboard() {
        // A borderless window answers `false` by default and the symptom of forgetting is a control
        // that silently ignores a keystroke; a key window on a display with no controls on it is the
        // same mistake pointing the other way.
        let (host, _) = Self.scrim(controller: nil)
        let (second, _) = Self.scrim(controller: nil)
        defer { for window in [host, second] { window.orderOut(nil) } }
        host.takesKey = true

        #expect(host.canBecomeKey)
        #expect(host.canBecomeMain)
        #expect(!second.canBecomeKey)
        #expect(!second.canBecomeMain)
    }
}
