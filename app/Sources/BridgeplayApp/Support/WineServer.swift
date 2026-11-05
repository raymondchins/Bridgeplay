import Foundation

// Whether a game's Wine server is running. The server's name depends on the engine: the
// arm64 engine runs wineserver-arm64, Rosetta's runs wineserver or wineserver-x86 (the names
// PrefixTools.layout and dylib/feats/compat_run.sh pick). Match them all, not "wineserver".
enum WineServer {
    // An extended regex for pgrep -x, which anchors it to the whole process name.
    static let processPattern = "wineserver(-arm64|-x86)?"

    // This account's servers only. pgrep can take seconds, so callers keep it off the main actor.
    static func isRunning(pgrep: String = "/usr/bin/pgrep") -> Bool {
        Shell.processIsRunning(named: processPattern, pgrep: pgrep)
    }
}
