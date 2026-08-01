import Foundation
import Testing
@testable import EmiraShell

// Where the wordmark asset is looked for: the two layouts SwiftPM emits, the two places a build leaves
// the bundle, and a miss that resolves to `nil` rather than trapping — `Wordmark.init?` opens the
// window without a heading, so resolution has to be able to fail as a value.

@Suite @MainActor struct WordmarkTests {

    /// A resource bundle at `root`, in whichever layout SwiftPM's toolchain would have written.
    /// `logoURL` only resolves a path, so the asset's bytes don't matter here.
    static func plant(_ layout: Layout, in root: URL, named name: String = "logo.webp") throws {
        let bundle = root.appendingPathComponent(Wordmark.resourceBundleName)
        let resources = switch layout {
        case .flat: bundle
        case .deep: bundle.appendingPathComponent("Contents/Resources")
        }
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data().write(to: resources.appendingPathComponent(name))
        if case .deep = layout {
            // CFBundle needs this to read the directory as the macOS layout rather than a flat one.
            try Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
                "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict><key>CFBundleName</key><string>Emira_EmiraShell</string></dict></plist>
                """.utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
    }

    enum Layout { case flat, deep }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wordmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // The layouts a toolchain may emit

    @Test(arguments: [Layout.flat, Layout.deep])
    func theAssetIsFoundInEitherLayoutSwiftPMWrites(layout: Layout) throws {
        // Which layout a build produces is the toolchain's choice, so both have to work.
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.plant(layout, in: root)

        let url = Wordmark.logoURL(searching: [root])
        #expect(url != nil)
        #expect(url?.lastPathComponent == "logo.webp")
    }

    // The places a build leaves it

    @Test func theAppBundlesCopyIsPreferredToOneBesideTheExecutable() throws {
        // Inside a shipped `.app` both roots can exist; the sealed copy belongs to this build.
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Self.plant(.flat, in: resources)
        try Self.plant(.flat, in: root)

        let url = Wordmark.logoURL(searching: [resources, root])
        #expect(url?.path.contains("Contents/Resources") == true)
    }

    @Test func bothRootsAreSearchedBeforeGivingUp() throws {
        // The bare `swift build` shape: nothing at the first root, the bundle at the second.
        let empty = try Self.temporaryDirectory()
        let root = try Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: empty)
            try? FileManager.default.removeItem(at: root)
        }
        try Self.plant(.flat, in: root)

        #expect(Wordmark.logoURL(searching: [empty, root]) != nil)
    }

    // Missing is a value, not a trap

    @Test func aMissingAssetIsNilRatherThanACrash() throws {
        let empty = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }

        #expect(Wordmark.logoURL(searching: []) == nil)
        #expect(Wordmark.logoURL(searching: [empty]) == nil)
        #expect(Wordmark.logoURL(searching: [empty.appendingPathComponent("nowhere")]) == nil)
    }

    @Test func aBundleWithoutTheAssetIsNil() throws {
        // A bundle that exists but is empty must not read as a hit.
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.plant(.flat, in: root, named: "something-else.txt")

        #expect(Wordmark.logoURL(searching: [root]) == nil)
    }
}
