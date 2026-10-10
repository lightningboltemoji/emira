import AppKit

// The core's app-grouping key (`WindowState.bundleId`), minted here and read back here. A bundle
// identifier where the app has one, otherwise its executable's path: a bare binary run out of a build
// directory is an app too, and its path is unique and survives a relaunch. A bundle identifier admits
// no `/`, so the two spellings never collide and the key alone says which one it is.

extension NSRunningApplication {

    /// This app's key in the core — what `app-id` in a window rule matches.
    var appId: String? { bundleIdentifier ?? executableURL?.path }
}

enum AppId {

    /// Where the app `appId` names lives on disk, or `nil` for a bundle LaunchServices cannot find.
    static func location(of appId: String) -> URL? {
        appId.hasPrefix("/") ? URL(fileURLWithPath: appId)
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: appId)
    }
}
