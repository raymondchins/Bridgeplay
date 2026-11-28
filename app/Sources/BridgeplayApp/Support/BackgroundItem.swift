import Foundation
import ServiceManagement

// The login agent behind Settings › Check Steam in the Background. Its launchd plist ships in
// Contents/Library/LaunchAgents and runs this app's own executable with --background-check, as
// the user, never as root. Registration is behind BackgroundItemService so the on/off logic is
// testable; registering for real needs a signed app and a login session.
enum BackgroundItem {
    static let plistName = "com.bridgeplay.Bridgeplay.background.plist"

    enum State: Equatable, Sendable {
        case off
        case on
        // Registered, but turned off in System Settings › General › Login Items.
        case needsApproval
        // The plist is not in this copy of the app (a debug build).
        case unavailable
    }

    // Tests pass their own; nil is the real SMAppService agent.
    @MainActor
    private static func resolve(_ service: (any BackgroundItemService)?) -> any BackgroundItemService {
        service ?? AgentService()
    }

    // Turning it on registers first and records the mode only when that worked, so a refusal
    // leaves it off. Turning it off records first: an agent that is still running reads the
    // mode and leaves.
    @MainActor
    static func set(
        _ mode: BackgroundCheck.Mode,
        service given: (any BackgroundItemService)? = nil,
        defaults: UserDefaults = .standard
    ) throws -> State {
        let service = resolve(given)
        if mode == .off {
            defaults.set(BackgroundCheck.Mode.off.rawValue, forKey: BackgroundCheck.modeKey)
            if service.state != .off { try service.unregister() }
            return service.state
        }
        if service.state == .off || service.state == .unavailable { try service.register() }
        defaults.set(mode.rawValue, forKey: BackgroundCheck.modeKey)
        // A new opt-in starts with a clean slate.
        for key in [BackgroundCheck.toldKey, BackgroundCheck.lastTryKey, BackgroundCheck.lastTryFailedKey] {
            defaults.removeObject(forKey: key)
        }
        return service.state
    }

    // What the Settings row shows: on only when both the mode and the registration say so.
    @MainActor
    static func current(service given: (any BackgroundItemService)? = nil, defaults: UserDefaults = .standard) -> State {
        let state = resolve(given).state
        if BackgroundCheck.mode(defaults) == .off { return state == .unavailable ? .unavailable : .off }
        return state
    }

    static func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
protocol BackgroundItemService {
    var state: BackgroundItem.State { get }
    func register() throws
    func unregister() throws
}

private struct AgentService: BackgroundItemService {
    private var agent: SMAppService { SMAppService.agent(plistName: BackgroundItem.plistName) }

    var state: BackgroundItem.State {
        switch agent.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notFound: .unavailable
        case .notRegistered: .off
        @unknown default: .off
        }
    }

    func register() throws {
        try agent.register()
        AppLog.note("background check: registered (\(state))")
    }

    func unregister() throws {
        try agent.unregister()
        AppLog.note("background check: unregistered")
    }
}
