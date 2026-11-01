import CryptoKit
import Darwin
import Foundation

@_silgen_name("renamex_np")
private func bridgeplayRenamex(_ from: UnsafePointer<CChar>, _ to: UnsafePointer<CChar>, _ flags: UInt32) -> Int32

private let renameSwap: UInt32 = 0x0000_0002
private let renameExclusive: UInt32 = 0x0000_0004
private let sharedStateName = ".bridgeplay-gta-sa-de-1547000.json"
private let sharedLockName = ".bridgeplay-gta-sa-de-1547000.lock"
private let privateStateName = ".bridgeplay-gta-sa-de-1547000"
private let privateLockName = ".bridgeplay-gta-sa-de-1547000.lock"
private let stateSchema = 1

private struct PrepFailure: Error {
    let token: String
    let status: Int32

    init(_ token: String, _ status: Int32 = 2) {
        self.token = token
        self.status = status
    }
}

private struct DLLPin: Decodable, Equatable {
    let name: String
    let sha256: String
}

private struct VendorPin: Decodable, Equatable {
    let version: String
    let sha256: String
}

private struct Manifest: Decodable {
    let schema: Int
    let appid: String
    let engine: String
    let gameBuild: String
    let gameExecutable: String
    let gameExecutableSHA256: String
    let gameExecutableSize: Int
    let dxmtDirectory: String
    let dxmtFiles: [DLLPin]
    let helperDirectory: String
    let helperName: String
    let realHelperName: String
    let helperChecksumName: String
    let helperLicenseName: String
    let helperWrapperSHA256: String
    let helperLicenseSHA256: String
    let supportedVendorHelpers: [VendorPin]

    var dllHashes: [String: String] {
        Dictionary(uniqueKeysWithValues: dxmtFiles.map { ($0.name, $0.sha256.lowercased()) })
    }

    var vendorHashes: Set<String> {
        Set(supportedVendorHelpers.map { $0.sha256.lowercased() })
    }

    func validate(wrapper: Data, license: Data) throws {
        let expectedNames: Set<String> = ["d3d11.dll", "dxgi.dll", "d3d10core.dll"]
        guard schema == 1, appid == "1547000", engine == "winecx-11.17",
              gameBuild == "16391096",
              Set(dxmtFiles.map(\.name)) == expectedNames,
              dxmtFiles.count == expectedNames.count,
              gameExecutableSize > 0,
              isHash(gameExecutableSHA256),
              dxmtFiles.allSatisfy({ isHash($0.sha256) }),
              isHash(helperWrapperSHA256), isHash(helperLicenseSHA256),
              !supportedVendorHelpers.isEmpty,
              supportedVendorHelpers.allSatisfy({ isHash($0.sha256) }),
              isSafeRelative(gameExecutable), isSafeRelative(dxmtDirectory),
              isSafeRelative(helperDirectory),
              isSafeFilename(helperName), isSafeFilename(realHelperName),
              isSafeFilename(helperChecksumName), isSafeFilename(helperLicenseName)
        else {
            throw PrepFailure("invalid-embedded-manifest")
        }
        guard sha256(wrapper) == helperWrapperSHA256.lowercased(),
              sha256(license) == helperLicenseSHA256.lowercased()
        else {
            throw PrepFailure("invalid-embedded-assets")
        }
    }
}

private struct FileInfo {
    let mode: mode_t
    let uid: uid_t
    let device: dev_t
    let inode: ino_t

    var isRegular: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
    var isDirectory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
    var isSymlink: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFLNK) }
}

private enum FilePresence {
    case absent
    case present(FileInfo)
}

private func isHash(_ value: String) -> Bool {
    guard value.count == 64 else { return false }
    return value.unicodeScalars.allSatisfy {
        (48...57).contains(Int($0.value)) || (97...102).contains(Int($0.value))
            || (65...70).contains(Int($0.value))
    }
}

private func isSafeFilename(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".."
        && !value.contains("/") && !value.contains("\0")
}

