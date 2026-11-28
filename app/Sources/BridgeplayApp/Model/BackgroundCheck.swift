import Foundation

// The opt-in background check (Settings › Check Steam in the Background): what the login
// agent does after a Steam update while the Bridgeplay app is closed. It only reads state and
// decides; BackgroundAgent runs it. By default it only tells the user. Re-applying on its own
// is a second opt-in and follows SteamPatchKeeper's rules, so it never touches Steam.app while
// Steam or a game runs, nor while Bridgeplay is paused, the breaker has tripped or the app is open.
enum BackgroundCheck {

    enum Mode: String, Sendable, CaseIterable {
        case off
        // Post one notification per Steam update that removed Bridgeplay.
        case notify
        // Also put Bridgeplay back once Steam and every game are closed.
        case reapply
    }

    static let modeKey = "backgroundCheck"
    // The notice already posted, so one Steam update gives one notification.
    static let toldKey = "backgroundCheckTold"
    static let lastTryKey = "backgroundCheckLastTry"
    static let lastTryFailedKey = "backgroundCheckLastTryFailed"

    static func mode(_ defaults: UserDefaults = .standard) -> Mode {
        defaults.string(forKey: modeKey).flatMap(Mode.init(rawValue:)) ?? .off
    }

    enum Skip: Equatable, Sendable {
        case off
        // The app's own keeper is running.
        case appOpen
        // Pause in Steam (the `paused` file) or Repair Steam (the keeper's paused flag).
        case paused
        // The crash-loop breaker sent this Steam build into passive mode.
        case breakerTripped
        case installBlocked
        // Steam carries this Bridgeplay, has none from this account, or is missing.
        case nothingToDo
        case alreadyTold
    }

    enum Action: Equatable, Sendable {
        case skip(Skip)
        case notify(Notice)
        case reapply(SteamPatchKeeper.Kind)
    }

    struct Notice: Equatable, Sendable {
        let kind: SteamPatchKeeper.Kind
        // nil in notify mode; in reapply mode, why it waits.
        let blocker: SteamPatchKeeper.Blocker?
        // Steam build and Bridgeplay build: a new key is a new notice.
        let key: String

        var title: String {
            switch kind {
            case .removedBySteam: String(localized: "Steam updated")
            case .outdated: String(localized: "Bridgeplay update for Steam")
            }
        }

        var body: String {
            let lead = switch kind {
            case .removedBySteam: String(localized: "Steam's update removed Bridgeplay, so Windows games won't start.")
            case .outdated: String(localized: "This version of Bridgeplay has newer files for Steam.")
            }
            let next = switch blocker {
            case nil, .lastTryFailed?: String(localized: "Open Bridgeplay to put it back.")
            case .steamRunning?, .gameRunning?: String(localized: "Bridgeplay puts itself back once Steam is closed.")
            }
            return "\(lead) \(next)"
        }
    }

    struct Inputs: Sendable {
        var mode: Mode
        var deployment: SteamDeployment
        var previouslyDeployed: Bool
        var steamRunning: Bool
        var gameRunning: Bool
        var appOpen = false
        // The keeper's flag, set by Repair Steam.
        var keeperPaused = false
        var installBlocked = false
        var health: HealthReading = .none
        var steamBuild: String?
        var bundledVersion: String
        var told: String?
        var lastTry: Date?
        var lastTryFailed = false
        var now = Date()
    }

    // A breaker verdict counts only while it is about this Steam and this Bridgeplay: the
    // breaker itself lets go when either updates.
    static func breakerTripped(_ health: HealthReading) -> Bool {
        health.mode == .passive
    }

    static func noticeKey(_ kind: SteamPatchKeeper.Kind, steamBuild: String?, bundledVersion: String) -> String {
        "\(kind)|\(steamBuild ?? "?")|\(bundledVersion)"
    }

    static func decide(_ inputs: Inputs) -> Action {
        guard inputs.mode != .off else { return .skip(.off) }
        guard !inputs.appOpen else { return .skip(.appOpen) }
        guard !inputs.health.paused, !inputs.keeperPaused else { return .skip(.paused) }
        guard !breakerTripped(inputs.health) else { return .skip(.breakerTripped) }
        guard !inputs.installBlocked else { return .skip(.installBlocked) }
        guard let kind = SteamPatchKeeper.kind(of: inputs.deployment, previouslyDeployed: inputs.previouslyDeployed)
        else { return .skip(.nothingToDo) }
        let key = noticeKey(kind, steamBuild: inputs.steamBuild, bundledVersion: inputs.bundledVersion)
        let blocker: SteamPatchKeeper.Blocker?
        if inputs.mode == .reapply {
            switch SteamPatchKeeper.decide(SteamPatchKeeper.Inputs(
                deployment: inputs.deployment, previouslyDeployed: inputs.previouslyDeployed,
                steamRunning: inputs.steamRunning, gameRunning: inputs.gameRunning,
                lastAttempt: inputs.lastTry, lastAttemptFailed: inputs.lastTryFailed, now: inputs.now)) {
            case .reapply(let kind): return .reapply(kind)
            case .ask(_, let why): blocker = why
            case .nothing: return .skip(.nothingToDo)
            }
        } else {
            blocker = nil
        }
        // A failed try is news even when the update was already announced, and is told once too.
        let notice = Notice(kind: kind, blocker: blocker, key: blocker == .lastTryFailed ? key + "|failed" : key)
        return inputs.told == notice.key ? .skip(.alreadyTold) : .notify(notice)
    }

    // Whether the agent should watch Steam (and the app) quit and decide again.
    static func waitsForQuit(_ action: Action, inputs: Inputs) -> Bool {
        switch action {
        case .skip(.appOpen): true
        case .skip(.alreadyTold), .notify:
            inputs.mode == .reapply && (inputs.steamRunning || inputs.gameRunning)
        case .skip, .reapply: false
        }
    }

    // A try that ended with Steam open again was interrupted, not failed: the next quit tries again.
    static func tryFailed(exitStatus: Int32, steamRunningAfter: Bool) -> Bool {
        exitStatus != 0 && !steamRunningAfter
    }
}
