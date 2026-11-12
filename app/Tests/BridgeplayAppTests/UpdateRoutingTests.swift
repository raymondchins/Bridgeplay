import Foundation
import Testing
@testable import BridgeplayApp

private let stableFeed = "https://github.com/raymondchins/Bridgeplay/releases/latest/download/appcast.xml"

private func stable(_ build: Int, contains list: String? = nil) -> FeedItem {
    FeedItem(label: "0.7.\(build)", build: String(build), channel: nil, containsBetas: list)
}

private func beta(_ build: Int, critical: Bool = false) -> FeedItem {
    FeedItem(label: "0.7.\(build)-beta.1", build: String(build), channel: critical ? "beta-critical" : "beta")
}

private func running(_ build: Int, _ channel: ProductVersion.Channel) -> RunningBuild {
    RunningBuild(label: channel == .beta ? "0.7.\(build)-beta.1" : "0.7.\(build)", build: String(build), channel: channel)
}

// A routing with one check started.
private func checking(_ build: RunningBuild, enrolled: Bool) -> UpdateRouting {
    var routing = UpdateRouting(running: build, settings: UpdateSettings(enrolled: enrolled))
    routing.startCheck(settings: UpdateSettings(enrolled: enrolled))
    return routing
}

// What `choose` picked, as the item.
private func picked(_ routing: inout UpdateRouting, _ items: [FeedItem]) -> FeedItem?? {
    guard let choice = routing.choose(items) else { return nil }
    return .some(choice.map { items[$0] })
}

@Suite("Updater state")
struct UpdaterStateTests {

    @Test("Every row of the state table")
    func table() {
        #expect(UpdaterState.of(enrolled: false, running: .stable) == .stable)
        #expect(UpdaterState.of(enrolled: true, running: .stable) == .beta)
        #expect(UpdaterState.of(enrolled: true, running: .beta) == .beta)
        #expect(UpdaterState.of(enrolled: false, running: .beta) == .leaving)
    }

    @Test("Allowed channels per state")
    func channels() {
        #expect(UpdaterState.stable.allowedChannels.isEmpty)
        #expect(UpdaterState.beta.allowedChannels == ["beta", "beta-critical"])
        #expect(UpdaterState.leaving.allowedChannels == ["beta-critical"])
    }

    @Test("Only a real boolean enrolls; missing, unreadable or garbage is off")
    func preference() {
        let defaults = scratchDefaults()
        #expect(!BetaUpdates.enrolled(defaults))
        defaults.set(true, forKey: "BetaUpdates")
        #expect(BetaUpdates.enrolled(defaults))
        defaults.set(false, forKey: "BetaUpdates")
        #expect(!BetaUpdates.enrolled(defaults))
        for garbage: Any in ["banana", "YES", "1", 1, 2.5, ["on"], Data([1])] {
            defaults.set(garbage, forKey: "BetaUpdates")
            #expect(!BetaUpdates.enrolled(defaults), "\(garbage)")
        }
    }
}

@Suite("Beta off behaves as today")
struct BetaOffTests {

    // Today's AppUpdater wrote exactly these keys when Sparkle found an update.
    private func todaysWrites(_ defaults: UserDefaults, _ item: FeedItem) {
        defaults.set(item.build, forKey: "LatestReleaseBuild")
        defaults.set(item.label, forKey: "LatestReleaseVersion")
        defaults.set(nil as String?, forKey: "LatestReleaseNotes")
    }

    // One check the way AppUpdater drives it, writing what it writes.
    private func check(_ defaults: UserDefaults, items: [FeedItem]) -> (route: UpdateRoute, choice: Int??, lines: [String]) {
        let build = running(79, .stable)
        var routing = UpdateRouting(running: build, settings: .read(defaults))
        routing.startCheck(settings: .read(defaults))
        routing.feedDidLoad()
        let choice = routing.choose(items)
        var lines: [String] = []
        let found = items[0]
        LatestRelease.record(build: found.build, version: found.label, notes: nil, state: routing.state, defaults: defaults)
        if let line = routing.found(found, feedURL: stableFeed) { lines.append(line) }
        if let line = routing.finished(error: nil, feedFailed: false, feedURL: stableFeed) { lines.append(line) }
        return (routing.route, choice, lines)
    }

