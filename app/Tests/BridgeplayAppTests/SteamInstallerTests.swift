import Foundation
import Testing

@testable import BridgeplayApp

// Run against a real pinned Valve bundle staged into scratch, not /Applications/Steam.app.
// The chain seals a dylib inside a bundle inside another signature. Serialized, one cache.
@Suite("Steam installer", .serialized)
struct SteamInstallerTests {

    private func stockBundle(into work: URL) async throws -> URL {
        let manifest = try ValvePackageManifest.bundled()
        let bundle = try #require(manifest.bundle)
        return try await SteamRepair.stage(
            bundle,
            bases: manifest.bases,
            downloads: try isolatedValveDownloads(in: work),
            work: work.appending(path: "staging")
        )
    }

    // A stand-in payload rather than the shipped one, so the tests do not depend on make
    // having been run. The dylib has to be a real Mach-O because it gets signed.
    private func payload(in work: URL) throws -> InstallPayload.Located {
        let root = work.appending(path: "payload")
        let signatureDir = root.appending(path: "signatures/macos.arm64")
        try FileManager.default.createDirectory(at: signatureDir, withIntermediateDirectories: true)

        let source = work.appending(path: "probe.c")
        try Data("int np_probe(void) { return 1; }\n".utf8).write(to: source)

        let dylib = root.appending(path: SupportPaths.dylibName)
        try Shell.check("/usr/bin/clang", [
            "-dynamiclib", "-o", dylib.path(percentEncoded: false), source.path(percentEncoded: false),
        ])

        let shim = root.appending(path: "overlay-shim.dylib")
        try FileManager.default.copyItem(at: dylib, to: shim)

        let iconmaker = root.appending(path: "iconmaker")
        try FileManager.default.copyItem(at: dylib, to: iconmaker)

        let appinfo = root.appending(path: "appinfo")
        try FileManager.default.copyItem(at: dylib, to: appinfo)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: root.appending(path: "run"))
        try Data("100\n".utf8).write(to: root.appending(path: "build-time"))

        try Data("{}".utf8).write(to: signatureDir.appending(path: "1788400362.json"))
        try Data("{}".utf8).write(to: signatureDir.appending(path: "1788652215.json"))
        let altFonts = root.appending(path: "fonts/alt")
        try FileManager.default.createDirectory(at: altFonts, withIntermediateDirectories: true)
        try Data("arial".utf8).write(to: root.appending(path: "fonts/arial.ttf"))
        try Data("alt arial".utf8).write(to: altFonts.appending(path: "arial.ttf"))

