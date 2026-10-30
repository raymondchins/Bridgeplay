import Foundation
import Testing
@testable import BridgeplayApp

@Suite("Update flow")
struct UpdateFlowTests {
    private func backgroundDownload(_ version: String = "0.7.59") -> UpdateFlow {
        var flow = UpdateFlow()
        flow.apply(.cycleStarted(byUser: false))
        flow.apply(.found(version: version))
        flow.apply(.downloading(version: version))
        return flow
    }

    @Test func aBackgroundCheckThatFindsNothingStaysOutOfSight() {
        var flow = UpdateFlow()
        flow.apply(.cycleStarted(byUser: false))
        #expect(flow.notice == nil)
        flow.apply(.cycleFinished)
        #expect(flow.notice == nil)
    }

    @Test func aFoundUpdateShowsBeforeTheDownloadFinishes() {
        var flow = UpdateFlow()
        flow.apply(.cycleStarted(byUser: false))
        flow.apply(.found(version: "0.7.59"))
        #expect(flow.notice == .available(version: "0.7.59"))
        flow.apply(.downloading(version: "0.7.59"))
        #expect(flow.notice == .downloading(version: "0.7.59"))
        flow.apply(.preparing(version: "0.7.59"))
        #expect(flow.notice == .preparing(version: "0.7.59"))
    }

    @Test func readyOutlivesTheSessionThatPreparedIt() {
        var flow = backgroundDownload()
        flow.apply(.ready(version: "0.7.59"))
        flow.apply(.cycleFinished)
        #expect(flow.notice == .ready(version: "0.7.59"))
        // Later background checks resume the same waiting installer.
        flow.apply(.cycleStarted(byUser: false))
        flow.apply(.found(version: "0.7.59"))
        #expect(flow.notice == .ready(version: "0.7.59"))
    }

    @Test func aClickDuringABackgroundSessionIsQueuedAndShown() {
        var flow = UpdateFlow()
        flow.apply(.cycleStarted(byUser: false))
        let click = flow.click(busy: true)
        #expect(click == .wait)
        #expect(flow.checkQueued)
        #expect(flow.notice == .checking)
    }

    @Test func aClickBeforeSparkleReportsTheSessionStillShows() {
        var flow = UpdateFlow()
        let click = flow.click(busy: true)
        #expect(click == .wait)
        #expect(flow.notice == .checking)
    }

    @Test func aQueuedCheckKeepsTheDownloadVisibleAndRunsOnce() {
        var flow = backgroundDownload()
        let click = flow.click(busy: true)
        #expect(click == .wait)
        #expect(flow.notice == .downloading(version: "0.7.59"))
        let first = flow.takeQueuedCheck()
        let second = flow.takeQueuedCheck()
        #expect(first)
        #expect(!second)
    }

    @Test func aFailedDownloadStillRunsTheQueuedCheck() {
        var flow = backgroundDownload()
        _ = flow.click(busy: true)
        flow.apply(.cycleFinished)
        #expect(flow.notice == .checking)
        let ran = flow.takeQueuedCheck()
        #expect(ran)
        #expect(flow.notice == nil)
    }

    @Test func nothingQueuedMeansNothingRuns() {
        var flow = UpdateFlow()
        let ran = flow.takeQueuedCheck()
        #expect(!ran)
    }

    @Test func aClickWhenIdleRuns() {
        var flow = UpdateFlow()
        let click = flow.click(busy: false)
        #expect(click == .run)
        #expect(!flow.checkQueued)
    }

    // The session stays open once ready, so anything queued would wait until quit.
    @Test func readyAnswersAQueuedClickItself() {
        var flow = backgroundDownload()
        _ = flow.click(busy: true)
        flow.apply(.ready(version: "0.7.59"))
        #expect(!flow.checkQueued)
        #expect(flow.notice == .ready(version: "0.7.59"))
    }

    @Test func aClickWhileReadyShowsTheBannerAndQueuesNothing() {
        var flow = backgroundDownload()
        flow.apply(.ready(version: "0.7.59"))
        let click = flow.click(busy: true)
        #expect(click == .wait)
        #expect(!flow.checkQueued)
    }

    @Test func aReminderForADownloadedUpdateLetsSparkleOfferIt() {
        var flow = UpdateFlow()
        flow.apply(.reminder(version: "0.7.59", downloaded: true))
        let click = flow.click(busy: false)
        #expect(click == .run)
        #expect(flow.restart(busy: false, canInstallNow: false) == .offer)
    }

