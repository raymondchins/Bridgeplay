import Foundation

// How a game's last launch ended, for the card under the Status hero. compat_run.sh writes
// compatdata/<appid>/bridgeplay-last-launch at the end of every launch, including ones that
// stopped before the game ran; without that file the run log is read instead.
struct LaunchRecord: Equatable, Sendable {
    enum Stopper: String, Sendable {
        case steam, game, unknown
    }

    static let fileName = "bridgeplay-last-launch"

    var code: String
    var exit: Int?
    var seconds: Int?
    var stopped: Stopper = .unknown
    var backend: String?
    var engine: String?
    // Seconds to the first window. nil: not recorded; .some(nil): recorded, no window ever.
    var window: Int??
    var ended: Date?

    // KEY=VALUE lines. Unknown keys are ignored, so later versions stay readable.
    static func parse(_ text: String) -> LaunchRecord? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if values[key] == nil { values[key] = value }
        }
        guard let code = values["code"], !code.isEmpty else { return nil }
        var record = LaunchRecord(code: code.lowercased())
        record.exit = values["exit"].flatMap { Int($0) }
        record.seconds = values["seconds"].flatMap { Int($0) }
        record.stopped = values["stopped"].flatMap { Stopper(rawValue: $0.lowercased()) } ?? .unknown
        record.backend = values["backend"].flatMap { $0.isEmpty ? nil : $0 }
        record.engine = values["engine"].flatMap { $0.isEmpty ? nil : $0 }
        if let window = values["window"] { record.window = .some(Int(window)) }
        record.ended = values["ended"].flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
        return record
    }

    var verdict: LaunchVerdict {
        let byCode = LaunchVerdict(code: code)
        guard stopped == .steam else { return byCode }
        // The player's Stop before the game started is no failure either.
        if byCode == .aborted { return .stoppedFromSteam }
        guard !byCode.beforeLaunch else { return byCode }
        if case .some(.none) = window { return .neverOpenedWindow }
        return .stoppedFromSteam
    }
}

// The reason a launch ended, as one localised sentence. The codes are the run script's.
enum LaunchVerdict: Equatable, Sendable {
    case ok
    case stoppedFromSteam
    case neverOpenedWindow
    case quitEarly
    case crashed
    case illegalInstruction
    case missingFile
    case macKilled
    case lowMemory
    case antiCheat
    case stoppedOutside
    case aborted
    case rosettaMissing
    case engineMissing
    case engineUnsupported
    case untracked
    case unexpected

    // The codes compat_run.sh writes (exit_outcome and np_outcome), listed in docs/DEVELOPING.md
    // under "The outcome record". Anything else reads as "stopped unexpectedly".
    init(code: String) {
        switch code {
        case "ok": self = .ok
        case "stopped_from_steam": self = .stoppedFromSteam
        case "quit_early": self = .quitEarly
        case "crashed", "generic_failure", "game_error", "exit_code",
             "abort", "access_violation", "fail_fast", "invalid_parameter", "cpp_exception",
             "heap_corruption", "stack_overflow":
            self = .crashed
        case "illegal_instruction": self = .illegalInstruction
        case "dll_not_found", "dll_init_failed": self = .missingFile
        case "sigkill": self = .lowMemory
        case "sigill", "sigtrap", "sigabrt", "sigfpe", "sigbus", "sigsegv": self = .macKilled
        case "sighup", "sigint", "sigterm": self = .stoppedOutside
        case "anticheat_driver", "anticheat_blocked": self = .antiCheat
        case "launch_services": self = .untracked
        case "aborted": self = .aborted
        case "rosetta_missing": self = .rosettaMissing
        case "engine_missing": self = .engineMissing
        case "engine_unsupported": self = .engineUnsupported
        default: self = .unexpected
        }
    }

    // A normal end has no card, nor does one whose status Bridgeplay could not see.
    var failed: Bool { ![.ok, .stoppedFromSteam, .untracked].contains(self) }

