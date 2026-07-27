import ApplicationServices
import EmiraCore
import Foundation

// The Accessibility API in the only shape the rest of emira is allowed to see it: two value types over
// an `AXUIElement`, with typed reads and no `CFTypeRef` in any signature. This is the **truth plane's
// vocabulary** (PRINCIPLES.md §3) — `AXClient` supplies the concurrency discipline around it,
// `AXEnumerator` the traversal policy, and almost nothing else in the codebase imports
// `ApplicationServices`.
//
// **"Almost", corrected 2026-07-25.** `AXObservers.swift` imports it too, and has to: `AXObserver` is
// its own object with its own C callback and its own run-loop source, and there is no way to wrap that
// in a value type without the wrapper being the machinery. So the rule is now stated as it actually
// holds — *two* files touch `ApplicationServices`, this one for the **vocabulary** (what you can ask a
// window and tell a window) and that one for the **notifications** (when to ask). Neither holds policy;
// everything with a decision in it sits above both.
//
// Both directions live here: the reads the enumerator and the observers need, and the writes the
// executor issues. What does *not* live here is any policy about them — when to suspend an app's
// assistive mode (`EnhancedUI.swift`), which windows go out together (`AXExecutor.swift`), or which
// thread any of it runs on (`AXClient.swift`).
//
// **AX hygiene is a property of this file** (PRINCIPLES.md §5, "do this or apps will feel broken").
// Chromium/Electron and JVM apps spin up a heavyweight accessibility engine the moment an AX client
// touches their tree, and that — not our arithmetic — is what makes a window manager feel like it slows
// the machine down. So the reads available here are **window-level only**: an application element
// yields its windows, and a window yields its own attributes. There is no child accessor, deliberately;
// `AXUIElementCopyAttributeValue(_, kAXChildrenAttribute, _)` appears nowhere in emira and the way to
// keep it that way is to never expose it.
//
// **Coordinates need no flip here, and that is worth stating plainly** (it corrects the loose reading
// of IMPLEMENTATION.md §7). AX reports `AXPosition` in global **top-left-origin** coordinates measured
// from the primary display's top-left — which is *exactly* `EmiraCore`'s virtual-strip space. The
// reflection `ScreenGeometry` owns is between core space and **Cocoa's** bottom-left space, and its
// only customers are the compositor's overlay and `NSScreen` enumeration. The AX boundary is a
// straight copy: `Rect(x:y:width:height:)` and done. One flip in the codebase, and it is not this one.
//
// **`@unchecked Sendable`, justified once.** `AXUIElement` is an immutable CoreFoundation handle and
// the AX client API is callable from any thread (that is the premise of the per-app serial queues in
// §5 — the work *must* leave the main thread). Swift cannot see that through a C type, so the two
// wrappers assert it here, in the one file that owns the raw handle, rather than at every call site.

// MARK: - Attribute names

// The AX attribute/role/subrole strings, as one complete table.
//
// Spelled as literals rather than the `kAX…` constants on purpose: the SDK exports some of these as
// Swift `String`s and omits others entirely (`AXFullScreen` has no constant), and a table that is half
// symbols and half literals reads as if the literals were the sloppy ones. They are all equally load-
// bearing strings in a C API, so they are all listed together, here, once.
private enum AXKey {
    static let windows = "AXWindows"
    static let title = "AXTitle"
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let minimized = "AXMinimized"
    /// No `kAX…` constant exists for this one. Set on a window that has taken a native macOS
    /// full-screen Space of its own.
    static let fullScreen = "AXFullScreen"
    /// The window an app considers its main one. Setting it is half of "make this window key".
    static let main = "AXMain"
    /// The window that holds keyboard focus within its app. The other half.
    static let focused = "AXFocused"
    /// AppKit's assistive-client mode. No `kAX…` constant; see `EnhancedUI.swift` for why we care.
    static let enhancedUserInterface = "AXEnhancedUserInterface"
    /// An application's currently focused window. Read on activation, when `NSWorkspace` tells us an
    /// app came forward but not which of its windows the user is now typing into.
    static let focusedWindow = "AXFocusedWindow"
}

/// The AX *actions* emira performs. Same literal-table reasoning as `AXKey`; separate because an
/// action is performed, not written, and confusing the two is an easy silent no-op.
private enum AXAction {
    /// Bring a window to the front of its app's window stack. Z-order only — it does not move
    /// keyboard focus, which is what makes it the right primitive for `Effect.raise`.
    static let raise = "AXRaise"
}

