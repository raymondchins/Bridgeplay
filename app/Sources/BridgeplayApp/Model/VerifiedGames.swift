import Foundation

// Games a maintainer already checked (compat/games.json in the Bridgeplay repository) on a
// Mac with this Mac's chip: the app doesn't ask about those. The list is cached on disk and
// fetched at most once a day; without it (offline, first launch) the app asks as before.
enum VerifiedGames {

    static let source = URL(string: "https://raw.githubusercontent.com/raymondchins/Bridgeplay/main/compat/games.json")!
    static var cache: URL { SupportPaths.caches.appending(path: "compat-games.json") }

    // "M5 Max", "M2", "A18 Pro" out of free text such as "M5 Max · macOS 27"; the same names
    // GameReport.chip gives.
    static func chipFamilies(in text: String) -> Set<String> {
        let pattern = /\b[AM][1-9]\d{0,2}(?: (?:Pro|Max|Ultra))?\b/
        return Set(text.matches(of: pattern).map { String($0.output) })
    }

    // AppIDs whose maintainer result (any status but untested) was recorded on `chip`.
    static func verified(on chip: String, in data: Data) -> Set<String> {
        guard chip != "Other",
              let games = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var found = Set<String>()
        for game in games {
            guard let status = game["status"] as? String, status != "untested",
                  let appID = (game["appid"] as? Int).map(String.init) ?? game["appid"] as? String else { continue }
            var texts = [game["tested_on"] as? String]
            for report in game["reports"] as? [[String: Any]] ?? [] {
                texts.append(report["chip"] as? String)
                texts.append(report["device"] as? String)
            }
            if texts.compactMap({ $0 }).contains(where: { chipFamilies(in: $0).contains(chip) }) { found.insert(appID) }
        }
        return found
    }

    // The cached list, refreshed when it is a day old. Never throws; run off the main thread.
    static func load(chip: String, cache: URL = cache, session: URLSession = .shared,
                     now: Date = Date()) async -> Set<String> {
        let modified = (try? FileManager.default.attributesOfItem(atPath: cache.path(percentEncoded: false)))?[.modificationDate] as? Date
        if modified.map({ now.timeIntervalSince($0) >= 86400 }) ?? true {
            var request = URLRequest(url: source, timeoutInterval: 20)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               (try? JSONSerialization.jsonObject(with: data)) is [Any] {
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cache, options: .atomic)
            } else if modified != nil {
                // Failed: keep the old copy for another day rather than retry on every scan.
                try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: cache.path(percentEncoded: false))
            }
        }
        guard let data = try? Data(contentsOf: cache) else { return [] }
        return verified(on: chip, in: data)
    }
}
