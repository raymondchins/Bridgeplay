import Foundation

@main
enum Launch {
    static func main() {
        // A game launch is waiting on this one: post and leave before anything else runs.
        if let parts = NotifyCommand.requested() { NotifyCommand.run(parts) }
        if CommandLine.arguments.dropFirst().first == LaunchProgressCommand.flag {
            LaunchProgressCommand.run(Array(CommandLine.arguments.dropFirst(2)))
        }
        let rebuilding = CommandLine.arguments.dropFirst().first == RebuildPrefixCommand.flag
        // Out of the launching process group, so stopping the game in Steam cannot take
        // the rebuild with it.
        if rebuilding { _ = setsid() }
        // Before anything opens the support folder: the 3.0.0 move needs the old one intact.
        MainActor.assumeIsolated { MigrationLaunch.shared.runAtLaunch() }
        #if DEBUG
        if CommandLine.arguments.dropFirst().contains(SetupPreviewApp.flag) {
            SetupPreviewApp.main()
            return
        }
        #endif
        // The command line paths log as well, so a scripted run leaves the same trail.
        AppLog.start()
        MainActor.assumeIsolated { MigrationLaunch.shared.logLaunchResult() }
        if rebuilding {
            AppLog.note("command line: \(RebuildPrefixCommand.flag)")
            refuseWhileMigrating()
            let arguments = Array(CommandLine.arguments.dropFirst(2))
            if RebuildProgressCommand.requested { RebuildProgressCommand.run(arguments) }
            do {
                try RebuildPrefixCommand.run(arguments)
                exit(AppLog.finished(0))
            } catch {
                AppLog.note("rebuild prefix failed: \(error.localizedDescription)")
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(AppLog.finished(1))
            }
        }
        if CommandLine.arguments.dropFirst().contains(RemoveEverythingCommand.flag) {
            AppLog.note("command line: \(RemoveEverythingCommand.flag)")
            RemoveEverythingCommand.run()
        }
        if CommandLine.arguments.dropFirst().contains(InstallIntoSteamCommand.flag) {
            AppLog.note("command line: \(InstallIntoSteamCommand.flag)")
            refuseWhileMigrating()
            InstallIntoSteamCommand.run()
        }
        if CommandLine.arguments.dropFirst().contains(SetupWinecxCommand.flag) {
            AppLog.note("command line: \(SetupWinecxCommand.flag)")
            refuseWhileMigrating()
            SetupWinecxCommand.run()
        }
        BridgeplayApp.main()
    }

    // The installs write the new support folder, which the pending 3.0 move must find as
    // it left it, so they wait for it like the app's own buttons do.
    private static func refuseWhileMigrating() {
        guard let refusal = MainActor.assumeIsolated({ MigrationLaunch.shared.refusal }) else { return }
        AppLog.note("command line refused: the 3.0 folder move is pending")
        FileHandle.standardError.write(Data("\(refusal)\n".utf8))
        exit(AppLog.finished(1))
    }
}

enum RebuildPrefixCommand {
    static let flag = "--rebuild-prefix"
    static let executableRecord = "app-executable"

    struct Request {
        let prefix: WinePrefix
        let tool: InstalledTool
        let keepBackup: Bool
    }

    static func request(_ arguments: [String], tools: [InstalledTool]) throws -> Request {
        func refused(_ detail: String) -> StepFailure {
            StepFailure(step: "Rebuild prefix", detail: detail)
        }
        guard arguments.count == 5,
            ["keep-backup", "discard-backup"].contains(arguments[4]),
            arguments[0].hasPrefix("/")
        else { throw refused("Invalid rebuild arguments.") }
        let root = URL(filePath: arguments[0]).standardizedFileURL
        let appID = root.lastPathComponent
        let compatdata = root.deletingLastPathComponent()
        let steamapps = compatdata.deletingLastPathComponent()
        guard !appID.isEmpty, appID.utf8.allSatisfy({ (48...57).contains($0) }),
            compatdata.lastPathComponent == "compatdata", steamapps.lastPathComponent == "steamapps",
            FileManager.default.fileExists(atPath: root.appending(path: "pfx").path(percentEncoded: false))
        else { throw refused("The game prefix could not be found under steamapps/compatdata.") }
        guard let tool = tools.first(where: {
            $0.name == arguments[1] && $0.build == arguments[2] && $0.tool.flavor.rawValue == arguments[3]
        }) else { throw refused("The selected compatibility tool is unavailable. Set it up in Bridgeplay first.") }
        let library = SteamLibrary(root: steamapps.deletingLastPathComponent())
        return Request(
            prefix: WinePrefix(appID: appID, name: PrefixStore.appName(appID: appID, in: library),
                               library: library, lastUsed: nil),
            tool: tool, keepBackup: arguments[4] == "keep-backup"
        )
    }