// MARK: - The application element

/// An application's AX element — the root of everything we are allowed to ask about one process, and
/// the object the per-app messaging timeout is set on.
///
/// Created from a pid, which is the *only* place a pid appears above the shell's own boundary: the core
/// keys apps by `bundleId` (`World.swift`), never by a number that is recycled at the next launch.
public struct AXApplication: @unchecked Sendable {

    /// The process this element addresses.
    public let pid: pid_t

    /// The raw handle. `internal` so the write path and the observers can use it without re-deriving
    /// it, and so nothing outside `EmiraShell` ever sees an `AXUIElement`.
    let element: AXUIElement

    /// Address an application by pid. Cheap and non-blocking — `AXUIElementCreateApplication` performs
    /// no IPC, so this is safe to call on the main actor; every *read* through it is not.
    public init(pid: pid_t) {
        self.pid = pid
        self.element = AXUIElementCreateApplication(pid)
    }

    /// Bound how long any AX call through this element may block before returning `.cannotComplete`.
    ///
    /// This protects **us**, not the app (PRINCIPLES.md §5): AX setters and getters are synchronous
    /// Mach IPC serviced by the target's main run loop, so a spinning Chrome would otherwise hold our
    /// per-app queue for as long as it likes. It makes nothing faster; it makes the tail bounded.
    public func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    /// Whether the app has AppKit's assistive-client mode on — the attribute behind the
    /// `setFrame`-comes-out-wrong bug (PRINCIPLES.md §5). Read, never assumed: see `EnhancedUI.swift`,
    /// which owns the *policy* around these two accessors.
    ///
    /// Unreadable (most apps never expose it) collapses to `false`, which is the safe answer — it
    /// means "nothing to suspend", and the frame set proceeds untouched.
    var isEnhancedUserInterfaceOn: Bool {
        copyAttribute(element, AXKey.enhancedUserInterface) as? Bool ?? false
    }

    /// Turn assistive-client mode on or off. Only ever called by `withEnhancedUserInterfaceSuspended`,
    /// and only on an app that was already answering the read — we never *introduce* the mode to an app
    /// that didn't have it.
    @discardableResult
    func setEnhancedUserInterface(_ on: Bool) -> Bool {
        setAttribute(element, AXKey.enhancedUserInterface, on as CFTypeRef)
    }

    /// The application's windows, window-level only — never a child walk (§5).
    ///
    /// Returns `[]` for anything that is not answering: no Accessibility grant, an app with no AX
    /// support, a process that exited mid-call, or a timeout. That collapse is intentional — every one
    /// of those is "this app contributes no windows right now", which is a normal state for a window
    /// manager and not an error to propagate. The *global* case of "nothing anywhere is answering" is
    /// caught once, by `Permissions`, before we get here.
    public func windows() -> [AXWindow] {
        guard let raw = copyAttribute(element, AXKey.windows) as? [AXUIElement] else { return [] }
        return raw.map(AXWindow.init)
    }

    /// The window the app currently considers focused, or `nil` if it has none (or won't say).
    ///
    /// The one read that exists because of `NSWorkspace`: an activation notification says *an app*
    /// came forward, and §4a's promise ("the user must never be focused on something they can't see")
    /// is about a *window*. Every other focus fact arrives with its own element attached.
    func focusedWindow() -> AXWindow? {
        guard let raw = copyAttribute(element, AXKey.focusedWindow),
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return AXWindow(raw as! AXUIElement)
    }
}

// MARK: - The window element

/// A window's AX element and the attributes emira reads from it.
///
/// Every property is a **round trip** — synchronous Mach IPC into the owning app — so they are read
/// once into an `ObservedWindow` value (`snapshot(bundleId:)`) and never polled. After first sight the
/// truth plane is driven by observation, not by re-querying (§5, "observe, don't poll").
public struct AXWindow: @unchecked Sendable {

    /// The raw handle — the thing an `Effect.setFrame` writes to (`AXWindowWriter`), which is why
    /// `WindowRegistry` holds onto it rather than re-finding the window each time.
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    /// The window title, or `nil` if the app doesn't answer. Read for display and for rule matching;
    /// **never** for identity after binding — titles are rewritten constantly (PRINCIPLES.md §7).
    public var title: String? { copyAttribute(element, AXKey.title) as? String }

    /// The AX role — `AXWindow` for an ordinary window, `AXSheet`/`AXPopover` for the attached kinds.
    public var role: String? { copyAttribute(element, AXKey.role) as? String }