private func isSafeRelative(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\0") else { return false }
    return !value.split(separator: "/").contains { $0 == "." || $0 == ".." }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func pathInfo(_ url: URL) throws -> FilePresence {
    var info = stat()
    var path = url.path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    let result = path.withCString { Darwin.lstat($0, &info) }
    if result == 0 {
        return .present(FileInfo(mode: info.st_mode, uid: info.st_uid,
                                 device: info.st_dev, inode: info.st_ino))
    }
    if errno == ENOENT || errno == ENOTDIR {
        return .absent
    }
    throw PrepFailure("filesystem-unavailable", 5)
}

private func requireDirectory(_ url: URL) throws {
    guard case let .present(info) = try pathInfo(url), info.isDirectory else {
        throw PrepFailure("required-directory-unavailable", 3)
    }
}

private func canonicalDirectory(_ raw: String?) throws -> URL {
    guard let raw, raw.hasPrefix("/") else { throw PrepFailure("invalid-launch-path", 3) }
    let url = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    try requireDirectory(url)
    return url
}

private func validateExistingDirectoryChain(root: URL, relativePath: String) throws {
    var current = root
    for component in relativePath.split(separator: "/") {
        current = current.appending(path: String(component), directoryHint: .notDirectory)
        switch try pathInfo(current) {
        case .absent:
            return
        case let .present(info):
            guard info.isDirectory else { throw PrepFailure("unsafe-directory-chain", 4) }
        }
    }
}

private func readRegularFile(_ url: URL, maxBytes: Int = 128 * 1024 * 1024) throws -> Data {
    let fd = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
    guard fd >= 0 else { throw PrepFailure("file-unavailable", 3) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          info.st_size >= 0, info.st_size <= maxBytes
    else {
        throw PrepFailure("unsafe-or-oversized-file", 3)
    }
    guard let data = try handle.readToEnd(), data.count == Int(info.st_size) else {
        throw PrepFailure("file-read-failed", 5)
    }
    return data
}

private func peIsX64(_ data: Data) -> Bool {
    guard data.count >= 64, data[0] == 0x4d, data[1] == 0x5a else { return false }
    func u16(_ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    func u32(_ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
    let offset = Int(u32(0x3c))
    guard offset >= 64, offset <= data.count - 26,
          data[offset] == 0x50, data[offset + 1] == 0x45,
          data[offset + 2] == 0, data[offset + 3] == 0
    else { return false }
    return u16(offset + 4) == 0x8664 && u16(offset + 24) == 0x20b
}

private func checksumSidecar(_ hash: String, filename: String) -> Data {
    Data("\(hash)  \(filename)\n".utf8)
}

private func checksumSidecarMatches(_ data: Data, hash: String, filename: String) -> Bool {
    data == checksumSidecar(hash, filename: filename)
}

private struct Inputs {
    let dataRoot: URL
    let prefix: URL
    let game: URL
    let runner: URL?
    let prefixID: String
    let appid: String
    let engine: String

    init(action: String, manifest: Manifest, environment: [String: String]) throws {
        guard let appid = environment["GTA_SA_APP_ID"], appid == manifest.appid else {
            throw PrepFailure("wrong-app-id", 3)
        }
        guard let data = environment["GTA_SA_DATA_PATH"],
              let prefix = environment["GTA_SA_PREFIX"],
              let game = environment["GTA_SA_GAME"]
        else { throw PrepFailure("missing-launch-path", 3) }

        dataRoot = try canonicalDirectory(data)
        self.prefix = try canonicalDirectory(prefix)
        self.game = try canonicalDirectory(game)
        self.appid = appid
        engine = environment["GTA_SA_ENGINE_ID"] ?? ""

        if action == "prepare" || action == "status" {
            guard engine == manifest.engine else { throw PrepFailure("unsupported-engine", 3) }
            runner = try canonicalDirectory(environment["GTA_SA_RUNNER"])
        } else {
            runner = nil
        }

        let canonicalPrefix = self.prefix.path(percentEncoded: false)
        prefixID = sha256(Data(canonicalPrefix.utf8))
    }

    var stateDirectory: URL { dataRoot.appending(path: privateStateName, directoryHint: .isDirectory) }
    var stateFile: URL { stateDirectory.appending(path: "state.json") }
    var prefixLock: URL { dataRoot.appending(path: privateLockName) }
    var sharedState: URL { game.appending(path: sharedStateName) }
    var sharedLock: URL { game.appending(path: sharedLockName) }

    func gameExecutable(_ manifest: Manifest) -> URL {
        game.appending(path: manifest.gameExecutable)
    }

    func runtimeDirectory(_ manifest: Manifest) throws -> URL {
        guard let runner else { throw PrepFailure("missing-runner", 3) }
        return runner.appending(path: manifest.dxmtDirectory)
    }

    func helperDirectory(_ manifest: Manifest) -> URL {
        prefix.appending(path: manifest.helperDirectory, directoryHint: .isDirectory)
    }
}

private enum Ownership: String, Codable {
    case bridgeplay
    case preexisting
}

private struct SharedFile: Codable, Equatable {
    var sha256: String
    var ownership: Ownership
}

private struct SharedState: Codable, Equatable {
    var schema: Int
    var appid: String
    var references: [String]
    var files: [String: SharedFile]
}

private struct ArchiveRecord: Codable, Equatable {
    var filename: String
    var sha256: String
}

private struct HelperState: Codable, Equatable {
    var ownership: Ownership
    var vendorSHA256: String
    var wrapperSHA256: String
    var licenseOwned: Bool
    var checksumOwned: Bool
    var archives: [ArchiveRecord]
}

private struct PrefixState: Codable, Equatable {
    var schema: Int
    var appid: String
    var prefixID: String
    var sharedReference: Bool
    var helper: HelperState?
}

private enum Change {
    case installed(URL, String)
    case swapped(URL, URL, String, String)
    case parked(URL, URL, String)
}

private final class Transaction {
    private(set) var changes: [Change] = []

    func install(_ staging: URL, at destination: URL, hash: String) throws {
        try rename(staging, destination, flags: renameExclusive, failure: "target-appeared")
        changes.append(.installed(destination, hash))
        guard try fileHash(destination) == hash else {
            throw PrepFailure("installed-file-mismatch", 5)
        }
    }

    func swap(_ staging: URL, with destination: URL, oldHash: String, newHash: String) throws {
        guard try fileHash(destination) == oldHash else { throw PrepFailure("target-changed", 4) }
        guard try fileHash(staging) == newHash else { throw PrepFailure("staged-file-mismatch", 5) }
        try rename(staging, destination, flags: renameSwap, failure: "atomic-swap-unavailable")
        if (try? fileHash(destination)) != newHash || (try? fileHash(staging)) != oldHash {
            _ = try? rename(staging, destination, flags: renameSwap, failure: "rollback-failed")
            throw PrepFailure("target-changed-during-swap", 4)
        }
        changes.append(.swapped(destination, staging, newHash, oldHash))
    }

    func park(_ destination: URL, expectedHash: String) throws {
        guard try fileHash(destination) == expectedHash else { throw PrepFailure("owned-file-changed", 4) }
        let staging = temporaryURL(beside: destination)
        try rename(destination, staging, flags: renameExclusive, failure: "atomic-remove-unavailable")
        guard (try? fileHash(staging)) == expectedHash else {
            _ = try? rename(staging, destination, flags: renameExclusive, failure: "rollback-failed")
            throw PrepFailure("owned-file-changed-during-remove", 4)
        }
        changes.append(.parked(destination, staging, expectedHash))
    }

    func rollback() -> Bool {
        var success = true
        for change in changes.reversed() {
            switch change {
            case let .installed(destination, hash):
                if removeOwned(destination, expectedHash: hash) == false { success = false }
            case let .swapped(destination, staging, newHash, oldHash):
                guard (try? fileHash(destination)) == newHash,
                      (try? fileHash(staging)) == oldHash,
                      (try? rename(staging, destination, flags: renameSwap, failure: "rollback-failed")) != nil
                else { success = false; continue }
                _ = removeOwned(staging, expectedHash: newHash)
            case let .parked(destination, staging, hash):
                guard (try? fileHash(staging)) == hash,
                      pathIsAbsent(destination),
                      (try? rename(staging, destination, flags: renameExclusive, failure: "rollback-failed")) != nil
                else { success = false; continue }
            }
        }
        return success
    }

    func finish() {
        for change in changes {
            switch change {
            case .installed:
                break
            case let .swapped(_, staging, _, oldHash), let .parked(_, staging, oldHash):
                _ = removeOwned(staging, expectedHash: oldHash)
            }
        }
    }
}

private func pathIsAbsent(_ url: URL) -> Bool {
    guard let presence = try? pathInfo(url) else { return false }
    if case .absent = presence { return true }
    return false
}

private func fileHash(_ url: URL) throws -> String {
    sha256(try readRegularFile(url))
}

private func removeOwned(_ url: URL, expectedHash: String) -> Bool {
    guard (try? fileHash(url)) == expectedHash else { return false }
    let parked = temporaryURL(beside: url)
    guard (try? rename(url, parked, flags: renameExclusive, failure: "atomic-remove-unavailable")) != nil else {
        return false
    }
    guard (try? fileHash(parked)) == expectedHash else {
        _ = try? rename(parked, url, flags: renameExclusive, failure: "rollback-failed")
        return false
    }
    return unlink(parked.path) == 0
}

private func temporaryURL(beside destination: URL) -> URL {
    destination.deletingLastPathComponent()
        .appending(path: ".bridgeplay-gta-sa-de-\(UUID().uuidString).tmp")
}

private func rename(_ from: URL, _ to: URL, flags: UInt32, failure: String) throws {
    let result = from.path.withCString { source in
        to.path.withCString { destination in bridgeplayRenamex(source, destination, flags) }
    }
    guard result == 0 else { throw PrepFailure(failure, 5) }
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw PrepFailure("file-write-failed", 5) }
            offset += count
        }
    }
    guard fsync(fd) == 0 else { throw PrepFailure("file-sync-failed", 5) }
}

private func stageData(_ data: Data, beside destination: URL, mode: mode_t) throws -> URL {
    let staging = temporaryURL(beside: destination)
    let fd = staging.path.withCString {
        open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
    }
    guard fd >= 0 else { throw PrepFailure("staging-file-failed", 5) }
    do {
        try writeAll(data, to: fd)
        guard fchmod(fd, mode) == 0 else { throw PrepFailure("staging-mode-failed", 5) }
        close(fd)
    } catch {
        close(fd)
        _ = unlink(staging.path)
        throw error
    }
    return staging
}

private func stageCopy(_ source: URL, beside destination: URL, expectedHash: String) throws -> URL {
    let staging = temporaryURL(beside: destination)
    let flags = UInt32(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC)
    let result = source.path.withCString { src in
        staging.path.withCString { dst in copyfile(src, dst, nil, flags) }
    }
    guard result == 0 else { throw PrepFailure("staging-copy-failed", 5) }
    guard (try? fileHash(staging)) == expectedHash else {
        _ = unlink(staging.path)
        throw PrepFailure("staging-copy-hash-mismatch", 5)
    }
    return staging
}

private func acquireLock(_ url: URL) throws -> Int32 {
    let fd = url.path.withCString {
        open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
    guard fd >= 0 else { throw PrepFailure("lock-unavailable", 5) }
    var info = stat()
    guard fstat(fd, &info) == 0,
          info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          info.st_uid == geteuid(),
          info.st_mode & mode_t(0o077) == 0
    else {
        close(fd)
        throw PrepFailure("unsafe-lock-file", 4)
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        throw PrepFailure("another-preparation-is-running", 4)
    }
    return fd
}

private func readPrivateData(_ url: URL) throws -> Data? {
    guard case let .present(info) = try pathInfo(url) else { return nil }
    guard info.isRegular, info.uid == geteuid(), info.mode & mode_t(0o077) == 0 else {
        throw PrepFailure("unsafe-state-file", 4)
    }
    return try readRegularFile(url, maxBytes: 1024 * 1024)
}

private func decodeJSON<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) }
    catch { throw PrepFailure("invalid-state-file", 4) }
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do { return try encoder.encode(value) }
    catch { throw PrepFailure("state-encode-failed", 5) }
}

