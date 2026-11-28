// Logic for the Repair button

import Foundation

enum RepairPhase: Sendable {
    case downloading(PinnedDownload.Progress)
    case unpacking
    case checking
    case stoppingClient
    case replacing
    case clearingInsert
    case removingUpdateBlock
    case registering
    case finished

    var label: String {
        switch self {
        case .downloading(let progress): progress.label
        case .unpacking: String(localized: "Unpacking")
        case .checking: String(localized: "Verifying")
        case .stoppingClient: String(localized: "Stopping Steam")
        case .replacing: String(localized: "Restoring Steam")
        case .clearingInsert: String(localized: "Cleaning up")
        case .removingUpdateBlock: String(localized: "Cleaning up")
        case .registering: String(localized: "Finishing up")
        case .finished: String(localized: "Done")
        }
    }
}

struct RepairOutcome: Sendable {
    let stoppedClient: Bool
}

enum SteamRepair {

    static let valveTeam = "MXGJJ98X76"
    static let valveIdentifier = "com.valvesoftware.steam"

    static let step = String(localized: "Repair Steam")

    static func run(
        manifest suppliedManifest: ValvePackageManifest? = nil,
        app: URL = SupportPaths.Steam.app,
        innerPlist: URL = SupportPaths.Steam.innerInfoPlist,
        updateBlocks: [URL] = UpdateBlock.paths,
        backups: URL = SupportPaths.backups,
        downloads: URL = SupportPaths.packageDownloads,
        kept: URL? = SupportPaths.steamRestore,
        modifications: SteamModifications = .shared,
        stopClient: SteamInstaller.ClientStopper = { app, onStopping in
            try SteamBundle.stopClient(app: app, step: String(localized: "Repair Steam"), onStopping: onStopping)
        },
        register: SteamInstaller.BundleRegistrar = { SteamBundle.register($0) },
        busyRunner: @Sendable () -> RunnerActivity? = { RunnerInstaller.activity() },
        report: @escaping @Sendable (RepairPhase) -> Void = { _ in }
    ) async throws -> RepairOutcome {
        let manifest = try suppliedManifest ?? ValvePackageManifest.bundled()
        guard let bundle = manifest.bundle else {
            throw StepFailure(
                step: step,
                detail: String(localized: "This copy of Bridgeplay cannot repair Steam. Please reinstall Bridgeplay.")
            )
        }

        // Quitting Steam can take a running game with it.
        func refuseRunningGame() throws {
            guard let busy = busyRunner() else { return }
            throw busy.refusal(
                step: step,
                plain: String(localized: "A game or Wine tool is running on build \(busy.build). Quit it before repairing Steam."),
                named: String(localized: "A game or Wine tool is running on build \(busy.builds): \(busy.names). Quit it before repairing Steam."))
        }
        try refuseRunningGame()

        let staged = try await stage(bundle, bases: manifest.bases, downloads: downloads, kept: kept, report: report)

        report(.checking)
        try verifyValveSignature(staged)

        // A game can start during the download.
        try refuseRunningGame()
        let stopped = try stopClient(app) { report(.stoppingClient) }

        try modifications.prepare()
        report(.replacing)
        try replace(app, with: staged)

        try verifyValveSignature(app)
        let plist = app.appending(path: "Contents/Info.plist")
        if let insert = SteamBundle.currentInsert(at: plist), !insert.isEmpty {
            AppLog.note("repair: restored bundle still declares \(insert)")
            throw StepFailure(
                step: step,
                detail: String(localized: "Steam could not be fully restored. Please run Repair Steam again.")
            )
        }

        _ = try modifications.retireIfClean(app)

        report(.clearingInsert)
        _ = try clearInsert(at: innerPlist)

        report(.removingUpdateBlock)
        _ = try UpdateBlock.remove(from: updateBlocks)

        report(.registering)
        register(app)

        _ = try removeStaleBackup(from: backups)

        report(.finished)
        return RepairOutcome(stoppedClient: stopped)
    }

