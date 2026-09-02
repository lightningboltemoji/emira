import Darwin
import Foundation
import QuartzCore
import Synchronization

// Attributing a main-thread stall to the code holding it, which is the one question the frame counter
// cannot answer: a transition that lost ten frames says only that the clock stopped being asked.
//
// A background thread watches a heartbeat the main run loop writes. When it goes stale while the loop
// is *not* parked in `beforeWaiting`, the main thread is inside something synchronous, and the watchdog
// signals it to photograph its own stack. Three properties make that the right shape:
//
//  · **Idle until a stall.** `/usr/bin/sample` at 1 ms hides the stalls this was built for — it keeps
//    the process warm enough that they stop happening — so the instrument has to cost nothing until
//    one starts.
//  · **`beforeWaiting` is not a stall.** A parked run loop has a stale heartbeat and is perfectly
//    healthy; without the activity the probe would report every idle moment.
//  · **The stack, not the duration.** A two-heartbeat probe separates a blocked thread from a late
//    display link and stops there. The frames are what name the caller.
//
// Off by default and installed only by `EMIRA_STALL_PROBE=<ms>`: nothing is allocated, no thread runs
// and no signal handler exists until something asks.

private let maxFrames = 128
private let maxShots = 12

private nonisolated(unsafe) let shotBuffer =
    UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxFrames)
private let shotDepth = Atomic<Int>(0)
private let shotReady = Atomic<Bool>(false)
private nonisolated(unsafe) var mainThread: pthread_t?

/// Runs *on the main thread*, interrupting whatever holds it. Async-signal-safe: `backtrace` walks frame
/// pointers and allocates nothing, and the two atomics are plain instructions. Symbolication happens on
/// the watchdog thread, where malloc is legal again.
private func photograph(_ signal: Int32) {
    let depth = backtrace(shotBuffer, Int32(maxFrames))
    shotDepth.store(Int(depth), ordering: .relaxed)
    shotReady.store(true, ordering: .releasing)
}

/// Reports every main-thread stall longer than a threshold, with the stack that was holding it.
public enum StallProbe {

    /// The last run-loop activity seen, and when. Both are written by an observer on the main run loop
    /// and read by the watchdog thread, so both are atomic.
    private static let lastActivity = Atomic<UInt>(0)
    private static let lastStamp = Atomic<UInt64>(0)

    public static func install(threshold: Double) {
        mainThread = pthread_self()
        lastStamp.store(now(), ordering: .relaxed)
        lastActivity.store(CFRunLoopActivity.afterWaiting.rawValue, ordering: .relaxed)

        // `SA_RESTART`, or the signal turns a blocked `read` on the IPC socket into an `EINTR` nothing
        // in the daemon expects.
        var action = sigaction()
        action.__sigaction_u.__sa_handler = photograph
        action.sa_flags = SA_RESTART
        sigemptyset(&action.sa_mask)
        sigaction(SIGPROF, &action, nil)

        // `.commonModes`, so a menu or a resize loop does not take the heartbeat with it.
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.allActivities.rawValue, true, 0
        ) { _, activity in
            lastActivity.store(activity.rawValue, ordering: .relaxed)
            lastStamp.store(now(), ordering: .relaxed)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)

        let watchdog = Thread { watch(threshold: threshold) }
        watchdog.qualityOfService = .userInteractive
        watchdog.stackSize = 512 << 10
        watchdog.start()
        write("stall probe armed at \(Int(threshold * 1000)) ms\n")
    }

    /// The watchdog loop: poll the heartbeat, photograph the main thread while it is stale, and report
    /// once it moves again.
    private static func watch(threshold: Double) {
        let thresholdNanos = UInt64(threshold * 1e9)
        var shots: [[UnsafeMutableRawPointer?]] = []
        var stallStart: UInt64 = 0

        while true {
            usleep(2000)
            let parked = lastActivity.load(ordering: .relaxed) == CFRunLoopActivity.beforeWaiting.rawValue
            let stamp = lastStamp.load(ordering: .relaxed)

            guard !parked, now() &- stamp > thresholdNanos else {
                if !shots.isEmpty {
                    report(shots, nanos: stamp &- stallStart)
                    shots.removeAll()
                }
                continue
            }
            if shots.isEmpty { stallStart = stamp }
            guard shots.count < maxShots else { continue }
            if let shot = photographMain() { shots.append(shot) }
            usleep(15000)
        }
    }

    /// Ask the main thread for its stack and wait briefly for it. `nil` if it never answered, which
    /// would mean a thread wedged somewhere a signal cannot reach.
    private static func photographMain() -> [UnsafeMutableRawPointer?]? {
        guard let mainThread else { return nil }
        shotReady.store(false, ordering: .relaxed)
        guard pthread_kill(mainThread, SIGPROF) == 0 else { return nil }
        for _ in 0..<200 {
            if shotReady.load(ordering: .acquiring) {
                let depth = shotDepth.load(ordering: .relaxed)
                return (0..<depth).map { shotBuffer[$0] }
            }
            usleep(250)
        }
        return nil
    }

    /// One stall, as the frames that were on the main thread's stack while it lasted. Consecutive shots
    /// that walked the same frames fold together: a stall inside one call is a column of identical
    /// stacks, and where they diverge is the interesting part.
    private static func report(_ shots: [[UnsafeMutableRawPointer?]], nanos: UInt64) {
        var text = String(format: "\n=== main-thread stall: %.1f ms, %d shot(s) ===\n",
                          Double(nanos) / 1e6, shots.count)
        var previous: [String] = []
        for (index, shot) in shots.enumerated() {
            let frames = shot.map(describe)
            guard frames != previous else {
                text += "  [shot \(index + 1)] — identical\n"
                continue
            }
            text += "  [shot \(index + 1)]\n"
            for (depth, frame) in frames.enumerated() {
                text += String(format: "    %2d  %@\n", depth, frame)
            }
            previous = frames
        }
        write(text)
    }

    /// One frame as `image  symbol + offset`. Swift names come out mangled; `swift demangle` reads them.
    private static func describe(_ address: UnsafeMutableRawPointer?) -> String {
        guard let address else { return "?" }
        var info = Dl_info()
        guard dladdr(address, &info) != 0 else {
            return String(format: "0x%llx", UInt(bitPattern: address))
        }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent }
            ?? "?"
        guard let name = info.dli_sname else {
            return String(format: "%@ 0x%llx", image, UInt(bitPattern: address))
        }
        return "\(image)  \(String(cString: name)) + "
            + "\(UInt(bitPattern: address) - UInt(bitPattern: info.dli_saddr))"
    }

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    private static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}
