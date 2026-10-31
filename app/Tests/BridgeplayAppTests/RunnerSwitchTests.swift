import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Preparing an installed build")
struct RunnerPrepareTests {

    private static let rosetta = SupportedRunners.all.first { $0.id == "27.0.0.40921" }!
    private static let fex = SupportedRunners.all.first { $0.flavor == "fex" }!
    private static let release = SupportedRunners.all.first { $0.id == "26.3.0.39832" }!
    private static let preview41069 = SupportedRunners.all.first { $0.id == "27.0.0.41069" }!
    private static let fex41069 = SupportedRunners.all.first { $0.id == "27.0.0.41069-fex" }!

    private static let licensed = CrossOverLicense.Status(
        licensed: true, detail: "CrossOver is activated.", diagnostic: "test"
    )
    private static let unlicensed = CrossOverLicense.Status(
        licensed: false, detail: CrossOverLicense.notActivated, diagnostic: "test"
    )

    private static let runScript = Data("#!/bin/sh\n".utf8)

    private final class Calls: @unchecked Sendable {
        var staged: [String] = []
        var patched: [String] = []
    }

    private func makeRunners(cloning builds: [RunnerBuild]) throws -> URL {
        let runners = FileManager.default.temporaryDirectory
            .appending(path: "np-prepare-\(UUID().uuidString)")
        for build in builds {
            try FileManager.default.createDirectory(
                at: SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
                    .appending(path: "lib/wine"),
                withIntermediateDirectories: true
            )
        }
        return runners
    }

    private static func writeStaged(for build: RunnerBuild, into bridge: URL) throws {
        for arch in build.patchedNtdll.keys {
            try atomicReplace(
                NtdllPatcher.stagedCopy(of: arch, build: build.id, in: bridge),
                with: Data("\(build.id) \(arch.rawValue)".utf8), step: "test"
            )
        }
    }

    private static func staged(_ build: RunnerBuild, in bridge: URL) -> [WineArch: Data] {
        var found: [WineArch: Data] = [:]
        for arch in WineArch.allCases {
            let copy = NtdllPatcher.stagedCopy(of: arch, build: build.id, in: bridge)
            if let data = try? Data(contentsOf: copy) { found[arch] = data }
        }
        return found
    }

    private func prepare(
        _ build: RunnerBuild,
        runners: URL,
        calls: Calls,
        license: CrossOverLicense.Status = licensed,
        failPatch: Bool = false
    ) throws -> RunnerSetup.Outcome {
        try RunnerSetup.prepare(
            build,
            runners: runners,
            bridge: runners.appending(path: "bridge"),
            toolList: runners.appending(path: "tools"),
            compatTools: runners.appending(path: "compatibilitytools.d"),
            runScript: {
                let script = runners.appending(path: "payload-run")
                try Self.runScript.write(to: script)
                return script
            },
            license: { _ in license },
            verify: { _, _ in },
            stage: { build, _, bridge in
                calls.staged.append(build.id)
                try Self.writeStaged(for: build, into: bridge)
                return []
            },
            patch: { build, _, _ in
                calls.patched.append(build.id)
                if failPatch { throw StepFailure(step: "test", detail: "patch failed") }
                return RunnerPatcher.Outcome()
            }
        )
    }

    private func toolList(_ runners: URL) -> String? {
        try? String(contentsOf: runners.appending(path: "tools"), encoding: .utf8)
    }

    @Test("Every set-up build is listed as its own tools")
    func listsEveryBuild() throws {
        let runners = try makeRunners(cloning: [Self.release, Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }

        let calls = Calls()
        let outcome = try prepare(Self.release, runners: runners, calls: calls)

        #expect(outcome.toolsChanged)
        #expect(calls.staged == [Self.release.id])
        #expect(calls.patched == [Self.release.id])
        #expect(toolList(runners) == CompatToolList.contents(
            SupportedRunners.tools(for: [Self.release, Self.fex])
        ))
        #expect(toolList(runners)?.hasPrefix("bridgeplay-proton-fex\t27.0.0.40921-fex\tfex\t") == true)

