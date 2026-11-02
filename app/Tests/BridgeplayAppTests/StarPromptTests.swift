import Foundation
import Testing

@testable import BridgeplayApp

@MainActor
@Suite("GitHub star prompt")
struct StarPromptTests {

    // One domain per test, emptied first: macOS keeps a file for every domain name used.
    private func defaults(launches: Int = 0, test: String = #function) -> UserDefaults {
        let name = "StarPromptTests.\(test.prefix { $0 != "(" })"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        for _ in 0..<launches { StarPrompt.countLaunch(in: defaults) }
        return defaults
    }

    private static func prompt(_ defaults: UserDefaults, opener: @escaping (URL) -> Void = { _ in },
                               gameRunning: Bool = false) -> StarPrompt {
        StarPrompt(defaults: defaults, opener: opener, gameRunning: { gameRunning })
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
        prompt.later()
        StarPrompt.countLaunch(in: defaults)
        #expect(!prompt.due)
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
        let prompt = StarPrompt(defaults: defaults, opener: { _ in }, gameRunning: { running })
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

    @Test("Due but never on screen, nothing is used up")
    func notShown() async {
        let defaults = defaults(launches: 3)
        let prompt = Self.prompt(defaults)
        await prompt.check()
        prompt.later()
        #expect(Self.prompt(defaults).due)
    }
}
