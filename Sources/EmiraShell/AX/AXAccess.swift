import ApplicationServices
import EmiraCore
import Foundation

// The Accessibility API in the only shape the rest of emira sees it: two value types over an
// `AXUIElement`, typed reads, no `CFTypeRef` in any signature. Three things a reader must not undo:
//
//  · Reads are window-level only. Nothing descends *below* a window — walking a Chromium/Electron or JVM
//    app's AX tree spins up its heavyweight accessibility engine and slows the whole machine. Naming the
//    application element's own children is not that walk, and `windows()` falls back to it.
//  · No coordinate flip here. `AXPosition` is global top-left from the primary display's top-left,
//    which is exactly `EmiraCore`'s virtual-strip space. The one flip lives in `ScreenGeometry`.
//  · `@unchecked Sendable` is sound: `AXUIElement` is an immutable CF handle and the AX client API is
//    callable from any thread. Swift cannot see that through a C type.

// Literals rather than the `kAX…` constants: the SDK exports some as Swift `String`s and omits others
// entirely (`AXFullScreen` has none).
private enum AXKey {
    static let windows = "AXWindows"
    /// The application element's own children: its windows, plus a menu bar the classifier drops.
    /// `windows()`'s second question, never a descent below a window.
    static let children = "AXChildren"
    static let title = "AXTitle"
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let minimized = "AXMinimized"
    /// Set on a window that has taken a native macOS full-screen Space of its own.
    static let fullScreen = "AXFullScreen"
    /// The window an app considers its main one. Half of "make this window key", and — as a settability
    /// rather than a value — the classifier's test for whether a window can be a primary one at all.
    static let main = "AXMain"
    /// The window that holds keyboard focus within its app. The other half.
    static let focused = "AXFocused"
    /// AppKit's assistive-client mode. See `EnhancedUI.swift`.
    static let enhancedUserInterface = "AXEnhancedUserInterface"
    /// An app's currently focused window. Read on activation, when `NSWorkspace` says an app came
    /// forward but not which of its windows.
    static let focusedWindow = "AXFocusedWindow"
    /// Whether the app is the active one. Written when AppKit's own activation is refused — see
    /// `AXWindowWriter.focus`.
    static let frontmost = "AXFrontmost"
    /// The window's own close button. A window-level *attribute*, not a child walk — the one element
    /// below a window emira ever asks for, and the only public way to close a foreign window
    /// (`IMPLEMENTATION.md` §7's "never walk children" is about enumerating a tree, not naming a
    /// standard part). A window that cannot be closed simply doesn't answer.
    static let closeButton = "AXCloseButton"
}

/// The AX *actions* emira performs. Separate from attributes because an action is performed, not
/// written, and confusing the two is a silent no-op.
private enum AXAction {
    /// Front of the app's window stack. Z-order only — it does not move keyboard focus.
    static let raise = "AXRaise"
    /// Click a button. Performed on a close button, never on a window.
    static let press = "AXPress"
}

/// An application's AX element, and the object the per-app messaging timeout is set on. Created from a
/// pid — the only place a pid appears above the shell's boundary; the core keys apps by `bundleId`.
public struct AXApplication: @unchecked Sendable {

    public let pid: pid_t

    /// `internal` so nothing outside `EmiraShell` ever sees an `AXUIElement`.
    let element: AXUIElement

    /// `AXUIElementCreateApplication` performs no IPC, so this is safe on the main actor; every *read*
    /// through it is not.
    public init(pid: pid_t) {
        self.pid = pid
        self.element = AXUIElementCreateApplication(pid)
    }

    /// Bound how long any AX call through this element may block before returning `.cannotComplete`.
    /// AX calls are synchronous Mach IPC serviced by the target's main run loop, so a spinning app would
    /// otherwise hold our per-app queue indefinitely.
    public func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    /// The attribute behind the `setFrame`-comes-out-wrong bug. Unreadable (most apps never expose it)
    /// collapses to `false`, i.e. "nothing to suspend".
    var isEnhancedUserInterfaceOn: Bool {
        copyAttribute(element, AXKey.enhancedUserInterface) as? Bool ?? false
    }

