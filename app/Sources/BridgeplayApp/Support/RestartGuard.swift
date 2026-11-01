import Foundation

// Whether a restart would land under a running game. pgrep can take seconds, so it stays off
// the main actor.
enum RestartGuard {
    static func gameRunning() async -> Bool {
        await Task.detached(priority: .utility) { Shell.processIsRunning(named: "wineserver") }.value
    }
}
