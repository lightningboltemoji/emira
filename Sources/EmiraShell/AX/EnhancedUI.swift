import Foundation

// The `AXEnhancedUserInterface` bug, and the four lines that work around it.
//
// The attribute is AppKit's "an assistive client is watching" mode. With it on, AppKit routes window
// geometry changes through the animated path it uses for user-initiated resizes, so an `AXPosition` write
// lands late and an `AXPosition`+`AXSize` pair lands at a position computed against the pre-animation
// size. The window ends up somewhere plausible and wrong, looking like a bug in our own arithmetic.
//
//  · Read first, suspend only what was on. Blindly writing `false`/`true` around every set *introduces*
//    assistive mode to apps that never had it, and each transition of the flag makes Chromium and JVM
//    apps rebuild their accessibility tree.
//  · Restore it always (`defer`, so an early return can't skip it) — leaving it off strips VoiceOver and
//    every other assistive client of the mode they asked the app for.
//  · Around the whole group, not each window: `AXWindowWriter.place` sends one app's batch through once.

extension AXApplication {

    /// Run `body` with the app's assistive-client mode suspended, restoring it afterwards. A no-op for
    /// the majority of apps, which do not have the mode on.
    ///
    /// Runs on the app's serial AX lane: three synchronous Mach round trips that must not happen on our
    /// own run loop.
    func withEnhancedUserInterfaceSuspended<T>(_ body: () -> T) -> T {
        guard isEnhancedUserInterfaceOn else { return body() }
        setEnhancedUserInterface(false)
        defer { setEnhancedUserInterface(true) }
        return body()
    }
}