        let again = try prepare(Self.release, runners: runners, calls: calls)
        #expect(!again.toolsChanged)
    }

    @Test("Every listed tool gets a run script")
    func writesMissingRunScripts() throws {
        let runners = try makeRunners(cloning: [Self.release, Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }

        _ = try prepare(Self.release, runners: runners, calls: Calls())

        let tools = CompatToolList.installed(runners: runners, file: runners.appending(path: "tools"))
        #expect(tools.count > 1)
        for tool in tools {
            let run = runners.appending(path: "compatibilitytools.d/\(tool.name)/run")
            #expect(try Data(contentsOf: run) == Self.runScript)
            #expect(FileManager.default.isExecutableFile(atPath: run.path))
        }
    }

    @Test("A tool's existing run script is left alone")
    func keepsExistingRunScript() throws {
        let runners = try makeRunners(cloning: [Self.release])
        defer { try? FileManager.default.removeItem(at: runners) }
        let tool = SupportedRunners.tools(for: [Self.release])[0].name
        let run = runners.appending(path: "compatibilitytools.d/\(tool)/run")
        let old = Data("#!/bin/sh\nexec runners/current\n".utf8)
        try atomicReplace(run, with: old, step: "test")

        _ = try prepare(Self.release, runners: runners, calls: Calls())

        #expect(try Data(contentsOf: run) == old)
    }

    @Test("Preparing one build leaves another build's staged copies alone")
    func keepsOtherBuildsStaged() throws {
        let runners = try makeRunners(cloning: [Self.rosetta, Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }
        let bridge = runners.appending(path: "bridge")
        try Self.writeStaged(for: Self.rosetta, into: bridge)
        let before = Self.staged(Self.rosetta, in: bridge)

        _ = try prepare(Self.fex, runners: runners, calls: Calls())

        #expect(Self.staged(Self.rosetta, in: bridge) == before)
        #expect(Self.staged(Self.fex, in: bridge).count == Self.fex.patchedNtdll.count)
    }

    @Test("A failed patch leaves the tool list as it was")
    func failedPatchKeepsList() throws {
        let runners = try makeRunners(cloning: [Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }

        #expect(throws: StepFailure.self) {
            try prepare(Self.fex, runners: runners, calls: Calls(), failPatch: true)
        }
        #expect(toolList(runners) == nil)
    }

    @Test("Copies and links left by the single-build layout are cleared")
    func clearsLegacyLayout() throws {
        let runners = try makeRunners(cloning: [Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }
        let bridge = runners.appending(path: "bridge")
        let legacy = bridge.appending(path: "wine/x86_64-windows/ntdll.dll")
        let gone = NtdllPatcher.stagedCopy(of: .x86_64Windows, build: Self.rosetta.id, in: bridge)
        for file in [legacy, gone] {
            try atomicReplace(file, with: Data("old".utf8), step: "test")
        }
        try FileManager.default.createSymbolicLink(
            atPath: runners.appending(path: "current").path(percentEncoded: false),
            withDestinationPath: "crossover-\(Self.fex.id)/CrossOver"
        )

        _ = try prepare(Self.fex, runners: runners, calls: Calls())

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: legacy.deletingLastPathComponent().path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: gone.path(percentEncoded: false)))
        #expect((try? fm.destinationOfSymbolicLink(
            atPath: runners.appending(path: "current").path(percentEncoded: false))) == nil)
        #expect(Self.staged(Self.fex, in: bridge).count == Self.fex.patchedNtdll.count)
    }

    @Test("With nothing set up and no list yet, no list is written")
    func writesNoEmptyList() throws {
        let runners = try makeRunners(cloning: [])
        defer { try? FileManager.default.removeItem(at: runners) }
        let file = runners.appending(path: "support/tools")

        let changed = try CompatToolList.sync(
            runners: runners, bridge: runners.appending(path: "bridge"), file: file,
            compatTools: runners.appending(path: "compatibilitytools.d")
        )

        #expect(!changed)
        #expect(!FileManager.default.fileExists(
            atPath: file.deletingLastPathComponent().path(percentEncoded: false)))
    }

    @Test("A tool whose build is gone leaves Steam's compatibility tools; the others and foreign tools stay")
    func staleToolIsPruned() throws {
        let runners = try makeRunners(cloning: [Self.rosetta])
        defer { try? FileManager.default.removeItem(at: runners) }
        let fm = FileManager.default
        let compat = runners.appending(path: "compatibilitytools.d")
        for name in ["bridgeplay-proton-gone", "GE-Proton"] {
            try fm.createDirectory(at: compat.appending(path: name), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: compat.appending(path: "\(name)/run"))
        }

        try sync(runners)

        let kept = try #require(toolList(runners)).split(separator: "\n").compactMap { $0.split(separator: "\t").first }
        #expect(!kept.isEmpty)
        #expect(!fm.fileExists(atPath: compat.appending(path: "bridgeplay-proton-gone").path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: compat.appending(path: "GE-Proton").path(percentEncoded: false)))
    }

    @Test("A tool under its name before 3.0 is left for the migration, never pruned")
    func legacyNamedToolIsKept() throws {
        let runners = try makeRunners(cloning: [Self.rosetta])
        defer { try? FileManager.default.removeItem(at: runners) }
        let fm = FileManager.default
        let compat = runners.appending(path: "compatibilitytools.d")
        let names = ["notproton", "notproton-gone", "notproton-winecx-11.17"]
        for name in names {
            try fm.createDirectory(at: compat.appending(path: name), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: compat.appending(path: "\(name)/run"))
        }

        try sync(runners)

        for name in names {
            #expect(fm.fileExists(atPath: compat.appending(path: "\(name)/run").path(percentEncoded: false)))
        }
        let listed = try #require(toolList(runners)).split(separator: "\n").compactMap { $0.split(separator: "\t").first }
        #expect(!listed.isEmpty)
        #expect(listed.allSatisfy { $0.hasPrefix("bridgeplay-proton") })
    }

    @Test("A tool list written before 3.0 still names the legacy holder")
    func legacyListedHolderIsRecognised() throws {
        let runners = try makeRunners(cloning: [Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }
        let list = runners.appending(path: "tools")
        try atomicReplace(list, with: Data("notproton\t\(Self.fex.id)\tfex\tOld\n".utf8), step: "test")
        let builds = RunnerStore.installedBuilds(in: runners)
        #expect(CompatToolList.legacyHolder(
            builds: builds, listed: try String(contentsOf: list, encoding: .utf8), runners: runners
        ) == .build(Self.fex.id))
    }

    private func sync(_ runners: URL) throws {
        try CompatToolList.sync(
            runners: runners, bridge: runners.appending(path: "bridge"), file: runners.appending(path: "tools"),
            compatTools: runners.appending(path: "compatibilitytools.d")
        )
    }

    private func holder(_ runners: URL) -> String? {
        toolList(runners)?.split(separator: "\n").map { $0.split(separator: "\t") }
            .first { $0.first == "bridgeplay-proton" }.map { String($0[1]) }
    }

    @Test("A 1.0 install keeps the legacy name on the build runners/current pointed at")
    func legacyNameFollowsCurrent() throws {
        let runners = try makeRunners(cloning: [Self.rosetta, Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }
        let current = runners.appending(path: "current").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: current, withDestinationPath: "crossover-\(Self.rosetta.id)/CrossOver"
        )

        try sync(runners)
        #expect(holder(runners) == Self.rosetta.id)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: current)) == nil)

        try sync(runners)
        #expect(holder(runners) == Self.rosetta.id)
        #expect(toolList(runners)?.contains("bridgeplay-proton-fex\t\(Self.fex.id)\tfex\t") == true)
    }

    @Test("Without FEX support a 1.0 FEX install keeps its legacy name")
    func legacyFEXNameSurvivesWithoutFEX() throws {
        let runners = try makeRunners(cloning: [Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }
        try FileManager.default.createSymbolicLink(
            atPath: runners.appending(path: "current").path(percentEncoded: false),
            withDestinationPath: "crossover-\(Self.fex.id)/CrossOver"
        )
        let sync = {
            try CompatToolList.sync(
                runners: runners, bridge: runners.appending(path: "bridge"), file: runners.appending(path: "tools"),
                compatTools: runners.appending(path: "compatibilitytools.d"), fexAvailable: false
            )
        }

        try sync()
        #expect(holder(runners) == Self.fex.id)
        try sync()
        #expect(holder(runners) == Self.fex.id)
    }

    @Test("Setting up a second Preview leaves the legacy name where it is")
    func secondPreviewRenamesNothing() throws {
        let runners = try makeRunners(cloning: [Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }
        try FileManager.default.createSymbolicLink(
            atPath: runners.appending(path: "current").path(percentEncoded: false),
            withDestinationPath: "crossover-\(Self.fex.id)/CrossOver"
        )
        try sync(runners)
        #expect(holder(runners) == Self.fex.id)

        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: Self.rosetta.id, runners: runners).appending(path: "lib/wine"),
            withIntermediateDirectories: true
        )
        try sync(runners)
        #expect(holder(runners) == Self.fex.id)
        #expect(toolList(runners)?.contains("bridgeplay-proton-preview\t\(Self.rosetta.id)\t") == true)
        #expect(toolList(runners)?.contains("bridgeplay-proton-fex-rosetta\t\(Self.fex.id)\t") == true)
    }

    @Test("A fresh install gives the legacy name to nobody")
    func freshInstallHasNoLegacyName() throws {
        let runners = try makeRunners(cloning: [Self.preview41069, Self.fex41069])
        defer { try? FileManager.default.removeItem(at: runners) }

        try sync(runners)
        #expect(holder(runners) == nil)
        #expect(toolList(runners)?.hasPrefix("bridgeplay-proton-fex-41069\t\(Self.fex41069.id)\tfex\t") == true)
        #expect(toolList(runners)?.contains("bridgeplay-proton-preview-41069\t\(Self.preview41069.id)\t") == true)
    }

    @Test("A 1.0.3 install keeps the legacy name on 41069")
    func legacyNameFollows41069() throws {
        let runners = try makeRunners(cloning: [Self.preview41069, Self.fex41069])
        defer { try? FileManager.default.removeItem(at: runners) }
        try FileManager.default.createSymbolicLink(
            atPath: runners.appending(path: "current").path(percentEncoded: false),
            withDestinationPath: "crossover-\(Self.preview41069.id)/CrossOver"
        )

        try sync(runners)
        #expect(holder(runners) == Self.preview41069.id)
        try sync(runners)
        #expect(holder(runners) == Self.preview41069.id)
        #expect(toolList(runners)?.contains("bridgeplay-proton-fex-41069\t\(Self.fex41069.id)\tfex\t") == true)
    }

    @Test("A Preview listed under its own name does not take the legacy name later")
    func ownNameSticks() throws {
        let runners = try makeRunners(cloning: [Self.rosetta, Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }
        try CompatToolList.contents(SupportedRunners.tools(for: [Self.rosetta, Self.fex], legacy: .nobody))
            .write(to: runners.appending(path: "tools"), atomically: true, encoding: .utf8)

        try sync(runners)
        #expect(holder(runners) == nil)
    }

    @Test("The single-build layout stays while Steam still runs a tool that reads it")
    func keepsLegacyLayoutForOldRunScript() throws {
        let runners = try makeRunners(cloning: [Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }
        let bridge = runners.appending(path: "bridge")
        let legacy = bridge.appending(path: "wine/x86_64-windows/ntdll.dll")
        try atomicReplace(legacy, with: Data("old".utf8), step: "test")
        let current = runners.appending(path: "current").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: current, withDestinationPath: "crossover-\(Self.fex.id)/CrossOver"
        )
        // A tool written before 3.0, still under its old name.
        let run = runners.appending(path: "compatibilitytools.d/notproton/run")
        try atomicReplace(
            run, with: Data("CX_ROOT=\"$HOME/Library/Application Support/notproton/runners/current\"\n".utf8),
            step: "test"
        )

        _ = try prepare(Self.fex, runners: runners, calls: Calls())

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: legacy.path(percentEncoded: false)))
        #expect((try? fm.destinationOfSymbolicLink(atPath: current)) != nil)

        try atomicReplace(run, with: Data("CX_ROOT=\"$np_support/runners/crossover-$np_build\"\n".utf8), step: "test")
        _ = try prepare(Self.fex, runners: runners, calls: Calls())
        #expect(!fm.fileExists(atPath: legacy.path(percentEncoded: false)))
        #expect((try? fm.destinationOfSymbolicLink(atPath: current)) == nil)
    }

    @Test("A build with no clone is refused without touching anything")
    func refusesMissingClone() throws {
        let runners = try makeRunners(cloning: [Self.rosetta])
        defer { try? FileManager.default.removeItem(at: runners) }

        let calls = Calls()
        let failure = try #require(throws: StepFailure.self) {
            try prepare(Self.fex, runners: runners, calls: calls)
        }

        #expect(failure.detail.contains("has not been set up"))
        #expect(calls.staged.isEmpty)
        #expect(toolList(runners) == nil)
    }

    @Test("Preparing is refused when CrossOver is not activated")
    func refusesUnlicensed() throws {
        let runners = try makeRunners(cloning: [Self.rosetta, Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }

        let calls = Calls()
        #expect(throws: StepFailure.self) {
            try prepare(Self.fex, runners: runners, calls: calls, license: Self.unlicensed)
        }

        #expect(calls.staged.isEmpty)
        #expect(toolList(runners) == nil)
    }

    @Test("Installed builds are supported clones that still have their payload")
    func installedBuildsListing() throws {
        let runners = try makeRunners(cloning: [Self.rosetta, Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }

        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: "1.0.0.1", runners: runners)
                .appending(path: "lib/wine"),
            withIntermediateDirectories: true
        )
        try FileManager.default.removeItem(
            at: SupportPaths.clonedRoot(forBuild: Self.fex.id, runners: runners)
        )

        #expect(RunnerStore.installedBuilds(in: runners) == [Self.rosetta])
    }
}

