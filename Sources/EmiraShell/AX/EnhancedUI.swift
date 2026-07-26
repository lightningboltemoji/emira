import Foundation

// **The `AXEnhancedUserInterface` bug**, and the four lines that work around it (PRINCIPLES.md §5:
// *"When on (Chromium/Electron enable it), `setFrame` gets animated and positions come out
// offset/wrong. Toggle it off immediately before a set and restore after — what Rectangle and yabai
// both do."*).
//
// The attribute is AppKit's "an assistive client is watching" mode. With it on, AppKit routes window
// geometry changes through the same animated path it uses for user-initiated resizes — so an
// `AXPosition` write lands *late*, and an `AXPosition`+`AXSize` pair lands at a position computed
// against the pre-animation size. The window ends up somewhere plausible and wrong, which is the worst
// kind of wrong: it looks like a layout bug in our arithmetic.
//
// **Why this is its own file rather than four lines inside `AXWriter`.** What lives here is *policy*,
// and each clause of it is a decision somebody will otherwise re-litigate:
//
//  · **Read first; suspend only what was on.** The obvious implementation writes `false` before every
//    set and `true` after. That *introduces* assistive mode to every app emira touches — including the
//    ones that never had it — and each transition of that flag makes Chromium and JVM apps rebuild
//    their accessibility tree, which is precisely the "window managers make my Mac feel slow" cost §5
//    exists to avoid. The read is one round trip and it turns a per-set cost into a per-set cost *for
//    the few apps that actually have the bug*.
//  · **Restore it, always.** The spikes did not (`spike/strip.swift:101` sets `false` once at binding
//    and walks away) because a spike's blast radius is its own process lifetime. Ours is the user's
//    session: leaving the flag off strips VoiceOver, Switch Control and every other assistive client of
//    the mode they asked the app for. `defer` rather than a trailing statement, so a `body` that
//    returns early can't skip it.
//  · **Around the whole group, not around each window.** The caller (`AXWindowWriter.place`) hands a
//    batch of *one app's* windows through this once, so a three-window app pays one read and at most
//    two writes for the whole batch instead of nine round trips and three tree rebuilds.
//
// **Untestable by construction, and small on purpose.** There is no way to observe this without a real
// Chromium window on a real desktop, so the file is deliberately nothing but the policy — the raw AX
// reads and writes it composes live in `AXAccess.swift` (still the only file importing
// `ApplicationServices`). What can be verified about the write path is verified above it, in
// `AXExecutor`.

extension AXApplication {

    /// Run `body` with the app's assistive-client mode suspended, restoring it afterwards.
    ///
    /// A no-op wrapper — `body` runs untouched — for the overwhelming majority of apps, which do not
    /// have the mode on. Runs **on the app's serial AX lane**, like everything else here: it is three
    /// synchronous Mach round trips and must not happen on our own run loop (§5).
    func withEnhancedUserInterfaceSuspended<T>(_ body: () -> T) -> T {
        guard isEnhancedUserInterfaceOn else { return body() }
        setEnhancedUserInterface(false)
        defer { setEnhancedUserInterface(true) }
        return body()
    }
}
