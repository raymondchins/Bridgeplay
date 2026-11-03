import AppKit
import Foundation
import Observation

// Asks for a GitHub star after a few game launches through Bridgeplay, and once more five
// launches after a Later. Everything stays in the app's defaults; nothing is sent.
@MainActor
@Observable
final class StarPrompt {

    static let shared = StarPrompt()
    static let repository = URL(string: "https://github.com/raymondchins/Bridgeplay")!
    static let firstAfter = 3
    static let againAfter = 5

    // Shared with the launch progress helper, a separate process of this app.
    nonisolated static let launchesKey = "StarPromptLaunches"
    private static let shownKey = "StarPromptShown"
    private static let shownAtKey = "StarPromptShownAt"
    private static let doneKey = "StarPromptDone"

    // Waiting for the card, which shows it once nothing else is asking.
    private(set) var pending = false
    // On screen this run.
    private(set) var shown = false
    private var checking = false
    // Later, or the window closed: nothing brings the card back this run.
    private var laterThisRun = false
    private let defaults: UserDefaults
    private let opener: (URL) -> Void
    private let gameRunning: () async -> Bool
    private let reportScanRunning: () -> Bool

    init(defaults: UserDefaults = .standard, opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         gameRunning: @escaping () async -> Bool = { await RestartGuard.gameRunning() },
         reportScanRunning: @escaping () -> Bool = { PlayReports.shared.finding }) {
        self.defaults = defaults
        self.opener = opener
        self.gameRunning = gameRunning
        self.reportScanRunning = reportScanRunning
    }

    // Every game launch starts the launch progress helper, which counts it here.
    nonisolated static func countLaunch(in defaults: UserDefaults = .standard) {
        defaults.set(defaults.integer(forKey: launchesKey) + 1, forKey: launchesKey)
    }

    var due: Bool {
        guard !shown, !defaults.bool(forKey: Self.doneKey) else { return false }
        let launches = defaults.integer(forKey: Self.launchesKey)
        switch defaults.integer(forKey: Self.shownKey) {
        case 0: return launches >= Self.firstAfter
        case 1: return launches >= defaults.integer(forKey: Self.shownAtKey) + Self.againAfter
        default: return false
        }
    }

    // When the app comes forward. A game started since takes the card back, even one already
    // on screen, which then stays away for this run without counting as another showing.
    func check() async {
        guard due || pending, !laterThisRun, !checking else { return }
        checking = true
        defer { checking = false }
        // A card not seen yet waits for a game check made after the play report scan, which
        // can take a while on the daily VerifiedGames download, so a game started meanwhile
        // keeps it hidden and uncounted.
        if !shown { pending = false }
        while reportScanRunning() { try? await Task.sleep(for: .milliseconds(250)) }
        let running = await gameRunning()
        if running {
            pending = false
        } else if due, !laterThisRun {
            pending = true
        }
    }

    // A showing counts once the card is on screen, so closing the window or quitting is a
    // Later as much as the button.
    func appeared() {
        guard pending, !shown else { return }
        shown = true
        defaults.set(defaults.integer(forKey: Self.shownKey) + 1, forKey: Self.shownKey)
        defaults.set(defaults.integer(forKey: Self.launchesKey), forKey: Self.shownAtKey)
    }

    func star() {
        opener(Self.repository)
        never()
    }

    func later() {
        pending = false
        laterThisRun = true
    }

    func never() {
        defaults.set(true, forKey: Self.doneKey)
        pending = false
    }
}
