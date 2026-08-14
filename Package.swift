// swift-tools-version: 6.0
import PackageDescription

// emira — a scrollable-tiling window manager for macOS (see PRINCIPLES.md / IMPLEMENTATION.md).
//
// Module graph (dependencies point strictly upward; nothing below imports a framework):
//
//   EmiraMotion   pure math — springs, easing curves, the scalar Animator.  (zero deps)
//       ▲
//   EmiraCore     pure — geometry, ids, Command/Event/Effect, State, layout, Engine.
//       ▲
//      ├── EmiraProtocol Codable request/reply envelope + wire framing.
//      └── EmiraConfig   pure — the TOML grammar and the config schema (text ⇄ Config).
//       ▲
//   EmiraGuide    AppKit — the guides' layer tree, hosted by the settings window and by the daemon.
//       ▲
//   EmiraSettings AppKit — the settings window: scrim, mock desktop, controls. Config + geometry only.
//       ▲
//   EmiraShell    imperative — Runtime, Executor, AX, Capture, Compositor, etc.
//       ▲
//      ├── emira-daemon   executable — accessory host that runs the Runtime.
//      └── emira          executable — CLI; a socket client, plus `emira config` over the file.
let package = Package(
    name: "Emira",
    // Platform floor: macOS 26 "Tahoe" (PRINCIPLES.md §7). No availability checks, no legacy paths.
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "emira-daemon", targets: ["emira-daemon"]),
        .executable(name: "emira", targets: ["emira"]),
    ],
    targets: [
        .target(name: "EmiraMotion"),
        .target(name: "EmiraCore", dependencies: ["EmiraMotion"]),
        .target(name: "EmiraProtocol", dependencies: ["EmiraCore"]),
        // A target rather than a folder in EmiraCore, because only a target can stop the settings GUI
        // from reaching the Engine: it sees the config and nothing else. The *values* stay in core —
        // the reducer reads them — so what lives here is text ⇄ `Config`, and nothing else needs it.
        .target(name: "EmiraConfig", dependencies: ["EmiraCore"]),
        // The guides' drawing: AppKit over the pure model, a layer tree and no window. A target for
        // `EmiraSettings`' reason and to the same end — the daemon and the settings window host the
        // *same* renderer, so a preview cannot be a second drawing of the guide. `ImportFenceTests`
        // scans it too: the compiler cannot say that a name is absent.
        .target(name: "EmiraGuide", dependencies: ["EmiraCore"]),
        // The settings window. A target for `EmiraConfig`'s reason, one rung further: it sees the
        // config and the geometry and nothing else, so it cannot reach the reducer. The graph does not
        // enforce that on its own — EmiraConfig pulls in EmiraCore — so `ImportFenceTests` pins it.
        .target(name: "EmiraSettings",
                dependencies: ["EmiraCore", "EmiraConfig", "EmiraMotion", "EmiraGuide"]),
        // The onboarding window's wordmark is a resource of the target that draws it, not of the app
        // bundle: `Bundle.module` resolves in a bare `swift build` daemon too, so the first-launch
        // window looks the same however emira was started. `make app` copies the bundle inwards.
        .target(name: "EmiraShell",
                dependencies: ["EmiraCore", "EmiraConfig", "EmiraProtocol", "EmiraSettings",
                               "EmiraGuide"],
                resources: [.copy("Resources/logo.webp")]),
        .executableTarget(name: "emira-daemon", dependencies: ["EmiraShell"]),
        // The CLI names `Command` (it parses argv straight into the one vocabulary, §2), so it
        // depends on EmiraCore as well — which EmiraProtocol already pulls in. EmiraConfig is
        // `emira config`, which reads and writes the file locally rather than asking the daemon. What
        // matters is what it *doesn't* have: no EmiraShell, no frameworks, nothing to slow down launch.
        .executableTarget(name: "emira", dependencies: ["EmiraProtocol", "EmiraCore", "EmiraConfig"]),
        .testTarget(name: "EmiraMotionTests", dependencies: ["EmiraMotion"]),
        .testTarget(name: "EmiraCoreTests", dependencies: ["EmiraCore"]),
        .testTarget(name: "EmiraConfigTests", dependencies: ["EmiraConfig", "EmiraCore"]),
        .testTarget(name: "EmiraProtocolTests", dependencies: ["EmiraProtocol", "EmiraCore"]),
        .testTarget(name: "EmiraGuideTests", dependencies: ["EmiraGuide", "EmiraCore"]),
        .testTarget(name: "EmiraSettingsTests",
                    dependencies: ["EmiraSettings", "EmiraCore", "EmiraConfig"]),
        .testTarget(name: "EmiraShellTests",
                    dependencies: ["EmiraShell", "EmiraCore", "EmiraProtocol"]),
    ]
)
