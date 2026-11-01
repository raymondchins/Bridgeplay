import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Installed content")
struct DeploymentContentTests {
    private let build = DeploymentContent.Build(version: "1.0.1", builtAt: 200)

    private func files(in root: URL) throws -> [DeploymentContent.File] {
        let source = root.appending(path: "source")
        let destination = root.appending(path: "installed")
        try Data("new!".utf8).write(to: source)
        try Data("old!".utf8).write(to: destination)
        return [.init(source: source, destination: destination, name: "run")]
    }

    @Test("Same-version builds with different contents offer an update by build time")
    func newerBuild() throws {
        let root = try scratchDirectory("content")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try files(in: root)
        try FileManager.default.setAttributes([.modificationDate: Date.distantFuture], ofItemAtPath: files[0].destination.path)
        #expect(try DeploymentContent.inspect(files: files, bundled: build,
                    installed: .init(version: "1.0.1", builtAt: 100)) == .update(["run"]))
    }

    @Test("Matching bytes do not offer an update just because the app was rebuilt")
    func identicalContents() throws {
        let root = try scratchDirectory("content")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try files(in: root)
        try Data("new!".utf8).write(to: files[0].destination)
        #expect(try DeploymentContent.inspect(files: files, bundled: build,
                    installed: .init(version: "1.0.1", builtAt: 100)) == .current)
    }

    @Test("An older app cannot offer its files over a newer installation")
    func newerInstallation() throws {
        #expect(try DeploymentContent.inspect(files: [], bundled: build,
                    installed: .init(version: "1.0.1", builtAt: 300)) == .newerInstalled)
        #expect(try DeploymentContent.inspect(files: [], bundled: build,
                    installed: .init(version: "1.0.2", builtAt: 100)) == .newerInstalled)
        #expect(try DeploymentContent.inspect(files: [], bundled: build, installed: nil,
                    legacyVersion: "1.0.10") == .newerInstalled)
    }

    @Test("A changed or missing file from the recorded build offers repair")
    func damagedInstallation() throws {
        let root = try scratchDirectory("content")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try files(in: root)
        #expect(try DeploymentContent.inspect(files: files, bundled: build, installed: build) == .repair(["run"]))
        try FileManager.default.removeItem(at: files[0].destination)
        #expect(try DeploymentContent.inspect(files: files, bundled: build, installed: build) == .repair(["run"]))
    }

    @Test("Legacy installations report differences without guessing build order")
    func unrecordedBuild() throws {
        let root = try scratchDirectory("content")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try DeploymentContent.inspect(files: files(in: root), bundled: build,
                    installed: nil, legacyVersion: "1.0.1") == .unrecorded(["run"]))
        #expect(try DeploymentContent.inspect(files: files(in: root), bundled: build,
                    installed: nil, legacyVersion: "1.0.0") == .update(["run"]))
    }

    @Test("A missing bundled file is an error rather than an update to install")
    func missingSource() throws {
        let root = try scratchDirectory("content")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try files(in: root)
        try FileManager.default.removeItem(at: files[0].source)
        #expect(throws: (any Error).self) { try DeploymentContent.inspect(files: files, bundled: build, installed: build) }
    }

    @Test("A matching script without execute permission still needs repair")
    func executablePermission() throws {
        let root = try scratchDirectory("content")
        defer { try? FileManager.default.removeItem(at: root) }
        var files = try files(in: root)
        files[0].executable = true
        try Data("new!".utf8).write(to: files[0].destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: files[0].destination.path)
        #expect(try DeploymentContent.inspect(files: files, bundled: build, installed: build) == .repair(["run"]))
    }

    @Test("A symlink is not mistaken for a matching installed file")
    func linkedDestination() throws {
        let root = try scratchDirectory("content")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try files(in: root)
        try FileManager.default.removeItem(at: files[0].destination)
        try FileManager.default.createSymbolicLink(at: files[0].destination, withDestinationURL: files[0].source)
        #expect(try !files[0].matches())
    }

    @Test("Corrupt build records do not silently become legacy installations")
    func invalidRecord() throws {
        let root = try scratchDirectory("content")
        defer { try? FileManager.default.removeItem(at: root) }
        let record = root.appending(path: "record")
        #expect(try DeploymentContent.readBuild(at: record) == nil)
        try Data("bad".utf8).write(to: record)
        #expect(throws: (any Error).self) { try DeploymentContent.readBuild(at: record) }
    }

    @Test("Re-signing is ignored but re-signed content changes with the same UUID are detected", arguments: [false, true])
    func signingDoesNotHideCodeChanges(largeSignature: Bool) throws {
        let root = try scratchDirectory("content-signing")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.c")
        let library = root.appending(path: "source.dylib")
        let installed = root.appending(path: "installed.dylib")
        try Data("const char np_marker[] = \"np-before\";\n".utf8).write(to: source)
        try Shell.check("/usr/bin/clang", ["-dynamiclib", "-arch", "arm64", "-arch", "x86_64", "-o", library.path, source.path])
        try FileManager.default.copyItem(at: library, to: installed)
        let identifier = largeSignature ? String(repeating: "x", count: 20_000) : "installed-copy"
        try Shell.check("/usr/bin/codesign", ["-f", "-s", "-", "--identifier", identifier, installed.path])
        let file = DeploymentContent.File(source: library, destination: installed, name: "notproton.dylib", allowsResigning: true)
        #expect(Digest.sha256IfPresent(library) != Digest.sha256IfPresent(installed))
        #expect(try file.matches())

        var bytes = try Data(contentsOf: installed)
        let marker = try #require(bytes.range(of: Data("np-before".utf8)))
        bytes.replaceSubrange(marker, with: Data("np-after!".utf8))
        try bytes.write(to: installed)
        let recorded = DeploymentContent.Build(version: build.version, builtAt: build.builtAt,
                                               dylibHashes: try MachOBuild.hashesIgnoringSignature(of: library))
        #expect(try DeploymentContent.inspect(files: [file], bundled: build, installed: recorded) == .repair(["notproton.dylib"]))
        try Shell.check("/usr/bin/codesign", ["-f", "-s", "-", installed.path])
        #expect(MachOBuild.identity(of: library) == MachOBuild.identity(of: installed))
        #expect(try !file.matches())
        let staleRecord = DeploymentContent.Build(version: "1.0.1", builtAt: 100,
                                                  dylibHashes: try MachOBuild.hashesIgnoringSignature(of: library))
        #expect(throws: StepFailure.self) {
            try DeploymentContent.inspect(files: [file], bundled: build, installed: staleRecord)
        }
    }

    @MainActor
    @Test("Build-record blockers also disable Install when the dylib is missing")
    func unavailableInstallAction() {
        let status = SystemStatus()
        let payload = PayloadState(expected: 0, present: 0, missing: [], overlayShimPresent: true,
                                   iconmakerPresent: true, appinfoPresent: true, gamefixPrepPresent: true,
                                   signatureDatabase: "fixture",
                                   legacyCompatPresent: 0, legacyCompatExpected: 0, manifestProblem: nil)
        status.snapshot = StatusSnapshot(steam: .notInstalled, steamRunning: false, updateBlocked: false,
                                         crossOver: [], runner: .none, payload: payload,
                                         installContent: .newerInstalled)
        #expect(!status.canInstall)
        status.snapshot?.installContent = .unavailable("invalid record")
        #expect(!status.canInstall)
        status.snapshot?.installContent = .unrecorded(["notproton.dylib"])
        #expect(status.canInstall)
    }

    @MainActor
    @Test("A newer installed build also blocks removing a build")
    func newerInstallBlocksRemoval() {
        let status = SystemStatus()
        let payload = PayloadState(expected: 0, present: 0, missing: [], overlayShimPresent: true,
                                   iconmakerPresent: true, appinfoPresent: true, gamefixPrepPresent: true,
                                   signatureDatabase: "fixture",
                                   legacyCompatPresent: 0, legacyCompatExpected: 0, manifestProblem: nil)
        status.snapshot = StatusSnapshot(steam: .notInstalled, steamRunning: false, updateBlocked: false,
                                         crossOver: [], runner: .none, payload: payload,
                                         installContent: .newerInstalled)
        status.requestBuildRemoval("crossover-26.0")
        #expect(status.pendingRemoval == nil)
        #expect(status.pendingConfirmation == nil)
        status.snapshot?.installContent = .unrecorded(["notproton.dylib"])
        status.requestBuildRemoval("crossover-26.0")
        #expect(status.pendingRemoval == "crossover-26.0")
        #expect(status.pendingConfirmation == .removeBuild)
    }

    @Test("Installation locking excludes another caller and releases without a lock file")
    func installationLock() throws {
        let root = try scratchDirectory("content-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let lock = try DeploymentContent.acquireInstallationLock(in: root, steamFolder: nil)
            defer { lock.release() }
            #expect(throws: StepFailure.self) { try DeploymentContent.acquireInstallationLock(in: root, steamFolder: nil) }
            let status = try Shell.run("/bin/sh", ["-c", #"exec 9< "$1"; /usr/bin/lockf -s -t 0 9"#, "fixture", root.path]).status
            #expect(status == 75)
        }
        let next = try DeploymentContent.acquireInstallationLock(in: root, steamFolder: nil)
        next.release()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Steam's folder is locked too, so another account on the Mac is kept out")
    func installationLockCoversSteam() throws {
        let root = try scratchDirectory("content-lock-steam")
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = root.appending(path: "mine"), theirs = root.appending(path: "theirs"), steam = root.appending(path: "Applications")
        for folder in [mine, theirs, steam] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        let lock = try DeploymentContent.acquireInstallationLock(in: mine, steamFolder: steam)
        #expect(throws: StepFailure.self) { try DeploymentContent.acquireInstallationLock(in: theirs, steamFolder: steam) }
        lock.release()

        let after = try DeploymentContent.acquireInstallationLock(in: theirs, steamFolder: steam)
        after.release()
    }

    @Test("Steam in the same folder as our own lock, directly or through a symlink, is not locked twice")
    func installationLockSharesAFolder() throws {
        let root = try scratchDirectory("content-lock-shared")
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)

        try DeploymentContent.acquireInstallationLock(in: root, steamFolder: root).release()
        try DeploymentContent.acquireInstallationLock(in: root, steamFolder: link).release()
    }

    @Test("An unplugged Steam drive does not stop the lock from being taken")
    func installationLockSkipsMissingSteam() throws {
        let root = try scratchDirectory("content-lock-unplugged")
        defer { try? FileManager.default.removeItem(at: root) }

        let lock = try DeploymentContent.acquireInstallationLock(in: root, steamFolder: URL(filePath: "/Volumes/np-missing-\(UUID().uuidString)"))
        defer { lock.release() }
        #expect(throws: StepFailure.self) { try DeploymentContent.acquireInstallationLock(in: root, steamFolder: nil) }
    }

    @Test("Missing and changed tool lists are included in the expected installed content")
    func includesToolList() throws {
        let root = try scratchDirectory("content-tools")
        defer { try? FileManager.default.removeItem(at: root) }
        let runners = root.appending(path: "runners")
        let runner = SupportPaths.clonedRoot(forBuild: "26.3.0.39832", runners: runners)
        try FileManager.default.createDirectory(at: runner.appending(path: "lib/wine"), withIntermediateDirectories: true)
        let list = root.appending(path: "tools")
        for text in [nil, "", "incorrect"] as [String?] {
            if let text { try Data(text.utf8).write(to: list) }
            let pins = try DeploymentContent.pinnedFiles(bridge: root.appending(path: "bridge"), runners: runners)
            let pin = try #require(pins.first { $0.name == "tools" })
            #expect(Digest.sha256IfPresent(pin.destination) != pin.hash)
        }
        try Data(CompatToolList.contents(CompatToolList.installed(runners: runners, file: list)).utf8).write(to: list)
        let pins = try DeploymentContent.pinnedFiles(bridge: root.appending(path: "bridge"), runners: runners)
        let pin = try #require(pins.first { $0.name == "tools" })
        #expect(Digest.sha256IfPresent(pin.destination) == pin.hash)
    }

    @Test("The staged ntdll and runner ntdll are checked independently")
    func includesStagedNtdll() throws {
        let root = try scratchDirectory("content-ntdll")
        defer { try? FileManager.default.removeItem(at: root) }
        let runners = root.appending(path: "runners")
        let build = SupportedRunners.all[0]
        let runner = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        try FileManager.default.createDirectory(at: runner.appending(path: "lib/wine"), withIntermediateDirectories: true)
        let bridge = root.appending(path: "bridge")
        let pins = try DeploymentContent.pinnedFiles(bridge: bridge, runners: runners)
        for (arch, hash) in build.patchedNtdll {
            let staged = NtdllPatcher.stagedCopy(of: arch, build: build.id, in: bridge)
            let pin = try #require(pins.first { $0.destination == staged })
            #expect(pin.hash == hash)
            #expect(pins.contains { $0.destination == runner.appending(path: "lib/wine/\(arch.rawValue)/ntdll.dll") })
            try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("wrong staged copy".utf8).write(to: staged)
            #expect(Digest.sha256IfPresent(pin.destination) != pin.hash)
        }
    }

    @Test("Signature comparison refuses truncated headers, overlapping slices and invalid command sizes")
    func malformedMachOLayouts() {
        #expect(MachOBuild.unsignedSlices(Data()) == nil)
        #expect(MachOBuild.unsignedSlices(Data([0xcf, 0xfa, 0xed, 0xfe])) == nil)
        var thin = Data(repeating: 0, count: 40)
        thin.replaceSubrange(0..<4, with: [0xcf, 0xfa, 0xed, 0xfe])
        thin[16] = 1
        thin[20] = 8
        thin[32] = 0x19
        #expect(MachOBuild.unsignedSlices(thin) == nil)
        thin[36] = 0xff
        #expect(MachOBuild.unsignedSlices(thin) == nil)
        thin.replaceSubrange(16..<20, with: [0xff, 0xff, 0xff, 0xff])
        #expect(MachOBuild.unsignedSlices(thin) == nil)
        var fat = Data(repeating: 0, count: 80)
        fat.replaceSubrange(0..<8, with: [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2])
        fat[19] = 48
        fat[23] = 32
        fat[39] = 48
        fat[43] = 32
        fat.replaceSubrange(48..<52, with: [0xcf, 0xfa, 0xed, 0xfe])
        #expect(MachOBuild.unsignedSlices(fat) == nil)
    }
}
