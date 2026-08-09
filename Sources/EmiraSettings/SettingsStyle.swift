import AppKit
import QuartzCore
import EmiraCore

// The composition's numbers, in one place because they are a design and not a scattering of literals.
//
// Two of them were **measured rather than chosen**, and the failure mode of getting them wrong is
// silent: `NSVisualEffectView` has no material that reports "I am opaque", so a scrim built on
// `.underPageBackground` or `.windowBackground` renders as flat black with the blur working perfectly
// behind it. `.hudWindow` and `.fullScreenUI` are the two that pass light through.

public enum SettingsStyle {

    // The scrim

    /// The backdrop material. **Not a taste** — see above.
    public static let backdropMaterial: NSVisualEffectView.Material = .hudWindow

    /// Black over the blur. Enough that the mock reads as the foreground, little enough that the user's
    /// own desktop is still recognisably theirs behind it.
    public static let dim: CGFloat = 0.34

    /// Above the menu bar and the Dock. A scrim that stops short of the menu bar is not a scrim, and
    /// `.floating` — where `Overlay` sits — is below it.
    ///
    /// One under the shielding level so that a system alert still outranks a settings window.
    public static var scrimLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
    }

    // The presentation
    //
    // The window is **set down** on the desktop and **lifted off** it again: the whole composition
    // dissolves while the stack it carries travels the last few percent of a zoom, from just above the
    // glass on the way in and back above it on the way out.
    //
    // One duration and one **symmetric** curve for both directions, so lifting off is setting down
    // played backwards rather than a second animation that happens to take the same time. An exit that
    // does not undo the entrance reads as a different object leaving than the one that arrived.

    /// How long the composition takes to be set down, and to be lifted off again.
    public static let present: TimeInterval = 0.22

    /// Its own reverse — `easeInEaseOut` is symmetric about its midpoint, which is what makes one
    /// constant serve both directions.
    public static var presentCurve: CAMediaTimingFunction {
        CAMediaTimingFunction(name: .easeInEaseOut)
    }

    /// The scale the composition arrives from and leaves to. **Above one**: it comes from the viewer's
    /// side of the glass and settles onto it, which is what "set down" means from where the user sits.
    /// Below one it would grow out of the screen instead, which is the same animation and the opposite
    /// story. Light enough that it is depth rather than a zoom: 4% of a 930 pt stack is 19 pt of travel
    /// at each edge.
    public static let liftedScale: CGFloat = 1.04

    // The mock monitor

    /// The mock's width as a fraction of the display's. Generous because the monitor floats on a scrim
    /// rather than sharing a window with the controls, but bounded by the stack it is the top of: the
    /// monitor, a gap and the control slab have to leave a margin on the shortest screen emira runs on.
    /// At 0.52 on an 1800 pt display an 8 pt gap still draws at 4.2 pt — 8 device pixels at 2×.
    public static let mockWidthFraction: Double = 0.52

    /// The gap between the bottom of the mock monitor and the top of the control slab.
    public static let stackGap: CGFloat = 44

    public static let monitorRadius: CGFloat = 14
    public static let monitorShadowOpacity: Float = 0.7
    public static let monitorShadowRadius: CGFloat = 52
    public static let monitorShadowOffset = CGSize(width: 0, height: -18)

    /// The mock's own hairline, which is what makes it read as a slab rather than a hole cut in the dim.
    /// Drawn *over* everything inside the panel, which is why a mark on the display's outermost point
    /// has to be slid in by its width to survive.
    public static var monitorEdge: CGColor { NSColor.white.withAlphaComponent(0.22).cgColor }
    public static let monitorEdgeWidth: CGFloat = 1

    // **The menu bar paints no background**, which is how macOS draws it — the wallpaper runs to the top
    // of the display and the bar is only its contents. Contrast is bought the way macOS buys it, by
    // sampling what is underneath and flipping the whole bar between black and white (`Wallpaper`).

    // A mock window
    //
    // **The compositor's own shadow, scaled.** `Reconstruction` synthesizes a window's drop shadow at
    // these numbers, so using them here — with the radius and offset through `Projection.mock(_:)` — is
    // what makes the small desktop lit like the big one rather than merely shaped like it.

    public static let paneShadowOpacity: Float = 0.35
    public static let paneShadowRadius: Double = 18
    public static let paneShadowOffset = CGSize(width: 0, height: -8)

    // **A window's own dimensions, in real points, projected like everything else.** These were mock
    // points until it sat next to a real desktop: a fixed 7 pt corner is a 13 pt corner on the display
    // being portrayed, which reads as a rounder, chunkier window than macOS draws — and it would drift
    // further at every other `k`. The rule the layout keeps is the rule the chrome keeps.

    /// A macOS window's corner, in real points.
    public static let paneRadius: Double = 11
    /// Its title bar's height, in real points.
    public static let paneTitleBandHeight: Double = 28
    /// A stoplight's diameter, the pitch between two of them, and the first one's inset — real points.
    public static let stoplightDiameter: Double = 12
    public static let stoplightPitch: Double = 20
    public static let stoplightInset: Double = 20

    public static var paneFill: CGColor { NSColor(calibratedWhite: 0.16, alpha: 1).cgColor }
    public static var paneTitleFill: CGColor { NSColor(calibratedWhite: 0.24, alpha: 1).cgColor }
    public static var paneEdge: CGColor { NSColor.white.withAlphaComponent(0.12).cgColor }
    public static var paneFocusEdge: CGColor { NSColor.controlAccentColor.cgColor }
    public static let paneEdgeWidth: CGFloat = 0.5
    public static let paneFocusEdgeWidth: CGFloat = 1.5

    /// The stoplight dots, which are what say "window" at a glance more than anything else does.
    public static let stoplights: [CGColor] = [
        NSColor.systemRed.cgColor, NSColor.systemYellow.cgColor, NSColor.systemGreen.cgColor,
    ]

    // The marks
    //
    // **One accent, and it is the focus ring's.** The ring, the marks and the cue are the settings
    // window speaking about the desktop rather than things on it, so they share one colour and nothing
    // else on the mock uses it. A second accent would make the reader ask what the difference is.
    //
    // **The gutter band is the exception, and it is not a second accent.** It lies on the user's own
    // desktop picture, which can be any colour at all — an accent stripe down the side of an
    // accent-coloured wallpaper is a stripe nobody can see. So it is bought the way the mock menu bar
    // buys its own contrast and the way macOS buys the real one: sample what is underneath, and flip.

    /// A hairline mark. One point wide, whatever the camera is doing.
    public static var markInk: CGColor { NSColor.controlAccentColor.cgColor }

    /// The gutter band's wash, over a dark wallpaper and over a light one. Heavy enough to be a
    /// different surface at a glance and no heavier: the band is a measurement of the desktop rather
    /// than a lid on it, so the picture keeps showing through — and the accent outline around it is what
    /// carries the edge, which is why the wash does not have to.
    public static var gutterOverDark: CGColor { NSColor.white.withAlphaComponent(0.55).cgColor }
    public static var gutterOverLight: CGColor { NSColor.black.withAlphaComponent(0.5).cgColor }

    /// Where "clearly light" starts, for anything that flips on what is underneath it. The mock menu
    /// bar's own threshold, and the gutter band's.
    public static let inkFlip: Double = 0.5

    /// How deep a strip is sampled to ink the band, in mock points. A zero gap is a hairline and a
    /// hairline is thinner than a pixel of the wallpaper, so what is asked about is the ground the band
    /// sits on rather than the band itself.
    public static let inkSampleDepth: CGFloat = 24

    /// How long a piece of furniture takes to arrive and to leave. Nothing under 120 ms — below that it
    /// is a cut, and a cut is a decision.
    public static let fadeIn: CFTimeInterval = 0.14
    public static let fadeOut: CFTimeInterval = 0.12

    /// The cross-fade when a window's still is taken again at its new size. Short, because it is the
    /// app catching up rather than a transition of its own.
    public static let reRender: CFTimeInterval = 0.08

    // The cue
    //
    // **Taken is the accent; declined is neutral and dimmed.** The two have to be tellable apart at a
    // glance and across a loop, because a rung whose whole answer is "nothing happens" is otherwise
    // indistinguishable from a preview that has stopped working.

    /// Nearly opaque, because a badge is an object rather than a wash: the mock's own focus ring runs
    /// down the middle of some sets, and a translucent capsule lets it through the keycap.
    public static var cueFill: CGColor { NSColor.black.withAlphaComponent(0.84).cgColor }
    public static var cueInk: NSColor { .controlAccentColor }
    public static var cueEdge: CGColor { NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor }
    public static var cueDeclinedInk: NSColor { NSColor.white.withAlphaComponent(0.55) }
    public static var cueDeclinedEdge: CGColor { NSColor.white.withAlphaComponent(0.2).cgColor }
    public static let cueDeclinedOpacity: Float = 0.55

    // A mock window's interior (`MockContent`).
    //
    // **Fixed rather than appearance-derived**, as `paneFill` is: the mock portrays a desktop, and a
    // desktop's windows do not all repaint when the settings window's own appearance changes. What they
    // are is a dark app, drawn in one palette so six roles read as six apps rather than six themes.

    /// A content rule — a line of text, a row in a list. The interior's workhorse.
    public static var contentRule: CGColor { NSColor.white.withAlphaComponent(0.22).cgColor }
    /// A rule that is background rather than content — a table's ruled rows.
    public static var contentFaint: CGColor { NSColor.white.withAlphaComponent(0.09).cgColor }
    /// A heading, and the title bar's own title. Brighter, because it is the one thing being read.
    public static var contentTitle: CGColor { NSColor.white.withAlphaComponent(0.38).cgColor }
    /// A sidebar or a toolbar: chrome, which macOS draws a shade off the content beside it.
    public static var contentSidebar: CGColor { NSColor.white.withAlphaComponent(0.05).cgColor }
    /// The hairline between chrome and content — what makes a sidebar a sidebar.
    public static var contentSeam: CGColor { NSColor.black.withAlphaComponent(0.35).cgColor }
    /// A web page, which is lighter than the browser holding it.
    public static var contentPage: CGColor { NSColor(calibratedWhite: 0.21, alpha: 1).cgColor }
    /// A picture, an album cover, a hero image — a solid the eye reads as "not text".
    public static var contentBlock: CGColor { NSColor.white.withAlphaComponent(0.14).cgColor }
    /// A field or a bubble: a rounded well that is filled rather than ruled.
    public static var contentPill: CGColor { NSColor.white.withAlphaComponent(0.10).cgColor }
    /// A terminal's ground, which is darker than any app's.
    public static var contentTerminal: CGColor { NSColor(calibratedWhite: 0.07, alpha: 1).cgColor }
    public static var contentTerminalInk: CGColor { NSColor.white.withAlphaComponent(0.26).cgColor }
    /// The prompt mark, and the one place a role's furniture is tinted.
    public static var contentPrompt: CGColor { NSColor.systemGreen.withAlphaComponent(0.7).cgColor }

    // The guide, drawn on the mock.
    //
    // **Higher contrast than `GuidePanel`'s own**, and that is not a disagreement with it. The real
    // guide is already a small thing on a full display; this is that same object at the mock's scale
    // again, so a tile is a couple of points across. `GuidePanel`'s separator-grey on
    // window-background — legible at its size — is one flat rectangle at this one. What the preview
    // owes the user is the guide's *shape and placement*, which are exactly what these settings change.

    public static let guideRadius: CGFloat = 10
    public static var guideFill: CGColor { NSColor.black.withAlphaComponent(0.55).cgColor }
    public static var guideEdge: CGColor { NSColor.white.withAlphaComponent(0.28).cgColor }
    public static var guideTileFill: CGColor { NSColor.white.withAlphaComponent(0.38).cgColor }
    public static var guideViewportEdge: CGColor { NSColor.white.withAlphaComponent(0.55).cgColor }

    // The control slab

    public static let slabWidth: CGFloat = 760
    public static let slabRadius: CGFloat = 20
    public static var slabEdge: CGColor { NSColor.white.withAlphaComponent(0.16).cgColor }
    public static let slabInset: CGFloat = 24
}
