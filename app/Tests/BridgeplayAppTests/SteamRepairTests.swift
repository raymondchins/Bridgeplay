import Foundation
import Testing

@testable import BridgeplayApp

// Real package and real pin, like the Valve fetcher tests: whether the gate takes Valve's
// actual bytes and refuses everything else is not a fixture question. Serialized, one cache.
@Suite("Steam repair", .serialized)
struct SteamRepairTests {

    private func stagedStockBundle(into work: URL) async throws -> URL {
        let manifest = try ValvePackageManifest.bundled()
        let bundle = try #require(manifest.bundle)
        return try await SteamRepair.stage(
            bundle,
            bases: manifest.bases,
            downloads: try isolatedValveDownloads(in: work),
            work: work.appending(path: "staging")
        )
    }

    @Test("The pinned package unpacks to a bundle that is signed by Valve")
    func stagesAValveSignedBundle() async throws {
        let work = try scratchDirectory("repair")
        defer { try? FileManager.default.removeItem(at: work) }
        let staged = try await stagedStockBundle(into: work)

        #expect(staged.lastPathComponent == "Steam.app")
        #expect(throws: Never.self) { try SteamRepair.verifyValveSignature(staged) }

        // The bundle Valve ships declares LC_ALL and no insert. Everything repair does to
        // the inner plist is measured against this, so it is asserted rather than assumed.
        let plist = try #require(SteamBundle.readInfoPlist(at: staged.appending(path: "Contents/Info.plist")))
        #expect(plist["CFBundleVersion"] as? String == "6.1")
        let environment = try #require(plist[SteamBundle.environmentKey] as? [String: Any])
        #expect(environment[SteamBundle.insertKey] == nil)
        #expect(environment["LC_ALL"] as? String == "en_US.UTF-8")
        #expect(environment.count == 1)
    }

    // The case that actually occurs: an injected bundle is ad-hoc signed and an ad-hoc signature
    // verifies strictly, so only the authority check catches it. Repair checks both.
    @Test("An ad-hoc signed bundle is refused even though it verifies strictly")
    func refusesAdHocSignedBundle() async throws {
        let work = try scratchDirectory("repair")
        defer { try? FileManager.default.removeItem(at: work) }
        let staged = try await stagedStockBundle(into: work)

        let copy = work.appending(path: "copy/Steam.app")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: staged, to: copy)
        try Shell.check("/usr/bin/codesign", ["-f", "-s", "-", copy.path(percentEncoded: false)])

        // Strict verification passes, which is precisely the trap.
        let strict = try Shell.run("/usr/bin/codesign", ["--verify", "--strict", copy.path(percentEncoded: false)])
        #expect(strict.succeeded, "an ad-hoc signature was expected to verify against itself")

