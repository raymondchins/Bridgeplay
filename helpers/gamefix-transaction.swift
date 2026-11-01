import CryptoKit
import Darwin
import Foundation

private let gamefixJournalName = ".bridgeplay-gta-sa-de-1547000.transaction.json"
private let gamefixStateDirectoryName = ".bridgeplay-gta-sa-de-1547000"
private let gamefixSharedMarkerName = ".bridgeplay-gta-sa-de-1547000.pending.json"
private let gamefixStagePrefix = ".bridgeplay-gta-sa-de-"
private let gamefixJournalTempPrefix = ".bridgeplay-gta-sa-de-journal-"
private let gamefixSharedMarkerTempPrefix = ".bridgeplay-gta-sa-de-marker-"
private let gamefixAppID = "1547000"
private let gamefixMaximumJournalBytes = 128 * 1024
private let gamefixMaximumSharedMarkerBytes = 4096
private let gamefixMaximumOperations = 256
private let gamefixMaximumRegisteredStages = 256
private let gamefixMaximumFileBytes = 512 * 1024 * 1024

#if GTA_FIXTURE_CRASH
private let gamefixFixtureCrashLock = NSLock()
nonisolated(unsafe) private var gamefixFixtureMutationCount = 0
#endif

final class GamefixTransaction {
    struct Failure: Error {
        let token: String
        let status: Int32

        init(_ token: String, _ status: Int32 = 5) {
            self.token = token
            self.status = status
        }
    }

    private enum Phase: String, Codable {
        case active, committed
        case released // Target cleanup is complete; recovery may only clean metadata.
    }
    private enum Kind: String, Codable { case install, swap, park }

    private struct Operation: Codable {
        let kind: Kind
        let target: String
        let staging: String
        let oldHash: String?
        let newHash: String?
    }

    private struct RegisteredStage: Codable {
        let parent: String
        let staging: String
        let hash: String
    }

    private struct Journal: Codable {
        let version: Int
        var transactionUUID: String?
        var phase: Phase
        var operations: [Operation]
        var registeredStages: [RegisteredStage]

        init(phase: Phase, operations: [Operation], registeredStages: [RegisteredStage] = [],
             transactionUUID: String? = UUID().uuidString.lowercased()) {
            version = 1
            self.transactionUUID = transactionUUID
            self.phase = phase
            self.operations = operations
            self.registeredStages = registeredStages
        }

