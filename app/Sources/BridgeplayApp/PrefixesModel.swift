// Prefix logic that drives the prefix view itself.

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PrefixesModel {

    private(set) var prefixes: [WinePrefix] = []
    private(set) var usage: [String: PrefixUsage] = [:]
    private(set) var shaderCaches: [String: ShaderCacheUsage] = [:]
    private(set) var isLoading = false
    private(set) var records: [String: PrefixBuildRecord] = [:]
    private(set) var tools: [InstalledTool] = []

    private(set) var stale: Set<String> = []

    // True when no installed compatibility tool runs the prefix's arch.
    func isStale(_ prefix: WinePrefix) -> Bool {
        stale.contains(prefix.id)
    }

    private(set) var currentTools: [String: InstalledTool] = [:]

    func lastTool(_ prefix: WinePrefix) -> String? {
        if let tool = currentTools[prefix.id] { return tool.display }
        guard let record = records[prefix.id] else { return nil }
        return record.display ?? SupportedRunners.displayVersion(forID: record.build)
    }

    private(set) var hasLoaded = false
    private(set) var busy = Set<WinePrefix.ID>()

    var isBusy: Bool { !busy.isEmpty }
    var outcome: String?
    private(set) var report: FailureReport?

    var selection = Set<WinePrefix.ID>()

    var pendingConfirmation: Confirmation?

    private(set) var backups: [PrefixBackup] = []

    var backupBytes: Int64 { backups.reduce(into: Int64(0)) { $0 += $1.bytes } }

    enum Confirmation: Equatable {
        case delete([WinePrefix])
        case rebuild([WinePrefix], InstalledTool)
        case backUp([WinePrefix])
        case deleteBackups([PrefixBackup])
        // A move to the Trash failed for these, so nothing of theirs was deleted.
        case deletePermanently([WinePrefix], [PrefixBackup])
        case restore(PrefixBackup)
        case clearShaderCache([WinePrefix])
    }

    func backups(of prefix: WinePrefix) -> [PrefixBackup] {
        backups.filter { $0.prefix.id == prefix.id }
    }

    var selectedPrefix: WinePrefix? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return prefixes.first { $0.id == id }
    }

    var selectedPrefixes: [WinePrefix] {
        prefixes.filter { selection.contains($0.id) }
    }

    private let libraries: @Sendable () -> [SteamLibrary]
    private let installedTools: @Sendable () -> [InstalledTool]
    private let rebuild: @Sendable (WinePrefix, InstalledTool, Bool) throws -> URL?
    private let makeBackup: @Sendable (WinePrefix) throws -> URL
    private let trash: PrefixTools.Trash
    private let caches: URL?

    init(
        libraries: @escaping @Sendable () -> [SteamLibrary] = { PrefixStore.libraries() },
        installedTools: @escaping @Sendable () -> [InstalledTool] = { CompatToolList.installed() },
        rebuild: @escaping @Sendable (WinePrefix, InstalledTool, Bool) throws -> URL? = {
            try PrefixTools.recreate($0, as: $1, keepBackup: $2)
        },
        makeBackup: @escaping @Sendable (WinePrefix) throws -> URL = {
            try PrefixTools.backUp($0)
        },
        trash: @escaping PrefixTools.Trash = PrefixTools.systemTrash,
        caches: URL? = ShaderCache.userCaches
    ) {
        self.trash = trash
        self.caches = caches
        self.libraries = libraries
        self.installedTools = installedTools
        self.rebuild = rebuild
        self.makeBackup = makeBackup
    }

    private var loadGeneration = 0
    func load() async {
        loadGeneration += 1
        let run = loadGeneration
        isLoading = true
        defer { if run == loadGeneration { isLoading = false } }

        let roots = libraries()
        let (found, parked) = await Task.detached {
            (PrefixStore.all(libraries: roots), PrefixStore.backupOnly(libraries: roots))
        }.value
        guard run == loadGeneration else { return }
        prefixes = found
        usage = usage.filter { id, _ in found.contains { $0.id == id } }
        shaderCaches = shaderCaches.filter { id, _ in found.contains { $0.id == id } }
        let listTools = installedTools
        let resolved = await Task.detached {
            let tools = listTools()
            var records: [String: PrefixBuildRecord] = [:]
            var stale = Set<String>()
            var current: [String: InstalledTool] = [:]
            for prefix in found {
                guard let record = PrefixTools.lastBuild(of: prefix) else { continue }
                records[prefix.id] = record
                if let tool = PrefixTools.tool(for: prefix, among: tools) {
                    current[prefix.id] = tool
                } else {
                    stale.insert(prefix.id)
                }
            }
            return (tools, records, stale, current)
        }.value
        guard run == loadGeneration else { return }
        (tools, records, stale, currentTools) = resolved
        selection = selection.filter { id in found.contains { $0.id == id } }

        // A prefix that is gone still lists its backups, so Restore can bring it back.
        var kept: [PrefixBackup] = []
        for prefix in found + parked {
            let details = await Task.detached { PrefixStore.backupDetails(of: prefix) }.value
            guard run == loadGeneration else { return }
            kept.append(contentsOf: details)
        }
        kept.sort { ($0.taken ?? .distantPast) > ($1.taken ?? .distantPast) }
        backups = kept
        // The lists are ready; sizes walk every file of every prefix, so they fill in row by
        // row ("Calculating…") instead of holding the whole page back.
        hasLoaded = true

        for prefix in found {
            let measured = await Task.detached { PrefixStore.usage(of: prefix) }.value
            guard run == loadGeneration else { return }
            usage[prefix.id] = measured
        }

        let caches = caches
        for prefix in found {
            let measured = await Task.detached { ShaderCache.usage(of: prefix, caches: caches) }.value
            guard run == loadGeneration else { return }
            shaderCaches[prefix.id] = measured
        }
    }

    func open(_ tool: WineTool, for prefix: WinePrefix) {
        act(on: prefix) {
            try PrefixTools.launch(tool, in: prefix)
            return String(localized: "Opened \(tool.label) in \(prefix.title).")
        }
    }

    func reveal(_ prefix: WinePrefix) {
        PrefixTools.reveal(prefix)
    }

    func hasLog(_ log: PrefixLog, for prefix: WinePrefix) -> Bool {
        PrefixTools.hasLog(log, for: prefix)
    }

    func open(_ log: PrefixLog, for prefix: WinePrefix) {
        PrefixTools.open(log, for: prefix)
    }

    func delete(_ targets: [WinePrefix]) async {
        let trash = trash
        let done = await eachInTurn(targets, { prefix -> Bool in
            do {
                try PrefixTools.delete(prefix, trash: trash)
                return true
            } catch is TrashUnavailable {
                return false
            }
        }) { done in
            let trashed = done.filter(\.made)
            if trashed.count == 1 {
                return String(localized: "Moved prefix for \(trashed[0].prefix.title) to Trash.")
            }
            guard trashed.count > 1 else { return nil }
            return String(localized: "Moved \(trashed.count) prefixes to Trash.")
        }
        let kept = done.filter { !$0.made }.map(\.prefix)
        if !kept.isEmpty { pendingConfirmation = .deletePermanently(kept, []) }
    }

    // What the no-Trash dialog frees: the prefixes with their backups, nil while unmeasured.
    func permanentBytes(_ prefixes: [WinePrefix], _ backups: [PrefixBackup]) -> Int64? {
        var total = backups.reduce(into: Int64(0)) { $0 += $1.bytes }
        for prefix in prefixes {
            guard let bytes = usage[prefix.id]?.bytes else { return nil }
            total += bytes + backupsBytes(of: prefix)
        }
        return total
    }

    private func backupsBytes(of prefix: WinePrefix) -> Int64 {
        backups(of: prefix).reduce(into: Int64(0)) { $0 += $1.bytes }
    }

    // Only from the no-Trash dialog, after the user chose Delete Permanently.
    func deletePermanently(_ prefixes: [WinePrefix], _ targets: [PrefixBackup]) async {
        if !prefixes.isEmpty {
            await eachInTurn(prefixes, { try PrefixTools.deletePermanently($0) }) { deleted in
                if deleted.count == 1 {
                    return String(localized: "Deleted prefix for \(deleted[0].prefix.title).")
                }
                guard deleted.count > 1 else { return nil }
                return String(localized: "Deleted \(deleted.count) prefixes.")
            }
        }
        if !targets.isEmpty {
            await removeBackups(targets, permanently: true)
        }
    }

    func restore(_ backup: PrefixBackup) async {
        await eachInTurn([backup.prefix], { _ in try PrefixTools.restore(backup) }) { done in
            guard !done.isEmpty else { return nil }
            return String(localized: "Restored \(backup.title). Old data is a new backup.")
        }
    }

    func shaderCacheBytes(_ targets: [WinePrefix]) -> Int64 {
        ShaderCacheUsage.totalBytes(targets.compactMap { shaderCaches[$0.id] })
    }

    func clearShaderCaches(_ targets: [WinePrefix]) async {
        let measured = shaderCaches
        let caches = caches
        let chosen = targets.filter { !(measured[$0.id]?.isEmpty ?? true) }
        await eachInTurn(chosen, { prefix in
            try ShaderCache.clear(prefix, folders: measured[prefix.id]?.folders ?? [], caches: caches)
        }) { cleared in
            if cleared.count == 1 {
                return String(localized: "Cleared shader cache for \(cleared[0].prefix.title).")
            }
            guard cleared.count > 1 else { return nil }
            return String(localized: "Cleared \(cleared.count) shader caches.")
        }
    }

    func backUp(_ targets: [WinePrefix]) async {
        await eachInTurn(targets, makeBackup) { saved in
            guard let first = saved.first else { return nil }
            guard saved.count == 1 else { return String(localized: "Backed up \(saved.count) prefixes.") }
            return String(localized: "Backed up the prefix for \(first.prefix.title).")
        }
    }

    @discardableResult
    func confirmRebuild(keepBackup: Bool = true) -> Task<Void, Never>? {
        guard case .rebuild(let targets, let tool) = pendingConfirmation else { return nil }
        pendingConfirmation = nil
        return Task { await recreate(targets, as: tool, keepBackup: keepBackup) }
    }

    func recreate(_ targets: [WinePrefix], as tool: InstalledTool, keepBackup: Bool = true) async {
        let make = rebuild
        await eachInTurn(targets, { try make($0, tool, keepBackup) }) { rebuilt in
            let kept = rebuilt.compactMap(\.made)
            if rebuilt.count == 1 {
                let title = rebuilt[0].prefix.title
                guard let backup = kept.first else { return String(localized: "Rebuilt the prefix for \(title).") }
                return String(localized: "Rebuilt the prefix for \(title). The original is at \(backup.path(percentEncoded: false)). Check that your save is present in the game, then delete the backup to save space.")
            }
            guard rebuilt.count > 1 else { return nil }
            guard !kept.isEmpty else { return String(localized: "Rebuilt \(rebuilt.count) prefixes.") }
            return String(localized: "Rebuilt \(rebuilt.count) prefixes. Each original is kept beside the game's prefix. Check that your saves are present in the games, then delete the backups to save space.")
        }
    }

    func reveal(_ backup: PrefixBackup) {
        PrefixTools.reveal(at: backup.url)
    }

    func forgetOutcome() {
        report = nil
        outcome = nil
    }

    func deleteBackups(_ targets: [PrefixBackup]) async {
        await removeBackups(targets, permanently: false)
    }

    private func removeBackups(_ targets: [PrefixBackup], permanently: Bool) async {
        guard !targets.isEmpty else { return }
        forgetOutcome()
        isLoading = true

        var cleared: [PrefixBackup] = []
        var noTrash: [PrefixBackup] = []
        var refused: [Error] = []
        let trash = trash
        for backup in targets {
            do {
                try await Task.detached {
                    if permanently {
                        try PrefixTools.deleteBackupPermanently(backup.url)
                    } else {
                        try PrefixTools.deleteBackup(backup.url, trash: trash)
                    }
                }.value
                cleared.append(backup)
            } catch is TrashUnavailable {
                noTrash.append(backup)
            } catch {
                refused.append(error)
            }
        }

        outcome = clearedSentence(cleared, permanently: permanently)
        report = FailureReport(refused)
        let gone = Set(cleared.map(\.id))
        backups.removeAll { gone.contains($0.id) }
        isLoading = false
        await load()
        if !noTrash.isEmpty { pendingConfirmation = .deletePermanently([], noTrash) }
    }

    private func clearedSentence(_ cleared: [PrefixBackup], permanently: Bool) -> String? {
        guard !cleared.isEmpty else { return nil }
        let games = Set(cleared.map(\.prefix.id)).count
        if permanently {
            if cleared.count == 1 {
                return String(localized: "Deleted backup for \(cleared[0].title).")
            }
            if games == 1 {
                return String(localized: "Deleted \(cleared.count) backups for \(cleared[0].title).")
            }
            return String(localized: "Deleted \(cleared.count) backups.")
        }
        if cleared.count == 1 {
            return String(localized: "Moved backup for \(cleared[0].title) to Trash.")
        }
        if games == 1 {
            return String(localized: "Moved \(cleared.count) backups for \(cleared[0].title) to Trash.")
        }
        return String(localized: "Moved \(cleared.count) backups to Trash.")
    }

    private typealias Step<Made> = (prefix: WinePrefix, made: Made)

    @discardableResult
    private func eachInTurn<Made: Sendable>(
        _ targets: [WinePrefix],
        _ work: @escaping @Sendable (WinePrefix) async throws -> Made,
        saying sentence: ([Step<Made>]) -> String?
    ) async -> [Step<Made>] {
        guard !targets.isEmpty else { return [] }
        forgetOutcome()
        isLoading = true
        busy = Set(targets.map(\.id))

        var done: [Step<Made>] = []
        var refused: [Error] = []
        for prefix in targets {
            do {
                let made = try await Task.detached { try await work(prefix) }.value
                done.append((prefix: prefix, made: made))
            } catch {
                refused.append(error)
            }
            busy.remove(prefix.id)
        }

        outcome = sentence(done)
        report = FailureReport(refused)

        busy = []
        isLoading = false
        await load()
        return done
    }

    func chooseExecutable(for prefix: WinePrefix) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = PrefixTools.runnableTypes
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.prompt = String(localized: "Run")
        panel.message = String(localized: "Choose a Windows program to run in \(prefix.title).")
        panel.directoryURL = PrefixStore.installDirectory(of: prefix)
            ?? prefix.pfx.appending(path: "drive_c")

        guard panel.runModal() == .OK, let picked = panel.url else { return }
        run(picked, in: prefix)
    }

    func run(_ executable: URL, in prefix: WinePrefix) {
        act(on: prefix) {
            try PrefixTools.run(executable, in: prefix)
            return String(localized: "Started \(executable.lastPathComponent) in \(prefix.title).")
        }
    }

    func winetricks(_ text: String, in prefix: WinePrefix) async {
        let verbs = PrefixTools.winetricksVerbs(text)
        await eachInTurn([prefix], { try await PrefixTools.winetricks(verbs, in: $0) }) { done in
            guard !done.isEmpty else { return nil }
            return String(localized: "Winetricks ran \(verbs.joined(separator: " ")) in \(prefix.title).")
        }
    }

    private func act(on prefix: WinePrefix, _ body: () throws -> String) {
        forgetOutcome()
        busy = [prefix.id]
        defer { busy = [] }
        do {
            outcome = try body()
        } catch {
            report = FailureReport([error])
        }
    }
}
