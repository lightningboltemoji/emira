import Foundation

// Which guides there are, and what one frame of one is.
//
// **A style is the unit every host counts in** — a renderer, a spring, a camera and a table of settings
// each belong to one guide, and two guides on a desktop are two of everything rather than one of each
// shared. `allCases` is their drawing order, so the minimap is under the row of names in both hosts and
// neither holds a second list of its own to drift.
//
// **A drawing is the model already run**, which is what a host hands its renderer. A renderer that ran
// the model itself and answered where its panel went would cost the settings window a second derivation
// of the same expression — it needs the panel *before* it draws, to frame a camera and to seed a
// movement spring — and would put a switch over the styles in a host rather than here.

/// One of the guides.
public enum GuideStyle: String, Sendable, Equatable, CaseIterable {
    /// The minimap of the strip: the strip's own geometry, small.
    case preview
    /// The strip as a row of app names.
    case names
}

/// One frame of one guide: everything inside the panel, and where the panel goes.
public enum GuideDrawing: Equatable, Sendable {
    case preview(GuideLayout)
    case names(NamesModel)

    /// Which guide this is a frame of.
    public var style: GuideStyle {
        switch self {
        case .preview: return .preview
        case .names:   return .names
        }
    }

    /// The panel the model placed, in core (top-left, global) screen coordinates. Where a host puts it
    /// on screen is the host's — a preview's travels under a spring — and this is where it belongs.
    public var panel: Rect {
        switch self {
        case .preview(let layout): return layout.panel
        case .names(let model):    return model.panel
        }
    }

    /// What `style` draws over `input`, or `nil` for a guide with **nothing to draw** — degenerate
    /// numbers, or a strip with no column for a row of names to name. Both hosts answer `nil` by
    /// showing nothing: a guide left carrying its last frame would answer *where am I* with the place
    /// you just left.
    ///
    /// `face` measures a word and `name` resolves an app to one. Only the names guide asks for either,
    /// and both are the caller's because only a host holds a font — but they are taken here rather than
    /// in the renderer, so the panel is answered before anything is drawn.
    public static func of(_ style: GuideStyle, input: GuideInput, settings: GuideSettings,
                          face: GuideFace, name: (String) -> String = { $0 }) -> GuideDrawing? {
        switch style {
        case .preview:
            return GuideModel.layout(input, settings: settings.preview).map(GuideDrawing.preview)
        case .names:
            return NamesModel.model(input, settings: settings.names, face: face, name: name)
                .map(GuideDrawing.names)
        }
    }
}