private func sidecarData(_ hash: String, filename: String) -> Data {
    Data("\(hash)  \(filename)\n".utf8)
}

private func supportedVendor(_ hash: String, manifest: Manifest) -> Bool {
    manifest.vendorHashes.contains(hash.lowercased())
}

private func validateChecksumFile(_ data: Data, hash: String, filename: String) -> Bool {
    data == sidecarData(hash, filename: filename)
}

private struct DLLPlan {
    var records: [String: SharedFile]
    var toInstall: [String]
    var sharedReference: Bool
    var sharedNew: SharedState?
}

private struct HelperPlan {
    var action: HelperAction
    var record: HelperState
    var currentHash: String
    var vendorData: Data?
    var realData: Data?
    var archiveName: String?
    var archiveExists: Bool
    var licenseData: Data?
    var checksumData: Data?
    var installLicense: Bool
    var installChecksum: Bool
}

private struct PreparePlan {
    var context: Inputs
    var sources: [String: Data]
    var dll: DLLPlan
    var helper: HelperPlan
    var sharedOldData: Data?
    var sharedNewData: Data?
    var prefixOldData: Data?
    var prefixNewData: Data?
}

private enum HelperAction {
    case none
    case fresh
    case rewrap
    case update
    case manual
}

private final class Coordinator {
    let manifest: Manifest
    let wrapper: Data
    let license: Data

    init(manifest: Manifest, wrapper: Data, license: Data) throws {
        try manifest.validate(wrapper: wrapper, license: license)
        self.manifest = manifest
        self.wrapper = wrapper
        self.license = license
    }

    func status(environment: [String: String]) throws -> String {
        let context = try Inputs(action: "status", manifest: manifest, environment: environment)
        let plan = try makePreparePlan(context)
        if plan.prefixNewData == nil && plan.sharedNewData == nil
            && plan.dll.toInstall.isEmpty
            && (plan.helper.action == .none || plan.helper.action == .manual) {
            return plan.helper.record.ownership == .preexisting ? "manual" : "prepared"
        }
        return "ready"
    }

    func prepare(environment: [String: String]) throws -> String {
        let context = try Inputs(action: "prepare", manifest: manifest, environment: environment)
        _ = try makePreparePlan(context) // Full read-only validation before creating locks.
        let gameLock = try acquireLock(context.game.appending(path: sharedLockName))
        defer { flock(gameLock, LOCK_UN); close(gameLock) }
        let prefixLock = try acquireLock(context.dataRoot.appending(path: privateLockName))
        defer { flock(prefixLock, LOCK_UN); close(prefixLock) }

        let plan = try makePreparePlan(context) // Revalidate under both locks.
        if plan.prefixNewData == nil && plan.sharedNewData == nil
            && plan.dll.toInstall.isEmpty
            && (plan.helper.action == .none || plan.helper.action == .manual) {
            return plan.helper.record.ownership == .preexisting ? "manual" : "already-prepared"
        }
        try apply(plan)
        return plan.helper.record.ownership == .preexisting ? "adopted-manual" : "prepared"
    }

