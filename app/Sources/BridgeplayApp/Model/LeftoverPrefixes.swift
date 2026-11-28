import Foundation

// A prefix whose game Steam uninstalled. Steam doesn't always remove compatdata, and a prefix
// can hold the only copy of a game's saves, so Status offers the Trash and never deletes.
struct LeftoverPrefix: Sendable, Hashable, Identifiable {
    let prefix: WinePrefix
    let bytes: Int64

    var id: String { prefix.id }
}

enum LeftoverPrefixes {
    // Prefix ids the user chose to keep
    static let keptKey = "KeptLeftoverPrefixes"
    // appid -> name, saved while a game is installed: its manifest, and the name, go with it
    static let namesKey = "SteamGameNames"

    struct Scan: Equatable {
        var leftovers: [WinePrefix] = []
        // Names of the installed games seen
        var names: [String: String] = [:]
    }

    static func scan(
        libraries: [SteamLibrary],
        listedApps: Set<String>,
        kept: Set<String>,
        names known: [String: String]
    ) -> Scan {
        let files = FileManager.default
        var manifests: [String: SteamLibrary] = [:]
        for library in libraries {
            let entries = (try? files.contentsOfDirectory(atPath: library.steamapps.path(percentEncoded: false))) ?? []
            for name in entries where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
                let id = String(name.dropFirst("appmanifest_".count).dropLast(".acf".count))
                if manifests[id] == nil { manifests[id] = library }
            }
        }

        var result = Scan()
        for library in libraries {
            let entries = (try? files.contentsOfDirectory(atPath: library.compatdata.path(percentEncoded: false))) ?? []
            for appID in entries.sorted() {
                // Numbers only; 0 is Steam's shared prefix; the high bit marks a non-Steam shortcut
                guard let number = UInt32(appID), String(number) == appID, number != 0,
                      number & 0x8000_0000 == 0 else { continue }
                if let home = manifests[appID] {
                    if let name = PrefixStore.appName(appID: appID, in: home) { result.names[appID] = name }
                    continue
                }
                // Listed for a library that isn't mounted: a game on an unplugged drive
                if listedApps.contains(appID) { continue }
                let prefix = WinePrefix(appID: appID, name: known[appID], library: library, lastUsed: nil)
                var isDirectory: ObjCBool = false
                guard files.fileExists(atPath: prefix.pfx.path(percentEncoded: false), isDirectory: &isDirectory),
                      isDirectory.boolValue, !kept.contains(prefix.id) else { continue }
                result.leftovers.append(prefix)
            }
        }
        return result
    }

    // Appids under each library's "apps" in libraryfolders.vdf, mounted or not
    static func listedApps(in text: String) -> Set<String> {
        var apps: Set<String> = []
        var depth = 0
        var appsDepth: Int?
        var lastKey: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                depth += 1
                if appsDepth == nil, lastKey?.lowercased() == "apps" { appsDepth = depth }
                lastKey = nil
            } else if line == "}" {
                if appsDepth == depth { appsDepth = nil }
                depth -= 1
            } else {
                let parts = line.split(separator: "\"", omittingEmptySubsequences: true)
                    .map(String.init).filter { !$0.allSatisfy(\.isWhitespace) }
                lastKey = parts.first
                if appsDepth == depth, let key = parts.first, key.allSatisfy(\.isNumber) { apps.insert(key) }
            }
        }
        return apps
    }

    static func load(defaults: UserDefaults = .standard) -> [LeftoverPrefix] {
        let vdf = SupportPaths.Steam.libraryFoldersVDF
        // Without the list, a game on an unplugged drive can't be told from an uninstalled one
        guard let text = try? String(contentsOf: vdf, encoding: .utf8) else { return [] }
        var names = defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        let found = scan(
            libraries: PrefixStore.libraries(vdf: vdf),
            listedApps: listedApps(in: text),
            kept: kept(defaults: defaults),
            names: names
        )
        if !found.names.isEmpty, found.names.contains(where: { names[$0.key] != $0.value }) {
            names.merge(found.names) { _, new in new }
            defaults.set(names, forKey: namesKey)
        }
        return found.leftovers.map { LeftoverPrefix(prefix: $0, bytes: PrefixStore.directoryBytes($0.root)) }
    }

    static func kept(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: keptKey) ?? [])
    }

    // Leftovers right now, kept ones included: checked again just before the Trash.
    // nil: Steam's library list can't be read, so no game can be told uninstalled.
    static func currentIDs() -> Set<String>? {
        let vdf = SupportPaths.Steam.libraryFoldersVDF
        guard let text = try? String(contentsOf: vdf, encoding: .utf8) else { return nil }
        let found = scan(libraries: PrefixStore.libraries(vdf: vdf), listedApps: listedApps(in: text), kept: [], names: [:])
        return Set(found.leftovers.map(\.id))
    }

    static func keep(_ ids: [String], defaults: UserDefaults = .standard) {
        let kept = Set(defaults.stringArray(forKey: keptKey) ?? []).union(ids)
        defaults.set(kept.sorted(), forKey: keptKey)
    }
}