    /// The AX subrole — `AXStandardWindow`, `AXDialog`, `AXFloatingWindow`, … The primary input to the
    /// tiling taxonomy (§6).
    public var subrole: String? { copyAttribute(element, AXKey.subrole) as? String }

    /// Whether the window is in the Dock. A minimized window **leaves the strip** like a close
    /// (2026-07-23), so this is truth the core needs at first sight, not a detail.
    public var isMinimized: Bool { copyAttribute(element, AXKey.minimized) as? Bool ?? false }

    /// Whether the window occupies a native macOS full-screen Space. Those windows are excluded from
    /// tiling entirely (§6) — they live somewhere we have chartered ourselves not to go (§10, "no
    /// native Spaces integration").
    public var isFullScreen: Bool { copyAttribute(element, AXKey.fullScreen) as? Bool ?? false }

    /// Whether the element still refers to a window that exists.
    ///
    /// A destroyed element answers `kAXErrorInvalidUIElement` to *everything*, so any attribute would
    /// do; `role` is the cheapest with an answer — one round trip where `frame` is two — and its value
    /// is thrown away. This is the one question a *notification* cannot answer, because the whole
    /// difficulty is that the notification saying so has not arrived yet (`WorldWatcher`'s focus probe).
    ///
    /// **A busy app answers `false` too**, when the read times out, so a caller must treat this as
    /// evidence rather than proof and pick the direction whose false answer is cheap.
    public var isAlive: Bool { role != nil }

    /// The window's frame in core (top-left, global) coordinates — no flip, see the file header.
    ///
    /// `nil` when either half is unreadable. Position and size are two separate attributes and two
    /// separate round trips; a window that answers one and not the other is not a window we can place,
    /// so the pair is all-or-nothing.
    public var frame: Rect? {
        guard let origin = axValue(element, AXKey.position, .cgPoint, CGPoint.zero),
              let size = axValue(element, AXKey.size, .cgSize, CGSize.zero)
        else { return nil }
        return Rect(x: Double(origin.x), y: Double(origin.y),
                    width: Double(size.width), height: Double(size.height))
    }

