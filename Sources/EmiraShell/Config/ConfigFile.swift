import AppKit
import Foundation
import EmiraConfig
import EmiraCore

// Opening the config file — the third thing the shell does with it, beside reading and watching.
//
// There is no editor to configure and no `$EDITOR` to consult: a daemon launched by launchd doesn't
// have one, and macOS types `.toml` as `public.toml`, which conforms to plain text. So LaunchServices
// always has an answer — whatever the user opens TOML with, and TextEdit when they've never said.

/// The config file as something to hand to the user's editor.
public enum ConfigFile {

    /// Open it, creating it first if it isn't there. Throws only what the disk throws.
    @MainActor
    public static func open(at path: String) throws {
        try create(at: path)
        let url = URL(fileURLWithPath: path)
        // `false` is LaunchServices finding nothing that opens the file. Finder always can, and
        // 'Open With' is one right-click from there — better than a menu item that does nothing.
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Create the file, and the directory holding it, unless they are already there. A file that
    /// exists is left exactly as it is — including one emira can't parse, which is the file most
    /// worth opening.
    ///
    /// A missing file has no handler and `NSWorkspace.open` would simply return `false`, so this is
    /// what makes the item work on a machine that has never had a config: emira runs perfectly well
    /// without the file, which is why it can be absent at the moment someone asks to edit it.
    static func create(at path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        try Data(Config.starter.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
