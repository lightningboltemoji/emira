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
//   EmiraProtocol Codable request/reply envelope + wire framing.
//       ▲
//   EmiraShell    imperative — Runtime, Executor, AX, Capture, Compositor, etc.
//       ▲
//      ├── emira-daemon   executable — accessory host that runs the Runtime.
//      └── emira          executable — CLI; thin socket client (EmiraProtocol only).
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
        // The onboarding window's wordmark is a resource of the target that draws it, not of the app
        // bundle: `Bundle.module` resolves in a bare `swift build` daemon too, so the first-launch
        // window looks the same however emira was started. `make app` copies the bundle inwards.
        .target(name: "EmiraShell",
                dependencies: ["EmiraCore", "EmiraProtocol"],
                resources: [.copy("Resources/logo.webp")]),
        .executableTarget(name: "emira-daemon", dependencies: ["EmiraShell"]),
        // The CLI names `Command` (it parses argv straight into the one vocabulary, §2), so it
        // depends on EmiraCore as well — which EmiraProtocol already pulls in. What matters is what
        // it *doesn't* have: no EmiraShell, no frameworks, nothing to slow down launch.
        .executableTarget(name: "emira", dependencies: ["EmiraProtocol", "EmiraCore"]),
        .testTarget(name: "EmiraMotionTests", dependencies: ["EmiraMotion"]),
        .testTarget(name: "EmiraCoreTests", dependencies: ["EmiraCore"]),
        .testTarget(name: "EmiraProtocolTests", dependencies: ["EmiraProtocol", "EmiraCore"]),
        .testTarget(name: "EmiraShellTests",
                    dependencies: ["EmiraShell", "EmiraCore", "EmiraProtocol"]),
    ]
)