    // Stops before Wine started the game.
    var beforeLaunch: Bool {
        [.antiCheat, .aborted, .rosettaMissing, .engineMissing, .engineUnsupported].contains(self)
    }

    // A prefix rebuild can help only when Wine ran.
    var offersRebuild: Bool {
        switch self {
        case .crashed, .missingFile, .macKilled, .quitEarly, .neverOpenedWindow, .unexpected: true
        default: false
        }
    }

    var sentence: String {
        switch self {
        case .ok: String(localized: "Quit normally.")
        case .stoppedFromSteam: String(localized: "Stopped from Steam.")
        case .neverOpenedWindow: String(localized: "No window opened.")
        case .quitEarly: String(localized: "Closed early.")
        case .crashed: String(localized: "Crashed.")
        case .illegalInstruction: String(localized: "Used a CPU instruction this Mac lacks.")
        case .missingFile: String(localized: "A Windows file didn't load.")
        case .macKilled: String(localized: "Stopped by macOS or Wine.")
        case .lowMemory: String(localized: "macOS stopped it, likely low memory.")
        case .antiCheat: String(localized: "Anti-cheat needs Windows.")
        case .stoppedOutside: String(localized: "Stopped outside Steam.")
        case .aborted: String(localized: "Stopped before starting. See the log.")
        case .rosettaMissing: String(localized: "Needs Rosetta, which isn't installed.")
        case .engineMissing: String(localized: "Engine missing. Set it up again below.")
        case .engineUnsupported:
            String(localized: "Needs macOS 26.5, or its Rosetta tool in Steam.")
        case .untracked: String(localized: "Started outside Steam, so the result is unknown.")
        case .unexpected: String(localized: "Stopped unexpectedly.")
        }
    }
}

// One game's last launch, from its record or its run log.
struct LastLaunch: Equatable, Sendable, Identifiable {
    let prefix: WinePrefix
    let verdict: LaunchVerdict
    let seconds: Int?
    let ended: Date
    // A pfx folder exists, so Rebuild has something to rebuild.
    let hasPrefix: Bool

    var id: String { "\(prefix.id)@\(Int(ended.timeIntervalSince1970))" }

    var duration: String {
        guard let seconds else { return String(localized: "Stopped") }
        if seconds < 120 { return String(localized: "Stopped after \(seconds) s") }
        return String(localized: "Stopped after \(seconds / 60) min")
    }

    static let maxAge: TimeInterval = 3 * 86400

