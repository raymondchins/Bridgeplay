import Foundation

enum UninstallPhase: Sendable {
    case stoppingClient
    case detaching
    case restoring(RepairPhase)
    case removing
    case finished

    var label: String {
        switch self {
        case .stoppingClient: String(localized: "Stopping Steam")
        case .detaching: String(localized: "Detaching from Steam")
        case .restoring(let phase): phase.label
        case .removing: String(localized: "Removing files")
        case .finished: String(localized: "Done")
        }
    }
}

struct UninstallOutcome: Sendable {
    let steamInstalled: Bool
    let restoredValveSignature: Bool
    let removed: [String]
    var unreachableSteam: [URL] = []
    // Where the user's own game fixes were moved, when there were any.
    var keptGamefixes: URL?
    // Steam's default compatibility tool was ours and was put back or cleared.
    var restoredDefaultTool = false

    var steamNeedsRedownload: Bool { steamInstalled && !restoredValveSignature }

    var keptGamefixesNote: String? {
        keptGamefixes.map {
            String(localized: "Your own game fixes were kept in \($0.path(percentEncoded: false)).")
        }
    }

    var partialRemoval: String? {
        guard !unreachableSteam.isEmpty else { return nil }
        return unreachableSteam.map {
            String(localized: "Bridgeplay has been partially removed, because Steam at \($0.path(percentEncoded: false)) cannot be found. Delete that copy of Steam and reinstall it to fully remove Bridgeplay.")
        }.joined(separator: "\n\n")
    }
}

enum Uninstall {
    static let step = String(localized: "Remove Bridgeplay")

    static func confirmation(modifications: SteamModifications = .shared) -> String {
        let missing = ((try? modifications.paths()) ?? []).filter { SupportPaths.Steam.isUnreachable($0) }
        guard !missing.isEmpty else {
            return String(localized: "Steam is restored to its unmodified state and Bridgeplay is removed, including the compatibility tool that lives inside the Steam folder. Windows games and Steam Play prefixes are not removed.")
        }
        return missing.map {
            String(localized: "Steam at \($0.path(percentEncoded: false)) isn't connected, so Bridgeplay can't be removed from it. All other Bridgeplay data is removed, except for Windows Games and prefixes.")
        }.joined(separator: "\n\n")
    }

    typealias Repair = @Sendable (URL, @escaping @Sendable (RepairPhase) -> Void) async throws -> Void

    typealias Stop = @Sendable (URL, @Sendable () -> Void) throws -> Bool

    // What Bridgeplay leaves outside the folders `directories` names, and where the user's own
    // game fixes go. No default in run(): the live paths are this Mac's, so tests name theirs.
    struct Leftovers: Sendable {
        var gamefixes: URL
        var keptGamefixes: URL
        var steamConfig: URL
        var defaultToolBackup: URL
        var files: [URL]
        var steamRunning: @Sendable () -> Bool
        // The password of Bridgeplay's signing keychain, kept in the login keychain.
        var forgetSigning: @Sendable () -> Void = {}
        var runningBuild: @Sendable () -> String? = { nil }

        static var live: Leftovers {
            Leftovers(
                gamefixes: SupportPaths.gamefixes,
                keptGamefixes: SupportPaths.keptGamefixes,
                steamConfig: SteamDefaultTool.config,
                defaultToolBackup: SteamDefaultTool.backup,
                files: [SupportPaths.homeDir],
                steamRunning: { SteamBundle.isRunningForThisUser },
                forgetSigning: { LocalSigning.forgetPrivateKeychain() },
                runningBuild: { RunnerInstaller.runningBuild() })
        }
    }