    enum Preference: CaseIterable, Sendable { case unset, off, garbage }

    @Test("No preference, preference off and a garbage preference: feed, channels, choice, defaults and log as today",
          arguments: Preference.allCases)
    func identical(preference: Preference) {
        let now = scratchDefaults(), today = scratchDefaults()
        for defaults in [now, today] {
            switch preference {
            case .unset: break
            case .off: defaults.set(false, forKey: "BetaUpdates")
            case .garbage: defaults.set("garbage", forKey: "BetaUpdates")
            }
        }
        let items = [stable(80), beta(81), beta(82, critical: true)]
        let (route, choice, lines) = check(now, items: items)
        todaysWrites(today, items[0])

        #expect(route.state == .stable)
        #expect(route.feedURL == nil, "Sparkle keeps SUFeedURL, requested as today")
        #expect(route.allowedChannels.isEmpty, "the empty set Sparkle uses when the delegate is silent")
        #expect(choice == nil, "Sparkle's own choice, no filtering")
        #expect(route.notes.isEmpty)
        #expect(NSDictionary(dictionary: now.dictionaryRepresentation()) == NSDictionary(dictionary: today.dictionaryRepresentation()),
                "no new defaults written")
        #expect(lines == ["update check: state=stable feed=\(stableFeed) running=79 (stable) chosen=80 (stable) pending=none"],
                "the one new line")
    }

    @Test("Watching the preference does nothing while it doesn't change")
    func quietPreference() {
        var routing = UpdateRouting(running: running(79, .stable), settings: UpdateSettings())
        #expect(routing.preferenceChanged(enrolled: false, sessionInProgress: false) == .none)
        #expect(routing.sessionEnded() == .none)
    }

    // Update settings belong to Info.plist and Sparkle; the routing has no way to touch them.
    @Test("AppUpdater changes no Sparkle update setting")
    func settingsUntouched() throws {
        let source = try String(contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/BridgeplayApp/Support/AppUpdater.swift"), encoding: .utf8)
        for setter in ["automaticallyChecksForUpdates =", "automaticallyDownloadsUpdates =", "updateCheckInterval =",
                       "sendsSystemProfile =", "setFeedURL", "clearFeedURLFromUserDefaults"] {
            #expect(!source.contains(setter), "\(setter)")
        }
    }
}

@Suite("Update routing")
struct UpdateRoutingTests {

    @Test("X-1: a stable player is not offered a beta")
    func x1() {
        var routing = checking(running(79, .stable), enrolled: false)
        #expect(routing.route.feedURL == nil)
        #expect(routing.route.allowedChannels.isEmpty)
        #expect(picked(&routing, [beta(81)]) == nil, "Sparkle filters the beta channel out itself")
        let rule = ItemChoice.choose([beta(81), beta(82, critical: true)], running: running(79, .stable), allowed: [])
        #expect(rule.index == nil)
    }

    @Test("X-3: beta 82 is not offered hotfix 83 that lacks it")
    func x3() {
        for list in [nil, "", "81", "83-90", "garbage"] as [String?] {
            var routing = checking(running(82, .beta), enrolled: true)
            #expect(picked(&routing, [stable(83, contains: list)]) == .some(nil), "\(String(describing: list))")
        }
    }

    @Test("X-4: beta 82 is offered beta-critical 84")
    func x4() {
        var routing = checking(running(82, .beta), enrolled: true)
        #expect(routing.route.feedURL == BetaUpdates.betaFeedURL)
        #expect(picked(&routing, [stable(83), beta(84, critical: true)]) == .some(beta(84, critical: true)))
    }

    @Test("X-5: leaving 82 is offered only beta-critical")
    func x5() {
        var routing = checking(running(82, .beta), enrolled: false)
        #expect(routing.state == .leaving)
        #expect(routing.route.feedURL == BetaUpdates.betaFeedURL)
        #expect(routing.route.allowedChannels == ["beta-critical"])
        #expect(picked(&routing, [beta(85), beta(84, critical: true)]) == .some(beta(84, critical: true)))
        var only = checking(running(82, .beta), enrolled: false)
        #expect(picked(&only, [beta(85)]) == .some(nil))
    }

