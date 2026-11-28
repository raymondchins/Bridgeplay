import AppKit

// After a game launch that went wrong, the run script starts this outside Steam's process
// group and exits, so Steam shows Play again while the panel says why: the Status card's
// sentence (LaunchVerdict) and one next step. A normal end shows nothing.
enum LaunchEndedCommand {
    // compat_run.sh looks for it in this binary before passing it, so it must stay over 15
    // bytes (see LaunchProgressCommand.flag).
    static let flag = "--launch-ended-panel"
    // An older record is another launch's: the script writes it just before starting this.
    static let freshness: TimeInterval = 120
    // The panel goes after this long, or when the game is launched again.
    static let limit: TimeInterval = 30 * 60

    // <compatdata>. Never returns.
    static func run(_ arguments: [String]) -> Never {
        guard arguments.count == 1, let prefix = prefix(compatdata: arguments[0]) else { exit(1) }
        // The step before the record: a Play pressed meanwhile has written another step, and
        // the record still on disk is the run before it.
        let step = LaunchEndedPanel.read(prefix.root.appending(path: LaunchProgressCommand.stepName).path(percentEncoded: false))
        let recordURL = prefix.root.appending(path: LaunchRecord.fileName)
        guard shows(step: step),
              let text = try? String(contentsOf: recordURL, encoding: .utf8),
              let record = LaunchRecord.parse(text),
              let ending = LaunchEnding(record: record, now: Date())
        else { exit(0) }
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.accessory)
            let watcher = LaunchEndedPanel(prefix: prefix, ending: ending, step: step)
            DispatchQueue.main.async { MainActor.assumeIsolated { watcher.present() } }
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { watcher.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            NSApp.run()
        }
        exit(0)
    }

    // The run script writes ended just before it starts this; any other step is a newer launch.
    static func shows(step: String?) -> Bool {
        step == LaunchStep.ended.rawValue
    }

    // steamapps/compatdata/<appid> on any library, with the game's name when Steam has one.
    static func prefix(compatdata path: String, userdata: URL = SupportPaths.Steam.userData.appending(path: "userdata"))
        -> WinePrefix? {
        guard path.hasPrefix("/") else { return nil }
        let root = URL(filePath: path).standardizedFileURL
        let appID = root.lastPathComponent
        let steamapps = root.deletingLastPathComponent().deletingLastPathComponent()
        guard !appID.isEmpty, appID.utf8.allSatisfy({ (48...57).contains($0) }),
              root.deletingLastPathComponent().lastPathComponent == "compatdata",
              steamapps.lastPathComponent == "steamapps"
        else { return nil }
        let library = SteamLibrary(root: steamapps.deletingLastPathComponent())
        var name = PrefixStore.appName(appID: appID, in: library)
        if name == nil, let id = UInt32(appID), id & 0x8000_0000 != 0 {
            name = PrefixStore.shortcutNames(userdata: userdata)[appID]
        }
        return WinePrefix(appID: appID, name: name, library: library, lastUsed: nil)
    }
}

// What the panel says and offers for one record, nil when it shows nothing.
struct LaunchEnding: Equatable {
    enum Next: Equatable {
        // The game's page on bridgeplay.dev: what other players found.
        case seeReports
        // The anti-cheat guide's other ways to play.
        case otherWaysToPlay
    }

    let verdict: LaunchVerdict
    let seconds: Int?
    let next: Next

    // Exit codes that name no cause. Without a crash line, after a minute they look like a
    // normal quit: some games always quit with 1.
    static let unexplained: Set<String> = ["generic_failure", "game_error", "exit_code"]

    init?(record: LaunchRecord, now: Date) {
        // Stops before the game started have their own alerts, and leave exit empty.
        guard record.exit != nil, let ended = record.ended,
              abs(now.timeIntervalSince(ended)) < LaunchEndedCommand.freshness,
              !(Self.unexplained.contains(record.code) && (record.seconds ?? 0) >= 60),
              let next = Self.next(for: record.verdict)
        else { return nil }
        verdict = record.verdict
        seconds = record.seconds
        self.next = next
    }

    // Only what went wrong after the game ran. A kill from outside Steam was someone's choice.
    static func next(for verdict: LaunchVerdict) -> Next? {
        switch verdict {
        case .neverOpenedWindow, .quitEarly, .crashed, .illegalInstruction, .missingFile, .macKilled,
             .lowMemory, .unexpected:
            .seeReports
        case .antiCheat:
            .otherWaysToPlay
        case .ok, .stoppedFromSteam, .stoppedOutside, .aborted, .rosettaMissing, .engineMissing,
             .engineUnsupported, .untracked:
            nil
        }
    }

    var button: String {
        switch next {
        case .seeReports: String(localized: "See Reports")
        case .otherWaysToPlay: String(localized: "Other Ways to Play")
        }
    }

    func url(for prefix: WinePrefix) -> URL {
        switch next {
        case .seeReports: HelpLinks.gamePage(appID: prefix.appID, name: prefix.name)
        case .otherWaysToPlay: HelpLinks.antiCheatAlternatives
        }
    }
}

@MainActor
final class LaunchEndedPanel {
    private let prefix: WinePrefix
    private let ending: LaunchEnding
    private let stepFile: String
    // What the step file said at the start: ended. A new launch writes another.
    private let step: String?
    private let started = ProcessInfo.processInfo.systemUptime
    private let panel = ProgressPanel(title: "Bridgeplay", activates: false)

    init(prefix: WinePrefix, ending: LaunchEnding, step: String?) {
        self.prefix = prefix
        self.ending = ending
        stepFile = prefix.root.appending(path: LaunchProgressCommand.stepName).path(percentEncoded: false)
        self.step = step
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel.panel, queue: .main) { _ in exit(0) }
    }

    func present() {
        let duration = LastLaunch.duration(seconds: ending.seconds)
        panel.show(message: ending.verdict.sentence, phase: "\(prefix.title) · \(duration)", buttons: [
            PanelButton(title: String(localized: "Close")) { exit(0) },
            PanelButton(title: ending.button) { [panel, prefix, ending] in
                panel.panel.orderOut(nil)
                NSWorkspace.shared.open(ending.url(for: prefix), configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                    exit(0)
                }
            },
        ])
        panel.present()
    }

    func tick() {
        if Self.read(stepFile) != step || ProcessInfo.processInfo.systemUptime - started >= LaunchEndedCommand.limit {
            exit(0)
        }
    }

    nonisolated static func read(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
