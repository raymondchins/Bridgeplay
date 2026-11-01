import Foundation
import Testing

@testable import BridgeplayApp

@Suite("Keeping Bridgeplay in Steam")
struct SteamPatchKeeperTests {

    private func inputs(
        _ deployment: SteamDeployment = .notInstalled,
        previouslyDeployed: Bool = true,
        steamRunning: Bool = false,
        gameRunning: Bool = false,
        paused: Bool = false,
        installBlocked: Bool = false,
        lastAttempt: Date? = nil,
        lastAttemptFailed: Bool = false,
        now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> SteamPatchKeeper.Inputs {
        SteamPatchKeeper.Inputs(
            deployment: deployment, previouslyDeployed: previouslyDeployed, steamRunning: steamRunning,
            gameRunning: gameRunning, paused: paused, installBlocked: installBlocked,
            lastAttempt: lastAttempt, lastAttemptFailed: lastAttemptFailed, now: now)
    }

    @Test("Steam closed and no game running: the patch goes back on its own")
    func reappliesSilently() {
        #expect(SteamPatchKeeper.decide(inputs()) == .reapply(.removedBySteam))
        #expect(SteamPatchKeeper.decide(inputs(.outdated(deployed: "1.0", bundled: "1.1"))) == .reapply(.outdated))
    }

    @Test("Steam running: ask, never stop Steam unasked")
    func asksWhileSteamRuns() {
        #expect(SteamPatchKeeper.decide(inputs(steamRunning: true)) == .ask(.removedBySteam, .steamRunning))
    }

    @Test("A running game wins over everything, and its banner cannot apply")
    func waitsForTheGame() {
        let decision = SteamPatchKeeper.decide(inputs(steamRunning: true, gameRunning: true))
        #expect(decision == .ask(.removedBySteam, .gameRunning))
        #expect(!SteamPatchKeeper.Banner(kind: .removedBySteam, blocker: .gameRunning).canApply)
        #expect(SteamPatchKeeper.Banner(kind: .removedBySteam, blocker: .steamRunning).canApply)
    }

    @Test("A Steam that never had Bridgeplay is left to the Setup Assistant")
    func leavesFreshSteamAlone() {
        #expect(SteamPatchKeeper.decide(inputs(previouslyDeployed: false)) == .nothing)
    }

    @Test("Installed, missing, foreign or repaired Steam is left alone")
    func nothingToDo() {
        #expect(SteamPatchKeeper.decide(inputs(.installed(version: "1.0"))) == .nothing)
        #expect(SteamPatchKeeper.decide(inputs(.steamMissing)) == .nothing)
        #expect(SteamPatchKeeper.decide(inputs(.foreign(insert: "/other.dylib"))) == .nothing)
        #expect(SteamPatchKeeper.decide(inputs(paused: true)) == .nothing)
        #expect(SteamPatchKeeper.decide(inputs(installBlocked: true)) == .nothing)
    }

    @Test("A failed or recent attempt is not repeated on its own")
    func debounces() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SteamPatchKeeper.decide(inputs(lastAttemptFailed: true)) == .ask(.removedBySteam, .lastTryFailed))
        #expect(SteamPatchKeeper.decide(inputs(lastAttempt: now.addingTimeInterval(-60), now: now))
            == .ask(.removedBySteam, .lastTryFailed))
        #expect(SteamPatchKeeper.decide(inputs(lastAttempt: now.addingTimeInterval(-SteamPatchKeeper.cooldown - 1), now: now))
            == .reapply(.removedBySteam))
    }

    @Test("Banner text names Bridgeplay and says what happens next")
    func bannerText() {
        let banner = SteamPatchKeeper.Banner(kind: .removedBySteam, blocker: .steamRunning)
        #expect(banner.title == "Steam updated")
        #expect(banner.message.contains("Bridgeplay"))
        #expect(banner.button == "Re-apply Bridgeplay")
    }

    // A clock the settle wait reads and its sleep moves forward, so no test really waits.
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var sleeps = 0
        func sleep(_ duration: Duration) async {
            sleeps += 1
            now += TimeInterval(duration.components.seconds)
        }
    }

    @Test("A Steam.app that settled a while ago is re-applied without waiting")
    @MainActor
    func settledBundleGoesStraightIn() async {
        let clock = Clock()
        let changed = clock.now.addingTimeInterval(-SteamPatchKeeper.settleQuiet - 1)
        let settled = await SteamPatchKeeper.waitForSteamToSettle(
            lastChange: { changed }, now: { clock.now }, sleep: clock.sleep)
        #expect(settled)
        #expect(clock.sleeps == 0)
    }

    @Test("A Steam.app still being written is waited on until it has been quiet")
    @MainActor
    func waitsWhileSteamWrites() async {
        let clock = Clock()
        let start = clock.now
        // The updater keeps writing for 20 seconds, then stops.
        let settled = await SteamPatchKeeper.waitForSteamToSettle(
            lastChange: { min(clock.now, start.addingTimeInterval(20)) },
            now: { clock.now }, sleep: clock.sleep)
        #expect(settled)
        #expect(clock.now.timeIntervalSince(start) >= 20 + SteamPatchKeeper.settleQuiet)
        #expect(clock.now.timeIntervalSince(start) < SteamPatchKeeper.settleTimeout)
    }

    @Test("A Steam.app that never settles is given up on, not waited on forever")
    @MainActor
    func settleWaitIsBounded() async {
        let clock = Clock()
        let start = clock.now
        let settled = await SteamPatchKeeper.waitForSteamToSettle(
            lastChange: { clock.now }, now: { clock.now }, sleep: clock.sleep)
        #expect(!settled)
        #expect(clock.now.timeIntervalSince(start) >= SteamPatchKeeper.settleTimeout)
        #expect(clock.now.timeIntervalSince(start) < SteamPatchKeeper.settleTimeout + 10)
    }

    @Test("A bundle that can't be read is left to the install to report")
    @MainActor
    func unreadableBundleCountsAsSettled() async {
        #expect(await SteamPatchKeeper.waitForSteamToSettle(lastChange: { nil }))
    }

    @Test("The bundle's last change includes files deep inside it")
    func lastChangeSeesNestedWrites() throws {
        let app = try scratchDirectory("keeper").appending(path: "Steam.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let before = try #require(SteamPatchKeeper.lastChange(in: app))
        Thread.sleep(forTimeInterval: 0.05)
        try Data("new".utf8).write(to: macOS.appending(path: "steam_osx"))
        let after = try #require(SteamPatchKeeper.lastChange(in: app))
        #expect(after > before)
        #expect(SteamPatchKeeper.lastChange(in: app.appending(path: "missing")) == nil)
    }

    @Test("After Steam's update the keeper waits for Steam.app before every try")
    @MainActor
    func removedBySteamWaitsFirst() async {
        var events: [String] = []
        await SteamPatchKeeper.reapply(.removedBySteam) { retrying in
            events.append("settle \(retrying)")
            return true
        } attempt: { number, mayRetry in
            events.append("try \(number) \(mayRetry)")
            return number < 2
        }
        #expect(events == ["settle false", "try 1 true", "settle true", "try 2 true"])
    }

    @Test("An outdated patch goes in at once, and retries stop after the last try")
    @MainActor
    func retriesAreBounded() async {
        var events: [String] = []
        await SteamPatchKeeper.reapply(.outdated) { retrying in
            events.append("settle \(retrying)")
            return true
        } attempt: { number, mayRetry in
            events.append("try \(number) \(mayRetry)")
            return true
        }
        #expect(events == ["try 1 true", "settle true", "try 2 true", "settle true", "try 3 false"])
    }

    @Test("A Steam.app that never settles is not tried at all")
    @MainActor
    func unsettledSteamIsNotTouched() async {
        var tries = 0
        await SteamPatchKeeper.reapply(.removedBySteam) { _ in false } attempt: { _, _ in
            tries += 1
            return true
        }
        #expect(tries == 0)
    }

    @Test("A failed re-apply stands while Steam's signature stays broken")
    func failureStandsOnBrokenSeal() {
        #expect(SteamPatchKeeper.failureStands(.installed(version: nil), lastAttemptFailed: true) { false })
        #expect(!SteamPatchKeeper.failureStands(.installed(version: nil), lastAttemptFailed: true) { true })

        // Nothing failed, or Steam isn't installed: the signature is not read at all.
        var read = false
        #expect(!SteamPatchKeeper.failureStands(.installed(version: nil), lastAttemptFailed: false) { read = true; return false })
        #expect(!SteamPatchKeeper.failureStands(.notInstalled, lastAttemptFailed: true) { read = true; return false })
        #expect(!read)
    }

    @Test("Only a failure marked as passing is retried")
    func retryableFailures() {
        #expect(SteamPatchKeeper.isRetryable(StepFailure(step: "s", detail: "d", retryable: true)))
        #expect(!SteamPatchKeeper.isRetryable(StepFailure(step: "s", detail: "d")))
        #expect(!SteamPatchKeeper.isRetryable(WriteRefused(path: "/x", remedy: .ownership)))
        #expect(!SteamPatchKeeper.isRetryable(nil))
    }

    @Test("The Input Monitoring link opens the ListenEvent list")
    @MainActor
    func inputMonitoringLink() {
        #expect(SystemStatus.inputMonitoringPane.scheme == "x-apple.systempreferences")
        #expect(SystemStatus.inputMonitoringPane.query == "Privacy_ListenEvent")
    }
}