@MainActor
@Suite("Choosing which CrossOver to set up from")
struct SetupSourceTests {

    private func install(_ name: String, _ build: RunnerBuild) -> CrossOverInstall {
        CrossOverInstall(
            bundle: URL(filePath: "/Applications/\(name).app"),
            releaseVersion: build.releaseVersion,
            support: .supported(build)
        )
    }

    private func status(runner: RunnerState, installs: [CrossOverInstall]) -> SystemStatus {
        let status = SystemStatus()
        status.snapshot = StatusSnapshot(
            steam: .steamMissing,
            steamRunning: false,
            updateBlocked: false,
            crossOver: installs,
            crossOverLicense: [:],
            runner: runner,
            payload: PayloadInspector.inspect(bridge: FileManager.default.temporaryDirectory, builds: [])
        )
        return status
    }

    @Test("A recopy comes from the install a set-up build was cloned from")
    func prefersInstalledBuild() {
        let rosetta = install("CrossOver", SupportedRunners.all[0])
        let fex = install("CrossOver FEX", SupportedRunners.all[1])

        let status = status(
            runner: .ready(builds: [SupportedRunners.all[1].id]),
            installs: [rosetta, fex]
        )

        #expect(status.setupSource?.id == fex.id)
    }

    @Test("With no tool set up, the preferred install is used")
    func fallsBackToPreferred() {
        let rosetta = install("CrossOver", SupportedRunners.all[0])
        let fex = install("CrossOver FEX", SupportedRunners.all[1])

        let status = status(runner: .none, installs: [rosetta, fex])

        #expect(status.setupSource?.id == rosetta.id)
        #expect(status.usableCrossOvers.map(\.id) == [rosetta.id, fex.id])
    }