    /// Read every attribute emira cares about in one pass and return the framework-free value the rest
    /// of the shell works on.
    ///
    /// This is the *only* method the enumerator calls, which keeps the round-trip count per window
    /// visible and countable: seven reads (role, subrole, title, minimized, full-screen, position,
    /// size), once, at first sight.
    ///
    /// `nil` on either of the two ways an element can fail to be a manageable window:
    ///
    ///  · **It is not a window** (`WindowRole.init?` declines the role). `kAXWindowsAttribute` is not
    ///    the pure list its name promises — Finder answers it with the **desktop**, whose role is
    ///    `AXScrollArea`. Found the first time this ran against a real machine; see the iteration
    ///    journal. Dropping it here rather than reporting it unbound matters, because it will *never*
    ///    bind (the desktop is precisely what `.excludeDesktopElements` removes from the window list)
    ///    and a permanent line in the "not managed" report is a permanent false alarm.
    ///  · **It has no readable frame.** Unplaceable, so we decline it rather than invent a geometry.
    public func snapshot(bundleId: String) -> ObservedWindow? {
        guard let role = WindowRole(axRole: role, axSubrole: subrole, isFullScreen: isFullScreen),
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

    // MARK: The write path (the truth plane's other direction)

    /// Move the window's top-left corner. Core coordinates, no flip (see the file header).
    @discardableResult
    func setPosition(_ point: Point) -> Bool {
        var value = CGPoint(x: point.x, y: point.y)
        guard let boxed = AXValueCreate(.cgPoint, &value) else { return false }
        return setAttribute(element, AXKey.position, boxed)
    }

    /// Resize the window.
    @discardableResult
    func setSize(_ size: Size) -> Bool {
        var value = CGSize(width: size.width, height: size.height)
        guard let boxed = AXValueCreate(.cgSize, &value) else { return false }
        return setAttribute(element, AXKey.size, boxed)
    }

    /// Put the window at `rect` and report what actually happened — the single write primitive behind
    /// `Effect.setFrame` and `Effect.park`.
    ///
    /// **The clamping dance, made conditional.** PRINCIPLES.md §5: *"Apps clamp to min/max/constraints;
    /// you may need size → position → size again to land exactly."* Size goes first because the
    /// dangerous clamp is positional — AppKit refuses to put a window where its *current* size wouldn't
    /// fit, so shrinking before moving is what makes the move land. But the third write is only needed
    /// when the first two didn't take, and *"may need"* is the operative phrase: we assert the frame,
    /// **read it back**, and only re-assert if reality disagrees. The common case costs two writes and
    /// one read-back instead of three blind writes, and — unlike the blind dance — it *knows* whether
    /// it worked, which is the entire point of returning something.
    ///
    /// Two outcomes, deliberately separate, because they mean opposite things to the reducer:
    ///
    ///  · **`accepted`** — every AX write returned `.success`. `false` is the app saying no: a timeout
    ///    (§5's bounded wait expiring), a dead element, a refused write. That is `Event.axFailed`.
    ///  · **`actual`** — where the window *is* now, which may not be where we asked. An app that
    ///    quantizes its size (a terminal snapping to character cells) accepts every write and lands
    ///    somewhere else, and calling that a failure would be a lie that gets a terminal dropped from
    ///    the layout the day `axFailed` grows real reconciliation. It is `Event.windowFrameChanged`.
    ///
    /// `actual` is `nil` only when the window stopped answering entirely between the write and the
    /// read — it closed mid-set, which is a normal race, not an error.
    func place(at rect: Rect) -> (accepted: Bool, actual: Rect?) {
        var accepted = setSize(rect.size)
        accepted = setPosition(rect.origin) && accepted
        guard var actual = frame else { return (accepted, nil) }
        guard !sameFrame(actual, rect) else { return (accepted, actual) }
        // One corrective pass, in the same order: the size write may have been clamped against the
        // *old* position and can succeed now that the window has moved. Bounded at one — an app that
        // refuses twice is asserting a constraint we are not entitled to override, and looping would
        // just be fighting it at AX's round-trip cost.
        accepted = setSize(rect.size) && accepted
        accepted = setPosition(rect.origin) && accepted
        actual = frame ?? actual
        return (accepted, actual)
    }

    /// Make this the app's key window: main + focused + front of its own stack.
    ///
    /// All three, because they are three different facts and apps honor different subsets — `AXMain`
    /// is what the app itself considers its primary window (and therefore what activation brings
    /// forward), `AXFocused` is where typing goes, and `AXRaise` is z-order. Bringing the *app* forward
    /// is the caller's job (`AXWindowWriter.focus`) and must happen after this, on the main actor:
    /// activation surfaces whichever window is main *at that moment*.
    @discardableResult
    func makeKey() -> Bool {
        let isMain = setAttribute(element, AXKey.main, true as CFTypeRef)
        // Best-effort and deliberately not part of the verdict: plenty of apps expose `AXFocused` as
        // read-only on a window, and refusing it is not a failure to focus.
        _ = setAttribute(element, AXKey.focused, true as CFTypeRef)
        let raised = performAction(element, AXAction.raise)
        return isMain || raised
    }

    /// Bring the window to the front of its app's stack without touching keyboard focus — the whole of
    /// `Effect.raise` (stacking within a column).
    @discardableResult
    func raise() -> Bool {
        performAction(element, AXAction.raise)
    }

    /// Whether two frames are the same window position, within the slack an app's own rounding
    /// introduces. Only used to decide whether the corrective pass is needed; the *reported* drift
    /// threshold is the executor's (`AXExecutor.landingTolerance`).
    private func sameFrame(_ a: Rect, _ b: Rect, tolerance: Double = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// The pid of the process owning this element. Not IPC — `AXUIElementGetPid` reads it out of the
    /// element itself — so it is free and cannot time out.
    ///
    /// Internal rather than private because an observer callback is handed an element with no other
    /// context at all, and for `AXWindowCreated` the owning app is the only thing about it we can yet
    /// know (`AXObservers.swift`).
    var ownerPid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }
}

// MARK: - Element identity (the observers' lookup key)

extension AXWindow: Hashable {

    /// Two `AXWindow`s are the same window when the Accessibility API says their elements are equal.
    ///
    /// **This is what lets an AX *notification* become a `WindowId` without private SPI.** An observer
    /// callback hands back the element the notification is about and nothing else — no window number,
    /// no title we would trust. yabai answers that with `_AXUIElementGetWindow`; we answer it by having
    /// bound the element at first sight and keeping a reverse map (`WindowRegistry.id(for:)`), which
    /// needs `AXWindow` to be a dictionary key.
    ///
    /// `CFEqual` is the right comparison and not merely a convenient one: `AXUIElement` implements it
    /// structurally, so two elements fetched from the same app on different occasions — one at
    /// enumeration, one arriving with a `AXUIElementDestroyed` notification — compare equal even though
    /// they are distinct allocations. Pointer identity would silently never match, which is precisely
    /// the bug class that would make every observation about a window we already knew look like an
    /// observation about an unknown one.
    public static func == (lhs: AXWindow, rhs: AXWindow) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

// MARK: - The tiling taxonomy

extension WindowRole {