    @Test("X-6: leaving 82 is offered stable 86 that lists 82, then is stable after the install")
    func x6() {
        var routing = checking(running(82, .beta), enrolled: false)
        let item = stable(86, contains: "81-85")
        #expect(picked(&routing, [beta(85), item]) == .some(item))
        routing.waitingForQuit(item)
        let after = routing.prediction(enrolled: false)
        #expect(after.build == "86" && after.channel == .stable && after.state == .stable && after.installsPending)

        let installed = checking(running(86, .stable), enrolled: false)
        #expect(installed.state == .stable)
        #expect(installed.route.feedURL == nil && installed.route.allowedChannels.isEmpty)
    }

    @Test("X-8: opting in then out before a download goes back to the stable feed")
    func x8() {
        var routing = UpdateRouting(running: running(79, .stable), settings: UpdateSettings())
        #expect(routing.preferenceChanged(enrolled: true, sessionInProgress: false) == .restartCycleAndCheck)
        routing.startCheck(settings: UpdateSettings(enrolled: true))
        #expect(routing.route.feedURL == BetaUpdates.betaFeedURL)
        #expect(routing.preferenceChanged(enrolled: false, sessionInProgress: false) == .restartCycle)
        routing.startCheck(settings: UpdateSettings(enrolled: false))
        #expect(routing.state == .stable)
        #expect(routing.route.feedURL == nil && routing.route.allowedChannels.isEmpty)
        #expect(routing.choose([beta(81)]) == nil)
        #expect(routing.pending == nil)
    }

    @Test("An enrolled player on a stable build is offered a higher stable")
    func enrolledStable() {
        var routing = checking(running(79, .stable), enrolled: true)
        #expect(picked(&routing, [stable(80)]) == .some(stable(80)), "no catch-up list needed from a stable build")
        var higher = checking(running(79, .stable), enrolled: true)
        #expect(picked(&higher, [beta(81), stable(86, contains: "81")]) == .some(stable(86, contains: "81")))
    }

    @Test("Never a build equal to or below the running one")
    func neverDown() {
        var routing = checking(running(82, .beta), enrolled: true)
        #expect(picked(&routing, [beta(82), beta(81, critical: true), stable(80, contains: "82")]) == .some(nil))
    }

    @Test("A preference change mid-session restarts the cycle once the session ends")
    func queuedRestart() {
        var routing = UpdateRouting(running: running(79, .stable), settings: UpdateSettings())
        #expect(routing.preferenceChanged(enrolled: true, sessionInProgress: true) == .none)
        #expect(routing.route.feedURL == nil, "the session in progress keeps its route")
        #expect(routing.sessionEnded() == .restartCycleAndCheck)
        #expect(routing.route.feedURL == BetaUpdates.betaFeedURL)
        #expect(routing.sessionEnded() == .none)
    }

    @Test("A preference change routes at once, and opting in checks without resetting first")
    func preferenceOrdering() {
        var routing = UpdateRouting(running: running(79, .stable), settings: UpdateSettings())
        let optIn = routing.preferenceChanged(enrolled: true, sessionInProgress: false)
        // Sparkle refuses a background check made while resetUpdateCycle's probe holds the session.
        #expect(optIn.calls == [.checkInBackground])
        #expect(routing.route.feedURL == BetaUpdates.betaFeedURL)
        #expect(routing.route.allowedChannels == ["beta", "beta-critical"])

        let optOut = routing.preferenceChanged(enrolled: false, sessionInProgress: false)
        #expect(optOut.calls == [.resetUpdateCycle])
        #expect(routing.route.feedURL == nil && routing.route.allowedChannels.isEmpty)
        #expect(UpdateRouting.PreferenceAction.none.calls.isEmpty)
    }
}

@Suite("Catch-up list")
struct CatchUpListTests {

