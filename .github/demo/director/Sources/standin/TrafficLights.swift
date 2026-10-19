import AppKit
import ObjectiveC

/// Fiber's traffic lights (~/Developer/fiber, `WindowFrame` and `BrowserWindowController`): moved in
/// from the corner by a subclass of AppKit's private frame view, in a capsule of rimmed glass.
@MainActor
enum TrafficLights {
    /// The capsule's top-left corner is this far from the window's.
    static let edgeInset: CGFloat = 16
    /// The capsule reaches this far past the lights, rim included.
    static let padding = NSSize(width: 14, height: 13)
    static let rimWidth: CGFloat = 5

    private static var subclasses: [ObjectIdentifier: AnyClass] = [:]

    /// A subclass of `base`, the frame view class AppKit chose, that puts the lights `edgeInset +
    /// padding` from the window's left edge, centred in a title bar as tall as the capsule plus its inset.
    static func frameViewClass(base: AnyClass) -> AnyClass {
        if let subclass = subclasses[ObjectIdentifier(base)] { return subclass }
        guard let subclass = objc_allocateClassPair(base, "StandIn\(NSStringFromClass(base))", 0) else { return base }
        override("_minXTitlebarWidgetInset", in: subclass, base: base, value: edgeInset + padding.width)
        // The lights are 14pt.
        override("_titlebarHeight", in: subclass, base: base, value: 2 * (edgeInset + padding.height) + 14)
        let center: @convention(block) (NSView) -> Bool = { _ in true }
        class_addMethod(
            subclass, NSSelectorFromString("_shouldCenterTrafficLights"), imp_implementationWithBlock(center), "B@:")
        objc_registerClassPair(subclass)
        subclasses[ObjectIdentifier(base)] = subclass
        return subclass
    }

    /// Makes `subclass` answer `value` to one of `base`'s CGFloat getters.
    private static func override(_ name: String, in subclass: AnyClass, base: AnyClass, value: CGFloat) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(base, selector) else { return }
        let getter: @convention(block) (NSView) -> CGFloat = { _ in value }
        class_addMethod(subclass, selector, imp_implementationWithBlock(getter), method_getTypeEncoding(method))
    }

    /// Puts the capsule behind the lights, which stay in the title bar above it.
    static func addCapsule(to window: NSWindow) {
        window.layoutIfNeeded()
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .reduce(NSRect.null) { $0.union($1.convert($1.bounds, to: nil)) }
        guard !buttons.isNull, let content = window.contentView else { return }
        let capsule = RimmedGlass(frame: buttons.insetBy(dx: -padding.width, dy: -padding.height), rimWidth: rimWidth)
        capsule.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(capsule)
    }
}

/// Glass in a rim of glass, a capsule as tall as it is.
private final class RimmedGlass: NSView {
    private let outer = NSGlassEffectView()
    private let inner = NSGlassEffectView()

    init(frame: NSRect, rimWidth: CGFloat) {
        super.init(frame: frame)
        let rim = NSView(frame: bounds)
        inner.frame = rim.bounds.insetBy(dx: rimWidth, dy: rimWidth)
        rim.addSubview(inner)
        outer.frame = bounds
        outer.contentView = rim
        outer.cornerRadius = frame.height / 2
        inner.cornerRadius = frame.height / 2 - rimWidth
        addSubview(outer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
