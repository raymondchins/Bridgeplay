// What Remove Everything will remove, what stays, and the check afterwards that Steam is
// Valve's again. Reads only; Uninstall.run does the removing.

import Foundation

struct UninstallItem: Sendable, Hashable, Identifiable {
    let url: URL
    var bytes: Int64?
    // Why it stays, for an item on the "remains" side.
    var note: String?

    var id: String { url.plainPath }
    var path: String { url.plainPath }
    var size: String? { bytes.map { $0.formatted(.byteCount(style: .file)) } }
}

// Where to look. `live` is this account on this Mac; tests pass fixture folders.
struct UninstallPaths: Sendable {
    var app: URL
    var innerPlist: URL
    var updateBlocks: [URL]
    var legacyCompat: URL
    var compatTools: URL
    // Folders and files only Bridgeplay writes, in this account's home, new and legacy names.
    var owned: [URL]
    var launchAgents: URL
    var keptGamefixes: URL
    var libraries: [SteamLibrary]
    var userdata: URL
    // The app and the files macOS keeps for it; they stay until the app is in the Trash.
    var appFiles: [URL]
    var users: URL
    var userName: String

    static var live: UninstallPaths {
        let home = SupportPaths.home
        let id = Bundle.main.bundleIdentifier ?? "com.bridgeplay.Bridgeplay"
        return UninstallPaths(
            app: SupportPaths.Steam.app,
            innerPlist: SupportPaths.Steam.innerInfoPlist,
            updateBlocks: UpdateBlock.paths,
            legacyCompat: SupportPaths.Steam.legacyCompat,
            compatTools: SupportPaths.Steam.compatTools,
            owned: [
                SupportPaths.support, SupportPaths.legacyApplicationSupport,
                SupportPaths.caches, SupportPaths.legacyCaches,
                SupportPaths.homeDir, SupportPaths.legacyHomeDir,
                SupportPaths.steamBundlesRecord, SupportPaths.legacySteamBundlesRecord,
            ],
            launchAgents: home.appending(path: "Library/LaunchAgents"),
            keptGamefixes: SupportPaths.keptGamefixes,
            libraries: PrefixStore.libraries(),
            userdata: SupportPaths.Steam.userData.appending(path: "userdata"),
            appFiles: [
                Bundle.main.bundleURL,
                home.appending(path: "Library/Preferences/\(id).plist"),
                home.appending(path: "Library/Caches/\(id)"),
                home.appending(path: "Library/HTTPStorages/\(id)"),
                home.appending(path: "Library/Saved Application State/\(id).savedState"),
            ],
            users: URL(filePath: "/Users"),
            userName: NSUserName())
    }

    // Login items Bridgeplay could have left. It adds none today; older or hand-made ones go too.
    static let launchAgentPrefixes = ["com.bridgeplay.", "com.notproton."]

    func ourLaunchAgents() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: launchAgents, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { url in
            url.pathExtension == "plist" && Self.launchAgentPrefixes.contains { url.lastPathComponent.hasPrefix($0) }
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // Bridgeplay's files inside Steam's own folders, outside Steam.app.
    func filesInSteamData() -> [URL] {
        var found = SupportPaths.Steam.ourTools(in: compatTools)
        found.append(legacyCompat)
        for library in libraries {
            found.append(library.compatdata.appending(path: SupportPaths.prefixTemplateFolder))
            let link = library.steamapps.appending(path: "common/Steam.dll")
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.plainPath))
                == legacyCompat.appending(path: "Steam.dll").plainPath {
                found.append(link)
            }
        }
        return found.filter(Self.exists)
    }

    // Other accounts with a home folder. Their Bridgeplay files are theirs to remove, and
    // their Library is not readable from here.
    func otherUsers() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: users.plainPath)) ?? []
        return names.filter { name in
            name != userName && name != "Shared" && name != "Guest" && !name.hasPrefix(".")
                && Self.isDirectory(users.appending(path: name))
        }.sorted()
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.plainPath, &info) == 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.plainPath, isDirectory: &directory) && directory.boolValue
    }
}

struct UninstallPrefix: Sendable, Hashable, Identifiable {
    let prefix: WinePrefix
    let bytes: Int64

