import Darwin
import Foundation

public enum InstallationState: Sendable, Equatable {
    case notInstalled
    case updateAvailable(currentBuild: Int, currentVersion: String, release: InstallerRelease)
    case upToDate(build: Int, version: String)

    public var isCurrent: Bool {
        if case .upToDate = self { return true }
        return false
    }

    public var installedVersion: String? {
        switch self {
        case .notInstalled: nil
        case .updateAvailable(_, let version, _), .upToDate(_, let version): version
        }
    }
}

/// Detects and safely replaces the Bridgeplay app bundle. Game setup stays in the app.
public struct InstallerService: Sendable {
    public static let bundleIdentifier = "com.bridgeplay.Bridgeplay"
    public static let applicationName = "Bridgeplay.app"

    public let destination: URL
    private let ensureAppIsClosed: @Sendable () throws -> Void

    public init(destination: URL = URL(fileURLWithPath: "/Applications/Bridgeplay.app", isDirectory: true)) {
        self.init(destination: destination, ensureAppIsClosed: { try Self.requireAppIsClosed() })
    }

    init(
        destination: URL,
        ensureAppIsClosed: @escaping @Sendable () throws -> Void
    ) {
        self.destination = destination
        self.ensureAppIsClosed = ensureAppIsClosed
    }

    public func state(for release: InstallerRelease) throws -> InstallationState {
        try recoverIfNeeded()
        try Self.checkSystem(release)
        let target = transactionDestination
        guard try Self.pathExistsWithoutSymlink(target) else { return .notInstalled }
        let current = try Self.readBundle(at: target)
        guard current.identifier == Self.bundleIdentifier else {
            throw InstallerError.otherAppInstalled(current.identifier)
        }
        guard release.build >= current.build else {
            throw InstallerError.downgrade(current: current.build, offered: release.build)
        }
        if release.build == current.build {
            guard release.shortVersion == current.version else {
                throw InstallerError.invalidInstallation("Its version number does not match its build number.")
            }
            return .upToDate(build: current.build, version: current.version)
        }
        return .updateAvailable(
            currentBuild: current.build, currentVersion: current.version, release: release
        )
    }

    /// Restore a verified previous app after an interrupted replacement, without network access.
    public func recoverIfNeeded() throws {
        guard destination.isFileURL, destination.lastPathComponent == Self.applicationName else {
            throw InstallerError.invalidDestination
        }
        let target = transactionDestination
        let parent = target.deletingLastPathComponent()
        let backup = Self.backupURL(in: parent)
        guard try !Self.pathExistsWithoutSymlink(target),
              try Self.pathExistsWithoutSymlink(backup) else { return }

        let lock = try InstallLock(parent: parent)
        defer { lock.release() }
        try ensureAppIsClosed()

        // Recheck after acquiring the cross-process lock.
        guard try !Self.pathExistsWithoutSymlink(target),
              try Self.pathExistsWithoutSymlink(backup) else { return }
        let previous = try Self.readBundle(at: backup)
        guard previous.identifier == Self.bundleIdentifier else {
            throw InstallerError.invalidInstallation("The saved recovery app has a different bundle identifier.")
        }
        try Self.verifyInstalledSignature(at: backup)
        do { try FileManager.default.moveItem(at: backup, to: target) }
        catch { throw InstallerError.replacementFailure("The saved copy could not be restored. \(error.localizedDescription)") }
    }