    /// Only called by `withEnhancedUserInterfaceSuspended`, and only on an app already answering the
    /// read — we never *introduce* the mode to an app without it.
    @discardableResult
    func setEnhancedUserInterface(_ on: Bool) -> Bool {
        setAttribute(element, AXKey.enhancedUserInterface, on as CFTypeRef)
    }

    /// The app's windows, window-level only. `[]` for anything not answering — no grant, no AX support,
    /// exited process, timeout — all of which mean "contributes no windows right now".
    ///
    /// An *empty* answer is asked again as `AXChildren`, which still lists the windows of an app that has
    /// stopped listing `AXWindows`. A *failed* read is not: that is usually the messaging timeout, and a
    /// second one would double what a hung app costs its lane.
    public func windows() -> [AXWindow] {
        guard let listed = copyAttribute(element, AXKey.windows) as? [AXUIElement] else { return [] }
        guard listed.isEmpty else { return listed.map(AXWindow.init) }
        let children = copyAttribute(element, AXKey.children) as? [AXUIElement] ?? []
        return children.map(AXWindow.init)
    }

    /// Bring the app forward through AX rather than AppKit. Answers the one refusal `activate()` has no
    /// way around (`AXWindowWriter.focus`); `false` from an app that does not expose the attribute.
    func makeFrontmost() -> Bool {
        setAttribute(element, AXKey.frontmost, true as CFTypeRef)
    }

    /// The window the app considers focused. Exists because an `NSWorkspace` activation notification
    /// names an app, not a window.
    func focusedWindow() -> AXWindow? {
        guard let raw = copyAttribute(element, AXKey.focusedWindow),
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return AXWindow(raw as! AXUIElement)
    }
}

/// A window's AX element and the attributes emira reads from it. Every property is a **round trip** —
/// synchronous Mach IPC into the owning app — so they are read once into an `ObservedWindow` and never
/// polled.
public struct AXWindow: @unchecked Sendable {

    /// The handle an `Effect.setFrame` writes to, which is why `WindowRegistry` holds onto it.
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    /// Read for display and rule matching; **never** for identity after binding — titles churn.
    public var title: String? { copyAttribute(element, AXKey.title) as? String }

    /// `AXWindow` for an ordinary window, `AXSheet`/`AXPopover` for the attached kinds.
    public var role: String? { copyAttribute(element, AXKey.role) as? String }

    /// `AXStandardWindow`, `AXDialog`, `AXFloatingWindow`, … The primary input to the tiling taxonomy.
    public var subrole: String? { copyAttribute(element, AXKey.subrole) as? String }

    /// Whether the window is in the Dock. A minimized window leaves the strip like a close.
    public var isMinimized: Bool { copyAttribute(element, AXKey.minimized) as? Bool ?? false }

    /// On a native full-screen Space, and therefore excluded from tiling entirely.
    public var isFullScreen: Bool { copyAttribute(element, AXKey.fullScreen) as? Bool ?? false }

    /// Whether this window can ever be its application's *main* one — `AXMain`'s **settability**, not its
    /// value. AppKit exposes the attribute as writable only where `NSWindow.canBecomeMain` is true, so
    /// `false` is the framework saying this surface is not a primary window and never will be.
    public var canBecomeMain: Bool { isSettable(element, AXKey.main) }

    /// A destroyed element answers `kAXErrorInvalidUIElement` to everything, so any attribute would do;
    /// `role` is the cheapest. **A busy app answers `false` too**, when the read times out — treat this
    /// as evidence, not proof.
    public var isAlive: Bool { role != nil }

    /// Core (top-left, global) coordinates — no flip, see the file header. Position and size are two
    /// round trips; a window answering one and not the other is unplaceable, so the pair is
    /// all-or-nothing.
    public var frame: Rect? {
        guard let origin = axValue(element, AXKey.position, .cgPoint, CGPoint.zero),
              let size = axValue(element, AXKey.size, .cgSize, CGSize.zero)
        else { return nil }
        return Rect(x: Double(origin.x), y: Double(origin.y),
                    width: Double(size.width), height: Double(size.height))
    }

