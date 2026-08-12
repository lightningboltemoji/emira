import AppKit
import EmiraConfig

// The controls, floating below the mock monitor and blurring the scrim beneath them.
//
// `.withinWindow` rather than `.behindWindow`: the slab sits *on* the backdrop, so what it blurs is the
// already-blurred desktop plus the dim, which is what gives it a second step of depth. A second
// `.behindWindow` view would sample the same thing the backdrop does and read as flat.
//
// **Nothing here describes a setting.** The rows are a fold over `ConfigSchema.settings` filtered by
// section; the label, the sentence beneath it and the bounds all come off the entry. That is the
// property `IMPLEMENTATION.md` §9 claims, finally collecting on it.
//
// The surfaces the table cannot describe fold too, off `ConfigSchema.bespoke` — the one thing that is
// *not* automatic there is the editor, which `BespokeEditors` either has or names a reason for. What
// this file still decides is order: settings, then surfaces, then the dials behind the disclosure.

@MainActor
final class ControlSlab: NSVisualEffectView {

    /// A control moved. The window forwards it to the draft.
    var onChange: (@MainActor (Draft.Edit) -> Void)?
    /// A drag began or ended — a take pauses while the hand is on a control.
    var onDragChanged: (@MainActor (Bool) -> Void)?
    /// The section on screen changed, so the mock wants that section's set.
    var onSection: (@MainActor (Setting.Section) -> Void)?
    /// The pointer came to rest on a row, which names the setting or the surface under it. The window
    /// decides whether it has dwelt long enough.
    var onHover: (@MainActor (String) -> Void)?
    var onSave: (@MainActor () -> Void)?
    var onDiscard: (@MainActor () -> Void)?
    /// The banner's two answers, when the file has changed underneath an edited draft.
    var onReload: (@MainActor () -> Void)?
    var onKeepEditing: (@MainActor () -> Void)?

    static let width: CGFloat = 720

    // How tall the panel is, and it is **derived**: a scroller that is a whole number of rows tall is
    // the strongest claim a list can make that it ends there, and this one was making it. 258 pt of
    // scroller against a 52 pt row pitch is 4.96 rows, so the fifth row's bottom edge landed two points
    // above the fold and eight rows of Layout read as five. Half a row of the sixth is the affordance —
    // content rather than chrome, and the only one that survives someone who has turned scroll bars off.
    //
    // **The half is taken off rather than added on**, so the panel is 24 pt shorter than it was and not
    // 28 taller. The mock, the gap and the slab are one centred stack, and its height is already close
    // to a scaled display's: at 1352 × 878 — "Larger Text" on this machine — a 0.52-width mock plus the
    // 44 pt gap plus a 380 pt slab is two points more than the screen. Growing the panel to show one
    // more row would have bought the affordance by making that worse everywhere.

    static let rowSpacing: CGFloat = 6
    /// One row's contribution to the scroller's height.
    static let rowPitch: CGFloat = ControlRow.height + rowSpacing
    /// Rows before the fold. The half is the whole point; a whole number here undoes this.
    static let visibleRows: CGFloat = 4.5
    /// The scroller's height, which is what the fraction is really about.
    static let viewport: CGFloat = rowPitch * visibleRows
    /// Everything that is not the scroller: the tabs, the banner's collapsed gap, the button row and
    /// the insets between them. Measured rather than derived, and `ScrollFadeTests` measures it again —
    /// AppKit owns a button's height, so a number taken from it needs a test that takes it again.
    static let chrome: CGFloat = 122
    static let height: CGFloat = chrome + viewport

    private let tabs = NSSegmentedControl()
    private let scroll = NSScrollView()
    private let rows = NSStackView()
    private let disclosure = NSButton()
    private let advanced = NSStackView()

    private let refusal = NSTextField(labelWithString: "")
    private let banner = NSView()
    private let bannerText = NSTextField(labelWithString: "")
    private let save = NSButton()
    private let discard = NSButton()

    /// Every section with something to show, in schema order — a setting, or a bespoke surface that has
    /// an editor. `keys` and `windowRules` have neither, so they never become a tab that opens on
    /// nothing; `layout` would qualify either way, and does carry one.
    static let sections: [Setting.Section] = Setting.Section.allCases.filter { section in
        ConfigSchema.settings.contains { $0.section == section }
            || ConfigSchema.bespoke.contains {
                $0.section == section && BespokeEditors.isEditable($0)
            }
    }

    private var section: Setting.Section
    /// The rows on screen, in the order they are stacked. Readable so a test can ask what the
    /// panel actually built rather than re-deriving what it should have.
    private(set) var controls: [any PanelRow] = []
    private var showsAdvanced = false
    /// What was last shown. Held **only** to re-display it: switching section throws every control away
    /// and builds new ones, and a fresh control has no value until it is told one.
    private var shown: Draft?

