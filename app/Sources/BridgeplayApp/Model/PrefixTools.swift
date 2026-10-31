// Shortcuts to launch the Wine tools (winecfg/regedit/task manager) against
// a selected prefix, opens prefix directory in finder, etc.

import AppKit
import Foundation
import UniformTypeIdentifiers

enum WineTool: String, CaseIterable, Sendable {
    case winecfg
    case regedit
    case taskmgr

    var label: String {
        switch self {
        case .winecfg: String(localized: "Wine Configuration")
        case .regedit: String(localized: "Registry Editor")
        case .taskmgr: String(localized: "Task Manager")
        }
    }
}

// The logs compat_run.sh writes for a game.
enum PrefixLog: CaseIterable, Sendable {
    case launch
    case wine

    var label: String {
        switch self {
        case .launch: String(localized: "Launch Log")
        case .wine: String(localized: "Wine Log")
        }
    }

    // compat_run.sh writes bridgeplay-*.log; a prefix last run before 3.0 has notproton-*.log,
    // which is shown until the new one exists.
    func url(for prefix: WinePrefix, launchers: URL = SupportPaths.launchers) -> URL {
        let folder = switch self {
        case .launch: prefix.root
        case .wine: launchers.appending(path: prefix.appID)
        }
        let current = folder.appending(path: fileName)
        let legacy = folder.appending(path: legacyFileName)
        let files = FileManager.default
        if !files.fileExists(atPath: current.path(percentEncoded: false)),
           files.fileExists(atPath: legacy.path(percentEncoded: false)) {
            return legacy
        }
        return current
    }

    // Games print raw bytes into these logs, and one invalid UTF-8 byte must not cost the
    // whole file. nil only when it can't be read.
    static func text(of url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    var fileName: String {
        switch self {
        case .launch: "bridgeplay-run.log"
        case .wine: "bridgeplay-wine.log"
        }
    }

    var legacyFileName: String {
        switch self {
        case .launch: "notproton-run.log"
        case .wine: "notproton-wine.log"
        }
    }
}

// What compat_run.sh writes to notproton-build (a prefix marker, kept) when a tool first runs a prefix.
struct PrefixBuildRecord: Sendable, Equatable {
    let build: String
    let display: String?
}

enum PrefixTools {

    static let buildRecordName = "notproton-build"

    static func buildRecord(of prefix: WinePrefix) -> PrefixBuildRecord? {
        let file = prefix.root.appending(path: buildRecordName)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let build = lines.first, !build.isEmpty else { return nil }
        let display = lines.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 }
        return PrefixBuildRecord(build: build, display: display)
    }

    static func lastBuild(of prefix: WinePrefix, runners: URL = SupportPaths.runners) -> PrefixBuildRecord? {
        if let record = buildRecord(of: prefix) { return record }
        let file = prefix.pfx.appending(path: ".update-timestamp")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let field = text.split(whereSeparator: \.isWhitespace).first,
              let updated = Int(field)
        else { return nil }
        for build in RunnerStore.clonedBuilds(in: runners) {
            let inf = SupportPaths.clonedRoot(forBuild: build, runners: runners)
                .appending(path: "share/wine/wine.inf")
            let modified = (try? FileManager.default.attributesOfItem(
                atPath: inf.path(percentEncoded: false))[.modificationDate]) as? Date
            if let modified, Int(modified.timeIntervalSince1970) == updated {
                return PrefixBuildRecord(build: build, display: nil)
            }
        }
        return PrefixBuildRecord(build: "", display: String(localized: "another version of CrossOver"))
    }

    static func writeBuildRecord(_ tool: InstalledTool, for prefix: WinePrefix) throws {
        let file = prefix.root.appending(path: buildRecordName)
        try atomicReplace(file, with: Data("\(tool.build)\n\(tool.display)\n".utf8), step: String(localized: "Record prefix build"))
    }

    static func tool(
        for prefix: WinePrefix, among tools: [InstalledTool] = CompatToolList.installed(),
        runners: URL = SupportPaths.runners
    ) -> InstalledTool? {
        let arch = PrefixStore.arch(of: prefix)
        func byArch(_ candidates: [InstalledTool]) -> InstalledTool? {
            guard let arch else { return candidates.first }
            return candidates.first { $0.tool.prefixArch == arch }
        }
        guard let record = lastBuild(of: prefix, runners: runners) else { return byArch(tools) }
        let served = tools.filter { $0.build == record.build }
        if let named = served.first(where: { $0.display == record.display }),
           arch == nil || named.tool.prefixArch == arch {
            return named
        }
        // Any build of the prefix's arch can run it, see note_other_build in compat_run.sh.
        return byArch(served) ?? byArch(tools)
    }

