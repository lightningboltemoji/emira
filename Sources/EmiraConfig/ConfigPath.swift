import Foundation
import EmiraCore

// Where the config file lives — a fact about the config, not about the shell, so it sits beside the
// grammar rather than with the code that opens the file. The CLI and the daemon both need it and
// share nothing else.

extension Config {
    /// `$EMIRA_CONFIG`, or the XDG-style `~/.config/emira/emira.toml`.
    public static func defaultPath() -> String {
        if let override = ProcessInfo.processInfo.environment["EMIRA_CONFIG"], !override.isEmpty {
            return override
        }
        return NSHomeDirectory() + "/.config/emira/emira.toml"
    }
}