    init() {
        section = Self.sections.first ?? .layout
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        material = SettingsStyle.backdropMaterial
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = SettingsStyle.slabRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = SettingsStyle.slabEdge
        build()
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // The selector form takes a zeroing-weak reference, so this is belt and braces rather than a leak
    // being closed — `Environment.swift` documents the block form, which is the one that does leak.
    deinit { NotificationCenter.default.removeObserver(self) }

    private func build() {
        let inset = SettingsStyle.slabInset

        tabs.segmentCount = Self.sections.count
        for (i, section) in Self.sections.enumerated() {
            tabs.setLabel(section.title, forSegment: i)
        }
        tabs.trackingMode = .selectOne
        tabs.segmentDistribution = .fillEqually
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabPicked)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabs)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Self.rowSpacing
        rows.translatesAutoresizingMaskIntoConstraints = false

        // **Flipped**, or the stack sits at the bottom of the scroller and a short section opens with
        // its rows pushed to the floor. A document view's origin is its bottom-left unless it says
        // otherwise, and a settings list reads downward.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        // The scroller carries the fade, so what dissolves is the rows and not the slab under them.
        scroll.wantsLayer = true
        // How far it is scrolled…
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        // …and how much there is to scroll, which lands a layout pass after the rows do.
        document.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.frameDidChangeNotification,
                                               object: document)

        refusal.font = .systemFont(ofSize: 11)
        refusal.textColor = .systemRed
        refusal.lineBreakMode = .byTruncatingTail
        refusal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(refusal)

        buildBanner()

        save.title = "Save"
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.target = self
        save.action = #selector(savePressed)
        save.translatesAutoresizingMaskIntoConstraints = false
        addSubview(save)

        discard.title = "Discard"
        discard.bezelStyle = .rounded
        discard.target = self
        discard.action = #selector(discardPressed)
        discard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(discard)

        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: topAnchor, constant: inset - 4),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            tabs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            banner.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            banner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            scroll.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            scroll.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -12),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -16),

            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            refusal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            refusal.trailingAnchor.constraint(lessThanOrEqualTo: discard.leadingAnchor, constant: -12),
            refusal.centerYAnchor.constraint(equalTo: save.centerYAnchor),

            save.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            save.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset + 4),
            save.widthAnchor.constraint(equalToConstant: 86),
            discard.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -10),
            discard.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            discard.widthAnchor.constraint(equalToConstant: 86),
        ])
    }

    /// The changed-underneath-you banner. Hidden by collapsing its height, so the rows above it take the
    /// space back rather than leaving a gap where it would have been.
    private func buildBanner() {
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 8
        banner.layer?.cornerCurve = .continuous
        banner.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
        banner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(banner)

        bannerText.stringValue = "The config file changed on disk."
        bannerText.font = .systemFont(ofSize: 11)
        bannerText.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(bannerText)

        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadPressed))
        reload.bezelStyle = .rounded
        reload.controlSize = .small
        reload.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(reload)

        let keep = NSButton(title: "Keep editing", target: self, action: #selector(keepPressed))
        keep.bezelStyle = .rounded
        keep.controlSize = .small
        keep.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(keep)

        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bannerHeight,
            bannerText.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            bannerText.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            keep.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -8),
            keep.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            reload.trailingAnchor.constraint(equalTo: keep.leadingAnchor, constant: -6),
            reload.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
        ])
        banner.isHidden = true
    }

    private var bannerHeight: NSLayoutConstraint!

    /// Put the section's rows in the stack: the plain ones, then a disclosure holding the advanced ones.
    private func rebuildRows() {
        for view in rows.arrangedSubviews { view.removeFromSuperview() }
        for view in advanced.arrangedSubviews { view.removeFromSuperview() }
        controls = []

        let entries = ConfigSchema.settings.filter { $0.section == section }
        let surfaces = ConfigSchema.bespoke.filter { $0.section == section }
        for setting in entries where !setting.isAdvanced {
            add(setting, to: rows)
            // A surface goes where the entry says it goes, which is where the generated document puts
            // it too — outer gaps under the two other gaps, not after the preset lists.
            for surface in surfaces where surface.after == setting.key { add(surface, to: rows) }
        }
        for surface in surfaces where surface.after == nil { add(surface, to: rows) }

        let dials = entries.filter(\.isAdvanced)
        guard !dials.isEmpty else { return }

        disclosure.setButtonType(.onOff)
        disclosure.bezelStyle = .disclosure
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggleAdvanced)
        disclosure.state = showsAdvanced ? .on : .off

        let caption = NSTextField(labelWithString: "Advanced")
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = .secondaryLabelColor
        let header = NSStackView(views: [disclosure, caption])
        header.orientation = .horizontal
        header.spacing = 4
        rows.addArrangedSubview(header)

        advanced.orientation = .vertical
        advanced.alignment = .leading
        advanced.spacing = 6
        advanced.isHidden = !showsAdvanced
        rows.addArrangedSubview(advanced)
        advanced.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        for setting in dials {
            add(setting, to: advanced)
        }
    }

    /// Build the section's rows and put the draft's values in them. Every path that changes which
    /// controls exist goes through here, so none of them can leave a control blank.
    private func rebuild() {
        rebuildRows()
        if let shown { for control in controls { control.show(shown) } }
        // The content's height just changed, which is half of what the fade is computed from.
        updateFade()
    }

    /// **Added first, constrained second.** A constraint between two views with no common ancestor is
    /// not a layout the engine can hold an opinion about, and pinning a row's width to a stack it is not
    /// yet in is exactly that.
    private func add(_ setting: Setting, to stack: NSStackView) {
        add(ControlFactory.control(
            for: setting,
            onChange: { [weak self] edit in self?.onChange?(edit) },
            onDrag: { [weak self] dragging in self?.onDragChanged?(dragging) },
            onHover: { [weak self] key in self?.onHover?(key) }), to: stack)
    }

    /// A bespoke surface's editor, when it has one. A surface with none is silently absent here and
    /// loudly absent in `BespokeTests`, which is the right way round.
    private func add(_ surface: Bespoke, to stack: NSStackView) {
        guard let editor = BespokeEditors.editor(
            for: surface,
            onChange: { [weak self] edit in self?.onChange?(edit) },
            onHover: { [weak self] key in self?.onHover?(key) })
        else { return }
        add(editor, to: stack)
    }

    private func add(_ control: any PanelRow, to stack: NSStackView) {
        controls.append(control)
        stack.addArrangedSubview(control.view)
        control.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// Show what the draft holds — every control, the refusal sentence, and whether there is anything to
    /// save. **The one direction values travel**: a control never writes its own widget back from its
    /// own callback, so a refused edit leaves the file's value on screen rather than the typed one.
    func show(_ draft: Draft) {
        shown = draft
        for control in controls { control.show(draft) }
        refusal.stringValue = draft.refusal ?? ""
        save.isEnabled = draft.isDirty
        discard.isEnabled = draft.isDirty
    }

    // The fade
    //
    // A gradient mask, so a row at an overflowing edge dissolves into the blur behind the slab rather
    // than into a painted colour — which is the reason a fade suits *this* panel and not merely any
    // panel: the material is already what is behind it.
    //
    // **The scroller's own layer is geometry-flipped, and the mask must not flip itself.** AppKit sets
    // `isGeometryFlipped` on the backing layer of a flipped view, and an `NSScrollView` is flipped when
    // its document view is — so inside it `(0.5, 0)` is already the *top* edge, and a mask that flipped
    // its own geometry as well would cancel that and put the fade at the wrong end. Which is what the
    // first version did: a list scrolled to the top wore a fade at the top.
    //
    // On the scroll view rather than on the clip view inside it, because the scroller's bounds do not
    // travel, so the mask holds still and only its stops move.
    //
    // **Two inputs, and both are watched.** How far it is scrolled is the clip view's bounds; how much
    // there is to scroll is the document view's frame, and that one settles a layout pass *after* the
    // rows go in — `rebuild()` asking for the fade is asking about a height that has not been resolved
    // yet. Watching only the first is why the fade used to be missing until the first scroll: the real
    // numbers arrived with nothing attached to them.

    /// The fade at full strength. Just under half a row, so what it eats is the run of a row rather
    /// than the row.
    static let fadeLength: CGFloat = 20

    /// What the fade should be, from the two things it is made of.
    var wantedFade: ScrollFade {
        let clip = scroll.contentView
        return ScrollFade.over(offset: Double(clip.bounds.origin.y),
                               viewport: Double(clip.bounds.height),
                               content: Double(scroll.documentView?.frame.height ?? 0),
                               length: Double(Self.fadeLength))
    }

    /// Recompute the fade and put it on the scroller.
    ///
    /// **The layer is the fact.** This used to skip its work whenever the numbers matched what it last
    /// wrote — a remembered value standing in for the thing it remembers, and one that says "already
    /// correct" while the scroller carries no mask at all is a fade that never appears. Doing it anyway
    /// costs four numbers.
    private func updateFade() {
        let wanted = wantedFade
        guard let mask = self.mask(for: wanted) else { return }
        // **No implicit animation.** A gradient that animates its locations turns every scroll tick
        // into a quarter-second cross-fade, and the fade lags the content it is describing.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = scroll.bounds
        mask.locations = wanted.locations.map(NSNumber.init(value:))
        CATransaction.commit()
    }

    /// The mask layer, installed when there is something to fade and taken off when there is not — a
    /// list that fits is not masked at all, rather than masked with a gradient that hides nothing.
    private func mask(for wanted: ScrollFade) -> CAGradientLayer? {
        guard wanted != .none else {
            scroll.layer?.mask = nil
            return nil
        }
        if let existing = scroll.layer?.mask as? CAGradientLayer { return existing }
        let gradient = CAGradientLayer()
        // Top to bottom — the scroller's layer is already geometry-flipped, so this runs downward, and
        // `isGeometryFlipped` is deliberately left alone rather than set to say so twice.
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.colors = [NSColor.clear.cgColor, NSColor.black.cgColor,
                           NSColor.black.cgColor, NSColor.clear.cgColor]
        gradient.locations = wanted.locations.map(NSNumber.init(value:))
        gradient.frame = scroll.bounds
        scroll.layer?.mask = gradient
        return gradient
    }

    /// The scroller moved, or what is in it changed height. Both arrive here.
    @objc private func scrolled() { updateFade() }

    override func layout() {
        super.layout()
        updateFade()
    }

    /// Raise or lower the changed-underneath-you banner.
    func showBanner(_ shown: Bool) {
        banner.isHidden = !shown
        bannerHeight.constant = shown ? 30 : 0
    }

    @objc private func tabPicked() {
        select(section: tabs.selectedSegment)
    }

    /// Show the `index`-th tab, exactly as clicking it does — the one path that changes which controls
    /// exist, so a test asks for a section the same way a hand does.
    func select(section index: Int) {
        guard Self.sections.indices.contains(index) else { return }
        tabs.selectedSegment = index
        section = Self.sections[index]
        showsAdvanced = false
        rebuild()
        onSection?(section)
    }

    @objc private func toggleAdvanced() {
        showsAdvanced = disclosure.state == .on
        advanced.isHidden = !showsAdvanced
        updateFade()
    }

    @objc private func savePressed() { onSave?() }
    @objc private func discardPressed() { onDiscard?() }
    @objc private func reloadPressed() { onReload?() }
    @objc private func keepPressed() { onKeepEditing?() }
}

