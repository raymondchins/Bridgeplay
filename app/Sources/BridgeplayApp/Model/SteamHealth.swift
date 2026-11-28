import Darwin
import Foundation

// What the dylib reports about the Steam it runs in: health.json, written at each Steam start
// and after its hooks are in. health-web.json carries the Steam page's gates and boot.json the
// crash-loop strikes. All three live in the support folder of the macOS user running Steam.
struct SteamHealth: Equatable, Sendable {
    enum Mode: String, Sendable {
        case active, passive, off, unknown
    }

    var written: Date?
    var pid: Int32?
    var patchBuild: String?
    var steamBuild: String?
    var channel: String?
    var sigdbBuild: String?
    var mode: Mode = .unknown
    var strikes: Int?
    var signaturesResolved: Int?
    var signaturesRequired: Int?
    var hooksInstalled: Int?
    var hooksTotal: Int?
    var layoutKnown: Bool?

    static func parse(_ data: Data) -> SteamHealth? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var health = SteamHealth()
        health.written = HealthJSON.date(json["written"])
        health.pid = HealthJSON.int(json["pid"]).map(Int32.init(truncatingIfNeeded:))
        health.patchBuild = HealthJSON.string(json["patch_build"])
        health.steamBuild = HealthJSON.string(json["steam_build"])
        health.channel = HealthJSON.string(json["channel"])
        health.sigdbBuild = HealthJSON.string(json["sigdb_build"])
        health.mode = HealthJSON.string(json["mode"]).flatMap { Mode(rawValue: $0.lowercased()) } ?? .unknown
        health.strikes = HealthJSON.int(json["strikes"])
        health.signaturesResolved = HealthJSON.int(json["signatures_resolved"])
        health.signaturesRequired = HealthJSON.int(json["signatures_required"])
        health.hooksInstalled = HealthJSON.int(json["hooks_installed"])
        health.hooksTotal = HealthJSON.int(json["hooks_total"])
        health.layoutKnown = HealthJSON.bool(json["layout_known"])
        return health
    }

    // Every signature found, every hook in, the client's layout known. A missing count says nothing.
    var isComplete: Bool {
        func short(_ have: Int?, _ need: Int?) -> Bool {
            guard let have, let need else { return false }
            return have < need
        }
        return !short(signaturesResolved, signaturesRequired) && !short(hooksInstalled, hooksTotal) && layoutKnown != false
    }
}

// health-web.json: the Steam page's patch gates, written by Steam Helper.
struct SteamWebHealth: Equatable, Sendable {
    var written: Date?
    var gatesApplied: Int?
    var gatesTotal: Int?

    static func parse(_ data: Data) -> SteamWebHealth? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return SteamWebHealth(written: HealthJSON.date(json["written"]),
                              gatesApplied: HealthJSON.int(json["gates_applied"]),
                              gatesTotal: HealthJSON.int(json["gates_total"]))
    }

    var isComplete: Bool {
        guard let gatesApplied, let gatesTotal else { return true }
        return gatesApplied >= gatesTotal
    }
}

struct HealthReading: Equatable, Sendable {
    enum Freshness: Equatable, Sendable {
        // The pid in health.json is this user's running Steam.
        case live
        // Steam is closed, and the patch and Steam builds are the ones the file names.
        case lastStart
        // From another build or a Steam that is gone: says nothing.
        case stale
        // No health.json (a Bridgeplay before it, or Steam never started with it).
        case missing
    }

    var health: SteamHealth?
    var web: SteamWebHealth?
    var bootStrikes: Int?
    var paused = false
    var freshness: Freshness = .missing

    var mode: SteamHealth.Mode? {
        guard freshness == .live || freshness == .lastStart else { return nil }
        return health?.mode
    }

    static let none = HealthReading()
}

enum SteamHealthStore {
    static let healthFile = "health.json"
    static let webFile = "health-web.json"
    static let bootFile = "boot.json"
    static let pausedFile = "paused"

    // The dylib's np_support_path: .../bridgeplay, or the old .../notproton while only it exists.
    static func supportFolder(home: URL = SupportPaths.home) -> URL {
        let support = home.appending(path: "Library/Application Support")
        let current = support.appending(path: SupportPaths.supportDirName)
        let legacy = support.appending(path: SupportPaths.legacySupportDirName)
        return !isDirectory(current) && isDirectory(legacy) ? legacy : current
    }

    static func read(
        folder: URL = supportFolder(),
        installedPatch: String?,
        installedSteam: String? = installedSteamBuild(),
        isThisUsersSteam: (Int32) -> Bool = isThisUsersSteam
    ) -> HealthReading {
        var reading = HealthReading()
        reading.paused = FileManager.default.fileExists(atPath: folder.appending(path: pausedFile).path(percentEncoded: false))
        reading.web = (try? Data(contentsOf: folder.appending(path: webFile))).flatMap(SteamWebHealth.parse)
        if let data = try? Data(contentsOf: folder.appending(path: bootFile)),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            reading.bootStrikes = HealthJSON.int(json["strikes"])
        }
        guard let data = try? Data(contentsOf: folder.appending(path: healthFile)),
              let health = SteamHealth.parse(data) else { return reading }
        reading.health = health
        if let pid = health.pid, pid > 0, isThisUsersSteam(pid) {
            reading.freshness = .live
        } else if let patch = health.patchBuild, let steam = health.steamBuild,
                  patch == installedPatch, steam == installedSteam {
            reading.freshness = .lastStart
        } else {
            reading.freshness = .stale
        }
        return reading
    }

    // "4.0.85", the deploy key in Steam's install record, is patch build 85.
    static func patchBuild(deployed: String?) -> String? {
        guard let deployed else { return nil }
        return deployed.hasPrefix("4.0.") ? String(deployed.dropFirst(4)) : deployed
    }

    // Steam's client build: "version" in the manifest beside the newest package/*.installed.
    static func installedSteamBuild(
        package: URL = SupportPaths.Steam.innerApp.appending(path: "Contents/MacOS/package")
    ) -> String? {
        let files = FileManager.default
        let entries = (try? files.contentsOfDirectory(at: package, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = entries.filter { $0.pathExtension == "installed" }.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (da, a.lastPathComponent) < (db, b.lastPathComponent)
        }
        guard let newest else { return nil }
        let manifest = newest.deletingPathExtension().appendingPathExtension("manifest")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            if let (key, value, _) = BrandMigration.keyValue(String(line)), key == "version" { return value }
        }
        return nil
    }

    static func isThisUsersSteam(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return false }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).hasSuffix("/steam_osx")
    }

    // Pause: the dylib reads this file at Steam's start and leaves Steam alone. Nothing in
    // Steam.app or Steam's config is touched.
    static func setPaused(_ paused: Bool, folder: URL = supportFolder()) throws {
        let file = folder.appending(path: pausedFile)
        if paused {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("paused from the Bridgeplay app\n".utf8).write(to: file, options: .atomic)
        } else if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: file)
        }
    }

    // Try Again after the breaker tripped: no strikes, and no passive verdict from the last
    // start. The dylib writes both files again at the next Steam start.
    static func clearStrikes(folder: URL = supportFolder()) throws {
        for name in [bootFile, healthFile] {
            let file = folder.appending(path: name)
            guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

// The dylib writes JSON by hand, so numbers may come as strings and flags as 0 or 1.
private enum HealthJSON {
    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text.isEmpty ? nil : text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: number.boolValue
        case let text as String: ["1", "true", "yes"].contains(text.lowercased()) ? true
            : ["0", "false", "no"].contains(text.lowercased()) ? false : nil
        default: nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        (int(value)).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}
