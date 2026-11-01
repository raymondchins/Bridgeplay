// Re-applying the Steam patch after Sparkle installs a newer Bridgeplay

import Foundation
import Sparkle

// Sparkle replaces the app, but the patch inside Steam is still the one the previous
// version installed. On the first launch of a newer build this runs the normal install
// once, and only when nothing would be interrupted or asked: Steam is closed, no game or
// Wine tool is running, a compatibility tool exists (so no activation question), and the
// installed content does not block installation. Otherwise the Status row keeps showing
// "Update available" with its install button. While Steam or a game runs, SteamPatchKeeper
// also shows a banner and re-applies by itself once both close, with no relaunch.
enum PostUpdateRefresh {

    enum Decision: Equatable, Sendable {
        case install
        // Steam or a game is running. SteamPatchKeeper re-applies once both close, and this
        // tries again on the next launch.
        case wait
        case nothing
    }

    static let lastBuildKey = "PostUpdateRefresh.lastBuild"

    nonisolated static func decide(
        steam: SteamDeployment,
        steamRunning: Bool,
        workloadRunning: Bool,
        contentBlocks: Bool,
        hasRunner: Bool,
        build: String?,
        lastBuild: String?
    ) -> Decision {
        // An unstamped development build never touches Steam on its own.
        guard let build else { return .nothing }
        if let lastBuild,
           SUStandardVersionComparator().compareVersion(build, toVersion: lastBuild) != .orderedDescending {
            return .nothing
        }
        // Only an older recorded Bridgeplay counts; a missing record or the same version
        // with a stale Info.plist is left to the Status row.
        guard case .outdated(let deployed, let bundled) = steam, !deployed.isEmpty, deployed != bundled else {
            return .nothing
        }
        guard hasRunner, !contentBlocks else { return .nothing }
        return steamRunning || workloadRunning ? .wait : .install
    }

    @MainActor private static var handled = false

    // Called whenever the status snapshot or idleness changes; acts once per launch, on the
    // first idle snapshot.
    @MainActor
    static func runIfNeeded(_ status: SystemStatus, defaults: UserDefaults = .standard) async {
        guard !handled, status.isIdle, let snapshot = status.snapshot else { return }
        handled = true

        let build = ProductVersion.build
        // pgrep and ps can take seconds, so neither runs on the main actor.
        let (steamRunning, workloadRunning) = await Task.detached(priority: .utility) {
            (SteamBundle.isRunning,
             RunnerInstaller.runningBuild() != nil)
        }.value
        let decision = decide(
            steam: snapshot.steam,
            steamRunning: snapshot.steamRunning || steamRunning,
            workloadRunning: workloadRunning,
            contentBlocks: snapshot.installContent.blocksInstallation,
            hasRunner: snapshot.runner != .none,
            build: build,
            lastBuild: defaults.string(forKey: lastBuildKey)
        )

        switch decision {
        case .nothing:
            if let build { defaults.set(build, forKey: lastBuildKey) }
        case .wait:
            AppLog.note("post-update: Steam patch is outdated; waiting for Steam and games to close")
        case .install:
            AppLog.note("post-update: re-applying the Steam patch for \(ProductVersion.display)")
            if let build { defaults.set(build, forKey: lastBuildKey) }
            await status.requestInstall(unattended: true)
        }
        // Engines whose files this build rebuilt or re-pinned follow, under the same rule.
        if decision != .wait { await status.updateEverything(includingSteamPatch: false) }
    }
}
