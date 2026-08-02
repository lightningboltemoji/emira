import CoreGraphics
import Darwin
import Foundation

// **The whole of emira's private surface, and nothing else in the repository mentions CGS.**
//
// `PRINCIPLES.md` §2 takes its one narrow exception here, on terms this file is built to keep: the two
// symbols are reached by `dlsym` and are neither linked nor `dlopen`ed, so a macOS that stops exporting
// them makes emira's cursor setting unavailable rather than making emira unlaunchable — arm64 binaries
// use chained fixups with no lazy binding, so a *linked* symbol that went away would fail in dyld before
// `main`. Nothing here decides where a window goes: if every call below fails, silently or loudly, every
// window still lands exactly where it would have.
//
// The property is set **lazily, on the first hide**, so a user who leaves `[mouse] hide` off has emira
// execute no private call at all. Deletable in one commit if the policy is ever reversed.

/// The private half of hiding the pointer: telling the window server that this connection may hide the
/// cursor while it is not the frontmost app.
///
/// The public API cannot do it — `cursorUpdate` is not delivered to non-active applications, which
/// closes cursor rects, tracking areas and `NSCursor.push`/`set` — so an `.accessory` app has exactly
/// one route. `CGDisplayHideCursor` is public and lives on the other side of the seam.
@MainActor
enum CursorConnection {

    /// `CGSMainConnectionID()` — this process's window-server connection.
    private typealias MainConnectionID = @convention(c) () -> Int32

    /// `CGSSetConnectionProperty(cid, target, key, value)` — a `CGError` in the return.
    private typealias SetConnectionProperty =
        @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    /// The property that makes a background app's `CGDisplayHideCursor` take effect.
    private static let propertyKey = "SetsCursorInBackground"

    private static let mainConnectionID: MainConnectionID? = symbol("CGSMainConnectionID")
    private static let setConnectionProperty: SetConnectionProperty? =
        symbol("CGSSetConnectionProperty")

    /// Whether the private route exists in this macOS at all — a *capability*, in the shape
    /// `transitionMode`'s Screen Recording grant has, and the thing `[mouse] hide` is clamped against.
    /// Looking the symbols up costs nothing and calls nothing.
    static var isAvailable: Bool { mainConnectionID != nil && setConnectionProperty != nil }

    /// Whether the property has been set on this connection. Once is enough — it is a property of the
    /// connection, which lives as long as the process.
    private static var isMarked = false

    /// Mark this connection as one that may hide the cursor in the background, and answer whether it
    /// worked. Called on the first hide and never again. A property that stops being honoured while the
    /// symbol survives is a silent no-op nothing can detect; a symbol that has gone is `isAvailable`'s.
    static func markConnection() -> Bool {
        guard !isMarked else { return true }
        guard let mainConnectionID, let setConnectionProperty else { return false }
        let connection = mainConnectionID()
        isMarked = setConnectionProperty(connection, connection, propertyKey as CFString,
                                         kCFBooleanTrue) == 0
        return isMarked
    }

    /// One symbol, by name, out of whatever is already loaded. `RTLD_DEFAULT` rather than a handle:
    /// CoreGraphics is linked for its public half regardless, and opening a library by path is the
    /// half of "no private symbols" this exception does not take.
    private static func symbol<T>(_ name: String) -> T? {
        // `RTLD_DEFAULT` is a `#define` for `((void *)-2)`, so it does not import into Swift.
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}