    @Test("An install matching a set-up build can repair it")
    func repairSourceMatchesInstalledBuild() {
        let rosetta = install("CrossOver", SupportedRunners.all[0])
        let status = status(
            runner: .ready(builds: [SupportedRunners.all[0].id]),
            installs: [rosetta]
        )
        status.snapshot?.installedRunners = [SupportedRunners.all[0]]

        #expect(status.repairSource?.id == rosetta.id)
    }

    @Test("An install offering another build cannot repair a set-up one")
    func repairSourceIsNilWhenBuildDiffers() {
        let rosetta = install("CrossOver", SupportedRunners.all[0])
        let status = status(
            runner: .ready(builds: [SupportedRunners.all[1].id]),
            installs: [rosetta]
        )
        status.snapshot?.installedRunners = [SupportedRunners.all[1]]

        #expect(status.repairSource == nil)
        #expect(status.setupSource?.id == rosetta.id)
    }

    @Test("With every build on disk, a repair comes from the set-up build's install")
    func repairSourceWithEveryBuildCopied() {
        let rosetta = install("CrossOver", SupportedRunners.all[0])
        let fex = install("CrossOver FEX", SupportedRunners.all[1])
        let status = status(
            runner: .ready(builds: [SupportedRunners.all[1].id]),
            installs: [rosetta, fex]
        )
        status.snapshot?.installedRunners = SupportedRunners.all

        #expect(status.repairSource?.id == fex.id)
    }