    @Test("Ranges and single builds")
    func ranges() {
        let list = CatchUpList("81-85,87")
        #expect(list == .list([81...85, 87...87]))
        #expect(list.contains(81) && list.contains(83) && list.contains(85) && list.contains(87))
        #expect(!list.contains(80) && !list.contains(86) && !list.contains(88))
        #expect(CatchUpList(" 81, 83 ") == .list([81...81, 83...83]))
    }

    @Test("Empty and missing mean none")
    func none() {
        #expect(CatchUpList("") == .list([]))
        #expect(!CatchUpList("").contains(82))
        #expect(CatchUpList(nil) == .missing)
        #expect(!CatchUpList(nil).contains(82))
    }

    @Test("A malformed list is none, and the check's log line says so")
    func malformed() {
        for text in ["85-81", "81,,83", "a", "83,81", "81-83-85", "81-", "-81", "81,82-84,83", "+81", "８２"] {
            #expect(CatchUpList(text) == .malformed, "\(text)")
            #expect(!CatchUpList(text).contains(82))
        }
        var routing = checking(running(82, .beta), enrolled: true)
        routing.feedDidLoad()
        #expect(picked(&routing, [stable(86, contains: "82,banana")]) == .some(nil))
        let line = routing.notFound(reason: "no update", feedURL: BetaUpdates.betaFeedURL)
        #expect(line?.contains("malformed containsBetas on 86, treated as none") == true)
    }
}

@Suite("Feed fallback and overrides")
struct UpdateFeedTests {

    @Test("A failed beta-feed check sends the next check to the stable feed, under the same rules")
    func fallback() {
        var routing = checking(running(82, .beta), enrolled: true)
        let failed = routing.finished(error: "SUSparkleErrorDomain 2001", feedFailed: true, feedURL: BetaUpdates.betaFeedURL)
        #expect(failed?.contains("chosen=none (check failed: SUSparkleErrorDomain 2001)") == true)

        routing.startCheck(settings: UpdateSettings(enrolled: true))
        #expect(routing.route.feed == .stable && routing.route.feedURL == nil && routing.route.fallback)
        #expect(routing.route.allowedChannels == ["beta", "beta-critical"])
        #expect(picked(&routing, [stable(86, contains: "")]) == .some(nil), "the per-user rule still applies")
        routing.feedDidLoad()
        let line = routing.notFound(reason: "no update", feedURL: stableFeed)
        #expect(line?.contains("feed=\(stableFeed)") == true)
        #expect(line?.contains("stable feed after a failed beta-feed check") == true)

        routing.startCheck(settings: UpdateSettings(enrolled: true))
        #expect(routing.route.feed == .beta && !routing.route.fallback, "one check only")
    }

    @Test("No fallback for a feed that loaded, an error that isn't the feed's, or the stable state")
    func noFallback() {
        var loaded = checking(running(82, .beta), enrolled: true)
        loaded.feedDidLoad()
        _ = loaded.finished(error: "SUSparkleErrorDomain 1000", feedFailed: true, feedURL: nil)
        loaded.startCheck(settings: UpdateSettings(enrolled: true))
        #expect(loaded.route.feed == .beta)

        var other = checking(running(82, .beta), enrolled: true)
        _ = other.finished(error: "SUSparkleErrorDomain 4007", feedFailed: false, feedURL: nil)
        other.startCheck(settings: UpdateSettings(enrolled: true))
        #expect(other.route.feed == .beta)

        var offline = checking(running(79, .stable), enrolled: false)
        _ = offline.finished(error: "SUSparkleErrorDomain 2001", feedFailed: true, feedURL: stableFeed)
        offline.startCheck(settings: UpdateSettings())
        #expect(!offline.route.fallback && offline.route.feedURL == nil)
    }