    var id: String { prefix.id }
    var size: String { bytes.formatted(.byteCount(style: .file)) }
}

struct UninstallPlan: Sendable {
    // This account's Bridgeplay files that exist now.
    var remove: [UninstallItem]
    var steamModified: Bool
    // Restoring needs no download: Valve's pinned bundle is kept on this Mac.
    var steamKeptOffline: Bool
    var prefixes: [UninstallPrefix]
    var keeps: [UninstallItem]
    var otherUsers: [String]

    var prefixBytes: Int64 { prefixes.reduce(0) { $0 + $1.bytes } }

    static func make(
        paths: UninstallPaths,
        steamModified: @Sendable (URL) -> Bool = { (try? SteamModifications.inspect($0)) == .modified },
        keptOffline: @Sendable () -> Bool = {
            guard let bundle = try? ValvePackageManifest.bundled().bundle else { return false }
            return SteamRepair.keptArchive(bundle, in: SupportPaths.steamRestore) != nil
        },
        measure: @Sendable (URL) -> Int64 = { PrefixStore.directoryBytes($0) }
    ) -> UninstallPlan {
        let owned = paths.owned + paths.ourLaunchAgents() + paths.filesInSteamData()
        let remove = owned.filter(UninstallPaths.exists).map { UninstallItem(url: $0, bytes: measure($0)) }
        let prefixes = PrefixStore.all(libraries: paths.libraries, userdata: paths.userdata)
            .map { UninstallPrefix(prefix: $0, bytes: measure($0.root)) }
        return UninstallPlan(
            remove: remove,
            steamModified: steamModified(paths.app),
            steamKeptOffline: keptOffline(),
            prefixes: prefixes,
            keeps: remainders(paths: paths, prefixes: prefixes.map(\.prefix), trashed: []),
            otherUsers: paths.otherUsers())
    }

    // What stays after Remove Everything: game data not picked for the Trash, the user's own
    // game fixes, and the app with its settings.
    static func remainders(paths: UninstallPaths, prefixes: [WinePrefix], trashed: Set<String>) -> [UninstallItem] {
        var kept: [UninstallItem] = prefixes.filter { !trashed.contains($0.id) }.map {
            UninstallItem(url: $0.root, note: String(localized: "Saves for \($0.title)"))
        }
        // The kept folder, and the dated ones earlier removals left beside it.
        let folder = paths.keptGamefixes.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.plainPath)) ?? []
        kept += names.filter { $0.hasPrefix(paths.keptGamefixes.lastPathComponent) }.sorted()
            .map { UninstallItem(url: folder.appending(path: $0), note: String(localized: "Your game fixes")) }
        kept += paths.appFiles.filter(UninstallPaths.exists).map {
            UninstallItem(url: $0, note: String(localized: "Trash it after it quits"))
        }
        return kept
    }
}

// The proof after removal: Steam.app carries Valve's signature and nothing of Bridgeplay's.
struct UninstallVerification: Sendable {
    enum Signature: Sendable, Equatable {
        case valve
        case notValve(String)
        case missing
    }

    var signature: Signature
    var app: URL
    // Bridgeplay's files or settings still in Steam.app or Steam's own folders.
    var leftInSteam: [UninstallItem]
    // This account's Bridgeplay files still on disk.
    var leftForUser: [UninstallItem]

    var signedByValve: Bool { signature == .valve }
    var passed: Bool { signedByValve && leftInSteam.isEmpty }

    static let liveSignature: @Sendable (URL) -> Signature = { app in
        guard UninstallPaths.exists(app) else { return .missing }
        do {
            try SteamRepair.verifyValveSignature(app, step: String(localized: "Verify"))
            return .valve
        } catch {
            return .notValve(error.localizedDescription)
        }
    }

