import Dispatch
import Foundation
import EmiraCore

// The imperative half of the config file: **find it, read it, watch it**. The half with the decisions
// in it — what a key means, what a legal value is, what the diagnostic says — is pure and lives in
// `EmiraCore/ConfigSyntax.swift`, so this file holds only what genuinely needs a disk.
//
// **Three behaviours are policy, and each is a decision worth naming.**
//
//  1. **A missing file is not an error.** It loads as `Config()` — the same zero-config strip an empty
//     file gives. emira must run before it is configured; the first launch of a window manager is not
//     the moment to demand a file the user hasn't written yet.
//  2. **A broken file changes nothing.** A parse failure leaves the running config exactly as it was
//     and reports a diagnostic; no event reaches the core. The alternative — falling back to defaults
//     on a syntax error — would rearrange the user's whole desktop as the side effect of a typo, at
//     the exact moment they're editing the file and least able to tell why.
//  3. **The watch is on the file *and* its directory.** An editor saving atomically (temp file +
//     `rename(2)`) is a directory event that kills a file-level watch with the inode it held; a
//     shell redirect rewriting the same inode is a file event the directory never sees. Watching one
//     and not the other means hot reload works for some ways of editing a file and silently not for
//     others — see `ConfigWatcher` for how both are held.
//
// **The seam is the watcher, not the read.** `FileWatcher` is a protocol for the same reason
// `FrameClock`, `CoverSurface` and `WindowSource` are: the untestable surface (a kernel event source)
// is two methods wide, while the policy around it — coalescing, the missing-file rule, the
// keep-the-old-config-on-error rule — is tested against a real temp file and a hand-driven watcher.
// Reading the file itself needs no seam; a temp directory is a perfectly good test fixture, the same
// judgement `SocketServerTests` makes about real sockets.

/// What `Effect.reloadConfig` reaches — narrowed to the one thing the effect asks for, so the
/// executor's routing doesn't have to know what a config *is*.
@MainActor
public protocol ConfigSource: AnyObject {
    /// Re-read the file and report the outcome (a `configChanged` event, or a diagnostic).
    func reload()
}

/// Something that says "the config file may have changed". One implementation watches a directory;
/// tests hand-fire it.
@MainActor
public protocol FileWatcher: AnyObject {
    /// Begin watching. `onChange` may fire several times for one logical save — coalescing is the
    /// caller's job, because only the caller knows what it costs to act on one.
    func start(_ onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// Why a config file couldn't be loaded — a read failure or a parse failure, both rendered as a
/// `path:line: message` diagnostic a human (and an editor's error parser) can act on.
public enum ConfigLoadError: Error, CustomStringConvertible {
    /// The file exists but could not be read (permissions, a directory in its place, bad encoding).
    case unreadable(path: String, reason: String)
    /// The file was read and isn't valid (`ConfigSyntaxError` already knows the line).
    case syntax(path: String, error: ConfigSyntaxError)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason):
            return "\(path): \(reason)"
        case .syntax(let path, let error):
            return "\(path):\(error.line): \(Self.message(of: error))"
        }
    }

    /// `ConfigSyntaxError.description` opens with "line N: " because the core has no idea what file it
    /// is reading. Here we do, so the line is hoisted into the path prefix and this drops it.
    private static func message(of error: ConfigSyntaxError) -> String {
        let text = error.description
        guard let colon = text.firstIndex(of: ":"), text.hasPrefix("line ") else { return text }
        return String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }
}

/// Loads `~/.config/emira/emira.toml` and keeps the daemon in step with it.
@MainActor
public final class ConfigLoader: ConfigSource {

    /// The file this loader reads.
    public let path: String

    /// Where a load's outcome goes. The daemon sets this to "dispatch `Event.configChanged` on
    /// success, log the diagnostic on failure" — the loader itself has no opinion about either,
    /// which is what keeps the `Event` vocabulary out of a file about the filesystem.
    public var onLoad: (@MainActor (Result<Config, ConfigLoadError>) -> Void)?

    private let watcher: (any FileWatcher)?
    private let scheduler: any DelayScheduler
    /// How long to wait after a filesystem event before re-reading, so one save is one reload.
    private let coalesce: TimeInterval
    /// Whether a coalesced reload is already scheduled. The `DelayScheduler` contract has no
    /// cancellation, so a pending flag *is* the coalescing mechanism: extra events during the window
    /// are dropped, and the one scheduled read sees the final state of the file.
    private var reloadPending = false
    /// The last config successfully read off disk — the yardstick for "did this event change
    /// anything?". See `reload(suppressingUnchanged:)`.
    private var lastLoaded: Config?

