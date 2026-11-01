import Foundation

// Notices when Steam no longer carries Bridgeplay (a Steam client update rewrites
// Steam.app) or carries an older build (Bridgeplay itself updated), and decides whether to
// put it back silently or to ask. It never touches Steam while Steam or a game runs, so it
// cannot fight Steam's own updater, and it tries on its own at most once per cooldown
// (a try that hits a Steam still settling gets a couple of retries, see reapply).
enum SteamPatchKeeper {

    // Set by Repair Steam, cleared by any install: a Steam the user restored on purpose
    // stays restored.
    static let pausedKey = "steamPatchKeeperPaused"
    static let cooldown: TimeInterval = 15 * 60
    // Window focus can arrive in bursts; checks closer together than this are skipped.
    static let checkInterval: TimeInterval = 20
    static let pollInterval: Duration = .seconds(300)

    enum Kind: Equatable, Sendable {
        // Steam's update replaced the bundle, so the patch is gone.
        case removedBySteam
        // This Bridgeplay has a newer patch than the one in Steam.
        case outdated
    }

    enum Blocker: Equatable, Sendable {
        case steamRunning
        case gameRunning
        case lastTryFailed
    }

    enum Decision: Equatable, Sendable {
        case nothing
        case reapply(Kind)
        case ask(Kind, Blocker)
    }

    struct Inputs: Sendable {
        var deployment: SteamDeployment
        // dylib.version exists, so Bridgeplay was installed into Steam from this account.
        var previouslyDeployed: Bool
        var steamRunning: Bool
        var gameRunning: Bool
        var paused = false
        var installBlocked = false
        var lastAttempt: Date?
        var lastAttemptFailed = false
        var now = Date()
    }

    static func kind(of deployment: SteamDeployment, previouslyDeployed: Bool) -> Kind? {
        switch deployment {
        case .notInstalled: previouslyDeployed ? .removedBySteam : nil
        case .outdated: .outdated
        case .installed, .steamMissing, .foreign: nil
        }
    }

    static func decide(_ inputs: Inputs) -> Decision {
        guard !inputs.paused, !inputs.installBlocked,
              let kind = kind(of: inputs.deployment, previouslyDeployed: inputs.previouslyDeployed)
        else { return .nothing }
        if inputs.gameRunning { return .ask(kind, .gameRunning) }
        if inputs.steamRunning { return .ask(kind, .steamRunning) }
        if inputs.lastAttemptFailed { return .ask(kind, .lastTryFailed) }
        if let last = inputs.lastAttempt, inputs.now.timeIntervalSince(last) < cooldown {
            return .ask(kind, .lastTryFailed)
        }
        return .reapply(kind)
    }

    // Reads only what decide() needs: the plist, two process lists and one small file.
    static func capture(
        bundledVersion: String,
        versionFile: URL = SupportPaths.deployedVersion
    ) -> (deployment: SteamDeployment, previouslyDeployed: Bool, steamRunning: Bool, gameRunning: Bool) {
        let gameRunning = Shell.processIsRunning(named: "wineserver")
            || RunnerInstaller.runningBuild() != nil
        return (SteamBundle.deployment(bundledVersion: bundledVersion, versionFile: versionFile),
                SteamBundle.deployedVersion(at: versionFile) != nil,
                SteamBundle.isRunning,
                gameRunning)
    }

    // MARK: Waiting for Steam's update to finish

    // Steam's updater rewrites Steam.app in place. Going in while it still writes made both
    // codesign and the plist write fail (#1931), so the keeper waits until nothing in the
    // bundle has changed for `settleQuiet`, and gives up after `settleTimeout`.
    static let settleQuiet: TimeInterval = 15
    static let settleTimeout: TimeInterval = 120
    static let settlePoll: Duration = .seconds(3)
    // Tries per re-apply; a failure that may pass is held back until the last one.
    static let maxAttempts = 3

    // True once settled, false on timeout. A bundle it can't read counts as settled and is
    // left to the install to report.
    @MainActor
    static func waitForSteamToSettle(
        lastChange: () async -> Date?,
        quiet: TimeInterval = settleQuiet,
        timeout: TimeInterval = settleTimeout,
        poll: Duration = settlePoll,
        now: () -> Date = Date.init,
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Bool {
        let start = now()
        while true {
            guard let changed = await lastChange() else { return true }
            let current = now()
            if current.timeIntervalSince(changed) >= quiet { return true }
            if current.timeIntervalSince(start) >= timeout { return false }
            await sleep(poll)
        }
    }

    // The newest status change of anything in the bundle, folders included, so a file
    // added, replaced or removed counts too. ctime, because an updater can set mtimes back.
    static func lastChange(in app: URL) -> Date? {
        let root = app.path(percentEncoded: false)
        func changed(_ path: String) -> Date? {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            let time = info.st_ctimespec
            return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
        }
        guard var newest = changed(root) else { return nil }
        let walk = FileManager.default.enumerator(atPath: root)
        while let relative = walk?.nextObject() as? String {
            if let date = changed(root + "/" + relative), date > newest { newest = date }
        }
        return newest
    }

    static func isRetryable(_ error: Error?) -> Bool {
        (error as? StepFailure)?.retryable == true
    }

    // Runs up to `maxAttempts` tries. Each try after a removedBySteam, and every retry, first
    // waits for Steam.app to settle (told whether it is a retry); `settle` returning false
    // stops. `attempt` is told whether a later try remains and returns true when it held a
    // failure back for one.
    @MainActor
    static func reapply(
        _ kind: Kind,
        maxAttempts: Int = maxAttempts,
        settle: (_ retrying: Bool) async -> Bool,
        attempt: (_ number: Int, _ mayRetry: Bool) async -> Bool
    ) async {
        for number in 1...maxAttempts {
            if kind == .removedBySteam || number > 1 {
                guard await settle(number > 1) else { return }
            }
            guard await attempt(number, number < maxAttempts) else { return }
        }
    }

    struct Banner: Equatable, Sendable {
        let kind: Kind
        let blocker: Blocker

        var title: String {
            switch kind {
            case .removedBySteam: String(localized: "Steam updated")
            case .outdated: String(localized: "Bridgeplay update for Steam")
            }
        }

        var message: String {
            let lead = switch kind {
            case .removedBySteam: String(localized: "Steam's update removed Bridgeplay, so Windows games won't start.")
            case .outdated: String(localized: "This version of Bridgeplay has newer files for Steam.")
            }
            let next = switch blocker {
            case .steamRunning: String(localized: "Steam closes for a moment and opens again.")
            case .gameRunning: String(localized: "Quit your game first.")
            case .lastTryFailed: String(localized: "Bridgeplay couldn't do this on its own.")
            }
            return "\(lead) \(next)"
        }

        var button: String {
            switch blocker {
            case .lastTryFailed: String(localized: "Try Again")
            case .steamRunning, .gameRunning: String(localized: "Re-apply Bridgeplay")
            }
        }

        var canApply: Bool { blocker != .gameRunning }
    }
}