    static func resolvedTool(
        step: String, for prefix: WinePrefix, among tools: [InstalledTool] = CompatToolList.installed()
    ) throws -> InstalledTool {
        if let found = tool(for: prefix, among: tools) { return found }
        if let record = lastBuild(of: prefix) {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(prefix.title) was last run by \(record.display ?? "build \(record.build)"), which is no longer set up. Rebuild the prefix first.")
            )
        }
        throw StepFailure(step: step, detail: String(localized: "No compatibility tool is set up."))
    }

    static func syncBackend(prefix: WinePrefix) -> String {
        let marker = prefix.root.appending(path: "notproton-msync")
        let recorded = try? String(contentsOf: marker, encoding: .utf8)
        return recorded?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" ? "1" : "0"
    }

    static func environment(
        prefix: WinePrefix, runner: URL, flavor: CompatTool.Flavor = .fex
    ) -> [String: String] {
        let root = runner.path(percentEncoded: false)
        var environment = ProcessInfo.processInfo.environment
        environment["CX_ROOT"] = root
        environment["CX_HOME"] = SupportPaths.applicationSupport
            .appending(path: "CrossOver").path(percentEncoded: false)
        let wine = layout(runner: runner, flavor: flavor)
        environment["WINELOADER"] = wine.loader.path(percentEncoded: false)
        environment["WINESERVER"] = wine.server.path(percentEncoded: false)
        environment["WINEDLLPATH"] = "\(root)/lib/wine/x86_64-windows:"
            + wine.unixDir.path(percentEncoded: false)
        environment["WINEPREFIX"] = prefix.pfx.path(percentEncoded: false)
        environment["WINEMSYNC"] = syncBackend(prefix: prefix)
        environment["PATH"] = "\(root)/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        return environment
    }

    static func loader(runner: URL, flavor: CompatTool.Flavor = .fex) -> URL {
        layout(runner: runner, flavor: flavor).loader
    }

    struct WineLayout {
        let loader: URL
        let server: URL
        let unixDir: URL
    }

    static func layout(runner: URL, flavor: CompatTool.Flavor = .fex) -> WineLayout {
        let fm = FileManager.default
        let bin = runner.appending(path: "bin")
        func executable(_ url: URL) -> Bool {
            fm.isExecutableFile(atPath: url.path(percentEncoded: false))
        }

        let arm = runner.appending(path: "lib/wine/aarch64-unix")
        let armLoader = arm.appending(path: "wine.app/Contents/MacOS/wine")
        let armServer = bin.appending(path: "wineserver-arm64")
        if flavor == .fex, executable(armLoader), executable(armServer) {
            return WineLayout(loader: armLoader, server: armServer, unixDir: arm)
        }

        let unix = runner.appending(path: "lib/wine/x86_64-unix")
        let server = bin.appending(path: "wineserver")
        return WineLayout(
            loader: unix.appending(path: "wine"),
            server: executable(server) ? server : bin.appending(path: "wineserver-x86"),
            unixDir: unix
        )
    }

    private static func readyLoader(
        step: String, prefix: WinePrefix, runner: URL, flavor: CompatTool.Flavor
    ) throws -> URL {
        let loader = loader(runner: runner, flavor: flavor)
        guard FileManager.default.isExecutableFile(atPath: loader.path(percentEncoded: false)) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "No compatibility tool at \(loader.path(percentEncoded: false)). Use Set Up Compatibility Tool first.")
            )
        }
        guard FileManager.default.fileExists(atPath: prefix.pfx.path(percentEncoded: false)) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(prefix.title) has no prefix at \(prefix.pfx.path(percentEncoded: false)).")
            )
        }
        return loader
    }

    static func launch(_ tool: WineTool, in prefix: WinePrefix) throws {
        let chosen = try resolvedTool(step: String(localized: "Open \(tool.label)"), for: prefix)
        try launch(
            tool, in: prefix, runner: SupportPaths.clonedRoot(forBuild: chosen.build),
            flavor: chosen.tool.flavor
        )
    }

    static func launch(
        _ tool: WineTool, in prefix: WinePrefix, runner: URL, flavor: CompatTool.Flavor = .fex
    ) throws {
        let loader = try readyLoader(
            step: String(localized: "Open \(tool.label)"), prefix: prefix, runner: runner, flavor: flavor
        )
        try Shell.detach(
            loader.path(percentEncoded: false),
            [tool.rawValue],
            environment: environment(prefix: prefix, runner: runner, flavor: flavor)
        )
    }

    static func run(_ executable: URL, in prefix: WinePrefix) throws {
        let chosen = try resolvedTool(step: String(localized: "Run \(executable.lastPathComponent)"), for: prefix)
        try run(
            executable, in: prefix, runner: SupportPaths.clonedRoot(forBuild: chosen.build),
            flavor: chosen.tool.flavor
        )
    }

    static func run(
        _ executable: URL,
        in prefix: WinePrefix,
        runner: URL,
        flavor: CompatTool.Flavor = .fex
    ) throws {
        let step = String(localized: "Run \(executable.lastPathComponent)")
        let loader = try readyLoader(step: step, prefix: prefix, runner: runner, flavor: flavor)
        guard FileManager.default.fileExists(atPath: executable.path(percentEncoded: false)) else {
            throw StepFailure(step: step, detail: String(localized: "No file at \(executable.path(percentEncoded: false))."))
        }
        guard let arguments = arguments(for: executable) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(executable.lastPathComponent) is not a Windows program. Pick an exe, msi, bat or cmd file.")
            )
        }

        try Shell.detach(
            loader.path(percentEncoded: false),
            arguments,
            environment: environment(prefix: prefix, runner: runner, flavor: flavor),
            currentDirectory: executable.deletingLastPathComponent()
        )
    }

    // Winetricks is LGPL, so it is downloaded rather than shipped.
    static let winetricksRelease = "20260125"
    static let winetricksSHA256 = "431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b"
    static let winetricksLogName = "winetricks.log"

    // Wine truncates vc_redist's 1638 (newer runtime installed) to 102; Winetricks only accepts 236
    static let winetricksWine = #"""
        #!/bin/sh
        "$BRIDGEPLAY_WINE" "$@"
        status=$?
        case "$status:${1##*[\\/]}" in
          102:[Vv][Cc]*[Rr][Ee][Dd][Ii][Ss][Tt]*.[Ee][Xx][Ee]) exit 236 ;;
        esac
        exit "$status"

        """#

    static func winetricksVerbs(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func winetricks(_ verbs: [String], in prefix: WinePrefix) async throws -> URL {
        let step = String(localized: "Run Winetricks")
        let chosen = try resolvedTool(step: step, for: prefix)
        let script = try await PinnedDownload.obtain(
            file: "winetricks",
            sha256: winetricksSHA256,
            bases: [URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/\(winetricksRelease)/src")!],
            into: SupportPaths.winetricksDownloads,
            step: step,
            from: "GitHub"
        )
        return try winetricks(
            verbs, in: prefix, script: script,
            runner: SupportPaths.clonedRoot(forBuild: chosen.build), flavor: chosen.tool.flavor,
            sha256: winetricksSHA256
        )
    }

    // sha256: the pin the script must still match when it runs. The cached copy is the
    // user's to write, so it is read once, checked, and the checked bytes are what runs.
    static func winetricks(
        _ verbs: [String], in prefix: WinePrefix, script: URL, runner: URL,
        flavor: CompatTool.Flavor = .fex, sha256: String? = nil
    ) throws -> URL {
        let step = String(localized: "Run Winetricks")
        guard !verbs.isEmpty else {
            throw StepFailure(step: step, detail: String(localized: "Enter at least one verb, like vcrun2022."))
        }
        // Under -q annihilate wipes the prefix and its saves without asking, prefix= switches to
        // another prefix, and options like --self-update change winetricks itself.
        if let refused = verbs.first(where: { $0 == "annihilate" || $0.hasPrefix("prefix=") || $0.hasPrefix("-") }) {
            throw StepFailure(step: step, detail: String(localized: "Bridgeplay does not run \(refused) with Winetricks."))
        }
        guard let claim = PrefixStore.claim(prefix) else {
            throw StepFailure(step: step, detail: String(localized: "\(prefix.title) is running. Quit the game first."))
        }
        defer { claim.release() }
        let loader = try readyLoader(step: step, prefix: prefix, runner: runner, flavor: flavor)
        let wrapper = script.deletingLastPathComponent().appending(path: "bridgeplay-wine")
        do {
            try Data(winetricksWine.utf8).write(to: wrapper, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path(percentEncoded: false))
        } catch {
            throw StepFailure(step: step, detail: error.localizedDescription)
        }

        // cabextract comes from the runner's bin, which environment() puts on PATH.
        var environment = environment(prefix: prefix, runner: runner, flavor: flavor)
        environment["WINE"] = wrapper.path(percentEncoded: false)
        environment["BRIDGEPLAY_WINE"] = loader.path(percentEncoded: false)
        // Winetricks reads the architecture from WINE_BIN, which would otherwise be the wrapper.
        environment["WINE_BIN"] = loader.path(percentEncoded: false)

        let checked = try sha256.map { try verifiedCopy(of: script, sha256: $0, step: step) }
        defer { if let checked { try? FileManager.default.removeItem(at: checked.deletingLastPathComponent()) } }

        let log = prefix.root.appending(path: winetricksLogName)
        let status = try Shell.logged(
            "/bin/sh", [(checked ?? script).path(percentEncoded: false), "-q"] + verbs,
            environment: environment, to: log
        )
        // Until the wineserver exits, the prefix still counts as in use.
        _ = try? Shell.run(layout(runner: runner, flavor: flavor).server.path(percentEncoded: false), ["-w"], environment: environment)
        guard status == 0 else {
            throw StepFailure(
                step: step,
                detail: String(localized: "Winetricks stopped with status \(status). Its output is in \(log.path(percentEncoded: false)).")
            )
        }
        return log
    }

    // Reads the script once, checks those bytes against the pin and writes them to a new
    // private folder, so what runs is what was checked.
    static func verifiedCopy(of script: URL, sha256: String, step: String) throws -> URL {
        let data: Data
        do {
            data = try Data(contentsOf: script)
        } catch {
            throw StepFailure(step: step, detail: error.localizedDescription)
        }
        guard Digest.sha256(of: data) == sha256 else {
            AppLog.note("winetricks: \(script.path(percentEncoded: false)) no longer matches its pin")
            try? FileManager.default.removeItem(at: script)
            throw StepFailure(step: step, detail: String(localized: "The downloaded Winetricks changed after it was checked, so it was not run. Try again to download it afresh."))
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "bridgeplay-winetricks-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let copy = folder.appending(path: "winetricks")
            try data.write(to: copy, options: .withoutOverwriting)
            return copy
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw StepFailure(step: step, detail: error.localizedDescription)
        }
    }

    static func arguments(for executable: URL) -> [String]? {
        let path = executable.path(percentEncoded: false)
        switch executable.pathExtension.lowercased() {
        case "exe", "bat", "cmd": return [path]
        case "msi": return ["msiexec", "/i", path]
        default: return nil
        }
    }

    static var runnableTypes: [UTType] {
        ["exe", "msi", "bat", "cmd"].compactMap { UTType(filenameExtension: $0) }
    }

    static func reveal(_ prefix: WinePrefix) {
        NSWorkspace.shared.selectFile(
            prefix.pfx.path(percentEncoded: false),
            inFileViewerRootedAtPath: prefix.root.path(percentEncoded: false)
        )
    }

    static func hasLog(_ log: PrefixLog, for prefix: WinePrefix) -> Bool {
        FileManager.default.fileExists(atPath: log.url(for: prefix).path(percentEncoded: false))
    }

    static func open(_ log: PrefixLog, for prefix: WinePrefix) {
        NSWorkspace.shared.open(log.url(for: prefix))
    }

    static func reveal(at url: URL) {
        NSWorkspace.shared.selectFile(
            url.path(percentEncoded: false),
            inFileViewerRootedAtPath: url.deletingLastPathComponent().path(percentEncoded: false)
        )
    }

    static func deleteBackup(_ backup: URL) throws {
        try WriteRefused.catching(backup.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: backup)
        }
    }

    static func delete(_ prefix: WinePrefix) throws {
        guard let claim = PrefixStore.claim(prefix) else {
            throw StepFailure(
                step: String(localized: "Delete prefix"),
                detail: String(localized: "\(prefix.title) is running. Quit the game first.")
            )
        }
        defer { claim.release() }
        try WriteRefused.catching(prefix.root) {
            try FileManager.default.removeItem(at: prefix.root)
        }
    }
}
