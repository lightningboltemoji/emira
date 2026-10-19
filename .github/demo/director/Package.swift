// swift-tools-version: 6.0

// The director: plays a tape (.github/demo/tapes/*.tape) on a display of its own and records the take
// that .github/demo/studio cuts into a video. See .agents/DEMO.md.
//
//   swift run --package-path .github/demo/director director .github/demo/tapes/readme.tape

import PackageDescription

let package = Package(
    name: "Director",
    platforms: [.macOS("26.0")],
    targets: [
        // CGVirtualDisplay is private CoreGraphics, declared here because Swift can't see it otherwise.
        .target(name: "VirtualDisplay", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(
            name: "director", dependencies: ["VirtualDisplay"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // The take's windows: one solid colour each, opened by the director next to which it's built.
        .executableTarget(name: "standin", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
