// One-time move of a NotProton (<= 2.x) install to the Bridgeplay 3.0.0 names.
//
// Every root is a parameter so tests run against temporary directories; live() builds the
// real ones. The steps are idempotent and recorded in a marker file inside the support
// directory, so a crash part way through resumes on the next launch. Nothing the user owns
// is deleted: directories are moved, Steam's config files are copied into a backup folder
// before they are edited, and anything that would overwrite an existing file is left alone
// and reported in Summary.notes.

import Darwin
import Foundation

struct BrandMigration: Sendable {

    // Where the old and new names live. Steam's userData is Application Support/Steam.
    let legacySupport: URL
    let support: URL
    let legacyCaches: URL
    let caches: URL
    let legacyHome: URL
    let home: URL
    let steamUserData: URL

    var steamRunning: @Sendable () -> Bool = { SteamBundle.isRunningForThisUser }
    var gameRunning: @Sendable () -> Bool = { Shell.processIsRunning(named: "wineserver") }

    static let markerName = ".migrated-3.0.0"
    static let backupFolder = "backups/migration-3.0.0"

    static func live() -> BrandMigration {
        BrandMigration(
            legacySupport: SupportPaths.legacyApplicationSupport,
            support: SupportPaths.support,
            legacyCaches: SupportPaths.legacyCaches,
            caches: SupportPaths.caches,
            legacyHome: SupportPaths.legacyHomeDir,
            home: SupportPaths.homeDir,
            steamUserData: SupportPaths.Steam.userData)
    }

    enum Blocker: Equatable, Sendable {
        case steamRunning
        case gameRunning
    }

    enum Failure: Error, Equatable {
        case blocked(Blocker)
    }

    enum Step: String, CaseIterable, Sendable {
        case backup, move, symlinks, supportFiles = "support-files", compatTools = "compat-tools"
        case compatMapping = "compat-mapping", launchOptions = "launch-options", runLogs = "run-logs", done
    }

    struct Summary: Equatable, Sendable {
        var toolsRenamed = 0
        var mappingsRewritten = 0
        var launchOptionsRewritten = 0
        var symlinksFixed = 0
        var logsRenamed = 0
        var logsLeft = 0
        var filesRewritten = 0
        var notes: [String] = []

        var description: String {
            "Moved NotProton data to Bridgeplay 3.0.0: \(toolsRenamed) compatibility tools renamed, "
                + "\(mappingsRewritten) Steam mappings and \(launchOptionsRewritten) launch options rewritten, "
                + "\(symlinksFixed) symlinks fixed, \(logsRenamed) logs renamed, \(filesRewritten) files rewritten."
                + (logsLeft == 0 ? "" : " \(logsLeft) logs could not be renamed.")
                + (notes.isEmpty ? "" : " " + notes.joined(separator: " "))
        }
    }

    // MARK: When to run

    // Cheap enough to call at every launch: a few stat calls and one small read.
    static func isNeeded(legacySupport: URL, support: URL) -> Bool {
        let legacyMarker = steps(at: legacySupport.appending(path: markerName))
        let marker = steps(at: support.appending(path: markerName))
        if marker?.contains(.done) == true || legacyMarker?.contains(.done) == true { return false }
        return exists(legacySupport) || marker != nil
    }

    var isNeeded: Bool { Self.isNeeded(legacySupport: legacySupport, support: support) }

    func canRun() -> Blocker? {
        if steamRunning() { return .steamRunning }
        if gameRunning() { return .gameRunning }
        return nil
    }

    // MARK: Running

    @discardableResult
    func run() throws -> Summary {
        var summary = Summary()
        guard isNeeded else { return summary }
        if let blocker = canRun() { throw Failure.blocked(blocker) }

        // Until the support directory moves, the marker lives in the legacy one and moves with it.
        var done = Set(Self.steps(at: support.appending(path: Self.markerName)) ?? [])
            .union(Self.steps(at: legacySupport.appending(path: Self.markerName)) ?? [])
        func record(_ step: Step) throws {
            done.insert(step)
            try writeMarker(done)
        }
        try writeMarker(done)

        if !done.contains(.backup) {
            try backUpSteamConfig()
            try record(.backup)
        }
        if !done.contains(.move) {
            try moveDirectories(&summary)
            try record(.move)
        }
        if !done.contains(.symlinks) {
            summary.symlinksFixed = try fixSymlinks()
            try record(.symlinks)
        }
        if !done.contains(.supportFiles) {
            try migrateSupportFiles(&summary)
            try record(.supportFiles)
        }
        if !done.contains(.compatTools) {
            try migrateCompatTools(&summary)
            try record(.compatTools)
        }
        if !done.contains(.compatMapping) {
            summary.mappingsRewritten = try rewriteFile(steamConfig) { Self.migratedCompatMapping($0) }
            try record(.compatMapping)
        }
        if !done.contains(.launchOptions) {
            for file in localConfigs() {
                summary.launchOptionsRewritten += try rewriteFile(file) { Self.migratedLaunchOptions($0) }
            }
            try record(.launchOptions)
        }
        if !done.contains(.runLogs) {
            renameRunLogs(&summary)
            try record(.runLogs)
        }
        try record(.done)
        return summary
    }

