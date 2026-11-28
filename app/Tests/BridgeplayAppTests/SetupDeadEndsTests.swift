import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Setup dead ends")
struct SetupDeadEndsTests {

    private func folder() throws -> URL {
        try scratchDirectory("setup-dead-ends")
    }

    private func snapshot(steam: SteamDeployment, runners: [RunnerBuild] = [], engines: Set<String> = []) -> StatusSnapshot {
        let payload = PayloadState(expected: 0, present: 0, missing: [], overlayShimPresent: true,
                                   iconmakerPresent: true, appinfoPresent: true, signatureDatabase: "fixture",
                                   legacyCompatPresent: 0, legacyCompatExpected: 0, manifestProblem: nil)
        return StatusSnapshot(steam: steam, steamRunning: false, updateBlocked: false, crossOver: [], runner: .none,
                              payload: payload, installedRunners: runners, currentFreeEngines: engines)
    }

    private static let runner = RunnerBuild(bundleVersion: "test-build", releaseVersion: "test-build", flavor: nil,
                                            loaderSHA256: "", cleanNtdll: [:], patchedNtdll: [:])

    @Test("Not Now leaves Setup to open again; only closing the Done step finishes it")
    @MainActor
    func notNow() {
        #expect(!SetupAssistant.closingFinishes(.mac))
        #expect(!SetupAssistant.closingFinishes(.finish))
        #expect(SetupAssistant.closingFinishes(.done))
        #expect(SetupAssistant.shouldShow(snapshot(steam: .notInstalled), defaults: scratchDefaults()))
    }

    @Test("Setup stays away once Steam has Bridgeplay and an engine, WineCX or another")
    @MainActor
    func readyMacs() {
        let defaults = scratchDefaults()
        let installed = SteamDeployment.installed(version: nil)
        #expect(SetupAssistant.shouldShow(snapshot(steam: installed), defaults: defaults))
        #expect(!SetupAssistant.shouldShow(snapshot(steam: installed, runners: [Self.runner]), defaults: defaults))
        #expect(!SetupAssistant.shouldShow(snapshot(steam: installed, engines: [FreeEngineWinecx.current.build]), defaults: defaults))
        #expect(SetupAssistant.shouldShow(snapshot(steam: .notInstalled, runners: [Self.runner]), defaults: defaults))
    }

    @Test("Set Up downloads first, before anything that quits Steam")
    @MainActor
    func downloadsFirst() {
        #expect(SetupAssistant.plannedTasks.map(\.id) == ["download", "steam", "engine", "default"])
    }

    @Test("A full disk stops the toolkit download with the free space named")
    @MainActor
    func fullDisk() async {
        let model = SetupAssistant(preview: .fresh)
        model.freeBytes = 1_000_000
        #expect(!model.hasSpace)
        await model.downloadGPTK()
        #expect(model.gptk == nil)
        #expect(model.message == model.spaceMessage)
        model.freeBytes = SetupChecks.requiredBytes
        #expect(model.hasSpace)
    }

    @Test("A full disk offers Storage settings, not a bug report")
    @MainActor
    func fullDiskIsNotReported() {
        let model = SetupAssistant(preview: .fresh)
        model.freeBytes = 1_000_000
        #expect(model.isOutOfSpace(model.spaceMessage))
        #expect(model.isOutOfSpace("Download: \(PinnedDownload.outOfSpaceDetail)"))
        #expect(!model.isOutOfSpace("The download's signature didn't match."))
    }

    @Test("A full disk still offers Storage after the free space changed")
    @MainActor
    func fullDiskAfterSpaceChanged() {
        let model = SetupAssistant(preview: .fresh)
        model.freeBytes = 1_000_000
        let before = model.spaceMessage
        let midway = "Download: \(PinnedDownload.outOfSpaceDetail(free: "1 MB"))"
        model.freeBytes = 3_000_000_000
        #expect(model.spaceMessage != before)
        #expect(model.isOutOfSpace(before))
        #expect(model.isOutOfSpace(midway))
        #expect(!model.isOutOfSpace("Download: \(before) Something else."))
        #expect(!model.isOutOfSpace("Download failed: the host answered 404."))
    }