    /// Verify, stage and install a release archive. The prior app is restored if replacement fails.
    @discardableResult
    public func install(release: InstallerRelease, archive: URL) throws -> URL {
        try Self.checkSystem(release)
        guard archive.isFileURL, destination.isFileURL,
              destination.lastPathComponent == Self.applicationName else {
            throw InstallerError.invalidDestination
        }
        try release.verifyArchive(at: archive)

        let fileManager = FileManager.default
        let target = transactionDestination
        let parent = target.deletingLastPathComponent()
        let stage = parent.appending(path: ".BridgeplayInstaller-\(UUID().uuidString)", directoryHint: .isDirectory)
        let payload = stage.appending(path: "payload", directoryHint: .isDirectory)
        let stagedApp = payload.appending(path: Self.applicationName, directoryHint: .isDirectory)
        let backup = Self.backupURL(in: parent)
        defer { try? fileManager.removeItem(at: stage) }

        do {
            try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        } catch {
            throw InstallerError.writeFailure(error.localizedDescription)
        }

        try Self.extract(archive, into: payload)
        let entries = try fileManager.contentsOfDirectory(atPath: payload.path)
        guard entries == [Self.applicationName] else { throw InstallerError.appValidation("The archive does not contain a single Bridgeplay app.") }
        try Self.validateBundle(at: stagedApp, expectedBuild: release.build, expectedVersion: release.shortVersion)

        // Coordinate concurrent installers and the installed app immediately before mutation.
        let lock = try InstallLock(parent: parent)
        defer { lock.release() }
        try ensureAppIsClosed()

        var destinationExists = try Self.pathExistsWithoutSymlink(destination)
        var backupExists = try Self.pathExistsWithoutSymlink(backup)

        // Recover an interrupted replacement before considering a new one. The backup is
        // retained across successful installs so this also recovers a later disk failure.
        if !destinationExists, backupExists {
            let previous = try Self.readBundle(at: backup)
            guard previous.identifier == Self.bundleIdentifier else {
                throw InstallerError.invalidInstallation("The saved recovery app has a different bundle identifier.")
            }
            try Self.verifyInstalledSignature(at: backup)
            do { try fileManager.moveItem(at: backup, to: target) }
            catch { throw InstallerError.replacementFailure("The saved copy could not be restored. \(error.localizedDescription)") }
            destinationExists = true
            backupExists = false
        }

        if destinationExists {
            let current = try Self.readBundle(at: destination)
            guard current.identifier == Self.bundleIdentifier else {
                throw InstallerError.otherAppInstalled(current.identifier)
            }
            guard release.build > current.build else {
                if release.build == current.build { throw InstallerError.alreadyCurrent }
                throw InstallerError.downgrade(current: current.build, offered: release.build)
            }
        }

        var retiredBackup: URL?
        if backupExists {
            let previous = try Self.readBundle(at: backup)
            guard previous.identifier == Self.bundleIdentifier else {
                throw InstallerError.invalidInstallation("A different app is occupying the saved recovery location.")
            }
            try Self.verifyInstalledSignature(at: backup)
            let retired = parent.appending(path: ".Bridgeplay.app.previous-\(UUID().uuidString)", directoryHint: .isDirectory)
            do { try fileManager.moveItem(at: backup, to: retired) }
            catch { throw InstallerError.writeFailure(error.localizedDescription) }
            retiredBackup = retired
        }

        do {
            if destinationExists { try fileManager.moveItem(at: target, to: backup) }
            try fileManager.moveItem(at: stagedApp, to: target)
        } catch {
            var rollbackDetail = ""
            if fileManager.fileExists(atPath: backup.path), !fileManager.fileExists(atPath: target.path) {
                do {
                    try fileManager.moveItem(at: backup, to: target)
                    rollbackDetail = " The previous app was restored."
                } catch {
                    rollbackDetail = " The previous app remains at \(backup.path): \(error.localizedDescription)"
                }
            }
            if let retiredBackup, !fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: retiredBackup, to: backup)
            }
            throw InstallerError.replacementFailure("\(error.localizedDescription)\(rollbackDetail)")
        }

        // Foreign-owned or read-only copies remain intact for an administrator to remove.
        if let retiredBackup, Self.canDiscardRetiredBackup(retiredBackup) {
            try? fileManager.removeItem(at: retiredBackup)
        }
        // Keep one verified previous app for recovery if the next launch fails.
        return destination
    }

    private static func canDiscardRetiredBackup(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid() else { return false }
        func writableDirectories(_ directory: URL) -> Bool {
            guard fm.isWritableFile(atPath: directory.path),
                  let children = try? fm.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ) else { return false }
            for child in children {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                if values.isDirectory == true, values.isSymbolicLink != true, !writableDirectories(child) { return false }
            }
            return true
        }
        return writableDirectories(url)
    }

    /// Resolve symlinked ancestors once, while preserving the final path component for lstat.
    /// This avoids operations through aliases such as macOS's /tmp -> /private/tmp.
    private var transactionDestination: URL {
        let normalized = destination.standardizedFileURL
        let parent = normalized.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent.appending(path: normalized.lastPathComponent, directoryHint: .isDirectory)
    }

    private static func checkSystem(_ release: InstallerRelease) throws {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let current = [version.majorVersion, version.minorVersion, version.patchVersion]
            .map(String.init).joined(separator: ".")
        if compareVersions(current, release.minimumOS) == .orderedAscending {
            throw InstallerError.unsupportedSystem(minimum: release.minimumOS)
        }
        #if arch(arm64)
        // Supported hardware for Bridgeplay.
        #else
        throw InstallerError.unsupportedSystem(minimum: "Apple silicon")
        #endif
    }

    private static func readBundle(at url: URL) throws -> BundleInfo {
        guard try pathExistsWithoutSymlink(url) else {
            throw InstallerError.invalidInstallation("The app bundle does not exist.")
        }
        var status = stat()
        guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
            throw InstallerError.invalidInstallation("The app bundle is not a regular directory.")
        }
        let infoURL = url.appending(path: "Contents/Info.plist")
        let info: [String: Any]
        do {
            let data = try Data(contentsOf: infoURL)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw InstallerError.invalidInstallation("Its Info.plist is malformed.")
            }
            info = plist
        } catch let error as InstallerError {
            throw error
        } catch {
            throw InstallerError.invalidInstallation(error.localizedDescription)
        }
        guard let identifier = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String,
              let buildText = info["CFBundleVersion"] as? String,
              buildText.utf8.allSatisfy({ (48...57).contains($0) }), let build = Int(buildText),
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..",
              !executable.contains("/"), !executable.contains("\\") else {
            throw InstallerError.invalidInstallation("Its app identity or version is missing.")
        }
        let executableURL = url.appending(path: "Contents/MacOS/\(executable)")
        let executableValues = try? executableURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey])
        guard executableValues?.isRegularFile == true,
              executableValues?.isSymbolicLink != true,
              executableValues?.isExecutable == true else {
            throw InstallerError.invalidInstallation("Its app executable is missing or unsafe.")
        }
        return BundleInfo(identifier: identifier, version: version, build: build)
    }

    private static func validateBundle(at url: URL, expectedBuild: Int, expectedVersion: String) throws {
        let info = try readBundle(at: url)
        guard info.identifier == bundleIdentifier else { throw InstallerError.appValidation("The app has a different bundle identifier.") }
        guard info.build == expectedBuild, info.version == expectedVersion else {
            throw InstallerError.appValidation("The app version does not match the authenticated release information.")
        }
        try verifyInstalledSignature(at: url)
    }

    private static func verifyInstalledSignature(at url: URL) throws {
        try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", url.path], failure: InstallerError.appValidation("Its code signature is invalid."))
    }

    private static func pathExistsWithoutSymlink(_ url: URL) throws -> Bool {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            if errno == ENOENT { return false }
            throw InstallerError.invalidDestination
        }
        guard (status.st_mode & S_IFMT) != S_IFLNK else {
            throw InstallerError.invalidDestination
        }
        return true
    }

    private static func backupURL(in parent: URL) -> URL {
        parent.appending(path: ".Bridgeplay.app.previous", directoryHint: .isDirectory)
    }

    private static func extract(_ archive: URL, into directory: URL) throws {
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path], failure: InstallerError.appValidation("The app archive could not be extracted."))
    }

    private static func requireAppIsClosed() throws {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { throw InstallerError.appIsRunning }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { throw InstallerError.appIsRunning }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = String(
                decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if blocksInstall(executable) {
                InstallerLog.write("Blocked by running process \(pid): \(executable)")
                throw InstallerError.appIsRunning
            }
        }
    }

    // Sparkle names every app's updater Autoupdate, so only Bridgeplay's own copy counts.
    static func blocksInstall(_ executable: String) -> Bool {
        switch (executable as NSString).lastPathComponent {
        case "BridgeplayApp": true
        case "Autoupdate": executable.contains("/\(applicationName)/") || executable.contains("/\(bundleIdentifier)/")
        default: false
        }
    }

    private static func run(_ executable: String, _ arguments: [String], failure: InstallerError) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw failure }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure }
    }

    private struct BundleInfo {
        let identifier: String
        let version: String
        let build: Int
    }
}

private final class InstallLock {
    private let descriptor: Int32

    init(parent: URL) throws {
        let path = parent.appending(path: ".Bridgeplay.app.install.lock").path
        var fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        let created = fd >= 0
        if created, fchmod(fd, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH) != 0 {
            close(fd)
            throw InstallerError.installLocked
        }
        if !created, errno == EEXIST {
            // Other macOS accounts can take the exclusive advisory lock through a read-only fd.
            // A brief retry covers the creator's interval between O_EXCL and fchmod(0644).
            for _ in 0..<10 {
                fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0, errno == EACCES || errno == EPERM {
                    fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                }
                if fd >= 0 { break }
                guard errno == EACCES || errno == EPERM else { break }
                usleep(10_000)
            }
        }
        guard fd >= 0 else { throw InstallerError.installLocked }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            close(fd)
            throw InstallerError.installLocked
        }
        if status.st_uid == geteuid(), fchmod(fd, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH) != 0 {
            close(fd)
            throw InstallerError.installLocked
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw InstallerError.installLocked
        }
        descriptor = fd
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