    @Test("With nothing set up there is no repair source")
    func noRepairSourceBeforeFirstSetUp() {
        let rosetta = install("CrossOver", SupportedRunners.all[0])
        let status = status(runner: .none, installs: [rosetta])

        #expect(status.repairSource == nil)
        #expect(status.setupSource?.id == rosetta.id)
    }
}

@Suite("Removing an installed build")
struct RunnerRemovalTests {

    private static let rosetta = SupportedRunners.all.first { $0.flavor == nil }!
    private static let fex = SupportedRunners.all.first { $0.flavor == "fex" }!

    private func makeRunners(cloning builds: [String]) throws -> URL {
        let runners = FileManager.default.temporaryDirectory
            .appending(path: "np-remove-\(UUID().uuidString)")
        for build in builds {
            try FileManager.default.createDirectory(
                at: SupportPaths.clonedRoot(forBuild: build, runners: runners)
                    .appending(path: "lib/wine"),
                withIntermediateDirectories: true
            )
        }
        return runners
    }

    private func remove(
        _ build: String, runners: URL, libraries: [SteamLibrary] = [], running: Bool = false
    ) throws -> Bool {
        try RunnerInstaller.removeClone(
            forBuild: build, runners: runners,
            bridge: runners.appending(path: "bridge"), toolList: runners.appending(path: "tools"),
            compatTools: runners.appending(path: "compatibilitytools.d"),
            libraries: libraries,
            running: { _ in running }
        )
    }