    func restore(environment: [String: String]) throws -> String {
        let context = try Inputs(action: "restore", manifest: manifest, environment: environment)
        _ = try validatePrivateStateDirectory(context)
        guard try readPrivateData(context.stateFile) != nil else { return "no-owned-state" }
        try validateDirectoryChains(context)
        let gameLock = try acquireLock(context.game.appending(path: sharedLockName))
        defer { flock(gameLock, LOCK_UN); close(gameLock) }
        let prefixLock = try acquireLock(context.dataRoot.appending(path: privateLockName))
        defer { flock(prefixLock, LOCK_UN); close(prefixLock) }
        _ = try validatePrivateStateDirectory(context)
        let stateData = try readPrivateData(context.stateFile)
        guard let stateData else { return "no-owned-state" }
        let state: PrefixState = try decodeJSON(PrefixState.self, data: stateData)
        try validate(state, context: context)
        try restore(state: state, stateData: stateData, context: context)
        return "restored"
    }

    private func planHelper(context: Inputs, existing: HelperState?) throws -> HelperPlan {
        let directory = context.helperDirectory(manifest)
        guard case let .present(directoryInfo) = try pathInfo(directory),
              directoryInfo.isDirectory else { throw PrepFailure("social-club-directory-unavailable", 3) }

        let helperURL = directory.appending(path: manifest.helperName)
        let realURL = directory.appending(path: manifest.realHelperName)
        let checksumURL = directory.appending(path: manifest.helperChecksumName)
        let licenseURL = directory.appending(path: manifest.helperLicenseName)

        guard case let .present(helperInfo) = try pathInfo(helperURL), helperInfo.isRegular else {
            throw PrepFailure("social-club-helper-unavailable", 3)
        }
        let helperData = try readRegularFile(helperURL)
        let helperHash = sha256(helperData)
        let realPresence = try pathInfo(realURL)
        let realData: Data?
        if case .absent = realPresence {
            realData = nil
        } else {
            guard case let .present(realInfo) = realPresence, realInfo.isRegular else {
                throw PrepFailure("social-club-real-helper-conflict", 4)
            }
            realData = try readRegularFile(realURL)
        }
        let realHash = realData.map(sha256)

        let checksumPresence = try pathInfo(checksumURL)
        let checksumData: Data?
        if case .absent = checksumPresence {
            checksumData = nil
        } else {
            guard case let .present(checksumInfo) = checksumPresence, checksumInfo.isRegular else {
                throw PrepFailure("helper-checksum-conflict", 4)
            }
            checksumData = try readRegularFile(checksumURL, maxBytes: 4096)
        }
        let licensePresence = try pathInfo(licenseURL)
        let existingLicense: Data?
        if case .absent = licensePresence {
            existingLicense = nil
        } else {
            guard case let .present(licenseInfo) = licensePresence, licenseInfo.isRegular else {
                throw PrepFailure("helper-license-conflict", 4)
            }
            existingLicense = try readRegularFile(licenseURL, maxBytes: 64 * 1024)
            guard sha256(existingLicense!) == manifest.helperLicenseSHA256.lowercased() else {
                throw PrepFailure("helper-license-conflict", 4)
            }
        }

        if let existing {
            guard existing.wrapperSHA256 == manifest.helperWrapperSHA256.lowercased() else {
                throw PrepFailure("helper-state-version-mismatch", 4)
            }
            guard let realData, let realHash,
                  realHash == existing.vendorSHA256,
                  supportedVendor(realHash, manifest: manifest)
            else { throw PrepFailure("real-helper-changed", 4) }
            if existing.checksumOwned {
                guard let checksumData,
                      validateChecksumFile(checksumData, hash: realHash,
                                           filename: manifest.realHelperName)
                else { throw PrepFailure("helper-checksum-changed", 4) }
            } else if let checksumData,
                      !validateChecksumFile(checksumData, hash: realHash,
                                            filename: manifest.realHelperName) {
                throw PrepFailure("helper-checksum-conflict", 4)
            }
            if existing.licenseOwned {
                guard existingLicense != nil else { throw PrepFailure("helper-license-missing", 4) }
            }
            if existing.ownership == .preexisting {
                guard helperHash == manifest.helperWrapperSHA256.lowercased() else {
                    throw PrepFailure("manual-helper-changed", 4)
                }
                return HelperPlan(action: .manual, record: existing, currentHash: helperHash,
                                  vendorData: nil, realData: realData, archiveName: nil,
                                  archiveExists: false, licenseData: existingLicense,
                                  checksumData: checksumData, installLicense: false,
                                  installChecksum: false)
            }
            if helperHash == manifest.helperWrapperSHA256.lowercased() {
                return HelperPlan(action: .none, record: existing, currentHash: helperHash,
                                  vendorData: nil, realData: realData, archiveName: nil,
                                  archiveExists: false, licenseData: existingLicense,
                                  checksumData: checksumData, installLicense: false,
                                  installChecksum: false)
            }
            guard supportedVendor(helperHash, manifest: manifest) else {
                throw PrepFailure("unsupported-vendor-helper", 3)
            }
            let vendorData = helperData
            if helperHash == existing.vendorSHA256 {
                return HelperPlan(action: .rewrap, record: existing, currentHash: helperHash,
                                  vendorData: vendorData, realData: realData, archiveName: nil,
                                  archiveExists: false, licenseData: existingLicense,
                                  checksumData: checksumData, installLicense: false,
                                  installChecksum: false)
            }
            let archiveName = "SocialClubHelper_real.previous.\(existing.vendorSHA256.prefix(16)).exe"
            let archiveURL = directory.appending(path: archiveName)
            let archiveExists: Bool
            switch try pathInfo(archiveURL) {
            case .absent:
                archiveExists = false
            case let .present(info):
                guard info.isRegular, try fileHash(archiveURL) == existing.vendorSHA256 else {
                    throw PrepFailure("vendor-backup-archive-conflict", 4)
                }
                archiveExists = true
            }
            var updated = existing
            if !updated.archives.contains(where: { $0.filename == archiveName }) {
                updated.archives.append(ArchiveRecord(filename: archiveName, sha256: existing.vendorSHA256))
            }
            updated.vendorSHA256 = helperHash
            let checksumOwned = existing.checksumOwned
            if !checksumOwned && checksumData != nil {
                throw PrepFailure("helper-checksum-not-owned", 4)
            }
            return HelperPlan(action: .update, record: updated, currentHash: helperHash,
                              vendorData: vendorData, realData: realData, archiveName: archiveName,
                              archiveExists: archiveExists, licenseData: existingLicense,
                              checksumData: checksumData, installLicense: false,
                              installChecksum: checksumData == nil)
        }

        if helperHash == manifest.helperWrapperSHA256.lowercased() {
            guard let realData, let realHash, supportedVendor(realHash, manifest: manifest) else {
                throw PrepFailure("manual-helper-backup-unverified", 4)
            }
            if let checksumData,
               !validateChecksumFile(checksumData, hash: realHash, filename: manifest.realHelperName) {
                throw PrepFailure("helper-checksum-conflict", 4)
            }
            let record = HelperState(ownership: .preexisting, vendorSHA256: realHash,
                                     wrapperSHA256: manifest.helperWrapperSHA256.lowercased(),
                                     licenseOwned: false, checksumOwned: false, archives: [])
            return HelperPlan(action: .manual, record: record, currentHash: helperHash,
                              vendorData: nil, realData: realData, archiveName: nil,
                              archiveExists: false, licenseData: existingLicense,
                              checksumData: checksumData, installLicense: false,
                              installChecksum: false)
        }

        guard supportedVendor(helperHash, manifest: manifest), realData == nil else {
            throw PrepFailure("unsupported-vendor-helper", 3)
        }
        if checksumData != nil {
            throw PrepFailure("helper-checksum-without-backup", 4)
        }
        let licenseOwned = existingLicense == nil
        let record = HelperState(ownership: .bridgeplay, vendorSHA256: helperHash,
                                 wrapperSHA256: manifest.helperWrapperSHA256.lowercased(),
                                 licenseOwned: licenseOwned, checksumOwned: true, archives: [])
        return HelperPlan(action: .fresh, record: record, currentHash: helperHash,
                          vendorData: helperData, realData: nil, archiveName: nil,
                          archiveExists: false, licenseData: existingLicense,
                          checksumData: nil, installLicense: licenseOwned,
                          installChecksum: true)
    }

