import Dispatch
import Foundation
import EmiraConfig
import EmiraCore

// The imperative half of the config file: read it, watch it. What a key means, what the diagnostic
// says, and where the file lives are pure and belong to `EmiraConfig`.
//
// A missing file is not an error — it loads as `Config()`. A broken file changes nothing: falling back
// to defaults on a syntax error would rearrange the whole desktop as the side effect of a typo.

/// Something that says "the config file may have changed". Tests hand-fire it.
@MainActor
public protocol FileWatcher: AnyObject {
    /// Begin watching. `onChange` may fire several times for one logical save; coalescing is the
    /// caller's job.
    func start(_ onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// Why a config file couldn't be loaded, rendered as a `path:line: message` diagnostic an editor's
/// error parser can act on.
public enum ConfigLoadError: Error, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case syntax(path: String, error: ConfigSyntaxError)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason):
            return "\(path): \(reason)"
        case .syntax(let path, let error):
            // `description` opens with "line N: " because `EmiraConfig` doesn't know the file. Here we
            // do, so the line is hoisted into the path prefix and the complaint is asked for on its own.
            return "\(path):\(error.line): \(error.message)"
        }
    }
}

/// Loads `~/.config/emira/emira.toml` and keeps the daemon in step with it.
@MainActor
public final class ConfigLoader {

    public let path: String

    /// Where a load's outcome goes. The daemon dispatches `Event.configChanged` on success and logs
    /// the diagnostic on failure; the loader has no opinion either way.
    public var onLoad: (@MainActor (Result<Config, ConfigLoadError>) -> Void)?

    private let watcher: (any FileWatcher)?
    private let scheduler: any DelayScheduler
    /// How long to wait after a filesystem event before re-reading, so one save is one reload.
    private let coalesce: TimeInterval
    /// `DelayScheduler` has no cancellation, so this flag *is* the coalescing: extra events in the
    /// window are dropped and the one scheduled read sees the file's final state.
    private var reloadPending = false
    /// The last config successfully read — the yardstick for "did this event change anything?".
    private var lastLoaded: Config?

    /// A `nil` `watcher` disables hot reload; `coalesce` is the coalescing window in seconds.
    public init(path: String = Config.defaultPath(),
                watcher: (any FileWatcher)? = nil,
                scheduler: any DelayScheduler,
                coalesce: TimeInterval = 0.08) {
        self.path = path
        self.watcher = watcher
        self.scheduler = scheduler
        self.coalesce = coalesce
    }

    // MARK: - Reading

    /// Read and parse now; a missing file is `.success(Config())`. Called once at boot, before there
    /// is a pump to send events to.
    public func load() -> Result<Config, ConfigLoadError> {
        let result = read()
        if case .success(let config) = result { lastLoaded = config }
        return result
    }

    private func read() -> Result<Config, ConfigLoadError> {
        guard FileManager.default.fileExists(atPath: path) else { return .success(Config()) }
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return .failure(.unreadable(path: path, reason: error.localizedDescription))
        }
        do {
            return .success(try Config.parse(text))
        } catch let error as ConfigSyntaxError {
            return .failure(.syntax(path: path, error: error))
        } catch {
            return .failure(.unreadable(path: path, reason: "\(error)"))
        }
    }

    /// Re-read after a filesystem event — the only thing that ever asks, now that the config file is
    /// the whole interface and there is no `reload-config` verb to ask on a user's behalf.
    ///
    /// A file that parses to the config we already have is **not** reported: *any* activity in the
    /// watched directory wakes us, so unrelated temp files would otherwise reload every few seconds.
    /// Failures are always reported, because a suppressed repeat would make a save that *didn't* fix
    /// the problem look like one that did.
    func reload() {
        let result = read()
        if case .success(let config) = result {
            let unchanged = config == lastLoaded
            lastLoaded = config
            if unchanged { return }
        }
        onLoad?(result)
    }

    // MARK: - Watching

    /// Begin hot reload. A burst of filesystem events collapses into one `reload()` a window later.
    public func start() {
        watcher?.start { [weak self] in self?.fileChanged() }
    }

    public func stop() {
        watcher?.stop()
    }

    private func fileChanged() {
        guard !reloadPending else { return }
        reloadPending = true
        scheduler.schedule(after: coalesce) { [weak self] in
            guard let self else { return }
            self.reloadPending = false
            self.reload()
        }
    }
}

/// Kernel vnode sources on the config file *and* on its directory, because each half of "the file
/// changed" is invisible to the other watch: an atomic save kills the file watch with the inode it
/// held, and an in-place rewrite never touches the directory entry. So the file source is re-armed
/// *by path* whenever its inode is renamed or unlinked. A file that doesn't exist yet is fine.
@MainActor
public final class ConfigWatcher: FileWatcher {

    private let path: String
    private let directory: String
    private var onChange: (@MainActor () -> Void)?
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?

    public init(watching path: String) {
        self.path = path
        self.directory = (path as NSString).deletingLastPathComponent
    }

    /// Whether the containing directory could be opened; `false` means hot reload is off.
    public var isWatching: Bool { directorySource != nil }

    public func start(_ onChange: @escaping @MainActor () -> Void) {
        guard directorySource == nil else { return }
        self.onChange = onChange
        directorySource = source(for: directory, mask: [.write, .rename, .delete]) { [weak self] _ in
            guard let self else { return }
            // The file may have just been created, or replaced by something we aren't holding.
            if self.fileSource == nil { self.armFileSource() }
            self.onChange?()
        }
        armFileSource()
    }

    public func stop() {
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
        onChange = nil
    }

    /// Watch the file at `path` — following the *path*, not the inode, so an atomic save is survived.
    private func armFileSource() {
        fileSource?.cancel()
        fileSource = source(for: path, mask: [.write, .extend, .rename, .delete, .attrib]) { [weak self] events in
            guard let self else { return }
            // A rename or unlink means the inode we hold is no longer what `path` names; re-open it.
            // A plain write keeps the same file, so re-arming there would be churn.
            if events.contains(.rename) || events.contains(.delete) { self.armFileSource() }
            self.onChange?()
        }
    }

    private func source(for path: String, mask: DispatchSource.FileSystemEvent,
                        handler: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void)
    -> DispatchSourceFileSystemObject? {
        // `O_EVTONLY` doesn't count as a reference that would keep an unmounting volume busy.
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak source] in
            let events = source?.data ?? []
            // The main queue *is* the main actor's executor.
            MainActor.assumeIsolated { handler(events) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
