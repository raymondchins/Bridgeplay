import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Install payload")
struct InstallPayloadTests {

    private func stage(_ root: URL, dylib: Bool = true, shim: Bool = true, iconmaker: Bool = true, appinfo: Bool = true, gamefixPrep: Bool = true, signatures: [String] = ["1788400362.json"], fonts: [String] = ["arial.ttf"]) throws {
        let files = FileManager.default
        let signatureDir = root.appending(path: "signatures/macos.arm64")
        try files.createDirectory(at: signatureDir, withIntermediateDirectories: true)
        if dylib { try Data("dylib".utf8).write(to: root.appending(path: SupportPaths.dylibName)) }
        if shim { try Data("shim".utf8).write(to: root.appending(path: "overlay-shim.dylib")) }
        if iconmaker { try Data("iconmaker".utf8).write(to: root.appending(path: "iconmaker")) }
        if appinfo { try Data("appinfo".utf8).write(to: root.appending(path: "appinfo")) }
        if gamefixPrep {
            let tool = root.appending(path: "gamefix-prep")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
        }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: root.appending(path: "run"))
        try Data("100\n".utf8).write(to: root.appending(path: "build-time"))
        for name in signatures {
            try Data("{}".utf8).write(to: signatureDir.appending(path: name))
        }
        for name in fonts {
            let font = root.appending(path: "fonts/\(name)")
            try files.createDirectory(at: font.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("font".utf8).write(to: font)
        }
    }

    @Test("The shipped app carries a payload staged by make")
    func shippedPayloadIsStaged() throws {
        let located = try InstallPayload.locate()

        #expect(located.dylib.lastPathComponent == "notproton.dylib")
        #expect(located.overlayShim.lastPathComponent == "overlay-shim.dylib")
        #expect(located.appinfo.lastPathComponent == "appinfo")
        #expect(located.gamefixPrep.lastPathComponent == "gamefix-prep")
        #expect(!located.signatures.isEmpty)
        #expect(located.fonts.contains("arial.ttf"))
        #expect(located.fonts.contains("alt/arial.ttf"))

        // A real fat dylib, not a placeholder: an install that copied a stub would
        // deploy something dyld refuses at launch.
        let size = try FileManager.default.attributesOfItem(
            atPath: located.dylib.path(percentEncoded: false)
        )[.size] as? Int
        #expect((size ?? 0) > 100_000, "the staged dylib is too small to be the built one")

        let architectures = try Shell.run("/usr/bin/lipo", ["-info", located.dylib.path(percentEncoded: false)])
        #expect(architectures.stdout.contains("arm64"))
        #expect(architectures.stdout.contains("x86_64"))
    }

    @Test("Every signature database in the payload is found, in a stable order")
    func findsAllSignatureDatabases() throws {
        let root = try scratchDirectory("payload")
        defer { try? FileManager.default.removeItem(at: root) }
        try stage(root, signatures: ["1788652215.json", "1788400362.json", "notes.txt"])

        let located = try InstallPayload.locate(root: root)

        #expect(located.signatures.map(\.lastPathComponent) == ["1788400362.json", "1788652215.json"])
    }

    @Test("A payload missing an artifact says which one and how to fix it")
    func reportsMissingArtifacts() throws {
        let root = try scratchDirectory("payload")
        defer { try? FileManager.default.removeItem(at: root) }
        try stage(root, dylib: false)

        do {
            _ = try InstallPayload.locate(root: root)
            Issue.record("a payload with no dylib was accepted")
        } catch let failure as StepFailure {
            #expect(failure.detail.contains("notproton.dylib"))
            #expect(failure.detail.contains("make app-payload"))
            #expect(!failure.detail.contains("overlay-shim.dylib"), "the shim was present and should not be named")
        }
    }

    @Test("The game-fix helper must be executable")
    func refusesNonExecutableGamefixPrep() throws {
        let root = try scratchDirectory("payload-gamefix-prep")
        defer { try? FileManager.default.removeItem(at: root) }
        try stage(root)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: root.appending(path: "gamefix-prep").path(percentEncoded: false)
        )

        do {
            _ = try InstallPayload.locate(root: root)
            Issue.record("a non-executable game-fix helper was accepted")
        } catch let failure as StepFailure {
            #expect(failure.detail.contains("gamefix-prep"))
        }
    }

    @Test("A payload with no signature database is refused")
    func refusesPayloadWithoutSignatures() throws {
        let root = try scratchDirectory("payload")
        defer { try? FileManager.default.removeItem(at: root) }
        try stage(root, signatures: [])

        do {
            _ = try InstallPayload.locate(root: root)
            Issue.record("a payload with no signature database was accepted")
        } catch let failure as StepFailure {
            #expect(failure.detail.contains("signatures/macos.arm64"))
        }
    }

    @Test("An empty payload names every missing artifact")
    func reportsEverythingMissing() throws {
        let root = try scratchDirectory("payload")
        defer { try? FileManager.default.removeItem(at: root) }
        try stage(root, dylib: false, shim: false, iconmaker: false, appinfo: false,
                  gamefixPrep: false, signatures: [], fonts: [])

        do {
            _ = try InstallPayload.locate(root: root)
            Issue.record("an empty payload was accepted")
        } catch let failure as StepFailure {
            #expect(failure.detail.contains("notproton.dylib"))
            #expect(failure.detail.contains("overlay-shim.dylib"))
            #expect(failure.detail.contains("iconmaker"))
            #expect(failure.detail.contains("appinfo"))
            #expect(failure.detail.contains("gamefix-prep"))
            #expect(failure.detail.contains("signatures/macos.arm64"))
            #expect(failure.detail.contains("fonts"))
        }
    }

    @Test("A missing script or invalid build timestamp cannot be installed")
    func refusesIncompleteBuildMetadata() throws {
        let root = try scratchDirectory("payload-build")
        defer { try? FileManager.default.removeItem(at: root) }
        try stage(root)
        try Data("not a timestamp".utf8).write(to: root.appending(path: "build-time"))
        #expect(throws: StepFailure.self) { try InstallPayload.locate(root: root) }
        try Data("100".utf8).write(to: root.appending(path: "build-time"))
        try FileManager.default.removeItem(at: root.appending(path: "run"))
        #expect(throws: StepFailure.self) { try InstallPayload.locate(root: root) }
    }
}
