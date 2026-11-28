// Shortcuts to launch the Wine tools (winecfg/regedit/task manager) against
// a selected prefix, opens prefix directory in finder, etc.

import AppKit
import Foundation
import UniformTypeIdentifiers

enum WineTool: String, CaseIterable, Sendable {
    case winecfg
    case regedit
    case taskmgr
    case joystick

    var label: String {
        switch self {
        case .winecfg: String(localized: "Wine Configuration")
        case .regedit: String(localized: "Registry Editor")
        case .taskmgr: String(localized: "Task Manager")
        case .joystick: String(localized: "Game Controllers")
        }
    }

    // What the loader runs. Game Controllers is Wine's joy.cpl, which lists the pads the
    // game would see and tests their buttons, axes and rumble.
    var arguments: [String] {
        switch self {
        case .joystick: ["control", "joy.cpl"]
        default: [rawValue]
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
            tool.arguments,
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
    // cabextract 1.12 (GPL-2.0-or-later, NOTICE), built by scripts/build-cabextract.sh.
    static let cabextractSHA256 = "8c8f3b80ce8998b952df3638abcacd44161793646376fa549d9f33ab8aeea171"

    // Copies the bundled cabextract into its own folder next to the wrapper and returns that
    // folder, or nil when this build carries none (the runner's own stays on PATH).
    static func stagedCabextract(
        beside wrapper: URL, step: String,
        source: URL? = Bundle.module.url(forResource: "cabextract", withExtension: nil)
    ) throws -> URL? {
        guard let source else { return nil }
        let dir = wrapper.deletingLastPathComponent().appending(path: "bin")
        let staged = dir.appending(path: "cabextract")
        let files = FileManager.default
        // A copy of an app unzipped from a browser download carries quarantine, and macOS then
        // stops an ad hoc cabextract at exec, so a quarantined copy is replaced too.
        let quarantine = "com.apple.quarantine"
        if files.isExecutableFile(atPath: staged.path(percentEncoded: false)),
           getxattr(staged.path(percentEncoded: false), quarantine, nil, 0, 0, 0) < 0,
           SignedPin.matches(staged, sha256: cabextractSHA256) {
            return dir
        }
        // Two prefixes can run Winetricks at once, so a checked temp copy is renamed into place.
        let temp = dir.appending(path: "cabextract.\(UUID().uuidString)")
        defer { try? files.removeItem(at: temp) }
        do {
            try files.createDirectory(at: dir, withIntermediateDirectories: true)
            try files.copyItem(at: source, to: temp)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path(percentEncoded: false))
        } catch {
            throw StepFailure(step: step, detail: error.localizedDescription)
        }
        if removexattr(temp.path(percentEncoded: false), quarantine, XATTR_NOFOLLOW) != 0, errno != ENOATTR, errno != ENOTSUP {
            throw StepFailure(step: step, detail: String(cString: strerror(errno)))
        }
        guard SignedPin.matches(temp, sha256: cabextractSHA256) else {
            throw StepFailure(step: step, detail: String(localized: "The bundled cabextract does not match its pin. Reinstall Bridgeplay."))
        }
        guard rename(temp.path(percentEncoded: false), staged.path(percentEncoded: false)) == 0 else {
            throw StepFailure(step: step, detail: String(cString: strerror(errno)))
        }
        return dir
    }

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

        // Most verbs unpack cabinets, and only CrossOver's own runners ship cabextract in bin,
        // so the bundled one goes first on PATH.
        var environment = environment(prefix: prefix, runner: runner, flavor: flavor)
        if let tools = try stagedCabextract(beside: wrapper, step: step) {
            environment["PATH"] = tools.path(percentEncoded: false) + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        }
        environment["WINE"] = wrapper.path(percentEncoded: false)
        environment["BRIDGEPLAY_WINE"] = loader.path(percentEncoded: false)
        // Winetricks reads the architecture from WINE_BIN, which would otherwise be the wrapper.
        environment["WINE_BIN"] = loader.path(percentEncoded: false)

        let checked = try sha256.map { try verifiedCopy(of: script, sha256: $0, step: step) }
        defer { if let checked { try? FileManager.default.removeItem(at: checked.deletingLastPathComponent()) } }

        let fontLinks = try setAsideFontLinks(in: prefix, step: step)
        defer { restoreFontLinks(fontLinks) }

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

    // The launcher links the prefix's Fonts to Bridgeplay's shared fonts and the engine's
    // (link_fonts), and Winetricks installs fonts with cp -f, which writes through a link into
    // every prefix's copy. So those links are moved out while it runs; any name Winetricks did
    // not fill gets its link back, and the next launch links the rest as before. Other links
    // stay, so a crash mid-run loses none the launcher can't make again.
    static func setAsideFontLinks(in prefix: WinePrefix, step: String) throws -> [(link: String, target: String)] {
        let fonts = prefix.pfx.appending(path: "drive_c/windows/Fonts").path(percentEncoded: false)
        func real(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        // A Fonts folder that is a link (into another prefix, which isn't claimed, or anywhere
        // else) would take Winetricks' fonts and cp -f through its links, so it doesn't run.
        // Only Wine's part of the path may differ in case, and only on a volume that ignores case.
        let refused = StepFailure(
            step: step,
            detail: String(localized: "The Fonts folder in \(prefix.title) is a link to another folder, so Bridgeplay didn't run Winetricks. Replace the link with a regular Fonts folder, then try again.")
        )
        guard let root = real(prefix.pfx.path(percentEncoded: false)) else { return [] }
        guard let resolved = real(fonts) else {
            // Nothing there: Winetricks makes the folder. A dangling link: it would follow it.
            var info = stat()
            if lstat(fonts, &info) == 0 { throw refused }
            return []
        }
        guard resolved.hasPrefix(root + "/"),
              resolved.dropFirst(root.count + 1).lowercased() == "drive_c/windows/fonts" else { throw refused }
        let files = FileManager.default
        // The folder is there (realpath found it), so a listing that fails leaves its links unguarded.
        let names: [String]
        do {
            names = try files.contentsOfDirectory(atPath: fonts)
        } catch {
            throw StepFailure(step: step, detail: error.localizedDescription)
        }
        var moved: [(link: String, target: String)] = []
        for name in names {
            let link = fonts + "/" + name
            guard let target = try? files.destinationOfSymbolicLink(atPath: link), isSharedFont(target) else { continue }
            guard unlink(link) == 0 else {
                let detail = String(cString: strerror(errno))
                restoreFontLinks(moved, anyCase: false)
                throw StepFailure(step: step, detail: detail)
            }
            moved.append((link, target))
        }
        return moved
    }

    // The folders link_fonts links from: Bridgeplay's fonts and their alt/ (the legacy notproton
    // ones too, which older launches linked), and an engine's.
    static func isSharedFont(_ target: String) -> Bool {
        let folder = (target as NSString).deletingLastPathComponent
        let shared = [SupportPaths.support, SupportPaths.legacyApplicationSupport].map {
            $0.appending(path: "fonts").path(percentEncoded: false)
        }
        return shared.contains { folder == $0 || folder == $0 + "/alt" } || folder.hasSuffix("/share/wine/fonts")
    }

    // anyCase: false puts back exactly what was moved, for a set-aside that stopped halfway.
    static func restoreFontLinks(_ links: [(link: String, target: String)], anyCase: Bool = true) {
        guard let first = links.first else { return }
        let fonts = (first.link as NSString).deletingLastPathComponent
        // A dangling link holds no name, as in link_fonts.
        let present = anyCase ? ((try? FileManager.default.contentsOfDirectory(atPath: fonts)) ?? [])
            .filter { FileManager.default.fileExists(atPath: fonts + "/" + $0) } : []
        for (link, target) in fontLinksToRestore(links, present: present) where symlink(target, link) != 0 {
            AppLog.note("winetricks: could not link \(link) back to \(target): \(String(cString: strerror(errno)))")
        }
    }

    // Windows finds fonts by name in any case, so a font installed as Arial.TTF on a
    // case-sensitive volume takes the place of the arial.ttf link too.
    static func fontLinksToRestore(
        _ links: [(link: String, target: String)], present: [String]
    ) -> [(link: String, target: String)] {
        let taken = Set(present.map { $0.lowercased() })
        return links.filter { !taken.contains(($0.link as NSString).lastPathComponent.lowercased()) }
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

    // The run log holds every launch, oldest first, so it opens at a run long gone. This copies
    // the last run into its own file (replaced each time) and opens that; the full log when
    // the log has no run header.
    static func openLastRun(for prefix: WinePrefix) {
        NSWorkspace.shared.open(lastRunFile(for: prefix) ?? PrefixLog.launch.url(for: prefix))
    }

    static func lastRunFile(for prefix: WinePrefix,
                            folder: URL = URL.temporaryDirectory.appending(path: "Bridgeplay Last Run")) -> URL? {
        guard let text = PrefixLog.text(of: PrefixLog.launch.url(for: prefix)),
              let block = LastLaunch.lastRun(in: text) else { return nil }
        let file = folder.appending(path: "\(prefix.appID)-last-run.log")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(block.utf8).write(to: file, options: .atomic)
        } catch {
            AppLog.note("last run: \(file.path(percentEncoded: false)) not written: \(error)")
            return nil
        }
        return file
    }

    static func reveal(at url: URL) {
        NSWorkspace.shared.selectFile(
            url.path(percentEncoded: false),
            inFileViewerRootedAtPath: url.deletingLastPathComponent().path(percentEncoded: false)
        )
    }

    typealias Trash = @Sendable (URL) throws -> Void

    // The Trash is per volume, so this is a rename on the drive the game data is on.
    static let systemTrash: Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    static func moveToTrash(_ url: URL, trash: Trash) throws {
        let path = url.path(percentEncoded: false)
        do {
            try trash(url)
        } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
            throw WriteRefused(path: path, errno: WriteRefused.posixCode(of: error))
        } catch {
            AppLog.note("trash: \(path) not moved: \(error)")
            // Gone since it was listed (a drive unplugged, a folder removed): that failure, not
            // a drive without a Trash, so no permanent delete is offered for it.
            if (try? FileManager.default.attributesOfItem(atPath: path)) == nil { throw error }
            // Only a drive without a Trash is offered a permanent delete; any other failure
            // is reported as itself.
            guard trashIsMissing(error, for: url) else { throw error }
            throw TrashUnavailable(url: url)
        }
    }

    // trashItem says "not supported" on a volume without a Trash, and such a volume has no
    // Trash folder to name.
    static func trashIsMissing(_ error: Error, for url: URL) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFeatureUnsupportedError { return true }
        return (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                             appropriateFor: url, create: false)) == nil
    }

    static func deleteBackup(_ backup: URL, trash: Trash = systemTrash) throws {
        try moveToTrash(backup, trash: trash)
    }

    // Only after the user chose Delete Permanently for a drive without a Trash.
    static func deleteBackupPermanently(_ backup: URL) throws {
        try WriteRefused.catching(backup.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: backup)
        }
    }

    static func delete(_ prefix: WinePrefix, trash: Trash = systemTrash) throws {
        let claim = try claimForDelete(prefix)
        defer { claim.release() }
        try moveToTrash(prefix.root, trash: trash)
    }

    // Only after the user chose Delete Permanently for a drive without a Trash.
    static func deletePermanently(_ prefix: WinePrefix) throws {
        let claim = try claimForDelete(prefix)
        defer { claim.release() }
        try WriteRefused.catching(prefix.root.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: prefix.root)
        }
    }

    private static func claimForDelete(_ prefix: WinePrefix) throws -> PrefixClaim {
        guard let claim = PrefixStore.claim(prefix) else {
            throw StepFailure(
                step: String(localized: "Delete prefix"),
                detail: String(localized: "\(prefix.title) is running. Quit the game first.")
            )
        }
        return claim
    }

    // Swaps a backup in: the current pfx becomes a new backup, then the chosen one is renamed
    // to pfx. Both are renames inside the game's folder, so nothing is copied or overwritten.
    // Returns the backup now holding the data that was current, nil when there was none.
    @discardableResult
    static func restore(
        _ backup: PrefixBackup, now: Date = .now,
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws -> URL? {
        let prefix = backup.prefix
        let step = String(localized: "Restore backup")
        let fm = FileManager.default
        // plainPath: a parent from deletingLastPathComponent ends in a slash, a library root doesn't.
        let folder = backup.url.deletingLastPathComponent().standardizedFileURL.plainPath
        guard folder == prefix.root.standardizedFileURL.plainPath,
              backup.url.lastPathComponent.hasPrefix(PrefixStore.backupPrefix)
        else {
            throw StepFailure(step: step, detail: String(localized: "This backup is not in the folder of \(prefix.title)."))
        }
        guard let claim = PrefixStore.claim(prefix) else {
            throw StepFailure(step: step, detail: String(localized: "\(prefix.title) is running. Quit the game first."))
        }
        defer { claim.release() }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: backup.url.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw StepFailure(step: step, detail: String(localized: "The backup is no longer there."))
        }

        // attributesOfItem doesn't follow a final link, so a dangling pfx link still counts.
        let current = (try? fm.attributesOfItem(atPath: prefix.pfx.path(percentEncoded: false))) != nil
        let kept = current ? backupSlot(in: prefix.root, at: now) : nil
        try WriteRefused.catching(prefix.root.path(percentEncoded: false)) {
            if let kept { try move(prefix.pfx, kept) }
            do {
                try move(backup.url, prefix.pfx)
            } catch {
                if let kept {
                    do {
                        try move(kept, prefix.pfx)
                    } catch let undo {
                        AppLog.note("restore \(prefix.appID): current data left at \(kept.path(percentEncoded: false)): \(undo)")
                    }
                }
                throw error
            }
        }
        // The build record names whoever ran the data that is now a backup. Without it the
        // next launch reads the restored prefix's own .update-timestamp, as for an old prefix.
        try? fm.removeItem(at: prefix.root.appending(path: buildRecordName))
        try? fm.removeItem(at: prefix.root.appending(path: "notproton-switch"))
        return kept
    }
}

// A move to the Trash failed and nothing was deleted, most often because the drive has no
// Trash (some network and non-Apple volumes).
struct TrashUnavailable: LocalizedError {
    let url: URL

    var errorDescription: String? {
        String(localized: "\(url.lastPathComponent) could not be moved to the Trash. Nothing was deleted.")
    }
}
