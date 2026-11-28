import Darwin
import Foundation
import CryptoKit
import Testing
@testable import BridgeplayInstallerCore

@Suite("Installer installation detection")
struct InstallerServiceTests {
    private let signature = Data(repeating: 0xA5, count: 64)
    private let archiveURL = URL(string: "https://github.com/raymondchins/Bridgeplay/releases/download/v3.5.0/Bridgeplay.zip")!

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "BridgeplayInstallerTests-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func service(at destination: URL, gate: @escaping @Sendable () throws -> Void = {}) -> InstallerService {
        InstallerService(destination: destination, ensureAppIsClosed: gate)
    }

    private func writeApp(at url: URL, identifier: String = InstallerService.bundleIdentifier,
                          version: String = "3.4.1", build: String = "34") throws {
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleExecutable": "BridgeplayApp",
        ]
        let infoURL = url.appending(path: "Contents/Info.plist")
        try FileManager.default.createDirectory(at: infoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: infoURL)
        let executable = url.appending(path: "Contents/MacOS/BridgeplayApp")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    private func writeSignedApp(at url: URL, version: String, build: String) throws {
        try writeApp(at: url, version: version, build: build)
        let executable = url.appending(path: "Contents/MacOS/BridgeplayApp")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--deep", url.path])
        try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", url.path])
    }

    private func installedBuild(at url: URL) throws -> String? {
        let data = try Data(contentsOf: url.appending(path: "Contents/Info.plist"))
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        return (propertyList as? [String: Any])?["CFBundleVersion"] as? String
    }

    private func release(build: Int = 35, version: String = "3.5.0", minimumOS: String = "26.0",
                         signature: Data? = nil, key: Curve25519.Signing.PrivateKey? = nil) throws -> InstallerRelease {
        try InstallerRelease(build: build, shortVersion: version, minimumOS: minimumOS,
                             archiveURL: archiveURL, archiveLength: 1234,
                             signature: signature ?? self.signature,
                             verificationKey: key?.publicKey.rawRepresentation ?? Data(repeating: 0, count: 32))
    }

    private func makeSignedArchive(in root: URL, build: String, version: String,
                                   key: Curve25519.Signing.PrivateKey) throws -> (InstallerRelease, URL) {
        let app = root.appending(path: "source/Bridgeplay.app", directoryHint: .isDirectory)
        try writeSignedApp(at: app, version: version, build: build)

        let archive = root.appending(path: "Bridgeplay.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
        let data = try Data(contentsOf: archive)
        let signature = try key.signature(for: data)
        let release = try InstallerRelease(
            build: Int(build)!, shortVersion: version, minimumOS: "26.0", archiveURL: archiveURL,
            archiveLength: Int64(data.count), signature: signature,
            verificationKey: key.publicKey.rawRepresentation
        )
        return (release, archive)
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func detectsFreshInstallWithoutMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        let state = try service(at: destination).state(for: release())
        #expect(state == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func identifiesAnAvailableUpdateAndKeepsUnrelatedDataUntouched() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: destination)
        let save = root.appending(path: "save.dat")
        let config = root.appending(path: "default.conf")
        try Data("save".utf8).write(to: save)
        try Data("user override".utf8).write(to: config)
        let state = try service(at: destination).state(for: release())
        guard case .updateAvailable(let build, let version, _) = state else {
            Issue.record("Expected an available update; received \(state).")
            return
        }
        #expect(build == 34)
        #expect(version == "3.4.1")
        #expect(try Data(contentsOf: save) == Data("save".utf8))
        #expect(try Data(contentsOf: config) == Data("user override".utf8))
    }

    @Test func updatesByBuildWhenPublicVersionReturnsToZeroSeries() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Applications/Bridgeplay.app", directoryHint: .isDirectory)
        try writeSignedApp(at: destination, version: "3.5.0", build: "43")
        let key = Curve25519.Signing.PrivateKey()
        let (offered, archive) = try makeSignedArchive(in: root, build: "44", version: "0.7.0", key: key)
        let installer = service(at: destination)
        guard case .updateAvailable = try installer.state(for: offered) else {
            Issue.record("A higher build must update even when its public version is lower.")
            return
        }
        try installer.install(release: offered, archive: archive)
        #expect(try installer.state(for: offered) == .upToDate(build: 44, version: "0.7.0"))
    }

    @Test func treatsSameBuildAndVersionAsCurrent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: destination, version: "3.5.0", build: "35")
        #expect(try service(at: destination).state(for: release()) == .upToDate(build: 35, version: "3.5.0"))
    }

    @Test func rejectsDowngradesAndInconsistentInstalledVersion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: destination, version: "3.6.0", build: "36")
        do {
            _ = try service(at: destination).state(for: release())
            Issue.record("An older release must not replace a newer installed build.")
        } catch let error as InstallerError {
            guard case .downgrade(current: 36, offered: 35) = error else {
                Issue.record("Expected downgrade, received \(error).")
                return
            }
        }
        try writeApp(at: destination, version: "3.5.1", build: "35")
        do {
            _ = try service(at: destination).state(for: release())
            Issue.record("A version/build mismatch must not be reported as current.")
        } catch let error as InstallerError {
            guard case .invalidInstallation = error else {
                Issue.record("Expected invalidInstallation, received \(error).")
                return
            }
        }
    }

    @Test func refusesAnUnrelatedApplicationAtDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: destination, identifier: "com.example.other")
        do {
            _ = try service(at: destination).state(for: release())
            Issue.record("An unrelated app at the destination must be preserved.")
        } catch let error as InstallerError {
            guard case .otherAppInstalled("com.example.other") = error else {
                Issue.record("Expected otherAppInstalled, received \(error).")
                return
            }
        }
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "Contents/Info.plist").path))
    }

    @Test func refusesSymbolicLinkAtDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "real-app", directoryHint: .isDirectory)
        try writeApp(at: target)
        let destination = root.appending(path: "Bridgeplay.app")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        do {
            _ = try service(at: destination).state(for: release())
            Issue.record("The install target must not follow a symbolic link.")
        } catch let error as InstallerError {
            guard case .invalidDestination = error else {
                Issue.record("Expected invalidInstallation, received \(error).")
                return
            }
        }
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "Contents/Info.plist").path))
    }

    @Test func refusesDanglingSymbolicLinkAtDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "missing-app", directoryHint: .isDirectory)
        let destination = root.appending(path: "Bridgeplay.app")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)

        #expect(throws: InstallerError.self) {
            try service(at: destination).state(for: release())
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == target.path)
    }

    @Test func rejectsUnsupportedSystemBeforeTouchingDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        #expect(throws: InstallerError.self) {
            try service(at: destination).state(for: release(minimumOS: "99.0"))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func installsSignedArchiveIntoAnIsolatedDirectoryAndPreservesSiblingData() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let (release, archive) = try makeSignedArchive(in: root, build: "35", version: "3.5.0", key: key)
        let save = root.appending(path: "saves/slot.sav")
        let config = root.appending(path: "Application Support/bridgeplay/gamefixes/default.conf")
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("save survives".utf8).write(to: save)
        try Data("user settings survive".utf8).write(to: config)

        let destination = root.appending(path: "Applications/Bridgeplay.app", directoryHint: .isDirectory)
        let installed = try service(at: destination).install(release: release, archive: archive)
        #expect(installed == destination)
        #expect(try service(at: destination).state(for: release) == .upToDate(build: 35, version: "3.5.0"))
        #expect(try Data(contentsOf: save) == Data("save survives".utf8))
        #expect(try Data(contentsOf: config) == Data("user settings survive".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Applications/.Bridgeplay.app.previous").path))
    }

    @Test func validatesBeforeReplacingAnExistingApp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let (release, archive) = try makeSignedArchive(in: root, build: "35", version: "3.5.0", key: key)
        let destination = root.appending(path: "Applications/Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: destination, version: "3.4.1", build: "34")
        let oldData = try Data(contentsOf: destination.appending(path: "Contents/Info.plist"))

        var tampered = try Data(contentsOf: archive)
        tampered[tampered.startIndex] ^= 0x1
        try tampered.write(to: archive)
        do {
            try service(at: destination).install(release: release, archive: archive)
            Issue.record("A changed archive must be rejected before the installed app is moved.")
        } catch let error as InstallerError {
            guard case .signatureMismatch = error else {
                Issue.record("Expected signatureMismatch, received \(error).")
                return
            }
        }

        #expect(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")) == oldData)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Applications/.Bridgeplay.app.previous").path))
    }

    @Test func rejectsWrongSignedBundleAndKeepsExistingInstallation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let (release, archive) = try makeSignedArchive(in: root, build: "36", version: "3.6.0", key: key)
        let destination = root.appending(path: "Applications/Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: destination, version: "3.4.1", build: "34")
        let oldData = try Data(contentsOf: destination.appending(path: "Contents/Info.plist"))
        let expectedRelease = try InstallerRelease(
            build: 35, shortVersion: "3.5.0", minimumOS: "26.0", archiveURL: archiveURL,
            archiveLength: release.archiveLength, signature: release.signature,
            verificationKey: key.publicKey.rawRepresentation
        )

        do {
            try service(at: destination).install(release: expectedRelease, archive: archive)
            Issue.record("A validly signed app with a mismatching build/version must be rejected.")
        } catch let error as InstallerError {
            guard case .appValidation = error else {
                Issue.record("Expected appValidation, received \(error).")
                return
            }
        }
        #expect(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")) == oldData)
    }

    @Test func successfulUpdateRetainsVerifiedPreviousAppAndPersistentLockFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let (release, archive) = try makeSignedArchive(in: root, build: "35", version: "3.5.0", key: key)
        let destination = root.appending(path: "Applications/Bridgeplay.app", directoryHint: .isDirectory)
        try writeSignedApp(at: destination, version: "3.4.1", build: "34")
        let save = root.appending(path: "saves/slot.sav")
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep this save".utf8).write(to: save)

        try service(at: destination).install(release: release, archive: archive)

        let parent = root.appending(path: "Applications", directoryHint: .isDirectory)
        let backup = parent.appending(path: ".Bridgeplay.app.previous", directoryHint: .isDirectory)
        let lockURL = parent.appending(path: ".Bridgeplay.app.install.lock")
        #expect(try installedBuild(at: destination) == "35")
        #expect(try installedBuild(at: backup) == "34")
        #expect(FileManager.default.fileExists(atPath: lockURL.path))
        let lockMode = try FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions] as? NSNumber
        #expect(lockMode?.intValue == 0o644)
        #expect(try Data(contentsOf: save) == Data("keep this save".utf8))
    }

    @Test func rotatesReadOnlyPreviousBundleWithoutDeletingItsContents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let (release, archive) = try makeSignedArchive(in: root, build: "35", version: "3.5.0", key: key)
        let parent = root.appending(path: "Applications", directoryHint: .isDirectory)
        let destination = parent.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        let backup = parent.appending(path: ".Bridgeplay.app.previous", directoryHint: .isDirectory)
        try writeSignedApp(at: destination, version: "3.4.1", build: "34")
        try writeSignedApp(at: backup, version: "3.3.0", build: "33")
        let contents = backup.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: contents.path)
        defer {
            for entry in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
                if entry.lastPathComponent.hasPrefix(".Bridgeplay.app.previous-") {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.appending(path: "Contents").path)
                }
            }
        }

        try service(at: destination).install(release: release, archive: archive)

        #expect(try installedBuild(at: destination) == "35")
        #expect(try installedBuild(at: backup) == "34")
        let retired = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".Bridgeplay.app.previous-") }
        #expect(retired.count == 1)
        let preserved = try #require(retired.first)
        #expect(try installedBuild(at: preserved) == "33")
        try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", preserved.path])
    }

    @Test func recoversPreviousBundleBeforeUpdatingAndPreservesUserData() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let (release, _) = try makeSignedArchive(in: root, build: "35", version: "3.5.0", key: key)
        let parent = root.appending(path: "Applications", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        let backup = parent.appending(path: ".Bridgeplay.app.previous", directoryHint: .isDirectory)
        try writeSignedApp(at: backup, version: "3.4.1", build: "34")
        let save = root.appending(path: "saves/slot.sav")
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("recovery must keep saves".utf8).write(to: save)

        try service(at: destination).recoverIfNeeded()

        guard case .updateAvailable(let build, let version, _) = try service(at: destination).state(for: release) else {
            Issue.record("Recovery must restore the previous Bridgeplay build without installing the offered release.")
            return
        }
        #expect(build == 34)
        #expect(version == "3.4.1")
        #expect(try installedBuild(at: destination) == "34")
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(try Data(contentsOf: save) == Data("recovery must keep saves".utf8))
    }

    @Test func rejectsInstallWhileAnotherProcessHoldsPersistentLock() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let (release, archive) = try makeSignedArchive(in: root, build: "35", version: "3.5.0", key: key)
        let destination = root.appending(path: "Applications/Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: destination, version: "3.4.1", build: "34")
        let oldInfo = try Data(contentsOf: destination.appending(path: "Contents/Info.plist"))
        let lockURL = root.appending(path: "Applications/.Bridgeplay.app.install.lock")
        let lockPath = lockURL.path
        let creatorDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        #expect(creatorDescriptor >= 0)
        guard creatorDescriptor >= 0 else { return }
        close(creatorDescriptor)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: lockPath)
        let descriptor = open(lockPath, O_RDONLY | O_NOFOLLOW)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

        do {
            try service(at: destination).install(release: release, archive: archive)
            Issue.record("An installer must not proceed while another installer holds the lock.")
        } catch let error as InstallerError {
            guard case .installLocked = error else {
                Issue.record("Expected installLocked, received \(error).")
                return
            }
        }

        #expect(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")) == oldInfo)
        #expect(FileManager.default.fileExists(atPath: lockPath))
    }

    @Test func readOnlyDestinationDoesNotDeleteInstalledAppOrUserData() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let (release, archive) = try makeSignedArchive(in: root, build: "35", version: "3.5.0", key: key)
        let parent = root.appending(path: "readonly", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: destination, version: "3.4.1", build: "34")
        let oldInfo = try Data(contentsOf: destination.appending(path: "Contents/Info.plist"))
        let save = root.appending(path: "save.dat")
        try Data("unchanged".utf8).write(to: save)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }

        do {
            try service(at: destination).install(release: release, archive: archive)
            Issue.record("A read-only install parent must reject replacement.")
        } catch let error as InstallerError {
            guard case .writeFailure = error else {
                Issue.record("Expected writeFailure, received \(error).")
                return
            }
        }

        #expect(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")) == oldInfo)
        #expect(try Data(contentsOf: save) == Data("unchanged".utf8))
    }

    @Test func injectedProcessGatePreventsAnyInstallMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let (release, archive) = try makeSignedArchive(in: root, build: "35", version: "3.5.0", key: key)
        let destination = root.appending(path: "Applications/Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: destination, version: "3.4.1", build: "34")
        let oldInfo = try Data(contentsOf: destination.appending(path: "Contents/Info.plist"))

        do {
            try service(at: destination, gate: { throw InstallerError.appIsRunning })
                .install(release: release, archive: archive)
            Issue.record("The process gate must prevent app replacement.")
        } catch let error as InstallerError {
            guard case .appIsRunning = error else {
                Issue.record("Expected appIsRunning, received \(error).")
                return
            }
        }

        #expect(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")) == oldInfo)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Applications/.Bridgeplay.app.previous").path))
    }

    @Test func restoresOriginalAppIfStagedBundleDisappearsDuringReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let (release, archive) = try makeSignedArchive(in: root, build: "35", version: "3.5.0", key: key)
        let parent = root.appending(path: "Applications", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeSignedApp(at: destination, version: "3.4.1", build: "34")
        let oldInfo = try Data(contentsOf: destination.appending(path: "Contents/Info.plist"))
        let service = InstallerService(destination: destination, ensureAppIsClosed: {
            let stages = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".BridgeplayInstaller-") }
            guard let stagedApp = stages.first?.appending(path: "payload/Bridgeplay.app") else {
                throw InstallerError.appValidation("The staged app fixture is missing.")
            }
            try FileManager.default.removeItem(at: stagedApp)
        })

        do {
            try service.install(release: release, archive: archive)
            Issue.record("A vanished staged app must fail and restore the previous install.")
        } catch let error as InstallerError {
            guard case .replacementFailure = error else {
                Issue.record("Expected replacementFailure, received \(error).")
                return
            }
        }

        #expect(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")) == oldInfo)
        #expect(!FileManager.default.fileExists(atPath: parent.appending(path: ".Bridgeplay.app.previous").path))
    }

    @Test func onlyBridgeplaysOwnUpdaterBlocksInstall() {
        #expect(InstallerService.blocksInstall("/Applications/Bridgeplay.app/Contents/MacOS/BridgeplayApp"))
        #expect(InstallerService.blocksInstall("/Applications/Bridgeplay.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"))
        #expect(InstallerService.blocksInstall("/Users/a/Library/Caches/com.bridgeplay.Bridgeplay/org.sparkle-project.Sparkle/Launcher/X/Autoupdate"))
        #expect(!InstallerService.blocksInstall("/Applications/OpenUsage.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"))
        #expect(!InstallerService.blocksInstall("/Applications/Bridgeplay.app/Contents/MacOS/Helper"))
    }

    @Test func idleBackgroundCheckDoesNotBlockInstall() {
        let app = "/Applications/Bridgeplay.app/Contents/MacOS/BridgeplayApp"
        #expect(!InstallerService.blocksInstall(app, arguments: { ["BridgeplayApp", "--background-check"] }))
        #expect(InstallerService.blocksInstall(app, arguments: { ["BridgeplayApp"] }))
        #expect(InstallerService.blocksInstall(app, arguments: { [app, "--install-into-steam", "--unattended"] }))
        #expect(InstallerService.blocksInstall(app, arguments: { ["BridgeplayApp", "--background-check", "x"] }))
        #expect(InstallerService.blocksInstall(app, arguments: { nil }))
    }

    @Test func readsProcessArguments() {
        var buffer = withUnsafeBytes(of: Int32(2)) { Array($0) }
        buffer += Array("/x/BridgeplayApp".utf8) + [0, 0, 0, 0]
        buffer += Array("BridgeplayApp".utf8) + [0] + Array("--background-check".utf8) + [0]
        buffer += Array("HOME=/Users/a".utf8) + [0]
        #expect(InstallerService.parseProcessArguments(buffer) == ["BridgeplayApp", "--background-check"])
        #expect(InstallerService.parseProcessArguments(Array(buffer.prefix(30))) == nil)
        #expect(InstallerService.arguments(of: getpid())?.first == CommandLine.arguments.first)
    }

    @Test func installWaitsForTheBackgroundChecksInstall() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        guard case .held(let shared) = AppInUseLock.take(appBundle: app) else {
            Issue.record("The background check's lock was not taken.")
            return
        }
        do {
            _ = try InstallLock(parent: root)
            Issue.record("The installer took its lock while the background check was installing.")
        } catch InstallerError.installLocked {
        } catch { Issue.record("Expected installLocked, received \(error).") }
        guard case .held(let second) = AppInUseLock.take(appBundle: app) else {
            Issue.record("A second shared holder was refused.")
            return
        }
        second.release()
        shared.release()
        let exclusive = try InstallLock(parent: root)
        guard case .updating = AppInUseLock.take(appBundle: app) else {
            Issue.record("The background check did not see the update in progress.")
            return
        }
        exclusive.release()
        guard case .held(let after) = AppInUseLock.take(appBundle: app) else {
            Issue.record("The lock was not free after the update.")
            return
        }
        after.release()
    }

    @Test func logRedactsHomeDirectory() {
        #expect(InstallerLog.redact(NSHomeDirectory() + "/Downloads/x") == "~/Downloads/x")
    }
}
