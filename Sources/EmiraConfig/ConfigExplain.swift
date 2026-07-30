import EmiraCore

// The schema as an explanation: what a setting is, what it may be, and what it is now. `emira config
// explain` prints it, and it is generated the same way the example file is — from the table, so a
// setting cannot be described here in terms that have stopped being true of the reader.
//
// Text rather than a view, which is the point of it going first: a schema that can drive a page of
// prose isn't secretly GUI-shaped, and a mistake in the table shows up somewhere with no AppKit in
// the way.

extension ConfigSchema {

    /// Every setting and what `config` makes of it, grouped under the `[table]`s the file writes them
    /// under — so the listing reads like the file it describes.
    public static func summary(of config: Config) -> String {
        let width = settings.map(\.name.count).max() ?? 0
        var lines: [String] = []
        var table: String?
        for setting in settings {
            if setting.table != table {
                table = setting.table
                if !lines.isEmpty { lines.append("") }
                lines.append("[\(setting.table)]")
            }
            let padding = String(repeating: " ", count: width - setting.name.count + 2)
            lines.append("  \(setting.name)\(padding)\(setting.value(in: config).spelled)")
        }
        return lines.joined(separator: "\n")
    }
}

extension Setting {

    /// This setting in full: its name in prose, its sentence, what it may be, what it is when nothing
    /// says otherwise, and what it is now.
    public func explanation(in config: Config) -> String {
        var lines = ["\(key) — \(label)", "  \(help)"]
        if let legend = kind.legend { lines.append("  \(legend)") }
        lines.append("")
        lines.append("  default  \(defaultValue.spelled)")
        lines.append("  current  \(value(in: config).spelled)")
        return lines.joined(separator: "\n")
    }
}
