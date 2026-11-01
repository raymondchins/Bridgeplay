import Foundation

// What the Update button on the Status page does, for scripts: deploys this app's files
// into Steam and exits. Refuses the same cases the button refuses.
enum InstallIntoSteamCommand {
    static let flag = "--install-into-steam"

    static func run() -> Never {
        Task.detached { exit(AppLog.finished(await perform())) }
        dispatchMain()
    }

    private static func perform() async -> Int32 {
        do {
            if DeploymentContent.current(version: AppVersion.bundled).blocksInstallation {
                throw StepFailure(step: SteamInstaller.step,
                                  detail: "Installation is blocked. Use the Bridgeplay app that installed this build.")
            }
            if RunnerInstaller.runningBuild() != nil {
                throw StepFailure(step: SteamInstaller.step,
                                  detail: "A game or Wine tool is running. Quit it before updating Bridgeplay.")
            }
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            let result = try SteamInstaller.run(holdingInstallationLock: true, report: { say($0.label) })

            let valve = try ValvePackageManifest.bundled()
            if valve.files.contains(where: {
                Digest.sha256IfPresent(SupportPaths.bridge.appending(path: $0.bridgePath)) != $0.sha256
            }) {
                say("Downloading missing components")
                _ = try await ValveFetcher.run { say($0.label) }
            }
            try SteamInstaller.finish(result)
            UserDefaults.standard.removeObject(forKey: SteamPatchKeeper.pausedKey)
            say("Bridgeplay \(ProductVersion.short) installed into Steam.")
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