        private enum CodingKeys: String, CodingKey { case version, transactionUUID, phase, operations, registeredStages }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            transactionUUID = try values.decodeIfPresent(String.self, forKey: .transactionUUID)
            phase = try values.decode(Phase.self, forKey: .phase)
            operations = try values.decode([Operation].self, forKey: .operations)
            registeredStages = try values.decodeIfPresent([RegisteredStage].self, forKey: .registeredStages) ?? []
        }
    }

    private struct SharedMarker: Codable {
        let version: Int
        let appid: String
        let transactionUUID: String

        init(transactionUUID: String) {
            version = 1
            appid = gamefixAppID
            self.transactionUUID = transactionUUID
        }
    }

    private let journalURL: URL
    private let targets: [String: URL]

    private var sharedMarkerURL: URL {
        targets["state:shared"]!.deletingLastPathComponent().appending(path: gamefixSharedMarkerName)
    }

    init(journalURL: URL, targets: [String: URL]) {
        self.journalURL = journalURL.standardizedFileURL
        self.targets = targets.mapValues { $0.standardizedFileURL }
    }

    static func hasPending(journalURL: URL, targets: [String: URL]) throws -> Bool {
        let transaction = GamefixTransaction(journalURL: journalURL, targets: targets)
        try transaction.validateConfiguration()
        let marker = try transaction.readSharedMarker()
        let directoryExists = try transaction.validatePrivateDirectory(missingAllowed: true)
        let journal = directoryExists ? try transaction.readJournal() : nil
        if let marker {
            guard let journal, journal.transactionUUID == marker.transactionUUID else {
                throw Failure("transaction-shared-busy", 4)
            }
            return true
        }
        return journal != nil
    }

    static func recover(journalURL: URL, targets: [String: URL]) throws {
        let transaction = GamefixTransaction(journalURL: journalURL, targets: targets)
        try transaction.recover()
    }

    func registerStagedFiles(_ files: [URL: String]) throws {
        guard !files.isEmpty else { return }
        try validateConfiguration()
        try rejectForeignSharedMarker()
        guard try validatePrivateDirectory(missingAllowed: false) else {
            throw Failure("transaction-journal-directory-unavailable", 5)
        }
        var journal = try readJournal() ?? Journal(phase: .active, operations: [])
        guard journal.phase == .active else { throw Failure("transaction-already-committed", 5) }

        for (url, hash) in files.sorted(by: { $0.key.path < $1.key.path }) {
            let stage = try registeredStage(for: url, hash: hash)
            if let existing = journal.registeredStages.first(where: {
                $0.parent == stage.parent && $0.staging == stage.staging
            }) {
                guard existing.hash == stage.hash else { throw Failure("transaction-staging-reused", 5) }
                continue
            }
            guard journal.registeredStages.count < gamefixMaximumRegisteredStages else {
                throw Failure("transaction-staging-limit", 5)
            }
            journal.registeredStages.append(stage)
        }
        _ = try ensureTransactionUUID(&journal)
        try writeJournal(journal)
    }

    func install(_ staging: URL, at destination: URL, hash: String) throws {
        try validateConfiguration()
        try rejectForeignSharedMarker()
        let key = try targetKey(for: destination)
        let destination = destination.standardizedFileURL
        let staging = try checkedStaging(staging, beside: destination)
        let newHash = try normalizedHash(hash)
        try syncStagedFile(staging, expectedHash: newHash)
        guard try fileHash(destination) == nil else { throw Failure("target-appeared", 4) }

        try append(Operation(kind: .install, target: key, staging: staging.lastPathComponent,
                             oldHash: nil, newHash: newHash))
        try rename(staging, destination, flags: UInt32(Darwin.RENAME_EXCL), token: "target-appeared")
        try syncDirectory(destination.deletingLastPathComponent())
        gamefixAfterTargetMutation()
        guard try fileHash(destination) == newHash else { throw Failure("installed-file-mismatch", 5) }
    }

    func swap(_ staging: URL, with destination: URL, oldHash: String, newHash: String) throws {
        try validateConfiguration()
        try rejectForeignSharedMarker()
        let key = try targetKey(for: destination)
        let destination = destination.standardizedFileURL
        let staging = try checkedStaging(staging, beside: destination)
        let oldHash = try normalizedHash(oldHash)
        let newHash = try normalizedHash(newHash)
        guard try fileHash(destination) == oldHash else { throw Failure("target-changed", 4) }
        try syncStagedFile(staging, expectedHash: newHash)

        try append(Operation(kind: .swap, target: key, staging: staging.lastPathComponent,
                             oldHash: oldHash, newHash: newHash))
        try rename(staging, destination, flags: UInt32(Darwin.RENAME_SWAP), token: "atomic-swap-unavailable")
        try syncDirectory(destination.deletingLastPathComponent())
        gamefixAfterTargetMutation()
        guard try fileHash(destination) == newHash, try fileHash(staging) == oldHash else {
            throw Failure("target-changed-during-swap", 4)
        }
    }

    func park(_ destination: URL, expectedHash: String) throws {
        try validateConfiguration()
        try rejectForeignSharedMarker()
        let key = try targetKey(for: destination)
        let destination = destination.standardizedFileURL
        let expectedHash = try normalizedHash(expectedHash)
        guard try fileHash(destination) == expectedHash else { throw Failure("owned-file-changed", 4) }

        let staging = try unusedStageURL(beside: destination)
        try append(Operation(kind: .park, target: key, staging: staging.lastPathComponent,
                             oldHash: expectedHash, newHash: nil))
        try rename(destination, staging, flags: UInt32(Darwin.RENAME_EXCL), token: "atomic-remove-unavailable")
        try syncDirectory(destination.deletingLastPathComponent())
        gamefixAfterTargetMutation()
        guard try fileHash(staging) == expectedHash else { throw Failure("owned-file-changed-during-remove", 4) }
    }

    func rollback() -> Bool {
        do {
            try validateConfiguration()
            let marker = try readSharedMarker()
            guard try validatePrivateDirectory(missingAllowed: true) else {
                return marker == nil
            }
            guard var journal = try readJournal() else { return marker == nil }
            if journal.phase == .released {
                try completeReleasedJournal(journal)
                return true
            }
            if let marker {
                guard journal.transactionUUID == marker.transactionUUID else { return false }
            } else if !journal.operations.isEmpty {
                _ = try ensureTransactionUUID(&journal)
                try claimSharedMarker(transactionUUID: journal.transactionUUID!)
            }
            guard journal.phase == .active else { return false }
            try rollback(journal)
            return true
        } catch {
            return false
        }
    }

    func finish() throws {
        try validateConfiguration()
        guard var journal = try readJournal() else { return }
        guard journal.phase == .active else { throw Failure("transaction-already-committed", 5) }
        try guardOrClaimSharedMarker(&journal)
        try validateCommittedResult(journal, allowCleanedStages: false)
        var committed = journal
        committed.phase = .committed
        try writeJournal(committed)
        try finalizeCommitted(committed)
    }

    private func recover() throws {
        try validateConfiguration()
        let marker = try readSharedMarker()
        guard try validatePrivateDirectory(missingAllowed: true) else {
            if marker != nil { throw Failure("transaction-shared-busy", 4) }
            return
        }
        guard var journal = try readJournal() else {
            if marker != nil { throw Failure("transaction-shared-busy", 4) }
            return
        }
        if journal.phase == .released {
            try completeReleasedJournal(journal)
            return
        }
        if let marker {
            guard journal.transactionUUID == marker.transactionUUID else {
                throw Failure("transaction-shared-busy", 4)
            }
        } else if !journal.operations.isEmpty {
            try guardOrClaimSharedMarker(&journal)
        }
        if journal.phase == .committed { try finalizeCommitted(journal) }
        else { try rollback(journal) }
    }

    private func append(_ operation: Operation) throws {
        try validateConfiguration()
        guard try validatePrivateDirectory(missingAllowed: false) else {
            throw Failure("transaction-journal-directory-unavailable", 5)
        }
        var journal = try readJournal() ?? Journal(phase: .active, operations: [])
        guard journal.phase == .active else { throw Failure("transaction-already-committed", 5) }
        guard journal.operations.count < gamefixMaximumOperations else {
            throw Failure("transaction-operation-limit", 5)
        }
        guard !journal.operations.contains(where: { $0.staging == operation.staging }) else {
            throw Failure("transaction-staging-reused", 5)
        }
        guard !journal.operations.contains(where: { $0.target == operation.target }) else {
            throw Failure("transaction-target-reused", 5)
        }
        try validate(operation)
        _ = try ensureTransactionUUID(&journal)
        try writeJournal(journal)
        try claimSharedMarker(transactionUUID: journal.transactionUUID!)
        journal.operations.append(operation)
        try writeJournal(journal)
    }

    private func rollback(_ journal: Journal) throws {
        for operation in journal.operations.reversed() { try undo(operation) }
        try cleanupRegisteredStages(journal)
        try releaseTransaction(journal)
    }

    private func undo(_ operation: Operation) throws {
        try validate(operation)
        guard let destination = targets[operation.target] else { throw Failure("transaction-target-unknown", 5) }
        let staging = destination.deletingLastPathComponent().appending(path: operation.staging)
        let targetHash = try fileHash(destination)
        let stageHash = try fileHash(staging)

        switch operation.kind {
        case .install:
            guard let newHash = operation.newHash else { throw Failure("transaction-journal-invalid", 5) }
            if targetHash == newHash && stageHash == nil {
                try rename(destination, staging, flags: UInt32(Darwin.RENAME_EXCL), token: "rollback-failed")
                try syncDirectory(destination.deletingLastPathComponent())
                gamefixAfterTargetMutation()
            } else if targetHash == nil && (stageHash == newHash || stageHash == nil) {
                // Not applied, or already moved back by an interrupted recovery.
            } else {
                throw Failure("transaction-recovery-conflict", 5)
            }
            if try fileHash(staging) == newHash { try removeOwned(staging, expectedHash: newHash) }

        case .swap:
            guard let oldHash = operation.oldHash, let newHash = operation.newHash else {
                throw Failure("transaction-journal-invalid", 5)
            }
            if targetHash == newHash && stageHash == oldHash {
                try rename(staging, destination, flags: UInt32(Darwin.RENAME_SWAP), token: "rollback-failed")
                try syncDirectory(destination.deletingLastPathComponent())
                gamefixAfterTargetMutation()
            } else if targetHash == oldHash && (stageHash == newHash || stageHash == nil) {
                // Not applied, or already reversed by an interrupted recovery.
            } else {
                throw Failure("transaction-recovery-conflict", 5)
            }
            if try fileHash(staging) == newHash { try removeOwned(staging, expectedHash: newHash) }

        case .park:
            guard let oldHash = operation.oldHash else { throw Failure("transaction-journal-invalid", 5) }
            if targetHash == nil && stageHash == oldHash {
                try rename(staging, destination, flags: UInt32(Darwin.RENAME_EXCL), token: "rollback-failed")
                try syncDirectory(destination.deletingLastPathComponent())
                gamefixAfterTargetMutation()
            } else if targetHash == oldHash && stageHash == nil {
                // Not applied, or already restored by an interrupted recovery.
            } else {
                throw Failure("transaction-recovery-conflict", 5)
            }
        }
    }

    private func validateCommittedResult(_ journal: Journal, allowCleanedStages: Bool) throws {
        var finalOperations: [String: Operation] = [:]
        for operation in journal.operations {
            try validate(operation)
            finalOperations[operation.target] = operation
            guard let destination = targets[operation.target] else {
                throw Failure("transaction-target-unknown", 5)
            }
            let staging = destination.deletingLastPathComponent().appending(path: operation.staging)
            let stageHash = try fileHash(staging)
            switch operation.kind {
            case .install:
                guard stageHash == nil else { throw Failure("transaction-result-mismatch", 5) }
            case .swap, .park:
                guard stageHash == operation.oldHash || (allowCleanedStages && stageHash == nil) else {
                    throw Failure("transaction-result-mismatch", 5)
                }
            }
        }
        for (key, operation) in finalOperations {
            guard let destination = targets[key] else { throw Failure("transaction-target-unknown", 5) }
            let actual = try fileHash(destination)
            switch operation.kind {
            case .install, .swap:
                guard actual == operation.newHash else { throw Failure("transaction-result-mismatch", 5) }
            case .park:
                guard actual == nil else { throw Failure("transaction-result-mismatch", 5) }
            }
        }
    }

    private func finalizeCommitted(_ journal: Journal) throws {
        guard journal.phase == .committed else { throw Failure("transaction-journal-invalid", 5) }
        try validateCommittedResult(journal, allowCleanedStages: true)
        for operation in journal.operations where operation.kind != .install {
            guard let destination = targets[operation.target], let oldHash = operation.oldHash else {
                throw Failure("transaction-journal-invalid", 5)
            }
            let staging = destination.deletingLastPathComponent().appending(path: operation.staging)
            if try fileHash(staging) == oldHash { try removeOwned(staging, expectedHash: oldHash) }
            else if try fileHash(staging) != nil { throw Failure("transaction-recovery-conflict", 5) }
        }
        try cleanupRegisteredStages(journal)
        try releaseTransaction(journal)
    }

    private func releaseTransaction(_ journal: Journal) throws {
        var released = journal
        if released.transactionUUID == nil {
            released.transactionUUID = UUID().uuidString.lowercased()
        }
        released.phase = .released
        try writeJournal(released)
        try completeReleasedJournal(released)
    }

    private func completeReleasedJournal(_ journal: Journal) throws {
        if let transactionUUID = journal.transactionUUID,
           try removeSharedMarker(transactionUUID: transactionUUID) {
            gamefixAfterSharedRelease()
        }
        try removeJournal()
    }

    private func cleanupRegisteredStages(_ journal: Journal) throws {
        for registered in journal.registeredStages {
            let staging = try registeredStageURL(registered)
            if try fileHash(staging) == registered.hash {
                try removeOwned(staging, expectedHash: registered.hash)
            } else if try fileHash(staging) != nil {
                throw Failure("transaction-recovery-conflict", 5)
            }
        }
    }

    private func registeredStage(for url: URL, hash: String) throws -> RegisteredStage {
        let staging = url.standardizedFileURL
        guard staging.isFileURL, staging.path.hasPrefix("/"), isValidStageName(staging.lastPathComponent) else {
            throw Failure("transaction-staging-invalid", 5)
        }
        let parentPath = staging.deletingLastPathComponent().path
        let stableParentKeys = [
            "dll:d3d11.dll", "dll:dxgi.dll", "dll:d3d10core.dll",
            "helper:wrapper", "helper:real", "helper:checksum", "helper:license",
            "state:shared", "state:prefix"
        ]
        guard let parent = stableParentKeys.first(where: {
            targets[$0]?.deletingLastPathComponent().path == parentPath
        }) else { throw Failure("transaction-staging-parent-unknown", 4) }
        let normalized = try normalizedHash(hash)
        try validateTargetParent(staging)
        try syncStagedFile(staging, expectedHash: normalized)
        return RegisteredStage(parent: parent, staging: staging.lastPathComponent, hash: normalized)
    }

    private func registeredStageURL(_ stage: RegisteredStage) throws -> URL {
        guard let parentTarget = targets[stage.parent], isAllowedTargetKey(stage.parent),
              isValidStageName(stage.staging),
              (try? normalizedHash(stage.hash)) == stage.hash
        else { throw Failure("transaction-journal-invalid", 5) }
        let parent = parentTarget.deletingLastPathComponent()
        let staging = parent.appending(path: stage.staging)
        guard staging.deletingLastPathComponent().path == parent.path else {
            throw Failure("transaction-journal-invalid", 5)
        }
        try validateTargetParent(staging)
        return staging
    }

    private func validate(_ operation: Operation) throws {
        guard let destination = targets[operation.target], isAllowedTargetKey(operation.target),
              isValidStageName(operation.staging)
        else { throw Failure("transaction-journal-invalid", 5) }
        let staging = destination.deletingLastPathComponent().appending(path: operation.staging)
        guard staging.deletingLastPathComponent().path == destination.deletingLastPathComponent().path else {
            throw Failure("transaction-journal-invalid", 5)
        }
        try validateTargetParent(destination)
        switch operation.kind {
        case .install:
            guard operation.oldHash == nil, let newHash = operation.newHash,
                  (try? normalizedHash(newHash)) == newHash else {
                throw Failure("transaction-journal-invalid", 5)
            }
        case .swap:
            guard let oldHash = operation.oldHash, let newHash = operation.newHash,
                  (try? normalizedHash(oldHash)) == oldHash,
                  (try? normalizedHash(newHash)) == newHash, oldHash != newHash else {
                throw Failure("transaction-journal-invalid", 5)
            }
        case .park:
            guard let oldHash = operation.oldHash, operation.newHash == nil,
                  (try? normalizedHash(oldHash)) == oldHash else {
                throw Failure("transaction-journal-invalid", 5)
            }
        }
    }

    private func targetKey(for destination: URL) throws -> String {
        let path = destination.standardizedFileURL.path
        let matches = targets.filter { $0.value.path == path }.map(\.key)
        guard matches.count == 1, let key = matches.first, isAllowedTargetKey(key),
              targetLeaf(for: key) == destination.standardizedFileURL.lastPathComponent
        else { throw Failure("transaction-target-unknown", 4) }
        try validateTargetParent(destination.standardizedFileURL)
        guard destination.standardizedFileURL.path != journalURL.path else {
            throw Failure("transaction-target-is-journal", 4)
        }
        return key
    }

    private func checkedStaging(_ staging: URL, beside destination: URL) throws -> URL {
        let staging = staging.standardizedFileURL
        guard staging.isFileURL, staging.path.hasPrefix("/"), isValidStageName(staging.lastPathComponent),
              staging.deletingLastPathComponent().path == destination.deletingLastPathComponent().path
        else { throw Failure("transaction-staging-invalid", 5) }
        try validateTargetParent(staging)
        return staging
    }

    private func unusedStageURL(beside destination: URL) throws -> URL {
        for _ in 0..<8 {
            let candidate = destination.deletingLastPathComponent()
                .appending(path: gamefixStagePrefix + UUID().uuidString + ".tmp")
            if try fileHash(candidate) == nil { return candidate }
        }
        throw Failure("transaction-staging-unavailable", 5)
    }

    private func ensureTransactionUUID(_ journal: inout Journal) throws -> String {
        if let transactionUUID = journal.transactionUUID {
            guard isValidTransactionUUID(transactionUUID) else {
                throw Failure("transaction-journal-invalid", 5)
            }
            return transactionUUID
        }
        let transactionUUID = UUID().uuidString.lowercased()
        journal.transactionUUID = transactionUUID
        try writeJournal(journal)
        return transactionUUID
    }

    private func guardOrClaimSharedMarker(_ journal: inout Journal) throws {
        let transactionUUID = try ensureTransactionUUID(&journal)
        if let marker = try readSharedMarker() {
            guard marker.transactionUUID == transactionUUID else {
                throw Failure("transaction-shared-busy", 4)
            }
        } else if !journal.operations.isEmpty {
            try claimSharedMarker(transactionUUID: transactionUUID)
        }
    }

    private func rejectForeignSharedMarker() throws {
        guard let marker = try readSharedMarker() else { return }
        guard let journal = try readJournal(), journal.transactionUUID == marker.transactionUUID else {
            throw Failure("transaction-shared-busy", 4)
        }
    }

    private func claimSharedMarker(transactionUUID: String) throws {
        guard isValidTransactionUUID(transactionUUID) else {
            throw Failure("transaction-journal-invalid", 5)
        }
        if let marker = try readSharedMarker() {
            guard marker.transactionUUID == transactionUUID else {
                throw Failure("transaction-shared-busy", 4)
            }
            return
        }
        try validateTargetParent(sharedMarkerURL)
        let data: Data
        do { data = try JSONEncoder().encode(SharedMarker(transactionUUID: transactionUUID)) }
        catch { throw Failure("transaction-shared-marker-write-failed", 5) }

        for _ in 0..<8 {
            let temporary = sharedMarkerURL.deletingLastPathComponent()
                .appending(path: gamefixSharedMarkerTempPrefix + UUID().uuidString + ".tmp")
            let fd = temporary.path.withCString {
                open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o644))
            }
            if fd < 0 {
                if errno == EEXIST { continue }
                throw Failure("transaction-shared-marker-write-failed", 5)
            }
            do {
                try writeAll(data, fd: fd)
                guard fchmod(fd, mode_t(0o644)) == 0 else {
                    throw Failure("transaction-shared-marker-write-failed", 5)
                }
                var info = stat()
                guard fstat(fd, &info) == 0,
                      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      info.st_mode & mode_t(0o777) == mode_t(0o644),
                      info.st_size >= 0, info.st_size <= off_t(gamefixMaximumSharedMarkerBytes)
                else { throw Failure("transaction-shared-marker-unsafe", 4) }
                guard fsync(fd) == 0 else { throw Failure("transaction-shared-marker-sync-failed", 5) }
                close(fd)
            } catch {
                close(fd)
                _ = unlink(temporary.path)
                throw error
            }

            let result = temporary.path.withCString { from in
                sharedMarkerURL.path.withCString { to in
                    Darwin.renamex_np(from, to, UInt32(Darwin.RENAME_EXCL))
                }
            }
            if result != 0 {
                let renameError = errno
                _ = unlink(temporary.path)
                if renameError == EEXIST, let marker = try readSharedMarker() {
                    guard marker.transactionUUID == transactionUUID else {
                        throw Failure("transaction-shared-busy", 4)
                    }
                    return
                }
                throw Failure("transaction-shared-marker-write-failed", 5)
            }
            try syncDirectory(sharedMarkerURL.deletingLastPathComponent())
            return
        }
        throw Failure("transaction-shared-marker-write-failed", 5)
    }

    private func readSharedMarker() throws -> SharedMarker? {
        var pathInfo = stat()
        let result = sharedMarkerURL.path.withCString { Darwin.lstat($0, &pathInfo) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw Failure("transaction-shared-marker-unavailable", 5)
        }
        guard pathInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              pathInfo.st_mode & mode_t(0o777) == mode_t(0o644),
              pathInfo.st_size >= 0, pathInfo.st_size <= off_t(gamefixMaximumSharedMarkerBytes)
        else { throw Failure("transaction-shared-marker-unsafe", 4) }

        let fd = sharedMarkerURL.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure("transaction-shared-marker-unavailable", 5)
        }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_mode & mode_t(0o777) == mode_t(0o644),
              opened.st_dev == pathInfo.st_dev, opened.st_ino == pathInfo.st_ino,
              opened.st_size >= 0, opened.st_size <= off_t(gamefixMaximumSharedMarkerBytes)
        else { throw Failure("transaction-shared-marker-unsafe", 4) }

        let data: Data
        do { data = try readBounded(fd: fd, maximum: gamefixMaximumSharedMarkerBytes) }
        catch { throw Failure("transaction-shared-marker-unsafe", 4) }
        let marker: SharedMarker
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["version", "appid", "transactionUUID"])
            else { throw Failure("transaction-shared-marker-unsafe", 4) }
            marker = try JSONDecoder().decode(SharedMarker.self, from: data)
        } catch { throw Failure("transaction-shared-marker-unsafe", 4) }
        guard marker.version == 1, marker.appid == gamefixAppID,
              isValidTransactionUUID(marker.transactionUUID)
        else { throw Failure("transaction-shared-marker-unsafe", 4) }
        return marker
    }

    @discardableResult
    private func removeSharedMarker(transactionUUID: String) throws -> Bool {
        guard let marker = try readSharedMarker(), marker.transactionUUID == transactionUUID else {
            return false
        }
        var info = stat()
        let result = sharedMarkerURL.path.withCString { Darwin.lstat($0, &info) }
        if result != 0 {
            if errno == ENOENT { return false }
            throw Failure("transaction-shared-marker-unavailable", 5)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & mode_t(0o777) == mode_t(0o644)
        else { throw Failure("transaction-shared-marker-unsafe", 4) }
        guard let confirmed = try readSharedMarker(), confirmed.transactionUUID == transactionUUID else {
            return false
        }
        if unlink(sharedMarkerURL.path) != 0 {
            if errno == ENOENT { return false }
            throw Failure("transaction-shared-marker-remove-failed", 5)
        }
        try syncDirectory(sharedMarkerURL.deletingLastPathComponent())
        return true
    }

    private func isValidTransactionUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private func readJournal() throws -> Journal? {
        guard try validatePrivateDirectory(missingAllowed: true) else { return nil }
        var pathInfo = stat()
        let result = journalURL.path.withCString { Darwin.lstat($0, &pathInfo) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw Failure("transaction-journal-unavailable", 5)
        }
        guard pathInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), pathInfo.st_uid == geteuid(),
              pathInfo.st_mode & mode_t(0o777) == mode_t(0o600),
              pathInfo.st_size >= 0, pathInfo.st_size <= gamefixMaximumJournalBytes
        else { throw Failure("transaction-journal-unsafe", 4) }

        let fd = journalURL.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { throw Failure("transaction-journal-unavailable", 5) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_uid == geteuid(), opened.st_mode & mode_t(0o777) == mode_t(0o600),
              opened.st_dev == pathInfo.st_dev, opened.st_ino == pathInfo.st_ino
        else { throw Failure("transaction-journal-unsafe", 4) }
        let data = try readBounded(fd: fd, maximum: gamefixMaximumJournalBytes)
        let journal: Journal
        do { journal = try JSONDecoder().decode(Journal.self, from: data) }
        catch { throw Failure("transaction-journal-invalid", 5) }
        guard journal.version == 1, journal.operations.count <= gamefixMaximumOperations,
              journal.registeredStages.count <= gamefixMaximumRegisteredStages
        else {
            throw Failure("transaction-journal-invalid", 5)
        }
        if let transactionUUID = journal.transactionUUID,
           !isValidTransactionUUID(transactionUUID) {
            throw Failure("transaction-journal-invalid", 5)
        }
        // A later transaction may have changed these targets after this marker was removed.
        if journal.phase == .released { return journal }
        var stages = Set<String>()
        var operationTargets = Set<String>()
        for operation in journal.operations {
            guard stages.insert(operation.staging).inserted,
                  operationTargets.insert(operation.target).inserted
            else { throw Failure("transaction-journal-invalid", 5) }
            try validate(operation)
        }
        var registeredPaths = Set<String>()
        for registered in journal.registeredStages {
            let staging = try registeredStageURL(registered)
            guard registeredPaths.insert(staging.path).inserted else {
                throw Failure("transaction-journal-invalid", 5)
            }
        }
        for operation in journal.operations {
            guard let target = targets[operation.target] else {
                throw Failure("transaction-journal-invalid", 5)
            }
            let operationParent = target.deletingLastPathComponent().path
            if let registered = journal.registeredStages.first(where: {
                guard let parent = targets[$0.parent] else { return false }
                return parent.deletingLastPathComponent().path == operationParent
                    && $0.staging == operation.staging
            }) {
                guard operation.kind != .park, registered.hash == operation.newHash else {
                    throw Failure("transaction-journal-invalid", 5)
                }
            }
        }
        return journal
    }

    private func writeJournal(_ journal: Journal) throws {
        guard try validatePrivateDirectory(missingAllowed: false) else {
            throw Failure("transaction-journal-directory-unavailable", 5)
        }
        guard let transactionUUID = journal.transactionUUID,
              isValidTransactionUUID(transactionUUID)
        else { throw Failure("transaction-journal-invalid", 5) }
        let data: Data
        do { data = try JSONEncoder().encode(journal) }
        catch { throw Failure("transaction-journal-write-failed", 5) }
        guard data.count <= gamefixMaximumJournalBytes else { throw Failure("transaction-journal-too-large", 5) }

        var temporary: URL?
        for _ in 0..<8 {
            let name = gamefixJournalTempPrefix + UUID().uuidString + ".tmp"
            let candidate = journalURL.deletingLastPathComponent().appending(path: name)
            let fd = candidate.path.withCString {
                open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
            }
            if fd < 0 {
                if errno == EEXIST { continue }
                throw Failure("transaction-journal-write-failed", 5)
            }
            do {
                try writeAll(data, fd: fd)
                guard fchmod(fd, mode_t(0o600)) == 0 else { throw Failure("transaction-journal-write-failed", 5) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
                      info.st_mode & mode_t(0o777) == mode_t(0o600)
                else { throw Failure("transaction-journal-unsafe", 4) }
                guard fsync(fd) == 0 else { throw Failure("transaction-journal-sync-failed", 5) }
                temporary = candidate
            } catch {
                close(fd)
                _ = unlink(candidate.path)
                throw error
            }
            close(fd)
            break
        }
        guard let temporary else { throw Failure("transaction-journal-write-failed", 5) }

        do {
            try validateJournalLeafForReplacement()
            let result = temporary.path.withCString { from in
                journalURL.path.withCString { to in Darwin.renamex_np(from, to, 0) }
            }
            guard result == 0 else { throw Failure("transaction-journal-replace-failed", 5) }
            try syncDirectory(journalURL.deletingLastPathComponent())
        } catch {
            _ = unlink(temporary.path)
            throw error
        }
    }

    private func validateJournalLeafForReplacement() throws {
        var info = stat()
        let result = journalURL.path.withCString { Darwin.lstat($0, &info) }
        if result != 0 {
            if errno == ENOENT { return }
            throw Failure("transaction-journal-unavailable", 5)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
              info.st_mode & mode_t(0o777) == mode_t(0o600)
        else { throw Failure("transaction-journal-unsafe", 4) }
    }

    private func removeJournal() throws {
        try validateJournalLeafForReplacement()
        if unlink(journalURL.path) != 0 {
            if errno == ENOENT { return }
            throw Failure("transaction-journal-remove-failed", 5)
        }
        try syncDirectory(journalURL.deletingLastPathComponent())
    }

    private func validateConfiguration() throws {
        guard journalURL.isFileURL, journalURL.path.hasPrefix("/"),
              journalURL.lastPathComponent == gamefixJournalName,
              journalURL.deletingLastPathComponent().lastPathComponent == gamefixStateDirectoryName,
              let prefixState = targets["state:prefix"], prefixState.lastPathComponent == "state.json",
              prefixState.deletingLastPathComponent().path == journalURL.deletingLastPathComponent().path,
              let sharedState = targets["state:shared"],
              sharedState.lastPathComponent == ".bridgeplay-gta-sa-de-1547000.json"
        else { throw Failure("transaction-configuration-invalid", 4) }

        var seenPaths = Set<String>()
        for (key, url) in targets {
            guard isAllowedTargetKey(key), url.isFileURL, url.path.hasPrefix("/"),
                  !url.pathComponents.contains(".."), !url.pathComponents.contains("."),
                  targetLeaf(for: key) == url.lastPathComponent, url.path != journalURL.path,
                  seenPaths.insert(url.path).inserted
            else { throw Failure("transaction-configuration-invalid", 4) }
            _ = try directoryChainExists(url.deletingLastPathComponent(), missingAllowed: true)
        }
        _ = try directoryChainExists(journalURL.deletingLastPathComponent(), missingAllowed: true)
    }

    private func validatePrivateDirectory(missingAllowed: Bool) throws -> Bool {
        let directory = journalURL.deletingLastPathComponent()
        guard try directoryChainExists(directory, missingAllowed: missingAllowed) else { return false }
        var info = stat()
        guard directory.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid(),
              info.st_mode & mode_t(0o777) == mode_t(0o700)
        else { throw Failure("transaction-private-directory-unsafe", 4) }
        return true
    }

    private func validateTargetParent(_ url: URL) throws {
        guard try directoryChainExists(url.deletingLastPathComponent(), missingAllowed: false) else {
            throw Failure("transaction-target-directory-unavailable", 5)
        }
    }

    private func directoryChainExists(_ directory: URL, missingAllowed: Bool) throws -> Bool {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.pathComponents.contains(".."), !directory.pathComponents.contains(".")
        else { throw Failure("transaction-path-invalid", 4) }
        var components = directory.pathComponents
        var usedAppleAlias = false
        if components.count > 1, let alias = components[1] as String?,
           ["var", "tmp", "etc"].contains(alias) {
            let aliasURL = URL(fileURLWithPath: "/" + alias)
            var aliasInfo = stat()
            guard aliasURL.path.withCString({ Darwin.lstat($0, &aliasInfo) }) == 0,
                  aliasInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
                  aliasInfo.st_uid == 0
            else { throw Failure("transaction-symlink-or-file-ancestor", 4) }
            var linkBytes = [CChar](repeating: 0, count: Int(PATH_MAX))
            let linkLength = aliasURL.path.withCString {
                Darwin.readlink($0, &linkBytes, linkBytes.count)
            }
            guard linkLength > 0 else { throw Failure("transaction-path-invalid", 4) }
            let linkTarget = String(decoding: linkBytes.prefix(linkLength).map { UInt8(bitPattern: $0) },
                                    as: UTF8.self)
            let expectedTarget = "private/" + alias
            guard linkTarget == expectedTarget || linkTarget == "/" + expectedTarget else {
                throw Failure("transaction-symlink-or-file-ancestor", 4)
            }
            components[1] = "private"
            components.insert(alias, at: 2)
            usedAppleAlias = true
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.dropFirst().enumerated() {
            current.append(path: component, directoryHint: .isDirectory)
            var info = stat()
            var path = current.path
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            let result = path.withCString { Darwin.lstat($0, &info) }
            if result != 0 {
                if errno == ENOENT && missingAllowed { return false }
                throw Failure("transaction-directory-unavailable", 5)
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw Failure("transaction-symlink-or-file-ancestor", 4)
            }
            if usedAppleAlias && index < 2 && info.st_uid != 0 {
                throw Failure("transaction-symlink-or-file-ancestor", 4)
            }
        }
        return true
    }

    private func targetLeaf(for key: String) -> String? {
        if key.hasPrefix("dll:") { return String(key.dropFirst("dll:".count)) }
        switch key {
        case "helper:wrapper": return "SocialClubHelper.exe"
        case "helper:real": return "SocialClubHelper_real.exe"
        case "helper:checksum": return "SocialClubHelper_real.exe.sha256"
        case "helper:license": return "SocialClubHelper.bridgeplay.LICENSE"
        case "state:shared": return ".bridgeplay-gta-sa-de-1547000.json"
        case "state:prefix": return "state.json"
        default:
            guard key.hasPrefix("helper:archive:") else { return nil }
            return String(key.dropFirst("helper:archive:".count))
        }
    }

    private func isAllowedTargetKey(_ key: String) -> Bool {
        if key.hasPrefix("dll:") {
            return ["dll:d3d11.dll", "dll:dxgi.dll", "dll:d3d10core.dll"].contains(key)
        }
        switch key {
        case "helper:wrapper", "helper:real", "helper:checksum", "helper:license",
             "state:shared", "state:prefix":
            return true
        default:
            guard key.hasPrefix("helper:archive:"), let filename = targetLeaf(for: key) else { return false }
            let prefix = "SocialClubHelper_real.previous."
            guard filename.hasPrefix(prefix), filename.hasSuffix(".exe") else { return false }
            let hash = filename.dropFirst(prefix.count).dropLast(".exe".count)
            return hash.count == 16 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        }
    }

    private func isValidStageName(_ name: String) -> Bool {
        guard name.hasPrefix(gamefixStagePrefix), name.hasSuffix(".tmp") else { return false }
        let uuid = name.dropFirst(gamefixStagePrefix.count).dropLast(".tmp".count)
        return UUID(uuidString: String(uuid)) != nil
    }

    private func normalizedHash(_ hash: String) throws -> String {
        let value = hash.lowercased()
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else {
            throw Failure("transaction-hash-invalid", 5)
        }
        return value
    }

    private func fileHash(_ url: URL) throws -> String? {
        var pathInfo = stat()
        let result = url.path.withCString { Darwin.lstat($0, &pathInfo) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw Failure("transaction-file-unavailable", 5)
        }
        guard pathInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw Failure("transaction-file-not-regular", 4)
        }
        let fd = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { throw Failure("transaction-file-unavailable", 5) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_dev == pathInfo.st_dev, opened.st_ino == pathInfo.st_ino,
              opened.st_size >= 0, opened.st_size <= off_t(gamefixMaximumFileBytes)
        else { throw Failure("transaction-file-unsafe-or-oversized", 4) }

        return try hashFileDescriptor(fd, expectedSize: opened.st_size)
    }

    private func syncStagedFile(_ url: URL, expectedHash: String) throws {
        var pathInfo = stat()
        let result = url.path.withCString { Darwin.lstat($0, &pathInfo) }
        guard result == 0, pathInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw Failure("staged-file-unavailable", 5)
        }
        let fd = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { throw Failure("staged-file-unavailable", 5) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_dev == pathInfo.st_dev, opened.st_ino == pathInfo.st_ino,
              opened.st_size >= 0, opened.st_size <= off_t(gamefixMaximumFileBytes)
        else { throw Failure("transaction-file-unsafe-or-oversized", 4) }
        guard try hashFileDescriptor(fd, expectedSize: opened.st_size) == expectedHash else {
            throw Failure("staged-file-mismatch", 5)
        }
        guard fsync(fd) == 0 else { throw Failure("staged-file-sync-failed", 5) }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private func hashFileDescriptor(_ fd: Int32, expectedSize: off_t) throws -> String {
        var hasher = SHA256()
        var total: Int64 = 0
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = bytes.withUnsafeMutableBufferPointer { buffer in
                Darwin.read(fd, buffer.baseAddress, buffer.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure("transaction-file-read-failed", 5) }
            if count == 0 { break }
            total += Int64(count)
            guard total <= Int64(gamefixMaximumFileBytes) else {
                throw Failure("transaction-file-unsafe-or-oversized", 4)
            }
            hasher.update(data: Data(bytes.prefix(count)))
        }
        guard total == Int64(expectedSize) else { throw Failure("transaction-file-changed", 4) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func readBounded(fd: Int32, maximum: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(16 * 1024, maximum + 1))
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure("transaction-journal-read-failed", 5) }
            if count == 0 { break }
            guard data.count + count <= maximum else { throw Failure("transaction-journal-too-large", 5) }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure("transaction-journal-write-failed", 5) }
                offset += count
            }
        }
    }

    private func rename(_ source: URL, _ destination: URL, flags: UInt32, token: String) throws {
        let result = source.path.withCString { from in
            destination.path.withCString { to in Darwin.renamex_np(from, to, flags) }
        }
        guard result == 0 else { throw Failure(token, 5) }
    }

    private func removeOwned(_ url: URL, expectedHash: String) throws {
        guard try fileHash(url) == expectedHash else { throw Failure("transaction-recovery-conflict", 5) }
        guard unlink(url.path) == 0 else { throw Failure("transaction-file-remove-failed", 5) }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private func syncDirectory(_ url: URL) throws {
        let fd = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { throw Failure("transaction-directory-sync-failed", 5) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              fsync(fd) == 0 else { throw Failure("transaction-directory-sync-failed", 5) }
    }
}

private func gamefixAfterTargetMutation() {
    #if GTA_FIXTURE_CRASH
    gamefixFixtureCrashLock.lock()
    gamefixFixtureMutationCount += 1
    let count = gamefixFixtureMutationCount
    gamefixFixtureCrashLock.unlock()
    if let value = ProcessInfo.processInfo.environment["GAMEFIX_TEST_CRASH_AFTER"],
       let requested = Int(value), requested > 0, count == requested {
        _ = Darwin.kill(getpid(), SIGKILL)
        _exit(128 + SIGKILL)
    }
    #endif
}

private func gamefixAfterSharedRelease() {
    #if GTA_FIXTURE_CRASH
    if ProcessInfo.processInfo.environment["GAMEFIX_TEST_CRASH_PHASE"] == "after-shared-release" {
        _ = Darwin.kill(getpid(), SIGKILL)
        _exit(128 + SIGKILL)
    }
    #endif
}
