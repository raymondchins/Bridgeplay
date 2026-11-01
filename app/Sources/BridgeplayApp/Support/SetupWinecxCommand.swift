import Foundation

// What the WineCX Engine row's "Download & Set Up" does, for scripts: installs the WineCX
// engine (reusing any pinned archive already in the download cache), links a Game Porting
// Toolkit when one is found, sets the compatibility tool up and makes it Steam's default.
// Steam must be closed, since it rewrites config.vdf when it quits.
enum SetupWinecxCommand {
    static let flag = "--setup-winecx"

    static func run() -> Never {
        Task.detached { exit(AppLog.finished(await perform())) }
        dispatchMain()
    }

    private static func perform() async -> Int32 {
        do {
            if SteamBundle.isRunningForThisUser {
                throw StepFailure(step: FreeEngineWinecx.step, detail: "Steam is running. Quit Steam and run this again.")
            }
            if DeploymentContent.current(version: AppVersion.bundled).blocksInstallation {
                throw StepFailure(step: FreeEngineWinecx.step,
                                  detail: "Installation is blocked. Use the Bridgeplay app that installed this build.")
            }
            if RunnerInstaller.runningBuild() != nil {
                throw StepFailure(step: FreeEngineWinecx.step,
                                  detail: "A game or Wine tool is running. Quit it before setting WineCX up.")
            }
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }

            let install = try await FreeEngineWinecx.install { say($0.label) }
            _ = try RunnerSetup.run(from: install, replacingExisting: true) { say($0.label) }
            say(WinecxD3DMetal.linkedSource(root: install.crossOverRoot).map { "Game Porting Toolkit linked from \($0)." }
                ?? "Game Porting Toolkit not found; games use DXMT.")

            if let tool = FreeEngineWinecx.current.runner.tools.first?.name {
                do {
                    try SteamDefaultTool.set(tool)
                } catch is SteamDefaultTool.SteamRunning {
                    // Steam opened while the engine was set up; everything but the default is done.
                    throw StepFailure(step: SteamDefaultTool.step,
                                      detail: "WineCX is set up, but Steam opened in the meantime, so its default compatibility tool was not changed. Quit Steam and run this again.")
                }
                say("Steam's default compatibility tool is \(tool).")
            }
            say("WineCX is set up.")
            return 0
        } catch {
            AppLog.note("command line failed: \(RemoveEverythingCommand.failureMessage(error))")
            FileHandle.standardError.write(Data("\(RemoveEverythingCommand.failureMessage(error))\n".utf8))
            return 1
        }
    }

    private static func say(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
    }
}
