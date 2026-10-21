import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Product version")
struct ProductVersionTests {

    private static func define(_ name: String) throws -> String {
        let header = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "dylib/version.h")
        let text = try String(contentsOf: header, encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("#define \(name) ") })
        return String(line.dropFirst("#define \(name) ".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    // The last version of the old scheme, as an installed build record in Steam says it.
    private static let lastLegacy = "1.2.0-winehq.1-ray.32"

    @Test("The install record reads as newer than any build of the old scheme")
    func newerThanLegacy() throws {
        let version = try Self.define("BRIDGEPLAY_VERSION")
        #expect(version.split(separator: ".").count == 3)
        let key = AppVersion.deployKey(build: try Self.define("BRIDGEPLAY_BUILD"), display: version)
        let bundled = DeploymentContent.Build(version: key, builtAt: 1)
        for old in [Self.lastLegacy, "3.5.0"] {
            let installed = DeploymentContent.Build(version: old, builtAt: 2)
            #expect(bundled.isNewer(than: installed), "\(old)")
            #expect(!installed.isNewer(than: bundled), "\(old)")
        }
    }

    // 3.5.0 went back to 0.7.0: installs are ordered by the build, never the display version.
    @Test("The deploy key follows the build, and an older app leaves a newer install alone")
    func deployKey() {
        #expect(AppVersion.deployKey(build: "44", display: "0.7.0") == "4.0.44")
        #expect(AppVersion.deployKey(build: nil, display: "0.1.0-dev") == "0.1.0-dev")
        let next = DeploymentContent.Build(version: AppVersion.deployKey(build: "45", display: "0.7.1"), builtAt: 1)
        let this = DeploymentContent.Build(version: AppVersion.deployKey(build: "44", display: "0.7.0"), builtAt: 2)
        let build100 = DeploymentContent.Build(version: AppVersion.deployKey(build: "100", display: "0.9.0"), builtAt: 1)
        #expect(next.isNewer(than: this) && build100.isNewer(than: next))
        // Bridgeplay 3.5.0 (build 43), as another macOS user sharing Steam.app might still run it.
        let older = DeploymentContent.Build(version: "3.5.0", builtAt: 3)
        #expect(this.isNewer(than: older) && !older.isNewer(than: this))
        #expect(AppVersion.label(deployed: "4.0.44") == "build 44")
        #expect(AppVersion.label(deployed: "3.5.0") == "3.5.0")
    }

    @Test("The build number is a plain integer past the old ray counter")
    func buildContinuesCounter() throws {
        let build = try #require(Int(try Self.define("BRIDGEPLAY_BUILD")))
        #expect(build >= 32)
    }

    @Test("The display names the build and the NotProton release")
    func display() {
        #expect(ProductVersion.display(short: "2.0.0", build: "32", upstream: "1.2.0")
            == "Bridgeplay 2.0.0 (32) · based on NotProton 1.2.0")
        #expect(ProductVersion.display(short: "0.1.0-dev", build: nil, upstream: nil) == "Bridgeplay 0.1.0-dev")
    }
}

@Suite("Post-update refresh")
struct PostUpdateRefreshTests {

    private func decide(
        steam: SteamDeployment = .outdated(deployed: "1.1.9-winehq.1-ray.31", bundled: "2.0.0"),
        steamRunning: Bool = false,
        workloadRunning: Bool = false,
        contentBlocks: Bool = false,
        hasRunner: Bool = true,
        build: String? = "32",
        lastBuild: String? = nil
    ) -> PostUpdateRefresh.Decision {
        PostUpdateRefresh.decide(steam: steam, steamRunning: steamRunning, workloadRunning: workloadRunning,
                                 contentBlocks: contentBlocks, hasRunner: hasRunner,
                                 build: build, lastBuild: lastBuild)
    }

    @Test("The first launch after an update re-applies an older patch")
    func installsAfterUpdate() {
        #expect(decide() == .install)
        // Sparkle's own ordering: build 32 follows the old dotted 1.1.9.31.
        #expect(decide(lastBuild: "1.1.9.31") == .install)
        #expect(decide(build: "33", lastBuild: "32") == .install)
    }

    @Test("Steam or a running game defers it to a later launch")
    func waitsForSteamAndGames() {
        #expect(decide(steamRunning: true) == .wait)
        #expect(decide(workloadRunning: true) == .wait)
    }

    @Test("Nothing happens without an update or when installing would need the user")
    func leavesOtherCasesAlone() {
        #expect(decide(lastBuild: "32") == .nothing)
        #expect(decide(build: "32", lastBuild: "33") == .nothing)
        #expect(decide(build: nil) == .nothing)
        #expect(decide(steam: .installed(version: "2.0.0")) == .nothing)
        #expect(decide(steam: .notInstalled) == .nothing)
        #expect(decide(steam: .outdated(deployed: "", bundled: "2.0.0")) == .nothing)
        #expect(decide(steam: .outdated(deployed: "2.0.0", bundled: "2.0.0")) == .nothing)
        #expect(decide(contentBlocks: true) == .nothing)
        #expect(decide(hasRunner: false) == .nothing)
    }
}