    /// Every attribute emira cares about in one pass: seven round trips, once, at first sight, plus an
    /// eighth only for a window that declines to name its own subrole.
    ///
    /// `nil` when the element has no readable frame, or is not a window at all — `kAXWindowsAttribute`
    /// is not the pure list its name promises, e.g. Finder answers it with the desktop, an
    /// `AXScrollArea`. Dropped here rather than reported unbound, since it will never bind.
    public func snapshot(bundleId: String) -> ObservedWindow? {
        guard let role = WindowRole(axRole: role, axSubrole: subrole, isFullScreen: isFullScreen,
                                    canBecomeMain: canBecomeMain),
              let frame
        else { return nil }
        return ObservedWindow(
            pid: ownerPid,
            bundleId: bundleId,
            title: title ?? "",
            role: role,
            frame: frame,
            isMinimized: isMinimized)
    }

    @discardableResult
    func setPosition(_ point: Point) -> Bool {
        var value = CGPoint(x: point.x, y: point.y)
        guard let boxed = AXValueCreate(.cgPoint, &value) else { return false }
        return setAttribute(element, AXKey.position, boxed)
    }

    @discardableResult
    func setSize(_ size: Size) -> Bool {
        var value = CGSize(width: size.width, height: size.height)
        guard let boxed = AXValueCreate(.cgSize, &value) else { return false }
        return setAttribute(element, AXKey.size, boxed)
    }

    /// Put the window at `rect` and report what actually happened.
    ///
    /// Size before position, because the dangerous clamp is positional: AppKit refuses to put a window
    /// where its *current* size wouldn't fit, so shrinking before moving is what makes the move land.
    /// The frame is then read back and re-asserted only if reality disagrees.
    ///
    /// `accepted` is the app's verdict on the *write* (`Event.axFailed`); `actual` is where it ended up,
    /// which may differ — a terminal snapping to character cells accepts every write and lands
    /// elsewhere. `actual` is `nil` only if the window stopped answering mid-set.
    func place(at rect: Rect) -> (accepted: Bool, actual: Rect?) {
        var accepted = setSize(rect.size)
        accepted = setPosition(rect.origin) && accepted
        guard var actual = frame else { return (accepted, nil) }
        guard !sameFrame(actual, rect) else { return (accepted, actual) }
        // One corrective pass, same order: the size write may have been clamped against the *old*
        // position and can succeed now. Bounded at one — an app that refuses twice is asserting a
        // constraint we are not entitled to override.
        accepted = setSize(rect.size) && accepted
        accepted = setPosition(rect.origin) && accepted
        actual = frame ?? actual
        return (accepted, actual)
    }

    /// Main + focused + front of its own stack. All three, because apps honor different subsets.
    /// Bringing the *app* forward is the caller's job and must happen after this: activation surfaces
    /// whichever window is `AXMain` at that moment.
    @discardableResult
    func makeKey() -> Bool {
        let isMain = setAttribute(element, AXKey.main, true as CFTypeRef)
        // Best-effort: plenty of apps expose `AXFocused` as read-only, and refusing it is not a failure.
        _ = setAttribute(element, AXKey.focused, true as CFTypeRef)
        let raised = performAction(element, AXAction.raise)
        return isMain || raised
    }

    /// Front of the app's stack, without touching keyboard focus.
    @discardableResult
    func raise() -> Bool {
        performAction(element, AXAction.raise)
    }

    /// Press the window's close button — the public equivalent of the user clicking the red dot, which
    /// is deliberately *not* the same as quitting the app or destroying the window behind its back: the
    /// app runs its own close path, so an unsaved document still gets to put up its sheet.
    ///
    /// Returns `false` when the window exposes no close button (a panel, a sheet, an app that hides it).
    /// Nothing else here reports success either — the truth that the window went away arrives as an
    /// `AXUIElementDestroyed` observation, not as this return value.
    @discardableResult
    func close() -> Bool {
        guard let raw = copyAttribute(element, AXKey.closeButton),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        return performAction(raw as! AXUIElement, AXAction.press)
    }

    /// Only gates the corrective pass; the *reported* drift threshold is `AXExecutor.landingTolerance`.
    private func sameFrame(_ a: Rect, _ b: Rect, tolerance: Double = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Not IPC — `AXUIElementGetPid` reads it out of the element — so it is free and cannot time out.
    /// Internal because an observer callback is handed an element with no other context.
    var ownerPid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }
}

