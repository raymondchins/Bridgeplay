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
        modifications: SteamModifications = .shared,
        stopClient: SteamInstaller.ClientStopper = { app, onStopping in
            try SteamBundle.stopClient(app: app, step: String(localized: "Repair Steam"), onStopping: onStopping)
        },
        register: SteamInstaller.BundleRegistrar = { SteamBundle.register($0) },
        runningBuild: @Sendable () -> String? = { RunnerInstaller.runningBuild() },
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
            guard let build = runningBuild() else { return }
            throw StepFailure(step: step, detail: String(localized: "A game or Wine tool is running on build \(build). Quit it before repairing Steam."))
        }
        try refuseRunningGame()

        let staged = try await stage(bundle, bases: manifest.bases, downloads: downloads, report: report)

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
        work suppliedWork: URL? = nil,
        report: @Sendable (RepairPhase) -> Void = { _ in }
    ) async throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: downloads, withIntermediateDirectories: true)

        let archive = try await PinnedDownload.obtain(
            file: bundle.file, sha256: bundle.sha256, bases: bases, into: downloads, step: step
        ) { report(.downloading($0)) }

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