    static func run(
        app: URL = SupportPaths.Steam.app,
        innerPlist: URL = SupportPaths.Steam.innerInfoPlist,
        updateBlocks: [URL] = UpdateBlock.paths,
        legacyCompat: URL = SupportPaths.Steam.legacyCompat,
        compatTools: [URL] = SupportPaths.Steam.ourTools(),
        directories: [URL] = [
            SupportPaths.support,
            SupportPaths.caches,
        ],
        libraries: [SteamLibrary] = PrefixStore.libraries(),
        modifications: SteamModifications = .shared,
        lockFolder: URL = SupportPaths.applicationSupport,
        leftovers: Leftovers,
        report: @escaping @Sendable (UninstallPhase) -> Void = { _ in },
        repair: Repair? = nil,
        stop: Stop = { app, onStopping in try SteamBundle.stopClient(app: app, step: step, onStopping: onStopping) }
    ) async throws -> UninstallOutcome {
        let lock = try DeploymentContent.acquireInstallationLock(in: lockFolder, steamFolder: nil)
        defer { lock.release() }
        // Quitting Steam can take a running game with it, and its runner is deleted below.
        if let build = leftovers.runningBuild() {
            throw StepFailure(step: step, detail: String(localized: "A game or Wine tool is running on build \(build). Quit it before removing Bridgeplay."))
        }
        try modifications.prepare()
        let tracked = try modifications.paths()
        let targets = Set((tracked + [app]).map { $0.standardizedFileURL.path }).sorted()
            .map { URL(filePath: $0, directoryHint: .notDirectory) }
        var checkedClient = false
        var steamInstalled = false
        var restored = true
        var missing: [URL] = []
        var failures: [any Error] = []

        for target in targets {
            do {
                let bundleLock = try DeploymentContent.acquireSteamLock(for: target, holding: lock)
                defer { bundleLock.release() }
                switch try SteamModifications.inspect(target) {
                case .unreachable:
                    if tracked.contains(target) { missing.append(target) }
                    continue
                case .absent, .clean:
                    if tracked.contains(target), try !modifications.retireIfClean(target) {
                        throw StepFailure(step: step, detail: String(localized: "Steam could not be fully restored. Please run Repair Steam again."))
                    }
                    continue
                case .modified: break
                }
                try modifications.mark(target)
                _ = try stop(target) { report(.stoppingClient) }
                checkedClient = true
                report(.detaching)
                _ = try detach(from: target, innerPlist: innerPlist, updateBlocks: updateBlocks)
                steamInstalled = true
                do {
                    if let repair {
                        try await repair(target) { report(.restoring($0)) }
                    } else {
                        _ = try await SteamRepair.run(app: target, innerPlist: innerPlist,
                                                     updateBlocks: updateBlocks, modifications: modifications,
                                                     runningBuild: { nil },
                                                     report: { report(.restoring($0)) })
                    }
                } catch { restored = false }
                guard try modifications.retireIfClean(target) else {
                    throw StepFailure(step: step, detail: String(localized: "Steam could not be fully restored. Please run Repair Steam again."))
                }
            } catch {
                if let refusal = error as? WriteRefused {
                    failures.append(refusal)
                } else {
                    failures.append(StepFailure(step: step,
                                                detail: "\(target.path(percentEncoded: false)): \(error.localizedDescription)"))
                }
            }
        }

        if failures.count == 1 { throw failures[0] }
        if !failures.isEmpty {
            throw StepFailure(step: step, detail: failures.map(\.localizedDescription).joined(separator: "\n"))
        }
        if !checkedClient {
            let bundleLock = try DeploymentContent.acquireSteamLock(for: app, holding: lock)
            defer { bundleLock.release() }
            do {
                _ = try stop(app) { report(.stoppingClient) }
            } catch is SteamBundle.OpenInAnotherAccount {
                // Steam.app is left as it is from here on, and another account's Steam does
                // not use this account's files.
            }
        }
        _ = try SteamRepair.clearInsert(at: innerPlist)
        _ = try UpdateBlock.remove(from: updateBlocks)
        // Before the support folder, which holds the backup, goes: a default naming a tool
        // that is about to be deleted would leave Steam pointing at nothing.
        let restoredDefault = try SteamDefaultTool.restore(
            in: leftovers.steamConfig, backup: leftovers.defaultToolBackup, steamRunning: leftovers.steamRunning)
        try SteamDefaultTool.removeGameEntries(in: leftovers.steamConfig, steamRunning: leftovers.steamRunning)
        report(.removing)
        let kept = try keepGamefixes(leftovers.gamefixes, in: leftovers.keptGamefixes)
        var removed = try remove(
            legacyCompat: legacyCompat, compatTools: compatTools, directories: directories + leftovers.files
        )
        leftovers.forgetSigning()
        // The record of modified bundles is kept while one is out of reach, so a later
        // removal still finds it.
        if missing.isEmpty, try modifications.paths().isEmpty {
            removed += try removeItems([modifications.file] + [modifications.legacyFile].compactMap { $0 })
        }
        removed += try removeSteamDLLLinks(to: legacyCompat, in: libraries)
        let templateFailures = RunnerInstaller.removePrefixTemplates(
            keeping: [], libraries: libraries, removingFolder: true)
        if !templateFailures.isEmpty {
            throw StepFailure(step: step, detail: templateFailures.map(\.detail).joined(separator: "\n"))
        }
        report(.finished)
        return UninstallOutcome(
            steamInstalled: steamInstalled,
            restoredValveSignature: restored,
            removed: removed,
            unreachableSteam: missing,
            keptGamefixes: kept,
            restoredDefaultTool: restoredDefault
        )
    }