    // Every compatdata/<appid>/ on every library, with or without a pfx: a launch that never
    // started Wine has none, and is the one most worth explaining.
    static func scan(libraries: [SteamLibrary] = PrefixStore.libraries(), now: Date = Date(),
                     userdata: URL = SupportPaths.Steam.userData.appending(path: "userdata")) -> [LastLaunch] {
        var shortcuts: [String: String]?
        var found: [LastLaunch] = []
        let files = FileManager.default
        for library in libraries {
            let entries = (try? files.contentsOfDirectory(
                at: library.compatdata, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                let appID = entry.lastPathComponent
                guard !appID.isEmpty, appID.allSatisfy(\.isNumber) else { continue }
                var name = PrefixStore.appName(appID: appID, in: library)
                if name == nil, let id = UInt32(appID), id & 0x8000_0000 != 0 {
                    if shortcuts == nil { shortcuts = PrefixStore.shortcutNames(userdata: userdata) }
                    name = shortcuts?[appID]
                }
                let prefix = WinePrefix(appID: appID, name: name, library: library, lastUsed: nil)
                guard let launch = read(prefix), now.timeIntervalSince(launch.ended) < maxAge else { continue }
                found.append(launch)
            }
        }
        return found.sorted { $0.ended > $1.ended }
    }

    static func read(_ prefix: WinePrefix) -> LastLaunch? {
        var isDirectory: ObjCBool = false
        let hasPrefix = FileManager.default.fileExists(atPath: prefix.pfx.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
        let recordURL = prefix.root.appending(path: LaunchRecord.fileName)
        if let text = try? String(contentsOf: recordURL, encoding: .utf8), let record = LaunchRecord.parse(text) {
            let modified = modificationDate(recordURL) ?? Date.distantPast
            return LastLaunch(prefix: prefix, verdict: record.verdict, seconds: record.seconds,
                              ended: record.ended ?? modified, hasPrefix: hasPrefix)
        }
        let log = PrefixLog.launch.url(for: prefix)
        guard let modified = modificationDate(log), let text = PrefixLog.text(of: log),
              let outcome = fromLog(text, modified: modified) else { return nil }
        return LastLaunch(prefix: prefix, verdict: outcome.verdict, seconds: outcome.seconds,
                          ended: modified, hasPrefix: hasPrefix)
    }

    // The last run block of a run log, sorted into a verdict. A block with neither an exit
    // line nor a stop before launch is a game still running, or a log cut short: no verdict.
    static func fromLog(_ log: String, modified: Date) -> (verdict: LaunchVerdict, seconds: Int?)? {
        let headers = ["=== bridgeplay run ", "=== notproton run "]
        let starts = headers.compactMap { header -> String.Index? in
            if let found = log.range(of: "\n" + header, options: .backwards) { return log.index(after: found.lowerBound) }
            return log.hasPrefix(header) ? log.startIndex : nil
        }
        guard let start = starts.max() else { return nil }
        let block = log[start...]

        if let session = GameSession.last(in: String(block), modified: modified) {
            return (verdict(exited: session.exitStatus, seconds: session.seconds,
                            stoppedBySteam: session.stoppedBySteam, block: block), session.seconds)
        }
        if block.contains("=== not launched: kernel anti-cheat") { return (.antiCheat, nil) }
        if block.contains("=== Rosetta 2 is not installed") { return (.rosettaMissing, nil) }
        if block.contains("=== runner is missing ") || block.contains("behind this compatibility tool is not set up") {
            return (.engineMissing, nil)
        }
        if block.contains("=== Wine through FEX did not start") { return (.engineUnsupported, nil) }
        if block.contains("=== aborted during ") { return (.aborted, nil) }
        return nil
    }

    static func verdict(exited status: Int, seconds: Int?, stoppedBySteam: Bool, block: Substring) -> LaunchVerdict {
        if block.contains("=== exit cause: kernel anti-cheat") { return .antiCheat }
        if stoppedBySteam { return .stoppedFromSteam }
        if block.contains("Unhandled illegal instruction") || status == 29 { return .illegalInstruction }
        if block.contains("err:module:import_dll") || status == 53 || status == 66 { return .missingFile }
        switch status {
        case 137: return .lowMemory
        case 132...139: return .macKilled
        case 129, 130, 143: return .stoppedOutside
        default: break
        }
        if block.contains("=== exit cause: ") || status != 0 { return .crashed }
        if let seconds, seconds < 60 { return .quitEarly }
        return .ok
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

// Launches the player closed from the card. Keyed by the launch, so the next one shows.
enum LastLaunchDismissals {
    static let key = "BridgeplayHiddenLaunches"

    static func hidden(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func hide(_ launch: LastLaunch, defaults: UserDefaults = .standard) {
        var list = defaults.stringArray(forKey: key) ?? []
        guard !list.contains(launch.id) else { return }
        list.append(launch.id)
        defaults.set(Array(list.suffix(50)), forKey: key)
    }

    // At most three, newest first, only the ones that went wrong.
    static func visible(_ launches: [LastLaunch], hidden: Set<String>) -> [LastLaunch] {
        Array(launches.filter { $0.verdict.failed && !hidden.contains($0.id) }.prefix(3))
    }
}
