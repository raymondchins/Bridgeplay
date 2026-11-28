import Foundation
import Testing

@testable import BridgeplayApp

// A user with an older WineCX release set up, after an app update makes a newer one current.
// The fixtures name a release after the real ones, so the rules hold for the next bump too.
@Suite("Moving to the current WineCX release")
struct WinecxUpgradeTests {

    private static func engine(_ build: String) -> CrossOverInstall {
        let runner = RunnerBuild(bundleVersion: build, releaseVersion: build, flavor: nil, loaderSHA256: build,
                                 cleanNtdll: [:], patchedNtdll: [:], isFree: true)
        return CrossOverInstall(bundle: URL(filePath: "/engines/\(build).app"), releaseVersion: build,
                                support: .supported(runner), isEngine: true)
    }

    private static let builds = ["winecx-11.99", "winecx-11.17", "winecx-11.15"]

    // MARK: What Status offers

    @Test("An older release set up and the current one not unpacked offers the current one")
    func offersTheCurrentRelease() {
        let offer = WinecxUpgrade.offer(installs: [Self.engine("winecx-11.17")], builds: Self.builds)
        #expect(offer == WinecxUpgrade.Offer(from: "winecx-11.17", to: "winecx-11.99"))
        // With two older ones, it names the newer as the one games keep.
        let both = WinecxUpgrade.offer(
            installs: [Self.engine("winecx-11.15"), Self.engine("winecx-11.17")], builds: Self.builds)
        #expect(both?.from == "winecx-11.17")
    }