    private func validate(_ state: SharedState) throws {
        guard state.schema == stateSchema, state.appid == manifest.appid,
              Set(state.references).count == state.references.count,
              state.references.allSatisfy({ isHash($0) }),
              Set(state.files.keys) == Set(manifest.dxmtFiles.map(\.name))
        else { throw PrepFailure("invalid-shared-ownership-state", 4) }
        for pin in manifest.dxmtFiles {
            guard let file = state.files[pin.name],
                  file.sha256 == pin.sha256.lowercased()
            else { throw PrepFailure("invalid-shared-ownership-state", 4) }
        }
    }

    private func validate(_ state: PrefixState, context: Inputs) throws {
        guard state.schema == stateSchema, state.appid == manifest.appid,
              state.prefixID == context.prefixID
        else { throw PrepFailure("invalid-prefix-ownership-state", 4) }
        if state.sharedReference {
            guard state.prefixID.count == 64 else { throw PrepFailure("invalid-prefix-reference", 4) }
        }
    }

    private func readSharedData(_ url: URL) throws -> Data? {
        guard case let .present(info) = try pathInfo(url) else { return nil }
        guard info.isRegular, info.uid == geteuid(), info.mode & mode_t(0o077) == 0 else {
            throw PrepFailure("unsafe-shared-state-file", 4)
        }
        return try readRegularFile(url, maxBytes: 1024 * 1024)
    }

    private var gameInstallRelativeDirectory: String {
        manifest.gameExecutable.split(separator: "/").dropLast().joined(separator: "/")
    }

    private func gameInstallDirectory(_ context: Inputs) -> URL {
        gameInstallRelativeDirectory.isEmpty
            ? context.game
            : context.game.appending(path: gameInstallRelativeDirectory)
    }

    private func validateDirectoryChains(_ context: Inputs) throws {
        try validateExistingDirectoryChain(root: context.game,
                                           relativePath: gameInstallRelativeDirectory)
        try validateExistingDirectoryChain(root: context.prefix,
                                           relativePath: manifest.helperDirectory)
        if let runner = context.runner {
            try validateExistingDirectoryChain(root: runner, relativePath: manifest.dxmtDirectory)
        }
    }

    private func validatePrivateStateDirectory(_ context: Inputs) throws -> Bool {
        switch try pathInfo(context.stateDirectory) {
        case .absent:
            return false
        case let .present(info):
            guard info.isDirectory, info.uid == geteuid(),
                  info.mode & mode_t(0o777) == mode_t(0o700)
            else { throw PrepFailure("unsafe-prefix-state-directory", 4) }
            return true
        }
    }

    private func validateOperationDirectories(_ context: Inputs) throws {
        try validateDirectoryChains(context)
        _ = try validatePrivateStateDirectory(context)
    }

    private func planDLLs(context: Inputs, existing: SharedState?) throws -> DLLPlan {
        let gameDirectory = gameInstallDirectory(context)
        var present: [String: String] = [:]
        for pin in manifest.dxmtFiles {
            let target = gameDirectory.appending(path: pin.name)
            switch try pathInfo(target) {
            case .absent:
                break
            case let .present(info):
                guard info.isRegular else { throw PrepFailure("game-dll-symlink-or-nonfile", 4) }
                let data = try readRegularFile(target)
                let hash = sha256(data)
                guard hash == pin.sha256.lowercased(), peIsX64(data) else {
                    throw PrepFailure("game-dll-conflict", 4)
                }
                present[pin.name] = hash
            }
        }

        if let existing {
            var updated = existing
            var toInstall: [String] = []
            for pin in manifest.dxmtFiles {
                guard let record = existing.files[pin.name] else {
                    throw PrepFailure("invalid-shared-ownership-state", 4)
                }
                if present[pin.name] == nil {
                    guard record.ownership == .bridgeplay else {
                        throw PrepFailure("preexisting-game-dll-missing", 4)
                    }
                    toInstall.append(pin.name)
                }
            }
            if !updated.references.contains(context.prefixID) {
                updated.references.append(context.prefixID)
                updated.references.sort()
            }
            return DLLPlan(records: existing.files, toInstall: toInstall,
                           sharedReference: true,
                           sharedNew: updated == existing ? nil : updated)
        }

        let allAbsent = present.isEmpty
        let allPresent = present.count == manifest.dxmtFiles.count
        guard allAbsent || allPresent else { throw PrepFailure("partial-game-dll-set", 4) }
        if allPresent {
            let records = Dictionary(uniqueKeysWithValues: manifest.dxmtFiles.map {
                ($0.name, SharedFile(sha256: $0.sha256.lowercased(), ownership: .preexisting))
            })
            return DLLPlan(records: records, toInstall: [], sharedReference: false, sharedNew: nil)
        }
        let records = Dictionary(uniqueKeysWithValues: manifest.dxmtFiles.map {
            ($0.name, SharedFile(sha256: $0.sha256.lowercased(), ownership: .bridgeplay))
        })
        return DLLPlan(records: records, toInstall: manifest.dxmtFiles.map(\.name),
                       sharedReference: true,
                       sharedNew: SharedState(schema: stateSchema, appid: manifest.appid,
                                              references: [context.prefixID], files: records))
    }

