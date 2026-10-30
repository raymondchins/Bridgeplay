import Foundation

// Steam's default compatibility tool: CompatToolMapping's "0" entry in config.vdf, which
// applies to every app without a mapping of its own. Steam rewrites config.vdf when it quits,
// so this is only written while Steam is closed, and refused while it runs. The entry it
// replaces is kept in a backup, so removing Bridgeplay can put the user's own choice back.
enum SteamDefaultTool {
    static let globalPriority = "75"

    static var config: URL {
        SupportPaths.Steam.userData.appending(path: "config/config.vdf")
    }

    static var backup: URL {
        SupportPaths.backups.appending(path: "steam-default-tool.json")
    }

    // The fields of a "0" entry, as raw text between their quotes.
    struct Mapping: Codable, Equatable, Sendable {
        var name: String
        var config: String = ""
        var priority: String = SteamDefaultTool.globalPriority
    }

    // What the "0" entry was before Bridgeplay first set it; nil when there was none.
    struct Backup: Codable, Equatable, Sendable {
        var previous: Mapping?
    }

    struct SteamRunning: LocalizedError {
        var errorDescription: String? {
            String(localized: "Steam is running, and it rewrites its settings when it quits. Quit Steam, then try again.")
        }
    }

    static func set(
        _ tool: String, in file: URL = config, backup: URL = backup,
        steamRunning: () -> Bool = { SteamBundle.isRunningForThisUser }
    ) throws {
        guard !steamRunning() else { throw SteamRunning() }
        let (text, result) = try planned(tool, in: file)
        guard result != text else { return }
        // A default that is already one of ours is not the user's, so the backup taken when
        // Bridgeplay first replaced theirs is kept.
        let previous = current(in: text)
        if previous.map({ !ToolName.isOurs($0.name) }) ?? true {
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Backup(previous: previous)).write(to: backup, options: .atomic)
        }
        try result.write(to: file, atomically: true, encoding: .utf8)
    }

    // Whether set() would write, so a caller can leave Steam open when it would not. A new
    // Steam may write config.vdf only when it quits, so a missing one counts as a change.
    static func needsChange(to tool: String, in file: URL = config) throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return true }
        let (text, result) = try planned(tool, in: file)
        return result != text
    }

    private static func planned(_ tool: String, in file: URL) throws -> (text: String, result: String) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw StepFailure(step: step, detail: "Steam has no config.vdf yet. Open Steam once, log in, quit it and run this again.")
        }
        guard let result = updated(text, tool: tool) else {
            throw StepFailure(step: step, detail: "config.vdf has no InstallConfigStore > Software > Valve > Steam section.")
        }
        return (text, result)
    }

    // Puts back what set() replaced when the default is still one of Bridgeplay's tools: the
    // backed up entry, or no "0" entry at all when there is no backup or there was none.
    // A default the user has changed since is left alone. Returns whether it wrote.
    @discardableResult
    static func restore(
        in file: URL = config, backup: URL = backup,
        steamRunning: () -> Bool = { SteamBundle.isRunningForThisUser }
    ) throws -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let mapping = current(in: text), ToolName.isOurs(mapping.name)
        else { return false }
        guard !steamRunning() else { throw SteamRunning() }
        let saved = (try? Data(contentsOf: backup)).flatMap { try? JSONDecoder().decode(Backup.self, from: $0) }
        guard let result = replacingDefault(text, with: saved?.previous), result != text else { return false }
        try WriteRefused.catching(file) { try result.write(to: file, atomically: true, encoding: .utf8) }
        return true
    }

    // Removes the per-game entries under CompatToolMapping whose tool is one of Bridgeplay's
    // (the "0" default is restore()'s). nil when there is nothing to remove.
    static func removingOurGameEntries(_ text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard let mapping = keyLine(lines, "CompatToolMapping", from: 0),
              let open = openBrace(lines, after: mapping), let close = closeBrace(lines, open: open)
        else { return nil }
        let depth = indent(lines[mapping]) + 1
        var ranges: [ClosedRange<Int>] = []
        var index = open + 1
        while index < close {
            guard indent(lines[index]) == depth, BrandMigration.quotedKey(lines[index]) != nil,
                  let entryOpen = openBrace(lines, after: index), let entryClose = closeBrace(lines, open: entryOpen)
            else { index += 1; continue }
            if BrandMigration.quotedKey(lines[index]) != "0", lines[entryOpen + 1 ..< entryClose].contains(where: {
                guard let (field, value, _) = BrandMigration.keyValue($0) else { return false }
                return field.lowercased() == "name" && ToolName.isOurs(value)
            }) { ranges.append(index ... entryClose) }
            index = entryClose + 1
        }
        guard !ranges.isEmpty else { return nil }
        for range in ranges.reversed() { lines.removeSubrange(range) }
        return lines.joined(separator: "\n")
    }

    // Removes Bridgeplay's per-game tool choices from config.vdf, so no game is left naming a
    // deleted tool. Refused while Steam runs. Returns whether it wrote.
    @discardableResult
    static func removeGameEntries(
        in file: URL = config,
        steamRunning: () -> Bool = { SteamBundle.isRunningForThisUser }
    ) throws -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let result = removingOurGameEntries(text)
        else { return false }
        guard !steamRunning() else { throw SteamRunning() }
        try WriteRefused.catching(file) { try result.write(to: file, atomically: true, encoding: .utf8) }
        return true
    }

    static let step = "Set Steam's default compatibility tool"

    // Replaces the "0" entry under CompatToolMapping, or adds it (and CompatToolMapping) when
    // missing. nil when the file has no Valve > Steam section to put it in.
    static func updated(_ text: String, tool: String) -> String? {
        replacingDefault(text, with: Mapping(name: tool))
    }

    // The "0" entry under CompatToolMapping, if there is one.
    static func current(in text: String) -> Mapping? {
        let lines = text.components(separatedBy: "\n")
        guard let (zero, close) = defaultEntry(lines) else { return nil }
        var fields: [String: String] = [:]
        for line in lines[zero + 1 ..< close] {
            guard let (key, value, _) = BrandMigration.keyValue(line) else { continue }
            fields[key.lowercased()] = value
        }
        guard let name = fields["name"] else { return nil }
        return Mapping(name: name, config: fields["config"] ?? "", priority: fields["priority"] ?? globalPriority)
    }

    // Sets the "0" entry to mapping, or removes it when mapping is nil. nil when the file has
    // no place for it.
    static func replacingDefault(_ text: String, with mapping: Mapping?) -> String? {
        var lines = text.components(separatedBy: "\n")

        if let section = keyLine(lines, "CompatToolMapping", from: 0) {
            guard let open = openBrace(lines, after: section), closeBrace(lines, open: open) != nil else { return nil }
            let replacement = mapping.map { entry($0, depth: indent(lines[section]) + 1) } ?? []
            if let (zero, zeroClose) = defaultEntry(lines) {
                lines.replaceSubrange(zero ... zeroClose, with: replacement)
            } else {
                lines.insert(contentsOf: replacement, at: open + 1)
            }
            return lines.joined(separator: "\n")
        }
        guard let mapping else { return text }

        guard let valve = keyLine(lines, "Valve", from: 0),
              let steam = keyLine(lines, "Steam", from: valve + 1),
              let open = openBrace(lines, after: steam)
        else { return nil }
        let depth = indent(lines[steam]) + 1
        let tabs = String(repeating: "\t", count: depth)
        let block = ["\(tabs)\"CompatToolMapping\"", "\(tabs){"] + entry(mapping, depth: depth + 1) + ["\(tabs)}"]
        lines.insert(contentsOf: block, at: open + 1)
        return lines.joined(separator: "\n")
    }

    // The "0" key line and its closing brace, directly under CompatToolMapping.
    private static func defaultEntry(_ lines: [String]) -> (Int, Int)? {
        guard let mapping = keyLine(lines, "CompatToolMapping", from: 0),
              let open = openBrace(lines, after: mapping), let close = closeBrace(lines, open: open)
        else { return nil }
        let entryDepth = indent(lines[mapping]) + 1
        guard let zero = (open + 1 ..< close).first(where: {
            indent(lines[$0]) == entryDepth && BrandMigration.quotedKey(lines[$0]) == "0"
        }), let zeroOpen = openBrace(lines, after: zero), let zeroClose = closeBrace(lines, open: zeroOpen)
        else { return nil }
        return (zero, zeroClose)
    }

    private static func entry(_ mapping: Mapping, depth: Int) -> [String] {
        let tabs = String(repeating: "\t", count: depth)
        return [
            "\(tabs)\"0\"",
            "\(tabs){",
            "\(tabs)\t\"name\"\t\t\"\(mapping.name)\"",
            "\(tabs)\t\"config\"\t\t\"\(mapping.config)\"",
            "\(tabs)\t\"priority\"\t\t\"\(mapping.priority)\"",
            "\(tabs)}",
        ]
    }

    // Section names compare case-insensitively, as Steam's KeyValues does.
    private static func keyLine(_ lines: [String], _ name: String, from start: Int) -> Int? {
        guard start < lines.count else { return nil }
        return (start ..< lines.count).first {
            BrandMigration.quotedKey(lines[$0])?.caseInsensitiveCompare(name) == .orderedSame
                && openBrace(lines, after: $0) == $0 + 1
        }
    }

    private static func openBrace(_ lines: [String], after line: Int) -> Int? {
        let next = line + 1
        guard next < lines.count, lines[next].trimmingCharacters(in: .whitespaces) == "{" else { return nil }
        return next
    }

    private static func closeBrace(_ lines: [String], open: Int) -> Int? {
        var depth = 0
        for index in open ..< lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "{" { depth += 1 }
            if trimmed == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func indent(_ line: String) -> Int {
        line.prefix { $0 == "\t" }.count
    }
}
