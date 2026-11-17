import EmiraCore

// The layer `override` lays over the config file, for this run of the daemon only. It sits between the
// file's reading and `applyEnvironment`, so a reload keeps it on top of what the file now says; and it
// reads values through the codecs `emira config set` uses, so it refuses them in the same words.

/// Settings laid over the config file, in the order they were laid.
public struct ConfigOverrides {

    /// One setting and the value laid over it.
    public struct Entry {
        public let setting: Setting
        public let value: TOMLValue
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// Each entry as the file would spell it: `focus.unfocused-opacity = 1`.
    public var lines: [String] { entries.map { "\($0.setting.key) = \($0.value.spelled)" } }

    /// Carry out `intent`, and say whether the layer changed — a caller reloads only for something.
    /// - Throws: `ConfigSyntaxError` for a key the schema does not have or a value it refuses — the
    ///   complaint `emira config set` makes, without a line.
    @discardableResult
    public mutating func apply(_ intent: OverrideIntent) throws -> Bool {
        switch intent {
        case .set(let key, let text):
            let (setting, value) = try Self.read(key, text)
            return lay(setting, value)
        case .toggle(let key, let text):
            let (setting, value) = try Self.read(key, text)
            if let index = index(of: key), entries[index].value.spelled == value.spelled {
                entries.remove(at: index)
                return true
            }
            return lay(setting, value)
        case .reset(nil):
            defer { entries.removeAll() }
            return !entries.isEmpty
        case .reset(let key?):
            _ = try Self.setting(key)
            guard let index = index(of: key) else { return false }
            entries.remove(at: index)
            return true
        }
    }

    /// `config` with every entry written over it.
    public func applied(to config: Config) -> Config {
        var config = config
        // Each value went through this setting's codec when it was laid, and a codec's verdict does not
        // depend on the config it writes into — so this cannot refuse.
        for entry in entries { try? entry.setting.apply(entry.value, &config) }
        return config
    }

    /// Whether `intent` names settings and values the schema takes — what a binding and the CLI check
    /// before anything is sent, so a typo is caught where it was typed.
    public static func check(_ intent: OverrideIntent) throws {
        switch intent {
        case .set(let key, let text), .toggle(let key, let text): _ = try read(key, text)
        case .reset(let key?):                                     _ = try setting(key)
        case .reset(nil):                                          break
        }
    }

    private static func read(_ key: String, _ text: String) throws -> (Setting, TOMLValue) {
        let setting = try setting(key)
        return (setting, try setting.value(from: text))
    }

    private static func setting(_ key: String) throws -> Setting {
        guard let setting = ConfigSchema.setting(for: key) else {
            throw ConfigSyntaxError.unknownKey(line: 0, key: key)
        }
        return setting
    }

    private func index(of key: String) -> Int? { entries.firstIndex { $0.setting.key == key } }

    /// Lay `value` over `setting`, in place if the setting already has an entry.
    private mutating func lay(_ setting: Setting, _ value: TOMLValue) -> Bool {
        let entry = Entry(setting: setting, value: value)
        guard let index = index(of: setting.key) else {
            entries.append(entry)
            return true
        }
        guard entries[index].value.spelled != value.spelled else { return false }
        entries[index] = entry
        return true
    }
}