    @Test("Overrides apply in any state and are noted on every check; a bad one is ignored")
    func overrides() {
        let settings = UpdateSettings(enrolled: false, betaFeedOverride: "http://127.0.0.1:8000/beta.xml",
                                      stableFeedOverride: "file:///tmp/stable.xml")
        let stableRoute = UpdateRoute.make(state: .stable, settings: settings, betaFeedFailed: false)
        #expect(stableRoute.feedURL == "file:///tmp/stable.xml")
        #expect(stableRoute.notes == ["StableFeedURLOverride used"])
        let betaRoute = UpdateRoute.make(state: .beta, settings: settings, betaFeedFailed: false)
        #expect(betaRoute.feedURL == "http://127.0.0.1:8000/beta.xml")
        #expect(betaRoute.notes == ["BetaFeedURLOverride used"])
        let fallback = UpdateRoute.make(state: .leaving, settings: settings, betaFeedFailed: true)
        #expect(fallback.feedURL == "file:///tmp/stable.xml")

        let bad = UpdateSettings(enrolled: true, betaFeedOverride: "not a url")
        let route = UpdateRoute.make(state: .beta, settings: bad, betaFeedFailed: false)
        #expect(route.feedURL == BetaUpdates.betaFeedURL)
        #expect(route.notes == ["BetaFeedURLOverride ignored (not a URL)"])
    }

    @Test("Overrides are read from defaults")
    func readOverrides() {
        let defaults = scratchDefaults()
        defaults.set("https://example.invalid/beta.xml", forKey: "BetaFeedURLOverride")
        defaults.set(42, forKey: "StableFeedURLOverride")
        let settings = UpdateSettings.read(defaults)
        #expect(settings.betaFeedOverride == "https://example.invalid/beta.xml")
        #expect(settings.stableFeedOverride == nil)
    }
}

@Suite("First run, offline and a hand-installed beta")
struct UpdateEdgeTests {

    @Test("First run: no defaults is the stable state and writes nothing")
    func firstRun() {
        let defaults = scratchDefaults()
        let before = NSDictionary(dictionary: defaults.dictionaryRepresentation())
        var routing = UpdateRouting(running: running(79, .stable), settings: .read(defaults))
        routing.startCheck(settings: .read(defaults))
        #expect(routing.state == .stable && routing.route.feedURL == nil)
        #expect(NSDictionary(dictionary: defaults.dictionaryRepresentation()) == before)
    }

    @Test("Offline: the check fails, is logged, and nothing changes")
    func offline() {
        var routing = checking(running(79, .stable), enrolled: false)
        let route = routing.route
        let line = routing.finished(error: "SUSparkleErrorDomain 2001", feedFailed: true, feedURL: stableFeed)
        #expect(line == "update check: state=stable feed=\(stableFeed) running=79 (stable) chosen=none (check failed: SUSparkleErrorDomain 2001) pending=none")
        routing.startCheck(settings: UpdateSettings())
        #expect(routing.route == route && routing.pending == nil)
    }

    @Test("A hand-installed beta with the preference off is leaving")
    func handInstalledBeta() {
        let defaults = scratchDefaults()
        var routing = UpdateRouting(running: running(82, .beta), settings: .read(defaults))
        routing.startCheck(settings: .read(defaults))
        #expect(routing.state == .leaving)
        #expect(routing.route.feedURL == BetaUpdates.betaFeedURL)
        #expect(routing.route.allowedChannels == ["beta-critical"])
    }

    @Test("One log line per check")
    func oneLine() {
        var routing = checking(running(82, .beta), enrolled: true)
        routing.feedDidLoad()
        #expect(routing.found(beta(84, critical: true), feedURL: BetaUpdates.betaFeedURL)
            == "update check: state=beta feed=\(BetaUpdates.betaFeedURL) running=82 (beta) chosen=84 (beta-critical) pending=none")
        #expect(routing.finished(error: nil, feedFailed: false, feedURL: nil) == nil)

        routing.startCheck(settings: UpdateSettings(enrolled: true))
        routing.feedDidLoad()
        _ = routing.choose([beta(81)])
        #expect(routing.notFound(reason: "up to date", feedURL: BetaUpdates.betaFeedURL)?
            .contains("chosen=none (no allowed item above 82)") == true)
        #expect(routing.finished(error: "SUSparkleErrorDomain 1001", feedFailed: false, feedURL: nil) == nil)
    }
}