    @Test("A full disk is told apart from other download failures")
    func outOfSpace() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [NSUnderlyingErrorKey: posix])
        #expect(PinnedDownload.outOfSpace(wrapped))
        #expect(PinnedDownload.outOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        #expect(PinnedDownload.outOfSpace(URLError(.cannotWriteToFile)))
        #expect(!PinnedDownload.outOfSpace(URLError(.timedOut)))
        #expect(!PinnedDownload.outOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    @Test("Steam outside /Applications is found; its inner bundle, the Trash and duplicates are not")
    func steamCandidates() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let external = try folder()
        defer { try? FileManager.default.removeItem(at: external) }
        let own = home.appending(path: "Applications/Steam.app")
        let inner = home.appending(path: "Library/Application Support/Steam/Steam.AppBundle/Steam")
        let trash = home.appending(path: ".Trash/Steam.app")
        let drive = external.appending(path: "Steam.app")
        let image = external.appending(path: "Image/Steam.app")
        for url in [own, inner, trash, drive, image] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let found = SetupChecks.steamCandidates(
            home: home, known: { [inner, trash, own, drive, image, external.appending(path: "Gone/Steam.app")] },
            isSteam: { _ in true }, isReadOnly: { $0 == image })
        #expect(found.map(\.standardizedFileURL) == [own, drive].map(\.standardizedFileURL))
        #expect(SetupChecks.steamCandidates(home: home, known: { [] }, isSteam: { _ in false }, isReadOnly: { _ in false }).isEmpty)
    }

    @Test("Who owns Steam is told on the first step")
    func steamAccess() {
        let app = URL(filePath: "/Applications/Steam.app")
        func access(present: Bool = true, owner: uid_t?, deployed: Bool = false, writable: Bool = true) -> SetupChecks.SteamAccess {
            var lookup = Remedy.Lookup()
            lookup.user = 501
            lookup.owner = { _ in owner }
            lookup.writable = { _ in writable }
            return SetupChecks.steamAccess(app: app, present: present, deployed: { deployed }, lookup: lookup)
        }
        #expect(access(owner: 501) == .ok)
        #expect(access(owner: nil) == .ok)
        #expect(access(owner: 502, deployed: true) == .thisAccountOnly)
        #expect(access(owner: 502) == .otherAccount)
        #expect(access(owner: 0) == .systemOwned)
        #expect(access(present: false, owner: nil) == .ok)
        #expect(access(present: false, owner: nil, writable: false) == .homeApplications)
        #expect(SetupChecks.accessNote(.ok) == nil)
        #expect(SetupChecks.accessNote(.otherAccount) != nil)
    }

    @Test("Set Up fetches the engine and DXMT, and Valve's packages only when a bridge file misses its pin")
    func prefetchList() async throws {
        let bridge = try folder()
        defer { try? FileManager.default.removeItem(at: bridge) }
        let bytes = Data("steamclient".utf8)
        let valve = ValvePackageManifest(
            bases: [URL(string: "https://example.invalid/client")!],
            packages: [ValvePackage(id: "win64", file: "bins_win64.zip.test", sha256: "aa")],
            files: [ValveFile(bridgePath: "x64/steamclient64.dll", package: "win64", innerPath: "steamclient64.dll",
                              sha256: Digest.sha256(of: bytes))],
            bundle: nil)
        let caches = bridge.appending(path: "caches")
        let release = FreeEngineWinecx.current
        func list() -> [String] {
            SetupPrefetch.files(valve: valve, bridge: bridge, engineCache: caches, rendererCache: caches, valveCache: caches).map(\.file)
        }
        #expect(list() == [release.archive, release.renderer.archive, "bins_win64.zip.test"])

        let file = bridge.appending(path: "x64/steamclient64.dll")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        #expect(list() == [release.archive, release.renderer.archive])

        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [String] = []
            func add(_ file: String) { lock.withLock { seen.append(file) } }
            var files: Set<String> { lock.withLock { Set(seen) } }
        }
        let seen = Seen()
        try await SetupPrefetch.run(SetupPrefetch.files(valve: valve, bridge: bridge, engineCache: caches,
                                                        rendererCache: caches, valveCache: caches)) { seen.add($0.file) }
        // They run side by side, so in no set order.
        #expect(seen.files == [release.archive, release.renderer.archive])
        #expect(!FileManager.default.fileExists(atPath: caches.path(percentEncoded: false)))
    }
}
