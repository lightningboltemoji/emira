import Foundation
import EmiraCore

// Where the config file lives, and what emira puts in one it creates — facts about the config, not
// about the shell, so they sit beside the grammar rather than with the code that opens the file. The
// CLI and the daemon both need them and share nothing else.

extension Config {
    /// `$EMIRA_CONFIG`, or the XDG-style `~/.config/emira/emira.toml`.
    public static func defaultPath() -> String {
        if let override = ProcessInfo.processInfo.environment["EMIRA_CONFIG"], !override.isEmpty {
            return override
        }
        return NSHomeDirectory() + "/.config/emira/emira.toml"
    }

    /// What a config file emira creates for the user contains, so a fresh one opens onto a sentence
    /// rather than an empty buffer. Deliberately *not* `ConfigSchema.document`: that writes every
    /// setting out at its default, and a file that writes a default down pins it against ever changing.
    public static let starter = """
    # Every setting is at its default until it is written down here — an absent key keeps its default,
    # and a key emira does not know is an error naming its line. `emira config explain` prints the lot:
    # what each setting is, what it may be, and what it is now.

    """
}