    private func makePreparePlan(_ context: Inputs) throws -> PreparePlan {
        try validateOperationDirectories(context)
        let gameData = try readRegularFile(context.gameExecutable(manifest))
        guard gameData.count == manifest.gameExecutableSize,
              sha256(gameData) == manifest.gameExecutableSHA256.lowercased()
        else { throw PrepFailure("unsupported-game-build", 3) }

        guard let runner = context.runner else { throw PrepFailure("missing-runner", 3) }
        let runtimeDirectory = runner.appending(path: manifest.dxmtDirectory)
        guard case let .present(runtimeInfo) = try pathInfo(runtimeDirectory),
              runtimeInfo.isDirectory
        else { throw PrepFailure("dxmt-runtime-unavailable", 3) }

        var sources: [String: Data] = [:]
        for pin in manifest.dxmtFiles {
            let data = try readRegularFile(runtimeDirectory.appending(path: pin.name))
            guard sha256(data) == pin.sha256.lowercased(), peIsX64(data) else {
                throw PrepFailure("unsupported-dxmt-runtime", 3)
            }
            sources[pin.name] = data
        }

        let prefixOldData = try readPrivateData(context.stateFile)
        let prefixState = try prefixOldData.map { try decodeJSON(PrefixState.self, data: $0) }
        if let prefixState { try validate(prefixState, context: context) }
        let sharedOldData = try readSharedData(context.sharedState)
        let sharedState = try sharedOldData.map { try decodeJSON(SharedState.self, data: $0) }
        if let sharedState { try validate(sharedState) }
        if prefixState?.sharedReference == true && sharedState == nil {
            throw PrepFailure("missing-shared-ownership-state", 4)
        }

        let dll = try planDLLs(context: context, existing: sharedState)
        let helper = try planHelper(context: context, existing: prefixState?.helper)

        var prefixNew: PrefixState?
        if let prefixState {
            var updated = prefixState
            updated.sharedReference = dll.sharedReference
            updated.helper = helper.record
            prefixNew = updated
        } else if helper.action != .manual || dll.sharedReference {
            prefixNew = PrefixState(schema: stateSchema, appid: manifest.appid,
                                    prefixID: context.prefixID,
                                    sharedReference: dll.sharedReference,
                                    helper: helper.record)
        }
        let prefixNewData: Data?
        if let prefixNew {
            let encoded = try encodeJSON(prefixNew)
            prefixNewData = encoded == prefixOldData ? nil : encoded
        } else {
            prefixNewData = nil
        }
        let sharedNewData: Data?
        if let shared = dll.sharedNew {
            sharedNewData = try encodeJSON(shared)
        } else {
            sharedNewData = nil
        }
        return PreparePlan(context: context, sources: sources, dll: dll, helper: helper,
                           sharedOldData: sharedOldData, sharedNewData: sharedNewData,
                           prefixOldData: prefixOldData, prefixNewData: prefixNewData)
    }