        return try InstallPayload.locate(root: root)
    }

    private struct Fixture {
        let work: URL
        let app: URL
        let payload: InstallPayload.Located
        let support: URL

        var plist: URL { app.appending(path: "Contents/Info.plist") }
        var deployedDylib: URL { app.appending(path: "Contents/MacOS/\(SupportPaths.dylibName)") }
        var signatures: URL { support.appending(path: "signatures/macos.arm64") }
        var fonts: URL { support.appending(path: "fonts") }
        var overlayShim: URL { support.appending(path: "overlay-shim.dylib") }
        var iconmaker: URL { support.appending(path: "iconmaker") }
        var appinfo: URL { support.appending(path: "appinfo") }
        var deployedVersion: URL { support.appending(path: "dylib.version") }
        var backups: URL { support.appending(path: "backups") }
        var bridge: URL { support.appending(path: "bridge") }
        var modifications: SteamModifications {
            SteamModifications(file: work.appending(path: "steam-bundles.json"),
                               legacyRecord: DeploymentContent.record(beside: deployedVersion))
        }
    }

    private func fixture(into work: URL) async throws -> Fixture {
        Fixture(
            work: work,
            app: try await stockBundle(into: work),
            payload: try payload(in: work),
            support: work.appending(path: "support")
        )
    }

    // The registrar and stopper a test uses: record the call, do nothing.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var registered: [URL] = []
        func register(_ url: URL) { lock.lock(); registered.append(url); lock.unlock() }
        var registrations: [URL] { lock.lock(); defer { lock.unlock() }; return registered }
        private var resets = 0
        func resetInputAccess() { lock.lock(); resets += 1; lock.unlock() }
        var inputAccessResets: Int { lock.lock(); defer { lock.unlock() }; return resets }
        private var stopRequests = 0
        func stop() { lock.lock(); stopRequests += 1; lock.unlock() }
        var stops: Int { lock.lock(); defer { lock.unlock() }; return stopRequests }
        private var runnerLooks = 0
        // Which look at the runners this is, from 1.
        func lookAtRunners() -> Int { lock.lock(); defer { lock.unlock() }; runnerLooks += 1; return runnerLooks }
    }

    private func install(
        _ fixture: Fixture,
        version: String = "9.9.9-test",
        calls: Calls = Calls(),
        stopped: Bool = false,
        running: Bool = false,
        recordBuild: Bool = true,
        refusedResets: [String] = [],
        runnerIsRunning: (@Sendable (URL) -> Bool)? = nil,
        launchingBuild: (URL) -> String? = { _ in nil },
        stopClient: SteamInstaller.ClientStopper? = nil,
        verifyRunner: (RunnerBuild, URL) throws -> Void = { _, _ in },
        register: SteamInstaller.BundleRegistrar? = nil,
        onInputReset: ([String]) -> Void = { _ in }
    ) throws -> InstallOutcome {
        let outcome = try SteamInstaller.run(
            payload: fixture.payload,
            version: version,
            app: fixture.app,
            bridge: fixture.bridge,
            signatures: fixture.signatures,
            fonts: fixture.fonts,
            overlayShim: fixture.overlayShim,
            iconmaker: fixture.iconmaker,
            appinfo: fixture.appinfo,
            deployedVersion: fixture.deployedVersion,
            backups: fixture.backups,
            compatTools: fixture.work.appending(path: "compatibilitytools.d"),
            lockFolder: fixture.work,
            modifications: fixture.modifications,
            runnerIsRunning: runnerIsRunning ?? { _ in running },
            launchingBuild: launchingBuild,
            verifyRunner: verifyRunner,
            patchRunner: { _, _, _ in },
            stopClient: stopClient ?? { _, onStopping in
                calls.stop()
                if stopped { onStopping() }
                return stopped
            },
            register: register ?? { calls.register($0) },
            resetInputAccess: { calls.resetInputAccess(); return refusedResets },
            onInputReset: onInputReset
        )
        if recordBuild {
            try SteamInstaller.finish(outcome, deployedVersion: fixture.deployedVersion, isCurrent: { _ in true })
        }
        return outcome
    }

    @Test("A full install puts every artifact in place and declares the insert")
    func installsEverything() async throws {
        let work = try scratchDirectory("install")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let calls = Calls()

        let outcome = try install(fixture, calls: calls)

        #expect(outcome.version == "9.9.9-test")
        #expect(outcome.signatureDatabases == 2)
        #expect(outcome.backedUpPlist)
        #expect(!outcome.stoppedClient)
        #expect(calls.inputAccessResets == 1)
        #expect(outcome.failedInputResets == [])

        let files = FileManager.default
        #expect(files.fileExists(atPath: fixture.deployedDylib.path(percentEncoded: false)))
        #expect(files.fileExists(atPath: fixture.overlayShim.path(percentEncoded: false)))
        #expect(files.fileExists(atPath: fixture.iconmaker.path(percentEncoded: false)))
        #expect(files.fileExists(atPath: fixture.appinfo.path(percentEncoded: false)))
        #expect(
            try String(contentsOf: fixture.deployedVersion, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "9.9.9-test"
        )

        // Both databases, and the arch component preserved: the dylib builds that path
        // itself, so a database one level up resolves nothing.
        let installed = try files.contentsOfDirectory(atPath: fixture.signatures.path(percentEncoded: false))
        #expect(installed.sorted() == ["1788400362.json", "1788652215.json"])

        #expect(
            SteamBundle.currentInsert(at: fixture.plist)
                == fixture.deployedDylib.path(percentEncoded: false)
        )
        #expect(calls.registrations == [fixture.app], "the bundle was not re-registered")
    }

    @Test("A reset stays known when the install fails after it")
    func reportsInputResetBeforeALaterFailure() async throws {
        let work = try scratchDirectory("install-reset-then-fail")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let calls = Calls()
        let plist = fixture.app.appending(path: "Contents/Info.plist")
        var told: [String]?

        // Another writer changing the insert trips the check after registering.
        let failure = try #require(throws: StepFailure.self) {
            try install(fixture, calls: calls, refusedResets: ["ListenEvent"], register: { _ in
                guard var dict = SteamBundle.readInfoPlist(at: plist),
                      var env = dict[SteamBundle.environmentKey] as? [String: Any] else { return }
                env[SteamBundle.insertKey] = "/elsewhere.dylib"
                dict[SteamBundle.environmentKey] = env
                try? SteamBundle.writeInfoPlist(dict, at: plist)
            }, onInputReset: { told = $0 })
        }

        #expect(failure.detail.contains("different dylib"))
        #expect(calls.inputAccessResets == 1)
        #expect(told == ["ListenEvent"])
    }

    @Test("Only an install that reset input access reports on it")
    func reportsInputResetsOnlyWhenTheyRan() async throws {
        let work = try scratchDirectory("install-input-resets")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let calls = Calls()

        #expect(try install(fixture, calls: calls, refusedResets: ["ListenEvent"]).failedInputResets == ["ListenEvent"])
        #expect(try install(fixture, calls: calls).failedInputResets == nil)
        #expect(calls.inputAccessResets == 1)
    }

    @Test("A Steam that won't stop is left as it was, and the failure is the stopper's")
    func stopFailureLeavesSteamAlone() async throws {
        let work = try scratchDirectory("install-stop-failure")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let plist = try Data(contentsOf: fixture.plist)

        #expect(throws: SteamInstaller.ClientStarted.self) {
            try install(fixture, stopClient: { _, _ in throw SteamInstaller.ClientStarted() })
        }
        let refusal = try #require(throws: StepFailure.self) {
            try install(fixture, stopClient: { _, _ in
                throw StepFailure(step: "Test", detail: "Steam did not quit.")
            })
        }

        #expect(refusal.detail == "Steam did not quit.")
        #expect(try Data(contentsOf: fixture.plist) == plist)
        for untouched in [fixture.deployedDylib, fixture.bridge, fixture.deployedVersion, fixture.overlayShim] {
            #expect(!FileManager.default.fileExists(atPath: untouched.path(percentEncoded: false)))
        }
    }

    @Test("Steam is stopped before anything in or beside it changes")
    func stopsBeforeWriting() async throws {
        let work = try scratchDirectory("install-stop-order")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let calls = Calls()
        let plist = fixture.plist, dylib = fixture.deployedDylib, bridge = fixture.bridge
        let original = try Data(contentsOf: plist)

        _ = try install(fixture, stopClient: { _, _ in
            calls.stop()
            #expect((try? Data(contentsOf: plist)) == original)
            #expect(!FileManager.default.fileExists(atPath: dylib.path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: bridge.path(percentEncoded: false)))
            return true
        })

        #expect(calls.stops == 1)
        #expect(FileManager.default.fileExists(atPath: dylib.path(percentEncoded: false)))
    }

    @Test("Setting the insert keeps the rest of Valve's environment")
    func preservesValveEnvironment() async throws {
        let work = try scratchDirectory("install")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)

        // What Valve actually ships, asserted before the install rather than assumed.
        let before = try #require(SteamBundle.readInfoPlist(at: fixture.plist))
        let stock = try #require(before[SteamBundle.environmentKey] as? [String: Any])
        #expect(stock["LC_ALL"] as? String == "en_US.UTF-8")

        _ = try install(fixture)

        let after = try #require(SteamBundle.readInfoPlist(at: fixture.plist))
        let environment = try #require(after[SteamBundle.environmentKey] as? [String: Any])
        #expect(environment["LC_ALL"] as? String == "en_US.UTF-8", "LC_ALL is Valve's and has to survive")
        #expect(environment[SteamBundle.controllerBlockKey] as? String == SteamBundle.controllerBlockValue)
        #expect(environment.count == 3, "only the insert and the controller block should have been added")
        #expect(after["CFBundleVersion"] as? String == "6.1", "the rest of the plist was disturbed")
    }

    @Test("The bundle is signed inner to outer, so every seal verifies afterwards")
    func signsInnerToOuter() async throws {
        let work = try scratchDirectory("install")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)

        _ = try install(fixture)

        // The outer seal covers the executable and the dylib is sealed in its own right, so
        // signing outer first would leave the bundle describing files that changed afterwards.
        for target in [fixture.deployedDylib, fixture.app.appending(path: "Contents/MacOS/steam_osx"), fixture.app] {
            let result = try Shell.run("/usr/bin/codesign", ["--verify", "--strict", target.path(percentEncoded: false)])
            #expect(result.succeeded, "\(target.lastPathComponent) does not verify: \(result.stderr)")
        }

        // Valve's authority is gone, which is the whole reason repair replaces the bundle
        // rather than editing it back.
        let described = try Shell.run("/usr/bin/codesign", ["-dvv", fixture.app.path(percentEncoded: false)])
        #expect(!(described.stdout + described.stderr).contains("TeamIdentifier=MXGJJ98X76"))
    }

    @Test("A Steam carrying Finder info or a resource fork still installs, and only those are cleared")
    func installsOverFinderData() async throws {
        let work = try scratchDirectory("install")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let app = fixture.app.path(percentEncoded: false)
        let icon = fixture.app.appending(path: "Icon\r").path(percentEncoded: false)
        try Data().write(to: URL(filePath: icon))
        try Shell.check("/usr/bin/xattr", ["-w", "com.apple.ResourceFork", "icns", icon])
        try Shell.check("/usr/bin/xattr", ["-wx", "com.apple.FinderInfo", String(repeating: "0", count: 64), icon])
        try Shell.check("/usr/bin/xattr", [
            "-wx", "com.apple.FinderInfo", "0000000000000000040000000000000000000000000000000000000000000000", app,
        ])
        try Shell.check("/usr/bin/xattr", ["-w", "com.bridgeplay.keep", "1", app])
        #expect(!(try Shell.run("/usr/bin/codesign", ["-f", "-s", "-", app])).succeeded)

        _ = try install(fixture)

        let verified = try Shell.run("/usr/bin/codesign", ["--verify", "--strict", app])
        #expect(verified.succeeded, "\(verified.stderr)")
        let left = try Shell.run("/usr/bin/xattr", ["-lr", app]).stdout
        #expect(!left.contains("com.apple.FinderInfo"))
        #expect(!left.contains("com.apple.ResourceFork"))
        #expect(left.contains("com.bridgeplay.keep"))
    }

    @Test("An insert belonging to something else stops the install and is left alone")
    func refusesForeignInsert() async throws {
        let work = try scratchDirectory("install")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)

        let foreign = "/Applications/Steam.app/Contents/MacOS/somethingelse.dylib"
        try SteamInstaller.setInsert(at: fixture.plist, to: URL(filePath: foreign))

        do {
            _ = try install(fixture)
            Issue.record("an install over a foreign insert was allowed")
        } catch let failure as SteamInstaller.ForeignInsert {
            #expect(failure.tool == "somethingelse.dylib")
            #expect(failure.localizedDescription.contains("somethingelse.dylib is already set up in Steam"))
        }

        #expect(SteamBundle.currentInsert(at: fixture.plist) == foreign, "the foreign insert was modified")
        #expect(
            !FileManager.default.fileExists(atPath: fixture.deployedDylib.path(percentEncoded: false)),
            "the dylib was copied in despite the refusal"
        )
    }

    @Test("Installing over an existing install is allowed and refreshes it")
    func reinstallIsAllowed() async throws {
        let work = try scratchDirectory("install")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)

        _ = try install(fixture, version: "1.0.0")
        let second = try install(fixture, version: "2.0.0")

        #expect(second.version == "2.0.0")
        #expect(
            try String(contentsOf: fixture.deployedVersion, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "2.0.0"
        )
        // Taken by the first install, and not retaken: a backup of what Bridgeplay itself
        // left behind is not a backup of the original.
        #expect(second.backedUpPlist == false)
    }

    @Test("A failure while signing puts the plist back, so the bundle still starts")
    func revertsInsertWhenSigningFails() async throws {
        let work = try scratchDirectory("install")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)

        let before = try Data(contentsOf: fixture.plist)

        // Signing walks inner to outer with the client executable second, so removing it fails
        // between the insert and the signature. That window left a Steam its own seal misses.
        try FileManager.default.removeItem(at: fixture.app.appending(path: "Contents/MacOS/steam_osx"))

        let failure = try #require(throws: StepFailure.self) { try install(fixture) }

        // Asserting where the failure came from, because a test that stopped earlier
        // than the signing step would pass on a plist that was never touched.
        #expect(
            failure.detail.contains("could not be signed"),
            "the install failed before the window this test is about: \(failure.detail)"
        )
        #expect(
            try Data(contentsOf: fixture.plist) == before,
            "the plist kept the insert, so the executable no longer matches its signature"
        )
        #expect(SteamBundle.currentInsert(at: fixture.plist) == nil)
        #expect(!FileManager.default.fileExists(atPath: DeploymentContent.record(beside: fixture.deployedVersion).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.deployedVersion.path))
    }

    // Both halves used to be try?, so a Steam left with the insert reported nothing.
    @Test("Putting the plist back reports a write it could not make")
    func revertReportsItsOwnFailure() throws {
        let work = try scratchDirectory("install")
        defer { try? FileManager.default.removeItem(at: work) }
        let missing = work.appending(path: "gone/Steam.app")

        #expect(throws: (any Error).self) {
            try SteamInstaller.revertPlist(Data("plist".utf8), at: missing.appending(path: "Contents/Info.plist"), app: missing)
        }
        #expect(throws: Never.self) {
            try SteamInstaller.revertPlist(nil, at: missing.appending(path: "Contents/Info.plist"), app: missing)
        }
    }

    @Test("The plist backup records the state before the first install only")
    func backsUpOriginalPlistOnce() async throws {
        let work = try scratchDirectory("install")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)

        _ = try install(fixture)

        let backup = fixture.backups.appending(path: "Info.plist.before-bridgeplay")
        let saved = try #require(SteamBundle.readInfoPlist(at: backup))
        let environment = try #require(saved[SteamBundle.environmentKey] as? [String: Any])
        #expect(environment[SteamBundle.insertKey] == nil, "the backup already carries an insert")
        #expect(environment["LC_ALL"] as? String == "en_US.UTF-8")
    }

    @Test("A missing Steam bundle is reported as its own condition")
    func reportsMissingBundle() async throws {
        let work = try scratchDirectory("install")
        defer { try? FileManager.default.removeItem(at: work) }
        var fixture = try await self.fixture(into: work)
        fixture = Fixture(
            work: work,
            app: work.appending(path: "nothing-here/Steam.app"),
            payload: fixture.payload,
            support: fixture.support
        )

        do {
            _ = try install(fixture)
            Issue.record("an install into a bundle that is not there was allowed")
        } catch let failure as StepFailure {
            #expect(failure.detail.contains("is not there"))
        }
    }

    // Straight at the probe, so neither of these needs a Valve bundle to be fetched first.
    private func bundle(writable: Bool) throws -> URL {
        let app = try scratchDirectory("install").appending(path: "Steam.app")
        try FileManager.default.createDirectory(
            at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true
        )
        if !writable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: app.appending(path: "Contents/MacOS").path(percentEncoded: false)
            )
        }
        return app
    }

    @Test("A bundle that refuses the probe is reported as a refused write")
    func probeRefusalIsARefusal() throws {
        let app = try bundle(writable: false)
        let inside = app.appending(path: "Contents/MacOS").path(percentEncoded: false)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inside)
            try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
        }

        let refusal = try #require(throws: WriteRefused.self) {
            try SteamInstaller.assertBundleIsWritable(app)
        }

        #expect(refusal.path == inside)
    }

    // The probe used to call every failure a refused write, so anything that stopped it sent
    // the user to grant a permission that had nothing to do with it.
    @Test("A probe that fails for another reason keeps that reason")
    func probeFailureKeepsItsOwnReason() throws {
        let app = try scratchDirectory("install").appending(path: "Steam.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let failure = try #require(throws: StepFailure.self) {
            try SteamInstaller.assertBundleIsWritable(app)
        }

        #expect(failure.detail.contains("could not be written"))
        #expect(
            failure.detail.contains("App Management") == false,
            "a bundle that is not there was reported as a permission to grant"
        )
    }

    @Test("A bundle that takes the probe is left exactly as it was")
    func probeLeavesNothingBehind() throws {
        let app = try bundle(writable: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        try SteamInstaller.assertBundleIsWritable(app)

        let left = try FileManager.default.contentsOfDirectory(
            atPath: app.appending(path: "Contents/MacOS").path(percentEncoded: false)
        )
        #expect(left.isEmpty, "the probe file was left in the bundle")
    }

    @Test("A second account installs its own components without touching a patched Steam")
    func secondAccountLeavesTheBundleAlone() async throws {
        let work = try scratchDirectory("install")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let files = FileManager.default

        _ = try install(fixture)

        let pinned = Date(timeIntervalSince1970: 1_000_000)
        try files.setAttributes(
            [.modificationDate: pinned],
            ofItemAtPath: fixture.deployedDylib.path(percentEncoded: false)
        )
        try files.removeItem(at: fixture.support)

        let calls = Calls()
        let outcome = try install(fixture, calls: calls, stopped: true)

        #expect(!outcome.stoppedClient, "Steam was stopped for an install that changed nothing")
        #expect(calls.inputAccessResets == 0)
        #expect(!outcome.backedUpPlist)
        #expect(outcome.signatureDatabases == 2)

        let untouched = try files.attributesOfItem(
            atPath: fixture.deployedDylib.path(percentEncoded: false)
        )[.modificationDate] as? Date
        #expect(untouched == pinned, "the deployed dylib was rewritten")

        #expect(files.fileExists(atPath: fixture.overlayShim.path(percentEncoded: false)))
        #expect(files.fileExists(atPath: fixture.iconmaker.path(percentEncoded: false)))
        #expect(files.fileExists(atPath: fixture.appinfo.path(percentEncoded: false)))
        #expect(
            try files.contentsOfDirectory(atPath: fixture.signatures.path(percentEncoded: false))
                .sorted() == ["1788400362.json", "1788652215.json"]
        )
        #expect(
            try String(contentsOf: fixture.deployedVersion, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "9.9.9-test"
        )
    }

    @Test("A Steam carrying a different build of the dylib is patched again")
    func differentBuildIsPatched() async throws {
        let work = try scratchDirectory("install")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)

        _ = try install(fixture)
        #expect(
            try !SteamInstaller.needsPatching(
                plist: fixture.plist,
                dylib: fixture.deployedDylib,
                shipping: fixture.payload.dylib,
                app: fixture.app
            )
        )

        try Data("a different build".utf8).write(to: fixture.deployedDylib)

        #expect(
            try SteamInstaller.needsPatching(
                plist: fixture.plist,
                dylib: fixture.deployedDylib,
                shipping: fixture.payload.dylib,
                app: fixture.app
            )
        )
    }

    @Test("The installer records the package build time rather than the installation time")
    func recordsPackageBuild() async throws {
        let work = try scratchDirectory("install-record")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        _ = try install(fixture)
        let build = try #require(try DeploymentContent.readBuild(at: DeploymentContent.record(beside: fixture.deployedVersion)))
        #expect(build.builtAt == 100)
        #expect(build.version == "9.9.9-test")
        #expect(build.dylibHashes == (try MachOBuild.hashesIgnoringSignature(of: fixture.payload.dylib)))
        #expect(try fixture.modifications.paths().map(\.path) == [fixture.app.standardizedFileURL.path])
    }

    @Test("A failed install records the bundle before copying its dylib")
    func tracksFailedInstallation() async throws {
        let work = try scratchDirectory("install-failure-record")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        try FileManager.default.createDirectory(at: fixture.support, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: fixture.support.appending(path: "signatures"))

        #expect(throws: (any Error).self) { try install(fixture) }

        #expect(FileManager.default.fileExists(atPath: fixture.deployedDylib.path))
        #expect(try fixture.modifications.paths().map(\.path) == [fixture.app.standardizedFileURL.path])
        #expect(try DeploymentContent.readBuild(at: DeploymentContent.record(beside: fixture.deployedVersion)) == nil)
    }

    @Test("Installing another Steam preserves the disconnected installation")
    func tracksBothInstallations() async throws {
        let work = try scratchDirectory("install-two-bundles")
        defer { try? FileManager.default.removeItem(at: work) }
        let first = try await fixture(into: work)
        let other = work.appending(path: "other/Steam.app")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: first.app, to: other)
        let second = Fixture(work: work, app: other, payload: first.payload, support: first.support)
        _ = try install(first)
        try FileManager.default.moveItem(at: first.app.deletingLastPathComponent(), to: work.appending(path: "disconnected"))

        _ = try install(second)

        let recorded = Set(try first.modifications.paths().map(\.path))
        let expected = Set([first.app.standardizedFileURL.path, second.app.standardizedFileURL.path])
        #expect(recorded == expected)
    }

    @Test("An older package is refused before any installed files change")
    func refusesDowngrade() async throws {
        let work = try scratchDirectory("install-newer")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        _ = try install(fixture)
        let record = DeploymentContent.record(beside: fixture.deployedVersion)
        let newer = DeploymentContent.Build(version: "9.9.9-test", builtAt: 300)
        try JSONEncoder().encode(newer).write(to: record)
        let before = try Data(contentsOf: fixture.deployedDylib)
        let calls = Calls()

        let error = try #require(throws: StepFailure.self) { try install(fixture, calls: calls, stopped: true) }

        #expect(error.detail.contains("newer Bridgeplay"))
        #expect(try Data(contentsOf: fixture.deployedDylib) == before)
        #expect(try DeploymentContent.readBuild(at: record) == newer)
        #expect(calls.registrations.isEmpty)
    }

    @Test("Changed helpers are updated without replacing the matching dylib")
    func updatesHelperOnly() async throws {
        let work = try scratchDirectory("install-helper")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        _ = try install(fixture)
        let before = try Data(contentsOf: fixture.deployedDylib)
        let helper = try Data(contentsOf: fixture.payload.appinfo)
        try Data(repeating: 7, count: helper.count).write(to: fixture.appinfo)

        let result = try install(fixture, stopped: true)

        #expect(result.stoppedClient)
        #expect(!result.backedUpPlist)
        #expect(try Data(contentsOf: fixture.appinfo) == helper)
        #expect(try Data(contentsOf: fixture.deployedDylib) == before)
    }

    @Test("Repairing missing pinned components stops Steam even when bundled files already match")
    func pinnedRepairStopsSteam() async throws {
        let work = try scratchDirectory("install-pinned")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        _ = try install(fixture)
        #expect(try install(fixture, stopped: true).stoppedClient)
    }

    @Test("Install updates every deployed tool's script and runner bridge copy")
    func updatesScriptsAndRunnerCopies() async throws {
        let work = try scratchDirectory("install-scripts")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let runners = fixture.support.appending(path: "runners")
        let build = SupportedRunners.all[0]
        let runner = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        try FileManager.default.createDirectory(at: runner.appending(path: "lib/wine"), withIntermediateDirectories: true)

        _ = try install(fixture)

        let tools = CompatToolList.installed(runners: runners, file: fixture.support.appending(path: "tools"))
        try #require(!tools.isEmpty)
        for tool in tools {
            let script = work.appending(path: "compatibilitytools.d/\(tool.name)/run")
            #expect(try Data(contentsOf: script) == Data(contentsOf: fixture.payload.run))
            #expect(FileManager.default.isExecutableFile(atPath: script.path))
        }
        let bridge = try BridgePayload.locate()
        let files = DeploymentContent.files(payload: fixture.payload, bridgePayload: bridge, app: fixture.app,
                                            bridge: fixture.bridge, signatures: fixture.signatures,
                                            fonts: fixture.fonts, overlayShim: fixture.overlayShim, iconmaker: fixture.iconmaker,
                                            appinfo: fixture.appinfo, compatTools: work.appending(path: "compatibilitytools.d"),
                                            tools: tools, runners: runners)
        #expect(try files.allSatisfy { try $0.matches() })
    }

    @Test("Fonts a newer build no longer ships are removed")
    func removesStaleFonts() throws {
        let work = try scratchDirectory("install-stale-fonts")
        defer { try? FileManager.default.removeItem(at: work) }
        let fonts = work.appending(path: "fonts")
        try FileManager.default.createDirectory(at: fonts.appending(path: "alt"), withIntermediateDirectories: true)
        for name in ["arial.ttf", "old.ttf", "alt/arial.ttf", "alt/old.ttf"] {
            try Data("font".utf8).write(to: fonts.appending(path: name))
        }
        try SteamInstaller.removeStaleFonts(in: fonts, keeping: ["arial.ttf", "alt/arial.ttf"])
        let left = (FileManager.default.subpaths(atPath: fonts.path(percentEncoded: false)) ?? []).sorted()
        #expect(left == ["alt", "alt/arial.ttf", "arial.ttf"])
    }

    @Test("An install keeps the CJK fonts it doesn't ship and still drops stale ones")
    func keepsCJKFonts() async throws {
        let work = try scratchDirectory("install-cjk-fonts")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let seeded = ["msyh.ttf", "source-han-sans/LICENSE.txt", "old.ttf"]
        for name in seeded {
            let file = fixture.fonts.appending(path: name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("font".utf8).write(to: file)
        }

        _ = try install(fixture)

        let left = FileManager.default.subpaths(atPath: fixture.fonts.path(percentEncoded: false)) ?? []
        #expect(left.contains("msyh.ttf"))
        #expect(left.contains("source-han-sans/LICENSE.txt"))
        #expect(left.contains("arial.ttf"))
        #expect(!left.contains("old.ttf"))
    }

    @Test("A running game prevents file replacement before Steam is stopped")
    func refusesRunningRunner() async throws {
        let work = try scratchDirectory("install-running")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let runner = SupportPaths.clonedRoot(forBuild: SupportedRunners.all[0].id,
                                            runners: fixture.support.appending(path: "runners"))
        try FileManager.default.createDirectory(at: runner.appending(path: "lib/wine"), withIntermediateDirectories: true)
        let calls = Calls()

        let error = try #require(throws: StepFailure.self) { try install(fixture, calls: calls, running: true) }

        #expect(error.detail.contains("is running"))
        #expect(calls.stops == 0, "Steam was asked to quit under a running game")
        #expect(!FileManager.default.fileExists(atPath: fixture.bridge.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.deployedDylib.path))
    }

    @Test("A game started while Steam was stopping still blocks the install")
    func refusesRunnerStartedDuringStop() async throws {
        let work = try scratchDirectory("install-running-late")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let runner = SupportPaths.clonedRoot(forBuild: SupportedRunners.all[0].id,
                                            runners: fixture.support.appending(path: "runners"))
        try FileManager.default.createDirectory(at: runner.appending(path: "lib/wine"), withIntermediateDirectories: true)
        let calls = Calls()

        // One clone, so one look per pass: quiet before the stop, running after it.
        let error = try #require(throws: StepFailure.self) {
            try install(fixture, calls: calls, runnerIsRunning: { _ in calls.lookAtRunners() > 1 })
        }

        #expect(error.detail.contains("is running"))
        #expect(calls.stops == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.bridge.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.deployedDylib.path))
    }

    @Test("A game still launching, before Wine shows up, blocks installation before Steam is asked to quit")
    func refusesLaunchingGame() async throws {
        let work = try scratchDirectory("install-launching")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let calls = Calls()
        let tools = fixture.work.appending(path: "compatibilitytools.d")
        let error = try #require(throws: StepFailure.self) {
            try install(fixture, calls: calls, launchingBuild: { $0 == tools ? "winecx-11.17" : nil })
        }
        #expect(error.detail.contains("winecx-11.17"))
        #expect(calls.stops == 0, "Steam was asked to quit under a starting game")
        #expect(!FileManager.default.fileExists(atPath: fixture.deployedDylib.path))
    }

    @Test("Wine running from an unsupported clone also blocks installation")
    func refusesRunningOrphan() async throws {
        let work = try scratchDirectory("install-orphan")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let runner = SupportPaths.clonedRoot(forBuild: "99.0.0.12345", runners: fixture.support.appending(path: "runners"))
        try FileManager.default.createDirectory(at: runner.appending(path: "lib/wine"), withIntermediateDirectories: true)
        let calls = Calls()
        let error = try #require(throws: StepFailure.self) { try install(fixture, calls: calls, running: true) }
        #expect(error.detail.contains("99.0.0.12345"))
        #expect(calls.stops == 0, "Steam was asked to quit under a running game")
        #expect(!FileManager.default.fileExists(atPath: fixture.deployedDylib.path))
    }

    @Test("A recognized runner folder with invalid binaries is refused before deployment")
    func validatesExistingRunner() async throws {
        let work = try scratchDirectory("install-runner-validation")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let runners = fixture.support.appending(path: "runners")
        let build = SupportedRunners.all[0]
        let runner = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        try FileManager.default.createDirectory(at: runner.appending(path: "lib/wine/x86_64-unix"), withIntermediateDirectories: true)
        try Data("wrong loader".utf8).write(to: runner.appending(path: "lib/wine/x86_64-unix/wine"))
        let error = try #require(throws: StepFailure.self) {
            try install(fixture, verifyRunner: RunnerInstaller.verifyClone)
        }
        #expect(error.detail.contains("does not match"))
        #expect(!FileManager.default.fileExists(atPath: fixture.bridge.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.deployedDylib.path))
    }

    @Test("An install writes no build record until it is finished")
    func defersRecord() async throws {
        let work = try scratchDirectory("install-deferred")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        _ = try install(fixture, recordBuild: false)
        #expect(!FileManager.default.fileExists(atPath: DeploymentContent.record(beside: fixture.deployedVersion).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.deployedVersion.path))
    }

    @Test("Finishing records the build")
    func finishRecordsBuild() async throws {
        let work = try scratchDirectory("install-finish")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let outcome = try install(fixture, recordBuild: false)

        try SteamInstaller.finish(outcome, deployedVersion: fixture.deployedVersion, isCurrent: { _ in true })

        #expect(try DeploymentContent.readBuild(at: DeploymentContent.record(beside: fixture.deployedVersion)) == outcome.build)
        #expect(try String(contentsOf: fixture.deployedVersion, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "9.9.9-test")
    }

    @Test("Finishing records nothing when the installed content is not current")
    func finishRefusesUnverifiedContent() async throws {
        let work = try scratchDirectory("install-unverified")
        defer { try? FileManager.default.removeItem(at: work) }
        let fixture = try await self.fixture(into: work)
        let outcome = try install(fixture, recordBuild: false)

        #expect(throws: StepFailure.self) {
            try SteamInstaller.finish(outcome, deployedVersion: fixture.deployedVersion, isCurrent: { _ in false })
        }
        #expect(!FileManager.default.fileExists(atPath: DeploymentContent.record(beside: fixture.deployedVersion).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.deployedVersion.path))
    }

    @Test("An install seeds the controller mappings and leaves the user's own alone")
    func seedsControllerMappings() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let payload = dir.appending(path: "payload")
        let support = dir.appending(path: "support")
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        let mappings = support.appending(path: "gamecontrollerdb.txt")

        SteamInstaller.seedControllerMappings(from: payload, in: support)
        #expect(!fm.fileExists(atPath: mappings.path(percentEncoded: false)))

        try Data("shipped".utf8).write(to: payload.appending(path: "gamecontrollerdb.txt"))
        SteamInstaller.seedControllerMappings(from: payload, in: support)
        #expect(fm.contents(atPath: mappings.path(percentEncoded: false)) == Data("shipped".utf8))

        try Data("mine".utf8).write(to: mappings)
        SteamInstaller.seedControllerMappings(from: payload, in: support)
        #expect(fm.contents(atPath: mappings.path(percentEncoded: false)) == Data("mine".utf8))
    }

}