    static func detach(from app: URL, innerPlist: URL, updateBlocks: [URL]) throws -> Bool {
        let files = FileManager.default
        let plist = app.appending(path: "Contents/Info.plist")
        let dylib = app.appending(path: "Contents/MacOS/\(SupportPaths.dylibName)")
        let executable = app.appending(path: "Contents/MacOS/steam_osx")

        _ = try SteamRepair.clearInsert(at: innerPlist)
        _ = try UpdateBlock.remove(from: updateBlocks)

        let cleared = try SteamRepair.clearInsert(at: plist)
        var droppedDylib = false
        do {
            if files.fileExists(atPath: dylib.path(percentEncoded: false)) {
                try files.removeItem(at: dylib)
                droppedDylib = true
            }

            guard cleared || droppedDylib else { return false }

            try SteamInstaller.adHocSign(executable, step: step)
            try SteamInstaller.adHocSign(app, step: step)
        } catch {
            if cleared || droppedDylib {
                try? SteamInstaller.adHocSign(executable, step: step)
                try? SteamInstaller.adHocSign(app, step: step)
            }
            throw error
        }
        return true
    }

    static func remove(legacyCompat: URL, compatTools: [URL], directories: [URL]) throws -> [String] {
        try removeItems([legacyCompat] + compatTools + directories)
    }

    private static func removeItems(_ targets: [URL]) throws -> [String] {
        let files = FileManager.default
        var removed: [String] = []

        for target in targets {
            let path = target.path(percentEncoded: false)
            guard files.fileExists(atPath: path) else { continue }
            try WriteRefused.catching(path) { try files.removeItem(at: target) }
            removed.append(target.lastPathComponent)
        }
        return removed
    }

    // The user's own overrides are theirs: they are moved out of the folder about to be
    // deleted rather than deleted with it. An empty folder is not worth keeping. A previous
    // removal's copy is never overwritten; this one gets a dated name beside it.
    static func keepGamefixes(_ gamefixes: URL, in kept: URL, now: Date = Date()) throws -> URL? {
        let files = FileManager.default
        let entries = (try? files.contentsOfDirectory(atPath: gamefixes.path(percentEncoded: false))) ?? []
        guard entries.contains(where: { $0 != ".DS_Store" }) else { return nil }
        var destination = kept
        if files.fileExists(atPath: destination.path(percentEncoded: false)) {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let stamp = format.string(from: now)
            destination = kept.deletingLastPathComponent().appending(path: "\(kept.lastPathComponent) \(stamp)")
        }
        try WriteRefused.catching(destination) { try files.moveItem(at: gamefixes, to: destination) }
        AppLog.note("uninstall: kept the user's game fixes in \(destination.path(percentEncoded: false))")
        return destination
    }

    // Links the run script made point at legacycompat. Anything else at that name is left alone.
    static func removeSteamDLLLinks(to legacyCompat: URL, in libraries: [SteamLibrary]) throws -> [String] {
        let files = FileManager.default
        let target = legacyCompat.appending(path: "Steam.dll").path(percentEncoded: false)
        var removed: [String] = []
        for library in libraries {
            let link = library.steamapps.appending(path: "common/Steam.dll")
            let path = link.path(percentEncoded: false)
            guard (try? files.destinationOfSymbolicLink(atPath: path)) == target else { continue }
            try WriteRefused.catching(path) { try files.removeItem(at: link) }
            removed.append(link.lastPathComponent)
        }
        return removed
    }
}
