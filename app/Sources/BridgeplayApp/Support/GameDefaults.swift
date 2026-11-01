import Foundation

// The settings Game Defaults, the Setup Assistant and the Status page offer for every game.
// Bridgeplay ships its own in gamefixes-default/default.conf, replaced on every install, and
// the user's choices live in gamefixes/default.conf over them. The run script reads both
// before the per-game confs and the launch options, which win over them. Only the lines for
// these keys are rewritten: every other line, comment or setting the user wrote stays as it
// is. A choice that matches what the layers below already give writes no line, so a later
// change to Bridgeplay's shipped defaults still reaches the user.
enum GameDefaults {

    enum Kind: Equatable, Sendable {
        case toggle
        // The values the page offers, in its order.
        case choice([String])
        case dllOverrides
    }

    enum Requirement: Sendable {
        // WineCX with a Game Porting Toolkit linked in.
        case d3dmetal
    }

    enum Setting: String, CaseIterable, Identifiable, Sendable {
        case backend
        case highResolution
        case metalHUD
        case nvapi
        case metalFX
        case dlssFrameGen
        case advertiseAVX
        case msync
        case vsync
        case frameGen
        case frameGenQuality
        case frameGenUI
        case frameGenFallback
        case frameGenEngine
        case dllOverrides

        var id: String { rawValue }

        // The first spelling is the one written; the others are read and replaced.
        var keys: [String] {
            switch self {
            case .backend: ["BACKEND"]
            case .highResolution: ["RETINA", "BRIDGEPLAY_RETINA"]
            case .metalHUD: ["MTL_HUD_ENABLED"]
            case .nvapi: ["NVAPI"]
            case .metalFX: ["D3DM_ENABLE_METALFX"]
            case .dlssFrameGen: ["DLSS_FG"]
            case .advertiseAVX: ["ROSETTA_ADVERTISE_AVX"]
            case .msync: ["MSYNC"]
            case .vsync: ["VSYNC", "BRIDGEPLAY_VSYNC"]
            case .frameGen: ["FRAMEGEN", "BRIDGEPLAY_FRAMEGEN"]
            case .frameGenQuality: ["FRAMEGEN_QUALITY", "BRIDGEPLAY_FRAMEGEN_QUALITY"]
            case .frameGenUI: ["FRAMEGEN_UI", "BRIDGEPLAY_FRAMEGEN_UI"]
            case .frameGenFallback: ["FRAMEGEN_FALLBACK", "BRIDGEPLAY_FRAMEGEN_FALLBACK"]
            case .frameGenEngine: ["FRAMEGEN_ENGINE", "BRIDGEPLAY_FRAMEGEN_ENGINE"]
            case .dllOverrides: ["DLLOVERRIDES"]
            }
        }

        // The same setting in a game's launch options, where it wins over every conf.
        // NVAPI and DLSS_FG have no launch-option spelling, and WINEDLLOVERRIDES adds to DLLOVERRIDES
        // per DLL instead of replacing it.
        var launchKeys: [String] {
            switch self {
            case .backend: ["BRIDGEPLAY_BACKEND", "NOTPROTON_BACKEND", "CX_GRAPHICS_BACKEND"]
            case .metalHUD, .metalFX, .advertiseAVX: keys
            case .msync: ["WINEMSYNC"]
            case .nvapi, .dlssFrameGen, .dllOverrides: []
            case .highResolution, .vsync, .frameGen, .frameGenQuality, .frameGenUI, .frameGenFallback, .frameGenEngine:
                ["BRIDGEPLAY_\(keys[0])", "NOTPROTON_\(keys[0])"]
            }
        }

        var kind: Kind {
            switch self {
            case .backend: .choice(["dxmt", "dxvk", "wined3d", "d3dmetal"])
            case .msync: .choice(["1", "0"])
            case .frameGen: .choice(["0", "2", "3", "adaptive"])
            case .frameGenQuality: .choice(["performance", "balanced", "quality"])
            case .frameGenEngine: .choice(["own", "metalfx"])
            case .dllOverrides: .dllOverrides
            default: .toggle
            }
        }

        // What the run script accepts in a conf (gamefix_reason); nil takes any safe value.
        var accepted: [String]? {
            switch self {
            case .metalHUD, .metalFX, .dllOverrides: nil
            case .backend: ["dxmt", "dxvk", "wined3d", "d3dmetal"]
            case .frameGen: ["0", "1", "2", "3", "adaptive"]
            case .frameGenQuality: ["performance", "balanced", "quality"]
            case .frameGenEngine: ["own", "metalfx"]
            default: ["0", "1"]
            }
        }

