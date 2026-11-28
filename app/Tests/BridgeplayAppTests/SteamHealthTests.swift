import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Steam health and the Status hero")
struct SteamHealthTests {

    private static func folder() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "bp-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func health(pid: Int = 4242, mode: String = "active", patch: String = "85", steam: String = "1795567705",
                               hooks: (Int, Int) = (12, 12), layout: String = "true") -> String {
        """
        {"written": 1800000000, "pid": \(pid), "patch_build": "\(patch)", "steam_build": "\(steam)",
         "channel": "publicbeta", "sigdb_build": "1795567705", "mode": "\(mode)", "strikes": 0,
         "signatures_resolved": 40, "signatures_required": 40,
         "hooks_installed": \(hooks.0), "hooks_total": \(hooks.1), "layout_known": \(layout)}
        """
    }

    @Test("health.json is read, with numbers as strings and flags as 0 or 1 too")
    func parses() throws {
        let health = try #require(SteamHealth.parse(Data(Self.health().utf8)))
        #expect(health.pid == 4242)
        #expect(health.mode == .active)
        #expect(health.channel == "publicbeta")
        #expect(health.isComplete)
        let loose = try #require(SteamHealth.parse(Data(#"{"pid": "7", "patch_build": 85, "mode": "PASSIVE", "layout_known": 0}"#.utf8)))
        #expect(loose.pid == 7)
        #expect(loose.patchBuild == "85")
        #expect(loose.mode == .passive)
        #expect(loose.layoutKnown == false)
        #expect(!loose.isComplete)
        #expect(SteamHealth.parse(Data("not json".utf8)) == nil)
    }

    @Test("Live while its Steam runs, last start while the builds match and no Steam runs, stale otherwise, missing without a file")
    func freshness() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SteamHealthStore.read(folder: dir, installedPatch: "85", installedSteam: "1795567705", isThisUsersSteam: { _ in true }).freshness == .missing)

        try Data(Self.health().utf8).write(to: dir.appending(path: "health.json"))
        func read(running: Bool, patch: String = "85", steam: String = "1795567705", other: Bool = false) -> HealthReading {
            SteamHealthStore.read(folder: dir, installedPatch: patch, installedSteam: steam,
                                  isThisUsersSteam: { ($0 == 4242 && running) || ($0 == 5151 && other) },
                                  pids: { [1, 4242, 5151] })
        }
        #expect(read(running: true).freshness == .live)
        #expect(read(running: false).freshness == .lastStart)
        #expect(read(running: false, other: true).freshness == .stale)
        #expect(read(running: false, other: true).mode == nil)
        #expect(SteamHealthStore.allPids().contains(getpid()))
        #expect(read(running: false, steam: "1795999999").freshness == .stale)
        #expect(read(running: false, patch: "86").freshness == .stale)
        #expect(read(running: false, patch: "86").mode == nil)

        try Data(#"{"strikes": 2}"#.utf8).write(to: dir.appending(path: "boot.json"))
        #expect(read(running: false).bootStrikes == 2)
    }

    @Test("Pause writes only the paused file; Resume removes it; Try Again clears the boot record")
    func pause() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let support = dir.appending(path: "bridgeplay")
        try SteamHealthStore.setPaused(true, folder: support)
        #expect(try FileManager.default.contentsOfDirectory(atPath: support.path(percentEncoded: false)) == ["paused"])
        #expect(SteamHealthStore.read(folder: support, installedPatch: nil, installedSteam: nil).paused)
        try SteamHealthStore.setPaused(false, folder: support)
        try SteamHealthStore.setPaused(false, folder: support)
        #expect(!SteamHealthStore.read(folder: support, installedPatch: nil, installedSteam: nil).paused)

        try Data("{}".utf8).write(to: support.appending(path: "boot.json"))
        try Data(Self.health().utf8).write(to: support.appending(path: "health.json"))
        try Data("{}".utf8).write(to: support.appending(path: "health-web.json"))
        try SteamHealthStore.clearStrikes(folder: support)
        #expect(try FileManager.default.contentsOfDirectory(atPath: support.path(percentEncoded: false)) == ["health-web.json"])
    }

    @Test("The support folder follows the dylib: the old one only while the new one is absent")
    func supportFolder() throws {
        let home = try Self.folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let appSupport = home.appending(path: "Library/Application Support")
        #expect(SteamHealthStore.supportFolder(home: home).lastPathComponent == "bridgeplay")
        try FileManager.default.createDirectory(at: appSupport.appending(path: "notproton"), withIntermediateDirectories: true)
        #expect(SteamHealthStore.supportFolder(home: home).lastPathComponent == "notproton")
        try FileManager.default.createDirectory(at: appSupport.appending(path: "bridgeplay"), withIntermediateDirectories: true)
        #expect(SteamHealthStore.supportFolder(home: home).lastPathComponent == "bridgeplay")
    }

    @Test("Steam's build comes from the manifest beside the newest .installed that has one")
    func steamBuild() throws {
        let package = try Self.folder()
        defer { try? FileManager.default.removeItem(at: package) }
        #expect(SteamHealthStore.installedSteamBuild(package: package) == nil)
        let old = package.appending(path: "steam_client_signed_osx.installed")
        try Data("x".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400)], ofItemAtPath: old.path(percentEncoded: false))
        try Data("\"steam_client_signed_osx\"\n{\n\t\"version\"\t\t\"1782866176\"\n}\n".utf8)
            .write(to: package.appending(path: "steam_client_signed_osx.manifest"))
        try Data("x".utf8).write(to: package.appending(path: "steam_client_publicbeta_signed-2_osx.installed"))
        try Data("\"steam_client_publicbeta\"\n{\n\t\"version\"\t\t\"1795567705\"\n}\n".utf8)
            .write(to: package.appending(path: "steam_client_publicbeta_signed-2_osx.manifest"))
        #expect(SteamHealthStore.installedSteamBuild(package: package) == "1795567705")
        try FileManager.default.removeItem(at: package.appending(path: "steam_client_publicbeta_signed-2_osx.manifest"))
        #expect(SteamHealthStore.installedSteamBuild(package: package) == "1782866176")
        #expect(SteamHealthStore.patchBuild(deployed: "4.0.85") == "85")
    }

}

