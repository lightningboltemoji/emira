import Foundation
import Testing
import EmiraCore
@testable import EmiraShell

// The shell's half of the config file — the part that needs a disk. The parse itself is tested in
// `EmiraCoreTests/ConfigSyntaxTests`; what is tested here is *policy*, and all three of its rules are
// about what happens when the file isn't what we hoped:
//
//  · a **missing** file is the zero-config strip, not an error;
//  · a **broken** file changes nothing and says why, rather than falling back to defaults and
//    silently rearranging a desktop;
//  · a **saved** file reloads once, however many filesystem events the editor produced.
//
// Real temp files, because a temp directory is a perfectly good fixture (the same judgement
// `SocketServerTests` makes about real sockets). The one thing that *is* faked is the change source:
// a kernel event has no place in a unit test, which is why `FileWatcher` is a protocol.

@Suite @MainActor struct ConfigLoaderTests {

    // MARK: - Fixtures

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

    // MARK: - Reading

    /// emira must run before it is configured. The first launch of a window manager is not the moment
    /// to demand a file the user hasn't written.
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

    /// The diagnostic is `path:line: message` — the shape an editor's error parser and a human both
    /// already know how to read. The core's own wording opens with "line N: " because it has no idea
    /// what file it is reading; here we do, so the line moves into the prefix.
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

    // MARK: - Reporting

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

    /// The rule that keeps a typo from rearranging a desktop: a failed reload reports an error and
    /// **no config at all**, so the daemon has nothing to dispatch and the running settings stand.
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

    // MARK: - Watching

    /// One save is several filesystem events (a temp file appears, then a rename over the target).
    /// Acting on each would re-place every window several times over, so a burst collapses into one
    /// read — and that read sees the file's *final* state.
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

    /// Deleting the config file is a legitimate way to go back to the defaults, and it must not read
    /// as an error — it is the missing-file rule arriving through the watcher.
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

    /// Watching a *directory* is the only way to see an atomic save, and the price is that unrelated
    /// activity in that directory wakes us too — observed in a hand smoke with the config under
    /// `$TMPDIR`, where a reload fired every few seconds with nobody editing anything. The filter is
    /// the parsed value, not the file: the file changing is a guess, the config changing is a fact.
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

    /// The user asking is not the filesystem guessing: an explicit `reload-config` always answers,
    /// because a reload that reports nothing is indistinguishable from one that didn't happen.
    @Test func anExplicitReloadReportsEvenWhenNothingChanged() {
        let scratch = Scratch()
        scratch.write("[layout]\ncolumn-gap = 5\n")
        let loader = Self.loader(scratch)
        let reports = Reports()
        reports.attach(to: loader)
        _ = loader.load()

        loader.reload()
        loader.reload()
        #expect(reports.configs.map(\.columnGap) == [5, 5])
    }

    @Test func stoppingTearsTheWatchDown() {
        let scratch = Scratch()
        let watcher = ManualWatcher()
        let loader = Self.loader(scratch, watcher: watcher)
        loader.start()
        loader.stop()
        #expect(watcher.isStopped)
    }

    /// A loader with no watcher is hot reload turned off, not a crash: the daemon still reads the
    /// file at boot and on `reload-config`.
    @Test func aLoaderWithoutAWatcherStillReloadsOnDemand() {
        let scratch = Scratch()
        scratch.write("[layout]\ncolumn-gap = 6\n")
        let loader = Self.loader(scratch)
        let reports = Reports()
        reports.attach(to: loader)
        loader.start()                                        // no watcher: nothing to start
        loader.reload()
        #expect(reports.configs.map(\.columnGap) == [6])
    }

    // MARK: - The effect that reaches it

    /// `Effect.reloadConfig` is routed to the config plane, not to AX and not to the compositor —
    /// the property that lets a keybinding (M5 part 2) reload the file without touching the socket.
    @Test func theReloadEffectReachesTheConfigSourceAndNothingElse() {
        final class CountingSource: ConfigSource {
            private(set) var reloads = 0
            func reload() { reloads += 1 }
        }
        let source = CountingSource()
        let timeline = CompositingExecutorTests.Timeline()
        let truth = CompositingExecutorTests.RecordingTruth(timeline)
        let executor = CompositingExecutor(surface: CompositingExecutorTests.RecordingSurface(timeline),
                                           store: CompositingExecutorTests.RecordingStore(timeline),
                                           truth: truth,
                                           config: source)

        executor.execute([.reloadConfig], feedback: EventSink { _ in })
        #expect(source.reloads == 1)
        #expect(truth.batches.isEmpty)
        // Not a presentation run either: a reload opens no frame (`beginFrame`/`endFrame`).
        #expect(timeline.entries.isEmpty)
    }

    /// A run of reloads is one reload: the file can only be in one state, and re-reading it twice in
    /// a batch would send the core two identical `configChanged` events.
    @Test func aRunOfReloadsInOneBatchReadsTheFileOnce() {
        final class CountingSource: ConfigSource {
            private(set) var reloads = 0
            func reload() { reloads += 1 }
        }
        let source = CountingSource()
        let timeline = CompositingExecutorTests.Timeline()
        let executor = CompositingExecutor(surface: CompositingExecutorTests.RecordingSurface(timeline),
                                           store: CompositingExecutorTests.RecordingStore(timeline),
                                           truth: CompositingExecutorTests.RecordingTruth(timeline),
                                           config: source)
        executor.execute([.reloadConfig, .reloadConfig, .reloadConfig], feedback: EventSink { _ in })
        #expect(source.reloads == 1)
    }
}
