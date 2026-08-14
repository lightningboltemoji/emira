import EmiraConfig
import EmiraCore
import EmiraGuide

// The guides on the mock desktop — **the real ones**, drawn by `EmiraGuide` through `GuideModel` and
// `NamesModel`, at the mock's own scale. A preview that drew its own would be a second opinion about
// every setting beside it.
//
// So what is here is the two facts a *host* owns: how a mock desktop becomes a `GuideInput`, and where
// the panel a drawing carries ends up on screen. **Which model a style runs is not one of them** —
// `GuideDrawing.of` answers that for both hosts, so a third guide is not a switch in a window.

/// One frame of one guide on the mock desktop: what it draws, the settings it obeys, and where it sits.
public struct GuideFrame: Sendable, Equatable {

    /// The model already run — **the same value the daemon hands its own renderer**, carrying the style
    /// it belongs to and the panel the model placed.
    public let drawing: GuideDrawing
    /// The whole `[guide]` table, because a renderer reads what is not geometry out of it.
    public let settings: GuideSettings
    /// Where the panel goes, in true points on the display. Separate from the drawing's own because it
    /// travels: picking `bottom-left` sends the guide gliding across the desktop under a spring, and the
    /// frame it is drawn at is not the frame the model placed.
    public let panel: Rect

    public var style: GuideStyle { drawing.style }

    /// The guides in `showing` over a mock desktop whose windows are at `frames`, in drawing order —
    /// **which of them are up is the caller's**, because a dwell is one guide's and the model owns the
    /// clock. A style with nothing to draw is absent, exactly as the daemon shows nothing for one.
    static func all(showing styles: [GuideStyle], config: Config, scene: Scene, workingArea: Rect,
                    frames: [WindowId: Rect]) -> [GuideFrame] {
        guard !styles.isEmpty else { return [] }
        let input = GuideInput(scene: scene, workingArea: workingArea, frames: frames)
        return styles.compactMap { style in
            GuideDrawing.of(style, input: input, settings: config.guide, face: GuideTypeface.face,
                            name: MockNames.name(for:))
                .map { GuideFrame(drawing: $0, settings: config.guide, panel: $0.panel) }
        }
    }

    /// The same guide with its panel somewhere else — what the movement spring produces while
    /// `position` is being changed and the guide is gliding across the desktop.
    public func on(panel moved: Rect) -> GuideFrame {
        GuideFrame(drawing: drawing, settings: settings, panel: moved)
    }
}

extension GuideInput {
    /// A mock desktop as a guide's model sees one. **A role stands in for a bundle id**, which a
    /// renderer never resolves itself — it asks `GuideSources`, and the mock answers. Floats take no
    /// part, exactly as they take none in the real guide.
    init(scene: Scene, workingArea: Rect, frames: [WindowId: Rect]) {
        self.init(workingArea: workingArea,
                  columns: scene.columns.map { column in
                      GuideInput.Column(id: column.id,
                                        windows: column.windows.map {
                                            GuideInput.Window(id: $0.id, bundleId: $0.role.rawValue)
                                        })
                  },
                  frames: frames,
                  focus: scene.focus)
    }
}

/// The word each mock role is named by — **fixed, where the icon is resolved**: an icon is recognisable
/// whichever candidate app answered, and a word is not.
enum MockNames {
    static let names: [MockRole: String] = [
        .editor: "Code", .browser: "Safari", .terminal: "Terminal",
        .chat: "Slack", .notes: "Notes", .music: "Music",
    ]

    /// The name for a role spelled as a bundle id — the shape `GuideSources` asks in.
    static func name(for bundleId: String) -> String {
        MockRole(rawValue: bundleId).flatMap { names[$0] } ?? bundleId
    }
}