@Suite("Pending updates")
struct PendingUpdateTests {

    @Test("A pending beta, then opting out: the beta still installs and the player is leaving")
    func pendingBetaOptOut() {
        var routing = checking(running(79, .stable), enrolled: true)
        routing.feedDidLoad()
        _ = routing.found(beta(83), feedURL: BetaUpdates.betaFeedURL)
        routing.waitingForQuit(beta(83))
        _ = routing.preferenceChanged(enrolled: false, sessionInProgress: true)
        let after = routing.prediction(enrolled: false)
        #expect(after == UpdatePrediction(label: "0.7.83-beta.1", build: "83", channel: .beta, state: .leaving,
                                          installsPending: true, pendingOutsideState: true))
    }

    @Test("A beta downloading, then opting out: it is pending until the download ends")
    func downloadingBetaOptOut() {
        var routing = checking(running(79, .stable), enrolled: true)
        routing.feedDidLoad()
        _ = routing.found(beta(83), feedURL: BetaUpdates.betaFeedURL)
        routing.downloading(beta(83))
        #expect(routing.preferenceChanged(enrolled: false, sessionInProgress: true) == .none)
        #expect(routing.prediction(enrolled: false)
            == UpdatePrediction(label: "0.7.83-beta.1", build: "83", channel: .beta, state: .leaving,
                                installsPending: true, pendingOutsideState: true))

        // It finished: Sparkle installs it on quit.
        var finished = routing
        finished.waitingForQuit(beta(83))
        #expect(finished.pending == PendingUpdate(item: beta(83), stage: .waitingForQuit))

        // It finished and the user chose later: Sparkle keeps it for a reminder.
        var kept = routing
        kept.downloaded(beta(83))
        var authorizeLater = kept
        _ = kept.finished(error: nil, feedFailed: false, feedURL: nil)
        #expect(kept.pending == PendingUpdate(item: beta(83), stage: .resumable))

        // Authorizing the install was put off: Sparkle keeps it too.
        _ = authorizeLater.finished(error: "SUSparkleErrorDomain 4008", feedFailed: false, authorizeLater: true, feedURL: nil)
        #expect(authorizeLater.pending == PendingUpdate(item: beta(83), stage: .resumable))

        // Extracting it failed: Sparkle drops it.
        var dropped = routing
        dropped.downloaded(beta(83))
        _ = dropped.finished(error: "SUSparkleErrorDomain 3000", feedFailed: false, feedURL: nil)
        #expect(dropped.pending == nil)

        // A download resumed from an earlier run is not this check's: an error leaves it to notFound.
        var earlier = checking(running(79, .stable), enrolled: true)
        _ = earlier.found(beta(83), feedURL: BetaUpdates.betaFeedURL)
        _ = earlier.finished(error: "SUSparkleErrorDomain 3000", feedFailed: false, feedURL: nil)
        #expect(earlier.pending == PendingUpdate(item: beta(83), stage: .resumable))

        // It stopped (failed, or quit first): nothing is pending.
        _ = routing.finished(error: "SUSparkleErrorDomain 2001", feedFailed: false, feedURL: nil)
        #expect(routing.pending == nil)
        #expect(routing.prediction(enrolled: false).installsPending == false)
    }

    @Test("A resumable beta, then opting out: Sparkle resumes it, the app logs it and predicts it")
    func resumableBetaOptOut() {
        var routing = checking(running(82, .beta), enrolled: true)
        // Sparkle resumes without fetching the feed.
        let line = routing.found(beta(83), feedURL: BetaUpdates.betaFeedURL)
        #expect(line == "update check: state=beta feed=not fetched running=82 (beta) chosen=83 (beta) pending=resumed 83 (beta)")
        #expect(routing.pending == PendingUpdate(item: beta(83), stage: .resumable))
        #expect(routing.resuming(beta(83)) == nil, "still allowed while enrolled")

        _ = routing.preferenceChanged(enrolled: false, sessionInProgress: false)
        #expect(routing.resuming(beta(83))
            == "update: resuming 83 (beta), which the leaving state does not allow; Sparkle installs it anyway")
        let after = routing.prediction(enrolled: false)
        #expect(after == UpdatePrediction(label: "0.7.83-beta.1", build: "83", channel: .beta, state: .leaving,
                                          installsPending: true, pendingOutsideState: true))
    }

    @Test("Opting in while a stable is pending: the stable installs and the player is enrolled")
    func optInWhileStablePending() {
        var routing = checking(running(79, .stable), enrolled: false)
        routing.feedDidLoad()
        _ = routing.found(stable(80), feedURL: stableFeed)
        routing.waitingForQuit(stable(80))
        _ = routing.preferenceChanged(enrolled: true, sessionInProgress: true)
        let after = routing.prediction(enrolled: true)
        #expect(after == UpdatePrediction(label: "0.7.80", build: "80", channel: .stable, state: .beta,
                                          installsPending: true, pendingOutsideState: false))
    }

    @Test("Nothing pending: the running build, in the state the preference gives it")
    func nothingPending() {
        let routing = UpdateRouting(running: running(82, .beta), settings: UpdateSettings(enrolled: true))
        #expect(routing.prediction(enrolled: false)
            == UpdatePrediction(label: "0.7.82-beta.1", build: "82", channel: .beta, state: .leaving,
                                installsPending: false, pendingOutsideState: false))
    }
}