    private func apply(_ plan: PreparePlan) throws {
        let context = plan.context
        try validateDirectoryChains(context)
        let stateDirectoryWasPresent = try validatePrivateStateDirectory(context)
        if plan.prefixNewData != nil && !stateDirectoryWasPresent {
            let result = context.stateDirectory.path.withCString { mkdir($0, mode_t(0o700)) }
            guard result == 0 else { throw PrepFailure("prefix-state-directory-unavailable", 5) }
            _ = try validatePrivateStateDirectory(context)
        }
        var staged: [URL: String] = [:]
        var dllStages: [String: URL] = [:]
        let transaction = Transaction()
        do {
            let gameDirectory = gameInstallDirectory(context)
            for name in plan.dll.toInstall {
                guard let sourceData = plan.sources[name],
                      let pin = manifest.dxmtFiles.first(where: { $0.name == name })
                else { throw PrepFailure("invalid-dxmt-plan", 5) }
                let stage = try stageData(sourceData, beside: gameDirectory.appending(path: name),
                                          mode: mode_t(0o644))
                staged[stage] = pin.sha256.lowercased()
                dllStages[name] = stage
            }

            let helperDirectory = context.helperDirectory(manifest)
            let helperURL = helperDirectory.appending(path: manifest.helperName)
            let realURL = helperDirectory.appending(path: manifest.realHelperName)
            let checksumURL = helperDirectory.appending(path: manifest.helperChecksumName)
            let licenseURL = helperDirectory.appending(path: manifest.helperLicenseName)
            var wrapperStage: URL?
            var realStage: URL?
            var checksumStage: URL?
            var licenseStage: URL?
            var archiveStage: URL?

            switch plan.helper.action {
            case .none, .manual:
                break
            case .fresh:
                guard let vendorData = plan.helper.vendorData else { throw PrepFailure("invalid-helper-plan", 5) }
                let vendorSource = helperURL
                let stageReal = try stageCopy(vendorSource, beside: realURL,
                                              expectedHash: plan.helper.record.vendorSHA256)
                staged[stageReal] = plan.helper.record.vendorSHA256
                realStage = stageReal
                let sum = sidecarData(plan.helper.record.vendorSHA256, filename: manifest.realHelperName)
                let stageSum = try stageData(sum, beside: checksumURL, mode: mode_t(0o600))
                staged[stageSum] = sha256(sum)
                checksumStage = stageSum
                if plan.helper.installLicense {
                    let stageLicense = try stageData(license, beside: licenseURL, mode: mode_t(0o644))
                    staged[stageLicense] = manifest.helperLicenseSHA256.lowercased()
                    licenseStage = stageLicense
                }
                let stageWrapper = try stageData(wrapper, beside: helperURL, mode: mode_t(0o755))
                staged[stageWrapper] = manifest.helperWrapperSHA256.lowercased()
                wrapperStage = stageWrapper
                _ = vendorData
            case .rewrap:
                let stageWrapper = try stageData(wrapper, beside: helperURL, mode: mode_t(0o755))
                staged[stageWrapper] = manifest.helperWrapperSHA256.lowercased()
                wrapperStage = stageWrapper
            case .update:
                guard let vendorData = plan.helper.vendorData,
                      let oldRealData = plan.helper.realData,
                      let archiveName = plan.helper.archiveName
                else { throw PrepFailure("invalid-helper-update-plan", 5) }
                if !plan.helper.archiveExists {
                    let archiveURL = helperDirectory.appending(path: archiveName)
                    let stageArchive = try stageData(oldRealData, beside: archiveURL, mode: mode_t(0o600))
                    staged[stageArchive] = sha256(oldRealData)
                    archiveStage = stageArchive
                }
                let stageReal = try stageData(vendorData, beside: realURL,
                                              mode: mode_t(0o644))
                staged[stageReal] = plan.helper.record.vendorSHA256
                realStage = stageReal
                let sum = sidecarData(plan.helper.record.vendorSHA256, filename: manifest.realHelperName)
                let stageSum = try stageData(sum, beside: checksumURL, mode: mode_t(0o600))
                staged[stageSum] = sha256(sum)
                checksumStage = stageSum
                let stageWrapper = try stageData(wrapper, beside: helperURL, mode: mode_t(0o755))
                staged[stageWrapper] = manifest.helperWrapperSHA256.lowercased()
                wrapperStage = stageWrapper
            }

            var sharedStage: URL?
            if let data = plan.sharedNewData {
                let stage = try stageData(data, beside: context.sharedState, mode: mode_t(0o600))
                staged[stage] = sha256(data)
                sharedStage = stage
            }
            var prefixStage: URL?
            if let data = plan.prefixNewData {
                let stage = try stageData(data, beside: context.stateFile, mode: mode_t(0o600))
                staged[stage] = sha256(data)
                prefixStage = stage
            }

            for name in plan.dll.toInstall {
                guard let pin = manifest.dxmtFiles.first(where: { $0.name == name }),
                      let stage = dllStages[name]
                else { throw PrepFailure("missing-dxmt-stage", 5) }
                let target = gameDirectory.appending(path: name)
                try transaction.install(stage, at: target, hash: pin.sha256.lowercased())
                staged.removeValue(forKey: stage)
            }

            if case .fresh = plan.helper.action {
                guard let realStage, let checksumStage else { throw PrepFailure("missing-helper-stage", 5) }
                try transaction.install(realStage, at: realURL, hash: plan.helper.record.vendorSHA256)
                staged.removeValue(forKey: realStage)
                try transaction.install(checksumStage, at: checksumURL,
                                        hash: sha256(sidecarData(plan.helper.record.vendorSHA256,
                                                                filename: manifest.realHelperName)))
                staged.removeValue(forKey: checksumStage)
                if let licenseStage {
                    try transaction.install(licenseStage, at: licenseURL,
                                            hash: manifest.helperLicenseSHA256.lowercased())
                    staged.removeValue(forKey: licenseStage)
                }
                guard let wrapperStage else { throw PrepFailure("missing-wrapper-stage", 5) }
                try transaction.swap(wrapperStage, with: helperURL,
                                     oldHash: plan.helper.currentHash,
                                     newHash: manifest.helperWrapperSHA256.lowercased())
                staged.removeValue(forKey: wrapperStage)
            } else if case .rewrap = plan.helper.action {
                guard let wrapperStage else { throw PrepFailure("missing-wrapper-stage", 5) }
                try transaction.swap(wrapperStage, with: helperURL,
                                     oldHash: plan.helper.currentHash,
                                     newHash: manifest.helperWrapperSHA256.lowercased())
                staged.removeValue(forKey: wrapperStage)
            } else if case .update = plan.helper.action {
                guard let vendorData = plan.helper.vendorData,
                      let archiveName = plan.helper.archiveName,
                      let realData = plan.helper.realData,
                      let realStage, let checksumStage, let wrapperStage
                else { throw PrepFailure("missing-helper-update-stage", 5) }
                let archiveURL = helperDirectory.appending(path: archiveName)
                if let archiveStage {
                    try transaction.install(archiveStage, at: archiveURL,
                                            hash: sha256(realData))
                    staged.removeValue(forKey: archiveStage)
                }
                try transaction.swap(realStage, with: realURL,
                                     oldHash: sha256(realData),
                                     newHash: plan.helper.record.vendorSHA256)
                staged.removeValue(forKey: realStage)
                let oldChecksum = try readRegularFile(checksumURL, maxBytes: 4096)
                try transaction.swap(checksumStage, with: checksumURL,
                                     oldHash: sha256(oldChecksum),
                                     newHash: sha256(sidecarData(plan.helper.record.vendorSHA256,
                                                                 filename: manifest.realHelperName)))
                staged.removeValue(forKey: checksumStage)
                try transaction.swap(wrapperStage, with: helperURL,
                                     oldHash: plan.helper.currentHash,
                                     newHash: manifest.helperWrapperSHA256.lowercased())
                staged.removeValue(forKey: wrapperStage)
                _ = vendorData
            }

            if let sharedStage, let sharedNewData = plan.sharedNewData {
                if let oldData = plan.sharedOldData {
                    try transaction.swap(sharedStage, with: context.sharedState,
                                         oldHash: sha256(oldData), newHash: sha256(sharedNewData))
                } else {
                    try transaction.install(sharedStage, at: context.sharedState, hash: sha256(sharedNewData))
                }
                staged.removeValue(forKey: sharedStage)
            }
            if let prefixStage, let prefixNewData = plan.prefixNewData {
                if let oldData = plan.prefixOldData {
                    try transaction.swap(prefixStage, with: context.stateFile,
                                         oldHash: sha256(oldData), newHash: sha256(prefixNewData))
                } else {
                    try transaction.install(prefixStage, at: context.stateFile, hash: sha256(prefixNewData))
                }
                staged.removeValue(forKey: prefixStage)
            }
            transaction.finish()
            for (stage, hash) in staged { _ = removeOwned(stage, expectedHash: hash) }
        } catch {
            let rollbackSucceeded = transaction.rollback()
            if rollbackSucceeded {
                for (stage, hash) in staged { _ = removeOwned(stage, expectedHash: hash) }
                if !stateDirectoryWasPresent, plan.prefixNewData != nil {
                    _ = rmdir(context.stateDirectory.path)
                }
            } else {
                throw PrepFailure("preparation-failed-rollback-incomplete", 5)
            }
            throw error
        }
    }