    /// - Parameters:
    ///   - path: the config file. Defaults to `EMIRA_CONFIG`, else `~/.config/emira/emira.toml`.
    ///   - watcher: the change source; `nil` disables hot reload (the file is then read at boot and
    ///     on an explicit `reload-config` only).
    ///   - scheduler: the delay source used to coalesce a burst of filesystem events.
    ///   - coalesce: the coalescing window in seconds.
    public init(path: String = ConfigLoader.defaultPath(),
                watcher: (any FileWatcher)? = nil,
                scheduler: any DelayScheduler,
                coalesce: TimeInterval = 0.08) {
        self.path = path
        self.watcher = watcher
        self.scheduler = scheduler
        self.coalesce = coalesce
    }

    /// `$EMIRA_CONFIG`, or `~/.config/emira/emira.toml` — the conventional XDG-style location, and
    /// the one the daemon prints at boot. The override exists for the same reason
    /// `EMIRA_SOCKET` does: a hand smoke test must be able to run against a scratch file without
    /// touching the config the machine is actually using.
    public static func defaultPath() -> String {
        if let override = ProcessInfo.processInfo.environment["EMIRA_CONFIG"], !override.isEmpty {
            return override
        }
        return NSHomeDirectory() + "/.config/emira/emira.toml"
    }

    // MARK: - Reading

    /// Read and parse the file **now**. A missing file is `.success(Config())` — see decision 1 in the
    /// file header. The daemon calls this once at boot, before there is a pump to send events to.
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

    /// Re-read the file and report the outcome through `onLoad` — `Effect.reloadConfig`, i.e. the
    /// user asking. It reports even when nothing changed, because a reload that answers with silence
    /// is indistinguishable from one that didn't happen.
    public func reload() {
        reload(suppressingUnchanged: false)
    }

    /// - Parameter suppressingUnchanged: when `true`, a file that parses to the config we already
    ///   have is not reported at all.
    ///
    /// **This is what a directory watch costs, and it was measured rather than predicted.** Watching
    /// the directory (the only way to see an atomic save, per the file header) means *any* activity in
    /// it wakes us — with the config under `$TMPDIR` during a hand smoke, unrelated temp files
    /// produced a reload every few seconds. Each was harmless (the reducer re-places nothing that is
    /// already in place) and each was still a file read, a `configChanged` through the pump and a line
    /// in the log claiming something happened. Comparing the parsed value is the honest filter: the
    /// *file* changing is a guess, the *config* changing is the fact. It also covers the everyday case
    /// of saving a file after editing only a comment.
    ///
    /// Failures are always reported. A diagnostic repeating while the user fixes their typo is noise
    /// they are already looking at, and suppressing it would mean a save that *didn't* fix the problem
    /// looked like one that did.
    private func reload(suppressingUnchanged: Bool) {
        let result = read()
        if case .success(let config) = result {
            let unchanged = config == lastLoaded
            lastLoaded = config
            if suppressingUnchanged && unchanged { return }
        }
        onLoad?(result)
    }

    // MARK: - Watching

    /// Begin hot reload. Every burst of filesystem events collapses into a single `reload()` a
    /// coalescing window later.
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
            self.reload(suppressingUnchanged: true)
        }
    }
}

/// The real watcher: kernel vnode sources on the config file **and** on its containing directory.
///
/// **Both, because the two halves of "the file changed" are different events, and each is invisible
/// to the other watch.** This was learned the hard way in the M5 hand smoke, where one editing
/// gesture reloaded and the next was ignored entirely:
///
///  · An **atomic save** — write a temp file, `rename(2)` it over the target — is a *directory*
///    change. The file watch dies with the inode it was holding, so watching only the file sees the
///    first save and nothing after it. This is what most editors do.
///  · An **in-place rewrite** — a shell redirect, `vim` with `backupcopy=yes`, anything that
///    truncates and writes the same inode — never touches the directory entry, so watching only the
///    directory never fires at all.
///
/// So: the directory catches creation, deletion and replacement; the file catches ordinary writes;
/// and the file source is **re-armed by path** whenever its inode is renamed or unlinked, which is
/// what keeps the watch alive across an atomic save. A config file that doesn't exist yet is fine —
/// the directory watch picks it up the moment it is created.
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

    /// Whether the containing directory could be opened. `false` means hot reload is off — the
    /// daemon says so at boot rather than pretending to watch.
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
            // A plain write keeps the same file, so re-arming there would be churn for nothing.
            if events.contains(.rename) || events.contains(.delete) { self.armFileSource() }
            self.onChange?()
        }
    }

    private func source(for path: String, mask: DispatchSource.FileSystemEvent,
                        handler: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void)
    -> DispatchSourceFileSystemObject? {
        // `O_EVTONLY` opens for event delivery only — it doesn't count as a reference that would keep
        // an unmounting volume busy.
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak source] in
            let events = source?.data ?? []
            // The main queue *is* the main actor's executor (same assertion `DispatchScheduler` makes).
            MainActor.assumeIsolated { handler(events) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
