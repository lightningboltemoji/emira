import AppKit
import EmiraConfig
import EmiraCore

// The editors for the surfaces `ConfigSchema` cannot describe as a table — and the written record of
// which ones have none.
//
// `ControlFactory` is a fold: a `Setting` carries its own kind, so a control falls out of the entry. A
// bespoke surface carries no kind, by definition, so each one that gets an editor gets a *written* one.
// What keeps that from being a licence to forget is `notEditable`: `BespokeTests` requires every entry
// on `ConfigSchema.bespoke` to build an editor or to be named here with a reason, which is the rule
// `Catalog.notDemonstrable` keeps one rung down.

@MainActor
enum BespokeEditors {

    /// The editor for `surface`, or `nil` when it is one of the surfaces named on `notEditable`.
    static func editor(for surface: Bespoke,
                       onChange: @escaping @MainActor (Draft.Edit) -> Void,
                       onHover: @escaping @MainActor (String) -> Void = { _ in })
        -> (any PanelRow)? {
        guard notEditable[surface.key] == nil else { return nil }
        let editor: any PanelRow
        switch surface.key {
        case "layout.outer-gap":
            editor = OuterGapsControl(surface: surface, onChange: onChange, onHover: onHover)
        case "keys":
            editor = KeysEditor(surface: surface, onChange: onChange, onHover: onHover)
        default:
            // Unreachable while `BespokeTests` passes: a surface with neither an editor nor a reason
            // fails there rather than opening on a blank row here.
            return nil
        }
        (editor.view as? RowView)?.onHover = { onHover(editor.key) }
        return editor
    }

    /// Whether `surface` has an editor — what decides whether its section becomes a tab at all.
    static func isEditable(_ surface: Bespoke) -> Bool { notEditable[surface.key] == nil }

    /// The surfaces with no editor, and why. A reason rather than a bare list: "why is this only in the
    /// file" is the only question the omission provokes, and the answer is a fact about what the editor
    /// would have to do rather than about how much time there was.
    static let notEditable: [String: String] = [
        "window-rules": """
        Order in the file is precedence, so an editor has to move whole blocks — an API `ConfigDocument` \
        does not have, and deliberately: it splices single values, and `set` refuses a positional index \
        rather than making one public by accident.
        """,
    ]
}

// Outer gaps, the simpler of the two bespoke editors. `[keys]` is `KeysEditor.swift`, which is a list
// rather than a row and needs the space to say why.
//
// **Four fields on one row, not a row each.** The four edges are one setting the file happens to spell
// five ways, and four rows of "Outer gap top" would say the opposite — as well as pushing every other
// Layout setting off the first screen of the panel.

/// `layout.outer-gap` and its four per-side spellings.
@MainActor
final class OuterGapsControl: PanelRow {
    let key: String
    var view: NSView { row.view }

    /// The four edges, in the order the reader reads them — which is also the order the sentence under
    /// the row names them, so the captions need no legend.
    private static let sides: [(caption: String, name: String, edge: KeyPath<EdgeInsets, Double>)] = [
        ("T", "top", \.top), ("L", "left", \.left),
        ("B", "bottom", \.bottom), ("R", "right", \.right),
    ]

    private let row: ControlRow
    private let fields: [NSTextField]
    private let onChange: @MainActor (Draft.Edit) -> Void

    /// The key one edge is spelled by — what a take is looked up under, for hovering and for editing
    /// alike, so the mock marks the same edge either way.
    static func key(ofSide name: String) -> String { "layout.outer-gap-\(name)" }

    init(surface: Bespoke, onChange: @escaping @MainActor (Draft.Edit) -> Void,
         onHover: @escaping @MainActor (String) -> Void = { _ in }) {
        self.key = surface.key
        self.onChange = onChange

        // **Stacks rather than a chain of constraints between the eight views.** Four captioned fields
        // pinned leading-to-trailing across a fixed well is over-constrained the moment their intrinsic
        // widths don't add up to it, and what that costs is a constraint broken at runtime and a row
        // that looks nearly right. `.equalSpacing` has the same intent and cannot be unsatisfiable.
        var fields: [NSTextField] = []
        var cells: [NSView] = []
        for (caption, name, _) in Self.sides {
            let label = NSTextField(labelWithString: caption)
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.textColor = .secondaryLabelColor

            let field = NSTextField()
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.toolTip = name.prefix(1).uppercased() + name.dropFirst()
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 44).isActive = true
            fields.append(field)

            let pair = NSStackView(views: [label, field])
            pair.orientation = .horizontal
            pair.spacing = 3
            pair.translatesAutoresizingMaskIntoConstraints = false

            // **Each edge reports its own hover**, which is what lets the mock mark the one under the
            // hand. Four numbers on one row is the right editor and the wrong pointer target, so the
            // target is put back a level down rather than the row being split into four.
            let cell = RowView()
            cell.addSubview(pair)
            NSLayoutConstraint.activate([
                pair.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                pair.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                pair.topAnchor.constraint(equalTo: cell.topAnchor),
                pair.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            ])
            cell.onHover = { onHover(Self.key(ofSide: name)) }
            cells.append(cell)
        }

        let well = NSStackView(views: cells)
        well.orientation = .horizontal
        well.distribution = .equalSpacing
        well.alignment = .centerY

        self.fields = fields
        row = ControlRow(label: surface.label, help: surface.help, well: well)
        for field in fields {
            field.target = self
            field.action = #selector(typed(_:))
        }
    }

    func show(_ draft: Draft) {
        let insets = draft.config.outerGaps
        for (field, side) in zip(fields, Self.sides) {
            // Never over the hand — `show` runs after every edit anywhere in the panel.
            guard field.currentEditor() == nil else { continue }
            field.stringValue = TOMLValue.number(insets[keyPath: side.edge]).spelled
        }
    }

    /// **Always a per-side key, never the base one.** Writing `outer-gap` would silently move the three
    /// edges the user did not touch; writing the side that was touched moves that side, whether or not
    /// a base key is what it was resolving against. `ConfigDocument.setOrUnset` is then what keeps the
    /// file from filling up with lines that repeat the base.
    @objc private func typed(_ sender: NSTextField) {
        guard let index = fields.firstIndex(of: sender) else { return }
        let key = Self.key(ofSide: Self.sides[index].name)
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        // Handed over as text when it is not a number, so the schema refuses it in its own words —
        // `NumberControl`'s rule, and for its reason.
        guard let value = Double(text) else { return onChange(.key(key, .string(text))) }
        onChange(.key(key, .number(value)))
    }
}