    private func restore(state: PrefixState, stateData: Data, context: Inputs) throws {
        try validateDirectoryChains(context)
        _ = try validatePrivateStateDirectory(context)
        let helperDirectory = context.helperDirectory(manifest)
        let helperURL = helperDirectory.appending(path: manifest.helperName)
        let realURL = helperDirectory.appending(path: manifest.realHelperName)
        let checksumURL = helperDirectory.appending(path: manifest.helperChecksumName)
        let licenseURL = helperDirectory.appending(path: manifest.helperLicenseName)
        let helperData = try readRegularFile(helperURL)
        let helperHash = sha256(helperData)

        var currentSharedData: Data?
        var currentShared: SharedState?
        if state.sharedReference {
            currentSharedData = try readSharedData(context.sharedState)
            guard let currentSharedData else { throw PrepFailure("missing-shared-ownership-state", 4) }
            currentShared = try decodeJSON(SharedState.self, data: currentSharedData)
            guard let currentShared, currentShared.references.contains(context.prefixID) else {
                throw PrepFailure("missing-prefix-reference", 4)
            }
            try validate(currentShared)
        }

        var realData: Data?
        var realHash: String?
        if let helperState = state.helper, helperState.ownership == .bridgeplay {
            realData = try readRegularFile(realURL)
            realHash = sha256(realData!)
            guard realHash == helperState.vendorSHA256,
                  supportedVendor(realHash!, manifest: manifest)
            else { throw PrepFailure("real-helper-changed", 4) }
            let checksumData = try readRegularFile(checksumURL, maxBytes: 4096)
            guard validateChecksumFile(checksumData, hash: realHash!,
                                       filename: manifest.realHelperName)
            else { throw PrepFailure("helper-checksum-changed", 4) }
            if helperState.licenseOwned {
                let currentLicense = try readRegularFile(licenseURL, maxBytes: 64 * 1024)
                guard sha256(currentLicense) == manifest.helperLicenseSHA256.lowercased() else {
                    throw PrepFailure("helper-license-changed", 4)
                }
            }
            guard helperHash == helperState.wrapperSHA256
                    || supportedVendor(helperHash, manifest: manifest)
            else { throw PrepFailure("helper-changed", 4) }
        }

        let transaction = Transaction()
        var pendingStages: [URL: String] = [:]
        do {
            if let helperState = state.helper, helperState.ownership == .bridgeplay {
                if helperHash == helperState.wrapperSHA256 {
                    let stage = try stageCopy(realURL, beside: helperURL, expectedHash: helperState.vendorSHA256)
                    pendingStages[stage] = helperState.vendorSHA256
                    try transaction.swap(stage, with: helperURL,
                                         oldHash: helperState.wrapperSHA256,
                                         newHash: helperState.vendorSHA256)
                    pendingStages.removeValue(forKey: stage)
                }
                if let realHash { try transaction.park(realURL, expectedHash: realHash) }
                if helperState.checksumOwned {
                    let sidecar = try readRegularFile(checksumURL, maxBytes: 4096)
                    try transaction.park(checksumURL, expectedHash: sha256(sidecar))
                }
                if helperState.licenseOwned {
                    try transaction.park(licenseURL, expectedHash: manifest.helperLicenseSHA256.lowercased())
                }
            }

            if let oldData = currentSharedData, var shared = currentShared {
                shared.references.removeAll { $0 == context.prefixID }
                if shared.references.isEmpty {
                    let gameDirectory = gameInstallDirectory(context)
                    for pin in manifest.dxmtFiles {
                        guard let file = shared.files[pin.name], file.ownership == .bridgeplay else { continue }
                        let target = gameDirectory.appending(path: pin.name)
                        if case let .present(info) = try pathInfo(target), info.isRegular,
                           (try? fileHash(target)) == file.sha256 {
                            try transaction.park(target, expectedHash: file.sha256)
                        }
                    }
                    try transaction.park(context.sharedState, expectedHash: sha256(oldData))
                } else {
                    let updated = try encodeJSON(shared)
                    let stage = try stageData(updated, beside: context.sharedState, mode: mode_t(0o600))
                    pendingStages[stage] = sha256(updated)
                    try transaction.swap(stage, with: context.sharedState,
                                         oldHash: sha256(oldData), newHash: sha256(updated))
                    pendingStages.removeValue(forKey: stage)
                }
            }

            try transaction.park(context.stateFile, expectedHash: sha256(stateData))
            transaction.finish()
        } catch {
            if transaction.rollback() {
                for (stage, hash) in pendingStages { _ = removeOwned(stage, expectedHash: hash) }
            } else {
                throw PrepFailure("restore-failed-rollback-incomplete", 5)
            }
            throw error
        }
    }
}

@main
private struct GamefixPrepCLI {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 2,
              ["prepare", "restore", "status"].contains(args[1])
        else {
            writeError("invalid-action")
            exit(64)
        }

        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: GTAFixPrepAssets.manifestJSON)
            let coordinator = try Coordinator(manifest: manifest, wrapper: GTAFixPrepAssets.helperWrapper,
                                              license: GTAFixPrepAssets.helperLicense)
            let environment = ProcessInfo.processInfo.environment
            let result: String
            switch args[1] {
            case "prepare":
                let context = try Inputs(action: "prepare", manifest: manifest, environment: environment)
                result = try coordinator.prepare(environment: environment)
                _ = context
            case "restore":
                result = try coordinator.restore(environment: environment)
            default:
                result = try coordinator.status(environment: environment)
            }
            print(result)
            exit(0)
        } catch let failure as PrepFailure {
            writeError(failure.token)
            exit(failure.status)
        } catch {
            writeError("operation-failed")
            exit(5)
        }
    }

    private static func writeError(_ token: String) {
        FileHandle.standardError.write(Data("gta-sa-de: \(token)\n".utf8))
    }
}
