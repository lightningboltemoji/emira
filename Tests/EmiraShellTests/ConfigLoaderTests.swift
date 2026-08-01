import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The shell's half of the config file — the part that needs a disk; the parse itself is tested in
// `EmiraCoreTests`. The policy: a missing file is the zero-config strip, not an error; a broken file
// changes nothing and says why; a saved file reloads once however many filesystem events the editor
// produced. Real temp files, because a temp directory is a perfectly good fixture. The change source
// is faked — a kernel event has no place in a unit test, which is why `FileWatcher` is a protocol.

@Suite @MainActor struct ConfigLoaderTests {

    /// A `FileWatcher` a test fires by hand.
    final class ManualWatcher: FileWatcher {
        private var onChange: (@MainActor () -> Void)?
        private(set) var isStopped = false

        func start(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
        func stop() { isStopped = true; onChange = nil }
        /// Model one filesystem event.
        func fire() { onChange?() }
    }

    /// A `DelayScheduler` whose work runs only when a test says so.
    final class ManualScheduler: DelayScheduler {
        private var work: [(TimeInterval, @MainActor () -> Void)] = []
        var scheduledDelays: [TimeInterval] { work.map(\.0) }

        func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            self.work.append((seconds, work))
        }

        func fire() {
            let due = work
            work.removeAll()
            for (_, item) in due { item() }
        }
    }

    /// A scratch directory that cleans itself up, so a test can write, rewrite and delete a real file.
    final class Scratch {
        let directory: URL
        var path: String { directory.appendingPathComponent("emira.toml").path }