    // MARK: Marker

    private var markerHome: URL {
        Self.exists(support) || !Self.exists(legacySupport) ? support : legacySupport
    }

    private func writeMarker(_ steps: Set<Step>) throws {
        let directory = markerHome
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = Step.allCases.filter(steps.contains).map(\.rawValue).joined(separator: "\n") + "\n"
        try text.write(to: directory.appending(path: Self.markerName), atomically: true, encoding: .utf8)
        // A merge leaves the legacy marker behind; the one in markerHome now holds both.
        if directory == support {
            let stale = legacySupport.appending(path: Self.markerName)
            if Self.exists(stale) { try? FileManager.default.removeItem(at: stale) }
        }
    }

    private static func steps(at url: URL) -> [Step]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).compactMap { Step(rawValue: String($0)) }
    }

    // MARK: Step 1, backups

    private var steamConfig: URL { steamUserData.appending(path: "config/config.vdf") }

    private func localConfigs() -> [URL] { userConfigs(named: "localconfig.vdf") }

    private func userConfigs(named name: String) -> [URL] {
        let userdata = steamUserData.appending(path: "userdata")
        let users = (try? FileManager.default.contentsOfDirectory(atPath: userdata.path(percentEncoded: false))) ?? []
        return users.sorted().map { userdata.appending(path: "\($0)/config/\(name)") }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    // Copies go into whichever support directory exists now, so they move along in step 2.
    // A copy already there is the older one and is kept.
    private func backUpSteamConfig() throws {
        let files = FileManager.default
        let backups = markerHome.appending(path: Self.backupFolder)
        let root = steamUserData.path(percentEncoded: false)
        let sources = [steamConfig] + localConfigs() + userConfigs(named: "compat.vdf")
        for source in sources where files.fileExists(atPath: source.path(percentEncoded: false)) {
            let relative = String(source.path(percentEncoded: false).dropFirst(root.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let destination = backups.appending(path: relative)
            guard !Self.exists(destination) else { continue }
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: source, to: destination)
        }
    }

    // MARK: Step 2, moving directories

    private func moveDirectories(_ summary: inout Summary) throws {
        for (from, to) in [(legacySupport, support), (legacyCaches, caches), (legacyHome, home)] {
            try Self.merge(from, into: to, notes: &summary.notes)
        }
    }

    // Moves source to destination; when destination exists, moves in only what it lacks and
    // never overwrites. The source is removed only once empty.
    static func merge(_ source: URL, into destination: URL, notes: inout [String]) throws {
        let files = FileManager.default
        guard exists(source) else { return }
        guard exists(destination) else {
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.moveItem(at: source, to: destination)
            return
        }
        guard isDirectory(source), isDirectory(destination) else {
            if source.lastPathComponent == ".DS_Store" || source.lastPathComponent == markerName {
                try? files.removeItem(at: source)
            } else {
                notes.append("Kept \(source.path(percentEncoded: false)): \(destination.path(percentEncoded: false)) already exists.")
            }
            return
        }
        let children = (try? files.contentsOfDirectory(atPath: source.path(percentEncoded: false))) ?? []
        for child in children.sorted() {
            try merge(source.appending(path: child), into: destination.appending(path: child), notes: &notes)
        }
        Darwin.rmdir(source.path(percentEncoded: false))
    }

    // MARK: Step 3, symlinks

    // Absolute links into the old roots (launcher bundles link every Wine .so into runners/)
    // are repointed. Links are never followed, and links pointing elsewhere are left alone.
    private func fixSymlinks() throws -> Int {
        let root = support.path(percentEncoded: false)
        guard let walker = FileManager.default.enumerator(atPath: root) else { return 0 }
        var fixed = 0
        while let relative = walker.nextObject() as? String {
            let path = root + "/" + relative
            guard walker.fileAttributes?[.type] as? FileAttributeType == .typeSymbolicLink,
                  let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
                  target.hasPrefix("/"),
                  let moved = movedPath(target)
            else { continue }
            let temporary = path + ".bridgeplay-link"
            unlink(temporary)
            try FileManager.default.createSymbolicLink(atPath: temporary, withDestinationPath: moved)
            guard Darwin.rename(temporary, path) == 0 else {
                unlink(temporary)
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
            }
            fixed += 1
        }
        return fixed
    }

    // The same path under the new roots, or nil when it is under none of the old ones.
    func movedPath(_ path: String) -> String? {
        for (old, new) in [(legacySupport, support), (legacyCaches, caches), (legacyHome, home)] {
            let oldPath = old.path(percentEncoded: false).trimmingSuffix("/")
            if path == oldPath || path.hasPrefix(oldPath + "/") {
                return new.path(percentEncoded: false).trimmingSuffix("/") + path.dropFirst(oldPath.count)
            }
        }
        return nil
    }

    // MARK: Step 4, files inside the support directory

    static let logNames = [
        ("notproton-run.log", "bridgeplay-run.log"),
        ("notproton-wine.log", "bridgeplay-wine.log"),
        ("notproton.log", "bridgeplay.log"),
    ]

    private func migrateSupportFiles(_ summary: inout Summary) throws {
        let launchers = support.appending(path: "launchers")
        let launcherDirs = ((try? FileManager.default.contentsOfDirectory(
            atPath: launchers.path(percentEncoded: false))) ?? []).sorted().map { launchers.appending(path: $0) }
        for directory in [support] + launcherDirs {
            for (old, new) in Self.logNames {
                if try Self.renameIfFree(directory.appending(path: old), to: directory.appending(path: new)) {
                    summary.logsRenamed += 1
                }
            }
        }

        let tools = support.appending(path: "tools")
        if try rewriteFile(tools, { Self.migratedToolList($0) }) > 0 { summary.filesRewritten += 1 }

        // Launcher scripts carry absolute paths; Steam rewrites them on the next game launch,
        // but a launcher started from the Dock before that would point at the old directory.
        for file in Self.textFiles(under: launchers) {
            if try rewriteFile(file, { text in
                let result = rewrittenPaths(text)
                return (result, result == text ? 0 : 1)
            }) > 0 { summary.filesRewritten += 1 }
        }
    }

    static func migratedToolList(_ text: String) -> (String, Int) {
        var count = 0
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var fields = line.components(separatedBy: "\t")
            guard let name = fields.first, let moved = migratedToolName(name) else { return line }
            fields[0] = moved
            count += 1
            return fields.joined(separator: "\t")
        }
        return (lines.joined(separator: "\n"), count)
    }

    // MARK: Step 5, compatibilitytools.d

    private func migrateCompatTools(_ summary: inout Summary) throws {
        let directory = steamUserData.appending(path: "compatibilitytools.d")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in entries.sorted() {
            guard let moved = Self.migratedToolName(name) else { continue }
            let old = directory.appending(path: name)
            guard Self.isDirectory(old) else { continue }
            let new = directory.appending(path: moved)
            if Self.exists(new) {
                summary.notes.append("Kept compatibility tool \(name): \(moved) already exists.")
                continue
            }
            try FileManager.default.moveItem(at: old, to: new)
            summary.toolsRenamed += 1
        }
        // Rewriting is idempotent, so a crash between a rename and its rewrite is caught here.
        let current = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in current.sorted() where name == Self.newToolPrefix || name.hasPrefix(Self.newToolPrefix + "-") {
            let folder = directory.appending(path: name)
            guard Self.isDirectory(folder) else { continue }
            let oldName = "notproton" + name.dropFirst(Self.newToolPrefix.count)
            for file in Self.textFiles(under: folder) {
                if try rewriteFile(file, { text in
                    let result = rewrittenPaths(text)
                        .replacingOccurrences(of: "\"\(oldName)\"", with: "\"\(name)\"")
                    return (result, result == text ? 0 : 1)
                }) > 0 { summary.filesRewritten += 1 }
            }
        }
    }

    // Absolute old roots, the $HOME-relative spellings scripts use, and log names.
    func rewrittenPaths(_ text: String) -> String {
        var result = text
        for (old, new) in [(legacySupport, support), (legacyCaches, caches), (legacyHome, home)] {
            result = Self.replacingBounded(
                result, old.path(percentEncoded: false).trimmingSuffix("/"),
                new.path(percentEncoded: false).trimmingSuffix("/"))
        }
        result = Self.replacingBounded(result, "Library/Application Support/notproton", "Library/Application Support/bridgeplay")
        result = Self.replacingBounded(result, "Library/Caches/notproton", "Library/Caches/bridgeplay")
        result = Self.replacingBounded(result, "/.notproton", "/.bridgeplay")
        for (old, new) in Self.logNames {
            result = Self.replacingBounded(result, old, new)
        }
        return result
    }

    // MARK: Step 6, config.vdf

    // Rewrites "name" values naming one of our tools inside CompatToolMapping. Everything else,
    // whitespace and order included, stays byte for byte.
    static func migratedCompatMapping(_ text: String) -> (String, Int) {
        var lines = text.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { quotedKey($0)?.caseInsensitiveCompare("CompatToolMapping") == .orderedSame }),
              header + 1 < lines.count, lines[header + 1].trimmingCharacters(in: .whitespaces) == "{"
        else { return (text, 0) }
        var depth = 0
        var count = 0
        for index in header + 1 ..< lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "{" { depth += 1 }
            if trimmed == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            guard let (key, value, range) = keyValue(lines[index]),
                  key.caseInsensitiveCompare("name") == .orderedSame,
                  let moved = migratedToolName(value)
            else { continue }
            lines[index].replaceSubrange(range, with: moved)
            count += 1
        }
        return (lines.joined(separator: "\n"), count)
    }

    // MARK: Step 7, localconfig.vdf

    // Only LaunchOptions values change: the np-native path and NOTPROTON_ variables.
    static func migratedLaunchOptions(_ text: String) -> (String, Int) {
        var count = 0
        let lines = text.components(separatedBy: "\n").map { line -> String in
            guard let (key, value, range) = keyValue(line),
                  key.caseInsensitiveCompare("LaunchOptions") == .orderedSame
            else { return line }
            var moved = replacingBounded(value, "/.notproton", "/.bridgeplay")
            moved = replacingVariablePrefix(moved, "NOTPROTON_", "BRIDGEPLAY_")
            guard moved != value else { return line }
            count += 1
            var line = line
            line.replaceSubrange(range, with: moved)
            return line
        }
        return (lines.joined(separator: "\n"), count)
    }

    // MARK: Step 8, per-game run logs

    // Renames steamapps/compatdata/<appid>/notproton-run.log in every library Steam lists.
    // One directory listing per library and one stat per game; a library on a volume that
    // is not mounted is skipped. A log this account can't rename, in a library another user
    // owns, stays under the old name, where PrefixLog still finds it.
    private func renameRunLogs(_ summary: inout Summary) {
        for library in libraries() {
            let compatdata = library.appending(path: "steamapps/compatdata")
            let games = (try? FileManager.default.contentsOfDirectory(atPath: compatdata.path(percentEncoded: false))) ?? []
            for game in games.sorted() {
                let folder = compatdata.appending(path: game)
                do {
                    if try Self.renameIfFree(folder.appending(path: "notproton-run.log"),
                                             to: folder.appending(path: "bridgeplay-run.log")) {
                        summary.logsRenamed += 1
                    }
                } catch {
                    summary.logsLeft += 1
                }
            }
        }
    }

    // Library roots from steamapps/libraryfolders.vdf, always including Steam's own folder.
    func libraries() -> [URL] {
        let vdf = steamUserData.appending(path: "steamapps/libraryfolders.vdf")
        let text = (try? String(contentsOf: vdf, encoding: .utf8)) ?? ""
        let roots = [steamUserData] + PrefixStore.libraryPaths(in: text).map { URL(filePath: $0) }
        var seen: Set<String> = []
        return roots.filter { seen.insert($0.path(percentEncoded: false).trimmingSuffix("/")).inserted }
    }

    // MARK: Names

    // Steam maps Cloud save paths only for tool names containing "proton".
    static let newToolPrefix = "bridgeplay-proton"

    // notproton -> bridgeplay-proton, notproton-<x> -> bridgeplay-proton-<x>, and the
    // panel's "no tool" choice notproton.none -> bridgeplay-proton.none; nil when the tool
    // is not ours.
    static func migratedToolName(_ name: String) -> String? {
        guard name == "notproton" || name.hasPrefix("notproton-") || name.hasPrefix("notproton.") else { return nil }
        return newToolPrefix + name.dropFirst("notproton".count)
    }

    // MARK: Text helpers

    // A line holding only a quoted key, which is a section name.
    static func quotedKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\""),
              !trimmed.dropFirst().dropLast().contains("\"")
        else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    // `"key"<ws>"value"` on one line; value is the raw text between its quotes (escapes kept)
    // and range is where that text sits in the line.
    static func keyValue(_ line: String) -> (String, String, Range<String.Index>)? {
        var index = line.startIndex
        func skipSpace() {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
        }
        func quoted() -> Range<String.Index>? {
            guard index < line.endIndex, line[index] == "\"" else { return nil }
            let start = line.index(after: index)
            var cursor = start
            while cursor < line.endIndex {
                if line[cursor] == "\\" {
                    cursor = line.index(after: cursor)
                    if cursor < line.endIndex { cursor = line.index(after: cursor) }
                    continue
                }
                if line[cursor] == "\"" {
                    index = line.index(after: cursor)
                    return start ..< cursor
                }
                cursor = line.index(after: cursor)
            }
            return nil
        }
        skipSpace()
        guard let key = quoted() else { return nil }
        skipSpace()
        guard let value = quoted() else { return nil }
        return (String(line[key]), String(line[value]), value)
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
    }

    // Replaces old only where the next character cannot continue a name, so
    // ".notproton-msync" and "notproton-backends" survive "/.notproton" and "notproton".
    static func replacingBounded(_ text: String, _ old: String, _ new: String) -> String {
        guard !old.isEmpty, text.contains(old) else { return text }
        var result = ""
        var rest = text[...]
        while let found = rest.range(of: old) {
            let bounded = found.upperBound == rest.endIndex || !isNameCharacter(rest[found.upperBound])
            result += rest[..<found.lowerBound]
            result += bounded ? new : old
            rest = rest[found.upperBound...]
        }
        return result + rest
    }

    // Replaces a variable prefix only at the start of a word, so FOO_NOTPROTON_X is kept.
    static func replacingVariablePrefix(_ text: String, _ old: String, _ new: String) -> String {
        guard text.contains(old) else { return text }
        var result = ""
        var rest = text[...]
        while let found = rest.range(of: old) {
            let before = found.lowerBound == rest.startIndex ? result.last : rest[rest.index(before: found.lowerBound)]
            let atWordStart = before.map { !($0.isLetter || $0.isNumber || $0 == "_") } ?? true
            result += rest[..<found.lowerBound]
            result += atWordStart ? new : old
            rest = rest[found.upperBound...]
        }
        return result + rest
    }

    // MARK: File helpers

    static let textLimit = 1 << 20

    // Small UTF-8 files under a folder, skipping symlinks, backups and logs.
    static func textFiles(under folder: URL) -> [URL] {
        let root = folder.path(percentEncoded: false)
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var found: [URL] = []
        while let relative = walker.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            guard walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
                  let size = walker.fileAttributes?[.size] as? Int, size <= textLimit,
                  !name.contains(".bak"), !name.hasSuffix(".log"), name != ".DS_Store"
            else { continue }
            found.append(folder.appending(path: relative))
        }
        return found.sorted { $0.path < $1.path }
    }

    // Applies transform to a text file and writes it back atomically with its permissions,
    // only when it changed. Returns the transform's count; 0 for a missing or binary file.
    private func rewriteFile(_ file: URL, _ transform: (String) -> (String, Int)) throws -> Int {
        let path = file.path(percentEncoded: false)
        guard let data = FileManager.default.contents(atPath: path), data.count <= Self.textLimit,
              !data.contains(0), let text = String(data: data, encoding: .utf8)
        else { return 0 }
        let (result, count) = transform(text)
        guard result != text else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let temporary = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).bridgeplay")
        try Data(result.utf8).write(to: temporary)
        if let permissions = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path(percentEncoded: false))
        }
        guard Darwin.rename(temporary.path(percentEncoded: false), path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        return count
    }

    private static func renameIfFree(_ old: URL, to new: URL) throws -> Bool {
        guard exists(old), !exists(new) else { return false }
        try FileManager.default.moveItem(at: old, to: new)
        return true
    }

    // lstat-based, so a dangling symlink still counts.
    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.type]
            as? FileAttributeType == .typeDirectory
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}