    static func stage(
        _ bundle: ValveBundle,
        bases: [URL],
        downloads: URL,
        kept: URL? = nil,
        work suppliedWork: URL? = nil,
        report: @Sendable (RepairPhase) -> Void = { _ in }
    ) async throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: downloads, withIntermediateDirectories: true)

        let archive: URL
        if let held = kept.flatMap({ keptArchive(bundle, in: $0) }) {
            report(.downloading(.reusing))
            archive = held
        } else {
            archive = try await PinnedDownload.obtain(
                file: bundle.file, sha256: bundle.sha256, bases: bases, into: downloads, step: step
            ) { report(.downloading($0)) }
        }

        report(.unpacking)

        let work = suppliedWork ?? downloads.appending(path: "bundle")
        try? files.removeItem(at: work)
        try files.createDirectory(at: work, withIntermediateDirectories: true)

        try Shell.check("/usr/bin/unzip", [
            "-q", "-o", archive.path(percentEncoded: false), bundle.innerArchive,
            "-d", work.path(percentEncoded: false),
        ])
        try Shell.check("/usr/bin/tar", [
            "-xzf", work.appending(path: bundle.innerArchive).path(percentEncoded: false),
            "-C", work.path(percentEncoded: false),
        ])

        let staged = work.appending(path: bundle.bundleName)
        guard files.fileExists(atPath: staged.path(percentEncoded: false)) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(bundle.innerArchive) did not contain \(bundle.bundleName).")
            )
        }
        return staged
    }

    /// The kept copy of `bundle`, only while it still matches the pin.
    static func keptArchive(_ bundle: ValveBundle, in kept: URL) -> URL? {
        let archive = kept.appending(path: bundle.file)
        return Digest.sha256IfPresent(archive) == bundle.sha256 ? archive : nil
    }

    /// Keeps the pinned bundle in `kept`, from the download cache when it holds it, so Restore
    /// Steam needs no network later. Never throws: without it Repair downloads as before.
    @discardableResult
    static func keepForOffline(
        manifest suppliedManifest: ValvePackageManifest? = nil,
        kept: URL = SupportPaths.steamRestore,
        downloads: URL = SupportPaths.packageDownloads,
        report: @Sendable (RepairPhase) -> Void = { _ in }
    ) async -> Bool {
        guard let manifest = suppliedManifest ?? (try? ValvePackageManifest.bundled()),
              let bundle = manifest.bundle else { return false }
        let files = FileManager.default
        if keptArchive(bundle, in: kept) == nil {
            do {
                try files.createDirectory(at: kept, withIntermediateDirectories: true)
                let cached = downloads.appending(path: bundle.file)
                if Digest.sha256IfPresent(cached) == bundle.sha256 {
                    let pending = kept.appending(path: bundle.file + ".bridgeplay-pending")
                    try? files.removeItem(at: pending)
                    try files.copyItem(at: cached, to: pending)
                    try? files.removeItem(at: kept.appending(path: bundle.file))
                    try files.moveItem(at: pending, to: kept.appending(path: bundle.file))
                } else {
                    _ = try await PinnedDownload.obtain(
                        file: bundle.file, sha256: bundle.sha256, bases: manifest.bases, into: kept, step: step
                    ) { report(.downloading($0)) }
                }
            } catch {
                AppLog.note("repair: Valve's Steam bundle not kept for offline use: \(error.localizedDescription)")
                return false
            }
        }
        // A pin change leaves the previous bundle behind.
        for old in (try? files.contentsOfDirectory(at: kept, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent != bundle.file {
            try? files.removeItem(at: old)
        }
        return keptArchive(bundle, in: kept) != nil
    }

    // Requirements codesign evaluates against the certificate chain itself. Text that
    // `codesign -dvv` prints can be claimed by any self-signed certificate; an anchor in
    // Apple's root plus Valve's team in the leaf cannot.
    static let valveRequirement = "=anchor apple generic and certificate leaf[subject.OU] = \"\(valveTeam)\""
    static let steamRequirement = "=identifier \"\(valveIdentifier)\""

    static func verifyValveSignature(_ url: URL, step: String = step) throws {
        let path = url.path(percentEncoded: false)

        let strict = try Shell.run("/usr/bin/codesign", ["--verify", "--strict", path])
        guard strict.succeeded else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(path) does not verify against its own signature. ")
                    + strict.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let signed = try Shell.run("/usr/bin/codesign", ["--verify", "-R", valveRequirement, path])
        guard signed.succeeded else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(path) is not signed by Valve. Expected TeamIdentifier=\(valveTeam).")
            )
        }
        let named = try Shell.run("/usr/bin/codesign", ["--verify", "-R", steamRequirement, path])
        guard named.succeeded else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(path) is not the Steam bundle. Expected Identifier=\(valveIdentifier).")
            )
        }
    }

    static func replace(
        _ app: URL, with staged: URL,
        verify: (URL) throws -> Void = { try verifyValveSignature($0) }
    ) throws {
        let files = FileManager.default
        try WriteRefused.catching(app) {
            var staged = staged
            let folder = app.deletingLastPathComponent()
            if volume(of: staged) != volume(of: folder) {
                let copy = folder.appending(path: ".\(app.lastPathComponent).\(UUID().uuidString)")
                do {
                    try files.copyItem(at: staged, to: copy)
                    try verify(copy)
                } catch {
                    try? files.removeItem(at: copy)
                    throw error
                }
                staged = copy
            }
            defer { try? files.removeItem(at: staged) }

            guard files.fileExists(atPath: app.path(percentEncoded: false)) else {
                try files.moveItem(at: staged, to: app)
                return
            }
            _ = try files.replaceItemAt(app, withItemAt: staged)
        }
    }

    private static func volume(of url: URL) -> URL? {
        try? url.resourceValues(forKeys: [.volumeURLKey]).volume
    }

    static func clearInsert(at plist: URL) throws -> Bool {
        guard var dict = SteamBundle.readInfoPlist(at: plist),
              var environment = dict[SteamBundle.environmentKey] as? [String: Any]
        else { return false }

        let removed = [SteamBundle.insertKey, SteamBundle.controllerBlockKey]
            .compactMap { environment.removeValue(forKey: $0) }
        guard !removed.isEmpty else { return false }
        dict[SteamBundle.environmentKey] = environment
        try SteamBundle.writeInfoPlist(dict, at: plist)
        return true
    }

    static func removeStaleBackup(from backups: URL) throws -> Bool {
        let files = FileManager.default
        var removed = false
        for name in [SteamBundle.plistBackupName, SteamBundle.legacyPlistBackupName] {
            let backup = backups.appending(path: name)
            let path = backup.path(percentEncoded: false)
            guard files.fileExists(atPath: path) else { continue }
            try WriteRefused.catching(path) { try files.removeItem(at: backup) }
            removed = true
        }
        return removed
    }
}
