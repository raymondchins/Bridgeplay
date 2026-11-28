// The shader caches a game leaves in this macOS user's cache folder. D3DMetal keys its own by
// the exe's file name (d3dm/<Game>.exe), and Metal keeps one per launcher bundle, which
// compat_run.sh names com.notproton.launcher.<appid>. Both are Apple's private formats: they
// are only measured and cleared, never edited, moved or shared.

import Foundation

struct ShaderCacheUsage: Sendable, Equatable {
    let folders: [URL]
    let bytes: Int64

    var isEmpty: Bool { folders.isEmpty }
}

enum ShaderCache {

    // $(getconf DARWIN_USER_CACHE_DIR), per macOS user.
    static var userCaches: URL? {
        let size = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, size) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : URL(filePath: path, directoryHint: .isDirectory)
    }

    static func launcherCache(appID: String, caches: URL) -> URL {
        caches.appending(path: "com.notproton.launcher.\(appID)")
    }

    static func folders(
        for prefix: WinePrefix, caches: URL? = userCaches,
        installDirectory: URL? = nil
    ) -> [URL] {
        guard let caches else { return [] }
        let fm = FileManager.default
        var found: [URL] = []

        let launcher = launcherCache(appID: prefix.appID, caches: caches)
        if isDirectory(launcher) { found.append(launcher) }

        let d3dm = caches.appending(path: "d3dm")
        let install = installDirectory ?? PrefixStore.installDirectory(of: prefix)
        if let install, let entries = try? fm.contentsOfDirectory(atPath: d3dm.path(percentEncoded: false)) {
            let names = exeNames(in: install)
            // d3dm/shaders.cache is shared by every game, so it is never one game's.
            for entry in entries.sorted()
            where entry.lowercased().hasSuffix(".exe") && names.contains(entry.lowercased()) {
                let folder = d3dm.appending(path: entry)
                if isDirectory(folder) { found.append(folder) }
            }
        }
        return found
    }

    static func usage(
        of prefix: WinePrefix, caches: URL? = userCaches, installDirectory: URL? = nil
    ) -> ShaderCacheUsage {
        let folders = folders(for: prefix, caches: caches, installDirectory: installDirectory)
        let bytes = folders.reduce(into: Int64(0)) { $0 += PrefixStore.directoryBytes($1) }
        return ShaderCacheUsage(folders: folders, bytes: bytes)
    }

    // The exe file names in a game's folder, lowercased. Unreal games keep the one that draws
    // four levels down (Game/Binaries/Win64), so the walk stops below that or at a cap.
    static func exeNames(in folder: URL, depth: Int = 5, limit: Int = 50_000) -> Set<String> {
        guard let walk = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var names: Set<String> = []
        var seen = 0
        for case let url as URL in walk {
            seen += 1
            if seen > limit { break }
            if walk.level >= depth { walk.skipDescendants() }
            let name = url.lastPathComponent.lowercased()
            if name.hasSuffix(".exe") { names.insert(name) }
        }
        return names
    }

    // Removes the folders measured for the game, only while it isn't running. A folder outside
    // the caches it was found in is refused, so a stale list can't reach anything else.
    static func clear(_ prefix: WinePrefix, folders: [URL], caches: URL? = userCaches) throws {
        let step = String(localized: "Clear shader cache")
        guard let caches else { return }
        let allowed = [
            caches.appending(path: "d3dm").standardizedFileURL.path(percentEncoded: false),
            caches.standardizedFileURL.path(percentEncoded: false),
        ].map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        let launcher = launcherCache(appID: prefix.appID, caches: caches).lastPathComponent
        for folder in folders {
            let parent = folder.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
            let trimmed = parent.hasSuffix("/") ? String(parent.dropLast()) : parent
            let name = folder.lastPathComponent
            let inD3DM = trimmed == allowed[0] && name.lowercased().hasSuffix(".exe")
            let isLauncher = trimmed == allowed[1] && name == launcher
            guard inD3DM || isLauncher else {
                throw StepFailure(step: step, detail: String(localized: "\(folder.path(percentEncoded: false)) is not a shader cache."))
            }
        }
        guard let claim = PrefixStore.claim(prefix) else {
            throw StepFailure(step: step, detail: String(localized: "\(prefix.title) is running. Quit the game first."))
        }
        defer { claim.release() }
        let fm = FileManager.default
        for folder in folders where (try? fm.attributesOfItem(atPath: folder.path(percentEncoded: false))) != nil {
            try WriteRefused.catching(folder.path(percentEncoded: false)) {
                try fm.removeItem(at: folder)
            }
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
