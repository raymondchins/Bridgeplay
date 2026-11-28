import Foundation

// Players' verdicts and anti-cheat names for the Bridgeplay panel in Steam and the game page's
// warning. The verdicts and AreWeAntiCheatYet's names come from compat-index.json on the
// compat-data branch (scripts/compat-export.md), the maintainers' names from compat/games.json
// (VerifiedGames' cache). They are written as compat-verdicts.tsv in the support folder, which
// the dylib reads when Steam loads the page (dylib/feats/compatverdict.c), so Steam never waits
// on the network. Fetched at most once a day; offline, the last copy stays.
enum CompatVerdicts {

    static let source = URL(string: "https://raw.githubusercontent.com/raymondchins/Bridgeplay/compat-data/compat-index.json")!
    static var cache: URL { SupportPaths.caches.appending(path: "compat-index.json") }
    static let fileName = "compat-verdicts.tsv"
    // Kept in step with NP_VERDICT_HEADER and NP_VERDICT_FILE_MAX in compatverdict.h.
    static let header = "bridgeplay-compat-verdicts"
    static let maxBytes = 2 << 20

    static let labels = ["one_report": "o", "broken_since": "s", "playable": "p", "doesnt_run": "d", "mixed": "m"]
    static let ids: Set<String> = ["eac", "battleye", "ricochet", "vanguard", "ace", "xigncode3", "nprotect",
                                   "javelin", "denuvo", "vac", "other"]
    // compat/games.json names, lower case with only letters and digits.
    static let names = ["easyanticheat": "eac", "battleye": "battleye", "ricochet": "ricochet", "vanguard": "vanguard",
                        "anticheatexpert": "ace", "xigncode3": "xigncode3", "nprotectgameguard": "nprotect",
                        "eajavelin": "javelin", "eaanticheat": "javelin", "denuvoanticheat": "denuvo", "vac": "vac",
                        "valveanticheat": "vac"]

    // The id for a maintainer's anti-cheat name, nil for none.
    static func anticheatID(_ name: String) -> String? {
        let key = name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if key.isEmpty || key == "none" || key == "noneknown" || key == "unknown" { return nil }
        return names[key] ?? "other"
    }

    // The folder the dylib reads, as np_support_path picks it: the old notproton one while only
    // that exists. nil before Bridgeplay is installed, so nothing creates a folder.
    static func folder(support: URL = SupportPaths.support, legacy: URL = SupportPaths.legacyApplicationSupport) -> URL? {
        func isDir(_ url: URL) -> Bool {
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &dir) && dir.boolValue
        }
        if isDir(support) { return support }
        return isDir(legacy) ? legacy : nil
    }

    private static func appID(_ value: Any?) -> UInt32? {
        let text = (value as? Int).map(String.init) ?? value as? String
        guard let text, text.first != "0", text.count <= 10, text.allSatisfy(\.isASCIIDigit),
              let id = UInt32(text), id > 0, id < 1 << 31 else { return nil }
        return id
    }

    private static func count(_ value: Any?) -> Int {
        min(max((value as? Int) ?? 0, 0), 999_999)
    }

    // "0.7.66" as is, "Steam build 123" as s123, anything else -.
    static func since(_ value: Any?) -> String {
        guard let text = value as? String else { return "-" }
        if text.wholeMatch(of: /\d{1,4}(\.\d{1,4}){0,3}/) != nil { return text }
        if let m = text.wholeMatch(of: /Steam build (\d{1,12})/) { return "s\(m.1)" }
        return "-"
    }

    // The file's text from the two downloads, either of which may be missing. nil when there is
    // nothing to show.
    static func tsv(index: Data?, games: Data?) -> String? {
        struct Row { var v = "-", n = 0, p = 0, i = 0, b = 0, since = "-", ac: [String] = [] }
        var rows: [UInt32: Row] = [:]
        var updated = 0
        if let index, let root = try? JSONSerialization.jsonObject(with: index) as? [String: Any],
           root["schema"] as? Int == 1 {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let text = root["updated"] as? String,
               let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
                updated = max(0, Int(date.timeIntervalSince1970))
            }
            for (key, value) in root["games"] as? [String: Any] ?? [:] {
                guard let id = appID(key), let g = value as? [String: Any],
                      let label = (g["v"] as? String).flatMap({ labels[$0] }) else { continue }
                rows[id, default: Row()].v = label
                rows[id]!.n = count(g["n"])
                rows[id]!.p = count(g["p"])
                rows[id]!.i = count(g["i"])
                rows[id]!.b = count(g["b"])
                rows[id]!.since = since(g["since"])
            }
            for (key, value) in root["anticheat"] as? [String: Any] ?? [:] {
                guard let id = appID(key) else { continue }
                let found = (value as? [Any] ?? []).compactMap { $0 as? String }.filter(ids.contains)
                if !found.isEmpty { rows[id, default: Row()].ac += found }
            }
        }
        if let games, let list = try? JSONSerialization.jsonObject(with: games) as? [[String: Any]] {
            for game in list {
                guard let id = appID(game["appid"]), let name = game["anticheat"] as? String else { continue }
                // "Easy Anti-Cheat, BattlEye" names two.
                let found = name.split(separator: ",").compactMap { anticheatID(String($0)) }
                if !found.isEmpty { rows[id, default: Row()].ac = found + (rows[id]?.ac ?? []) }
            }
        }
        if rows.isEmpty { return nil }
        var lines = ["\(header)\t1\t\(updated)"]
        for id in rows.keys.sorted() {
            let r = rows[id]!
            var seen = Set<String>()
            let ac = r.ac.filter { seen.insert($0).inserted }.prefix(4)
            lines.append([String(id), r.v, String(r.n), String(r.p), String(r.i), String(r.b), r.since,
                          ac.isEmpty ? "-" : ac.joined(separator: ",")].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // Writes the file when it changed. A file the dylib would refuse is not written.
    @discardableResult
    static func write(_ text: String, into folder: URL) -> Bool {
        let data = Data(text.utf8)
        guard data.count <= maxBytes else { return false }
        let url = folder.appending(path: fileName)
        if (try? Data(contentsOf: url)) == data { return true }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    // Refreshes the cached index when it is a day old and rewrites the file. Never throws; run
    // off the main thread, after VerifiedGames.load so compat/games.json is fresh too.
    static func refresh(cache: URL = cache, games: URL = VerifiedGames.cache, folder: URL? = folder(),
                        session: URLSession = .shared, now: Date = Date()) async {
        guard let folder else { return }
        let modified = (try? FileManager.default.attributesOfItem(atPath: cache.path(percentEncoded: false)))?[.modificationDate] as? Date
        if modified.map({ now.timeIntervalSince($0) >= 86400 }) ?? true {
            var request = URLRequest(url: source, timeoutInterval: 20)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schema"] as? Int == 1 {
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cache, options: .atomic)
            } else if modified != nil {
                // No branch yet, offline, or a schema this build doesn't read: try again tomorrow.
                try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: cache.path(percentEncoded: false))
            }
        }
        guard let text = tsv(index: try? Data(contentsOf: cache), games: try? Data(contentsOf: games)) else { return }
        write(text, into: folder)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
