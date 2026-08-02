import Foundation

/// What the pointer plane is owed, and it is owed rather than observed: **neither field is a fact about
/// the desktop**, which is why they are not `World`'s.
///
/// Nothing can refresh `isCursorHidden` — no public API reports cursor visibility, and any application
/// activating discards a background hide — so `Event.appActivated` re-asserts it instead. A visit is a
/// debt the reducer took on and has not paid. One type, because they are one subsystem's.
public struct Pointer: Sendable, Equatable, Codable {

    /// The window the pointer owes a visit, held until the transition revealing it closes. Newest wins,
    /// the resolution `FocusIntent` and every retargeted animator already use: a second focus mid-scroll
    /// means the pointer was always going to the second window.
    public var pendingWarp: WindowId?

    /// Whether emira *wants* the pointer hidden — an intent, not a fact.
    public var isCursorHidden: Bool

    public init(pendingWarp: WindowId? = nil, isCursorHidden: Bool = false) {
        self.pendingWarp = pendingWarp
        self.isCursorHidden = isCursorHidden
    }
}
