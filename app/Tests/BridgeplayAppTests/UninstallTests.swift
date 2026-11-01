import Foundation
import Testing

@testable import BridgeplayApp

// Every path is passed explicitly. The defaults are /Applications/Steam.app, the real
// steam.cfg and the real caches directory, so leaning on them would uninstall this machine.
@Suite("Uninstall")
struct UninstallTests {

    // The report closure is Sendable, so what it records has to be too.
    private final class PhaseLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [UninstallPhase] = []
        func add(_ phase: UninstallPhase) { lock.lock(); seen.append(phase); lock.unlock() }
        var all: [UninstallPhase] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func set() { lock.withLock { raised = true } }
        var value: Bool { lock.withLock { raised } }
    }

    private struct Layout: Sendable {
        let root: URL
        let app: URL
        let innerPlist: URL
        let updateBlock: URL
        let legacyCompat: URL
        let compatTool: URL
        let support: URL
        let caches: URL

        var compatTools: [URL] {
            SupportPaths.Steam.ourTools(in: compatTool.deletingLastPathComponent())
        }
        var secondTool: URL { compatTool.deletingLastPathComponent().appending(path: "bridgeplay-proton-26.3") }
        var foreignTool: URL { compatTool.deletingLastPathComponent().appending(path: "GE-Proton9-1") }

        var outerPlist: URL { app.appending(path: "Contents/Info.plist") }
        var dylib: URL { app.appending(path: "Contents/MacOS/\(SupportPaths.dylibName)") }
        var modifications: SteamModifications {
            SteamModifications(file: root.appending(path: "steam-bundles.json"),
                               legacyRecord: support.appending(path: "install-build.json"))
        }
        var steamConfig: URL { root.appending(path: "config.vdf") }
        var keptGamefixes: URL { root.appending(path: "bridgeplay-gamefixes") }
        var homeDir: URL { root.appending(path: ".bridgeplay") }
        var leftovers: Uninstall.Leftovers {
            Uninstall.Leftovers(
                gamefixes: support.appending(path: "gamefixes"),
                keptGamefixes: keptGamefixes,
                steamConfig: steamConfig,
                defaultToolBackup: support.appending(path: "backups/steam-default-tool.json"),
                files: [homeDir],
                steamRunning: { false })
        }
    }

    private func layout(signable: Bool = true) throws -> Layout {
        let files = FileManager.default
        let root = URL.temporaryDirectory.appending(path: "np-uninstall-\(UUID().uuidString)")
        let app = root.appending(path: "Steam.app")
        let macOS = app.appending(path: "Contents/MacOS")
        let inner = root.appending(path: "inner")
        let legacyCompat = inner.appending(path: "legacycompat")
        // Named as before 3.0, beside bridgeplay-proton-26.3: uninstalling removes both spellings.
        let compatTool = root.appending(path: "compatibilitytools.d/notproton")
        let support = root.appending(path: "bridgeplay")
        let caches = root.appending(path: "valve-packages")

        let tools = compatTool.deletingLastPathComponent()
        for dir in [macOS, inner, legacyCompat, compatTool, support, caches,
                    tools.appending(path: "bridgeplay-proton-26.3"), tools.appending(path: "GE-Proton9-1")] {
            try files.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let updateBlock = root.appending(path: "steam.cfg")
        // A client config holding a setting of Valve's beside the one Bridgeplay adds, which is
        // the shape that shows the removal taking out only its own line.
        try Data("BootStrapperInhibitAll=enable\nBootStrapperInhibitUpdateOnLaunch=enable\n".utf8)
            .write(to: updateBlock)
        try Data("1\n".utf8).write(to: support.appending(path: "dylib.version"))
        try Data("archive\n".utf8).write(to: caches.appending(path: "steam_client_osx.zip"))
        try Data("\"run\"\n".utf8).write(to: compatTool.appending(path: "toolmanifest.vdf"))

        let result = Layout(
            root: root,
            app: app,
            innerPlist: inner.appending(path: "Info.plist"),
            updateBlock: updateBlock,
            legacyCompat: legacyCompat,
            compatTool: compatTool,
            support: support,
            caches: caches
        )

        guard signable else { return result }

        // Signed for real rather than stubbed, because the thing worth checking is that a
        // plist edit inside a sealed bundle is followed by a signature that still verifies.
        let source = root.appending(path: "main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        try Shell.check("/usr/bin/clang", [
            "-o", macOS.appending(path: "steam_osx").path(percentEncoded: false),
            source.path(percentEncoded: false),
        ])
        try Shell.check("/usr/bin/clang", [
            "-dynamiclib",
            "-o", result.dylib.path(percentEncoded: false),
            source.path(percentEncoded: false),
        ])

        let injected: [String: Any] = [
            "CFBundleExecutable": "steam_osx",
            "CFBundleIdentifier": "com.valvesoftware.steam",
            SteamBundle.environmentKey: [
                "LC_ALL": "C",
                SteamBundle.insertKey: result.dylib.path(percentEncoded: false),
            ],
        ]
        try SteamBundle.writeInfoPlist(injected, at: result.outerPlist)
        try SteamBundle.writeInfoPlist(injected, at: result.innerPlist)
        try SteamInstaller.adHocSign(app)

        return result
    }

    @Test("Detaching leaves a Steam that loads nothing of ours")
    func takesEverythingOfOursOutOfTheBundle() throws {
        let layout = try layout(signable: true)
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let files = FileManager.default

        let detached = try Uninstall.detach(
            from: layout.app,
            innerPlist: layout.innerPlist,
            updateBlocks: [layout.updateBlock]
        )

        #expect(detached)
        #expect(SteamBundle.currentInsert(at: layout.outerPlist) == nil)
        #expect(SteamBundle.currentInsert(at: layout.innerPlist) == nil)
        #expect(!files.fileExists(atPath: layout.dylib.path(percentEncoded: false)))
        #expect(unpinnedWithoutLosingTheRest(layout.updateBlock))

        // LC_ALL is stock and has to survive, or the detach has swapped one difference
        // from Valve's bundle for another.
        let environment = SteamBundle.readInfoPlist(at: layout.outerPlist)?[
            SteamBundle.environmentKey
        ] as? [String: Any]
        #expect(environment?["LC_ALL"] as? String == "C")

        let verified = try Shell.run("/usr/bin/codesign", [
            "--verify", "--deep", layout.app.path(percentEncoded: false),
        ])
        #expect(verified.succeeded)
    }

    // The client is no longer pinned and the setting that was not Bridgeplay's is still there.
    private func unpinnedWithoutLosingTheRest(_ cfg: URL) -> Bool {
        guard let text = try? String(contentsOf: cfg, encoding: .utf8) else { return false }
        return !UpdateBlock.isPresent(at: [cfg]) && text.contains("BootStrapperInhibitAll=enable")
    }

    private func verifies(_ app: URL) throws -> Bool {
        try Shell.run("/usr/bin/codesign", [
            "--verify", "--deep", app.path(percentEncoded: false),
        ]).succeeded
    }

    // These hold no signature but used to be cleared after the bundle's own plist, so a throw
    // returned with the bundle edited and unsigned, which is a Steam only a redownload fixes.
    @Test("A removal that fails outside the bundle leaves the bundle alone")
    func failureOutsideTheBundleLeavesItSigned() throws {
        let files = FileManager.default
        let layout = try layout(signable: true)
        defer { try? FileManager.default.removeItem(at: layout.root) }
        // The block is taken out by rewriting steam.cfg without that line, since the file holds
        // settings of Valve's too, so it is the file that has to refuse the write.
        try files.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: layout.updateBlock.path(percentEncoded: false))
        defer {
            try? files.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: layout.updateBlock.path(percentEncoded: false))
        }

        // Pinned to the refused write rather than to any throw at all, so the test cannot pass
        // on a failure from somewhere else in the removal.
        #expect(throws: WriteRefused.self) {
            try Uninstall.detach(
                from: layout.app, innerPlist: layout.innerPlist, updateBlocks: [layout.updateBlock])
        }

        #expect(SteamBundle.currentInsert(at: layout.outerPlist) != nil)
        #expect(try verifies(layout.app))
    }

    // Once the plist is cleared the executable will not validate until it is signed again, so a
    // throw between the two signs anyway. Forward, not back: the client starts carrying nothing.
    @Test("A removal that fails inside the bundle still signs it")
    func failureInsideTheBundleStillSignsIt() throws {
        let layout = try layout(signable: true)
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let dylib = layout.dylib.path(percentEncoded: false)
        try Shell.check("/usr/bin/chflags", ["uchg", dylib])
        defer { _ = try? Shell.check("/usr/bin/chflags", ["nouchg", dylib]) }

        #expect(throws: (any Error).self) {
            try Uninstall.detach(
                from: layout.app, innerPlist: layout.innerPlist, updateBlocks: [layout.updateBlock])
        }

        #expect(SteamBundle.currentInsert(at: layout.outerPlist) == nil)
        #expect(try verifies(layout.app))
    }

    @Test("A restore that fails does not cancel the removal")
    func removesEverythingWhenSteamCannotBeRestored() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        struct Offline: Error {}

        let outcome = try await Uninstall.run(
            app: layout.app,
            innerPlist: layout.innerPlist,
            updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat,
            compatTools: layout.compatTools,
            directories: [layout.support, layout.caches],
            libraries: [],
            modifications: layout.modifications, lockFolder: layout.root, leftovers: layout.leftovers,
            repair: { _, _ in throw Offline() },
            stop: { _, _ in false }
        )

        #expect(outcome.restoredValveSignature == false)

        let files = FileManager.default
        #expect(!files.fileExists(atPath: layout.support.path(percentEncoded: false)))
        #expect(!files.fileExists(atPath: layout.caches.path(percentEncoded: false)))
        #expect(!files.fileExists(atPath: layout.legacyCompat.path(percentEncoded: false)))
        #expect(
            !files.fileExists(atPath: layout.compatTool.path(percentEncoded: false)),
            "Steam would still list the tool in its dropdown after a removal"
        )
        #expect(!files.fileExists(atPath: layout.secondTool.path(percentEncoded: false)))
        #expect(files.fileExists(atPath: layout.foreignTool.path(percentEncoded: false)))
        #expect(unpinnedWithoutLosingTheRest(layout.updateBlock))
    }

    @Test("A removal does not install Steam when there is none")
    func leavesAMissingSteamMissing() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try FileManager.default.removeItem(at: layout.app)
        let repaired = Flag()

        let outcome = try await Uninstall.run(
            app: layout.app,
            innerPlist: layout.innerPlist,
            updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat,
            compatTools: layout.compatTools,
            directories: [layout.support, layout.caches],
            libraries: [],
            modifications: layout.modifications, lockFolder: layout.root, leftovers: layout.leftovers,
            repair: { _, _ in repaired.set() },
            stop: { _, _ in false }
        )

        #expect(!repaired.value)
        #expect(!outcome.steamInstalled)
        #expect(!outcome.steamNeedsRedownload)
        #expect(outcome.partialRemoval == nil)
        #expect(!FileManager.default.fileExists(atPath: layout.app.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: layout.support.path(percentEncoded: false)))
    }

    @Test("A removal with Steam's drive unplugged removes the rest and says Steam was left alone")
    func reportsAnUnpluggedSteam() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let unplugged = URL(filePath: "/Volumes/np-missing-\(UUID().uuidString)/Steam.app")
        try layout.modifications.mark(unplugged)

        let outcome = try await Uninstall.run(
            app: unplugged,
            innerPlist: layout.innerPlist,
            updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat,
            compatTools: layout.compatTools,
            directories: [layout.support, layout.caches],
            libraries: [],
            modifications: layout.modifications, lockFolder: layout.root, leftovers: layout.leftovers,
            repair: { _, _ in },
            stop: { _, _ in false }
        )

        #expect(outcome.unreachableSteam == [unplugged])
        #expect(outcome.partialRemoval?.contains(unplugged.path(percentEncoded: false)) == true)
        #expect(!FileManager.default.fileExists(atPath: layout.support.path(percentEncoded: false)))
    }

    @Test("An unplugged Steam that Bridgeplay was never installed into is not reported")
    func ignoresAnUnpluggedSteamWithoutBridgeplay() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }

        let outcome = try await Uninstall.run(
            app: URL(filePath: "/Volumes/np-missing-\(UUID().uuidString)/Steam.app"),
            innerPlist: layout.innerPlist,
            updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat,
            compatTools: layout.compatTools,
            directories: [layout.support, layout.caches],
            libraries: [],
            modifications: layout.modifications, lockFolder: layout.root, leftovers: layout.leftovers,
            repair: { _, _ in },
            stop: { _, _ in false }
        )

        #expect(outcome.partialRemoval == nil)
    }

    @Test("Shipped build records migrate to /Applications once")
    func readsTheInstalledSteam() throws {
        let root = try scratchDirectory("installed-steam")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = root.appending(path: "install-build.json")
        let modifications = SteamModifications(file: root.appending(path: "steam-bundles.json"), legacyRecord: record)

        #expect(try modifications.paths().isEmpty)
        try Data(#"{"version":"1.1.7","builtAt":1}"#.utf8).write(to: record)
        #expect(try modifications.paths() == [SupportPaths.Steam.defaultApp])
        try modifications.prepare()
        try FileManager.default.removeItem(at: record)
        #expect(try modifications.paths() == [SupportPaths.Steam.defaultApp])
        try Data(#"{"version":"1.1.7","builtAt":1}"#.utf8).write(to: record)
        try JSONEncoder().encode([String]()).write(to: modifications.file)
        #expect(try modifications.paths().isEmpty)
    }

    @Test("A restore that fails asks for a redownload")
    func asksForARedownloadWhenTheRestoreFails() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        struct Offline: Error {}

        let outcome = try await Uninstall.run(
            app: layout.app,
            innerPlist: layout.innerPlist,
            updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat,
            compatTools: layout.compatTools,
            directories: [layout.support, layout.caches],
            libraries: [],
            modifications: layout.modifications, lockFolder: layout.root, leftovers: layout.leftovers,
            repair: { _, _ in throw Offline() },
            stop: { _, _ in false }
        )

        #expect(outcome.steamNeedsRedownload)
    }

    @Test("The command line names the path it could not write")
    func namesTheRefusedPath() {
        let path = "/nonexistent/Steam.app/Contents/Info.plist"
        let message = RemoveEverythingCommand.failureMessage(WriteRefused(path: path))
        #expect(message.hasPrefix("Could not write \(path). "))
        #expect(RemoveEverythingCommand.failureMessage(StepFailure(step: "x", detail: "Steam is running, please close Steam."))
            == StepFailure(step: "x", detail: "Steam is running, please close Steam.").localizedDescription)
    }

    @Test("The copy the restore downloads is removed with everything else")
    func removesWhatTheRestoreLeavesBehind() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let caches = layout.caches
        try FileManager.default.removeItem(at: caches)

        let outcome = try await Uninstall.run(
            app: layout.app,
            innerPlist: layout.innerPlist,
            updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat,
            compatTools: layout.compatTools,
            directories: [layout.support, caches],
            libraries: [],
            modifications: layout.modifications, lockFolder: layout.root, leftovers: layout.leftovers,
            repair: { _, _ in
                let staged = caches.appending(path: "bundle")
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                try Data("2.6G of Steam".utf8).write(to: staged.appending(path: "Steam.app"))
            },
            stop: { _, _ in false }
        )

        #expect(outcome.restoredValveSignature)
        #expect(!FileManager.default.fileExists(atPath: caches.path(percentEncoded: false)))
    }

    // Restoring forwards whatever phase repair reached. Carrying the phase rather than its
    // rendering lets this assert on the phase and keeps the wording in one place.
    @Test("A removal reports the repair's own phases while it restores")
    func reportsTheRepairPhases() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }

        let log = PhaseLog()
        _ = try await Uninstall.run(
            app: layout.app,
            innerPlist: layout.innerPlist,
            updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat,
            compatTools: layout.compatTools,
            directories: [layout.support, layout.caches],
            libraries: [],
            modifications: layout.modifications, lockFolder: layout.root, leftovers: layout.leftovers,
            report: { log.add($0) },
            repair: { _, report in
                report(.checking)
                report(.replacing)
            },
            stop: { _, _ in false }
        )

        let restoring = log.all.compactMap { phase -> RepairPhase? in
            if case .restoring(let inner) = phase { inner } else { nil }
        }
        #expect(restoring.count == 2)
        #expect(restoring.contains { if case .checking = $0 { true } else { false } })
        #expect(restoring.contains { if case .replacing = $0 { true } else { false } })

        // Read from the outer phase, which is what the window shows: the wording has to come
        // from RepairPhase rather than being restated here.
        let labels = log.all.map(\.label)
        #expect(labels.contains(RepairPhase.checking.label))
        #expect(labels.contains(RepairPhase.replacing.label))
    }

    @Test("Uninstall removes templates of installed builds but keeps unrelated library data")
    func removesLibraryTemplates() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let library = SteamLibrary(root: layout.root.appending(path: "library"))
        let build = "26.3.0.39832"
        let templates = SupportPaths.prefixTemplates(forBuild: build, in: library)
        for template in templates {
            try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: build, runners: layout.support.appending(path: "runners")),
            withIntermediateDirectories: true)
        let unrelated = templates[0].deletingLastPathComponent().appending(path: "notes")
        try Data("keep".utf8).write(to: unrelated)

        _ = try await Uninstall.run(
            app: layout.app, innerPlist: layout.innerPlist, updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat, compatTools: layout.compatTools,
            directories: [layout.support, layout.caches], libraries: [library],
            modifications: layout.modifications, lockFolder: layout.root, leftovers: layout.leftovers,
            repair: { _, _ in }, stop: { _, _ in false })

        for template in templates { #expect(!FileManager.default.fileExists(atPath: template.path)) }
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep")
        #expect(FileManager.default.fileExists(atPath: library.compatdata.appending(path: ".notproton-template.lock").path))
    }

    @Test("Uninstall removes the Steam.dll links it made and leaves any other Steam.dll")
    func removesSteamDLLLinks() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let files = FileManager.default
        let ours = SteamLibrary(root: layout.root.appending(path: "ours"))
        let foreign = SteamLibrary(root: layout.root.appending(path: "foreign"))
        let real = SteamLibrary(root: layout.root.appending(path: "real"))
        let empty = SteamLibrary(root: layout.root.appending(path: "empty"))
        func dll(_ library: SteamLibrary) -> URL { library.steamapps.appending(path: "common/Steam.dll") }
        for library in [ours, foreign, real] {
            try files.createDirectory(at: dll(library).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try files.createSymbolicLink(
            atPath: dll(ours).path(percentEncoded: false),
            withDestinationPath: layout.legacyCompat.appending(path: "Steam.dll").path(percentEncoded: false))
        let elsewhere = layout.root.appending(path: "elsewhere/Steam.dll")
        try files.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("other".utf8).write(to: elsewhere)
        try files.createSymbolicLink(
            atPath: dll(foreign).path(percentEncoded: false),
            withDestinationPath: elsewhere.path(percentEncoded: false))
        try Data("real".utf8).write(to: dll(real))

        let outcome = try await Uninstall.run(
            app: layout.app, innerPlist: layout.innerPlist, updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat, compatTools: layout.compatTools,
            directories: [layout.support, layout.caches], libraries: [ours, foreign, real, empty],
            modifications: layout.modifications, lockFolder: layout.root, leftovers: layout.leftovers,
            repair: { _, _ in }, stop: { _, _ in false })

        #expect((try? files.destinationOfSymbolicLink(atPath: dll(ours).path(percentEncoded: false))) == nil)
        #expect(outcome.removed.filter { $0 == "Steam.dll" }.count == 1)
        #expect(
            try files.destinationOfSymbolicLink(atPath: dll(foreign).path(percentEncoded: false))
                == elsewhere.path(percentEncoded: false))
        #expect(try String(contentsOf: dll(real), encoding: .utf8) == "real")
        #expect(!files.fileExists(atPath: empty.root.path(percentEncoded: false)))
    }

    private func remove(_ layout: Layout, app: URL? = nil,
                         leftovers: Uninstall.Leftovers? = nil,
                         repair: @escaping Uninstall.Repair = { _, _ in },
                         stop: Uninstall.Stop = { _, _ in false }) async throws -> UninstallOutcome {
        try await Uninstall.run(
            app: app ?? layout.app, innerPlist: layout.innerPlist, updateBlocks: [layout.updateBlock],
            legacyCompat: layout.legacyCompat, compatTools: layout.compatTools,
            directories: [layout.support, layout.caches], libraries: [],
            modifications: layout.modifications, lockFolder: layout.root, leftovers: leftovers ?? layout.leftovers,
            repair: repair, stop: stop)
    }

    @Test("A running game stops the removal before Steam is touched")
    func refusesWhileAGameRuns() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        var leftovers = layout.leftovers
        leftovers.runningBuild = { "27.0.0" }
        let stops = Flag()

        let failure = try await #require(throws: StepFailure.self) {
            try await remove(layout, leftovers: leftovers, stop: { _, _ in stops.set(); return false })
        }

        #expect(failure.detail.contains("27.0.0"))
        #expect(!stops.value)
        #expect(FileManager.default.fileExists(atPath: layout.support.path))
        #expect(try SteamModifications.inspect(layout.app) == .modified)
    }

    @Test("--remove-everything fails while a game runs")
    func commandRefusesWhileAGameRuns() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        var leftovers = layout.leftovers
        leftovers.runningBuild = { "27.0.0" }
        let captured = leftovers

        let exitCode = await RemoveEverythingCommand.perform { _ in try await remove(layout, leftovers: captured) }

        #expect(exitCode == 1)
        #expect(FileManager.default.fileExists(atPath: layout.support.path))
    }

    @Test("Removal cleans both tracked copies when the first drive returns")
    func removesReturnedSteamAsWellAsSelectedSteam() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let drive = layout.root.appending(path: "external")
        let first = drive.appending(path: "Steam.app")
        let parked = layout.root.appending(path: "disconnected")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: layout.app, to: first)
        try layout.modifications.mark(first)
        try FileManager.default.moveItem(at: drive, to: parked)
        try layout.modifications.mark(layout.app)
        try FileManager.default.moveItem(at: parked, to: drive)
        let stoppedFirst = Flag()
        let stoppedSecond = Flag()
        let otherAccount = layout.root.appending(path: "other-account")
        try FileManager.default.createDirectory(at: otherAccount, withIntermediateDirectories: true)

        let outcome = try await remove(layout, stop: { target, _ in
            if target.path == first.standardizedFileURL.path { stoppedFirst.set() }
            if target.path == layout.app.standardizedFileURL.path { stoppedSecond.set() }
            #expect(throws: StepFailure.self) {
                let lock = try DeploymentContent.acquireInstallationLock(
                    in: otherAccount, steamFolder: target.deletingLastPathComponent())
                lock.release()
            }
            return false
        })

        #expect(stoppedFirst.value && stoppedSecond.value)
        #expect(outcome.partialRemoval == nil)
        #expect(try SteamModifications.inspect(first) == .clean)
        #expect(try SteamModifications.inspect(layout.app) == .clean)
        #expect(try layout.modifications.paths().isEmpty)
    }

    @Test("Partial removal stays incomplete on CLI retries after support data is deleted")
    func partialRemovalSurvivesRetries() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let first = layout.root.appending(path: "missing-a/Steam.app")
        let second = layout.root.appending(path: "missing-b/Steam.app")
        let parkedFirst = layout.root.appending(path: "disconnected-a")
        let parkedSecond = layout.root.appending(path: "disconnected-b")
        for (app, parked) in [(first, parkedFirst), (second, parkedSecond)] {
            try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: layout.app, to: app)
            try FileManager.default.moveItem(at: app.deletingLastPathComponent(), to: parked)
        }
        try layout.modifications.mark(first)
        try layout.modifications.mark(second)
        try layout.modifications.mark(layout.app)

        for _ in 0..<2 {
            let exitCode = await RemoveEverythingCommand.perform { _ in
                let result = try await remove(layout)
                #expect(Set(result.unreachableSteam) == Set([first, second]))
                #expect(result.partialRemoval?.contains(first.path) == true)
                #expect(result.partialRemoval?.contains(second.path) == true)
                return result
            }
            #expect(exitCode == 1)
            #expect(Set(try layout.modifications.paths()) == Set([first, second]))
            #expect(!FileManager.default.fileExists(atPath: layout.support.path))
        }
        let confirmation = Uninstall.confirmation(modifications: layout.modifications)
        #expect(confirmation.contains(first.path) && confirmation.contains(second.path))

        try FileManager.default.moveItem(at: parkedFirst, to: first.deletingLastPathComponent())
        try FileManager.default.moveItem(at: parkedSecond, to: second.deletingLastPathComponent())
        let exitCode = await RemoveEverythingCommand.perform { _ in try await remove(layout) }

        #expect(exitCode == 0)
        #expect(try layout.modifications.paths().isEmpty)
        #expect(try SteamModifications.inspect(first) == .clean)
        #expect(try SteamModifications.inspect(second) == .clean)
    }

    @Test("A conservatively recorded clean bundle is retired without repair")
    func resolvesAnUnpatchedAttempt() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        _ = try Uninstall.detach(from: layout.app, innerPlist: layout.innerPlist, updateBlocks: [])
        try layout.modifications.mark(layout.app)

        let result = try await remove(layout)

        #expect(result.partialRemoval == nil)
        #expect(!result.steamNeedsRedownload)
        #expect(try layout.modifications.paths().isEmpty)
    }

    @Test("Interrupted detachment stays tracked until Steam's signature is repaired")
    func recoversInterruptedDetachment() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try layout.modifications.mark(layout.app)
        _ = try SteamRepair.clearInsert(at: layout.outerPlist)
        try FileManager.default.removeItem(at: layout.dylib)
        #expect(try !verifies(layout.app))
        let attempted = Flag()
        struct Offline: Error {}

        let failed = await RemoveEverythingCommand.perform { _ in
            try await remove(layout, repair: { _, _ in
                attempted.set()
                throw Offline()
            })
        }

        #expect(failed == 1)
        #expect(attempted.value)
        #expect(try layout.modifications.paths().map(\.path) == [layout.app.standardizedFileURL.path])
        #expect(FileManager.default.fileExists(atPath: layout.support.path))

        let recovered = await RemoveEverythingCommand.perform { _ in
            try await remove(layout, repair: { app, _ in try SteamInstaller.adHocSign(app) })
        }

        #expect(recovered == 0)
        #expect(try verifies(layout.app))
        #expect(try layout.modifications.paths().isEmpty)
    }

    @Test("A refused bundle lock preserves that target for a later removal")
    func preservesLockedTarget() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let drive = layout.root.appending(path: "external")
        let app = drive.appending(path: "Steam.app")
        let otherAccount = layout.root.appending(path: "other-account")
        for folder in [drive, otherAccount] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: layout.app, to: app)
        try layout.modifications.mark(app)
        let lock = try DeploymentContent.acquireInstallationLock(in: otherAccount, steamFolder: drive)
        do {
            defer { lock.release() }
            await #expect(throws: StepFailure.self) { try await remove(layout) }
            #expect(try layout.modifications.paths().map(\.path) == [app.standardizedFileURL.path])
            #expect(try SteamModifications.inspect(app) == .modified)
        }

        let result = try await remove(layout)
        #expect(result.partialRemoval == nil)
        #expect(try layout.modifications.paths().isEmpty)
    }

    @Test("Unreadable bundle metadata never clears an outstanding target")
    func preservesUninspectableTarget() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try layout.modifications.mark(layout.app)
        try Data("not a plist".utf8).write(to: layout.outerPlist)

        await #expect(throws: StepFailure.self) { try await remove(layout) }

        #expect(try layout.modifications.paths().map(\.path) == [layout.app.standardizedFileURL.path])
    }

    @Test("A corrupt path record blocks removal without deleting it")
    func preservesCorruptRecord() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try Data("corrupt".utf8).write(to: layout.modifications.file)

        let exitCode = await RemoveEverythingCommand.perform { _ in try await remove(layout) }

        #expect(exitCode == 1)
        #expect(try String(contentsOf: layout.modifications.file, encoding: .utf8) == "corrupt")
        #expect(FileManager.default.fileExists(atPath: layout.support.path))
        #expect(try SteamModifications.inspect(layout.app) == .modified)
    }

    @Test("Uninstall reports template cleanup refusal rather than claiming completion")
    func reportsTemplateCleanupFailure() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let library = SteamLibrary(root: layout.root.appending(path: "library"))
        try FileManager.default.createDirectory(at: library.compatdata, withIntermediateDirectories: true)
        let outside = layout.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appending(path: "crossover-26.3.0.39832-x86_64-unix")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: library.compatdata.appending(path: SupportPaths.prefixTemplateFolder), withDestinationURL: outside)

        await #expect(throws: StepFailure.self) {
            _ = try await Uninstall.run(
                app: layout.app, innerPlist: layout.innerPlist, updateBlocks: [layout.updateBlock],
                legacyCompat: layout.legacyCompat, compatTools: layout.compatTools,
                directories: [layout.support, layout.caches], libraries: [library],
                modifications: layout.modifications, lockFolder: layout.root, leftovers: layout.leftovers,
                repair: { _, _ in }, stop: { _, _ in false })
        }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
    }

    // MARK: What lives outside the removed folders

    private static let config = """
        "InstallConfigStore"
        {
        \t"Software"
        \t{
        \t\t"Valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        \t\t\t\t"CompatToolMapping"
        \t\t\t\t{
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t}
        }
        """

    @Test("The user's own game fixes are moved aside, never deleted")
    func keepsTheUsersGamefixes() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let fix = layout.support.appending(path: "gamefixes/3764200.conf")
        try FileManager.default.createDirectory(at: fix.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("BACKEND=wined3d\n".utf8).write(to: fix)
        // A copy kept by an earlier removal stays as it is.
        try FileManager.default.createDirectory(at: layout.keptGamefixes, withIntermediateDirectories: true)

        let outcome = try await remove(layout)

        let kept = try #require(outcome.keptGamefixes)
        #expect(kept != layout.keptGamefixes)
        #expect(try String(contentsOf: kept.appending(path: "3764200.conf"), encoding: .utf8) == "BACKEND=wined3d\n")
        #expect(outcome.keptGamefixesNote?.contains(kept.path(percentEncoded: false)) == true)
        #expect(!FileManager.default.fileExists(atPath: layout.support.path))
    }

    @Test("Without game fixes of the user's own, nothing is kept")
    func keepsNothingWithoutGamefixes() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try FileManager.default.createDirectory(at: layout.support.appending(path: "gamefixes"), withIntermediateDirectories: true)

        let outcome = try await remove(layout)
        #expect(outcome.keptGamefixes == nil)
        #expect(!FileManager.default.fileExists(atPath: layout.keptGamefixes.path))
    }

    // Steam was left defaulting to a tool the removal had just deleted.
    @Test("Steam's default tool is put back to what the user had")
    func restoresSteamsDefaultTool() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let original = Self.config.replacingOccurrences(
            of: "\t\t\t\t{\n\t\t\t\t}",
            with: "\t\t\t\t{\n\t\t\t\t\t\"0\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"name\"\t\t\"GE-Proton9-1\"\n\t\t\t\t\t\t\"config\"\t\t\"\"\n\t\t\t\t\t\t\"priority\"\t\t\"250\"\n\t\t\t\t\t}\n\t\t\t\t}")
        try Data(original.utf8).write(to: layout.steamConfig)
        let leftovers = layout.leftovers
        try SteamDefaultTool.set("bridgeplay-proton-winecx-11.17", in: leftovers.steamConfig,
                                 backup: leftovers.defaultToolBackup, steamRunning: { false })

        let outcome = try await remove(layout)

        #expect(outcome.restoredDefaultTool)
        #expect(try String(contentsOf: layout.steamConfig, encoding: .utf8) == original)
    }

    @Test("~/.bridgeplay and the record of modified Steam bundles go too")
    func removesTheOtherLeftovers() async throws {
        let layout = try layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try FileManager.default.createDirectory(at: layout.homeDir, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: layout.homeDir.appending(path: "np-native"))
        try layout.modifications.prepare()
        #expect(FileManager.default.fileExists(atPath: layout.modifications.file.path))

        let outcome = try await remove(layout)

        #expect(!FileManager.default.fileExists(atPath: layout.homeDir.path))
        #expect(!FileManager.default.fileExists(atPath: layout.modifications.file.path))
        #expect(outcome.removed.contains(".bridgeplay"))
    }
}