    /// Classify an AX element into the core's tiling taxonomy (IMPLEMENTATION.md §6, "built-in taxonomy
    /// defaults"): **only `.standard` tiles; everything else floats** — or `nil` if the element is not a
    /// window at all.
    ///
    /// **Failable, because `kAXWindowsAttribute` lies about its contents.** Finder answers it with the
    /// desktop, an `AXScrollArea`; other apps put other furniture in there. An unrecognized *role* is
    /// therefore not "a window of an unknown kind" — it is not a window, and `.other` (which means "a
    /// real window emira leaves alone") would be the wrong thing to say about it. An unrecognized
    /// *subrole* still is: hence one `nil` and one `.other`, and the difference between them is exactly
    /// the difference between "not our business" and "our business, hands off".
    ///
    /// Three inputs, because AX splits the answer across attributes:
    ///
    ///  · **Full-screen wins over everything.** A window on its own native Space is excluded from
    ///    tiling (§6) even though its subrole often still looks ordinary — it is on a Space we do not
    ///    touch (§10), so tiling it would fight macOS for a window that isn't there.
    ///  · **Role says whether this is a window, and catches the attached kinds.** Sheets and popovers
    ///    are their own *role*, not a subrole, and a sheet frequently reports no subrole at all.
    ///  · **Subrole decides the rest**, which is the ordinary case.
    ///
    /// An unrecognized subrole lands on `.other` and therefore floats. That default is the safe
    /// direction: the failure mode of misclassifying a window as floating is that emira leaves it
    /// alone, and the failure mode of the opposite is that emira drags a spell-check popover into the
    /// strip.
    public init?(axRole: String?, axSubrole: String?, isFullScreen: Bool) {
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
        default:                       self = .other
        }
    }
}

// MARK: - CF bridging (the +1/+0 boundary, PRINCIPLES.md §7)

/// Copy an attribute, or `nil` if it is absent, unreadable, or the call timed out.
///
/// `AXUIElementCopyAttributeValue` is a *Copy* function: it hands back a +1 reference through an
/// out-parameter, which Swift's `CFTypeRef?` binding takes ownership of and ARC then releases. Every
/// non-`.success` `AXError` — `.attributeUnsupported`, `.cannotComplete` (the timeout), `.apiDisabled`
/// (no grant), `.invalidUIElement` (the window closed between two of our reads) — collapses to `nil`,
/// because at this layer they are the same fact: there is no value to be had.
private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

/// Write an attribute, reporting whether the app accepted it.
///
/// `AXUIElementSetAttributeValue` is **not** a *Copy* function — it borrows the value and the caller
/// keeps ownership, so there is no +1 to balance here (unlike `copyAttribute` above). Every
/// non-`.success` collapses to `false`, and at this layer they are again the same fact: the write did
/// not happen. *Which* way it failed matters one level up, where a timeout during a transition and a
/// refused write both become `Event.axFailed` anyway.
@discardableResult
private func setAttribute(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
    AXUIElementSetAttributeValue(element, name as CFString, value) == .success
}

/// Perform an action (`AXRaise`), reporting whether it was accepted.
@discardableResult
private func performAction(_ element: AXUIElement, _ name: String) -> Bool {
    AXUIElementPerformAction(element, name as CFString) == .success
}

/// Copy an attribute that is boxed in an `AXValue` (points, sizes, rects) and unwrap it.
///
/// The `CFGetTypeID` check is not paranoia: `AXValueGetValue` reinterprets its out-parameter according
/// to the `type` it is told, so handing it something that is not an `AXValue` — an app answering
/// `AXPosition` with a string, which happens — is how you get a garbage frame instead of a `nil` one.
private func axValue<T>(_ element: AXUIElement, _ name: String, _ type: AXValueType, _ zero: T) -> T? {
    guard let raw = copyAttribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else {
        return nil
    }
    var out = zero
    guard AXValueGetValue(raw as! AXValue, type, &out) else { return nil }
    return out
}