    static func run(paths: UninstallPaths, signature: @Sendable (URL) -> Signature = liveSignature) -> UninstallVerification {
        var inSteam: [UninstallItem] = []
        let dylib = SupportPaths.Steam.deployedDylib(inBundle: paths.app)
        if UninstallPaths.exists(dylib) { inSteam.append(UninstallItem(url: dylib)) }
        let plist = SupportPaths.Steam.infoPlist(inBundle: paths.app)
        for file in [plist, paths.innerPlist] where Self.declaresBridgeplay(file) {
            inSteam.append(UninstallItem(url: file, note: String(localized: "Still loads Bridgeplay")))
        }
        if UpdateBlock.isPresent(at: paths.updateBlocks) {
            inSteam.append(UninstallItem(url: paths.updateBlocks[0], note: String(localized: "Updates still blocked")))
        }
        inSteam += paths.filesInSteamData().map { UninstallItem(url: $0) }
        let user = (paths.owned + paths.ourLaunchAgents()).filter(UninstallPaths.exists).map { UninstallItem(url: $0) }
        return UninstallVerification(signature: signature(paths.app), app: paths.app,
                                     leftInSteam: inSteam, leftForUser: user)
    }

    static func declaresBridgeplay(_ plist: URL) -> Bool {
        guard let dict = SteamBundle.readInfoPlist(at: plist),
              let environment = dict[SteamBundle.environmentKey] as? [String: Any]
        else { return false }
        let insert = environment[SteamBundle.insertKey] as? String ?? ""
        return insert.split(separator: ":").contains { URL(filePath: String($0)).lastPathComponent == SupportPaths.dylibName }
            || environment[SteamBundle.controllerBlockKey] as? String == SteamBundle.controllerBlockValue
    }
}

// The list shown when Remove Everything ends.
struct UninstallChecklist: Sendable {
    var removed: [UninstallItem]
    var trashed: [UninstallItem]
    var remains: [UninstallItem]
    var otherUsers: [String]
    var verification: UninstallVerification

    static func make(plan: UninstallPlan, outcome: UninstallOutcome, paths: UninstallPaths,
                     verification: UninstallVerification) -> UninstallChecklist {
        let left = Set((verification.leftForUser + verification.leftInSteam).map(\.id))
        let removed = plan.remove.filter { !left.contains($0.id) }
        var remains = verification.leftForUser.map {
            UninstallItem(url: $0.url, note: String(localized: "Not removed"))
        }
        remains += remainders(paths: paths, plan: plan, outcome: outcome)
        return UninstallChecklist(removed: removed, trashed: outcome.trashed, remains: remains,
                                  otherUsers: plan.otherUsers, verification: verification)
    }

    private static func remainders(paths: UninstallPaths, plan: UninstallPlan, outcome: UninstallOutcome) -> [UninstallItem] {
        let trashed = Set(outcome.trashedPrefixes)
        var kept = UninstallPlan.remainders(paths: paths, prefixes: plan.prefixes.map(\.prefix), trashed: trashed)
        for failure in outcome.notTrashed {
            if let index = kept.firstIndex(where: { $0.url == failure.url }) {
                kept[index].note = failure.note
            }
        }
        return kept
    }

    // Plain text for the command line and for copying.
    var text: String {
        var lines: [String] = []
        func section(_ title: String, _ items: [UninstallItem]) {
            guard !items.isEmpty else { return }
            lines.append(title)
            for item in items {
                let extra = [item.size, item.note].compactMap { $0 }.joined(separator: ", ")
                lines.append("  \(item.path)" + (extra.isEmpty ? "" : "  (\(extra))"))
            }
        }
        section("Removed:", removed)
        section("Moved to the Trash:", trashed)
        section("Remains:", remains)
        if !otherUsers.isEmpty {
            lines.append("Other accounts on this Mac keep their own Bridgeplay files until they remove them: "
                + otherUsers.joined(separator: ", "))
        }
        lines.append(verification.text)
        return lines.joined(separator: "\n")
    }
}

extension UninstallVerification {
    var text: String {
        var lines = ["Verify:"]
        switch signature {
        case .valve: lines.append("  [ok] \(app.plainPath) is signed by Valve (\(SteamRepair.valveTeam))")
        case .missing: lines.append("  [--] \(app.plainPath) is not there")
        case .notValve(let why): lines.append("  [!!] \(app.plainPath) is not signed by Valve: \(why)")
        }
        if leftInSteam.isEmpty {
            lines.append("  [ok] No Bridgeplay files in Steam")
        } else {
            lines.append("  [!!] Bridgeplay files still in Steam:")
            lines += leftInSteam.map { "       \($0.path)" + ($0.note.map { " (\($0))" } ?? "") }
        }
        return lines.joined(separator: "\n")
    }
}
