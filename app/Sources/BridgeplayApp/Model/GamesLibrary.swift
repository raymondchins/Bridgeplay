import AppKit
import Foundation
import Observation

// One installed Windows game on the Games page: a compatdata/<appid>/ folder whose game still
// has its appmanifest in one of the libraries, or a named non-Steam shortcut. Read from files
// only, so Steam need not be running.
struct InstalledGame: Equatable, Sendable, Identifiable {
    let prefix: WinePrefix
    let hasPrefix: Bool
    // The run script's outcome record; nil for launches from before it existed.
    let record: LaunchRecord?
    // notproton-backend's first line, for launches from before the record.
    let backendFile: String?
    let installedIn: SteamLibrary?

    var id: String { prefix.id }
    var appID: String { prefix.appID }
    var title: String { prefix.title }
    var backend: String? { record?.backend ?? backendFile }
    var isShortcut: Bool { UInt32(appID).map { $0 & 0x8000_0000 != 0 } ?? false }
}

enum GamesLibrary {

    static func scan(
        libraries: [SteamLibrary] = PrefixStore.libraries(),
        userdata: URL = SupportPaths.Steam.userData.appending(path: "userdata")
    ) -> [InstalledGame] {
        let files = FileManager.default
        // appid -> the library whose steamapps holds its manifest
        var installed: [String: SteamLibrary] = [:]
        for library in libraries {
            let names = (try? files.contentsOfDirectory(atPath: library.steamapps.path(percentEncoded: false))) ?? []
            for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
                let id = String(name.dropFirst("appmanifest_".count).dropLast(".acf".count))
                if installed[id] == nil { installed[id] = library }
            }
        }

        var shortcuts: [String: String]?
        var byApp: [String: InstalledGame] = [:]
        for library in libraries {
            let entries = (try? files.contentsOfDirectory(
                at: library.compatdata, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                let appID = entry.lastPathComponent
                guard !appID.isEmpty, appID.allSatisfy(\.isASCII), appID.allSatisfy(\.isNumber),
                      appID != "0" else { continue }
                let home = installed[appID]
                var name = home.flatMap { PrefixStore.appName(appID: appID, in: $0) }
                if name == nil, let id = UInt32(appID), id & 0x8000_0000 != 0 {
                    if shortcuts == nil { shortcuts = PrefixStore.shortcutNames(userdata: userdata) }
                    name = shortcuts?[appID]
                }
                // Not installed any more: its leftover prefix stays on the Prefixes page.
                guard home != nil || name != nil else { continue }

                let pfx = entry.appending(path: "pfx")
                var isDirectory: ObjCBool = false
                let hasPrefix = files.fileExists(atPath: pfx.path(percentEncoded: false), isDirectory: &isDirectory)
                    && isDirectory.boolValue
                let lastUsed = hasPrefix
                    ? (try? pfx.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    : nil
                let game = InstalledGame(
                    prefix: WinePrefix(appID: appID, name: name, library: library, lastUsed: lastUsed),
                    hasPrefix: hasPrefix,
                    record: (try? String(contentsOf: entry.appending(path: LaunchRecord.fileName), encoding: .utf8))
                        .flatMap(LaunchRecord.parse),
                    backendFile: firstLine(entry.appending(path: "notproton-backend")),
                    installedIn: home
                )
                // A game moved between drives can leave a compatdata on each: keep the one
                // beside the install, else the one with a prefix.
                if let kept = byApp[appID], rank(kept) >= rank(game) { continue }
                byApp[appID] = game
            }
        }
        return byApp.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func rank(_ game: InstalledGame) -> Int {
        (game.installedIn == game.prefix.library ? 2 : 0) + (game.hasPrefix ? 1 : 0)
    }

    static func firstLine(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return nil }
        return line
    }

    // What the Prefix menu and the prefix dialogs act on while Games is shown: the game its
    // table selected, when that game has a prefix, else nothing.
    static func prefixSelection(_ id: InstalledGame.ID?, in games: [InstalledGame]) -> Set<WinePrefix.ID> {
        guard let id, let game = games.first(where: { $0.id == id }), game.hasPrefix else { return [] }
        return [game.prefix.id]
    }

    // Steam's own Play. A non-Steam shortcut's game id is its appid in the high 32 bits.
    static func playURL(_ game: InstalledGame) -> URL? {
        guard let appID = UInt64(game.appID) else { return nil }
        let id = game.isShortcut ? (appID << 32) | 0x0200_0000 : appID
        return URL(string: "steam://rungameid/\(id)")
    }

    // Graphics backend ids from the run script, as their projects write them.
    static func backendLabel(_ id: String) -> String {
        switch id.lowercased() {
        case "d3dmetal": "D3DMetal"
        case "wined3d": "WineD3D"
        case "dxmt-builtin": "DXMT"
        default: id.uppercased()
        }
    }

    // The small icon Steam keeps at appcache/librarycache/<appid>/<sha1>.jpg (or one folder
    // down); nil when Steam has not cached one.
    static func iconFile(appID: String, cache: URL) -> URL? {
        let files = FileManager.default
        func icon(in folder: URL) -> URL? {
            ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first { url in
                    let stem = url.deletingPathExtension().lastPathComponent
                    return url.pathExtension.lowercased() == "jpg" && stem.count == 40 && stem.allSatisfy(\.isHexDigit)
                }
        }
        let folder = cache.appending(path: appID)
        if let found = icon(in: folder) { return found }
        let subfolders = ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return subfolders.lazy.compactMap(icon(in:)).first
    }
}

// The list for the Games page. Sizes, backups and actions come from PrefixesModel; this adds
// the games, their last launch and their icons, each filled in after the list shows.
@MainActor
@Observable
final class GamesModel {