    @Test func restartInstallsInOneClick() {
        var flow = backgroundDownload()
        flow.apply(.ready(version: "0.7.59"))
        #expect(flow.restart(busy: false, canInstallNow: true) == .install)
    }

    @Test func aRunningGameBlocksTheRestart() {
        var flow = backgroundDownload()
        flow.apply(.ready(version: "0.7.59"))
        flow.apply(.gameRunning(true))
        #expect(flow.restart(busy: false, canInstallNow: true) == .blocked)
        flow.apply(.gameRunning(false))
        #expect(flow.restart(busy: false, canInstallNow: true) == .install)
    }

    @Test func workInBridgeplayBlocksTheRestart() {
        var flow = backgroundDownload()
        flow.apply(.ready(version: "0.7.59"))
        #expect(flow.restart(busy: true, canInstallNow: true) == .blocked)
    }

    @Test func aSecondClickDuringAUserCheckFocusesItsWindow() {
        var flow = UpdateFlow()
        _ = flow.click(busy: false)
        flow.apply(.cycleStarted(byUser: true))
        let click = flow.click(busy: true)
        #expect(click == .focus)
        #expect(!flow.checkQueued)
    }

    @Test func aUserCheckShowsNoBannerOverSparklesWindow() {
        var flow = UpdateFlow()
        _ = flow.click(busy: false)
        flow.apply(.cycleStarted(byUser: true))
        flow.apply(.found(version: "0.7.59"))
        flow.apply(.downloading(version: "0.7.59"))
        #expect(flow.notice == nil)
    }

    @Test func aQueuedCheckCountsAsTheUsersOwn() {
        var flow = UpdateFlow()
        _ = flow.click(busy: true)
        let ran = flow.takeQueuedCheck()
        #expect(ran)
        let click = flow.click(busy: true)
        #expect(click == .focus)
    }

    @Test func aGentleReminderFollowsTheUpdatesStage() {
        var flow = UpdateFlow()
        flow.apply(.reminder(version: "0.7.59", downloaded: false))
        #expect(flow.notice == .available(version: "0.7.59"))
        flow.apply(.updateClosed)
        #expect(flow.notice == nil)
        flow.apply(.reminder(version: "0.7.59", downloaded: true))
        flow.apply(.updateClosed)
        #expect(flow.notice == .ready(version: "0.7.59"))
    }
}

@Suite("What's New")
struct WhatsNewTests {
    private func defaults() throws -> UserDefaults {
        let name = "WhatsNewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func showsOncePerBuild() throws {
        let defaults = try defaults()
        LatestRelease.record(build: "77", version: "0.7.60", notes: "- fix(panel): show the menu (#1)", defaults: defaults)
        let first = LatestRelease.takeWhatsNew(build: "77", defaults: defaults)
        #expect(first == WhatsNew(version: "0.7.60", changes: ["Show the menu"]))
        #expect(LatestRelease.takeWhatsNew(build: "77", defaults: defaults) == nil)
    }

    @Test func waitsForTheBuildItDescribes() throws {
        let defaults = try defaults()
        LatestRelease.record(build: "77", version: "0.7.60", notes: "- fix: a", defaults: defaults)
        #expect(LatestRelease.takeWhatsNew(build: "76", defaults: defaults) == nil)
        #expect(LatestRelease.takeWhatsNew(build: "77", defaults: defaults) != nil)
    }

    @Test func nothingRecordedShowsNothing() throws {
        #expect(LatestRelease.takeWhatsNew(build: "77", defaults: try defaults()) == nil)
    }

    @Test func aReleaseWithoutNotesStillSaysItUpdated() throws {
        let defaults = try defaults()
        LatestRelease.record(build: "77", version: "0.7.60", defaults: defaults)
        #expect(LatestRelease.takeWhatsNew(build: "77", defaults: defaults)?.changes == [])
    }

    @Test func keepsWhatAPlayerWouldNotice() {
        let notes = """
        - chore(release): Bridgeplay 0.7.59
        - test(prefixes): wait for the first tool scan instead of timing out (#1682)
        - fix(setup): say Rosetta is still needed when the password window is closed (#1660)
        - feat!: add a thing
        - docs(readme): link the guides (#1655)
        - Plain line with no type
        not a list item
        """
        #expect(LatestRelease.changes(in: notes) == [
            "Say Rosetta is still needed when the password window is closed",
            "Add a thing",
            "Plain line with no type",
        ])
    }
}
