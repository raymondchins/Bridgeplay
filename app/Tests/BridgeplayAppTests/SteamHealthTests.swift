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

    @Test("The pause list's keys: why the start is passive and the entry that paused it")
    func parsesPauseList() throws {
        let listed = try #require(SteamHealth.parse(Data(#"{"mode": "passive", "mode_reason": "pause_list", "pause_list": "ok", "pause_list_serial": 1800000000, "pause_note": "Steam beta closes at start.", "pause_fixed_in": "0.7.70", "pause_url": "https://example.invalid/1"}"#.utf8)))
        #expect(listed.pausedByList)
        #expect(listed.pauseList == "ok")
        #expect(listed.pauseListSerial == 1_800_000_000)
        #expect(listed.pauseFixedIn == "0.7.70")
        #expect(listed.pauseURL == "https://example.invalid/1")
        let strikes = try #require(SteamHealth.parse(Data(#"{"mode": "passive", "mode_reason": "strikes", "pause_fixed_in": ""}"#.utf8)))
        #expect(!strikes.pausedByList)
        #expect(strikes.pauseFixedIn == nil)
        // A dylib from before the list
        #expect(try #require(SteamHealth.parse(Data(Self.health(mode: "passive").utf8))).modeReason == nil)
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

    // MARK: hero

    private static let payload = PayloadState(expected: 0, present: 0, missing: [], overlayShimPresent: true,
                                              iconmakerPresent: true, appinfoPresent: true, signatureDatabase: "fixture",
                                              legacyCompatPresent: 0, legacyCompatExpected: 0, manifestProblem: nil)

    private static func snapshot(runner: RunnerState = .ready(builds: ["crossover-26.0"]), running: Bool = false,
                                 health: HealthReading = .none, payload: PayloadState = payload) -> StatusSnapshot {
        StatusSnapshot(steam: .installed(version: "4.0.85"), steamRunning: running, updateBlocked: false,
                       crossOver: [], runner: runner, payload: payload, steamRunningHere: running, health: health)
    }

    private static func reading(_ mode: SteamHealth.Mode, _ freshness: HealthReading.Freshness,
                                hooks: (Int, Int) = (12, 12), paused: Bool = false) -> HealthReading {
        var health = SteamHealth()
        health.mode = mode
        health.hooksInstalled = hooks.0
        health.hooksTotal = hooks.1
        return HealthReading(health: health, paused: paused, freshness: freshness)
    }

    @Test("Ready with CrossOver alone and no free engine; Open Steam while Steam is closed")
    func readyWithoutFreeEngine() {
        let closed = HeroState.make(Self.snapshot(), offModes: true)
        #expect(closed.headline == "Ready to play")
        #expect(closed.ready)
        #expect(closed.actions == [.openSteam, .pause])
        let open = HeroState.make(Self.snapshot(running: true, health: Self.reading(.active, .live)), offModes: true)
        #expect(open.ready)
        #expect(open.actions == [.pause])
    }

    @Test("With the off modes disabled there is no Pause, and a paused file or passive report is ignored")
    func offModesDisabled() {
        #expect(!SteamHealthStore.offModesEnabled)
        #expect(HeroState.make(Self.snapshot()).actions == [.openSteam])
        #expect(HeroState.make(Self.snapshot(running: true, health: Self.reading(.active, .live))).actions.isEmpty)
        let paused = HeroState.make(Self.snapshot(running: true, health: Self.reading(.active, .live, paused: true)))
        #expect(paused.headline == "Ready to play")
        #expect(paused.actions.isEmpty)
        #expect(HeroState.make(Self.snapshot(health: HealthReading(paused: true))).ready)
        #expect(HeroState.make(Self.snapshot(health: Self.reading(.passive, .lastStart))).ready)
        let partly = HeroState.make(Self.snapshot(running: true, health: Self.reading(.active, .live, hooks: (10, 12))))
        #expect(partly.headline == "Partly working")
        #expect(partly.actions.isEmpty)
    }

    @Test("Almost ready names what is missing")
    func almostReady() {
        #expect(HeroState.make(Self.snapshot(runner: .none)).detail == "Install an engine below.")
        #expect(HeroState.make(Self.snapshot(runner: .unpatched(builds: ["x"], problems: []))).detail == "Set up the engine again below.")
        var broken = Self.payload
        broken.signatureDatabase = nil
        let state = HeroState.make(Self.snapshot(payload: broken))
        #expect(state.headline == "Almost ready")
        #expect(state.detail.hasPrefix("Reinstall into Steam"))
    }

    @Test("Paused, passive after bad starts, partly working and not confirmed each have their own hero")
    func steamStates() {
        let paused = HeroState.make(Self.snapshot(health: HealthReading(paused: true)), offModes: true)
        #expect(paused.headline == "Paused in Steam")
        #expect(paused.actions == [.resume])
        #expect(!paused.ready)
        let pendingPause = HeroState.make(Self.snapshot(running: true, health: Self.reading(.active, .live, paused: true)), offModes: true)
        #expect(pendingPause.headline == "Pausing at restart")
        #expect(pendingPause.detail == "Still on until Steam restarts.")
        #expect(pendingPause.actions == [.resume])
        // Resumed: this Steam is still off, the next start is not
        let pendingResume = HeroState.make(Self.snapshot(running: true, health: Self.reading(.off, .live)), offModes: true)
        #expect(pendingResume.detail == "Restart Steam to resume.")
        #expect(pendingResume.actions == [.pause])
        #expect(HeroState.make(Self.snapshot(health: Self.reading(.off, .lastStart)), offModes: true).ready)

        let passive = HeroState.make(Self.snapshot(health: Self.reading(.passive, .lastStart)), offModes: true)
        #expect(passive.headline == "Turned off")
        #expect(passive.actions == [.tryAgain])
        // A passive verdict from another Steam build says nothing
        #expect(HeroState.make(Self.snapshot(health: Self.reading(.passive, .stale)), offModes: true).ready)

        var listed = Self.reading(.passive, .lastStart)
        listed.health?.modeReason = "pause_list"
        let listedHero = HeroState.make(Self.snapshot(health: listed), offModes: true)
        #expect(listedHero.headline == "Paused for this build")
        #expect(listedHero.detail.contains("Bridgeplay fix"))
        #expect(listedHero.actions.isEmpty)
        listed.health?.pauseFixedIn = "0.7.70"
        #expect(HeroState.make(Self.snapshot(health: listed), offModes: true).detail.contains("Update to Bridgeplay 0.7.70"))
        // Bridgeplay updated past the entry: that report is from another build and says nothing
        listed.freshness = .stale
        #expect(HeroState.make(Self.snapshot(health: listed), offModes: true).ready)

        let partly = HeroState.make(Self.snapshot(running: true, health: Self.reading(.active, .live, hooks: (10, 12))), offModes: true)
        #expect(partly.headline == "Partly working")
        #expect(!partly.ready)

        let unconfirmed = HeroState.make(Self.snapshot(running: true, health: Self.reading(.active, .stale)), offModes: true)
        #expect(unconfirmed.headline == "Not confirmed")
        // A report left by the previous start says nothing about this running Steam
        let earlier = HeroState.make(Self.snapshot(running: true, health: Self.reading(.active, .lastStart)), offModes: true)
        #expect(earlier.headline == "Not confirmed")
        #expect(!earlier.ready)
        // No health file at all (a dylib from before it): today's answer
        #expect(HeroState.make(Self.snapshot(running: true), offModes: true).ready)
    }
}

extension SteamHealthTests {
    @Test("Web gates count only from this Steam start")
    func webGates() {
        var reading = Self.reading(.active, .live)
        reading.health?.written = Date(timeIntervalSince1970: 1000)
        reading.web = SteamWebHealth(written: Date(timeIntervalSince1970: 900), gatesApplied: 3, gatesTotal: 5)
        #expect(HeroState.make(Self.snapshot(running: true, health: reading)).ready)
        reading.web?.written = Date(timeIntervalSince1970: 1001)
        #expect(HeroState.make(Self.snapshot(running: true, health: reading)).headline == "Partly working")
    }
}