    @Test("No offer once the current release is unpacked, without an older one, or for other engines")
    func noOffer() {
        #expect(WinecxUpgrade.offer(
            installs: [Self.engine("winecx-11.17"), Self.engine("winecx-11.99")], builds: Self.builds) == nil)
        #expect(WinecxUpgrade.offer(installs: [], builds: Self.builds) == nil)
        #expect(WinecxUpgrade.offer(installs: [Self.engine("winehq-11.15")], builds: Self.builds) == nil)
        #expect(WinecxUpgrade.offer(installs: [Self.engine("winecx-11.17")], builds: ["winecx-11.17"]) == nil)
    }

    @Test("The real releases: an older one set up offers the current one by name")
    func realReleases() throws {
        let releases = FreeEngineWinecx.releases
        guard releases.count > 1 else { return }
        let offer = try #require(WinecxUpgrade.offer(installs: [Self.engine(releases[1].build)]))
        #expect(offer.to == FreeEngineWinecx.current.build)
    }

    // MARK: Nothing downloads by itself

    @Test("The launch update leaves a new runtime to the user: it reads as missing, not outdated")
    func noUnaskedDownload() {
        let status = FreeEngineStatus.state(
            build: "winecx-11.99", installs: [Self.engine("winecx-11.17")], current: ["winecx-11.17"])
        #expect(status == .missing)
        #expect(SystemStatus.updatePlan(
            steam: .installed(version: "4.0.85"), hasRunner: true, winecx: status, winehq: .current).isEmpty)
    }

    // MARK: Older releases stay

    @Test("Every older release stays pinned, patchable and selectable beside the current one")
    func olderReleasesStay() throws {
        let current = try #require(FreeEngineWinecx.currentTool)
        #expect(!FreeEngineWinecx.olderTools.contains(current))
        #expect(FreeEngineWinecx.previousTool == FreeEngineWinecx.releases.dropFirst().first?.runner.tools.first?.name)
        let tools = SupportedRunners.tools(for: FreeEngineWinecx.releases.map(\.runner)).map(\.name)
        #expect(Set(tools) == FreeEngineWinecx.olderTools.union([current]))
        for release in FreeEngineWinecx.releases {
            #expect(SupportedRunners.build(id: release.build) == release.runner)
            #expect(!NtdllPatcher.patches(for: release.runner).isEmpty)
        }
    }

    @Test("A failed install of the current release leaves the older engine as it was")
    func failedInstallKeepsTheOlder() throws {
        let older = try #require(FreeEngineWinecx.releases.dropFirst().first)
        let base = try scratchDirectory("winecx-upgrade")
        defer { try? FileManager.default.removeItem(at: base) }
        let engines = base.appending(path: "engines")
        let kept = FreeEngineWinecx.bundle(for: older, engines: engines).appending(path: "Contents/marker")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("older".utf8).write(to: kept)

        // An archive without a Wine tree fails before anything moves into engines/.
        let empty = base.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let archive = base.appending(path: "broken.tar.gz")
        #expect(try Shell.run("/usr/bin/tar", ["-czf", archive.path(percentEncoded: false),
                                               "-C", empty.path(percentEncoded: false), "."]).status == 0)
        #expect(throws: StepFailure.self) {
            try FreeEngineWinecx.unpack(archive, renderer: nil, release: FreeEngineWinecx.current, engines: engines)
        }
        #expect(try String(contentsOf: kept, encoding: .utf8) == "older")
        let current = FreeEngineWinecx.bundle(for: FreeEngineWinecx.current, engines: engines)
        #expect(!FileManager.default.fileExists(atPath: current.path(percentEncoded: false)))
        #expect(current != FreeEngineWinecx.bundle(for: older, engines: engines))
    }

    // MARK: Steam's default

    private static let head = """
        "InstallConfigStore"
        {
        \t"Software"
        \t{
        \t\t"valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        \t\t\t\t"CompatToolMapping"
        \t\t\t\t{
        """
    private static let tail = """
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t}
        }
        """

    private static func vdf(_ entries: [(String, String)]) -> String {
        Self.head + "\n" + entries.map { key, tool in
            "\t\t\t\t\t\"\(key)\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"name\"\t\t\"\(tool)\"\n"
                + "\t\t\t\t\t\t\"config\"\t\t\"\"\n\t\t\t\t\t\t\"priority\"\t\t\"75\"\n\t\t\t\t\t}\n"
        }.joined() + Self.tail
    }

    private static let new = "bridgeplay-proton-winecx-11.99"
    private static let old = "bridgeplay-proton-winecx-11.17"
    private static let oldest = "bridgeplay-proton-winecx"
    private static let older: Set<String> = [old, oldest]

    private static func move(_ text: String, backup: SteamDefaultTool.Backup?) -> String? {
        SteamDefaultTool.movingWinecxDefault(text, from: older, previous: old, to: new, backup: backup)
    }

    @Test("A default Bridgeplay set to the older release moves; per-game choices stay")
    func movesBridgeplaysDefault() {
        let text = Self.vdf([("0", Self.old), ("10", Self.old), ("20", "GE-Proton9-1")])
        let moved = Self.vdf([("0", Self.new), ("10", Self.old), ("20", "GE-Proton9-1")])
        #expect(Self.move(text, backup: .init(previous: nil, applied: Self.old)) == moved)
        // A backup from before `applied` was kept: Setup wrote the previous release's tool.
        #expect(Self.move(text, backup: .init(previous: nil)) == moved)
        #expect(Self.move(moved, backup: .init(previous: nil, applied: Self.new)) == nil)
    }

    @Test("A default the user chose is left alone")
    func keepsTheUsersChoice() {
        let old = Self.vdf([("0", Self.old)])
        // No backup: Bridgeplay never set the default, so the user picked it.
        #expect(Self.move(old, backup: nil) == nil)
        // Bridgeplay last set the current tool, and the user went back to the older one.
        #expect(Self.move(old, backup: .init(previous: nil, applied: Self.new)) == nil)
        // An older release than the one Setup wrote, picked without a record of ours.
        #expect(Self.move(Self.vdf([("0", Self.oldest)]), backup: .init(previous: nil)) == nil)
        #expect(Self.move(Self.vdf([("0", "GE-Proton9-1")]), backup: .init(previous: nil)) == nil)
        #expect(Self.move(Self.vdf([("10", Self.old)]), backup: .init(previous: nil)) == nil)
    }

    @Test("set() records the tool it wrote and keeps the user's backed-up default")
    func setRecordsApplied() throws {
        let dir = try scratchDirectory("winecx-default-set")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.vdf")
        let backup = dir.appending(path: "backups/steam-default-tool.json")
        try Self.vdf([("0", "GE-Proton9-1")]).write(to: file, atomically: true, encoding: .utf8)

        try SteamDefaultTool.set(Self.old, in: file, backup: backup, steamRunning: { false })
        #expect(SteamDefaultTool.readBackup(backup)?.applied == Self.old)
        try SteamDefaultTool.set(Self.new, in: file, backup: backup, steamRunning: { false })
        let saved = try #require(SteamDefaultTool.readBackup(backup))
        #expect(saved.applied == Self.new)
        #expect(saved.previous?.name == "GE-Proton9-1")
    }

    private func follow(
        _ dir: URL, installed: [String] = [new], steamRunning: @escaping () -> Bool = { false }
    ) throws -> SteamDefaultTool.FollowResult {
        try SteamDefaultTool.followCurrentWinecx(
            current: Self.new, older: Self.older, previous: Self.old, installed: installed,
            in: dir.appending(path: "config.vdf"), backup: dir.appending(path: "backups/steam-default-tool.json"),
            compatTools: dir.appending(path: "compatibilitytools.d"), steamRunning: steamRunning)
    }

    @Test("The move waits for the current tool to be set up, and never writes while Steam runs")
    func followWaitsForToolAndSteam() throws {
        let dir = try scratchDirectory("winecx-default-follow")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.vdf")
        let backup = dir.appending(path: "backups/steam-default-tool.json")
        let text = Self.vdf([("0", Self.old), ("10", Self.old)])
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(SteamDefaultTool.Backup(previous: nil, applied: Self.old)).write(to: backup)

        // Not installed yet, or installed without its Steam folder: nothing to move to.
        #expect(try follow(dir, installed: []) == .unchanged)
        #expect(try follow(dir) == .unchanged)
        try FileManager.default.createDirectory(
            at: dir.appending(path: "compatibilitytools.d/\(Self.new)"), withIntermediateDirectories: true)

        #expect(try follow(dir, steamRunning: { true }) == .steamRunning)
        var checks = 0
        #expect(try follow(dir, steamRunning: { checks += 1; return checks == 2 }) == .steamRunning)
        #expect(try String(contentsOf: file, encoding: .utf8) == text)

        #expect(try follow(dir) == .updated)
        #expect(try String(contentsOf: file, encoding: .utf8) == Self.vdf([("0", Self.new), ("10", Self.old)]))
        #expect(SteamDefaultTool.readBackup(backup)?.applied == Self.new)
        #expect(try follow(dir) == .unchanged)

        // Set back to the older release by the user afterwards: it stays.
        try Self.vdf([("0", Self.old)]).write(to: file, atomically: true, encoding: .utf8)
        #expect(try follow(dir) == .unchanged)
    }

    @Test("A move whose record can't be written puts the default back and is tried again")
    func followUndoesWithoutRecord() throws {
        let dir = try scratchDirectory("winecx-default-unrecorded")
        let backups = dir.appending(path: "backups")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backups.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: dir)
        }
        let file = dir.appending(path: "config.vdf")
        let backup = backups.appending(path: "steam-default-tool.json")
        let text = Self.vdf([("0", Self.old)])
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try JSONEncoder().encode(SteamDefaultTool.Backup(previous: nil, applied: Self.old)).write(to: backup)
        try FileManager.default.createDirectory(
            at: dir.appending(path: "compatibilitytools.d/\(Self.new)"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: backups.path(percentEncoded: false))

        #expect(try follow(dir) == .failed)
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
        #expect(SteamDefaultTool.readBackup(backup)?.applied == Self.old)
    }
}
