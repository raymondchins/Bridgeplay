import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Cloning a runner")
struct RunnerInstallerTests {

    private func makeRunners() throws -> URL {
        let runners = FileManager.default.temporaryDirectory
            .appending(path: "np-point-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runners, withIntermediateDirectories: true)
        return runners
    }

    // The clone is found afterwards at a fixed name inside the build directory, so the copy has
    // to land as a child. cp keys that off the destination existing, and first time it does not.
    @Test("The copy lands as a payload directory inside the build directory")
    func copyLandsAsChildOfBuildDirectory() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let source = runners.appending(path: "source/CrossOver Preview.app/Contents/SharedSupport/CrossOver")
        try FileManager.default.createDirectory(
            at: source.appending(path: "lib/wine"), withIntermediateDirectories: true
        )

        let version = "27.0.0.40921"
        let target = SupportPaths.runnerRoot(forBuild: version, runners: runners)
        try RunnerInstaller.copyPayload(from: source, to: target)

        #expect(FileManager.default.fileExists(
            atPath: target.appending(path: "CrossOver/lib/wine").path(percentEncoded: false)
        ))

        // The check the setup path runs next has to agree, because that is where a wrongly
        // shaped copy was being reported.
        #expect(RunnerInstaller.hasClone(forBuild: version, runners: runners))
    }

    @Test("Clearing quarantine leaves the tree's other attributes alone")
    func clearQuarantineOnlyRemovesQuarantine() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }
        let file = runners.appending(path: "lib/wine/ntdll.so")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("so".utf8).write(to: file)
        try Shell.check("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0083;6a2b3c4d;Safari;", file.path(percentEncoded: false)])
        try Shell.check("/usr/bin/xattr", ["-w", "com.bridgeplay.keep", "1", file.path(percentEncoded: false)])

        try RunnerInstaller.clearQuarantine(at: runners)

        let left = try Shell.run("/usr/bin/xattr", [file.path(percentEncoded: false)]).stdout
        #expect(!left.contains("com.apple.quarantine"))
        #expect(left.contains("com.bridgeplay.keep"))
    }

    @Test("Clearing quarantine doesn't follow links out of the tree")
    func clearQuarantineStaysInsideTree() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }
        let tree = runners.appending(path: "tree")
        let outside = runners.appending(path: "outside")
        let outsideFile = outside.appending(path: "lib.dylib")
        let lonelyFile = runners.appending(path: "lonely.dylib")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("dylib".utf8).write(to: outsideFile)
        try Data("dylib".utf8).write(to: lonelyFile)
        for target in [outside, outsideFile, lonelyFile] {
            try Shell.check("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0083;6a2b3c4d;Safari;", target.path(percentEncoded: false)])
        }
        try FileManager.default.createSymbolicLink(at: tree.appending(path: "dir"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: tree.appending(path: "file.dylib"), withDestinationURL: lonelyFile)

        try RunnerInstaller.clearQuarantine(at: tree)

        for target in [outside, outsideFile, lonelyFile] {
            let left = try Shell.run("/usr/bin/xattr", [target.path(percentEncoded: false)]).stdout
            #expect(left.contains("com.apple.quarantine"), "\(target.lastPathComponent) lost its quarantine")
        }
    }

    @Test("A file whose quarantine can't be cleared fails the step")
    func clearQuarantineReportsFailure() throws {
        let runners = try makeRunners()
        let locked = runners.appending(path: "lib")
        defer {
            _ = try? Shell.run("/bin/chmod", ["-R", "u+w", runners.path(percentEncoded: false)])
            try? FileManager.default.removeItem(at: runners)
        }
        let file = locked.appending(path: "winemetal.so")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("so".utf8).write(to: file)
        try Shell.check("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0083;6a2b3c4d;Safari;", file.path(percentEncoded: false)])
        try Shell.check("/bin/chmod", ["444", file.path(percentEncoded: false)])
        try Shell.check("/bin/chmod", ["555", locked.path(percentEncoded: false)])

        #expect(throws: CommandFailure.self) { try RunnerInstaller.clearQuarantine(at: runners) }
    }

    // A CrossOver bundle holding only the files the clone path hashes, with the build describing
    // those exact bytes, so verification passes without a real 1.2G install to copy.
    private func makeSupportedInstall(
        in directory: URL, version: String = "27.0.0.40921"
    ) throws -> (CrossOverInstall, RunnerBuild) {
        let bundle = directory.appending(path: "source/CrossOver Preview.app")
        let wine = bundle.appending(path: "Contents/SharedSupport/CrossOver/lib/wine")

        for arch in WineArch.allCases {
            try FileManager.default.createDirectory(
                at: wine.appending(path: arch.rawValue), withIntermediateDirectories: true
            )
            try Data("ntdll for \(arch.rawValue)".utf8)
                .write(to: wine.appending(path: "\(arch.rawValue)/ntdll.dll"))
        }
        try FileManager.default.createDirectory(
            at: wine.appending(path: "x86_64-unix"), withIntermediateDirectories: true
        )
        try Data("wine loader".utf8).write(to: wine.appending(path: "x86_64-unix/wine"))

        func hash(_ url: URL) throws -> String {
            try #require(Digest.sha256IfPresent(url))
        }

        var clean: [WineArch: String] = [:]
        for arch in WineArch.allCases {
            clean[arch] = try hash(wine.appending(path: "\(arch.rawValue)/ntdll.dll"))
        }

        let build = RunnerBuild(
            bundleVersion: version,
            releaseVersion: "20260821",
            flavor: nil,
            loaderSHA256: try hash(wine.appending(path: "x86_64-unix/wine")),
            cleanNtdll: clean,
            patchedNtdll: [:]
        )
        let install = CrossOverInstall(
            bundle: bundle, releaseVersion: build.releaseVersion, support: .supported(build)
        )
        return (install, build)
    }

    @Test("A payload that never finished copying is replaced rather than kept")
    func partialCloneIsReplaced() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let (install, build) = try makeSupportedInstall(in: runners.appending(path: "src"))

        let stale = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: stale.appending(path: "leftover"))
        #expect(!RunnerInstaller.hasClone(forBuild: build.id, runners: runners))

        _ = try RunnerInstaller.clone(from: install, runners: runners)

        #expect(RunnerInstaller.hasClone(forBuild: build.id, runners: runners))
        #expect(!FileManager.default.fileExists(
            atPath: stale.appending(path: "leftover").path(percentEncoded: false)
        ))
    }

    @Test("Cloning another build leaves the first clone in place")
    func cloneKeepsOtherBuilds() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let (first, firstBuild) = try makeSupportedInstall(
            in: runners.appending(path: "first"), version: "1.0.0.1"
        )
        let (second, _) = try makeSupportedInstall(
            in: runners.appending(path: "second"), version: "2.0.0.2"
        )

        _ = try RunnerInstaller.clone(from: first, runners: runners)
        _ = try RunnerInstaller.clone(from: second, runners: runners)
        #expect(RunnerInstaller.hasClone(forBuild: firstBuild.bundleVersion, runners: runners))
        #expect(RunnerInstaller.hasClone(forBuild: "2.0.0.2", runners: runners))
    }

    // The first attempt left the build directory holding the payload's contents, not the payload.
    // Setup read that as a finished clone, skipped the copy, then failed the lookup itself.
    @Test("A build directory with no payload in it is cloned again rather than trusted")
    func replacesACloneThatHasNoPayloadInIt() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let (install, build) = try makeSupportedInstall(in: runners)

        let target = SupportPaths.runnerRoot(forBuild: build.bundleVersion, runners: runners)
        try FileManager.default.createDirectory(
            at: target.appending(path: "Contents/SharedSupport/CrossOver"),
            withIntermediateDirectories: true
        )

        _ = try RunnerInstaller.clone(from: install, runners: runners)

        #expect(RunnerInstaller.hasClone(forBuild: build.bundleVersion, runners: runners))

        // The leftover contents must be gone, not left beside the payload.
        #expect(!FileManager.default.fileExists(
            atPath: target.appending(path: "Contents").path(percentEncoded: false)
        ))
    }

    // Keeping lib/wine is not the same as keeping the loader inside it, and the loader is what
    // a game needs. Setup skips the copy for such a clone, so nothing else catches the loss.
    @Test("A clone that kept its payload directory but lost its loader is refused")
    func refusesCloneThatLostItsLoader() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let (install, build) = try makeSupportedInstall(in: runners)
        _ = try RunnerInstaller.clone(from: install, runners: runners)

        let root = SupportPaths.clonedRoot(forBuild: build.bundleVersion, runners: runners)
        try FileManager.default.removeItem(at: CrossOverSource.unixLoader(inRoot: root))

        // Still counts as cloned, so the copy is skipped and the loader check is reached.
        #expect(RunnerInstaller.hasClone(forBuild: build.bundleVersion, runners: runners))

        let failure = try #require(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: install, runners: runners)
        }
        #expect(
            failure.detail.contains("no Wine loader"),
            "a clone with no loader in it was reported as something else"
        )
    }

    // Replacing an intact clone used to remove it before the copy, so a failed copy took a
    // working 1.2G tree with it, with nothing in the UI.
    @Test("A failed recopy leaves the working clone intact")
    func keepsWorkingCloneWhenRecopyFails() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let (install, build) = try makeSupportedInstall(in: runners)
        _ = try RunnerInstaller.clone(from: install, runners: runners)

        let payload = SupportPaths
            .clonedRoot(forBuild: build.bundleVersion, runners: runners)
            .appending(path: "lib/wine")
        let files = FileManager.default

        // Asserted before the failure, or the checks afterwards pass on a clone that was
        // never there to begin with.
        #expect(files.fileExists(atPath: payload.path(percentEncoded: false)))

        // Removing the source fails the copy the same way running out of room part way
        // through does, which is the case that costs the user a working runner.
        try files.removeItem(at: runners.appending(path: "source"))

        #expect(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: install, replacingExisting: true, runners: runners)
        }

        #expect(
            files.fileExists(atPath: payload.path(percentEncoded: false)),
            "a recopy that failed destroyed the working clone"
        )
    }

    @Test("A rejected replacement keeps the installed runner", arguments: [false, true])
    func rejectedReplacementKeepsInstalledRunner(missing: Bool) throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }
        let (install, build) = try makeSupportedInstall(in: runners)
        _ = try RunnerInstaller.clone(from: install, runners: runners)
        let relative = "lib/wine/x86_64-windows/ntdll.dll"
        let installed = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        let original = try Data(contentsOf: installed.appending(path: relative))
        let source = install.crossOverRoot.appending(path: relative)
        if missing {
            try FileManager.default.removeItem(at: source)
        } else {
            try Data("damaged DLL".utf8).write(to: source)
        }

        #expect(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: install, replacingExisting: true, runners: runners)
        }
        #expect(try Data(contentsOf: installed.appending(path: relative)) == original)
        try RunnerInstaller.verifyClone(build: build, root: installed)
        #expect(!FileManager.default.fileExists(atPath:
            runners.appending(path: ".crossover-\(build.id).new").path(percentEncoded: false)))
    }

    @Test("A runner a game is using is not replaced")
    func runningRunnerIsNotReplaced() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }
        let (install, build) = try makeSupportedInstall(in: runners)
        _ = try RunnerInstaller.clone(from: install, runners: runners)
        let installed = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        let marker = installed.appending(path: "in-use")
        try Data().write(to: marker)

        let failure = #expect(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: install, replacingExisting: true, runners: runners, running: { _ in true })
        }
        #expect(failure?.detail.contains("still running") == true)
        #expect(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
        for leftover in [".new", ".removing"] {
            #expect(!FileManager.default.fileExists(atPath:
                runners.appending(path: ".crossover-\(build.id)\(leftover)").path(percentEncoded: false)))
        }
    }

    @Test("An idle runner is replaced and the old copy removed")
    func idleRunnerIsReplaced() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }
        let (install, build) = try makeSupportedInstall(in: runners)
        _ = try RunnerInstaller.clone(from: install, runners: runners)
        let installed = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        let marker = installed.appending(path: "old-copy")
        try Data().write(to: marker)

        _ = try RunnerInstaller.clone(from: install, replacingExisting: true, runners: runners, running: { _ in false })
        #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
        try RunnerInstaller.verifyClone(build: build, root: installed)
        #expect(!FileManager.default.fileExists(atPath:
            runners.appending(path: ".crossover-\(build.id).removing").path(percentEncoded: false)))
    }

    @Test("A rejected first copy is not left installed")
    func rejectedFirstCopyIsNotInstalled() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }
        let (install, build) = try makeSupportedInstall(in: runners)
        try Data("damaged DLL".utf8).write(to:
            install.crossOverRoot.appending(path: "lib/wine/x86_64-windows/ntdll.dll"))

        #expect(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: install, runners: runners)
        }
        #expect(!RunnerInstaller.hasClone(forBuild: build.id, runners: runners))
        #expect(!FileManager.default.fileExists(atPath:
            runners.appending(path: ".crossover-\(build.id).new").path(percentEncoded: false)))
    }

    @Test("The state reader agrees with what was just written")
    func stateAgreesWithInstaller() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let version = SupportedRunners.all[0].bundleVersion
        try FileManager.default.createDirectory(
            at: runners.appending(path: "crossover-\(version)/CrossOver/lib/wine"),
            withIntermediateDirectories: true
        )

        #expect(RunnerStore.state(runners: runners, verify: { _, _ in [] })
            == .ready(builds: [version]))
    }
}