    private(set) var games: [InstalledGame] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    // From the run log, for games whose last launch has no record.
    private(set) var launches: [String: LastLaunch] = [:]
    private(set) var icons: [String: NSImage] = [:]

    private let libraries: @Sendable () -> [SteamLibrary]
    private let userdata: URL
    private let iconCache: URL

    init(
        libraries: @escaping @Sendable () -> [SteamLibrary] = { PrefixStore.libraries() },
        userdata: URL = SupportPaths.Steam.userData.appending(path: "userdata"),
        iconCache: URL = SupportPaths.Steam.userData.appending(path: "appcache/librarycache")
    ) {
        self.libraries = libraries
        self.userdata = userdata
        self.iconCache = iconCache
    }

    // When the game last ended: its record, else its run log, else when its prefix changed.
    func lastLaunch(_ game: InstalledGame) -> Date? {
        game.record?.ended ?? launches[game.id]?.ended ?? game.prefix.lastUsed
    }

    func verdict(_ game: InstalledGame) -> LaunchVerdict? {
        game.record?.verdict ?? launches[game.id]?.verdict
    }

    func engine(_ game: InstalledGame) -> String? {
        game.record?.engine.map(SupportedRunners.displayVersion(forID:))
    }

    private var generation = 0
    func load() async {
        generation += 1
        let run = generation
        isLoading = true
        defer { if run == generation { isLoading = false } }

        let listLibraries = libraries
        let userdata = userdata
        let found = await Task.detached { GamesLibrary.scan(libraries: listLibraries(), userdata: userdata) }.value
        guard run == generation else { return }
        games = found
        hasLoaded = true
        let ids = Set(found.map(\.id))
        launches = launches.filter { ids.contains($0.key) }

        let cache = iconCache
        for game in found where icons[game.id] == nil {
            let data = await Task.detached(priority: .utility) {
                GamesLibrary.iconFile(appID: game.appID, cache: cache).flatMap { try? Data(contentsOf: $0) }
            }.value
            guard run == generation else { return }
            if let data, let image = NSImage(data: data) { icons[game.id] = image }
        }

        for game in found where game.record == nil {
            let launch = await Task.detached(priority: .utility) { LastLaunch.read(game.prefix) }.value
            guard run == generation else { return }
            launches[game.id] = launch
        }
    }
}