        #expect(throws: StepFailure.self) { try SteamRepair.verifyValveSignature(copy) }
    }

    // codesign echoes the path it was given into the description it prints, so a bundle under
    // directories named after the fields repair looks for used to answer for them.
    @Test("A path named after the expected fields cannot answer for them")
    func refusesFieldsSuppliedByThePath() throws {
        let work = try scratchDirectory("repair")
        defer { try? FileManager.default.removeItem(at: work) }

        let nested = work
            .appending(path: "TeamIdentifier=\(SteamRepair.valveTeam)")
            .appending(path: "Identifier=\(SteamRepair.valveIdentifier)")
        let app = nested.appending(path: "Steam.app")
        try FileManager.default.createDirectory(
            at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: URL(filePath: "/bin/echo"), to: app.appending(path: "Contents/MacOS/Steam")
        )
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>Steam</string>
            <key>CFBundleIdentifier</key><string>com.attacker.evil</string>
            </dict></plist>
            """.utf8
        ).write(to: app.appending(path: "Contents/Info.plist"))

        let path = app.path(percentEncoded: false)
        try Shell.check("/usr/bin/codesign", ["-f", "-s", "-", path])

        // The same trap as above: this verifies against itself, so only the authority
        // check stands between it and being installed as stock.
        let strict = try Shell.run("/usr/bin/codesign", ["--verify", "--strict", path])
        #expect(strict.succeeded, "the ad-hoc signature was expected to verify against itself")

        // And it is genuinely not Valve's, so the refusal below is the fields being
        // matched whole rather than anything about this bundle's own signature.
        let described = try Shell.run("/usr/bin/codesign", ["-dvv", path])
        let text = described.stdout + described.stderr
        #expect(text.contains("Signature=adhoc"))
        #expect(text.contains("TeamIdentifier=not set"))

        #expect(throws: StepFailure.self) { try SteamRepair.verifyValveSignature(app) }
    }

    @Test("A bundle with an added file no longer matches its signature and is refused")
    func refusesTamperedBundle() async throws {
        let work = try scratchDirectory("repair")
        defer { try? FileManager.default.removeItem(at: work) }
        let staged = try await stagedStockBundle(into: work)

        let copy = work.appending(path: "copy/Steam.app")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: staged, to: copy)
        #expect(throws: Never.self) { try SteamRepair.verifyValveSignature(copy) }

        // The injection this whole project performs, which is what repair exists to undo.
        try Data("not a dylib".utf8).write(to: copy.appending(path: "Contents/MacOS/notproton.dylib"))

        #expect(throws: StepFailure.self) { try SteamRepair.verifyValveSignature(copy) }
    }

    // Setup's download of steam.dmg goes through the same gate before Steam.app is copied.
    @Test("Setup copies Steam out of the image only when Valve signed it")
    func setupCopiesOnlyValveSignedSteam() async throws {
        let work = try scratchDirectory("repair")
        defer { try? FileManager.default.removeItem(at: work) }
        let staged = try await stagedStockBundle(into: work)

        let installed = work.appending(path: "apps/Steam.app")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SetupChecks.copySteam(from: staged.deletingLastPathComponent(), to: installed)
        #expect(throws: Never.self) { try SteamRepair.verifyValveSignature(installed) }

        let forged = work.appending(path: "image/Steam.app")
        try FileManager.default.createDirectory(at: forged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: staged, to: forged)
        try Shell.check("/usr/bin/codesign", ["-f", "-s", "-", forged.path(percentEncoded: false)])
        let refused = work.appending(path: "refused/Steam.app")
        let failure = try #require(throws: StepFailure.self) {
            try SetupChecks.copySteam(from: forged.deletingLastPathComponent(), to: refused)
        }
        #expect(failure.step == SetupChecks.step)
        #expect(!FileManager.default.fileExists(atPath: refused.path(percentEncoded: false)))
    }

    @Test("A manifest with no bundle row cannot repair")
    func refusesManifestWithoutBundle() async throws {
        let real = try ValvePackageManifest.bundled()
        let without = ValvePackageManifest(
            bases: real.bases, packages: real.packages, files: real.files, bundle: nil
        )

        await #expect(throws: StepFailure.self) {
            try await SteamRepair.run(manifest: without)
        }
    }

    // A patched Steam in scratch, for the runs below. Every path a repair defaults to is
    // passed in, since those are the real Steam's.
    private struct Patched {
        let work: URL, app: URL, modifications: SteamModifications
        var marker: URL { SupportPaths.Steam.deployedDylib(inBundle: app) }
        var isUntouched: Bool { FileManager.default.contents(atPath: marker.path(percentEncoded: false)) == Data("patched".utf8) }

        func repair(manifest: ValvePackageManifest? = nil, downloads: URL,
                    stopClient: @escaping SteamInstaller.ClientStopper,
                    runningBuild: @escaping @Sendable () -> String? = { nil },
                    report: @escaping @Sendable (RepairPhase) -> Void = { _ in }) async throws {
            _ = try await SteamRepair.run(
                manifest: manifest, app: app, innerPlist: work.appending(path: "inner.plist"), updateBlocks: [],
                backups: work.appending(path: "support/backups"), downloads: downloads,
                modifications: modifications, stopClient: stopClient, register: { _ in },
                runningBuild: runningBuild, report: report)
        }
    }

    private func patched(from stock: URL, in work: URL) throws -> Patched {
        let app = work.appending(path: "installed/Steam.app")
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: stock, to: app)
        let patched = Patched(work: work, app: app, modifications: SteamModifications(
            file: work.appending(path: "steam-bundles.json"), legacyRecord: work.appending(path: "support/install-build.json")))
        try Data("patched".utf8).write(to: patched.marker)
        try patched.modifications.mark(app)
        return patched
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    @Test("A Steam that won't stop is not replaced")
    func stopFailureKeepsTheBundle() async throws {
        let work = try scratchDirectory("repair-stop-failure")
        defer { try? FileManager.default.removeItem(at: work) }
        let steam = try patched(from: try await stagedStockBundle(into: work), in: work)

        struct StillRunning: Error {}
        await #expect(throws: StillRunning.self) {
            try await steam.repair(downloads: try isolatedValveDownloads(in: work), stopClient: { _, _ in throw StillRunning() })
        }

        #expect(steam.isUntouched)
    }

    @Test("A running game stops the repair before anything is downloaded")
    func runningGameRefusesTheRepair() async throws {
        let work = try scratchDirectory("repair-running-game")
        defer { try? FileManager.default.removeItem(at: work) }
        let steam = try patched(from: try await stagedStockBundle(into: work), in: work)
        let log = Log()

        let refusal = try await #require(throws: StepFailure.self) {
            try await steam.repair(downloads: try isolatedValveDownloads(in: work), stopClient: { _, _ in
                log.add("stopped")
                return true
            }, runningBuild: { "27.0.0" }, report: { log.add($0.label) })
        }

        #expect(refusal.detail.contains("27.0.0"))
        #expect(log.all.isEmpty)
        #expect(steam.isUntouched)
    }

    @Test("A game started during the download stops the repair before Steam is touched")
    func gameStartedDuringTheDownloadRefusesTheRepair() async throws {
        let work = try scratchDirectory("repair-game-started")
        defer { try? FileManager.default.removeItem(at: work) }
        let steam = try patched(from: try await stagedStockBundle(into: work), in: work)
        let log = Log()

        await #expect(throws: StepFailure.self) {
            try await steam.repair(downloads: try isolatedValveDownloads(in: work), stopClient: { _, _ in
                log.add("stopped")
                return true
            }, runningBuild: {
                log.all.contains(RepairPhase.checking.label) ? "27.0.0" : nil
            }, report: { log.add($0.label) })
        }

        #expect(!log.all.contains("stopped"))
        #expect(steam.isUntouched)
    }

    @Test("The staged bundle is checked and Steam stopped before the old bundle goes")
    func stopsBeforeReplacing() async throws {
        let work = try scratchDirectory("repair-stop-order")
        defer { try? FileManager.default.removeItem(at: work) }
        let steam = try patched(from: try await stagedStockBundle(into: work), in: work)
        let log = Log()

        try await steam.repair(downloads: try isolatedValveDownloads(in: work), stopClient: { _, onStopping in
            onStopping()
            #expect(steam.isUntouched)
            return true
        }, report: { log.add($0.label) })

        #expect(!steam.isUntouched)
        let checked = try #require(log.all.firstIndex(of: RepairPhase.checking.label))
        let stopped = try #require(log.all.firstIndex(of: RepairPhase.stoppingClient.label))
        #expect(checked < stopped)
    }

    @Test("A staged bundle Valve didn't sign stops the repair before Steam is touched")
    func unsignedBundleNeverStopsSteam() async throws {
        let work = try scratchDirectory("repair-unsigned")
        defer { try? FileManager.default.removeItem(at: work) }
        let steam = try patched(from: try await stagedStockBundle(into: work), in: work)

        // Laid out as Valve's package is: a zip holding a tar.gz of the bundle.
        let host = work.appending(path: "host")
        let contents = host.appending(path: "Steam.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: contents.appending(path: "Info.plist"))
        let path = host.path(percentEncoded: false)
        try Shell.check("/usr/bin/tar", ["-czf", path + "/inner.tar.gz", "-C", path, "Steam.app"])
        try Shell.check("/usr/bin/zip", ["-q", "-j", path + "/package.zip", path + "/inner.tar.gz"])
        let package = host.appending(path: "package.zip")
        let manifest = ValvePackageManifest(
            bases: [host], packages: [], files: [],
            bundle: ValveBundle(file: "package.zip", sha256: try Digest.sha256(of: package),
                                innerArchive: "inner.tar.gz", bundleName: "Steam.app"))
        let log = Log()

        let refusal = try await #require(throws: StepFailure.self) {
            try await steam.repair(manifest: manifest, downloads: work.appending(path: "unsigned-downloads"), stopClient: { _, _ in
                log.add("stopped")
                return true
            })
        }

        #expect(refusal.detail.contains("does not verify against its own signature"))
        #expect(log.all.isEmpty)
        #expect(steam.isUntouched)
    }

    @Test("A repaired Steam is not outstanding after its drive disconnects")
    func retiresRepairedSteamBeforeDisconnect() async throws {
        let work = try scratchDirectory("repair-tracking")
        defer { try? FileManager.default.removeItem(at: work) }
        let stock = try await stagedStockBundle(into: work)
        let drive = work.appending(path: "external")
        let app = drive.appending(path: "Steam.app")
        let support = work.appending(path: "support")
        let modifications = SteamModifications(file: work.appending(path: "steam-bundles.json"),
                                              legacyRecord: support.appending(path: "install-build.json"))
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: stock, to: app)
        try Data("patched".utf8).write(to: SupportPaths.Steam.deployedDylib(inBundle: app))
        try modifications.mark(app)

        _ = try await SteamRepair.run(
            app: app, innerPlist: work.appending(path: "inner.plist"), updateBlocks: [],
            backups: support.appending(path: "backups"), downloads: try isolatedValveDownloads(in: work),
            modifications: modifications, stopClient: { _, _ in false }, register: { _ in }, runningBuild: { nil })

        #expect(try modifications.paths().isEmpty)
        try FileManager.default.moveItem(at: drive, to: work.appending(path: "disconnected"))
        let result = try await Uninstall.run(
            app: app, innerPlist: work.appending(path: "inner.plist"), updateBlocks: [],
            legacyCompat: work.appending(path: "legacycompat"), compatTools: [],
            directories: [support], libraries: [], modifications: modifications, lockFolder: work,
            leftovers: Uninstall.Leftovers(gamefixes: support.appending(path: "gamefixes"), keptGamefixes: work.appending(path: "kept"),
                                           steamConfig: work.appending(path: "config.vdf"),
                                           defaultToolBackup: support.appending(path: "backups/steam-default-tool.json"),
                                           files: [], steamRunning: { false }),
            repair: { _, _ in Issue.record("A disconnected repaired copy needs no repair") },
            stop: { _, _ in false })

        #expect(result.partialRemoval == nil)
        #expect(!result.steamNeedsRedownload)
    }

    // MARK: - The inner plist

    @Test("Clearing the insert removes the keys Bridgeplay added and nothing else")
    func clearsOnlyTheInsert() throws {
        let work = try scratchDirectory("repair")
        defer { try? FileManager.default.removeItem(at: work) }

        let plist = work.appending(path: "Info.plist")
        let stock: [String: Any] = [
            "CFBundleVersion": "6.1",
            SteamBundle.environmentKey: ["LC_ALL": "en_US.UTF-8"],
        ]
        var tampered = stock
        tampered[SteamBundle.environmentKey] = [
            "LC_ALL": "en_US.UTF-8",
            SteamBundle.insertKey: "/Applications/Steam.app/Contents/MacOS/notproton.dylib",
            SteamBundle.controllerBlockKey: SteamBundle.controllerBlockValue,
        ]
        try SteamBundle.writeInfoPlist(tampered, at: plist)

        #expect(try SteamRepair.clearInsert(at: plist))

        let after = try #require(SteamBundle.readInfoPlist(at: plist))
        let environment = try #require(after[SteamBundle.environmentKey] as? [String: Any])
        #expect(environment[SteamBundle.insertKey] == nil)
        #expect(environment[SteamBundle.controllerBlockKey] == nil)
        #expect(environment["LC_ALL"] as? String == "en_US.UTF-8", "LC_ALL is Valve's and has to survive")
        #expect(environment.count == 1, "the environment dict is kept rather than emptied")
        #expect(after["CFBundleVersion"] as? String == "6.1")

        // Running twice is not an error, and the second run reports it changed nothing.
        #expect(try SteamRepair.clearInsert(at: plist) == false)
    }

    @Test("Clearing the insert reports nothing done when there is no plist or no insert")
    func clearInsertIsQuietWhenThereIsNothingToDo() throws {
        let work = try scratchDirectory("repair")
        defer { try? FileManager.default.removeItem(at: work) }

        #expect(try SteamRepair.clearInsert(at: work.appending(path: "absent.plist")) == false)

        let bare = work.appending(path: "bare.plist")
        try SteamBundle.writeInfoPlist(["CFBundleVersion": "6.1"], at: bare)
        #expect(try SteamRepair.clearInsert(at: bare) == false)
    }

    // MARK: - The invalidated backup

    // What matters is that both sides agree on the name, so this drives one with the other. A
    // test that hardcoded the name would still pass if the two diverged.
    @Test("Repair removes the backup the installer wrote")
    func removesTheBackupTheInstallerWrote() throws {
        let work = try scratchDirectory("repair")
        defer { try? FileManager.default.removeItem(at: work) }

        let plist = work.appending(path: "Info.plist")
        let backups = work.appending(path: "backups")
        try SteamBundle.writeInfoPlist(["CFBundleVersion": "6.1"], at: plist)

        #expect(try SteamInstaller.backUpPlist(plist, into: backups))
        #expect(try SteamRepair.removeStaleBackup(from: backups))

        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: backups.path(percentEncoded: false)
        )
        #expect(leftovers.isEmpty, "left behind: \(leftovers)")
    }

    @Test("Removing a backup that is not there is not a failure")
    func absentBackupIsNotAFailure() throws {
        let work = try scratchDirectory("repair")
        defer { try? FileManager.default.removeItem(at: work) }

        #expect(try SteamRepair.removeStaleBackup(from: work.appending(path: "backups")) == false)
    }

    // MARK: - The swap

    @Test("Replacing a bundle leaves Valve's signature intact at the destination")
    func replaceInstallsAVerifiableBundle() async throws {
        let work = try scratchDirectory("repair")
        defer { try? FileManager.default.removeItem(at: work) }
        let staged = try await stagedStockBundle(into: work)

        // Stand in for the tampered bundle being replaced, so this exercises the
        // replaceItemAt path rather than the install-into-nothing one.
        let destination = work.appending(path: "dest/Steam.app")
        try FileManager.default.createDirectory(
            at: destination.appending(path: "Contents/MacOS"), withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: destination.appending(path: "Contents/MacOS/notproton.dylib"))

        try SteamRepair.replace(destination, with: staged)

        #expect(throws: Never.self) { try SteamRepair.verifyValveSignature(destination) }
        let plist = destination.appending(path: "Contents/Info.plist")
        #expect(SteamBundle.readInfoPlist(at: plist)?["CFBundleVersion"] as? String == "6.1")
        #expect(SteamBundle.currentInsert(at: plist) == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appending(path: "Contents/MacOS/notproton.dylib").path(percentEncoded: false)
            ),
            "the injected dylib survived the replacement"
        )
    }

    @Test("A bundle that is not installed at all is installed rather than refused")
    func replaceInstallsWhenNothingIsThere() async throws {
        let work = try scratchDirectory("repair")
        defer { try? FileManager.default.removeItem(at: work) }
        let staged = try await stagedStockBundle(into: work)

        let destination = work.appending(path: "dest/Steam.app")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try SteamRepair.replace(destination, with: staged)

        #expect(throws: Never.self) { try SteamRepair.verifyValveSignature(destination) }
    }

    @Test("A copy onto another volume is checked before it replaces Steam")
    func crossVolumeCopyIsCheckedFirst() throws {
        let work = try scratchDirectory("repair")
        defer { try? FileManager.default.removeItem(at: work) }
        let image = work.appending(path: "other.dmg").path(percentEncoded: false)
        let mount = work.appending(path: "other")
        try #require(Shell.run("/usr/bin/hdiutil", [
            "create", "-quiet", "-size", "8m", "-fs", "HFS+", "-volname", "np-repair-test", image,
        ]).succeeded)
        try #require(Shell.run("/usr/bin/hdiutil", [
            "attach", "-quiet", "-nobrowse", "-mountpoint", mount.path(percentEncoded: false), image,
        ]).succeeded)
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", mount.path(percentEncoded: false)]) }

        let staged = work.appending(path: "staging/Steam.app")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("valve".utf8).write(to: staged.appending(path: "marker"))
        let app = mount.appending(path: "Steam.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("current".utf8).write(to: app.appending(path: "marker"))

        var checked: [URL] = []
        #expect(throws: StepFailure.self) {
            try SteamRepair.replace(app, with: staged) {
                checked.append($0)
                throw StepFailure(step: "test", detail: "altered by the copy")
            }
        }

        #expect(checked.count == 1)
        #expect(checked.first?.deletingLastPathComponent().path == mount.path)
        #expect(try String(contentsOf: app.appending(path: "marker"), encoding: .utf8) == "current")
        #expect(try FileManager.default.contentsOfDirectory(atPath: mount.path(percentEncoded: false))
            .filter { $0.hasPrefix(".Steam.app.") }.isEmpty)
    }

    // The wording is defined once on PinnedDownload.Progress so repair and the fetcher
    // cannot drift apart on it. This case is the only thing carrying it out of repair.
    @Test("The download phase shows the download's own wording")
    func downloadPhaseDelegatesItsLabel() {
        #expect(RepairPhase.downloading(.reusing).label
                == PinnedDownload.Progress.reusing.label)
        #expect(RepairPhase.downloading(.fetching(host: "cdn.example")).label
                == "Downloading from cdn.example")
    }

}