        init() {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("emira-config-tests-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func write(_ text: String) {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(atPath: path) }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    static func loader(_ scratch: Scratch, watcher: ManualWatcher? = nil,
                       scheduler: ManualScheduler = ManualScheduler()) -> ConfigLoader {
        ConfigLoader(path: scratch.path, watcher: watcher, scheduler: scheduler)
    }

    /// The outcomes a loader reported, in order.
    @MainActor final class Reports {
        private(set) var configs: [Config] = []
        private(set) var errors: [String] = []
        var count: Int { configs.count + errors.count }

        func attach(to loader: ConfigLoader) {
            loader.onLoad = { [self] result in
                switch result {
                case .success(let config): configs.append(config)
                case .failure(let error):  errors.append(error.description)
                }
            }
        }
    }

    /// emira must run before it is configured.
    @Test func aMissingFileIsTheDefaultConfigAndNotAnError() throws {
        let scratch = Scratch()
        let result = Self.loader(scratch).load()
        #expect(try result.get() == Config())
    }

    @Test func aRealFileIsReadAndParsed() throws {
        let scratch = Scratch()
        scratch.write("[layout]\ncolumn-gap = 14\n")
        #expect(try Self.loader(scratch).load().get().columnGap == 14)
    }

    /// The diagnostic is `path:line: message`, the shape an editor's error parser reads. The core's
    /// own wording opens with "line N: " since it doesn't know the file; here the line moves up front.
    @Test func aBrokenFileReportsThePathAndTheLine() {
        let scratch = Scratch()
        scratch.write("[layout]\ncolumn-gap = 8\ncolum-gap = 4\n")
        guard case .failure(let error) = Self.loader(scratch).load() else {
            Issue.record("expected a diagnostic")
            return
        }
        #expect(error.description == "\(scratch.path):3: unknown setting 'layout.colum-gap'")
    }

    @Test func aFileThatCannotBeReadIsADiagnosticRatherThanACrash() {
        let scratch = Scratch()
        // A directory where the config should be: exists, so the missing-file path doesn't fire, and
        // unreadable, so the parse never starts.
        try? FileManager.default.createDirectory(atPath: scratch.path, withIntermediateDirectories: true)
        guard case .failure(let error) = Self.loader(scratch).load() else {
            Issue.record("expected a diagnostic")
            return
        }
        #expect(error.description.hasPrefix(scratch.path))
    }

    @Test func reloadReportsThroughOnLoad() {
        let scratch = Scratch()
        scratch.write("[layout]\ncolumn-gap = 3\n")
        let loader = Self.loader(scratch)
        let reports = Reports()
        reports.attach(to: loader)

        loader.reload()
        #expect(reports.configs.map(\.columnGap) == [3])

        scratch.write("[layout]\ncolumn-gap = 9\n")
        loader.reload()
        #expect(reports.configs.map(\.columnGap) == [3, 9])
    }

    /// A failed reload reports an error and no config at all, so the daemon has nothing to dispatch
    /// and the running settings stand.
    @Test func aBrokenReloadReportsNoConfigSoTheRunningOneStands() {
        let scratch = Scratch()
        scratch.write("[layout]\ncolumn-gap = 3\n")
        let loader = Self.loader(scratch)
        let reports = Reports()
        reports.attach(to: loader)
        loader.reload()

        scratch.write("[layout]\ncolumn-gap = oops\n")
        loader.reload()
        #expect(reports.configs.map(\.columnGap) == [3])     // still just the good one
        #expect(reports.errors.count == 1)
    }

    /// One save is several filesystem events (a temp file, then a rename over the target), so a burst
    /// collapses into one read of the file's final state rather than re-placing every window twice.
    @Test func aBurstOfFilesystemEventsIsOneReload() {
        let scratch = Scratch()
        scratch.write("[layout]\ncolumn-gap = 1\n")
        let watcher = ManualWatcher()
        let scheduler = ManualScheduler()
        let loader = Self.loader(scratch, watcher: watcher, scheduler: scheduler)
        let reports = Reports()
        reports.attach(to: loader)
        loader.start()

        watcher.fire()
        watcher.fire()
        watcher.fire()
        #expect(reports.count == 0)                          // nothing has been read yet
        #expect(scheduler.scheduledDelays.count == 1)         // and only one read is pending

        scratch.write("[layout]\ncolumn-gap = 7\n")           // the editor's last write wins
        scheduler.fire()
        #expect(reports.configs.map(\.columnGap) == [7])
    }

    /// After the window closes, the *next* save schedules its own read — the pending flag is a
    /// coalescing window, not a one-shot.
    @Test func aLaterSaveReloadsAgain() {
        let scratch = Scratch()
        scratch.write("[layout]\ncolumn-gap = 1\n")
        let watcher = ManualWatcher()
        let scheduler = ManualScheduler()
        let loader = Self.loader(scratch, watcher: watcher, scheduler: scheduler)
        let reports = Reports()
        reports.attach(to: loader)
        loader.start()

        watcher.fire()
        scheduler.fire()
        scratch.write("[layout]\ncolumn-gap = 2\n")
        watcher.fire()
        scheduler.fire()
        #expect(reports.configs.map(\.columnGap) == [1, 2])
    }

    /// Deleting the config file is the missing-file rule arriving through the watcher, not an error.
    @Test func deletingTheFileReloadsTheDefaults() {
        let scratch = Scratch()
        scratch.write("[layout]\ncolumn-gap = 5\n")
        let watcher = ManualWatcher()
        let scheduler = ManualScheduler()
        let loader = Self.loader(scratch, watcher: watcher, scheduler: scheduler)
        let reports = Reports()
        reports.attach(to: loader)
        loader.start()

        scratch.remove()
        watcher.fire()
        scheduler.fire()
        #expect(reports.errors.isEmpty)
        #expect(reports.configs == [Config()])
    }

    /// Watching a directory is the only way to see an atomic save, and the price is that unrelated
    /// activity in it wakes us too. So the filter is the parsed value, not the file: the file
    /// changing is a guess, the config changing is a fact.
    @Test func aFilesystemEventThatChangedNothingIsNotReported() {
        let scratch = Scratch()
        scratch.write("[layout]\ncolumn-gap = 5\n")
        let watcher = ManualWatcher()
        let scheduler = ManualScheduler()
        let loader = Self.loader(scratch, watcher: watcher, scheduler: scheduler)
        let reports = Reports()
        reports.attach(to: loader)
        _ = loader.load()                                     // boot read, as the daemon does
        loader.start()

        watcher.fire()                                        // some other file in the directory
        scheduler.fire()
        #expect(reports.count == 0)

        scratch.write("[layout]\ncolumn-gap = 5   # only a comment changed\n")
        watcher.fire()
        scheduler.fire()
        #expect(reports.count == 0)                           // same config, different bytes

        scratch.write("[layout]\ncolumn-gap = 9\n")
        watcher.fire()
        scheduler.fire()
        #expect(reports.configs.map(\.columnGap) == [9])
    }

    /// The daemon manages nothing until a parse succeeds, so the *first* success after a failed boot
    /// read has to reach it — including when what finally parses is the default config. `lastLoaded`
    /// is the suppression yardstick and a failed boot never sets it, which is what makes this hold.
    @Test func theFirstParseAfterAFailedBootIsReportedEvenWhenItIsTheDefault() {
        let scratch = Scratch()
        scratch.write("[layout]\ncolum-gap = 4\n")
        let watcher = ManualWatcher()
        let scheduler = ManualScheduler()
        let loader = Self.loader(scratch, watcher: watcher, scheduler: scheduler)
        let reports = Reports()
        guard case .failure = loader.load() else { return #expect(Bool(false)) }
        reports.attach(to: loader)
        loader.start()

        scratch.write("# fixed, and back to saying nothing at all\n")
        watcher.fire()
        scheduler.fire()
        #expect(reports.configs == [Config()])
    }

    @Test func stoppingTearsTheWatchDown() {
        let scratch = Scratch()
        let watcher = ManualWatcher()
        let loader = Self.loader(scratch, watcher: watcher)
        loader.start()
        loader.stop()
        #expect(watcher.isStopped)
    }

    /// A loader with no watcher is hot reload turned off, not a crash: the daemon still reads the file
    /// at boot. Without a watcher nothing ever asks it again, which is the whole of the degradation.
    @Test func aLoaderWithoutAWatcherStillReadsTheFileAtBoot() {
        let scratch = Scratch()
        scratch.write("[layout]\ncolumn-gap = 6\n")
        let loader = Self.loader(scratch)
        loader.start()                                        // no watcher: nothing to start
        guard case .success(let config) = loader.load() else { return #expect(Bool(false)) }
        #expect(config.columnGap == 6)
    }

    //
    // Handing the file to an editor is a `NSWorkspace.open` that a unit test must not make. What is
    // testable — and what the menu item actually needs — is that there is a file there to open.

    @Test func openingAFileThatIsntThereCreatesIt() throws {
        let scratch = Scratch()
        scratch.remove()
        try ConfigFile.create(at: scratch.path)
        let text = try String(contentsOfFile: scratch.path, encoding: .utf8)
        #expect(text == Config.starter)
        // The file emira creates has to be one emira reads, and it has to mean what no file meant.
        #expect(try Config.parse(text) == Config())
    }

    @Test func aFileThatIsntThereBecauseItsDirectoryIsntEither() throws {
        let scratch = Scratch()
        let nested = scratch.directory.appendingPathComponent("nested/deeper/emira.toml").path
        try ConfigFile.create(at: nested)
        #expect(FileManager.default.fileExists(atPath: nested))
    }

    /// Including a broken one, which is the file most worth opening: creation must never be a write
    /// over work the user is in the middle of.
    @Test func anExistingFileIsLeftExactlyAsItIs() throws {
        let scratch = Scratch()
        scratch.write("[layout]\ncolum-gap = ")
        try ConfigFile.create(at: scratch.path)
        #expect(try String(contentsOfFile: scratch.path, encoding: .utf8) == "[layout]\ncolum-gap = ")
    }

    /// The file appearing is a filesystem event like any other, and it parses to what the absent file
    /// already meant — so a running daemon reloads nothing when the menu item creates one.
    @Test func creatingTheFileIsNotAReload() throws {
        let scratch = Scratch()
        scratch.remove()
        let watcher = ManualWatcher()
        let scheduler = ManualScheduler()
        let loader = Self.loader(scratch, watcher: watcher, scheduler: scheduler)
        let reports = Reports()
        _ = loader.load()
        reports.attach(to: loader)
        loader.start()

        try ConfigFile.create(at: scratch.path)
        watcher.fire()
        scheduler.fire()
        #expect(reports.count == 0)
    }
}