/// How much of each end of the scroller is faded out, as a fraction of its height.
///
/// **Asymmetric, and that is the whole of it.** A fade at an end with nothing beyond it is decoration;
/// what carries information is the fade being *there* on the side that has more and *gone* on the side
/// that doesn't. A panel that dims both edges however much it holds has stopped saying anything, and a
/// list that fits fades neither.
///
/// The arithmetic is here rather than in the layer code because this is the part with a decision in it.
struct ScrollFade: Equatable {
    /// The fraction of the scroller's height dissolved at the top, and at the bottom.
    var top: Double
    var bottom: Double

    static let none = ScrollFade(top: 0, bottom: 0)

    /// The fade for a scroller `viewport` tall showing `content`, scrolled `offset` down from the top.
    ///
    /// `length` is the fade at full strength, in points. **It tapers over the last `length` points of
    /// travel** rather than switching off at the end of the run: a fade that vanished on the final
    /// pixel would read as a flicker at exactly the moment the user is looking at that edge.
    static func over(offset: Double, viewport: Double, content: Double, length: Double) -> ScrollFade {
        // A half point of slack: a content height that rounds to the viewport's is a list that fits,
        // and fading it would be the decoration this exists to avoid.
        guard viewport > 0, length > 0, content > viewport + 0.5 else { return .none }
        let above = min(max(0, offset), content - viewport)
        let below = max(0, content - viewport - max(0, offset))
        return ScrollFade(top: min(above, length) / viewport,
                          bottom: min(below, length) / viewport)
    }

    /// The four stops a gradient mask wants, **from the top edge down**: transparent, opaque, opaque,
    /// transparent. A zero-width fade collapses its pair onto the edge, which is a mask that hides
    /// nothing there.
    ///
    /// Top-down because the layer this drives sits under a **geometry-flipped** parent — AppKit sets
    /// `isGeometryFlipped` on the backing layer of a flipped view, and an `NSScrollView` is flipped when
    /// its document view is. Measured rather than assumed: a probe sublayer at layer-y 0 inside the
    /// scroller converts to the scroller's *top* edge in the slab. So the mask must not flip itself, and
    /// the low stops are the top.
    ///
    /// Which end is which is the one fact here a laid-out view cannot be asked, and getting it backwards
    /// is invisible until someone scrolls to an edge and finds the fade at the other one — which is how
    /// the first version was found, by someone scrolling to the top and seeing a fade there.
    var locations: [Double] { [0, top, 1 - bottom, 1] }
}

/// A view whose origin is its top left. `NSScrollView` hands its document view a bottom-left origin
/// otherwise, which stacks a settings list upward from the floor.
@MainActor
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