@Suite("Player was behind")
struct LatestReleaseStateTests {

    @Test("Only a release found in the current state counts")
    func stateScoped() {
        let defaults = scratchDefaults()
        LatestRelease.record(build: "83", version: "0.7.83-beta.1", state: .beta, defaults: defaults)
        #expect(defaults.string(forKey: LatestRelease.stateKey) == "beta")
        #expect(LatestRelease.newer(than: "79", state: .stable, defaults: defaults) == nil)
        #expect(LatestRelease.newer(than: "79", state: .leaving, defaults: defaults) == nil)
        #expect(LatestRelease.newer(than: "79", state: .beta, defaults: defaults) == "0.7.83-beta.1 (83)")

        LatestRelease.record(build: "80", version: "0.7.80", defaults: defaults)
        #expect(defaults.object(forKey: LatestRelease.stateKey) == nil)
        #expect(LatestRelease.newer(than: "79", defaults: defaults) == "0.7.80 (80)")
    }

    @Test("The stable state writes no state key")
    func stableWritesNothingNew() {
        let defaults = scratchDefaults()
        LatestRelease.record(build: "80", version: "0.7.80", defaults: defaults)
        #expect(defaults.object(forKey: LatestRelease.stateKey) == nil)
    }
}

@Suite("Game reports carry the update state")
struct ReportUpdateStateTests {

    @Test("The payload has the updater state and build channel")
    func payload() throws {
        var machine = GameReport.Machine(chip: "Apple M4", memoryBytes: 16 * 1_073_741_824,
                                         macOS: "macOS 27.0", bridgeplay: "0.7.65-beta.2 (83)")
        machine.updateState = "leaving"
        machine.buildChannel = "beta"
        let payload = ReportPayload.make(name: "MGSV", appID: "287700", status: .gold, source: .tap, session: .byHand(),
                                         log: nil, wineLog: nil, machine: machine,
                                         install: "0F8FAD5B-D9CB-469F-A165-70867728950E")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        #expect(json?["updateState"] as? String == "leaving")
        #expect(json?["buildChannel"] as? String == "beta")
    }
}

@Suite("Update log file")
struct UpdateLogTests {

    @Test("Lines are appended, and a missing folder is never created")
    func append() throws {
        let dir = try scratchDirectory("updatelog")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "bridgeplay.log")
        try "dylib line\n".write(to: file, atomically: true, encoding: .utf8)
        UpdateLog.append("update check: one\n", to: file)
        UpdateLog.append("update check: two\n", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "dylib line\nupdate check: one\nupdate check: two\n")

        let missing = dir.appending(path: "absent/bridgeplay.log")
        UpdateLog.append("update check: three\n", to: missing)
        #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path(percentEncoded: false)))
    }
}
