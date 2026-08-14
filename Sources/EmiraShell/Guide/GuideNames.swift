import AppKit
import Foundation

// The word that stands for an app in the names guide, resolved once per bundle id and kept for the
// daemon's life — `GuideIcons`' cache, for the same two reasons. An app's name does not change while it
// is running, and a bundle id that resolves to nothing is cached *as* nothing, so a window whose app has
// no name on disk costs one lookup rather than one per frame.
//
// The **localized** name, which is what the user calls the app: `NSWorkspace` answers "Safari" where the
// bundle id says `com.apple.Safari`.

/// `bundleId → app name`, resolved once.
@MainActor
public final class GuideNames {

    private var names: [String: String] = [:]

    public init() {}

    /// The name for `bundleId` — its last dotted segment where nothing on disk answers, which is a
    /// worse word than the app's own and a much better one than the whole identifier.
    public func name(for bundleId: String) -> String {
        if let known = names[bundleId] { return known }
        let name = Self.resolve(bundleId) ?? Self.fallback(bundleId)
        names[bundleId] = name
        return name
    }

    /// Drop everything — nothing calls this in the daemon; it is the seam a test needs.
    public func removeAll() { names.removeAll() }

    private static func resolve(_ bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    static func fallback(_ bundleId: String) -> String {
        String(bundleId.split(separator: ".").last ?? Substring(bundleId))
    }
}