        // What a game gets when no conf sets the key; nil when the run script decides per
        // game or engine (the backend is auto-detected, msync follows the engine).
        var fallback: String? {
            switch self {
            case .backend, .msync, .dllOverrides: nil
            case .frameGenUI, .frameGenFallback: "1"
            case .frameGenQuality: "balanced"
            case .frameGenEngine: "own"
            default: "0"
            }
        }

        var requirement: Requirement? {
            switch self {
            case .nvapi, .dlssFrameGen, .metalFX: .d3dmetal
            default: nil
            }
        }
    }

    // Where the value a game gets comes from.
    enum Source: Equatable, Sendable {
        case engine
        case bridgeplay
        case user
    }

    struct Resolved: Equatable, Sendable {
        var value: String?
        var source: Source
    }

    struct Refused: LocalizedError, Equatable {
        var reason: String
        var errorDescription: String? { reason }
    }

    struct Problem: Equatable, Sendable {
        var setting: Setting
        var reason: String
    }

    static var file: URL { SupportPaths.gamefixes.appending(path: "default.conf") }
    static var shippedFile: URL { SupportPaths.gamefixesDefault.appending(path: "default.conf") }

    static let header = "# Settings for every game. Per-game confs and Steam launch options win over these."

    // MARK: Reading

    // The last accepted assignment wins, as in the run script, which skips a refused line.
    static func value(_ setting: Setting, in text: String) -> String? {
        var found: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let (key, value) = assignment(line), setting.keys.contains(key),
                  refusal(value, for: setting) == nil
            else { continue }
            found = value
        }
        // The first frame generation release spelled 2x as 1.
        if setting == .frameGen, found == "1" { return "2" }
        return found
    }

    static func resolve(_ setting: Setting, user: String, shipped: String) -> Resolved {
        if let found = Self.value(setting, in: user) { return Resolved(value: found, source: .user) }
        if let found = Self.value(setting, in: shipped) { return Resolved(value: found, source: .bridgeplay) }
        return Resolved(value: setting.fallback, source: .engine)
    }

    static func isOn(_ setting: Setting, in text: String, shipped: String = "") -> Bool {
        resolve(setting, user: text, shipped: shipped).value == "1"
    }

    static func isOn(_ setting: Setting, at url: URL = file, shipped: URL = shippedFile) -> Bool {
        isOn(setting, in: read(url), shipped: read(shipped))
    }

    // Lines for these keys that the run script refuses, with the reason.
    static func problems(in text: String) -> [Problem] {
        var found: [Problem] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let (key, value) = assignment(line),
                  let setting = Setting.allCases.first(where: { $0.keys.contains(key) }),
                  let reason = refusal(value, for: setting)
            else { continue }
            found.append(Problem(setting: setting, reason: reason))
        }
        return found
    }

    // MARK: Writing

    // nil resets the setting: its lines go and the layers below apply again.
    static func setting(_ setting: Setting, to value: String?, in text: String, shipped: String = "") -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        lines.removeAll { line in assignment(Substring(line)).map { setting.keys.contains($0.0) } ?? false }
        let below = Self.value(setting, in: shipped) ?? setting.fallback
        if let value, value != below {
            if lines.isEmpty { lines.append(header) }
            lines.append("\(setting.keys[0])=\(value)")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // Every setting back to Bridgeplay's defaults; lines for other keys stay.
    static func resettingAll(in text: String) -> String {
        Setting.allCases.reduce(text) { Self.setting($1, to: nil, in: $0) }
    }

    static func set(_ setting: Setting, to on: Bool, at url: URL = file, shipped: URL = shippedFile) throws {
        try set(setting, to: on ? "1" : "0", at: url, shipped: shipped)
    }

    static func set(_ setting: Setting, to value: String?, at url: URL = file, shipped: URL = shippedFile) throws {
        if let value, let reason = refusal(value, for: setting) { throw Refused(reason: reason) }
        let current = read(url)
        try write(Self.setting(setting, to: value, in: current, shipped: read(shipped)), replacing: current, at: url)
        AppLog.note("game defaults: \(setting.keys[0]) \(value ?? "reset")")
    }

    static func resetAll(at url: URL = file) throws {
        let current = read(url)
        try write(resettingAll(in: current), replacing: current, at: url)
        AppLog.note("game defaults: all reset")
    }

    private static func write(_ updated: String, replacing current: String, at url: URL) throws {
        guard updated != current else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(updated.utf8).write(to: url, options: .atomic)
    }

    // MARK: Validation, as gamefix_reason in compat_run.sh

    static func refusal(_ value: String, for setting: Setting) -> String? {
        if value.contains("`") || value.contains("$(") || value.contains("\"") || value.contains("'") {
            return String(localized: "Bridgeplay ignores a value with a backtick, $( or a quote.")
        }
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return String(localized: "Bridgeplay ignores a value with a control character.")
        }
        if value.count > 1024 {
            return String(localized: "Bridgeplay ignores a value over 1024 characters.")
        }
        if let accepted = setting.accepted, !accepted.contains(value) {
            return String(localized: "Bridgeplay doesn't know this value.")
        }
        if setting == .dllOverrides, !validDLLOverrides(value) {
            return String(localized: "Use Wine's syntax, for example dinput8=n,b;xinput1_3=n.")
        }
        return nil
    }

    // name[,name...]=[n|b|n,b|b,n|d] entries joined by semicolons (valid_dll_overrides).
    static func validDLLOverrides(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let nameCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.,+-")
        for entry in text.split(separator: ";") {
            guard let equals = entry.firstIndex(of: "=") else { return false }
            let names = entry[..<equals]
            let mode = String(entry[entry.index(after: equals)...])
            if names.isEmpty || names.hasPrefix(",") || names.hasSuffix(",") || names.contains(",,") { return false }
            if names.contains(where: { !nameCharacters.contains($0) }) { return false }
            if !["n", "b", "d", "n,b", "b,n"].contains(mode) { return false }
        }
        return true
    }

    // MARK: Moving Bridgeplay's defaults out of the user's file

    // Earlier installers wrote Bridgeplay's shipped defaults into the user's own
    // gamefixes/default.conf, where they masked every later change to them. Once the shipped
    // file sits in gamefixes-default/, the user's file keeps only what the user changed: a
    // copy nobody edited goes, and so do lines identical to the copy last installed, while a
    // shipped KEY=1 the user deleted from that recorded copy becomes KEY=0, the off it meant.
    // The original is backed up first, and a marker makes this run once.
    static let splitMarker = ".installer/defaults-split"
    // What the first installers shipped, before .installer/default.conf recorded it.
    static let firstShippedHash = "442803b868fc31b188aa7f650c711efc6b8d2d63cb47399312d028c92be7b130"

    // nil when nothing of the user's is left. Without a record of the installed copy a
    // missing key says nothing: the app writes the file too, so it may never have been there.
    static func splitText(_ user: String, baseline: String, recorded: Bool = true) -> String? {
        if user == baseline { return nil }
        let baseLines = Set(baseline.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var lines = user.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        // Keys the user still sets, shipped value or not, before the shipped lines go.
        let userKeys = Set(lines.compactMap { assignment(Substring($0))?.0 })
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && baseLines.contains(trimmed)
        }
        for line in baseline.split(separator: "\n") where recorded {
            guard let (key, value) = assignment(line), value == "1", !userKeys.contains(key) else { continue }
            lines.append("\(key)=0")
        }
        guard lines.contains(where: { assignment(Substring($0)) != nil }) else { return nil }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n") + "\n"
    }

    // true when it changed the user's file.
    @discardableResult
    static func splitShipped(in support: URL, now: Date = Date()) throws -> Bool {
        let files = FileManager.default
        let marker = support.appending(path: splitMarker)
        let shipped = support.appending(path: "gamefixes-default/default.conf")
        guard !files.fileExists(atPath: marker.path(percentEncoded: false)),
              files.fileExists(atPath: shipped.path(percentEncoded: false))
        else { return false }
        let user = support.appending(path: "gamefixes/default.conf")
        var changed = false
        if files.fileExists(atPath: user.path(percentEncoded: false)) {
            let text = read(user)
            let recorded = support.appending(path: ".installer/default.conf")
            let hasRecord = files.fileExists(atPath: recorded.path(percentEncoded: false))
            let baseline = hasRecord ? read(recorded) : read(shipped)
            let unedited = (try? Digest.sha256(of: user)) == firstShippedHash
            let kept = unedited ? nil : splitText(text, baseline: baseline, recorded: hasRecord)
            if kept != text {
                let backup = support.appending(path: "backups/default.conf.\(Int(now.timeIntervalSince1970))")
                try files.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !files.fileExists(atPath: backup.path(percentEncoded: false)) {
                    try files.copyItem(at: user, to: backup)
                }
                if let kept {
                    try Data(kept.utf8).write(to: user, options: .atomic)
                } else {
                    try files.removeItem(at: user)
                }
                changed = true
            }
        }
        try files.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker, options: .atomic)
        AppLog.note("game defaults: shipped defaults split out\(changed ? ", the user's file reduced" : "")")
        return changed
    }

    // MARK: Games with their own settings

    struct Override: Equatable, Sendable, Identifiable {
        enum Place: Hashable, Sendable {
            // gamefixes/<appid>.conf
            case conf
            // The launch options one Steam account keeps in its localconfig.vdf.
            case launchOptions(account: String)
        }

        var appID: String
        var place: Place
        var settings: [Setting]
        // From the game's appmanifest, or a non-Steam shortcut's name; nil when not installed.
        var name: String? = nil

        var id: String {
            switch place {
            case .conf: "\(appID)/conf"
            case .launchOptions(let account): "\(appID)/\(account)"
            }
        }
    }

    static func confOverrides(_ text: String) -> [Setting] {
        Setting.allCases.filter { Self.value($0, in: text) != nil }
    }

    // The NAME=value words before %command%, which the launch reads as the environment.
    // Without %command% Steam passes the options as the game's arguments, so none count.
    static func launchVariables(_ options: String) -> [String] {
        var names: [String] = []
        for word in options.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if word.lowercased() == "%command%" { return names }
            guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { continue }
            let name = word[..<equals]
            if name.first?.isNumber == false,
               name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
                names.append(String(name))
            }
        }
        return []
    }

    static func launchOverrides(_ options: String) -> [Setting] {
        let names = Set(launchVariables(options))
        return Setting.allCases.filter { !Set($0.launchKeys).isDisjoint(with: names) }
    }

    // LaunchOptions by app id in one localconfig.vdf: the closest numeric key above it
    // names the app, as in the apps block Steam writes.
    static func launchOptions(inLocalConfig text: String) -> [String: String] {
        var found: [String: String] = [:]
        var app: String?
        for line in text.components(separatedBy: "\n") {
            if let key = BrandMigration.quotedKey(line) {
                if !key.isEmpty, key.allSatisfy(\.isNumber) { app = key }
                continue
            }
            guard let app, let (key, value, _) = BrandMigration.keyValue(line),
                  key.caseInsensitiveCompare("LaunchOptions") == .orderedSame
            else { continue }
            found[app] = value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        return found
    }

    // Read only; a game is listed once per place it sets something of these.
    static func overrides(gamefixes: URL = SupportPaths.gamefixes,
                          steamUserData: URL = SupportPaths.Steam.userData,
                          libraries: [SteamLibrary] = PrefixStore.libraries()) -> [Override] {
        let files = FileManager.default
        var found: [Override] = []
        var shortcuts: [String: String]?
        func gameName(_ appID: String) -> String? {
            if let name = libraries.lazy.compactMap({ PrefixStore.appName(appID: appID, in: $0) }).first { return name }
            guard let id = UInt32(appID), id & 0x8000_0000 != 0 else { return nil }
            if shortcuts == nil { shortcuts = PrefixStore.shortcutNames(userdata: steamUserData.appending(path: "userdata")) }
            return shortcuts?[appID]
        }
        let confs = (try? files.contentsOfDirectory(atPath: gamefixes.path(percentEncoded: false))) ?? []
        for name in confs.sorted() where name.hasSuffix(".conf") {
            let appID = String(name.dropLast(".conf".count))
            guard !appID.isEmpty, appID.allSatisfy(\.isNumber) else { continue }
            let settings = confOverrides(read(gamefixes.appending(path: name)))
            if !settings.isEmpty { found.append(Override(appID: appID, place: .conf, settings: settings, name: gameName(appID))) }
        }
        let userdata = steamUserData.appending(path: "userdata")
        let accounts = (try? files.contentsOfDirectory(atPath: userdata.path(percentEncoded: false))) ?? []
        for account in accounts.sorted() where !account.isEmpty && account.allSatisfy(\.isNumber) {
            let text = read(userdata.appending(path: "\(account)/config/localconfig.vdf"))
            for (appID, options) in launchOptions(inLocalConfig: text).sorted(by: { $0.key < $1.key }) {
                let settings = launchOverrides(options)
                if !settings.isEmpty {
                    found.append(Override(appID: appID, place: .launchOptions(account: account),
                                          settings: settings, name: gameName(appID)))
                }
            }
        }
        return found
    }

    // Use Defaults for a game's own conf: its lines for these settings go, after a backup.
    static func clearConf(appID: String, gamefixes: URL = SupportPaths.gamefixes,
                          backups: URL = SupportPaths.backups, now: Date = Date()) throws {
        let url = gamefixes.appending(path: "\(appID).conf")
        let current = read(url)
        let updated = resettingAll(in: current)
        guard updated != current else { return }
        let backup = backups.appending(path: "\(appID).conf.\(Int(now.timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) {
            try FileManager.default.copyItem(at: url, to: backup)
        }
        try Data(updated.utf8).write(to: url, options: .atomic)
        AppLog.note("game defaults: \(appID).conf now uses the defaults")
    }

    // MARK: Text helpers

    static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // KEY=VALUE with surrounding whitespace trimmed, as the run script reads it.
    private static func assignment(_ line: Substring) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let equals = trimmed.firstIndex(of: "="), !trimmed.hasPrefix("#") else { return nil }
        return (String(trimmed[..<equals]), String(trimmed[trimmed.index(after: equals)...]))
    }
}