    // Phase, then this process's pid. The dylib reads it for the Compatibility page and takes
    // a pid that is gone as a rebuild that died. The notproton-* names are shared with the
    // dylib and the run script.
    static let statusName = "notproton-rebuild"
    static let rebuildLockName = ".notproton-rebuild.lock"

    static func run(
        _ arguments: [String], tools: () -> [InstalledTool] = { CompatToolList.installed() },
        observe: (String?, RebuildPhase) -> Void = { _, _ in }
    ) throws {
        let name = try request(arguments, tools: tools()).prefix.name
        let status = arguments.first.flatMap(statusFile)
        // One rebuild per prefix. A second one exits before it can overwrite the first one's
        // progress with a failure that is not the first one's.
        let held = try status.map { try claimRebuild(beside: $0) } ?? -1
        defer { if held >= 0 { FileLock.release(held) } }
        func report(_ phase: String) {
            guard let status else { return }
            try? atomicReplace(status, with: Data("\(phase)\n\(getpid())\n".utf8), step: "Record rebuild progress")
        }
        report(RebuildPhase.settingUp.rawValue)
        observe(name, .settingUp)
        do {
            // Another game's rebuild or an install holds this. Waiting keeps the page on
            // "Rebuilding prefix" rather than failing a rebuild that only had to queue.
            let lock = try DeploymentContent.acquireInstallationLock(waiting: true)
            defer { lock.release() }
            let request = try request(arguments, tools: tools())
            let kept = try PrefixTools.recreate(
                request.prefix, as: request.tool, keepBackup: request.keepBackup,
                progress: { report($0.rawValue); observe(name, $0) })
            report(kept != nil ? "done-backup" : "done")
        } catch {
            report("failed")
            throw error
        }
    }

    static func claimRebuild(beside status: URL) throws -> Int32 {
        let path = status.deletingLastPathComponent().appending(path: rebuildLockName)
        let fd = open(path.path(percentEncoded: false), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var claimed = fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while fd >= 0 && !claimed && errno == EWOULDBLOCK && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            claimed = flock(fd, LOCK_EX | LOCK_NB) == 0
        }
        guard claimed else {
            if fd >= 0 { close(fd) }
            throw StepFailure(step: "Rebuild prefix", detail: "Another rebuild of this prefix is running.")
        }
        return fd
    }

    static func statusFile(_ path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let root = URL(filePath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard root.deletingLastPathComponent().lastPathComponent == "compatdata",
            root.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "steamapps",
            !root.lastPathComponent.isEmpty,
            root.lastPathComponent.utf8.allSatisfy({ (48...57).contains($0) }),
            FileManager.default.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return root.appending(path: statusName)
    }

    static func recordExecutable(_ executable: URL, in support: URL) throws {
        // A translocated copy or a mounted disk image is gone by the next launch, so nothing
        // recorded from there would still run.
        let readOnly = (try? executable.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        if readOnly || executable.pathComponents.contains("AppTranslocation") {
            AppLog.note("install: Bridgeplay runs from \(executable.path), so Steam cannot start rebuilds")
            try? FileManager.default.removeItem(at: support.appending(path: executableRecord))
            return
        }
        try atomicReplace(support.appending(path: executableRecord),
                          with: Data(executable.path(percentEncoded: false).utf8), step: "Record Bridgeplay app")
    }
}