// Element identity (the observers' lookup key)

extension AXWindow: Hashable {

    /// What lets an AX notification become a `WindowId` without private SPI: the callback hands back
    /// only the element, and `WindowRegistry.id(for:)` reverse-maps it.
    ///
    /// `CFEqual` is required, not convenient — `AXUIElement` implements it structurally, so an element
    /// fetched at enumeration and one arriving with a destroy notification compare equal despite being
    /// distinct allocations. Pointer identity would silently never match.
    public static func == (lhs: AXWindow, rhs: AXWindow) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

extension WindowRole {

    /// Classify an AX element: only `.standard` tiles, everything else floats — or `nil` if this is not
    /// a window at all.
    ///
    /// Failable in two directions, because `kAXWindowsAttribute` lies about its contents twice over. An
    /// unrecognized *role* is not a window (Finder answers it with the desktop). A subrole of literally
    /// `AXUnknown` on a window whose `AXMain` is not settable is app chrome carrying an `NSWindow`, and
    /// **both halves are required** — either alone has real windows behind it. An unrecognized subrole
    /// that can still be main means "a real window we leave alone".
    ///
    /// Full-screen wins over everything, since such a window's subrole often still looks ordinary; role
    /// catches the attached kinds, because sheets and popovers are their own role and a sheet frequently
    /// reports no subrole at all.
    ///
    /// `canBecomeMain` is a round trip, so it is read only on the branch that needs it.
    public init?(axRole: String?, axSubrole: String?, isFullScreen: Bool,
                 canBecomeMain: @autoclosure () -> Bool) {
        switch axRole {
        case "AXWindow":  break                       // an ordinary window; the subrole decides
        case "AXSheet":   self = isFullScreen ? .other : .sheet;   return
        case "AXPopover": self = isFullScreen ? .other : .popover; return
        default:          return nil                  // not a window (Finder's desktop, and friends)
        }
        if isFullScreen {
            self = .other
            return
        }
        switch axSubrole {
        case "AXStandardWindow":       self = .standard
        case "AXDialog":               self = .dialog
        case "AXSystemDialog":         self = .dialog
        case "AXFloatingWindow":       self = .panel
        case "AXSystemFloatingWindow": self = .panel
        case "AXUnknown" where !canBecomeMain(): return nil   // app chrome, not a window
        default:                       self = .other
        }
    }
}

// CF bridging (the +1/+0 boundary)

/// A *Copy* function: it hands back a +1 reference that Swift's `CFTypeRef?` binding takes ownership of.
/// Every non-`.success` `AXError` collapses to `nil` — at this layer they are the same fact.
private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

/// Whether an attribute can be *written*, a different question from what it currently reads. A round
/// trip like any other. Every non-`.success` `AXError` collapses to `false`: an element that cannot
/// answer the question cannot be written either.
private func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
    var settable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success else {
        return false
    }
    return settable.boolValue
}

/// **Not** a *Copy* function — it borrows the value, so there is no +1 to balance here.
@discardableResult
private func setAttribute(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
    AXUIElementSetAttributeValue(element, name as CFString, value) == .success
}

@discardableResult
private func performAction(_ element: AXUIElement, _ name: String) -> Bool {
    AXUIElementPerformAction(element, name as CFString) == .success
}

/// Copy an attribute boxed in an `AXValue` (points, sizes) and unwrap it. The `CFGetTypeID` check is
/// load-bearing: `AXValueGetValue` reinterprets its out-parameter according to the `type` it is told, so
/// an app answering `AXPosition` with a string yields a garbage frame rather than `nil`.
///
/// `BitwiseCopyable` is the precondition the C call already assumes: it blits `type`-many bytes over
/// `out` with no regard for what lives there, which is only sound for a type holding no references.
/// Stating it lets the compiler check our callers instead of warning about the raw-pointer conversion.
private func axValue<T: BitwiseCopyable>(
    _ element: AXUIElement, _ name: String, _ type: AXValueType, _ zero: T
) -> T? {
    guard let raw = copyAttribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else {
        return nil
    }
    var out = zero
    guard AXValueGetValue(raw as! AXValue, type, &out) else { return nil }
    return out
}
