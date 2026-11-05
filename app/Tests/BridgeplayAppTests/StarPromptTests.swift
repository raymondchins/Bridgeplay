import Foundation
import Testing

@testable import BridgeplayApp

@MainActor
@Suite("GitHub star prompt")
struct StarPromptTests {

    private func defaults(launches: Int = 0) -> UserDefaults {
        let defaults = scratchDefaults()
        for _ in 0..<launches { StarPrompt.countLaunch(in: defaults) }
        return defaults
    }

    private static func prompt(_ defaults: UserDefaults, opener: @escaping (URL) -> Void = { _ in },
                               gameRunning: Bool = false) -> StarPrompt {
        StarPrompt(defaults: defaults, opener: opener, gameRunning: { gameRunning }, reportScanRunning: { false })
    }

    // The card goes on screen.
    private static func show(_ prompt: StarPrompt) async {
        await prompt.check()
        prompt.appeared()
    }

    @Test("Due from the third launch, once per run")
    func firstShowing() async {
        let defaults = defaults(launches: 2)
        #expect(!Self.prompt(defaults).due)
        StarPrompt.countLaunch(in: defaults)
        let prompt = Self.prompt(defaults)
        #expect(prompt.due)
        await Self.show(prompt)
        #expect(prompt.pending)
        prompt.later()  // also what closing the window does
        StarPrompt.countLaunch(in: defaults)
        #expect(!prompt.due)
        await prompt.check()
        #expect(!prompt.pending)
        #expect(defaults.integer(forKey: "StarPromptShown") == 1 && defaults.integer(forKey: "StarPromptShownAt") == 3)
    }

    @Test("Later, or closing it any other way, shows it once more five launches on, then never")
    func later() async {
        let defaults = defaults(launches: 3)
        await Self.show(Self.prompt(defaults))  // closed without an answer
        for _ in 0..<4 { StarPrompt.countLaunch(in: defaults) }
        #expect(!Self.prompt(defaults).due)
        StarPrompt.countLaunch(in: defaults)
        let second = Self.prompt(defaults)
        #expect(second.due)
        await Self.show(second)
        second.later()
        for _ in 0..<20 { StarPrompt.countLaunch(in: defaults) }
        #expect(!Self.prompt(defaults).due)
    }

    @Test("Star on GitHub opens the repository and ends it")
    func star() async {
        let defaults = defaults(launches: 3)
        var opened: [URL] = []
        let prompt = Self.prompt(defaults, opener: { opened.append($0) })
        await Self.show(prompt)
        prompt.star()
        #expect(opened == [URL(string: "https://github.com/raymondchins/Bridgeplay")!])
        #expect(!prompt.pending)
        for _ in 0..<10 { StarPrompt.countLaunch(in: defaults) }
        #expect(!Self.prompt(defaults).due)
    }

    @Test("Don't show again ends it, even before the second showing")
    func never() async {
        let defaults = defaults(launches: 3)
        let prompt = Self.prompt(defaults)
        await Self.show(prompt)
        prompt.never()
        #expect(!prompt.pending)
        for _ in 0..<10 { StarPrompt.countLaunch(in: defaults) }
        #expect(!Self.prompt(defaults).due)
    }

    @Test("Not while a game is running, and a game started while it waits takes it back")
    func gameRunning() async {
        let defaults = defaults(launches: 3)
        var running = true
        let prompt = StarPrompt(defaults: defaults, opener: { _ in }, gameRunning: { running }, reportScanRunning: { false })
        await prompt.check()
        #expect(!prompt.pending)
        running = false
        await prompt.check()
        #expect(prompt.pending)
        running = true
        await prompt.check()
        #expect(!prompt.pending)
        prompt.appeared()
        #expect(defaults.integer(forKey: "StarPromptShown") == 0)
    }

    @Test("A card on screen is taken back when a game starts, without another showing")
    func shownThenGame() async {
        let defaults = defaults(launches: 3)
        var running = false
        let prompt = StarPrompt(defaults: defaults, opener: { _ in }, gameRunning: { running }, reportScanRunning: { false })
        await Self.show(prompt)
        running = true
        await prompt.check()
        #expect(!prompt.pending)
        running = false
        await prompt.check()
        #expect(!prompt.pending)
        #expect(defaults.integer(forKey: "StarPromptShown") == 1)
    }

    @Test("Closing the window during a check, or before the card was seen, keeps it away this run")
    func closedDuringCheck() async {
        let defaults = defaults(launches: 3)
        let prompt = StarPrompt(defaults: defaults, opener: { _ in }, gameRunning: {
            try? await Task.sleep(for: .milliseconds(100))
            return false
        }, reportScanRunning: { false })
        let checking = Task { await prompt.check() }
        try? await Task.sleep(for: .milliseconds(20))
        prompt.later()
        await checking.value
        #expect(!prompt.pending)
        await prompt.check()
        #expect(!prompt.pending)
        #expect(defaults.integer(forKey: "StarPromptShown") == 0)
    }

    @Test("A game started during the play report scan keeps the card hidden and uncounted")
    func gameDuringScan() async {
        let defaults = defaults(launches: 3)
        var running = false, scanning = false
        let prompt = StarPrompt(defaults: defaults, opener: { _ in }, gameRunning: { running },
                                reportScanRunning: { scanning })
        await prompt.check()
        #expect(prompt.pending)
        // The app comes forward again and a new scan starts: the unseen card waits for it.
        scanning = true
        let checking = Task { await prompt.check() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!prompt.pending)
        running = true
        scanning = false
        await checking.value
        #expect(!prompt.pending)
        prompt.appeared()
        #expect(defaults.integer(forKey: "StarPromptShown") == 0)
    }

    @Test("Due but never on screen, nothing is used up")
    func notShown() async {
        let defaults = defaults(launches: 3)
        let prompt = Self.prompt(defaults)
        await prompt.check()
        prompt.later()
        #expect(Self.prompt(defaults).due)
    }
}
