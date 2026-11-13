import CryptoKit
import Darwin
import Foundation

@main
struct NativeInstallerCoreSmoke {
    private static let archiveURL = URL(
        string: "https://github.com/raymondchins/Bridgeplay/releases/download/v3.5.0/Bridgeplay.zip"
    )!

    static func main() {
        do {
            try run()
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeFailure("Pass one temporary work directory.")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try testAppcastValidation()
        print("PASS appcast fields, URL, size, version, hardware, and XML validation")

        let key = Curve25519.Signing.PrivateKey()
        let bytes = Data("signed fixture".utf8)
        let signature = try key.signature(for: bytes)
        try InstallerRelease.verify(bytes, signature: signature, publicKey: key.publicKey.rawRepresentation)
        try expectInstallerError("tampered signature") {
            try InstallerRelease.verify(Data("tampered fixture".utf8), signature: signature,
                                        publicKey: key.publicKey.rawRepresentation)
        } matches: {
            if case .signatureMismatch = $0 { return true }
            return false
        }
        print("PASS Ed25519 signature accepts authentic bytes and rejects tampering")

        let (release35, archive35) = try makeSignedArchive(in: root, build: "35", version: "3.5.0", key: key)
        try testDetectionAndInstall(release: release35, archive: archive35, key: key, root: root)
        try testRejectedReplacement(release: release35, archive: archive35, root: root)
        try testLockAndReadonlyLock(release: release35, archive: archive35, root: root)
        try testReadonlyParent(release: release35, archive: archive35, root: root)
        try testProcessGate(release: release35, archive: archive35, root: root)
        try testRollback(release: release35, archive: archive35, root: root)
        try testBackupRecovery(release: release35, root: root)
        try testDanglingSymlink(root: root)

        print("PASS isolated fresh install, update detection, user-data preservation, backup recovery, rollback, lock, and destination checks")
        print("PASS all native installer core smoke checks")
    }

    private static func testAppcastValidation() throws {
        let signature = Data(repeating: 0xA5, count: 64).base64EncodedString()
        let valid = appcast(signature: signature, minimumOS: "26.0.1")
        let release = try InstallerRelease.parse(appcast: valid)
        try require(release.build == 35 && release.shortVersion == "3.5.0", "parsed build and release version")
        try require(release.minimumOS == "26.0.1", "three-component minimum OS version")
        try require(release.archiveLength == 512 && release.archiveURL == archiveURL, "archive metadata")

        _ = try InstallerRelease.parse(appcast: appcast(signature: signature, minimumOS: "26.0"))
        try expectInstallerError("wrong archive host") {
            _ = try InstallerRelease.parse(appcast: appcast(signature: signature,
                                                            archive: "https://github.com.attacker.invalid/raymondchins/Bridgeplay/releases/download/v3.5.0/Bridgeplay.zip"))
        }
        try expectInstallerError("wrong archive path") {
            _ = try InstallerRelease.parse(appcast: appcast(signature: signature,
                                                            archive: "https://github.com/raymondchins/Bridgeplay/releases/download/v3.5.0/Other.zip"))
        }
        try expectInstallerError("oversized archive length") {
            _ = try InstallerRelease.parse(appcast: appcast(signature: signature, length: "1073741825"))
        }
        try expectInstallerError("invalid version") {
            _ = try InstallerRelease.parse(appcast: appcast(signature: signature, version: "3.release"))
        }
        try expectInstallerError("four-component OS version") {
            _ = try InstallerRelease.parse(appcast: appcast(signature: signature, minimumOS: "26.0.1.1"))
        }
        try expectInstallerError("wrong hardware") {
            _ = try InstallerRelease.parse(appcast: appcast(signature: signature, hardware: "x86_64"))
        }
        try expectInstallerError("missing hardware") {
            _ = try InstallerRelease.parse(appcast: appcast(signature: signature, hardware: nil))
        }
        try expectInstallerError("DTD") {
            _ = try InstallerRelease.parse(appcast: Data("<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss>&x;</rss>".utf8))
        }
        try expectInstallerError("oversized feed") {
            _ = try InstallerRelease.parse(appcast: Data(repeating: 0x20, count: 256_001))
        }
        try testChannelItems(signature: signature)
        try testSignedAndCatchUpFeeds()
    }

    /// A channel item, whatever its value, is never installed; the stable item after it is.
    private static func testChannelItems(signature: String) throws {
        let beta = channelItem(channel: "beta", build: "90", version: "3.6.0", signature: signature)
        for channel in ["beta", "beta-critical", "", "other"] {
            let first = channelItem(channel: channel, build: "90", version: "3.6.0", signature: signature)
            let release = try InstallerRelease.parse(appcast: appcast(signature: signature, preceding: first))
            try require(release.build == 35 && release.shortVersion == "3.5.0", "stable item after a '\(channel)' item")
        }
        let twoBetas = try InstallerRelease.parse(appcast: appcast(signature: signature, preceding: beta + beta))
        try require(twoBetas.build == 35, "stable item after two channel items")
        try expectInstallerError("only channel items") {
            _ = try InstallerRelease.parse(appcast: appcast(signature: signature, channel: "beta"))
        }
        try expectInstallerError("invalid stable item after a channel item") {
            _ = try InstallerRelease.parse(appcast: appcast(signature: signature, version: "3.release", preceding: beta))
        }
        try expectInstallerError("x86_64 stable item after a channel item") {
            _ = try InstallerRelease.parse(appcast: appcast(signature: signature, hardware: "x86_64", preceding: beta))
        }
        print("PASS channel items are skipped; a feed with only channel items is refused")
    }

    /// Feeds signed by Sparkle's generate_appcast (throwaway key), with and without the
    /// bridgeplay:containsBetas element.
    private static func testSignedAndCatchUpFeeds() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "fixtures/appcast")
        for name in ["signed.xml", "signed-betas-empty.xml", "signed-betas-list.xml"] {
            let data = try Data(contentsOf: folder.appending(path: name))
            try require(String(decoding: data, as: UTF8.self).contains("sparkle-signatures"), "\(name) is signed")
            let release = try InstallerRelease.parse(appcast: data)
            try require(release.build == 35 && release.shortVersion == "3.5.0" && release.minimumOS == "26.0",
                        "\(name) fields")
            try require(release.archiveURL == archiveURL && release.signature.count == 64, "\(name) enclosure")
        }
        for text in ["", "81-85,87"] {
            let xml = String(decoding: appcast(signature: Data(repeating: 0xA5, count: 64).base64EncodedString()), as: UTF8.self)
                .replacingOccurrences(of: "<enclosure", with: "<bridgeplay:containsBetas>\(text)</bridgeplay:containsBetas><enclosure")
                .replacingOccurrences(of: "<rss ", with: "<rss xmlns:bridgeplay=\"https://bridgeplay.dev/ns/appcast/1\" ")
            try require(try InstallerRelease.parse(appcast: Data(xml.utf8)).build == 35, "containsBetas '\(text)'")
        }
        print("PASS Sparkle-signed feeds and the containsBetas element parse as before")
    }

    private static func channelItem(channel: String, build: String, version: String, signature: String) -> String {
        """
        <item>
            <sparkle:channel>\(channel)</sparkle:channel>
            <sparkle:version>\(build)</sparkle:version>
            <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure url="https://github.com/raymondchins/Bridgeplay/releases/download/v\(version)/Bridgeplay.zip"
                       length="512" type="application/octet-stream" sparkle:edSignature="\(signature)" />
        </item>

        """
    }

    private static func appcast(
        signature: String,
        minimumOS: String = "26.0",
        archive: String = "https://github.com/raymondchins/Bridgeplay/releases/download/v3.5.0/Bridgeplay.zip",
        length: String = "512",
        version: String = "3.5.0",
        hardware: String? = "arm64",
        channel: String? = nil,
        preceding: String = ""
    ) -> Data {
        let channelElement = channel.map { "<sparkle:channel>\($0)</sparkle:channel>" } ?? ""
        let hardwareElement = hardware.map { "<sparkle:hardwareRequirements>\($0)</sparkle:hardwareRequirements>" } ?? ""
        let xml = """
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>\(preceding)<item>
            \(channelElement)
            <sparkle:version>35</sparkle:version>
            <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>\(minimumOS)</sparkle:minimumSystemVersion>
            \(hardwareElement)
            <enclosure url="\(archive)" length="\(length)" type="application/octet-stream"
                       sparkle:edSignature="\(signature)" />
          </item></channel>
        </rss>
        """
        return Data(xml.utf8)
    }

    private static func testDetectionAndInstall(
        release: InstallerRelease,
        archive: URL,
        key: Curve25519.Signing.PrivateKey,
        root: URL
    ) throws {
        let directory = root.appending(path: "install-flow", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        let service = InstallerService(destination: destination, ensureAppIsClosed: {})
        try require(try service.state(for: release) == .notInstalled, "new-install detection")

        let save = directory.appending(path: "saves/slot.sav")
        let config = directory.appending(path: "Application Support/bridgeplay/gamefixes/default.conf")
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("save survives".utf8).write(to: save)
        try Data("user config survives".utf8).write(to: config)

        try service.install(release: release, archive: archive)
        try require(try service.state(for: release) == .upToDate(build: 35, version: "3.5.0"), "installed version is current")
        try require(try Data(contentsOf: save) == Data("save survives".utf8), "save remains untouched")
        try require(try Data(contentsOf: config) == Data("user config survives".utf8), "config remains untouched")
        let lockMode = try FileManager.default.attributesOfItem(
            atPath: directory.appending(path: ".Bridgeplay.app.install.lock").path
        )[.posixPermissions] as? NSNumber
        try require(lockMode?.intValue == 0o644, "persistent lock is readable by other macOS accounts")

        let zeroVersionRoot = root.appending(path: "zero-version-release", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: zeroVersionRoot, withIntermediateDirectories: true)
        let (zeroVersion, zeroArchive) = try makeSignedArchive(in: zeroVersionRoot, build: "36", version: "0.7.0", key: key)
        guard case .updateAvailable = try service.state(for: zeroVersion) else {
            throw SmokeFailure("A higher build with a lower public version must remain eligible.")
        }
        try service.install(release: zeroVersion, archive: zeroArchive)
        try require(try service.state(for: zeroVersion) == .upToDate(build: 36, version: "0.7.0"), "build ordering survives public version reset")
        print("PASS higher build updates from 3.x to 0.x public version")

        let updateDirectory = root.appending(path: "update-flow", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: updateDirectory, withIntermediateDirectories: true)
        let updateDestination = updateDirectory.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeSignedApp(at: updateDestination, version: "3.4.1", build: "34")
        let updateService = InstallerService(destination: updateDestination, ensureAppIsClosed: {})
        guard case .updateAvailable(let currentBuild, let currentVersion, _) = try updateService.state(for: release) else {
            throw SmokeFailure("Existing Bridgeplay did not report an available update.")
        }
        try require(currentBuild == 34 && currentVersion == "3.4.1", "update detection")

        let olderRelease = try makeRelease(build: 33, version: "3.3.0", archive: archive, key: key)
        try expectInstallerError("downgrade") {
            _ = try updateService.state(for: olderRelease)
        } matches: {
            if case .downgrade(current: 34, offered: 33) = $0 { return true }
            return false
        }
        let unsupported = try makeRelease(build: 35, version: "3.5.0", minimumOS: "99.0", archive: archive, key: key)
        try expectInstallerError("minimum OS") {
            _ = try updateService.state(for: unsupported)
        } matches: {
            if case .unsupportedSystem(minimum: "99.0") = $0 { return true }
            return false
        }

        try updateService.install(release: release, archive: archive)
        let previousApp = updateDirectory.appending(path: ".Bridgeplay.app.previous", directoryHint: .isDirectory)
        try require(try installedBuild(at: updateDestination) == "35", "update installs offered build")
        try require(try installedBuild(at: previousApp) == "34", "update retains previous signed build")

        let unrelatedDirectory = root.appending(path: "unrelated-app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)
        let unrelated = unrelatedDirectory.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: unrelated, identifier: "com.example.other", version: "1.0", build: "1")
        let unrelatedService = InstallerService(destination: unrelated, ensureAppIsClosed: {})
        try expectInstallerError("unrelated app") {
            _ = try unrelatedService.state(for: release)
        } matches: {
            if case .otherAppInstalled("com.example.other") = $0 { return true }
            return false
        }
    }

    private static func testRejectedReplacement(release: InstallerRelease, archive: URL, root: URL) throws {
        let directory = root.appending(path: "reject-replacement", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: destination, version: "3.4.1", build: "34")
        let originalInfo = try Data(contentsOf: destination.appending(path: "Contents/Info.plist"))
        let tampered = directory.appending(path: "tampered.zip")
        var bytes = try Data(contentsOf: archive)
        bytes[bytes.startIndex] ^= 0x1
        try bytes.write(to: tampered)

        let service = InstallerService(destination: destination, ensureAppIsClosed: {})
        try expectInstallerError("tampered archive replacement") {
            try service.install(release: release, archive: tampered)
        } matches: {
            if case .signatureMismatch = $0 { return true }
            return false
        }
        try require(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")) == originalInfo,
                    "signature failure leaves prior app intact")
    }

    private static func testLockAndReadonlyLock(release: InstallerRelease, archive: URL, root: URL) throws {
        let directory = root.appending(path: "locked-install", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: destination, version: "3.4.1", build: "34")
        let originalInfo = try Data(contentsOf: destination.appending(path: "Contents/Info.plist"))
        let lockURL = directory.appending(path: ".Bridgeplay.app.install.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SmokeFailure("Could not create lock fixture: \(String(cString: strerror(errno)))") }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        try require(flock(fd, LOCK_EX | LOCK_NB) == 0, "fixture obtains install lock")
        let service = InstallerService(destination: destination, ensureAppIsClosed: {})
        try expectInstallerError("concurrent installer lock") {
            try service.install(release: release, archive: archive)
        } matches: {
            if case .installLocked = $0 { return true }
            return false
        }
        try require(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")) == originalInfo,
                    "locked install leaves prior app intact")

        let readonlyDirectory = root.appending(path: "readonly-lock", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: readonlyDirectory, withIntermediateDirectories: true)
        let readonlyDestination = readonlyDirectory.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: readonlyDestination, version: "3.4.1", build: "34")
        let readonlyLock = readonlyDirectory.appending(path: ".Bridgeplay.app.install.lock")
        try Data().write(to: readonlyLock)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readonlyLock.path)
        let readonlyFD = open(readonlyLock.path, O_RDONLY | O_NOFOLLOW)
        guard readonlyFD >= 0 else { throw SmokeFailure("Could not open shared lock read-only.") }
        defer {
            flock(readonlyFD, LOCK_UN)
            close(readonlyFD)
        }
        try require(flock(readonlyFD, LOCK_EX | LOCK_NB) == 0, "another macOS account can hold an exclusive read-only lock")
        let readonlyInfo = try Data(contentsOf: readonlyDestination.appending(path: "Contents/Info.plist"))
        let readonlyService = InstallerService(destination: readonlyDestination, ensureAppIsClosed: {})
        try expectInstallerError("read-only persistent lock") {
            try readonlyService.install(release: release, archive: archive)
        } matches: {
            if case .installLocked = $0 { return true }
            return false
        }
        try require(try Data(contentsOf: readonlyDestination.appending(path: "Contents/Info.plist")) == readonlyInfo,
                    "read-only lock leaves prior app intact")
    }

    private static func testReadonlyParent(release: InstallerRelease, archive: URL, root: URL) throws {
        guard geteuid() != 0 else {
            print("SKIP read-only parent: smoke runner is root and bypasses POSIX write permissions")
            return
        }
        let directory = root.appending(path: "readonly-parent", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: destination, version: "3.4.1", build: "34")
        let originalInfo = try Data(contentsOf: destination.appending(path: "Contents/Info.plist"))
        let save = root.appending(path: "readonly-save.dat")
        try Data("untouched".utf8).write(to: save)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        let service = InstallerService(destination: destination, ensureAppIsClosed: {})
        try expectInstallerError("read-only install parent") {
            try service.install(release: release, archive: archive)
        } matches: {
            if case .writeFailure = $0 { return true }
            return false
        }
        try require(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")) == originalInfo,
                    "read-only parent leaves prior app intact")
        try require(try Data(contentsOf: save) == Data("untouched".utf8), "read-only install leaves save intact")
    }

    private static func testProcessGate(release: InstallerRelease, archive: URL, root: URL) throws {
        let directory = root.appending(path: "running-app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeApp(at: destination, version: "3.4.1", build: "34")
        let originalInfo = try Data(contentsOf: destination.appending(path: "Contents/Info.plist"))
        let service = InstallerService(destination: destination, ensureAppIsClosed: {
            throw InstallerError.appIsRunning
        })
        try expectInstallerError("running app process gate") {
            try service.install(release: release, archive: archive)
        } matches: {
            if case .appIsRunning = $0 { return true }
            return false
        }
        try require(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")) == originalInfo,
                    "process gate leaves prior app intact")
    }

    private static func testRollback(release: InstallerRelease, archive: URL, root: URL) throws {
        let directory = root.appending(path: "rollback", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        try writeSignedApp(at: destination, version: "3.4.1", build: "34")
        let originalInfo = try Data(contentsOf: destination.appending(path: "Contents/Info.plist"))
        let service = InstallerService(destination: destination, ensureAppIsClosed: {
            let stage = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".BridgeplayInstaller-") }
            guard let stagedApp = stage?.appending(path: "payload/Bridgeplay.app") else {
                throw SmokeFailure("Validated staging directory was not found.")
            }
            try FileManager.default.removeItem(at: stagedApp)
        })
        try expectInstallerError("replacement rollback") {
            try service.install(release: release, archive: archive)
        } matches: {
            if case .replacementFailure = $0 { return true }
            return false
        }
        try require(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")) == originalInfo,
                    "failed replacement restores previous app")
        try require(!FileManager.default.fileExists(atPath: directory.appending(path: ".Bridgeplay.app.previous").path),
                    "rollback consumes recovery backup only after restoring it")
    }

    private static func testBackupRecovery(release: InstallerRelease, root: URL) throws {
        let directory = root.appending(path: "backup-recovery", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "Bridgeplay.app", directoryHint: .isDirectory)
        let backup = directory.appending(path: ".Bridgeplay.app.previous", directoryHint: .isDirectory)
        try writeSignedApp(at: backup, version: "3.4.1", build: "34")
        let save = directory.appending(path: "saves/slot.sav")
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("survive backup recovery".utf8).write(to: save)
        let service = InstallerService(destination: destination, ensureAppIsClosed: {})
        try service.recoverIfNeeded()
        guard case .updateAvailable(let build, let version, _) = try service.state(for: release) else {
            throw SmokeFailure("Recovery must restore the previous app without installing the offered release.")
        }
        try require(build == 34 && version == "3.4.1", "recovered prior build detected as update available")
        try require(try installedBuild(at: destination) == "34", "recovered previous app is restored")
        try require(!FileManager.default.fileExists(atPath: backup.path), "restored backup path is cleared")
        try require(try Data(contentsOf: save) == Data("survive backup recovery".utf8), "backup recovery preserves save")
    }

    private static func testDanglingSymlink(root: URL) throws {
        let directory = root.appending(path: "dangling-symlink", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "Bridgeplay.app")
        let target = directory.appending(path: "target-does-not-exist")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        let release = try InstallerRelease(
            build: 35,
            shortVersion: "3.5.0",
            minimumOS: "1.0",
            archiveURL: archiveURL,
            archiveLength: 1,
            signature: Data(repeating: 0, count: 64)
        )
        let service = InstallerService(destination: destination, ensureAppIsClosed: {})
        try expectInstallerError("dangling destination symlink") {
            _ = try service.state(for: release)
        } matches: {
            if case .invalidDestination = $0 { return true }
            return false
        }
        try require(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == target.path,
                    "dangling destination link remains untouched")
    }

    private static func makeSignedArchive(
        in root: URL,
        build: String,
        version: String,
        key: Curve25519.Signing.PrivateKey
    ) throws -> (InstallerRelease, URL) {
        let source = root.appending(path: "source-\(build)/Bridgeplay.app", directoryHint: .isDirectory)
        try writeSignedApp(at: source, version: version, build: build)
        let archive = root.appending(path: "Bridgeplay-\(build).zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, archive.path])
        let bytes = try Data(contentsOf: archive)
        let release = try InstallerRelease(
            build: Int(build)!,
            shortVersion: version,
            minimumOS: "1.0",
            archiveURL: archiveURL,
            archiveLength: Int64(bytes.count),
            signature: try key.signature(for: bytes),
            verificationKey: key.publicKey.rawRepresentation
        )
        return (release, archive)
    }

    private static func makeRelease(
        build: Int,
        version: String,
        minimumOS: String = "1.0",
        archive: URL,
        key: Curve25519.Signing.PrivateKey
    ) throws -> InstallerRelease {
        let bytes = try Data(contentsOf: archive)
        return try InstallerRelease(
            build: build,
            shortVersion: version,
            minimumOS: minimumOS,
            archiveURL: archiveURL,
            archiveLength: Int64(bytes.count),
            signature: try key.signature(for: bytes),
            verificationKey: key.publicKey.rawRepresentation
        )
    }

    private static func writeApp(
        at url: URL,
        identifier: String = InstallerService.bundleIdentifier,
        version: String,
        build: String
    ) throws {
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

    private static func writeSignedApp(at url: URL, version: String, build: String) throws {
        try writeApp(at: url, version: version, build: build)
        let executable = url.appending(path: "Contents/MacOS/BridgeplayApp")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--deep", url.path])
        try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", url.path])
    }

    private static func installedBuild(at url: URL) throws -> String? {
        let data = try Data(contentsOf: url.appending(path: "Contents/Info.plist"))
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        return (propertyList as? [String: Any])?["CFBundleVersion"] as? String
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SmokeFailure("\(executable) exited with status \(process.terminationStatus).")
        }
    }

    private static func expectInstallerError(
        _ name: String,
        operation: () throws -> Void,
        matches: (InstallerError) -> Bool = { _ in true }
    ) throws {
        do {
            try operation()
            throw SmokeFailure("Expected \(name) to fail.")
        } catch let error as InstallerError {
            guard matches(error) else { throw SmokeFailure("Unexpected error for \(name): \(error.localizedDescription)") }
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw SmokeFailure("Assertion failed: \(message)") }
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) { self.message = message }

    var description: String { message }
}