    @Test("Removing a build leaves nothing of it in the runners folder")
    func removalLeavesNothing() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, Self.fex.id])
        defer { try? FileManager.default.removeItem(at: runners) }
        let fm = FileManager.default
        let leftover = runners.appending(path: ".crossover-\(Self.rosetta.id).removing/CrossOver")
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)

        _ = try remove(Self.rosetta.id, runners: runners)

        let left = try fm.contentsOfDirectory(atPath: runners.path(percentEncoded: false))
            .filter { $0.contains(Self.rosetta.id) }
        #expect(left.isEmpty)
        #expect(RunnerStore.clonedBuilds(in: runners) == [Self.fex.id])
    }

    @Test("Removing a build also clears what an earlier failed removal of another build left")
    func removalClearsOtherLeftovers() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id])
        defer { try? FileManager.default.removeItem(at: runners) }
        let fm = FileManager.default
        let leftover = runners.appending(path: ".crossover-\(Self.fex.id).removing/CrossOver")
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)

        _ = try remove(Self.rosetta.id, runners: runners)

        #expect(try fm.contentsOfDirectory(atPath: runners.path(percentEncoded: false))
            .filter { $0.hasSuffix(".removing") }.isEmpty)
    }

    @Test("A removal whose tool list cannot be written puts the build back")
    func failedSyncRestoresBuild() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, Self.fex.id])
        defer { try? FileManager.default.removeItem(at: runners) }
        let fm = FileManager.default
        try fm.createDirectory(at: runners.appending(path: "tools/blocked"), withIntermediateDirectories: true)
        let staged = runners.appending(path: "bridge/wine/\(Self.rosetta.id)/x86_64-windows/ntdll.dll")
        try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("patched".utf8).write(to: staged)

        #expect(throws: (any Error).self) { try remove(Self.rosetta.id, runners: runners) }
        #expect(fm.fileExists(atPath: staged.path(percentEncoded: false)))

        #expect(RunnerStore.clonedBuilds(in: runners) == [Self.fex.id, Self.rosetta.id].sorted())
        #expect(RunnerInstaller.hasClone(forBuild: Self.rosetta.id, runners: runners))
        #expect(try fm.contentsOfDirectory(atPath: runners.path(percentEncoded: false))
            .filter { $0.hasSuffix(".removing") }.isEmpty)
    }

    @Test("Removing a build deletes its prefix templates in every library and keeps the others")
    func removesThatBuildsTemplates() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, Self.fex.id])
        defer { try? FileManager.default.removeItem(at: runners) }
        let fm = FileManager.default
        let libraries = ["internal", "external"].map {
            SteamLibrary(root: runners.appending(path: "libraries/\($0)"))
        }
        for library in libraries {
            for build in [Self.rosetta.id, Self.fex.id] {
                for template in SupportPaths.prefixTemplates(forBuild: build, in: library) {
                    try fm.createDirectory(
                        at: template.appending(path: "pfx/drive_c"), withIntermediateDirectories: true)
                }
            }
        }

        _ = try remove(Self.rosetta.id, runners: runners, libraries: libraries)

        for library in libraries {
            let left = try fm.contentsOfDirectory(
                atPath: library.compatdata.appending(path: SupportPaths.prefixTemplateFolder)
                    .path(percentEncoded: false)
            ).sorted()
            #expect(left == SupportPaths.prefixTemplates(forBuild: Self.fex.id, in: library)
                .map(\.lastPathComponent).sorted())
        }
    }

    @Test("Removing a build also clears templates left by builds removed while their drive was away")
    func removesTemplatesOfBuildsAlreadyGone() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, Self.fex.id])
        defer { try? FileManager.default.removeItem(at: runners) }
        let fm = FileManager.default
        let library = SteamLibrary(root: runners.appending(path: "libraries/external"))
        let gone = SupportPaths.prefixTemplates(forBuild: "26.3.0.39832", in: library)
        for template in gone {
            try fm.createDirectory(at: template.appending(path: "pfx"), withIntermediateDirectories: true)
        }

        _ = try remove(Self.rosetta.id, runners: runners, libraries: [library])

        for template in gone { #expect(!fm.fileExists(atPath: template.path(percentEncoded: false))) }
    }

    @Test("A template is named by the build and the unix arch, under notproton-template")
    func templateNamesMatchTheScript() throws {
        let library = SteamLibrary(root: URL(filePath: "/L"))
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: repo.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
        let expression = try #require(script.firstMatch(of: #/runner_id="([^"]+)"/#)).1
        let cache = script.split(separator: "\n").first { $0.contains("template_cache=\"") }
        #expect(cache?.contains("$(dirname \"$STEAM_COMPAT_DATA_PATH\")/\(SupportPaths.prefixTemplateFolder)\"") == true)
        let template = script.split(separator: "\n").first { $0.contains("template_dir=\"") }
        #expect(template?.contains("template_dir=\"$template_cache/$runner_id\"") == true)
        let names = ["x86_64-unix", "aarch64-unix"].map { arch in
            expression.replacingOccurrences(of: "$np_build", with: "27.0.0.40921-fex")
                .replacingOccurrences(of: "${wine_unix##*/}", with: arch)
        }
        #expect(SupportPaths.prefixTemplates(forBuild: "27.0.0.40921-fex", in: library).map(\.path)
            == names.map { library.compatdata.appending(path: SupportPaths.prefixTemplateFolder).appending(path: $0).path })
    }

    @Test("A build with a game still running on it is not removed")
    func keepsRunningBuild() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id])
        defer { try? FileManager.default.removeItem(at: runners) }

        #expect(throws: StepFailure.self) { try remove(Self.rosetta.id, runners: runners, running: true) }
        #expect(RunnerInstaller.hasClone(forBuild: Self.rosetta.id, runners: runners))
    }

    @Test("A process runs from a clone only when its executable sits inside it")
    func readsRunningExecutables() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-ps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ps = dir.appending(path: "ps")
        try """
            #!/bin/sh
            echo "/launchd"
            echo "/R/crossover-26.3.0.39832/CrossOver/CrossOver-Hosted Application/wineserver"
            """.write(to: ps, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path(percentEncoded: false))
        let path = ps.path(percentEncoded: false)

        #expect(RunnerInstaller.isRunning(from: URL(filePath: "/R/crossover-26.3.0.39832"), ps: path))
        #expect(!RunnerInstaller.isRunning(from: URL(filePath: "/R/crossover-26.3.0"), ps: path))
        #expect(!RunnerInstaller.isRunning(from: URL(filePath: "/R/crossover-27.0.0.40921"), ps: path))
        #expect(RunnerInstaller.isRunning(from: URL(filePath: "/R/x"), ps: "/nonexistent/ps"))
    }

    @Test("A clone linked to another drive reads as running, and its build is named")
    func readsRunningThroughALink() throws {
        let fm = FileManager.default
        let dir = URL(filePath: try scratchDirectory("runner-link").path(percentEncoded: false)).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: dir) }
        let real = dir.appending(path: "external/crossover-27")
        let runners = dir.appending(path: "runners")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createDirectory(at: runners, withIntermediateDirectories: true)
        let link = runners.appending(path: "crossover-27")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let printed = real.path(percentEncoded: false).withCString { path in
            realpath(path, nil).map { defer { free($0) }; return String(cString: $0) }
        } ?? ""
        let ps = dir.appending(path: "ps")
        try """
            #!/bin/sh
            echo "\(printed)/CrossOver/bin/wineserver"
            """.write(to: ps, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path(percentEncoded: false))
        let path = ps.path(percentEncoded: false)

        #expect(RunnerInstaller.isRunning(from: link, ps: path))
        #expect(RunnerInstaller.runningBuild(in: runners, running: { RunnerInstaller.isRunning(from: $0, ps: path) }, launching: { nil }) == "27")
        #expect(RunnerInstaller.runningBuild(in: runners, running: { _ in false }, launching: { nil }) == nil)
    }

    @Test("A launch reads as running from its run script, before any Wine process shows up")
    func readsALaunchFromItsRunScript() throws {
        let fm = FileManager.default
        let dir = URL(filePath: try scratchDirectory("runner-launching").path(percentEncoded: false)).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: dir) }
        let tools = dir.appending(path: "compatibilitytools.d")
        let current = tools.appending(path: "bridgeplay-proton-winecx-11.17")
        let legacy = tools.appending(path: "notproton-winecx-11.1")
        for tool in [current, legacy] { try fm.createDirectory(at: tool, withIntermediateDirectories: true) }
        try "winecx-11.17\n".write(to: current.appending(path: "build"), atomically: true, encoding: .utf8)
        func ps(_ lines: [String]) throws -> String {
            let ps = dir.appending(path: "ps-\(UUID().uuidString)")
            let body = lines.map { "echo '\($0)'" }.joined(separator: "\n")
            try "#!/bin/sh\n\(body)\n".write(to: ps, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path(percentEncoded: false))
            return ps.path(percentEncoded: false)
        }
        let script = current.appending(path: "run").path(percentEncoded: false)
        let launching = try ps(["/sbin/launchd", "/bin/sh \(script) waitforexitandrun /G/Game.exe"])
        // What Steam runs.
        let dotted = try ps(["/bin/sh \(current.path(percentEncoded: false))/./run waitforexitandrun /G/Game.exe"])
        #expect(RunnerInstaller.launchingBuild(tools: [current], ps: dotted) == "winecx-11.17")

        #expect(RunnerInstaller.launchingBuild(tools: [current, legacy], ps: launching) == "winecx-11.17")
        #expect(RunnerInstaller.launchingBuild(tools: [legacy], ps: launching) == nil)
        #expect(RunnerInstaller.launchingBuild(tools: [], ps: launching) == nil)
        // A tool without a build file is named by its folder.
        let old = try ps(["/bin/sh \(legacy.appending(path: "run").path(percentEncoded: false))"])
        #expect(RunnerInstaller.launchingBuild(tools: [current, legacy], ps: old) == "notproton-winecx-11.1")
        #expect(RunnerInstaller.launchingBuild(tools: [current], ps: try ps(["\(script) waitforexitandrun /G/Game.exe"])) == "winecx-11.17")
        // Nothing running, a longer name, a file next to run, a process only naming the script,
        // and ps failing all read as no launch.
        let idle = try ps(["/sbin/launchd", "/bin/sh \(script)x", "/bin/cat \(script).log", "/bin/sh /x\(script)",
                           "/usr/bin/tail -f \(script)", "/usr/bin/vim \(script)", "/bin/sh -c cat \(script)"])
        #expect(RunnerInstaller.launchingBuild(tools: [current, legacy], ps: idle) == nil)
        #expect(RunnerInstaller.launchingBuild(tools: [current], ps: "/nonexistent/ps") == nil)

        let runners = dir.appending(path: "runners")
        try fm.createDirectory(at: runners.appending(path: "crossover-27"), withIntermediateDirectories: true)
        #expect(RunnerInstaller.runningBuild(in: runners, running: { _ in false }, launching: { "winecx-11.17" }) == "winecx-11.17")
        #expect(RunnerInstaller.runningBuild(in: runners, running: { _ in true }, launching: { "winecx-11.17" }) == "27")
        #expect(RunnerInstaller.runningBuild(in: runners, running: { _ in false }, launching: { nil }) == nil)
    }

    @Test("Any build can be removed, and its tools and staged copies go with it")
    func removesBuild() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, Self.fex.id])
        defer { try? FileManager.default.removeItem(at: runners) }
        let bridge = runners.appending(path: "bridge")
        let staged = NtdllPatcher.stagedCopy(of: .x86_64Windows, build: Self.fex.id, in: bridge)
        try atomicReplace(staged, with: Data("fex".utf8), step: "test")

        #expect(try remove(Self.fex.id, runners: runners))

        #expect(!RunnerInstaller.hasClone(forBuild: Self.fex.id, runners: runners))
        #expect(RunnerInstaller.hasClone(forBuild: Self.rosetta.id, runners: runners))
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        let list = try String(contentsOf: runners.appending(path: "tools"), encoding: .utf8)
        #expect(list == CompatToolList.contents(SupportedRunners.tools(for: [Self.rosetta])))

        #expect(try remove(Self.rosetta.id, runners: runners))
        #expect(try String(contentsOf: runners.appending(path: "tools"), encoding: .utf8).isEmpty)
    }

    @Test("A build with no clone reports rather than succeeding quietly")
    func refusesMissingBuild() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id])
        defer { try? FileManager.default.removeItem(at: runners) }

        #expect(throws: StepFailure.self) {
            try remove(Self.fex.id, runners: runners)
        }
    }

    @Test("A supported build whose payload never finished copying is listed as damaged")
    func damagedCloneIsListed() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id])
        defer { try? FileManager.default.removeItem(at: runners) }

        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: Self.fex.id, runners: runners),
            withIntermediateDirectories: true
        )

        #expect(RunnerStore.damagedClones(in: runners) == [Self.fex.id])
        #expect(RunnerStore.orphanedClones(in: runners).isEmpty)
        #expect(RunnerStore.installedBuilds(in: runners).map(\.id) == [Self.rosetta.id])
    }

    @Test("Every clone on disk lands in exactly one of the three lists")
    func cloneListsPartition() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, "1.2.3.4567"])
        defer { try? FileManager.default.removeItem(at: runners) }

        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: Self.fex.id, runners: runners),
            withIntermediateDirectories: true
        )

        let installed = RunnerStore.installedBuilds(in: runners).map(\.id)
        let damaged   = RunnerStore.damagedClones(in: runners)
        let orphaned  = RunnerStore.orphanedClones(in: runners)
        let all       = installed + damaged + orphaned

        #expect(Set(all) == Set(RunnerStore.clonedBuilds(in: runners)))
        #expect(all.count == Set(all).count)
    }

    @Test("Clones of unsupported versions are listed apart from installed builds")
    func orphanedClonesAreFound() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, "1.2.3.4567"])
        defer { try? FileManager.default.removeItem(at: runners) }

        #expect(RunnerStore.orphanedClones(in: runners) == ["1.2.3.4567"])
        #expect(RunnerStore.installedBuilds(in: runners).map(\.id) == [Self.rosetta.id])
    }

    @Test("An orphaned clone can be removed")
    func removesOrphanedClone() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, "1.2.3.4567"])
        defer { try? FileManager.default.removeItem(at: runners) }

        _ = try remove("1.2.3.4567", runners: runners)

        #expect(RunnerStore.orphanedClones(in: runners).isEmpty)
        #expect(RunnerInstaller.hasClone(forBuild: Self.rosetta.id, runners: runners))
    }

    @Test("A clone's size counts the bytes it occupies")
    func measuresCloneSize() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id])
        defer { try? FileManager.default.removeItem(at: runners) }
        let file = SupportPaths.clonedRoot(forBuild: Self.rosetta.id, runners: runners)
            .appending(path: "lib/wine/blob")
        try Data(repeating: 0, count: 64 * 1024).write(to: file)

        #expect(RunnerStore.cloneSize(forBuild: Self.rosetta.id, runners: runners) >= 64 * 1024)
    }
}
