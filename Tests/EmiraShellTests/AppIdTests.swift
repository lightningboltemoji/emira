import Foundation
import Testing
@testable import EmiraShell

// An app with no bundle is keyed by its executable's path, and everything that reads a key back has to
// find the app from either spelling. Which processes get a key is LaunchServices' answer and is checked
// live, not here.

@Suite @MainActor struct AppIdTests {

    @Test func aPathIsItsOwnLocation() {
        #expect(AppId.location(of: "/usr/bin/true") == URL(fileURLWithPath: "/usr/bin/true"))
    }

    @Test func aBundleIdentifierIsAskedOfLaunchServices() {
        #expect(AppId.location(of: "com.apple.finder")?.lastPathComponent == "Finder.app")
    }

    /// Not the dotted-segment fallback, which would read a build directory's `.build` as a separator.
    @Test func anUnbundledAppIsNamedForItsExecutable() {
        #expect(GuideNames().name(for: "/Users/someone/app/.build/debug/Harness") == "Harness")
    }

    @Test func anUnbundledAppHasAnIcon() {
        #expect(GuideIcons().icon(for: "/usr/bin/true") != nil)
    }
}
